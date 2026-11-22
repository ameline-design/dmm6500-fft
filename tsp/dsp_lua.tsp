-- DSP attributes and plan lifecycle. The app installs this shim only if firmware has no DSP API.

fftsa = fftsa or {}

function fftsa.dsp_install()
  dsp = {}

  dsp.OK, dsp.EARG, dsp.EPOW2, dsp.ENOMEM = 0, -1, -2, -3
  dsp.EUNSUPPORTED, dsp.ESHORT, dsp.EBETA = -4, -5, -6
  dsp.EDECLINE, dsp.EALIGN, dsp.EZONE = -7, -8, -9
  -- Lua-only status for a plan invalidated by an attribute write.
  dsp.EDIRTY = -10

  dsp.WINDOW_RECT, dsp.WINDOW_HANN, dsp.WINDOW_BLACKMAN = 0, 1, 2
  dsp.WINDOW_BLACKMAN_HARRIS, dsp.WINDOW_KAISER = 3, 4
  dsp.OFF, dsp.ON = 0, 1
  dsp.MAINS_BOTH = -1

  dsp.version = 1

  -- Timer callbacks return error codes instead of throwing. Keep only the latest event.
  dsp.events = {}
  dsp.nevents = 0
  local function post(code, why)
    dsp.nevents = dsp.nevents + 1
    dsp.events[1] = {code = code, why = why}
    return code
  end

  function dsp.lastevent()
    if dsp.nevents < 1 then return nil end
    return dsp.events[1]
  end

  -- Plan changes either rebuild tables or refresh filter metadata. Frame attributes
  -- take effect immediately. Rewriting the same request invalidates nothing.
  local set_times
  local function group(settable, readback, classof)
    local store, req, p = {}, {}, {}
    local k, v
    for k, v in pairs(settable) do store[k] = v; req[k] = v end
    for k, v in pairs(readback) do store[k] = v end
    setmetatable(p, {
      __index = function(_, key) return store[key] end,
      __newindex = function(_, key, val)
        if settable[key] == nil then
          post(dsp.EARG, 'not a settable attribute: ' .. tostring(key))
          return
        end
        -- Compare requests, not readback: automatic decimation can report a different value.
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
  -- The default floor accommodates the DMM7510's 0.1 V range; the app sets its own floor.
  dsp.out, out_s = group({segments = 255, lowfreq = 10, highfreq = 50000,
                          dbfloor = -140, dbceil = 20, vfloor = 1e-9}, {}, 'frame')
  dsp.peaks, peaks_s = group({count = 6}, {}, 'frame')
  dsp.thd, thd_s = group({harmonics = 20, mains = dsp.MAINS_BOTH, bins = 1024}, {}, 'frame')

  dsp.dirty = true
  dsp.dirty_tables = true
  dsp.dirty_filter = true
  dsp.built = false
  dsp.shortreads = 0          -- captures too short to transform, counted per the edge cases
  dsp.ran = false
  dsp.builds = 0

  -- Estimated seconds to rebuild the interpreted tables; zero if absent or up to date.
  local function commit_cost(n)
    if fftsa.fft_init == nil then return 0 end
    if dsp.dirty_tables or not dsp.built then return 0.163e-3 * (n or 0) end
    return 0
  end

  -- Estimated seconds for an interpreted frame, including acquisition and plotting.
  local function spectrum_cost(n)
    if fftsa.fft_init == nil then return 0 end
    if n == nil or n < 2 then n = 512 end
    local log2n = math.log(n) / 0.69314718055995
    return n * 46.6e-6 + 3.593e-6 * n * log2n + 0.04
  end

  set_times = function()
    fft_s.committime = commit_cost(fft_s.samples)
  end
  set_times()

  -- Map DSP window enum back to the picker index.
  local win_of = {}
  win_of[dsp.WINDOW_HANN] = 1
  win_of[dsp.WINDOW_BLACKMAN] = 2
  win_of[dsp.WINDOW_BLACKMAN_HARRIS] = 3
  win_of[dsp.WINDOW_KAISER] = 4

  -- The interpreted builder accepts the six picker betas; the C library accepts a range.
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

  local function span_ok()
    local flo, fhi = out_s.lowfreq, out_s.highfreq
    return (fhi > flo) and (flo >= 0)
  end

  -- Commit the plan and publish the capture size before acquisition.
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

    local fs = fft_s.samplerate
    if type(fs) ~= 'number' or not (fs > 0) then
      return post(dsp.EARG, 'fft.samplerate is needed to place the band and the taps')
    end

    -- Reject a filter request rather than returning an unfiltered, potentially aliased spectrum.
    if filter_s.state ~= dsp.OFF and filter_s.state ~= false then
      return post(dsp.EUNSUPPORTED, 'no filter in this implementation')
    end
    local binhz = fs / n

    -- Update the window key even when the interpreted tables do not need rebuilding.
    fftsa.win_i, fftsa.kbeta_i = wi, bi
    -- Without the optional interpreted transform, commit still publishes the capture geometry.
    if (dsp.dirty_tables or not dsp.built) and fftsa.fft_init ~= nil then
      fftsa.fft_init(n)
      dsp.builds = dsp.builds + 1
    end
    fft_s.srclength = n
    -- Provisional until capture timestamps supply the actual rate.
    fft_s.binwidth = binhz
    fft_s.binzerohz, fft_s.binsense, fft_s.zone = 0, 1, 0
    fft_s.spectrumtime = spectrum_cost(n)
    -- Keep the request and the effective filter settings separate.
    filter_s.decimate, filter_s.ntaps = 1, 0
    dsp.nbins = n / 2
    dsp.dirty, dsp.dirty_tables, dsp.dirty_filter = false, false, false
    dsp.built = true
    dsp.ran = false
    dsp.capchecked = false
    set_times()
    return dsp.OK
  end

  -- Invalidate the plan and results without resetting requested attributes.
  function dsp.release()
    if type(fftsa.dsp_release_math) == 'function' then fftsa.dsp_release_math() end
    dsp.st_v, dsp.st_f = nil, nil
    dsp.dirty, dsp.dirty_tables, dsp.dirty_filter = true, true, true
    dsp.built, dsp.ran, dsp.capchecked = false, false, false
    set_times()
    return dsp.OK
  end

  -- The instrument archive ships native math only; the offline harness can bind interpreted math.
  if type(fftsa.dsp_install_math) == 'function' then
    fftsa.dsp_install_math(dsp, {post = post, span_ok = span_ok, fft_s = fft_s,
                                 out_s = out_s, peaks_s = peaks_s, thd_s = thd_s})
  end

  return dsp
end
