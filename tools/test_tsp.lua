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
table.getn  = table.getn  or function(t) return #t end
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
  BUFS[#BUFS + 1] = b
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
  active = nil, events = {},
}
function display.create(parent, kind, ...)
  local a = {...}
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
  if kind == display.OBJ_EDIT_NUMBER then OBJ[h].value = a[5] end   -- default value
  if kind == display.OBJ_EDIT_OPTION then OBJ[h].value = 1 end
  if kind == display.OBJ_TEXT then OBJ[h].text = a[3] end
  return h
end
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
function display.setvalue(h, v)  use(h, 'setvalue').value = v end
function display.getvalue(h)     return use(h, 'getvalue').value end
function display.setevent(h, ev, cmd)
  use(h, 'setevent')
  display.events[h] = display.events[h] or {}
  display.events[h][ev] = cmd
end
display.graph = {}
function display.graph.add(g, ...)      use(g, 'graph.add'); OBJ[g].traces = (OBJ[g].traces or 0) + 1 end
function display.graph.removeall(g)     use(g, 'graph.removeall'); OBJ[g].traces = 0 end
function display.graph.drawstyle(g, s)  use(g, 'graph.drawstyle') end
function display.graph.scaley(g, ...)   use(g, 'graph.scaley') end
function display.setcolor(h, ...)       use(h, 'setcolor') end
function display.setfill(h, ...)        use(h, 'setfill'); OBJ[h].fills = (OBJ[h].fills or 0) + 1 end
-- Records the pinned range so tests can assert the axis is not auto-ranging, and
-- returns it when called with the id alone, like the real readback.
function display.graph.scalex(g, ...)
  use(g, 'graph.scalex')
  local a = {...}
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
  b.alive = false
end
function buffer.write.format(b, ...) if not b.alive then error('format on dead buffer', 0) end end
function buffer.write.reading(b, val, extra, secs, frac)
  if not b.alive then error('write to a DELETED buffer', 0) end
  b.n = b.n + 1
  b.readings[b.n] = val
  b.extra[b.n] = extra
  b.seconds[b.n] = secs + frac
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
  if (type(v) == 'function' or k:match('^sg_') or k:match('^fft_') or k:match('^opt'))
     and k:match('^[a-z]') and k ~= 'fftsa' and _G[k] ~= nil then
    -- only count names the modules could plausibly have leaked
    if k:match('^sg_') or k:match('^fft_') or k:match('^opt') or k:match('^app_') then
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
local nb = fftsa.fft_magnitude()
local binhz = 100000 / N
check('magnitude returns N/2 bins', nb == N / 2, 'nb=' .. tostring(nb))
local bestk, bestv = 0, -1
for k = 1, nb do if fftsa.fft_mag[k] > bestv then bestk, bestv = k, fftsa.fft_mag[k] end end
check('peak in the right bin', near((bestk - 1) * binhz, SIG.f, binhz),
      string.format('bin %d = %.0f Hz', bestk, (bestk - 1) * binhz))
check('amplitude within 0.5%', near(bestv, SIG.amp, 0.005),
      string.format('%.6f V (%.3f%% error)', bestv, math.abs(bestv - SIG.amp) * 100))
check('DC pedestal removed', fftsa.fft_mag[1] < bestv * 1e-3,
      string.format('dc bin %.3e with 2.5 V offset', fftsa.fft_mag[1]))

