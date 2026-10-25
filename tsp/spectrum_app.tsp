-- spectrum_app.tsp -- interactive standalone spectrum analyser for the DMM6500
--
-- The touch options form and the on-instrument run loop, over fft_core.tsp (the
-- transform and the windows), spectrum_ui.tsp (the loading cover, fftsa.find_peaks)
-- and spectrum_graph.tsp (fftsa.sg_*). The stop frequency sets the sample rate
-- (smallest exact rate >= 2*stop, with a 100 kS/s floor),
-- the start frequency only windows the display, the input range is
-- dmm.digitize.range, and the window and its beta pick the analysis window.
--
-- Every screen, field and buffer is created once in fftsa.start(), behind the
-- loading cover, and deleted once by fftsa.stop(). A press only ever switches
-- screens: a create/delete cycle risks part of the 463-object pool for the rest of
-- the power cycle, because a refused display.delete raises nothing.

fftsa = fftsa or {}   -- the single global this app exposes

-- Every table, window and twiddle is sized from the selected power-of-two count.
-- 512 remains the default; larger records trade update speed for finer bins.
fftsa.n       = 512
fftsa.sample_counts = {512, 1024, 2048, 4096, 8192, 16384}
fftsa.sample_labels = {"512", "1024", "2048", "4096", "8192", "16384"}

-- Floor for the start frequency. A start of 0 would admit bin 1, which is DC and,
-- with the mean removed by fftsa.fft_load(), holds only window leakage.
fftsa.flomin  = 10          -- floor for the start frequency (Hz)
fftsa.flo     = 10          -- display start frequency (Hz)
fftsa.fhi     = 50000       -- display stop frequency (Hz)
-- Nyquist at the fastest rate, so this is the widest view the hardware can give.
-- The low end is not a hardware limit: zooming in does not change the bin width, so
-- 2 kHz is already down to about ten bins across the plot and narrower is a handful
-- of points.
fftsa.fhi_max = 500000
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
  fftsa.opt_n    = nil      -- FFT sample-count edit-option field
  fftsa.opt_info = nil      -- read-back info line on the options screen
  fftsa.handles_inited = true
end

-- SAMPLE RATE: THE SPAN MAY RAISE IT, NEVER LOWER IT BELOW THE FLOOR.
--
-- There is no anti-alias filter in front of the digitizer, so a rate whose Nyquist
-- falls below what is actually on the wire folds that content into the display as
-- peaks that are not there. Measured on the bench 2026-10-23: a pure 21.1 kHz sine,
-- shown over a 0 to 7 kHz span at 20 kS/s, drew one 4.5135 V peak at 1.100 kHz --
-- 21100 reduced mod 20000 -- amplitude right to four digits, with nothing on the
-- screen to say the frequency was not.
--
-- The direction is what matters. RAISING the rate can only remove aliases; lowering
-- it is what creates them. So zooming in never drops the rate: the span selects
-- which bins are drawn, and below the floor it stops affecting acquisition at all.
-- Widening the span past the floor's Nyquist does raise the rate, because showing
-- 200 kHz honestly requires sampling for it.
--
-- The floor is 100 kS/s, which gives 195.3 Hz bins at the default 512 samples.
-- Increasing the sample count makes bins finer. Raising the rate
-- coarsens the bins in proportion, which is the price of the wider view.
--
-- Content above the chosen Nyquist still folds. That is the missing filter, not the
-- rate, and no setting here removes it.
fftsa.fs_min = 100000
-- Exact, achievable rates only; the hardware cannot produce 102400 S/s.
fftsa.rates  = {100000, 200000, 500000, 1000000}

-- Smallest rate whose Nyquist covers the stop frequency, never below the floor.
function fftsa.pick_fs(fhi)
  local r = fftsa.rates
  local n = table.getn(r)
  for i = 1, n do
    if r[i] >= fftsa.fs_min and r[i] / 2 >= fhi then return r[i] end
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

-- Falls back rather than raising. A count off the list can only arrive from a host
-- assignment, and raising here took Options and Apply down together with no way back
-- but End App: both paths call this before they can show anything.
function fftsa.sample_to_idx(n)
  for i = 1, table.getn(fftsa.sample_counts) do
    if fftsa.sample_counts[i] == n then return i end
  end
  return 1
end

function fftsa.options_samples()
  local i = fftsa.opt_index(display.getvalue(fftsa.opt_n), fftsa.sample_labels,
                           fftsa.sample_to_idx(fftsa.n))
  return fftsa.sample_counts[i]
