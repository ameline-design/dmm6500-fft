-- spectrum_app.tsp -- interactive standalone spectrum analyser for the DMM6500
--
-- The touch options form and the run loop, over fft_core.tsp, spectrum_ui.tsp and
-- spectrum_graph.tsp. The stop frequency sets the sample rate -- smallest exact rate at
-- or above 2x stop, with a 100 kS/s floor -- and the start frequency only windows the
-- display.
--
-- Every screen and field is created once in start(), behind the loading cover, and
-- deleted once by stop(); a press only ever switches screens. A create/delete cycle
-- risks part of the 463-object pool for the rest of the power cycle, because a refused
-- display.delete raises nothing. The capture buffer and the frame timer are the
-- exceptions.

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
  fftsa.optbtn   = nil      -- Options (cog) button on the spectrum screen
  fftsa.optimg   = nil      -- cog image drawn over it
  fftsa.lockbtn  = nil      -- Lock button beside it
  fftsa.lockimg_c = nil     -- closed-padlock image over the Lock button
  fftsa.lockimg_o = nil     -- open-padlock image over it; one of the pair is visible
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

-- The span may raise the sample rate, never lower it below the floor.
--
-- There is no anti-alias filter in front of the digitizer, so a rate whose Nyquist falls
-- below what is on the wire folds that content in as peaks that are not there, at full
-- amplitude and with nothing on the glass to say so. Raising the rate can only remove
-- aliases; lowering it creates them. So zooming in never drops the rate -- the span only
-- selects which bins are drawn -- while widening past the floor's Nyquist does raise it.
--
-- The floor is 100 kS/s, 195.3 Hz bins at the default 512 samples. A higher rate coarsens
-- the bins in proportion, which is the price of the wider view.
-- Band-pass, off by default: low-pass the capture at the stop frequency and decimate to
-- match, so the bin becomes fs/(D*N) and a narrow span reaches a resolution that would
-- otherwise need a transform D times longer. The filter is what makes the decimation
-- safe. It cannot undo folding that already happened at the ADC.
fftsa.bp_on = false

fftsa.fs_min = 100000
-- Exact, achievable rates only; the hardware cannot produce 102400 S/s.
fftsa.rates  = {100000, 200000, 500000, 1000000}

-- One rate up, which is what the band-pass is given: sampling faster raises the Nyquist
-- so the filter can remove a band that would otherwise already be folded into the record.
-- The next rate in fftsa.rates rather than literally twice, because the hardware has
-- 100k, 200k, 500k and 1M and nothing between.
--
-- The cost is read budget: the bin is fs_acq/M, so holding resolution means doubling M
-- with the rate, and where bp_maxm caps the decimation the bin comes out coarser instead.
function fftsa.bp_rate(fs)
  local r = fftsa.rates
  local n = table.getn(r)
  local i
  for i = 1, n do
    if r[i] > fs then return r[i] end
  end
  return r[n]
end

-- Rate and decimation chosen together, by the bin width they produce: stepping the rate
-- up gains only where the decimation can absorb it. At a 50 kHz span the decimation is 1
-- either way and stepping up doubles the bin for nothing, 390.63 Hz against 195.31. The
-- finer bin wins; on a tie the higher rate does, its Nyquist being further from the span.
function fftsa.bp_plan(fhi, n)
  local base = fftsa.pick_fs(fhi)
  -- ONE STEP UP AT MOST. Searching every rate the hardware has finds a plan for a 50 kHz
  -- span -- 500 kS/s at /3 -- but 51 taps over 512 outputs is around 135 ms of
  -- multiply-accumulate, and the frame goes from 0.08 s to a quarter of a second for a
  -- bin COARSER than the unfiltered one. Not worth it: at a span that wide the filter is
  -- left out and the line says so.
  local cand = {base, fftsa.bp_rate(base)}
  local bestfs, bestd = nil, nil
  local i
  for i = 1, 2 do
    local fs = cand[i]
    if fs >= base then
      local d = fftsa.bp_pick_d(fs, fhi, n)
      -- A decimation of 1 is the filter bypassed, so only plans that can actually run
      -- are candidates; among those the finest bin wins.
      if d > 1 and (bestfs == nil or (fs / d) < (bestfs / bestd)) then
        bestfs, bestd = fs, d
      end
    end
  end
  -- Neither rate could decimate: run at the rate the span needs and leave the filter out.
  if bestfs == nil then return base, 1 end
  return bestfs, bestd
end

-- Smallest rate whose Nyquist covers the stop frequency, never below the floor.
function fftsa.pick_fs(fhi)
  local r = fftsa.rates
  local n = table.getn(r)
  for i = 1, n do
    if r[i] >= fftsa.fs_min and r[i] / 2 >= fhi then return r[i] end
  end
  return r[n]
end

-- Boolean fields are an EDIT_OPTION of two, matching the other fields on the form rather
-- than using display.OBJ_EDIT_CHECK. Index 1 is off, so a field the pool refused reads as
-- off through fftsa.getval's fallback.
fftsa.onoff_labels = {"Off", "On"}

function fftsa.onoff_to_idx(v)
  if v then return 2 end
  return 1
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
  local i = fftsa.opt_index(fftsa.getval(fftsa.opt_n), fftsa.sample_labels,
                           fftsa.sample_to_idx(fftsa.n))
  return fftsa.sample_counts[i]
end

-- The DIGITIZER's rate, from the capture's own timestamps. The fallback is fs_acq, not
-- fftsa.fs: fftsa.fs is the decimated rate and returning it here would divide it twice.
function fftsa.measure_fs(buf)
  local back = fftsa.fs_acq or fftsa.fs
  local n = buf.n
  if n < 4 then return back end
  local t1, tN = buf.relativetimestamps[1], buf.relativetimestamps[n]
  if tN <= t1 then return back end
  return (n - 1) / (tN - t1)
