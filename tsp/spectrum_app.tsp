-- Instrument app: acquisition, FFT frames, settings and screen lifecycle.

fftsa = fftsa or {}

-- Match the archive manifest so on-device reports identify the installed build.
fftsa.VERSION = '9.58'

-- Prefer native DSP. Install the Lua DSP interface only when firmware provides none.
fftsa.dsp_native = (dsp ~= nil and dsp.version ~= nil and dsp.version >= 1)
if not fftsa.dsp_native then
  if type(fftsa.dsp_install) == 'function' then
    fftsa.dsp_install()
    fftsa.dsp_native = (dsp ~= nil and dsp.version ~= nil and dsp.version >= 1)
  else
    fftsa.dsp_absent = true
  end
end

-- Map the picker separately to the firmware and native DSP enums.
fftsa.win_dsp = {}
if not fftsa.dsp_absent then
  fftsa.win_dsp[1] = dsp.WINDOW_HANN
  fftsa.win_dsp[2] = dsp.WINDOW_BLACKMAN
  fftsa.win_dsp[3] = dsp.WINDOW_BLACKMAN_HARRIS
  fftsa.win_dsp[4] = dsp.WINDOW_KAISER
end

function fftsa.win_to_dsp(wi)
  local k = fftsa.win_dsp[wi or fftsa.win_i]
  if k == nil then k = fftsa.win_dsp[1] end
  return k
end

fftsa.thd_hmax_want  = 20              -- harmonics counted; the window top usually stops first
fftsa.thd_bins_want  = 1024            -- bins sampled for the floor; 0 means every bin
fftsa.thd_mains_want = -1              -- hum discounted at 50 and at 60 Hz
if not fftsa.dsp_absent and dsp.MAINS_BOTH ~= nil then
  fftsa.thd_mains_want = dsp.MAINS_BOTH
end

function fftsa.dsp_why(what, code)
  local msg = tostring(what) .. " refused (" .. tostring(code) .. ")"
  local e = dsp.lastevent()
  if e ~= nil and e.why ~= nil and e.code == code then
    msg = msg .. ": " .. tostring(e.why)
  end
  return msg
end

fftsa.n          = 1024
fftsa.n_compiled = 2048
fftsa.sample_counts = {1024, 2048, 4096, 8192, 16384, 32768}
fftsa.sample_labels = {"1024", "2048", "4096", "8192", "16384", "32768"}

-- Native startup needs the embedded image, its layout metadata and the firmware memory API.
function fftsa.native_likely()
  local nl = fftsa.nl
  if nl == nil then return false end
  if nl.SIZEOF_REAL == nil or nl.SIZEOF_REAL == 0 then return false end
  if nl._DSP_CODE_B64 == nil or nl._DSP_CODE_B64_LEN == 0 then return false end
  if ki == nil or ki.memwrite == nil or ki.poke32 == nil then return false end
  return true
end

-- Exclude DC, which is not a spectral peak after mean removal.
fftsa.flomin  = 10
fftsa.flo     = 10
fftsa.fhi     = 50000
fftsa.fhi_max = 500000
fftsa.fhi_min = 500  -- minimum stop frequency (Hz)
fftsa.flo_max = fftsa.fhi_max - 1000
fftsa.range   = 10          -- digitizer input range (V): 0.1 / 1 / 10
fftsa.fs      = 100000      -- sample rate (picked from fftsa.fhi, then measured)
fftsa.binhz   = 0           -- true bin width, from measured fs
fftsa.binhz_pin = nil
-- Hold bin width through timestamp jitter to avoid repinning the X axis.
fftsa.BINHZ_REPIN = 1e-3
fftsa.busy    = false       -- reentrancy guard (never preserved across a reload)
fftsa.stop_pending = false  -- a teardown deferred until the running frame ends
fftsa.retune_pending = false -- a gesture's span, waiting for its re-plan between frames
fftsa.halted  = false       -- frames suppressed after repeated failures
fftsa.lasterr = nil
fftsa.errcount = 0
fftsa.errrun  = 0
fftsa.errmax  = 20          -- give up (and say so) after this many in a row
fftsa.shortreads = 0        -- captures rejected for returning fewer than n samples

-- Reset uses the same settings as startup.
fftsa.defaults = {flo = fftsa.flo, fhi = fftsa.fhi, range = fftsa.range,
                  win_i = fftsa.win_i, kbeta_i = fftsa.kbeta_i, n = fftsa.n}

-- Apply and unlocked gestures share the same limits in whole hertz.
function fftsa.span_clamp(lo, hi)
  local nlo, nhi = lo, hi
  -- Replace NaN before clamping the limits.
  if nlo ~= nlo then nlo = fftsa.flomin end
  if nhi ~= nhi then nhi = fftsa.fhi_min end
  if nhi > fftsa.fhi_max then nhi = fftsa.fhi_max end
  if nhi < fftsa.fhi_min then nhi = fftsa.fhi_min end
  if nlo < fftsa.flomin then nlo = fftsa.flomin end
  if nlo > fftsa.flo_max then nlo = fftsa.flo_max end
  if nlo >= nhi then nlo = fftsa.flomin end
  return nlo, nhi
end

-- Preserve live display handles when the script is loaded again during the same boot.
if fftsa.handles_inited == nil then
  fftsa.cap      = nil
  fftsa.cap_cap  = nil      -- readings it was made for
  fftsa.optbtn   = nil
  fftsa.optimg   = nil
  fftsa.lockbtn  = nil
  fftsa.lockimg_c = nil
  fftsa.lockimg_o = nil     -- open-padlock image over it; one of the pair is visible
  fftsa.timer    = nil
  fftsa.errscr   = nil
  fftsa.optscr   = nil
  fftsa.opt_flo  = nil
  fftsa.opt_fhi  = nil
  fftsa.opt_rng  = nil
  fftsa.opt_win  = nil
  fftsa.opt_beta = nil
  fftsa.opt_n    = nil
  fftsa.opt_info = nil
  fftsa.handles_inited = true
end

-- Pick the slowest acquisition rate whose Nyquist covers the stop frequency.
fftsa.rates    = {12500, 25000, 50000, 100000, 200000, 500000, 1000000}
fftsa.rate_fhi = { 5000, 12000, 25000,  50000, 100000, 250000,  500000}
fftsa.fs_min   = fftsa.rates[1]

function fftsa.pick_fs(fhi)
  local r = fftsa.rates
  local n = table.getn(r)
  for i = 1, n do
    if fftsa.rate_fhi[i] >= fhi then return r[i] end
  end
  return r[n]
end

-- Replan on a rate change even when the FFT length stays fixed.
function fftsa.plan_changed(fhi_new)
  return fftsa.pick_fs(fhi_new) ~= fftsa.pick_fs(fftsa.fhi)
end

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

-- EDIT_OPTION can return either a one-based index or the option label.
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

-- Infer the rate from capture timestamps; fall back to the requested acquisition rate.
function fftsa.measure_fs(buf)
  local back = fftsa.fs_acq or fftsa.fs
  local n = buf.n
  if n < 4 then return back end
  local t1, tN = buf.relativetimestamps[1], buf.relativetimestamps[n]
  if tN <= t1 then return back end
  return (n - 1) / (tN - t1)
end

-- Change the held bin width only when the measured rate moves past the tolerance.
function fftsa.binhz_hold(cap)
  local b = fftsa.measure_fs(cap) / fftsa.n
  local pin = fftsa.binhz_pin
  if pin == nil or pin <= 0 or b <= 0 then
    fftsa.binhz_pin = b
    return b
  end
  local d = b - pin
  if d < 0 then d = -d end
  if d > pin * fftsa.BINHZ_REPIN then
    fftsa.binhz_pin = b
    fftsa.binhz_repins = (fftsa.binhz_repins or 0) + 1
    return b
  end
  return pin
end

-- Clamp frame-time settings to the allocated display and DSP capacities.
function fftsa.dsp_live()
  local ncol = fftsa.sg_ncol
  local cap = nil
  if fftsa.sg_buf ~= nil then cap = fftsa.sg_points_max() end
  if cap ~= nil and ncol ~= nil and ncol > cap then ncol = cap end
  if ncol == nil or ncol < 2 then ncol = 2 end
  fftsa.live_ncol = ncol
  local npk = fftsa.sg_npeak
  local rows = nil
  if fftsa.sg_pk_f ~= nil then rows = table.getn(fftsa.sg_pk_f) end
  if rows ~= nil and rows > 0 and npk > rows then npk = rows end
  if npk == nil or npk < 1 then npk = 1 end
  fftsa.live_npk = npk
  return npk
end

function fftsa.dsp_live_push()
  dsp.out.segments = fftsa.live_ncol
  dsp.out.dbfloor = fftsa.sg_dbmin
  dsp.out.dbceil  = fftsa.sg_dbmax
  dsp.out.vfloor  = fftsa.sg_vfloor
  dsp.peaks.count = fftsa.live_npk
  dsp.thd.harmonics = fftsa.thd_hmax_want
  dsp.thd.bins      = fftsa.thd_bins_want
  dsp.thd.mains     = fftsa.thd_mains_want
end

