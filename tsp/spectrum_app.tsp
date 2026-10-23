-- spectrum_app.tsp -- interactive standalone spectrum analyser for the DMM6500
--
-- Uses the other modules:
--   fft_core.tsp       real-input FFT
--   spectrum_ui.tsp    fftsa.find_peaks()
--   spectrum_graph.tsp fftsa.sg_build / fftsa.sg_update / fftsa.sg_bind_min / fftsa.sg_show_peaks / etc.
--
-- Provides a touch OPTIONS FORM (a screen of editable fields, not a chain of
-- modal prompts) and an on-instrument run loop, so the app runs by itself.
--
-- OPTIONS SEMANTICS (like a real spectrum analyser):
--   Stop frequency  -> sets the sample rate: fs = smallest EXACT rate >= 2*stop.
--                      A narrower span therefore also gives finer resolution.
--                      Only exact decimal rates are used (102400 is NOT exact).
--   Start frequency -> restricts the displayed span to [start, stop]; the graph
--                      shows only the bins in that window (see fftsa.sg_set_xrange).
--   Input range     -> dmm.digitize.range, one of 0.1 / 1 / 10 V (fixed).
--
-- OBJECT LIFETIME: every display object and buffer is deleted and its handle set
-- to nil before a replacement is created (fftsa.sg_destroy / fftsa.destroy_options /
-- fftsa.arm / fftsa.apply). Creating over a live handle would overwrite the only
-- reference to the old object, stranding it in the firmware with no way to delete
-- it until the next power cycle -- and it is accumulated display churn, not any
-- single call, that walks this instrument toward a panic.

fftsa = fftsa or {}   -- the single global this app exposes

fftsa.n       = 512         -- FFT size (256 bins). Power of two.
-- Lowest start frequency the app will accept or display. Bin 1 is DC, and
-- fftsa.fft_load() subtracts the mean, so bin 1 carries only the residual the
-- window leaks -- never a signal. Including it puts a meaningless spike at the
-- left edge of every trace and lets it into the peak table, so the span starts
-- above DC. 10 Hz is below the lowest bin width the app can produce, so it costs
-- no real signal at any sample rate.
fftsa.flomin  = 10          -- floor for the start frequency (Hz)
fftsa.flo     = 10          -- display start frequency (Hz)
fftsa.fhi     = 50000       -- display stop frequency (Hz)
fftsa.range   = 10          -- digitizer input range (V): 0.1 / 1 / 10
fftsa.fs      = 100000      -- sample rate (derived from fftsa.fhi)
fftsa.binhz   = 0           -- true bin width, from measured fs
fftsa.busy    = false       -- reentrancy guard (never preserved across a reload)
fftsa.stop_pending = false  -- a teardown deferred until the running frame ends
fftsa.halted  = false       -- frames suppressed after repeated failures
fftsa.lasterr = nil         -- last frame error (nil if none) -- diagnosis
fftsa.errcount = 0          -- count of dropped frames
fftsa.errrun  = 0           -- CONSECUTIVE dropped frames
fftsa.errmax  = 20          -- give up (and say so) after this many in a row: 6 s
fftsa.shortreads = 0        -- captures rejected for returning fewer than n samples

-- FIRMWARE HANDLES -- initialised ONLY on the first load (see the same block in
-- spectrum_graph.tsp for the full reasoning). Opening the App a second time in one
-- power session re-runs this body; clearing a live handle here would strand the
-- previous launch's timer, screens and buffer in the firmware until a power cycle.
-- Keeping them lets fftsa.start()'s opening fftsa.stop() reclaim them properly.
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

-- 1-based index <-> range for the OBJ_EDIT_OPTION field. getvalue() may hand back
-- a numeric index (0- OR 1-based, firmware-dependent) or the option label string,
-- so fftsa.idx_to_range() tolerates all three.
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

-- Smallest exact rate whose Nyquist (fs/2) covers the requested stop frequency.
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

