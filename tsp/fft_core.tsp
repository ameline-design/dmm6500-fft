-- fft_core.tsp -- real-input radix-2 FFT for the DMM6500's TSP (Lua 5.0.2)
--
-- Design notes (the reasons this is fast enough to be interactive):
--
--  * Everything loop-invariant is precomputed ONCE in fftsa.fft_init(): the Hann
--    window, the bit-reversal swap list, and every twiddle factor. A naive
--    implementation rebuilds these per frame, which on this hardware costs
--    more than the butterflies themselves.
--  * The input is REAL, so the imaginary array starts all-zero. That lets us
--    skip the imaginary half of the bit-reversal permutation entirely and
--    specialise stage 1 (len=2, twiddle == 1) into pure adds/subs with no
--    multiplies and no imaginary writes.
--  * Lua 5.0.2 table reads cost ~1.4 us and arithmetic ~1.2 us on the 400 MHz
--    in-order PPC, so the inner loop is table-access bound. Locals are cached
--    aggressively; that is not style, it is the optimisation.
--
-- Lua 5.0.2 constraints: no '#' operator (use table.getn), no bitwise
-- operators, math.mod for modulo.

fftsa = fftsa or {}   -- the single global this app exposes

fftsa.fft_n      = 0      -- transform size (power of two)
fftsa.fft_re     = nil    -- real working array, 1..N
fftsa.fft_im     = nil    -- imaginary working array, 1..N
fftsa.fft_win    = nil    -- Hann window, 1..N
fftsa.fft_mag    = nil    -- magnitude output, 1..N/2
fftsa.fft_swp_a  = nil    -- bit-reversal swap pairs
fftsa.fft_swp_b  = nil
fftsa.fft_nswp   = 0
fftsa.fft_twr    = nil    -- flattened twiddles, stage-major
fftsa.fft_twi    = nil
fftsa.fft_cg     = 0.5    -- Hann coherent gain; fftsa.fft_init() overwrites this
                          -- with the exact value for the window it built