-- The archive has no interpreted FFT. Report why native DSP is unavailable.
function fftsa.spectrum_interp(cap, buf)
  if fftsa.fft_init == nil or dsp.spectrum == nil then
    if not fftsa.halted then
      fftsa.lasterr = 'the compiled DSP stopped and this archive has no interpreted fallback'
      fftsa.halt('HALTED ' .. tostring(fftsa.nl_lasterr))
    end
    return nil
  end
  fftsa.dsp_live_push()
  fftsa.dsp_window()
  return dsp.spectrum(cap, buf, nil)
end

function fftsa.dsp_window()
  local lo, hi = fftsa.sg_flo_hz, fftsa.sg_fhi_hz
  if lo == nil or hi == nil or not (hi > lo) then return false end
  dsp.out.lowfreq  = lo
  dsp.out.highfreq = hi
  return true
end

-- Size the native arena once for the largest FFT the app offers.
fftsa.nl_nmax = 32768

fftsa.cap_floor_n = fftsa.nl_nmax
fftsa.cap_cap_mult = 2       -- capacity is twice the longest record

fftsa.nl_enable = true

function fftsa.mains_native(v)
  if v == 50 or v == 60 or v == 0 then return v end
  return fftsa.nl.MAINS_BOTH
end

-- Resolve capture storage at Apply, not in the frame; discovery can sweep memory.
function fftsa.nl_call(name, arg, dflt)
  local nl = fftsa.nl
  if nl == nil or type(nl[name]) ~= 'function' then return dflt end
  local v = nl[name](arg)
  if v == nil then return dflt end
  return v
end

function fftsa.nl_bind()
  local nl = fftsa.nl
  if nl == nil or not nl.ready or fftsa.cap == nil or fftsa.sg_buf == nil then
    fftsa.nl_cap = nil
    fftsa.nl_lasterr = 'bind: ready=' .. tostring(nl ~= nil and nl.ready)
                       .. ' cap=' .. tostring(fftsa.cap ~= nil)
                       .. ' trace=' .. tostring(fftsa.sg_buf ~= nil)
    return false
  end
  fftsa.nl_cap, fftsa.nl_cap_of = nil, nil
  local c = nl.describe(fftsa.cap, false)
  if c == nil then
    fftsa.nl_lasterr = 'bind: describe found no descriptor for the capture buffer -- '
                       .. tostring(nl._stor_why) .. ' raw=' .. tostring(nl._raw_n)
                       .. ' hits=' .. tostring(nl._hit_n)
                       .. ' inst=' .. string.format('%X', nl.inst or 0)
                       .. ' ' .. fftsa.nl_call('windows_str', nil, 'windows=?')
    return false
  end
  fftsa.nl_cap, fftsa.nl_cap_of = c, fftsa.cap
  -- Warm both descriptor cache entries before the first native frame.
  if type(nl.stash) == 'function' then nl.stash() end
  return true
end

function fftsa.nl_usable()
  if not fftsa.nl_enable then return false end
  local nl = fftsa.nl
  if nl == nil or not nl.ready then return false end
  if nl.n ~= fftsa.n then return false end
  return fftsa.nl_cap ~= nil
end

function fftsa.nl_reduction(binhz)
  local r = fftsa.nl_redt
  if r == nil then r = {}; fftsa.nl_redt = r end
  local kmin, kmax = fftsa.sg_window_bins(fftsa.sg_nbins, binhz,
                                          fftsa.sg_flo_hz, fftsa.sg_fhi_hz)
  -- The graph helper returns one-based bounds; the native reducer takes zero-based bins.
  r.k0, r.k1 = kmin - 1, kmax - 1
  r.nseg   = fftsa.live_ncol
  r.npk    = fftsa.live_npk
  r.binhz  = binhz
  r.f0     = 0
  r.sense  = 1
  r.dbmin  = fftsa.sg_dbmin
  r.dbmax  = fftsa.sg_dbmax
  r.vfloor = fftsa.sg_vfloor
  r.mains  = fftsa.mains_native(fftsa.thd_mains_want)
  return r
end

-- Commit the settings to DSP, acquisition, and the graph in that order.
function fftsa.apply()
  -- fs_acq is the requested digitizer rate; fs is the rate seen by the transform.
  fftsa.fs_acq = fftsa.pick_fs(fftsa.fhi)
  dsp.fft.samples    = fftsa.n
  dsp.fft.window     = fftsa.win_to_dsp(fftsa.win_i)
  dsp.fft.beta       = fftsa.kbeta(fftsa.kbeta_i)
  dsp.fft.samplerate = fftsa.fs_acq
  -- Set filter OFF explicitly, even when using a firmware DSP implementation.
  dsp.filter.state = dsp.OFF
  -- Use the requested span here; the stored graph limits are updated after commit.
  dsp.out.lowfreq  = fftsa.flo
  dsp.out.highfreq = fftsa.fhi
  if fftsa.sg_dbmin_set(fftsa.range) then fftsa.sg_pin_y() end
  fftsa.dsp_live()
  -- Set plan attributes before commit; frame attributes can be written later.
  fftsa.dsp_live_push()
  local rc = dsp.commit()
  if rc ~= dsp.OK then error(fftsa.dsp_why("commit", rc), 0) end
  local need = dsp.fft.srclength
  fftsa.fs = fftsa.fs_acq
  fftsa.sg_nbins = fftsa.n / 2
  -- Set the digitizer function before accessing its settings, even at startup.
  trigger.model.abort()
  dmm.digitize.func       = dmm.FUNC_DIGITIZE_VOLTAGE
  dmm.digitize.range      = fftsa.range
  dmm.digitize.samplerate = fftsa.fs_acq
  fftsa.binhz = fftsa.fs / fftsa.n
  fftsa.sg_set_xrange(fftsa.flo, fftsa.fhi)
  dmm.digitize.aperture   = 1e-6
  -- The DSP supplies the required capture length; the FFT length need not equal it.
  dmm.digitize.count      = need
  -- Allocate for the largest supported capture so normal Apply operations reuse the buffer.
  local want = need
  if want < fftsa.cap_floor_n then want = fftsa.cap_floor_n end
  want = want * fftsa.cap_cap_mult
  if fftsa.cap ~= nil and (fftsa.cap_cap == nil or fftsa.cap_cap < want) then
    fftsa.del_buf(fftsa.cap)
    fftsa.cap = nil
  end
  if fftsa.cap == nil then
    fftsa.cap     = buffer.make(want, buffer.STYLE_STANDARD)
    fftsa.cap_cap = want
  end
  fftsa.cap.clear()
  dmm.digitize.read(fftsa.cap)
  -- Use capture timestamps rather than the samplerate readback.
  fftsa.fs_acq = fftsa.measure_fs(fftsa.cap)
  fftsa.fs     = fftsa.fs_acq
  fftsa.binhz  = fftsa.fs / fftsa.n
  fftsa.binhz_pin = fftsa.binhz
  -- Allow the busy guard enough time for the configured acquisition and transform.
  fftsa.busy_max = math.max(2.0, 3.0 * fftsa.frame_estimate(fftsa.n))
  fftsa.work_peak, fftsa.work_seen, fftsa.plain_peak = nil, 0, nil
  -- Reset worst-case diagnostics when the plan changes so they describe that plan.
  fftsa.ph_peak = {}
  fftsa.work_plain, fftsa.work_tick = nil, nil
  fftsa.fps, fftsa.fps_n, fftsa.fps_t0 = nil, 0, nil
  -- Only re-arm the modelled timer when the FFT count changes.
  if fftsa.timer ~= nil and fftsa.armed_n ~= fftsa.n then
    fftsa.period = fftsa.frame_period(fftsa.n)
    fftsa.arm(fftsa.period)
    fftsa.period_modelled = true
  end
  fftsa.sg_pk_last, fftsa.sg_pk_lf, fftsa.sg_pk_lv = nil, {}, {}
  -- Replan the native transform for the committed window, beta and sample count.
  fftsa.nl_replan()
  fftsa.sg_write_xunit()
end

function fftsa.nl_replan()
  local nl = fftsa.nl
  if nl == nil or type(nl.reinit) ~= 'function' then return false end
  if nl.entry == nil or nl.entry == 0 then return false end
  if nl.nmax == nil or fftsa.n > nl.nmax then
    -- Preserve capture and trace descriptors when only the plan changes.
    nl.ready = false
    return false
  end
  local ok = nl.reinit(fftsa.n, nl.win_to_native(fftsa.win_i),
                       fftsa.kbeta(fftsa.kbeta_i), 1, nl.FFT_FOURSTEP)
  if not ok then
    fftsa.nl_lasterr = 'reinit refused rc='
                       .. fftsa.nl_call('rc_name', nl.last_rc, tostring(nl.last_rc))
                       .. ' at n=' .. tostring(fftsa.n)
    return false
  end
  return fftsa.nl_bind()
end

function fftsa.dsp_peaks(count)
  if fftsa.pk_hz == nil then fftsa.pk_hz, fftsa.pk_v = {}, {} end
  local hz, v = fftsa.pk_hz, fftsa.pk_v
  local i
  -- Native peaks are already in the result block; do not ask the DSP again.
  if fftsa.nl_frame then
    local res = fftsa.nl_results()
    for i = 1, count do
      if res == nil then hz[i], v[i] = nil, nil
      else hz[i], v[i] = res.hz[i], res.v[i] end
    end
    return hz, v
  end
  if dsp.peak == nil then
    for i = 1, count do hz[i], v[i] = nil, nil end
    return hz, v
  end
  for i = 1, count do
    hz[i], v[i] = dsp.peak(i)
  end
  return hz, v
