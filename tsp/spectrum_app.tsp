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

-- Capability gate. The whole of the change when native dsp.* ships: the
-- firmware's own primitives are used when they are there, and the Lua
-- implementation is installed when they are not.
fftsa.dsp_native = (dsp ~= nil and dsp.version ~= nil and dsp.version >= 1)
if not fftsa.dsp_native then fftsa.dsp_install() end

-- Here and not in fft_core.tsp because tools/package_tspa.py concatenates the modules into
-- one loadscript chunk in a fixed order and there is no runtime module loading on this
-- instrument: both implementations are in the archive for ever and this only decides which
-- binds the name. tsp/dsp_lua.tsp sits ahead of this file in that order, so the installer
-- exists before the gate runs.

-- THE WINDOW ENUM IS NOT THE PICKER INDEX. It currently coincides -- dsp.WINDOW_HANN is 1
-- and fftsa.win_names[1] is "Hann", with WINDOW_RECT at 0 excluded, which is the only reason
-- the off-by-one never shows. Twenty-five call sites drive the options form and the settings
-- line off the index, so an enum numbered differently in the firmware would select the wrong
-- window with nothing on the glass to say so: every amplitude out by a scalloping factor.
-- Mapped rather than assumed, in both directions, one map each side of the seam. Built from
-- whatever dsp.WINDOW_* turn out to be, which is why it sits after the gate.
--
-- Index-parallel to fftsa.win_names: a window added to one and not the other falls back to
-- Hann without saying so, which is what the length check in the proto suite is for.
fftsa.win_dsp = {}
fftsa.win_dsp[1] = dsp.WINDOW_HANN
fftsa.win_dsp[2] = dsp.WINDOW_BLACKMAN
fftsa.win_dsp[3] = dsp.WINDOW_BLACKMAN_HARRIS
fftsa.win_dsp[4] = dsp.WINDOW_KAISER

function fftsa.win_to_dsp(wi)
  local k = fftsa.win_dsp[wi or fftsa.win_i]
  if k == nil then k = fftsa.win_dsp[1] end
  return k
end

-- The harmonic rules are the app's, not an implementation default. Their own names because
-- fftsa.thd_hmax, thd_nsample and thd_mains are where the primitive puts the ones it used.
-- After the gate, the mains selection being one of its enums.
fftsa.thd_hmax_want  = 20              -- harmonics counted; the window top usually stops first
fftsa.thd_bins_want  = 1024            -- bins sampled for the floor; 0 means every bin
fftsa.thd_mains_want = dsp.MAINS_BOTH  -- hum discounted at 50 and at 60 Hz

-- A refusal as something that can go on the glass. The primitives post an event and return a
-- negative code, and "-2" tells an operator nothing; dsp.lastevent() carries the reason the
-- implementation posted. fftsa.options_apply writes this behind "APPLY FAILED:" and
-- fftsa.frame puts its first 60 characters behind the HALTED banner.
--
-- The code is compared as well as read: an older event still in the log is not this
-- refusal's reason, and a wrong reason reads exactly like a right one.
function fftsa.dsp_why(what, code)
  local msg = tostring(what) .. " refused (" .. tostring(code) .. ")"
  local e = dsp.lastevent()
  if e ~= nil and e.why ~= nil and e.code == code then
    msg = msg .. ": " .. tostring(e.why)
  end
  return msg
end

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
-- Ceiling for the start, a kilohertz under the stop's so the form cannot be set to a span
-- of nothing. It is the Start field's own max, and span_clamp holds a gesture to the same
-- line: without that, a pinch high up the range could hand Options a start its own field
-- would refuse.
fftsa.flo_max = fftsa.fhi_max - 1000
fftsa.range   = 10          -- digitizer input range (V): 0.1 / 1 / 10
fftsa.fs      = 100000      -- sample rate (picked from fftsa.fhi, then measured)
fftsa.binhz   = 0           -- true bin width, from measured fs
fftsa.busy    = false       -- reentrancy guard (never preserved across a reload)
fftsa.stop_pending = false  -- a teardown deferred until the running frame ends
fftsa.retune_pending = false -- a gesture's span, waiting for its re-plan between frames
fftsa.halted  = false       -- frames suppressed after repeated failures
fftsa.lasterr = nil         -- last frame error, nil if none
fftsa.errcount = 0          -- count of dropped frames
fftsa.errrun  = 0           -- consecutive dropped frames
fftsa.errmax  = 20          -- give up (and say so) after this many in a row
fftsa.shortreads = 0        -- captures rejected for returning fewer than n samples

