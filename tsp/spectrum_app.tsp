-- spectrum_app.tsp -- interactive standalone spectrum analyser for the DMM6500
--
-- The touch options form and the on-instrument run loop, over fft_core.tsp (the
-- transform), spectrum_ui.tsp (fftsa.find_peaks) and spectrum_graph.tsp (fftsa.sg_*).
-- The stop frequency sets the sample rate (smallest exact rate >= 2*stop, so a
-- narrower span also gives finer resolution), the start frequency only windows the
-- display, and the input range is dmm.digitize.range.
--
-- Every display object and buffer is deleted and its handle cleared before a
-- replacement is created. Creating over a live handle drops the only reference to
-- the old object, which stays alive in the firmware until a power cycle.

fftsa = fftsa or {}   -- the single global this app exposes

-- FFT size, a power of two; every table, window and twiddle is sized from it. 512
-- gives 256 bins of 195.3 Hz at 100 kS/s. Halving it trades bin width for frame
-- rate; resolution was chosen. docs/PERFORMANCE.md has the frame-rate model.
fftsa.n       = 512

-- Floor for the start frequency. A start of 0 would admit bin 1, which is DC and,
-- with the mean removed by fftsa.fft_load(), holds only window leakage.
fftsa.flomin  = 10          -- floor for the start frequency (Hz)
fftsa.flo     = 10          -- display start frequency (Hz)
fftsa.fhi     = 50000       -- display stop frequency (Hz)
fftsa.range   = 10          -- digitizer input range (V): 0.1 / 1 / 10
fftsa.fs      = 100000      -- sample rate (picked from fftsa.fhi, then measured)
fftsa.binhz   = 0           -- true bin width, from measured fs
fftsa.busy    = false       -- reentrancy guard (never preserved across a reload)
fftsa.stop_pending = false  -- a teardown deferred until the running frame ends
fftsa.halted  = false       -- frames suppressed after repeated failures
fftsa.lasterr = nil         -- last frame error, nil if none
fftsa.errcount = 0          -- count of dropped frames
fftsa.errrun  = 0           -- consecutive dropped frames
fftsa.errmax  = 20          -- give up (and say so) after this many in a row
fftsa.shortreads = 0        -- captures rejected for returning fewer than n samples

-- Firmware handles, initialised only on the first load: opening the App again in
-- one power session re-runs this body, and clearing a live handle would strand the
-- previous launch's objects. fftsa.start()'s opening fftsa.stop() reclaims them.
if fftsa.handles_inited == nil then
  fftsa.cap      = nil      -- acquisition buffer
  fftsa.optbtn   = nil      -- Options button on the spectrum screen
  fftsa.timer    = nil      -- periodic timer driving frames
  fftsa.errscr   = nil      -- error screen shown if startup fails
  fftsa.optscr   = nil      -- options form screen
  fftsa.opt_flo  = nil      -- Start Frequency edit field
  fftsa.opt_fhi  = nil      -- Stop Frequency edit field
  fftsa.opt_rng  = nil      -- Input Range edit-option field
  fftsa.opt_info = nil      -- read-back info line on the options screen
  fftsa.handles_inited = true
end

-- Exact, achievable sample rates only; the hardware cannot produce 102400 S/s.
fftsa.rates = {1000, 10000, 20000, 50000, 100000, 200000, 500000, 1000000}

-- getvalue() on the OBJ_EDIT_OPTION field may return a 0- or 1-based index or the
-- option label, so fftsa.idx_to_range() accepts all three.
fftsa.ranges       = {0.1, 1, 10}
fftsa.range_labels = {"0.1 V", "1 V", "10 V"}

function fftsa.range_to_idx(r)
  for i = 1, table.getn(fftsa.ranges) do
    if fftsa.ranges[i] == r then return i end
  end
  return 3
end

function fftsa.idx_to_range(v)
  if type(v) == "string" then
    for j = 1, table.getn(fftsa.range_labels) do
      if v == fftsa.range_labels[j] then return fftsa.ranges[j] end
    end
    local n = tonumber(v)
    if n ~= nil then v = n else return fftsa.range end
  end
  local n = table.getn(fftsa.ranges)
  v = math.floor(v + 0.5)
  if v < 1 then v = v + 1 end       -- tolerate 0-based
  if v < 1 then v = 1 end
  if v > n then v = n end
  return fftsa.ranges[v]
