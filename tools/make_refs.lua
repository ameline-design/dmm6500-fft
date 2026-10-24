-- make_refs.lua -- regenerate the pinned reference values in tools/test_tsp.lua.
--
-- Deliberately INDEPENDENT of tsp/fft_core.tsp: its own window, its own weighted-mean
-- removal and its own O(N^2) direct DFT, so the literals it prints are not the app's
-- output fed back into the app's own test. It then reports the app's figures beside
-- its own, which is a check and not the source of the numbers.
--
-- The scaling matches the app's contract: bin power in volts-squared peak, so an
-- on-bin tone of amplitude A reads A^2. With X the windowed DFT and S the window sum,
-- that is (2*|X|/S)^2.
--
--   ~/tmp/base/out/lua502/bin/lua tools/make_refs.lua

local N, fs = 512, 100000
local pi, cos, sin, sqrt = math.pi, math.cos, math.sin, math.sqrt

-- Symmetric Hann, built here rather than read from the app.
local w, S = {}, 0
for i = 1, N do
  w[i] = 0.5 - 0.5 * cos(2 * pi * (i - 1) / (N - 1))
  S = S + w[i]
end

-- Direct DFT of the windowed, DC-removed record. Returns power 1..N/2.
local function power_of(xs)
  local wsx = 0
  for i = 1, N do wsx = wsx + w[i] * xs[i] end
  local m = wsx / S                     -- the weighted mean is what zeroes windowed DC
  local wx = {}
  for i = 1, N do wx[i] = w[i] * (xs[i] - m) end
  local p = {}
  for k = 0, N/2 - 1 do
    local re, im = 0, 0
    local a = -2 * pi * k / N
    for i = 1, N do
      local th = a * (i - 1)
      re = re + wx[i] * cos(th)
      im = im + wx[i] * sin(th)
    end
    local mag = 2 * sqrt(re*re + im*im) / S
    p[k + 1] = mag * mag
  end
  return p, m
end

local KEYS = {1, 2, 3, 20, 21, 22, 23, 63, 64, 65, 66, 128, 142, 143, 144, 200, 255, 256}

-- Case 1: a 2.5 V pedestal and three tones.
local xs = {}
for i = 1, N do
  local t = (i - 1) / fs
  xs[i] = 2.5 + 0.7 * sin(2 * pi * 12345 * t)
             + 0.3 * sin(2 * pi * 4000 * t + 0.5)
             + 0.1 * cos(2 * pi * 27777 * t)
end
local p1 = power_of(xs)

print('  local REF = {')
local line = '   '
for n = 1, table.getn(KEYS) do
  local k = KEYS[n]
  line = line .. string.format(' [%d]%s= %.12e,', k, string.rep(' ', 4 - string.len('' .. k)), p1[k])
  if math.mod(n, 2) == 0 then print(line); line = '   ' end
end
if line ~= '   ' then print(line) end
print('  }')

local tot = 0
for k = 1, N/2 do tot = tot + p1[k] end
print(string.format("  total power          %.12e", tot))

-- Case 2: a 1 V pedestal and one tone at a 0.2-bin offset.
local ys = {}
for i = 1, N do ys[i] = 1.0 + 0.5 * sin(2 * pi * 12345 * (i - 1) / fs) end
local p2 = power_of(ys)
local pk, pv = 0, -1
for k = 2, N/2 do if p2[k] > pv then pk, pv = k, p2[k] end end
print(string.format("  case 2 peaks in bin  %d", pk))
print(string.format("  raw scalloped read   %.9f V", sqrt(pv)))
print(string.format("  case 2 DC bin power  %.4e", p2[1]))

-- The window constants, for the two checks that pin them.
print(string.format("  coherent gain        %.17g", S / N))
local ksq = (1 / S) * (1 / S)
print(string.format("  power scale          %.15e", ksq))

-- Now the app, for comparison only.
dofile('tsp/fft_core.tsp')
fftsa.win_i = 1
fftsa.fft_init(N)
fftsa.fft_load({readings = xs, n = N})
fftsa.fft_run()
fftsa.fft_power()
local worst, worstk = 0, 0
for n = 1, table.getn(KEYS) do
  local k = KEYS[n]
  local d = math.abs(fftsa.fft_pwr[k] - p1[k]) / (1e-9 * p1[k] + 1e-14)
  if d > worst then worst, worstk = d, k end
end
print('')
print(string.format('app vs this independent DFT: worst %.3f of the suite budget, at bin %d',
                    worst, worstk))
print(string.format('app coherent gain %.17g, power scale %.15e',
                    fftsa.fft_cg, fftsa.fft_ksq))