-- Apply the current fftsa settings to the hardware and the graph. Safe to call
-- repeatedly (that is what the Options Apply button does).
function fftsa.apply()
  fftsa.fs = fftsa.pick_fs(fftsa.fhi)
  fftsa.fft_init(fftsa.n)
  dmm.digitize.func       = dmm.FUNC_DIGITIZE_VOLTAGE
  dmm.digitize.range      = fftsa.range
  dmm.digitize.samplerate = fftsa.fs
  dmm.digitize.aperture   = 1e-6
  dmm.digitize.count      = fftsa.n
  -- Acquisition buffer: delete the old one and clear the handle BEFORE making a
  -- new one, so re-applying can never strand a buffer behind an overwritten
  -- reference (and a changed fftsa.n always gets a correctly sized buffer).
  -- Apply is user-paced, so this costs nothing per frame.
  if fftsa.cap ~= nil then
    fftsa.del_buf(fftsa.cap)
    fftsa.cap = nil
  end
  fftsa.cap = buffer.make(fftsa.n * 4, buffer.STYLE_STANDARD)
  dmm.digitize.read(fftsa.cap)
  fftsa.fs    = fftsa.measure_fs(fftsa.cap)     -- the samplerate readback is unreliable
  fftsa.binhz = fftsa.fs / fftsa.n
  -- Restrict the displayed span to [start, stop]. fftsa.sg_update() then plots only the
  -- bins in that window, so the graph auto-ranges to it.
  fftsa.sg_set_xrange(fftsa.flo, fftsa.fhi)
  fftsa.sg_rebind()
end

-- The per-frame work (one acquisition + FFT + display), split out so fftsa.frame()
-- can run it under pcall.
--
-- Measured frame budget at 256 bins, in ms: fft_run 30.6, sg_update 24.7,
-- fft_load 15.3, digitize.read 6.2, find_peaks 1.9, fft_magnitude 1.5
-- sg_show_peaks 0.9, cap.clear 0.2 -- 81.4 total, so 12.3 Hz. The transform and
-- the buffer refill now dominate; the display path is no longer the limit.
--
-- The display figures above are for the detach-first order sg_update() now
-- uses. It used to refill the buffer first and call sg_bind_min() after, which
-- paid two avoidable costs: the writes went through a live subscription at
-- 76 us a point instead of 54, and removeall then waited on the paint of the
-- frame it was in rather than the one before. sg_bind_min() is kept for callers
-- that genuinely need a re-attach, but nothing per-frame calls it.
--
-- Do not "optimise" the removeall away. It is the only thing in the frame that
-- blocks for the display task, and that task is not scheduled while Lua runs --
-- see the measurements in fftsa.sg_update.
function fftsa.frame_body()
  -- Everything a frame touches must still exist. A frame can be dispatched while
  -- the app is half-built (a failed startup) or half-torn-down (End App, a host
  -- reload), and indexing a nil buffer or a nil peak-field table would raise on
  -- every tick, so bail out quietly instead.
  if fftsa.cap == nil or fftsa.sg_buf == nil or fftsa.sg_graph == nil
     or fftsa.sg_pk_f == nil then
    return
  end
  fftsa.cap.clear()
  dmm.digitize.read(fftsa.cap)
  -- Reject a short capture rather than transform it. fftsa.fft_load() would
  -- zero-pad the missing tail, and the step from real samples into zeros is
  -- broadband: the result is a convincing but completely FALSE spectrum. Holding
  -- the previous frame is honest; drawing a fabricated one is not.
  if fftsa.cap.n < fftsa.n then
    fftsa.shortreads = (fftsa.shortreads or 0) + 1
    return
  end
  fftsa.fft_load(fftsa.cap)
  fftsa.fft_run()
  -- Power, not magnitude: the untangle pass that unpacks the N/2 complex
  -- transform back to N/2 real bins produces |X|^2 for free, so taking the
  -- square root here would be 256 sqrt calls a frame thrown away immediately
  -- by the dB conversion, which is 10*log10 of power.
  fftsa.fft_power()
  local nb = fftsa.fft_m
  -- Search for peaks in exactly the window the graph plots, so the table always
  -- describes the visible trace instead of reporting off-screen tones.
  local kmin, kmax = fftsa.sg_window_bins(nb, fftsa.binhz)
  local bi, bv = fftsa.find_peaks(nb, fftsa.sg_npeak, kmin, kmax)
  fftsa.sg_update(nb, fftsa.binhz)
  fftsa.sg_show_peaks(bi, bv, fftsa.sg_npeak, fftsa.binhz)
end