end

function fftsa.pick_fs(fhi)
  local r = fftsa.rates
  local n = table.getn(r)
  for i = 1, n do
    if r[i] / 2 >= fhi then return r[i] end
  end
  return r[n]
end

function fftsa.measure_fs(buf)
  local n = buf.n
  if n < 4 then return fftsa.fs end
  local t1, tN = buf.relativetimestamps[1], buf.relativetimestamps[n]
  if tN <= t1 then return fftsa.fs end
  return (n - 1) / (tN - t1)
end

-- Apply the current settings to the hardware and the graph. Safe to repeat.
function fftsa.apply()
  fftsa.fs = fftsa.pick_fs(fftsa.fhi)
  fftsa.fft_init(fftsa.n)
  dmm.digitize.func       = dmm.FUNC_DIGITIZE_VOLTAGE
  dmm.digitize.range      = fftsa.range
  dmm.digitize.samplerate = fftsa.fs
  dmm.digitize.aperture   = 1e-6
  dmm.digitize.count      = fftsa.n
  if fftsa.cap ~= nil then
    fftsa.del_buf(fftsa.cap)
    fftsa.cap = nil
  end
  fftsa.cap = buffer.make(fftsa.n * 4, buffer.STYLE_STANDARD)
  dmm.digitize.read(fftsa.cap)
  fftsa.fs    = fftsa.measure_fs(fftsa.cap)     -- the samplerate readback is unreliable
  fftsa.binhz = fftsa.fs / fftsa.n
  fftsa.sg_set_xrange(fftsa.flo, fftsa.fhi)
  fftsa.sg_rebind()
end

-- One frame: acquire, transform, plot. Runs under pcall from fftsa.frame().
-- docs/PERFORMANCE.md has the measured phase costs.
function fftsa.frame_body()
  -- A frame can be dispatched while the app is half-built (a failed startup) or
  -- half-torn-down (End App, a host reload); bail out rather than index a nil.
  if fftsa.cap == nil or fftsa.sg_buf == nil or fftsa.sg_graph == nil
     or fftsa.sg_pk_f == nil then
    return
  end
  fftsa.cap.clear()
  dmm.digitize.read(fftsa.cap)
  -- A short capture is rejected, not transformed: zero-padding the tail would give
  -- a convincing but false broadband spectrum. The previous frame stays on screen.
  if fftsa.cap.n < fftsa.n then
    fftsa.shortreads = (fftsa.shortreads or 0) + 1
    return
  end
  fftsa.fft_load(fftsa.cap)
  fftsa.fft_run()
  fftsa.fft_power()
  local nb = fftsa.fft_m
  -- Peaks are searched in the window the graph plots, so the table matches the trace.
  local kmin, kmax = fftsa.sg_window_bins(nb, fftsa.binhz)
  local bi, bv = fftsa.find_peaks(nb, fftsa.sg_npeak, kmin, kmax)
  fftsa.sg_update(nb, fftsa.binhz)
  fftsa.sg_show_peaks(bi, bv, fftsa.sg_npeak, fftsa.binhz)
end

-- Reentrancy-guarded frame. The body runs under pcall so an error cannot leave
-- fftsa.busy set, which would make every later frame return at the top. A host
-- abort (event 1409) mid-frame is not covered by the pcall and does leave it set,
-- so a guard held longer than fftsa.busy_max is broken and the break counted.
fftsa.busy_since = nil
fftsa.busy_max   = 2.0      -- seconds a guard may be held before it is judged stuck
fftsa.busy_stuck = 0        -- how many times the guard had to be broken

