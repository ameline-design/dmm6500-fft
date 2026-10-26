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
-- `capacity` is the firmware's name for it; `cap` was the mock's own and is kept so the
-- existing checks still read. A mock that lacks a field the firmware has hides nothing
-- on the instrument and breaks only here, which is the wrong way round.
local function newbuf(cap)
  local b = {alive = true, cap = cap, capacity = cap, n = 0, readings = {},
             relativetimestamps = {}, extra = {}, seconds = {},
             fillmode = buffer.FILL_ONCE, startindex = 1, endindex = 0, wpos = 1}
  -- The firmware calls this column extravalues. The mock stored it as `extra` alone,
  -- which is a name the instrument does not have: reading b.extra over the socket is
  -- error -286. Both names are the SAME TABLE here, so a test or a probe written in the
  -- firmware's vocabulary works and neither name can drift from the other.
  b.extravalues = b.extra
  function b.clear()
    CLEAR_AT_WRITES, LOG10_AT_CLEAR = WRITES, LOG10S
    b.n = 0
    b.wpos, b.startindex, b.endindex = 1, 1, 0
    b.readings, b.relativetimestamps, b.extra, b.seconds = {}, {}, {}, {}
    b.extravalues = b.extra
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
  OBJ_IMAGE = 'image',
  EVENT_PRESS = 'press', EVENT_ENDAPP = 'endapp',
  EVENT_DRAG = 'drag', EVENT_CURSOR = 'cursor',
  -- A graph reports its own pan and zoom with this, confirmed on the instrument: about
  -- ten fires a drag, and our own pin fires it too, asynchronously.
  EVENT_SCALE = 'scale',
  -- Fonts, at the firmware's own values from its registration table. SMALL through HUGE
  -- are the documented four; FONT_1..FONT_10 continue the same enum and are in the table
  -- but not in the display API reference, so their sizes are a panel measurement.
  FONT_SMALL = 0, FONT_MEDIUM = 1, FONT_LARGE = 2, FONT_HUGE = 3,
  FONT_1 = 4, FONT_2 = 5, FONT_3 = 6, FONT_4 = 7, FONT_5 = 8,
  FONT_6 = 9, FONT_7 = 10, FONT_8 = 11, FONT_9 = 12, FONT_10 = 13,
  JUST_LEFT = 0, JUST_CENTER = 1, JUST_RIGHT = 2,
  NFORMAT_PREFIX = 1, TIMER_FOREVER = -1,
  -- The firmware's own values, read out of its registration table, because the app
  -- now chooses between them: a mock that called them all 0 could not tell an auto
  -- method from a fixed one.
  XSCALE_SMART = 0, XSCALE_LATEST = 1, XSCALE_GROUP = 2, XSCALE_ALL = 3,
  XSCALE_AUTOBIN = 4, XSCALE_SWIM = 5, XSCALE_SHARED = 6, XSCALE_OFF = 7,
  YSCALE_SMART = 0, YSCALE_PER_TRACE = 1, YSCALE_PER_TRACE_ONCE = 2,
  YSCALE_SWIM = 3, YSCALE_SHARED = 4, YSCALE_OFF = 5,
  AXIS_NORMAL = 0, AXIS_LOG = 1, STYLE_LINE = 0, STYLE_MARKER = 1, STYLE_BOTH = 2,
  TRACE_ACTIVE = 0, TRACE_ALL = 1, MARKER_LAST_TRACE = 0, MARKER_LAST_CUSTOM = 1,
  -- The firmware's own values, from its registration table. They used to be strings
  -- here, which cannot be compared with ELEMENT_EXTRA and made a mixed-type mock.
  ELEMENT_DATA = 0, ELEMENT_TIME = 1, ELEMENT_EXTRA = 2, ELEMENT_SOURCE = 2,
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
  -- OBJ_TEXT is (x, y, text, colour, font, justify), so the font is a[5].
  if kind == display.OBJ_TEXT then OBJ[h].text = a[3] end
  if kind == display.OBJ_TEXT then OBJ[h].colour, OBJ[h].font = a[4], a[5] end
  if kind == display.OBJ_TEXT then OBJ[h].justify = a[6] end
  if kind == display.OBJ_EDIT_OPTION then OBJ[h].help = a[4] end
  -- OBJ_IMAGE is (x, y, image name), so a[3] is the loadimage name. Kept because a name
  -- the archive does not carry draws nothing and reports nothing: a blank button.
  if kind == display.OBJ_IMAGE then OBJ[h].image = a[3] end
  -- A button's label, which the firmware offers no way to read back -- so this field
  -- exists for this suite, to hold the icon buttons to a blank face.
  if kind == display.OBJ_BUTTON then OBJ[h].label = a[3] end
  -- Creating a screen makes it the active one. Modelled because it is the whole
  -- reason the cover has to be raised again after every screen create. The title is
  -- kept because the firmware truncates one over 31 characters with event 1707.
  if kind == display.OBJ_SCREEN then
    display.active = h
    OBJ[h].title = a[1]
  end
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
  -- A command string registers a handler; the boolean form turns the event on or off for
  -- display.waitevent(). Either way 0 means off, and off is what takes the object's event
  -- generation back down -- which is what the scale read-back's validity depends on.
  if cmd == 0 or cmd == '' then
    display.events[h][ev] = nil
  else
    display.events[h][ev] = cmd
  end
end
display.graph = {}
-- `traces` is the live trace count; `adds` and `removes` count the CALLS. The
-- distinction matters: a removeall+add pair leaves the count at 1, exactly as
-- never touching it does, so only the call counters can see a per-frame
-- detach and re-attach.
function display.graph.add(g, ...)
  use(g, 'graph.add')
  OBJ[g].adds = (OBJ[g].adds or 0) + 1
  -- Firmware binds nothing for an empty buffer, even if later frames fill it.
  if arg[1].n == 0 then return end
  -- buffer is the FIRST trace bound, which is the spectrum; buffers is every trace in
  -- the order they were added, so a second one can be asserted without changing what
  -- OBJ[g].buffer means to the checks that came before markers existed.
  if OBJ[g].buffer == nil then OBJ[g].buffer = arg[1] end
  if OBJ[g].buffers == nil then OBJ[g].buffers = {} end
  OBJ[g].buffers[table.getn(OBJ[g].buffers) + 1] = arg[1]
  -- Which element each axis is bound to. ELEMENT_TIME makes it the firmware's time plot,
  -- labelled in seconds with a suffix that cannot be switched off; ELEMENT_EXTRA makes it
  -- the numeric x-y plot, which the firmware labels in the data's own units.
  OBJ[g].yelem, OBJ[g].xelem = arg[2], arg[4]
  OBJ[g].traces = (OBJ[g].traces or 0) + 1
end
-- select() names a BUFFER, not a trace index, and the marker calls apply to whichever
-- trace is selected -- so the mock records the selection and attributes each marker size
-- to the buffer that was active when it was set.
function display.graph.select(g, b, ...)
  use(g, 'graph.select')
  OBJ[g].selected = b
  OBJ[g].selects = (OBJ[g].selects or 0) + 1
end
function display.graph.markersize(g, size, ...)
  use(g, 'graph.markersize')
  if OBJ[g].marksize == nil then OBJ[g].marksize = {} end
  OBJ[g].marksize[OBJ[g].selected] = size
  OBJ[g].marksizelast = size
end
function display.graph.markerlastcolor(g, kind, ...)
  use(g, 'graph.markerlastcolor')
  OBJ[g].marklastcolor = kind
end
function display.graph.removeall(g)
  use(g, 'graph.removeall')
  OBJ[g].buffer, OBJ[g].buffers = nil, nil
  OBJ[g].selected, OBJ[g].xpin, OBJ[g].ypin = nil, nil, nil
  OBJ[g].scaletrace_mode = nil          -- a fresh graph is back to TRACE_ACTIVE
  OBJ[g].traces = 0
  OBJ[g].removes = (OBJ[g].removes or 0) + 1
end
function display.graph.drawstyle(g, s)
  use(g, 'graph.drawstyle')
  OBJ[g].drawstyle = s
  OBJ[g].drawstyles = (OBJ[g].drawstyles or 0) + 1
end
-- PER SELECTED TRACE, which is what the API reference says of both axes: "positions
-- apply to selected trace only for multitrace". Modelled, because a graph-wide model is
-- kinder than the firmware and let a second trace go unpinned and invisible.
-- WHICH TRACES A SCALE CALL REACHES. A custom graph starts at TRACE_ACTIVE, where the
-- positions "apply to selected trace only for multitrace"; scaletrace(TRACE_ALL) syncs
-- them, and from then on a scale call lands on every bound trace. Modelled because a
-- graph-wide model is kinder than the firmware and let a second trace go unpinned.
local function pin_targets(g)
  if OBJ[g].scaletrace_mode == display.TRACE_ALL and OBJ[g].buffers ~= nil then
    return OBJ[g].buffers
  end
  return {OBJ[g].selected or OBJ[g].buffer}
end
-- A scale read-back answers only on an object with event generation enabled, so the
-- mock hands back nil until something has called display.setevent on the graph.
local function readback(g, lo, hi)
  local ev = display.events[g]
  if ev == nil then return nil, nil end
  local k
  for k in pairs(ev) do return lo, hi end        -- any live registration will do
  return nil, nil
end
function display.graph.scaley(g, ...)
  use(g, 'graph.scaley')
  local a = arg
  if OBJ[g].ypin == nil then OBJ[g].ypin = {} end
  if a[3] ~= nil then
    local t = pin_targets(g)
    local i
    for i = 1, table.getn(t) do OBJ[g].ypin[t[i]] = {a[3], a[4]} end
    OBJ[g].ymin, OBJ[g].ymax = a[3], a[4]
    OBJ[g].ypins = (OBJ[g].ypins or 0) + 1  -- counted, like the x pin
  end
  -- With no limits this is a read, and it answers ONLY when the object has event
  -- generation enabled: "return values are only valid when the objects event generation
  -- is set to ALL and the only argument passed in is the id", and non-button objects
  -- have none by default. Modelled, because an unconditional read-back here let a view
  -- lock that never pinned anything pass the whole suite and then do nothing on the
  -- glass. On the instrument it answered nil with no event posted.
  return readback(g, OBJ[g].ymin, OBJ[g].ymax)
end
function display.setcolor(h, ...)       use(h, 'setcolor') end
function display.setfill(h, ...)        use(h, 'setfill'); OBJ[h].fills = (OBJ[h].fills or 0) + 1 end
-- Records the pinned range so tests can assert the axis is not auto-ranging, and
-- returns it when called with the id alone, like the real readback.
function display.graph.scalex(g, ...)
  use(g, 'graph.scalex')
  local a = arg
  OBJ[g].xmethod = a[1]                    -- which scale method was asked for
  if OBJ[g].xpin == nil then OBJ[g].xpin = {} end
  if a[3] ~= nil then
    OBJ[g].xmin, OBJ[g].xmax = a[3], a[4]
    -- Per selected trace, like scaley, and per ALL of them after scaletrace(TRACE_ALL).
    local t = pin_targets(g)
    local i
    for i = 1, table.getn(t) do OBJ[g].xpin[t[i]] = {a[3], a[4]} end
    OBJ[g].pins = (OBJ[g].pins or 0) + 1   -- counted: re-pinning flickers the axis
    -- Where in the frame the pin landed, as the buffer-write count at that moment: a pin
    -- between the clear and the last write repaints a half-filled trace.
    OBJ[g].pin_at_writes = WRITES
  end
  return readback(g, OBJ[g].xmin, OBJ[g].xmax)
end
-- scaletrace is counted, not acted on: what the firmware does with it is the open
-- question the instrument has to answer. select() is modelled above, where the marker
-- calls that depend on it are -- defined once, because a second definition of a mock
-- function silently wins and takes its witnesses with it.
function display.graph.scaletrace(g, mode)
  use(g, 'graph.scaletrace')
  OBJ[g].scaletraces = (OBJ[g].scaletraces or 0) + 1
  OBJ[g].scaletrace_mode = mode
end

buffer = {
  STYLE_WRITABLE_FULL = 'wf', STYLE_STANDARD = 'std',
  UNIT_VOLT = 'V', UNIT_HERTZ = 'Hz', DIGITS_4_5 = 45, DIGITS_6_5 = 65,
  -- The firmware's values, read off its registration table. UNIT_DECIBEL is 4 and is
  -- NOT used: it panics the instrument during build. A custom unit is the safe route to
  -- a dB suffix.
  UNIT_DECIBEL = 4, UNIT_CUSTOM1 = 14, UNIT_DBM = 20, UNIT_NONE = 23,
  FILL_ONCE = 0, FILL_CONTINUOUS = 1,
  write = {},
}
-- buffer.unit(unit, label) names a custom unit. The firmware uses only the first TWO
-- characters and posts 4933, "Reading buffer custom unit truncated to two characters",
-- when handed more -- so the mock stores what the instrument would keep, not what it was
-- given. A harness that stored the whole string would let a three-character label look
-- fine here and arrive truncated on the glass.
CUSTOM_UNITS, CUSTOM_TRUNCATED = {}, 0
function buffer.unit(u, label)
  local t = tostring(label)
  if string.len(t) > 2 then
    t = string.sub(t, 1, 2)
    CUSTOM_TRUNCATED = CUSTOM_TRUNCATED + 1
  end
  CUSTOM_UNITS[u] = t
end
-- REFUSES AN UNDERSIZED BUFFER, like the firmware: "capacity must be between 10 and
-- 5311488 readings", event 4920, and make() then RETURNS NIL rather than raising. A mock
-- that accepted any capacity is how a 6-reading marker buffer reached the instrument,
-- where it was refused and every call on the nil handle took a 1138.
BUF_MIN, BUF_MAX = 10, 5311488
REFUSED_BUF_MAKES = 0
function buffer.make(cap, style)
  if cap == nil or cap < BUF_MIN or cap > BUF_MAX then
    REFUSED_BUF_MAKES = REFUSED_BUF_MAKES + 1
    return nil
  end
  return newbuf(cap)
end
-- REFUSES BY POSTING, like the firmware, rather than raising: a raising mock would have
-- the suite testing a failure mode the instrument does not have. The refusals are counted
-- instead, and a refused delete leaves the buffer ALIVE -- which is what made 61 live
-- buffers on the instrument when a bound one was remade without detaching first.
REFUSED_BUF_DELETES, REFUSED_OBJ_DELETES = 0, 0
function buffer.delete(b)
  if type(b) ~= 'table' or not b.alive then
    REFUSED_BUF_DELETES = REFUSED_BUF_DELETES + 1
    return
  end
  for _, o in pairs(OBJ) do
    if o.alive and o.buffer == b then
      REFUSED_BUF_DELETES = REFUSED_BUF_DELETES + 1
      return
    end
  end
  b.alive = false
