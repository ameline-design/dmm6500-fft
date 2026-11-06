-- Gates for keeping a native install across a relaunch.
--
-- fftsa.nl.reattach resumes the install this boot already made, so a second launch in one
-- power cycle runs compiled rather than falling back to dsp.spectrum. Everything it does
-- afterwards is a call into heap addresses, so what matters here is that it REFUSES
-- whenever it cannot prove those addresses are still ours. Each of the four proofs is
-- withdrawn in turn, and a proof that stops being consulted fails this.
--
-- tools/test_tsp.lua runs with no nl module loaded at all, which is why this is its own
-- file: native_link.tsp is loaded here directly against stubs.
--
--     ~/tmp/lua502/lua-5.0.2/bin/lua tools/test_nl_reattach.lua

local pass, fail = 0, 0
local function check(name, cond, note)
  if cond then
    pass = pass + 1
    print('  PASS  ' .. name .. (note and ('   ' .. note) or ''))
  else
    fail = fail + 1
    print('  FAIL  ' .. name .. (note and ('   ' .. note) or ''))
  end
end

fftsa, ki, buffer, display, dmm = {}, {}, {}, {}, {}
assert(loadfile('tsp/native_link.tsp'))()
local nl = fftsa.nl
assert(type(nl.reattach) == 'function')
assert(type(nl.stash) == 'function')

-- The install, as it would stand after a successful init: two live buffers, the
-- trampoline's own bytes in the heap where it was placed, and the params address in the
-- image's slot.
-- Decimal, not hex: Lua 5.0.2 rejects a hex literal at parse time.
local TRAMP_AT, CODE_BASE, PARAMS, ENTRY = 54525952, 54591488, 54657024, 54591488
nl.PARAMS_SLOT = nl.PARAMS_SLOT or 31272

local MEM = {}                     -- address -> string, for memread
local WORDS = {}                   -- address -> number, for peek32
local function reset_heap()
  MEM = {[TRAMP_AT] = nl._TRAMP}
  WORDS = {[CODE_BASE + nl.PARAMS_SLOT] = PARAMS}
end

ki.memread = function(addrhex, lenhex)
  local a = tonumber(addrhex, 16)
  local n = tonumber(lenhex, 16)
  local s = MEM[a]
  if s == nil then return string.rep('\0', n) end
  return string.sub(s, 1, n)
end
ki.peek32 = function(addrhex)
  local w = WORDS[tonumber(addrhex, 16)]
  return string.format('%X', w or 0)
end

local function live_buffer(cap)
  return {capacity = cap or 1024}
end
local function dead_buffer()
  -- A buffer the firmware has dropped raises on a capacity read, which is the only
  -- liveness test there is. The mock has to raise where the firmware raises or the
  -- liveness check is untested by construction.
  return setmetatable({}, {__index = function() error('buffer deleted', 0) end})
end

local function fresh_stash()
  -- The constants come from the stash rather than from nl, because a relaunch reloads the
  -- modules in an order reattach has no business depending on: native_code.tsp carries
  -- PARAMS_SLOT and may not be back yet. So they are part of what stash() must save, and
  -- this mirrors that.
  return {entry = ENTRY, params = PARAMS, tramp = TRAMP_AT, code_base = CODE_BASE,
          code_buf = live_buffer(), plan_buf = live_buffer(),
          PARAMS_SLOT = nl.PARAMS_SLOT, TRAMP_RANGE = nl.TRAMP_RANGE,
          _TRAMP = nl._TRAMP,
          n = 2048, nmax = 16384, kind = 1, beta = 0, decim = 1, method = 1,
          fn = {sin = 4651068, cos = 4654344}}
end

-- reinit is the call into the installed code. Counted rather than performed, so a refusal
-- that happens to leave ready set cannot pass by accident.
local replans
local function arm_reinit(result)
  replans = 0
  nl.reinit = function()
    replans = replans + 1
    nl.ready = result
    return result
  end
end

local function try(mutate)
  reset_heap()
  NLSTASH = fresh_stash()
  if mutate then mutate(NLSTASH) end
  nl.ready, nl.reattached = false, nil
  arm_reinit(true)
  local got = nl.reattach(2048, 1, 0, 1, 1)
  return got, nl.ready, replans
end

print('\nnl.reattach')

local ok, ready, n = try(nil)
check('resumes an install whose heap still matches, and re-plans once',
      ok == true and ready == true and n == 1,
      string.format('ok=%s ready=%s replans=%d', tostring(ok), tostring(ready), n))

