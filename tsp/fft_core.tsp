-- fft_core.tsp -- real-input FFT for the DMM6500's TSP (Lua 5.0.2)
--
-- fftsa.fft_init() builds everything loop-invariant once: window, bit-reversal swaps,
-- butterfly and untangle twiddles, peak-interpolation tables. The real input packs into
-- N/2 complex points z[k] = x[2k-1] + i*x[2k], an N/2-point transform runs on those, and
-- one untangle pass recovers the N/2 bins as power, volts-squared peak. Anything wanting
-- volts takes the square root at the point of use.
--
-- Lua 5.0.2: no '#' operator (table.getn), no hex literals, no bitwise operators.

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

-- ============================ analysis windows ============================
-- Every entry is a generalised cosine sum except Kaiser, whose beta trades main-lobe
-- width against sidelobe level and so spans the named windows and goes past them.
--
-- Rectangular is absent: its transform has a null one bin from the peak, which leaves the
-- three-bin interpolation ill-conditioned, so peak readings would be wrong in a way the
-- trace does not show. Hamming is absent because it exits the app on the instrument;
-- Kaiser at beta 6 covers it to within a dB of sidelobe level.
fftsa.win_names = {"Hann", "Blackman", "Blk-Harris", "Kaiser"}
-- Index-parallel to fftsa.win_names, coefficients a0 - a1*cos + a2*cos2 - a3*cos3.
-- Kaiser has no entry, which is how fftsa.win_build() tells it apart.
fftsa.win_cos = {
  {0.5, 0.5},
  {0.42, 0.5, 0.08},
  {0.35875, 0.48829, 0.14128, 0.01168},
}
fftsa.win_i = 1             -- index into fftsa.win_names

-- A fixed list rather than a typed number: every value here is verified for peak
-- frequency and amplitude in the suite, and a typed beta would admit unmeasured shapes.
-- The floor is 4 because the first null sits at sqrt(1 + (beta/pi)^2) bins and has to
-- stay outside 1.5 bins for the interpolation to read main lobe rather than sidelobe,
-- which puts the boundary at 3.5. Labels carry the peak sidelobe level beta buys.
fftsa.kbetas       = {4, 6, 9, 12, 15, 18}
fftsa.kbeta_labels = {"4  -30dB", "6  -44dB", "9  -66dB",
                      "12  -90dB", "15  -114dB", "18  -139dB"}
fftsa.kbeta_i      = 4      -- index into fftsa.kbetas

function fftsa.kbeta(bi)
  local b = fftsa.kbetas[bi or fftsa.kbeta_i]
  if b == nil then b = fftsa.kbetas[1] end
  return b
end

function fftsa.win_name(wi)
  wi = wi or fftsa.win_i
  return fftsa.win_names[wi] or fftsa.win_names[1]
end

-- Window name for a readback line, with beta where beta applies.
-- Defaults to the applied window; the options preview passes the field values so the
-- whole line describes one state rather than two.
function fftsa.win_label(wi, bi)
  wi = wi or fftsa.win_i
  if fftsa.win_cos[wi] ~= nil then return fftsa.win_name(wi) end
  return fftsa.win_name(wi) .. " b=" .. tostring(fftsa.kbeta(bi))
end

-- I0 by its power series, sum of ((x/2)^k / k!)^2. The term ratio is (x/2)^2/k^2, so
-- beta 18 converges inside 40 terms. Evaluated N/2 times per fftsa.fft_init() and
-- never per frame.
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

function fftsa.fft_init(N)
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
end

-- Load N samples from a reading buffer, remove DC, window, and pack sample pairs into
-- the M complex points. Two passes, because the mean must be known before it is
-- subtracted; samples are staged in fftsa.fft_x, a buffer element costing far more to
-- read than a table entry. Returns the mean.
--
-- The mean is window-weighted, sum(w*x)/sum(w). What has to vanish is the DC of the
-- sequence the transform sees, sum(w*(x-m)) = sum(w*x) - m*sum(w), and only the weighted
-- mean makes it. The arithmetic mean zeroes the true DC instead and leaves the window's
-- own DC response spread over the first few bins: a 1.000 V tone at bin 10.5 then leaves
-- a -27 dBc line at bin 1 under every window, against -147 here.
--
-- The price is that near DC the estimate is the tone, so win_tables() measures how far
-- that reaches and find_peaks() stops reporting there.
-- The display task shares this core with the interpreter and runs only while Lua is
-- blocked, so a stretch with no delay() in it cannot dispatch a touch -- and at 16384
-- samples fft_load and fft_run are 0.5 s and 0.8 s of arithmetic. Hence many yield points
-- rather than one long one, placed where the enclosing loop is cheap so the per-sample
-- inner loops are untouched. Both gates are sized so 512 samples reaches neither.
fftsa.fft_yield     = 0.005   -- seconds blocked at a yield point
fftsa.fft_yield_n   = 2048    -- fft_load samples between yields
fftsa.fft_yield_m   = 1024    -- fft_run yields per stage only above this half-length