end
function buffer.write.format(b, ...)
  if not b.alive then error('format on dead buffer', 0) end
  b.yunit, b.xunit = arg[1], arg[3]
end
-- Fractional times the firmware would refuse. It posts event 1131 -- a MODAL
-- DIALOG, once per call -- and RETURNS, so this counts rather than raises, which is
-- what the real call does. A frame writes 255 points, so a dialog per point makes
-- the app impossible to exit; that is why this is counted and asserted.
BADFRAC = 0
-- The firmware's stated limit, and the mock refuses above it.
FRAC_MAX = 0.9999999
-- "Data must be added in chronological order" -- buffer.write.reading, Details.
-- Counted rather than raised, since what the real call does with an out-of-order
-- timestamp is not known. Comparing each write against the one before it is the only way
-- a non-monotonic sequence shows up at all.
NONMONO = 0
NONMONODUMP = true
-- WRITES counts every point written anywhere; CLEAR_AT_WRITES is the value it had when
-- a buffer was last cleared. Together they say what happened INSIDE the window where the
-- trace buffer is empty: the refill stages every value into preallocated arrays first,
-- so the only thing between the clear and a full buffer should be writes.
WRITES, CLEAR_AT_WRITES = 0, 0
-- LOG10S counts the per-point dB conversions, LOG10_AT_CLEAR its value at the last
-- clear. These are what tell a STAGED refill from an interleaved one: counting writes
-- cannot, because an interleaved refill also writes only after the clear -- it just does
-- the arithmetic for each point in between.
LOG10S, LOG10_AT_CLEAR = 0, 0
local REAL_LOG10 = math.log10
function math.log10(x)
  LOG10S = LOG10S + 1
  return REAL_LOG10(x)
end
function buffer.write.reading(b, val, extra, secs, frac)
  if not b.alive then error('write to a DELETED buffer', 0) end
  WRITES = WRITES + 1
  if frac == nil or frac < 0 or frac > FRAC_MAX then BADFRAC = BADFRAC + 1 end
  local i = b.wpos or (b.n + 1)
  if b.fillmode == buffer.FILL_CONTINUOUS then
    -- Wraps with no event posted; n pins at capacity. Measured 2026-10-24.
    -- Only within a logical run. Slot 1 against slot capacity is the ring's wrap seam,
    -- and after exactly capacity writes startindex is back at 1, so the firmware reads
    -- 1..capacity in order and that seam is not a discontinuity it ever sees.
    local t = secs + frac
    if i > 1 and b.seconds[i - 1] ~= nil and t <= b.seconds[i - 1] then
      NONMONO = NONMONO + 1
      if NONMONODUMP then
        print(string.format('   NONMONO at slot %d: prev %.9f this %.9f (secs %.9f'
                            .. ' frac %.9f) extra %.4f', i, b.seconds[i - 1], t,
                            secs, frac, extra))
      end
    end
    b.readings[i], b.extra[i], b.seconds[i] = val, extra, t
    b.wpos = i + 1
    if b.wpos > b.capacity then b.wpos = 1 end
    if b.n < b.capacity then b.n = b.n + 1 end
    b.startindex = b.wpos
    if b.n < b.capacity then b.startindex = 1 end
    b.endindex = b.n
    return
  end
  if b.n >= b.capacity then
    -- FILL_ONCE past the end is event 4915, not a wrap.
    error('buffer full: 4915', 0)
  end
  b.n = b.n + 1
  b.readings[b.n] = val
  b.extra[b.n] = extra
  local t = secs + frac
  if b.n > 1 and t <= b.seconds[b.n - 1] then NONMONO = NONMONO + 1 end
  b.seconds[b.n] = t
  b.wpos = b.n + 1
  b.endindex = b.n
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
-- The coherent gain is a window identity, so it must change with the window: a window
-- selection that did not reach win_build() would leave it alone.
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
check('exactly four screens are live', live('screen') == 4,
      'screens=' .. live('screen') .. ' (cover + spectrum + options + about)')
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
check('still exactly four screens after rebuild', live('screen') == 4,
      'screens=' .. live('screen'))

print('\nband-pass: filter and decimate to the span (real code)')
-- Unit DC gain, odd length, symmetric. The gain matters most: a filter that did not sum
-- to 1 would scale every reading, and the amplitude would be wrong by a constant nobody
-- would attribute to the filter.
-- The band-pass is given one rate up, so the filter can remove a band that would
-- otherwise have folded at the ADC. The hardware has four exact rates and nothing
-- between, so "double" means the next one, and 1 MS/s is the ceiling.
check('the band-pass steps the acquisition rate up one, and stops at 1 MS/s', (function()
  local got = {}
  local i
  for i = 1, table.getn(fftsa.rates) do got[i] = fftsa.bp_rate(fftsa.rates[i]) end
  return got[1] == 200000 and got[2] == 500000 and got[3] == 1000000
         and got[4] == 1000000,
         string.format('100k->%g 200k->%g 500k->%g 1M->%g', got[1], got[2], got[3],
                       got[4])
end)())
-- The digitizer runs at the rate the plan chose -- not necessarily the stepped one, since
-- the filter length limits the decimation and the base rate can give the finer bin. What
-- has to hold is that the rate is one the hardware has, is never under the floor, and is
-- what was actually programmed.
check('a band-pass Apply runs the digitizer at the rate it planned', (function()
  display.setvalue(fftsa.opt_flo, 10)
  display.setvalue(fftsa.opt_fhi, 10000)
  display.setvalue(fftsa.opt_n, 1)
  fftsa.bp_on = true
  if not fftsa.options_apply() then return false, fftsa.lasterr end
  local rate, acq, d = dmm.digitize.samplerate, fftsa.fs_acq, fftsa.bp_d
  fftsa.bp_on = false
  if not fftsa.options_apply() then return false, fftsa.lasterr end
  local plain = dmm.digitize.samplerate
  display.setvalue(fftsa.opt_fhi, 50000)
  fftsa.options_apply()
  local exact = false
  local i
  for i = 1, table.getn(fftsa.rates) do
    if fftsa.rates[i] == acq then exact = true end
  end
  return rate == acq and exact and acq >= fftsa.fs_min and plain == 100000 and d > 1,
         string.format('band-pass at %g /%d, plain at %g', rate, d, plain)
end)())
-- The rate on the readback line is the DIGITIZER's. With the band-pass decimating, the
-- rate the transform sees is lower -- 200 kS/s over /3 is 66.667 -- and printing that as
-- "fs" reads as the hardware running under its own 100 kS/s floor. A 20 kHz span is the
-- case that produced it.
check('the readback line reports the digitizer rate, not the decimated one', (function()
  display.setvalue(fftsa.opt_flo, 10)
  display.setvalue(fftsa.opt_fhi, 20000)
  display.setvalue(fftsa.opt_n, 1)
  fftsa.bp_on = true
  if not fftsa.options_apply() then return false, fftsa.lasterr end
  local line = fftsa.sg_xunit_text()
  local acq, eff, d = fftsa.fs_acq, fftsa.fs, fftsa.bp_d
  fftsa.bp_on = false
  display.setvalue(fftsa.opt_fhi, 50000)
  fftsa.options_apply()
  if d < 2 then return false, 'no decimation at a 20 kHz span, nothing to tell apart' end
  -- The acquisition rate is in the line and the decimated one is NOT, while the bin
  -- width is computed from the decimated rate.
  local named = string.find(line, string.format('BP:On /%d', d), 1, true) ~= nil
  if not named then return false, 'the line does not name the decimation: ' .. line end
  local shown = string.find(line, fftsa.sample_rate_text(acq), 1, true) ~= nil
  local hidden = string.find(line, fftsa.sample_rate_text(eff), 1, true) == nil
  local bin = string.find(line, string.format('bin %.2f Hz', eff / 512), 1, true) ~= nil
  return shown and hidden and bin and acq >= fftsa.fs_min,
         string.format('%s | acq %s eff %s /%d', line, fftsa.sample_rate_text(acq),
                       fftsa.sample_rate_text(eff), d)
end)())
check('the taps sum to one, are odd in number and symmetric', (function()
  fftsa.bp_build(100000, 10000, 512, 4)
  local h, l = fftsa.bp_h, fftsa.bp_l
  if h == nil then return false, 'no taps built' end
  local sum, worst = 0, 0
  local i
  for i = 1, l do sum = sum + h[i] end
  for i = 1, l do
    local d = math.abs(h[i] - h[l + 1 - i])
    if d > worst then worst = d end
  end
  return math.mod(l, 2) == 1 and math.abs(sum - 1) < 1e-12 and worst < 1e-15,
         string.format('%d taps, sum %.15f, worst asymmetry %g', l, sum, worst)
end)())
-- THE POINT OF THE FILTER. Decimating by 4 at 100 kS/s leaves a 12.5 kHz Nyquist, so a
-- 20 kHz tone -- which the hardware samples perfectly well -- folds to 5 kHz if the
-- record is simply thinned. Driven through the real filter it must not survive to be
-- folded. Both tones measured through the same path, so the in-band one is the control:
-- a filter that killed everything would pass the alias test and fail this.
check('an out-of-band tone is stopped before it can fold in', (function()
  local fs, fhi, n, d = 100000, 10000, 512, 4
  fftsa.bp_build(fs, fhi, n, d)
  local function peak_of(hz)
    local rd = {}
    local i
    for i = 1, fftsa.bp_m do
      rd[i] = math.sin(2 * math.pi * hz * (i - 1) / fs)
    end
    local out = fftsa.bp_filter(rd)
    local mx = 0
    -- The first taps are still filling, so the steady state starts after the group delay.
    for i = math.ceil(fftsa.bp_l / d) + 1, n do
      local v = math.abs(out[i])
      if v > mx then mx = v end
    end
    return mx
  end
  local inband = peak_of(2000)
  local alias  = peak_of(20000)
  return inband > 0.9 and alias < 0.05,
         string.format('2 kHz through at %.3f, 20 kHz down to %.4f (%.1f dB)',
                       inband, alias, 20 * math.log10(alias / inband))
end)())
-- THE TWO NUMBERS THAT WERE WRONG. The filter has to be flat across the displayed span
-- and down by the time the decimated Nyquist arrives. The old design was neither: its
-- cutoff sat on the span top so the band was inside the roll-off, and 13 taps where 51
-- were needed left the near stopband barely attenuated. Measured on the glass against the
-- same stimulus, that read 3.5 dB low at 16.6 kHz of a 20 kHz span.
--
-- Driven through the real taps at the real plan for a 20 kHz span, which is the case that
-- showed it.
check('the filter is flat across the span and down past the Nyquist', (function()
  local fs, fhi, n = 200000, 20000, 512
  local d = fftsa.bp_pick_d(fs, fhi, n)
  if d < 2 then return false, 'no decimation to test at /1' end
  fftsa.bp_build(fs, fhi, n, d)
  local nyq = fs / (2 * d)
  local function gain(hz)
    local rd, i = {}, nil
    for i = 1, fftsa.bp_m do rd[i] = math.sin(2 * math.pi * hz * (i - 1) / fs) end
    local out = fftsa.bp_filter(rd)
    local mx = 0
    for i = math.ceil(fftsa.bp_l / d) + 1, n do
      local v = math.abs(out[i])
      if v > mx then mx = v end
    end
    return mx
  end
  local dc    = gain(100)
  local mid   = gain(fhi / 2)
  local edge  = gain(fhi * 0.98)
  local above = gain(nyq * 1.15)
  local function db(x) return 20 * math.log10(x / dc) end
  -- Flat to half a dB across the span, and 30 dB down above the Nyquist.
  return math.abs(db(mid)) < 0.5 and math.abs(db(edge)) < 0.5 and db(above) < -30,
         string.format('%d taps at /%d: mid %.2f dB, span edge %.2f dB, %.0f Hz %.1f dB',
                       fftsa.bp_l, d, db(mid), db(edge), nyq * 1.15, db(above))
end)())
-- The decimation is chosen, not fixed: a narrow span can afford more of it, and a large
-- sample count cannot afford any because the read is what it costs.
-- TWO CAPS, and the filter is usually the tighter: a decimation leaves a transition from
-- the span top to the decimated Nyquist, and the taps that transition needs grow fast as
-- it narrows. Every chosen decimation must have a filter that fits the ceiling.
check('the decimation is capped by the filter length as well as the read cost', (function()
  local wide   = fftsa.bp_pick_d(100000, 50000, 512)
  local mid    = fftsa.bp_pick_d(100000, 10000, 512)
  local narrow = fftsa.bp_pick_d(100000, 2000, 512)
  local big    = fftsa.bp_pick_d(100000, 2000, 16384)
  local read   = math.floor((fftsa.bp_maxm - fftsa.bp_lmax) / (512 - 1))
  -- every one of them has a filter that fits
  local hi
  for hi = 2000, 50000, 500 do
    local d = fftsa.bp_pick_d(100000, hi, 512)
    if d > 1 and fftsa.bp_taps_for(100000, hi, d) == nil then
      return false, string.format('stop %d Hz chose /%d, which needs more than %d taps',
                                  hi, d, fftsa.bp_lmax)
    end
  end
  return wide == 1 and mid == 3 and narrow > 1 and narrow < read and big == 1,
         string.format('50k->%d 10k->%d 2k->%d (read cap %d), 2k at 16384->%d',
                       wide, mid, narrow, read, big)
end)())
-- Every decimation has to keep the stop frequency inside the decimated Nyquist, or the
-- span the operator asked for would be partly folded -- which is the failure this whole
-- feature exists to avoid.
check('no chosen decimation puts the stop frequency past its own Nyquist', (function()
  local fs = 100000
  local hi
  for hi = 2000, 50000, 500 do
    local d = fftsa.bp_pick_d(fs, hi, 512)
    if (fs / d) / 2 < hi then
      return false, string.format('stop %d Hz at /%d leaves Nyquist %.0f', hi, d,
                                  (fs / d) / 2)
    end
  end
  return true, 'every stop from 2 kHz to 50 kHz stays inside its Nyquist'
end)())
-- Off is off: no decimation, the capture is the sample count, and the loader is the
-- buffer one.
check('band-pass off leaves the record and the rate alone', (function()
  fftsa.bp_on = false
  display.setvalue(fftsa.opt_n, 1)
  if not fftsa.options_apply() then return false, fftsa.lasterr end
  return fftsa.bp_on == false and fftsa.bp_d == 1 and fftsa.bp_m == fftsa.n
         and dmm.digitize.count == fftsa.n
         and math.abs(fftsa.binhz - fftsa.fs_acq / fftsa.n) < 1e-9,
         string.format('d=%d m=%d count=%d binhz=%.4f',
                       fftsa.bp_d, fftsa.bp_m, dmm.digitize.count, fftsa.binhz)
end)())
-- On: the bin is finer by exactly the decimation, the capture grows to match, and the
-- rate the transform sees is the digitizer's divided by it.
check('band-pass on narrows the bin by the decimation', (function()
  display.setvalue(fftsa.opt_flo, 10)
  display.setvalue(fftsa.opt_fhi, 10000)
  display.setvalue(fftsa.opt_n, 1)
  fftsa.bp_on = false
  if not fftsa.options_apply() then return false, fftsa.lasterr end
  local plain = fftsa.binhz
  fftsa.bp_on = true
  if not fftsa.options_apply() then return false, fftsa.lasterr end
  -- Everything read at the SAME moment: the rate the transform sees is the digitizer's
  -- divided by the decimation, which is the relationship the whole feature rests on.
  local d = fftsa.bp_d
  local fine, eff, acq = fftsa.binhz, fftsa.fs, fftsa.fs_acq
  local m, count, taps = fftsa.bp_m, dmm.digitize.count, fftsa.bp_l
  fftsa.bp_on = false
  display.setvalue(fftsa.opt_fhi, 50000)
  fftsa.options_apply()
  -- The bin is fs_acq/(d*n), and fs_acq is the STEPPED-UP rate, so the improvement over
  -- the plain path is d divided by the rate step rather than d itself. Both relationships
  -- asserted: the bin against the rate actually used, and that it is still an improvement.
  return d > 1 and math.abs(fine - acq / (d * 512)) < 1e-6 and fine < plain
         and m == (512 - 1) * d + taps and count == m
         and math.abs(eff * d - acq) < 1e-6,
         string.format('/%d: %.2f Hz against %.2f, fs %.1f of %.1f, capture %d of %d',
                       d, fine, plain, eff, acq, count, m)
end)())

