-- fft_interp.tsp -- the interpreted FFT, and the one module deliberately left out of the
-- archive.
--
-- Everything the compiled image replaces lives here: the window build, the interpolation
-- tables, the transform, the power pass and the peak interpolation. package_tspa.py does not
-- list it, so it reaches no instrument, and test_tsp.lua does, so the offline gates drive a
-- real spectrum rather than a stub. It is the reference implementation and the test oracle,
-- maintained as shipped code even though it does not ship.
--
-- Loaded after fft_core.tsp, which holds the window enums these read. dsp_lua.tsp tests for
-- fftsa.fft_init before using any of it, so an archive without this module commits plans and
-- refuses to transform rather than raising.
fftsa = fftsa or {}   -- the single global this app exposes

fftsa.fft_n      = 0      -- number of samples N (power of two)
fftsa.fft_m      = 0      -- N/2: the complex transform size, and the number of bins
fftsa.fft_x      = nil    -- raw samples 1..N, staged between the two load passes
fftsa.fft_re     = nil    -- packed complex working array, real parts, 1..M
fftsa.fft_im     = nil    -- imaginary parts, 1..M
fftsa.fft_win    = nil    -- analysis window, 1..N
fftsa.fft_pwr    = nil    -- power output, 1..M, volts-squared (peak)
fftsa.fft_swp_a  = nil    -- bit-reversal swap pairs over 1..M
fftsa.fft_swp_b  = nil
fftsa.fft_nswp   = 0
fftsa.fft_twr    = nil    -- flattened butterfly twiddles, stage-major
fftsa.fft_twi    = nil
fftsa.fft_utr    = nil    -- untangle twiddles e^(-2*pi*i*k/N), k = 0..M-1
fftsa.fft_uti    = nil
-- Coherent gain, the mean window sample. A window identity worth pinning, and
-- tools/test_tsp.lua and tools/make_refs.lua do; no shipped module reads it. The
-- amplitude calibration is fftsa.fft_ksq, from the window sum.
fftsa.fft_cg     = 0.5
fftsa.fft_ksq    = 0      -- power scale applied to the untangled |2X|^2
function fftsa.bessel_i0(x)
  local hh = (x / 2) * (x / 2)
  local t, s = 1, 1
  for k = 1, 40 do
    t = t * hh / (k * k)
    s = s + t
    if t < s * 1e-17 then return s end
  end
  return s
end

-- Build fftsa.fft_win and the amplitude scale from it. Symmetric, so only half the
-- samples are computed. The scale comes from the window sum, and assuming N/2 for
-- Hann rather than summing it reads every amplitude 0.2 % low at N = 512.
function fftsa.win_build(N)
  local cos, sqrt, floor, pi = math.cos, math.sqrt, math.floor, math.pi
  local w    = {}
  local c    = fftsa.win_cos[fftsa.win_i]
  local half = floor((N + 1) / 2)
  if c ~= nil then
    local a0, a1, a2, a3 = c[1], c[2] or 0, c[3] or 0, c[4] or 0
    local step = 2 * pi / (N - 1)
    for i = 1, half do
      local t = step * (i - 1)
      local v = a0 - a1*cos(t) + a2*cos(2*t) - a3*cos(3*t)
      w[i] = v
      w[N + 1 - i] = v
    end
  else
    local b   = fftsa.kbeta()
    local i0b = fftsa.bessel_i0(b)
    for i = 1, half do
      local u = 2*(i-1)/(N-1) - 1
      local s = 1 - u*u
      if s < 0 then s = 0 end
      local v = fftsa.bessel_i0(b * sqrt(s)) / i0b
      w[i] = v
      w[N + 1 - i] = v
    end
  end
  fftsa.fft_win = w
  local wsum = 0
  for i = 1, N do wsum = wsum + w[i] end
  fftsa.fft_wsum = wsum           -- fftsa.fft_load() divides by it to weight the mean
  fftsa.fft_cg = wsum / N
  -- Volts would be 2/(N*cg); the untangle leaves every bin doubled, so 1/(N*cg),
  -- squared because the output is power.
  local k = 1 / wsum
  fftsa.fft_ksq = k * k
  return w
end

-- ===================== peak interpolation, per window =====================
-- A tone at bin k+d puts the three bins around the peak at -d, 1-d and 1+d on the
-- window's own transform, so with
--   G(x) = |sum w[i]*cos(2*pi*x*(i-c)/N)| / sum w[i],    c = (N+1)/2
-- the normalised main lobe, the ratio r = (R-L)/(L+2C+R) is a fixed odd function of d and
-- the scalloping loss is exactly G(d). fft_gtab samples G out to 1.5 bins and fft_dtab
-- inverts it to r -> d. Both come from the window samples in use, so a window change
-- needs no new constants; the grids put d, 1-d and 1+d on gtab nodes.
fftsa.fft_ghx  = 0.025    -- gtab step, in bins
fftsa.fft_gn   = 60       -- gtab spans 0 .. fft_gn*fft_ghx = 1.5 bins
fftsa.fft_dn   = 40       -- dtab nodes, spaced uniformly in r
fftsa.fft_gtab = nil
fftsa.fft_dtab = nil
fftsa.fft_dhr  = 0        -- dtab step in r; 0 means there is no usable table
fftsa.win_mono = false    -- r(d) rose all the way to half a bin