-- What the Reset button restores, captured from the assignments that set the six form
-- fields rather than restating their values: one owner per setting, so a changed default
-- cannot disagree with what the button offers. The capture is sound because every one of
-- those assignments is unconditional -- fftsa = fftsa or {} inherits the previous launch's
-- table, and an `or` on any of them would make this the last session's settings.
fftsa.defaults = {flo = fftsa.flo, fhi = fftsa.fhi, range = fftsa.range,
                  win_i = fftsa.win_i, kbeta_i = fftsa.kbeta_i, n = fftsa.n}

-- The legal span, for anything that asks for one: the Options form and an unlocked graph
-- gesture both come through here, or the form would offer a range a gesture could not
-- reach. Each end clamps to its own field's declared range, then the pair is ordered -- a
-- stop at or below the start holds no bins. One repair settles the order whatever the four
-- clamps did, and does so because fhi_min is wholly above flomin: the stop is already at or
-- above fhi_min by then, so dropping the start to flomin always leaves start < stop.
function fftsa.span_clamp(lo, hi)
  local nlo, nhi = lo, hi
  -- NaN first, or it passes through as a pair that is neither in range nor ordered: every
  -- comparison below is false for one. Tested against itself, NaN being the only value not
  -- equal to itself; repaired to the floors, which is the narrowest legal span. Callers
  -- should still refuse a NaN rather than adopt this, and sg_adopt_x does -- but the
  -- postcondition belongs here, where it holds for any two numbers whatever.
  if nlo ~= nlo then nlo = fftsa.flomin end
  if nhi ~= nhi then nhi = fftsa.fhi_min end
  if nhi > fftsa.fhi_max then nhi = fftsa.fhi_max end
  if nhi < fftsa.fhi_min then nhi = fftsa.fhi_min end
  if nlo < fftsa.flomin then nlo = fftsa.flomin end
  if nlo > fftsa.flo_max then nlo = fftsa.flo_max end
  if nlo >= nhi then nlo = fftsa.flomin end
  return nlo, nhi
end

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

-- Does a new stop frequency need the hardware re-planned? The digitizer runs at the lowest
-- rate whose Nyquist covers the stop, so a stop inside the rate in force changes only which
-- bins are plotted: one axis write, no capture. Planned rate against planned rate, never
-- against fs_acq, which holds the rate MEASURED off the timestamps and never equals one.
function fftsa.plan_changed(fhi_new)
  return fftsa.pick_fs(fhi_new) ~= fftsa.pick_fs(fftsa.fhi)
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

-- Every frame-class attribute the display owns, written every frame: all are settable while
-- the app runs and an unchanged write costs a comparison, so syncing one and not the rest is
-- what makes sg_ncol live and sg_dbmin dead with nothing to say which. Both counts are clamped
-- to what was built, being refused above it. The peak count is returned so the display loops
-- ask for the same number -- read separately, a raised sg_npeak asks dsp.peak() for a peak it
-- never found, and that posts an event per peak per frame.
function fftsa.dsp_live()
  local ncol = fftsa.sg_ncol
  local cap = nil
  if fftsa.sg_buf ~= nil then cap = fftsa.sg_buf.capacity end
  if cap ~= nil and ncol ~= nil and ncol > cap then ncol = cap end
  if ncol == nil or ncol < 2 then ncol = 2 end
  dsp.out.segments = ncol
  -- The plot's own axis, so trace, peak column and noise figure share one floor.
  dsp.out.dbfloor = fftsa.sg_dbmin
  dsp.out.dbceil  = fftsa.sg_dbmax
  dsp.out.vfloor  = fftsa.sg_vfloor
  -- Ceiling is the rows build() made: a row that does not exist cannot be written.
  local npk = fftsa.sg_npeak
  local rows = nil
  if fftsa.sg_pk_f ~= nil then rows = table.getn(fftsa.sg_pk_f) end
  if rows ~= nil and rows > 0 and npk > rows then npk = rows end
  if npk == nil or npk < 1 then npk = 1 end
  dsp.peaks.count = npk
  -- The harmonic rules, or a native dsp's own defaults move all three figures on switch day.
  dsp.thd.harmonics = fftsa.thd_hmax_want
  dsp.thd.bins      = fftsa.thd_bins_want
  dsp.thd.mains     = fftsa.thd_mains_want
  return npk