ok, ready, n = try(function(s) s.code_buf = dead_buffer() end)
check('refuses when the code buffer has been dropped',
      ok == false and ready == false and n == 0,
      string.format('ok=%s replans=%d', tostring(ok), n))

ok, ready, n = try(function(s) s.plan_buf = dead_buffer() end)
check('refuses when the plan buffer has been dropped',
      ok == false and ready == false and n == 0,
      string.format('ok=%s replans=%d', tostring(ok), n))

ok, ready, n = try(function(s)
  -- The image overwritten by whatever took the heap next: one byte of CODE is enough, and
  -- it has to be code rather than one of the range words. Byte 20 is inside the body.
  MEM[s.tramp] = string.sub(nl._TRAMP, 1, 19) .. '\255' .. string.sub(nl._TRAMP, 21)
end)
check('refuses when the trampoline code no longer matches the literal',
      ok == false and ready == false and n == 0,
      string.format('ok=%s replans=%d', tostring(ok), n))

ok, ready, n = try(function(s)
  -- The entry branch at the very front, which a whole-image compare would also catch but
  -- a compare that skipped too much would not.
  MEM[s.tramp] = '\255' .. string.sub(nl._TRAMP, 2)
end)
check('refuses when the entry branch has been overwritten',
      ok == false and ready == false and n == 0,
      string.format('ok=%s replans=%d', tostring(ok), n))

-- And the other way: the two range words at TRAMP_RANGE are the trampoline's arguments,
-- written by nl.flush before every call, so the literal's zeros there are stale from the
-- first flush onwards. A compare that includes them refuses every real install -- which is
-- what it did on the instrument, and the reason this case exists.
ok, ready, n = try(function(s)
  local r = nl.TRAMP_RANGE
  MEM[s.tramp] = string.sub(nl._TRAMP, 1, r) .. '\018\052\086\120\000\000\001\000'
                 .. string.sub(nl._TRAMP, r + 9)
end)
check('accepts an install whose range words hold the last flush',
      ok == true and ready == true and n == 1,
      string.format('ok=%s ready=%s replans=%d', tostring(ok), tostring(ready), n))

ok, ready, n = try(function(s) WORDS[s.code_base + nl.PARAMS_SLOT] = PARAMS + 32 end)
check('refuses when the params slot holds a different address',
      ok == false and ready == false and n == 0,
      string.format('ok=%s replans=%d', tostring(ok), n))

ok, ready, n = try(function(s) s.PARAMS_SLOT = nil end)
check('refuses a stash without the generated constants it has to compare against',
      ok == false and ready == false and n == 0,
      string.format('ok=%s replans=%d', tostring(ok), n))

ok, ready, n = try(function(s) s._TRAMP = nil end)
check('refuses a stash without the trampoline literal',
      ok == false and ready == false and n == 0,
      string.format('ok=%s replans=%d', tostring(ok), n))

ok, ready, n = try(function(s) s.tramp = nil end)
check('refuses a stash with an address missing',
      ok == false and ready == false and n == 0,
      string.format('ok=%s replans=%d', tostring(ok), n))

reset_heap()
NLSTASH = nil
arm_reinit(true)
check('refuses when there is no stash at all',
      nl.reattach(2048) == false and replans == 0)

-- A re-plan that the installed code rejects is a refusal, not a half-ready state: the
-- count may be above what the arena was sized for, and the app has to end up on the
-- interpreted path rather than calling a plan that was never built.
reset_heap()
NLSTASH = fresh_stash()
nl.ready = false
arm_reinit(false)
ok = nl.reattach(2048)
check('refuses, and leaves ready clear, when the re-plan fails',
      ok == false and nl.ready == false and replans == 1,
      string.format('ok=%s ready=%s', tostring(ok), tostring(nl.ready)))

print('\nnl.stash')

-- The stash is what the next launch restores from, so it has to carry the addresses and
-- the buffers and must NOT carry functions: those come from the module being loaded, and
-- copying them back would run the previous build's Lua.
fftsa.nl.entry, fftsa.nl.params, fftsa.nl.tramp = ENTRY, PARAMS, TRAMP_AT
fftsa.nl.code_buf, fftsa.nl.plan_buf = live_buffer(), live_buffer()
fftsa.nl.fn = {sin = 4651068}
fftsa.nl.stash()
check('carries the addresses, the buffers and the resolved math table',
      NLSTASH.entry == ENTRY and NLSTASH.params == PARAMS and NLSTASH.tramp == TRAMP_AT
      and NLSTASH.code_buf == fftsa.nl.code_buf
      and NLSTASH.plan_buf == fftsa.nl.plan_buf
      and NLSTASH.fn ~= nil and NLSTASH.fn.sin == 4651068
      and NLSTASH.fn ~= fftsa.nl.fn)