end

-- Distortion results follow the implementation that produced the frame.
function fftsa.nl_results()
  if not fftsa.nl_frame then return nil end
  if not fftsa.nl_res_done then
    fftsa.nl_res_done = true
    fftsa.nl_res = fftsa.nl.results()
  end
  return fftsa.nl_res
end

function fftsa.distortion()
  if fftsa.nl_frame then
    local res = fftsa.nl_results()
    if res == nil then return nil, nil, nil end
    return res.thd, res.snr, res.noise
  end
  if dsp.distortion == nil then return nil, nil, nil end
  return dsp.distortion()
end

-- THD formatting uses the size of the completed transform, not the pending selection.
function fftsa.plan_n()
  if fftsa.nl_frame then return fftsa.n end
  return dsp.fft.samples
end

-- Exit if the physical FUNCTION key changes the meter mode.
function fftsa.exit_if_function_changed()
  if dmm.digitize.func == dmm.FUNC_DIGITIZE_VOLTAGE then return false end
  fftsa.cleanup()  -- deferred to the frame boundary if a frame is in flight
  return true
end

function fftsa.frame_body()
  -- A late timer event can arrive during startup or after teardown.
  if fftsa.cap == nil or fftsa.sg_buf == nil or fftsa.sg_graph == nil
     or fftsa.sg_pk_f == nil then
    return
  end
  if fftsa.exit_if_function_changed() then return end
  -- FFTSA_FREEZE leaves the display undisturbed after one complete frame.
  if FFTSA_FREEZE and fftsa.froze then return end
  -- Poll before long acquisition so a queued press is not held behind another capture.
  local acq = 0
  if fftsa.fs ~= nil and fftsa.fs > 0 then acq = fftsa.n / fftsa.fs end
  if acq > fftsa.press_poll_above and fftsa.press_poll() then return end
  local t_a = os.clock()
  fftsa.cap.clear()
  dmm.digitize.read(fftsa.cap)
  -- Discard a capture if the measurement function changed while it was in flight.
  if fftsa.exit_if_function_changed() then return end
  fftsa.overrange = fftsa.cap_overrange(fftsa.cap)
  local t_b = os.clock()
  local npk = fftsa.dsp_live()
  -- Native DSP reduces in place; Lua coordinates graph writes with the display task.
  local nseg
  fftsa.nl_frame = false
  -- Reuse one results-block read across consumers, even if that read failed.
  fftsa.nl_res, fftsa.nl_res_done = nil, false
  local native = fftsa.nl_usable()
  -- Reject empty captures before treating startindex as a ring offset.
  if native and (fftsa.cap.n == nil or fftsa.cap.n < fftsa.n) then
    fftsa.nl_shortreads = (fftsa.nl_shortreads or 0) + 1
    fftsa.shortreads = fftsa.nl_shortreads
    return
  end
  -- A wrapped buffer is in physical slot order; advance the start to the requested record.
  if native and fftsa.cap.startindex ~= nil and fftsa.cap.startindex ~= 1 then
    fftsa.nl_rotated = (fftsa.nl_rotated or 0) + 1
    native = false
  end
  if native then
    local binhz = fftsa.binhz_hold(fftsa.cap)
    nseg = fftsa.nl.call_dsp(fftsa.nl_cap, nil, fftsa.nl_reduction(binhz))
    if nseg == nil then
      -- Disable native DSP for the session rather than retrying a runtime refusal every frame.
      fftsa.nl.ready = false
      fftsa.nl_lasterr = 'call_dsp rc='
                         .. fftsa.nl_call('rc_name', fftsa.nl.last_rc,
                                          tostring(fftsa.nl.last_rc))
      nseg = fftsa.spectrum_interp(fftsa.cap, fftsa.sg_buf)
    else
      -- The append path needs Hz and dB; an engaged native pixel writer can consume dB in place.
      local rd = fftsa.nl.reduce(nseg, false)
      if rd == nil then
        fftsa.nl.ready = false
        fftsa.nl_lasterr = 'reduce returned nil for nseg=' .. tostring(nseg)
        nseg = fftsa.spectrum_interp(fftsa.cap, fftsa.sg_buf)
      else
        fftsa.binhz = binhz
        fftsa.nl_frame = true
        -- Defer the results block until a consumer needs it; the trace does not depend on it.
        if fftsa.sg_fill(rd.db, rd.hz, nseg) == 0 then nseg = 0 end
      end
    end
  else
    nseg = fftsa.spectrum_interp(fftsa.cap, fftsa.sg_buf)
  end
  if nseg == nil or nseg < 0 then error(fftsa.dsp_why("spectrum", nseg), 0) end
  if nseg == 0 then
    if not fftsa.nl_frame then fftsa.shortreads = dsp.shortreads end
    return
  end
  -- Both paths plot with the bin width used for this frame's transform.
  if not fftsa.nl_frame then
    fftsa.binhz = dsp.fft.binwidth
  end
  fftsa.sg_nwrote = nseg
  local t_c = os.clock()
  local pk_hz, pk_v = fftsa.dsp_peaks(npk)
  fftsa.sg_update_markers(nil, nil, npk, fftsa.binhz, pk_hz, pk_v)
  local t_d = os.clock()
  -- Display updates outside the trace write window can yield independently.
  local sg_ran, sg_heavy = fftsa.sg_slow_tick()
  fftsa.ph_tick = sg_heavy
  local t_e = os.clock()
  delay(fftsa.sg_yield)
  local t_f = os.clock()
  if fftsa.overrange then
    fftsa.sg_show_peaks_over()
  else
    fftsa.sg_show_peaks(nil, nil, npk, fftsa.binhz, pk_hz, pk_v)
  end
  local ph, pk = fftsa.ph, fftsa.ph_peak
  ph.acq  = t_b - t_a
  -- Separate acquisition timing by the previous frame's display work.
  if fftsa.acq_for ~= fftsa.n then
    fftsa.acq_for = fftsa.n
    fftsa.acq_after_tick, fftsa.acq_after_plain = nil, nil
    fftsa.acq_tick_n, fftsa.acq_tick_s = 0, 0
    fftsa.acq_plain_n, fftsa.acq_plain_s = 0, 0
  end
  if fftsa.prev_tick then
    if fftsa.acq_after_tick == nil or ph.acq > fftsa.acq_after_tick then
      fftsa.acq_after_tick = ph.acq
    end
    fftsa.acq_tick_n = (fftsa.acq_tick_n or 0) + 1
    fftsa.acq_tick_s = (fftsa.acq_tick_s or 0) + ph.acq
  else
    if fftsa.acq_after_plain == nil or ph.acq > fftsa.acq_after_plain then
      fftsa.acq_after_plain = ph.acq
    end
    fftsa.acq_plain_n = (fftsa.acq_plain_n or 0) + 1
    fftsa.acq_plain_s = (fftsa.acq_plain_s or 0) + ph.acq
  end
  ph.spec = t_c - t_b
  ph.mark = t_d - t_c
  ph.tick = t_e - t_d
  ph.yld  = t_f - t_e
  ph.show = os.clock() - t_f
  local k, v
  for k, v in pairs(ph) do
    if pk[k] == nil or v > pk[k] then pk[k] = v end
  end
  fftsa.froze = true
  fftsa.prev_tick = fftsa.ph_tick
end

function fftsa.phases()
  local ph, pk = fftsa.ph, fftsa.ph_peak
  local names = {'acq', 'spec', 'mark', 'tick', 'yld', 'show'}
  local out, i = '', nil
  for i = 1, table.getn(names) do
    local k = names[i]
    out = out .. string.format('%s %.1f/%.1f  ', k, 1000 * (ph[k] or 0),
                               1000 * (pk[k] or 0))
  end
  return string.format('%sframe %.1f  plain %.1f  tick %.1f', out,
                       1000 * (fftsa.frame_work or 0),
                       1000 * (fftsa.work_plain or 0), 1000 * (fftsa.work_tick or 0))
end

-- Guard timer reentry and release the guard even if the frame raises.
fftsa.busy_since = nil
fftsa.busy_max   = 2.0      -- seconds a guard may be held before it is judged stuck

-- Estimate the initial frame period from acquisition and DSP cost until measured work is available.
function fftsa.frame_estimate(n, fs)
  if n == nil or n < 2 then n = 512 end
  local est = 0.05
  if dsp.fft.samples == n then
    local t = dsp.fft.spectrumtime
    if type(t) == "number" and t > 0 then est = t end
  end
  -- Acquisition time is a lower bound on frame duration.
  if type(fs) ~= "number" or fs <= 0 then fs = fftsa.fs_acq or fftsa.fs or fftsa.fs_min end
  local acq = n / fs
  if est < acq then est = acq end
  return est
end
fftsa.busy_stuck = 0        -- how many times the guard had to be broken