-- ---------- find_peaks ----------
print('\nfind_peaks (real code)')
local bi, bv = fftsa.find_peaks(nb, 6)
check('strongest peak is the tone', bi[1] == bestk)
local sorted = true
for p = 1, 5 do if bv[p] < bv[p + 1] then sorted = false end end
check('sorted strongest first', sorted)
-- Bin 1 is DC, so bin 2 is the first real frequency bin and must be reportable.
fftsa.fft_mag = {}
for k = 1, nb do fftsa.fft_mag[k] = 1e-6 end
fftsa.fft_mag[2] = 0.5
local b2 = fftsa.find_peaks(nb, 6)
check('a tone in bin 2 is reportable', b2[1] == 2, 'bi[1]=' .. tostring(b2[1]))
-- windowing keeps an out-of-window tone out of the table
for k = 1, nb do fftsa.fft_mag[k] = 1e-6 end
fftsa.fft_mag[62] = 0.2      -- ~12 kHz, inside 8-16 kHz
fftsa.fft_mag[205] = 1.0     -- ~40 kHz, outside
local wi = fftsa.find_peaks(nb, 6, 41, 82)
check('windowed search ignores the off-screen tone', wi[1] == 62, 'bi[1]=' .. tostring(wi[1]))
local outside = false
for p = 1, 6 do if wi[p] ~= 0 and (wi[p] < 41 or wi[p] > 82) then outside = true end end
check('no reported peak outside the window', not outside)
check('nil-sparse magnitudes do not raise', (function()
  fftsa.fft_mag = {}
  fftsa.fft_mag[5] = 0.1                    -- everything else nil
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
local nbi = fftsa.fft_magnitude()
local pk, pv = 0, -1
for k = 1, nbi do if fftsa.fft_mag[k] > pv then pk, pv = k, fftsa.fft_mag[k] end end
local dk, iv = fftsa.peak_interp(pk, nbi)
local fi = (pk - 1 + dk) * binhz
check('the raw peak bin really is off (so this test has teeth)',
      math.abs((pk - 1) * binhz - 12000) > 50 and math.abs(pv - 1.0) > 0.05,
      string.format('raw %.1f Hz / %.5f V', (pk - 1) * binhz, pv))
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
  local save = fftsa.fft_mag
  fftsa.fft_mag = {}
  fftsa.fft_mag[5] = 0.1
  local a, b = fftsa.peak_interp(5, nbi)
  fftsa.fft_mag = save
  return a == 0 and b == nil
end)())
-- An on-bin tone must come back unchanged, not nudged by the correction.
SIG.f = 25 * binhz
dmm.digitize.read(cap)
fftsa.fft_load(cap)
fftsa.fft_run()
fftsa.fft_magnitude()
local dk0, iv0 = fftsa.peak_interp(26, nbi)
check('an on-bin tone is left alone', math.abs(dk0) < 0.01 and near(iv0, 1.0, 0.005),
      string.format('d=%.5f v=%.5f', dk0, iv0))
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
check('inverted span cannot index past fft_mag', k0 <= nb and k1 <= nb,
      string.format('kmin=%d kmax=%d nbins=%d', k0, k1, nb))
check('binhz of zero degrades safely', (function()
  local a, b = fftsa.sg_window_bins(nb, 0)
  return a == 1 and b == nb
end)())

-- ---------- axis scale ----------
print('\nseconds-trick axis scale (real code)')
check('50 kHz span labels directly in kHz', fftsa.sg_pick_fscale(50000) == 1000)
local rollover = false
for _, f in ipairs({500, 5000, 50000, 58999, 60000, 100000, 500000, 1000000}) do
  if f / fftsa.sg_pick_fscale(f) >= 59 then rollover = true end
end
check('no span up to 1 MHz hits the MM:SS rollover', not rollover)
fftsa.sg_fscale = fftsa.sg_pick_fscale(50000)
check('legend names both units at the default scale',
      fftsa.sg_xunit_text() == 'X: kHz   Y: dBV', fftsa.sg_xunit_text())
fftsa.sg_fscale = fftsa.sg_pick_fscale(500000)
check('legend still states the graph multiplier when scaled',
      fftsa.sg_xunit_text() == 'X: kHz   Y: dBV   (graph x10)', fftsa.sg_xunit_text())

-- ---------- range mapping / sample rate ----------
print('\nrange + sample rate (real code)')
check('range_to_idx round-trips', fftsa.idx_to_range(fftsa.range_to_idx(0.1)) == 0.1
      and fftsa.idx_to_range(fftsa.range_to_idx(10)) == 10)
check('idx_to_range tolerates 1-based', fftsa.idx_to_range(1) == 0.1)
check('idx_to_range tolerates the label string', fftsa.idx_to_range('10 V') == 10)
check('idx_to_range tolerates 0-based', fftsa.idx_to_range(0) == 0.1)
check('idx_to_range clamps out-of-range', fftsa.idx_to_range(99) == 10)
local nyq = true
for _, f in ipairs({500, 5000, 25000, 50000, 250000, 500000}) do
  if fftsa.pick_fs(f) / 2 < f then nyq = false end
