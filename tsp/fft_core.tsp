-- fft_core.tsp -- real-input FFT for the DMM6500's TSP (Lua 5.0.2)
--
-- Design notes (the reasons this is fast enough to be interactive):
--
--  * Everything loop-invariant is precomputed ONCE in fftsa.fft_init(): the Hann
--    window, the bit-reversal swap list, every butterfly twiddle and the untangle
--    twiddles. A naive implementation rebuilds these per frame, which on this
--    hardware costs more than the butterflies themselves.
--  * The input is REAL, so it is PACKED: each pair of samples becomes one complex
--    point, z[k] = x[2k-1] + i*x[2k], an N/2-point complex transform runs on those,
--    and one O(N/2) untangle pass recovers the N/2 output bins. Against a full
--    N-point transform fed real data that is 896 full butterflies at N = 512
--    instead of 2048, and the first stage of the half-size transform is still
--    twiddle-free adds. The host-side suite checks the result against a direct DFT.
--  * The untangle pass writes POWER (|X|^2 in volts-squared), not magnitude. The
--    display works in dB, where 10*log10 of a power costs exactly what 20*log10 of
--    a magnitude does, so the 256 square roots a frame become the few the peak
--    table needs. fftsa.fft_pwr is power everywhere; anything that wants volts
--    takes the square root at the point of use.
--  * Lua 5.0.2 table reads cost ~1.4 us and arithmetic ~1.2 us on the 400 MHz
--    in-order PPC, so every inner loop is table-access bound. Locals are cached
--    aggressively; that is not style, it is the optimisation.
--
-- Lua 5.0.2 constraints: no '#' operator (use table.getn), no bitwise
-- operators, math.mod for modulo.

fftsa = fftsa or {}   -- the single global this app exposes

fftsa.fft_n      = 0      -- number of samples N (power of two)
fftsa.fft_m      = 0      -- N/2: the complex transform size, and the number of bins
fftsa.fft_x      = nil    -- raw samples 1..N, staged between the two load passes
fftsa.fft_re     = nil    -- packed complex working array, real parts, 1..M
fftsa.fft_im     = nil    -- imaginary parts, 1..M
fftsa.fft_win    = nil    -- Hann window, 1..N
fftsa.fft_pwr    = nil    -- power output, 1..M, volts-squared (peak)
fftsa.fft_swp_a  = nil    -- bit-reversal swap pairs over 1..M
fftsa.fft_swp_b  = nil
fftsa.fft_nswp   = 0
fftsa.fft_twr    = nil    -- flattened butterfly twiddles, stage-major
fftsa.fft_twi    = nil
fftsa.fft_utr    = nil    -- untangle twiddles e^(-2*pi*i*k/N), k = 0..M-1
fftsa.fft_uti    = nil
fftsa.fft_cg     = 0.5    -- Hann coherent gain; fftsa.fft_init() overwrites this
                          -- with the exact value for the window it built
fftsa.fft_ksq    = 0      -- power scale applied to the untangled |2X|^2