fftsa.fps_window = 1.0      -- seconds a measurement spans
fftsa.fps        = nil      -- frames a second, nil until the first window closes
fftsa.fps_n      = 0        -- frames counted in the window
fftsa.fps_t0     = nil      -- when the window opened
fftsa.fps_show   = false    -- a fresh figure is waiting for the line

fftsa.ph       = {}
fftsa.ph_peak  = {}
fftsa.ph_tick  = false      -- the one-a-second display block ran in the last frame
fftsa.work_plain = nil
fftsa.work_tick  = nil
-- Keep a separate peak for frames without periodic UI work; it drives pacing.
fftsa.plain_peak = nil
fftsa.period_modelled = false

function fftsa.frame()
  if fftsa.halted then return end
  if fftsa.busy then
    local since = fftsa.busy_since
    if since == nil or (os.clock() - since) < (fftsa.busy_max or 2.0) then return end
    fftsa.busy_stuck = (fftsa.busy_stuck or 0) + 1
  end
  fftsa.busy_since = os.clock()
  fftsa.busy = true
  local entry = os.clock()
  local ok, err = pcall(fftsa.frame_body)
  if fftsa.stop_pending then
    fftsa.busy = false
    fftsa.stop()
    return
  end
  fftsa.frame_work = os.clock() - entry
  -- Record the actual interval between delivered frames independently of the timer period.
  if fftsa.last_entry ~= nil then
    local gap = entry - fftsa.last_entry
    if fftsa.gap_peak == nil or gap > fftsa.gap_peak then fftsa.gap_peak = gap end
    fftsa.gap_last = gap
  end
  fftsa.last_entry = entry
  fftsa.fps_n = (fftsa.fps_n or 0) + 1
  if fftsa.fps_t0 == nil then fftsa.fps_t0 = entry end
  local span = os.clock() - fftsa.fps_t0
  if span >= fftsa.fps_window then
    fftsa.fps = fftsa.fps_n / span
    fftsa.fps_n, fftsa.fps_t0 = 0, os.clock()
    fftsa.fps_show = true
    -- Keep per-size timing in a boot-scoped diagnostic table.
    if FFTSA_CENSUS == nil then FFTSA_CENSUS = {} end
    local ph = fftsa.ph
    -- Record both the requested period and the period the controller actually armed.
    FFTSA_CENSUS[fftsa.n] = string.format(
      'per=%.3f fps=%.2f gap=%.1f d=%.1f from=%.1f want=%.1f wp=%.1f wt=%.1f'
      .. ' acq=%.1f spec=%.1f mark=%.1f yld=%.1f show=%.1f nl=%s',
      fftsa.period or 0, fftsa.fps or 0, 1000 * (fftsa.gap_peak or 0),
      1000 * (fftsa.gap_last or 0), 1000 * (fftsa.armed_from or 0),
      1000 * (fftsa.armed_want or 0),
      1000 * (fftsa.work_plain or 0), 1000 * (fftsa.work_tick or 0),
      1000 * (ph.acq or 0), 1000 * (ph.spec or 0), 1000 * (ph.mark or 0),
      1000 * (ph.yld or 0), 1000 * (ph.show or 0),
      tostring(fftsa.nl_frame))
    local pn, tn = fftsa.acq_plain_n or 0, fftsa.acq_tick_n or 0
    FFTSA_ACQ = string.format(
      'n=%d after-plain mean=%.1f peak=%.1f (%d) | after-tick mean=%.1f peak=%.1f (%d)',
      fftsa.n,
      1000 * (pn > 0 and (fftsa.acq_plain_s / pn) or 0),
      1000 * (fftsa.acq_after_plain or 0), pn,
      1000 * (tn > 0 and (fftsa.acq_tick_s / tn) or 0),
      1000 * (fftsa.acq_after_tick or 0), tn)
  end
  -- Re-arm from measured frame work, not the model.
  if ok then
    if fftsa.work_peak == nil or fftsa.frame_work > fftsa.work_peak then
      fftsa.work_peak = fftsa.frame_work
    end
    if fftsa.ph_tick then
      if fftsa.work_tick == nil or fftsa.frame_work > fftsa.work_tick then
        fftsa.work_tick = fftsa.frame_work
      end
    else
      if fftsa.work_plain == nil or fftsa.frame_work > fftsa.work_plain then
        fftsa.work_plain = fftsa.frame_work
      end
      if fftsa.plain_peak == nil or fftsa.frame_work > fftsa.plain_peak then
        fftsa.plain_peak = fftsa.frame_work
      end
    end
    fftsa.work_seen = (fftsa.work_seen or 0) + 1
    -- Keep the frame count monotonic for Options latency diagnostics.
    fftsa.nframes = (fftsa.nframes or 0) + 1
    -- Use one frame to replace a modelled period, then eight-frame measurement windows.
    local win = 8
    if fftsa.period_modelled then win = 1 end
    if fftsa.work_seen >= win and fftsa.timer ~= nil then
      -- Pace from the worst plain frame; include UI work only until a plain frame is available.
      local want = fftsa.tick_period(fftsa.plain_peak or fftsa.work_peak)
      -- Use a one-grid-step fall and a wider rise threshold to avoid timer churn.
      -- Do not pace from the delivered gap: re-arming itself delays the next frame.
      local move = want - (fftsa.period or 0)
      local need = fftsa.tick_rise
      if move < 0 then
        move, need = -move, fftsa.tick_grid_now()
      end
      -- The first measured period bypasses the deadband.
      if fftsa.period_modelled then need = 0 end
      -- The deadband cannot hold a period below measured work plus dispatch slack.
      local peak = fftsa.plain_peak or fftsa.work_peak
      if peak ~= nil and fftsa.period ~= nil
         and fftsa.period < peak + fftsa.tick_floor then
        need = 0
      end
      -- Save the controller inputs before resetting the measurement window.
      fftsa.armed_from = fftsa.plain_peak or fftsa.work_peak
      fftsa.armed_want = want
      -- Allow rounding error when comparing differences of decimal grid multiples.
      if fftsa.period == nil or move >= need - 1e-5 then
        fftsa.period = want
        fftsa.arm(want)
      end
      fftsa.period_modelled = false
      -- Reset the peaks each window so pacing can follow a decrease in work.
      fftsa.work_peak = fftsa.frame_work
      fftsa.plain_peak = nil
      if not fftsa.ph_tick then fftsa.plain_peak = fftsa.frame_work end
      fftsa.gap_peak = nil
      fftsa.work_seen = 0
    end
  end
  if not ok then
    -- Rebind the graph after a failed write so the next frame has a trace.
    if fftsa.errrun == 0 and fftsa.sg_graph ~= nil and fftsa.sg_buf ~= nil
       and fftsa.sg_buf.n > 0 then
      fftsa.sg_rebind()
    end
    fftsa.lasterr  = tostring(err)
    fftsa.errcount = (fftsa.errcount or 0) + 1
    fftsa.errrun   = (fftsa.errrun or 0) + 1
    -- Stop retrying after consecutive failures and expose the diagnostic on screen.
    if fftsa.errrun >= (fftsa.errmax or 20) then
      fftsa.halt("HALTED after " .. fftsa.errrun .. " frames: " ..
                 string.sub(tostring(fftsa.lasterr), 1, 40))
    end
  else
    fftsa.errrun = 0
  end
  if fftsa.fps_show and not fftsa.halted then
    fftsa.fps_show = false
    fftsa.sg_write_xunit()
  end
  -- Apply an unlocked gesture between frames, not inside the scale callback.
  if fftsa.retune_pending and not fftsa.stop_pending and not fftsa.halted
     and not fftsa.exit_if_function_changed() then
    fftsa.retune_pending = false
    -- Reconfigure under the loading cover with the trace paused.
    fftsa.say(string.format("retuning to %.0f - %.0f Hz", fftsa.flo, fftsa.fhi))
    fftsa.halted = true
    local rok, rerr = pcall(function() fftsa.apply() end)
    fftsa.halted = false
    if not rok then
      fftsa.lasterr = tostring(rerr)
      fftsa.say("RETUNE FAILED: " .. tostring(rerr))
      -- Restore pinned limits if Apply fails before repinning the adopted span.
      fftsa.sg_pin_x()
    end
  end
  fftsa.busy = false
  if fftsa.stop_pending then
    fftsa.stop_pending = false
    fftsa.stop()
  end
end

-- Deleting the screen frees its children; clear their Lua handles too.
function fftsa.destroy_options()
  fftsa.del_scr(fftsa.optscr, fftsa.sg_scr)
  fftsa.optscr, fftsa.opt_flo, fftsa.opt_fhi, fftsa.opt_rng, fftsa.opt_info =
    nil, nil, nil, nil, nil
  fftsa.opt_win, fftsa.opt_beta, fftsa.opt_n = nil, nil, nil
  fftsa.opt_mk = nil
  fftsa.opt_info_last = nil
  -- Clear cached event IDs along with the screen so recycled IDs can't match.
  fftsa.opt_b_apply, fftsa.opt_b_cancel = nil, nil
  fftsa.opt_b_about, fftsa.opt_b_rst, fftsa.opt_preview = nil, nil, nil
end