-- describe()'s cache survives a relaunch only if its KEY does. The address it caches is a
-- number and rides along as a scalar; the key is the capture buffer's handle, and without it
-- the `_stor_of == buf` test fails and describe() discards a still-valid address and sweeps.
--
-- The slot is a SINGLE shared one, so which buffer's key a stash carries is decided by when
-- the stash is taken and not by the handle list. Both orders are driven, because asserting
-- only the second one passes while the app -- which stashes in the first order -- fails.
local CAP, PLAN = live_buffer(65536), live_buffer(28672)
local CAP_E0, PLAN_E0 = 60831232, 60176864
local function describe_slot(buf, elem0, stride)
  fftsa.nl._stor_of, fftsa.nl._stor_x = buf, false
  fftsa.nl._stor_elem0, fftsa.nl._stor_stride = elem0, stride
  fftsa.nl._desc_of, fftsa.nl._desc_at = elem0, elem0 + 65568
end

-- nl.init's order: the plan buffer is the last thing it describes, and the stash is its last
-- act. So a stash taken there carries the plan buffer however long the handle list grows.
describe_slot(PLAN, PLAN_E0, 32)
fftsa.nl.stash()
check('a stash taken before the capture is described carries the other buffer',
      NLSTASH._stor_of == PLAN and NLSTASH._stor_elem0 == PLAN_E0,
      string.format('capacity=%s elem0=%s',
                    tostring(NLSTASH._stor_of.capacity), tostring(NLSTASH._stor_elem0)))

-- fftsa.nl_bind's order: re-taken once the capture buffer is the described one.
describe_slot(CAP, CAP_E0, 24)
fftsa.nl.stash()
check('carries describe()\'s capture-buffer cache, key included',
      NLSTASH._stor_of == CAP and NLSTASH._stor_x == false
      and NLSTASH._stor_elem0 == CAP_E0 and NLSTASH._stor_stride == 24
      and NLSTASH._desc_of == CAP_E0 and NLSTASH._desc_at == CAP_E0 + 65568,
      string.format('key=%s elem0=%s stride=%s desc=%s/%s x=%s',
                    tostring(NLSTASH._stor_of == CAP), tostring(NLSTASH._stor_elem0),
                    tostring(NLSTASH._stor_stride), tostring(NLSTASH._desc_of),
                    tostring(NLSTASH._desc_at), tostring(NLSTASH._stor_x)))
check('carries no functions',
      (function()
        local k, v
        for k, v in pairs(NLSTASH) do
          if type(v) == 'function' then return false, k end
        end
        return true
      end)())
check('carries the constants the next launch compares against, whatever reloads first',
      NLSTASH._TRAMP == fftsa.nl._TRAMP
      and NLSTASH.TRAMP_RANGE == fftsa.nl.TRAMP_RANGE
      and NLSTASH.PARAMS_SLOT == fftsa.nl.PARAMS_SLOT)

-- And the far end of the same path: carrying the cache is only worth anything if a relaunch
-- puts it back on a module table that reloaded without it. _stor_x is asserted against false
-- rather than merely being present, because describe() compares it to has_extras and a nil
-- there misses the cache for a STYLE_STANDARD buffer exactly as a wrong key would.
print('\nnl.reattach restores the cache')

reset_heap()
NLSTASH = fresh_stash()
NLSTASH._stor_of, NLSTASH._stor_x = CAP, false
NLSTASH._stor_elem0, NLSTASH._stor_stride = CAP_E0, 24
NLSTASH._desc_of, NLSTASH._desc_at = CAP_E0, CAP_E0 + 65568
fftsa.nl._stor_of, fftsa.nl._stor_x = nil, nil
fftsa.nl._stor_elem0, fftsa.nl._stor_stride = nil, nil
fftsa.nl._desc_of, fftsa.nl._desc_at = nil, nil
nl.ready, nl.reattached = false, nil
arm_reinit(true)
local rok = nl.reattach(2048, 1, 0, 1, 1)
check('puts all six cache fields back on a cold module table',
      rok == true and nl._stor_of == CAP and nl._stor_x == false
      and nl._stor_elem0 == CAP_E0 and nl._stor_stride == 24
      and nl._desc_of == CAP_E0 and nl._desc_at == CAP_E0 + 65568,
      string.format('ok=%s key=%s elem0=%s stride=%s x=%s',
                    tostring(rok), tostring(nl._stor_of == CAP), tostring(nl._stor_elem0),
                    tostring(nl._stor_stride), tostring(nl._stor_x)))

