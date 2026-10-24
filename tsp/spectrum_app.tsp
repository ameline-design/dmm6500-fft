-- spectrum_app.tsp -- interactive standalone spectrum analyser for the DMM6500
--
-- The touch options form and the on-instrument run loop, over fft_core.tsp (the
-- transform and the windows), spectrum_ui.tsp (the loading cover, fftsa.find_peaks)
-- and spectrum_graph.tsp (fftsa.sg_*). The stop frequency sets the sample rate
-- (smallest exact rate >= 2*stop, so a narrower span also gives finer resolution),
-- the start frequency only windows the display, the input range is
-- dmm.digitize.range, and the window and its beta pick the analysis window.
--
-- Every screen, field and buffer is created once in fftsa.start(), behind the
-- loading cover, and deleted once by fftsa.stop(). A press only ever switches
-- screens: a create/delete cycle risks part of the 463-object pool for the rest of
-- the power cycle, because a refused display.delete raises nothing.

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
-- Nyquist at the fixed 100 kS/s. The floor is not a hardware limit but a useful
-- one: the span no longer changes the bin width, so 2 kHz is already down to about
-- ten bins across the plot and anything narrower is a handful of points.
fftsa.fhi_max = 50000
fftsa.fhi_min = 2000
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
  fftsa.cap_n    = nil      -- the fftsa.n it was sized for
  fftsa.optbtn   = nil      -- Options button on the spectrum screen
  fftsa.timer    = nil      -- periodic timer driving frames
  fftsa.errscr   = nil      -- error screen shown if startup fails
  fftsa.optscr   = nil      -- options form screen
  fftsa.opt_flo  = nil      -- Start Frequency edit field
  fftsa.opt_fhi  = nil      -- Stop Frequency edit field
  fftsa.opt_rng  = nil      -- Input Range edit-option field
  fftsa.opt_win  = nil      -- Window edit-option field
  fftsa.opt_beta = nil      -- Kaiser Beta edit-option field
  fftsa.opt_info = nil      -- read-back info line on the options screen
  fftsa.handles_inited = true
end

-- Sample rates, floored at 10 kS/s. A narrow span buys finer bins; the floor is
-- there because 512 samples cost 512/fs of pure waiting -- 5 ms at 100 kS/s, 51 ms
-- at 10 kS/s, 512 ms at 1 kS/s -- and a press is only dispatched while Lua is idle,
-- so a frame long enough starves the touch handler and the Options button stops
-- answering. At 10 kS/s the frame is about 129 ms against a 150 ms timer cadence,
-- which leaves 21 ms of idle; the operator judged that enough.
--
-- 100 kS/s is the ceiling, so Nyquist puts the top of the range at 50 kHz.
fftsa.rates = {10000, 20000, 50000, 100000}

function fftsa.pick_fs(fhi)
  local r = fftsa.rates
  local n = table.getn(r)
  for i = 1, n do
    if r[i] / 2 >= fhi then return r[i] end
  end
  return r[n]
end

fftsa.ranges       = {0.1, 1, 10}
fftsa.range_labels = {"0.1 V", "1 V", "10 V"}

function fftsa.range_to_idx(r)
  for i = 1, table.getn(fftsa.ranges) do
    if fftsa.ranges[i] == r then return i end
  end
  return 3
end

-- getvalue() on an OBJ_EDIT_OPTION returns the 1-based index, but it can also come
-- back as the option's own label, so both are read. Anything outside the list
-- clamps: an index used raw would otherwise fetch a nil option.
function fftsa.opt_index(v, labels, fallback)
  local n = table.getn(labels)
  if type(v) == "string" then
    for j = 1, n do
      if v == labels[j] then return j end
    end
    v = tonumber(v)
  end
  if v == nil then return fallback end
  v = math.floor(v + 0.5)
  if v < 1 then v = 1 end
  if v > n then v = n end
  return v
end

function fftsa.idx_to_range(v)
  local i = fftsa.opt_index(v, fftsa.range_labels, fftsa.range_to_idx(fftsa.range))
  return fftsa.ranges[i]
end

function fftsa.measure_fs(buf)
  local n = buf.n
  if n < 4 then return fftsa.fs end
  local t1, tN = buf.relativetimestamps[1], buf.relativetimestamps[n]
  if tN <= t1 then return fftsa.fs end
  return (n - 1) / (tN - t1)
end