-- Fit six fields into two columns above the readback and buttons.
fftsa.opt_nf      = 6
fftsa.opt_cols    = 2
fftsa.opt_x       = 185
fftsa.opt_x_c2    = 552
fftsa.opt_y0      = 8
fftsa.opt_dy      = 100     -- preferred pitch; clamped to what fits
fftsa.opt_edit_h  = 50      -- box height
fftsa.opt_edit_dy = 4       -- offset of the box inside the object
fftsa.opt_y_adj   = 0       -- nudge of the centred block, negative being up
fftsa.opt_btn_y   = 360
fftsa.opt_info_y  = 323     -- readback line; its ink lands about 37 px below this
fftsa.opt_info_h  = 20      -- its height above that baseline, so the fields clear it

-- Compute row pitch from the available height, capped at the preferred pitch.
function fftsa.opt_layout()
  local nrows = math.ceil(fftsa.opt_nf / fftsa.opt_cols)
  local eh, edy = fftsa.opt_edit_h, fftsa.opt_edit_dy
  local y0, dy  = fftsa.opt_y0, fftsa.opt_dy
  local floor_y = fftsa.opt_info_y - fftsa.opt_info_h
  if nrows > 1 then
    local maxdy = math.floor((floor_y - y0 - edy - eh) / (nrows - 1))
    if dy > maxdy then dy = maxdy end
  end
  local spare = floor_y - ((nrows - 1) * dy + eh + edy) - y0
  if spare > 0 then y0 = y0 + math.floor(spare / 2) end
  if y0 + fftsa.opt_y_adj >= 0 then y0 = y0 + fftsa.opt_y_adj end
  return nrows, dy, y0
end

function fftsa.build_options()
  fftsa.destroy_options()

  local create = display.create
  -- Firmware limits screen titles to 31 characters.
  fftsa.optscr = create(display.ROOT, display.OBJ_SCREEN, "FFT ANALYSER OPTIONS")
  if fftsa.optscr == nil then
    fftsa.lasterr = "OBJPOOL exhausted building the options screen"
    return false, fftsa.lasterr
  end
  fftsa.loading_front()

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
  -- EDIT_OPTION takes its choices as positional arguments.
  local x5, y5 = nextpos()
  fftsa.opt_win = create(fftsa.optscr, display.OBJ_EDIT_OPTION, x5, y5,
                       "Window", "lobe vs sidelobe",
                       fftsa.win_names[1], fftsa.win_names[2], fftsa.win_names[3],
                       fftsa.win_names[4])
  -- Always build the beta field; changing window should not allocate display objects.
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

  fftsa.opt_info = create(fftsa.optscr, display.OBJ_TEXT, 400, fftsa.opt_info_y, "",
                        56575, display.FONT_SMALL, display.JUST_CENTER)
  -- The Options timer previews edits without applying them.
  local preview = create(fftsa.optscr, display.OBJ_TIMER, fftsa.opt_tick_period,
                         display.TIMER_FOREVER)
  fftsa.opt_preview = preview
  display.setevent(preview, display.EVENT_PRESS,
                  "if fftsa ~= nil then fftsa.guard(fftsa.opt_tick) end")

  -- Keep these object IDs so the spectrum poll can recognize queued Options events.
  local b_apply = create(fftsa.optscr, display.OBJ_BUTTON, 470, fftsa.opt_btn_y, "Apply", 140)
  fftsa.opt_b_apply = b_apply
  display.setevent(b_apply, display.EVENT_PRESS, "if fftsa ~= nil then fftsa.guard(fftsa.options_apply) end")
  local b_cancel = create(fftsa.optscr, display.OBJ_BUTTON, 630, fftsa.opt_btn_y, "Cancel", 140)
  fftsa.opt_b_cancel = b_cancel
  display.setevent(b_cancel, display.EVENT_PRESS, "if fftsa ~= nil then fftsa.guard(fftsa.options_cancel) end")
  local b_about = create(fftsa.optscr, display.OBJ_BUTTON, 8, fftsa.opt_btn_y, "About", 140)
  fftsa.opt_b_about = b_about
  fftsa.opt_b_about = b_about
  display.setevent(b_about, display.EVENT_PRESS, "if fftsa ~= nil then fftsa.guard(fftsa.about) end")
  local b_rst = create(fftsa.optscr, display.OBJ_BUTTON, 168, fftsa.opt_btn_y, "Reset", 140)
  fftsa.opt_b_rst = b_rst
  display.setevent(b_rst, display.EVENT_PRESS, "if fftsa ~= nil then fftsa.guard(fftsa.options_reset) end")
  -- Hook End App on the Options screen while it can be the visible screen.
  display.setevent(fftsa.optscr, display.EVENT_ENDAPP,
                   "if fftsa ~= nil then fftsa.cleanup() end")
  return fftsa.optscr
end

-- About pages
fftsa.about_x        = 12
fftsa.about_title_x  = 400        -- centred, so the x is the screen's middle
fftsa.about_title_y  = 30
fftsa.about_body_y   = 70
fftsa.about_body_dy  = 20
fftsa.about_rows     = 14
fftsa.about_page     = 1
fftsa.about_c_title  = 56575      -- cyan 00DCFF
fftsa.about_c_body   = 16777215

-- OBJ_TEXT does not wrap; keep each licence line within the page width.
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

fftsa.about_cols = 92

function fftsa.destroy_about()
  fftsa.del_scr(fftsa.aboutscr, fftsa.sg_scr)
  fftsa.aboutscr, fftsa.about_name, fftsa.about_lines = nil, nil, nil
  fftsa.about_pageno, fftsa.about_page = nil, 1
  fftsa.ab_up, fftsa.ab_dn, fftsa.ab_back = nil, nil, nil
end

-- Append a snapshot of the native and frame diagnostics to the About pages.
function fftsa.ms_str(t)
  if type(t) ~= 'number' then return '-' end
  return string.format('%.0f', t * 1000)
end

function fftsa.diag_str()
  local app = 'halt=' .. tostring(fftsa.halted)
              .. ' err=' .. tostring(fftsa.lasterr)
              .. ' nlerr=' .. tostring(fftsa.nl_lasterr)
              .. ' rc=' .. tostring(fftsa.nl ~= nil and fftsa.nl.last_rc)
              .. ' nerr=' .. tostring(fftsa.errcount)
              .. ' short=' .. tostring(fftsa.shortreads)
              .. ' rot=' .. tostring(fftsa.nl_rotated)
              .. ' n=' .. tostring(fftsa.n)
              .. ' ncol=' .. tostring(fftsa.sg_ncol)
              .. ' repin=' .. tostring(fftsa.binhz_repins or 0)
              -- UI timings: switch in, populate fields, and switch back.
              .. ' ui=' .. fftsa.ms_str(fftsa.opt_t_sw) .. '/' .. fftsa.ms_str(fftsa.opt_t_fill)
              .. '/' .. fftsa.ms_str(fftsa.main_t_sw)
              .. ' gap=' .. fftsa.ms_str(fftsa.opt_gap) .. '/' .. tostring(fftsa.opt_frames)
              .. ' arm=' .. tostring(fftsa.narms or 0)
              .. '/' .. tostring(fftsa.narms_off or 0)
              -- Poll diagnostics count consumed, unrecognized and coalesced presses.
              .. ' poll=' .. tostring(fftsa.poll_n or 0)
              .. '/' .. tostring(fftsa.poll_got)
              .. '/' .. tostring(fftsa.poll_stale or 0)
              .. '/' .. tostring(fftsa.poll_lost or 0)
              .. ' coal=' .. tostring(fftsa.opt_coalesced or 0)
  local d = nil
  if fftsa.nl ~= nil and fftsa.nl.diag ~= nil then
    local ok, got = pcall(fftsa.nl.diag)
    if ok then d = got end
  end
  if d == nil then d = 'no native path: nl=' .. tostring(fftsa.nl ~= nil) end
  local px = ''
  if fftsa.nl ~= nil and fftsa.nl.px_str ~= nil then
    local okp, gotp = pcall(fftsa.nl.px_str)
    if okp then px = ' | ' .. tostring(gotp) end
  end
  return app .. ' | ' .. tostring(d) .. px
end

function fftsa.halt(short)
  fftsa.halted = true
  pcall(fftsa.say, short)
  pcall(fftsa.show_error, fftsa.diag_str(), true)
  return nil
end

function fftsa.about_add_diag()
  if fftsa.about_text == nil then return false end
  if fftsa.about_diag_at == nil then
    fftsa.about_diag_at = table.getn(fftsa.about_text) + 1
  end
  local i
  for i = table.getn(fftsa.about_text), fftsa.about_diag_at, -1 do
    fftsa.about_text[i] = nil
  end
  local body = fftsa.err_wrap('v' .. tostring(fftsa.VERSION) .. ' ' .. fftsa.node_str()
                              .. ' | ' .. fftsa.diag_str(), fftsa.about_cols)
  -- Start diagnostics on a fresh page so they do not split the licence.
  local at = fftsa.about_diag_at
  local pad = math.mod(at - 1, fftsa.about_rows)
  if pad > 0 then
    for i = 1, fftsa.about_rows - pad do
      fftsa.about_text[at] = ''
      at = at + 1
    end
  end
  for i = 1, table.getn(body) do
    fftsa.about_text[at] = body[i]
    at = at + 1
  end
  if fftsa.about_pageno ~= nil then fftsa.about_show_page(fftsa.about_page or 1) end
  return true
