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
  -- One record, not a list. nevents stays monotonic, so a test can assert that a refusal
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
  -- dbfloor defaults to -140, not -120: the default has to clear the quietest front end in
  -- the family, and a DMM7510 measures -134 dBV on its 0.1 V range. A caller that sets it --
  -- which the app does every frame, from its own axis -- is unaffected.
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

  -- 0.163 ms a sample, measured; docs/PERFORMANCE.md has it. Zero when the tables a commit
  -- would build are already the ones in force, which is every adopted gesture and most
  -- presses -- so a caller can tell a commit it has to cover the screen for from one it
  -- does not.
  local function commit_cost(n)
    -- Nothing to build when tsp/fft_interp.tsp is not in the archive, which is the shipped
    -- case: the tables this cost is for are the interpreted transform's.
    if fftsa.fft_init == nil then return 0 end
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
    -- The model is of the INTERPRETED frame, so it describes nothing when that module is not
    -- in the archive. Zero, and frame_estimate falls through to its own floor: the modelled
    -- period was 0.407 s at 4096 against a real compiled frame of 0.037.
    if fftsa.fft_init == nil then return 0 end
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
    -- Guarded, because tsp/fft_interp.tsp is not in the archive: a commit still has to
    -- settle srclength and the bin width for the caller that is about to acquire, whether or
    -- not anything here can transform the record.
    if (dsp.dirty_tables or not dsp.built) and fftsa.fft_init ~= nil then
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
    -- The interpreted implementation's arena, where that module is loaded at all. In the
    -- archive it is absent, so there is nothing of its to give back.
    if type(fftsa.dsp_release_math) == 'function' then fftsa.dsp_release_math() end
    dsp.st_v, dsp.st_f = nil, nil
    dsp.dirty, dsp.dirty_tables, dsp.dirty_filter = true, true, true
    dsp.built, dsp.ran, dsp.capchecked = false, false, false
    set_times()
    return dsp.OK
  end


  -- The transform, the peak search and the distortion figures are NOT in this archive.
  -- tsp/fft_interp.tsp carries them and package_tspa.py leaves it out, because csrc/ does
  -- that work on the instrument -- so dsp.spectrum, dsp.peak and dsp.distortion are nil
  -- here and the app's callers test for the native results instead of asking for them.
  -- Bound when the harness has loaded that module, which is what keeps the pinned
  -- arithmetic in tools/test_tsp.lua pinned to a real implementation.
  if type(fftsa.dsp_install_math) == 'function' then
    fftsa.dsp_install_math(dsp, {post = post, span_ok = span_ok, fft_s = fft_s,
                                 out_s = out_s, peaks_s = peaks_s, thd_s = thd_s})
  end

  return dsp
end