-- Apply the current settings to the hardware and the graph. Safe to repeat: the
-- capture buffer is reused, since only fftsa.n sizes it and that does not change at
-- runtime. fftsa.fft_init() rebuilds the window and its interpolation tables, which
-- is the slow part of a press -- about 0.3 s for Kaiser -- hence the cover.
function fftsa.apply()
  fftsa.fs = fftsa.pick_fs(fftsa.fhi)
  fftsa.fft_init(fftsa.n)
  dmm.digitize.func       = dmm.FUNC_DIGITIZE_VOLTAGE
  dmm.digitize.range      = fftsa.range
  dmm.digitize.samplerate = fftsa.fs
  dmm.digitize.aperture   = 1e-6
  dmm.digitize.count      = fftsa.n
  if fftsa.cap ~= nil and fftsa.cap_n ~= fftsa.n then
    fftsa.del_buf(fftsa.cap)
    fftsa.cap = nil
  end
  if fftsa.cap == nil then
    fftsa.cap   = buffer.make(fftsa.n * 4, buffer.STYLE_STANDARD)
    fftsa.cap_n = fftsa.n
  end
  fftsa.cap.clear()
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
    pcall(function() fftsa.show_main() end)
    fftsa.del_obj(fftsa.optscr)
  end
  fftsa.optscr, fftsa.opt_flo, fftsa.opt_fhi, fftsa.opt_rng, fftsa.opt_info =
    nil, nil, nil, nil, nil
  fftsa.opt_win, fftsa.opt_beta = nil, nil
end

-- Form geometry, two columns like the decode app's: five fields become three rows,
-- and the gap that buys is what makes each box a touch target. display.create takes
-- no width for an OBJ_EDIT_*, so the second column's x is the one number to check on
-- the glass. Labels are right-aligned and end at the column x.
fftsa.opt_nf      = 5
fftsa.opt_cols    = 2
fftsa.opt_x       = 185
fftsa.opt_x_c2    = 552
fftsa.opt_y0      = 8
fftsa.opt_dy      = 100     -- preferred pitch; clamped to what fits
fftsa.opt_edit_h  = 50      -- box height, measured
fftsa.opt_edit_dy = 4       -- offset of the box inside the object
fftsa.opt_y_adj   = -8      -- nudge of the centred block, negative being up
fftsa.opt_btn_y   = 360
fftsa.opt_btn_gap = 24      -- air kept between the last box and the button row
fftsa.opt_info_y  = 318

-- Rows, pitch and top for the field block. The pitch asks for every pixel available
-- and the clamp decides what it gets: the last box has to end above the button row.
function fftsa.opt_layout()
  local nrows = math.ceil(fftsa.opt_nf / fftsa.opt_cols)
  local eh, edy = fftsa.opt_edit_h, fftsa.opt_edit_dy
  local y0, dy  = fftsa.opt_y0, fftsa.opt_dy
  if nrows > 1 then
    local maxdy = math.floor((fftsa.opt_btn_y - fftsa.opt_btn_gap - y0 - edy - eh)
                             / (nrows - 1))
    if dy > maxdy then dy = maxdy end
  end
  -- Centred, because three rows do not fill the form, then nudged. Only ever down,
  -- and only by what is spare; the nudge is separate from y0 because the centring
  -- divides the leftover space and would give back half of a move asked for there.
  local spare = fftsa.opt_btn_y - ((nrows - 1) * dy + eh + edy) - y0
  if spare > 0 then y0 = y0 + math.floor(spare / 2) end
  if y0 + fftsa.opt_y_adj >= 0 then y0 = y0 + fftsa.opt_y_adj end
  fftsa.opt_nrows, fftsa.opt_dy_used, fftsa.opt_y0_used = nrows, dy, y0
  return nrows, dy, y0
end