end

-- Apply the current settings to the hardware and the graph. Safe to repeat: the
-- capture buffer is resized when needed; the graph keeps its original buffer.
-- fftsa.fft_init() rebuilds the window and its interpolation tables, which
-- is the slow part of a press -- about 0.3 s for Kaiser -- hence the cover.
function fftsa.apply()
  -- TWO RATES from here on. fs_acq is what the digitizer runs at; fftsa.fs is what the
  -- transform sees, which is fs_acq/bp_d once the band-pass is decimating. Everything
  -- downstream reads fftsa.fs -- binhz, the settings line, the span arithmetic -- so the
  -- decimation is invisible to it, which is the point.
  fftsa.fs_acq = fftsa.pick_fs(fftsa.fhi)
  local d = 1
  if fftsa.bp_on then
    fftsa.fs_acq, d = fftsa.bp_plan(fftsa.fhi, fftsa.n)
  end
  fftsa.bp_build(fftsa.fs_acq, fftsa.fhi, fftsa.n, d)
  local need = fftsa.bp_m
  fftsa.fs = fftsa.fs_acq / fftsa.bp_d
  fftsa.fft_init(fftsa.n)
  -- Before the sg_set_xrange() below, which reads it: the settings line counts the bins
  -- inside the span, and that count is computed from sg_nbins.
  fftsa.sg_nbins = fftsa.n / 2
  dmm.digitize.func       = dmm.FUNC_DIGITIZE_VOLTAGE
  dmm.digitize.range      = fftsa.range
  dmm.digitize.samplerate = fftsa.fs_acq
  -- The bin width commits with the rate, not after the capture: a capture that fails
  -- between the two -- a trigger timeout is the obvious one -- would otherwise leave the
  -- hardware at the new rate and fftsa.binhz at the old one. The measurement below
  -- refines it by about 0.01 %.
  fftsa.binhz = fftsa.fs / fftsa.n
  -- The span is fftsa.flo/fhi, committed by options_apply(), so the axis is pinned before
  -- the capture rather than after it.
  fftsa.sg_set_xrange(fftsa.flo, fftsa.fhi)
  dmm.digitize.aperture   = 1e-6
  -- The capture is bp_m long, which is fftsa.n unless the filter is decimating.
  dmm.digitize.count      = need
  if fftsa.cap ~= nil and fftsa.cap_n ~= need then
    fftsa.del_buf(fftsa.cap)
    fftsa.cap = nil
  end
  if fftsa.cap == nil then
    fftsa.cap   = buffer.make(need * 4, buffer.STYLE_STANDARD)
    fftsa.cap_n = need
  end
  fftsa.cap.clear()
  dmm.digitize.read(fftsa.cap)
  -- Measured from the timestamps, which are the DIGITIZER's: the readback is unreliable,
  -- and the decimation is arithmetic afterwards, so it divides the measured rate.
  fftsa.fs_acq = fftsa.measure_fs(fftsa.cap)
  fftsa.fs     = fftsa.fs_acq / fftsa.bp_d
  fftsa.binhz  = fftsa.fs / fftsa.n
  -- Large transforms outrun the 2 s default, so the guard follows the measured frame
  -- cost with margin rather than a multiple of the sample count.
  fftsa.busy_max = math.max(2.0, 3.0 * fftsa.frame_estimate(fftsa.n))
  -- Re-armed here because the period depends on the sample count and this is where the
  -- count changes. From the model; frame() replaces it with one measured from real frames
  -- once it has eight, so the peak is cleared here with the count.
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
  -- The length needed is bp_m, which is fftsa.n unless the filter is decimating -- and
  -- the filter's inner loop has no nil test, so this is what makes that safe.
  if fftsa.cap.n < fftsa.bp_m then
    fftsa.shortreads = (fftsa.shortreads or 0) + 1
    return
  end
  if fftsa.bp_d > 1 then
    fftsa.fft_load_rd(fftsa.bp_filter(fftsa.cap.readings))
  else
    fftsa.fft_load(fftsa.cap)
  end
  fftsa.fft_run()
  fftsa.fft_power()
  local nb = fftsa.fft_m
  -- Peaks are searched in the window the graph plots, so the table matches the trace.
  local kmin, kmax = fftsa.sg_window_bins(nb, fftsa.binhz)
  local bi, bv = fftsa.find_peaks(nb, fftsa.sg_npeak, kmin, kmax)
  -- Before the spectrum refill, so the yield at the end of that refill is the first
  -- paint either buffer sees after both are complete.
  fftsa.sg_update_markers(bi, bv, fftsa.sg_npeak, fftsa.binhz)
  fftsa.sg_update(nb, fftsa.binhz)
  fftsa.sg_show_peaks(bi, bv, fftsa.sg_npeak, fftsa.binhz)
end

-- Reentrancy-guarded frame. The body runs under pcall so an error cannot leave
-- fftsa.busy set, which would make every later frame return at the top. A host
-- abort (event 1409) mid-frame is not covered by the pcall and does leave it set,
-- so a guard held longer than fftsa.busy_max is broken and the break counted.
fftsa.busy_since = nil
fftsa.busy_max   = 2.0      -- seconds a guard may be held before it is judged stuck