print('\npeak markers (real code)')
-- NOT OFFERED IN THE FORM YET, so these drive fftsa.sg_markers directly: the field is
-- withheld until the second trace can be pinned, and setvalue on its nil handle raises.
-- The machinery stays tested so it does not rot while it waits.
check('the form offers neither peak markers nor band-pass', fftsa.opt_mk == nil
      and fftsa.opt_bp == nil and fftsa.sg_markers == false,
      'opt_mk=' .. tostring(fftsa.opt_mk) .. ' opt_bp=' .. tostring(fftsa.opt_bp)
      .. ' markers=' .. tostring(fftsa.sg_markers))
-- Off means ONE trace drawn as a line: the marker buffer exists but is not bound, so
-- drawstyle must not be STYLE_BOTH or the spectrum gets a dot per point.
check('markers off binds one trace and draws a line', (function()
  fftsa.sg_markers = false
  fftsa.sg_bind()
  local o = OBJ[fftsa.sg_graph]
  return fftsa.sg_markers == false and o.traces == 1
         and o.drawstyle == display.STYLE_LINE and o.buffer == fftsa.sg_buf,
         string.format('markers=%s traces=%s style=%s',
                       tostring(fftsa.sg_markers), tostring(o.traces),
                       tostring(o.drawstyle))
end)())
-- The marker buffer is made with the trace buffer whether or not markers are on, because
-- making it when the option is set would be an allocation while frames are running. Its
-- capacity is the peak count RAISED TO THE FIRMWARE'S FLOOR of 10 readings: at six the
-- make is refused with event 4920 and answers nil, which is a marker trace that cannot
-- exist and five 1138s from the calls that follow.
check('the marker buffer exists and clears the firmware capacity floor', (function()
  local want = fftsa.sg_npeak * fftsa.sg_mk_per
  if want < fftsa.sg_bufmin then want = fftsa.sg_bufmin end
  return fftsa.sg_mk ~= nil and fftsa.sg_mk.alive
         and fftsa.sg_mk.capacity == want and want >= BUF_MIN
         and fftsa.sg_mk ~= fftsa.sg_buf,
         string.format('capacity %s, wanted %d, floor %d, alive %s',
                       tostring(fftsa.sg_mk ~= nil and fftsa.sg_mk.capacity),
                       want, BUF_MIN,
                       tostring(fftsa.sg_mk ~= nil and fftsa.sg_mk.alive))
end)())
-- And nothing anywhere in a build is refused for size: a refused make answers nil, and
-- every call on that nil is a dialog the operator has to dismiss.
check('no buffer the app asks for is refused for its size', REFUSED_BUF_MAKES == 0,
      'refused makes: ' .. REFUSED_BUF_MAKES)
check('a frame writes nothing to the marker buffer while markers are off', (function()
  local before = WRITES
  local n = fftsa.sg_update_markers(fftsa.pk_bi, fftsa.pk_bv, fftsa.sg_npeak, fftsa.binhz)
  return n == 0 and WRITES == before, string.format('wrote %d points, %d writes',
                                                    n, WRITES - before)
end)())
-- On: two traces, STYLE_BOTH because drawstyle is per graph, and the sizes attributed to
-- the right buffer -- the spectrum at 1, where the glyph is lost under its own line, and
-- the markers at sg_mk_size.
-- On: two traces, both drawn as LINES -- no markers anywhere, because drawstyle is per
-- graph and a marker for the peak trace is a marker on all 255 spectrum points too -- and
-- the scales synced with TRACE_ALL, which is what reaches the second trace at all.
check('markers on bind a second line trace with the scales synced', (function()
  fftsa.sg_markers = true
  fftsa.sg_bind()
  local o = OBJ[fftsa.sg_graph]
  local two = o.buffers ~= nil and table.getn(o.buffers) == 2
  local order = two and o.buffers[1] == fftsa.sg_buf and o.buffers[2] == fftsa.sg_mk
  return fftsa.sg_markers == true and two and order
         and o.drawstyle == display.STYLE_LINE
         and o.scaletrace_mode == display.TRACE_ALL,
         string.format('traces=%s spectrum-first=%s style=%s scaletrace=%s',
                       tostring(two), tostring(order), tostring(o.drawstyle),
                       tostring(o.scaletrace_mode))
end)())

-- THE BUG THAT MADE MARKERS INVISIBLE. Both axes apply their limits to the SELECTED
-- trace only once a graph has more than one, so pinning once after adding both left the
-- marker trace auto-scaling: its handful of points were scaled against themselves and
-- landed nowhere near the spectrum, with nothing refused and nothing logged. Every trace
-- has to come out pinned to the same limits.
check('every bound trace is pinned to the same dB range and span', (function()
  fftsa.sg_markers = true
  fftsa.sg_bind()
  local o = OBJ[fftsa.sg_graph]
  if o.buffers == nil or table.getn(o.buffers) ~= 2 then
    return false, 'expected two traces, got ' .. tostring(o.buffers and
                                                          table.getn(o.buffers))
  end
  local i
  for i = 1, table.getn(o.buffers) do
    local b = o.buffers[i]
    local y = o.ypin ~= nil and o.ypin[b]
    local x = o.xpin ~= nil and o.xpin[b]
    if not y then return false, 'trace ' .. i .. ' has no dB range pinned' end
    if not x then return false, 'trace ' .. i .. ' has no span pinned' end
    if y[1] ~= fftsa.sg_dbmin or y[2] ~= fftsa.sg_dbmax then
      return false, string.format('trace %d pinned %g..%g, wanted %g..%g', i,
                                  y[1], y[2], fftsa.sg_dbmin, fftsa.sg_dbmax)
    end
    if x[2] ~= fftsa.sg_fhi_hz then
      return false, string.format('trace %d spans to %g, wanted %g', i, x[2],
                                  fftsa.sg_fhi_hz)
    end
  end
  return true, string.format('both traces at %g..%g dB and 0..%g Hz',
                             fftsa.sg_dbmin, fftsa.sg_dbmax, fftsa.sg_fhi_hz)
end)())
check('each peak gets a needle: floor, peak, floor, in frequency order', (function()
  fftsa.frame()
  local mk = fftsa.sg_mk
  local found, i = 0, nil
  for i = 1, fftsa.sg_npeak do
    local k = fftsa.pk_bi[i]
    if k ~= nil and k > 0 and fftsa.pk_bv[i] > 0 then found = found + 1 end
  end
  if found < 1 then return false, 'no peaks to mark' end
  if mk.n ~= found * fftsa.sg_mk_per then
    return false, string.format('%d points for %d peaks at %d a needle', mk.n, found,
                                fftsa.sg_mk_per)
  end
  -- Each triple is floor, above the floor, floor again, and x never goes backwards.
  for i = 1, found do
    local b = (i - 1) * 3
    if mk.readings[b + 1] ~= fftsa.sg_dbmin or mk.readings[b + 3] ~= fftsa.sg_dbmin then
      return false, string.format('needle %d does not start and end at the floor', i)
    end
    if not (mk.readings[b + 2] > fftsa.sg_dbmin) then
      return false, string.format('needle %d has no height', i)
    end
  end
  for i = 2, mk.n do
    if mk.extravalues[i] < mk.extravalues[i - 1] then
      return false, string.format('x goes backwards at point %d', i)
    end
  end
  return true, string.format('%d needles, %d points', found, mk.n)
end)())

-- The sort, driven directly. The end-to-end check above cannot reach it: the mock's
-- capture is one tone, so the finder reports a single peak and a one-point buffer is
-- sorted whatever the code does. These three arrive strongest-first with their
-- frequencies deliberately out of order.
check('markers come out in frequency order from an amplitude-ordered list', (function()
  -- peak_interp is stubbed so BOTH columns are a known function of the bin: the offset
  -- is zero and the amplitude is k/1000, giving 0.005, 0.02 and 0.04 V for bins 5, 20
  -- and 40. Driving it with the real estimator instead reads the live spectrum, where
  -- the amplitude has nothing to do with the bv passed in -- which is how this check
  -- first "failed" against correct code.
  local real = fftsa.peak_interp
  fftsa.peak_interp = function(k, nb) return 0, k * 0.001 end
  local bi, bv = {20, 5, 40}, {1.0, 0.5, 0.25}
  local n = fftsa.sg_update_markers(bi, bv, 3, 100)
  local mk = fftsa.sg_mk
  fftsa.peak_interp = real
  if n ~= 9 or mk.n ~= 9 then
    return false, string.format('wrote %d, buffer holds %d, wanted 9', n, mk.n)
  end
  -- The peak of each needle is the middle point of its triple.
  local hz, db = {}, {}
  local i
  for i = 1, 3 do
    hz[i], db[i] = mk.extravalues[(i - 1) * 3 + 2], mk.readings[(i - 1) * 3 + 2]
  end
  -- Bins 5, 20 and 40 at 100 Hz: 400, 1900, 3900. Each has to carry its OWN amplitude
  -- through the sort, which here means dB rising with frequency.
  local want = {{400, 20 * math.log10(0.005)},
                {1900, 20 * math.log10(0.020)},
                {3900, 20 * math.log10(0.040)}}
  for i = 1, 3 do
    if math.abs(hz[i] - want[i][1]) > 1 then
      return false, string.format('point %d at %.0f Hz, wanted %.0f',
                                  i, hz[i], want[i][1])
    end
    if math.abs(db[i] - want[i][2]) > 0.01 then
      return false, string.format('point %d at %.0f Hz carries %.2f dB, wanted %.2f',
                                  i, hz[i], db[i], want[i][2])
    end
  end
  return true, string.format('%.0f Hz %.1f dB, %.0f Hz %.1f dB, %.0f Hz %.1f dB',
                             hz[1], db[1], hz[2], db[2], hz[3], db[3])
end)())
check('the marker refill happens before the trace refill', (function()
  -- The trace's clear is the last notify in a frame, so its write count has to be the
  -- one that moves last: markers filled after it would leave the spectrum short of a
  -- trace at the yield.
  local order = {}
  local realwr = buffer.write.reading
  local realclear = fftsa.sg_mk.clear
  buffer.write.reading = function(b, ...)
    local tag = 'other'
    if b == fftsa.sg_mk then tag = 'marker' elseif b == fftsa.sg_buf then tag = 'trace' end
    if order[table.getn(order)] ~= tag then order[table.getn(order) + 1] = tag end
    return realwr(b, unpack(arg))
  end
  fftsa.frame()
  buffer.write.reading = realwr
  return table.getn(order) >= 2 and order[1] == 'marker' and order[2] == 'trace',
         table.concat(order, ' then ')
end)())
check('switching markers off again leaves one trace and a line', (function()
  fftsa.sg_markers = false
  fftsa.sg_bind()
  local o = OBJ[fftsa.sg_graph]
  return fftsa.sg_markers == false and o.traces == 1
         and o.drawstyle == display.STYLE_LINE,
         string.format('traces=%s style=%s', tostring(o.traces), tostring(o.drawstyle))
end)())