function fftsa.frame()
  if fftsa.halted then return end
  if fftsa.busy then
    local since = fftsa.busy_since
    if since == nil or (os.clock() - since) < (fftsa.busy_max or 2.0) then return end
    fftsa.busy_stuck = (fftsa.busy_stuck or 0) + 1
  end
  fftsa.busy_since = os.clock()
  fftsa.busy = true
  local ok, err = pcall(fftsa.frame_body)
  if not ok then
    -- Re-bind the trace after a failure so the graph is never left without one.
    if fftsa.sg_graph ~= nil and fftsa.sg_buf ~= nil then
      pcall(function() fftsa.sg_rebind() end)
    end
    fftsa.lasterr  = tostring(err)
    fftsa.errcount = (fftsa.errcount or 0) + 1
    fftsa.errrun   = (fftsa.errrun or 0) + 1
    -- After a run of failures stop retrying and say so on screen: a trace that
    -- stopped updating looks like a working analyser on a dead signal.
    if fftsa.errrun >= (fftsa.errmax or 20) then
      fftsa.halted = true
      pcall(function()
        display.settext(fftsa.sg_xunit,
          "HALTED after " .. fftsa.errrun .. " failed frames: " ..
          string.sub(tostring(fftsa.lasterr), 1, 60))
      end)
    end
  else
    fftsa.errrun = 0
  end
  fftsa.busy = false
  -- A teardown that arrived mid-frame waits here, where nothing is in flight.
  if fftsa.stop_pending then
    fftsa.stop_pending = false
    pcall(function() fftsa.stop() end)
  end
end

-- The firmware frees the fields with their screen; the Lua handles still need clearing.
function fftsa.destroy_options()
  if fftsa.optscr ~= nil then
    -- Never delete the screen currently on show: leave it first.
    if fftsa.sg_scr ~= nil then
      pcall(function() display.changescreen(fftsa.sg_scr) end)
    else
      pcall(function() display.changescreen(display.SCREEN_HOME) end)
    end
    fftsa.del_obj(fftsa.optscr)
  end
  fftsa.optscr, fftsa.opt_flo, fftsa.opt_fhi, fftsa.opt_rng, fftsa.opt_info =
    nil, nil, nil, nil, nil
end

function fftsa.build_options()
  fftsa.destroy_options()

  local create = display.create
  -- A screen title over 31 characters is truncated by the firmware (event 1707).
  fftsa.optscr = create(display.ROOT, display.OBJ_SCREEN, "FFT ANALYSER OPTIONS")

  create(fftsa.optscr, display.OBJ_TEXT, 30, 62,
         "Touch a field to edit it, then Apply.", 11579568, display.FONT_MEDIUM,   -- grey B0B0B0
         display.JUST_LEFT)

  -- Edit objects draw their label and description to the left of the value box;
  -- x=270 leaves room for them.
  fftsa.opt_flo = create(fftsa.optscr, display.OBJ_EDIT_NUMBER, 270, 108,
                       "Start Frequency", "low edge (Hz)",
                       display.NFORMAT_PREFIX, fftsa.flo, fftsa.flomin, 499000, "Hz")
  fftsa.opt_fhi = create(fftsa.optscr, display.OBJ_EDIT_NUMBER, 270, 180,
                       "Stop Frequency", "sets sample rate",
                       display.NFORMAT_PREFIX, fftsa.fhi, 500, 500000, "Hz")
  fftsa.opt_rng = create(fftsa.optscr, display.OBJ_EDIT_OPTION, 270, 252,
                       "Input Range", "full-scale",
                       "0.1 V", "1 V", "10 V")

  fftsa.opt_info = create(fftsa.optscr, display.OBJ_TEXT, 30, 322, "",
                        56575, display.FONT_SMALL, display.JUST_LEFT)   -- cyan 00DCFF

  local b_apply = create(fftsa.optscr, display.OBJ_BUTTON, 470, 362, "Apply", 140)
  display.setevent(b_apply, display.EVENT_PRESS, "if fftsa ~= nil then fftsa.options_apply() end")
  local b_cancel = create(fftsa.optscr, display.OBJ_BUTTON, 630, 362, "Cancel", 140)
  display.setevent(b_cancel, display.EVENT_PRESS, "if fftsa ~= nil then fftsa.options_cancel() end")
  -- End App is hooked on this screen too: the firmware may deliver EVENT_ENDAPP to
  -- the visible screen, and leaving from the form must still tear down.
  pcall(function()
    display.setevent(fftsa.optscr, display.EVENT_ENDAPP, "if fftsa ~= nil then fftsa.cleanup() end")
  end)
  return fftsa.optscr