-- A refusal must not leave a key behind: the addresses it names were validated by the same
-- checks that just failed, and describe() would hit the cache rather than sweep.
fftsa.nl._stor_of, fftsa.nl._stor_elem0 = nil, nil
ok, ready, n = try(function(s)
  s.code_buf = dead_buffer()
  s._stor_of, s._stor_x, s._stor_elem0, s._stor_stride = CAP, false, CAP_E0, 24
end)
check('a refused reattach installs no cache key',
      ok == false and nl._stor_of == nil and nl._stor_elem0 == nil,
      string.format('ok=%s key=%s elem0=%s',
                    tostring(ok), tostring(nl._stor_of), tostring(nl._stor_elem0)))

print('\nnl._find_storage')

-- A STYLE_STANDARD element is 24 bytes, and a quiet capture's first two readings are often
-- identical at 4.5 digits. The discovered-offset loop is skipped in that case -- with every
-- reading equal, every offset would match and the list would fill with noise -- so 24 has to
-- be a standing candidate or the capture buffer cannot be found at all.
--
-- 32 is left failing against the mock exactly as it fails against a real 24-byte element, so
-- these drive the stride selection rather than merely reaching a hit. FINDS is stubbed: the
-- defect is in the candidate list, and sweeping 32 MB of mock heap would prove nothing more.
local FINDS_REAL = fftsa.nl.FINDS
local SELEM0 = 60831232
local function place(stride, vals)
  reset_heap()
  local i, v
  for i, v in pairs(vals) do
    local hi, lo = fftsa.nl._f64_words(v)
    WORDS[SELEM0 + (i - 1) * stride] = hi
    WORDS[SELEM0 + (i - 1) * stride + 4] = lo
  end
  fftsa.nl.FINDS = function() return {SELEM0} end
end
local function readings(r1, r2)
  local v = {r1, r2, 0.25, 0.375, 0.5, 0.625}
  v[64], v[256] = 1.5, 2.5
  return v
end

local QUIET = readings(0.125, 0.125)
place(24, QUIET)
local e0, st = fftsa.nl._find_storage({n = 2048, readings = QUIET}, false)
check('finds a 24-byte element whose first two readings are identical',
      e0 == SELEM0 and st == 24,
      string.format('elem0=%s stride=%s why=%s',
                    tostring(e0), tostring(st), tostring(fftsa.nl._stor_why)))

local LIVE = readings(0.125, 0.1875)
place(24, LIVE)
e0, st = fftsa.nl._find_storage({n = 2048, readings = LIVE}, false)
check('still finds one whose readings all differ',
      e0 == SELEM0 and st == 24,
      string.format('elem0=%s stride=%s', tostring(e0), tostring(st)))

-- And not promiscuous: a standing candidate must not confirm an element it does not match.
place(40, QUIET)
e0, st = fftsa.nl._find_storage({n = 2048, readings = QUIET}, false)
check('confirms no stride for an element size it does not know, and says why',
      e0 == nil and fftsa.nl._stor_why ~= nil
      and string.find(fftsa.nl._stor_why, 'no stride confirmed', 1, true) ~= nil,
      string.format('elem0=%s why=%s', tostring(e0), tostring(fftsa.nl._stor_why)))

place(24, QUIET)
e0, st = fftsa.nl._find_storage({n = 3, readings = QUIET}, false)
check('refuses a record shorter than the confirmation, and says which term',
      e0 == nil and fftsa.nl._stor_why ~= nil
      and string.find(fftsa.nl._stor_why, 'short record', 1, true) ~= nil,
      string.format('elem0=%s why=%s', tostring(e0), tostring(fftsa.nl._stor_why)))

fftsa.nl.FINDS = FINDS_REAL

print()
print(string.format('%d passed, %d failed', pass, fail))
os.exit(fail == 0 and 0 or 1)
