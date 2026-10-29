-- dsp_lua.tsp -- the app's signal-processing math, in a table of its own. Lua 5.0.2.
--
-- The division this file exists for: the transform, the reduction, the peak search and the
-- distortion figures are reached through one table, dsp, and the app's data path calls
-- nothing else. Attributes to configure and one call to run, in the style of dmm.digitize --
-- commit, spectrum, plan, peak, distortion, release and lastevent, over the attribute groups
-- dsp.fft, dsp.filter, dsp.out, dsp.peaks and dsp.thd.
--
-- Keeping the math behind one table is what makes it replaceable: the app cannot reach past
-- it, so an implementation bound under the same names behaves the same or not at all.
--
-- Nothing is installed at load time: the body is a function, so the gate at the head of
-- tsp/spectrum_app.tsp can decline to call it and leave a dsp this instrument already has.
-- There is no runtime module loading here, so the gate chooses between what the archive
-- already carries rather than loading either.
--
-- The arithmetic underneath is fftsa's own, pinned by tools/test_tsp.lua, so a figure that
-- moves is whatever replaced this table and not the table. Every argument the interface
-- says is illegal is refused here too: an implementation kinder than its own rules hides
-- the defect the rules exist to catch.

fftsa = fftsa or {}   -- the single global this app exposes