-- Bins above DC that the mean removal in fftsa.fft_load() makes unreportable, and
-- the amplitude error that decides which they are. Set by fftsa.win_tables(), read
-- by fftsa.find_peaks(). 0 before the first fftsa.fft_init().
fftsa.fft_dctol = 0.05    -- 5 % of amplitude, 0.45 dB
fftsa.fft_kdc   = 0
fftsa.fft_kdcn  = 6       -- bins scanned; covers Kaiser b=18's 5.82-bin main lobe

-- Costs (fft_gn+1)*N/2 cosines at init and nothing per frame.
function fftsa.win_tables(N)
  local cos, floor = math.cos, math.floor
  local w   = fftsa.fft_win
  local M2  = floor(N / 2)            -- N is a power of two, so every sample pairs
  local ctr = (N + 1) / 2
  local hx  = fftsa.fft_ghx
  local nx  = fftsa.fft_gn
  local wsum = 0
  for i = 1, M2 do wsum = wsum + w[i] end
  wsum = 2 * wsum

  local g = {}
  local twopi_N = 2 * math.pi / N
  for j = 0, nx do
    local a = twopi_N * j * hx
    local s = 0
    for i = 1, M2 do s = s + w[i] * cos(a * (i - ctr)) end
    s = 2 * s / wsum
    if s < 0 then s = -s end
    g[j+1] = s
  end
  fftsa.fft_gtab = g

  -- r at every d node. one and nd are node counts, not lengths: 1 bin and half a bin.
  local one = floor(1/hx + 0.5)
  local nd  = floor(0.5/hx + 0.5)
  -- The grid has to reach 1 + 0.5 bins, and at the shipped values it reaches exactly
  -- that. Shrinking fft_gn without raising fft_ghx would read past the end of gtab
  -- and do arithmetic on a nil, so it fails here instead.
  if one + nd > nx then
    error("fft_gn " .. nx .. " is too small for fft_ghx " .. hx
          .. ": the gain table must reach 1.5 bins", 0)
  end
  local rt  = {}
  for jd = 0, nd do
    local C, R, L = g[jd+1], g[one-jd+1], g[one+jd+1]
    rt[jd+1] = (R - L) / (L + 2*C + R)
  end

  -- Invert onto a grid uniform in r, so a lookup is an index rather than a search.
  local mono = true
  for jd = 1, nd do
    if rt[jd+1] <= rt[jd] then mono = false end
  end
  fftsa.win_mono = mono
  local nr   = fftsa.fft_dn
  local rmax = rt[nd+1]
  local dt   = {}
  if mono and rmax > 0 then
    local hr = rmax / nr
    local jd = 0
    for m = 0, nr do
      local target = m * hr
      while jd < nd - 1 and rt[jd+2] < target do jd = jd + 1 end
      local r0, r1 = rt[jd+1], rt[jd+2]
      local f = 0
      if r1 > r0 then f = (target - r0) / (r1 - r0) end
      dt[m+1] = (jd + f) * hx
    end
    dt[nr+1] = nd * hx                -- the top of the table is exactly half a bin
    fftsa.fft_dhr = hr
  else
    fftsa.fft_dhr = 0
  end
  fftsa.fft_dtab = dt

  -- How far up from DC fftsa.fft_load()'s mean removal reaches, which is where
  -- fftsa.find_peaks() stops reporting. Removing a weighted mean of
  -- D + A*G(b)*cos(phase) takes 2*A*G(b)^2 out of the tone's own bin: at bin 1 a
  -- 1.000 V tone reads 0.589 V under Hann. The largest b, not the first, since G is
  -- not monotonic.
  local kdc = 0
  for b = 1, fftsa.fft_kdcn do
    local a = twopi_N * b
    local s = 0
    for i = 1, M2 do s = s + w[i] * cos(a * (i - ctr)) end
    s = 2 * s / wsum
    if 2 * s * s > fftsa.fft_dctol then kdc = b end
  end
  fftsa.fft_kdc = kdc
  return g, dt
end

-- Scalloping loss at offset d: the factor a tone's amplitude is read low by.
function fftsa.win_gain(d)
  local g = fftsa.fft_gtab
  if g == nil then return 1 end
  if d < 0 then d = -d end
  local t = d / fftsa.fft_ghx
  local m = math.floor(t)
  if m >= fftsa.fft_gn then return g[fftsa.fft_gn + 1] end
  local a = g[m+1]
  return a + (t - m) * (g[m+2] - a)
end

-- Sub-bin offset from the three-bin ratio r, by table inversion. Past the end of the
-- table the three bins are not one tone, and the offset saturates at half a bin.
function fftsa.win_offset(r)
  local hr = fftsa.fft_dhr
  if hr == nil or hr <= 0 then return nil end
  local neg = false
  if r < 0 then r = -r; neg = true end
  local nr = fftsa.fft_dn
  local d
  local t = r / hr
  local m = math.floor(t)
  if m >= nr then
    d = fftsa.fft_dtab[nr+1]
  else
    local a = fftsa.fft_dtab[m+1]
    d = a + (t - m) * (fftsa.fft_dtab[m+2] - a)
  end
  if neg then return -d end
  return d