end

-- The plotted window, written per frame. An adopted gesture moves the axis without re-planning, so a
-- window written only at Apply leaves the trace, the peaks and the THD figures on the span
-- before it -- every frequency on the plot mislabelled. Frame attributes, so this dirties
-- nothing. From the stored axis range, which is what the widget was pinned to.
function fftsa.dsp_window()
  local lo, hi = fftsa.sg_flo_hz, fftsa.sg_fhi_hz
  if lo == nil or hi == nil or not (hi > lo) then return false end
  dsp.out.lowfreq  = lo
  dsp.out.highfreq = hi
  return true
end

-- Apply the current settings to the hardware and the graph. Safe to repeat: the
-- capture buffer is resized when needed; the graph keeps its original buffer.
-- dsp.commit() rebuilds the window and its interpolation tables, which is the slow part of a
-- press -- 0.163 ms a sample, so 83 ms at 512 and a measured 2.667 s at 16384 -- hence the
-- cover. It rebuilds nothing when neither the count, the window nor the beta moved, which is
-- every adopted gesture and most presses: every attribute below is rewritten
-- unconditionally, and a write that does not CHANGE the value dirties nothing.
function fftsa.apply()
  -- fs_acq is the digitizer's rate and fftsa.fs the rate the transform sees. They are equal
  -- with no filter in the path, and kept separate because everything downstream -- binhz,
  -- the settings line, the span arithmetic -- reads fftsa.fs.
  fftsa.fs_acq = fftsa.pick_fs(fftsa.fhi)
  dsp.fft.samples    = fftsa.n
  dsp.fft.window     = fftsa.win_to_dsp(fftsa.win_i)
  dsp.fft.beta       = fftsa.kbeta(fftsa.kbeta_i)
  -- The rate the digitizer is ABOUT to be set to. commit() needs it before any capture
  -- exists, because the bin width and srclength follow from it.
  dsp.fft.samplerate = fftsa.fs_acq
  -- Written every Apply, not left at the default: the app offers no filter, and something
  -- setting it over the socket would otherwise survive the next press.
  dsp.filter.state = dsp.OFF
  -- From fftsa.flo/fhi, not the stored axis dsp_window() reads: the pin below is what puts
  -- the axis on this pair, so the stored one still holds the previous span here.
  dsp.out.lowfreq  = fftsa.flo
  dsp.out.highfreq = fftsa.fhi
  -- The axis floor follows the range: a DMM7510 plots to -140 dBV on 1 V and 0.1 V, where its
  -- noise floor measures -129 and -134. Ahead of dsp_live(), which hands the floor to the
  -- primitive, and ahead of the capture for the same reason the X pin is; the pin is
  -- conditional because an axis write costs 60 ms.
  if fftsa.sg_dbmin_set(fftsa.range) then fftsa.sg_pin_y() end
  fftsa.dsp_live()
  local rc = dsp.commit()
  if rc ~= dsp.OK then error(fftsa.dsp_why("commit", rc), 0) end
  local need = dsp.fft.srclength
  fftsa.fs = fftsa.fs_acq
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
  -- srclength read back rather than assumed to be fftsa.n: it is the primitive that decides
  -- how long a record it consumes, and under-acquiring would short-read every frame.
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
  -- Measured from the capture's own timestamps: the samplerate read-back is unreliable.
  fftsa.fs_acq = fftsa.measure_fs(fftsa.cap)
  fftsa.fs     = fftsa.fs_acq
  fftsa.binhz  = fftsa.fs / fftsa.n
  -- Large transforms outrun the 2 s default, so the guard follows the measured frame
  -- cost with margin rather than a multiple of the sample count.
  fftsa.busy_max = math.max(2.0, 3.0 * fftsa.frame_estimate(fftsa.n))
  -- Re-armed only when the SAMPLE COUNT moved, which is the only thing the period is
  -- derived from. arm() deletes the timer and creates a replacement, so re-arming restarts
  -- the period and churns the object pool: an adopted gesture, which cannot change the
  -- count, would pay a frame of latency for an identical timer and throw away the period
  -- frame() had measured. From the model, which frame() replaces after eight real frames.
  fftsa.work_peak, fftsa.work_seen = nil, 0
  if fftsa.timer ~= nil and fftsa.armed_n ~= fftsa.n then
    fftsa.period = fftsa.frame_period(fftsa.n)
    fftsa.arm(fftsa.period)
  end
  fftsa.sg_pk_last, fftsa.sg_pk_lf, fftsa.sg_pk_lv = nil, {}, {}
  -- The LEGEND again, not the axis. What the measured rate refined is binhz, and so the bin
  -- count the legend reports for a narrow span; fftsa.flo and fftsa.fhi have not moved since
  -- the pin above, so re-pinning would be a second 60 ms write of identical limits.
  fftsa.sg_write_xunit()
