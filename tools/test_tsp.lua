-- test_tsp.lua -- unit tests that run the REAL .tsp modules on the host.
--
-- The instrument is the only place the shipped code normally runs, and getting
-- there costs a power cycle (one build per power cycle), so everything that is
-- not genuinely device-dependent is tested here instead. This loads the actual
-- tsp/*.tsp sources -- not a re-implementation, which could drift from them --
-- against a mock of the instrument API.
--
-- The mock deliberately ERRORS when a deleted object is touched and keeps a
-- live-object census, which is what lets these tests prove the object-lifetime
-- invariant: nothing is ever created over a live handle, and a rebuild leaks
-- nothing (orphaned display objects survive until the next power cycle and are
-- what walk the firmware toward a panic).
--
-- Run from the repo root:  lua tools/test_tsp.lua
--
-- Host Lua is 5.4/5.5; the instrument is 5.0.2. The shims below supply the two
-- 5.0.2 library functions the modules use that newer Lua dropped. tools/lint_tsp.py
-- separately guards against 5.0.2 SYNTAX incompatibilities.

-- ---------- Lua 5.0.2 compatibility shims ----------
-- 5.0.2 has table.getn natively. No '#' fallback: '#' is rejected at PARSE
-- time by 5.0.2, so even a branch that never runs stops the file loading.
if table.getn == nil then error('this suite requires Lua 5.0.2 (table.getn)') end
math.log10  = math.log10  or function(x) return math.log(x, 10) end
math.mod    = math.mod    or math.fmod

-- ---------- test harness ----------
local pass, fail = 0, 0
local function check(name, cond, detail)
  if cond then
    pass = pass + 1
    print("  PASS  " .. name .. (detail and ("   " .. detail) or ""))
  else
    fail = fail + 1
    print("  FAIL  " .. name .. (detail and ("   " .. detail) or ""))
  end
end
local function near(a, b, tol) return a ~= nil and b ~= nil and math.abs(a - b) <= tol end

-- ---------- mock instrument ----------
local OBJ = {}        -- id -> {type=, parent=, alive=, text=, value=}
local nextid = 0
local function newobj(kind, parent)
  nextid = nextid + 1
  OBJ[nextid] = {type = kind, parent = parent, alive = true}
  return nextid
end
local function live(kind)
  local n = 0
  for _, o in pairs(OBJ) do
    if o.alive and (kind == nil or o.type == kind) then n = n + 1 end
  end
  return n
end
local function use(h, what)
  if h == nil then error(what .. " on a nil handle", 0) end
  local o = OBJ[h]
  if o == nil then error(what .. " on an unknown handle", 0) end
  if not o.alive then error(what .. " on a DELETED object (dangling handle)", 0) end
  return o
end

local BUFS = {}       -- buffer objects, so we can count live ones
local function newbuf(cap)
  local b = {alive = true, cap = cap, n = 0, readings = {},
             relativetimestamps = {}, extra = {}, seconds = {}}
  function b.clear()
    b.n = 0
    b.readings, b.relativetimestamps, b.extra = {}, {}, {}
  end
  BUFS[table.getn(BUFS) + 1] = b
  return b
end
local function livebufs()
  local n = 0
  for _, b in ipairs(BUFS) do if b.alive then n = n + 1 end end
  return n
end

display = {
  ROOT = 0, SCREEN_HOME = -1,
  OBJ_SCREEN = 'screen', OBJ_GRAPH = 'graph', OBJ_TEXT = 'text',
  OBJ_BUTTON = 'button', OBJ_TIMER = 'timer', OBJ_RECT = 'rect',
  OBJ_EDIT_NUMBER = 'editnum', OBJ_EDIT_OPTION = 'editopt',
  EVENT_PRESS = 'press', EVENT_ENDAPP = 'endapp',
  EVENT_DRAG = 'drag', EVENT_CURSOR = 'cursor',
  FONT_SMALL = 1, FONT_MEDIUM = 2,
  JUST_LEFT = 0, JUST_CENTER = 1, JUST_RIGHT = 2,
  NFORMAT_PREFIX = 1, TIMER_FOREVER = -1,
  YSCALE_OFF = 0, XSCALE_OFF = 0, AXIS_NORMAL = 0, STYLE_LINE = 1,
  ELEMENT_DATA = 'data', ELEMENT_TIME = 'time',
  -- Object states. Only these two are modelled, because they are the two the
  -- app uses: STATE_DISABLE and STATE_READONLY are refused on a Graph with
  -- event 1717 on the real firmware, so modelling them would model a bug.
  STATE_ENABLE = 0, STATE_INVISIBLE = 3,
  active = nil, events = {},
}
function display.create(parent, kind, ...)
  local a = arg
  -- The firmware rejects a width outside 1..799 with "1130 Parameter width,
  -- expected value from 1 to 799" -- and returns nil rather than raising, so the
  -- object silently does not exist. Mirror the limit here so a geometry mistake
  -- fails on the host instead of on the instrument.
  if kind == display.OBJ_RECT or kind == display.OBJ_GRAPH then
    local w = a[3]
    if w ~= nil and (w < 1 or w > 799) then
      error('width ' .. tostring(w) .. ' outside the firmware limit 1..799', 0)
    end
  end
  local h = newobj(kind, parent)
  -- Which screen was on show at the moment of creation. The only evidence that
  -- separates a screen built behind the loading cover from one built in view: both
  -- look identical once finished.
  OBJ[h].born_on = display.active
  -- x and y, where the object has them: an OBJ_SCREEN's first argument is its title.
  if type(a[1]) == 'number' and type(a[2]) == 'number' then
    OBJ[h].x, OBJ[h].y = a[1], a[2]
  end
  -- OBJ_EDIT_NUMBER is (x, y, label, help, format, value, min, max, units), so the
  -- seeded value is a[6]. a[5] is the format constant, and reading that as the value
  -- made every field read back as 1 before any setvalue.
  if kind == display.OBJ_EDIT_NUMBER then OBJ[h].value = a[6] end
  if kind == display.OBJ_EDIT_OPTION then OBJ[h].value = 1 end
  if kind == display.OBJ_TEXT then OBJ[h].text = a[3] end
  if kind == display.OBJ_TEXT then OBJ[h].justify = a[6] end
  if kind == display.OBJ_EDIT_OPTION then OBJ[h].help = a[4] end
  -- Creating a screen makes it the active one. Modelled because it is the whole
  -- reason the cover has to be raised again after every screen create.
  if kind == display.OBJ_SCREEN then display.active = h end
  return h
end
-- Objects parented to `scr` that were created while `scr` was the screen on show.
-- Timers are excluded because one draws nothing, so creating it in view cannot be
-- seen. The app does not need the exemption -- fftsa.start() arms under the cover --
-- but this suite re-arms three times further down to prove timers do not stack, and
-- those creates land on a visible screen.
function born_in_view(scr)
  local n = 0
  for _, o in pairs(OBJ) do
    if o.parent == scr and o.born_on == scr and o.type ~= display.OBJ_TIMER then
      n = n + 1
    end
  end
  return n
end
-- The mock's record for a handle: kind, parent, x, y, text, value, born_on.
function obj_at(h) return OBJ[h] end
function display.delete(h)
  local o = use(h, 'delete')
  o.alive = false
  for id, c in pairs(OBJ) do                    -- children die with the parent
    if c.parent == h and c.alive then OBJ[id].alive = false end
  end
end
function display.changescreen(h)
  if h ~= display.SCREEN_HOME then use(h, 'changescreen') end
  display.active = h
end
function display.settext(h, txt)
  local o = use(h, 'settext')
  o.text = txt
  o.sets = (o.sets or 0) + 1     -- counted so tests can assert per-frame traffic
end
-- The hide/show the per-frame refill brackets itself with. `hidden` is what the
-- tests read; `hides` counts the transitions so per-frame traffic can be
-- asserted rather than assumed.
function display.setstate(h, st)
  local o = use(h, 'setstate')
  if st == display.STATE_INVISIBLE then
    o.hidden = true
    o.hides = (o.hides or 0) + 1
  elseif st == display.STATE_ENABLE then
    o.hidden = false
  else
    error('state ' .. tostring(st) .. ' is refused on this object type (1717)', 0)
  end
end
-- The per-frame yield. Counted rather than ignored: it is the only thing in the
-- frame that lets the display task paint, so a test must be able to see it.
DELAYED, DELAYS = 0, 0
function delay(s)
  DELAYED = DELAYED + (s or 0)
  DELAYS = DELAYS + 1
end

function display.setvalue(h, v)  use(h, 'setvalue').value = v end
function display.getvalue(h)     return use(h, 'getvalue').value end
function display.setevent(h, ev, cmd)
  use(h, 'setevent')
  display.events[h] = display.events[h] or {}
  display.events[h][ev] = cmd
end
display.graph = {}
-- `traces` is the live trace count; `adds` and `removes` count the CALLS. The
-- distinction matters: a removeall+add pair leaves the count at 1, exactly as
-- never touching it does, so only the call counters can see a per-frame
-- detach and re-attach -- the thing that used to cost 43 ms a frame.
function display.graph.add(g, ...)
  use(g, 'graph.add')
  OBJ[g].adds = (OBJ[g].adds or 0) + 1
  -- Firmware binds nothing for an empty buffer, even if later frames fill it.
  if arg[1].n == 0 then return end
  OBJ[g].buffer = arg[1]
  OBJ[g].traces = (OBJ[g].traces or 0) + 1
end
function display.graph.removeall(g)
  use(g, 'graph.removeall')
  OBJ[g].buffer = nil
  OBJ[g].traces = 0
  OBJ[g].removes = (OBJ[g].removes or 0) + 1
end
function display.graph.drawstyle(g, s)  use(g, 'graph.drawstyle') end
function display.graph.scaley(g, ...)   use(g, 'graph.scaley') end
function display.setcolor(h, ...)       use(h, 'setcolor') end
function display.setfill(h, ...)        use(h, 'setfill'); OBJ[h].fills = (OBJ[h].fills or 0) + 1 end
-- Records the pinned range so tests can assert the axis is not auto-ranging, and
-- returns it when called with the id alone, like the real readback.
function display.graph.scalex(g, ...)
  use(g, 'graph.scalex')
  local a = arg
  if a[3] ~= nil then
    OBJ[g].xmin, OBJ[g].xmax = a[3], a[4]
    OBJ[g].pins = (OBJ[g].pins or 0) + 1   -- counted: re-pinning flickers the axis
  end
  return OBJ[g].xmin, OBJ[g].xmax
end

buffer = {
  STYLE_WRITABLE_FULL = 'wf', STYLE_STANDARD = 'std',
  UNIT_VOLT = 'V', UNIT_HERTZ = 'Hz', DIGITS_4_5 = 45, DIGITS_6_5 = 65,
  write = {},
}
function buffer.make(cap, style) return newbuf(cap) end
function buffer.delete(b)
  if type(b) ~= 'table' or not b.alive then error('buffer.delete on a dead buffer', 0) end
  for _, o in pairs(OBJ) do
    if o.alive and o.buffer == b then error('deleting a buffer still bound to a graph', 0) end
  end
  b.alive = false
end
function buffer.write.format(b, ...) if not b.alive then error('format on dead buffer', 0) end end
-- Fractional times the firmware would refuse. It posts event 1131 -- a MODAL
-- DIALOG, once per call -- and RETURNS, so this counts rather than raises, which is
-- what the real call does. A frame writes 255 points, so a dialog per point makes
-- the app impossible to exit; that is why this is counted and asserted.
BADFRAC = 0
-- The firmware's stated limit, and the mock refuses above it. fftsa.sg_split_t
-- carries at it, one representable step conservative, so the gap between the two is
-- deliberate -- and invisible from inside sg_update, which is why a check below
-- asserts the relationship rather than leaving the mock to catch it.
FRAC_MAX = 0.9999999
-- "Data must be added in chronological order" -- buffer.write.reading, Details.
-- Counted rather than raised, since what the real call does with an out-of-order
-- timestamp is not known. The mock used to store secs + frac without ever comparing
-- two of them, so a non-monotonic sequence passed in silence.
NONMONO = 0
function buffer.write.reading(b, val, extra, secs, frac)
  if not b.alive then error('write to a DELETED buffer', 0) end
  if frac == nil or frac < 0 or frac > FRAC_MAX then BADFRAC = BADFRAC + 1 end
  b.n = b.n + 1
  b.readings[b.n] = val
  b.extra[b.n] = extra
  local t = secs + frac
  if b.n > 1 and t <= b.seconds[b.n - 1] then NONMONO = NONMONO + 1 end
  b.seconds[b.n] = t
end

-- Signal source for the mocked digitizer: a 12.5 kHz tone on a 2.5 V pedestal.
local SIG = {f = 12500, amp = 1.0, dc = 2.5, short = false}
dmm = {FUNC_DIGITIZE_VOLTAGE = 'digv', digitize = {}}
function dmm.digitize.read(b)
  local count = dmm.digitize.count or 512
  local fs    = dmm.digitize.samplerate or 100000
  if SIG.short then count = math.floor(count / 2) end     -- simulate a partial read
  b.clear()
  for i = 1, count do
    b.n = i
    b.readings[i] = SIG.dc + SIG.amp * math.sin(2 * math.pi * SIG.f * (i - 1) / fs)
    b.relativetimestamps[i] = (i - 1) / fs
  end
  return b.readings[1]
end

function collectgarbage() end   -- no-op; the real one is fine, this keeps it quiet

-- ---------- load the REAL modules ----------
for _, m in ipairs({'tsp/fft_core.tsp', 'tsp/spectrum_ui.tsp',
                   'tsp/spectrum_graph.tsp', 'tsp/spectrum_app.tsp'}) do
  local chunk, err = loadfile(m)
  if chunk == nil then print('LOAD FAILED ' .. m .. ': ' .. tostring(err)); os.exit(1) end
  chunk()
end

print('module load')
check('all four modules load and define fftsa', type(fftsa) == 'table')
local globals = 0
for k, v in pairs(_G) do
  if (type(v) == 'function' or string.find(k, '^sg_') or string.find(k, '^fft_') or string.find(k, '^opt'))
     and string.find(k, '^[a-z]') and k ~= 'fftsa' and _G[k] ~= nil then
    -- only count names the modules could plausibly have leaked
    if string.find(k, '^sg_') or string.find(k, '^fft_') or string.find(k, '^opt') or string.find(k, '^app_') then
      globals = globals + 1
      print('      leaked global: ' .. k)
    end
  end
end
check('the modules leak no app globals besides fftsa', globals == 0)

-- ---------- FFT core ----------
print('\nfft_core (real code)')
local N = 512
fftsa.fft_init(N)
check('coherent gain is the exact window mean', near(fftsa.fft_cg, (N - 1) / (2 * N), 1e-12),
      string.format('cg=%.9f', fftsa.fft_cg))
local cap = buffer.make(N * 4, buffer.STYLE_STANDARD)
dmm.digitize.count, dmm.digitize.samplerate = N, 100000
dmm.digitize.read(cap)
fftsa.fft_load(cap)
fftsa.fft_run()
local nb = fftsa.fft_power()
local binhz = 100000 / N
check('power returns N/2 bins', nb == N / 2, 'nb=' .. tostring(nb))
local bestk, bestv = 0, -1
for k = 1, nb do if fftsa.fft_pwr[k] > bestv then bestk, bestv = k, fftsa.fft_pwr[k] end end
check('peak in the right bin', near((bestk - 1) * binhz, SIG.f, binhz),
      string.format('bin %d = %.0f Hz', bestk, (bestk - 1) * binhz))
local bestamp = math.sqrt(bestv)
check('amplitude within 0.5%', near(bestamp, SIG.amp, 0.005),
      string.format('%.6f V (%.3f%% error)', bestamp,
                    math.abs(bestamp - SIG.amp) * 100))
check('DC pedestal removed', fftsa.fft_pwr[1] < bestv * 1e-6,
      string.format('dc bin %.3e with 2.5 V offset', fftsa.fft_pwr[1]))

-- ---------- find_peaks ----------
print('\nfind_peaks (real code)')
local bi, bv = fftsa.find_peaks(nb, 6)
check('strongest peak is the tone', bi[1] == bestk)
local sorted = true
for p = 1, 5 do if bv[p] < bv[p + 1] then sorted = false end end
check('sorted strongest first', sorted)
-- Index 1 is DC and the fftsa.fft_kdc indices above it are the mean removal's own
-- error, so the first reportable index is fft_kdc + 2. Both halves are asserted:
-- the bin past the region is reported and the region itself never is.
local kdc = fftsa.fft_kdc
check('Hann puts one bin above DC inside the region', kdc == 1,
      'fft_kdc=' .. tostring(kdc))
fftsa.fft_pwr = {}
for k = 1, nb do fftsa.fft_pwr[k] = 1e-12 end
fftsa.fft_pwr[kdc + 2] = 0.25
local b2 = fftsa.find_peaks(nb, 6)
check('the first bin past the DC region is reportable', b2[1] == kdc + 2,
      'bi[1]=' .. tostring(b2[1]) .. ', want ' .. (kdc + 2))
fftsa.fft_pwr[kdc + 2] = 1e-12
fftsa.fft_pwr[2] = 1.0            -- a full-scale peak, inside the region
local bdc = fftsa.find_peaks(nb, 6)
check('a peak inside the DC region is refused however tall it stands', bdc[1] == 0,
      'bi[1]=' .. tostring(bdc[1]))
-- windowing keeps an out-of-window tone out of the table
for k = 1, nb do fftsa.fft_pwr[k] = 1e-12 end
fftsa.fft_pwr[62] = 0.04      -- ~12 kHz, inside 8-16 kHz
fftsa.fft_pwr[205] = 1.0     -- ~40 kHz, outside
local wi = fftsa.find_peaks(nb, 6, 41, 82)
check('windowed search ignores the off-screen tone', wi[1] == 62, 'bi[1]=' .. tostring(wi[1]))
local outside = false
for p = 1, 6 do if wi[p] ~= 0 and (wi[p] < 41 or wi[p] > 82) then outside = true end end
check('no reported peak outside the window', not outside)
check('nil-sparse power bins do not raise', (function()
  fftsa.fft_pwr = {}
  fftsa.fft_pwr[5] = 0.01                    -- everything else nil
  local ok = pcall(function() fftsa.find_peaks(nb, 6) end)
  return ok
end)())

-- ---------- sub-bin peak interpolation ----------
-- Reproduces the hardware measurement exactly: a 12.000 kHz 1.000 V tone at
-- 100 kS/s and N=512, where the bin grid (195.3 Hz) puts the tone 0.44 bins
-- above bin 62 -- the worst case for a single-bin read.
print('\npeak_interp (real code)')
SIG.f, SIG.amp = 12000, 1.0
dmm.digitize.read(cap)
fftsa.fft_load(cap)
fftsa.fft_run()
local nbi = fftsa.fft_power()
local pk, pv = 0, -1
for k = 1, nbi do if fftsa.fft_pwr[k] > pv then pk, pv = k, fftsa.fft_pwr[k] end end
local dk, iv = fftsa.peak_interp(pk, nbi)
local fi = (pk - 1 + dk) * binhz
-- pv is POWER, so the amplitude comparison has to take the root. Left as pv it
-- still passed, by luck: 0.777 is far enough from 1.0 either way. The bound is
-- a voltage bound, so compare a voltage with it.
local pvamp = math.sqrt(pv)
check('the raw peak bin really is off (so this test has teeth)',
      math.abs((pk - 1) * binhz - 12000) > 50 and math.abs(pvamp - 1.0) > 0.05,
      string.format('raw %.1f Hz / %.5f V', (pk - 1) * binhz, pvamp))
check('interpolated frequency within 1 Hz of 12 kHz', near(fi, 12000, 1.0),
      string.format('%.2f Hz (d=%.5f)', fi, dk))
check('interpolated amplitude within 0.5% of 1 V', near(iv, 1.0, 0.005),
      string.format('%.5f V', iv))
check('the offset stays inside half a bin', dk >= -0.5 and dk <= 0.5, 'd=' .. dk)
check('spectrum-edge bins fall back instead of indexing off the end', (function()
  local a, b = fftsa.peak_interp(1, nbi)
  local c, e = fftsa.peak_interp(nbi, nbi)
  return a == 0 and b == nil and c == 0 and e == nil
end)())
check('a sparse spectrum falls back', (function()
  local save = fftsa.fft_pwr
  fftsa.fft_pwr = {}
  fftsa.fft_pwr[5] = 0.01
  local a, b = fftsa.peak_interp(5, nbi)
  fftsa.fft_pwr = save
  return a == 0 and b == nil
end)())
-- An on-bin tone must come back unchanged, not nudged by the correction.
SIG.f = 25 * binhz
dmm.digitize.read(cap)
fftsa.fft_load(cap)
fftsa.fft_run()
fftsa.fft_power()
local dk0, iv0 = fftsa.peak_interp(26, nbi)
check('an on-bin tone is left alone', math.abs(dk0) < 0.01 and near(iv0, 1.0, 0.005),
      string.format('d=%.5f v=%.5f', dk0, iv0))

-- ---------- selectable windows ----------
-- The operator's requirement is that the peak reading is accurate for EVERY window,
-- so every window and every beta is swept here rather than Hann alone. Both halves
-- are checked against the truth: the tone's frequency and its amplitude are known
-- because the tone is synthesised, so neither is compared with the other.
print('\nwindows: peak frequency and amplitude, every window (real code)')
local WN = 512
-- Offsets at j/83 of a bin, coprime with the 40-node interpolation grid. On the
-- nodes every window reads zero error, which measures the grid rather than the code.
-- Routed through fftsa.find_peaks, the way a frame reaches peak_interp, NOT through
-- a local argmax: an argmax always lands on the tone, so it cannot see a tone that
-- is present in the spectrum and absent from the table. `misses` counts that.
--
-- `fb` counts offsets where peak_interp declined and the raw bin was used, which is
-- what fftsa.sg_show_peaks() does, so the error columns describe the number the
-- operator reads rather than the number peak_interp returned.
local function win_sweep(centre, from_j)
  local wf, wa, misses, fb = 0, 0, 0, 0
  if from_j == nil then from_j = -41 end
  for j = from_j, 41 do
    local d  = j / 83
    local bn = centre + d
    local xs = {}
    for i = 1, WN do xs[i] = math.cos(2 * math.pi * bn * (i - 1) / WN + 0.3) end
    fftsa.fft_load({readings = xs, n = WN})
    fftsa.fft_run()
    fftsa.fft_power()
    local bi_ = fftsa.find_peaks(fftsa.fft_m, 6, 2, fftsa.fft_m)
    local bk = bi_[1]
    -- The strongest peak must BE the tone, within a bin of where it was put.
    if bk == nil or bk < 1 or math.abs((bk - 1) - bn) > 1.5 then
      misses = misses + 1
    else
      local dd, vv = fftsa.peak_interp(bk, fftsa.fft_m)
      if vv == nil then
        fb = fb + 1
        dd, vv = 0, math.sqrt(fftsa.fft_pwr[bk])
      end
      local ef = math.abs((bk - 1 + dd) - bn)
      local ea = math.abs(20 * math.log10(vv))     -- amplitude is 1.0, so dB vs 0
      if ef > wf then wf = ef end
      if ea > wa then wa = ea end
    end
  end
  return wf, wa, misses, fb
end
-- Rows of the table reported inside the DC region with the tone placed there. The
-- whole region must stay empty: those bins carry fft_load's own error, so a number
-- printed from them is wrong by up to 11.6 dB and moves with the capture phase.
local function dc_reported(centre)
  local n = 0
  for j = -41, 41 do
    local bn = centre + j / 83
    local xs = {}
    for i = 1, WN do xs[i] = math.cos(2 * math.pi * bn * (i - 1) / WN + 0.3) end
    fftsa.fft_load({readings = xs, n = WN})
    fftsa.fft_run()
    fftsa.fft_power()
    local bi_ = fftsa.find_peaks(fftsa.fft_m, 6, 2, fftsa.fft_m)
    for p = 1, 6 do
      if bi_[p] ~= nil and bi_[p] > 0 and bi_[p] <= fftsa.fft_kdc + 1 then
        n = n + 1
      end
    end
  end
  return n
end
-- Rows the table shows for a tone BELOW the lowest reportable bin. Such a tone
-- leaks into that bin and makes it a local maximum, and it was then reported a
-- whole bin and 16 dB out under Blackman and Kaiser b=9. find_peaks refuses it on
-- the estimate, so nothing may come back at all.
local function dc_leak()
  local n = 0
  local bn = 0.3
  while bn <= 0.99 + 1e-9 do
    for p = 0, 3 do
      local xs = {}
      for i = 1, WN do
        xs[i] = math.cos(2 * math.pi * bn * (i - 1) / WN + p * math.pi / 4)
      end
      fftsa.fft_load({readings = xs, n = WN})
      fftsa.fft_run()
      fftsa.fft_power()
      local bi_ = fftsa.find_peaks(fftsa.fft_m, 6, 2, fftsa.fft_m)
      -- Rows at the mask edge only. The other five legitimately carry whatever
      -- noise-level maxima exist further up the spectrum.
      for s = 1, 6 do
        if bi_[s] ~= nil and bi_[s] > 0 and bi_[s] <= 2 + fftsa.fft_kdc then
          n = n + 1
        end
      end
    end
    bn = bn + 0.01
  end
  return n
end
-- Worst level anywhere in the DC region with the only tone far away and off a bin
-- centre. This is why fft_load weights the mean: the arithmetic mean leaves the
-- window's own DC response behind as a line at bin 1 following G(k), 100 dB above
-- the floor the low-sidelobe windows are chosen for.
--
-- Eight phases, not one. The residue is A*G_rect(b)*cos(phase) about the window
-- centre, and at phase 0.3 alone the arithmetic mean reads -60 dBc here and passed.
local function dc_spur(centre)
  local worst = 0
  for p = 0, 7 do
    local ph = p * math.pi / 8
    local xs = {}
    for i = 1, WN do xs[i] = math.cos(2 * math.pi * centre * (i - 1) / WN + ph) end
    fftsa.fft_load({readings = xs, n = WN})
    fftsa.fft_run()
    fftsa.fft_power()
    for k = 1, fftsa.fft_kdc + 2 do
      local v = fftsa.fft_pwr[k]
      if v ~= nil and v > worst then worst = v end
    end
  end
  if worst <= 0 then return -300 end
  return 10 * math.log10(worst)
end
-- Bounds from tools/window_check.lua, loosened by about 2x so a harmless last-bit
-- change does not fail: measured worst cases are 4.0e-6 bins and 0.0035 dB, both at
-- Kaiser b=4, and both at mid-spectrum. The low and high ends are four to six orders
-- worse and have their own bounds below.
local WIN_DF, WIN_DA = 1e-5, 0.008
-- The first bin the table may report. Measured worst over every window at and above
-- that bin centre: 0.102 bins and 0.15 dB, at Kaiser b=9. Offsets below the centre
-- are not swept -- the tone is then under the app's own low-frequency limit, and the
-- masked bin beside it vetoes the one above, so the table is legitimately empty
-- (1 of 83 under Hann). Loosened like the pair above.
local LOW_DF, LOW_DA = 0.15, 0.3
-- The top bin of the spectrum has no right-hand neighbour, so peak_interp declines
-- for every window and the raw bin is read: half a bin of frequency and 2.3 to
-- 7.1 dB of scalloping, which is the high end of the accuracy claim in the docs.
local TOP_DF, TOP_DA = 0.5, 8.0
local nwin = table.getn(fftsa.win_names)
for wi = 1, nwin do
  fftsa.win_i = wi
  local nb_ = 1
  if fftsa.win_cos[wi] == nil then nb_ = table.getn(fftsa.kbetas) end
  for bi = 1, nb_ do
    fftsa.kbeta_i = bi
    fftsa.fft_init(WN)
    local nm = fftsa.win_label()
    local wf, wa, miss = win_sweep(128)
    check(nm .. ': peak frequency within 1e-5 bins', wf <= WIN_DF,
          string.format('%.2e bins', wf))
    check(nm .. ': peak amplitude within 0.008 dB', wa <= WIN_DA,
          string.format('%.1e dB', wa))
    check(nm .. ': the peak finder reports the tone, every offset', miss == 0,
          miss .. ' of 83 offsets missed')
    -- The DC region, which fft_load's mean removal owns: one or two bins for every
    -- shipped window.
    local kdc = fftsa.fft_kdc
    check(nm .. ': the DC region is one or two bins wide', kdc == 1 or kdc == 2,
          'fft_kdc=' .. tostring(kdc))
    check(nm .. ': a tone inside the DC region is not reported there',
          dc_reported(1) == 0 and dc_reported(0.5) == 0,
          'bin 1: ' .. dc_reported(1) .. ' rows, bin 0.5: ' .. dc_reported(0.5))
    -- And not reported anywhere else either: the first reportable bin must not
    -- pick it up as leakage.
    check(nm .. ': a tone below the limit puts no row in the table at all',
          dc_leak() == 0, dc_leak() .. ' rows at the mask edge over 280 positions')
    -- Both axes. The amplitude error used to be formatted into the message and
    -- never compared, so it read 2.17 dB and passed.
    local lf, la, lmiss = win_sweep(kdc + 1, 0)
    check(nm .. ': the lowest reportable bin is found at every offset', lmiss == 0,
          'bin ' .. (kdc + 1) .. ', ' .. lmiss .. ' of 42 missed')
    check(nm .. ': ... within 0.15 bins and 0.3 dB',
          lf < LOW_DF and la < LOW_DA,
          string.format('%.4f bins, %.2f dB', lf, la))
    -- The arithmetic mean reads -42 to -46 dBc here for every window; the weighted
    -- mean reads -54 (Kaiser b=4, its own sidelobes) to -167 (Kaiser b=18).
    local spur = dc_spur(64.5)
    check(nm .. ': a distant off-centre tone leaves the DC region clean',
          spur < -50, string.format('%.1f dBc', spur))
    local hf, ha, hmiss, hfb = win_sweep(fftsa.fft_m - 1)
    check(nm .. ': the top bin falls back to the raw bin, and reads half a bin out',
          hmiss == 0 and hfb > 0 and hf < TOP_DF and ha < TOP_DA,
          string.format('%d of 83 fell back, %.3f bins, %.2f dB', hfb, hf, ha))
    -- r(d) must rise all the way to half a bin, or the offset is not invertible and
    -- the window has no business being on the list.
    check(nm .. ': r(d) is monotonic to half a bin', fftsa.win_mono)
  end
end
-- The sweep must be able to fail, or the bounds above mean nothing.
check('and the sweep has teeth -- a wrong window in the tables is caught', (function()
  fftsa.win_i = 1
  fftsa.fft_init(WN)
  local hann = fftsa.fft_win
  fftsa.win_i = 4                             -- build Blackman-Harris tables...
  fftsa.fft_init(WN)
  fftsa.fft_win = hann                        -- ...then feed them Hann data
  local wf, wa = win_sweep(128)
  return wf > WIN_DF and wa > WIN_DA, string.format('%.2e bins, %.2f dB', wf, wa)
end)())

print('\nwindow tables (real code)')
fftsa.win_i = 1
fftsa.fft_init(WN)
check('G(0) is exactly 1, so an on-bin tone takes no correction',
      math.abs(fftsa.win_gain(0) - 1) < 1e-12, string.format('%.15f', fftsa.win_gain(0)))
check('G is even, so the correction does not depend on which side d is',
      math.abs(fftsa.win_gain(0.37) - fftsa.win_gain(-0.37)) < 1e-15)
-- Cross-check of the table against theory, which is the only independent evidence
-- that win_tables() built the right thing: Hann's kernel is sin(pi*d)/(pi*d*(1-d^2))
-- in closed form, and the table is a numerical transform of the window samples.
--
-- They do not agree exactly, and must not: the closed form is the PERIODIC Hann and
-- this window is the symmetric one, which differ by O(1/N). So the test is that the
-- gap is small and that it shrinks like 1/N -- an error in the table would not.
-- 5.5e-4 at N=512 is the shipped case, and it is error the old closed-form kernel
-- carried into every amplitude it reported.
check('the Hann table is the Hann kernel, with the symmetric-window residual',
      (function()
  local function worst(n)
    fftsa.win_i = 1
    fftsa.fft_init(n)
    local w = 0
    for j = 1, 20 do
      local d = j / 40
      local want = math.sin(math.pi * d) / (math.pi * d * (1 - d * d))
      local e = math.abs(fftsa.win_gain(d) - want)
      if e > w then w = e end
    end
    return w
  end
  local a, b = worst(512), worst(2048)
  fftsa.fft_init(WN)
  return a < 1e-3 and math.abs(a / b - 4) < 0.4,
         string.format('%.2e at N=512, %.2e at N=2048, ratio %.2f', a, b, a / b)
end)())
check('Hann scalloping loss is -1.42 dB half a bin off centre',
      math.abs(20 * math.log10(fftsa.win_gain(0.5)) + 1.42) < 0.01,
      string.format('%.3f dB', 20 * math.log10(fftsa.win_gain(0.5))))
check('r(d) inverts to exactly half a bin at the top of the table',
      math.abs(fftsa.win_offset(1e6) - 0.5) < 1e-12)
check('a negative ratio gives a negative offset',
      fftsa.win_offset(-0.1) == -fftsa.win_offset(0.1))
-- fft_pwr has to be POPULATED for this to reach win_offset at all: with an empty
-- power array peak_interp returns 0, nil from the sparse guard and the test passes
-- whatever the table is doing. That is how it was written, and it could not fail.
check('with no table built, peak_interp says so instead of guessing', (function()
  local xs = {}
  for i = 1, WN do xs[i] = math.cos(2 * math.pi * 64.3 * (i - 1) / WN) end
  fftsa.fft_load({readings = xs, n = WN})
  fftsa.fft_run()
  fftsa.fft_power()
  -- Control first: with the table intact this same call MUST give an estimate, or
  -- the assertion below is measuring the sparse guard again.
  local c, cv = fftsa.peak_interp(65, 256)
  local keep = fftsa.fft_dhr
  fftsa.fft_dhr = 0
  local a, b = fftsa.peak_interp(65, 256)
  fftsa.fft_dhr = keep
  return cv ~= nil and a == 0 and b == nil,
         string.format('with table: %s; without: %s', tostring(cv), tostring(b))
end)())
-- The coherent gain is what calibrates amplitude, so it has to follow the window.
check('coherent gain follows the window', (function()
  local seen = {}
  for wi = 1, nwin do
    fftsa.win_i = wi
    fftsa.fft_init(WN)
    local cg = string.format('%.9f', fftsa.fft_cg)
    if seen[cg] then return false end
    seen[cg] = true
  end
  return true
end)())
check('the gain grid reaches 1.5 bins, and says so if it ever stops', (function()
  local reach = fftsa.fft_gn * fftsa.fft_ghx
  local keep = fftsa.fft_gn
  fftsa.fft_gn = keep - 1
  local ok = pcall(function() fftsa.fft_init(256) end)
  fftsa.fft_gn = keep
  fftsa.fft_init(WN)
  return reach >= 1.5 and not ok, string.format('reach %.3f bins', reach)
end)())
check('Kaiser beta 4 keeps its first null outside 1.5 bins', (function()
  -- The null is at sqrt(1 + (beta/pi)^2) bins; inside 1.5 the interpolation would
  -- read sidelobe rather than main lobe. This is why the beta list starts at 4.
  local b = fftsa.kbetas[1]
  return math.sqrt(1 + (b / math.pi) ^ 2) > 1.5, 'beta=' .. b
end)())
check('win_label names beta only where beta applies', (function()
  fftsa.win_i = 1
  local a = fftsa.win_label()
  fftsa.win_i = nwin
  local b = fftsa.win_label()
  return string.find(a, 'b=') == nil and string.find(b, 'b=') ~= nil, a .. ' / ' .. b
end)())
fftsa.win_i, fftsa.kbeta_i = 1, 4
fftsa.fft_init(512)
dmm.digitize.count = 512
SIG.f, SIG.amp = 12500, 1.0

-- ---------- window clamping ----------
print('\nsg_window_bins (real code)')
local spans = {{0, 50000}, {8000, 16000}, {499000, 500}, {16000, 8000}, {0, 0}, {500000, 500000}}
local allin = true
for _, s in ipairs(spans) do
  fftsa.sg_set_xrange(s[1], s[2])
  local k0, k1 = fftsa.sg_window_bins(nb, binhz)
  if not (k0 >= 1 and k0 <= nb and k1 >= 1 and k1 <= nb and k1 >= k0) then
    allin = false
    print(string.format('      span %g..%g -> %s..%s', s[1], s[2], tostring(k0), tostring(k1)))
  end
end
check('every span (incl. inverted) stays inside 1..nbins', allin)
fftsa.sg_set_xrange(499000, 500)
local k0, k1 = fftsa.sg_window_bins(nb, binhz)
check('inverted span cannot index past fft_pwr', k0 <= nb and k1 <= nb,
      string.format('kmin=%d kmax=%d nbins=%d', k0, k1, nb))
check('binhz of zero degrades safely', (function()
  local a, b = fftsa.sg_window_bins(nb, 0)
  return a == 1 and b == nb
end)())

-- ---------- axis scale ----------
print('\nseconds-trick axis scale (real code)')
check('a 50 kHz span labels directly in kHz', fftsa.sg_pick_fscale(50000) == 1000)
check('a wider span steps by a decade rather than rolling over',
      fftsa.sg_pick_fscale(500000) == 10000,
      tostring(fftsa.sg_pick_fscale(500000)))
local rollover = false
for _, f in ipairs({500, 5000, 50000, 58999, 60000, 100000, 500000, 1000000}) do
  if f / fftsa.sg_pick_fscale(f) >= 59 then rollover = true end
end
check('no span up to 1 MHz hits the MM:SS rollover', not rollover)
-- The label count the firmware chooses has to be stable, which is what fixing
-- the scale at 1e6 broke: it put a 50 kHz span at 50 ms, where the row drew six
-- labels on most frames and eleven on some. A decade scale keeps every span in
-- a range whose divisions are wide and distinct.
check('a 50 kHz span sits in tens of label-seconds, not hundredths',
      50000 / fftsa.sg_pick_fscale(50000) == 50,
      tostring(50000 / fftsa.sg_pick_fscale(50000)))
fftsa.sg_fscale = fftsa.sg_pick_fscale(50000)
check('legend names both units at the default scale',
      fftsa.sg_xunit_text() == 'X: kHz   Y: dBV', fftsa.sg_xunit_text())
fftsa.sg_fscale = fftsa.sg_pick_fscale(500000)
check('legend states the multiplier once the decade has stepped',
      fftsa.sg_xunit_text() == 'X: kHz   Y: dBV   (graph x10)', fftsa.sg_xunit_text())
-- Back to the real default: later checks divide by this.
fftsa.sg_fscale = 1000

-- ---------- range mapping / sample rate ----------
print('\nrange + sample rate (real code)')
check('range_to_idx round-trips', fftsa.idx_to_range(fftsa.range_to_idx(0.1)) == 0.1
      and fftsa.idx_to_range(fftsa.range_to_idx(10)) == 10)
check('idx_to_range tolerates 1-based', fftsa.idx_to_range(1) == 0.1)
check('idx_to_range tolerates the label string', fftsa.idx_to_range('10 V') == 10)
check('idx_to_range tolerates 0-based', fftsa.idx_to_range(0) == 0.1)
check('idx_to_range clamps out-of-range', fftsa.idx_to_range(99) == 10)
-- THE RATE RULE IS DIRECTIONAL, and that is an anti-aliasing requirement rather
-- than a convenience. There is no anti-alias filter, so a rate whose Nyquist falls
-- below what is on the wire folds it into the display. Measured on hardware: a pure
-- 21.1 kHz sine over a 0-7 kHz span at 20 kS/s drew one 4.51 V peak at 1.100 kHz,
-- which is 21100 reduced mod 20000, with nothing on screen to say so. Raising the
-- rate can only remove aliases; lowering it is what creates them.
check('zooming in never lowers the sample rate below the floor', (function()
  local worst, at = 1e12, 0
  for _, f in ipairs({2000, 3000, 5000, 10000, 20000, 25000, 40000, 50000}) do
    local fs = fftsa.pick_fs(f)
    if fs < worst then worst, at = fs, f end
  end
  return worst >= fftsa.fs_min,
         string.format('lowest %g S/s at a %g Hz stop, floor %g', worst, at,
                       fftsa.fs_min)
end)())
check('the rate never decreases as the span widens', (function()
  local prev, ok = 0, true
  for f = 2000, 500000, 2000 do
    local fs = fftsa.pick_fs(f)
    if fs < prev then ok = false end
    prev = fs
  end
  return ok
end)())
check('widening past the floor Nyquist does raise the rate',
      fftsa.pick_fs(50000) == fftsa.fs_min
      and fftsa.pick_fs(200000) > fftsa.fs_min,
      string.format('%g at 50 kHz, %g at 200 kHz', fftsa.pick_fs(50000),
                    fftsa.pick_fs(200000)))
check('every settable span is covered by its own Nyquist', (function()
  local bad = 0
  for f = fftsa.fhi_min, fftsa.fhi_max, 1000 do
    if fftsa.pick_fs(f) / 2 < f then bad = bad + 1 end
  end
  return bad == 0, bad .. ' span(s) past Nyquist'
end)())
check('the widest span is the fastest rate Nyquist, so no bandwidth is thrown away',
      fftsa.fhi_max * 2 == fftsa.rates[table.getn(fftsa.rates)],
      string.format('fhi_max %g, fastest %g', fftsa.fhi_max,
                    fftsa.rates[table.getn(fftsa.rates)]))
check('acquisition is short at every rate, so the panel keeps its slice', (function()
  local worst = 0
  for i = 1, table.getn(fftsa.rates) do
    local a = fftsa.n / fftsa.rates[i]
    if a > worst then worst = a end
  end
  return worst < 0.010, string.format('%.1f ms worst', worst * 1000)
end)())
check('the finest bin width is the floor rate, and it is the default span', (function()
  return fftsa.pick_fs(fftsa.fhi) == fftsa.fs_min
         and fftsa.fs_min / fftsa.n < 200,
         string.format('%.2f Hz bins at the default %g Hz stop',
                       fftsa.pick_fs(fftsa.fhi) / fftsa.n, fftsa.fhi)
end)())

-- ---------- lifecycle: the object-lifetime invariant ----------
print('\nobject lifetime (real code, mocked display)')
check('nothing live before start', live() == 0, 'live=' .. live())
-- This harness made its own buffer for the fft_core tests above; only buffers
-- beyond that baseline belong to the app and must be freed by fftsa.stop().
local base_bufs = livebufs()
fftsa.flo, fftsa.fhi, fftsa.range = 0, 50000, 10
local ok, err = pcall(function() fftsa.start() end)
check('start() succeeds', ok, tostring(err))
local after1, bufs1 = live(), livebufs()
check('start() created objects', after1 > 0, 'live=' .. after1 .. ' buffers=' .. bufs1)
check('frame and preview timers are live', live('timer') == 2)
check('exactly three screens are live', live('screen') == 3,
      'screens=' .. live('screen') .. ' (cover + spectrum + options)')
check('the graph has exactly one trace bound', (function()
  return OBJ[fftsa.sg_graph].traces == 1
end)(), 'traces=' .. tostring(OBJ[fftsa.sg_graph].traces))

-- a second start() must not orphan the first build
local ok2 = pcall(function() fftsa.start() end)
check('start() twice succeeds', ok2)
check('rebuilding leaks NO display objects', live() == after1,
      'live=' .. live() .. ' vs ' .. after1)
check('rebuilding leaks NO buffers', livebufs() == bufs1,
      'buffers=' .. livebufs() .. ' vs ' .. bufs1)
check('still exactly two timers after rebuild', live('timer') == 2,
      'timers=' .. live('timer'))
check('still exactly three screens after rebuild', live('screen') == 3,
      'screens=' .. live('screen'))

-- arm() must never stack timers (two would double the frame rate and flood)
fftsa.arm(0.3); fftsa.arm(0.3); fftsa.arm(0.3)
check('arm() three more times still leaves two timers', live('timer') == 2,
      'timers=' .. live('timer'))

-- frames run clean
fftsa.errcount, fftsa.shortreads = 0, 0
for _ = 1, 5 do fftsa.frame() end
check('5 frames run without a dropped frame', fftsa.errcount == 0,
      'errcount=' .. fftsa.errcount .. ' lasterr=' .. tostring(fftsa.lasterr))
check('peak fields were populated', OBJ[fftsa.sg_pk_f[1]].text ~= nil
      and string.find(OBJ[fftsa.sg_pk_f[1]].text, 'kHz') ~= nil,
      tostring(OBJ[fftsa.sg_pk_f[1]].text))
check('the x-axis legend is on screen', OBJ[fftsa.sg_xunit].text ~= nil,
      tostring(OBJ[fftsa.sg_xunit].text))

-- The peak-text gate, asserted in both directions. Five frames ran above and
-- only the first of them is allowed to have drawn the block; a gate that never
-- opens would pass the "populated" check above just as well as a correct one,
-- so suppression and drawing are both tested.
check('the block drew at least once across those five frames',
      fftsa.sg_pk_last ~= nil, tostring(fftsa.sg_pk_last))
local pbi, pbv = fftsa.find_peaks(fftsa.n / 2, fftsa.sg_npeak, 1, fftsa.n / 2)
check('a second call inside the same second is suppressed',
      fftsa.sg_show_peaks(pbi, pbv, fftsa.sg_npeak, fftsa.binhz) == false)
-- Open the clock gate by hand: the tolerance alone must still hold it shut
-- when nothing has moved, which is the other half of the requirement.
fftsa.sg_pk_last = fftsa.sg_pk_last - 2 * fftsa.sg_pk_period
check('past the clock gate, an unchanged spectrum draws nothing',
      fftsa.sg_show_peaks(pbi, pbv, fftsa.sg_npeak, fftsa.binhz) == false)
-- And prove it is not simply stuck shut.
fftsa.sg_pk_last  = fftsa.sg_pk_last - 2 * fftsa.sg_pk_period
fftsa.sg_pk_lf[1] = nil
check('past the clock gate, a moved peak does draw',
      fftsa.sg_show_peaks(pbi, pbv, fftsa.sg_npeak, fftsa.binhz) == true)

-- The per-frame repaint refills IN PLACE and then yields. It must not detach,
-- re-attach or hide the graph: all three repaint the whole widget, and the
-- operator sees the graph's own axis label text flicker once per frame. This is
-- the only order that leaves the axes alone, so the absence of those calls is
-- the behaviour under test, not an implementation detail.
--
-- Counted calls, not the live trace count: a removeall+add pair leaves the
-- count at 1, exactly as never touching it does, so a count cannot tell them
-- apart. An earlier version of this test asserted the count and passed with the
-- pair restored, which is how that was found.
print('\nper-frame repaint is in place, with a yield (real code)')
local gh = fftsa.sg_graph
local ad0, rm0 = (OBJ[gh].adds or 0), (OBJ[gh].removes or 0)
local dl0 = DELAYS
fftsa.frame_body()
check('the frame does not detach the trace', (OBJ[gh].removes or 0) == rm0,
      'removes=' .. tostring(OBJ[gh].removes) .. ' was ' .. tostring(rm0))
check('nor re-attach it', (OBJ[gh].adds or 0) == ad0,
      'adds=' .. tostring(OBJ[gh].adds) .. ' was ' .. tostring(ad0))
check('nor hide it', (OBJ[gh].hides or 0) == 0,
      'hides=' .. tostring(OBJ[gh].hides))
check('the trace stays attached throughout', OBJ[gh].traces == 1,
      'traces=' .. tostring(OBJ[gh].traces))
check('and the frame yields exactly once for the paint', DELAYS == dl0 + 1,
      'delays=' .. DELAYS .. ' was ' .. dl0)

-- The yield is the only thing feeding the display task, so a zero or missing
-- one is a silent regression into the jumpy behaviour. Assert the value too.
check('the yield is the configured amount', fftsa.sg_yield > 0.005
      and fftsa.sg_yield < 0.1, tostring(fftsa.sg_yield))

-- A frame that raises part way through must still leave a usable graph.
local realupd = fftsa.sg_update
fftsa.sg_update = function() error('raised mid-refill', 0) end
fftsa.errcount, fftsa.errrun = 0, 0
fftsa.frame()
fftsa.sg_update = realupd
check('a frame raising mid-refill still leaves a trace attached',
      OBJ[gh].traces == 1, 'traces=' .. tostring(OBJ[gh].traces))
check('and the failure was counted rather than swallowed', fftsa.errcount == 1,
      'errcount=' .. tostring(fftsa.errcount))
fftsa.errcount, fftsa.errrun, fftsa.lasterr = 0, 0, nil

-- Our own X tick labels, in kHz, below the plot (the firmware's read seconds).
print('\ncustom axis labels (real code)')
check('there is an X tick for each end and the divisions between',
      fftsa.sg_xlab ~= nil and table.getn(fftsa.sg_xlab) == fftsa.sg_nxlab)
check('X ticks are labelled across the current span',
      OBJ[fftsa.sg_xlab[1]].text == '0.0 kHz'
      and OBJ[fftsa.sg_xlab[fftsa.sg_nxlab]].text == '50.0 kHz',
      tostring(OBJ[fftsa.sg_xlab[1]].text) .. ' .. '
      .. tostring(OBJ[fftsa.sg_xlab[fftsa.sg_nxlab]].text))
check('the legend names both units', fftsa.sg_xunit_text() == 'X: kHz   Y: dBV',
      fftsa.sg_xunit_text())
-- THE invariant that makes the labels visible at all: anything inside the graph's
-- rectangle is erased by its per-frame repaint, and re-issuing it each frame
-- flickers and floods. So the ticks must sit below the graph and above the peaks.
check('the X ticks sit BELOW the graph rectangle, where a repaint cannot erase them',
      fftsa.sg_xlab_y > fftsa.sg_gy + fftsa.sg_gh and fftsa.sg_xlab_y < fftsa.sg_pky,
      string.format('xlab_y=%d graph bottom=%d peaks start=%d', fftsa.sg_xlab_y,
                    fftsa.sg_gy + fftsa.sg_gh, fftsa.sg_pky))
-- Geometry must stay in OBJECT coordinates (0..420, below the 49 px title bar).
check('label geometry is inside the usable object area',
      fftsa.sg_xlab_y <= 420 and fftsa.sg_px1 <= 799 and fftsa.sg_px0 >= 0,
      string.format('xlab %d px %d..%d', fftsa.sg_xlab_y, fftsa.sg_px0, fftsa.sg_px1))
check('the tick row is derived from the graph, so moving the graph moves it',
      fftsa.sg_xlab_y == fftsa.sg_gy + fftsa.sg_gh + 18,
      string.format('xlab_y=%d gy=%d gh=%d', fftsa.sg_xlab_y, fftsa.sg_gy,
                    fftsa.sg_gh))
check('the graph starts at the top of the object area', fftsa.sg_gy == 0,
      'gy=' .. fftsa.sg_gy)
check('the graph and the peak table both fit the panel',
      fftsa.sg_gy + fftsa.sg_gh < fftsa.sg_pky
      and fftsa.sg_pky + (fftsa.sg_npeak / 2 - 1) * fftsa.sg_pkdy < fftsa.sg_xunit_y,
      string.format('graph %d..%d, peaks %d, legend %d', fftsa.sg_gy,
                    fftsa.sg_gy + fftsa.sg_gh, fftsa.sg_pky, fftsa.sg_xunit_y))
-- -120 dBV, not -100: the DMM7510's noise floor is 12 to 14 dB below the DMM6500's
-- and at -100 it sat off the bottom of the plot.
check('the dB floor reaches the DMM7510 noise floor', fftsa.sg_dbmin == -120,
      'dbmin=' .. fftsa.sg_dbmin)
check('the voltage floor is below the dB floor, so log10 never sees a zero',
      20 * math.log10(fftsa.sg_vfloor) < fftsa.sg_dbmin,
      string.format('vfloor %g = %.0f dBV', fftsa.sg_vfloor,
                    20 * math.log10(fftsa.sg_vfloor)))
check('a bin under the floor is plotted AT the floor, not dropped', (function()
  local save = fftsa.fft_pwr
  fftsa.fft_pwr = {}
  for k = 1, fftsa.sg_nbins do fftsa.fft_pwr[k] = 1e-30 end   -- -300 dBV
  fftsa.sg_update(fftsa.sg_nbins, 195.3125)
  local lo = nil
  for i = 1, fftsa.sg_buf.n do
    local v = fftsa.sg_buf.readings[i]
    if lo == nil or v < lo then lo = v end
  end
  fftsa.fft_pwr = save
  return lo == fftsa.sg_dbmin, 'lowest written = ' .. tostring(lo)
end)())
-- Every comparison with a NaN is false, so a `db < dbmin` test lets one through to
-- buffer.write.reading. Hardening only: no reachable NaN was found, so this feeds
-- one in by hand.
check('a NaN power bin is plotted at the floor, not written as a NaN', (function()
  local save = fftsa.fft_pwr
  fftsa.fft_pwr = {}
  for k = 1, fftsa.sg_nbins do fftsa.fft_pwr[k] = 1e-4 end
  fftsa.fft_pwr[40] = 0 / 0
  local ok = pcall(function() fftsa.sg_update(fftsa.sg_nbins, 195.3125) end)
  local bad, seen = 0, nil
  for i = 1, fftsa.sg_buf.n do
    local v = fftsa.sg_buf.readings[i]
    if not (v >= fftsa.sg_dbmin and v <= fftsa.sg_dbmax) then
      bad = bad + 1
      seen = v
    end
  end
  fftsa.fft_pwr = save
  -- The premise: 0/0 really is a NaN in this interpreter, so the input was one.
  local nan = 0 / 0
  return ok and bad == 0 and not (nan == nan),
         string.format('%d written outside the axis (%s), 0/0 is %s', bad,
                       tostring(seen), tostring(nan))
end)())
-- Floored at the plot's own floor: a 1e-26 power bin reads -260 dBV against a
-- -120 dBV axis, which the trace cannot show.
check('the peak table dB column is floored at the plot floor', (function()
  local save = fftsa.fft_pwr
  fftsa.fft_pwr = {}
  for k = 1, fftsa.sg_nbins do fftsa.fft_pwr[k] = 1e-30 end
  fftsa.fft_pwr[40] = 1e-26
  fftsa.sg_show_peaks_now({40}, {1e-26}, 1, 195.3125)
  local txt = obj_at(fftsa.sg_pk_d[1]).text
  fftsa.fft_pwr = save
  fftsa.sg_pk_last = nil                 -- let the next frame redraw the block
  return txt == '-120.0 dBV', tostring(txt)
end)())
-- Start 1999 / Stop 2000 is legal and leaves one plotted point, so the trace is a
-- dot and five peak rows read ---. The legend is the only place that can say why.
check('a span with almost no bins in it says so in the legend', (function()
  local lo, hi, bz = fftsa.sg_flo_hz, fftsa.sg_fhi_hz, fftsa.binhz
  fftsa.binhz = 195.3125
  fftsa.sg_flo_hz, fftsa.sg_fhi_hz = 1999, 2000
  local narrow = fftsa.sg_xunit_text()
  fftsa.sg_flo_hz, fftsa.sg_fhi_hz = 10, 50000
  local wide = fftsa.sg_xunit_text()
  fftsa.sg_flo_hz, fftsa.sg_fhi_hz, fftsa.binhz = lo, hi, bz
  return string.find(narrow, '1 bin in this span', 1, true) ~= nil
         and wide == 'X: kHz   Y: dBV',
         narrow .. ' | wide: ' .. wide
end)())
check('the X axis is PINNED to the window, not auto-ranged', (function()
  local lo, hi = display.graph.scalex(fftsa.sg_graph)
  return near(lo, fftsa.sg_flo_hz / fftsa.sg_fscale, 1e-9)
     and near(hi, fftsa.sg_fhi_hz / fftsa.sg_fscale, 1e-9)
end)(), 'pinned to ' .. tostring(fftsa.sg_flo_hz) .. '..' .. tostring(fftsa.sg_fhi_hz))
-- The optimisation: an unchanged span must cost no display messages at all.
check('an unchanged span is skipped, not rewritten', fftsa.sg_axis_update() == false)
check('a changed span relabels', (function()
  fftsa.sg_set_xrange(8000, 16000)
  return OBJ[fftsa.sg_xlab[1]].text == '8.0 kHz'
     and OBJ[fftsa.sg_xlab[fftsa.sg_nxlab]].text == '16.0 kHz'
end)(), tostring(OBJ[fftsa.sg_xlab[1]].text) .. ' .. '
      .. tostring(OBJ[fftsa.sg_xlab[fftsa.sg_nxlab]].text))
check('a narrow span switches the ticks to Hz', (function()
  fftsa.sg_set_xrange(8000, 8200)
  return OBJ[fftsa.sg_xlab[1]].text == '8000 Hz'
     and OBJ[fftsa.sg_xlab[fftsa.sg_nxlab]].text == '8200 Hz'
end)(), tostring(OBJ[fftsa.sg_xlab[1]].text) .. ' .. '
      .. tostring(OBJ[fftsa.sg_xlab[fftsa.sg_nxlab]].text))
-- Re-issuing labels every frame is what flickered and saturated the display
-- processor on hardware, so a refresh must not touch them at all.
check('a frame refresh costs ZERO label traffic', (function()
  local before = OBJ[fftsa.sg_xlab[1]].sets or 0
  fftsa.sg_bind_min()
  fftsa.sg_bind_min()
  return (OBJ[fftsa.sg_xlab[1]].sets or 0) == before
end)())
-- Re-pinning per frame makes the firmware redraw its own axis labels, which shows
-- as flicker on hardware. The pin survives a re-add, so a refresh must not re-pin.
check('a frame refresh does NOT re-pin the axis', (function()
  local before = OBJ[fftsa.sg_graph].pins or 0
  fftsa.sg_bind_min()
  fftsa.sg_bind_min()
  return (OBJ[fftsa.sg_graph].pins or 0) == before
end)())
check('setting a new span DOES re-pin', (function()
  local before = OBJ[fftsa.sg_graph].pins or 0
  fftsa.sg_set_xrange(4000, 20000)
  return (OBJ[fftsa.sg_graph].pins or 0) > before
end)())
fftsa.sg_set_xrange(fftsa.flo, fftsa.fhi)

-- a short capture must be REJECTED, not zero-padded into a false spectrum
SIG.short = true
local before = fftsa.shortreads
for _ = 1, 3 do fftsa.frame() end
check('short captures are rejected, not transformed', fftsa.shortreads == before + 3,
      'shortreads=' .. fftsa.shortreads)
check('a rejected short capture is not an error frame', fftsa.errcount == 0,
      'errcount=' .. fftsa.errcount)
SIG.short = false

-- Nothing may be assembled where the operator can watch it happen. The cover is
-- what prevents it, and the mock's born_on is the only thing that can see it.
print('\nloading cover (real code)')
check('nothing on the spectrum screen was created while it was on show',
      born_in_view(fftsa.sg_scr) == 0, 'in view=' .. born_in_view(fftsa.sg_scr))
check('nothing on the options form was created while it was on show',
      born_in_view(fftsa.optscr) == 0, 'in view=' .. born_in_view(fftsa.optscr))
-- The cover is allocated once and outlives the build, because Apply raises it again
-- for the 0.3 s the window tables take to rebuild. Creating and deleting one per
-- raise would cycle two pool objects every time.
check('the cover is still allocated after start()', fftsa.loadscr ~= nil)
check('and the spectrum screen is the one on show', display.active == fftsa.sg_scr)
check('raising the cover creates nothing', (function()
  local before = live()
  fftsa.loading_front()
  local mid = live()
  fftsa.show_main()
  return mid == before and live() == before
end)())
-- The control: without the cover both screens build in full view. Without this the
-- two checks above pass whether the cover works or not.
check('and that check has teeth -- without the cover, both screens build in view',
      (function()
  local real = fftsa.loading_front
  fftsa.loading_front = function() return false end
  fftsa.stop()
  fftsa.start()
  local n = born_in_view(fftsa.sg_scr) + born_in_view(fftsa.optscr)
  fftsa.loading_front = real
  fftsa.stop()
  fftsa.start()
  return n > 0, 'in view=' .. n
end)())
check('and the cover is raised again after the rebuild',
      born_in_view(fftsa.sg_scr) + born_in_view(fftsa.optscr) == 0)
-- A press must only ever switch screens: with everything built at launch, a nil
-- handle means the pool refused and building it now would fail the same way.
check('options() creates nothing when the form handle is nil', (function()
  local keep = fftsa.optscr
  fftsa.optscr = nil
  local before = live()
  local r = fftsa.options()
  fftsa.optscr = keep
  return r == false and live() == before
end)())

-- A fractional time above 0.9999999 is refused with event 1131, a modal dialog per
-- refused write, and math.floor() produces one when the scaled frequency lands a
-- rounding error below an integer.
--
-- How often: over every reachable configuration the naive floor refuses at most 3
-- points of 256 in one frame, and nothing at all in 514691 of 515052. The
-- 255-of-256 figure recorded with the fix came from a bin width of 999.9999999999,
-- which needs 512000 S/s -- 2.4 % off the commanded rate -- so it is outside the
-- reachable set, not at its edge. measure_fs's round trip 511/(511/fs) is exact or
-- lands above exact at every rate, never below, so the hazard cannot repeat every
-- frame for a stated reason.
--
-- The bench symptom is therefore still unexplained. This query, with the app
-- running, settles whether a real frame goes near the limit -- counting in place,
-- since the readback line shows binhz to 2 dp:
--   do local n=0 for k=2,256 do local t=((k-1)*fftsa.binhz)/fftsa.sg_fscale
--   if t-math.floor(t) > 0.9999999 then n=n+1 end end
--   print("BADFRAC="..n.." binhz="..string.format("%.14g",fftsa.binhz)) end
-- If that prints 0, the 1131 storm had another cause and that cause is still there.
print('\nfractional time (real code)')
check('sg_split_t carries a near-integer into the whole part', (function()
  local w, fr = fftsa.sg_split_t(9.9999999999)
  return w == 10 and fr == 0, string.format('%d + %.12f', w, fr)
end)())
check('and the naive floor it replaces WOULD have been refused', (function()
  local t = 9.9999999999
  local naive = t - math.floor(t)
  return naive > 0.9999999, string.format('naive frac %.12f', naive)
end)())
check('an exact value is left alone', (function()
  local w, fr = fftsa.sg_split_t(12.25)
  return w == 12 and fr == 0.25, string.format('%d + %g', w, fr)
end)())
-- The worst bin width the hardware can produce: one ulp below the exact 390.625 of
-- 200 kS/s, putting bins 64, 128 and 192 a hair under 25, 50 and 75 label-seconds.
local FRAC_WORST = 199999.99999999997 / 512
local function naive_refusals(binhz, fscale)
  local bad = 0
  for k = 1, fftsa.sg_nbins do
    local t = ((k - 1) * binhz) / fscale
    if t - math.floor(t) > 0.9999999 then bad = bad + 1 end
  end
  return bad
end
local function frame_refusals(binhz)
  local before = BADFRAC
  local lo, hi, sc = fftsa.sg_flo_hz, fftsa.sg_fhi_hz, fftsa.sg_fscale
  fftsa.sg_flo_hz, fftsa.sg_fhi_hz, fftsa.sg_fscale = 0, 1e6, 1000
  for k = 1, fftsa.sg_nbins do fftsa.fft_pwr[k] = 1e-4 end
  fftsa.sg_update(fftsa.sg_nbins, binhz)
  fftsa.sg_flo_hz, fftsa.sg_fhi_hz, fftsa.sg_fscale = lo, hi, sc
  return BADFRAC - before
end
check('the worst REACHABLE bin width writes no fraction the firmware would refuse',
      frame_refusals(FRAC_WORST) == 0,
      'refused writes: ' .. frame_refusals(FRAC_WORST))
check('and that frame really did hit the hazard, so the check has teeth',
      naive_refusals(FRAC_WORST, 1000) == 3,
      naive_refusals(FRAC_WORST, 1000) .. ' of ' .. fftsa.sg_nbins
      .. ' points would have been refused by the naive floor')
-- A stress case, not a reachable one: 999.9999999999 Hz bins need 512000 S/s, and
-- every point is then a hair under a whole label-second.
check('and so does a bin width the hardware cannot reach', (function()
  local bad = naive_refusals(999.9999999999, 1000)
  return frame_refusals(999.9999999999) == 0 and bad == 255,
         bad .. ' of ' .. fftsa.sg_nbins .. ' would have been refused'
end)())
check('no frame anywhere in this suite wrote a refused fraction', BADFRAC == 0,
      'total refused: ' .. BADFRAC)
-- One representable step tighter than the firmware's limit, which is the safe
-- direction. Asserted because the mock's predicate is the firmware's, so it cannot
-- see the guard loosened past it.
check('the carry threshold sits at or below the fraction the firmware refuses',
      (function()
  local worst = 0
  local i
  for i = 1, 300 do
    local w, fr = fftsa.sg_split_t(i * 7 - i * 1e-9)     -- a hair under integers
    if fr > worst then worst = fr end
    w, fr = fftsa.sg_split_t(i + FRAC_MAX)
    if fr > worst then worst = fr end
    w, fr = fftsa.sg_split_t(i + FRAC_MAX * (1 - 1e-9))
    if fr > worst then worst = fr end
  end
  return worst <= FRAC_MAX, string.format('worst fraction emitted %.12f', worst)
end)())
-- Every timestamp this suite wrote was above the one before it, within its fill.
check('no buffer fill anywhere in this suite went back in time', NONMONO == 0,
      'out-of-order writes: ' .. NONMONO)

-- the options round trip, including an inverted span
print('\noptions form (real code)')
-- Two columns, six fields, three rows.
local nrows, pitch, top = fftsa.opt_layout()
check('six fields lay out as three rows in two columns', nrows == 3,
      'nrows=' .. nrows)
check('the last box ends above the button row',
      top + (nrows - 1) * pitch + fftsa.opt_edit_dy + fftsa.opt_edit_h
        <= fftsa.opt_btn_y,
      string.format('bottom=%d btn=%d',
                    top + (nrows - 1) * pitch + fftsa.opt_edit_dy
                      + fftsa.opt_edit_h, fftsa.opt_btn_y))
check('the pitch is at least the box height, so boxes cannot overlap',
      pitch >= fftsa.opt_edit_h, 'pitch=' .. pitch .. ' box=' .. fftsa.opt_edit_h)
check('the readback line clears the last box and the buttons',
      fftsa.opt_info_y > top + (nrows - 1) * pitch + fftsa.opt_edit_dy
                             + fftsa.opt_edit_h
        and fftsa.opt_info_y < fftsa.opt_btn_y,
      'info_y=' .. fftsa.opt_info_y)
check('the readout is centered and five pixels lower', (function()
  local o = obj_at(fftsa.opt_info)
  return o.x == 400 and o.y == 323 and o.justify == display.JUST_CENTER
end)())
-- Nine fields, five rows: the first count where the clamp changes the outcome and
-- not just the pitch. 274 px over four gaps is 68, and unclamped the last box would
-- end at 454 against a button row at 360. Six fields -- now the live count -- still
-- lay out as three rows at the same pitch and top as five, so a six-field case here
-- would be a second copy of 'the readback line clears the last box'.
check('a field count that overruns is clamped to fit above the button row',
      (function()
  local keep = fftsa.opt_nf
  fftsa.opt_nf = 9
  local r, p, t = fftsa.opt_layout()
  fftsa.opt_nf = keep
  fftsa.opt_layout()
  local bottom = t + (r - 1) * p + fftsa.opt_edit_dy + fftsa.opt_edit_h
  return r == 5 and p < fftsa.opt_dy and bottom <= fftsa.opt_btn_y,
         string.format('%d rows, pitch %d of %d asked, bottom %d vs button %d',
                       r, p, fftsa.opt_dy, bottom, fftsa.opt_btn_y)
end)())
check('the first three fields are in column one at opt_x', (function()
  local x = fftsa.opt_x
  return obj_at(fftsa.opt_flo).x == x and obj_at(fftsa.opt_fhi).x == x
         and obj_at(fftsa.opt_rng).x == x
end)(), 'x=' .. tostring(obj_at(fftsa.opt_flo).x))
check('the window and sample fields are in column two at opt_x_c2', (function()
  local x = fftsa.opt_x_c2
  return obj_at(fftsa.opt_win).x == x and obj_at(fftsa.opt_beta).x == x
         and obj_at(fftsa.opt_n).x == x
end)(), 'x=' .. tostring(obj_at(fftsa.opt_win).x))
check('each column runs top to bottom at the layout pitch', (function()
  return obj_at(fftsa.opt_fhi).y - obj_at(fftsa.opt_flo).y == pitch
         and obj_at(fftsa.opt_rng).y - obj_at(fftsa.opt_fhi).y == pitch
         and obj_at(fftsa.opt_beta).y - obj_at(fftsa.opt_win).y == pitch
         and obj_at(fftsa.opt_n).y - obj_at(fftsa.opt_beta).y == pitch
end)())
check('the two columns start on the same row',
      obj_at(fftsa.opt_win).y == obj_at(fftsa.opt_flo).y)
-- opt_layout() derives the pitch from opt_nf, so a count that disagrees with the
-- fields actually created lays the form out for a field that is not there.
check('opt_nf matches the number of fields actually created', (function()
  local n = 0
  for _, o in pairs(OBJ) do
    if o.alive and o.parent == fftsa.optscr
       and (o.type == display.OBJ_EDIT_NUMBER or o.type == display.OBJ_EDIT_OPTION) then
      n = n + 1
    end
  end
  return n == fftsa.opt_nf, 'created ' .. n .. ', opt_nf ' .. fftsa.opt_nf
end)())
-- A press is dispatched by the firmware evaluating a command string, so an error
-- raised in a handler becomes a dialog over the app rather than a return value.
check('a handler that raises is caught instead of reaching the panel', (function()
  local before = fftsa.lasterr
  local ok = fftsa.guard(function() error('boom', 0) end)
  local caught = fftsa.lasterr ~= before and
                 string.find(tostring(fftsa.lasterr), 'boom', 1, true) ~= nil
  fftsa.lasterr = before
  return ok == false and caught, tostring(fftsa.lasterr)
end)())
-- A failure that is only recorded is invisible: the operator sees a press that did
-- nothing and the previous spectrum still running.
check('a caught handler failure is also said on the glass', (function()
  fftsa.guard(function() error('visible-boom', 0) end)
  local said = obj_at(fftsa.sg_xunit).text
  pcall(function() display.settext(fftsa.sg_xunit, fftsa.sg_xunit_text()) end)
  return string.find(tostring(said), 'visible-boom', 1, true) ~= nil, tostring(said)
end)())
check('a failed Apply says so, and a good one restores the legend', (function()
  local real = fftsa.apply
  fftsa.apply = function() error('apply-boom', 0) end
  fftsa.options_apply()
  local bad = obj_at(fftsa.sg_xunit).text
  -- No halt asserted here: this failure does not resize, so frames must survive it.
  -- 'a buffer allocation failure halts frames' covers the resize case.
  fftsa.apply = real
  fftsa.options_apply()
  local good = obj_at(fftsa.sg_xunit).text
  return string.find(tostring(bad), 'apply-boom', 1, true) ~= nil
         and not fftsa.halted and good == fftsa.sg_xunit_text(),
         tostring(bad) .. ' | then ' .. tostring(good)
end)())
-- The check above stubs fftsa.apply out, so it never reaches the real body. This
-- one drives it with a capture that raises, after the rate has been written.
check('a capture that raises leaves binhz describing the rate in force', (function()
  local rate0, bin0 = dmm.digitize.samplerate, fftsa.binhz
  display.setvalue(fftsa.opt_fhi, 200000)              -- pick_fs() -> 500 kS/s
  local realread = dmm.digitize.read
  dmm.digitize.read = function() error('trigger timeout', 0) end
  local ok = fftsa.options_apply()
  dmm.digitize.read = realread
  local rate1 = dmm.digitize.samplerate
  -- The premises first: the Apply really failed, and the rate really did move.
  return (not ok) and rate1 ~= rate0
         and math.abs(fftsa.binhz - rate1 / fftsa.n) < 1e-9,
         string.format('ok=%s, rate %g -> %g, binhz %.4f -> %.4f (want %.4f)',
                       tostring(ok), rate0, rate1, bin0, fftsa.binhz,
                       rate1 / fftsa.n)
end)())
-- The operator-visible half: with binhz left at the old rate's value a 12.5 kHz
-- tone read 2500.0 Hz, the ratio 976.5625/195.3125, with errcount 0.
check('and the frames after it report the tone at its real frequency', (function()
  fftsa.errcount = 0
  SIG.f, SIG.amp = 12500, 1.0
  fftsa.frame()
  local bi_ = fftsa.find_peaks(fftsa.fft_m, 6,
                               fftsa.sg_window_bins(fftsa.fft_m, fftsa.binhz))
  local k  = bi_[1]
  local dk = fftsa.peak_interp(k, fftsa.fft_m)
  local f  = (k - 1 + dk) * fftsa.binhz
  return fftsa.errcount == 0 and math.abs(f - 12500) < 50,
         string.format('%.1f Hz, errcount %d, binhz %.4f', f, fftsa.errcount,
                       fftsa.binhz)
end)())
display.setvalue(fftsa.opt_fhi, 50000)                 -- back to the default span
fftsa.options_apply()
check('every button press goes through the guard', (function()
  local bad = nil
  for h, evs in pairs(display.events) do
    local c, o = evs[display.EVENT_PRESS], OBJ[h]
    if c ~= nil and o ~= nil and o.type == display.OBJ_BUTTON
       and string.find(c, 'fftsa.guard(', 1, true) == nil then
      bad = c
    end
  end
  return bad == nil, tostring(bad)
end)())
check('the form carries no instruction text', (function()
  for _, o in pairs(OBJ) do
    if o.alive and o.parent == fftsa.optscr and o.type == display.OBJ_TEXT
       and o.text ~= nil and string.find(o.text, 'Touch') ~= nil then
      return false
    end
  end
  return true
end)())
fftsa.options()
check('options() switches to the form', display.active == fftsa.optscr)
check('the readback line names the window in use',
      string.find(obj_at(fftsa.opt_info).text, fftsa.win_label(), 1, true) ~= nil,
      obj_at(fftsa.opt_info).text)
-- A round trip through the form with nothing touched must change nothing, and must
-- allocate nothing: Apply raises the cover rather than creating one.
check('Apply with nothing changed leaves every setting alone, and allocates nothing',
      (function()
  local flo, fhi, rng, wi = fftsa.flo, fftsa.fhi, fftsa.range, fftsa.win_i
  local before = live()
  fftsa.options_apply()
  return fftsa.flo == flo and fftsa.fhi == fhi and fftsa.range == rng
         and fftsa.win_i == wi and live() == before
         and display.active == fftsa.sg_scr,
         string.format('%g..%g %gV %s, live %d -> %d', fftsa.flo, fftsa.fhi,
                       fftsa.range, fftsa.win_label(), before, live())
end)())
fftsa.options()
display.setvalue(fftsa.opt_flo, 8000)
display.setvalue(fftsa.opt_fhi, 16000)
fftsa.options_apply()
check('a zoom applies', fftsa.flo == 8000 and fftsa.fhi == 16000,
      string.format('%g..%g', fftsa.flo, fftsa.fhi))
check('apply returns to the spectrum', display.active == fftsa.sg_scr)
-- The window fields have to reach the transform, not just the setting: every
-- reading comes out of tables fft_init() rebuilds, so a field that set only
-- fftsa.win_i would leave the previous window in the data it reports.
check('the Window field reaches the transform', (function()
  local cg0 = fftsa.fft_cg
  -- Looked up rather than hardcoded: the list has lost an entry once already.
  local want = 'Blackman'
  local j
  for j = 1, table.getn(fftsa.win_names) do
    if fftsa.win_names[j] == want then display.setvalue(fftsa.opt_win, j) end
  end
  fftsa.options_apply()
  return fftsa.win_name() == want and math.abs(fftsa.fft_cg - cg0) > 1e-6,
         fftsa.win_label() .. ' cg=' .. string.format('%.6f', fftsa.fft_cg)
end)())
check('the Kaiser Beta field reaches the transform', (function()
  display.setvalue(fftsa.opt_win, table.getn(fftsa.win_names))   -- Kaiser is last
  display.setvalue(fftsa.opt_beta, 1)
  fftsa.options_apply()
  local cg4 = fftsa.fft_cg
  local b4  = fftsa.kbeta()
  display.setvalue(fftsa.opt_beta, 6)
  fftsa.options_apply()
  return b4 == 4 and fftsa.kbeta() == 18 and math.abs(fftsa.fft_cg - cg4) > 1e-6,
         string.format('beta %g cg %.6f -> beta %g cg %.6f', b4, cg4,
                       fftsa.kbeta(), fftsa.fft_cg)
end)())
check('an out-of-range option index clamps instead of fetching a nil window',
      (function()
  display.setvalue(fftsa.opt_win, 99)
  fftsa.options_apply()
  local hi = fftsa.win_i
  display.setvalue(fftsa.opt_win, 0)
  fftsa.options_apply()
  return hi == table.getn(fftsa.win_names) and fftsa.win_i == 1,
         'hi=' .. hi .. ' lo=' .. fftsa.win_i
end)())
check('an option field read back as its own label still selects it', (function()
  display.setvalue(fftsa.opt_win, 'Blk-Harris')
  fftsa.options_apply()
  return fftsa.win_name() == 'Blk-Harris', fftsa.win_label()
end)())
display.setvalue(fftsa.opt_win, 1)
fftsa.options_apply()
check('the form returns to Hann', fftsa.win_name() == 'Hann')

print('\nFFT sample selection and preview (real code)')
check('sample-rate labels use SI prefixes', (function()
  return fftsa.sample_rate_text(512) == '512 S/s'
         and fftsa.sample_rate_text(100000) == '100 kS/s'
         and fftsa.sample_rate_text(200000) == '200 kS/s'
         and fftsa.sample_rate_text(500000) == '500 kS/s'
         and fftsa.sample_rate_text(1000000) == '1 MS/s'
end)())
check('all count/rate combinations preview bin spacing and record duration', (function()
  local count0, fs0, n0 = dmm.digitize.count, dmm.digitize.samplerate, fftsa.n
  local objects0, buffers0 = live(), livebufs()
  for i = 1, table.getn(fftsa.sample_counts) do
    local n = fftsa.sample_counts[i]
    display.setvalue(fftsa.opt_n, i)
    for j = 1, table.getn(fftsa.rates) do
      local fs = fftsa.rates[j]
      display.setvalue(fftsa.opt_fhi, fs / 2)
      fftsa.options_preview()
      local text = obj_at(fftsa.opt_info).text
      if string.find(text, 'fs ' .. fftsa.sample_rate_text(fs), 1, true) == nil
         or string.find(text, string.format('bin %.2f Hz', fs / n), 1, true) == nil
         or string.find(text, string.format('acq %.2f ms', 1000 * n / fs), 1, true) == nil
      then return false, text end
    end
  end
  return dmm.digitize.count == count0 and dmm.digitize.samplerate == fs0
         and fftsa.n == n0 and live() == objects0 and livebufs() == buffers0
end)())
check('unchanged previews do not redraw the info line', (function()
  local before = obj_at(fftsa.opt_info).sets
  fftsa.options_preview()
  return obj_at(fftsa.opt_info).sets == before
end)())
check('the preview uses the timestamp-measured rate for the active rate', (function()
  local fs = fftsa.fs
  fftsa.fs = fs - 0.25
  display.setvalue(fftsa.opt_fhi, fftsa.fhi)
  display.setvalue(fftsa.opt_n, 1)
  fftsa.options_preview()
  local text = obj_at(fftsa.opt_info).text
  local expected = fftsa.opt_info_text(fftsa.fs, 512)
  fftsa.fs = fs
  return text == expected
end)())
check('preview and Apply share stop-frequency clamping', (function()
  display.setvalue(fftsa.opt_fhi, 1)
  fftsa.options_preview()
  local low = obj_at(fftsa.opt_info).text
  display.setvalue(fftsa.opt_fhi, fftsa.fhi_max * 2)
  fftsa.options_preview()
  return string.find(low, 'fs 100 kS/s', 1, true) ~= nil
         and string.find(obj_at(fftsa.opt_info).text, 'fs 1 MS/s', 1, true) ~= nil
end)())
check('Cancel discards a pending sample-count edit', (function()
  local n = fftsa.n
  fftsa.options_cancel()
  fftsa.options()
  return fftsa.n == n and display.getvalue(fftsa.opt_n) == fftsa.sample_to_idx(n)
end)())
check('the preview timer is attached to the options screen and refreshes the readout',
      (function()
  for h, o in pairs(OBJ) do
    if o.alive and o.type == display.OBJ_TIMER and o.parent == fftsa.optscr then
      display.setvalue(fftsa.opt_n, '16384')
      display.setvalue(fftsa.opt_fhi, 50000)
      local callback = loadstring(display.events[h][display.EVENT_PRESS])
      callback()
      return string.find(obj_at(fftsa.opt_info).text, 'bin 6.10 Hz', 1, true) ~= nil
             and string.find(obj_at(fftsa.opt_info).text, 'acq 163.84 ms', 1, true) ~= nil
    end
  end
  return false
end)())
check('the graph mock rejects empty bindings until explicitly rebound', (function()
  local b = buffer.make(16, buffer.STYLE_WRITABLE_FULL)
  local g = display.create(fftsa.loadscr, display.OBJ_GRAPH, 0, 0, 100, 100)
  display.graph.add(g, b, display.ELEMENT_DATA, b, display.ELEMENT_TIME)
  fftsa.sg_write_point(b, -20, 1)
  local rejected = OBJ[g].buffer == nil and (OBJ[g].traces or 0) == 0
  display.graph.add(g, b, display.ELEMENT_DATA, b, display.ELEMENT_TIME)
  local rebound = OBJ[g].buffer == b and OBJ[g].traces == 1
  display.graph.removeall(g)
  display.delete(g)
  buffer.delete(b)
  return rejected and rebound
end)())
check('all size transitions keep the original trace bound and plot without leaks',
      (function()
  display.setvalue(fftsa.opt_flo, 10)
  local objects0, buffers0 = live(), livebufs()
  local graph0, screen0 = fftsa.sg_graph, fftsa.sg_scr
  local graphbuf0 = fftsa.sg_buf
  local adds0, removes0 = OBJ[graph0].adds, OBJ[graph0].removes
  local transitions = {1, 2, 1, 3, 1, 4, 1, 5, 1, 6, 1, 6, 5, 4, 3, 2, 1}
  for _, i in ipairs(transitions) do
    local oldcap = fftsa.cap
    local n = fftsa.sample_counts[i]
    display.setvalue(fftsa.opt_n, fftsa.sample_labels[i])
    if not fftsa.options_apply() then return false, fftsa.lasterr end
    if fftsa.n ~= n or fftsa.fft_n ~= n or fftsa.sg_nbins ~= n / 2
       or dmm.digitize.count ~= n or fftsa.cap.cap ~= n * 4
       or fftsa.sg_buf.cap ~= 16384 / 2 + 16 or OBJ[graph0].buffer ~= graphbuf0
       or fftsa.sg_buf ~= graphbuf0 or not graphbuf0.alive
       or OBJ[graph0].adds ~= adds0 or OBJ[graph0].removes ~= removes0
       or live() ~= objects0 or livebufs() ~= buffers0
       or fftsa.busy_max < 2 * n / 512
    then return false, 'wrong size or leaked resource at N=' .. n end
    if oldcap ~= fftsa.cap and oldcap.alive then
      return false, 'old buffer still alive at N=' .. n
    end
    fftsa.frame()
    local kmin, kmax = fftsa.sg_window_bins(n / 2, fftsa.binhz)
    if fftsa.errrun ~= 0 or fftsa.sg_buf.n ~= kmax - kmin + 1 then
      return false, 'frame failed at N=' .. n .. ': ' .. tostring(fftsa.lasterr)
    end
    local bi, bv = fftsa.find_peaks(n / 2, 1)
    local dk = fftsa.peak_interp(bi[1], n / 2)
    if not near((bi[1] - 1 + dk) * fftsa.binhz, SIG.f, 0.1) then
      return false, 'incorrect peak at N=' .. n
    end
  end
  display.setvalue(fftsa.opt_n, 1)
  local ok = fftsa.options_apply()
  fftsa.frame()
  return ok and fftsa.n == 512 and fftsa.sg_nbins == 256
         and OBJ[graph0].buffer == fftsa.sg_buf and OBJ[graph0].traces == 1
         and fftsa.sg_buf.n > 0 and fftsa.errrun == 0
         and fftsa.sg_graph == graph0 and fftsa.sg_scr == screen0
         and live() == objects0 and livebufs() == buffers0
end)())
check('unchanged sample counts reuse acquisition and graph buffers', (function()
  local cap, graphbuf = fftsa.cap, fftsa.sg_buf
  return fftsa.options_apply() and fftsa.cap == cap and fftsa.sg_buf == graphbuf
end)())
check('a buffer allocation failure halts frames and allows recovery', (function()
  display.setvalue(fftsa.opt_n, 2)
  local real = buffer.make
  buffer.make = function() error('resize-boom', 0) end
  local ok = fftsa.options_apply()
  buffer.make = real
  local halted = fftsa.halted
  local message = obj_at(fftsa.sg_xunit).text
  fftsa.frame()
  display.setvalue(fftsa.opt_n, 1)
  local recovered = fftsa.options_apply()
  fftsa.frame()
  return not ok and halted and string.find(message, 'resize-boom', 1, true) ~= nil
         and recovered and not fftsa.halted and fftsa.errrun == 0
         and fftsa.n == 512 and fftsa.sg_nbins == 256
end)())
check('sample changes never allocate or replace a graph buffer', (function()
  local buffers0 = livebufs()
  local graphbuf = fftsa.sg_buf
  display.setvalue(fftsa.opt_n, 2)
  local real, calls = buffer.make, 0
  buffer.make = function(cap, style)
    calls = calls + 1
    if style == buffer.STYLE_WRITABLE_FULL then error('graph buffer replaced', 0) end
    return real(cap, style)
  end
  local ok = fftsa.options_apply()
  buffer.make = real
  local allocations = calls
  display.setvalue(fftsa.opt_n, 1)
  local recovered = fftsa.options_apply()
  fftsa.frame()
  return ok and allocations == 1 and recovered and not fftsa.halted and fftsa.errrun == 0
         and livebufs() == buffers0 and OBJ[fftsa.sg_graph].buffer == graphbuf
         and fftsa.sg_buf == graphbuf
end)())
-- An inverted span must be repaired: a stop below the start describes no bins,
-- and every frame then indexes past fft_pwr and dies on a nil comparison.
display.setvalue(fftsa.opt_flo, 8000)
display.setvalue(fftsa.opt_fhi, 5000)
fftsa.options_apply()
check('stop below start is repaired, not left inverted', fftsa.flo < fftsa.fhi,
      string.format('flo=%g fhi=%g', fftsa.flo, fftsa.fhi))
fftsa.errcount = 0
for _ = 1, 5 do fftsa.frame() end
check('frames still run after an inverted span', fftsa.errcount == 0,
      'errcount=' .. fftsa.errcount .. ' lasterr=' .. tostring(fftsa.lasterr))
-- Every value the fields can return, including ones the form cannot produce: each
-- pair must leave flo < fhi and a bin to plot. Ported from tools/test_algorithms.py,
-- which asserted it against a re-implementation that expected the start to reset to
-- 0, which flomin = 10 made impossible. fftsa.apply is replaced by its span half, so
-- the sweep costs no fft_init and the bin window still follows the repaired pair.
check('no field pair leaves an empty span or an empty bin window', (function()
  local V = {'nil', 0, -1, 1, 9, 10, 11, 1999, 2000, 2001, 8000, 49999, 50000,
             499000, 499999, 500000, 500001, 1e9, 1e300}
  local nv = table.getn(V)
  local function setf(h, v)
    if v == 'nil' then display.setvalue(h, nil) else display.setvalue(h, v) end
  end
  local realapply = fftsa.apply
  fftsa.apply = function() fftsa.sg_set_xrange(fftsa.flo, fftsa.fhi) end
  local bad, least, leastat, n = nil, 1e9, '', 0
  local a, b
  for _, st in ipairs({{10, 50000}, {8000, 16000}, {499000, 500000}}) do
    for a = 1, nv do
      for b = 1, nv do
        fftsa.flo, fftsa.fhi = st[1], st[2]
        setf(fftsa.opt_flo, V[a])
        setf(fftsa.opt_fhi, V[b])
        fftsa.options_apply()
        local k0, k1 = fftsa.sg_window_bins(fftsa.fft_m, fftsa.binhz)
        local pts = k1 - k0 + 1
        n = n + 1
        if not (fftsa.flo < fftsa.fhi) then
          bad = string.format('%s/%s from %g..%g gave %g..%g', tostring(V[a]),
                              tostring(V[b]), st[1], st[2], fftsa.flo, fftsa.fhi)
        end
        if pts < least then
          least = pts
          leastat = string.format('%g..%g', fftsa.flo, fftsa.fhi)
        end
      end
    end
  end
  fftsa.apply = realapply
  setf(fftsa.opt_flo, 10)
  setf(fftsa.opt_fhi, 50000)
  fftsa.options_apply()
  return bad == nil and least >= 1,
         string.format('%d pairs, worst %d plotted point(s) at %s%s', n, least,
                       leastat, bad and (' -- ' .. bad) or '')
end)())

-- The pool-exhaustion path is the one show_error exists for, and it used to blank
-- the panel there: display.create returns nil, every child goes to a nil parent and
-- changescreen(nil) raises inside the pcall.
print('\nstartup failure (real code)')
check('show_error survives an exhausted pool and does not blank the panel',
      (function()
  local real = display.create
  display.create = function() return nil end
  local ok, err = pcall(function() fftsa.show_error('synthetic failure') end)
  display.create = real
  return ok and fftsa.errscr == nil and display.active == display.SCREEN_HOME,
         string.format('raised=%s errscr=%s active=%s', tostring(not ok),
                       tostring(fftsa.errscr), tostring(display.active))
end)())
check('and with a working pool it builds a screen and shows it', (function()
  local h = fftsa.show_error('synthetic failure, readable')
  local on = (display.active == h)
  local txt = false
  for _, o in pairs(OBJ) do
    if o.alive and o.parent == h and o.type == display.OBJ_TEXT
       and o.text ~= nil and string.find(o.text, 'readable', 1, true) ~= nil then
      txt = true
    end
  end
  return h ~= nil and on and txt, 'screen ' .. tostring(h) .. ', message shown: '
         .. tostring(txt)
end)())
check('and stop() reclaims it', (function()
  fftsa.stop()
  return fftsa.errscr == nil and live() == 0, 'live=' .. live()
end)())
fftsa.start()

-- teardown must leave nothing behind
print('\nteardown (real code)')
fftsa.stop()
check('stop() deletes every display object', live() == 0, 'live=' .. live())
check('stop() frees every buffer it made', livebufs() == base_bufs,
      'buffers=' .. livebufs() .. ' vs baseline ' .. base_bufs)
check('stop() nils every handle', fftsa.sg_scr == nil and fftsa.sg_graph == nil
      and fftsa.optscr == nil and fftsa.opt_flo == nil and fftsa.opt_fhi == nil
      and fftsa.opt_rng == nil and fftsa.opt_info == nil and fftsa.optbtn == nil
      and fftsa.opt_n == nil
      and fftsa.timer == nil and fftsa.cap == nil and fftsa.sg_buf == nil
      and fftsa.sg_xlab == nil and fftsa.sg_xlab_txt == nil)
check('stop() twice is harmless', pcall(function() fftsa.stop() end))
check('cleanup() is safe with nothing built', pcall(function() fftsa.cleanup() end))

-- ---------- the deployed launch model: opening the App re-runs the script ----------
-- This is the path a user takes, and it is not the same as calling start() twice:
-- the whole script body runs again first. If the handle declarations reset the
-- fields, the previous launch's objects become unreachable and survive until a
-- power cycle, so this reloads the real module bodies to check they do not.
print('\ninstalled-App relaunch (real code)')
fftsa.flo, fftsa.fhi, fftsa.range = 0, 50000, 10
fftsa.start()
local live_one, bufs_one = live(), livebufs()
check('first launch is live', live_one > 0 and live('timer') == 2)
-- Leave by HOME / another App: EVENT_ENDAPP never fires, nothing is torn down.
for _, m in ipairs({'tsp/fft_core.tsp', 'tsp/spectrum_ui.tsp',
                    'tsp/spectrum_graph.tsp', 'tsp/spectrum_app.tsp'}) do
  loadfile(m)()
end
check('a script reload keeps the live handles reachable',
      fftsa.sg_scr ~= nil and fftsa.timer ~= nil and fftsa.cap ~= nil)
fftsa.start()
check('relaunching leaks NO display objects', live() == live_one,
      'live=' .. live() .. ' vs ' .. live_one)
check('relaunching leaks NO buffers', livebufs() == bufs_one,
      'buffers=' .. livebufs() .. ' vs ' .. bufs_one)
check('exactly two timers after a relaunch', live('timer') == 2, 'timers=' .. live('timer'))

-- A refused deletion must be counted, not mistaken for success.
local realdel = display.delete
local fails0 = fftsa.delfails
display.delete = function() error('firmware refused', 0) end
local delok = fftsa.del_obj(999)
display.delete = realdel
check('a refused delete returns false and is counted',
      delok == false and fftsa.delfails == fails0 + 1, 'delfails=' .. fftsa.delfails)

-- End App pressed while the OPTIONS form is on screen must still tear down.
fftsa.options()
local ev = display.events[fftsa.optscr]
-- Substring, not equality: the command is a STRING the firmware evaluates
-- later, possibly after this app's table is gone, so it is wrapped in a nil
-- guard. What matters is that cleanup is what gets called.
check('End App is hooked on the options screen too',
      ev ~= nil and ev['endapp'] ~= nil
      and string.find(ev['endapp'], 'fftsa.cleanup()', 1, true) ~= nil,
      tostring(ev and ev['endapp']))
if ev ~= nil and ev['endapp'] ~= nil then
  loadstring(ev['endapp'])()
end
check('End App from the options screen frees every object', live() == 0, 'live=' .. live())
check('End App from the options screen frees every buffer', livebufs() == base_bufs,
      'buffers=' .. livebufs())

-- Frames must give up and say so rather than fail silently forever.
fftsa.start()
fftsa.errcount, fftsa.errrun, fftsa.halted = 0, 0, false
local realread = dmm.digitize.read
dmm.digitize.read = function() error('digitizer gone', 0) end
for _ = 1, fftsa.errmax + 2 do fftsa.frame() end
dmm.digitize.read = realread
check('a run of failed frames halts the loop', fftsa.halted == true,
      'errrun=' .. fftsa.errrun .. ' errcount=' .. fftsa.errcount)
check('the halt is stated on screen', OBJ[fftsa.sg_xunit].text ~= nil
      and string.find(OBJ[fftsa.sg_xunit].text, 'HALTED') ~= nil,
      tostring(OBJ[fftsa.sg_xunit].text))
check('a halted app still tears down cleanly',
      (function() fftsa.stop(); return live() == 0 and livebufs() == base_bufs end)(),
      'live=' .. live())

-- ---------- the transform against a direct DFT ----------
-- The gate for replacing the transform. Every other check here looks at the
-- peak bin of a single tone, which a transform can get right while being wrong
-- everywhere else -- a bin-ordering or scaling error in the untangle pass would
-- pass all of them. This compares ALL bins against the textbook sum.
--
-- The scaling being asserted is the one fft_power() applies: power is
-- |2*X[k]|^2 / (sum of the window)^2, so a bin's square root is the peak
-- amplitude of a tone sitting on it, window-corrected.
print('\ntransform vs a direct DFT (real code)')
do
  local NS = 64
  fftsa.fft_init(NS)
  local cap64 = buffer.make(NS * 4, buffer.STYLE_STANDARD)
  dmm.digitize.count = NS
  SIG.f, SIG.amp = 11000, 0.7
  dmm.digitize.read(cap64)
  local mean = fftsa.fft_load(cap64)
  fftsa.fft_run()
  local MS = fftsa.fft_power()

  local win, x = fftsa.fft_win, fftsa.fft_x
  local wsum = 0
  for n = 1, NS do wsum = wsum + win[n] end
  local worst, worstk = 0, 0
  for b = 0, MS - 1 do
    local sr, si = 0, 0
    for n = 1, NS do
      local ang = -2 * math.pi * b * (n - 1) / NS
      local v = (x[n] - mean) * win[n]
      sr = sr + v * math.cos(ang)
      si = si + v * math.sin(ang)
    end
    local want = 4 * (sr * sr + si * si) / (wsum * wsum)
    local got = fftsa.fft_pwr[b + 1]
    -- Relative where the bin carries energy, absolute in the noise floor,
    -- because a 1e-30 bin cannot be compared relatively in doubles.
    local err
    if want > 1e-12 then err = math.abs(got - want) / want
    else err = math.abs(got - want) end
    if err > worst then worst, worstk = err, b end
  end
  check('every bin matches a direct DFT', worst < 1e-9,
        string.format('worst %.3e at bin %d of %d', worst, worstk, MS))

  -- And that the comparison could fail: perturb one bin and re-measure.
  local keep = fftsa.fft_pwr[8]
  fftsa.fft_pwr[8] = keep * 1.01
  local b, sr, si = 7, 0, 0
  for n = 1, NS do
    local ang = -2 * math.pi * b * (n - 1) / NS
    local v = (x[n] - mean) * win[n]
    sr = sr + v * math.cos(ang); si = si + v * math.sin(ang)
  end
  local want8 = 4 * (sr * sr + si * si) / (wsum * wsum)
  check('and the comparison has teeth',
        math.abs(fftsa.fft_pwr[8] - want8) / want8 > 1e-3,
        string.format('perturbed bin 8 by 1%%, err %.3e',
                      math.abs(fftsa.fft_pwr[8] - want8) / want8))
  fftsa.fft_pwr[8] = keep

  -- Restore: later nothing runs, but a suite that grows must not inherit N=64.
  cap64 = nil
  fftsa.fft_init(512)
  dmm.digitize.count = 512
end

-- ---------- the busy-guard watchdog ----------
-- A frame killed from outside never clears fftsa.busy, and every later frame
-- then returns at the top: a frozen trace that stop() cannot recover from.
-- Both directions are asserted, because a watchdog that always fires is just
-- a missing guard and would pass a one-sided test.
print('\nbusy-guard watchdog (real code)')
do
  fftsa.errcount, fftsa.errrun, fftsa.busy_stuck = 0, 0, 0
  fftsa.halted = false
  -- Count body calls rather than display writes: this is about the guard, and
  -- the app has been torn down by this point in the suite.
  local ran = 0
  local realbody = fftsa.frame_body
  fftsa.frame_body = function() ran = ran + 1 end

  -- A guard held for less than busy_max is a frame that really is running.
  fftsa.busy = true
  fftsa.busy_since = os.clock()
  fftsa.frame()
  check('a freshly held guard still blocks re-entry',
        ran == 0 and fftsa.busy_stuck == 0,
        'ran=' .. ran .. ' stuck=' .. tostring(fftsa.busy_stuck))

  -- A guard older than busy_max cannot be a frame that is still running.
  fftsa.busy_since = os.clock() - (fftsa.busy_max + 1)
  fftsa.frame()
  check('a stale guard is broken and the frame runs',
        ran == 1 and fftsa.busy_stuck == 1,
        'ran=' .. ran .. ' stuck=' .. tostring(fftsa.busy_stuck))
  check('and the guard is left clear afterwards', fftsa.busy == false,
        tostring(fftsa.busy))

  fftsa.frame_body = realbody
  fftsa.busy, fftsa.busy_since, fftsa.busy_stuck = false, nil, 0
  fftsa.errcount, fftsa.errrun, fftsa.lasterr = 0, 0, nil
end

-- ---------- pinned reference values ----------
-- The DFT check above recomputes the truth in this file, which catches a wrong
-- transform but not a changed INPUT: if the signal mock drifts, both sides move
-- together and the check still passes. These are literals, computed off-tree by
-- a direct DFT, against a deterministic three-tone input with no math.random
-- (which differs between Lua versions). They also pin the two scale constants,
-- where a silent change would shift every bin by the same factor and so be
-- invisible to a self-consistent comparison.
print('\npinned DFT reference values (real code)')
do
  local N, fs = 512, 100000
  local xs = {}
  for i = 1, N do
    local t = (i - 1) / fs
    xs[i] = 2.5 + 0.7 * math.sin(2 * math.pi * 12345 * t)
                + 0.3 * math.sin(2 * math.pi * 4000 * t + 0.5)
                + 0.1 * math.cos(2 * math.pi * 27777 * t)
  end
  fftsa.fft_init(N)
  fftsa.fft_load({readings = xs, n = N})
  fftsa.fft_run()
  local nbr = fftsa.fft_power()
  check('the reference case returns 256 bins', nbr == 256, 'nb=' .. tostring(nbr))
  -- 511/1024 to within rounding, not bit-exact: fft_cg is a sum of 512 window
  -- samples divided by N, so the last bit is accumulation error (measured
  -- 0.4990234374999999). Asserting equality here fails for no useful reason.
  check('Hann coherent gain is 511/1024',
        math.abs(fftsa.fft_cg - 0.4990234375) <= 1e-15,
        string.format('%.17g', fftsa.fft_cg))
  check('the power scale constant is unchanged',
        math.abs(fftsa.fft_ksq - 1.53185687861183e-05) <= 1e-19,
        string.format('%.15e', fftsa.fft_ksq))

  -- Regenerated by tools/make_refs.lua, which has its OWN window, its own
  -- weighted-mean removal and its own O(N^2) DFT -- so these are not the app's
  -- output pinned against the app. Bin 1 is 1.3e-29 rather than the 1.07e-04 the
  -- arithmetic mean used to leave there: that zero IS the weighted mean working.
  local REF = {
    [1]   = 1.300361262791e-29, [2]   = 1.021704940227e-09,
    [3]   = 5.016625104977e-10, [20]  = 2.976886198854e-03,
    [21]  = 6.663924261446e-02, [22]  = 6.319270653668e-02,
    [23]  = 2.332826285037e-03, [63]  = 6.055496038219e-02,
    [64]  = 4.638311684332e-01, [65]  = 2.105245146147e-01,
    [66]  = 1.196709648263e-03, [128] = 2.275997790175e-11,
    [142] = 1.179005939318e-03, [143] = 9.404683131771e-03,
    [144] = 4.410196683798e-03, [200] = 4.112308028054e-14,
    [255] = 2.881897498689e-15, [256] = 2.871653489567e-15,
  }
  -- Mixed bound, not relative: the sub-1e-14 bins are rounding noise and a pure
  -- relative test fails them at around 1e-7 while telling you nothing.
  local worst, worstk = 0, 0
  for k, ref in pairs(REF) do
    local d = math.abs(fftsa.fft_pwr[k] - ref)
    local allow = 1e-9 * ref + 1e-14
    if d / allow > worst then worst, worstk = d / allow, k end
  end
  check('every pinned bin is within tolerance', worst <= 1.0,
        string.format('worst %.3f of budget at bin %d', worst, worstk))
  local tot = 0
  for k = 1, 256 do tot = tot + fftsa.fft_pwr[k] end
  check('the total power matches the reference',
        math.abs(tot - 8.867318993681e-01) <= 1e-9 * 8.867318993681e-01,
        string.format('%.12e', tot))

  -- Second case: a half-bin offset, which is what exercises peak_interp's
  -- square roots and the untangle away from a bin centre.
  local ys = {}
  for i = 1, N do
    ys[i] = 1.0 + 0.5 * math.sin(2 * math.pi * 12345 * (i - 1) / fs)
  end
  fftsa.fft_load({readings = ys, n = N})
  fftsa.fft_run()
  fftsa.fft_power()
  local pk, pv = 0, -1
  for k = 2, 256 do if fftsa.fft_pwr[k] > pv then pk, pv = k, fftsa.fft_pwr[k] end end
  check('the offset tone peaks in bin 64', pk == 64, 'bin=' .. tostring(pk))
  check('the raw scalloped read is 0.4865 V',
        math.abs(math.sqrt(pv) - 0.486465471) <= 1e-6,
        string.format('%.9f V', math.sqrt(pv)))
  local d64, a64 = fftsa.peak_interp(64, 256)
  check('interpolation recovers 12345 Hz within 0.5 Hz',
        math.abs((64 - 1 + d64) * 195.3125 - 12345) <= 0.5,
        string.format('%.6f Hz (d=%.9f)', (64 - 1 + d64) * 195.3125, d64))
  check('interpolation recovers 0.5 V within 0.5%',
        math.abs(a64 - 0.5) <= 0.005 * 0.5, string.format('%.9f V', a64))
  -- 1e-20, not 1e-5: the weighted mean zeroes windowed DC exactly, so the only
  -- thing left in bin 1 is rounding. At 1e-5 this passed with the arithmetic mean
  -- too, which left 6.5e-07 here and 1.07e-04 in the three-tone case -- enough to
  -- bury a low-frequency tone. The tight bound is what makes it a real guard.
  check('the pedestal is removed to rounding, not merely to small',
        fftsa.fft_pwr[1] < 1e-20, string.format('%.4e', fftsa.fft_pwr[1]))

  fftsa.fft_init(512)
  dmm.digitize.count = 512
end

print()
print(string.format('%d passed, %d failed', pass, fail))
os.exit(fail == 0 and 0 or 1)