end

function fftsa.measure_fs(buf)
  local n = buf.n
  if n < 4 then return fftsa.fs end
  local t1, tN = buf.relativetimestamps[1], buf.relativetimestamps[n]
  if tN <= t1 then return fftsa.fs end
  return (n - 1) / (tN - t1)
end

-- Apply the current settings to the hardware and the graph. Safe to repeat: the
-- capture buffer is resized when needed; the graph keeps its original buffer.
-- fftsa.fft_init() rebuilds the window and its interpolation tables, which
-- is the slow part of a press -- about 0.3 s for Kaiser -- hence the cover.
function fftsa.apply()
  fftsa.fs = fftsa.pick_fs(fftsa.fhi)
  fftsa.fft_init(fftsa.n)
  -- Before the sg_set_xrange() below, which reads it: the legend reports how many
  -- bins land in the span, and nbins is half of that answer.
  fftsa.sg_nbins = fftsa.n / 2
  dmm.digitize.func       = dmm.FUNC_DIGITIZE_VOLTAGE
  dmm.digitize.range      = fftsa.range
  dmm.digitize.samplerate = fftsa.fs
  -- The bin width commits with the rate, not after the capture. A raise in between
  -- -- a trigger timeout is the obvious one -- used to leave the hardware at the new
  -- rate and fftsa.binhz at the old one, and a 12.5 kHz tone then read 2500.0 Hz
  -- with errcount 0. The measurement below refines this by about 0.01 %.
  fftsa.binhz = fftsa.fs / fftsa.n
  -- Same reason: the span is fftsa.flo/fhi, already committed by options_apply(),
  -- so pinning the axis to it never depended on the capture.
  fftsa.sg_set_xrange(fftsa.flo, fftsa.fhi)
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
  -- Large transforms outrun the 2 s default, so the guard follows the measured frame
  -- cost with margin rather than a multiple of the sample count.
  fftsa.busy_max = math.max(2.0, 3.0 * fftsa.frame_estimate(fftsa.n))
  -- A SMALL FIXED YIELD, because the frame no longer owns the display task's whole
  -- budget. It used to: work equalled the inter-frame interval at every count, so the
  -- only time the task got was this delay, and a fixed 25 ms meant 250 ms a second at
  -- 512 samples against 15 at 16384 -- the same constant, thirty times less time. It was
  -- scaled to a fifth of the frame for that reason.
  --
  -- The timer period now leaves 20 % of every frame idle, and Lua is blocked on the
  -- timer throughout that idle, so the task is scheduled there in proportion to the
  -- frame as well. Measured at 2048 samples: dropping the yield from 43 ms to 10 and
  -- then 5 raised idle from 46 % to 54 % and posted no 1706 at either, so the delay is
  -- no longer what feeds the task -- it is only insurance against a frame whose work
  -- happens to fill its whole period.
  fftsa.sg_yield = 0.010
  -- Re-armed here, not at startup: the period depends on the sample count, and this is
  -- the one place the count changes. The timer object is replaced, which is a create
  -- and a delete -- acceptable on a settings change, never in a frame.
  --
  -- This arm is from the model. frame() replaces it with one measured from real frames
  -- as soon as it has eight of them, so the peak is cleared here with the count.
  fftsa.work_peak, fftsa.work_seen = nil, 0
  if fftsa.timer ~= nil then
    fftsa.period = fftsa.frame_period(fftsa.n)
    fftsa.arm(fftsa.period)
  end
  fftsa.sg_pk_last, fftsa.sg_pk_lf, fftsa.sg_pk_lv = nil, {}, {}
  -- Again with the measured rate, which refines binhz and so the bin count the
  -- legend reports for a narrow span.
  fftsa.sg_set_xrange(fftsa.flo, fftsa.fhi)
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


-- Seconds one frame costs at a given sample count, from costs measured on the
-- instrument on 2026-10-24 (docs/PERFORMANCE.md): 10.9 us a sample to acquire, 32.0
-- to load and window, 3.593e-6 per butterfly-equivalent for the transform and its
-- power, 3.7 us a sample for the peak search, and a fill now capped by sg_maxpts.
-- Predicts 0.080 s at 512 against 81.8 ms measured, and 3.33 s at 32768.
--
-- busy_max exists to break a guard a host abort left set, and until it expires the
-- app looks dead -- so it has to clear a legitimate frame and not much more. Scaling
-- it as 2.0 * n/512 gave 128 s at 32768 against a real frame of 3.3.
function fftsa.frame_estimate(n)
  if n == nil or n < 2 then n = 512 end
  local log2n = math.log(n) / 0.69314718055995
  return n * 46.6e-6 + 3.593e-6 * n * log2n + 0.04