-- Reentrancy-guarded frame. The body runs under pcall so an error can never skip
-- the fftsa.busy reset: were the guard left latched, every later frame would return
-- at the top and the display would freeze. A failed frame is simply dropped, and
-- fftsa.lasterr / fftsa.errcount record it for diagnosis.
--
-- The pcall does not cover being killed from OUTSIDE. Observed 2026-10-23: a
-- host sent ABORT (event 1409) while a frame was running, the frame never
-- reached the reset below, and from then on every frame returned at the top --
-- a frozen trace, and fftsa.stop() could never complete because it waits for
-- the frame to finish. The age check below is the way out of that: a guard held
-- longer than any real frame can take did not come from a frame that is still
-- running, so it is cleared and the drop is counted.
fftsa.busy_since = nil
fftsa.busy_max   = 2.0      -- seconds; a frame is ~0.08 s, so this is 25x slack
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
    -- fftsa.sg_update() detaches the trace before refilling and re-attaches it
    -- at the end, so an error raised in between leaves the graph with no trace
    -- at all -- which looks exactly like a dead signal. This is the net: a
    -- failed frame always ends with the trace attached.
    if fftsa.sg_graph ~= nil and fftsa.sg_buf ~= nil then
      pcall(function() fftsa.sg_rebind() end)
    end
    fftsa.lasterr  = tostring(err)
    fftsa.errcount = (fftsa.errcount or 0) + 1
    fftsa.errrun   = (fftsa.errrun or 0) + 1
    -- A trace that stopped updating looks exactly like a working analyser looking
    -- at a dead signal, so after a run of failures stop retrying and SAY so on
    -- screen. The timer keeps ticking into a no-op, which is cheaper and safer
    -- than deleting a timer from inside its own callback.
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

-- Delete the options form and clear EVERY handle into it. The fields are children
-- of the screen, so the firmware frees them with it, but the Lua handles would
-- otherwise dangle at deleted objects and a later fftsa.options() would poke them.
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

-- Build the OPTIONS form: a screen of editable fields the user touches to edit,
-- plus Apply / Cancel. Created once, hidden until the Options button is pressed.
function fftsa.build_options()
  -- Destroy first, ALWAYS: a second create would overwrite fftsa.optscr and leave
  -- the first screen alive in the firmware with nothing able to reach it.
  fftsa.destroy_options()

  local create = display.create
  -- Screen title must be <= 31 chars or the firmware truncates it (error 1707).
  fftsa.optscr = create(display.ROOT, display.OBJ_SCREEN, "FFT ANALYSER OPTIONS")

  create(fftsa.optscr, display.OBJ_TEXT, 30, 62,
         "Touch a field to edit it, then Apply.", 11579568, display.FONT_MEDIUM,   -- 0xB0B0B0
         display.JUST_LEFT)

  -- Edit objects render their label+description to the LEFT of the value box, so
  -- the box x must leave room for them; at x=270 the labels sit fully on-screen.
  -- Descriptions are kept short so they don't overrun the left edge.
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
                        56575, display.FONT_SMALL, display.JUST_LEFT)   -- 0x00DCFF

  local b_apply = create(fftsa.optscr, display.OBJ_BUTTON, 470, 362, "Apply", 140)
  display.setevent(b_apply, display.EVENT_PRESS, "if fftsa ~= nil then fftsa.options_apply() end")
  local b_cancel = create(fftsa.optscr, display.OBJ_BUTTON, 630, 362, "Cancel", 140)
  display.setevent(b_cancel, display.EVENT_PRESS, "if fftsa ~= nil then fftsa.options_cancel() end")
  -- Hook End App on THIS screen too. If the firmware delivers EVENT_ENDAPP to the
  -- screen that is currently visible, a user who exits from the options form would
  -- otherwise leave with no teardown at all -- both screens, the graph, the timer
  -- and both buffers stranded until the next power cycle.
  pcall(function()
    display.setevent(fftsa.optscr, display.EVENT_ENDAPP, "if fftsa ~= nil then fftsa.cleanup() end")
  end)
  return fftsa.optscr
end

-- Options button handler: seed the fields with the current settings, show a
-- read-back line, and switch to the form.
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

-- Apply the form: read every field, validate, then reconfigure and return.
function fftsa.options_apply()
  local lo = display.getvalue(fftsa.opt_flo)
  local hi = display.getvalue(fftsa.opt_fhi)
  local ri = display.getvalue(fftsa.opt_rng)
  -- Validate the span as a PAIR. Applying the two fields independently lets a new
  -- stop frequency land BELOW the surviving start (zoom to 8-16 kHz, then set stop
  -- to 5 kHz): the new start is rejected, the surviving one stays, and flo > fhi
  -- leaves an EMPTY window -- a span that describes no bins at all.
  local nlo, nhi = fftsa.flo, fftsa.fhi
  if hi ~= nil and hi > 0 then nhi = hi end
  if lo ~= nil and lo >= fftsa.flomin then nlo = lo end
  -- Inconsistent pair: widen back to the full span rather than leave an empty one.
  if nlo >= nhi then nlo = fftsa.flomin end
  fftsa.flo, fftsa.fhi = nlo, nhi
  if ri ~= nil then fftsa.range = fftsa.idx_to_range(ri) end
  display.changescreen(fftsa.sg_scr)
  fftsa.apply()