-- Seconds one frame costs at a given sample count, from per-phase costs in
-- docs/PERFORMANCE.md. Predicts 0.080 s at 512 against 0.079 measured, 1.63 s at 16384
-- against 1.686.
--
-- busy_max breaks a guard a host abort left set, and the app looks dead until it expires,
-- so it has to clear a legitimate frame and not much more. Three times the model does
-- that at every count; a multiple of the sample count does not.
function fftsa.frame_estimate(n)
  if n == nil or n < 2 then n = 512 end
  local log2n = math.log(n) / 0.69314718055995
  local est = n * 46.6e-6 + 3.593e-6 * n * log2n + 0.04
  -- The band-pass adds the reads it does not share with the plain path and one
  -- multiply-accumulate per tap per output. Derived from the documented per-operation
  -- costs -- 22 us a buffer reading, and two table reads plus a multiply and an add at
  -- 1.4 and 1.2 us -- not measured on this loop, so it is a starting point: frame()
  -- replaces the period with one measured from real frames after eight of them.
  if fftsa.bp_d ~= nil and fftsa.bp_d > 1 then
    est = est + (fftsa.bp_m - n) * 22e-6 + n * fftsa.bp_l * 5.2e-6
  end
  return est
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
  -- Re-arm from measured work: frame_estimate() is a model, and divided by the occupancy
  -- target an error of a few ms lands either side of a tick boundary, which is a 50 %
  -- swing in displayed rate.
  --
  -- The peak over a window of frames, not the mean, because the period has to cover the
  -- slowest frame or ticks drop and the rate halves. Raised only by a whole tick and
  -- re-armed only when the tick count changes, so one long frame does not re-arm
  -- every frame after it.
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
    if fftsa.sg_graph ~= nil and fftsa.sg_buf ~= nil and fftsa.sg_buf.n > 0 then
      fftsa.sg_rebind()
    end
    fftsa.lasterr  = tostring(err)
    fftsa.errcount = (fftsa.errcount or 0) + 1
    fftsa.errrun   = (fftsa.errrun or 0) + 1
    -- After a run of failures stop retrying and say so on screen: a trace that
    -- stopped updating looks like a working analyser on a dead signal.
    if fftsa.errrun >= (fftsa.errmax or 20) then
      fftsa.halted = true
      display.settext(fftsa.sg_xunit,
        "HALTED after " .. fftsa.errrun .. " failed frames: " ..
        string.sub(tostring(fftsa.lasterr), 1, 60))
    end
  else
    fftsa.errrun = 0
  end
  fftsa.busy = false
  -- A teardown that arrived mid-frame waits here, where nothing is in flight.
  if fftsa.stop_pending then
    fftsa.stop_pending = false
    fftsa.stop()
  end
end

-- The firmware frees the fields with their screen; the Lua handles still need clearing.
function fftsa.destroy_options()
  if fftsa.optscr ~= nil then
    -- Never delete the screen currently on show: leave it first.
    fftsa.show_main()
    fftsa.del_obj(fftsa.optscr)
  end
  fftsa.optscr, fftsa.opt_flo, fftsa.opt_fhi, fftsa.opt_rng, fftsa.opt_info =
    nil, nil, nil, nil, nil
  fftsa.opt_win, fftsa.opt_beta, fftsa.opt_n = nil, nil, nil
  fftsa.opt_mk, fftsa.opt_bp = nil, nil
  fftsa.opt_info_last = nil
end

-- Form geometry, two columns like the decode app's: six fields become three rows,
-- and the gap that buys is what makes each box a touch target. display.create takes
-- no width for an OBJ_EDIT_*, so the second column's x is the one number to check on
-- the glass. Labels are right-aligned and end at the column x.
-- Six: Peak Markers and Band-Pass are both withheld. See fftsa.opt_mk and fftsa.opt_bp.
fftsa.opt_nf      = 6
fftsa.opt_cols    = 2
fftsa.opt_x       = 185
fftsa.opt_x_c2    = 552
fftsa.opt_y0      = 8
fftsa.opt_dy      = 100     -- preferred pitch; clamped to what fits
fftsa.opt_edit_h  = 50      -- box height, measured
fftsa.opt_edit_dy = 4       -- offset of the box inside the object
fftsa.opt_y_adj   = 0       -- nudge of the centred block, negative being up
fftsa.opt_btn_y   = 360
fftsa.opt_info_y  = 323     -- readback line BASELINE; an OBJ_TEXT y is its baseline
fftsa.opt_info_h  = 20      -- its height above that baseline, so the fields clear it

