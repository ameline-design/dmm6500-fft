-- window_check.lua -- what the peak estimator actually achieves, per window.
--
-- Drives the real tsp/fft_core.tsp over synthesised tones of known frequency and
-- known amplitude, so both halves of the estimate are checked against the truth
-- rather than against each other. Reports, per window and per Kaiser beta:
--
--   df     worst sub-bin frequency error, in bins
--   dA     worst amplitude error, in dB
--   scallop  G(0.5), the amplitude a tone half a bin off a centre is read low by
--   SL     peak sidelobe level, measured from the window's own transform
--   w20    the -20 dB peak width in bins, on a bin centre and half a bin off --
--          the two numbers behind "the peak at 25 kHz is narrower than at 24"
--   skirt swing
--          the level at the second bin from the peak, on a centre against half a
--          bin off: 2.0 bins from the tone against 1.5. Hann's is set by how close
--          its null at 2 bins comes to zero, so it scales with N.
--
-- Run from the repo root with Lua 5.0.2:
--   ~/tmp/base/out/lua502/bin/lua tools/window_check.lua [N]

local N = 512
if arg ~= nil and arg[1] ~= nil then N = tonumber(arg[1]) or 512 end

dofile('tsp/fft_core.tsp')

local floor, cos, sqrt, pi = math.floor, math.cos, math.sqrt, math.pi
local log10 = math.log10 or function(x) return math.log(x) / math.log(10) end

-- A reading buffer, as much of one as fftsa.fft_load() touches.
local function tone_buf(nsamp, bin, amp, phase)
  local b = {readings = {}, n = nsamp}
  local w = 2 * pi * bin / N
  for i = 1, nsamp do b.readings[i] = amp * cos(w * (i - 1) + phase) end
  return b
end

local function run_tone(bin, amp, phase)
  fftsa.fft_load(tone_buf(N, bin, amp, phase))
  fftsa.fft_run()
  fftsa.fft_power()
  local M, best, bk = fftsa.fft_m, -1, 0
  for k = 2, M - 1 do
    local v = fftsa.fft_pwr[k]
    if v > best then best, bk = v, k end
  end
  return bk, best
end

-- G(x) straight from the window samples, for the sidelobe scan: fftsa.fft_gtab only
-- reaches 1.5 bins.
local function G(x)
  local w, M2, ctr = fftsa.fft_win, floor(N/2), (N + 1) / 2
  local a, s, ws = 2 * pi * x / N, 0, 0
  for i = 1, M2 do
    s  = s + w[i] * cos(a * (i - ctr))
    ws = ws + w[i]
  end
  s = s / ws
  if s < 0 then s = -s end
  return s
end

local function sidelobe_db()
  -- Walk out of the main lobe, then take the highest point beyond it. The first
  -- sidelobe is the tallest for every window here, but the scan does not assume it.
  local x, prev, step = 0, 1, 0.02
  while x < 12 do
    local g = G(x + step)
    if g > prev then break end          -- past the first null, climbing again
    prev = g
    x = x + step
  end
  local peak = 0
  while x < 12 do
    local g = G(x)
    if g > peak then peak = g end
    x = x + step
  end
  if peak <= 0 then return -999 end
  return 20 * log10(peak)
end

-- Bins within 20 dB of the peak: the visible width of the trace's peak.
local function width20(d)
  local bk = run_tone(128 + d, 1.0, 0.3)
  local pk = fftsa.fft_pwr[bk]
  local n = 0
  for k = 2, fftsa.fft_m - 1 do
    local v = fftsa.fft_pwr[k]
    if v ~= nil and v > 0 and 10 * log10(v / pk) >= -20 then n = n + 1 end
  end
  return n
end

-- Level two bins out, relative to the peak. On a bin centre the DFT samples the
-- window transform at its own nulls and the skirt vanishes; half a bin off it
-- samples the sidelobe envelope instead. The gap between the two is why a tone that
-- happens to land on a centre draws a visibly narrower peak than its neighbours.
--
-- The larger of the two bins two out, not bk+2: at d = 0.5 the two centre bins are
-- equal to within 7e-12, so the > in run_tone's argmax decided which was the peak
-- and moved the sample between 1.5 and 2.5 bins from the tone, 17 dB apart. The
-- larger is the one 1.5 bins out whichever way the tie falls.
local function skirt2(d)
  local bk = run_tone(128 + d, 1.0, 0.3)
  local pk = fftsa.fft_pwr[bk]
  local s  = fftsa.fft_pwr[bk - 2]
  local hi = fftsa.fft_pwr[bk + 2]
  if s == nil or (hi ~= nil and hi > s) then s = hi end
  if s == nil or s <= 0 then return -200 end
  return 10 * log10(s / pk)
end

