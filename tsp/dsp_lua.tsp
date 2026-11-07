-- dsp_lua.tsp -- the app's signal-processing interface, in a table of its own. Lua 5.0.2.
--
-- The whole data path reaches the math through one table, dsp: attributes to configure and
-- one call to run, in the style of dmm.digitize -- commit, spectrum, plan, peak,
-- distortion, release and lastevent, over dsp.fft, dsp.filter, dsp.out, dsp.peaks and
-- dsp.thd. The app cannot reach past it, so an implementation bound under the same names
-- behaves the same or not at all.
--
-- Nothing is installed at load time: the body is a function, so the gate at the head of
-- tsp/spectrum_app.tsp can decline to call it and leave a dsp the instrument already has.
--
-- Every argument the interface says is illegal is refused here too, an implementation
-- kinder than its own rules hiding the defect the rules exist to catch.

fftsa = fftsa or {}   -- the single global this app exposes

function fftsa.dsp_install()
  dsp = {}

  -- Negative, so a caller can test one answer for failure, and fixed rather than an enum
  -- the firmware might number differently.
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

  -- Posted rather than raised, the convention throughout: a raise inside a timer or button
  -- callback posts -286 and leaves the app on screen and dead. One record and a monotonic
  -- count, so a test can assert a refusal posted and a caller can tell a fresh one from a
  -- stale one without the records accumulating across an unattended power cycle.
  dsp.events = {}
  dsp.nevents = 0
  local function post(code, why)
    dsp.nevents = dsp.nevents + 1
    dsp.events[1] = {code = code, why = why}
    return code
  end

  -- The last refusal, as a code and a reason string: what turns a negative integer into
  -- something that can go on the glass, the operator getting "-2" otherwise.
  function dsp.lastevent()
    if dsp.nevents < 1 then return nil end
    return dsp.events[1]
  end

  -- Which class an attribute is in is the whole of what a commit costs:
  --
  --   'tables'  fft.samples, fft.window, fft.beta, filter.decimate -- the window, the
  --             twiddles and the interpolation tables, or the size of the arena. 0.163 ms a
  --             sample, so a measured 2.667 s at 16384.
  --   'filter'  fft.samplerate, filter.state/lowcutoff/highcutoff/order -- no table depends
  --             on them, so a commit that only moved these builds nothing.
  --   'frame'   out.*, peaks.*, thd.* -- read per call, so a span gesture or a mains
  --             setting costs no rebuild at all.
  --
  -- A write that does not change the value dirties nothing, and fftsa.apply() rewrites every
  -- attribute unconditionally on every press and every adopted gesture: without that rule
  -- each of those forces the full rebuild above. The class is per attribute and not per
  -- namespace -- fft.samples and fft.samplerate cost two different things. One proxy a
  -- namespace, so a read crosses one metamethod and no more.
  local set_times
  local function group(settable, readback, classof)
    local store, req, p = {}, {}, {}
    local k, v
    for k, v in pairs(settable) do store[k] = v; req[k] = v end
    for k, v in pairs(readback) do store[k] = v end
    setmetatable(p, {
      __index = function(_, key) return store[key] end,
      __newindex = function(_, key, val)
        -- An unknown name is refused: a typo on a settings attribute is otherwise invisible
        -- until the spectrum looks wrong.
        if settable[key] == nil then
          post(dsp.EARG, 'not a settable attribute: ' .. tostring(key))
          return
        end
        -- Against the request, not the read-back: filter.decimate reads back the decimation
        -- chosen while the request is still 0, so comparing read-backs would make rewriting
        -- 0 look like a change from 4 and dirty the plan on every press.
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
  -- window nor the twiddles. filter.decimate is expensive despite sitting among the
  -- filter's attributes, because it sizes the arena.
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
  -- dbfloor defaults to -140 because the default has to clear the quietest front end in the
  -- family: a DMM7510 measures -134 dBV on its 0.1 V range. The app sets it every frame
  -- from its own axis, so the default only matters to another caller.
  dsp.out, out_s = group({segments = 255, lowfreq = 10, highfreq = 50000,
                          dbfloor = -140, dbceil = 20, vfloor = 1e-9}, {}, 'frame')
  dsp.peaks, peaks_s = group({count = 6}, {}, 'frame')
  dsp.thd, thd_s = group({harmonics = 20, mains = dsp.MAINS_BOTH, bins = 1024}, {}, 'frame')

  dsp.dirty = true            -- no plan until commit() has run
  dsp.dirty_tables = true
  dsp.dirty_filter = true
  dsp.built = false           -- whether a plan exists at all, which release() takes away
  dsp.shortreads = 0          -- captures too short to transform, counted per the edge cases
  dsp.ran = false             -- whether a spectrum exists for peak() and distortion()
  dsp.builds = 0              -- table rebuilds a commit has done, for the cost tests

  -- 0.163 ms a sample, measured; docs/PERFORMANCE.md has it. Zero when the tables are
  -- already the ones in force, so a caller can tell a commit it must cover the screen for
  -- from one it need not.
  local function commit_cost(n)
    -- The tables are the interpreted transform's, and that module is not in the archive.
    if fftsa.fft_init == nil then return 0 end
    if dsp.dirty_tables or not dsp.built then return 0.163e-3 * (n or 0) end
    return 0
  end

  -- Seconds one spectrum() costs at the plan in force, the model docs/PERFORMANCE.md
  -- calibrates: 1.63 s at 16384 against 1.686 measured. The whole frame and not the
  -- transform alone, because that is what it was calibrated against.
  local function spectrum_cost(n)
    -- A model of the interpreted frame describes nothing without that module: zero, and
    -- frame_estimate falls through to its own floor. Modelled 0.407 s at 4096 against a
    -- compiled frame of 0.037.
    if fftsa.fft_init == nil then return 0 end
    if n == nil or n < 2 then n = 512 end
    local log2n = math.log(n) / 0.69314718055995
    return n * 46.6e-6 + 3.593e-6 * n * log2n + 0.04
  end

  set_times = function()
    fft_s.committime = commit_cost(fft_s.samples)
  end
  set_times()

  -- The enum back to the picker index: the other half of the map, fftsa.win_to_dsp, is in
  -- tsp/spectrum_app.tsp. That the two coincide today is a coincidence.
  local win_of = {}
  win_of[dsp.WINDOW_HANN] = 1
  win_of[dsp.WINDOW_BLACKMAN] = 2
  win_of[dsp.WINDOW_BLACKMAN_HARRIS] = 3
  win_of[dsp.WINDOW_KAISER] = 4

  -- One of the six betas the Lua window builder has tables for. The C library takes any
  -- beta in its range, so this is that implementation's limit and not the interface's.
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

  -- The span, read per call rather than at commit, and passed to the bin-window arithmetic
  -- as arguments: fftsa.sg_window_bins is the single owner of the ceil/floor convention, so
  -- nothing about the display reaches in here and nothing here reaches back out.
  local function span_ok()
    local flo, fhi = out_s.lowfreq, out_s.highfreq
    return (fhi > flo) and (flo >= 0)
  end

  -- Build the window, the interpolation tables, the twiddles and the filter taps: the slow
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

    -- The rate has to be known here: the decimation, the tap count and so srclength all
    -- follow from it, and the caller needs srclength before it acquires.
    local fs = fft_s.samplerate
    if type(fs) ~= 'number' or not (fs > 0) then
      return post(dsp.EARG, 'fft.samplerate is needed to place the band and the taps')
    end

    -- Refused rather than ignored: a filter silently left out reads as a flat passband that
    -- is really the unfiltered record aliased into the band.
    if filter_s.state ~= dsp.OFF and filter_s.state ~= false then
      return post(dsp.EUNSUPPORTED, 'no filter in this implementation')
    end
    local binhz = fs / n

    -- Set before fft_init, which keys its cache on them, and on every commit so the two
    -- cannot drift even when the rebuild below is skipped.
    fftsa.win_i, fftsa.kbeta_i = wi, bi
    -- The expensive call, and only when something it is built from moved. Guarded because
    -- tsp/fft_interp.tsp is not in the archive: a commit still has to settle srclength and
    -- the bin width for the caller about to acquire, transform or no transform.
    if (dsp.dirty_tables or not dsp.built) and fftsa.fft_init ~= nil then
      fftsa.fft_init(n)
      dsp.builds = dsp.builds + 1
    end
    -- With no filter the record the caller must acquire is the transform length itself.
    fft_s.srclength = n
    -- Provisional: spectrum() replaces it with the rate measured off the capture's own
    -- timestamps, which is the only timebase the instrument has.
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


  -- Release the plan: the arena goes, the attributes keep their values, and nothing runs
  -- until commit() again. A plan-attribute write only marks the plan dirty, so nothing is
  -- freed outside this call and a commit that needs a different size -- which is what keeps
  -- a re-plan from opening a window with the smaller arena given back and the larger one
  -- not yet allocated. Natively the arena is one allocation, leaked for the rest of the
  -- power cycle if nobody releases it; fftsa.start() opens with the stop() that does.
  function dsp.release()
    -- Absent from the archive, so there is nothing of the interpreted arena to give back.
    if type(fftsa.dsp_release_math) == 'function' then fftsa.dsp_release_math() end
    dsp.st_v, dsp.st_f = nil, nil
    dsp.dirty, dsp.dirty_tables, dsp.dirty_filter = true, true, true
    dsp.built, dsp.ran, dsp.capchecked = false, false, false
    set_times()
    return dsp.OK
  end


  -- The transform, the peak search and the distortion figures are not in this archive:
  -- csrc/ does that work on the instrument, so package_tspa.py leaves tsp/fft_interp.tsp
  -- out and dsp.spectrum, dsp.peak and dsp.distortion are nil here -- which the app's
  -- callers test for. Bound when the harness has loaded that module, which is what keeps
  -- the arithmetic tools/test_tsp.lua pins pinned to a real implementation.
  if type(fftsa.dsp_install_math) == 'function' then
    fftsa.dsp_install_math(dsp, {post = post, span_ok = span_ok, fft_s = fft_s,
                                 out_s = out_s, peaks_s = peaks_s, thd_s = thd_s})
  end

  return dsp
end