function fftsa.dsp_install()
  dsp = {}

  -- Return codes. Negative, so a caller can test one answer for failure, and fixed values
  -- rather than an enum the firmware might number differently.
  dsp.OK, dsp.EARG, dsp.EPOW2, dsp.ENOMEM = 0, -1, -2, -3
  dsp.EUNSUPPORTED, dsp.ESHORT, dsp.EBETA = -4, -5, -6
  dsp.EDECLINE, dsp.EALIGN, dsp.EZONE = -7, -8, -9
  -- No code in dsp.h covers a plan an attribute write has invalidated.
  dsp.EDIRTY = -10

  dsp.WINDOW_RECT, dsp.WINDOW_HANN, dsp.WINDOW_BLACKMAN = 0, 1, 2
  dsp.WINDOW_BLACKMAN_HARRIS, dsp.WINDOW_KAISER = 3, 4
  dsp.OFF, dsp.ON = 0, 1
  -- Negative, because every real selection is a frequency and so positive.
  dsp.MAINS_BOTH = -1

  dsp.version = 1

  -- Posted rather than raised, which is the convention throughout: a raise inside
  -- a timer or button callback posts -286 and leaves the app on screen and dead. The list
  -- stands in for the instrument's event log so a test can assert that a refusal posted AND
  -- returned a code.
  -- ONE RECORD, not a list. nevents stays monotonic, so a test can assert that a refusal
  -- posted and a caller can tell a fresh one from a stale one, but the records cannot
  -- accumulate: this app runs unattended for the rest of a power cycle and nothing reads an
  -- event except the one lastevent() returns. Natively these go to the instrument's own
  -- event log, which has its own bound.
  dsp.events = {}
  dsp.nevents = 0
  local function post(code, why)
    dsp.nevents = dsp.nevents + 1
    dsp.events[1] = {code = code, why = why}
    return code
  end

  -- The last refusal, as a code and a reason string. This is what turns a negative integer
  -- into something that can go on the glass: fftsa.options_apply writes it behind
  -- "APPLY FAILED:" and fftsa.frame puts the first 60 characters of it behind the HALTED
  -- banner. Without it the operator gets "-2".
  function dsp.lastevent()
    if dsp.nevents < 1 then return nil end
    return dsp.events[1]
  end

  -- Three attribute classes, not two, and which one an attribute is in is the whole of what
  -- a commit costs:
  --
  --   'tables'  fft.samples, fft.window, fft.beta, filter.decimate -- the window, the
  --             twiddles and the interpolation tables, or the size of the arena. 0.163 ms a
  --             sample: 83 ms at 512 and a measured 2.667 s at 16384.
  --   'filter'  fft.samplerate, filter.state/lowcutoff/highcutoff/order -- no
  --             table depends on them, so a commit that only moved these builds nothing.
  --   'frame'   out.*, peaks.*, thd.* -- nothing is built from them, so they are read per
  --             call and a span gesture or a mains setting costs no rebuild at all.
  --
  -- And a write that does not CHANGE the value dirties nothing. fftsa.apply() rewrites every
  -- attribute unconditionally on every press and every adopted gesture; without this rule
  -- each of those would force a full commit, which is the 2.667 s above.
  -- The class is per ATTRIBUTE, not per namespace: fft.samples and fft.samplerate sit behind
  -- one name and cost two different things. One proxy a namespace, so a read crosses one
  -- metamethod and no more.
  local set_times
  local function group(settable, readback, classof)
    local store, req, p = {}, {}, {}
    local k, v
    for k, v in pairs(settable) do store[k] = v; req[k] = v end
    for k, v in pairs(readback) do store[k] = v end
    setmetatable(p, {
      __index = function(_, key) return store[key] end,
      __newindex = function(_, key, val)
        -- An unknown name is refused rather than accepted: a typo on a settings attribute is
        -- otherwise invisible until the spectrum looks wrong.
        if settable[key] == nil then
          post(dsp.EARG, 'not a settable attribute: ' .. tostring(key))
          return
        end
        -- Against the REQUEST, not the read-back. filter.decimate reads back the decimation
        -- chosen while the request is still 0, so comparing against the read-back would make
        -- rewriting 0 look like a change to 0 from 4 and dirty the plan every press.
        if req[key] == val then return end
        req[key] = val
        store[key] = val
        local class = classof
        if type(class) ~= 'string' then class = classof[key] end
        if class == 'frame' then
          dsp.capchecked = false    -- segments or peaks may no longer fit the buffers
        else
          if class == 'tables' then dsp.dirty_tables = true
          else dsp.dirty_filter = true end
          dsp.dirty = true
          set_times()
        end
      end,
    })
    return p, store, req
  end

  local fft_s, filter_s, out_s, peaks_s, thd_s, filter_req
  -- fft.samplerate is cheap: the rate places the taps and the band, reaching neither the
  -- window nor the twiddles. filter.decimate is expensive despite sitting among the filter's
  -- attributes, because it sizes the arena -- srclength follows from it, and so does
  -- dsp_plan_bytes.
  dsp.fft, fft_s = group(
    {samples = 512, window = dsp.WINDOW_HANN, beta = 12, samplerate = 0},
    {srclength = 0, binwidth = 0, binzerohz = 0, binsense = 1, zone = 0,
     spectrumtime = 0, committime = 0},
    {samples = 'tables', window = 'tables', beta = 'tables', samplerate = 'filter'})
  dsp.filter, filter_s, filter_req = group(
    {state = dsp.OFF, lowcutoff = 0, highcutoff = 0, order = 0, decimate = 0},
    {ntaps = 0},
    {state = 'filter', lowcutoff = 'filter', highcutoff = 'filter', order = 'filter',
     decimate = 'tables'})
  dsp.out, out_s = group({segments = 255, lowfreq = 10, highfreq = 50000,
                          dbfloor = -120, dbceil = 20, vfloor = 1e-9}, {}, 'frame')
  dsp.peaks, peaks_s = group({count = 6}, {}, 'frame')
  dsp.thd, thd_s = group({harmonics = 20, mains = dsp.MAINS_BOTH, bins = 1024}, {}, 'frame')

  dsp.dirty = true            -- no plan until commit() has run
  dsp.dirty_tables = true
  dsp.dirty_filter = true
  dsp.built = false           -- whether a plan exists at all, which release() takes away
  dsp.shortreads = 0          -- captures too short to transform, counted per the edge cases
  dsp.ran = false             -- whether a spectrum exists for peak() and distortion()
  dsp.builds = 0              -- table rebuilds a commit has done, for the cost tests

  -- 0.163 ms a sample, measured; docs/PERFORMANCE.md has it. Zero when the tables a commit
  -- would build are already the ones in force, which is every adopted gesture and most
  -- presses -- so a caller can tell a commit it has to cover the screen for from one it
  -- does not.
  local function commit_cost(n)
    if dsp.dirty_tables or not dsp.built then return 0.163e-3 * (n or 0) end
    return 0
  end

  -- Seconds one spectrum() costs at the plan in force, which is the model
  -- docs/PERFORMANCE.md calibrates: 0.080 s at 512 against 0.079 measured and 1.63 s at
  -- 16384 against 1.686.
  --
  -- THE WHOLE FRAME, not the transform alone: the model was calibrated against frames, and
  -- splitting it into a primitive's share and the app's would be re-deriving a measured
  -- figure without measuring. Switch day re-derives it against the native path, which is
  -- what docs/PERFORMANCE.md's phase table is for.
  local function spectrum_cost(n)
    if n == nil or n < 2 then n = 512 end
    local log2n = math.log(n) / 0.69314718055995
    return n * 46.6e-6 + 3.593e-6 * n * log2n + 0.04
  end

  set_times = function()
    fft_s.committime = commit_cost(fft_s.samples)
  end
  set_times()

  -- THE WINDOW ENUM IS NOT THE PICKER INDEX. dsp.WINDOW_HANN happens to be 1 and
  -- fftsa.win_names[1] happens to be "Hann", and relying on that coincidence means a native
  -- enum numbered differently selects the wrong window with nothing on the glass to say so --
  -- every amplitude wrong by a scalloping factor. Mapped, in both directions, one map on each
  -- side of the seam: this one, and fftsa.win_to_dsp in tsp/spectrum_app.tsp.
  local win_of = {}
  win_of[dsp.WINDOW_HANN] = 1
  win_of[dsp.WINDOW_BLACKMAN] = 2
  win_of[dsp.WINDOW_BLACKMAN_HARRIS] = 3
  win_of[dsp.WINDOW_KAISER] = 4

  -- One of the six betas the shipped window builder has tables for. The C library takes any
  -- beta in its range, so this is the Lua implementation's limit rather than the API's.
  local function beta_index(b)
    local i
    for i = 1, table.getn(fftsa.kbetas) do
      if fftsa.kbetas[i] == b then return i end
    end
    return nil
  end

  local function is_pow2(n)
    if type(n) ~= 'number' or n < 4 or n > 32768 then return false end
    local t = 4
    while t < n do t = t * 2 end
    return t == n
  end

  -- PURE. Builds nothing, allocates nothing, touches no plan state, answers in microseconds.
  -- It is the one call a keystroke can afford: fftsa.options_preview runs on every edit in
  -- the form and has to promise the bin width Apply will actually produce, and the rate
  -- chooser compares two candidate rates by the bin each would give. commit() cannot stand in
  -- for either -- it is 2.667 s at 16,384 samples.
  --
  -- No filter here, so the decimation is always 1 and the taps 0: nothing beats fs/n for bin
  -- width. Still the four answers the API specifies, so a caller written against a native
  -- dsp.* that does decimate needs no change.
  function dsp.plan(fs, flo, fhi, n)
    if type(fs) ~= 'number' or type(fhi) ~= 'number' or type(n) ~= 'number'
       or not (fs > 0) or not (fhi > 0) or n < 2 then
      return 1, 0, n or 0, 0, 'off'
    end
    return 1, fs / n, n, 0, 'no filter in this implementation'
  end

  -- The span, read per call rather than at commit. Passed on to the bin-window arithmetic
  -- rather than written into the display's own fields: fftsa.sg_window_bins is the single
  -- owner of the ceil/floor convention and takes the span as arguments, so nothing about the
  -- display reaches in here and nothing here reaches back out.
  local function span_ok()
    local flo, fhi = out_s.lowfreq, out_s.highfreq
    return (fhi > flo) and (flo >= 0)
  end

  -- Build the window, the interpolation tables, the twiddles and the filter taps. The slow
  -- call, and the one a frame must never make.
  function dsp.commit()
    local n = fft_s.samples
    if not is_pow2(n) then
      return post(dsp.EPOW2, 'samples must be a power of two in 4..32768')
    end
    local kind = fft_s.window
    if kind == dsp.WINDOW_RECT then
      return post(dsp.EUNSUPPORTED, 'no rectangular window in the reference implementation')
    end
    local wi = win_of[kind]
    if wi == nil then return post(dsp.EARG, 'unknown window ' .. tostring(kind)) end
    local bi = 4
    if kind == dsp.WINDOW_KAISER then
      bi = beta_index(fft_s.beta)
      if bi == nil then return post(dsp.EBETA, 'beta ' .. tostring(fft_s.beta)) end
    end
    if not span_ok() then
      return post(dsp.EARG, 'out.lowfreq must be below out.highfreq')
    end
    if out_s.segments < 2 then return post(dsp.EARG, 'out.segments below 2') end
    if peaks_s.count < 1 then return post(dsp.EARG, 'peaks.count below 1') end

    -- The acquisition rate has to be known HERE: the decimation, the tap count and so
    -- srclength all follow from it, and the caller needs srclength before it acquires.
    local fs = fft_s.samplerate
    if type(fs) ~= 'number' or not (fs > 0) then
      return post(dsp.EARG, 'fft.samplerate is needed to place the band and the taps')
    end

    -- Refused rather than ignored: a filter silently left out reads as a flat passband that is
    -- really the unfiltered record aliased into the band.
    if filter_s.state ~= dsp.OFF and filter_s.state ~= false then
      return post(dsp.EUNSUPPORTED, 'no filter in this implementation')
    end
    local binhz = fs / n

    -- Set before fft_init, which keys its cache on them. This is the one place the window
    -- enum becomes the shipped index, and it happens on every commit so the two cannot
    -- drift even when the expensive rebuild below is skipped.
    fftsa.win_i, fftsa.kbeta_i = wi, bi
    -- EXPENSIVE, and only when something it is built from moved. fft_init has its own cache
    -- on (n, win_i, kbeta_i), so a commit whose only change was the decimation costs the
    -- taps alone even though decimate is in the expensive class for the arena's sake.
    if dsp.dirty_tables or not dsp.built then
      fftsa.fft_init(n)
      dsp.builds = dsp.builds + 1
    end
    -- With no filter the record the caller must acquire is the transform length itself.
    fft_s.srclength = n
    -- Provisional. spectrum() measures the rate the digitizer actually delivered and
    -- replaces this, which is the only timebase the instrument has.
    fft_s.binwidth = binhz
    fft_s.binzerohz, fft_s.binsense, fft_s.zone = 0, 1, 0
    fft_s.spectrumtime = spectrum_cost(n)
    -- Read back as no filter; the request is kept separately, so rewriting 0 is no change.
    filter_s.decimate, filter_s.ntaps = 1, 0
    dsp.nbins = n / 2
    dsp.dirty, dsp.dirty_tables, dsp.dirty_filter = false, false, false
    dsp.built = true
    dsp.ran = false
    dsp.capchecked = false
    set_times()
    return dsp.OK
  end

  -- The rate DELIVERED, off the digitizer's own timestamps, which is what every reported
  -- frequency is a multiple of. The read-back of digitize.samplerate does not match what
  -- arrives, so it is never the source here.
  local function measured_binwidth(cap, n)
    local fallback = fft_s.binwidth
    if cap.n == nil or cap.n < 4 then return fallback end
    local ts = cap.relativetimestamps
    if ts == nil then return fallback end
    local t1, tn = ts[1], ts[cap.n]
    if t1 == nil or tn == nil or not (tn > t1) then return fallback end
    return ((cap.n - 1) / (tn - t1)) / n
  end

  -- One point in dB. Used for the marker trace, where there are as many calls as peaks;
  -- the segment loop inlines the same arithmetic because there are 255 of them and a call
  -- is about 12 us on the instrument.
  local function seg_value(hi)
    local vfl = out_s.vfloor * out_s.vfloor
    local db = out_s.dbfloor
    if hi ~= nil and hi > vfl then
      db = 10 * math.log10(hi)
      if not (db > out_s.dbfloor) then db = out_s.dbfloor
      elseif not (db < out_s.dbceil) then db = out_s.dbceil end
    end
    return db
  end

  -- Window, transform, power, reduce, find the peaks. Callable from a timer callback, and it
  -- YIELDS: the yields inside fft_load_rd and fft_run are what let the display task dispatch
  -- a touch, and at 16,384 samples those two are 0.5 s and 0.8 s of arithmetic.
  function dsp.spectrum(cap, trace, marks)
    if dsp.dirty then return post(dsp.EDIRTY, 'an attribute moved since commit()') end
    if cap == nil or trace == nil then return post(dsp.EARG, 'nil buffer') end
    if not span_ok() then return post(dsp.EARG, 'out.lowfreq is not below out.highfreq') end
    -- Capacity is refused on the first frame rather than at commit: the destination buffer is
    -- not an attribute, so commit() has never seen it. Checked once and remembered.
    if not dsp.capchecked then
      local cp = trace.capacity
      if cp ~= nil and out_s.segments > cp then
        return post(dsp.EARG, 'out.segments ' .. tostring(out_s.segments)
                    .. ' over the trace buffer capacity ' .. tostring(cp))
      end
      if marks ~= nil then
        cp = marks.capacity
        if cp ~= nil and peaks_s.count > cp then
          return post(dsp.EARG, 'peaks.count over the marks buffer capacity')
        end
      end
      dsp.capchecked = true
    end
    local n = fft_s.samples
    -- Short record: nothing written, the previous spectrum left in place, and counted.
    -- Zero-padding the tail would give a convincing and false broadband spectrum, and a
    -- trigger timeout is the ordinary cause.
    if cap.n == nil or cap.n < fft_s.srclength then
      dsp.shortreads = dsp.shortreads + 1
      dsp.nseg = 0
      return 0
    end
    fft_s.binwidth = measured_binwidth(cap, n)
    local binhz = fft_s.binwidth
    fftsa.fft_load(cap)
    fftsa.fft_run()
    fftsa.fft_power()
    local nb = fftsa.fft_m
    local pwr = fftsa.fft_pwr
    local flo, fhi = out_s.lowfreq, out_s.highfreq
    local kmin, kmax = fftsa.sg_window_bins(nb, binhz, flo, fhi)
    dsp.kmin, dsp.kmax = kmin, kmax

    -- The reduction takes the MAXIMUM of the bins a segment covers. At 16,384 samples and
    -- 255 segments each spans 32 bins, and anything but a maximum loses a narrow tone.
    local npts = kmax - kmin + 1
    local ncol = out_s.segments
    local floor, log10 = math.floor, math.log10
    local dbmin, dbmax = out_s.dbfloor, out_s.dbceil
    local vfl = out_s.vfloor * out_s.vfloor
    local fstep = (npts / ncol) * binhz
    local f0 = (kmin - 1) * binhz
    local st_v, st_f = dsp.st_v, dsp.st_f
    if st_v == nil then st_v, st_f = {}, {}; dsp.st_v, dsp.st_f = st_v, st_f end
    local nseg, c = 0, nil
    for c = 0, ncol - 1 do
      local a = kmin + floor(c * npts / ncol)
      local b = kmin + floor((c + 1) * npts / ncol) - 1
      if b < a then b = a end
      if b > kmax then b = kmax end
      local hi, k = nil, nil
      for k = a, b do
        local v = pwr[k]
        if v ~= nil and (hi == nil or v > hi) then hi = v end
      end
      -- Inlined rather than a call per segment: the two dB limits, the squared voltage floor and
      -- math.log10 are hoisted above the loop, and at a measured 1.4 us a table read that
      -- is about 1.8 ms of an 81.8 ms frame over 255 segments.
      --
      -- nil (a sparse power array after a short read) and anything at or below the floor
      -- land on the floor, so log10 is never handed a zero. The range tests are positives
      -- because every comparison with a NaN is false, so `db < dbmin` would pass one through
      -- to buffer.write.reading and a refused parameter is event 1131.
      local val = dbmin
      if hi ~= nil and hi > vfl then
        val = 10 * log10(hi)
        if not (val > dbmin) then val = dbmin
        elseif not (val < dbmax) then val = dbmax end
      end
      nseg = nseg + 1
      -- The segment's own frequency, not the winning bin's: segments can be narrower than a
      -- bin and several would then share one, so only this is strictly increasing.
      st_v[nseg], st_f[nseg] = val, f0 + c * fstep
    end

    local bi, bv = fftsa.find_peaks(nb, peaks_s.count, kmin, kmax)
    dsp.pk_hz, dsp.pk_v, dsp.pk_db = dsp.pk_hz or {}, dsp.pk_v or {}, dsp.pk_db or {}
    local i
    for i = 1, peaks_s.count do
      local k = bi[i]
      dsp.pk_hz[i], dsp.pk_v[i], dsp.pk_db[i] = nil, nil, nil
      if k ~= nil and k > 0 then
        local d, amp = fftsa.peak_interp(k, nb)
        if amp == nil then d, amp = 0, math.sqrt(bv[i]) end
        if amp > 0 then
          dsp.pk_hz[i] = (k - 1 + d) * binhz
          dsp.pk_v[i] = amp
          dsp.pk_db[i] = 20 * log10(amp)
        end
      end
    end

    -- The primitive writes the trace and sets its count; the caller never clears it. A
    -- clear-then-refill from outside opens a window in which the graph paints a half-filled
    -- trace, which is worth designing out rather than working around.
    --
    -- buffer.write.reading HOISTED: looked up inside the loop it is two table reads per
    -- point, 255 x 7 us on the instrument, and those are the only microseconds that fall
    -- inside the window where the buffer holds less than a full trace.
    local wr = buffer.write.reading
    trace.clear()
    for i = 1, nseg do
      wr(trace, st_v[i], st_f[i], i, 0)
    end
    if marks ~= nil then
      marks.clear()
      for i = 1, peaks_s.count do
        if dsp.pk_hz[i] ~= nil then
          wr(marks, seg_value(dsp.pk_v[i] * dsp.pk_v[i]), dsp.pk_hz[i], i, 0)
        end
      end
    end
    dsp.ran = true
    dsp.nseg = nseg
    return nseg
  end

  -- The i'th peak, strongest first. Sub-bin corrected in both frequency and amplitude, which
  -- is the part a caller cannot reproduce from the trace.
  function dsp.peak(i)
    if not dsp.ran then
      post(dsp.EARG, 'no spectrum yet')
      return nil
    end
    if i == nil or i < 1 or i > peaks_s.count then
      post(dsp.EARG, 'peak index ' .. tostring(i))
      return nil
    end
    if dsp.pk_hz[i] == nil then return nil end
    return dsp.pk_hz[i], dsp.pk_v[i], dsp.pk_db[i]
  end

  -- Distortion, signal-to-noise and the noise floor, over the bins the peaks came from.
  -- thd is a FRACTION of the fundamental; snr and floor are dB. Both ratios are nil when
  -- nothing in the span is a tone, and the floor is a number regardless -- with the inputs
  -- disconnected it is the instrument's own noise and the only one of the three that means
  -- anything. A nil thd with a live snr is a tone whose harmonics all fall outside the span.
  function dsp.distortion()
    if not dsp.ran then
      post(dsp.EARG, 'no spectrum yet')
      return nil
    end
    if not span_ok() then
      post(dsp.EARG, 'out.lowfreq is not below out.highfreq')
      return nil
    end
    local nb, binhz = fftsa.fft_m, fft_s.binwidth
    fftsa.thd_hmax = thd_s.harmonics
    fftsa.thd_nsample = thd_s.bins
    if thd_s.bins == 0 then fftsa.thd_nsample = nb end
    -- Both regions, one of them, or neither. 0 is the caller saying the hum is the signal,
    -- expressed to the shipped rule as a frequency no bin in any span is a multiple of.
    -- Refused rather than ignored: a frequency that is neither mains would discount a band
    -- nothing picks up and leave the figures looking plausible over the hole.
    local m = thd_s.mains
    if m == dsp.MAINS_BOTH then
      fftsa.thd_mains = {50, 60}
    elseif m == 50 or m == 60 then
      fftsa.thd_mains = {m, m}
    elseif m == 0 then
      fftsa.thd_mains = {1e12, 1e12}
    else
      post(dsp.EARG, 'thd.mains must be MAINS_BOTH, 50, 60 or 0')
      return nil
    end
    -- The span goes in as arguments. Reading fftsa.sg_flo_hz out of the display module
    -- instead is the seam crossed backwards, and works only while both halves are Lua.
    -- out.dbfloor is not passed: it bounds the trace, not the measured noise floor.
    local thd, ndb, nh, snr = fftsa.thd_noise(nb, binhz, out_s.lowfreq, out_s.highfreq)
    local f0 = nil
    if thd ~= nil then thd = thd / 100 end        -- percent in the TSP, a fraction here
    if snr ~= nil and dsp.pk_hz[1] ~= nil then f0 = dsp.pk_hz[1] end
    return thd, snr, ndb, f0
  end

  -- Release the plan: the arena goes, the attributes keep their values, and nothing runs
  -- until commit() again. A plan-attribute write marks the plan dirty and does NOT come
  -- here -- only this call and a commit that needs a different size free anything, which is
  -- what keeps a re-plan from opening a window where a smaller arena has been given back
  -- and the larger one is not yet allocated.
  --
  -- In Lua the arena is these tables and they are garbage once dropped; natively it is one
  -- allocation, leaked per launch for the rest of the power cycle if nobody releases it.
  -- fftsa.stop() is the caller, and fftsa.start() opens with a stop().
  function dsp.release()
    fftsa.fft_built_n, fftsa.fft_built_win, fftsa.fft_built_beta = nil, nil, nil
    fftsa.fft_x, fftsa.fft_re, fftsa.fft_im, fftsa.fft_pwr = nil, nil, nil, nil
    fftsa.fft_win, fftsa.fft_twr, fftsa.fft_twi = nil, nil, nil
    fftsa.fft_utr, fftsa.fft_uti = nil, nil
    fftsa.fft_swp_a, fftsa.fft_swp_b = nil, nil
    fftsa.fft_gtab, fftsa.fft_dtab = nil, nil
    dsp.st_v, dsp.st_f = nil, nil
    dsp.dirty, dsp.dirty_tables, dsp.dirty_filter = true, true, true
    dsp.built, dsp.ran, dsp.capchecked = false, false, false
    set_times()
    return dsp.OK
  end

  return dsp
end