end

-- The peaks the primitive reported, into two tables the display reads. Allocated once: the
-- house rule is to allocate at Apply and never in a frame.
--
-- Through dsp.peak() rather than the implementation's own arrays, which are not API -- a
-- native primitive has none to reach into. Resolved once here, where the three display users
-- between them used to call fftsa.peak_interp eighteen times a frame.
function fftsa.dsp_peaks(count)
  if fftsa.pk_hz == nil then fftsa.pk_hz, fftsa.pk_v = {}, {} end
  local hz, v = fftsa.pk_hz, fftsa.pk_v
  local i
  for i = 1, count do
    hz[i], v[i] = dsp.peak(i)
  end
  return hz, v
end

-- One frame: acquire, one primitive call, plot. Runs under pcall from fftsa.frame().
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
  -- Asked of the capture before anything is computed from it, and free: the firmware keeps the
  -- buffer's min and max current as the readings land, so this is one call rather than a pass.
  fftsa.overrange = fftsa.cap_overrange(fftsa.cap)
  local npk = fftsa.dsp_live()
  fftsa.dsp_window()
  -- FILTER, WINDOW, TRANSFORM, POWER, REDUCE, PEAKS, and the trace written and counted. The
  -- primitive clears the destination itself: a clear-then-refill from out here opens a
  -- window in which the graph paints a half-filled trace.
  --
  -- marks = nil deliberately. One point a peak on a STYLE_LINE trace draws a polyline
  -- joining the peaks across the plot, and drawstyle is per graph, so the spectrum's own 255
  -- points would get markers too. fftsa.sg_update_markers draws needles instead -- three
  -- points a peak, a pixel either side -- from the same resolved table.
  local nseg = dsp.spectrum(fftsa.cap, fftsa.sg_buf, nil)
  if nseg == nil or nseg < 0 then error(fftsa.dsp_why("spectrum", nseg), 0) end
  -- ZERO SEGMENTS IS A SHORT RECORD, not a failure: nothing was written, the previous
  -- spectrum is still on screen, and a trigger timeout is the ordinary cause. Counted by the
  -- primitive, mirrored here because the settings line and the suite read this name.
  if nseg == 0 then
    fftsa.shortreads = dsp.shortreads
    return
  end
  -- MEASURED PER FRAME now, off the capture's own timestamps, where it used to be committed
  -- once an Apply and refined once more. At the 0.01 % timebase wander that is a dither far
  -- inside sg_pk_ftol, so the peak block does not redraw on it.
  fftsa.binhz = dsp.fft.binwidth
  -- Segments the widget was actually handed, from the primitive's own count rather than
  -- inferred from the buffer: clamped or overrun, the buffer's n ends at capacity either
  -- way, so only a counter can tell the two apart.
  fftsa.sg_nwrote = nseg
  local pk_hz, pk_v = fftsa.dsp_peaks(npk)
  -- After the trace rather than before it: the peaks come out of the same call that writes
  -- the trace, so the markers cannot be filled first. What the ordering was for still holds
  -- -- the yield below is the first paint after BOTH buffers are complete -- and the window
  -- in which one of them is incomplete is now the 18 marker points rather than 255 trace
  -- points.
  fftsa.sg_update_markers(nil, nil, npk, fftsa.binhz, pk_hz, pk_v)
  -- Display work the primitive does not do: outside any write window, then the paint.
  fftsa.sg_slow_tick()
  delay(fftsa.sg_yield)
  -- Dashes rather than the figures, which are all arithmetic about the sentinel: the peak
  -- frequencies in particular are arbitrary picks from a spectrum whose bins are equal.
  if fftsa.overrange then
    fftsa.sg_show_peaks_over()
  else
    fftsa.sg_show_peaks(nil, nil, npk, fftsa.binhz, pk_hz, pk_v)
  end
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
-- STATED BY THE PRIMITIVE, not modelled here: dsp.fft.spectrumtime is filled by commit() for
-- the plan in force, and every coefficient belongs to whichever implementation is bound.
--
-- Both callers ask about the count just committed: busy_max at the end of apply(), and the
-- first timer arm immediately after it. So the floor below is reached only by a question
-- about a plan that does not exist, and it answers one tick rather than a second copy of a
-- model free to drift from the primitive's.
function fftsa.frame_estimate(n)
  if n == nil or n < 2 then n = 512 end
  if dsp.fft.samples == n then
    local t = dsp.fft.spectrumtime
    if type(t) == "number" and t > 0 then return t end
  end
  return 0.05
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
  -- An unlocked gesture's span is installed here, between frames: fftsa.apply() re-plans
  -- the digitizer and takes its own capture, so it cannot run inside a frame using the
  -- buffers. halted keeps the timer out of frame_body meanwhile and the guard above is still
  -- held. Skipped when a teardown waits, and when the frame above gave up -- halted is
  -- cleared at the end of this block, so retuning through a halt would restart that loop.
  if fftsa.retune_pending and not fftsa.stop_pending and not fftsa.halted then
    fftsa.retune_pending = false
    -- Reconfigures the digitizer and takes one capture, with the trace frozen for it. The
    -- window tables are NOT rebuilt: fft_init() is keyed on the sample count and the window,
    -- and a gesture changes neither. The line says why; apply() rewrites it at the end.
    fftsa.say(string.format("retuning to %.0f - %.0f Hz", fftsa.flo, fftsa.fhi))
    fftsa.halted = true
    local rok, rerr = pcall(function() fftsa.apply() end)
    fftsa.halted = false
    if not rok then
      fftsa.lasterr = tostring(rerr)
      fftsa.say("RETUNE FAILED: " .. tostring(rerr))
      -- sg_adopt_x left the pin to apply(), so a failure before apply's own pin would
      -- strand the axis on the gesture's unclamped limits with the trace in the clamped
      -- window. Nothing else would re-pin until the next gesture.
      fftsa.sg_pin_x()
    end
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
  fftsa.opt_mk = nil
  fftsa.opt_info_last = nil