end

function fftsa.about_pages()
  local rows = fftsa.about_rows
  return math.ceil(table.getn(fftsa.about_text) / rows)
end

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

fftsa.opt_tick_period = 0.1

function fftsa.opt_tick()
  if fftsa.timer ~= nil and fftsa.exit_if_function_changed() then return false end
  fftsa.options_preview()
  return true
end

-- Build About at startup; opening it should not allocate objects.
function fftsa.build_about()
  fftsa.destroy_about()
  local create = display.create
  fftsa.aboutscr = create(display.ROOT, display.OBJ_SCREEN, "FFT Analyser - About")
  if fftsa.aboutscr == nil then
    fftsa.lasterr = "OBJPOOL exhausted building the about screen"
    return false, fftsa.lasterr
  end
  fftsa.loading_front()
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
  fftsa.ab_up = b_up
  display.setevent(b_up, display.EVENT_PRESS,
                   "if fftsa ~= nil then fftsa.guard(fftsa.about_pgup) end")
  local b_dn = create(fftsa.aboutscr, display.OBJ_BUTTON, 168, fftsa.opt_btn_y,
                      "PgDn", 140)
  fftsa.ab_dn = b_dn
  display.setevent(b_dn, display.EVENT_PRESS,
                   "if fftsa ~= nil then fftsa.guard(fftsa.about_pgdn) end")
  local b_back = create(fftsa.aboutscr, display.OBJ_BUTTON, 630, fftsa.opt_btn_y,
                        "Back", 140)
  fftsa.ab_back = b_back
  display.setevent(b_back, display.EVENT_PRESS,
                   "if fftsa ~= nil then fftsa.guard(fftsa.about_back) end")
  display.setevent(fftsa.aboutscr, display.EVENT_ENDAPP,
                   "if fftsa ~= nil then fftsa.cleanup() end")
  -- The About timer watches the function key without acquiring data.
  local watch = create(fftsa.aboutscr, display.OBJ_TIMER, 0.25, display.TIMER_FOREVER)
  if watch ~= nil then
    display.setevent(watch, display.EVENT_PRESS,
      "if fftsa ~= nil and fftsa.timer ~= nil then fftsa.guard(fftsa.exit_if_function_changed) end")
  end
  fftsa.about_show_page(1)
  return fftsa.aboutscr
end

function fftsa.about()
  if fftsa.aboutscr == nil then return false end
  -- Snapshot diagnostics each time About opens, not just at launch.
  pcall(fftsa.about_add_diag)
  fftsa.about_show_page(1)
  if fftsa.scr_now == fftsa.aboutscr then return true end
  display.changescreen(fftsa.aboutscr)
  fftsa.scr_now = fftsa.aboutscr
  return true
end

function fftsa.about_back()
  if fftsa.optscr == nil then return fftsa.show_main() end
  display.changescreen(fftsa.optscr)
  return true
end

-- FRONT/REAR is read live; the app does not control that key.
function fftsa.terminal_text()
  local t = dmm.terminals
  if t == dmm.TERMINALS_REAR then return "REAR" end
  if t == dmm.TERMINALS_FRONT then return "FRONT" end
  return "TERM?"
end

function fftsa.sample_rate_text(fs)
  if type(fs) ~= "number" then return "?" end
  if fs >= 1000000 then return string.format("%g MS/s", fs / 1000000) end
  if fs >= 1000 then return string.format("%g kS/s", fs / 1000) end
  return string.format("%g S/s", fs)
end

-- Acquisition duration is N/fs, not the first-to-last timestamp interval.
function fftsa.opt_info_text(fs, n, wi, bi, acq)
  fs, n = fs or fftsa.fs, n or fftsa.n
  if acq == nil then acq = fftsa.fs_acq or fs end
  -- Allow missing values while the UI is being built or torn down.
  local wl = tostring(fftsa.win_label(wi, bi))
  if type(fs) ~= "number" or type(n) ~= "number" or n == 0 or fs == 0 then
    return string.format("fs %s   bin ? Hz   acq ? ms   %s",
                         fftsa.sample_rate_text(acq), wl)
  end
  return string.format("fs %s   bin %.2f Hz   acq %.2f ms   %s",
                       fftsa.sample_rate_text(acq), fs / n, 1000 * n / fs, wl)
end

function fftsa.getval(h, fallback)
  if h == nil then return fallback end
  return display.getvalue(h)
end

function fftsa.setval(h, v)
  if h == nil then return false end
  display.setvalue(h, v)
  return true
end

function fftsa.settxt(h, t)
  if h == nil then return false end
  display.settext(h, t)
  return true
end

-- Preview pending settings without committing them or touching acquisition.
function fftsa.options_preview(wi, bi)
  local lo, hi = fftsa.options_span()
  local n = fftsa.options_samples()
  local fs = fftsa.pick_fs(hi)
  -- Reuse the measured rate if the preview selects the active acquisition rate.
  if fs == fftsa.pick_fs(fftsa.fhi) then fs = fftsa.fs_acq or fftsa.fs end
  local acq = fs
  if wi == nil then
    wi = fftsa.opt_index(fftsa.getval(fftsa.opt_win), fftsa.win_names, fftsa.win_i)
  end
  if bi == nil then
    bi = fftsa.opt_index(fftsa.getval(fftsa.opt_beta), fftsa.kbeta_labels,
                         fftsa.kbeta_i)
  end
  local text = fftsa.opt_info_text(fs, n, wi, bi, acq)
  if text ~= fftsa.opt_info_last then
    fftsa.settxt(fftsa.opt_info, text)
    fftsa.opt_info_last = text
  end
end

-- Catch callback errors before they escape to the firmware event handler.
function fftsa.guard(f)
  if f == nil then return false end
  local ok, err = pcall(f)
  if not ok then
    fftsa.lasterr = "button handler failed: " .. tostring(err)
    fftsa.say(fftsa.lasterr)
  end
  return ok
end

function fftsa.say(msg)
  if fftsa.sg_xunit ~= nil then
    display.settext(fftsa.sg_xunit, string.sub(tostring(msg), 1, 70))
  end
end

function fftsa.show_main()
  if fftsa.sg_scr ~= nil then
    if fftsa.scr_now == fftsa.sg_scr then return true end
    local t0 = os.clock()
    display.changescreen(fftsa.sg_scr)
    fftsa.scr_now = fftsa.sg_scr
    fftsa.main_t_sw = os.clock() - t0
    fftsa.loading_watch_back()
    return true
  end
  display.changescreen(display.SCREEN_HOME)
  fftsa.scr_now = nil
  return false
end

function fftsa.opt_fill(flo, fhi, range, win_i, kbeta_i, n)
  fftsa.setval(fftsa.opt_flo, flo)
  fftsa.setval(fftsa.opt_fhi, fhi)
  fftsa.setval(fftsa.opt_rng, fftsa.range_to_idx(range))
  fftsa.setval(fftsa.opt_win, win_i)
  fftsa.setval(fftsa.opt_beta, kbeta_i)
  fftsa.setval(fftsa.opt_n, fftsa.sample_to_idx(n))
  fftsa.options_preview(win_i, kbeta_i)
end

function fftsa.options()
  if fftsa.optscr == nil then return false end
  -- Switch to Options before filling fields so the spectrum timer stops immediately.
  if fftsa.scr_now == fftsa.optscr then
    fftsa.opt_coalesced = (fftsa.opt_coalesced or 0) + 1
    return true
  end
  local t0 = os.clock()
  display.changescreen(fftsa.optscr)
  fftsa.scr_now = fftsa.optscr
  local t1 = os.clock()
  delay(fftsa.sg_yield)
  fftsa.opt_fill(fftsa.flo, fftsa.fhi, fftsa.range, fftsa.win_i, fftsa.kbeta_i, fftsa.n)
  local t2 = os.clock()
  fftsa.opt_gap = nil
  if fftsa.opt_t_at ~= nil then fftsa.opt_gap = t0 - fftsa.opt_t_at end
  fftsa.opt_t_sw, fftsa.opt_t_fill, fftsa.opt_t_at = t1 - t0, t2 - t1, t2
  -- Record elapsed time and frame count between Options visits.
  fftsa.opt_frames = nil
  if fftsa.opt_nf_at ~= nil then fftsa.opt_frames = (fftsa.nframes or 0) - fftsa.opt_nf_at end
  fftsa.opt_nf_at = fftsa.nframes or 0
  fftsa.opt_opens = (fftsa.opt_opens or 0) + 1
  return true
end

-- Reset edits the form only; Apply commits and Cancel discards.
function fftsa.options_reset()
  if fftsa.optscr == nil then return false end
  local d = fftsa.defaults
  fftsa.opt_fill(d.flo, d.fhi, d.range, d.win_i, d.kbeta_i, d.n)
  return true
end