end

function fftsa.options_cancel()
  display.changescreen(fftsa.sg_scr)
end

-- Build the spectrum screen, add the Options button, and pre-build the form.
function fftsa.build()
  -- fftsa.sg_build() destroys any previous spectrum screen, its children and its
  -- buffer, and nils every handle, before creating the new one.
  fftsa.sg_build("FFT SPECTRUM ANALYSER", fftsa.n / 2)
  -- Options button: far bottom-right, clear of the right-hand peak column. The
  -- button is a child of the screen fftsa.sg_build() just destroyed, so clear the
  -- stale handle before creating its replacement.
  fftsa.optbtn = nil
  fftsa.optbtn = display.create(fftsa.sg_scr, display.OBJ_BUTTON, 645, 350, "Options", 145)
  display.setevent(fftsa.optbtn, display.EVENT_PRESS, "if fftsa ~= nil then fftsa.options() end")
  fftsa.build_options()
  -- Creating fftsa.optscr leaves it as the active screen, which would hide the
  -- spectrum and (since the frame timer only runs while its parent screen is
  -- visible) stop the display updating. Switch back to the spectrum explicitly.
  display.changescreen(fftsa.sg_scr)
  return fftsa.sg_scr
end

-- Arm the periodic frame timer (fires only while the spectrum screen is visible).
--
-- 0.3 s is deliberately conservative, and the reason is NOT Lua frame cost. A
-- frame's Lua work is about 81 ms (see fftsa.frame_body), so 0.05 s looks like
-- it should settle at ~12 Hz with the fftsa.busy guard dropping overlapping
-- ticks. The Lua side does reach 12.4 Hz, measured. The pacing is here because
-- what the frame rate drives is a STREAM into the display task, and nothing
-- measured so far bounds that: each frame clears the trace buffer and refills
-- it, and the display side is fed those readings by subscription, so 256 bins
-- at 12 Hz is some 3000 readings a second against about 850 at 0.3 s.
--
-- What is NOT established is that a short period is unsafe. A 0.05 s run on
-- 2026-10-23 drew a correct graph, posted event 1138, and ended on a blank
-- panel -- but the script driving it was killed mid-refill, which leaves the
-- graph hidden by itself (see fftsa.sg_update), and the panel came back from
-- the HOME key, which a crashed display processor would not. So that run
-- indicts the kill, not the period.
--
-- The period therefore stays at the value the pre-measurement code chose, as a
-- precaution rather than as a finding. Settling it means ramping the period
-- down while watching the event log for the queue-drop codes (2351, 1706)
-- rather than watching wall-clock frame rate, since the frame clock cannot see
-- the queue. If a frame runs long, the fftsa.busy guard skips the overlap.
function fftsa.arm(period_s)
  if period_s == nil then period_s = 0.1 end
  -- NEVER stack timers. Two live timers would both fire fftsa.frame(), doubling
  -- the frame rate, and that extra display traffic is exactly what floods the
  -- display processor and hangs the instrument.
  if fftsa.timer ~= nil then
    fftsa.del_obj(fftsa.timer)
    fftsa.timer = nil
  end
  if fftsa.sg_scr == nil then return nil end
  fftsa.timer = display.create(fftsa.sg_scr, display.OBJ_TIMER, period_s, display.TIMER_FOREVER)
  display.setevent(fftsa.timer, display.EVENT_PRESS, "if fftsa ~= nil and fftsa.frame ~= nil then fftsa.frame() end")
  return fftsa.timer
end

-- End App (the system button) fires EVENT_ENDAPP -> tear everything down so the
-- instrument is handed back clean.
function fftsa.cleanup()
  pcall(function() fftsa.stop() end)
end