-- Rows, pitch and top for the field block. The pitch is the preferred one, clamped if a
-- field count ever needs it: the last box has to end above the button row. At the six
-- fields the form carries, three rows at the preferred 100 leave the clamp inert.
function fftsa.opt_layout()
  local nrows = math.ceil(fftsa.opt_nf / fftsa.opt_cols)
  local eh, edy = fftsa.opt_edit_h, fftsa.opt_edit_dy
  local y0, dy  = fftsa.opt_y0, fftsa.opt_dy
  -- The last box has to end above the READBACK LINE, which sits above the buttons: at
  -- seven fields the button row alone leaves the bottom box over the top of it.
  local floor_y = fftsa.opt_info_y - fftsa.opt_info_h
  if nrows > 1 then
    local maxdy = math.floor((floor_y - y0 - edy - eh) / (nrows - 1))
    if dy > maxdy then dy = maxdy end
  end
  -- Centred, because three rows do not fill the form, then nudged. Only ever down,
  -- and only by what is spare; the nudge is separate from y0 because the centring
  -- divides the leftover space and would give back half of a move asked for there.
  local spare = floor_y - ((nrows - 1) * dy + eh + edy) - y0
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
    fftsa.lasterr = "display object pool exhausted building the options screen -- "
                    .. "power cycle the instrument."
    return false, fftsa.lasterr
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
  -- Spelled out rather than built from the table: display.create takes the options as
  -- separate arguments and Lua 5.0.2 has no unpack() worth using here.
  --
  -- Band-pass is not offered, so fftsa.opt_bp stays nil and the read falls back to
  -- fftsa.bp_on, leaving it settable over the socket. It is flat to 0.02 dB across the
  -- span with 61 dB of rejection, and not worth the frame: 51 taps over 512 outputs takes
  -- the frame from 0.08 s to about a quarter of a second for nothing an operator can
  -- see, and from 4096 samples up the read budget leaves no room for it at all.
  local x5, y5 = nextpos()
  fftsa.opt_win = create(fftsa.optscr, display.OBJ_EDIT_OPTION, x5, y5,
                       "Window", "lobe vs sidelobe",
                       fftsa.win_names[1], fftsa.win_names[2], fftsa.win_names[3],
                       fftsa.win_names[4])
  -- Always built, not only when Kaiser is selected: a field created on a press is a
  -- create on a visible screen, and this one is inert for the other three windows.
  local x6, y6 = nextpos()
  fftsa.opt_beta = create(fftsa.optscr, display.OBJ_EDIT_OPTION, x6, y6,
                       "Kaiser Beta", "sidelobe level",
                       fftsa.kbeta_labels[1], fftsa.kbeta_labels[2], fftsa.kbeta_labels[3],
                       fftsa.kbeta_labels[4], fftsa.kbeta_labels[5], fftsa.kbeta_labels[6])
  local x7, y7 = nextpos()
  fftsa.opt_n = create(fftsa.optscr, display.OBJ_EDIT_OPTION, x7, y7,
                       "FFT Samples", "resolution vs speed",
                       fftsa.sample_labels[1], fftsa.sample_labels[2], fftsa.sample_labels[3],
                       fftsa.sample_labels[4], fftsa.sample_labels[5], fftsa.sample_labels[6])
  -- Peak markers is not offered, so the eighth field is not created and fftsa.opt_mk
  -- stays nil; getval answers the fallback for a nil handle, so apply sees "off".
  --
  -- What is missing is the second trace's scaling: the firmware does not honour a pin
  -- applied with that trace selected, so its six points auto-scale across the plot and
  -- land nowhere near the spectrum. The buffer, the refill and the binding are in place.

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
  local b_about = create(fftsa.optscr, display.OBJ_BUTTON, 8, fftsa.opt_btn_y, "About", 140)
  display.setevent(b_about, display.EVENT_PRESS, "if fftsa ~= nil then fftsa.guard(fftsa.about) end")
  -- End App is hooked on this screen too: the firmware may deliver EVENT_ENDAPP to
  -- the visible screen, and leaving from the form must still tear down.
  display.setevent(fftsa.optscr, display.EVENT_ENDAPP,
                   "if fftsa ~= nil then fftsa.cleanup() end")
  return fftsa.optscr
end

-- ==================== About ====================
-- An OBJ_TEXT y is the text's BASELINE, not the top of its box, which is why these sit
-- lower than a button's y for the same apparent position.
fftsa.about_x        = 12
fftsa.about_title_x  = 400        -- centred, so the x is the screen's middle
fftsa.about_title_y  = 30
fftsa.about_body_y   = 70
-- FONT_1's line pitch, measured on the panel: the numbered fonts are in the firmware's
-- registration table but not in the display API reference, and FONT_1 draws about 17 px
-- tall. Eleven rows at this pitch end clear of the button row at opt_btn_y.
fftsa.about_body_dy  = 20
-- Rows a page. 14 splits the licence after the blank line that follows the copyright
-- notice, so the first page carries everything up to it and the second starts flush with
-- the warranty block instead of with a blank row.
fftsa.about_rows     = 14
fftsa.about_page     = 1
fftsa.about_c_title  = 56575      -- cyan 00DCFF
fftsa.about_c_body   = 16777215   -- white

-- The licence, verbatim from LICENSE and wrapped there: OBJ_TEXT does not wrap, so one
-- line is one row, and a blank line is a row of its own.
fftsa.about_text = {
  "MIT License",
  "",
  "Copyright (c) 2026 Ian Ameline",
  "",
  "Permission is hereby granted, free of charge, to any person obtaining a copy",
  'of this software and associated documentation files (the "Software"), to deal',
  "in the Software without restriction, including without limitation the rights",
  "to use, copy, modify, merge, publish, distribute, sublicense, and/or sell",
  "copies of the Software, and to permit persons to whom the Software is",
  "furnished to do so, subject to the following conditions:",
  "",
  "The above copyright notice and this permission notice shall be included in",
  "all copies or substantial portions of the Software.",
  "",
  'THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR',
  "IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,",
  "FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE",
  "AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER",
  "LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,",
  "OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE",
  "SOFTWARE.",
}

function fftsa.destroy_about()
  if fftsa.aboutscr ~= nil then
    -- Never delete the screen currently on show: leave it first.
    fftsa.show_main()
    fftsa.del_obj(fftsa.aboutscr)
  end
  fftsa.aboutscr, fftsa.about_name, fftsa.about_lines = nil, nil, nil
  fftsa.about_pageno, fftsa.about_page = nil, 1
end

function fftsa.about_pages()
  local rows = fftsa.about_rows
  return math.ceil(table.getn(fftsa.about_text) / rows)
end

-- Page p into the row objects, which are made once and rewritten. A row past the end of
-- the licence is blanked rather than left holding the previous page.
function fftsa.about_show_page(p)
  if fftsa.about_lines == nil then return false end
  local last = fftsa.about_pages()
  if p < 1 then p = 1 end
  if p > last then p = last end
  fftsa.about_page = p
  local base, i = (p - 1) * fftsa.about_rows, nil
  for i = 1, fftsa.about_rows do
    local s = fftsa.about_text[base + i]
    if s == nil then s = "" end
    fftsa.settxt(fftsa.about_lines[i], s)
  end
  fftsa.settxt(fftsa.about_pageno, string.format("page %d of %d", p, last))
  return true