end

-- Form geometry, two columns like the decode app's: six fields become three rows,
-- and the gap that buys is what makes each box a touch target. display.create takes
-- no width for an OBJ_EDIT_*, so the second column's x is the one number to check on
-- the glass. Labels are right-aligned and end at the column x.
-- Six: Peak Markers is withheld. See fftsa.opt_mk.
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
                       display.NFORMAT_PREFIX, fftsa.flo, fftsa.flomin, fftsa.flo_max, "Hz")
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
  -- Left of centre, 20 px off About and well clear of Apply at 470: the two that change
  -- what is measured stay together on the right, away from a thumb reaching for About.
  local b_rst = create(fftsa.optscr, display.OBJ_BUTTON, 168, fftsa.opt_btn_y, "Reset", 140)
  display.setevent(b_rst, display.EVENT_PRESS, "if fftsa ~= nil then fftsa.guard(fftsa.options_reset) end")
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

-- Which pair of terminals the ADC is on. FRONT/REAR is a front-panel button the app does
-- not own and cannot refuse, and the pair not selected is an open input: a signal on the
-- front with the switch on REAR reads as a dead signal rather than as a wrong setting,
-- which is indistinguishable from a broken transform. Named on the settings line so the
-- selection is always visible, and watched by the tick so pressing the button mid-session
-- shows up without an Apply. Total, like every other builder feeding that line.
function fftsa.terminal_text()
  local t = dmm.terminals
  if t == dmm.TERMINALS_REAR then return "REAR" end
  if t == dmm.TERMINALS_FRONT then return "FRONT" end
  return "TERM?"