end

-- Everything built here is a function of N and the window alone -- no rate, no span -- so a
-- call changing neither has nothing to do. That is the whole of the pause after an adopted
-- gesture: 0.163 ms a sample, which is 83 ms at 512 and a measured 2.667 s at 16384.
-- Keyed on the window indices, all win_build() reads; win_tables() also reads the five
-- interpolation constants, left out because nothing in the tree assigns them and a grid too
-- short raises. Cleared on the way in, so a raise part way is not taken for a finished build.
fftsa.fft_built_n = nil

function fftsa.fft_init(N)
  -- The tables are asked for alongside the three keys, because the keys outlive them.
  -- This file's own body nils fft_x, fft_re, fft_im and fft_pwr while fftsa itself
  -- survives, so re-running the modules -- which opening the app as an installed App does
  -- -- leaves the keys describing tables that are gone. The memo then reports the
  -- transform ready and the first frame indexes a nil array: "attempt to index local `re'
  -- (a nil value)", once a frame, with the failed-frame path re-pinning the axes after
  -- each one. dsp.release() clears the keys with the tables and is not the only way they
  -- part company.
  if fftsa.fft_built_n == N and fftsa.fft_built_win == fftsa.win_i
     and fftsa.fft_built_beta == fftsa.kbeta_i
     and fftsa.fft_x ~= nil and fftsa.fft_re ~= nil and fftsa.fft_im ~= nil
     and fftsa.fft_pwr ~= nil and fftsa.fft_win ~= nil
     and fftsa.fft_swp_a ~= nil and fftsa.fft_twr ~= nil and fftsa.fft_utr ~= nil then
    return
  end
  fftsa.fft_built_n = nil
  local floor, sin, cos, pi = math.floor, math.sin, math.cos, math.pi
  local M = floor(N / 2)
  fftsa.fft_n   = N
  fftsa.fft_m   = M
  fftsa.fft_x   = {}
  fftsa.fft_re  = {}
  fftsa.fft_im  = {}
  fftsa.fft_pwr = {}

  fftsa.win_build(N)
  fftsa.win_tables(N)

  -- Bit-reversal as a swap list; only the pairs that move are kept.
  fftsa.fft_swp_a = {}
  fftsa.fft_swp_b = {}
  local n = 0
  local j = 0
  for i = 0, M-2 do
    if i < j then
      n = n + 1
      fftsa.fft_swp_a[n] = i + 1
      fftsa.fft_swp_b[n] = j + 1
    end
    local kk = floor(M/2)
    while kk <= j do j = j - kk; kk = floor(kk/2) end
    j = j + kk
  end
  fftsa.fft_nswp = n

  -- Butterfly twiddles for every stage, flattened: the stage with half-length h
  -- occupies the next h entries.
  fftsa.fft_twr = {}
  fftsa.fft_twi = {}
  local idx = 0
  local len = 4                  -- stage 1 (len=2) needs no twiddles
  while len <= M do
    local half = floor(len/2)
    local ang  = -2*pi/len
    for m = 0, half-1 do
      idx = idx + 1
      fftsa.fft_twr[idx] = cos(ang*m)
      fftsa.fft_twi[idx] = sin(ang*m)
    end
    len = len * 2
  end

  fftsa.fft_utr = {}
  fftsa.fft_uti = {}
  local ang = -2*pi/N
  for jj = 1, M do
    fftsa.fft_utr[jj] = cos(ang*(jj-1))
    fftsa.fft_uti[jj] = sin(ang*(jj-1))
  end
  -- Last, so that only a complete build is remembered.
  fftsa.fft_built_n = N
  fftsa.fft_built_win, fftsa.fft_built_beta = fftsa.win_i, fftsa.kbeta_i
end

-- The display task shares this core with the interpreter and runs only while Lua is
-- blocked, so a stretch with no delay() in it cannot dispatch a touch -- and at 16384
-- samples fft_load and fft_run are 0.5 s and 0.8 s of arithmetic. Hence many yield points
-- rather than one long one, placed where the enclosing loop is cheap so the per-sample
-- inner loops are untouched.
fftsa.fft_yield     = 0.005   -- seconds blocked at a yield point
fftsa.fft_yield_n   = 2048    -- fft_load samples between yields
fftsa.fft_yield_m   = 1024    -- fft_run yields per stage only above this half-length

-- Load N samples from a reading buffer, remove DC, window, and pack sample pairs into the M
-- complex points. Returns the mean.
function fftsa.fft_load(buf)
  return fftsa.fft_load_rd(buf.readings)
end