end
check('picked fs always covers Nyquist', nyq)

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
check('exactly one timer is live', live('timer') == 1)
check('exactly one screen pair is live', live('screen') == 2,
      'screens=' .. live('screen') .. ' (spectrum + options)')
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
check('still exactly one timer after rebuild', live('timer') == 1,
      'timers=' .. live('timer'))
check('still exactly two screens after rebuild', live('screen') == 2,
      'screens=' .. live('screen'))

-- arm() must never stack timers (two would double the frame rate and flood)
fftsa.arm(0.3); fftsa.arm(0.3); fftsa.arm(0.3)
check('arm() three more times still leaves one timer', live('timer') == 1,
      'timers=' .. live('timer'))

-- frames run clean
fftsa.errcount, fftsa.shortreads = 0, 0
for _ = 1, 5 do fftsa.frame() end
check('5 frames run without a dropped frame', fftsa.errcount == 0,
      'errcount=' .. fftsa.errcount .. ' lasterr=' .. tostring(fftsa.lasterr))
check('peak fields were populated', OBJ[fftsa.sg_pk_f[1]].text ~= nil
      and OBJ[fftsa.sg_pk_f[1]].text:match('kHz') ~= nil,
      tostring(OBJ[fftsa.sg_pk_f[1]].text))
check('the x-axis legend is on screen', OBJ[fftsa.sg_xunit].text ~= nil,
      tostring(OBJ[fftsa.sg_xunit].text))

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

-- the options round trip, including an inverted span
print('\noptions form (real code)')
fftsa.options()
check('options() switches to the form', display.active == fftsa.optscr)
display.setvalue(fftsa.opt_flo, 8000)
display.setvalue(fftsa.opt_fhi, 16000)
fftsa.options_apply()
check('a zoom applies', fftsa.flo == 8000 and fftsa.fhi == 16000,
      string.format('%g..%g', fftsa.flo, fftsa.fhi))
check('apply returns to the spectrum', display.active == fftsa.sg_scr)
-- An inverted span must be repaired: a stop below the start describes no bins,
-- and every frame then indexes past fft_mag and dies on a nil comparison.
display.setvalue(fftsa.opt_flo, 8000)
display.setvalue(fftsa.opt_fhi, 5000)
fftsa.options_apply()
check('stop below start is repaired, not left inverted', fftsa.flo < fftsa.fhi,
      string.format('flo=%g fhi=%g', fftsa.flo, fftsa.fhi))
fftsa.errcount = 0
for _ = 1, 5 do fftsa.frame() end
check('frames still run after an inverted span', fftsa.errcount == 0,
      'errcount=' .. fftsa.errcount .. ' lasterr=' .. tostring(fftsa.lasterr))

-- teardown must leave nothing behind
print('\nteardown (real code)')
fftsa.stop()
check('stop() deletes every display object', live() == 0, 'live=' .. live())
check('stop() frees every buffer it made', livebufs() == base_bufs,
      'buffers=' .. livebufs() .. ' vs baseline ' .. base_bufs)
check('stop() nils every handle', fftsa.sg_scr == nil and fftsa.sg_graph == nil
      and fftsa.optscr == nil and fftsa.opt_flo == nil and fftsa.opt_fhi == nil
      and fftsa.opt_rng == nil and fftsa.opt_info == nil and fftsa.optbtn == nil
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
check('first launch is live', live_one > 0 and live('timer') == 1)
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
check('exactly one timer after a relaunch', live('timer') == 1, 'timers=' .. live('timer'))

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
check('End App is hooked on the options screen too',
      ev ~= nil and ev['endapp'] == 'fftsa.cleanup()')
if ev ~= nil and ev['endapp'] ~= nil then
  (load or loadstring)(ev['endapp'])()
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

print()
print(string.format('%d passed, %d failed', pass, fail))
os.exit(fail == 0 and 0 or 1)