-- Build all lookup tables for a given number of samples.
function fftsa.fft_init(N)
  local floor, sin, cos, pi = math.floor, math.sin, math.cos, math.pi
  local M = floor(N / 2)
  fftsa.fft_n   = N
  fftsa.fft_m   = M
  fftsa.fft_x   = {}
  fftsa.fft_re  = {}
  fftsa.fft_im  = {}
  fftsa.fft_win = {}
  fftsa.fft_pwr = {}

  -- Hann window, plus its EXACT coherent gain (the window's mean sample value),
  -- which the power scale divides back out. This is the SYMMETRIC Hann, so that
  -- gain is (N-1)/(2N), NOT exactly 0.5: assuming 0.5 reads every amplitude
  -- ~0.2 % (0.017 dB) low at N = 512. Measuring it costs one add per sample, once
  -- per fftsa.apply().
  local twopi_over = 2*pi/(N-1)
  local wsum = 0
  for i = 1, N do
    local w = 0.5 - 0.5*cos(twopi_over*(i-1))
    fftsa.fft_win[i] = w
    wsum = wsum + w
  end
  fftsa.fft_cg = wsum / N
  -- A plain transform would scale to volts by 2/(N*cg). The untangle leaves every
  -- bin doubled, so that becomes 1/(N*cg); squared, because the output is power.
  local k = 1 / (N * fftsa.fft_cg)
  fftsa.fft_ksq = k * k

  -- Bit-reversal of the M complex points as an explicit swap list: cheaper per
  -- frame than recomputing the reversed index, and only pairs that move are kept.
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

  -- Butterfly twiddles for every stage of the M-point transform, flattened. The
  -- stage with half-length h occupies the next h entries, so stage strides are
  -- implicit and no per-stage trig is needed at run time.
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

  -- Untangle twiddles: e^(-2*pi*i*k/N) for the N-point bins k = 0..M-1.
  fftsa.fft_utr = {}
  fftsa.fft_uti = {}
  local ang = -2*pi/N
  for jj = 1, M do
    fftsa.fft_utr[jj] = cos(ang*(jj-1))
    fftsa.fft_uti[jj] = sin(ang*(jj-1))
  end
end

-- Load N samples from a reading buffer, remove DC, window, and pack sample pairs
-- into the M complex points. Two passes: the mean has to be known before it can
-- be subtracted, and a buffer element costs 22 us to read, so the samples are
-- staged in fftsa.fft_x rather than read twice. Returns the mean (DC level).
function fftsa.fft_load(buf)
  local N   = fftsa.fft_n
  local M   = fftsa.fft_m
  local x   = fftsa.fft_x
  local re  = fftsa.fft_re
  local im  = fftsa.fft_im
  local win = fftsa.fft_win
  local rd  = buf.readings

  local mean = 0
  for i = 1, N do
    local v = rd[i]
    -- Last-resort net ONLY. fftsa.frame_body() rejects a short capture before it
    -- reaches here, because zero-padding one does not just lose data: the step
    -- from real samples to zeros is broadband, so it fabricates a plausible but
    -- entirely WRONG spectrum, and the mean below would be divided by N rather
    -- than by the number of samples actually read. This guard exists so that a
    -- sparse buffer cannot put nils into the transform, where a later comparison
    -- against nil would raise an error mid-frame.
    if v == nil then v = 0 end
    x[i] = v
    mean = mean + v
  end
  mean = mean / N

  local i = 1
  for k = 1, M do
    re[k] = (x[i] - mean) * win[i]
    im[k] = (x[i+1] - mean) * win[i+1]
    i = i + 2
  end
  return mean
end

-- In-place forward transform of the M packed points.
function fftsa.fft_run()
  local M     = fftsa.fft_m
  local re    = fftsa.fft_re
  local im    = fftsa.fft_im
  local swp_a = fftsa.fft_swp_a
  local swp_b = fftsa.fft_swp_b
  local twr   = fftsa.fft_twr
  local twi   = fftsa.fft_twi
  local floor = math.floor

  -- Bit-reversal permutation of both components: the packed input is complex.
  for s = 1, fftsa.fft_nswp do
    local a, b = swp_a[s], swp_b[s]
    re[a], re[b] = re[b], re[a]
    im[a], im[b] = im[b], im[a]
  end

  -- Stage 1: len = 2, twiddle == 1+0i. Pure add/sub, no multiplies.
  for i = 1, M, 2 do
    local ar, ai, br, bi = re[i], im[i], re[i+1], im[i+1]
    re[i]   = ar + br
    im[i]   = ai + bi
    re[i+1] = ar - br
    im[i+1] = ai - bi
  end

  -- Remaining stages.
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
  end
end

-- Untangle the half-size transform into the N/2 real-input bins and write their
-- POWER, scaled to volts-squared peak, into fftsa.fft_pwr[1..M]. Bin j (1-based)
-- is the frequency (j-1)*fs/N.
--
-- With Z the M-point transform of z[k] = x[2k-1] + i*x[2k] and Zc the conjugate
-- of Z at the mirror index (M-k) mod M,
--
--   X[k] = (Z + Zc)/2 + e^(-2*pi*i*k/N) * (Z - Zc)/(2i)
--
-- The halves are folded into fftsa.fft_ksq, and bins k and M-k share the same
-- four loads, so the pass walks mirror pairs. Bin 0 (DC) and bin M/2 are their
-- own mirrors and are done outside the loop.
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

-- Sub-bin peak estimate from the peak bin and its two neighbours.
--
-- A tone almost never lands on a bin centre, and a single-bin reading pays for
-- that twice: the frequency is quantised to the bin grid (+-binhz/2), and the
-- amplitude suffers SCALLOPING LOSS, which for a Hann window reaches -1.42 dB
-- (x0.849) at exactly half a bin. Both are recoverable in closed form, because
-- the Hann window's spectral response is known exactly:
--
--   D(x) = 0.5 * sinc(x) / (1 - x^2)
--
-- With the peak in bin k and the true tone at bin k+d, that kernel makes
--
--   d = 2*(R - L) / (L + 2*C + R)          (L, C, R = |X[k-1]|, |X[k]|, |X[k+1]|)
--
-- EXACT for a noiseless Hann-windowed tone, and the amplitude follows from
-- dividing out D(d)/D(0) = pi*d*(1-d^2)/sin(pi*d). The kernel is linear in the
-- MAGNITUDE, so the three power bins are square-rooted here -- three roots per
-- reported peak, in place of one per bin.
--
-- Verified against hardware: a 12.000 kHz 1.000 V source at 195.3 Hz bin width
-- read 11.914 kHz / 0.883 V from the peak bin alone; this returns 11999.8 Hz /
-- 1.0016 V from the same three bins.
--
-- Returns the fractional bin offset (-0.5..0.5) and the corrected amplitude in
-- volts, or 0 and nil when the estimate is not available -- at the spectrum
-- edges, where a neighbour does not exist, and for a sparse power array. Callers
-- fall back to the raw bin in that case.
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
  local d = 2*(R - L) / den
  -- The kernel only places the true tone within half a bin of the peak; a wider
  -- value means the three bins are noise rather than one tone, so clamp.
  if d < -0.5 then d = -0.5 end
  if d > 0.5 then d = 0.5 end
  local ad = d
  if ad < 0 then ad = -ad end
  if ad < 1e-9 then return d, C end     -- removable singularity at d = 0
  local pd = math.pi * d
  local s  = math.sin(pd)
  if s == 0 then return d, C end
  return d, C * pd * (1 - d*d) / s
end