-- The same from a plain array of readings, which is where the weighted-mean removal and the
-- windowing live, in one copy. Two passes, because the mean has to be known before it is
-- subtracted, and the samples are staged in fftsa.fft_x, a buffer element costing far more
-- to read than a table entry.
--
-- The mean is window-weighted, sum(w*x)/sum(w). What has to vanish is the DC of the sequence
-- the transform sees, sum(w*(x-m)) = sum(w*x) - m*sum(w), and only the weighted mean makes
-- it: the arithmetic mean zeroes the true DC instead and leaves the window's own DC response
-- spread over the first few bins, a 1.000 V tone at bin 10.5 leaving a -27 dBc line at bin 1
-- against -147 here. The price is that near DC the estimate is the tone, so win_tables()
-- measures how far that reaches and find_peaks() stops reporting there.
function fftsa.fft_load_rd(rd)
  local N   = fftsa.fft_n
  local M   = fftsa.fft_m
  local x   = fftsa.fft_x
  local re  = fftsa.fft_re
  local im  = fftsa.fft_im
  local win = fftsa.fft_win

  local wsx = 0
  -- Chunked so the yield is per chunk, not per sample: a test inside this loop would
  -- cost more than the yields save. One chunk means no yield, which is the 512 case.
  local chunk = fftsa.fft_yield_n
  local lo = 1
  while lo <= N do
    local hi = lo + chunk - 1
    if hi > N then hi = N end
    local i
    for i = lo, hi do
      local v = rd[i]
      -- A sparse buffer must not put nils into the arithmetic; fftsa.frame_body()
      -- rejects a short capture before it gets here.
      if v == nil then v = 0 end
      x[i] = v
      wsx = wsx + v * win[i]
    end
    lo = hi + 1
    if lo <= N then delay(fftsa.fft_yield) end
  end
  local mean = wsx / fftsa.fft_wsum

  local i = 1
  for k = 1, M do
    re[k] = (x[i] - mean) * win[i]
    im[k] = (x[i+1] - mean) * win[i+1]
    i = i + 2
  end
  return mean
end

function fftsa.fft_run()
  local M     = fftsa.fft_m
  local re    = fftsa.fft_re
  local im    = fftsa.fft_im
  local swp_a = fftsa.fft_swp_a
  local swp_b = fftsa.fft_swp_b
  local twr   = fftsa.fft_twr
  local twi   = fftsa.fft_twi
  local floor = math.floor

  for s = 1, fftsa.fft_nswp do
    local a, b = swp_a[s], swp_b[s]
    re[a], re[b] = re[b], re[a]
    im[a], im[b] = im[b], im[a]
  end

  -- Stage 1: len = 2, twiddle == 1+0i, so pure add/sub.
  for i = 1, M, 2 do
    local ar, ai, br, bi = re[i], im[i], re[i+1], im[i+1]
    re[i]   = ar + br
    im[i]   = ai + bi
    re[i+1] = ar - br
    im[i+1] = ai - bi
  end

  local len  = 4
  local base = 0
  while len <= M do
    local half = floor(len/2)
    for i = 0, M-1, len do
      local ti = base
      for m = 1, half do
        ti = ti + 1
        local a  = i + m
        local b  = a + half
        local wr, wi = twr[ti], twi[ti]
        local xr, xi = re[b], im[b]
        local vr = xr*wr - xi*wi
        local vi = xr*wi + xi*wr
        local ar, ai = re[a], im[a]
        re[b] = ar - vr
        im[b] = ai - vi
        re[a] = ar + vr
        im[a] = ai + vi
      end
    end
    base = base + half
    len  = len * 2
    if M > fftsa.fft_yield_m then delay(fftsa.fft_yield) end
  end
end

-- Untangle the half-size transform into the N/2 real-input bins and write their power,
-- volts-squared peak, into fftsa.fft_pwr[1..M]. Bin j is the frequency (j-1)*fs/N.
--
-- With Z the M-point transform of the packed input and Zc the conjugate of Z at the
-- mirror index (M-k) mod M,
--   X[k] = (Z + Zc)/2 + e^(-2*pi*i*k/N) * (Z - Zc)/(2i)
-- Bins k and M-k share the same four loads, so the pass walks mirror pairs; bin 0 and
-- bin M/2 are their own mirrors.
function fftsa.fft_power()
  local M    = fftsa.fft_m
  local re   = fftsa.fft_re
  local im   = fftsa.fft_im
  local pwr  = fftsa.fft_pwr
  local utr  = fftsa.fft_utr
  local uti  = fftsa.fft_uti
  local ksq  = fftsa.fft_ksq
  local half = M / 2
  -- j = 1 is bin 0: X = Re Z[0] + Im Z[0], real
  local a, b = re[1], im[1]
  local s = 2 * (a + b)
  pwr[1] = s * s * ksq
  -- j = half+1 is bin M/2: its own mirror with twiddle -i, X = Re Z - i Im Z
  a, b = re[half+1], im[half+1]
  pwr[half+1] = 4 * (a*a + b*b) * ksq
  local pj = M + 1                 -- mirror of j is M - j + 2
  for j = 2, half do
    pj = pj - 1
    local a, b = re[j], im[j]
    local c, d = re[pj], im[pj]
    local wr, wi = utr[j], uti[j]
    local s1, s2, d1, d2 = a + c, b + d, a - c, b - d
    local t1 = wr*s2 + wi*d1
    local t2 = wi*s2 - wr*d1
    local xr, xi = s1 + t1, d2 + t2
    pwr[j] = (xr*xr + xi*xi) * ksq
    xr, xi = s1 - t1, t2 - d2
    pwr[pj] = (xr*xr + xi*xi) * ksq
  end
  return M