end

function fftsa.about_pgup()
  return fftsa.about_show_page(fftsa.about_page - 1)
end

function fftsa.about_pgdn()
  return fftsa.about_show_page(fftsa.about_page + 1)
end

-- Built at launch with every other screen. A create on a visible screen is what strands
-- objects, and the only screen visible during a build is the loading cover.
function fftsa.build_about()
  fftsa.destroy_about()
  local create = display.create
  fftsa.aboutscr = create(display.ROOT, display.OBJ_SCREEN, "FFT Analyser - About")
  if fftsa.aboutscr == nil then
    fftsa.lasterr = "display object pool exhausted building the about screen -- "
                    .. "power cycle the instrument."
    return false, fftsa.lasterr
  end
  fftsa.loading_front()
  -- Outside the paged rows, so it stays put whichever page is showing.
  fftsa.about_name = create(fftsa.aboutscr, display.OBJ_TEXT, fftsa.about_title_x,
                            fftsa.about_title_y, "Author: Ian Ameline",
                            fftsa.about_c_title, display.FONT_4, display.JUST_CENTER)
  fftsa.about_lines = {}
  local y, i = fftsa.about_body_y, nil
  for i = 1, fftsa.about_rows do
    fftsa.about_lines[i] = create(fftsa.aboutscr, display.OBJ_TEXT, fftsa.about_x, y, "",
                                  fftsa.about_c_body, display.FONT_1, display.JUST_LEFT)
    y = y + fftsa.about_body_dy
  end
  fftsa.about_pageno = create(fftsa.aboutscr, display.OBJ_TEXT, fftsa.about_title_x,
                              fftsa.opt_btn_y - 8, "", fftsa.about_c_title,
                              display.FONT_SMALL, display.JUST_CENTER)
  local b_up = create(fftsa.aboutscr, display.OBJ_BUTTON, 8, fftsa.opt_btn_y, "PgUp", 140)
  display.setevent(b_up, display.EVENT_PRESS,
                   "if fftsa ~= nil then fftsa.guard(fftsa.about_pgup) end")
  local b_dn = create(fftsa.aboutscr, display.OBJ_BUTTON, 168, fftsa.opt_btn_y,
                      "PgDn", 140)
  display.setevent(b_dn, display.EVENT_PRESS,
                   "if fftsa ~= nil then fftsa.guard(fftsa.about_pgdn) end")
  local b_back = create(fftsa.aboutscr, display.OBJ_BUTTON, 630, fftsa.opt_btn_y,
                        "Back", 140)
  display.setevent(b_back, display.EVENT_PRESS,
                   "if fftsa ~= nil then fftsa.guard(fftsa.about_back) end")
  -- End App is delivered to the visible screen, and this one can be it.
  display.setevent(fftsa.aboutscr, display.EVENT_ENDAPP,
                   "if fftsa ~= nil then fftsa.cleanup() end")
  fftsa.about_show_page(1)
  return fftsa.aboutscr
end

-- A press only switches, like Options: a nil handle means the pool refused at build.
-- Always from the first page, so the screen reads the same every time it is opened.
function fftsa.about()
  if fftsa.aboutscr == nil then return false end
  fftsa.about_show_page(1)
  display.changescreen(fftsa.aboutscr)
  return true
end

-- Back to the form it was opened from, or to the spectrum if the form is gone.
function fftsa.about_back()
  if fftsa.optscr == nil then return fftsa.show_main() end
  display.changescreen(fftsa.optscr)
  return true
end

function fftsa.sample_rate_text(fs)
  if fs >= 1000000 then return string.format("%g MS/s", fs / 1000000) end
  if fs >= 1000 then return string.format("%g kS/s", fs / 1000) end
  return string.format("%g S/s", fs)
end

-- Acquisition duration is N/fs, not the first-to-last interval (N-1)/fs. With the
-- band-pass decimating, fs is the rate the transform sees, so N/fs is still the record
-- length in time, and the decimation is named rather than left implicit.
-- The band-pass line, on or off. When on, the decimation says whether the filter is
-- actually in the path: no decimation means the span is too wide for any. Its own
-- function because the two readback lines want it in different places.
function fftsa.bp_text(d, on)
  if d == nil then d = fftsa.bp_d end
  if on == nil then on = fftsa.bp_on end
  -- NOTHING when it is off, which is the only state the form can produce: the field is
  -- withheld, so "BP:Off" on every line would be a permanent label for a feature that is
  -- not there. It still speaks up when something sets fftsa.bp_on over the socket, or the
  -- decimation would be invisible.
  if not on then return "" end
  if d ~= nil and d > 1 then return string.format("BP:On /%d", d) end
  return "BP:On (" .. fftsa.bp_why(fftsa.fs_acq, fftsa.fhi, fftsa.n) .. ")"
end

-- fs IS THE DIGITIZER'S RATE, never the decimated one. The decimated rate is a derived
-- figure -- 200 kS/s over /3 is 66.667 -- and printing that as "fs" reads as the hardware
-- running below its own 100 kS/s floor, which it never does. The bin and the record
-- length are computed from the decimated rate, where they belong: the bin is fs_eff/N, and
-- N/fs_eff is the same record duration as N*D/fs_acq.
function fftsa.opt_info_text(fs, n, wi, bi, acq)
  fs, n = fs or fftsa.fs, n or fftsa.n
  if acq == nil then acq = fftsa.fs_acq or fs end
  return string.format("fs %s   bin %.2f Hz   acq %.2f ms   %s",
                       fftsa.sample_rate_text(acq), fs / n, 1000 * n / fs,
                       fftsa.win_label(wi, bi))