-- Use the same span validation as an unlocked graph gesture.
function fftsa.options_span()
  local nlo, nhi = fftsa.flo, fftsa.fhi
  local lo = fftsa.getval(fftsa.opt_flo, fftsa.flo)
  local hi = fftsa.getval(fftsa.opt_fhi, fftsa.fhi)
  if hi ~= nil and hi > 0 then nhi = hi end
  if lo ~= nil and lo >= 0 then nlo = lo end
  return fftsa.span_clamp(nlo, nhi)
end

function fftsa.options_apply()
  -- Apply reads fields directly; the preview timer may not have seen the last edit.
  if fftsa.timer ~= nil and fftsa.exit_if_function_changed() then return false end
  -- Validate all fields before changing applied settings.
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
  -- Rebind only when necessary: removeall discards the ring and repaints the graph.
  local mknew = (mki == 2)
  local mkchanged = (mknew ~= fftsa.sg_markers)
  fftsa.sg_markers = mknew
  -- Keep the loading cover up while Apply rebuilds the plan and acquires a capture.
  fftsa.loading_front()
  -- Never resume after a partial resize with mismatched DSP and capture sizes.
  fftsa.halted = (fftsa.n ~= nold)
  local ok, err = pcall(function() fftsa.apply() end)
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
    -- An explicit Apply supersedes any queued gesture retune.
    fftsa.retune_pending = false
    if mkchanged then fftsa.sg_bind() end
    fftsa.sg_write_xunit()
  end
  return ok
end

function fftsa.options_cancel()
  fftsa.show_main()
end

-- Draw the icons over ordinary buttons; the icons do not handle the press.
fftsa.btn_y      = 350
fftsa.btn_h      = 60
fftsa.btn_lock_x = 660
fftsa.btn_lock_w = 60
fftsa.btn_opt_x  = 730
fftsa.btn_opt_w  = 60
fftsa.lock_img_w = 28  -- fftlockc and fftlocko: 28x34
fftsa.lock_img_h = 34
fftsa.cog_img_w  = 34  -- fftcog: 34x34
fftsa.cog_img_h  = 34

-- The packager includes the assets named by these declarations.
fftsa.img_lock_c = "fftlockc"
fftsa.img_lock_o = "fftlocko"
fftsa.img_cog    = "fftcog"

function fftsa.lock_icon()
  local on, off = fftsa.lockimg_o, fftsa.lockimg_c
  if fftsa.sg_lock then on, off = fftsa.lockimg_c, fftsa.lockimg_o end
  if off ~= nil then display.setstate(off, display.STATE_INVISIBLE) end
  fftsa.icon_redraw(on)
end

-- Reassert icon visibility to force a redraw without rebuilding the button.
function fftsa.icon_redraw(h)
  if h == nil then return false end
  display.setstate(h, display.STATE_INVISIBLE)
  display.setstate(h, display.STATE_ENABLE)
  return true
end

function fftsa.icons_reassert()
  fftsa.lock_icon()
  fftsa.icon_redraw(fftsa.optimg)
  return true
end

-- Update the padlock before settling the axes so it always reflects the setting.
function fftsa.toggle_lock()
  fftsa.sg_lock = not fftsa.sg_lock
  fftsa.lock_icon()
  if fftsa.sg_lock then fftsa.sg_settle() end
  return fftsa.sg_lock
end

-- Missing icons leave usable buttons; keep the failure in diagnostics.
function fftsa.icon_at(x, y, name)
  if name == nil then return nil end
  local img = display.create(fftsa.sg_scr, display.OBJ_IMAGE, x, y, name)
  if img == nil then
    fftsa.lasterr = "image " .. tostring(name) .. " did not load"
    fftsa.say(fftsa.lasterr)
  end
  return img
end

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

-- Allocate screens and children at startup under the loading cover.
function fftsa.build()
  fftsa.loading_build()
  fftsa.loading_front()
  -- Allocate trace capacity independently of the current plotted column count.
  local scr, why = fftsa.sg_build("FFT SPECTRUM ANALYSER", fftsa.n / 2,
                                  fftsa.sg_capacity())
  if scr == nil then return false, why end
  -- The old spectrum screen owned its buttons; clear those handles before rebuilding.
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

-- Reserve interpreter idle time between frames for dispatching button presses.
fftsa.tick_idle = 0.020
-- The DMM6500 accepts 10 ms steps; the minimum timer period is 50 ms.
fftsa.tick_grid = 0.010
-- Use 50 ms steps on the DMM7510, where an off-grid period opens a modal event.
fftsa.tick_grid_7510 = 0.050
fftsa.tick_min  = 0.050
-- Require a larger rise than fall before re-arming to avoid jitter.
fftsa.tick_rise = 0.050

function fftsa.tick_grid_now()
  if fftsa.is_7510 ~= nil and fftsa.is_7510() then return fftsa.tick_grid_7510 end
  return fftsa.tick_grid
end

-- Enforce a minimum gap after frame work: a display yield does not free the Lua interpreter.
fftsa.tick_floor = 0.010

function fftsa.tick_period(busy)
  if busy == nil or busy <= 0 then return fftsa.tick_min end
  local g = fftsa.tick_grid_now()
  local ticks = math.ceil((busy + fftsa.tick_idle) / g - 0.05)
  if ticks < 1 then ticks = 1 end
  local p = ticks * g
  if p < fftsa.tick_min then p = fftsa.tick_min end
  -- Step up on the active grid rather than arming an off-grid period.
  while p < busy + fftsa.tick_floor do p = p + g end
  return p
end

function fftsa.frame_period(n)
  return fftsa.tick_period(fftsa.frame_estimate(n))
end

-- Long captures poll for presses before blocking. Always give waitevent a positive timeout.
fftsa.press_poll_above = 1.0     -- seconds of acquisition before the frame polls at all
fftsa.press_poll_wait  = 0.02    -- the timeout handed to waitevent, never nil and never 0

-- waitevent consumes events, so handle End App here and discard stale off-screen presses.
function fftsa.press_poll()
  if display.waitevent == nil or fftsa.optbtn == nil then return false end
  fftsa.poll_n = (fftsa.poll_n or 0) + 1
  local ok, id, ev = pcall(display.waitevent, fftsa.press_poll_wait)
  if not ok or id == nil then return false end
  fftsa.poll_got = tostring(id) .. '/' .. tostring(ev)
  -- The spectrum screen itself registers only End App.
  if id == fftsa.sg_scr then fftsa.guard(fftsa.cleanup) return true end
  if id == fftsa.loadscr and fftsa.loadwatch then
    fftsa.guard(fftsa.cleanup)
    return true
  end
  if id == fftsa.optbtn then fftsa.guard(fftsa.options) return true end
  if id == fftsa.lockbtn then fftsa.guard(fftsa.toggle_lock) return true end
  -- Do not dispatch timer or graph events as button presses.
  if id == fftsa.timer or id == fftsa.sg_graph then return false end
  -- Discard queued events from Options and About now that those screens are hidden.
  if id == fftsa.opt_b_apply or id == fftsa.opt_b_cancel or id == fftsa.opt_b_about
     or id == fftsa.opt_b_rst or id == fftsa.opt_preview or id == fftsa.optscr
     or id == fftsa.ab_up or id == fftsa.ab_dn or id == fftsa.ab_back
     or id == fftsa.aboutscr then
    fftsa.poll_stale = (fftsa.poll_stale or 0) + 1
    return false
  end
  -- Count unrecognized events; waitevent has already consumed them.
  fftsa.poll_lost = (fftsa.poll_lost or 0) + 1
  return false
end

function fftsa.arm(period_s)
  if period_s == nil then period_s = 0.05 end
  -- Count timer recreations and periods off the firmware's 50 ms grid separately.
  fftsa.narms = (fftsa.narms or 0) + 1
  local ms = math.floor(period_s * 1000 + 0.5)
  if math.mod(ms, 50) ~= 0 then fftsa.narms_off = (fftsa.narms_off or 0) + 1 end
  if fftsa.timer ~= nil then
    fftsa.del_obj(fftsa.timer)
    fftsa.timer = nil
  end
  if fftsa.sg_scr == nil then return nil end
  fftsa.armed_n = fftsa.n
  fftsa.timer = display.create(fftsa.sg_scr, display.OBJ_TIMER, period_s, display.TIMER_FOREVER)
  display.setevent(fftsa.timer, display.EVENT_PRESS, "if fftsa ~= nil and fftsa.frame ~= nil then fftsa.frame() end")
  return fftsa.timer
end

-- Tear down all screens and clear handles; firmware object IDs do not survive teardown.
function fftsa.cleanup()
  fftsa.stop()
end

-- Hook End App as soon as the spectrum screen exists, even during startup.
function fftsa.install_cleanup()
  if fftsa.sg_scr == nil then return false end
  local ok, err = pcall(function()
    display.setevent(fftsa.sg_scr, display.EVENT_ENDAPP, "if fftsa ~= nil then fftsa.cleanup() end")
  end)
  if not ok then fftsa.lasterr = "ENDAPP hook failed: " .. tostring(err) end
  return ok
end

function fftsa.start_failed(why)
  fftsa.lasterr = tostring(why)
  fftsa.stop()
  print("fftsa start FAILED (cleaned up): " .. tostring(why))
  fftsa.show_error(tostring(why))
  return false
end