end

-- Sub-bin peak estimate from the peak bin and its two neighbours. From the peak bin
-- alone a tone between centres is off by up to half a bin and low by the scalloping loss,
-- 1.42 dB with Hann; both come back from the window's own main lobe. Returns d in
-- -0.5..0.5 and volts, or 0 and nil at a spectrum edge, where callers use the bin.
function fftsa.peak_interp(k, nb)
  local pwr = fftsa.fft_pwr
  if k == nil or k < 2 then return 0, nil end
  if nb ~= nil and k >= nb then return 0, nil end
  local pc = pwr[k]
  local pl = pwr[k-1]
  local pr = pwr[k+1]
  if pc == nil or pl == nil or pr == nil or pc <= 0 then return 0, nil end
  local sqrt = math.sqrt
  local C, L, R = sqrt(pc), sqrt(pl), sqrt(pr)
  local den = L + 2*C + R
  if den <= 0 then return 0, nil end
  local d = fftsa.win_offset((R - L) / den)
  if d == nil then return 0, nil end           -- no table: no estimate
  local g = fftsa.win_gain(d)
  if g <= 0 then return d, C end
  return d, C / g
end

-- ===========================================================================
-- The interpreted peak search and distortion figures.
--
-- Here rather than in tsp/spectrum_ui.tsp because this module is not packaged:
-- package_tspa.py asserts it out of the archive, csrc/ doing this work on the instrument.
-- tools/test_tsp.lua loads it as the reference the compiled path is checked against, which
-- is the only thing that calls any of it.
-- ===========================================================================
-- ---------- peak finder ----------

-- Top `count` local maxima of fftsa.fft_pwr, strongest first, as bin indices and power.
-- kmin/kmax restrict the search to the bins the graph shows, so the table never reports a
-- tone absent from the trace. Index 1 and the fftsa.fft_kdc bins above it carry the mean
-- removal's own error rather than signal, so neither is a candidate whatever kmin says.
function fftsa.find_peaks(nbins, count, kmin, kmax)
  local pwr = fftsa.fft_pwr
  -- Reused, not rebuilt: two tables a frame was the only allocation left in the frame
  -- path, and the house rule is to allocate once. Callers read them immediately.
  if fftsa.pk_bi == nil then fftsa.pk_bi, fftsa.pk_bv = {}, {} end
  local bi, bv = fftsa.pk_bi, fftsa.pk_bv
  for s = 1, count do bi[s] = 0; bv[s] = -1 end
  local k0 = 2 + (fftsa.fft_kdc or 0)
  if kmin == nil or kmin < k0 then kmin = k0 end
  if kmax == nil or kmax > nbins then kmax = nbins end
  for k = kmin, kmax do
    local m = pwr[k]
    -- A partial fftsa.fft_pwr (after a short read) can hold nils, and comparing
    -- a nil raises.
    if m ~= nil then
      local ml = pwr[k-1]
      local mr = pwr[k+1]
      -- A missing neighbour is the end of the spectrum and counts as lower. Inside
      -- a zoom window the neighbours are real bins even when off-screen, so the
      -- flank of an out-of-window tone does not read as a peak.
      if ml == nil then ml = -1 end
      if mr == nil then mr = -1 end
      -- m == m and mr == mr are the NaN tests. This firmware implements a >= b as
      -- not (a < b), so m >= mr is true when mr is a NaN and a bin beside one would be
      -- reported as a peak. Strict > needs no guard; >= does.
      if m == m and mr == mr and m > ml and m >= mr then
        -- A tone inside the DC region leaks enough into the first reportable bin to
        -- make it a local maximum, which then reports the tone a whole bin and 16 dB
        -- out. The estimator saturates at -0.5 there, saying the three bins are not one
        -- tone centred here -- so refuse a peak estimating a quarter bin or more below
        -- the lowest reportable bin. A genuine tone there estimates within 0.017 bins,
        -- against the leak's 0.500, so the margin sits in the middle of the gap.
        local keep = true
        if k == k0 then
          local d = fftsa.peak_interp(k, nbins)
          if (k - 1) + d < (k0 - 1) - 0.25 then keep = false end
        end
        if keep and m > bv[count] then
          local s = count
          while s > 1 and m > bv[s-1] do
            bv[s] = bv[s-1]; bi[s] = bi[s-1]; s = s - 1
          end
          bv[s] = m; bi[s] = k
        end
      end
    end
  end
  return bi, bv
end

-- A harmonic is h times an interpolated fundamental, so it misses the bin centre and the
-- window spreads it: halfw is the search radius.
fftsa.thd_halfw = 2