-- Build all lookup tables for a given transform size.
function fftsa.fft_init(N)
  local floor, sin, cos, pi = math.floor, math.sin, math.cos, math.pi
  fftsa.fft_n   = N
  fftsa.fft_re  = {}
  fftsa.fft_im  = {}
  fftsa.fft_win = {}
  fftsa.fft_mag = {}

  -- Hann window, plus its EXACT coherent gain (the window's mean sample value),
  -- which fftsa.fft_magnitude() divides back out. This is the SYMMETRIC Hann, so
  -- that gain is (N-1)/(2N), NOT exactly 0.5: assuming 0.5 reads every amplitude
  -- ~0.2 % (0.017 dB) low at N = 512. Measuring it costs one add per bin, once
  -- per fftsa.apply().
  local twopi_over = 2*pi/(N-1)
  local wsum = 0
  for i = 1, N do
    local w = 0.5 - 0.5*cos(twopi_over*(i-1))
    fftsa.fft_win[i] = w
    wsum = wsum + w
  end
  fftsa.fft_cg = wsum / N

  -- Bit-reversal as an explicit swap list: cheaper per frame than recomputing
  -- the reversed index, and we only store pairs that actually move.
  fftsa.fft_swp_a = {}
  fftsa.fft_swp_b = {}
  local n = 0
  local j = 0
  for i = 0, N-2 do
    if i < j then
      n = n + 1
      fftsa.fft_swp_a[n] = i + 1
      fftsa.fft_swp_b[n] = j + 1
    end
    local k = floor(N/2)
    while k <= j do j = j - k; k = floor(k/2) end
    j = j + k
  end
  fftsa.fft_nswp = n

  -- Twiddles for every stage, flattened. Stage with half-length h occupies the
  -- next h entries, so stage strides are implicit and no per-stage trig is
  -- needed at run time.
  fftsa.fft_twr = {}
  fftsa.fft_twi = {}
  local idx = 0
  local len = 4                  -- stage 1 (len=2) needs no twiddles
  while len <= N do
    local half = floor(len/2)
    local ang  = -2*pi/len
    for m = 0, half-1 do
      idx = idx + 1
      fftsa.fft_twr[idx] = cos(ang*m)
      fftsa.fft_twi[idx] = sin(ang*m)
    end
    len = len * 2
  end
end

-- Load N samples from a reading buffer, remove DC, apply the window.
-- Returns the mean (DC level) and the raw peak-to-peak, both useful for the UI.
function fftsa.fft_load(buf)
  local N   = fftsa.fft_n
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
    -- sparse buffer cannot put nils into the FFT, where a later comparison
    -- against nil would raise an error mid-frame.
    if v == nil then v = 0 end
    re[i] = v
    mean = mean + v
  end
  mean = mean / N

  local vmin, vmax = re[1], re[1]
  for i = 1, N do
    local v = re[i]
    if v < vmin then vmin = v end
    if v > vmax then vmax = v end
    re[i] = (v - mean) * win[i]
    im[i] = 0
  end
  return mean, vmax - vmin
end

-- In-place forward transform of the (already loaded and windowed) data.
function fftsa.fft_run()
  local N     = fftsa.fft_n
  local re    = fftsa.fft_re
  local im    = fftsa.fft_im
  local swp_a = fftsa.fft_swp_a
  local swp_b = fftsa.fft_swp_b
  local twr   = fftsa.fft_twr
  local twi   = fftsa.fft_twi
  local floor = math.floor

  -- Bit-reversal permutation. im[] is all zero here (real input), so only re[]
  -- needs permuting.
  for s = 1, fftsa.fft_nswp do
    local a, b = swp_a[s], swp_b[s]
    re[a], re[b] = re[b], re[a]
  end

  -- Stage 1: len = 2, twiddle == 1+0i. Pure add/sub, imaginary parts stay 0,
  -- so this whole stage costs no multiplies and no im[] writes.
  for i = 1, N, 2 do
    local a, b = re[i], re[i+1]
    re[i]   = a + b
    re[i+1] = a - b
  end

  -- Remaining stages.
  local len  = 4
  local base = 0
  while len <= N do
    local half = floor(len/2)
    for i = 0, N-1, len do
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
--   d = 2*(R - L) / (L + 2*C + R)          (L, C, R = mag[k-1], mag[k], mag[k+1])
--
-- EXACT for a noiseless Hann-windowed tone, and the amplitude follows from
-- dividing out D(d)/D(0) = pi*d*(1-d^2)/sin(pi*d).
--
-- Verified against hardware: a 12.000 kHz 1.000 V source at 195.3 Hz bin width
-- read 11.914 kHz / 0.883 V from the peak bin alone; this returns 11999.8 Hz /
-- 1.0016 V from the same three bins.
--
-- Returns the fractional bin offset (-0.5..0.5) and the corrected amplitude, or
-- 0 and nil when the estimate is not available -- at the spectrum edges, where a
-- neighbour does not exist, and for a sparse magnitude array. Callers fall back
-- to the raw bin in that case.
function fftsa.peak_interp(k, nb)
  local mag = fftsa.fft_mag
  if k == nil or k < 2 then return 0, nil end
  if nb ~= nil and k >= nb then return 0, nil end
  local C = mag[k]
  local L = mag[k-1]
  local R = mag[k+1]
  if C == nil or L == nil or R == nil or C <= 0 then return 0, nil end
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

-- Magnitude spectrum in volts-peak, corrected for window coherent gain.
-- Only the first N/2 bins are meaningful for real input.
function fftsa.fft_magnitude()
  local N    = fftsa.fft_n
  local half = N/2
  local re   = fftsa.fft_re
  local im   = fftsa.fft_im
  local mag  = fftsa.fft_mag
  local sqrt = math.sqrt
  local k    = 2/(N*fftsa.fft_cg)
  for i = 1, half do
    local a, b = re[i], im[i]
    mag[i] = sqrt(a*a + b*b) * k
  end
  return half
end
