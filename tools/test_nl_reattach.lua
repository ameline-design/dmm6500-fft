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
-- the `_stor_of == buf` test fails, describe() discards a still-valid address and sweeps --
-- a sweep that came back empty on the instrument and halted every second launch. Asserted on
-- identity, because a copy of the handle would not compare equal to the live buffer.
check('carries describe()\'s capture-buffer cache, key included', (function()
  local cap = live_buffer()
  fftsa.nl._stor_of, fftsa.nl._stor_x = cap, false
  fftsa.nl._stor_elem0, fftsa.nl._stor_stride = 60176864, 24
  fftsa.nl._desc_of, fftsa.nl._desc_at = 60176864, 60242432
  fftsa.nl.stash()
  return NLSTASH._stor_of == cap and NLSTASH._stor_x == false
         and NLSTASH._stor_elem0 == 60176864 and NLSTASH._stor_stride == 24
         and NLSTASH._desc_of == 60176864 and NLSTASH._desc_at == 60242432,
         string.format('key=%s elem0=%s stride=%s desc=%s/%s x=%s',
                       tostring(NLSTASH._stor_of == cap), tostring(NLSTASH._stor_elem0),
                       tostring(NLSTASH._stor_stride), tostring(NLSTASH._desc_of),
                       tostring(NLSTASH._desc_at), tostring(NLSTASH._stor_x))
end)())
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

print()
print(string.format('%d passed, %d failed', pass, fail))
os.exit(fail == 0 and 0 or 1)