end
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
  -- Timed, because the timer period is set from what a frame actually costs.
  local entry = os.clock()
  local ok, err = pcall(fftsa.frame_body)
  fftsa.frame_work = os.clock() - entry
  -- RE-ARM FROM MEASURED WORK. frame_estimate() is a model fitted at one point count and
  -- one draw path, and it was setting the frame rate on its own: at 512 it predicted
  -- 80.4 ms, which divided by the 0.8 occupancy is 100.5 ms -- half a millisecond past
  -- the 0.10 s tick, so the period came out 0.15 and the rate 6.7 fps where the frame
  -- needed 0.10 and 10. At 2048 it errs the other way, 216 ms against 240 measured.
  --
  -- The peak over a window of frames, not the mean: the period has to cover the slowest
  -- frame or ticks are dropped and the rate halves. It is only ever raised by a whole
  -- tick and only re-armed when the tick count actually changes, so a frame that runs
  -- long once does not re-arm the timer every frame afterwards.
  if ok then
    if fftsa.work_peak == nil or fftsa.frame_work > fftsa.work_peak then
      fftsa.work_peak = fftsa.frame_work
    end
    fftsa.work_seen = (fftsa.work_seen or 0) + 1
    if fftsa.work_seen >= 8 and fftsa.timer ~= nil then
      local want = fftsa.tick_period(fftsa.work_peak)
      if want ~= fftsa.period then
        fftsa.period = want
        fftsa.arm(want)
      end
      -- Decay the peak so a size change downwards is noticed: it is re-earned over the
      -- next window rather than remembered for the life of the app.
      fftsa.work_peak = fftsa.frame_work
      fftsa.work_seen = 0
    end
  end
  if not ok then
    -- Re-bind the trace after a failure so the graph is never left without one, and only
    -- while the bound buffer still holds points: adding over an empty one binds nothing
    -- and never draws again.
    --
    -- The guard is cheap insurance rather than a live case now. sg_update() clears and
    -- fills the SPARE, so a raise in there leaves the bound buffer whole and still
    -- bound, and the only buffer that can be left part filled is one nothing draws
    -- from -- the next frame clears it before writing anyway.
    if fftsa.sg_graph ~= nil and fftsa.sg_buf ~= nil and fftsa.sg_buf.n > 0 then
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
  fftsa.opt_win, fftsa.opt_beta, fftsa.opt_n = nil, nil, nil
  fftsa.opt_info_last = nil
end

-- Form geometry, two columns like the decode app's: six fields become three rows,
-- and the gap that buys is what makes each box a touch target. display.create takes
-- no width for an OBJ_EDIT_*, so the second column's x is the one number to check on
-- the glass. Labels are right-aligned and end at the column x.
fftsa.opt_nf      = 6
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
fftsa.opt_info_y  = 323

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
  -- create on a visible screen, and this one is inert for the other three windows.
  local x5, y5 = nextpos()
  fftsa.opt_beta = create(fftsa.optscr, display.OBJ_EDIT_OPTION, x5, y5,
                       "Kaiser Beta", "sidelobe level",
                       fftsa.kbeta_labels[1], fftsa.kbeta_labels[2], fftsa.kbeta_labels[3],
                       fftsa.kbeta_labels[4], fftsa.kbeta_labels[5], fftsa.kbeta_labels[6])
  local x6, y6 = nextpos()
  fftsa.opt_n = create(fftsa.optscr, display.OBJ_EDIT_OPTION, x6, y6,
                       "FFT Samples", "resolution vs speed",
                       fftsa.sample_labels[1], fftsa.sample_labels[2], fftsa.sample_labels[3],
                       fftsa.sample_labels[4], fftsa.sample_labels[5], fftsa.sample_labels[6])

  fftsa.opt_info = create(fftsa.optscr, display.OBJ_TEXT, 400, fftsa.opt_info_y, "",
                        56575, display.FONT_SMALL, display.JUST_CENTER)   -- cyan 00DCFF
  -- A timer on the options screen previews edits without configuring acquisition.
  local preview = create(fftsa.optscr, display.OBJ_TIMER, 0.2, display.TIMER_FOREVER)
  display.setevent(preview, display.EVENT_PRESS,
                  "if fftsa ~= nil then fftsa.guard(fftsa.options_preview) end")

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