-- Bins either side of a line that hold the WINDOW's main lobe rather than noise. Counting
-- them as noise puts a floor under every figure: a fixed 3 capped reportable S/N at 38.5 dB
-- on Kaiser 18, against the 124.9 dB the window itself allows, measured on a pure tone at
-- 16384 samples. The first null in bins is 2 for Hann, 3 for Blackman, 4 for Blk-Harris
-- and sqrt(1 + (beta/pi)^2) for Kaiser -- 5.82 at beta 18 -- plus one bin of guard.
--
-- Sidelobes are not covered and cannot be: Kaiser 4's are 30 dB down and integrate to a
-- 36.7 dB ceiling whatever the skirt does. That is the window, not a measurement error.
fftsa.thd_lobes = {2, 3, 4}      -- Hann, Blackman, Blk-Harris

function fftsa.thd_skirt()
  local wi = fftsa.win_i
  local l = fftsa.thd_lobes[wi]
  if l == nil then
    -- Kaiser, the one window whose lobe moves with a setting.
    local b = fftsa.kbetas[fftsa.kbeta_i]
    if b == nil then b = 0 end
    l = math.ceil(math.sqrt(1 + (b / math.pi) * (b / math.pi)))
    if l < 2 then l = 2 end
  end
  return l + 1
end
fftsa.thd_hmax  = 20      -- ceiling on harmonics; the window top usually stops it first

-- The fundamental must clear the per-bin noise mean by this ratio before THD and S/N mean
-- anything: 45 dB. Measured at 16384 samples -- a shorted input's strongest bin stood
-- 17.1 dB over the mean, a floating input's best surviving candidate stood 38.8 (a mains
-- harmonic at 1019 Hz, past the cutoff below), and an 8 Vp-p tone stood 117.9. The margin
-- goes between the floating case and the tone, which is where the useful gap is.
--
-- The cost is that a tone under 45 dB over the per-bin floor reads NoSig -- about 0.9 mV at
-- 16384 samples -- and its distortion would have been noise anyway. Raising the mains
-- cutoff instead has no natural stopping point, the harmonic series being endless, and
-- would discount legitimate quiet tones landing on multiples of 50.
fftsa.thd_minratio = 31623

-- Mains pickup is not the signal under test. A floating input reads 60 Hz at -25.4 dBV
-- with harmonics out to 540, which made the hum the fundamental and reported its own
-- distortion as the instrument's: 11.04% measured, over a -105.2 dBV floor. A candidate at
-- a multiple of 50 or 60 Hz, below thd_mains_fmax and at or under -22 dBV, is passed over
-- so the search moves on -- and with nothing else there the margin then answers NoSig.
--
-- The harmonics have to go too, or discounting 60 Hz alone promotes 120 at -46.3 dBV,
-- which still clears the margin by 59 dB.
fftsa.thd_mains      = {50, 60}
fftsa.thd_mains_pwr  = 0.0063096   -- -22 dBV expressed as power
fftsa.thd_mains_fmax = 1000        -- above this a tone on a mains multiple is a tone

-- Bins the noise figures sample. They do not need all of them: the standard error of a
-- mean over 2048 bins is 0.1 dB, well inside the 0.5 dB the clip already costs, and the
-- clip wants several passes. Measured on the instrument, all 8192 bins at 16384 samples
-- cost 0.498 s a call and took the frame from 1.67 s to 2.17 s -- 30% of it, for a figure
-- that updates once a second. Striding holds it to a few per cent.
fftsa.thd_nsample = 1024

-- A noise bin above thd_clip times the running mean is an outlier and not noise, because the
-- plain mean of a windowed spectrum is set by whichever few bins carry a line's leakage
-- skirt: measured at 16384 samples with the tone off a bin centre, Hann's skirt put the
-- reported floor at -80.2 dBV over a trace sitting at -100, and swung it 62 dB purely on
-- where the tone fell between bins. Widening the skirt cannot reach that -- Hann is still
-- 45 dB down four bins out -- but clipping can, those bins being orders of magnitude up.
-- Each pass tightens the threshold and the loop stops when one removes nothing; on noise
-- with no outliers the clip trims the top few per cent and costs 0.5 dB.
fftsa.thd_clip  = 4
fftsa.thd_clips = 6

-- Is this candidate mains pickup rather than the signal? Level first, because it is the
-- cheap test and the common answer. Called only when a candidate beats the running
-- maximum, which happens a handful of times over a spectrum, not once a bin.
function fftsa.thd_is_mains(fhz, p, binhz)
  if not (p <= fftsa.thd_mains_pwr) then return false end
  if not (fhz < fftsa.thd_mains_fmax) then return false end
  local tol = binhz
  if not (tol > 2) then tol = 2 end
  local i
  for i = 1, 2 do
    local f = fftsa.thd_mains[i]
    local n = math.floor(fhz / f + 0.5)
    if n >= 1 then
      local d = fhz - n * f
      if d < 0 then d = -d end
      if d <= tol then return true end
    end
  end
  return false
end