end

-- Read a field, or answer the fallback if the handle was never built. The firmware
-- returns nil from display.create when the object pool is exhausted, so a field handle
-- can legitimately be nil, and getvalue on nil is a raise in OUR code -- not a firmware
-- refusal. Testing for nil here is what keeps a missing field from taking Options and
-- Apply down with it.
function fftsa.getval(h, fallback)
  if h == nil then return fallback end
  return display.getvalue(h)
end

-- Set a field, or do nothing if the handle was never built. See fftsa.options().
function fftsa.setval(h, v)
  if h == nil then return false end
  display.setvalue(h, v)
  return true
end

-- Set a text, or do nothing if the handle was never built.
function fftsa.settxt(h, t)
  if h == nil then return false end
  display.settext(h, t)
  return true
end

function fftsa.options_preview()
  local lo, hi = fftsa.options_span()
  local n = fftsa.options_samples()
  local fs = fftsa.pick_fs(hi)
  -- Reuse the timestamp-measured rate when previewing the active acquisition rate.
  if fs == fftsa.pick_fs(fftsa.fhi) then fs = fftsa.fs_acq or fftsa.fs end
  -- The decimation the pending fields would get, so the previewed bin width is the one
  -- Apply will actually produce rather than the undecimated one.
  local d = 1
  local bp = (fftsa.opt_index(fftsa.getval(fftsa.opt_bp), fftsa.onoff_labels,
                              fftsa.onoff_to_idx(fftsa.bp_on)) == 2)
  if bp then
    -- The same plan Apply will make, or the preview promises a bin width it cannot
    -- produce: the rate and the decimation are chosen together.
    fs, d = fftsa.bp_plan(hi, n)
  end
  local acq = fs
  fs = fs / d
  -- The window comes from the fields too, or three quarters of the line would track
  -- the edit and the fourth would silently show the applied window.
  local wi = fftsa.opt_index(fftsa.getval(fftsa.opt_win), fftsa.win_names, fftsa.win_i)
  local bi = fftsa.opt_index(fftsa.getval(fftsa.opt_beta), fftsa.kbeta_labels,
                             fftsa.kbeta_i)
  local text = fftsa.opt_info_text(fs, n, wi, bi, acq)
  local bptxt = fftsa.bp_text(d, bp)
  if bptxt ~= "" then text = text .. "   " .. bptxt end
  if text ~= fftsa.opt_info_last then
    fftsa.settxt(fftsa.opt_info, text)
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

-- Put a line on the glass, on the settings line under the peak rows. Failures that are
-- only recorded in fftsa.lasterr are invisible to the operator, who sees a press that did
-- nothing and a previous spectrum still running. The settings line is rewritten by the
-- next fftsa.sg_set_xrange(), so this is not sticky.
function fftsa.say(msg)
  if fftsa.sg_xunit ~= nil then
    display.settext(fftsa.sg_xunit, string.sub(tostring(msg), 1, 70))
  end
end

-- Back to the spectrum screen, which is also what lets the frame timer run again.
function fftsa.show_main()
  if fftsa.sg_scr ~= nil then
    display.changescreen(fftsa.sg_scr)
    return true
  end
  display.changescreen(display.SCREEN_HOME)
  return false
end

-- A press only switches. Everything is built in fftsa.start(), so a nil handle
-- means the object pool refused and building it now would fail the same way.
function fftsa.options()
  if fftsa.optscr == nil then return false end
  -- A nil handle is what an exhausted pool leaves, so every field goes through the
  -- nil-testing setters: the cost is then the fields the pool refused, not the Options
  -- button and Apply together.
  fftsa.setval(fftsa.opt_flo, fftsa.flo)
  fftsa.setval(fftsa.opt_fhi, fftsa.fhi)
  fftsa.setval(fftsa.opt_rng, fftsa.range_to_idx(fftsa.range))
  fftsa.setval(fftsa.opt_win, fftsa.win_i)
  fftsa.setval(fftsa.opt_beta, fftsa.kbeta_i)
  fftsa.setval(fftsa.opt_n, fftsa.sample_to_idx(fftsa.n))
  -- Guarded like its neighbours: five field reads on handles the pool may have refused,
  -- and changescreen is the next line. Unguarded, a refusal at the end of the create list
  -- leaves the Options button dead for the life of the app.
  fftsa.options_preview()
  display.changescreen(fftsa.optscr)
  return true
end

function fftsa.options_span()
  local lo = fftsa.getval(fftsa.opt_flo, fftsa.flo)
  local hi = fftsa.getval(fftsa.opt_fhi, fftsa.fhi)
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
  local ri = fftsa.getval(fftsa.opt_rng)
  local wi = fftsa.getval(fftsa.opt_win)
  local bi = fftsa.getval(fftsa.opt_beta)
  local mki = fftsa.opt_index(fftsa.getval(fftsa.opt_mk),
                              fftsa.onoff_labels,
                              fftsa.onoff_to_idx(fftsa.sg_markers))
  local bpi = fftsa.opt_index(fftsa.getval(fftsa.opt_bp),
                              fftsa.onoff_labels,
                              fftsa.onoff_to_idx(fftsa.bp_on))
  local nnew = fftsa.options_samples()
  local nlo, nhi = fftsa.options_span()
  fftsa.flo, fftsa.fhi = nlo, nhi
  local nold    = fftsa.n
  fftsa.n       = nnew
  fftsa.range   = fftsa.idx_to_range(ri)
  fftsa.win_i   = fftsa.opt_index(wi, fftsa.win_names, fftsa.win_i)
  fftsa.kbeta_i = fftsa.opt_index(bi, fftsa.kbeta_labels, fftsa.kbeta_i)
  -- Rebound only on a change: sg_bind() calls removeall, which repaints the whole widget
  -- including its axis labels, and this is the one moment that is already a repaint.
  local mknew = (mki == 2)
  local mkchanged = (mknew ~= fftsa.sg_markers)
  fftsa.sg_markers = mknew
  fftsa.bp_on = (bpi == 2)
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
    if mkchanged then fftsa.sg_bind() end
    display.settext(fftsa.sg_xunit, fftsa.sg_xunit_text())
  end
  return ok