-- ---------- band-pass: low-pass the capture and decimate to the span ----------
--
-- What it buys is bin width. Acquire M samples at the hardware rate, filter, keep every
-- Dth: the result is N samples at fs/D, so the bin is fs/M rather than fs/N -- a 2 kHz
-- span at 512 samples goes from 195 Hz bins to 12.2 Hz for the cost of the reads. The
-- filter is what makes that safe, since decimating an unfiltered record folds everything
-- above fs/2D into the band. It cannot undo folding already done at the ADC.
fftsa.bp_d     = 1        -- decimation in force; 1 means the filter is not in the path
fftsa.bp_h     = nil      -- taps, 1..bp_l
fftsa.bp_l     = 0        -- tap count, always odd so the delay is a whole sample
fftsa.bp_out   = nil      -- the N decimated samples fft_load_rd() reads
-- Samples the capture must hold for one record: fft_n when the filter is not decimating,
-- (n-1)*d + l when it is. Seeded at the default count because fftsa.frame_body() rejects a
-- capture shorter than this, and at zero that test would pass anything.
fftsa.bp_m     = 512
-- Read-cost ceiling. A buffer reading costs about 22 us (docs/PERFORMANCE.md), so 8192
-- of them is about 180 ms -- already the dominant term in a frame at the small counts
-- this feature is for. The decimation is capped to keep M under it, which is why a large
-- sample count leaves no room to decimate at all.
fftsa.bp_maxm  = 8192
-- Taps come from the transition width, not from the decimation: a Hamming-windowed FIR
-- needs about 3.3/transition taps for its stopband, the transition being a fraction of
-- the sample rate. Too few is not a subtle fault -- 13 taps where the transition needs 50
-- reads 3.5 dB low at the top of the span.
fftsa.bp_tapk  = 3.3      -- Hamming's transition constant
fftsa.bp_lmax  = 65       -- tap ceiling: N*L multiply-accumulates land in the frame

-- Largest decimation leaving the stop frequency inside the decimated Nyquist with room
-- for the transition, capped by what the read can afford. 2.56 is the usual margin over
-- 2: at D exactly fs/(2*fhi) the transition band has zero width.
-- The transition a decimation leaves, as a fraction of the sample rate. Zero or negative
-- means the span does not fit under it at all.
function fftsa.bp_transition(fs, fhi, d)
  return 1 / (2 * d) - fhi / fs
end

-- Taps that transition needs, odd, and nil when it needs more than the ceiling.
function fftsa.bp_taps_for(fs, fhi, d)
  local w = fftsa.bp_transition(fs, fhi, d)
  if w <= 0 then return nil end
  local l = math.ceil(fftsa.bp_tapk / w)
  if math.mod(l, 2) == 0 then l = l + 1 end
  if l > fftsa.bp_lmax then return nil end
  if l < 3 then l = 3 end
  return l
end

-- The decimation is limited by TWO things, and the filter is usually the tighter of them:
-- the read budget, and whether a filter short enough to run can hold the transition that
-- decimation leaves. Stepping down until both fit is what keeps the passband flat across
-- the displayed span -- decimating harder than the taps can support is how the amplitudes
-- came out low.
function fftsa.bp_pick_d(fs, fhi, n)
  if fs == nil or fhi == nil or n == nil or fhi <= 0 or n < 2 then return 1 end
  local dmax = math.floor((fftsa.bp_maxm - fftsa.bp_lmax) / (n - 1))
  local d = math.floor(fs / (2.56 * fhi))
  if d > dmax then d = dmax end
  while d > 1 and fftsa.bp_taps_for(fs, fhi, d) == nil do d = d - 1 end
  if d < 1 then d = 1 end
  return d