-- Sum and count the bins that are neither a line nor a skirt and do not exceed ceil. The
-- exclusion list is walked alongside the bins: one comparison a bin, not one a line a bin,
-- which at 8192 bins and twenty harmonics is what keeps this affordable. Module level, not
-- a local closure, because the house rule is to allocate once.
function fftsa.thd_noise_pass(pwr, kmin, kmax, ex, nex, skirt, ceil, stride)
  local sum, cnt, e, k = 0, 0, 1, nil
  for k = kmin, kmax, stride do
    while e <= nex and ex[e] + skirt < k do e = e + 1 end
    if e > nex or k < ex[e] - skirt then
      local p = pwr[k]
      -- p == p is the NaN test. Measured on this firmware, nan >= 0 and nan <= 1/0 are
      -- both true -- it implements a >= b as not (a < b), which inverts the unordered
      -- case -- so neither ordered guard rejects one. Strict > and < are correct, which
      -- is why the searches above can rely on them. Unguarded, one NaN bin makes the sum
      -- NaN and the whole readout degrades to NoSig; one infinity reads "inf dBV".
      if p ~= nil and p == p and p >= 0 and p <= ceil then
        sum = sum + p
        cnt = cnt + 1
      end
    end
  end
  return sum, cnt
end

-- THD and the noise floor over the plotted bins, as a percentage and dBV.
--
-- Amplitudes come from fftsa.peak_interp, not bin maxima, which read up to 3.9 dB low on a
-- tone between bins. The noise floor is the mean power of every bin that is not a line or
-- its skirt: averaging decibels instead lets one deep null drag it down several dB.
--
-- Both nil with nothing to measure. THD alone is nil when no harmonic fits in the window,
-- which is not a clean signal and must not read as 0.00%.
-- flo and fhi are the analysis window, defaulting to the display module's fields where the
-- shipped callers keep them; dsp.* passes its own, because reading the display's span from
-- inside the signal path is the seam crossed backwards and holds only while both halves are
-- Lua. No dB floor goes in: see the noise figure below.
function fftsa.thd_noise(nb, binhz, flo, fhi)
  local pwr = fftsa.fft_pwr
  if pwr == nil or nb == nil or nb < 8 then return nil, nil, 0 end
  if binhz == nil or not (binhz > 0) then return nil, nil, 0 end
  local sqrt, floor, log10 = math.sqrt, math.floor, math.log10
  local k0 = 2 + (fftsa.fft_kdc or 0)
  local kmin, kmax = fftsa.sg_window_bins(nb, binhz, flo, fhi)
  if kmin < k0 then kmin = k0 end
  if kmax > nb then kmax = nb end
  if kmax - kmin < 4 then return nil, nil, 0 end

  local k, kf, pf = nil, nil, 0
  for k = kmin, kmax do
    local p = pwr[k]
    -- A partial fftsa.fft_pwr after a short read holds nils, and comparing one raises.
    -- Strict > rejects a NaN correctly on this firmware where >= does not.
    if p ~= nil and p > pf then
      -- A local maximum, or the shoulder of a louder line qualifies. Measured with the
      -- inputs floating: the 60 Hz line sat in bin 11 and was discounted as mains, but
      -- bin 12 at 67.1 Hz -- its own skirt, 8 dB down -- missed the mains tolerance by
      -- 1 Hz and became the fundamental, giving 21.4% distortion on no signal at all.
      -- A monotonic skirt has no local maximum; a real tone is one.
      local l, r = pwr[k - 1], pwr[k + 1]
      if (l == nil or p > l) and (r == nil or (r == r and p >= r))
         and not fftsa.thd_is_mains((k - 1) * binhz, p, binhz) then
        kf, pf = k, p
      end
    end
  end
  -- No fundamental is not the end of it: the floor is the useful number with the inputs
  -- disconnected, and a flat spectrum has no local maximum at all. vf nil carries that
  -- through to the noise pass with nothing excluded.
  local df, vf = 0, nil
  if kf ~= nil and pf > 0 then
    df, vf = fftsa.peak_interp(kf, nb)
    if vf == nil then df, vf = 0, sqrt(pf) end
    if not (vf > 0) then vf = nil end
  end

  -- Line centres, ascending by construction. Reused: the house rule is to allocate once.
  local ex = fftsa.thd_ex
  if ex == nil then ex = {}; fftsa.thd_ex = ex end
  local nex, hsum, nh = 0, 0, 0
  if vf ~= nil then
    ex[1] = kf
    nex = 1
  end
  local halfw, skirt = fftsa.thd_halfw, fftsa.thd_skirt()
  local fb = 0
  if vf ~= nil then fb = kf - 1 + df end  -- the fundamental, in bins from DC
  local h
  for h = 2, fftsa.thd_hmax do
    if vf == nil then break end
    local c = fb * h + 1                  -- the h'th harmonic's predicted 1-based bin
    if c + halfw > kmax then break end
    local a, b = floor(c - halfw + 0.5), floor(c + halfw + 0.5)
    if a < kmin then a = kmin end
    local bk, bp = nil, -1
    for k = a, b do
      local p = pwr[k]
      if p ~= nil and p > bp then bk, bp = k, p end
    end
    if bk ~= nil and bp > 0 and bk > ex[nex] + skirt then
      local hd, hv = fftsa.peak_interp(bk, nb)
      if hv == nil then hv = sqrt(bp) end
      hsum = hsum + hv * hv
      nh, nex = nh + 1, nex + 1
      ex[nex] = bk
    end
  end

  -- One in every stride bins, which is what keeps the clip affordable. See thd_nsample.
  local stride = math.floor((kmax - kmin + 1) / fftsa.thd_nsample)
  if stride < 1 then stride = 1 end
  -- A finite ceiling, not 1/0: inf <= 1/0 is true and inf <= 1e308 is not, so this is
  -- what keeps an infinite bin out of the first pass.
  local sum, cnt = fftsa.thd_noise_pass(pwr, kmin, kmax, ex, nex, skirt, 1e308, stride)
  -- Again with the outliers clipped. See fftsa.thd_clip for why the plain mean is not the
  -- floor the trace shows.
  for h = 1, fftsa.thd_clips do
    if not (cnt > 0 and sum > 0) then break end
    local csum, ccnt = fftsa.thd_noise_pass(pwr, kmin, kmax, ex, nex, skirt,
                                            (sum / cnt) * fftsa.thd_clip, stride)
    -- Converged: a pass that removed nothing means the next would too.
    if ccnt == cnt or ccnt < 1 or not (csum > 0) then break end
    sum, cnt = csum, ccnt
  end

  local ndb, snr = nil, nil
  if cnt > 0 and sum > 0 then
    local mean = sum / cnt
    -- Not clamped to the plot's floor. The floor is a measurement, not a plotted point, and
    -- clamping it to the axis reports the axis. Measured here at -110 to -111 dBV, averaging
    -- about -110.6 and best -111.2, at 16,384 samples on Hann -- all four inputs shorted,
    -- weeks of continuous uptime, 22 C +/- 1 and 40 to 45 % RH. The conditions qualify it: a
    -- shorting block makes this the instrument's own noise rather than pickup, and a cold
    -- start reads worse, so a figure taken any other way is not this one. A DMM7510 reads
    -- -134 dBV on its 0.1 V range and -129 on 1 V, under what a -120 axis can show, which is
    -- one of the two cases fftsa.sg_dbmin_for() moves the floor to -140 for; a bin narrowed
    -- by a 16384 or 32768 count is the other.
    --
    -- log10 is safe without a guard: this branch needs cnt > 0 and sum > 0 above.
    ndb = 10 * log10(mean)
    -- No fundamental, no ratios. With the inputs shorted the strongest bin is a noise
    -- peak, and both ratios built on it are arithmetic about nothing -- 31.8% and -22 dB.
    -- The floor still reports: shorted, it is the instrument's own and the useful number.
    if vf ~= nil and vf * vf > mean * fftsa.thd_minratio then
      -- Against the integrated noise, not the per-bin mean, so it holds still when the
      -- sample count changes. Harmonics are out of the sum, so this is not THD restated.
      -- The halves of both mean squares cancel in the ratio.
      -- sum * stride is the integrated noise: the sampled sum scaled back up, which is
      -- unbiased. The mean is sum/cnt, where the stride cancels.
      snr = 10 * log10(vf * vf / (sum * stride))
    else
      nh = 0
    end
  end
  local thd = nil
  if nh > 0 then thd = 100 * sqrt(hsum) / vf end
  return thd, ndb, nh, snr