end

function fftsa.options_cancel()
  fftsa.show_main()
end

-- Lock and Options: two icon buttons in the slot Options filled alone. A button carries
-- no image and display.settext does not accept one, so an icon is an OBJ_IMAGE child
-- created after its button, which puts it on top; a press on the icon reaches the button
-- underneath.
fftsa.btn_y      = 350
fftsa.btn_h      = 60       -- measured off a panel capture
fftsa.btn_lock_x = 660
fftsa.btn_lock_w = 60
fftsa.btn_opt_x  = 730
fftsa.btn_opt_w  = 60
fftsa.lock_img_w = 28       -- fftlockc and fftlocko are 28x34
fftsa.lock_img_h = 34
fftsa.cog_img_w  = 34       -- fftcog is 34x34
fftsa.cog_img_h  = 34

-- tools/package_tspa.py reads these out of the source to decide which assets/<name>.png
-- to embed, so inlining one of them stops its image shipping.
fftsa.img_lock_c = "fftlockc"
fftsa.img_lock_o = "fftlocko"
fftsa.img_cog    = "fftcog"

-- The lock state on the glass is which of the padlock pair is visible: closed while the
-- view is locked, open while it is free.
function fftsa.lock_icon()
  local on, off = fftsa.lockimg_o, fftsa.lockimg_c
  if fftsa.sg_lock then on, off = fftsa.lockimg_c, fftsa.lockimg_o end
  if off ~= nil then display.setstate(off, display.STATE_INVISIBLE) end
  fftsa.icon_redraw(on)
end

-- Force an icon to paint. Setting a state the object already holds is 0.020 ms and may
-- be taken as nothing to do, so the pair is what guarantees the draw, at 0.034 ms.
function fftsa.icon_redraw(h)
  if h == nil then return false end
  display.setstate(h, display.STATE_INVISIBLE)
  display.setstate(h, display.STATE_ENABLE)
  return true
end

-- Called from fftsa.sg_slow_tick(), which is where the cadence is explained. Re-asserting
-- from a press handler instead does not work: the firmware's repaint comes after it.
function fftsa.icons_reassert()
  fftsa.lock_icon()
  fftsa.icon_redraw(fftsa.optimg)
  return true
end

-- The icon goes before the restore, so a restore that fails cannot leave the padlock
-- showing the opposite of fftsa.sg_lock for the rest of the session.
function fftsa.toggle_lock()
  fftsa.sg_lock = not fftsa.sg_lock
  fftsa.sg_lock_hook(fftsa.sg_lock)
  fftsa.lock_icon()
  if fftsa.sg_lock then fftsa.sg_relock() end
  return fftsa.sg_lock
end

-- A button whose icon did not load is blank but still works, so a nil here is recorded
-- rather than failing the start.
function fftsa.icon_at(x, y, name)
  if name == nil then return nil end
  local img = display.create(fftsa.sg_scr, display.OBJ_IMAGE, x, y, name)
  if img == nil then
    fftsa.lasterr = "image " .. tostring(name) .. " did not load"
    fftsa.say(fftsa.lasterr)
  end
  return img
end

-- A button with one or two icons centred over it, two being the padlock pair. An
-- exhausted object pool returns nil, so the icons are skipped without their button:
-- an icon alone looks pressable and does nothing.
function fftsa.icon_button(x, w, cmd, iw, ih, name1, name2)
  local b = display.create(fftsa.sg_scr, display.OBJ_BUTTON, x, fftsa.btn_y, " ", w)
  if b == nil then
    fftsa.lasterr = "button at x=" .. tostring(x) .. " could not be created"
    fftsa.say(fftsa.lasterr)
    return nil, nil, nil
  end
  display.setevent(b, display.EVENT_PRESS, cmd)
  local ix = x + math.floor((w - iw) / 2)
  local iy = fftsa.btn_y + math.floor((fftsa.btn_h - ih) / 2)
  return b, fftsa.icon_at(ix, iy, name1), fftsa.icon_at(ix, iy, name2)
end

-- Everything the app ever displays, created here and nowhere else. The cover comes
-- first so that no screen is ever assembled in view.
function fftsa.build()
  fftsa.loading_build()
  fftsa.loading_front()
  -- The trace buffer at sg_maxpts, for the life of the app: allocated at the CEILING
  -- rather than at sg_ncol so the point count stays adjustable upwards while running
  -- without anything being resized or reallocated.
  local scr, why = fftsa.sg_build("FFT SPECTRUM ANALYSER", fftsa.n / 2, fftsa.sg_maxpts)
  if scr == nil then return false, why end
  -- The buttons died with the screen fftsa.sg_build() just destroyed: clear the
  -- stale handles, do not delete them.
  fftsa.optbtn, fftsa.optimg = nil, nil
  fftsa.lockbtn, fftsa.lockimg_c, fftsa.lockimg_o = nil, nil, nil
  fftsa.lockbtn, fftsa.lockimg_c, fftsa.lockimg_o = fftsa.icon_button(
    fftsa.btn_lock_x, fftsa.btn_lock_w,
    "if fftsa ~= nil then fftsa.guard(fftsa.toggle_lock) end",
    fftsa.lock_img_w, fftsa.lock_img_h, fftsa.img_lock_c, fftsa.img_lock_o)
  fftsa.lock_icon()
  fftsa.sg_lock_hook(fftsa.sg_lock)
  fftsa.optbtn, fftsa.optimg = fftsa.icon_button(
    fftsa.btn_opt_x, fftsa.btn_opt_w,
    "if fftsa ~= nil then fftsa.guard(fftsa.options) end",
    fftsa.cog_img_w, fftsa.cog_img_h, fftsa.img_cog)
  local optok, optwhy = fftsa.build_options()
  if optok == false then return false, optwhy end
  local aboutok, aboutwhy = fftsa.build_about()
  if aboutok == false then return false, aboutwhy end
  return fftsa.sg_scr