function fftsa.sample_rate_text(fs)
  if fs >= 1000000 then return string.format("%g MS/s", fs / 1000000) end
  if fs >= 1000 then return string.format("%g kS/s", fs / 1000) end
  return string.format("%g S/s", fs)
end

-- Acquisition duration is N/fs, not the first-to-last timestamp interval (N-1)/fs.
function fftsa.opt_info_text(fs, n, wi, bi)
  fs, n = fs or fftsa.fs, n or fftsa.n
  return string.format("fs %s   bin %.2f Hz   acq %.2f ms   %s",
                       fftsa.sample_rate_text(fs), fs / n, 1000 * n / fs,
                       fftsa.win_label(wi, bi))
end

function fftsa.options_preview()
  local lo, hi = fftsa.options_span()
  local fs = fftsa.pick_fs(hi)
  -- Reuse the timestamp-measured rate when previewing the active acquisition rate.
  if fs == fftsa.pick_fs(fftsa.fhi) then fs = fftsa.fs end
  -- The window comes from the fields too, or three quarters of the line would track
  -- the edit and the fourth would silently show the applied window.
  local wi = fftsa.opt_index(display.getvalue(fftsa.opt_win), fftsa.win_names, fftsa.win_i)
  local bi = fftsa.opt_index(display.getvalue(fftsa.opt_beta), fftsa.kbeta_labels,
                             fftsa.kbeta_i)
  local text = fftsa.opt_info_text(fs, fftsa.options_samples(), wi, bi)
  if text ~= fftsa.opt_info_last then
    display.settext(fftsa.opt_info, text)
    fftsa.opt_info_last = text
  end
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
  pcall(function() display.setvalue(fftsa.opt_n, fftsa.sample_to_idx(fftsa.n)) end)
  -- Guarded like its neighbours: four getvalue/settext calls on handles the pool may
  -- have refused, and changescreen is the next line. Unguarded, a refusal at the end
  -- of the create list leaves the Options button dead for the life of the app.
  pcall(function() fftsa.options_preview() end)
  display.changescreen(fftsa.optscr)
  return true
end

function fftsa.options_span()
  local lo = display.getvalue(fftsa.opt_flo)
  local hi = display.getvalue(fftsa.opt_fhi)
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
  return nlo, nhi
end