print('\nthe about screen (real code)')
-- Every screen title, with its length: the firmware truncates one over 31 characters and
-- posts 1707, and a truncated title is the sort of thing that reaches the glass unnoticed.
check('every screen title is what it should be, and short enough', (function()
  local want = {[fftsa.sg_scr] = 'FFT SPECTRUM ANALYSER',
                [fftsa.optscr] = 'FFT ANALYSER OPTIONS',
                [fftsa.aboutscr] = 'FFT Analyser - About',
                [fftsa.loadscr] = 'FFT SPECTRUM ANALYSER'}
  local h, t
  for h, t in pairs(want) do
    local got = obj_at(h).title
    if got ~= t then
      return false, string.format('%q against %q', tostring(got), t)
    end
    if string.len(t) > 31 then
      return false, string.format('%q is %d characters', t, string.len(t))
    end
  end
  return true, string.format('about: %q, %d characters', want[fftsa.aboutscr],
                             string.len(want[fftsa.aboutscr]))
end)())
-- The licence has to be the repo's, not a paraphrase of it, so it is compared against
-- LICENSE itself. Trailing blank lines are dropped: the file ends with a newline and the
-- screen carries no row for it.
check('the licence on the about screen is LICENSE, verbatim', (function()
  local f = io.open('LICENSE', 'r')
  if f == nil then return false, 'LICENSE not readable from the suite cwd' end
  local want, n = {}, 0
  while true do
    local ln = f:read('*l')
    if ln == nil then break end
    n = n + 1
    want[n] = ln
  end
  f:close()
  while n > 0 and want[n] == '' do want[n] = nil; n = n - 1 end
  local got = fftsa.about_text
  local ng = table.getn(got)
  if ng ~= n then
    return false, string.format('%d rows on the screen, %d lines in LICENSE', ng, n)
  end
  local i
  for i = 1, n do
    if got[i] ~= want[i] then
      return false, string.format('row %d: %q against %q', i, tostring(got[i]),
                                  tostring(want[i]))
    end
  end
  return true, string.format('%d rows match', n)
end)())
check('the author line is FONT_4 and every licence row FONT_1', (function()
  local t = obj_at(fftsa.about_name)
  if t == nil then return false, 'no author line' end
  local body = fftsa.about_lines
  if body == nil or table.getn(body) == 0 then return false, 'no licence rows' end
  local wrong, i = 0, nil
  for i = 1, table.getn(body) do
    if obj_at(body[i]).font ~= display.FONT_1 then wrong = wrong + 1 end
  end
  return t.font == display.FONT_4 and t.text == 'Author: Ian Ameline' and wrong == 0
         and t.justify == display.JUST_CENTER and t.colour == 56575
         and obj_at(body[1]).colour == 16777215,
         string.format('title font %s %q just %s colour %s, %d rows, %d at the wrong'
                       .. ' font, body colour %s',
                       tostring(t.font), tostring(t.text), tostring(t.justify),
                       tostring(t.colour), table.getn(body), wrong,
                       tostring(obj_at(body[1]).colour))
end)())
-- One object a row, rewritten per page, so the count is the page size and not the licence
-- length. The licence is longer than a page at FONT_1, which is what the paging is for.
check('there is one object per row and more licence than fits a page', (function()
  local rows = table.getn(fftsa.about_lines)
  return rows == fftsa.about_rows and fftsa.about_pages() > 1,
         string.format('%d row objects for %d a page, %d licence rows, %d pages',
                       rows, fftsa.about_rows, table.getn(fftsa.about_text),
                       fftsa.about_pages())
end)())
-- The rows are laid out from two constants against an undocumented font, so the one thing
-- the host can check is that the arithmetic leaves the button row clear.
check('a page of rows ends above the button row', (function()
  local lasty = fftsa.about_body_y + (fftsa.about_rows - 1) * fftsa.about_body_dy
  return lasty + fftsa.about_body_dy <= fftsa.opt_btn_y,
         string.format('%d rows, last at y=%d, pitch %d, buttons at %d',
                       fftsa.about_rows, lasty, fftsa.about_body_dy, fftsa.opt_btn_y)
end)())
-- Every licence row has to appear on some page, in order, and the last page has to blank
-- the rows it does not fill or it shows the previous page's text under the new one.
check('the pages carry the whole licence in order, and blank the tail', (function()
  local seen, p, i = {}, nil, nil
  local nseen = 0
  for p = 1, fftsa.about_pages() do
    fftsa.about_show_page(p)
    for i = 1, fftsa.about_rows do
      local want = fftsa.about_text[(p - 1) * fftsa.about_rows + i]
      local got = obj_at(fftsa.about_lines[i]).text
      if want == nil then
        if got ~= '' then
          return false, string.format('page %d row %d past the licence reads %q', p, i,
                                      tostring(got))
        end
      else
        if got ~= want then
          return false, string.format('page %d row %d: %q against %q', p, i,
                                      tostring(got), tostring(want))
        end
        nseen = nseen + 1
        seen[(p - 1) * fftsa.about_rows + i] = true
      end
    end
  end
  fftsa.about_show_page(1)
  local missing = 0
  for i = 1, table.getn(fftsa.about_text) do
    if seen[i] ~= true then missing = missing + 1 end
  end
  return nseen == table.getn(fftsa.about_text) and missing == 0,
         string.format('%d of %d rows shown, %d missing', nseen,
                       table.getn(fftsa.about_text), missing)
end)())
check('PgUp and PgDn clamp at the ends instead of going blank', (function()
  local last = fftsa.about_pages()
  fftsa.about_show_page(1)
  fftsa.about_pgup()
  local atfirst = fftsa.about_page
  local p
  for p = 1, last + 3 do fftsa.about_pgdn() end
  local atlast = fftsa.about_page
  local text = obj_at(fftsa.about_lines[1]).text
  local name = obj_at(fftsa.about_name).text
  fftsa.about_show_page(1)
  return atfirst == 1 and atlast == last and text ~= ''
         and name == 'Author: Ian Ameline',
         string.format('PgUp from 1 -> %d, PgDn past %d -> %d, first row %q, author %q',
                       atfirst, last, atlast, tostring(text), tostring(name))
end)())
check('the page indicator tracks the page', (function()
  fftsa.about_show_page(2)
  local two = obj_at(fftsa.about_pageno).text
  fftsa.about_show_page(1)
  local one = obj_at(fftsa.about_pageno).text
  return one == string.format('page 1 of %d', fftsa.about_pages())
         and two == string.format('page 2 of %d', fftsa.about_pages()),
         tostring(one) .. ' | ' .. tostring(two)
end)())
-- Opened from the last page it was left on, the screen would read as a wall of capitals.
check('opening About goes back to the first page', (function()
  fftsa.about_show_page(fftsa.about_pages())
  display.changescreen(fftsa.optscr)
  fftsa.about()
  local p = fftsa.about_page
  fftsa.about_back()
  fftsa.show_main()
  return p == 1, 'page ' .. tostring(p)
end)())
check('About opens the screen and Back returns to the form', (function()
  display.changescreen(fftsa.optscr)
  local opened = fftsa.about() and display.active == fftsa.aboutscr
  local shown = display.active
  local returned = fftsa.about_back() and display.active == fftsa.optscr
  local back = display.active
  fftsa.show_main()
  return opened and returned,
         string.format('About showed %s (about is %s), Back showed %s (form is %s)',
                       tostring(shown), tostring(fftsa.aboutscr), tostring(back),
                       tostring(fftsa.optscr))
end)())
-- Reached when the pool refuses the screen: the button must not raise on a nil handle.
check('About with no screen built answers false instead of raising', (function()
  local keep = fftsa.aboutscr
  fftsa.aboutscr = nil
  local ok, ret = pcall(function() return fftsa.about() end)
  fftsa.aboutscr = keep
  return ok and ret == false, string.format('raised=%s returned=%s', tostring(not ok),
                                            tostring(ret))
end)())

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
check('the settings line is on screen', OBJ[fftsa.sg_xunit].text ~= nil,
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
-- Counted calls, not the live trace count: a removeall+add pair leaves the count at 1,
-- exactly as never touching it does, so a count cannot tell them apart.
print('\nper-frame repaint is in place, with a yield (real code)')
local gh = fftsa.sg_graph
local ad0, rm0 = (OBJ[gh].adds or 0), (OBJ[gh].removes or 0)
local dl0 = DELAYS
local pin0 = (OBJ[gh].pins or 0)
-- Snapshotted, not compared against zero: sg_bind() calls select and drawstyle when the
-- marker trace goes on or off, so only the change ACROSS A FRAME says anything.
local sel0 = (OBJ[gh].selects or 0)
local st0 = (OBJ[gh].scaletraces or 0)
local ds0 = (OBJ[gh].drawstyles or 0)
fftsa.frame_body()
-- The frame detaches nothing and attaches nothing: the refill rewrites the buffer the
-- graph already holds, so adds and removes must both come back unmoved. Either of them
-- moving is a regression into per-point churn, which is what these numbers guard.
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

-- NO GRAPH CALL AT ALL. The clear is the notify, so a frame touches nothing on the
-- widget -- and that is what keeps the axes still. Every synchronous graph call in a
-- frame repaints the whole widget including its own axis label text: measured at 8.5 ms
-- for a removeall and add per frame, and a visible flicker on the glass.
check('and an unlocked frame makes no graph call whatsoever', (function()
  local o = OBJ[gh]
  return (o.pins or 0) == pin0 and (o.selects or 0) == sel0
         and (o.scaletraces or 0) == st0 and (o.drawstyles or 0) == ds0,
         string.format('pins %d/%d selects %d/%d scaletrace %d/%d drawstyle %d/%d',
                       (o.pins or 0), pin0, (o.selects or 0), sel0,
                       (o.scaletraces or 0), st0, (o.drawstyles or 0), ds0)
end)())
-- The lock is ON by default and the frame above still made no graph call, which is the
-- point of the event-driven design: the cost is paid per gesture, not per frame.
check('and that holds with the view lock on, which is the default',
      fftsa.sg_lock == true and (fftsa.sg_ev or 0) == 0,
      'lock=' .. tostring(fftsa.sg_lock) .. ' ev=' .. tostring(fftsa.sg_ev))

-- The yield is the only thing feeding the display task, so a zero or missing
-- one is a silent regression into the jumpy behaviour. Assert the value too.
check('the yield is the configured amount', fftsa.sg_yield > 0.005
      and fftsa.sg_yield < 0.1, tostring(fftsa.sg_yield))

-- ---------- the view lock and the two icon buttons ----------
-- The graph pans and zooms on touch and the firmware offers no way to refuse it:
-- display.setstate answers event 1717 for STATE_DISABLE and STATE_READONLY on a Graph. So
-- the lock restores the window instead of preventing the gesture, which makes the cost a
-- per-frame one and the placement of the re-pin inside the frame the thing to hold still.
print('\nview lock and the icon buttons (real code)')
local function img_children(scr)
  local t = {}
  for _, o in pairs(OBJ) do
    if o.alive and o.parent == scr and o.type == display.OBJ_IMAGE then
      t[o.image] = o
    end
  end
  return t
end

check('the loadimage names are three distinct non-empty strings',
      fftsa.img_lock_c ~= nil and fftsa.img_lock_o ~= nil and fftsa.img_cog ~= nil
      and fftsa.img_lock_c ~= fftsa.img_lock_o
      and fftsa.img_lock_c ~= fftsa.img_cog and fftsa.img_lock_o ~= fftsa.img_cog,
      tostring(fftsa.img_lock_c) .. ' ' .. tostring(fftsa.img_lock_o) .. ' '
      .. tostring(fftsa.img_cog))
check('both buttons exist on the spectrum screen',
      fftsa.lockbtn ~= nil and fftsa.optbtn ~= nil
      and OBJ[fftsa.lockbtn].parent == fftsa.sg_scr
      and OBJ[fftsa.optbtn].parent == fftsa.sg_scr)
-- A 60 px face cannot hold a word, and a label under a transparent icon shows through
-- it, so the design is a blank button with the icon as its only marking.
check('with blank faces, because the icon is the whole label',
      OBJ[fftsa.lockbtn].label == ' ' and OBJ[fftsa.optbtn].label == ' ',
      '[' .. tostring(OBJ[fftsa.lockbtn].label) .. '] ['
      .. tostring(OBJ[fftsa.optbtn].label) .. ']')
check('side by side on the peak-table row, inside the 800 px panel',
      OBJ[fftsa.lockbtn].x == fftsa.btn_lock_x and OBJ[fftsa.optbtn].x == fftsa.btn_opt_x
      and OBJ[fftsa.lockbtn].y == fftsa.btn_y and OBJ[fftsa.optbtn].y == fftsa.btn_y
      and fftsa.btn_lock_x + fftsa.btn_lock_w <= fftsa.btn_opt_x
      and fftsa.btn_opt_x + fftsa.btn_opt_w <= 800)
check('Lock presses toggle_lock and the cog opens the options form', (function()
  local l = display.events[fftsa.lockbtn][display.EVENT_PRESS]
  local o = display.events[fftsa.optbtn][display.EVENT_PRESS]
  return string.find(l, 'toggle_lock', 1, true) ~= nil
         and string.find(o, 'fftsa.options', 1, true) ~= nil, l .. ' | ' .. o
end)())
check('all three icons were created, as children of the spectrum screen', (function()
  local im = img_children(fftsa.sg_scr)
  return im[fftsa.img_lock_c] ~= nil and im[fftsa.img_lock_o] ~= nil
         and im[fftsa.img_cog] ~= nil
end)())
check('each icon centred on its button', (function()
  local im = img_children(fftsa.sg_scr)
  local lx = fftsa.btn_lock_x + math.floor((fftsa.btn_lock_w - fftsa.lock_img_w) / 2)
  local ly = fftsa.btn_y + math.floor((fftsa.btn_h - fftsa.lock_img_h) / 2)
  local ox = fftsa.btn_opt_x + math.floor((fftsa.btn_opt_w - fftsa.cog_img_w) / 2)
  local c, o, g = im[fftsa.img_lock_c], im[fftsa.img_lock_o], im[fftsa.img_cog]
  return c.x == lx and c.y == ly and o.x == lx and o.y == ly and g.x == ox,
         string.format('closed %d,%d open %d,%d cog %d, wanted %d,%d and %d',
                       c.x, c.y, o.x, o.y, g.x, lx, ly, ox)
end)())
-- The state on the glass is which padlock is visible, so exactly one of the pair can be.
check('locked by default, showing the closed padlock and only that one',
      fftsa.sg_lock == true and OBJ[fftsa.lockimg_c].hidden == false
      and OBJ[fftsa.lockimg_o].hidden == true,
      'lock=' .. tostring(fftsa.sg_lock) .. ' closed hidden='
      .. tostring(OBJ[fftsa.lockimg_c].hidden) .. ' open hidden='
      .. tostring(OBJ[fftsa.lockimg_o].hidden))
check('and the graph reports its own pan and zoom, which is what the lock runs on',
      display.events[gh] ~= nil
      and display.events[gh][display.EVENT_SCALE] ~= nil
      and string.find(display.events[gh][display.EVENT_SCALE], 'sg_ev', 1, true) ~= nil,
      tostring(display.events[gh] and display.events[gh][display.EVENT_SCALE]))

local wx0, wx1 = OBJ[gh].xmin, OBJ[gh].xmax
local wy0, wy1 = OBJ[gh].ymin, OBJ[gh].ymax
-- A pan, as the firmware delivers it: the limits move AND EVENT_SCALE fires. Moving the
-- limits without the fire is not a thing the widget does, and a test that did only that
-- would be asserting against a mechanism the app cannot see.
local function drag_axes()
  OBJ[gh].xmin, OBJ[gh].xmax = 12345, 23456
  OBJ[gh].ymin, OBJ[gh].ymax = -77, -33
  fftsa.sg_ev = (fftsa.sg_ev or 0) + 10      -- about ten fires a drag, measured
end
-- The lock and the icons act on the once-a-second tick, not on every frame, and os.clock()
-- barely moves inside this suite -- so a test that wants the tick to fire has to say so.
local function tick_due()
  fftsa.sg_tick_last = nil
end

-- The frame-rate requirement, and the whole reason the lock is event-driven: a pin costs
-- 60 ms an axis and the frame has about 1 ms of headroom at 512 samples, so a locked view
-- nobody has touched must make no graph write whatsoever. This is the check that fails if
-- the lock ever goes back to re-asserting the limits every frame.
local pinq, ypinq = (OBJ[gh].pins or 0), (OBJ[gh].ypins or 0)
fftsa.sg_ev = 0
tick_due()
fftsa.frame_body()
tick_due()
fftsa.frame_body()
check('three locked ticks on an untouched view write no limit at all',
      (OBJ[gh].pins or 0) == pinq and (OBJ[gh].ypins or 0) == ypinq,
      string.format('pins %d/%d ypins %d/%d', (OBJ[gh].pins or 0), pinq,
                    (OBJ[gh].ypins or 0), ypinq))
check('and sg_lock_check() reports it had nothing to do',
      fftsa.sg_lock_check() == false)

local pin2, ypin2 = (OBJ[gh].pins or 0), (OBJ[gh].ypins or 0)
tick_due()
drag_axes()
fftsa.frame_body()
check('a locked tick restores the window a reported pan moved',
      OBJ[gh].xmin == wx0 and OBJ[gh].xmax == wx1
      and OBJ[gh].ymin == wy0 and OBJ[gh].ymax == wy1,
      string.format('x %s..%s y %s..%s, wanted %s..%s and %s..%s',
                    tostring(OBJ[gh].xmin), tostring(OBJ[gh].xmax),
                    tostring(OBJ[gh].ymin), tostring(OBJ[gh].ymax),
                    tostring(wx0), tostring(wx1), tostring(wy0), tostring(wy1)))
check('writing each axis exactly once', (OBJ[gh].pins or 0) == pin2 + 1
      and (OBJ[gh].ypins or 0) == ypin2 + 1,
      string.format('pins %d/%d ypins %d/%d', (OBJ[gh].pins or 0), pin2,
                    (OBJ[gh].ypins or 0), ypin2))
-- A pin between the clear and the last write would repaint a half-filled trace, which is
-- the blank-plot window the frame is built to keep short.
check('and the pin lands after the last write, never inside the refill window',
      OBJ[gh].pin_at_writes == WRITES and WRITES > CLEAR_AT_WRITES,
      'pin at ' .. tostring(OBJ[gh].pin_at_writes) .. ' writes, frame ended at '
      .. tostring(WRITES) .. ', cleared at ' .. tostring(CLEAR_AT_WRITES))
check('and the fire count is consumed, so the next frame is free again',
      fftsa.sg_ev == 0, tostring(fftsa.sg_ev))

-- The echo. Our own write fires EVENT_SCALE too, asynchronously, so fires arrive after a
-- restore with nothing having moved. They need no special case: the read-back answers
-- with the limits we just wrote, so there is nothing to write again. Acting on the fire
-- alone would pin, fire, and never stop.
check('fires with nothing moved write nothing, however many arrive', (function()
  local p, yp = (OBJ[gh].pins or 0), (OBJ[gh].ypins or 0)
  local i
  for i = 1, 7 do                      -- seven is what ten pin calls produced
    fftsa.sg_ev = (fftsa.sg_ev or 0) + 1
    tick_due()
    fftsa.frame_body()
  end
  return (OBJ[gh].pins or 0) == p and (OBJ[gh].ypins or 0) == yp
         and fftsa.sg_ev == 0,
         string.format('pins %d/%d ypins %d/%d ev=%s', (OBJ[gh].pins or 0), p,
                       (OBJ[gh].ypins or 0), yp, tostring(fftsa.sg_ev))
end)())
-- Only the axis that moved. Each write repaints the widget, so a Y pin for an X-only pan
-- is a second repaint for nothing.
check('a pan on X alone writes X alone', (function()
  local p, yp = (OBJ[gh].pins or 0), (OBJ[gh].ypins or 0)
  OBJ[gh].xmin = wx0 + (wx1 - wx0) * 0.25
  fftsa.sg_ev = 1
  tick_due()
  fftsa.frame_body()
  return (OBJ[gh].pins or 0) == p + 1 and (OBJ[gh].ypins or 0) == yp
         and OBJ[gh].xmin == wx0,
         string.format('pins %d/%d ypins %d/%d xmin=%s', (OBJ[gh].pins or 0), p,
                       (OBJ[gh].ypins or 0), yp, tostring(OBJ[gh].xmin))
end)())
-- The tolerance has to survive a narrow window a long way from DC. A span-relative test
-- alone goes to nothing there: Start 498999.9 / Stop 499010 is a 10.1 Hz span on 499 kHz
-- endpoints, reachable from the form, where the rounding on an endpoint is larger than
-- the whole span and the lock would write on every tick for ever.
check('a limit counts as moved only past the tolerance, span or endpoint', (function()
  local span, want = 10.1, 499010
  local eps = want * 1.2e-7            -- about a float32 step at that magnitude
  local rounding = fftsa.sg_moved(want + eps, want, span)
  local real = fftsa.sg_moved(want + span * 0.5, want, span)
  -- and a pixel of pan on a wide span is still a pan
  local pixel = fftsa.sg_moved(50000 / fftsa.sg_plotpx, 0, 50000)
  return rounding == false and real == true and pixel == true,
         string.format('rounding=%s realpan=%s pixel=%s', tostring(rounding),
                       tostring(real), tostring(pixel))
end)())
check('and a nil read-back is treated as moved, so the lock is never silently dead',
      fftsa.sg_moved(nil, 0, 50000) == false and (function()
        local g = fftsa.sg_graph
        local saved = display.events[g]
        display.events[g] = nil          -- read-back answers nil now
        local p = (OBJ[g].pins or 0)
        fftsa.sg_ev = 1
        local wrote = fftsa.sg_restore()
        display.events[g] = saved
        return wrote == true and (OBJ[g].pins or 0) == p + 1
      end)())

-- Both of scalex's returns are documented optional. A firmware that answered the lower
-- limit alone would leave a left-anchored zoom -- which moves only the upper one --
-- entirely invisible to the lock, so a nil in either position has to count as moved.
check('a read-back that answers one limit is treated as moved, not as unmoved', (function()
  local real = display.graph.scalex
  local p0 = (OBJ[gh].pins or 0)
  display.graph.scalex = function(g, ...)
    if arg[3] == nil then return OBJ[g].xmin end       -- min only, max absent
    return real(g, unpack(arg))
  end
  OBJ[gh].xmax = wx0 + (wx1 - wx0) * 0.75              -- a zoom anchored at the left
  fftsa.sg_ev = 1
  local ok, wrote = pcall(fftsa.sg_restore)
  display.graph.scalex = real
  if not ok then return false, 'raised: ' .. tostring(wrote) end
  return wrote == true and (OBJ[gh].pins or 0) == p0 + 1 and OBJ[gh].xmax == wx1,
         string.format('wrote=%s pins %d/%d xmax=%s', tostring(wrote),
                       (OBJ[gh].pins or 0), p0, tostring(OBJ[gh].xmax))
end)())
-- An axis of no height has nothing to measure a move against, and a zero scale makes
-- every difference exceed the tolerance -- a 60 ms write on every gesture for ever.
check('a zero-height axis is not a permanent write', (function()
  return fftsa.sg_moved(1e-9, 0, 0) == false and fftsa.sg_moved(5, 0, 0) == false
end)())
-- sg_bind re-asserts the pins because removeall and add may reset what the object
-- carries. The report registration sits in the same position, and sg_rebind() reaches
-- sg_bind from the failed-frame path -- so one raised frame must not cost the lock.
check('sg_bind re-asserts the pan report, so a rebind cannot kill the lock', (function()
  local was = fftsa.sg_lock
  fftsa.sg_lock = true
  display.events[gh] = nil                             -- as a reset object would look
  fftsa.sg_bind()
  local back = display.events[gh] ~= nil
                and display.events[gh][display.EVENT_SCALE] ~= nil
  -- and an unlocked rebind must NOT register one
  fftsa.sg_lock = false
  display.events[gh] = nil
  fftsa.sg_bind()
  local still_off = display.events[gh] == nil
                    or display.events[gh][display.EVENT_SCALE] == nil
  fftsa.sg_lock = was
  fftsa.sg_lock_hook(was)
  return back and still_off,
         'locked rebind registered=' .. tostring(back)
         .. ' unlocked rebind clean=' .. tostring(still_off)
end)())

check('a press unlocks it', fftsa.toggle_lock() == false and fftsa.sg_lock == false)
check('and shows the open padlock again',
      OBJ[fftsa.lockimg_o].hidden == false and OBJ[fftsa.lockimg_c].hidden == true)
local pin3, ypin3 = (OBJ[gh].pins or 0), (OBJ[gh].ypins or 0)
tick_due()
drag_axes()
fftsa.frame_body()
check('an unlocked tick leaves a panned view alone', OBJ[gh].xmin == 12345
      and OBJ[gh].ymin == -77 and (OBJ[gh].pins or 0) == pin3
      and (OBJ[gh].ypins or 0) == ypin3,
      string.format('x from %s, pins %d/%d', tostring(OBJ[gh].xmin),
                    (OBJ[gh].pins or 0), pin3))
-- Unlocking does not restore the view: the pan is what the operator asked for, and the
-- next Apply or zoom re-pins anyway.
check('unlocking leaves the panned view where the finger left it', OBJ[gh].xmax == 23456,
      tostring(OBJ[gh].xmax))
-- Locking re-pins at once, so a view dragged while free snaps back on the press rather
-- than at the next frame -- and that is the whole mechanism while the app is halted.
check('locking again restores it immediately, without waiting for a frame', (function()
  local p = (OBJ[gh].pins or 0)
  local on = fftsa.toggle_lock()
  return on == true and (OBJ[gh].pins or 0) == p + 1 and OBJ[gh].xmin == wx0,
         string.format('on=%s pins %d/%d xmin=%s', tostring(on),
                       (OBJ[gh].pins or 0), p, tostring(OBJ[gh].xmin))
end)())

-- The icons, which a focus repaint covers. The frame puts them back at the peak cadence,
-- so the assertion is that a frame redraws them at all -- setstate to a state the object
-- already holds may be taken as nothing to do, hence the invisible-then-enable pair.
check('a frame redraws both icons, so a focus repaint cannot leave one blank', (function()
  local im = img_children(fftsa.sg_scr)
  local cog = im[fftsa.img_cog]
  local c0 = (cog.hides or 0)
  tick_due()
  fftsa.frame_body()
  return (cog.hides or 0) > c0, string.format('cog hides %d, was %d',
                                              (cog.hides or 0), c0)
end)())
check('and the hidden padlock stays hidden through that redraw',
      OBJ[fftsa.lockimg_o].hidden == true and OBJ[fftsa.lockimg_c].hidden == false,
      'open hidden=' .. tostring(OBJ[fftsa.lockimg_o].hidden)
      .. ' closed hidden=' .. tostring(OBJ[fftsa.lockimg_c].hidden))
-- The period itself, which nothing else pins: with the gate alone asserted, setting it to
-- a minute would leave the suite green while the manual still promised a second.
check('the slow tick runs at the cadence the manual quotes', (function()
  local im = img_children(fftsa.sg_scr)
  local cog = im[fftsa.img_cog]
  local period = fftsa.sg_pk_period
  if period == nil or period <= 0 or period > 2 then
    return false, 'period=' .. tostring(period)
  end
  -- Just inside the period: no repair. Just outside: one.
  local c0 = (cog.hides or 0)
  fftsa.sg_tick_last = os.clock() - period * 0.5
  fftsa.frame_body()
  local held = (cog.hides or 0) == c0
  fftsa.sg_tick_last = os.clock() - period * 1.5
  fftsa.frame_body()
  local fired = (cog.hides or 0) > c0
  return held and fired,
         string.format('period=%s held=%s fired=%s', tostring(period),
                       tostring(held), tostring(fired))
end)())
-- Gated, or it is the icons' five setstate calls every frame instead of one a second.
check('but not on every frame', (function()
  local im = img_children(fftsa.sg_scr)
  local cog = im[fftsa.img_cog]
  local c0 = (cog.hides or 0)
  fftsa.frame_body()
  fftsa.frame_body()
  return (cog.hides or 0) == c0, string.format('cog hides %d, was %d',
                                               (cog.hides or 0), c0)
end)())

-- A press after the screen is gone. The handles are nil by then and a nil handed to the
-- firmware is a modal dialog per call, so both halves have to test for one.
check('toggling with nothing built neither raises nor touches the firmware', (function()
  local g, c, o = fftsa.sg_graph, fftsa.lockimg_c, fftsa.lockimg_o
  fftsa.sg_graph, fftsa.lockimg_c, fftsa.lockimg_o = nil, nil, nil
  local ok, err = pcall(function() fftsa.toggle_lock() fftsa.toggle_lock() end)
  fftsa.sg_graph, fftsa.lockimg_c, fftsa.lockimg_o = g, c, o
  fftsa.sg_lock = false
  fftsa.lock_icon()
  return ok, tostring(err)
end)())
-- Left as the app would leave it: lock off AND the report unregistered. The two are
-- driven together by toggle_lock, so a suite that unregisters only one of them hands
-- every later check a graph state the app cannot produce.
fftsa.sg_lock_hook(false)
check('and the lock is back off for the frames below, report included',
      fftsa.sg_lock == false
      and (display.events[gh] == nil
           or display.events[gh][display.EVENT_SCALE] == nil),
      'lock=' .. tostring(fftsa.sg_lock) .. ' ev='
      .. tostring(display.events[gh] and display.events[gh][display.EVENT_SCALE]))

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

-- The firmware labels the axis. X is bound to the reading's extra field, in hertz, which
-- makes this its numeric x-y plot rather than a time plot -- so the labels read +00.00kHz
-- and the app draws no label row of its own. Nor could it draw over the firmware's: a
-- child inside the graph's rectangle is painted over by its per-frame repaint.
print('\nthe firmware labels the axis (real code)')
check('X is bound to the extra field, not the timestamp',
      OBJ[fftsa.sg_graph].xelem == display.ELEMENT_EXTRA,
      'xelem=' .. tostring(OBJ[fftsa.sg_graph].xelem) .. ' time would be '
      .. tostring(display.ELEMENT_TIME))
-- Counted, not probed by name: the firmware labels both axes, so the spectrum screen's
-- only text children are the peak table and the settings line. Eighteen peak fields and
-- one line at the shipped sg_npeak, and a row of tick labels coming back breaks it.
check('no label row is created at all', (function()
  local n = 0
  for _, o in pairs(OBJ) do
    if o.alive and o.parent == fftsa.sg_scr and o.type == display.OBJ_TEXT then
      n = n + 1
    end
  end
  return n == fftsa.sg_npeak * 3 + 1,
         string.format('%d text objects on the spectrum screen, want %d',
                       n, fftsa.sg_npeak * 3 + 1)
end)())
-- The whole line, against a literal, for a state pinned here. Probing for the pieces one
-- at a time passes on a line that has them in any arrangement, and the arrangement is the
-- feature: this is the only place the applied settings read back without opening Options.
check('the legend carries the settings, not the axis units', (function()
  local fs, n, r, w = fftsa.fs, fftsa.n, fftsa.range, fftsa.win_i
  local lo, hi = fftsa.sg_flo_hz, fftsa.sg_fhi_hz
  fftsa.fs, fftsa.n, fftsa.range, fftsa.win_i = 100000, 512, 10, 1
  fftsa.sg_flo_hz, fftsa.sg_fhi_hz = 10, 50000
  local t = fftsa.sg_xunit_text()
  fftsa.fs, fftsa.n, fftsa.range, fftsa.win_i = fs, n, r, w
  fftsa.sg_flo_hz, fftsa.sg_fhi_hz = lo, hi
  -- No band-pass figure: the field is withheld, and the line only mentions it when
  -- something has set fftsa.bp_on over the socket.
  return t == '512 pts   fs 100 kS/s   bin 195.31 Hz   acq 5.12 ms   Hann   10 V', t
end)())
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
  return string.find(narrow, 'only 1 bin in the span', 1, true) ~= nil
         and string.find(wide, 'in the span', 1, true) == nil,
         narrow .. ' | wide: ' .. wide
end)())
-- Pinned IN HERTZ, which is what makes the firmware's own labels read as frequency.
-- Scaled limits would still draw a trace -- the data is in the extra field -- but the
-- axis would be labelled in the wrong units, and that is invisible from inside Lua.
-- Read off what the WRITE recorded, not through display.graph.scalex's read-back: that
-- answers only on a graph with event generation enabled, so a test using it is asserting
-- the precondition as much as the pin, and gets nil the moment the app stops enabling it.
--
-- The wanted low edge comes from fftsa.sg_xwant(), the app's own function, rather than
-- being re-derived here. A copy of the rule in the test is a second rule: this check
-- carried `sg_flo_hz < binhz`, the bin-width test the source explicitly rejects in favour
-- of the plot-width one, and it agreed only because the suite runs at Start = 10 Hz.
check('the X axis is pinned to the window in hertz, not auto-ranged', (function()
  local lo, hi = OBJ[fftsa.sg_graph].xmin, OBJ[fftsa.sg_graph].xmax
  local want_lo, want_hi = fftsa.sg_xwant()
  if lo == nil or want_lo == nil then return false, 'no pin recorded' end
  return near(lo, want_lo, 1e-9) and near(hi, want_hi, 1e-9),
         string.format('pinned %g..%g, wanted %g..%g', lo, hi, want_lo, want_hi)
end)())
check('a changed span re-pins in hertz', (function()
  local g = fftsa.sg_graph
  fftsa.sg_set_xrange(8000, 16000)
  local ok1 = near(OBJ[g].xmin, 8000, 1e-9) and near(OBJ[g].xmax, 16000, 1e-9)
  fftsa.sg_set_xrange(8000, 8200)
  return ok1 and near(OBJ[g].xmin, 8000, 1e-9) and near(OBJ[g].xmax, 8200, 1e-9),
         string.format('narrow pinned to %g..%g', OBJ[g].xmin, OBJ[g].xmax)
end)())
-- The read-back and its precondition: "return values are only valid when the objects
-- event generation is set to ALL". The app registers EVENT_SCALE on the graph, so it
-- answers here; stripped of events it answers nil, and on the instrument -- before
-- anything was ever registered -- nil is exactly what it gave, with no event posted.
-- A view lock that skipped its pin on that nil did nothing at all on the glass and the
-- suite could not see it, because this mock used to answer unconditionally.
check('a scale read-back answers only while event generation is on', (function()
  local g = fftsa.sg_graph
  local saved = display.events[g]
  -- Registered here rather than relying on whatever the app left behind: the point is
  -- the precondition, so the test has to set both sides of it itself.
  display.events[g] = nil
  local off_x, off_y = display.graph.scalex(g), display.graph.scaley(g)
  fftsa.sg_lock_hook(true)
  local on_x, on_y = display.graph.scalex(g), display.graph.scaley(g)
  fftsa.sg_lock_hook(false)
  local back_x = display.graph.scalex(g)
  display.events[g] = saved
  return off_x == nil and off_y == nil and on_x ~= nil and on_y ~= nil
         and back_x == nil,
         string.format('off %s, on %s, off again %s', tostring(off_x),
                       tostring(on_x), tostring(back_x))
end)())
-- Re-pinning makes the firmware redraw its own axis labels, which shows as flicker on
-- hardware. The pin survives a re-add, which is what lets a rebind skip it; sg_bind_min()
-- is that rebind, exercised here because the app only reaches it through sg_rebind().
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