end

function fftsa.options()
  if fftsa.optscr == nil then fftsa.build_options() end
  pcall(function() display.setvalue(fftsa.opt_flo, fftsa.flo) end)
  pcall(function() display.setvalue(fftsa.opt_fhi, fftsa.fhi) end)
  pcall(function() display.setvalue(fftsa.opt_rng, fftsa.range_to_idx(fftsa.range)) end)
  pcall(function()
    display.settext(fftsa.opt_info, string.format(
      "Current:  %.0f - %.0f Hz    fs = %d S/s    bin = %.2f Hz    range = %g V",
      fftsa.flo, fftsa.fhi, fftsa.fs, fftsa.binhz, fftsa.range))
  end)
  display.changescreen(fftsa.optscr)
end

function fftsa.options_apply()
  local lo = display.getvalue(fftsa.opt_flo)
  local hi = display.getvalue(fftsa.opt_fhi)
  local ri = display.getvalue(fftsa.opt_rng)
  -- Validate the span as a pair: a new stop below the surviving start would leave
  -- flo > fhi, a window with no bins in it.
  local nlo, nhi = fftsa.flo, fftsa.fhi
  if hi ~= nil and hi > 0 then nhi = hi end
  if lo ~= nil and lo >= fftsa.flomin then nlo = lo end
  if nlo >= nhi then nlo = fftsa.flomin end
  fftsa.flo, fftsa.fhi = nlo, nhi
  if ri ~= nil then fftsa.range = fftsa.idx_to_range(ri) end
  display.changescreen(fftsa.sg_scr)
  fftsa.apply()
end

function fftsa.options_cancel()
  display.changescreen(fftsa.sg_scr)
end

function fftsa.build()
  fftsa.sg_build("FFT SPECTRUM ANALYSER", fftsa.n / 2)
  -- The button died with the screen fftsa.sg_build() just destroyed: clear the
  -- stale handle, do not delete it.
  fftsa.optbtn = nil
  fftsa.optbtn = display.create(fftsa.sg_scr, display.OBJ_BUTTON, 645, 350, "Options", 145)
  display.setevent(fftsa.optbtn, display.EVENT_PRESS, "if fftsa ~= nil then fftsa.options() end")
  fftsa.build_options()
  -- The frame timer is active only while its parent screen is visible.
  display.changescreen(fftsa.sg_scr)
  return fftsa.sg_scr
end

-- Arm the frame timer; it is active only while its parent screen is visible.
-- 0.05 s is the firmware's floor (arm(0.045) is refused with event 1131), and a
-- tick that lands during a frame is dropped, so the displayed rate is quantised;
-- docs/PERFORMANCE.md has the model. One frame per tick: back-to-back frames keep
-- the interpreter out of its event loop.
function fftsa.arm(period_s)
  if period_s == nil then period_s = 0.05 end
  if fftsa.timer ~= nil then
    fftsa.del_obj(fftsa.timer)
    fftsa.timer = nil
  end
  if fftsa.sg_scr == nil then return nil end
  fftsa.timer = display.create(fftsa.sg_scr, display.OBJ_TIMER, period_s, display.TIMER_FOREVER)
  display.setevent(fftsa.timer, display.EVENT_PRESS, "if fftsa ~= nil and fftsa.frame ~= nil then fftsa.frame() end")
  return fftsa.timer
end

function fftsa.cleanup()
  pcall(function() fftsa.stop() end)
end

-- Hooked as soon as the spectrum screen exists, so a later startup failure still
-- leaves a way out that cleans up.
function fftsa.install_cleanup()
  if fftsa.sg_scr == nil then return false end
  local ok, err = pcall(function()
    display.setevent(fftsa.sg_scr, display.EVENT_ENDAPP, "if fftsa ~= nil then fftsa.cleanup() end")
  end)
  if not ok then fftsa.lasterr = "ENDAPP hook failed: " .. tostring(err) end
  return ok