function fftsa.build_options()
  fftsa.destroy_options()

  local create = display.create
  -- A screen title over 31 characters is truncated by the firmware (event 1707).
  fftsa.optscr = create(display.ROOT, display.OBJ_SCREEN, "FFT ANALYSER OPTIONS")
  if fftsa.optscr == nil then
    error("display object pool exhausted building the options screen -- power "
          .. "cycle the instrument.", 0)
  end
  fftsa.loading_front()

  -- Columns fill top to bottom, left column first. No instructions on the form:
  -- the fields label themselves.
  local nrows, dy, y0 = fftsa.opt_layout()
  local row = 0
  local function nextpos()
    local c = math.floor(row / nrows)
    if c > fftsa.opt_cols - 1 then c = fftsa.opt_cols - 1 end
    local fx = fftsa.opt_x
    if c > 0 then fx = fftsa.opt_x_c2 end
    local fy = y0 + (row - c * nrows) * dy
    row = row + 1
    return fx, fy
  end

  local x1, y1 = nextpos()
  fftsa.opt_flo = create(fftsa.optscr, display.OBJ_EDIT_NUMBER, x1, y1,
                       "Start Freq", "low edge",
                       display.NFORMAT_PREFIX, fftsa.flo, fftsa.flomin, fftsa.fhi_max - 1000, "Hz")
  local x2, y2 = nextpos()
  fftsa.opt_fhi = create(fftsa.optscr, display.OBJ_EDIT_NUMBER, x2, y2,
                       "Stop Freq", "display top",
                       display.NFORMAT_PREFIX, fftsa.fhi, fftsa.fhi_min, fftsa.fhi_max, "Hz")
  local x3, y3 = nextpos()
  fftsa.opt_rng = create(fftsa.optscr, display.OBJ_EDIT_OPTION, x3, y3,
                       "Input Range", "full-scale",
                       fftsa.range_labels[1], fftsa.range_labels[2], fftsa.range_labels[3])
  -- Spelled out rather than built from the table: display.create takes the options
  -- as separate arguments and Lua 5.0.2 has no unpack() worth using here.
  local x4, y4 = nextpos()
  fftsa.opt_win = create(fftsa.optscr, display.OBJ_EDIT_OPTION, x4, y4,
                       "Window", "lobe vs sidelobe",
                       fftsa.win_names[1], fftsa.win_names[2], fftsa.win_names[3],
                       fftsa.win_names[4])
  -- Always built, not only when Kaiser is selected: a field created on a press is a
  -- create on a visible screen, and this one is inert for the other four windows.
  local x5, y5 = nextpos()
  fftsa.opt_beta = create(fftsa.optscr, display.OBJ_EDIT_OPTION, x5, y5,
                       "Kaiser Beta", "sidelobe level",
                       fftsa.kbeta_labels[1], fftsa.kbeta_labels[2], fftsa.kbeta_labels[3],
                       fftsa.kbeta_labels[4], fftsa.kbeta_labels[5], fftsa.kbeta_labels[6])

  fftsa.opt_info = create(fftsa.optscr, display.OBJ_TEXT, 30, fftsa.opt_info_y, "",
                        56575, display.FONT_SMALL, display.JUST_LEFT)   -- cyan 00DCFF

  local b_apply = create(fftsa.optscr, display.OBJ_BUTTON, 470, fftsa.opt_btn_y, "Apply", 140)
  display.setevent(b_apply, display.EVENT_PRESS, "if fftsa ~= nil then fftsa.guard(fftsa.options_apply) end")
  local b_cancel = create(fftsa.optscr, display.OBJ_BUTTON, 630, fftsa.opt_btn_y, "Cancel", 140)
  display.setevent(b_cancel, display.EVENT_PRESS, "if fftsa ~= nil then fftsa.guard(fftsa.options_cancel) end")
  -- End App is hooked on this screen too: the firmware may deliver EVENT_ENDAPP to
  -- the visible screen, and leaving from the form must still tear down.
  pcall(function()
    display.setevent(fftsa.optscr, display.EVENT_ENDAPP, "if fftsa ~= nil then fftsa.cleanup() end")
  end)
  return fftsa.optscr
end

-- The settings as they ended up, which is not always as they were asked for: the
-- sample rate snaps to an achievable one and the bin width follows the measured rate.
function fftsa.opt_info_text()
  return string.format("%.0f - %.0f Hz    fs %d S/s    bin %.2f Hz    %g V    %s",
                       fftsa.flo, fftsa.fhi, fftsa.fs, fftsa.binhz, fftsa.range,
                       fftsa.win_label())
end

-- Every button press goes through here. A press is dispatched by the firmware
-- evaluating the command string setevent was given, and an error raised inside that
-- string arrives as a dialog over the app, not as a return value anyone can read --
-- so the handler is the last place that can catch it.
function fftsa.guard(f)
  if f == nil then return false end
  local ok, err = pcall(f)
  if not ok then
    fftsa.lasterr = "button handler failed: " .. tostring(err)
    fftsa.say(fftsa.lasterr)
  end
  return ok
end

-- Put a line on the glass where the axis legend goes. Failures that are only
-- recorded in fftsa.lasterr are invisible to the operator, who sees a press that
-- did nothing and a previous spectrum still running. The legend is rewritten by the
-- next fftsa.sg_set_xrange(), so this is not sticky.
function fftsa.say(msg)
  pcall(function()
    if fftsa.sg_xunit ~= nil then
      display.settext(fftsa.sg_xunit, string.sub(tostring(msg), 1, 70))
    end
  end)
end