function fftsa.options_apply()
  -- Every field is read before anything is committed: a raise in here leaves the
  -- applied state untouched, where a raise after the first commit would leave the
  -- span changed with the axis, the cover and the message all still describing the
  -- old one -- and say() writes the spectrum screen, which is not on show yet.
  local ri = display.getvalue(fftsa.opt_rng)
  local wi = display.getvalue(fftsa.opt_win)
  local bi = display.getvalue(fftsa.opt_beta)
  local nnew = fftsa.options_samples()
  local nlo, nhi = fftsa.options_span()
  fftsa.flo, fftsa.fhi = nlo, nhi
  local nold    = fftsa.n
  fftsa.n       = nnew
  fftsa.range   = fftsa.idx_to_range(ri)
  fftsa.win_i   = fftsa.opt_index(wi, fftsa.win_names, fftsa.win_i)
  fftsa.kbeta_i = fftsa.opt_index(bi, fftsa.kbeta_labels, fftsa.kbeta_i)
  -- Under the cover: fftsa.apply() rebuilds the window tables and takes a capture,
  -- and the frame timer does not run while its screen is off show, so no frame can
  -- meet half-rebuilt tables.
  fftsa.loading_front()
  -- A failed resize must not resume frames with mismatched FFT and buffer sizes.
  -- An unchanged size cannot desync them, and halting there would freeze the trace
  -- on any failed capture -- a trigger timeout leaves binhz describing the rate in
  -- force, which is exactly the case the frames should keep running through.
  fftsa.halted = (fftsa.n ~= nold)
  local ok, err = pcall(function() fftsa.apply() end)
  fftsa.show_main()
  if not ok then
    fftsa.lasterr = tostring(err)
    fftsa.say("APPLY FAILED: " .. tostring(err))
  else
    fftsa.halted, fftsa.errrun = false, 0
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
  -- Two trace buffers at sg_maxpts, for the life of the app: allocated at the CEILING
  -- rather than at sg_ncol so the point count stays adjustable upwards while running
  -- without anything being resized or reallocated.
  fftsa.sg_build("FFT SPECTRUM ANALYSER", fftsa.n / 2, fftsa.sg_maxpts)
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
-- The period a frame needs, with interpreter idle left over.
--
-- delay() lets the display task PAINT -- that is C -- but dispatching a touch means
-- evaluating Lua, and the interpreter is inside the delay. So a press is only handled
-- in the gap between a frame finishing and the next tick, and with the period left at
-- the 0.05 s floor that gap is whatever the quantisation happens to leave: 45 ms of
-- 150 at 512 samples, and 12 ms of 500 at 4096, which made Options unreachable there
-- while 512 was fine. It was luck, not design.
--
-- Asking for the work to be 80 % of the period puts the idle at about 20 % at every
-- count.
--
-- frame_estimate() ALREADY INCLUDES THE YIELD. It was fitted against measured frame
-- times -- 0.080 s predicted against 81.8 ms measured at 512 -- and a measured frame is
-- the whole frame, delay() and all. Adding sg_yield to it again counted the yield twice
-- and pushed 512 from 105 ms of apparent busy to 131 ms after the 80 % divide, which is
-- past the 0.10 s tick: the period came out 0.15 and the rate 6.7 fps where the frame
-- itself only needed 0.10 and 10 fps. A tick of quantisation lost to double counting.
-- Seconds of timer period that leave a frame of this length about 20 % idle, rounded up
-- to the firmware's 0.05 s tick. The one place the occupancy rule lives, so the modelled
-- first arm and the measured re-arms cannot disagree about it.
--
-- The slack matters as much as the 0.8 does. A tick is 50 ms, so holding the occupancy
-- target to the last millisecond buys a fiftieth of a tick of idle and costs a WHOLE
-- tick of rate. Measured at 512 samples: the worst frame is 80.1 ms, which over 0.8 is
-- 100.1 ms -- a tenth of a millisecond past two ticks -- so it took three and the rate
-- was 6.67 fps where 10 was there for 80.1 % occupancy instead of 80.0.
--
-- A twentieth of a tick, 2.5 ms. It can only change the answer for a frame already
-- within 2.5 ms of a boundary, and there it prefers the rate.
function fftsa.tick_period(busy)
  if busy == nil or busy <= 0 then return 0.05 end
  local ticks = math.ceil((busy / 0.8) / 0.05 - 0.05)
  if ticks < 1 then ticks = 1 end
  return ticks * 0.05
end

-- The FIRST arm, before any frame has been timed. From here on frame() re-arms from the
-- work it actually measures.
function fftsa.frame_period(n)
  return fftsa.tick_period(fftsa.frame_estimate(n))
end

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
    -- With the computed period, not the 0.05 s floor: apply() re-arms on a size change
    -- but cannot do it here, because the timer is created after the first apply() runs.
    -- Left at the floor, the default size kept whatever idle the quantisation happened
    -- to leave -- which is the whole fault this period exists to remove.
    fftsa.period = fftsa.frame_period(fftsa.n)
    fftsa.arm(fftsa.period)
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
-- The commonest reason startup fails is an exhausted object pool, and then
-- display.create returns nil here too: without the guard below every child is built
-- against a nil parent and changescreen(nil) raises, so the operator gets a BLANK
-- PANEL in precisely the case this screen exists for. Nothing can be drawn with at
-- that point, so it says so on the console and leaves the home screen up.
--
-- These children are created on a visible screen, which nothing else in the app
-- does. Accepted: it runs once, after startup has already failed, and the cover is
-- gone by then because fftsa.stop() took it.
function fftsa.show_error(msg)
  local shown = pcall(function()
    if fftsa.errscr ~= nil then
      fftsa.del_obj(fftsa.errscr)
      fftsa.errscr = nil
    end
    fftsa.errscr = display.create(display.ROOT, display.OBJ_SCREEN, "FFT ANALYSER ERROR")
    if fftsa.errscr == nil then
      error("object pool exhausted; no error screen", 0)
    end
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
  if not shown or fftsa.errscr == nil then
    fftsa.errscr = nil
    pcall(function() display.changescreen(display.SCREEN_HOME) end)
    print("fftsa: could not build the error screen either -- " .. tostring(msg))
  end
  return fftsa.errscr
end