-- The scaled-timestamp encoding is gone with the time axis, and with it the event-1131
-- hazard its carry existed for: the fractional-seconds field is refused above 0.9999999,
-- and a frequency landing an ulp below an integer after the divide produced exactly that.
-- The timestamp is the slot number, an integer, so the fraction is always 0. The mock
-- counts a refused fraction and the BADFRAC check below is what catches one creeping
-- back in.

-- Every timestamp this suite wrote was above the one before it, within its fill.
check('no buffer fill anywhere in this suite went back in time', NONMONO == 0,
      'out-of-order writes: ' .. NONMONO)
check('no fractional timestamp was ever written', BADFRAC == 0,
      'fractions the firmware would refuse: ' .. BADFRAC)

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
-- The readback line's y is its BASELINE, so clearing it means clearing opt_info_h above
-- that, which is the ceiling opt_layout() clamps the pitch against.
check('the readback line clears the last box and the buttons',
      fftsa.opt_info_y - fftsa.opt_info_h
        >= top + (nrows - 1) * pitch + fftsa.opt_edit_dy + fftsa.opt_edit_h
        and fftsa.opt_info_y < fftsa.opt_btn_y,
      string.format('bottom=%d, line clears at %d, buttons at %d',
                    top + (nrows - 1) * pitch + fftsa.opt_edit_dy + fftsa.opt_edit_h,
                    fftsa.opt_info_y - fftsa.opt_info_h, fftsa.opt_btn_y))