end

-- Total by construction. This feeds the settings line and the Options readback, both
-- cosmetic, and both are built inside apply() after the hardware has been configured: a
-- rate that is not a number has to read as a gap, not abort the Apply around it.
function fftsa.sample_rate_text(fs)
  if type(fs) ~= "number" then return "?" end
  if fs >= 1000000 then return string.format("%g MS/s", fs / 1000000) end
  if fs >= 1000 then return string.format("%g kS/s", fs / 1000) end
  return string.format("%g S/s", fs)
end

-- Acquisition duration is N/fs, not the first-to-last interval (N-1)/fs.
function fftsa.opt_info_text(fs, n, wi, bi, acq)
  fs, n = fs or fftsa.fs, n or fftsa.n
  if acq == nil then acq = fftsa.fs_acq or fs end
  -- Every input can be nil or zero while the app is part-built or part-torn-down, and a
  -- raise here would abort an Apply over a text line. The bin and record length are the
  -- two that need arithmetic, so they are the two that get withheld; tostring() covers
  -- the window label, which is a table lookup and can miss.
  local wl = tostring(fftsa.win_label(wi, bi))
  if type(fs) ~= "number" or type(n) ~= "number" or n == 0 or fs == 0 then
    return string.format("fs %s   bin ? Hz   acq ? ms   %s",
                         fftsa.sample_rate_text(acq), wl)
  end
  return string.format("fs %s   bin %.2f Hz   acq %.2f ms   %s",
                       fftsa.sample_rate_text(acq), fs / n, 1000 * n / fs, wl)
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
  local acq = fs
  -- The window comes from the fields too, or three quarters of the line would track
  -- the edit and the fourth would silently show the applied window.
  local wi = fftsa.opt_index(fftsa.getval(fftsa.opt_win), fftsa.win_names, fftsa.win_i)
  local bi = fftsa.opt_index(fftsa.getval(fftsa.opt_beta), fftsa.kbeta_labels,
                             fftsa.kbeta_i)
  local text = fftsa.opt_info_text(fs, n, wi, bi, acq)
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

-- The six fields from one set of values, and the readback line that follows from them. The
-- single filler, so what Options shows and what Reset offers cannot drift apart.
--
-- A nil handle is what an exhausted pool leaves, so every field goes through the nil-testing
-- setters: the cost is then the fields the pool refused, not the Options button and Apply
-- together. Callers run under fftsa.guard for the same reason -- unguarded, a refusal at the
-- end of the create list leaves the button dead for the life of the app.
function fftsa.opt_fill(flo, fhi, range, win_i, kbeta_i, n)
  fftsa.setval(fftsa.opt_flo, flo)
  fftsa.setval(fftsa.opt_fhi, fhi)
  fftsa.setval(fftsa.opt_rng, fftsa.range_to_idx(range))
  fftsa.setval(fftsa.opt_win, win_i)
  fftsa.setval(fftsa.opt_beta, kbeta_i)
  fftsa.setval(fftsa.opt_n, fftsa.sample_to_idx(n))
  fftsa.options_preview()
end

-- A press only switches. Everything is built in fftsa.start(), so a nil handle
-- means the object pool refused and building it now would fail the same way.
function fftsa.options()
  if fftsa.optscr == nil then return false end
  fftsa.opt_fill(fftsa.flo, fftsa.fhi, fftsa.range, fftsa.win_i, fftsa.kbeta_i, fftsa.n)
  display.changescreen(fftsa.optscr)
  return true
end

-- The shipped settings back into the form, and nothing else: Apply commits them and Cancel
-- abandons them, like every other control here, so a mis-press costs a press. Acquisition is
-- untouched until Apply, which is what keeps this off the 2.667 s commit a changed sample
-- count would otherwise charge for a button nobody meant to hit.
function fftsa.options_reset()
  if fftsa.optscr == nil then return false end
  local d = fftsa.defaults
  fftsa.opt_fill(d.flo, d.fhi, d.range, d.win_i, d.kbeta_i, d.n)
  return true