-- Hook End App as soon as the spectrum screen exists, so that even a failure
-- later in startup leaves the user a working way out that cleans up.
-- pcall'd, because a wrong EVENT_ENDAPP constant must not abort startup -- but
-- the failure is RECORDED and reported: silently swallowing it would leave the
-- app with no teardown path and nothing to say so.
function fftsa.install_cleanup()
  if fftsa.sg_scr == nil then return false end
  local ok, err = pcall(function()
    display.setevent(fftsa.sg_scr, display.EVENT_ENDAPP, "if fftsa ~= nil then fftsa.cleanup() end")
  end)
  if not ok then fftsa.lasterr = "ENDAPP hook failed: " .. tostring(err) end
  return ok
end

-- One-call startup: build the screens, hook End App, apply settings, arm the
-- frame timer. Guarded end to end -- an unprotected failure part-way through
-- would abort the script with screens, a graph binding and buffers already
-- created and no teardown wired up, and those orphaned display objects then
-- survive until the next power cycle.
function fftsa.start()
  -- Reclaim anything a previous launch left behind, IN DEPENDENCY ORDER (timer,
  -- then screens, then buffers), before building. Installed as an App this is the
  -- normal case, not an edge case: opening the App re-runs the whole script, and
  -- if the last exit skipped EVENT_ENDAPP (HOME, another App) the handles from
  -- that launch are still here -- which is exactly why the declarations above no
  -- longer wipe them.
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
    -- Running as an installed App there is no console: a print goes nowhere the
    -- user can see, and stop() has just removed the half-built screen, so without
    -- this they are dropped back to HOME with no idea whether the App is broken
    -- or the installation is.
    fftsa.show_error(tostring(err))
    return false
  end
  if not hooked then
    print("fftsa WARNING: End App cleanup not hooked -- " .. tostring(fftsa.lasterr))
    -- Same reasoning: say it on the panel, since this one costs the user a power
    -- cycle's worth of stranded objects every time they leave the App.
    pcall(function()
      display.settext(fftsa.sg_xunit, "WARNING: End App will not clean up")
    end)
  end
  print("fftsa started fs=" .. fftsa.fs .. " bin=" .. fftsa.binhz .. " range=" .. fftsa.range)
  return true
end

-- Tear down everything (timer, screens, buffers) and clear every handle. Called
-- on app exit via EVENT_ENDAPP, from the host when reloading, and by
-- fftsa.start() itself if startup fails part-way through.
function fftsa.stop()
  -- Never tear down underneath a frame that is mid-flight: it would be left
  -- writing into a deleted buffer or a deleted graph. Defer ONCE -- frame() runs
  -- the pending stop the moment it finishes -- and then proceed regardless, so a
  -- guard stuck set can never make the app impossible to shut down.
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
  -- Leave no latched state behind for the next start().
  fftsa.busy, fftsa.halted, fftsa.errrun = false, false, 0
  return true
end

-- Report a startup failure ON THE PANEL. Uses only calls this app already relies
-- on elsewhere (screen + text + changescreen), rather than an untested modal
-- dialog, and keeps the handle so fftsa.stop() can delete it like anything else.
-- End App is hooked here too, so the user's way out still cleans up.
function fftsa.show_error(msg)
  pcall(function()
    if fftsa.errscr ~= nil then
      fftsa.del_obj(fftsa.errscr)
      fftsa.errscr = nil
    end
    fftsa.errscr = display.create(display.ROOT, display.OBJ_SCREEN, "FFT ANALYSER ERROR")
    display.create(fftsa.errscr, display.OBJ_TEXT, 20, 80,
                   "The analyser could not start.", 16736352,   -- 0xFF6060
                   display.FONT_MEDIUM, display.JUST_LEFT)
    -- One long line runs off an 800 px panel, so break the message into chunks.
    local m = tostring(msg)
    local y = 140
    local i = 1
    while i <= string.len(m) and y <= 400 do
      display.create(fftsa.errscr, display.OBJ_TEXT, 20, y, string.sub(m, i, i + 79),
                     14737632, display.FONT_SMALL, display.JUST_LEFT)   -- 0xE0E0E0
      i = i + 80
      y = y + 22
    end
    display.create(fftsa.errscr, display.OBJ_TEXT, 20, 420,
                   "Press End App to exit.", 9474192,   -- 0x909090
                   display.FONT_SMALL, display.JUST_LEFT)
    display.setevent(fftsa.errscr, display.EVENT_ENDAPP, "if fftsa ~= nil then fftsa.cleanup() end")
    display.changescreen(fftsa.errscr)
  end)
  return fftsa.errscr
end