function fftsa.start()
  fftsa.stop()
  fftsa.halted, fftsa.errrun, fftsa.stop_pending = false, 0, false
  fftsa.froze = false

  -- Refuse a missing DSP implementation before allocating display objects.
  if fftsa.dsp_absent then
    return fftsa.start_failed("no DSP implementation: the archive was built without "
                              .. "dsp_lua.tsp and this instrument has no dsp module")
  end

  local built, why = fftsa.build()
  if built == false then return fftsa.start_failed(why or "build failed") end

  local hooked = fftsa.install_cleanup()
  -- Select the opening FFT count before the initial Apply.
  if fftsa.native_likely() then
    fftsa.n = fftsa.n_compiled
    fftsa.defaults.n = fftsa.n_compiled
  end
  local ok, err = pcall(function()
    fftsa.apply()
    fftsa.period = fftsa.frame_period(fftsa.n)
  end)
  if not ok then return fftsa.start_failed(tostring(err)) end

  -- Install or reattach native DSP before arming frames. Record the stage that refused.
  if fftsa.nl ~= nil and type(fftsa.nl.init) == 'function' then
    local iok, ierr = pcall(function()
      fftsa.nl.init(nil, fftsa.nl_nmax, fftsa.nl.win_to_native(fftsa.win_i),
                    fftsa.kbeta(fftsa.kbeta_i), 1, fftsa.nl.FFT_FOURSTEP,
                    fftsa.sg_maxpts)
      fftsa.nl_replan()
    end)
    if not iok then
      fftsa.nl.ready = false
      fftsa.nl.why = 'init raised: ' .. tostring(ierr)
    end
  end
  -- Refuse startup if neither native nor interpreted DSP is available.
  if fftsa.fft_init == nil
     and (fftsa.nl == nil or not fftsa.nl.ready
          or fftsa.nl.entry == nil or fftsa.nl.entry == 0) then
    local nl = fftsa.nl
    local why = "nl absent"
    if nl ~= nil then
      why = nl.diag()
      if fftsa.nl_lasterr ~= nil then why = why .. " | bind=" .. tostring(fftsa.nl_lasterr) end
    end
    return fftsa.start_failed("NODSP nofallback " .. why)
  end
  if not hooked then
    print("fftsa WARNING: End App cleanup not hooked -- " .. tostring(fftsa.lasterr))
    display.settext(fftsa.sg_xunit, "WARNING: End App will not clean up")
  end
  print("fftsa started fs=" .. fftsa.fs .. " bin=" .. fftsa.binhz ..
        " range=" .. fftsa.range .. " window=" .. fftsa.win_label())
  pcall(fftsa.about_add_diag)
  -- Switching off the cover activates the spectrum timer.
  fftsa.show_main()
  -- Give a freshly bound trace time for its first paint before frames replace it.
  delay(fftsa.sg_first_paint)
  local aok, aerr = pcall(function() fftsa.arm(fftsa.period) end)
  if not aok then return fftsa.start_failed(tostring(aerr)) end
  return true
end

function fftsa.stop()
  -- Defer teardown until the active frame is done touching buffers and objects.
  if fftsa.busy and not fftsa.stop_pending then
    fftsa.stop_pending = true
    return false
  end
  fftsa.stop_pending = false
  -- Stop the timer before deleting display and DSP state.
  if fftsa.timer ~= nil then fftsa.del_obj(fftsa.timer) end
  fftsa.timer = nil
  fftsa.optbtn, fftsa.optimg = nil, nil
  fftsa.lockbtn, fftsa.lockimg_c, fftsa.lockimg_o = nil, nil, nil
  -- Release the active DSP plan as part of teardown.
  pcall(function() dsp.release() end)
  pcall(function() fftsa.sg_destroy(true) end)
  fftsa.destroy_options()
  fftsa.destroy_about()
  fftsa.loading_destroy(display.SCREEN_HOME)
  fftsa.del_scr(fftsa.errscr)
  fftsa.errscr = nil
  -- Keep the capture buffer for the boot so a relaunch can reuse its allocation.
  fftsa.busy, fftsa.halted, fftsa.errrun = false, false, 0
  fftsa.retune_pending, fftsa.armed_n, fftsa.scr_now = false, nil, nil
  return true
end

fftsa.err_y0, fftsa.err_dy, fftsa.err_rows, fftsa.err_cols = 103, 20, 13, 92
fftsa.err_foot_y = 420

function fftsa.node_str()
  local m, v = nil, nil
  if localnode ~= nil then m, v = localnode.model, localnode.version end
  if m == nil then m = '?model' end
  if v == nil then v = '?fw' end
  return tostring(m) .. ' ' .. tostring(v)
end

-- Wrap diagnostics to the panel width without splitting words.
function fftsa.err_wrap(msg, cols)
  local m = tostring(msg)
  if cols == nil or cols < 8 then cols = 8 end
  local out, n = {}, 0
  local i, len = 1, string.len(m)
  while i <= len do
    local stop = i + cols - 1
    if stop < len then
      -- A space immediately after the window lets the whole window fit on this line.
      local cut, k = nil, stop + 1
      while k > i do
        if string.sub(m, k, k) == ' ' then cut = k break end
        k = k - 1
      end
      if cut ~= nil then stop = cut - 1 end
    else
      stop = len
    end
    n = n + 1
    out[n] = string.sub(m, i, stop)
    i = stop + 1
    while i <= len and string.sub(m, i, i) == ' ' do i = i + 1 end
  end
  return out
end

-- Reuse row objects while paging the wrapped diagnostic.
function fftsa.err_show_page(p)
  local lines = fftsa.err_text
  if lines == nil or fftsa.err_row == nil then return false end
  local rows = fftsa.err_rows
  local npg = math.floor((table.getn(lines) + rows - 1) / rows)
  if npg < 1 then npg = 1 end
  if p == nil or p < 1 or p > npg then p = 1 end
  fftsa.err_page = p
  local i
  for i = 1, rows do
    local t = lines[(p - 1) * rows + i]
    display.settext(fftsa.err_row[i], t or '')
  end
  if fftsa.err_pageno ~= nil then
    display.settext(fftsa.err_pageno, 'page ' .. tostring(p) .. ' of ' .. tostring(npg))
  end
  return true
end

function fftsa.err_more()
  return fftsa.err_show_page((fftsa.err_page or 1) + 1)
end

-- Keep the error screen handle and End App hook so normal teardown can release it.
function fftsa.show_error(msg, stay)
  -- Prefix the diagnostic with build, model and firmware for identification.
  local full = 'v' .. tostring(fftsa.VERSION) .. ' ' .. tostring(msg)
  local shown = pcall(function()
    if fftsa.errscr ~= nil then
      fftsa.del_obj(fftsa.errscr)
      fftsa.errscr = nil
    end
    fftsa.errscr = display.create(display.ROOT, display.OBJ_SCREEN, "FFT ANALYSER ERROR")
    if fftsa.errscr == nil then
      print("fftsa: object pool exhausted; no error screen")
      return false
    end
    display.create(fftsa.errscr, display.OBJ_TEXT, 20, 68,
                   "FFT " .. tostring(fftsa.VERSION) .. "  " .. fftsa.node_str(),
                   16736352,                                    -- red FF6060
                   display.FONT_MEDIUM, display.JUST_LEFT)
    fftsa.err_text = fftsa.err_wrap(full, fftsa.err_cols)
    fftsa.err_page = 1
    fftsa.err_row = {}
    local y, i = fftsa.err_y0, nil
    for i = 1, fftsa.err_rows do
      fftsa.err_row[i] = display.create(fftsa.errscr, display.OBJ_TEXT, 20, y,
                                        fftsa.err_text[i] or '',
                                        14737632,               -- light grey E0E0E0
                                        display.FONT_1, display.JUST_LEFT)
      y = y + fftsa.err_dy
    end
    local npg = math.floor((table.getn(fftsa.err_text) + fftsa.err_rows - 1)
                           / fftsa.err_rows)
    local foot = "End App exits"
    if npg > 1 then
      fftsa.err_pageno = display.create(fftsa.errscr, display.OBJ_TEXT, 470, 76,
                                        'page 1/' .. tostring(npg), 9474192,
                                        display.FONT_1, display.JUST_LEFT)
      local b = display.create(fftsa.errscr, display.OBJ_BUTTON, 630, fftsa.opt_btn_y,
                               "More", 140)
      display.setevent(b, display.EVENT_PRESS,
                       "if fftsa ~= nil then fftsa.err_more() end")
      foot = "More -> next page, and grab every page.  " .. foot
    end
    display.create(fftsa.errscr, display.OBJ_TEXT, 20, fftsa.err_foot_y, foot,
                   9474192,                                        -- grey 909090
                   display.FONT_1, display.JUST_LEFT)
    display.setevent(fftsa.errscr, display.EVENT_ENDAPP, "if fftsa ~= nil then fftsa.cleanup() end")
    display.changescreen(fftsa.errscr)
    fftsa.scr_now = fftsa.errscr
  end)
  if not shown or fftsa.errscr == nil then
    fftsa.errscr = nil
    -- Return to HOME only when no app screen is available to keep visible.
    if not stay then display.changescreen(display.SCREEN_HOME) end
    print("fftsa: could not build the error screen either -- " .. full)
  end
  return fftsa.errscr
end