end

-- WHY a decimation of 1 came out, for the readback line. Three different reasons land on
-- the same answer and the operator cannot tell them apart otherwise: at a 4096-sample
-- count the read budget leaves no room whatever the span, which reads as nothing to do
-- with the span at all.
function fftsa.bp_why(fs, fhi, n)
  if fs == nil or fhi == nil or n == nil then return "off" end
  if math.floor(fs / (2.56 * fhi)) < 2 then return "span too wide" end
  if math.floor((fftsa.bp_maxm - fftsa.bp_lmax) / (n - 1)) < 2 then
    return "too many samples"
  end
  if fftsa.bp_taps_for(fs, fhi, 2) == nil then return "filter will not fit" end
  return "no room"
end

-- Windowed-sinc low-pass, cutoff at the stop frequency, Hamming-windowed and normalised
-- to unit DC gain so the filter cannot change a reading's amplitude. Built once per Apply,
-- which costs L terms against fft_init's thousands.
function fftsa.bp_build(fs, fhi, n, d)
  fftsa.bp_d = d
  if d < 2 then
    fftsa.bp_l, fftsa.bp_h, fftsa.bp_m = 0, nil, n
    return 1
  end
  local l = fftsa.bp_taps_for(fs, fhi, d)
  if l == nil then l = fftsa.bp_lmax end
  -- THE CUTOFF SITS BETWEEN THE SPAN TOP AND THE DECIMATED NYQUIST, not on the span top:
  -- a filter's roll-off starts before its cutoff, so a cutoff at fhi puts the whole
  -- displayed band inside the roll-off and reads every peak low. Halfway leaves the
  -- passband flat to fhi and the stopband begun by the Nyquist.
  local fc = 0.5 * (fhi / fs + 0.5 / d)
  if fc > 0.5 / d then fc = 0.5 / d end
  local c = (l - 1) / 2
  local h, sum = {}, 0
  local i
  for i = 1, l do
    local m = (i - 1) - c
    local v
    if m == 0 then
      v = 2 * fc
    else
      v = math.sin(2 * math.pi * fc * m) / (math.pi * m)
    end
    -- Hamming, which holds the first sidelobe near -43 dB for a tap count this small.
    v = v * (0.54 - 0.46 * math.cos(2 * math.pi * (i - 1) / (l - 1)))
    h[i] = v
    sum = sum + v
  end
  for i = 1, l do h[i] = h[i] / sum end
  fftsa.bp_h, fftsa.bp_l = h, l
  fftsa.bp_m = (n - 1) * d + l
  -- Allocated once per Apply, never per frame, and only when the size changes.
  if fftsa.bp_out == nil or fftsa.bp_n ~= n then
    fftsa.bp_out, fftsa.bp_n = {}, n
    for i = 1, n do fftsa.bp_out[i] = 0 end
  end
  return d
end

-- One decimated record: output j is the filter centred on input (j-1)*d + 1, so the
-- inputs this needs are 1 .. (n-1)*d + l, which is fftsa.bp_m. No nil test in the inner
-- loop -- fftsa.frame_body() rejects a capture shorter than bp_m before calling this --
-- and the yield is per output chunk, like fft_load's.
function fftsa.bp_filter(rd)
  local n, d, l = fftsa.fft_n, fftsa.bp_d, fftsa.bp_l
  local h, out = fftsa.bp_h, fftsa.bp_out
  if d < 2 or h == nil or out == nil then return nil end
  local chunk = fftsa.fft_yield_n
  local lo = 1
  while lo <= n do
    local hi = lo + chunk - 1
    if hi > n then hi = n end
    local j
    for j = lo, hi do
      local base = (j - 1) * d
      local acc, t = 0, nil
      for t = 1, l do
        acc = acc + rd[base + t] * h[t]
      end
      out[j] = acc
    end
    lo = hi + 1
    if lo <= n then delay(fftsa.fft_yield) end
  end
  return out
end

function fftsa.fft_load(buf)
  return fftsa.fft_load_rd(buf.readings)
end

-- The same load from a plain array, which is what the band-pass path produces. Extracted
-- rather than copied: the weighted-mean removal and the windowing are subtle enough that
-- two versions of them would drift.
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