-- Back to the spectrum screen, which is also what lets the frame timer run again.
function fftsa.show_main()
  if fftsa.sg_scr ~= nil then
    display.changescreen(fftsa.sg_scr)
    return true
  end
  pcall(function() display.changescreen(display.SCREEN_HOME) end)
  return false
end

-- A press only switches. Everything is built in fftsa.start(), so a nil handle
-- means the object pool refused and building it now would fail the same way.
function fftsa.options()
  if fftsa.optscr == nil then return false end
  pcall(function() display.setvalue(fftsa.opt_flo, fftsa.flo) end)
  pcall(function() display.setvalue(fftsa.opt_fhi, fftsa.fhi) end)
  pcall(function() display.setvalue(fftsa.opt_rng, fftsa.range_to_idx(fftsa.range)) end)
  pcall(function() display.setvalue(fftsa.opt_win, fftsa.win_i) end)
  pcall(function() display.setvalue(fftsa.opt_beta, fftsa.kbeta_i) end)
  pcall(function() display.settext(fftsa.opt_info, fftsa.opt_info_text()) end)
  display.changescreen(fftsa.optscr)
  return true
end

function fftsa.options_apply()
  local lo = display.getvalue(fftsa.opt_flo)
  local hi = display.getvalue(fftsa.opt_fhi)
  local ri = display.getvalue(fftsa.opt_rng)
  local wi = display.getvalue(fftsa.opt_win)
  local bi = display.getvalue(fftsa.opt_beta)
  -- Clamp each end to what the fixed rate can show, then order the pair: a stop at
  -- or below the start is a window with no bins in it. One repair is enough and
  -- provably so -- the stop lands in fhi_min..fhi_max and fhi_min is above flomin,
  -- so dropping the start to its floor always leaves start < stop. Repairing the
  -- start without re-testing the stop does NOT, which is why the order matters.
  local nlo, nhi = fftsa.flo, fftsa.fhi
  if hi ~= nil and hi > 0 then nhi = hi end
  if lo ~= nil and lo >= 0 then nlo = lo end
  if nhi > fftsa.fhi_max then nhi = fftsa.fhi_max end
  if nhi < fftsa.fhi_min then nhi = fftsa.fhi_min end
  if nlo < fftsa.flomin then nlo = fftsa.flomin end
  if nlo >= nhi then nlo = fftsa.flomin end
  fftsa.flo, fftsa.fhi = nlo, nhi
  fftsa.range   = fftsa.idx_to_range(ri)
  fftsa.win_i   = fftsa.opt_index(wi, fftsa.win_names, fftsa.win_i)
  fftsa.kbeta_i = fftsa.opt_index(bi, fftsa.kbeta_labels, fftsa.kbeta_i)
  -- Under the cover: fftsa.apply() rebuilds the window tables and takes a capture,
  -- and the frame timer does not run while its screen is off show, so no frame can
  -- meet half-rebuilt tables.
  fftsa.loading_front()
  local ok, err = pcall(function() fftsa.apply() end)
  fftsa.show_main()
  if not ok then
    fftsa.lasterr = tostring(err)
    fftsa.say("APPLY FAILED: " .. tostring(err))
  else
    pcall(function() display.settext(fftsa.sg_xunit, fftsa.sg_xunit_text()) end)
  end
  return ok
end

function fftsa.options_cancel()
  fftsa.show_main()
end

-- Everything the app ever displays, created here and nowhere else. The cover comes
-- first so that no screen is ever assembled in view.
function fftsa.build()
  fftsa.loading_build()
  fftsa.loading_front()
  fftsa.sg_build("FFT SPECTRUM ANALYSER", fftsa.n / 2)
  -- The button died with the screen fftsa.sg_build() just destroyed: clear the
  -- stale handle, do not delete it.
  fftsa.optbtn = nil
  fftsa.optbtn = display.create(fftsa.sg_scr, display.OBJ_BUTTON, 645, 350, "Options", 145)
  display.setevent(fftsa.optbtn, display.EVENT_PRESS, "if fftsa ~= nil then fftsa.guard(fftsa.options) end")
  fftsa.build_options()
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
  print("fftsa started fs=" .. fftsa.fs .. " bin=" .. fftsa.binhz ..
        " range=" .. fftsa.range .. " window=" .. fftsa.win_label())
  -- Switching away from the cover is what starts the frames: the timer only runs
  -- while the screen it is parented to is the one on show. The cover itself stays
  -- allocated until fftsa.stop(), since Apply raises it again.
  fftsa.show_main()
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
  pcall(function() fftsa.loading_destroy(display.SCREEN_HOME) end)
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