end

-- The form's span: read the two fields, then clamp through fftsa.span_clamp, which is also
-- where a graph gesture lands. A field the object pool refused reads as nil through
-- getval's fallback, and a value the form cannot produce is not a span -- either keeps what
-- is in force rather than being clamped into something.
function fftsa.options_span()
  local nlo, nhi = fftsa.flo, fftsa.fhi
  local lo = fftsa.getval(fftsa.opt_flo, fftsa.flo)
  local hi = fftsa.getval(fftsa.opt_fhi, fftsa.fhi)
  if hi ~= nil and hi > 0 then nhi = hi end
  if lo ~= nil and lo >= 0 then nlo = lo end
  return fftsa.span_clamp(nlo, nhi)
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
  -- A failure with the count changed leaves the FFT tables and the capture buffer possibly
  -- sized apart, which is what halted above guards -- but leaving it set is an app that
  -- never draws again and that only another Apply can revive. So the count goes back and
  -- apply() runs once more on the pair that was in force a moment ago. Frames resume if
  -- that works. The Apply is still reported as failed, because the setting asked for did
  -- not take, and fftsa.n now holds what did, so the form reopens on it.
  if not ok and fftsa.n ~= nold then
    fftsa.n = nold
    if pcall(function() fftsa.apply() end) then
      err = tostring(err) .. "  [kept " .. tostring(nold) .. " samples]"
      fftsa.halted, fftsa.errrun = false, 0
      if mkchanged then fftsa.sg_bind() end
    end
  end
  fftsa.show_main()
  if not ok then
    fftsa.lasterr = tostring(err)
    fftsa.say("APPLY FAILED: " .. tostring(err))
  else
    fftsa.halted, fftsa.errrun = false, 0
    -- Apply supersedes a gesture waiting to be re-planned: it has just re-planned from
    -- the same fftsa.flo/fhi, so leaving the flag set buys a second, identical apply on
    -- the next frame.
    fftsa.retune_pending = false
    if mkchanged then fftsa.sg_bind() end
    -- Through the guarded writer, like the two inside apply(): this one is past every
    -- commit, so a raise building the text would report a failed Apply that had in fact
    -- succeeded -- and it is outside the pcall above, so it would escape options_apply
    -- altogether and take the button handler with it.
    fftsa.sg_write_xunit()
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

-- The icon goes before the settle, so a settle that fails cannot leave the padlock showing
-- the opposite of fftsa.sg_lock for the rest of the session. Locking settles at once rather
-- than at the next tick, which is also the only settle a halted app gets; unlocking settles
-- nothing, because a free view is exactly what the press asked for.
function fftsa.toggle_lock()
  fftsa.sg_lock = not fftsa.sg_lock
  fftsa.lock_icon()
  if fftsa.sg_lock then fftsa.sg_settle() end
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
  -- The count the live timer was armed for, so fftsa.apply() can tell a press that needs a
  -- new period from one that does not.
  fftsa.armed_n = fftsa.n
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
  -- THE PLAN GOES WITH THE APP. Natively it is one arena, and the app is relaunchable --
  -- every module opens with `fftsa = fftsa or {}` and fftsa.start() opens with this -- so an
  -- arena nobody releases is leaked per launch for the rest of the power cycle, which is the
  -- failure class this app is already careful about for buffers and for the 463-object
  -- display pool. Under pcall for the same reason sg_destroy is: a stop that raises leaves
  -- the rest of the teardown undone.
  --
  -- The cost is that the next launch rebuilds the tables, 0.163 ms a sample. It is paid
  -- behind the loading cover, start() running apply() before it switches away.
  pcall(function() dsp.release() end)
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
  -- The pending re-plan goes with the app. Two stops under one frame reach the teardown
  -- from the second call, which clears stop_pending -- and fftsa.frame() then finds the flag
  -- set with nothing left to retune, where apply() strands a fresh capture buffer on a
  -- screen that is already gone. This is also what keeps a gesture from the previous launch
  -- off the next one's first frame, fftsa.start() opening with a stop().
  fftsa.busy, fftsa.halted, fftsa.errrun = false, false, 0
  fftsa.retune_pending, fftsa.armed_n = false, nil
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