end

-- ===========================================================================
-- The interpreted transform, peak search and distortion, bound into a dsp table.
--
-- tsp/dsp_lua.tsp owns the attribute surface and ships; this owns the arithmetic and does
-- not, because csrc/ is the implementation on the instrument. The three entry points are
-- closures over that install's locals, so they are re-bound from the context table it
-- passes rather than reaching back into it.
-- ===========================================================================
function fftsa.dsp_install_math(dsp, ctx)
  local post, span_ok = ctx.post, ctx.span_ok
  local fft_s, out_s, peaks_s, thd_s = ctx.fft_s, ctx.out_s, ctx.peaks_s, ctx.thd_s

  -- The rate delivered, off the digitizer's own timestamps, which is what every reported
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
    -- The archive ships no interpreted transform, so on an instrument this refuses and the
    -- compiled path is the only one. Posted rather than raised, like every other refusal
    -- here, so the frame path counts it and the panel says why instead of the app dying in
    -- a timer callback.
    if fftsa.fft_init == nil then
      return post(dsp.EUNSUPPORTED, 'no interpreted transform in this archive')
    end
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

    -- The reduction takes the maximum of the bins a segment covers. At 16,384 samples and
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
    -- buffer.write.reading is hoisted: looked up inside the loop it is two table reads per
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
  -- thd is a fraction of the fundamental; snr and floor are dB. Both ratios are nil when
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

  -- Given back by dsp.release(), which calls this when the module is present.
  function fftsa.dsp_release_math()
    fftsa.fft_built_n, fftsa.fft_built_win, fftsa.fft_built_beta = nil, nil, nil
    fftsa.fft_x, fftsa.fft_re, fftsa.fft_im, fftsa.fft_pwr = nil, nil, nil, nil
    fftsa.fft_win, fftsa.fft_twr, fftsa.fft_twi = nil, nil, nil
    fftsa.fft_utr, fftsa.fft_uti = nil, nil
    fftsa.fft_swp_a, fftsa.fft_swp_b = nil, nil
    fftsa.fft_gtab, fftsa.fft_dtab = nil, nil
  end
end