end

-- Timer period leaving a frame of this length about a fifth idle, rounded up to the
-- firmware's 0.05 s tick floor (arm(0.045) is refused with event 1131). The one place the
-- occupancy rule lives, so the modelled first arm and the measured re-arms agree.
--
-- The idle is what dispatches a touch: delay() lets the display task paint, but a press
-- needs the interpreter, and a tick landing during a frame is dropped. At the 0.05 s floor
-- that left 12 ms of 500 at 4096 samples, where Options was unreachable.
--
-- The 2.5 ms of slack prefers rate over idle. A tick is 50 ms, so holding the target to
-- the last millisecond buys a fiftieth of a tick of idle and costs a whole tick of rate:
-- the worst frame at 512 is 80.1 ms, a tenth of a millisecond past two ticks.
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

-- Arm the frame timer. It is active only while its parent screen is visible, which is
-- what stops frames while Options or About is on show. One frame per tick: back-to-back
-- frames keep the interpreter out of its event loop.
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
  fftsa.stop()
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

-- One cleanup path for a failed start, so the two ways of failing cannot drift apart.
function fftsa.start_failed(why)
  fftsa.lasterr = tostring(why)
  fftsa.stop()
  print("fftsa start FAILED (cleaned up): " .. tostring(why))
  -- No console as an installed App, so the failure goes on the panel.
  fftsa.show_error(tostring(why))
  return false
end

-- Startup, guarded end to end so a failure part-way leaves nothing without a teardown.
-- The opening fftsa.stop() reclaims a previous launch's handles: as an installed App the
-- script re-runs on every open, and an exit that skipped EVENT_ENDAPP (the Home screen,
-- another App) leaves them behind.
function fftsa.start()
  fftsa.stop()
  fftsa.halted, fftsa.errrun, fftsa.stop_pending = false, 0, false

  -- The display object pool running out is a RETURN, not a raise: display.create answers
  -- nil and posts one event, and build() passes that up as false and a reason. Handled
  -- here directly rather than raised into the boundary below, which would be reporting a
  -- condition to ourselves.
  local built, why = fftsa.build()
  if built == false then return fftsa.start_failed(why or "build failed") end

  local hooked = fftsa.install_cleanup()
  -- The boundary that remains, and what it is for: apply() is arithmetic over tables
  -- fft_init builds, so a defect in OUR code raises here. A raise escaping a timer or
  -- button callback on this firmware posts -286 and leaves the app on screen and dead,
  -- so one backstop per entry point stays until those paths are proved non-raising.
  local ok, err = pcall(function()
    fftsa.apply()
    -- With the computed period, not the 0.05 s floor: apply() re-arms on a size change
    -- but cannot do it here, because the timer is created after the first apply() runs.
    -- Left at the floor, the default size kept whatever idle the quantisation happened
    -- to leave -- which is the whole fault this period exists to remove.
    fftsa.period = fftsa.frame_period(fftsa.n)
    fftsa.arm(fftsa.period)
  end)
  if not ok then return fftsa.start_failed(tostring(err)) end
  if not hooked then
    print("fftsa WARNING: End App cleanup not hooked -- " .. tostring(fftsa.lasterr))
    display.settext(fftsa.sg_xunit, "WARNING: End App will not clean up")
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
  fftsa.optbtn, fftsa.optimg = nil, nil       -- children of the spectrum screen
  fftsa.lockbtn, fftsa.lockimg_c, fftsa.lockimg_o = nil, nil, nil
  pcall(function() fftsa.sg_destroy() end)    -- screen, graph, texts, spectrum buffer
  fftsa.destroy_options()
  fftsa.destroy_about()
  fftsa.loading_destroy(display.SCREEN_HOME)
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

-- Startup failure on the panel. End App is hooked here too and the handle kept, so
-- stop() can delete the screen.
--
-- The commonest reason startup fails is an exhausted pool, and display.create then
-- answers nil here too: unguarded, every child is built against a nil parent and
-- changescreen(nil) raises, leaving a blank panel in exactly the case this screen exists
-- for. Nothing can be drawn at that point, so it says so on the console instead.
--
-- These children are created on a visible screen, which nothing else in the app does:
-- it runs once, after startup has already failed, and the cover is gone by then.
function fftsa.show_error(msg)
  local shown = pcall(function()
    if fftsa.errscr ~= nil then
      fftsa.del_obj(fftsa.errscr)
      fftsa.errscr = nil
    end
    fftsa.errscr = display.create(display.ROOT, display.OBJ_SCREEN, "FFT ANALYSER ERROR")
    if fftsa.errscr == nil then
      -- No screen to report on, so the console is all there is. Returning rather than
      -- raising: the caller is already handling a failure and has nothing better to do
      -- with a second one.
      print("fftsa: object pool exhausted; no error screen")
      return false
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
    display.changescreen(display.SCREEN_HOME)
    print("fftsa: could not build the error screen either -- " .. tostring(msg))
  end
  return fftsa.errscr
end