end

-- Startup, guarded end to end so a failure part-way leaves nothing without a
-- teardown. The opening fftsa.stop() reclaims a previous launch's handles: as an
-- installed App the script re-runs on every open, and an exit that skipped
-- EVENT_ENDAPP (the Home screen, another App) leaves them behind.
function fftsa.start()
  pcall(function() fftsa.stop() end)
  fftsa.halted, fftsa.errrun, fftsa.stop_pending = false, 0, false

  local hooked = false
  local ok, err = pcall(function()
    fftsa.build()
    hooked = fftsa.install_cleanup()
    fftsa.apply()
    fftsa.arm()
  end)
  if not ok then
    fftsa.lasterr = tostring(err)
    pcall(function() fftsa.stop() end)
    print("fftsa start FAILED (cleaned up): " .. tostring(err))
    -- No console as an installed App, so the failure goes on the panel.
    fftsa.show_error(tostring(err))
    return false
  end
  if not hooked then
    print("fftsa WARNING: End App cleanup not hooked -- " .. tostring(fftsa.lasterr))
    pcall(function()
      display.settext(fftsa.sg_xunit, "WARNING: End App will not clean up")
    end)
  end
  print("fftsa started fs=" .. fftsa.fs .. " bin=" .. fftsa.binhz .. " range=" .. fftsa.range)
  return true
end

function fftsa.stop()
  -- Not underneath a running frame, which would be left writing into a deleted
  -- buffer: defer once (fftsa.frame() runs the pending stop as it finishes), then
  -- proceed regardless, so a stuck guard cannot make the app impossible to stop.
  if fftsa.busy and not fftsa.stop_pending then
    fftsa.stop_pending = true
    return false
  end
  fftsa.stop_pending = false
  -- Timer first: stop frames before removing what the frames use.
  if fftsa.timer ~= nil then fftsa.del_obj(fftsa.timer) end
  fftsa.timer = nil
  fftsa.optbtn = nil                          -- child of the spectrum screen
  pcall(function() fftsa.sg_destroy() end)    -- screen, graph, texts, spectrum buffer
  fftsa.destroy_options()
  if fftsa.errscr ~= nil then
    fftsa.del_obj(fftsa.errscr)
    fftsa.errscr = nil
  end
  if fftsa.cap ~= nil then
    fftsa.del_buf(fftsa.cap)
    fftsa.cap = nil
  end
  fftsa.busy, fftsa.halted, fftsa.errrun = false, false, 0
  return true
end

-- Startup failure on the panel. End App is hooked here too, and the handle is kept
-- so fftsa.stop() can delete the screen.
function fftsa.show_error(msg)
  pcall(function()
    if fftsa.errscr ~= nil then
      fftsa.del_obj(fftsa.errscr)
      fftsa.errscr = nil
    end
    fftsa.errscr = display.create(display.ROOT, display.OBJ_SCREEN, "FFT ANALYSER ERROR")
    display.create(fftsa.errscr, display.OBJ_TEXT, 20, 80,
                   "The analyser could not start.", 16736352,   -- red FF6060
                   display.FONT_MEDIUM, display.JUST_LEFT)
    local m = tostring(msg)
    local y = 140
    local i = 1
    while i <= string.len(m) and y <= 400 do
      display.create(fftsa.errscr, display.OBJ_TEXT, 20, y, string.sub(m, i, i + 79),
                     14737632, display.FONT_SMALL, display.JUST_LEFT)   -- light grey E0E0E0
      i = i + 80
      y = y + 22
    end
    display.create(fftsa.errscr, display.OBJ_TEXT, 20, 420,
                   "Press End App to exit.", 9474192,   -- grey 909090
                   display.FONT_SMALL, display.JUST_LEFT)
    display.setevent(fftsa.errscr, display.EVENT_ENDAPP, "if fftsa ~= nil then fftsa.cleanup() end")
    display.changescreen(fftsa.errscr)
  end)
  return fftsa.errscr
end