-- Sweep sub-bin offsets at a mid-spectrum bin, over a few phases and amplitudes.
-- 83 is coprime with the 40 nodes of the interpolation grid, so the offsets land
-- between table nodes rather than on them -- on them every window reads 0.00000.
local function sweep(centre)
  local worst_f, worst_a, at_f, at_a = 0, 0, 0, 0
  local j
  for j = -41, 41 do
    local d = j / 83
    local ph
    for ph = 0, 2 do
      local amp = 1.0
      if ph == 1 then amp = 0.05 end
      local bk = run_tone(centre + d, amp, ph * 1.1)
      local dk, v = fftsa.peak_interp(bk, fftsa.fft_m)
      if v ~= nil then
        local ef = math.abs((bk - 1 + dk) - (centre + d))
        local ea = math.abs(20 * log10(v / amp))
        if ef > worst_f then worst_f, at_f = ef, d end
        if ea > worst_a then worst_a, at_a = ea, d end
      end
    end
  end
  return worst_f, worst_a, at_f, at_a
end

-- Derived from the window list, so adding or removing one needs no edit here.
local cfgs, nc = {}, 0
local i
for i = 1, table.getn(fftsa.win_names) do
  if fftsa.win_cos[i] ~= nil then
    nc = nc + 1
    cfgs[nc] = {wi = i, bi = nil}
  else
    local b
    for b = 1, table.getn(fftsa.kbetas) do
      nc = nc + 1
      cfgs[nc] = {wi = i, bi = b}
    end
  end
end

print(string.format('N = %d, tone at bin 128, 83 offsets across -0.5..0.5 (coprime '
                    .. 'with the table grid), 3 phase/amplitude combinations each', N))
print('')
print('window         df (bins)   dA (dB)   scallop     SL     w20     skirt swing')
print('--------------------------------------------------------------------------')
local nfail = 0
for i = 1, table.getn(cfgs) do
  local c = cfgs[i]
  fftsa.win_i = c.wi
  if c.bi ~= nil then fftsa.kbeta_i = c.bi end
  fftsa.fft_init(N)
  local name = fftsa.win_label()
  local wf, wa = sweep(128)
  local sc = 20 * log10(fftsa.win_gain(0.5))
  local sl = sidelobe_db()
  local w0, w1 = width20(0), width20(0.5)
  local s0, s1 = skirt2(0), skirt2(0.5)
  print(string.format('%-12s  %9.2e  %8.1e   %6.2f  %7.1f   %d/%d   %6.1f dB%s',
                      name, wf, wa, sc, sl, w0, w1, math.abs(s0 - s1),
                      fftsa.win_mono and '' or '   NOT MONOTONIC'))
  if not fftsa.win_mono then nfail = nfail + 1 end
end

-- Away from mid-spectrum the tone's negative-frequency image leaks into its own
-- skirts, so the low end is where the estimator is weakest.
print('')
print('same, with the tone near the low edge (Hann):')
fftsa.win_i = 1
fftsa.fft_init(N)
for i = 1, 4 do
  local centre = ({4, 8, 16, 64})[i]
  local wf, wa = sweep(centre)
  print(string.format('  bin %3d   df %9.2e   dA %8.1e', centre, wf, wa))
end

-- Two tones, the weak one inside the strong one's skirt: the mixed-signal case,
-- read through the app's own peak finder rather than a hand-picked bin.
dofile('tsp/spectrum_ui.tsp')
print('')
print('two tones, strong at bin 128.37, weak 40 dB down 5 bins up:')
for i = 1, table.getn(cfgs) do
  local c = cfgs[i]
  fftsa.win_i = c.wi
  if c.bi ~= nil then fftsa.kbeta_i = c.bi end
  fftsa.fft_init(N)
  local b = {readings = {}, n = N}
  local w1, w2 = 2*pi*128.37/N, 2*pi*133.37/N
  local j
  for j = 1, N do
    b.readings[j] = cos(w1*(j-1)) + 0.01*cos(w2*(j-1) + 0.7)
  end
  fftsa.fft_load(b); fftsa.fft_run(); fftsa.fft_power()
  local bi = fftsa.find_peaks(fftsa.fft_m, 2)
  -- Peak 1 is the strong tone; the weak one is whichever of the two is not it.
  local k = bi[2]
  if bi[1] > 131 then k = bi[1] end
  local dk, v = fftsa.peak_interp(k, fftsa.fft_m)
  local txt = '      none found'
  if v ~= nil then
    txt = string.format('%8.3f bins (want 133.370), %7.2f dBV (want -40.00)',
                        k - 1 + dk, 20 * log10(v))
  end
  print(string.format('  %-12s  %s', fftsa.win_label(), txt))
end

print('')
if nfail > 0 then
  print(string.format('%d window(s) have a non-monotonic r(d): their peak offsets '
                      .. 'are not usable', nfail))
else
  print('every window has a monotonic r(d) over the half-bin range')
end