check('the readout is centered and five pixels lower', (function()
  local o = obj_at(fftsa.opt_info)
  return o.x == 400 and o.y == 323 and o.justify == display.JUST_CENTER
end)())
-- Nine fields, five rows: a count past the live seven, so the clamp is exercised beyond
-- what the form actually carries. Asserted against the readback line, which is the real
-- ceiling -- clearing the button row is not enough and was what let seven fields lay the
-- bottom box over the top of the line.
check('a field count that overruns is clamped to fit above the readback line',
      (function()
  local keep = fftsa.opt_nf
  fftsa.opt_nf = 9
  local r, p, t = fftsa.opt_layout()
  fftsa.opt_nf = keep
  fftsa.opt_layout()
  local bottom = t + (r - 1) * p + fftsa.opt_edit_dy + fftsa.opt_edit_h
  local ceiling = fftsa.opt_info_y - fftsa.opt_info_h
  return r == 5 and p < fftsa.opt_dy and bottom <= ceiling,
         string.format('%d rows, pitch %d of %d asked, bottom %d vs ceiling %d',
                       r, p, fftsa.opt_dy, bottom, ceiling)
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
-- The measured rate the preview starts from is the DIGITIZER's, fs_acq, because that is
-- what the timestamps measure and what pick_fs answers; the decimation divides it
-- afterwards. Perturbing fftsa.fs instead would prove nothing now: fftsa.fs is the
-- derived rate the transform sees.
check('the preview uses the timestamp-measured rate for the active rate', (function()
  local acq = fftsa.fs_acq
  fftsa.fs_acq = acq - 0.25
  display.setvalue(fftsa.opt_fhi, fftsa.fhi)
  display.setvalue(fftsa.opt_n, 1)
  fftsa.options_preview()
  local text = obj_at(fftsa.opt_info).text
  local expected = fftsa.opt_info_text(fftsa.fs_acq / fftsa.bp_d, 512)
  fftsa.fs_acq = acq
  return text == expected, tostring(text) .. ' | wanted ' .. tostring(expected)
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
-- One buffer, bound for the life of the app, so its identity IS the invariant: it must
-- be the same object, still alive, still the one the graph holds, at the same capacity,
-- with adds and removes unmoved and no object or buffer created along the way.
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
    if not fftsa.options_apply() then
      display.setvalue(fftsa.opt_n, 1); fftsa.options_apply()
      return false, fftsa.lasterr
    end
    if fftsa.n ~= n or fftsa.fft_n ~= n or fftsa.sg_nbins ~= n / 2
       or dmm.digitize.count ~= n or fftsa.cap.cap ~= n * 4
       or fftsa.sg_buf.capacity ~= fftsa.sg_maxpts
       or OBJ[graph0].buffer ~= graphbuf0
       or fftsa.sg_buf ~= graphbuf0 or not graphbuf0.alive
       or OBJ[graph0].adds ~= adds0 or OBJ[graph0].removes ~= removes0
       or live() ~= objects0 or livebufs() ~= buffers0
       or fftsa.busy_max < 2.0
       or fftsa.busy_max < 3.0 * fftsa.frame_estimate(n) - 1e-9
    then
      display.setvalue(fftsa.opt_n, 1); fftsa.options_apply()
      return false, string.format('N=%d: same buffer=%s cap=%d adds %s/%s'
                                  .. ' objs %d/%d bufs %d/%d', n,
                                  tostring(fftsa.sg_buf == graphbuf0),
                                  fftsa.sg_buf.capacity,
                                  tostring(OBJ[graph0].adds), tostring(adds0),
                                  live(), objects0, livebufs(), buffers0)
    end
    if oldcap ~= fftsa.cap and oldcap.alive then
      display.setvalue(fftsa.opt_n, 1); fftsa.options_apply()
      return false, 'old buffer still alive at N=' .. n
    end
    fftsa.frame()
    local kmin, kmax = fftsa.sg_window_bins(n / 2, fftsa.binhz)
    -- Exactly the column count, at every sample count.
    local want = fftsa.sg_ncol
    if fftsa.errrun ~= 0 or fftsa.sg_buf.n ~= want then
      display.setvalue(fftsa.opt_n, 1); fftsa.options_apply()
      return false, string.format('frame at N=%d: %d points, wanted %d (%s)',
                                  n, fftsa.sg_buf.n, want, tostring(fftsa.lasterr))
    end
    local bi, bv = fftsa.find_peaks(n / 2, 1)
    local dk = fftsa.peak_interp(bi[1], n / 2)
    if not near((bi[1] - 1 + dk) * fftsa.binhz, SIG.f, 0.1) then
      display.setvalue(fftsa.opt_n, 1); fftsa.options_apply()
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
-- The buffer object itself must survive a sample change, still bound to the graph: the
-- capacity is the ceiling at every size, so a resize has nothing to reallocate.
check('sample changes never allocate or replace a graph buffer', (function()
  local buffers0 = livebufs()
  local trace = fftsa.sg_buf
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
  local shown = OBJ[fftsa.sg_graph].buffer
  return ok and allocations == 1 and recovered and not fftsa.halted and fftsa.errrun == 0
         and livebufs() == buffers0 and fftsa.sg_buf == trace and shown == trace,
         string.format('allocs=%d same=%s bound=%s bufs %d/%d',
                       allocations, tostring(fftsa.sg_buf == trace),
                       tostring(shown == trace), livebufs(), buffers0)
end)())

-- The trace buffer is made when the app starts and freed when it ends, with nothing
-- created or deleted in between. Hooked at both calls rather than compared by count,
-- because a make paired with a delete leaves livebufs() unchanged and passes a count
-- unnoticed -- which is how the 61-live-buffer leak got as far as the glass.
check('the trace buffer is never allocated or freed while the app runs', (function()
  local trace = fftsa.sg_buf
  if trace == nil then return false, 'no trace buffer at the start' end
  local realmake, realdel = buffer.make, buffer.delete
  local madefull, freed = 0, 0
  buffer.make = function(cap, style)
    if style == buffer.STYLE_WRITABLE_FULL then madefull = madefull + 1 end
    return realmake(cap, style)
  end
  buffer.delete = function(b)
    if b == trace then freed = freed + 1 end
    return realdel(b)
  end
  local i, err
  for i = 1, table.getn(fftsa.sample_counts) do
    display.setvalue(fftsa.opt_n, i)
    if not fftsa.options_apply() then err = fftsa.lasterr end
    fftsa.frame()
    fftsa.frame()
  end
  display.setvalue(fftsa.opt_n, 1)
  fftsa.options_apply()
  buffer.make, buffer.delete = realmake, realdel
  if err ~= nil then return false, tostring(err) end
  return madefull == 0 and freed == 0 and trace.alive
         and fftsa.sg_buf == trace
         and trace.capacity == fftsa.sg_maxpts,
         string.format('made %d freed %d, alive %s, capacity %d of %d',
                       madefull, freed, tostring(trace.alive),
                       trace.capacity, fftsa.sg_maxpts)
end)())
-- The guard inside sg_make_buffer, called directly. sg_build() is its only caller and
-- start() the only caller of that, so nothing in the app reaches it a second time, and
-- a guard nothing reaches is a guard nothing checks. A buffer remade here would also be
-- detached from the graph on the way, so the binding is asserted too.
check('making the trace buffer again at the same size keeps the one in use', (function()
  local trace = fftsa.sg_buf
  local realmake, made = buffer.make, 0
  buffer.make = function(cap, style)
    if style == buffer.STYLE_WRITABLE_FULL then made = made + 1 end
    return realmake(cap, style)
  end
  local got = fftsa.sg_make_buffer(fftsa.sg_nbins, fftsa.sg_maxpts)
  buffer.make = realmake
  return made == 0 and got == trace and fftsa.sg_buf == trace and trace.alive
         and OBJ[fftsa.sg_graph].buffer == trace,
         string.format('made %d, same %s, still bound %s', made,
                       tostring(got == trace),
                       tostring(OBJ[fftsa.sg_graph].buffer == trace))
end)())

-- The X axis is PINNED, and an auto method is a regression rather than an improvement.
-- XSCALE_ALL does make the trace redraw -- it reads the whole buffer, so it has to
-- notice new writes -- but it derives the range from the buffer's own timestamps, and
-- those move while a frame refills. A paint landing mid-fill computes a different range,
-- so the axis walks and the trace slides
-- left and right as though its point count were changing. Measured on the glass twice.
-- Both halves are asserted: the method, and that the limits really are the span.
-- Pinned, never auto-ranged, and the low limit is DC when Start falls inside the first
-- bin -- which is what gets the firmware's own ticks onto round numbers. Both halves
-- asserted, because using DC unconditionally would squash a zoomed span into the right
-- of the plot and nothing else here would notice.
check('the X axis is pinned, from dc when the shift is under a pixel', (function()
  fftsa.sg_pin_x()
  local o = OBJ[fftsa.sg_graph]
  return o.xmethod == display.XSCALE_OFF
         and near(o.xmin, 0, 1e-9) and near(o.xmax, fftsa.sg_fhi_hz, 1e-9),
         string.format('Start %g over a %g Hz span -> pinned %g..%g',
                       fftsa.sg_flo_hz, fftsa.sg_fhi_hz, o.xmin, o.xmax)
end)())
-- The rule is against the PLOT WIDTH, not the bin width, and this is the case that
-- distinguishes them. Bin width was tried first: 10 Hz sits inside a 195 Hz bin at 512
-- samples, so the labels came out round there, and does NOT at 16384 where the bins are
-- 6.1 Hz -- so every size above the default kept the offset. Caught on the glass only.
check('and from dc at every sample count, not just where Start is inside bin one',
      (function()
  local keep = fftsa.n
  local i, worst
  for i = 1, table.getn(fftsa.sample_counts) do
    display.setvalue(fftsa.opt_n, i)
    if not fftsa.options_apply() then
      display.setvalue(fftsa.opt_n, 1); fftsa.options_apply()
      return false, fftsa.lasterr
    end
    local o = OBJ[fftsa.sg_graph]
    if not near(o.xmin, 0, 1e-9) then
      worst = string.format('N=%d with %g Hz bins pinned from %g',
                            fftsa.sample_counts[i], fftsa.binhz, o.xmin)
    end
  end
  display.setvalue(fftsa.opt_n, fftsa.sample_to_idx(keep))
  fftsa.options_apply()
  return worst == nil, worst or 'every count pins from dc'
end)())
check('a zoom well above the first bin keeps its own low limit', (function()
  local flo0, fhi0 = fftsa.sg_flo_hz, fftsa.sg_fhi_hz
  fftsa.sg_set_xrange(8000, 16000)
  local o = OBJ[fftsa.sg_graph]
  -- Captured BEFORE the range is put back: reading o in the message would report the
  -- restored span and print a failure-looking line on a pass.
  local lo, hi = o.xmin, o.xmax
  local kept = near(lo, 8000, 1e-9) and near(hi, 16000, 1e-9)
  fftsa.sg_set_xrange(flo0, fhi0)
  return kept, string.format('pinned %g..%g, wanted 8000..16000', lo, hi)
end)())

-- The 0.05 s tick is a cliff: the occupancy divide turns an 80.4 ms frame into 100.5 ms,
-- and a tick either side of that is 0.10 s and 10 fps against 0.15 and 6.7. Pinned at the
-- boundary in both directions so the rounding cannot drift unnoticed.
check('tick_period rounds up to the 0.05 s tick, and the boundary is exact', (function()
  -- near(), not equality: ticks * 0.05 is 0.15000000000000002 where the literal 0.15 is
  -- 0.1499999999999999944, so == fails on values that are the same tick count.
  --
  -- 80.1 ms is the measured worst frame at 512 samples and must still give two ticks --
  -- that is the whole point of the slack. 82 ms is past it and must give three, which is
  -- what stops the slack from quietly becoming a rule that always rounds down.
  return near(fftsa.tick_period(0.080), 0.10, 1e-9)
         and near(fftsa.tick_period(0.0801), 0.10, 1e-9)
         and near(fftsa.tick_period(0.085), 0.15, 1e-9)
         and near(fftsa.tick_period(0.040), 0.05, 1e-9)
         and near(fftsa.tick_period(0), 0.05, 1e-9),
         string.format('80 ms -> %.2f, 80.1 -> %.2f, 85 -> %.2f, 40 -> %.2f',
                       fftsa.tick_period(0.080), fftsa.tick_period(0.0801),
                       fftsa.tick_period(0.085), fftsa.tick_period(0.040))
end)())

-- The period is re-armed from frames that actually ran, not from frame_estimate(). The
-- model is a fit at one point count and one draw path: it predicted 80.4 ms at 512 and
-- 216 ms at 2048 against 212 measured. Divided by the occupancy target an error of that
-- size can land either side of a tick boundary, which is a 50 % swing in displayed rate. The mock's frames are far faster than the instrument's, so a
-- measured period must fall to the 0.05 s floor while the model still asks for 0.15 --
-- which is also what makes this fail if the re-arm is removed.
check('the timer period follows measured work, not the model', (function()
  display.setvalue(fftsa.opt_n, 1)
  if not fftsa.options_apply() then return false, fftsa.lasterr end
  local modelled = fftsa.period
  local i
  for i = 1, 10 do fftsa.frame() end
  local measured = fftsa.period
  fftsa.options_apply()
  return near(modelled, 0.10, 1e-9) and near(measured, 0.05, 1e-9)
         and measured < modelled,
         string.format('model armed %.2f, measurement armed %.2f', modelled, measured)
end)())

-- The trace buffer is FILL_ONCE by choice, not by default. The widget draws a
-- continuous-fill buffer as a WRAPPING trace, joining its newest point back to its
-- oldest: a straight line across the whole plot, with the buffer itself perfectly
-- aligned while that line is on the glass, so the line is the fill mode and not a
-- rotation.
check('the trace buffer is FILL_ONCE, never a ring', (function()
  display.setvalue(fftsa.opt_n, 1)
  if not fftsa.options_apply() then return false, fftsa.lasterr end
  return fftsa.sg_buf.fillmode == buffer.FILL_ONCE
         and buffer.FILL_ONCE ~= buffer.FILL_CONTINUOUS,
         string.format('fillmode=%s, continuous would be %s',
                       tostring(fftsa.sg_buf.fillmode),
                       tostring(buffer.FILL_CONTINUOUS))
end)())

-- sg_ncol is a live knob, and changing it must not touch the allocation: the buffer stays
-- at the 680 it was made with and the frame simply writes fewer points. This is what lets
-- the point count be traded against the frame rate from the socket instead of by
-- reinstalling, so it is asserted rather than assumed.
check('the point count can be changed without reallocating anything', (function()
  local keep = fftsa.sg_ncol
  local trace = fftsa.sg_buf
  local bufs0 = livebufs()
  local made = 0
  local realmake = buffer.make
  buffer.make = function(cap, style)
    if style == buffer.STYLE_WRITABLE_FULL then made = made + 1 end
    return realmake(cap, style)
  end
  fftsa.sg_ncol = 340
  fftsa.frame()
  local at340 = fftsa.sg_buf.n
  fftsa.sg_ncol = keep
  fftsa.frame()
  local restored = fftsa.sg_buf.n
  buffer.make = realmake
  return at340 == 340 and restored == keep and made == 0
         and fftsa.sg_buf == trace and livebufs() == bufs0
         and trace.capacity == fftsa.sg_maxpts,
         string.format('340 -> %d points, %d -> %d, allocations %d, capacity %d',
                       at340, keep, restored, made, trace.capacity)
end)())

-- THE WINDOW. The trace buffer is bound for the life of the app and refilled in place,
-- so it sits at n = 0 from the clear to the last write and a paint landing there draws a
-- blank or partial trace. Nothing can remove that window: the firmware needs the clear
-- before a FILL_ONCE buffer can be rewritten.
--
-- So the window is made as narrow as possible: every value is computed into preallocated
-- arrays BEFORE the clear, leaving only buffer.write.reading inside it. A point costs
-- about 109 us to produce and 51.6 of that is the write, so this is better than half.
--
-- Counting writes cannot see this: they land after the clear either way. Counting the dB
-- conversions can, because staging puts every log10 before it.
check('the refill stages every value before clearing, so only writes are in the window',
      (function()
  local buf = fftsa.sg_buf
  local w0 = WRITES
  fftsa.sg_update(fftsa.sg_nbins, fftsa.binhz)
  local staged_after = LOG10S - LOG10_AT_CLEAR
  local wrote_before = CLEAR_AT_WRITES - w0
  local wrote_after  = WRITES - CLEAR_AT_WRITES
  return staged_after == 0 and wrote_before == 0
         and wrote_after == fftsa.sg_nwrote and buf.n == fftsa.sg_nwrote,
         string.format('%d dB conversions inside the window, %d writes before the clear,'
                       .. ' %d after, n %d of %d', staged_after, wrote_before,
                       wrote_after, buf.n, fftsa.sg_nwrote)
end)())

-- ---------- the merge's own regressions, each failable by reverting one line ----------

-- F1. The pool refuses from the end of the create list, and opt_n / opt_info / the
-- preview timer are the last three objects build_options() makes. Unguarded, the raise
-- lands before changescreen and the Options button is dead for the life of the app.
check('a refused options handle does not kill the Options button', (function()
  local keepinfo, keepn = fftsa.opt_info, fftsa.opt_n
  local scr0 = display.active
  local r1 = fftsa.options()
  fftsa.show_main()
  fftsa.opt_info = nil                       -- settext raise site
  local r2 = fftsa.options()
  local after2 = display.active
  fftsa.show_main()
  fftsa.opt_info, fftsa.opt_n = keepinfo, nil   -- getvalue raise site
  local r3 = fftsa.options()
  local after3 = display.active
  fftsa.opt_n = keepn
  fftsa.show_main()
  return r1 and r2 and r3 and after2 == fftsa.optscr and after3 == fftsa.optscr,
         string.format('ok %s/%s/%s, screens %s/%s', tostring(r1), tostring(r2),
                       tostring(r3), tostring(after2 == fftsa.optscr),
                       tostring(after3 == fftsa.optscr))
end)())

-- F4. An off-list count can only arrive from a host assignment, but raising on it took
-- Options and Apply down together with no way back but End App.
check('an off-list sample count leaves Options and Apply working', (function()
  local keep = fftsa.n
  fftsa.n = 3000
  local opened = fftsa.options()
  local onscr = display.active == fftsa.optscr
  display.setvalue(fftsa.opt_n, 1)
  local applied = fftsa.options_apply()
  local landed = fftsa.n
  fftsa.n = keep
  display.setvalue(fftsa.opt_n, 1)
  fftsa.options_apply()
  return opened and onscr and applied and landed == 512,
         string.format('opened=%s applied=%s n=%s', tostring(opened),
                       tostring(applied), tostring(landed))
end)())

-- A field whose handle the pool never gave us costs that field and nothing else: the
-- reads test for nil and fall back, so the span still commits and the axis, the cover and
-- the message all describe the same one.
check('a missing field costs that field alone, and the span still commits', (function()
  local flo0, fhi0 = fftsa.flo, fftsa.fhi
  local keepn, n0 = fftsa.opt_n, fftsa.n
  display.setvalue(fftsa.opt_flo, 2000)
  display.setvalue(fftsa.opt_fhi, 30000)
  fftsa.opt_n = nil                          -- the handle the pool could not give us
  local ok = fftsa.options_apply()
  fftsa.opt_n = keepn
  local kept = fftsa.n == n0
  local moved = fftsa.flo == 2000 and fftsa.fhi == 30000
  display.setvalue(fftsa.opt_flo, flo0)
  display.setvalue(fftsa.opt_fhi, fhi0)
  fftsa.options_apply()
  return ok and kept and moved,
         string.format('ok=%s n %s->%s, span %g..%g', tostring(ok), tostring(n0),
                       tostring(fftsa.n), 2000, 30000)
end)())

-- F2. The refill clears the bound buffer before rewriting it, so a raise inside it does
-- empty the buffer -- and frame()'s recovery must NOT re-add a trace over the empty one,
-- because the firmware binds nothing to an empty buffer and the trace would then never
-- draw again, silently, with the peak table still updating. Skipping the re-add needs no
-- recovery: the trace was never removed, and the next good refill draws through the
-- binding it still has. Both halves are asserted, since a re-add that bound nothing
-- would leave every other check here looking healthy.
check('a refill that raises empties the buffer, and the next frame recovers', (function()
  display.setvalue(fftsa.opt_rng, 3)
  display.setvalue(fftsa.opt_n, 1)
  fftsa.options_apply()
  fftsa.errrun, fftsa.errcount = 0, 0
  local g = fftsa.sg_graph
  local adds0 = OBJ[g].adds
  local realwr = buffer.write.reading
  buffer.write.reading = function() error('refill-boom', 0) end
  fftsa.frame()
  buffer.write.reading = realwr
  local emptied = fftsa.sg_buf.n == 0 and fftsa.errrun > 0
  local noadd = OBJ[g].adds == adds0
  fftsa.frame()
  local bound = (OBJ[g].traces or 0) > 0 and OBJ[g].buffer == fftsa.sg_buf
  fftsa.errrun, fftsa.errcount = 0, 0
  return emptied and noadd and bound and fftsa.sg_buf.n > 0,
         string.format('emptied=%s re-added=%s bound=%s n=%d', tostring(emptied),
                       tostring(not noadd), tostring(bound), fftsa.sg_buf.n)
end)())

-- F8. Three quarters of the preview tracked the edit and the window label did not.
check('the preview line previews the window too, not the applied one', (function()
  local wi0 = fftsa.win_i
  local other = 1
  if wi0 == 1 then other = 2 end
  display.setvalue(fftsa.opt_win, fftsa.win_names[other])
  fftsa.options_preview()
  local shown = obj_at(fftsa.opt_info).text
  display.setvalue(fftsa.opt_win, fftsa.win_names[wi0])
  fftsa.options_preview()
  local wanted = fftsa.win_names[other]
  return string.find(shown, wanted, 1, true) ~= nil,
         'field=' .. wanted .. ' line=' .. tostring(shown)
end)())

-- T1. The hoist: sg_nbins has to describe the new size before the sg_set_xrange() at
-- the top of apply(), because the legend reports how many bins land in the span.
-- A 501 Hz span holds 2 bins at 512 samples and 82 at 16384, so the warning appears at
-- one size and not at the other. The match is on the warning's own words: the settings
-- line always carries a bin WIDTH, so a bare 'bin' matches either way.
check('the legend bin count follows a resize in the same Apply', (function()
  display.setvalue(fftsa.opt_flo, 1999)
  display.setvalue(fftsa.opt_fhi, 2500)
  display.setvalue(fftsa.opt_n, 1)
  fftsa.options_apply()
  local at512 = fftsa.sg_xunit_text()
  display.setvalue(fftsa.opt_n, 6)           -- 16384
  fftsa.options_apply()
  local at16k = fftsa.sg_xunit_text()
  local nb = fftsa.sg_nbins
  display.setvalue(fftsa.opt_n, 1)
  display.setvalue(fftsa.opt_flo, 1000)
  display.setvalue(fftsa.opt_fhi, 50000)
  fftsa.options_apply()
  return nb == 8192 and string.find(at512, 'only 2 bins in the span', 1, true) ~= nil
         and string.find(at16k, 'in the span', 1, true) == nil,
         '512: ' .. tostring(at512) .. ' | 16384: ' .. tostring(at16k)
end)())

-- F13. Three constants that have to agree and nothing said so.
-- ---------- the trace column cap ----------

-- The graph is 784 px wide, so above the cap the firmware is handed points to throw away
-- by a rule that can discard the bin a tone sits in.
check('the trace never exceeds the column cap at any sample count', (function()
  local worst, worstn = 0, 0
  local i
  for i = 1, table.getn(fftsa.sample_counts) do
    display.setvalue(fftsa.opt_n, i)
    if not fftsa.options_apply() then return false, fftsa.lasterr end
    fftsa.frame()
    if fftsa.sg_buf.n > worst then worst, worstn = fftsa.sg_buf.n, fftsa.sample_counts[i] end
    if fftsa.sg_buf.n > fftsa.sg_maxpts then
      return false, string.format('N=%d wrote %d > cap %d', fftsa.sample_counts[i],
                                  fftsa.sg_buf.n, fftsa.sg_maxpts)
    end
    if fftsa.sg_buf.n > fftsa.sg_buf.cap then
      return false, 'overran the buffer at N=' .. fftsa.sample_counts[i]
    end
  end
  display.setvalue(fftsa.opt_n, 1)
  fftsa.options_apply()
  return true, string.format('worst %d points at N=%d, cap %d', worst, worstn,
                             fftsa.sg_maxpts)
end)())

-- The default must be untouched: fewer bins in the span than columns, so every bin
-- is still its own point and the shipped appearance does not change.
-- At the default the span holds fewer bins than there are columns, so no bin can be
-- skipped: every one lands in at least one column. That is the resolution guarantee at
-- the default, and it is weaker at every larger size.
check('the default skips no bin in the span', (function()
  display.setvalue(fftsa.opt_rng, 3)
  display.setvalue(fftsa.opt_n, 1)
  fftsa.options_apply()
  fftsa.frame()
  local nb = fftsa.sg_nbins
  local kmin, kmax = fftsa.sg_window_bins(nb, fftsa.binhz)
  local npts = kmax - kmin + 1
  local ncol = fftsa.sg_ncol
  local seen = {}
  local c
  for c = 0, ncol - 1 do
    local a = kmin + math.floor(c * npts / ncol)
    seen[a] = true
  end
  local missing = 0
  local k
  for k = kmin, kmax do
    if seen[k] == nil then missing = missing + 1 end
  end
  return npts <= ncol and missing == 0 and fftsa.sg_buf.n == ncol,
         string.format('%d bins over %d columns, %d skipped, %d written',
                       npts, ncol, missing, fftsa.sg_buf.n)
end)())

-- The point of max-per-column: a tone in any bin reaches the trace. Stride sampling
-- would miss it, and so can the firmware's own decimation.
check('a tone survives decimation whatever bin it lands in', (function()
  display.setvalue(fftsa.opt_n, 6)                     -- 16384, 8192 bins
  if not fftsa.options_apply() then return false, fftsa.lasterr end
  local nb = fftsa.sg_nbins
  local kmin, kmax = fftsa.sg_window_bins(nb, fftsa.binhz)
  local pwr = fftsa.fft_pwr
  local keep = {}
  local j
  for j = kmin, kmax do keep[j] = pwr[j]; pwr[j] = 1e-18 end
  local tried, found, missed = 0, 0, -1
  local off
  for off = 0, 71 do                                   -- more than one column wide
    local k = kmin + 97 + off
    if k <= kmax then
      pwr[k] = 1.0                                     -- a lone 1 V^2 tone
      fftsa.sg_update(nb, fftsa.binhz)
      pwr[k] = 1e-18
      local want = (k - 1) * fftsa.binhz
      -- Within one column: the trace carries each column's own frequency, so a tone is
      -- drawn at its column rather than its bin. What must survive is the LEVEL --
      -- taking the column maximum is what guarantees a narrow tone is not dropped.
      local tol = 1.5 * fftsa.binhz * (kmax - kmin + 1) / fftsa.sg_ncol
      if tol < 1.5 * fftsa.binhz then tol = 1.5 * fftsa.binhz end
      local hit = false
      local q
      for q = 1, fftsa.sg_buf.n do
        if fftsa.sg_buf.readings[q] > -10
           and math.abs(fftsa.sg_buf.extra[q] - want) < tol then hit = true end
      end
      tried = tried + 1
      if hit then found = found + 1 elseif missed < 0 then missed = k end
    end
  end
  for j = kmin, kmax do pwr[j] = keep[j] end
  display.setvalue(fftsa.opt_n, 1)
  fftsa.options_apply()
  return tried > 0 and found == tried,
         string.format('%d of %d bin positions reached the trace, first miss at bin %d',
                       found, tried, missed)
end)())

-- The floor reads as a band, not as its upper envelope: min and max both present.
-- The guarantee, swept over every sample count AND a range of spans: the widget is
-- never handed more segments than the budget, whatever the column arithmetic does.
check('the widget never gets more than the point budget, any size or span', (function()
  local spans = {{10, 50000}, {10, 1000}, {1000, 2000}, {1999, 2000},
                 {10, 500000}, {100000, 500000}, {10, 100}}
  local worst, worstat = 0, ''
  local i, j
  for i = 1, table.getn(fftsa.sample_counts) do
    for j = 1, table.getn(spans) do
      display.setvalue(fftsa.opt_rng, 3)
      display.setvalue(fftsa.opt_flo, spans[j][1])
      display.setvalue(fftsa.opt_fhi, spans[j][2])
      display.setvalue(fftsa.opt_n, i)
      if not fftsa.options_apply() then return false, fftsa.lasterr end
      fftsa.frame()
      local n = fftsa.sg_buf.n
      if n > worst then
        worst = n
        worstat = string.format('N=%d span %g-%g', fftsa.sample_counts[i],
                                spans[j][1], spans[j][2])
      end
      if n > fftsa.sg_maxpts then
        return false, string.format('%s wrote %d > budget %d', worstat, n,
                                    fftsa.sg_maxpts)
      end
      -- The plotted area is 680 px, measured off a capture, so the budget is the column
      -- count and 680 -- one point per pixel -- is the top of the range worth trying.
      if n > 680 then
        return false, string.format('%s wrote %d > one point per pixel', worstat, n)
      end
      if fftsa.sg_nwrote ~= n then
        return false, string.format('%s counted %d but buffer holds %d', worstat,
                                    fftsa.sg_nwrote, n)
      end
    end
  end
  display.setvalue(fftsa.opt_flo, 10)
  display.setvalue(fftsa.opt_fhi, 50000)
  display.setvalue(fftsa.opt_n, 1)
  fftsa.options_apply()
  return worst <= fftsa.sg_maxpts and worst <= 680,
         string.format('worst %d of budget %d at %s, over %d configurations', worst,
                       fftsa.sg_maxpts, worstat,
                       table.getn(fftsa.sample_counts) * table.getn(spans))
end)())

-- The budget must also hold if the column arithmetic is wrong, so it is enforced by a
-- counter rather than inferred: raise ncol past the budget and the budget still wins.
-- sg_ncol is settable while the app runs, so a value past capacity has to be CLAMPED,
-- not merely survived. The frame completing is the assertion that matters: writing one
-- point past a FILL_ONCE buffer is event 4915, a modal dialog, and a dialog per frame is
-- as impossible to exit as one per point. The buffer's n cannot see it: clamped or
-- overrun, n ends at capacity either way.
check('a column count past capacity is clamped, not refused', (function()
  local keep = fftsa.sg_ncol
  fftsa.sg_ncol = 4096
  display.setvalue(fftsa.opt_n, 6)
  fftsa.options_apply()
  fftsa.errrun, fftsa.errcount = 0, 0
  fftsa.frame()
  local failed, err = fftsa.errrun, fftsa.lasterr
  local wrote = fftsa.sg_nwrote
  local n = fftsa.sg_buf.n
  fftsa.sg_ncol = keep
  display.setvalue(fftsa.opt_n, 1)
  fftsa.options_apply()
  fftsa.errrun, fftsa.errcount = 0, 0
  return failed == 0 and wrote == 680 and n <= fftsa.sg_maxpts and n <= 680,
         string.format('ncol=4096 wrote %s points, n=%d, budget %d, errrun %d (%s)',
                       tostring(wrote), n, fftsa.sg_maxpts, failed, tostring(err))
end)())

-- Repeated refills rewrite the SAME buffer, with the trace never detached and never
-- re-added. Over three frames: one frame cannot tell a binding that holds from one that
-- is re-added every other frame, which on the glass flickers the axes at half the rate.
check('repeated refills rewrite the same buffer, with no rebinding', (function()
  display.setvalue(fftsa.opt_rng, 3)
  display.setvalue(fftsa.opt_n, 1)
  if not fftsa.options_apply() then return false, fftsa.lasterr end
  fftsa.frame()
  local buf = fftsa.sg_buf
  local o = OBJ[fftsa.sg_graph]
  local adds, removes = (o.adds or 0), (o.removes or 0)
  fftsa.sg_update(fftsa.sg_nbins, fftsa.binhz)
  fftsa.sg_update(fftsa.sg_nbins, fftsa.binhz)
  return fftsa.sg_buf == buf
         and (o.adds or 0) == adds and (o.removes or 0) == removes
         and o.buffer == buf and buf.n == fftsa.sg_ncol,
         string.format('same buffer=%s, adds %d/%d, removes %d/%d, n %d of %d',
                       tostring(fftsa.sg_buf == buf), (o.adds or 0), adds,
                       (o.removes or 0), removes, buf.n, fftsa.sg_ncol)
end)())

check('a decimated refill writes no non-monotonic timestamp', (function()
  local i
  local worst = 0
  NONMONO = 0
  for i = 1, table.getn(fftsa.sample_counts) do
    display.setvalue(fftsa.opt_n, i)
    if not fftsa.options_apply() then return false, fftsa.lasterr end
    local before = NONMONO
    fftsa.frame()
    if NONMONO > before then
      return false, string.format('N=%d produced %d non-monotonic writes'
                                  .. ' (binhz %g, span %g-%g, cap %d)',
                                  fftsa.sample_counts[i],
                                  NONMONO - before, fftsa.binhz, fftsa.sg_flo_hz,
                                  fftsa.sg_fhi_hz, fftsa.sg_ncol)
    end
    if fftsa.sg_buf.n > worst then worst = fftsa.sg_buf.n end
  end
  local bad = NONMONO
  display.setvalue(fftsa.opt_n, 1)
  fftsa.options_apply()
  NONMONO = 0
  return bad == 0, string.format('%d non-monotonic writes, worst refill %d points',
                                 bad, worst)
end)())

-- opt_nf is NOT the sample count; it was equal to it by coincidence at six fields.
check('sample_counts and sample_labels agree',
      table.getn(fftsa.sample_counts) == table.getn(fftsa.sample_labels),
      string.format('counts=%d labels=%d opt_nf=%d',
                    table.getn(fftsa.sample_counts),
                    table.getn(fftsa.sample_labels), fftsa.opt_nf))

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

-- The pool-exhaustion path is the one show_error exists for, and the one that can blank
-- the panel: display.create returns nil, every child goes to a nil parent and
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
      and fftsa.optimg == nil and fftsa.lockbtn == nil and fftsa.lockimg_c == nil
      and fftsa.lockimg_o == nil
      and fftsa.opt_n == nil
      and fftsa.timer == nil and fftsa.cap == nil and fftsa.sg_buf == nil
      and fftsa.aboutscr == nil and fftsa.about_lines == nil)
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

-- A REFUSED DELETE IS NOT A RAISE. The firmware posts an event and returns, and the
-- buffer stays ALIVE -- which is what put 61 live buffers on the instrument when a bound
-- buffer was remade without detaching it first, and drew two overlaid traces on the
-- glass. So the thing worth asserting is not that the app catches something, it is that
-- a delete is refused while bound and succeeds once detached.
-- An exhausted display object pool is a RETURN, not a raise: display.create answers nil
-- and posts one event. Before, the app raised on it and start()'s boundary reported the
-- message; now sg_build answers nil and a reason, which start() has to read. A return
-- nobody reads is worse than a raise, and nothing else in this suite exercises the path,
-- so this is the check that the reason still reaches the operator.
check('an exhausted object pool fails the start with a reason, and cleans up', (function()
  local objects0, buffers0 = live(), livebufs()
  fftsa.stop()
  fftsa.sg_destroy()
  fftsa.destroy_options()
  local realcreate = display.create
  -- Refuse only the spectrum screen, which is what sg_build tests for.
  display.create = function(parent, kind, ...)
    if kind == display.OBJ_SCREEN and arg[1] == 'FFT SPECTRUM ANALYSER' then return nil end
    return realcreate(parent, kind, unpack(arg))
  end
  local started = fftsa.start()
  display.create = realcreate
  local said = string.find(tostring(fftsa.lasterr), 'pool exhausted', 1, true) ~= nil
  local cleaned = live('timer') == 0
  local ok = fftsa.start()                       -- and it recovers afterwards
  return started == false and said and cleaned and ok,
         string.format('started=%s reason=%s timers-after-fail=%s recovered=%s',
                       tostring(started), tostring(fftsa.lasterr), tostring(cleaned),
                       tostring(ok))
end)())

check('a buffer bound to a graph is not deleted, and goes once detached', (function()
  local before = REFUSED_BUF_DELETES
  -- At the firmware's floor, not under it: a capacity below BUF_MIN is refused and
  -- answers nil, which is a raise here rather than the refusal this check is about.
  local b = buffer.make(BUF_MIN, buffer.STYLE_WRITABLE_FULL)
  local g = display.create(fftsa.loadscr, display.OBJ_GRAPH, 0, 0, 120, 100)
  fftsa.sg_write_point(b, -20, 1, 1)
  display.graph.add(g, b, display.ELEMENT_DATA, b, display.ELEMENT_EXTRA)
  fftsa.del_buf(b)
  local alive_while_bound = b.alive
  local counted = REFUSED_BUF_DELETES == before + 1
  display.graph.removeall(g)
  fftsa.del_buf(b)
  local freed = not b.alive
  display.delete(g)
  return alive_while_bound and counted and freed,
         string.format('alive while bound=%s, refusals %d->%d, freed after detach=%s',
                       tostring(alive_while_bound), before, REFUSED_BUF_DELETES,
                       tostring(freed))
end)())

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
  -- output pinned against the app. Bin 1 is 1.3e-29 where an arithmetic mean leaves
  -- 1.07e-04: that zero IS the weighted mean working.
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
