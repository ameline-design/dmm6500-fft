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
-- The sweep anchors on what tostring() gives a fresh table, which on the instrument is a
-- heap address from the same allocator that placed the buffers. Under the host interpreter it
-- is a host address nowhere near the fixtures below, so the harness supplies one: without it
-- every storage and descriptor case sweeps a window that cannot contain its own fixture and
-- answers nil, which is the same symptom a DMM7510 showed for the same reason.
local HOST_TOSTR = tostring
local MOCK_ANCHOR = 55890248          -- TRUE_E0, so the near window brackets every fixture
tostring = function(v)
  if type(v) == 'table' and next(v) == nil then
    return 'table: ' .. string.format('%x', MOCK_ANCHOR)
  end
  return HOST_TOSTR(v)
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
  nl.ready = false
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
nl.ready = false
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

-- geom_ok reads a CHUNK BOUNDARY -- element 1638 at perchunk 1638 -- so a six-entry table
-- cannot answer it. A metatable supplies a deterministic value for every other index, and
-- place_geom writes those same values at the addresses a stated geometry puts them at, so
-- the fixture has one source of truth and the code under test has to agree with it.
local function densify(v, n)
  setmetatable(v, {__index = function(_, i)
    if type(i) ~= 'number' or i < 1 or i > n then return nil end
    return 0.00390625 * i          -- exact in binary, so the f64 round trip is bit-exact
  end})
  return v
end

-- Every index geom_ok will look at, written where es/pc/vec put it. Only those indices,
-- because the WORDS model would otherwise need 130,000 entries for a 65,536-element record.
-- The arithmetic is restated here rather than shared with the module: that is what makes the
-- negative cases below able to place a record at one geometry and claim another.
local function place_geom(elem0, es, pc, vecaddr, n, v)
  local idx, ni, j = {}, 0, 0
  while j < n do ni = ni + 1; idx[ni] = j; j = j + pc end
  local l0 = pc - 1
  if l0 >= n then l0 = n - 1 end
  if l0 > 0 then ni = ni + 1; idx[ni] = l0 end
  local i
  for i = 1, ni do
    j = idx[i]
    local k = math.floor(j / pc)
    local base = elem0
    if k > 0 then base = WORDS[vecaddr + k * 4] end
    if base ~= nil then
      local hi, lo = fftsa.nl._f64_words(v[j + 1])
      WORDS[base + math.mod(j, pc) * es] = hi
      WORDS[base + math.mod(j, pc) * es + 4] = lo
    end
  end
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

print('\nnl.describe on an all-identical record')

-- The capture holds whatever was on the input, and on a quiet or shorted input every
-- reading can be the same value. A content scan cannot then tell one chunk of that buffer
-- from another -- confirmation at any stride passes everywhere -- so it answers with the
-- lowest-addressed chunk, which is not chunk 0 and which no descriptor references.
--
-- Measured: readings 1 and 2 both -1.0912892195e-06, the scan answering 0x3545240 against a
-- true element 0 of 0x354D148, low by exactly one chunk. These use those addresses.
local TRUE_E0, LOW_E0 = 55890248, 55857728    -- 0x354D148, 0x3545240
local DESC = 55959912                          -- 0x355D168
local SAME = -1.0912892195e-06

-- The descriptor as _read_desc validates it: storage pointer at +0x48, both owner
-- self-pointers, and the geometry of a 24-byte element in a 32768-byte chunk payload.
-- D is the layout to place it at, and defaults to the DMM6500's. A DMM7510's record is the
-- same fields with eight bytes gone ahead of the chunk vector, so the cases below place one
-- at either set rather than spelling two sets of numbers out.
local VEC = 56000000
local function place_desc(base, elem0, elemsize, perchunk, nchunks, cap, n, D)
  D = D or fftsa.nl.DOFF
  WORDS[base + D.stor] = elem0
  WORDS[base + D.s1] = base
  WORDS[base + D.s2] = base
  WORDS[base + D.es] = elemsize
  WORDS[base + D.pc] = perchunk
  WORDS[base + D.nc] = nchunks
  WORDS[base + D.vec] = VEC
  WORDS[base + D.cap] = cap
  WORDS[base + D.cap + 4] = n
  -- Real entries, because describe walks every one and refuses a zero.
  local i
  for i = 1, nchunks do
    WORDS[VEC + (i - 1) * 4] = elem0 + (i - 1) * 32784
  end
end

reset_heap()
place_desc(DESC, TRUE_E0, 24, 1365, 49, 65536, 2048)
-- The signature needle is capacity then n as adjacent big-endian words, so the hit lands on
-- the capacity field and the descriptor base is 0x74 below it. Matched on CONTENT, not on
-- length: a packed double is eight bytes too, so a length test would answer the content
-- scan's needle with the descriptor's hit and prove nothing.
local SIGPAT = string.char(0, 1, 0, 0, 0, 0, 8, 0)    -- capacity 65536, n 2048
fftsa.nl.FINDS = function(lo, hi, pat)
  if pat == SIGPAT then return {DESC + 116} end
  return {LOW_E0}
end
local flat = {SAME, SAME, SAME, SAME, SAME, SAME}
flat[64], flat[256] = SAME, SAME
densify(flat, 65536)
place_geom(TRUE_E0, 24, 1365, VEC, 2048, flat)
local CAPBUF = {n = 2048, capacity = 65536, readings = flat}

local d = fftsa.nl.describe(CAPBUF, false)
check('resolves element 0 from the descriptor, not from the identical readings',
      d ~= nil and d.chunk1 == TRUE_E0 and d.elemsize == 24,
      string.format('chunk1=%s elemsize=%s why=%s',
                    d and string.format('%X', d.chunk1) or 'nil',
                    d and tostring(d.elemsize) or 'nil', tostring(fftsa.nl._stor_why)))

check('does not answer with the chunk the content scan would have found',
      d ~= nil and d.chunk1 ~= LOW_E0,
      string.format('chunk1=%s low=%X', d and string.format('%X', d.chunk1) or 'nil', LOW_E0))

-- A buffer that carries extras is one we seeded ourselves, so it keeps the content route
-- and the install path is untouched. The signature hit is left reachable to prove the
-- has_extras gate is what excludes it rather than the mock.
fftsa.nl._stor_of = nil
reset_heap()
place_desc(DESC, TRUE_E0, 24, 1365, 49, 65536, 2048)
place_geom(TRUE_E0, 24, 1365, VEC, 2048, flat)
local probed = 0
local REAL_FS = fftsa.nl._find_storage
fftsa.nl._find_storage = function(b, x) probed = probed + 1; return REAL_FS(b, x) end
fftsa.nl.describe({n = 2048, capacity = 65536, readings = flat,
                   extravalues = {1, 2, 3}}, true)
fftsa.nl._find_storage = REAL_FS
check('a buffer with extras still goes through the content scan',
      probed == 1, string.format('content scans=%d', probed))

-- AND THE OTHER HALF OF THE SAME QUESTION: the signature route must not depend on the flat
-- record it was written for. A live capture's readings all differ, which is the case the
-- content scan already handled, so the two routes have to agree there -- otherwise fixing
-- the shorted input would have broken the working one.
--
-- FINDS is modelled on the needle's meaning rather than returning a fixed list: it answers
-- a signature pattern with every descriptor whose capacity and n pack to it. That is what
-- lets a decoy buffer be placed and proved unreachable.
local function u32be(v)
  return string.char(math.floor(v / 16777216), math.mod(math.floor(v / 65536), 256),
                     math.mod(math.floor(v / 256), 256), math.mod(v, 256))
end
local function sigof(cap, n) return u32be(cap) .. u32be(n) end

local DESCS, READHIT = {}, nil
fftsa.nl.FINDS = function(lo, hi, pat)
  local out, m, i = {}, 0, nil
  -- A four-byte needle is _find_desc looking for the storage address, so it is answered the
  -- way the instrument answers it: every word in the heap that holds that value. That is
  -- more than the descriptor -- entry 0 of the chunk vector holds it too -- which is why a
  -- real sweep reports several raw hits and only one confirmed.
  if string.len(pat) == 4 then
    -- One call a byte: Lua 5.0.2's string.byte returns a single value, and the range form
    -- that would give four is 5.1.
    local want = string.byte(pat, 1) * 16777216 + string.byte(pat, 2) * 65536
                 + string.byte(pat, 3) * 256 + string.byte(pat, 4)
    local a, v
    for a, v in pairs(WORDS) do
      if v == want then m = m + 1; out[m] = a end
    end
    return out
  end
  for i = 1, table.getn(DESCS) do
    local dd = DESCS[i]
    -- capoff, because the hit lands on the capacity field and which offset that is is per
    -- layout: a DMM7510 holds it at 0x6C.
    if pat == sigof(dd.cap, dd.n) then m = m + 1; out[m] = dd.base + (dd.capoff or 116) end
  end
  if m > 0 then return out end
  if READHIT ~= nil then return {READHIT} end
  return {}
end

local function place_record(elem0, stride, vals)
  local i, v
  for i, v in pairs(vals) do
    local hi, lo = fftsa.nl._f64_words(v)
    WORDS[elem0 + (i - 1) * stride] = hi
    WORDS[elem0 + (i - 1) * stride + 4] = lo
  end
end

reset_heap()
DESCS = {{base = DESC, cap = 65536, n = 2048}}
place_desc(DESC, TRUE_E0, 24, 1365, 49, 65536, 2048)
local live = densify(readings(0.125, 0.1875), 65536)
place_record(TRUE_E0, 24, live)
place_geom(TRUE_E0, 24, 1365, VEC, 2048, live)
READHIT = TRUE_E0
local LIVEBUF = {n = 2048, capacity = 65536, readings = live}

fftsa.nl._stor_of = nil
local dl = fftsa.nl.describe(LIVEBUF, false)
local ce0, cst = fftsa.nl._find_storage(LIVEBUF, false)
check('signature and content routes agree on a live record',
      dl ~= nil and dl.chunk1 == TRUE_E0 and ce0 == TRUE_E0 and cst == 24,
      string.format('sig=%s content=%s stride=%s',
                    dl and string.format('%X', dl.chunk1) or 'nil',
                    ce0 and string.format('%X', ce0) or 'nil', tostring(cst)))

-- A second buffer of the same capacity and a different count must not be reachable: n is
-- half the needle, so the wrong descriptor is never a hit rather than merely losing.
reset_heap()
local DECOY, DECOY_E0 = 57000000, 57500000
DESCS = {{base = DECOY, cap = 65536, n = 4096}, {base = DESC, cap = 65536, n = 2048}}
place_desc(DECOY, DECOY_E0, 24, 1365, 49, 65536, 4096)
place_desc(DESC, TRUE_E0, 24, 1365, 49, 65536, 2048)
place_record(TRUE_E0, 24, live)
place_geom(TRUE_E0, 24, 1365, VEC, 2048, live)
READHIT = TRUE_E0
fftsa.nl._stor_of = nil
local dd2 = fftsa.nl.describe(LIVEBUF, false)
check('a same-capacity buffer at a different count is not a candidate',
      dd2 ~= nil and dd2.chunk1 == TRUE_E0,
      string.format('chunk1=%s decoy=%X',
                    dd2 and string.format('%X', dd2.chunk1) or 'nil', DECOY_E0))

-- And the count the app actually offers, not just the one measured. Each FFT size gives a
-- different n, so each is a different needle, and the route has to hold for all of them.
local counts = {512, 2048, 4096, 16384, 32768}
local allok, firstbad = true, nil
local ci
for ci = 1, table.getn(counts) do
  local cn = counts[ci]
  reset_heap()
  DESCS = {{base = DESC, cap = 65536, n = cn}}
  place_desc(DESC, TRUE_E0, 24, 1365, 49, 65536, cn)
  place_record(TRUE_E0, 24, live)
  place_geom(TRUE_E0, 24, 1365, VEC, cn, live)
  READHIT = nil
  fftsa.nl._stor_of = nil
  local dc = fftsa.nl.describe({n = cn, capacity = 65536, readings = live}, false)
  if dc == nil or dc.chunk1 ~= TRUE_E0 then
    allok = false
    if firstbad == nil then firstbad = cn end
  end
end
check('resolves at every count the app offers, with no content scan available',
      allok, string.format('counts=%d firstbad=%s',
                           table.getn(counts), tostring(firstbad)))

-- The descriptor the question is about is the argument now, so the case has to hold one.
reset_heap()
DESCS = {{base = DESC, cap = 65536, n = 2048}}
place_desc(DESC, TRUE_E0, 24, 1365, 49, 65536, 2048)
place_geom(TRUE_E0, 24, 1365, VEC, 2048, flat)
READHIT = nil
fftsa.nl._stor_of, fftsa.nl._desc_of, fftsa.nl._desc_at = nil, nil, nil
local d65 = fftsa.nl.describe({n = 2048, capacity = 65536, readings = flat}, false)
check('a DMM6500 layout names itself, and a write at those offsets is allowed',
      d65 ~= nil and d65.doff == fftsa.nl.DOFF
      and fftsa.nl.desc_off_ok(d65) == true,
      string.format('%s doff=%s', fftsa.nl.desc_off_str(), tostring(d65 and d65.doff)))

-- Default refuse, which is the half that was a default permit: a descriptor this cannot
-- place, and no descriptor at all, are both writes it must not allow.
check('a descriptor naming no layout, and no descriptor, both refuse the rewind',
      fftsa.nl.desc_off_ok(nil) == false
      and fftsa.nl.desc_off_ok({}) == false,
      'nil and empty both refuse')

-- ========================================================================================
-- A DMM7510's own geometry, read off three 8.65 error pages.
--
-- Two things differ from a DMM6500 and each one stopped the app on its own:
--
--   * its STYLE_STANDARD reading element is 20 bytes, not 24. The content scan tried 32 and
--     24 unconditionally and reached 20 only through the discovery loop, which runs only
--     where readings 1 and 2 differ -- so a quiet capture reported "no stride confirmed
--     ... eq12=true" and the app halted. 20 also leaves half the readings in a record
--     4-aligned, which the native read refused outright as ECAPTURE.
--   * its descriptor is the same fields with eight bytes gone ahead of the chunk vector:
--     stor 0x40, s1 0x4C, s2 0x5C, vec 0x3C, cap 0x6C. The signature route looked for the
--     capacity at 0x74, found 58 hits of the pair and no descriptor -- and that route is
--     precisely the one a quiet capture depends on.
--
-- The figures are the ones on the glass, run 3 of three: the hit at 0x1321AF8, base
-- 0x1321AB8, elemsize 0x14, perchunk 0x666, 0x29 chunks, capacity 0x10000 at base+0x6C with
-- n 0x800 in the word above it. 20 * 1638 = 32,760 fills the payload with 8 to spare, and
-- 65,536 readings at 1638 a chunk is the 41 the record states.
-- ========================================================================================

print('\nnl.describe on a DMM7510 geometry')

local D75 = fftsa.nl.DOFF_7510
local DESC75, E0_75 = 20060856, 20227184      -- 0x1321AB8, 0x134A470

-- The quiet capture: identical readings, so no content scan can answer, and the signature
-- route has to find the descriptor at this model's own capacity offset.
reset_heap()
DESCS = {{base = DESC75, cap = 65536, n = 2048, capoff = D75.cap}}
place_desc(DESC75, E0_75, 20, 1638, 41, 65536, 2048, D75)
place_geom(E0_75, 20, 1638, VEC, 2048, flat)
READHIT = nil
fftsa.nl._stor_of = nil
local q75 = fftsa.nl.describe({n = 2048, capacity = 65536, readings = flat}, false)
check('a quiet DMM7510 capture resolves from the signature at its own capacity offset',
      q75 ~= nil and q75.chunk1 == E0_75 and q75.elemsize == 20 and q75.perchunk == 1638,
      string.format('chunk1=%s es=%s pc=%s why=%s/%s',
                    q75 and string.format('%X', q75.chunk1) or 'nil',
                    q75 and tostring(q75.elemsize) or 'nil',
                    q75 and tostring(q75.perchunk) or 'nil',
                    tostring(fftsa.nl._sig_why), tostring(fftsa.nl._stor_why)))

-- The one thing that must NOT follow from reading a second layout. The native cursor rewind
-- stores at offsets compiled into the image, so a descriptor identified at any other set is
-- readable and not writable -- the fields it would overwrite belong to whatever is there.
check('the layout it matched is named, and a write at those offsets is refused',
      q75 ~= nil and q75.doff == D75 and fftsa.nl.desc_off_ok(q75) == false,
      string.format('%s doff=%s', fftsa.nl.desc_off_str(), tostring(q75 and q75.doff)))

-- The element size the page could not state. It had to be decoded out of the hit dump a word
-- at a time, and the page is the whole channel to an instrument on another continent.
-- localnode only for this one check: diag() opens with the model and the firmware revision,
-- which is the rest of what makes a grab readable.
do
  localnode = { model = 'DMM7510', version = '1.7.16a' }
  local dg = fftsa.nl.diag()
  localnode = nil
  check('the diagnostic carries the measured stride and element 0',
        string.find(dg, 'str=20 e0=134A470', 1, true) ~= nil, dg)
end

-- Readings 1 and 2 equal and the rest distinct: the discovery loop never runs, so only the
-- unconditional candidates are tried. This is the "eq12=true" report exactly, and it passes
-- only because 20 is one of them.
local eqhead = {SAME, SAME, 0.25, 0.5, 0.75, 1.0}
eqhead[64], eqhead[256] = 2.5, 3.75
densify(eqhead, 65536)
reset_heap()
DESCS = {}
place_desc(DESC75, E0_75, 20, 1638, 41, 65536, 2048, D75)
place_record(E0_75, 20, eqhead)
place_geom(E0_75, 20, 1638, VEC, 2048, eqhead)
READHIT = E0_75
-- The descriptor cache as well as the storage one: the case above resolved the same element
-- 0, so a cache left in place would answer this one before it swept anything.
fftsa.nl._stor_of, fftsa.nl._desc_of, fftsa.nl._desc_at = nil, nil, nil
local eh = fftsa.nl.describe({n = 2048, capacity = 65536, readings = eqhead}, false)
check('stride 20 is an unconditional candidate, so equal first readings do not hide it',
      eh ~= nil and eh.chunk1 == E0_75 and eh.elemsize == 20,
      string.format('chunk1=%s es=%s why=%s',
                    eh and string.format('%X', eh.chunk1) or 'nil',
                    eh and tostring(eh.elemsize) or 'nil', tostring(fftsa.nl._stor_why)))

check('and the sweep hit reached the descriptor at this layout, not the derived route',
      fftsa.nl._hit_n == 1 and fftsa.nl.desc_off == nil and fftsa.nl.doff_used == D75,
      string.format('hits=%s %s', tostring(fftsa.nl._hit_n), fftsa.nl.desc_off_str()))

-- A record whose element 0 is only 4-aligned. A 20-byte element means the firmware is not
-- loading these 8-aligned either, so an 8-byte filter on the scan's hits would reject real
-- storage on this model half the time -- once per allocation, at random.
reset_heap()
DESCS = {}
place_desc(DESC75, E0_75 + 4, 20, 1638, 41, 65536, 2048, D75)
place_record(E0_75 + 4, 20, live)
place_geom(E0_75 + 4, 20, 1638, VEC, 2048, live)
READHIT = E0_75 + 4
fftsa.nl._stor_of, fftsa.nl._desc_of, fftsa.nl._desc_at = nil, nil, nil
local a4 = fftsa.nl.describe({n = 2048, capacity = 65536, readings = live}, false)
check('an element 0 only 4-aligned is found rather than filtered out',
      a4 ~= nil and a4.chunk1 == E0_75 + 4 and a4.elemsize == 20,
      string.format('chunk1=%s es=%s why=%s',
                    a4 and string.format('%X', a4.chunk1) or 'nil',
                    a4 and tostring(a4.elemsize) or 'nil', tostring(fftsa.nl._stor_why)))

-- And the report must not carry the last buffer that DID resolve. A DMM7510 grab showed a
-- 32-byte element and cap28672/n256 beside a capture buffer of cap65536/n2048 whose storage
-- was never found: _find_desc never ran, so nothing cleared what the previous call left.
reset_heap()
DESCS = {}
READHIT = nil
fftsa.nl._stor_of, fftsa.nl._desc_of, fftsa.nl._desc_at = nil, nil, nil
local miss = fftsa.nl.describe({n = 2048, capacity = 65536, readings = flat}, false)
check('a storage failure clears the descriptor half of the report',
      miss == nil and fftsa.nl._raw_n == 0 and fftsa.nl._hit_n == 0
      and fftsa.nl.hit_dump_str() == 'dump=none'
      and fftsa.nl.hits_str() == 'at=none'
      and fftsa.nl._desc_buf == 'cap65536/n2048',
      string.format('raw=%s hits=%s buf=%s %s %s', tostring(fftsa.nl._raw_n),
                    tostring(fftsa.nl._hit_n), tostring(fftsa.nl._desc_buf),
                    fftsa.nl.hits_str(), fftsa.nl.hit_dump_str()))

-- ========================================================================================
-- geom_ok: the element size settled against the firmware's own readings.
--
-- This is the gate that rests on nothing read off a screen. The element size is a runtime sum
-- of column widths -- no constant in either firmware image records it, confirmed by there
-- being no `mulli` by any element size in the DMM7510 1.7.16a image -- so 20 cannot be looked
-- up and has to be proved on the instrument. A wrong one does not refuse: it reads the wrong
-- bytes as samples and draws a plausible, wrong spectrum.
--
-- Each case below leaves the content scan and the descriptor AGREEING, because describe
-- already refuses them when they do not ("elemsize N disagrees with stride M") and that
-- refusal would mask this one. Only the firmware's own readings disagree, which is exactly
-- the shape a wrong per-model element size takes.
-- ========================================================================================

print('\ngeom_ok, the element size against the readings')

-- Chunk 1 holding the reading a perchunk of 1365 would put there. Both the scan and the
-- descriptor say 1638; a 24-byte element is what would put reading 1366 at that address.
reset_heap()
DESCS = {}
place_desc(DESC75, E0_75, 20, 1638, 41, 65536, 2048, D75)
place_record(E0_75, 20, live)
place_geom(E0_75, 20, 1638, VEC, 2048, live)
local c1 = WORDS[VEC + 4]
local wh, wl = fftsa.nl._f64_words(live[1366])
WORDS[c1], WORDS[c1 + 4] = wh, wl
READHIT = E0_75
fftsa.nl._stor_of, fftsa.nl._desc_of, fftsa.nl._desc_at = nil, nil, nil
local wrong = fftsa.nl.describe({n = 2048, capacity = 65536, readings = live}, false)
check('a geometry that does not address the readings is refused, not believed',
      wrong == nil and fftsa.nl._geom_why ~= nil
      and string.find(tostring(fftsa.nl._stor_why), 'does not address the readings',
                      1, true) ~= nil,
      string.format('d=%s why=%s stor=%s', tostring(wrong), tostring(fftsa.nl._geom_why),
                    tostring(fftsa.nl._stor_why)))

-- The figure a fix needs: not that 20 was wrong, but that 24 fits. A chunk boundary is what
-- makes this answerable -- each candidate element size predicts a different reading index at
-- the same address, so only the true one matches.
check('and it names the element size that WOULD fit, which is the actionable figure',
      string.find(tostring(fftsa.nl._geom_why), 'fits es=24', 1, true) ~= nil
      and string.find(tostring(fftsa.nl._geom_why), 'pc=1365', 1, true) ~= nil,
      tostring(fftsa.nl._geom_why))

check('and the refusal names the reading index and the geometry it was tried at',
      string.find(tostring(fftsa.nl._geom_why), 'reading 1639', 1, true) ~= nil
      and string.find(tostring(fftsa.nl._geom_why), 'es=20', 1, true) ~= nil
      and string.find(tostring(fftsa.nl._geom_why), 'pc=1638', 1, true) ~= nil,
      tostring(fftsa.nl._geom_why))

-- The last element of chunk 0. Without this term the stride is confirmed only as far as the
-- content scan's furthest index, 256, and a record of 1638 elements a chunk is unchecked over
-- the remaining 1381.
reset_heap()
DESCS = {}
place_desc(DESC, TRUE_E0, 24, 1365, 49, 65536, 2048)
place_record(TRUE_E0, 24, live)
place_geom(TRUE_E0, 24, 1365, VEC, 2048, live)
local lastw = TRUE_E0 + 1364 * 24
local lh, ll = fftsa.nl._f64_words(live[9999])
WORDS[lastw], WORDS[lastw + 4] = lh, ll
READHIT = TRUE_E0
fftsa.nl._stor_of, fftsa.nl._desc_of, fftsa.nl._desc_at = nil, nil, nil
local lastbad = fftsa.nl.describe({n = 2048, capacity = 65536, readings = live}, false)
check('the stride is checked at the last element of a chunk, not only as far as index 256',
      lastbad == nil
      and string.find(tostring(fftsa.nl._geom_why), 'reading 1365', 1, true) ~= nil,
      tostring(fftsa.nl._geom_why))

-- And a correct DMM6500 record passes, having actually looked at something: a check that
-- confirms zero indices passes everything.
reset_heap()
DESCS = {}
place_desc(DESC, TRUE_E0, 24, 1365, 49, 65536, 2048)
place_record(TRUE_E0, 24, live)
place_geom(TRUE_E0, 24, 1365, VEC, 2048, live)
READHIT = TRUE_E0
fftsa.nl._stor_of, fftsa.nl._desc_of, fftsa.nl._desc_at = nil, nil, nil
local good = fftsa.nl.describe({n = 2048, capacity = 65536, readings = live}, false)
check('a correct record passes, and the check looked at more than nothing',
      good ~= nil and fftsa.nl._geom_why == nil
      and type(fftsa.nl._geom_n) == 'number' and fftsa.nl._geom_n >= 3,
      string.format('d=%s n=%s why=%s', tostring(good ~= nil),
                    tostring(fftsa.nl._geom_n), tostring(fftsa.nl._geom_why)))

-- A DMM6500 descriptor must still not be read as a DMM7510 one or the other way round. The
-- two sets put the storage pointer and the two self-pointers at three different distances
-- from each other, so a record placed at one set is refused at the other -- which is what
-- lets both be tried without a false positive.
reset_heap()
DESCS = {}
place_desc(DESC75, E0_75, 24, 1365, 49, 65536, 2048)     -- the DMM6500 offsets
READHIT = E0_75
fftsa.nl._stor_of = nil
-- Named for what they hold: as_7510 is the record READ AT the 7510 offsets. Both directions,
-- and both at a fixed base, which is the one route where a single base can satisfy either set
-- -- so this is also the case that makes the order in DOFF_SETS load-bearing.
local as_7510 = fftsa.nl._read_desc_1(DESC75, E0_75, D75)
local as_6500 = fftsa.nl._read_desc_1(DESC75, E0_75, fftsa.nl.DOFF)
check('a record at one layout is refused when read at the other',
      as_7510 == nil and as_6500 == DESC75,
      string.format('as7510=%s as6500=%s', tostring(as_7510), tostring(as_6500)))

-- And the mirror, which the case above does not cover: a record placed at the 7510 offsets
-- must be refused when read at the compiled ones.
reset_heap()
place_desc(DESC75, E0_75, 20, 1638, 41, 65536, 2048, D75)
local m7510 = fftsa.nl._read_desc_1(DESC75, E0_75, D75)
local m6500 = fftsa.nl._read_desc_1(DESC75, E0_75, fftsa.nl.DOFF)
check('and the other way round, so neither layout can be read as the other',
      m7510 == DESC75 and m6500 == nil,
      string.format('as7510=%s as6500=%s', tostring(m7510), tostring(m6500)))

-- _read_desc_1 sets doff_used and chunk_span as a side effect, and these calls are outside
-- any describe(), so the module is left attributing a layout to a buffer nothing described.
fftsa.nl.doff_used, fftsa.nl.chunk_span = nil, nil

-- ========================================================================================
-- The descriptor outside every anchored window: the DMM7510 1.7.16 failure.
--
-- Reported from the glass at 8.47: element 0 confirmed at 0x0158D7C0 at stride 32, and no
-- descriptor anywhere, with windows 0x3000..0x27BF520 and 0x3000..0x8FBF520. The layout is not
-- the difference -- the function that initialises +0x44/+0x48/+0x54/+0x64/+0x74 and the four
-- copies of n is 1044 bytes byte-identical in the 6500 1.7.17a and 7510 1.7.16 images -- so the
-- descriptor was outside what tostring({}) can reach. The anchored pair covers 143 MB of a heap
-- that runs to 248 MB.
--
-- These use the reported numbers. FINDS is modelled on the needle's meaning: a hit comes back
-- only when the address it sits at is inside the window asked for, which is the whole of what
-- went wrong.
-- ========================================================================================

print('\nnl.scan_windows, the descriptor beyond the anchored windows')

do
  local SAVED = tostring
  fftsa.nl.BACKSTOP_LO, fftsa.nl.BACKSTOP_HI = 12288, 268435456

  local ANCHOR = 17179000        -- 0x1062178, the anchor that DMM7510 reported
  local ELEM0  = 22599616        -- 0x158D7C0, the element 0 it confirmed
  local INST   = 209715200       -- 0xC800000, a C++ instance 200 MB up
  local HDESC  = INST + 65536    -- the descriptor, in the instance's own arena
  local COLPTR = INST - 131072   -- a column pointer, as the chain lists them
  local REF    = {cclassref = true}

  -- tostring has to answer two different objects: a fresh table for the anchor, and the
  -- CClassRef userdata for the instance. Both print an address on the instrument.
  local setpair = function(anchor, refaddr)
    tostring = function(v)
      if v == REF and refaddr ~= nil then
        return 'userdata: ' .. string.format('%x', refaddr)
      end
      if type(v) == 'table' and next(v) == nil then
        return 'table: ' .. string.format('%x', anchor)
      end
      return SAVED(v)
    end
  end

  -- The buffer as the firmware presents it: a table with no own keys whose metatable carries
  -- CClassRef. The Udata payload holds one pointer, which is the instance.
  local REFAT = 55000000
  local function hbuf()
    return setmetatable({n = 2048, capacity = 263168}, {CClassRef = REF})
  end

  setpair(ANCHOR, REFAT)
  reset_heap()
  WORDS[REFAT] = INST

  check('the instance comes off the buffer metatable, with no searching',
        fftsa.nl.cclass(hbuf()) == INST,
        'inst=' .. tostring(fftsa.nl.cclass(hbuf())))

  check('a buffer with no metatable answers nil rather than guessing',
        fftsa.nl.cclass({n = 1}) == nil and fftsa.nl.cclass(nil) == nil,
        'both nil')

  -- The chain is (previous id, this id, two pointers) per 16 bytes, NUL-terminated. A reader
  -- that misses the terminator walks into unreclaimed heap and hands back pointers to nothing.
  WORDS[INST + 16 + 4] = 9
  WORDS[INST + 16 + 8] = COLPTR
  WORDS[INST + 16 + 12] = COLPTR + 4096
  WORDS[INST + 32 + 4] = 0
  local cp = fftsa.nl.col_ptrs(INST)
  check('the column chain stops at its terminator',
        table.getn(cp) == 2 and cp[1] == COLPTR and cp[2] == COLPTR + 4096,
        'n=' .. table.getn(cp))

  -- The ladder itself. Stage 1 has to be tight and first, or a model that works today pays
  -- minutes for what it used to find in a second.
  local w = fftsa.nl.scan_windows(hbuf(), ELEM0)
  local nw = table.getn(w)
  check('the first window is tight and centred on the instance',
        w[1][1] == INST - fftsa.nl.TIGHT and w[1][2] == INST + fftsa.nl.TIGHT,
        string.format('%X..%X over %d windows', w[1][1], w[1][2], nw))
  check('the last window is everything the backstop allows, so nothing in DRAM is unreachable',
        w[nw][1] == fftsa.nl.BACKSTOP_LO and w[nw][2] == fftsa.nl.BACKSTOP_HI,
        string.format('%X..%X', w[nw][1], w[nw][2]))
  -- The anchored pair is still in there. It is what works on a 6500 today and the ladder adds
  -- to it rather than replacing it.
  local kept = false
  local sw = fftsa.nl.sweep_windows()
  local wi, si
  for wi = 1, nw do
    for si = 1, table.getn(sw) do
      if w[wi][1] == sw[si][1] and w[wi][2] == sw[si][2] then kept = true end
    end
  end
  check('the anchored windows 8.46 swept are still swept', kept, 'n=' .. nw)
  -- The widening stage has to widen around the two centres the descriptor is known to sit
  -- near: the instance and the storage. An earlier ordering widened around a column pointer
  -- instead and left the storage with only its tight window.
  local wide = false
  for wi = 1, nw do
    if w[wi][1] == ELEM0 + fftsa.nl.TIGHT and w[wi][2] == ELEM0 + fftsa.nl.MID then
      wide = true
    end
  end
  check('the widening stage covers the storage address, not just a column pointer', wide,
        'n=' .. nw)
  -- And no window appears twice: elem0 and the instance can be in the same arena, and a
  -- duplicate of the wide stage would double the worst case.
  local dup = false
  for wi = 1, nw do
    for si = wi + 1, nw do
      if w[wi][1] == w[si][1] and w[wi][2] == w[si][2] then dup = true end
    end
  end
  check('no window is swept twice', not dup, 'n=' .. nw)

  -- A hit only where the needle really is. This is the model the 7510 defeated.
  local PLACES
  fftsa.nl.FINDS = function(lo, hi, pat)
    local out, n, i = {}, 0, nil
    for i = 1, table.getn(PLACES) do
      if PLACES[i][2] == pat and PLACES[i][1] >= lo and PLACES[i][1] <= hi then
        n = n + 1; out[n] = PLACES[i][1]
      end
    end
    return out
  end
  local E0PAT = string.char(1, 88, 215, 192)       -- 0x0158D7C0 big-endian

  reset_heap()
  WORDS[REFAT] = INST
  WORDS[INST + 16 + 4] = 9
  WORDS[INST + 16 + 8] = COLPTR
  WORDS[INST + 32 + 4] = 0
  place_desc(HDESC, ELEM0, 32, 1024, 2, 263168, 2048)
  PLACES = {{HDESC + 72, E0PAT}}
  fftsa.nl._desc_of, fftsa.nl._desc_at = nil, nil

  -- First the failure as it stands, so the fixture is known to reproduce it: the anchored pair
  -- alone cannot see a descriptor 200 MB up, and that is hits=0 with nothing to act on.
  local osw = fftsa.nl.scan_windows
  fftsa.nl.scan_windows = function() return fftsa.nl.sweep_windows() end
  local b0 = fftsa.nl._find_desc(ELEM0, hbuf())
  check('the anchored windows alone still miss it, which is what was reported',
        b0 == nil and fftsa.nl._raw_n == 0,
        'base=' .. tostring(b0) .. ' raw=' .. tostring(fftsa.nl._raw_n))
  fftsa.nl.scan_windows = osw

  fftsa.nl._desc_of, fftsa.nl._desc_at = nil, nil
  local b, es, pc, vec, nc = fftsa.nl._find_desc(ELEM0, hbuf())
  check('and the instance window finds it, in stage 1',
        b == HDESC and es == 32 and pc == 1024 and nc == 2 and fftsa.nl._win_hit == 1,
        string.format('base=%s win=%s raw=%s', tostring(b), tostring(fftsa.nl._win_hit),
                      tostring(fftsa.nl._raw_n)))

  -- A column pointer that is the descriptor needs no sweep at all. FINDS is replaced with one
  -- that fails the test if it is called, because "cheapest first" is the claim being made.
  reset_heap()
  WORDS[REFAT] = INST
  WORDS[INST + 16 + 4] = 9
  WORDS[INST + 16 + 8] = HDESC
  WORDS[INST + 32 + 4] = 0
  place_desc(HDESC, ELEM0, 32, 1024, 2, 263168, 2048)
  local swept = 0
  local KEEP = fftsa.nl.FINDS
  fftsa.nl.FINDS = function() swept = swept + 1; return {} end
  fftsa.nl._desc_of, fftsa.nl._desc_at, fftsa.nl.arena = nil, nil, nil
  local bd = fftsa.nl._find_desc(ELEM0, hbuf())
  fftsa.nl.FINDS = KEEP
  check('a chain pointer that is the descriptor is recognised without sweeping',
        bd == HDESC and fftsa.nl._win_hit == 0 and swept == 0,
        'base=' .. tostring(bd) .. ' win=' .. tostring(fftsa.nl._win_hit)
        .. ' sweeps=' .. swept)

  reset_heap()
  WORDS[REFAT] = INST
  WORDS[INST + 16 + 4] = 9
  WORDS[INST + 16 + 8] = COLPTR
  WORDS[INST + 32 + 4] = 0
  place_desc(HDESC, ELEM0, 32, 1024, 2, 263168, 2048)
  PLACES = {{HDESC + 72, E0PAT}}

  -- With no instance to be had -- a build whose metatable is shaped differently -- the wide
  -- stage is the one that answers. Slower, and the point is that it still answers.
  setpair(ANCHOR, nil)
  fftsa.nl._desc_of, fftsa.nl._desc_at, fftsa.nl.arena = nil, nil, nil
  local bw = fftsa.nl._find_desc(ELEM0, hbuf())
  check('with no instance the wide stage still reaches it rather than refusing',
        bw == HDESC and fftsa.nl._win_hit ~= nil and fftsa.nl._win_hit > 1,
        'base=' .. tostring(bw) .. ' win=' .. tostring(fftsa.nl._win_hit))

  -- raw against confirmed. A raw hit with nothing confirmed means the layout moved; no raw hit
  -- at all means the window never covered it. The 7510 report could not tell them apart.
  setpair(ANCHOR, REFAT)
  reset_heap()
  WORDS[REFAT] = INST
  place_desc(HDESC, ELEM0, 32, 1024, 2, 263168, 2048)
  WORDS[HDESC + 84] = HDESC + 4         -- an owner pointer that is not the base
  PLACES = {{HDESC + 72, E0PAT}}
  fftsa.nl._desc_of, fftsa.nl._desc_at, fftsa.nl.arena = nil, nil, nil
  local bl = fftsa.nl._find_desc(ELEM0, hbuf())
  check('a found-but-unconfirmed descriptor reports raw hits with none confirmed',
        bl == nil and fftsa.nl._raw_n > 0 and fftsa.nl._hit_n == 0,
        'raw=' .. tostring(fftsa.nl._raw_n) .. ' hits=' .. tostring(fftsa.nl._hit_n))

  -- The guarded read. Everything above starts from a pointer the firmware gave us rather than
  -- from a window we chose, so an address outside DRAM has to come back nil and not as an lwz.
  check('the guarded word refuses what peek32 would have faulted on',
        fftsa.nl._wg(2147483648) == nil and fftsa.nl._wg(INST + 1) == nil
        and fftsa.nl._wg(0) == nil and fftsa.nl._wg('x') == nil,
        'MMIO, unaligned, zero and non-numeric all refused')

  tostring = SAVED
  fftsa.nl._desc_of, fftsa.nl._desc_at, fftsa.nl.arena = nil, nil, nil
end

fftsa.nl.FINDS = FINDS_REAL

-- ========================================================================================
-- resolve_math: finding the libm entries without comparing anything to an address.
--
-- The entries move between models as well as between builds. A DMM7510 on 1.7.16 carries the
-- same Lua math block as a DMM6500 -- 13,228 bytes, function for function, same order -- at
-- 0x000CDD34 against the 6500's 0x002026F8, so its library sits BELOW the 0x00400000 that
-- used to pick it out, six names come back nil, and the app cannot start. Position cannot
-- separate the library call from the VM glue either: the VM calls are outside the wrapper's
-- body, outside the math block, and forward of the wrapper, exactly as the library call is.
--
-- What separates them is that math.abs, math.deg and math.rad call no library function at
-- all, so every target they reach is glue by construction -- a property of the Lua source,
-- not of the link map. These cases drive the real resolve_math from the target lists measured
-- off two 6500 images and from the 7510's wrapper addresses.
--
-- The mocks here are word-based, where the suite's own are string-based, so they are saved
-- and restored around the section.
-- ========================================================================================

local SAVED_PEEK, SAVED_READ, SAVED_TOSTR = ki.peek32, ki.memread, tostring

do
  local MEM, CLS = {}, {}
  ki.peek32 = function(ah) return string.format('%X', MEM[tonumber(ah, 16)] or 0) end
  ki.memread = function(ah, lh)
    local a, n = tonumber(ah, 16), tonumber(lh, 16)
    local acc, i = {}, nil
    for i = 0, n / 4 - 1 do
      local w = MEM[a + i * 4] or 0
      table.insert(acc, string.char(math.floor(w / 16777216),
                                    math.mod(math.floor(w / 65536), 256),
                                    math.mod(math.floor(w / 256), 256), math.mod(w, 256)))
    end
    return table.concat(acc)
  end
  -- FNT reads the closure address out of tostring, so the synthetic wrappers need one.
  tostring = function(v)
    if CLS[v] then return 'function: ' .. string.format('%X', CLS[v]) end
    return SAVED_TOSTR(v)
  end

  -- A wrapper body: mflr at word 0, the bls at words 1..n, the blr at word 89, which is
  -- where every measured wrapper puts its one exit.
  local function body(entry, targets)
    local i
    for i = 0, 90 do MEM[entry + i * 4] = 1610612736 end
    for i = 1, table.getn(targets) do
      local d = math.floor((targets[i] - (entry + i * 4)) / 4)
      if d < 0 then d = d + 16777216 end
      MEM[entry + i * 4] = 1207959552 + d * 4 + 1
    end
    MEM[entry + 89 * 4] = 1317011488
  end

  -- Ten VM calls, the library entry, then lua_pushnumber. abs/deg/rad are the same list with
  -- the library entry left out, which is what makes them the glue sample.
  local function layout(blockbase, glue, libbase, libstep)
    MEM, CLS = {}, {}
    local order = { 'abs', 'sin', 'cos', 'tan', 'asin', 'acos', 'atan', 'ceil', 'floor',
                    'sqrt', 'log', 'log10', 'exp', 'deg', 'rad' }
    local want, cls, i = {}, 44040192, nil
    for i = 1, table.getn(order) do
      local nm = order[i]
      local w = blockbase + (i - 1) * 364
      local c = cls + (i - 1) * 64
      local ts, k = {}, nil
      for k = 1, 10 do table.insert(ts, glue[k]) end
      if nm ~= 'abs' and nm ~= 'deg' and nm ~= 'rad' then
        local lib = libbase + (i - 1) * libstep
        table.insert(ts, lib)
        want[nm] = lib
      end
      table.insert(ts, glue[11])
      MEM[c + 12] = w
      body(w, ts)
      CLS[math[nm]] = c
    end
    return want
  end

  local function six(want)
    local i, ok = nil, true
    for i = 1, 6 do
      local nm = fftsa.nl.MATH_NAMES[i]
      if fftsa.nl.fn[nm] ~= want[nm] then ok = false end
    end
    return ok
  end

  local function hex(v) return string.format('%X', v or 0) end

  -- The measured glue lists: 1.7.17a, 1.7.18a, and the 7510's with the VM moved down
  -- alongside its math block.
  local G17 = {2222840, 2221992, 2221808, 2221700, 2221808, 2225156, 2217264, 2217800,
               2163164, 2163164, 2224932}
  local G18 = {2222816, 2221968, 2221784, 2221676, 2221784, 2225132, 2217240, 2217776,
               2163140, 2163140, 2224908}
  local G75 = {860000, 859000, 858000, 857000, 858000, 861000, 855000, 856000,
               845000, 845000, 862000}

  -- 1.7.17a: block 0x002026F8, library from 0x0046F83C.
  local want = layout(2103032, G17, 4651068, 256)
  local got = fftsa.nl.resolve_math()
  check('1.7.17a: all six resolve', got == 6,
        'found=' .. got .. ' glue=' .. tostring(fftsa.nl.nglue))
  check('1.7.17a: each is the measured entry', six(want), 'sin=' .. hex(fftsa.nl.fn.sin))
  check('1.7.17a: the glue set is the nine measured', fftsa.nl.nglue == 9,
        'nglue=' .. tostring(fftsa.nl.nglue))
  check('1.7.17a: the pick sits where the measured one does', fftsa.nl.math_odd == nil,
        'math_odd=' .. tostring(fftsa.nl.math_odd))

  -- 1.7.18a: different addresses, same shape. The VM moved -0x18 and the library +0x154
  -- between these two builds, which is why nothing may key on position.
  want = layout(2103008, G18, 4651408, 256)
  got = fftsa.nl.resolve_math()
  check('1.7.18a: six resolve, and each is right', got == 6 and six(want),
        'found=' .. got .. ' sin=' .. hex(fftsa.nl.fn.sin))

  -- DMM7510 1.7.16: block 0x000CDD34, library below 0x400000. This is the case that fails
  -- against the old scan floor, and the reason the floor is gone.
  want = layout(843060, G75, 3407872, 256)
  got = fftsa.nl.resolve_math()
  check('7510 shape, library below 0x400000: six resolve', got == 6,
        'found=' .. got .. ' sin=' .. hex(fftsa.nl.fn.sin))
  check('7510 shape: each is the right entry', six(want),
        'sin=' .. hex(fftsa.nl.fn.sin) .. ' want ' .. hex(want.sin))

  -- Above TEXT_HI: refused here, at the launch, rather than by the image's own bounds check
  -- at the first frame -- which is an app already on the glass and a spectrum that never
  -- arrives.
  want = layout(2103032, G17, 6000000, 256)
  got = fftsa.nl.resolve_math()
  check('library above TEXT_HI: none resolve, so nl.init refuses', got == 0, 'found=' .. got)

  -- Every wrapper reaching one address: both copies go, not the second. A shared address
  -- says neither name was identified, so keeping the first would be a guess with a count
  -- that looked like progress -- which is exactly how the broken change read as six.
  want = layout(2103032, G17, 4651068, 0)
  got = fftsa.nl.resolve_math()
  check('every wrapper reaching one entry: all refused', got == 0,
        'found=' .. got .. ' sin=' .. tostring(fftsa.nl.fn.sin))

  -- A glue sample that is not glue: abs reaches something the others do not, so the
  -- whole-set test fails for every census wrapper and the lot is refused.
  want = layout(2103032, G17, 4651068, 256)
  body(2103032, {G17[1], G17[2], 4800000, G17[4], G17[5], G17[6], G17[7], G17[8],
                 G17[9], G17[10], G17[11]})
  got = fftsa.nl.resolve_math()
  check('a glue sample reaching what the others do not: refused', got == 0, 'found=' .. got)

  -- No glue sample at all: nothing to subtract, so nothing is claimed.
  want = layout(2103032, G17, 4651068, 256)
  local sa, sd, sr = math.abs, math.deg, math.rad
  math.abs, math.deg, math.rad = nil, nil, nil
  got = fftsa.nl.resolve_math()
  math.abs, math.deg, math.rad = sa, sd, sr
  check('no glue sample: refused rather than guessed', got == 0,
        'found=' .. got .. ' nglue=' .. tostring(fftsa.nl.nglue))
end

-- ---------------------------------------------------------------------------
-- The heap sweep windows. These were two constants measured inside a DMM6500's heap, which
-- left about 45% of a DMM7510 1.7.16's heap unswept: describe() answered nil for a buffer
-- the allocator placed outside them, and nl.init then aborted with no reason recorded. They
-- are now derived from a heap address Lua hands over for free. Decimal throughout, because
-- Lua 5.0.2 rejects a hex literal at parse time.
-- ---------------------------------------------------------------------------
do
  local SAVED = tostring
  fftsa.nl.BACKSTOP_LO, fftsa.nl.BACKSTOP_HI = 12288, 268435456

  -- Measured on a DMM6500 1.7.17a: the four addresses the native path must find, and the
  -- anchor sampled over six calls.
  local D6500 = { 51587624, 56345968, 57110112, 57144480 }
  local A6500 = { 59283568, 59425080, 51858960, 45103512, 51513064, 51938648 }

  local setanchor = function(a)
    tostring = function(v)
      if type(v) == 'table' and next(v) == nil then
        return 'table: ' .. string.format('%x', a)
      end
      return SAVED(v)
    end
  end

  setanchor(59546064)
  check('the anchor is read out of what tostring gives a fresh table',
        fftsa.nl.heap_anchor() == 59546064,
        'got=' .. SAVED(fftsa.nl.heap_anchor()))

  -- Some builds print 0x and some do not. Both have to parse, or the sweep loses its anchor
  -- and falls back to the whole backstop, which takes minutes.
  tostring = function(v)
    if type(v) == 'table' and next(v) == nil then return 'table: 0x38c99d0' end
    return SAVED(v)
  end
  check('an 0x-prefixed address parses too', fftsa.nl.heap_anchor() == 59546064,
        'got=' .. SAVED(fftsa.nl.heap_anchor()))

  -- Every address the native path has to find, against every anchor sample. The near window
  -- has to contain all of them, because reaching the far one costs minutes.
  local worst, allin = 0, true
  local ai, di
  for ai = 1, table.getn(A6500) do
    setanchor(A6500[ai])
    local w = fftsa.nl.sweep_windows()
    if table.getn(w) ~= 2 then allin = false end
    for di = 1, table.getn(D6500) do
      local t = D6500[di]
      if not (t >= w[1][1] and t <= w[1][2]) then allin = false end
      local dist = t - A6500[ai]
      if dist < 0 then dist = -dist end
      if dist > worst then worst = dist end
    end
  end
  check('the near window holds every measured DMM6500 address, for every anchor', allin,
        'worst distance ' .. string.format('%.2f', worst / 1048576) .. ' MB of '
        .. string.format('%.0f', fftsa.nl.ANCHOR_NEAR / 1048576) .. ' MB')

  -- A DMM7510 1.7.16 heap runs 0x008A2000..0x0F8A2000. The old constants started at
  -- 0x01100000 and stopped at 0x09000000, so a buffer at either end of that heap was
  -- invisible. Whatever the anchor, a window must contain it and must stay inside the
  -- backstop.
  local reach = true
  local probes = { 9056256, 16777216, 159383552, 260644864 }
  for ai = 1, table.getn(probes) do
    setanchor(probes[ai])
    local w = fftsa.nl.sweep_windows()
    local far = w[table.getn(w)]
    if not (probes[ai] >= far[1] and probes[ai] <= far[2]) then reach = false end
    if far[1] < fftsa.nl.BACKSTOP_LO or far[2] > fftsa.nl.BACKSTOP_HI then reach = false end
  end
  check('windows stay inside the backstop and contain their anchor across a 7510 heap', reach,
        'backstop ' .. string.format('%X', fftsa.nl.BACKSTOP_LO) .. '..'
        .. string.format('%X', fftsa.nl.BACKSTOP_HI))

  -- No address from tostring means no anchor, and the only thing left that can still succeed
  -- is sweeping everything the backstop allows.
  tostring = function(v)
    if type(v) == 'table' and next(v) == nil then return 'table: (no address)' end
    return SAVED(v)
  end
  local w = fftsa.nl.sweep_windows()
  check('no anchor falls back to the whole backstop rather than refusing',
        table.getn(w) == 1 and w[1][1] == fftsa.nl.BACKSTOP_LO
        and w[1][2] == fftsa.nl.BACKSTOP_HI,
        'n=' .. table.getn(w))

  -- The chunk payload is derived, not asserted. The old pair of tests demanded exactly
  -- 32768, which refused a valid DMM7510 descriptor outright.
  check('a 6500 record: 32 bytes x 1024 fills a 32 KB payload',
        fftsa.nl._chunk_span(32, 1024) == 32768,
        'got=' .. tostring(fftsa.nl._chunk_span(32, 1024)))
  -- STYLE_STANDARD is 24 bytes and does not divide the payload: 1365 fill 32,760 and leave
  -- 8 spare, so the fit has to be a fit and not an exact product.
  check('a 24-byte element still pins the same payload',
        fftsa.nl._chunk_span(24, 1365) == 32768,
        'got=' .. tostring(fftsa.nl._chunk_span(24, 1365)))
  -- A model with a bigger allocator block is recognised rather than refused.
  check('a 64 KB payload is recognised, which the old tests refused',
        fftsa.nl._chunk_span(32, 2048) == 65536,
        'got=' .. tostring(fftsa.nl._chunk_span(32, 2048)))
  check('and a 4 KB one at the bottom of the range',
        fftsa.nl._chunk_span(32, 128) == 4096,
        'got=' .. tostring(fftsa.nl._chunk_span(32, 128)))
  -- Several payload sizes are valid now, which is the cost of not assuming one: 512 elements
  -- of 32 bytes exactly fill 16 KB, so that is a real geometry and is accepted. What is still
  -- refused is a count that fills no power of two at all -- 1000 elements of 32 bytes span
  -- 32,000 and one more reaches 32,032, so no payload size has them as its maximum.
  check('a geometry that fills no power of two is refused',
        fftsa.nl._chunk_span(32, 512) == 16384 and fftsa.nl._chunk_span(32, 1000) == nil,
        '512->' .. tostring(fftsa.nl._chunk_span(32, 512))
        .. ' 1000->' .. tostring(fftsa.nl._chunk_span(32, 1000)))
  check('nonsense geometry is refused',
        fftsa.nl._chunk_span(0, 1024) == nil and fftsa.nl._chunk_span(32, 0) == nil
        and fftsa.nl._chunk_span(32, 1048576) == nil,
        'zero and oversize both refused')

  tostring = SAVED
  -- Every refusal in init names itself now, so the panel never reports a bare nil again.
  check('a refusal records why',
        fftsa.nl._no('because') == false and fftsa.nl.why == 'because',
        'why=' .. tostring(fftsa.nl.why))
end

-- ========================================================================================
-- The display task's trace ring, found from values only this app appended.
--
-- The geometry here is the one measured on a DMM6500 1.7.17a: ring 0x03B53038..0x03B5CDF0,
-- span 40,376 = 721 records of 56 bytes, value float32 twice at record +0x20, x float32 twice
-- at +0x2C, header 40,904 bytes below the ring with lo/hi/oldest/write at +0, +4, +8, +0xC and
-- the count at +0x14.
--
-- NONE OF THOSE NUMBERS IS AN INPUT. The finder is given four appended db/hz pairs and has to
-- come back with the stride and the value-to-x distance on its own, because a DMM7510's have
-- never been measured and assuming them is what the operator ruled out. So the fixture is
-- built at the measured geometry and the test is whether the finder RECOVERS it -- and the
-- same fixture is then rebuilt at a different stride and a negative dx, which it must recover
-- just as well or it is reading its own assumption back.
-- ========================================================================================

print('\nnl.find_ring_records and find_ring_header')

do
  local SAVEDT = tostring
  fftsa.nl.BACKSTOP_LO, fftsa.nl.BACKSTOP_HI = 12288, 268435456

  -- A flat byte image, sparse by word, assembled on demand. memread has to serve unaligned
  -- addresses because FINDS overlaps its slices by the needle length minus one.
  local IMG = {}
  local function wr32(a, v)
    IMG[a] = string.char(math.floor(v / 16777216), math.mod(math.floor(v / 65536), 256),
                         math.mod(math.floor(v / 256), 256), math.mod(v, 256))
  end
  local function wrs(a, s)
    local i
    for i = 0, string.len(s) / 4 - 1 do
      IMG[a + i * 4] = string.sub(s, i * 4 + 1, i * 4 + 4)
    end
  end
  -- The ladder's last stage sweeps the whole backstop, which is 8192 blocks of 32 KB, and
  -- assembling each one word by word made this suite take a minute -- long enough that it
  -- would get skipped, which is how it came to be in no gate at all. The fixture is a few
  -- dozen words, so a block holding none of them is a constant and is answered from a cache.
  -- Same bytes either way: what is cached is the all-zero case, not a short cut around it.
  local ZEROS = {}
  local function zeros(n)
    if ZEROS[n] == nil then ZEROS[n] = string.rep('\0', n) end
    return ZEROS[n]
  end
  local function touches(w0, w1)
    local p, _
    for p, _ in pairs(IMG) do
      if p >= w0 and p < w1 then return true end
    end
    return false
  end
  ki.memread = function(ah, lh)
    local a, n = tonumber(ah, 16), tonumber(lh, 16)
    if a == nil or n == nil or n <= 0 then return nil end
    local w0 = a - math.mod(a, 4)
    local w1 = a + n + 3
    w1 = w1 - math.mod(w1, 4)
    if not touches(w0, w1) then return zeros(n) end
    local acc, k, p = {}, 0, nil
    for p = w0, w1 - 4, 4 do
      k = k + 1
      acc[k] = IMG[p] or '\0\0\0\0'
    end
    return string.sub(table.concat(acc), a - w0 + 1, a - w0 + n)
  end
  ki.peek32 = function(ah)
    local a = tonumber(ah, 16)
    local s = IMG[a]
    if s == nil then return '0' end
    return string.format('%X', ((string.byte(s, 1) * 256 + string.byte(s, 2)) * 256
                                + string.byte(s, 3)) * 256 + string.byte(s, 4))
  end

  local SENT = { {db = -100.0, hz = 1024.0}, {db = -101.0, hz = 2048.0},
                 {db = -102.0, hz = 4096.0}, {db = -103.0, hz = 8192.0} }

  -- lo, stride, how many records, the value and x offsets inside a record, and how far below
  -- the ring the header sits. Everything the finder must not be told.
  local function build(lo, stride, nrec, ov, ox, below)
    IMG = {}
    local hdr = lo - below
    wr32(hdr, lo)
    wr32(hdr + 4, lo + nrec * stride)
    wr32(hdr + 8, lo)
    wr32(hdr + 12, lo + (nrec - 2) * stride)
    wr32(hdr + 20, 255)
    local i
    for i = 1, table.getn(SENT) do
      local rec = lo + (i - 1) * stride
      local v = fftsa.nl._f32_pack(SENT[i].db)
      local x = fftsa.nl._f32_pack(SENT[i].hz)
      wrs(rec + ov, v .. v)
      wrs(rec + ox, x .. x)
      wr32(rec + ov + 8, 0)                 -- flags, zero on a numeric axis
      wr32(rec + ox + 8, 1073741824)        -- 2.0f, which the firmware puts there
    end
    -- The arena hint is what keeps the sweep's first window tight, and on the instrument it is
    -- set by whichever descriptor was found first.
    fftsa.nl.arena = lo
    return hdr
  end

  local RLO, STRIDE, NREC = 62206008, 56, 721       -- 0x03B53038, the measured ring
  local HDR = build(RLO, STRIDE, NREC, 32, 44, 40904)

  local g = fftsa.nl.find_ring_records(SENT)
  check('recovers the record stride and the value-to-x distance from four appends',
        g ~= nil and g.val0 == RLO + 32 and g.stride == STRIDE and g.dx == 12,
        g == nil and ('nil, why=' .. tostring(fftsa.nl.ring_why))
        or string.format('val0=%X stride=%d dx=%d nconf=%d', g.val0, g.stride, g.dx, g.nconf))

  -- THE LAST READ LOOP IN THE AUDIT. find_ring_header walks HDR_BELOW + HDR_ABOVE around the
  -- record in SWEEP_BLOCK pieces, and tests each prefix hit against the block it already has,
  -- so its reads are the window divided by the block size and nothing per hit. 320 KB in 32 KB
  -- pieces is ten, plus a handful where a field straddles a block edge and falls back to a
  -- word read. Asserted, because every other cost bug in this module was a loop whose reads
  -- turned out to scale with something the heap chose.
  local hrd, hpk = 0, 0
  local km0, kp0 = ki.memread, ki.peek32
  ki.memread = function(a, n) hrd = hrd + 1; return km0(a, n) end
  ki.peek32 = function(a) hpk = hpk + 1; return kp0(a) end
  local h = fftsa.nl.find_ring_header(g)
  ki.memread, ki.peek32 = km0, kp0
  check('the header walk reads the window and nothing per hit',
        h ~= nil and hrd <= 16 and hpk <= 16,
        string.format('%d memread(s) and %d peek32(s) over %d KB of window', hrd, hpk,
                      math.floor((fftsa.nl.HDR_BELOW + fftsa.nl.HDR_ABOVE) / 1024)))
  check('finds the ring header from the record, with no offset given',
        h ~= nil and h.hdr == HDR and h.lo == RLO and h.nrec == NREC,
        h == nil and ('nil, why=' .. tostring(fftsa.nl.ring_why))
        or string.format('hdr=%X lo=%X nrec=%d', h.hdr, h.lo, h.nrec))

  local hv = fftsa.nl.ring_header(g)
  check('reads the header back as five numbers',
        hv ~= nil and hv.lo == RLO and hv.hi == RLO + NREC * STRIDE
        and hv.oldest == RLO and hv.count == 255,
        hv == nil and 'nil' or string.format('count=%d write=%X', hv.count, hv.write))

  -- THE SAME FIXTURE AT A GEOMETRY NOBODY HAS MEASURED. A 7510 need not use 56 bytes, and the
  -- x may precede the value, which makes dx negative. If either of these fails the finder is
  -- recognising the 6500 rather than measuring the instrument.
  local RLO2, S2 = 48234496, 64
  local HDR2 = build(RLO2, S2, 512, 40, 20, 8192)
  local g2 = fftsa.nl.find_ring_records(SENT)
  check('recovers a different stride, and an x field that precedes the value',
        g2 ~= nil and g2.val0 == RLO2 + 40 and g2.stride == S2 and g2.dx == -20,
        g2 == nil and ('nil, why=' .. tostring(fftsa.nl.ring_why))
        or string.format('val0=%X stride=%d dx=%d', g2.val0, g2.stride, g2.dx))
  local h2 = fftsa.nl.find_ring_header(g2)
  check('and its header, 8 KB below instead of 40 KB',
        h2 ~= nil and h2.hdr == HDR2 and h2.nrec == 512,
        h2 == nil and ('nil, why=' .. tostring(fftsa.nl.ring_why))
        or string.format('hdr=%X nrec=%d', h2.hdr, h2.nrec))

  -- Refusals. Each of these is a way the finder could answer confidently and wrongly.
  build(RLO, STRIDE, NREC, 32, 44, 40904)
  check('three sentinels are the minimum, and two are refused by name',
        fftsa.nl.find_ring_records({SENT[1], SENT[2]}) == nil
        and string.find(tostring(fftsa.nl.ring_why), 'need 3', 1, true) ~= nil,
        'why=' .. tostring(fftsa.nl.ring_why))
  check('sentinels that pack alike are refused rather than searched for',
        fftsa.nl.find_ring_records({SENT[1], SENT[1], SENT[1]}) == nil
        and string.find(tostring(fftsa.nl.ring_why), 'same float32', 1, true) ~= nil,
        'why=' .. tostring(fftsa.nl.ring_why))

  -- A third sentinel that is not where the stride says it should be. Two records in a row can
  -- line up by accident; the whole run cannot, and this is the test that says so.
  build(RLO, STRIDE, NREC, 32, 44, 40904)
  local bad = fftsa.nl._f32_pack(-109.0)
  wrs(RLO + 2 * STRIDE + 32, bad .. bad)
  check('a run that breaks at the third record confirms no stride',
        fftsa.nl.find_ring_records(SENT) == nil
        and string.find(tostring(fftsa.nl.ring_why), 'no stride', 1, true) ~= nil,
        'why=' .. tostring(fftsa.nl.ring_why))

  -- THE SELF-HIT, WHICH COST A POWER CYCLE AND A BLUESCREEN. FINDS matches its own needle:
  -- the pattern is a live Lua string in the swept heap. Differencing two needles' hits for a
  -- stride is therefore meaningless, and when two 8-byte needles are interned a plausible
  -- distance apart it is CONVINCING -- 120 records of float went over Lua's string table and
  -- the next intern faulted at 0x0022D270 in luaS_newlstr, walking a chain through a next
  -- pointer that had been overwritten.
  --
  -- The lock is that a needle is re-interned per search, so a self-hit MOVES between two
  -- searches while a real record does not. FINDS here returns the record plus a decoy at a
  -- different address each call, with sentinel 2 planted one plausible stride above the decoy
  -- so that the old hit-difference logic would have confirmed it.
  build(RLO, STRIDE, NREC, 32, 44, 40904)
  local FINDS_KEEP = fftsa.nl.FINDS
  local MOVER = {RLO - 262144, RLO - 393216}
  local turn = 0
  local v1 = fftsa.nl._f32_pack(SENT[1].db)
  local v2b = fftsa.nl._f32_pack(SENT[2].db)
  local mi
  for mi = 1, 2 do
    wrs(MOVER[mi], v1 .. v1)
    wrs(MOVER[mi] + STRIDE, v2b .. v2b)
  end
  fftsa.nl.FINDS = function(lo, hi, p)
    local out, n = {}, 0
    if p == v1 .. v1 then
      turn = turn + 1
      local m = MOVER[math.mod(turn - 1, 2) + 1]
      if m >= lo and m <= hi then n = n + 1 out[n] = m end
      if RLO + 32 >= lo and RLO + 32 <= hi then n = n + 1 out[n] = RLO + 32 end
    end
    return out
  end
  local gm = fftsa.nl.find_ring_records(SENT)
  -- The right record, exactly one candidate, and the mover nowhere in the list. Asserting the
  -- hit COUNT would be asserting how the ladder's windows overlap, which is not the claim.
  local mseen = false
  local mk
  if fftsa.nl.ring_cands ~= nil then
    for mk = 1, table.getn(fftsa.nl.ring_cands) do
      if fftsa.nl.ring_cands[mk].val0 == MOVER[1]
         or fftsa.nl.ring_cands[mk].val0 == MOVER[2] then mseen = true end
    end
  end
  check('a needle hit that moves between two searches is dropped as the self-hit',
        gm ~= nil and gm.val0 == RLO + 32 and not mseen
        and table.getn(fftsa.nl.ring_cands) == 1,
        gm == nil and ('nil, why=' .. tostring(fftsa.nl.ring_why))
        or string.format('val0=%X cands=%d mover=%s hits=%s', gm.val0,
                         table.getn(fftsa.nl.ring_cands), tostring(mseen),
                         tostring(fftsa.nl.ring_hits)))

  -- Restored, or every case below runs against the mock above and passes or fails for the
  -- wrong reason -- which is exactly what happened the first time.
  fftsa.nl.FINDS = FINDS_KEEP

  -- THE DECOY THAT MATTERS. The buffer-side staging ring holds the same two float32 pairs in a
  -- 28-byte record, written in the same order by the same append, and it is NOT what the widget
  -- draws -- writing it buys nothing and advancing its cursors ends in a modal 2350. It
  -- confirms at a stride just as convincingly, so the display ring has to be picked out by its
  -- header: the staging ring keeps its bounds at +0x8C and +0x94, which are not adjacent, so
  -- there is no pair to find. Placed BELOW the real ring so it is the first candidate.
  build(RLO, STRIDE, NREC, 32, 44, 40904)
  local STG = RLO - 131072
  local si
  for si = 1, table.getn(SENT) do
    local rec = STG + (si - 1) * 28
    local v = fftsa.nl._f32_pack(SENT[si].db)
    local x = fftsa.nl._f32_pack(SENT[si].hz)
    wrs(rec + 4, v .. v)
    wrs(rec + 16, x .. x)
  end
  -- Its bounds exist but eight bytes apart, as the subscription keeps them.
  wr32(STG - 256 + 140, STG)
  wr32(STG - 256 + 148, STG + 16 * 28)
  local gd = fftsa.nl.find_ring_records(SENT)
  check('a 28-byte staging record confirms a stride too, so there are two candidates',
        gd ~= nil and table.getn(fftsa.nl.ring_cands) >= 2,
        'candidates=' .. tostring(fftsa.nl.ring_cands and table.getn(fftsa.nl.ring_cands)))
  local gr = fftsa.nl.find_ring(SENT)
  check('find_ring picks the one with a header, not the first one found',
        gr ~= nil and gr.stride == STRIDE and gr.lo == RLO and gr.hdr == HDR,
        gr == nil and ('nil, why=' .. tostring(fftsa.nl.ring_why))
        or string.format('stride=%d lo=%X', gr.stride, gr.lo))

  -- A header whose bounds are not a whole number of records, which is the discriminator that
  -- separates the real pair from any other two adjacent pointers.
  build(RLO, STRIDE, NREC, 32, 44, 40904)
  wr32(HDR + 4, RLO + NREC * STRIDE + 4)
  local g3 = fftsa.nl.find_ring_records(SENT)
  check('a span that is not a whole number of records is not a header',
        g3 ~= nil and fftsa.nl.find_ring_header(g3) == nil
        and string.find(tostring(fftsa.nl.ring_why), 'no ring header', 1, true) ~= nil,
        'why=' .. tostring(fftsa.nl.ring_why))

  -- And a count larger than the ring holds, which is the other half of the same judgement.
  build(RLO, STRIDE, NREC, 32, 44, 40904)
  wr32(HDR + 20, NREC + 1)
  local g4 = fftsa.nl.find_ring_records(SENT)
  check('a count larger than the ring is not a header either',
        g4 ~= nil and fftsa.nl.find_ring_header(g4) == nil,
        'why=' .. tostring(fftsa.nl.ring_why))

  -- A record near the bottom of memory. The candidate bounds are derived from the record
  -- address less a whole ring, which goes negative there, and math.mod keeps the sign -- so
  -- string.char would be handed a negative byte and RAISE, inside bind, where nothing catches
  -- it. pcall is the assertion here: the answer has to be a refusal and not an error.
  local lowok, lowres = pcall(fftsa.nl.find_ring_header,
                              {val0 = 20000, stride = 56, dx = 12})
  check('a record below one ring from zero is refused, not raised',
        lowok and lowres == nil,
        'ok=' .. tostring(lowok) .. ' res=' .. tostring(lowres))

  fftsa.nl.arena = nil
  tostring = SAVEDT
end

-- ========================================================================================
-- A descriptor whose field offsets are not the ones measured on a DMM6500.
--
-- A DMM7510 1.7.16 confirmed element 0 against eleven readings, found 30 words holding that
-- address with the sweep covering the whole backstop, and matched the descriptor signature at
-- none of them. Two things explain that and they need opposite fixes: the words were never
-- actually read, or the layout is not the assumed one. The first is now counted by
-- nl.sweep_str; the second is what the derived pass answers, and a DMM6500 cannot exercise it
-- because its layout is the one being assumed.
--
-- So the fixture here is a descriptor laid out DIFFERENTLY -- storage pointer at +0x60, self
-- pointers at +0x6C and +0x7C, geometry at +0x18, count at +0x20, vector at +0x5C -- and
-- every one of those has to be recovered from the data. None of them is an input. The second
-- fixture puts the same descriptor back at the measured offsets, which must still be found by
-- the cheap route with nothing derived at all.
-- ========================================================================================

print('\nnl._derive_desc: a layout that is not the measured one')

do
  local SAVEDT = tostring
  -- A megabyte, so the ladder's last stage is 32 blocks rather than 8192. Which windows get
  -- swept is settled by the scan_windows cases above; what is under test here is what happens
  -- to a hit once the sweep returns it.
  fftsa.nl.BACKSTOP_LO, fftsa.nl.BACKSTOP_HI = 3145728, 4194304     -- 0x300000..0x400000

  local ELEM0  = 3211264     -- 0x310000, 8-aligned, as _find_storage requires
  local PAY1   = 3244032     -- 0x318000
  local PAY2   = 3276800     -- 0x320000
  local VEC    = 3342336     -- 0x330000, below the descriptor so its hit is examined first
  local DESC   = 3407872     -- 0x340000
  local ANCHOR = 3473408     -- 0x350000

  local IMG = {}
  local function be32(v)
    return string.char(math.floor(v / 16777216), math.mod(math.floor(v / 65536), 256),
                       math.mod(math.floor(v / 256), 256), math.mod(v, 256))
  end
  local function wr32(a, v) IMG[a] = be32(v) end
  local function wr64(a, x)
    local hi, lo = fftsa.nl._f64_words(x)
    IMG[a], IMG[a + 4] = be32(hi), be32(lo)
  end
  local SHORT = 0            -- when non-zero, every memread answers this many bytes at most
  ki.memread = function(ah, lh)
    local a, n = tonumber(ah, 16), tonumber(lh, 16)
    if a == nil or n == nil or n <= 0 then return nil end
    if SHORT > 0 and n > SHORT then n = SHORT end
    local w0 = a - math.mod(a, 4)
    local w1 = a + n + 3
    w1 = w1 - math.mod(w1, 4)
    local acc, k, p = {}, 0, nil
    for p = w0, w1 - 4, 4 do
      k = k + 1
      acc[k] = IMG[p] or '\0\0\0\0'
    end
    return string.sub(table.concat(acc), a - w0 + 1, a - w0 + n)
  end
  ki.peek32 = function(ah)
    local a = tonumber(ah, 16)
    local s = IMG[a]
    if s == nil then return '0' end
    return string.format('%X', ((string.byte(s, 1) * 256 + string.byte(s, 2)) * 256
                                + string.byte(s, 3)) * 256 + string.byte(s, 4))
  end
  tostring = function(v)
    if type(v) == 'table' and next(v) == nil then
      return 'table: ' .. string.format('%x', ANCHOR)
    end
    return SAVEDT(v)
  end

  -- Readings a content scan can confirm: six consecutive, index 64 and index 256, and three
  -- extra values at +20 inside the element. Values with no 0x31 byte in them, so none of them
  -- can be mistaken for the 0x00310000 the descriptor sweep is looking for.
  local RV = {0.125, 0.1875, 0.25, 0.375, 0.5, 0.625}
  RV[64], RV[256] = 1.5, 2.5
  local EV = {4.0, 8.0, 16.0}
  local BUF = {n = 256, capacity = 1024, readings = RV, extravalues = EV}

  local function place_record()
    local i, v
    for i, v in pairs(RV) do
      wr64(ELEM0 + (i - 1) * 32, v)
    end
    for i = 1, 3 do
      wr64(ELEM0 + (i - 1) * 32 + 20, EV[i])
    end
  end

  -- off is base-to-storage-pointer; the rest move with it so nothing in the fixture lines up
  -- with the measured layout by accident.
  local function place(o)
    IMG = {}
    place_record()
    wr32(VEC, ELEM0)
    wr32(VEC + 4, PAY1)
    wr32(VEC + 8, PAY2)
    wr32(DESC + o.stor, ELEM0)
    wr32(DESC + o.s1, DESC)
    wr32(DESC + o.s2, DESC)
    wr32(DESC + o.es, 32)
    wr32(DESC + o.pc, 1024)
    wr32(DESC + o.nc, 3)
    wr32(DESC + o.vec, VEC)
    fftsa.nl._desc_of, fftsa.nl._desc_at, fftsa.nl.arena = nil, nil, nil
    fftsa.nl._stor_of, fftsa.nl._stor_elem0 = nil, nil
  end

  local SHIFTED = {stor = 96, s1 = 108, s2 = 124, es = 24, pc = 28, nc = 32, vec = 92}
  place(SHIFTED)

  local d = fftsa.nl.describe(BUF, true)
  local o = fftsa.nl.desc_off
  check('finds a descriptor whose every offset differs from the measured one',
        d ~= nil and d.desc == DESC and d.vec == VEC and d.nchunks == 3
        and d.elemsize == 32 and d.perchunk == 1024,
        string.format('desc=%s vec=%s nc=%s es=%s why=%s der=%s',
                      d and string.format('%X', d.desc) or 'nil',
                      d and string.format('%X', d.vec) or 'nil',
                      d and tostring(d.nchunks) or 'nil',
                      d and tostring(d.elemsize) or 'nil',
                      tostring(fftsa.nl._stor_why), tostring(fftsa.nl._der_why)))

  check('and reports the offsets it derived, every one of them the fixture\'s',
        o ~= nil and o.stor == SHIFTED.stor and o.es == SHIFTED.es and o.pc == SHIFTED.pc
        and o.nc == SHIFTED.nc and o.vec == SHIFTED.vec,
        o and string.format('stor=%d es=%d pc=%d nc=%d vec=%d self=%d',
                            o.stor, o.es, o.pc, o.nc, o.vec, o.self_n) or 'nil')

  -- The one consequence that matters: the image's cursor rewind stores at displacements
  -- compiled into it, so a descriptor found this way must not be handed to it.
  check('a derived layout refuses the native cursor rewind',
        fftsa.nl.desc_off_ok(d) == false, fftsa.nl.desc_off_str())

  -- The chunk vector holds the storage address too, and its neighbourhood has no self-pointer
  -- pair. That hit has to be rejected on its own terms rather than by being second in the
  -- list, so it is asked directly.
  local vb = fftsa.nl._derive_desc(VEC, ELEM0, 32)
  check('the chunk vector\'s own copy of the address is refused, and says why',
        vb == nil and fftsa.nl._der_why ~= nil
        and string.find(fftsa.nl._der_why, 'self-pointer', 1, true) ~= nil,
        'base=' .. tostring(vb) .. ' why=' .. tostring(fftsa.nl._der_why))

  -- One self-pointer is not a descriptor. A single word equal to a nearby address turns up in
  -- ordinary allocator bookkeeping, and the measured shape has two.
  place(SHIFTED)
  wr32(DESC + SHIFTED.s2, 0)
  local one = fftsa.nl._derive_desc(DESC + SHIFTED.stor, ELEM0, 32)
  check('one self-pointer is refused where two are confirmed',
        one == nil, 'base=' .. tostring(one) .. ' why=' .. tostring(fftsa.nl._der_why))

  -- The element size has to be the stride the content scan measured. A descriptor whose
  -- geometry says something else is a different buffer's, and the pair it would answer with
  -- would be checked against the stride one step later anyway.
  place(SHIFTED)
  wr32(DESC + SHIFTED.es, 24)
  local wrongsz = fftsa.nl._derive_desc(DESC + SHIFTED.stor, ELEM0, 32)
  check('a geometry that disagrees with the measured stride is refused',
        wrongsz == nil and fftsa.nl._der_why ~= nil
        and string.find(fftsa.nl._der_why, 'elemsize', 1, true) ~= nil,
        'why=' .. tostring(fftsa.nl._der_why))

  -- The count must equal what the vector actually holds. A field that says four where three
  -- entries are plausible would have the caller read a fourth from whatever follows.
  place(SHIFTED)
  wr32(DESC + SHIFTED.nc, 4)
  local wrongnc = fftsa.nl._derive_desc(DESC + SHIFTED.stor, ELEM0, 32)
  check('a chunk count the vector does not support is refused',
        wrongnc == nil and fftsa.nl._der_why ~= nil
        and string.find(fftsa.nl._der_why, 'plausible entries', 1, true) ~= nil,
        'why=' .. tostring(fftsa.nl._der_why))

  -- AND THE OTHER HALF: the measured layout must still be found by the cheap route, with
  -- nothing derived. Otherwise a fix for the model that fails could have moved the model that
  -- works onto a path with more freedom in it.
  place(fftsa.nl.DOFF)
  local d2 = fftsa.nl.describe(BUF, true)
  check('the measured layout is still found without deriving anything',
        d2 ~= nil and d2.desc == DESC and fftsa.nl.desc_off == nil
        and fftsa.nl.desc_off_ok(d2) == true,
        string.format('desc=%s doff=%s win=%s',
                      d2 and string.format('%X', d2.desc) or 'nil',
                      fftsa.nl.desc_off_str(), tostring(fftsa.nl._win_hit)))

  -- A short read is the other explanation for "swept everything and found nothing", and the
  -- one that would make every count on the error page a lie.
  --
  -- The needle is planted in the part of the FIRST block that a short read did not return:
  -- the block starts at lo and SHORT bytes came back, so lo + SHORT + 8 is inside the block
  -- and past everything read. A sweep that advances by the length it ASKED for steps over
  -- that address and reports the needle absent, having read an eighth of memory.
  print('\nnl.FINDS with every read answering short')

  place(fftsa.nl.DOFF)
  SHORT = 4096
  local MARK = 1515806629                -- 0x5A5AA5A5, nowhere else in the fixture
  local LO = fftsa.nl.BACKSTOP_LO
  local GAP = LO + SHORT + 8
  wr32(GAP, MARK)
  fftsa.nl.sweep_reset()
  local h = fftsa.nl.FINDS(LO, LO + 131072, be32(MARK))
  local found, i = false, nil
  for i = 1, table.getn(h) do
    if h[i] == GAP then found = true end
  end
  check('a needle in the part of a block a short read did not return is still found',
        found, string.format('hits=%d at=%s %s', table.getn(h),
                             h[1] and string.format('%X', h[1]) or 'none',
                             fftsa.nl.sweep_str()))
  check('and the short reads are counted rather than passed over in silence',
        fftsa.nl._sw_short > 0 and fftsa.nl._sw_bytes > 0,
        fftsa.nl.sweep_str())
  SHORT = 0

  -- A block that cannot be read at all must advance the sweep, not spin on it. An unbounded
  -- loop in one TSP statement cannot be interrupted from the panel.
  local READ_OK = ki.memread
  ki.memread = function() return nil end
  fftsa.nl.sweep_reset()
  local none = fftsa.nl.FINDS(fftsa.nl.BACKSTOP_LO, fftsa.nl.BACKSTOP_LO + 131072,
                              be32(ELEM0))
  ki.memread = READ_OK
  check('a sweep whose reads all fail terminates, and reports that it read nothing',
        table.getn(none) == 0 and fftsa.nl._sw_nil == 4 and fftsa.nl._sw_bytes == 0,
        fftsa.nl.sweep_str())

  fftsa.nl.desc_off, fftsa.nl.arena = nil, nil
  tostring = SAVEDT
end

-- ---------------------------------------------------------------------------
print('\nthe pixel fill')
-- ---------------------------------------------------------------------------
--
-- The pixel path writes 40 KB into an address it derived at runtime, so what these cases are
-- for is the refusals. Every term standing between a candidate and that write is withdrawn in
-- turn: the bounds, the span, the residual, the slot map, the frequency series and the
-- firmware's own point. A term that stops being consulted fails here rather than on the glass.

do
  local SAVEDT = tostring
  -- The fixture's mock heap, declared live. px_live refuses a pointer outside the span this
  -- module has already dereferenced, which is what stops the table walk following a garbage
  -- widget pointer into unmapped memory -- PC=0022D200 on the glass. The mock has no such
  -- hazard, so the span is simply stated here.
  fftsa.nl.map_lo, fftsa.nl.map_hi = 4096, 134217728
  -- No image here, so nfind cannot answer and _finds_native declines; FINDS then uses the
  -- ladder, which PX_SWEEP permits for the suite only. That keeps the bind-time search tested
  -- while the app itself has no path to it.
  local SAVED_NF = fftsa.nl.nfind
  local SAVED_RDY, SAVED_FA = fftsa.nl.ready, fftsa.nl.find_addr
  fftsa.nl.BACKSTOP_LO, fftsa.nl.BACKSTOP_HI = 12288, 268435456

  -- The same word-sparse image as the ring cases, with a memwrite that lands in it so a
  -- read-back assertion means something.
  local IMG = {}
  local ZEROS = {}
  local function zeros(n)
    if ZEROS[n] == nil then ZEROS[n] = string.rep('\0', n) end
    return ZEROS[n]
  end
  local function wr32(a, v)
    IMG[a] = string.char(math.floor(v / 16777216), math.mod(math.floor(v / 65536), 256),
                         math.mod(math.floor(v / 256), 256), math.mod(v, 256))
  end
  local function wrs(a, s)
    local i
    for i = 0, string.len(s) / 4 - 1 do
      IMG[a + i * 4] = string.sub(s, i * 4 + 1, i * 4 + 4)
    end
  end
  local function touches(w0, w1)
    local p, _
    for p, _ in pairs(IMG) do
      if p >= w0 and p < w1 then return true end
    end
    return false
  end
  ki.memread = function(ah, lh)
    local a, n = tonumber(ah, 16), tonumber(lh, 16)
    if a == nil or n == nil or n <= 0 then return nil end
    local w0 = a - math.mod(a, 4)
    local w1 = a + n + 3
    w1 = w1 - math.mod(w1, 4)
    if not touches(w0, w1) then return zeros(n) end
    local acc, k, p = {}, 0, nil
    for p = w0, w1 - 4, 4 do
      k = k + 1
      acc[k] = IMG[p] or '\0\0\0\0'
    end
    return string.sub(table.concat(acc), a - w0 + 1, a - w0 + n)
  end
  -- nl._wg reads a word through peek32, and the header is read that way. Without this the
  -- header comes from the ring section's own image, which this fixture never wrote to -- and
  -- a count of zero reads as "this is not a ring" rather than as a harness gap.
  ki.peek32 = function(ah)
    local a = tonumber(ah, 16)
    local w = IMG[a]
    if w == nil then return '0' end
    return string.format('%X', ((string.byte(w, 1) * 256 + string.byte(w, 2)) * 256
                                + string.byte(w, 3)) * 256 + string.byte(w, 4))
  end
  local WROTE = nil
  ki.memwrite = function(ah, s)
    local a = tonumber(ah, 16)
    WROTE = { at = a, len = string.len(s) }
    local i
    for i = 0, string.len(s) - 1 do
      local p = a + i
      local w = p - math.mod(p, 4)
      local old = IMG[w] or '\0\0\0\0'
      local k = p - w + 1
      IMG[w] = string.sub(old, 1, k - 1) .. string.sub(s, i + 1, i + 1)
               .. string.sub(old, k + 1)
    end
    return true
  end

  -- THE IMAGE'S SEARCH, EMULATED, because it is the only search the app can reach.
  --
  -- The pixel path engages by pointer, by its cached geometry, or by the native search. The
  -- Lua sweep is not reachable from it and there is no knob that makes it so, so every case
  -- below that has to search drives this.
  --
  -- It answers the way nfind does and no better: at most FIND_MAX hits, then a resume address
  -- that is the next START POSITION nothing has examined -- so a needle straddling the end of
  -- one call is found by the next, which is what stops a short answer reading as an absence.
  -- And it costs no ki.memread, because the image loads memory directly rather than through
  -- the firmware's read, which is the whole reason it is fast enough to run in a frame.
  local NF_MAX = 32
  local nf_calls, nf_bytes = 0, 0
  local function img_bytes(a, n)
    local w0 = a - math.mod(a, 4)
    local w1 = a + n + 3
    w1 = w1 - math.mod(w1, 4)
    local acc, k, p = {}, 0, nil
    for p = w0, w1 - 4, 4 do
      k = k + 1
      acc[k] = IMG[p] or '\0\0\0\0'
    end
    return string.sub(table.concat(acc), a - w0 + 1, a - w0 + n)
  end
  local function nf_emu(lo, hi, pat, cap)
    fftsa.nl.find_why = nil
    if type(pat) ~= 'string' then
      fftsa.nl.find_why = 'needle is not a string'
      return nil
    end
    local plen = string.len(pat)
    if plen < 1 or plen > fftsa.nl.NFIND_PAT_MAX then
      fftsa.nl.find_why = 'needle is ' .. tostring(plen) .. ' bytes, not 1..'
                          .. tostring(fftsa.nl.NFIND_PAT_MAX)
      return nil
    end
    if type(lo) ~= 'number' or type(hi) ~= 'number' or hi <= lo then
      fftsa.nl.find_why = 'range is not lo < hi'
      return nil
    end
    local top = hi
    if cap ~= nil and cap > 0 and lo + cap < top then top = lo + cap end
    nf_calls = nf_calls + 1
    nf_bytes = nf_bytes + (top - lo)
    local out, n = {}, 0
    -- A block the image has never written is zeros, so only an all-zero needle can be in it.
    if touches(lo - math.mod(lo, 4), top + plen + 4)
       or string.find(pat, '[^%z]') == nil then
      local s = img_bytes(lo, top - lo + plen - 1)
      local at = 1
      while n < NF_MAX do
        local f = string.find(s, pat, at, true)
        if f == nil or lo + f - 1 >= top then break end
        n = n + 1
        out[n] = lo + f - 1
        at = f + 1
      end
    end
    if n >= NF_MAX then return out, out[n] + 1 end
    return out, top
  end
  fftsa.nl.nfind = nf_emu
  fftsa.nl.ready, fftsa.nl.find_addr = true, 4096

  local APPENDS = {}
  buffer.write = { reading = function(b, v, x, t, st)
    APPENDS[table.getn(APPENDS) + 1] = { buf = b, db = v, hz = x, t = t }
  end }

  -- A spectrum with a peak in it, which is the point. A ramp is affine in frequency, so the x
  -- pixel would fit the value field as well as the y pixel does and the two triples could not
  -- be told apart -- on this fixture or on an instrument fed a ramp.
  local DB = { -100, -92, -85, -40, -88, -95, -103, -110 }
  -- A bin width the instrument actually produces, and dyadic so every member is exact in
  -- float32. Round powers of two pack to one or two non-zero bytes, which makes a poor needle
  -- and a fixture that flatters px_xneedle.
  local HZ, NSEG = {}, 8
  do
    local j
    for j = 1, NSEG do HZ[j] = 195.3125 * j end
  end
  local AY, BY = -2, 94.25
  local function ypix(db) return math.floor(AY * db + BY + 0.5) end
  local function xpix(j) return 100 + 102 * j end

  -- The fold's order, which is what a pass writes: up the band and back down it.
  local ORD = {}
  do
    local j
    for j = 1, NSEG do ORD[j] = j end
    for j = 1, NSEG do ORD[NSEG + j] = NSEG + 1 - j end
  end

  -- The column px_xneedle picks, which is what the staging lookalike has to carry too.
  local XCOL = nil
  do
    local _, c = fftsa.nl.px_xneedle(HZ, NSEG)
    XCOL = c or 1
  end

  local RLO, STRIDE, NREC, OV, OX = 62206008, 56, 24, 32, 44
  local HDRAT = RLO - 40904
  local WSLOT = 4                     -- where the header's write cursor points
  -- Which spectrum column each slot carries. 24 slots over a 16-record pass, so the pattern
  -- does not divide the ring and the phase is what the cursor left behind.
  local PHASE = 5
  local function slot_index(s)
    return ORD[math.mod(s - 1 + PHASE, 2 * NSEG) + 1]
  end

  local function build(xf)
    IMG = {}
    wr32(HDRAT, RLO)
    wr32(HDRAT + 4, RLO + NREC * STRIDE)
    wr32(HDRAT + 8, RLO)
    wr32(HDRAT + fftsa.nl.HDR_WRITE, RLO + (WSLOT - 1) * STRIDE)
    wr32(HDRAT + fftsa.nl.HDR_COUNT, NREC)
    local s
    for s = 1, NREC do
      local rec = RLO + (s - 1) * STRIDE
      local j = slot_index(s)
      local v = fftsa.nl._f32_pack(DB[j])
      local x = fftsa.nl._f32_pack((xf or HZ)[j])
      local xp, yp = xpix(j), ypix(DB[j])
      wr32(rec, xp)
      wr32(rec + 4, xp)
      wr32(rec + 8, xp)
      wr32(rec + 12, yp)
      wr32(rec + 16, yp)
      wr32(rec + 20, yp)
      wrs(rec + OV, v .. v)
      wr32(rec + OV + 8, 0)
      wrs(rec + OX, x .. x)
      wr32(rec + OX + 8, 1073741824)
    end
    fftsa.nl.arena = RLO
  end
  local function geom()
    return { lo = RLO, hi = RLO + NREC * STRIDE, nrec = NREC, stride = STRIDE,
             ov = OV, ox = OX, hdr = HDRAT, dx = OX - OV }
  end

  -- THE STAGING-RING LOOKALIKE, which is what the real instrument has and this fixture did
  -- not. The buffer side pushes each append into a 28-byte record carrying the same two
  -- float32 pairs in the same order, so it confirms a stride exactly as the trace record does
  -- -- and 28 comes first in the REC_MIN..REC_MAX walk. It has no header, so it is the
  -- candidate that must be rejected without losing the real one found in the same slice.
  --
  -- A kilobyte below the ring, which puts both inside one 4 KB sweep slice, and outside the
  -- ring's own bounds so the real header cannot be mistaken for its.
  local SLO = RLO - 1024
  local function stage()
    local i
    for i = 1, 4 do
      local rec = SLO + (i - 1) * 28
      local v = fftsa.nl._f32_pack(DB[i])
      local x = fftsa.nl._f32_pack(HZ[XCOL + i - 1])
      wrs(rec, x .. x)
      wrs(rec + 8, v .. v)
    end
  end
  local function ringbytes()
    return ki.memread(string.format('%X', RLO), string.format('%X', NREC * STRIDE))
  end

  -- A SECOND fixture, shaped like a real trace object: the buffer's name near the front, the
  -- bounds and cursors at +0x1F0, and the ring immediately past them at +0x220. The first
  -- fixture deliberately puts its header 40 KB from its ring, which is what gates the record
  -- route's header search over a distance; this one gates the name route, whose whole claim is
  -- that the geometry follows from the name by a short walk.
  local TLO = RLO - 1048576          -- a megabyte clear of the other fixture
  local TNAME, TBOUND, TRING = TLO + 8, TLO + 496, TLO + 544   -- 0x08, 0x1F0, 0x220
  local function tracefix()
    local nm = fftsa.nl.PX_NAME .. string.char(0)
    local i
    for i = 0, string.len(nm) - 1 do
      local a = TNAME + i
      local w = a - math.mod(a, 4)
      local old4 = IMG[w] or '\0\0\0\0'
      local k = a - w + 1
      IMG[w] = string.sub(old4, 1, k - 1) .. string.sub(nm, i + 1, i + 1)
               .. string.sub(old4, k + 1)
    end
    wr32(TBOUND, TRING)
    wr32(TBOUND + 4, TRING + NREC * STRIDE)
    wr32(TBOUND + fftsa.nl.HDR_OLD, TRING)
    wr32(TBOUND + fftsa.nl.HDR_WRITE, TRING + (WSLOT - 1) * STRIDE)
    wr32(TBOUND + fftsa.nl.HDR_COUNT, NREC)
    local s
    for s = 1, NREC do
      local rec = TRING + (s - 1) * STRIDE
      local j = slot_index(s)
      local v = fftsa.nl._f32_pack(DB[j])
      local x = fftsa.nl._f32_pack(HZ[j])
      local xp, yp = xpix(j), ypix(DB[j])
      wr32(rec, xp)
      wr32(rec + 4, xp)
      wr32(rec + 8, xp)
      wr32(rec + 12, yp)
      wr32(rec + 16, yp)
      wr32(rec + 20, yp)
      wrs(rec + OV, v .. v)
      wr32(rec + OV + 8, 0)
      wrs(rec + OX, x .. x)
      wr32(rec + OX + 8, 1073741824)
    end
  end

  fftsa.nl.RING_MIN = 8
  build(nil)

  -- ---- the triples, and the fit ----------------------------------------------
  local rec1 = ki.memread(string.format('%X', RLO), string.format('%X', STRIDE))
  local tr = fftsa.nl.px_triples(rec1, STRIDE)
  check('both pixel triples are found in a record, and nothing else is',
        table.getn(tr) == 2 and tr[1] == 0 and tr[2] == 12,
        'offsets ' .. table.concat(tr, ','))

  do
    -- Four equal words in a row report ONE triple, not two. A y pixel of zero beside the two
    -- zero words is exactly that, and the second offset would be three quarters padding.
    local t2 = fftsa.nl.px_triples(string.rep('\0', 24) .. string.sub(rec1, 25), STRIDE)
    check('a run of equal words past three reports one triple, not an overlapping pair',
          table.getn(t2) == 1 and t2[1] == 0, 'offsets ' .. table.concat(t2, ','))
  end

  do
    local blk = ringbytes()
    local nl = fftsa.nl
    local vals = nl.px_floats(blk, NREC, STRIDE, OV)
    local a, b, w, sp, m = nl.px_fit(nl.px_words(blk, NREC, STRIDE, 12), vals, NREC)
    check('the decibel map is recovered from the records the appends left',
          a ~= nil and math.abs(a - AY) < 0.01 and math.abs(b - BY) < 1.0
          and w <= 1.0 and m == NREC,
          string.format('y = %.4f*db %+.3f, worst %.2f px, span %.0f dB, n=%d',
                        a or 0, b or 0, w or -1, sp or -1, m or -1))
    local ax, _, wx = nl.px_fit(nl.px_words(blk, NREC, STRIDE, 0), vals, NREC)
    check('the x triple does not fit the value field',
          ax ~= nil and wx > nl.PX_RESID_MAX,
          string.format('the x triple fitted against the value is %.1f px out', wx or -1))
    -- And the other way round, which is the test that NAMES the x triple: the x pixel is an
    -- affine function of the frequency in the same record whatever the spectrum does, and the
    -- y pixel is not unless the trace is a straight line.
    local freq, s = {}, nil
    for s = 1, NREC do freq[s] = HZ[slot_index(s)] end
    local _, _, wxf = nl.px_fit(nl.px_words(blk, NREC, STRIDE, 0), freq, NREC)
    local _, _, wyf = nl.px_fit(nl.px_words(blk, NREC, STRIDE, 12), freq, NREC)
    check('against frequency the x triple fits and the y triple does not',
          wxf <= nl.PX_RESID_MAX and wyf > nl.PX_RESID_MAX,
          string.format('x %.2f px, y %.1f px', wxf, wyf))
    -- A constant field fits nothing, which is what keeps the two zero words out of the
    -- value-field search: they would otherwise be an affine map with every slope.
    local zero = {}
    for s = 1, NREC do zero[s] = 0 end
    check('a constant independent variable is refused outright',
          nl.px_fit(nl.px_words(blk, NREC, STRIDE, 12), zero, NREC) == nil)
  end

  -- ---- the map ---------------------------------------------------------------
  do
    fftsa.nl.px_restart('test')
    local ok = fftsa.nl.px_map(geom(), HZ, NSEG)
    local p = fftsa.nl.px
    local good, s = true, nil
    for s = 1, NREC do
      if p.idx == nil or p.idx[s] ~= slot_index(s) then good = false end
    end
    check('the map solves the y triple, the decibel map and every slot of the ring',
          ok and p.yoff == 12 and math.abs(p.ay - AY) < 0.01 and good
          and table.getn(p.T) == 3 * NREC,
          ok and string.format('yoff=%s ay=%.3f slots=%s', tostring(p.yoff), p.ay or 0,
                               tostring(good))
          or ('refused: ' .. tostring(p.why)))
    -- The three pieces a record have to reassemble into exactly what was read, or the write
    -- lays down a block differing from the ring outside the y triples.
    local re = table.concat(p.T)
    check('the sliced pieces reassemble byte for byte into the ring they came from',
          re == ringbytes(), string.format('%d bytes of %d', string.len(re), NREC * STRIDE))
  end

  do
    -- A slot carrying a frequency this plan does not have. Ordinary right after a retune, and
    -- the map has to refuse rather than draw that column from whatever index it guessed.
    build(nil)
    wrs(RLO + 2 * STRIDE + OX, fftsa.nl._f32_pack(999) .. fftsa.nl._f32_pack(999))
    fftsa.nl.px_restart('test')
    local ok = fftsa.nl.px_map(geom(), HZ, NSEG)
    check('a slot whose frequency is not in this plan refuses the whole map',
          not ok and string.find(tostring(fftsa.nl.px.why), 'frequency', 1, true) ~= nil,
          'why=' .. tostring(fftsa.nl.px.why))
    build(nil)
  end

  do
    -- Out of the backstop. This is the one term between an address derived from a search and a
    -- memcpy into whatever happens to be there, so the header is consistent and only the
    -- addresses are wrong -- a header that merely failed to parse would pass this case for the
    -- wrong reason.
    build(nil)
    wr32(HDRAT, 8)
    wr32(HDRAT + 4, 8 + NREC * STRIDE)
    wr32(HDRAT + fftsa.nl.HDR_OLD, 8)
    wr32(HDRAT + fftsa.nl.HDR_COUNT, NREC)
    local g = geom()
    g.lo, g.hi = 8, 8 + NREC * STRIDE
    fftsa.nl.px_restart('test')
    check('a window below the backstop is refused before a byte is written',
          not fftsa.nl.px_map(g, HZ, NSEG)
          and string.find(tostring(fftsa.nl.px.why), 'backstop', 1, true) ~= nil,
          'why=' .. tostring(fftsa.nl.px.why))
    build(nil)
  end

  do
    -- A narrow span. Pixels are integers, so a few decibels fit a slope badly while the points
    -- left out of the fit still agree -- a residual test alone passes this, and the span test
    -- is what catches it.
    local keep, flat, j = DB, {}, nil
    for j = 1, NSEG do flat[j] = -100 - j * 0.25 end
    DB = flat
    build(nil)
    fftsa.nl.px_restart('test')
    -- A flat trace has no decibel map in it to fit. The x pixel is still identified -- it
    -- sweeps the plot however flat the trace is -- and the refusal lands on the value field,
    -- which is where it belongs: a slope fitted over two decibels of noise would put every
    -- column within a few rows of one another on a plot 280 rows tall.
    check('a spectrum too flat to carry a decibel map is refused',
          not fftsa.nl.px_map(geom(), HZ, NSEG),
          'why=' .. tostring(fftsa.nl.px.why))
    DB = keep
    build(nil)
  end

  -- ---- the frame -------------------------------------------------------------
  do
    fftsa.nl.px_restart('test')
    check('the map stands up on the fixture before the frame cases run',
          fftsa.nl.px_map(geom(), HZ, NSEG), 'why=' .. tostring(fftsa.nl.px.why))
    local before = ringbytes()
    -- A spectrum 6 dB up, so every y moves and nothing else may.
    local up, j = {}, nil
    for j = 1, NSEG do up[j] = DB[j] + 6 end
    APPENDS, WROTE = {}, nil
    local n = fftsa.nl.px_frame(up, HZ, NSEG, 'TB', 7777)
    local after = ringbytes()
    check('one frame is one memwrite of the whole ring',
          n == NSEG and WROTE ~= nil and WROTE.at == RLO and WROTE.len == NREC * STRIDE,
          WROTE and string.format('n=%s at %X, %d bytes', tostring(n), WROTE.at, WROTE.len)
          or 'nothing was written')
    local yok, elsewhere, s = true, 0, nil
    for s = 1, NREC do
      local o = (s - 1) * STRIDE
      local want = ypix(up[slot_index(s)])
      local k
      for k = 0, 2 do
        local p = o + 13 + k * 4
        if (((string.byte(after, p) * 256 + string.byte(after, p + 1)) * 256
             + string.byte(after, p + 2)) * 256) + string.byte(after, p + 3) ~= want then
          yok = false
        end
      end
      if string.sub(after, o + 1, o + 12) ~= string.sub(before, o + 1, o + 12)
         or string.sub(after, o + 25, o + STRIDE)
            ~= string.sub(before, o + 25, o + STRIDE) then
        elsewhere = elsewhere + 1
      end
    end
    check('every y triple is the predicted pixel, in all three copies', yok)
    check('no byte outside a y triple is touched',
          elsewhere == 0, tostring(elsewhere) .. ' records changed elsewhere')
    -- ONE append, and the write cursor parked one slot PAST the drawn window so the record it
    -- leaves is never drawn. That is what makes the provoking append free of any effect on the
    -- picture, and it leaves one record in the ring this code never overwrites -- which is
    -- where the firmware's own pixel is read back from to check the map.
    local wrword = ki.memread(string.format('%X', HDRAT + fftsa.nl.HDR_WRITE),
                              string.format('%X', 4))
    local wr = (((string.byte(wrword, 1) * 256 + string.byte(wrword, 2)) * 256
                 + string.byte(wrword, 3)) * 256) + string.byte(wrword, 4)
    check('one append, with the cursor parked one slot past the drawn window',
          table.getn(APPENDS) == 1 and APPENDS[1].t == 7777 and APPENDS[1].buf == 'TB'
          and wr == RLO + NREC * STRIDE,
          table.getn(APPENDS) == 1
          and string.format('%d append(s), db=%s hz=%s t=%s, cursor at %X wanted %X',
                            table.getn(APPENDS), tostring(APPENDS[1].db),
                            tostring(APPENDS[1].hz), tostring(APPENDS[1].t), wr,
                            RLO + NREC * STRIDE)
          or (tostring(table.getn(APPENDS)) .. ' appends'))
    -- THE CURSOR REPAINT: no append at all, which is the point of it. The append is what
    -- moves the display task's oldest-record cursor, and a drawn window that does not start
    -- at the ring base runs its x values backwards once -- the wrap measured on the glass at
    -- 8.72. A frame that still appends in cursor mode would bring it straight back.
    do
      local saved_mode = fftsa.sg_pix_repaint
      local saved_graph = display.graph
      local curs = {}
      display.graph = { cursor = function(g, ty, a, b)
        curs[table.getn(curs) + 1] = { g = g, ty = ty, a = a, b = b }
      end }
      fftsa.sg_pix_repaint = 'cursor'
      APPENDS = {}
      fftsa.nl.px.gid = 52
      local nc = fftsa.nl.px_frame(DB, HZ, NSEG, 'TB', 8888)
      check('the cursor repaint draws the pass and appends NOTHING',
            nc == NSEG and table.getn(APPENDS) == 0 and table.getn(curs) == 1
            and curs[1].g == 52,
            string.format('n=%s appends=%d cursors=%d g=%s', tostring(nc),
                          table.getn(APPENDS), table.getn(curs),
                          table.getn(curs) > 0 and tostring(curs[1].g) or 'none'))
      -- 9e37 is the firmware's OFF sentinel, so the cursor draws nothing. A real position
      -- would put a line on the plot every frame.
      check('and it sets the cursor to the off sentinel rather than a position',
            table.getn(curs) == 1 and curs[1].a >= 9e37 and curs[1].b >= 9e37
            and curs[1].ty == display.CURSOR_VERTICAL,
            table.getn(curs) > 0 and string.format('ty=%s a=%s b=%s', tostring(curs[1].ty),
                                                   tostring(curs[1].a), tostring(curs[1].b))
            or 'no cursor call')
      -- A refused cursor keeps the path and skips the repaint: the pixels for the pass are
      -- already in the ring, so the glass keeps the previous picture for a frame and the next
      -- cursor shows both. Tearing the map down over one refusal costs a re-map and the frames
      -- of appending with it, which reads as a frame rate that will not settle. What it must
      -- never do is append, because the append is what wraps the trace.
      display.graph = { cursor = function() error('refused') end }
      APPENDS = {}
      local re0 = fftsa.nl.px.restarts or 0
      local nb = fftsa.nl.px_frame(DB, HZ, NSEG, 'TB', 8889)
      check('one refused cursor skips the repaint, keeps the map and appends nothing',
            nb == NSEG and table.getn(APPENDS) == 0
            and fftsa.nl.px.curfail == 1 and (fftsa.nl.px.restarts or 0) == re0,
            string.format('n=%s appends=%d curfail=%s restarts %s->%s', tostring(nb),
                          table.getn(APPENDS), tostring(fftsa.nl.px.curfail),
                          tostring(re0), tostring(fftsa.nl.px.restarts)))
      -- A RUN of them is different: the GUI is not going to answer and the map is worth
      -- nothing without a repaint, so the path comes down.
      local nc2, run = nil, nil
      for run = 2, fftsa.nl.PX_CURSOR_RUN do
        nc2 = fftsa.nl.px_frame(DB, HZ, NSEG, 'TB', 8889 + run)
      end
      check('a run of PX_CURSOR_RUN refusals tears the path down, still without appending',
            nc2 == nil and table.getn(APPENDS) == 0
            and (fftsa.nl.px.restarts or 0) == re0 + 1
            and fftsa.nl.px.state == 'idle'
            and string.find(tostring(fftsa.nl.px.whyframe), 'refused', 1, true) ~= nil,
            string.format('n=%s appends=%d state=%s restarts %s->%s why=%s', tostring(nc2),
                          table.getn(APPENDS), tostring(fftsa.nl.px.state), tostring(re0),
                          tostring(fftsa.nl.px.restarts),
                          tostring(fftsa.nl.px.whyframe or fftsa.nl.px.why)))
      fftsa.sg_pix_repaint = saved_mode
      display.graph = saved_graph
      fftsa.nl.px.gid = nil
    end

    -- And the window itself is put back, which is the thing that makes a second frame possible.
    local oldword = ki.memread(string.format('%X', HDRAT + fftsa.nl.HDR_OLD),
                               string.format('%X', 4))
    local o0 = (((string.byte(oldword, 1) * 256 + string.byte(oldword, 2)) * 256
                 + string.byte(oldword, 3)) * 256) + string.byte(oldword, 4)
    check('and the drawn window is put back where the map found it',
          o0 == RLO, string.format('oldest %X wanted %X', o0, RLO))
    build(nil)
  end

  do
    -- The plan moving under the map. nseg is the obvious one; the frequency series moving with
    -- nseg unchanged is the one that would otherwise draw the new spectrum at the old
    -- frequencies, correctly and silently.
    fftsa.nl.px_restart('test')
    assert(fftsa.nl.px_map(geom(), HZ, NSEG))
    check('a changed nseg restarts rather than drawing',
          fftsa.nl.px_frame(DB, HZ, NSEG - 1, 'TB', 1) == nil
          and fftsa.nl.px.state == 'idle', 'why=' .. tostring(fftsa.nl.px.why))
    fftsa.nl.px_restart('test')
    assert(fftsa.nl.px_map(geom(), HZ, NSEG))
    local moved, j = {}, nil
    for j = 1, NSEG do moved[j] = HZ[j] + 1 end
    -- With re-pointing off, which is what the knob is for: the series moved and the path has
    -- no way to follow it, so it must restart rather than draw the new spectrum at the old
    -- frequencies, correctly and silently.
    local keeprp = fftsa.nl.PX_REPOINT
    fftsa.nl.PX_REPOINT = false
    check('a moved frequency series restarts rather than drawing',
          fftsa.nl.px_frame(DB, moved, NSEG, 'TB', 1) == nil
          and fftsa.nl.px.state == 'idle', 'why=' .. tostring(fftsa.nl.px.why))
    fftsa.nl.PX_REPOINT = keeprp
  end

  do
    -- The map going stale, which is the only thing that can happen once the appends stop:
    -- nothing else on the instrument computes a pixel, so the one append's own answer is the
    -- whole check. One frame out of tolerance must not be enough to drop the path.
    build(nil)
    fftsa.nl.px_restart('test')
    assert(fftsa.nl.px_map(geom(), HZ, NSEG))
    fftsa.nl.px.state = 'on'          -- what px_try sets once the map stands up
    -- Driven the way sg_pix_draw drives it: px_frame is called only while the state is 'on',
    -- so a drop ends the run rather than being followed by a frame that restarts for its own
    -- reasons and overwrites the reason under test.
    local k, dropped = nil, nil
    for k = 1, fftsa.nl.PX_DRIFT_RUN + 2 do
      if dropped ~= nil then break end
      fftsa.nl.px_frame(DB, HZ, NSEG, 'TB', 1000 + k)
      -- The firmware's answer for the slot just appended, 40 px off what the map predicts.
      if fftsa.nl.px.slot ~= nil then
        wr32(RLO + (fftsa.nl.px.slot - 1) * STRIDE + 12,
             ypix(fftsa.nl.px.slotdb) + 40)
      end
      if dropped == nil and fftsa.nl.px.state ~= 'on' then dropped = k end
    end
    -- Frame 1 has no previous point to check, so the first disagreement is seen on frame 2 and
    -- the run completes on frame PX_DRIFT_RUN + 1. Dropping sooner would mean one rounding
    -- edge could cost the path; dropping later, or never, means a stale map keeps drawing.
    check('the map is dropped after a run of disagreeing frames, and not on one of them',
          dropped == fftsa.nl.PX_DRIFT_RUN + 1
          and string.find(tostring(fftsa.nl.px.why), 'px out', 1, true) ~= nil,
          'dropped on frame ' .. tostring(dropped) .. ' of '
          .. tostring(fftsa.nl.PX_DRIFT_RUN + 2) .. ', why=' .. tostring(fftsa.nl.px.why))
    build(nil)
  end

  -- ---- the ring write in the image -------------------------------------------
  --
  -- The write itself is a loop in dsp_native.c and cannot run here. What the Lua side owns
  -- can be gated, and all of it is: the block the image reads, the refusals that keep a bad
  -- block out of it, and -- the one that is a correctness question and not a format one --
  -- which writer lays the ring down on a frame that re-pointed the series.
  do
    -- The block's shape comes out of the generated module, not out of this file. A build that
    -- stops emitting it fails here instead of leaving these gates testing nothing.
    local fh = io.open('tsp/native_code.tsp', 'r')
    local gen = ''
    if fh ~= nil then
      gen = fh:read('*a')
      fh:close()
    end
    local _, _, gw = string.find(gen, 'fftsa%.nl%.PX_WORDS = (%d+)')
    local _, _, gm = string.find(gen, 'fftsa%.nl%.PX_MAXREC = (%d+)')
    local _, _, gh = string.find(gen, 'fftsa%.nl%.PX_HDR = (%d+)')
    check('the generated module carries the ring block shape the image compiled',
          gw ~= nil and gm ~= nil and gh ~= nil
          and tonumber(gh) + tonumber(gm) == tonumber(gw) and tonumber(gm) > NREC,
          string.format('words=%s hdr=%s map=%s', tostring(gw), tostring(gh), tostring(gm)))

    local keepW, keepM, keepH = fftsa.nl.PX_WORDS, fftsa.nl.PX_MAXREC, fftsa.nl.PX_HDR
    local keepP, keepCN = fftsa.nl.px_addr, fftsa.nl.call_native
    fftsa.nl.PX_WORDS  = tonumber(gw) or 0
    fftsa.nl.PX_MAXREC = tonumber(gm) or 0
    fftsa.nl.PX_HDR    = tonumber(gh) or 0
    -- Clear of the ring, of the staging lookalike and of the trace fixture below it.
    local PXAT = RLO + NREC * STRIDE + 4096
    fftsa.nl.px_addr = PXAT

    -- The image, as a return code this suite chooses. Nothing here executes PowerPC.
    local calls, answer = 0, nil
    fftsa.nl.call_native = function()
      calls = calls + 1
      return answer
    end
    -- Every write, in order, because the question these gates ask is WHICH write happened.
    local MW = {}
    local realmw = ki.memwrite
    ki.memwrite = function(ah, s)
      MW[table.getn(MW) + 1] = { at = tonumber(ah, 16), len = string.len(s) }
      return realmw(ah, s)
    end
    local function wrote_ring()
      local i
      for i = 1, table.getn(MW) do
        if MW[i].at == RLO and MW[i].len == NREC * STRIDE then return true end
      end
      return false
    end
    local function bword(blk, i)
      local o = i * 4
      return (((string.byte(blk, o + 1) * 256 + string.byte(blk, o + 2)) * 256
               + string.byte(blk, o + 3)) * 256) + string.byte(blk, o + 4)
    end
    local function blockbytes()
      return ki.memread(string.format('%X', PXAT),
                        string.format('%X', (fftsa.nl.PX_HDR + NREC) * 4))
    end

    do
      build(nil)
      fftsa.nl.px_restart('test')
      assert(fftsa.nl.px_map(geom(), HZ, NSEG))
      local p = fftsa.nl.px
      local blk = blockbytes()
      local ayh, ayl = fftsa.nl._f64_words(p.ay)
      local byh, byl = fftsa.nl._f64_words(p.by)
      local hdrok = bword(blk, 3) == STRIDE and bword(blk, 4) == p.yoff
                    and bword(blk, 5) == NREC and bword(blk, 6) == fftsa.nl.PX_YMAX
                    and bword(blk, 7) == ayh and bword(blk, 8) == ayl
                    and bword(blk, 9) == byh and bword(blk, 10) == byl
      local mapok, s = true, nil
      for s = 1, NREC do
        if bword(blk, fftsa.nl.PX_HDR + s - 1) ~= slot_index(s) then mapok = false end
      end
      check('the ring block carries the geometry, the row map and one column per slot',
            p.nat == true and hdrok and mapok,
            string.format('nat=%s why=%s stride=%d y@%d nrec=%d ymax=%d map=%s',
                          tostring(p.nat), tostring(p.nat_why), bword(blk, 3),
                          bword(blk, 4), bword(blk, 5), bword(blk, 6), tostring(mapok)))
    end

    do
      -- THE WINDOW IS THE RING AND THE RECORDS ARE THE DRAWN WINDOW, which are two different
      -- things from two different sources: the bounds pair in the trace object, and the ring
      -- header's own oldest and count. Made to differ here on purpose -- on the fixture they
      -- coincide, so a block that declared the drawn window as its window would pass every
      -- other gate in this file and let a crept header carry the write out of the ring.
      build(nil)
      wr32(HDRAT + fftsa.nl.HDR_OLD, RLO + STRIDE)
      wr32(HDRAT + fftsa.nl.HDR_COUNT, NREC - 1)
      fftsa.nl.px_restart('test')
      assert(fftsa.nl.px_map(geom(), HZ, NSEG))
      local blk = ki.memread(string.format('%X', PXAT), string.format('%X', 24))
      check('the block declares the whole ring and writes the drawn window inside it',
            fftsa.nl.px.nat == true
            and bword(blk, 0) == RLO and bword(blk, 1) == RLO + NREC * STRIDE
            and bword(blk, 2) == RLO + STRIDE and bword(blk, 5) == NREC - 1,
            string.format('window %X..%X, %d records from %X; ring is %X..%X',
                          bword(blk, 0), bword(blk, 1), bword(blk, 5), bword(blk, 2),
                          RLO, RLO + NREC * STRIDE))
      build(nil)
    end

    do
      -- A drawn window longer than the map the image compiled room for. Refused, and the
      -- frame stays on the Lua writer rather than calling with a block the image will read
      -- past the end of.
      build(nil)
      fftsa.nl.PX_MAXREC = NREC - 1
      fftsa.nl.px_restart('test')
      assert(fftsa.nl.px_map(geom(), HZ, NSEG))
      check('a drawn window longer than the image holds refuses the block, and says so',
            fftsa.nl.px.nat == false
            and string.find(tostring(fftsa.nl.px.nat_why), 'records', 1, true) ~= nil,
            'nat=' .. tostring(fftsa.nl.px.nat) .. ' why=' .. tostring(fftsa.nl.px.nat_why))
      fftsa.nl.PX_MAXREC = tonumber(gm) or 0
    end

    do
      -- A slot naming a column the spectrum does not have. px_map cannot produce one -- it
      -- refuses a frequency that is not in the plan -- so this is reached by corrupting the
      -- map it built, which is what a future route that derived idx some other way would do.
      build(nil)
      fftsa.nl.px_restart('test')
      assert(fftsa.nl.px_map(geom(), HZ, NSEG))
      fftsa.nl.px.idx[3] = NSEG + 1
      check('a slot naming a column the spectrum does not have refuses the block',
            fftsa.nl.px_block() == false
            and string.find(tostring(fftsa.nl.px.nat_why), 'slot 3', 1, true) ~= nil,
            'why=' .. tostring(fftsa.nl.px.nat_why))
    end

    do
      -- The satisfied call: the image writes the ring and Lua does not. The 28 KB block write
      -- is the whole saving, so its absence is the gate.
      build(nil)
      fftsa.nl.px_restart('test')
      assert(fftsa.nl.px_map(geom(), HZ, NSEG))
      MW, calls, answer = {}, 0, NREC
      local n = fftsa.nl.px_frame(DB, HZ, NSEG, 'TB', 4001)
      check('an answered ring write draws the frame and Lua writes no block',
            n == NSEG and calls == 1 and not wrote_ring()
            and fftsa.nl.px.natwrote == 1,
            string.format('n=%s calls=%d blockwrite=%s nw=%s', tostring(n), calls,
                          tostring(wrote_ring()), tostring(fftsa.nl.px.natwrote)))
    end

    do
      -- A REFUSAL COSTS THE CALL AND NOT THE PICTURE. The Lua writer runs in the same frame,
      -- so the ring is still complete; and the path stops asking, because a refusal that
      -- repeated would pay for the call on top of the write every frame for the session.
      build(nil)
      fftsa.nl.px_restart('test')
      assert(fftsa.nl.px_map(geom(), HZ, NSEG))
      MW, calls, answer = {}, 0, fftsa.nl.RC.EBOUNDS
      local n = fftsa.nl.px_frame(DB, HZ, NSEG, 'TB', 4002)
      local first = calls
      local drawn = wrote_ring()
      MW = {}
      local n2 = fftsa.nl.px_frame(DB, HZ, NSEG, 'TB', 4003)
      check('a refused ring write draws from Lua, retires itself and keeps the reason',
            n == NSEG and first == 1 and drawn and n2 == NSEG and calls == 1
            and wrote_ring() and fftsa.nl.px.nat == false
            and string.find(fftsa.nl.px_str(), 'nw=0/', 1, true) ~= nil,
            string.format('n=%s/%s calls=%d drawn=%s,%s nat=%s why=%s', tostring(n),
                          tostring(n2), calls, tostring(drawn), tostring(wrote_ring()),
                          tostring(fftsa.nl.px.nat), tostring(fftsa.nl.px.nat_why)))
    end

    do
      -- The knob, which is live because the comparison is made on the glass: it gates the
      -- call and not the block, so a session that came up with it off can be turned on
      -- without a relaunch.
      build(nil)
      fftsa.nl.px_restart('test')
      assert(fftsa.nl.px_map(geom(), HZ, NSEG))
      local keepk = fftsa.nl.PX_NATIVE
      fftsa.nl.PX_NATIVE = false
      MW, calls, answer = {}, 0, NREC
      local noff = fftsa.nl.px_frame(DB, HZ, NSEG, 'TB', 4010)
      local off_lua, off_calls = wrote_ring(), calls
      local off_page = string.find(fftsa.nl.px_str(), 'nw=off', 1, true) ~= nil
      fftsa.nl.PX_NATIVE = true
      MW, calls = {}, 0
      local non = fftsa.nl.px_frame(DB, HZ, NSEG, 'TB', 4011)
      check('the writer knob is live in both directions, with no re-map between',
            noff == NSEG and off_lua and off_calls == 0 and off_page
            and non == NSEG and calls == 1 and not wrote_ring(),
            string.format('off: lua=%s calls=%d page=%s; on: lua=%s calls=%d',
                          tostring(off_lua), off_calls, tostring(off_page),
                          tostring(wrote_ring()), calls))
      fftsa.nl.PX_NATIVE = keepk
    end

    do
      -- THE SAVING, AS A GATE. An engaged frame must not decode the decibels at all: the
      -- image writes the ring from the same array in the arena, and 255 values at a float
      -- decode each is about 8.5 ms of a frame -- the whole cost back again if Lua reads
      -- them for nothing.
      --
      -- Driven with an EMPTY db, which is exactly what nl.reduce now hands a frame: a reader
      -- gets nil on its first index rather than the last frame's spectrum, so a path that
      -- forgot to ask fails loudly instead of drawing a frozen trace.
      build(nil)
      fftsa.nl.px_restart('test')
      assert(fftsa.nl.px_map(geom(), HZ, NSEG))
      local saved_graph, keeprp = display.graph, fftsa.sg_pix_repaint
      display.graph = { cursor = function() end }
      fftsa.sg_pix_repaint = 'cursor'
      fftsa.nl.px.gid = 52
      local keepdn, dncalls = fftsa.nl.db_now, 0
      fftsa.nl.db_now = function(d)
        dncalls = dncalls + 1
        return DB
      end
      MW, calls, answer, APPENDS = {}, 0, NREC, {}
      local n = fftsa.nl.px_frame({}, HZ, NSEG, 'TB', 4020)
      check('an engaged frame draws without decoding the decibels at all',
            n == NSEG and calls == 1 and dncalls == 0 and not wrote_ring()
            and table.getn(APPENDS) == 0,
            string.format('n=%s calls=%d decodes=%d lua=%s appends=%d', tostring(n), calls,
                          dncalls, tostring(wrote_ring()), table.getn(APPENDS)))

      -- And the fallback DOES decode them, once, and draws from what it decoded -- which is
      -- what makes the skip safe rather than merely cheap.
      MW, calls, answer, dncalls = {}, 0, fftsa.nl.RC.EBOUNDS, 0
      local n2 = fftsa.nl.px_frame({}, HZ, NSEG, 'TB', 4021)
      local after = ringbytes()
      local yok, s = true, nil
      for s = 1, NREC do
        local o = (s - 1) * STRIDE
        local want = ypix(DB[slot_index(s)])
        if (((string.byte(after, o + 13) * 256 + string.byte(after, o + 14)) * 256
             + string.byte(after, o + 15)) * 256) + string.byte(after, o + 16) ~= want then
          yok = false
        end
      end
      check('a frame that falls back to Lua decodes them once and draws from them',
            n2 == NSEG and dncalls == 1 and wrote_ring() and yok,
            string.format('n=%s decodes=%d lua=%s pixels=%s', tostring(n2), dncalls,
                          tostring(wrote_ring()), tostring(yok)))

      -- A decode that cannot be had drops the frame rather than writing whatever an empty
      -- table indexes to, which is a nil reaching the ring write.
      fftsa.nl.db_now = function() return nil end
      fftsa.nl.px_restart('test')
      assert(fftsa.nl.px_map(geom(), HZ, NSEG))
      MW, calls, answer = {}, 0, fftsa.nl.RC.EBOUNDS
      local n3 = fftsa.nl.px_frame({}, HZ, NSEG, 'TB', 4022)
      check('a frame whose decibels will not decode drops rather than writing nils',
            n3 == nil and not wrote_ring()
            and string.find(tostring(fftsa.nl.px.whyframe), 'decode', 1, true) ~= nil,
            string.format('n=%s lua=%s why=%s', tostring(n3), tostring(wrote_ring()),
                          tostring(fftsa.nl.px.whyframe)))

      fftsa.nl.db_now = keepdn
      fftsa.sg_pix_repaint = keeprp
      display.graph = saved_graph
      fftsa.nl.px.gid = nil
      build(nil)
      fftsa.nl.px_restart('test')
      assert(fftsa.nl.px_map(geom(), HZ, NSEG))
    end

    do
      -- THE ONE CORRECTNESS CASE. A re-point rewrites the x pixel and the x float in the two
      -- pieces of the held image the ring write does not touch, so that frame has to lay the
      -- whole block down from Lua -- and the frame after it goes straight back to the image.
      -- Without this the series re-points in Lua and the ring keeps the old frequencies, which
      -- draws the new spectrum at the old columns: correct-looking and wrong.
      build(nil)
      fftsa.nl.px_restart('test')
      assert(fftsa.nl.px_map(geom(), HZ, NSEG))
      local moved, j = {}, nil
      for j = 1, NSEG do moved[j] = HZ[j] + 1 end
      MW, calls, answer = {}, 0, NREC
      local n = fftsa.nl.px_frame(DB, moved, NSEG, 'TB', 4004)
      local rp = fftsa.nl.px.repoints
      local lua_drew, img_called = wrote_ring(), calls
      -- And the x float in the ring is the moved series, which is what the block write was
      -- for: the image's write would have left the old one there.
      local rec = ki.memread(string.format('%X', RLO + 2 * STRIDE + OX),
                             string.format('%X', 4))
      local xf = fftsa.nl._f32_unpack(rec, 1)
      MW, calls = {}, 0
      local n2 = fftsa.nl.px_frame(DB, moved, NSEG, 'TB', 4005)
      check('a re-pointed frame writes the block from Lua, and the next frame does not',
            n == NSEG and rp == 1 and lua_drew and img_called == 0
            and xf ~= nil and math.abs(xf - moved[slot_index(3)]) < 0.01
            and n2 == NSEG and calls == 1 and not wrote_ring(),
            string.format('rp=%s lua=%s calls=%d x=%s wanted %s; next lua=%s calls=%d',
                          tostring(rp), tostring(lua_drew), img_called, tostring(xf),
                          tostring(moved[slot_index(3)]), tostring(wrote_ring()), calls))

      -- A NARROWED SPAN IS A RETUNED AXIS, and it must drop rather than re-point.
      --
      -- The fit maps a frequency to an x pixel under the axis it was measured against. Narrow
      -- the span and every new frequency is still inside the fitted range, so a containment
      -- test that only looks for frequencies OUTSIDE it passes -- and then each column takes
      -- its pixel from the old line, lands within a few columns of one end and clamps there.
      -- Nothing refuses, the decibel fit is untouched, and the trace is wrong: on the
      -- instrument, a 50 kHz stop moved to 500 Hz. Dropping costs a re-map, which is already
      -- what a WIDENED span pays, and that one draws correctly.
      build(nil)
      fftsa.nl.px_restart('test')
      assert(fftsa.nl.px_map(geom(), HZ, NSEG))
      local narrow, q = {}, nil
      for q = 1, NSEG do narrow[q] = HZ[q] / 100 end
      -- Inside the fitted range at both ends, which is what makes the one-sided test pass.
      local inside = narrow[1] >= fftsa.nl.px.fmin - (fftsa.nl.px.fmax - fftsa.nl.px.fmin)
                     and narrow[NSEG] <= fftsa.nl.px.fmax
      MW, calls, answer = {}, 0, NREC
      -- The delta, not the count: repoints is cumulative over this section.
      local rp0 = fftsa.nl.px.repoints or 0
      local nn = fftsa.nl.px_frame(DB, narrow, NSEG, 'TB', 4006)
      local rp2 = (fftsa.nl.px.repoints or 0) - rp0
      check('a narrowed span drops the frame rather than re-pointing onto the old fit',
            inside and nn == nil and rp2 == 0 and not wrote_ring()
            and string.find(tostring(fftsa.nl.px.whyframe), 'retuned', 1, true) ~= nil,
            string.format('inside=%s n=%s repoints=%s drew=%s why=%s',
                          tostring(inside), tostring(nn), tostring(rp2),
                          tostring(wrote_ring()), tostring(fftsa.nl.px.whyframe)))

      -- And the legitimate case still re-points: the step changes, the ends do not.
      build(nil)
      fftsa.nl.px_restart('test')
      assert(fftsa.nl.px_map(geom(), HZ, NSEG))
      local regrid = {}
      for q = 1, NSEG do
        regrid[q] = HZ[1] + (HZ[NSEG] - HZ[1]) * (q - 1) / (NSEG - 1) + 0.5
      end
      MW, calls, answer = {}, 0, NREC
      local rg0 = fftsa.nl.px.repoints or 0
      local ng = fftsa.nl.px_frame(DB, regrid, NSEG, 'TB', 4007)
      local rgd = (fftsa.nl.px.repoints or 0) - rg0
      check('a re-gridded series at the same span still re-points',
            ng == NSEG and rgd == 1,
            string.format('n=%s repointed=%s why=%s', tostring(ng), tostring(rgd),
                          tostring(fftsa.nl.px.rp_why)))
    end

    ki.memwrite = realmw
    fftsa.nl.PX_WORDS, fftsa.nl.PX_MAXREC, fftsa.nl.PX_HDR = keepW, keepM, keepH
    fftsa.nl.px_addr, fftsa.nl.call_native = keepP, keepCN
    build(nil)
    fftsa.nl.px_restart('test')
  end

  -- ---- the search ------------------------------------------------------------
  do
    -- Resumable, over slices far smaller than the distance the ring sits from the window start,
    -- so the answer can only come from a sweep that carried on where the last one stopped. The
    -- needle is the app's own first four columns, which is all a frame has.
    fftsa.nl.px_restart('test')
    fftsa.nl.px.noname = true
    local SENT, i = {}, nil
    for i = 1, 4 do SENT[i] = { db = DB[i], hz = HZ[i] } end
    local s0 = nil
    for i = 1, NREC - 3 do
      if slot_index(i) == XCOL and slot_index(i + 1) == XCOL + 1
         and slot_index(i + 2) == XCOL + 2 and slot_index(i + 3) == XCOL + 3 then
        s0 = i
        break
      end
    end
    check('the fixture has the four columns the needle was built from, consecutive',
          s0 ~= nil, 'the run from column ' .. tostring(XCOL) .. ' starts at slot '
          .. tostring(s0))
    -- No narrow window and nothing learned, because the mechanism under test is the budgeted
    -- slice and its resumable cursor. A window ahead of the fixture's ring would be spent
    -- before the ring was reached -- 500 slices of 4 KB is 2 MB -- which is the performance
    -- cost of a wrong window behaving exactly as intended, and not what this case is for. That
    -- cost has its own gate below.
    local keepinst2 = fftsa.nl.inst
    local keepseed = FFTSA_PXSEED
    fftsa.nl.inst = nil
    FFTSA_PXSEED = nil
    fftsa.nl.px.wins, fftsa.nl.px.wi, fftsa.nl.px.at = nil, nil, nil
    local c, calls = {}, 0
    while table.getn(c) == 0 and calls < 500 do
      calls = calls + 1
      -- One call is one frame, so it gets one frame's read allowance. px_seek is driven by
      -- px_try on the instrument and takes its refill from the frame stamp; called directly it
      -- has to be told, or the first 48 reads are the only ones it ever gets.
      fftsa.nl.rd_frame_reset()
      c = fftsa.nl.px_seek(HZ, NSEG, 4096, nil)
    end
    fftsa.nl.inst = keepinst2
    FFTSA_PXSEED = keepseed
    -- EVERY confirmed stride, not the first. The staging ring holds the same two float32 pairs
    -- in the same order in a 28-byte record, so a hit confirms more than once and the first
    -- confirmation is the one with no header. Returning only that threw the real geometry away
    -- and moved the cursor past it: 981 MB swept and reported absent, measured on the glass.
    local want, k = nil, nil
    for k = 1, table.getn(c) do
      if c[k].stride == STRIDE then want = c[k] end
    end
    check('the search finds the records over many budgeted slices, and says where',
          want ~= nil and s0 ~= nil and want.val0 == RLO + (s0 - 1) * STRIDE + OX,
          string.format('%d confirmations after %d slices of 4 KB: %s', table.getn(c), calls,
                        want ~= nil and string.format('val0=%X at stride %d', want.val0,
                                                      want.stride)
                        or 'none at the real stride'))
    check('and it took many slices, so the slices really do resume',
          calls > 4, tostring(calls) .. ' slices of 4 KB')
  end

  do
    -- THE FREQUENCY ROUTE COSTS ONE READ PER HIT, not one per candidate stride. It was 29 --
    -- REC_MIN..REC_MAX in fours -- and the hit count is whatever the heap holds, so a slice
    -- could be thousands of round trips inside one uninterruptible frame. Measured on the
    -- glass at 8.81: 0.1 fps at 2048 points, ten seconds in a single frame.
    do
      local xs, j = fftsa.nl.px_xneedle(HZ, NSEG)
      local reads, peeks = 0, 0
      local km, kp = ki.memread, ki.peek32
      ki.memread = function(a, n) reads = reads + 1; return km(a, n) end
      ki.peek32 = function(a) peeks = peeks + 1; return kp(a) end
      local gs = fftsa.nl.px_xconfirm_all(RLO + (SLOT0 or 1) * 0, xs)
      ki.memread, ki.peek32 = km, kp
      check('every candidate stride is tested off one read, whatever the answer',
            xs ~= nil and reads <= 1 and peeks == 0,
            string.format('%d memread(s), %d peek32(s), %d confirmation(s)', reads, peeks,
                          gs ~= nil and table.getn(gs) or -1))
    end

    -- THE NAME NEEDLE IS CAPPED. It keeps absolute precedence -- it is the only needle that
    -- says WHICH trace -- but it does not get to sweep the whole backstop to discover it is
    -- not in memory. Measured on the glass at 8.80: swept=276MB with laps=1, then the
    -- frequency series found the ring in the seed window almost at once.
    -- THIS PASS'S bytes, not the session's. The bound is on what the pass has swept without a
    -- single hit: judged on the cumulative total it fired on the first slice of every pass
    -- after the second, because the total was already past the bound whatever the pass had
    -- done -- and the needle that says WHICH trace was gone before the pass that mattered.
    fftsa.nl.px_restart('test')
    fftsa.nl.px.swept = fftsa.nl.PX_NAME_GIVEUP
    fftsa.nl.px.sweptpass = fftsa.nl.PX_NAME_GIVEUP
    fftsa.nl.px.namehits = 0
    fftsa.nl.px_seek(HZ, NSEG, 4096, nil)
    check('the name needle gives up at PX_NAME_GIVEUP and the lap switches needles',
          fftsa.nl.px.noname == true and fftsa.nl.px.gaveup == 1,
          string.format('noname=%s gaveup=%s col=%s', tostring(fftsa.nl.px.noname),
                        tostring(fftsa.nl.px.gaveup), tostring(fftsa.nl.px.xcol)))
    -- And a lap that HAS seen the name keeps it, however far it has swept: a name hit that
    -- did not map is still far better evidence than a frequency that matches everywhere.
    fftsa.nl.px_restart('test')
    -- gaveup is cumulative and survives a restart on purpose, so the test is that it does not
    -- move rather than that it is absent.
    local gave0 = fftsa.nl.px.gaveup
    fftsa.nl.px.swept = fftsa.nl.PX_NAME_GIVEUP * 4
    fftsa.nl.px.namehits = 3
    fftsa.nl.px_seek(HZ, NSEG, 4096, nil)
    check('a lap that has seen the name keeps using it however far it has swept',
          fftsa.nl.px.noname == nil and fftsa.nl.px.gaveup == gave0,
          string.format('noname=%s gaveup %s->%s', tostring(fftsa.nl.px.noname),
                        tostring(gave0), tostring(fftsa.nl.px.gaveup)))
  end

  do
    -- An axis with no usable needle in it. Four equal frequencies cannot confirm a stride --
    -- every offset matches -- and a frequency of zero packs to four zero bytes, of which the
    -- ring's own records hold two words. Both have to be refused without sweeping anything.
    fftsa.nl.px_restart('test')
    fftsa.nl.px.noname = true
    local flat, j = {}, nil
    for j = 1, NSEG do flat[j] = 4096 end
    check('an axis of equal frequencies is refused without sweeping anything',
          table.getn(fftsa.nl.px_seek(flat, NSEG, 65536, nil)) == 0
          and fftsa.nl.px.wins == nil and fftsa.nl.px.degen == 1,
          'wins=' .. tostring(fftsa.nl.px.wins)
          .. ' flat=' .. tostring(fftsa.nl.px.degen))
    -- And the column chosen out of a real axis is never one that packs to all zeros, even
    -- when that is where the band starts.
    local dc = {}
    for j = 1, NSEG do dc[j] = (j - 1) * 195.3125 end
    local xs, col = fftsa.nl.px_xneedle(dc, NSEG)
    check('a band starting at dc does not take dc as its needle',
          xs ~= nil and col ~= nil and col > 1
          and string.sub(xs[1], 1, 4) ~= string.rep('\0', 4),
          'column ' .. tostring(col) .. ' of a band whose first frequency is '
          .. tostring(dc[1]))
  end

  -- ---- the name route --------------------------------------------------------
  do
    -- The whole geometry out of one hit on the buffer's name, by a bounded walk and no further
    -- searching. This is the route the operator asked for: a pointer to follow rather than a
    -- scan to run, and every offset in it derived rather than taken from the layout notes.
    build(nil)
    tracefix()
    local gs = fftsa.nl.px_from_name(TNAME)
    local g, gi = nil, nil
    for gi = 1, table.getn(gs) do
      if gs[gi].stride == STRIDE then g = gs[gi] end
    end
    check('the name yields the ring bounds and a stride among the candidates',
          g ~= nil and g.lo == TRING and g.hi == TRING + NREC * STRIDE
          and g.nrec == NREC and g.hdr == TBOUND,
          g ~= nil and string.format('%d candidates, the %d-byte one is %X..%X n=%d, header '
                                     .. 'at %X, %d bytes past the name', table.getn(gs),
                                     g.stride, g.lo, g.hi, g.nrec, g.hdr, g.name_off)
          or (tostring(table.getn(gs)) .. ' candidates, none at stride '
              .. tostring(STRIDE)))
    -- The span does not fix the stride, so more than one candidate is the expected answer and
    -- px_map is what settles it. 1344 bytes is 24 records of 56 and also 56 of 24.
    check('and more than one stride is offered rather than one guessed at',
          table.getn(gs) > 1, tostring(table.getn(gs)) .. ' candidates')
    -- And nothing is read out of the layout: the distance from the name to the bounds is
    -- whatever the walk found, so a build that moved the field is still answered.
    check('the distance from the name to the bounds is measured, not assumed',
          g ~= nil and g.name_off == TBOUND - TNAME,
          g ~= nil and (tostring(g.name_off) .. ' bytes, fixture has '
                        .. tostring(TBOUND - TNAME)) or 'nil')
    check('a name with no plausible ring after it yields nothing',
          table.getn(fftsa.nl.px_from_name(TNAME + 65536)) == 0)
  end

  -- ---- the pointer route ----------------------------------------------------
  do
    -- THREE READS INSTEAD OF A SWEEP. The fixture models the chain GRAPH.md recovered from
    -- the image: a GUI object table indexed by the display handle, a widget whose
    -- null-terminated trace array at +0x3EC points at the trace object, and the trace object
    -- tracefix() already builds at the documented offsets.
    --
    -- Placed within a few kilobytes of the trace so that any window covering it covers these
    -- too -- the derivation sweeps for a four-byte needle over the same ladder.
    local GID = 7
    local WID = TLO - 4096
    -- BELOW THE HEAP, as the real table is: GRAPH.md puts it at a static 0x00D17BE0 and the
    -- 6500's heap starts at 0x01036000. px_anchor refuses a base inside the heap, because the
    -- forward walk cannot tell the table from any word that happens to hold the widget
    -- pointer -- it reads back the word the base came from. A fixture with the table in the
    -- heap would make that check untestable.
    local OBJ = 1048576
    local function wire()
      build(nil)
      tracefix()
      wr32(WID + fftsa.nl.PX_GRAPH_TRACE, TLO)         -- trace array entry 0
      wr32(WID + fftsa.nl.PX_GRAPH_TRACE + 4, 0)       -- and its null terminator
      -- The widget pointer sits at +0x50 INSIDE the entry, not at its start: GRAPH.md:178.
      wr32(OBJ + GID * fftsa.nl.PX_OBJ_STRIDE + fftsa.nl.PX_OBJ_WIDGET, WID)
    end

    wire()
    fftsa.nl.px_objbase = OBJ
    local gs = fftsa.nl.px_from_ptr(GID)
    local g = nil
    local gi
    for gi = 1, table.getn(gs) do
      if gs[gi].stride == STRIDE then g = gs[gi] end
    end
    check('the ring comes back from the display handle through the object table',
          g ~= nil and g.lo == TRING and g.nrec == NREC and g.hdr == TBOUND,
          g ~= nil and string.format('%X..%X n=%d hdr=%X', g.lo, g.hi, g.nrec, g.hdr)
          or (tostring(table.getn(gs)) .. ' candidates, none at stride '
              .. tostring(STRIDE)))
    check('and it is marked as having come by pointer rather than by a sweep',
          g ~= nil and g.via_ptr == true, g ~= nil and tostring(g.via_ptr) or 'nil')

    -- THE MARKER TRACE, which is the case the name field exists for. A second object of the
    -- same shape with a valid ring of its own and a different name: only the name tells them
    -- apart, so an array walk that skips it on geometry alone would pass this by accident.
    local MLO = TLO + 65536
    local function wrstr(at, str)
      local i
      for i = 0, string.len(str) - 1 do
        local a = at + i
        local w = a - math.mod(a, 4)
        local old4 = IMG[w] or '\0\0\0\0'
        local k = a - w + 1
        IMG[w] = string.sub(old4, 1, k - 1) .. string.sub(str, i + 1, i + 1)
                 .. string.sub(old4, k + 1)
      end
    end
    wire()
    -- A complete trace object: the mark name at +0x08, bounds at +0x1F0, ring at +0x220 with
    -- cursors that stand up. Everything px_from_name checks, and the wrong name.
    wrstr(MLO + 8, 'FFTSA_MARK' .. string.char(0))
    wr32(MLO + 496, MLO + 544)
    wr32(MLO + 500, MLO + 544 + NREC * STRIDE)
    wr32(MLO + 496 + fftsa.nl.HDR_OLD, MLO + 544)
    wr32(MLO + 496 + fftsa.nl.HDR_WRITE, MLO + 544)
    wr32(MLO + 496 + fftsa.nl.HDR_COUNT, NREC)
    -- It must be a trace object by every test but the name, or this gates nothing.
    check('the decoy IS a valid trace object apart from its name',
          table.getn(fftsa.nl.px_from_name(MLO + 8)) > 0,
          'decoy geometry stands up on its own')
    wr32(WID + fftsa.nl.PX_GRAPH_TRACE, MLO)           -- the marker trace is entry 0
    wr32(WID + fftsa.nl.PX_GRAPH_TRACE + 4, TLO)       -- ours is second
    wr32(WID + fftsa.nl.PX_GRAPH_TRACE + 8, 0)
    fftsa.nl.px_objbase = OBJ
    local g2 = fftsa.nl.px_from_ptr(GID)
    check('the array walk skips the marker trace and lands on this app\'s own',
          table.getn(g2) > 0 and g2[1].hdr == TBOUND and g2[1].lo == TRING,
          table.getn(g2) > 0 and string.format('hdr=%X lo=%X (mark is at %X)',
                                               g2[1].hdr, g2[1].lo, MLO + 496)
          or '0 candidates')

    -- THE BASE IS NOT DERIVED ANY MORE. The compiled hint answers, or this instrument's own
    -- record does once a base has worked. The derivation that used to live here searched for
    -- the word holding the widget pointer and subtracted -- but the table is static in low
    -- memory, about 47 MB from a ring in the GUI heap, so a bounded search could never reach it
    -- and an unbounded one bluescreened the instrument. Its forward check was vacuous besides.
    wire()
    fftsa.nl.px_objbase = nil
    local keeph = fftsa.nl.PX_OBJTAB_HINTS
    fftsa.nl.PX_OBJTAB_HINTS = { OBJ }
    local byhint = fftsa.nl.px_from_ptr(GID)
    -- AND THE ENTRY IS FOUND WHEN THE HANDLE IS NOT THE INDEX, which is the one link in the
    -- walk that cannot be read out of a firmware image.
    do
      wire()
      fftsa.nl.px_objbase = nil
      local kh2 = fftsa.nl.PX_OBJTAB_HINTS
      fftsa.nl.PX_OBJTAB_HINTS = { OBJ }
      fftsa.nl.px_objfound = nil
      fftsa.nl.rd_frame_reset()
      -- A handle that is not the table index at all.
      local g2 = fftsa.nl.px_from_ptr(GID + 23)
      fftsa.nl.PX_OBJTAB_HINTS = kh2
      -- AND THE WALK RESUMES ACROSS FRAMES. 64 entries at a few reads each is more than one
    -- frame's read allowance, so a walk that restarted at zero every frame would try the same
    -- low ids for ever and never reach a high one.
    do
      wire()
      fftsa.nl.px_objbase, fftsa.nl.px.objscan = nil, 0
      local kh3 = fftsa.nl.PX_OBJTAB_HINTS
      fftsa.nl.PX_OBJTAB_HINTS = { OBJ }
      local krd = fftsa.nl.RD_MAX_CALLS
      -- An allowance that cannot reach GID in one frame, so the walk has to carry on.
      fftsa.nl.RD_MAX_CALLS = 6
      local frames, g3 = 0, {}
      while frames < 40 and table.getn(g3) == 0 do
        frames = frames + 1
        fftsa.nl.rd_frame_reset()
        g3 = fftsa.nl.px_from_ptr(GID + 23)
      end
      fftsa.nl.RD_MAX_CALLS = krd
      fftsa.nl.PX_OBJTAB_HINTS = kh3
      check('the entry walk resumes across frames instead of restarting at zero',
            table.getn(g3) > 0 and fftsa.nl.px_objid == GID and frames > 1,
            string.format('found id=%s after %d frame(s) at %d reads each',
                          tostring(fftsa.nl.px_objid), frames, 6))
    end

    check('the entry is found by validation when the handle is not the index',
            table.getn(g2) > 0 and g2[1].lo == TRING and fftsa.nl.px_objid == GID
            and fftsa.nl.px_objfound ~= nil,
            string.format('%d candidate(s), id=%s, why=%s', table.getn(g2),
                          tostring(fftsa.nl.px_objid), tostring(fftsa.nl.px_objfound)))
    end

    check('the compiled hint reaches the ring, and is adopted as the base',
          table.getn(byhint) > 0 and byhint[1].lo == TRING
          and fftsa.nl.px_objbase == OBJ,
          string.format('%d candidate(s), base=%s', table.getn(byhint),
                        tostring(fftsa.nl.px_objbase)))
    -- A WRONG HINT COSTS READS AND NOTHING ELSE: it cannot answer, because the walk has to end
    -- on a trace carrying this app's own buffer name.
    wire()
    fftsa.nl.px_objbase = nil
    fftsa.nl.PX_OBJTAB_HINTS = { OBJ + 64 }
    local rd0 = 0
    local km1 = ki.memread
    local kp1 = ki.peek32
    ki.memread = function(a, n) rd0 = rd0 + 1; return km1(a, n) end
    ki.peek32 = function(a) rd0 = rd0 + 1; return kp1(a) end
    fftsa.nl.rd_frame_reset()
    local bad = fftsa.nl.px_from_ptr(GID)
    local leftover = fftsa.nl.rd_over()
    ki.memread, ki.peek32 = km1, kp1
    -- Bounded by the entry walk, not by one entry: the handle is not trusted to be the index,
    -- so a base that answers nothing is only known to be wrong once the table has been tried.
    -- PX_OBJ_SCAN entries at a few reads each, and the frame's read budget caps it besides --
    -- still far less than one sweep slice, which is the thing this exists to avoid.
    check('a wrong hint answers nothing and costs a bounded walk of the table',
          table.getn(bad) == 0 and fftsa.nl.px_objbase == nil
          and rd0 <= fftsa.nl.PX_OBJ_SCAN * 4,
          string.format('%d candidate(s), base=%s, %d read(s), bound %d', table.getn(bad),
                        tostring(fftsa.nl.px_objbase), rd0, fftsa.nl.PX_OBJ_SCAN * 4))
    -- AND IT TAKES ITS SHARE OF THE FRAME, NOT THE WHOLE FRAME. This is the bound that
    -- decides the engage time, and it is not the same bound as above.
    --
    -- The walk and the search run in the same frame -- the idle arm falls through rather than
    -- returning -- but the walk runs first, and px_seek's loop will not take a slice once
    -- rd_over() is true. So a walk bounded only by the frame's allowance left the search
    -- unable to scan a single byte in every frame the walk was running: 9.05 engaged in 2.0 s
    -- with the walk starved to one frame, 9.07 gave it its frames and engagement went to
    -- 4.2 s. Nothing about the search changed between them.
    --
    -- Both halves are asserted, because either alone passes while the defect stands: that the
    -- walk spent no more than its share, AND that the frame still has allowance left for the
    -- search when the walk hands back.
    check('the walk takes its share of the frame and leaves the rest for the search',
          rd0 <= fftsa.nl.PX_OBJ_CALLS and not leftover
          and fftsa.nl.PX_OBJ_CALLS < fftsa.nl.RD_MAX_CALLS,
          string.format('%d read(s) of a %d share and a %d allowance, over=%s',
                        rd0, fftsa.nl.PX_OBJ_CALLS, fftsa.nl.RD_MAX_CALLS,
                        tostring(leftover)))
    fftsa.nl.PX_OBJTAB_HINTS = keeph

    -- A base that has gone stale must refuse, not answer from whatever is at the offset.
    wire()
    -- Off by one entry, and the hint has to be out of the way or it would answer instead.
    local keephint = fftsa.nl.PX_OBJTAB_HINTS
    fftsa.nl.PX_OBJTAB_HINTS = nil
    fftsa.nl.px_objbase = OBJ + fftsa.nl.PX_OBJ_STRIDE
    check('a table base off by one entry is refused rather than believed',
          table.getn(fftsa.nl.px_from_ptr(GID)) == 0, 'stale base')

    fftsa.nl.PX_OBJTAB_HINTS = keephint
    -- And the handle changing takes the base with it, because the table is indexed by id.
    wire()
    fftsa.nl.px_objbase = OBJ
    fftsa.nl.px.gid = GID
    fftsa.nl.px.state = 'seek'
    fftsa.nl.px_try(DB, HZ, NSEG, 'TB', 7777, GID + 1)
    check('a changed display handle discards the derived base',
          fftsa.nl.px_objbase == nil and fftsa.nl.px.gid == GID + 1,
          string.format('base=%s gid=%s',
                        tostring(fftsa.nl.px_objbase), tostring(fftsa.nl.px.gid)))
    fftsa.nl.px_objbase = nil
    fftsa.nl.px.gid = nil
  end

  do
    -- End to end on the name, with the x field DERIVED: the name route never looks at a
    -- record, so which offset holds the frequency is settled by the one that carries a member
    -- of this plan's own series in every slot.
    build(nil)
    tracefix()
    FFTSA_PXRING = nil
    fftsa.nl.px_restart('test')
    fftsa.nl.px.state = 'idle'
    local calls, n = 0, nil
    while n == nil and calls < 500 do
      calls = calls + 1
      n = fftsa.nl.px_try(DB, HZ, NSEG, 'TB', 4000 + calls)
    end
    check('the whole path engages on the name, with the x field derived',
          n == NSEG and fftsa.nl.px.state == 'on' and fftsa.nl.px.lo == TRING
          and fftsa.nl.px.ox == OX and fftsa.nl.px.yoff == 12,
          string.format('n=%s state=%s ring=%s x@%s y@%s v@%s after %d frames', tostring(n),
                        tostring(fftsa.nl.px.state),
                        fftsa.nl.px.lo and string.format('%X', fftsa.nl.px.lo) or 'nil',
                        tostring(fftsa.nl.px.ox), tostring(fftsa.nl.px.yoff),
                        tostring(fftsa.nl.px.ov), calls))
    check('and it never needed the frequency needle',
          fftsa.nl.px.noname == nil and fftsa.nl.px.xcol == nil,
          'noname=' .. tostring(fftsa.nl.px.noname)
          .. ' xcol=' .. tostring(fftsa.nl.px.xcol))
  end

  -- ---- the cache -------------------------------------------------------------
  do
    FFTSA_PXRING = nil
    check('no cache reads back as no geometry', fftsa.nl.px_cache_get() == nil)
    fftsa.nl.px_cache_put(geom())
    local c = fftsa.nl.px_cache_get()
    check('the cached geometry round-trips through the global',
          c ~= nil and c.lo == RLO and c.hi == RLO + NREC * STRIDE and c.nrec == NREC
          and c.stride == STRIDE and c.ox == OX and c.hdr == HDRAT and c.ov == nil,
          tostring(FFTSA_PXRING))
    -- And is re-validated from content, never trusted: an address the ring has moved off maps
    -- nothing, because every one of its slots would have to carry a frequency out of this
    -- plan's own series and freed memory does not.
    --
    -- NOT by shifting the address a word. The value and the x are stored TWICE, so reading
    -- four bytes late gives the same float, and px_triples then finds the y triple four bytes
    -- late as well -- a 4-byte shift re-derives itself into the same correct geometry and is
    -- not a stale cache at all. The case to write is the one that happens: the ring is
    -- somewhere else and the old address holds something that is not a ring.
    local stale = geom()
    stale.lo, stale.hi = RLO + 131072, RLO + 131072 + NREC * STRIDE
    fftsa.nl.px_restart('test')
    check('a cached address the ring has moved off falls through to the search',
          not fftsa.nl.px_map(stale, HZ, NSEG), 'why=' .. tostring(fftsa.nl.px.why))
  end

  -- ---- the name walk costs one read ------------------------------------------
  do
    -- THE WALK IS A KILOBYTE AND IT USED TO BE 257 IPC ROUND TRIPS. nl._wg is ki.peek32, one
    -- call per word, and px_seek hands every aligned hit in a slice to this -- so a slice with
    -- tens of hits was tens of thousands of round trips inside one frame, and a frame cannot
    -- be interrupted. Measured on the glass as a 4 to 5 second stall while the search ran.
    local peeks, reads = 0, 0
    local kp, km = ki.peek32, ki.memread
    ki.peek32 = function(a) peeks = peeks + 1; return kp(a) end
    ki.memread = function(a, n) reads = reads + 1; return km(a, n) end
    local g = fftsa.nl.px_from_name(TLO + 8)
    ki.peek32, ki.memread = kp, km
    check('the name walk finds the ring in one read and no word-at-a-time peeks',
          table.getn(g) > 0 and g[1].hdr == TBOUND and reads == 1 and peeks == 0,
          string.format('%d candidate(s) hdr=%s, %d memread(s) and %d peek32(s)',
                        table.getn(g),
                        table.getn(g) > 0 and string.format('%X', g[1].hdr) or 'none',
                        reads, peeks))
    -- An unaligned hit answered nothing before, because _wg refuses an unaligned address, and
    -- it must still answer nothing -- without paying for a read to find that out.
    peeks, reads = 0, 0
    ki.peek32 = function(a) peeks = peeks + 1; return kp(a) end
    ki.memread = function(a, n) reads = reads + 1; return km(a, n) end
    local gu = fftsa.nl.px_from_name(TLO + 8 + 2)
    ki.peek32, ki.memread = kp, km
    check('an unaligned hit is refused without reading anything',
          table.getn(gu) == 0 and reads == 0 and peeks == 0,
          string.format('%d candidate(s), %d memread(s), %d peek32(s)',
                        table.getn(gu), reads, peeks))
  end

  -- ---- the seeded window -----------------------------------------------------
  do
    -- THE LAST RING IS THE FIRST PLACE TO LOOK. Without this the ladder reaches the ring only
    -- in its backstop pass -- the windows before it are centred on the buffer's instance and
    -- storage, and the ring is a display task allocation in neither -- so a span or size change
    -- fell through to 200 MB at PX_BUDGET a frame, 800 frames, which reads as never recovering.
    -- An Apply takes a new trace object from a pool of thirty 0x14220-byte objects, 2.4 MB in
    -- all, so the new ring is inside a window this wide around the old one.
    local keep, keeps = FFTSA_PXRING, FFTSA_PXSEED
    local keepinst = fftsa.nl.inst
    FFTSA_PXRING, FFTSA_PXSEED = nil, nil
    -- THE INSTANCE BAND IS THE ONLY NARROW WINDOW a machine with no record on its key has, and
    -- it is offered as sub-bands because px_seek takes anything wider than PX_WIN_MAX for its
    -- backstop pass and defers it to last. No address is compiled in for this: the band is
    -- derived from the trace buffer's own C++ instance, which this module has dereferenced.
    local INST = 58000000
    fftsa.nl.inst = INST
    local bands = fftsa.nl.px_inst_wins()
    local nb = table.getn(bands)
    -- EVERY SUB-BAND WITHIN PX_WIN_MAX. One that is not gets deferred to the backstop's
    -- position, which throws away the whole reason the band is offered in pieces.
    local wide = 0
    local bi
    for bi = 1, nb do
      if bands[bi][2] - bands[bi][1] > fftsa.nl.PX_WIN_MAX then wide = wide + 1 end
    end
    check('each instance sub-band is inside PX_WIN_MAX, so none is taken for the backstop',
          nb > 0 and wide == 0,
          string.format('%d band(s), %d wider than %d', nb, wide, fftsa.nl.PX_WIN_MAX))
    -- AND THEY TILE THE MEASURED RANGE WITH NO HOLE IN IT. Ten launches put the ring from
    -- 0.96 MB below inst to 32 MB above; the band covers -2 to +8 MB of that. A gap between
    -- two sub-bands is a ring that is never reached from the band at all, and it reads on the
    -- glass exactly like a search that is simply slow -- which is how 11 MB and then 9 MB were
    -- swept past a ring at +2.25 MB.
    local holes, lo1, hiN = 0, bands[1][1], bands[nb][2]
    for bi = 2, nb do
      if bands[bi][1] ~= bands[bi - 1][2] then holes = holes + 1 end
    end
    check('the sub-bands tile the band with no gap between them',
          holes == 0 and lo1 < INST and hiN > INST,
          string.format('[%X,%X] in %d band(s), %d gap(s)', lo1, hiN, nb, holes))
    -- And with no instance either -- before the first bind -- there is no narrow window and
    -- the ladder is the buffer-side windows and the backstop, which is what it always was.
    fftsa.nl.inst = nil
    local nw = fftsa.nl.px_windows(nil)
    check('and with no instance yet the ladder falls back to the buffer-side windows',
          table.getn(fftsa.nl.px_inst_wins()) == 0
          and nw[table.getn(nw)][2] - nw[table.getn(nw)][1] > fftsa.nl.PX_WIN_MAX,
          string.format('%d window(s), last is %d wide', table.getn(nw),
                        nw[table.getn(nw)][2] - nw[table.getn(nw)][1]))
    -- CHEAP, THEN THE BAND, THEN WIDTH -- and two measured failures bound this from both
    -- sides, so the gate asserts all three groups and not just one rule.
    --
    --   9.08  swept=29MB  the ring in a 256 KB buffer-side window that sat behind a learned
    --                     span grown to 23 MB. Ordering by trusted source let a cheap window
    --                     wait on an expensive one.
    --   9.13  swept=35MB  the ring at inst+4.48 MB, inside instance band 2, which sorted to
    --                     window 15 of 17 for being 4 MB wide. Ordering purely by width put
    --                     the window most likely to be right behind fourteen that were not.
    --
    -- A gate on either rule alone passes while the other failure stands, which is how the
    -- second one shipped.
    fftsa.nl.inst = INST
    local ow = fftsa.nl.px_windows(nil)
    local now = table.getn(ow)
    local isband = function(w)
      local k
      for k = 1, table.getn(bands) do
        if bands[k][1] == w[1] and bands[k][2] == w[2] then return true end
      end
      return false
    end
    -- Where the three groups start and end, walked once.
    local lastcheap, firstband, lastband, firstrest = 0, nil, nil, nil
    local cheapdesc, restdesc = 0, 0
    local prevcheap, prevrest = nil, nil
    for bi = 1, now do
      local wd = ow[bi][2] - ow[bi][1]
      if wd <= fftsa.nl.PX_WIN_CHEAP then
        lastcheap = bi
        if prevcheap ~= nil and wd < prevcheap then cheapdesc = cheapdesc + 1 end
        prevcheap = wd
      elseif isband(ow[bi]) then
        if firstband == nil then firstband = bi end
        lastband = bi
      else
        if firstrest == nil then firstrest = bi end
        if prevrest ~= nil and wd < prevrest then restdesc = restdesc + 1 end
        prevrest = wd
      end
    end
    check('every cheap window is tried before anything that is not cheap',
          lastcheap > 0 and firstband ~= nil and lastcheap < firstband
          and cheapdesc == 0,
          string.format('%d cheap window(s) first, %d out of order among them, band starts '
                        .. 'at %s of %d', lastcheap, cheapdesc, tostring(firstband), now))
    check('the instance band is tried before every wide window, including the backstop',
          firstband ~= nil and lastband ~= nil and firstrest ~= nil
          and lastband < firstrest
          and lastband - firstband + 1 == table.getn(bands),
          string.format('band at %s..%s of %d, %d sub-band(s), wide windows from %s',
                        tostring(firstband), tostring(lastband), now, table.getn(bands),
                        tostring(firstrest)))
    check('the wide windows are ordered narrowest first, with the backstop last',
          restdesc == 0 and ow[now][2] - ow[now][1] > fftsa.nl.PX_WIN_MAX,
          string.format('%d out of order among the wide ones, last is %d wide',
                        restdesc, ow[now][2] - ow[now][1]))
    -- Back to no instance for the blocks below. An instance left set changes every window the
    -- ladder offers, which changes the slices a later gate measures -- the cross-block leak
    -- that made this suite's results depend on its order.
    fftsa.nl.inst = nil
    local SEED = 62206008
    fftsa.nl.px_cache_put({ lo = SEED, hi = SEED + 4096, nrec = 24, stride = 56,
                            ox = 44, hdr = SEED - 496 })
    local w = fftsa.nl.px_windows(nil)
    local near = fftsa.nl.PX_SEED_NEAR
    local has = function(t, x, y)
      local i
      for i = 1, table.getn(t) do
        if t[i][1] == x and t[i][2] == y then return i end
      end
      return nil
    end
    -- THE SPAN IS IN THE LADDER, and where in it is decided by width rather than by the span
    -- being this machine's own record. Asserting the position was what the ladder used to
    -- promise, and the promise is gone: a span that has grown wide sorts to the back on
    -- purpose, because what it costs is the only thing knowable about it.
    check('the learned span is offered as a window, with tolerance either side',
          fftsa.nl.px_seed() == SEED and table.getn(w) >= 3
          and has(w, SEED - near, SEED + near) ~= nil,
          string.format('seed=%s span window at %s of %d',
                        tostring(fftsa.nl.px_seed()),
                        tostring(has(w, SEED - near, SEED + near)), table.getn(w)))
    -- A SPAN GROWN PAST ITS CEILING IS NOT OFFERED AT ALL. The span only ever widens -- it is
    -- every address this instrument has confirmed -- so after enough launches it covers more
    -- range than the backstop pass would in one slice, and sorted by width it lands beside the
    -- backstop. Measured at 9.08: a span of 23 MB, and the ring 86 KB from inst in a 256 KB
    -- window that the ladder reached after twenty-nine frames. Dropping it is what leaves the
    -- narrow windows to be tried first.
    do
      local keepspan = FFTSA_PXSEED
      local wide = fftsa.nl.PX_SEED_SPAN_MAX + 1024
      FFTSA_PXSEED = string.format('%d,%d', SEED, SEED + wide)
      local ws = fftsa.nl.px_windows(nil)
      check('a learned span wider than its ceiling is dropped rather than offered',
            has(ws, SEED - near, SEED + wide + near) == nil,
            string.format('span %d wide, ceiling %d, %d window(s)',
                          wide, fftsa.nl.PX_SEED_SPAN_MAX, table.getn(ws)))
      FFTSA_PXSEED = keepspan
    end
    -- AND IT LEARNS. A second confirmation at a different address widens the span rather
    -- than replacing it, which is what absorbs the display task's pool handing out a
    -- different trace object on the next launch.
    local SEED2 = SEED + 2097152
    fftsa.nl.px_cache_put({ lo = SEED2, hi = SEED2 + 4096, nrec = 24, stride = 56,
                            ox = 44, hdr = SEED2 - 496 })
    local a2, b2 = fftsa.nl.px_seed_span()
    local w2 = fftsa.nl.px_windows(nil)
    check('a second ring widens the learned span instead of replacing it',
          a2 == SEED and b2 == SEED2 and has(w2, SEED - near, SEED2 + near) ~= nil,
          string.format('span=[%X,%X], window at %s of %d', a2 or 0, b2 or 0,
                        tostring(has(w2, SEED - near, SEED2 + near)), table.getn(w2)))
    -- And the seed is reached before the backstop, which is the whole point: the backstop is
    -- the pass that costs 800 frames.
    local back, i = nil, nil
    for i = 1, table.getn(w) do
      if w[i][2] - w[i][1] > fftsa.nl.PX_WIN_MAX then back = i end
    end
    check('and the backstop pass is last, after every seeded and buffer-side window',
          back == table.getn(w),
          string.format('backstop at %s of %d', tostring(back), table.getn(w)))
    -- A WRONG WINDOW COSTS SLICES AND NOTHING ELSE, which is the condition the operator set
    -- for starting the search anywhere other than the beginning. The instance window only
    -- orders the ladder: it is not read from, not written to, and not believed -- so it is
    -- bounded, and the ladder carries on past it to the buffer-side windows and the backstop.
    do
      local keeplearned = FFTSA_PXSEED
      FFTSA_PXSEED = nil
      fftsa.nl.inst = 58000000
      local wh = fftsa.nl.px_windows(nil)
      local nh = table.getn(wh)
      local last = wh[nh]
      -- EVERY WINDOW BUT THE BACKSTOP IS INSIDE PX_WIN_MAX, so each costs a bounded amount of
      -- scanning and none of them is taken for the backstop pass and deferred to the end. And
      -- the backstop is still there and still last, which is what makes a wrong narrow window
      -- cost slices rather than correctness: the ladder reaches the whole proven span either
      -- way, just later.
      local over, sum, i2 = 0, 0, nil
      for i2 = 1, nh - 1 do
        local wd = wh[i2][2] - wh[i2][1]
        sum = sum + wd
        if wd > fftsa.nl.PX_WIN_MAX then over = over + 1 end
      end
      check('a wrong window costs a bounded first pass and the ladder still reaches everything',
            nh >= 2 and over == 0 and last[2] - last[1] > fftsa.nl.PX_WIN_MAX
            and last[1] <= fftsa.nl.BACKSTOP_LO and last[2] >= fftsa.nl.BACKSTOP_HI,
            string.format('%d window(s), %d over %d, %d bytes before the backstop, which is '
                          .. '%d wide', nh, over, fftsa.nl.PX_WIN_MAX, sum,
                          last[2] - last[1]))
      -- And a derived window is never written to the key as if this machine had confirmed a
      -- ring there.
      fftsa.nl._px_saved = nil
      check('with nothing learned there is nothing to save, window or no window',
            fftsa.nl.px_cache_save() == false, 'save with no learned span')
      fftsa.nl.inst = nil
      FFTSA_PXSEED = keeplearned
    end

    -- ---- and it survives a power cycle, which is the whole point --------------
    --
    -- Every cache in this app is a Lua global, so a power cycle loses all of it and the first
    -- search of a boot starts with nothing learned. The key's copy is what carries the span
    -- across. Nothing read back out of it is trusted: px_map re-validates from content before
    -- a byte is written, so a stale file costs one read.
    do
      local wrote = nil
      local keepio, keepfile = io, file
      io = { open = function(nm, mode)
        if mode ~= 'w' and mode ~= 'r' then return nil end
        if mode == 'w' then
          return { write = function(self, b) wrote = b end, close = function() end }
        end
        if wrote == nil then return nil end
        return { read = function(self, n) return wrote end, close = function() end }
      end }
      file = { usbdriveexists = function() return 1 end }
      local keepkey = fftsa.nl.PX_CACHE_KEY
      fftsa.nl.PX_CACHE_KEY = true
      -- 0-BASED, as this firmware's readdir is, and listing the directory is how existence is
      -- settled: io.open on a file that is not there POSTS 2203 as a modal dialog over the
      -- running app, and pcall is no defence because the file API posts rather than raises.
      -- Measured the expensive way on 8.80.
      local keepfs = fs
      fs = { readdir = function(d)
        if d ~= fftsa.nl.PX_CACHE_DIR then return nil end
        local t = {}
        t[0] = 'something_else.tspa'
        if wrote ~= nil then t[1] = fftsa.nl.PX_CACHE_NAME end
        return t
      end }
      fftsa.nl._px_saved = nil
      local saved = fftsa.nl.px_cache_save()
      -- A power cycle, modelled exactly: every global gone.
      FFTSA_PXRING, FFTSA_PXSEED = nil, nil
      fftsa.nl._px_loaded = nil
      local loaded = fftsa.nl.px_cache_load()
      local la, lb = fftsa.nl.px_seed_span()
      local lc = fftsa.nl.px_cache_get()
      io, file, fs = keepio, keepfile, keepfs
      fftsa.nl.PX_CACHE_KEY = keepkey
      check('the learned span and the geometry survive a power cycle through the key',
            saved and loaded and la == SEED and lb == SEED2
            and lc ~= nil and lc.lo == SEED2 and lc.stride == 56,
            string.format('saved=%s loaded=%s span=[%s,%s] ring=%s',
                          tostring(saved), tostring(loaded), tostring(la), tostring(lb),
                          lc ~= nil and string.format('%X/%d', lc.lo, lc.stride) or 'nil'))
      -- WHY A LOAD MISSED MUST OUTLIVE THE NEXT SAVE. The key's record is what turns the
      -- 72 MB sweep into a read, so a slow engage is answered by this field and by nothing
      -- else on the page. A confirmed geometry is re-put on every engage, so if the save
      -- cleared one reason field the load's reason would be gone by the time anyone read it --
      -- and a slow engage with no reason beside it is the case that cannot be diagnosed from
      -- a screen grab.
      do
        wrote = nil
        FFTSA_PXRING, FFTSA_PXSEED = nil, nil
        fftsa.nl._px_loaded, fftsa.nl._px_saved = nil, nil
        fftsa.nl.px_load_why, fftsa.nl.px_save_why = nil, nil
        io, file = keepio, keepfile
        file = { usbdriveexists = function() return 1 end }
        io = { open = function(nm, mode)
          if mode == 'w' then
            return { write = function(self, b) wrote = b end, close = function() end }
          end
          if wrote == nil then return nil end
          return { read = function(self, n) return wrote end, close = function() end }
        end }
        local keepfs2, keepkey2 = fs, fftsa.nl.PX_CACHE_KEY
        fs = { readdir = function(d)
          if d ~= fftsa.nl.PX_CACHE_DIR then return nil end
          local t = {}
          t[0] = 'something_else.tspa'
          return t
        end }
        fftsa.nl.PX_CACHE_KEY = true
        local miss = fftsa.nl.px_cache_load()
        local why_after_load = fftsa.nl.px_load_why
        fftsa.nl.px_seed_note(SEED2)
        FFTSA_PXRING = string.format('%d,%d,%d,%d,%d,%d', SEED2, SEED2 + 4096, 24, 56, 0, 12)
        local re = fftsa.nl.px_cache_save()
        io, fs, file = keepio, keepfs2, keepfile
        fftsa.nl.PX_CACHE_KEY = keepkey2
        check('a save that succeeds does not erase why the load missed',
              miss == false and why_after_load == 'no record on the key yet'
              and re == true and fftsa.nl.px_load_why == why_after_load
              and fftsa.nl.px_save_why == nil,
              string.format('load=%s loadwhy=%s save=%s loadwhy after=%s savewhy=%s',
                            tostring(miss), tostring(why_after_load), tostring(re),
                            tostring(fftsa.nl.px_load_why),
                            tostring(fftsa.nl.px_save_why)))
        fftsa.nl.px_load_why, fftsa.nl.px_save_why = nil, nil
      end
      -- With no key in the slot a save must not raise into the frame, and must not claim it
      -- wrote. file.usbdriveexists is the guard: a write with no key posts 2203 over the app.
      file = { usbdriveexists = function() return 0 end }
      fftsa.nl.PX_CACHE_KEY = true
      fftsa.nl._px_saved = nil
      local nokey = fftsa.nl.px_cache_save()
      file = keepfile
      fftsa.nl.PX_CACHE_KEY = keepkey
      check('a save with no key in the slot refuses quietly rather than raising',
            nokey == false, 'save returned ' .. tostring(nokey))
    end
    FFTSA_PXRING, FFTSA_PXSEED = keep, keeps
    fftsa.nl.inst = keepinst
  end

  -- ---- a lookalike in the same slice -----------------------------------------
  do
    -- One sweep slice holding both the staging lookalike and the real ring. The slice has to
    -- come back with BOTH confirmations: returning the first one and dropping it when it has
    -- no header leaves the cursor past the real ring, which reads as "swept and absent" and
    -- cost 981 MB of sweeping on the instrument before it was understood.
    --
    -- The budget spans the whole first window, so "one slice" is a fact here rather than an
    -- alignment that happened: at 4 KB the two sit 1,640 bytes apart and a slice edge falls
    -- between them often enough that the case would pass or fail on the fixture's address.
    build(nil)
    stage()
    -- No seed, because the ladder under test is the unseeded one: a cached ring puts a 4 MB
    -- window at the front, which is wider than this budget, and then "one slice" stops being
    -- a fact. The seeding has its own gate below.
    FFTSA_PXRING, FFTSA_PXSEED = nil, nil
    fftsa.nl.px_restart('test')
    fftsa.nl.px.noname = true
    local SENT, i = {}, nil
    for i = 1, 4 do SENT[i] = { db = DB[i], hz = HZ[i] } end
    -- DRAINED ACROSS FRAMES, AND THE SLICE IS READ ONCE. A frame's read allowance can stop
    -- the hit walk part way through a dense slice, so the two confirmations need not arrive in
    -- the same call. What must hold is that neither is lost and that the bytes are not swept
    -- again to recover the second: the hits are kept, not rediscovered.
    local c, calls, all, nall = {}, 0, {}, 0
    local swept_at_first = nil
    while calls < 20 do
      calls = calls + 1
      fftsa.nl.rd_frame_reset()
      c = fftsa.nl.px_seek(HZ, NSEG, 1048576, nil)
      local ci
      for ci = 1, table.getn(c) do
        nall = nall + 1
        all[nall] = c[ci]
      end
      if swept_at_first == nil and nall > 0 then swept_at_first = fftsa.nl.px.swept end
      if nall >= 2 then break end
    end
    local swept_at_end = fftsa.nl.px.swept
    local s28, s56, k = nil, nil, nil
    for k = 1, nall do
      if all[k].stride == 28 then s28 = all[k] end
      if all[k].stride == STRIDE then s56 = all[k] end
    end
    check('a dense slice is swept once and every confirmation in it is kept',
          s28 ~= nil and s56 ~= nil and swept_at_first ~= nil
          and swept_at_end == swept_at_first,
          string.format('28-byte=%s 56-byte=%s over %d call(s), swept %d -> %d bytes',
                        s28 ~= nil and string.format('%X', s28.val0) or 'none',
                        s56 ~= nil and string.format('%X', s56.val0) or 'none', calls,
                        swept_at_first or -1, swept_at_end or -1))
    check('one slice holding a lookalike and the ring returns both confirmations',
          s28 ~= nil and s56 ~= nil and s28.val0 == SLO and s56.val0 ~= SLO,
          string.format('%d confirmations in slice %d: 28-byte=%s 56-byte=%s',
                        table.getn(c), calls, s28 and string.format('%X', s28.val0) or 'none',
                        s56 and string.format('%X', s56.val0) or 'none'))
    check('and only the real one carries a header',
          s28 ~= nil and s56 ~= nil and fftsa.nl.find_ring_header(s28) == nil
          and fftsa.nl.find_ring_header(s56) ~= nil,
          'why=' .. tostring(fftsa.nl.ring_why))
  end

  do
    -- And the whole path gets there anyway, with the lookalike in the way.
    build(nil)
    stage()
    FFTSA_PXRING = nil
    fftsa.nl.px_restart('test')
    fftsa.nl.px.noname, fftsa.nl.px.state = true, 'idle'
    local calls, n = 0, nil
    while n == nil and calls < 500 do
      calls = calls + 1
      n = fftsa.nl.px_try(DB, HZ, NSEG, 'TB', 3000 + calls)
    end
    check('the path engages past a headerless lookalike in the same slice',
          n == NSEG and fftsa.nl.px.state == 'on' and fftsa.nl.px.lo == RLO
          and fftsa.nl.px.stride == STRIDE,
          string.format('n=%s state=%s ring=%s/%s after %d frames', tostring(n),
                        tostring(fftsa.nl.px.state),
                        fftsa.nl.px.lo and string.format('%X', fftsa.nl.px.lo) or 'nil',
                        tostring(fftsa.nl.px.stride), calls))
  end

  -- ---- the whole path --------------------------------------------------------
  do
    build(nil)
    FFTSA_PXRING = nil
    fftsa.nl.px_restart('test')
    fftsa.nl.px.noname, fftsa.nl.px.state = true, 'idle'
    local saw, calls, n = {}, 0, nil
    while n == nil and calls < 500 do
      calls = calls + 1
      n = fftsa.nl.px_try(DB, HZ, NSEG, 'TB', 2000 + calls)
      saw[fftsa.nl.px.state] = true
    end
    -- THE SEARCH RUNS WHILE THE STATE IS STILL IDLE, and the frame that engages also draws
    -- rather than returning nil and leaving the caller to append a pass it has already mapped.
    --
    -- The search's own states are seek, hdr and map, and a candidate found by the SEARCH walks
    -- all three. A candidate found by one of the cheap routes does not: the idle arm maps it
    -- where it stands and that frame draws, which is what this gate is on.
    --
    -- `seek` is a LATCH rather than a stage: the cheap routes -- the cached geometry and the
    -- object table entry -- are worth several frames each, and they used to be spent BEFORE
    -- the search started, so their frames were pure latency whenever they failed. The frame
    -- now falls through to the search with the state left at idle, so the cheap routes are
    -- retried next frame and neither waits for the other. Whichever answers first wins.
    --
    -- So a path that engages from the search inside PX_CACHE_TRIES frames never sets `seek` at
    -- all, and asserting that it passed through it is asserting the old serial order.
    --
    -- `from` is pinned as well. Without it this gate passes on a run that engaged from the
    -- cache a previous block wrote, which is the opposite of what it is here to prove.
    check('the search engages from idle, and the frame that engages also draws',
          n == NSEG and fftsa.nl.px.state == 'on' and saw['idle'] and not saw['seek']
          and fftsa.nl.px.from == 'search' and (fftsa.nl.px.swept or 0) > 0
          and calls < fftsa.nl.PX_CACHE_TRIES and FFTSA_PXRING ~= nil,
          string.format('n=%s state=%s via=%s after %d frames of %d, states=%s%s%s, '
                        .. 'swept=%s, cache=%s',
                        tostring(n), tostring(fftsa.nl.px.state),
                        tostring(fftsa.nl.px.from), calls, fftsa.nl.PX_CACHE_TRIES,
                        saw['idle'] and 'idle ' or '', saw['seek'] and 'seek ' or '',
                        saw['on'] and 'on' or '', tostring(fftsa.nl.px.swept),
                        tostring(FFTSA_PXRING)))
    check('and the state reads back as one field for the error page',
          string.find(fftsa.nl.px_str(), 'px=on', 1, true) == 1
          and string.find(fftsa.nl.px_str(), 'map=', 1, true) ~= nil,
          fftsa.nl.px_str())
    -- The cache then takes the next launch straight to the map, with no sweep at all.
    fftsa.nl.px.state, fftsa.nl.px.swept = 'idle', 0
    local n2 = fftsa.nl.px_try(DB, HZ, NSEG, 'TB', 9999)
    check('a cached ring engages on the first frame and sweeps nothing',
          n2 == NSEG and fftsa.nl.px.state == 'on' and fftsa.nl.px.from == 'cache'
          and (fftsa.nl.px.swept or 0) == 0,
          string.format('n=%s via=%s swept=%s', tostring(n2), tostring(fftsa.nl.px.from),
                        tostring(fftsa.nl.px.swept)))
  end

  do
    -- Off is off: nothing is swept, nothing is written, and the caller keeps its appends.
    fftsa.nl.px_off('the test said so')
    WROTE = nil
    check('a path switched off draws nothing and writes nothing',
          fftsa.nl.px_try(DB, HZ, NSEG, 'TB', 1) == nil and WROTE == nil
          and string.find(fftsa.nl.px_str(), 'px=off', 1, true) == 1,
          fftsa.nl.px_str())
  end

  do
    -- THE CACHE IS WORTH MORE THAN ONE FRAME. px_map needs every slot of the drawn window to
    -- carry a frequency this plan has, and on a relaunch the trace object has only just been
    -- created -- so the first attempt fails whatever the address, and says nothing about
    -- whether it was right. Abandoning it there sent a relaunch to the sweep: 20 seconds and
    -- about 50 MB on the glass to find a ring the cache could have named.
    fftsa.nl.px_restart('cache tries')
    -- A geometry that is the right shape but will not map yet: the ring is where the cache
    -- says, the frequencies are not in it.
    fftsa.nl.px_cache_put({ lo = TRING, hi = TRING + NREC * STRIDE, nrec = NREC,
                            stride = STRIDE, ox = OX, hdr = TBOUND })
    local keephz, j = {}, nil
    for j = 1, NSEG do keephz[j] = HZ[j] + 7919 end
    local tries, st = 0, nil
    for j = 1, fftsa.nl.PX_CACHE_TRIES + 2 do
      fftsa.nl.px_try(DB, keephz, NSEG, 'TB', 7100 + j, GID)
      if fftsa.nl.px.state == 'idle' then tries = tries + 1 end
      st = fftsa.nl.px.state
    end
    -- KEEPS TRYING, which is the whole point: a cache that cannot map on the first frame says
    -- nothing about whether its address is right, and neither does a pointer route whose
    -- live-address span is not wide enough yet. Both improve as the app runs. What must never
    -- happen is the path giving up for the session -- measured on the glass as an app that ran
    -- its whole session on the append path with why='no pointer and no usable cache'.
    check('a cache that cannot map yet is retried, not abandoned on the first frame',
          tries >= fftsa.nl.PX_CACHE_TRIES - 1 and st ~= 'off' and st ~= 'on',
          string.format('%d idle frame(s) of %d allowed, then state=%s, cachetries=%s',
                        tries, fftsa.nl.PX_CACHE_TRIES, tostring(st),
                        tostring(fftsa.nl.px.cachetries)))
  end

  do
    -- THE NATIVE SEARCH, through its marshalling. The image cannot run here, so call_native
    -- is replaced by a check of the REQUEST it was handed plus a fabricated answer. That is
    -- deliberately what this gates: the needle packed into four big-endian words, the block
    -- layout, and the answer decoded back. A wrong byte in a needle finds nothing for ever,
    -- and nothing else in the suite would notice.
    local keepready, keepentry = fftsa.nl.ready, fftsa.nl.entry
    local keepfa, keepfw = fftsa.nl.find_addr, fftsa.nl.FIND_WORDS
    local keepfm, keepcn = fftsa.nl.FIND_MAX, fftsa.nl.call_native
    local keepwp, keepmw, keepmr = fftsa.nl.write_params, ki.memwrite, ki.memread
    -- The REAL nfind for this block: the fixture emulates it everywhere else, and what is
    -- under test here is nfind's own marshalling.
    local keepemu = fftsa.nl.nfind
    fftsa.nl.nfind = SAVED_NF
    local FB, REQ = 4096, nil
    local H1, H2, NX = 61000000, 61000064, 61999999
    fftsa.nl.ready, fftsa.nl.entry = true, 1
    local keepnf = fftsa.nl.NFIND
    fftsa.nl.NFIND = true
    fftsa.nl.find_addr, fftsa.nl.FIND_WORDS, fftsa.nl.FIND_MAX = FB, 42, 32
    local sawmode = nil
    fftsa.nl.write_params = function(t) sawmode = t.mode; return true end
    ki.memwrite = function(a, b) if tonumber(a, 16) == FB then REQ = b end end
    local function be(v)
      return string.char(math.mod(math.floor(v / 16777216), 256),
                         math.mod(math.floor(v / 65536), 256),
                         math.mod(math.floor(v / 256), 256), math.mod(v, 256))
    end
    ki.memread = function(a, n)
      if tonumber(a, 16) == FB + 32 then
        return be(NX) .. be(2) .. be(H1) .. be(H2)
      end
      return keepmr(a, n)
    end
    fftsa.nl.call_native = function() return 2 end
    local want = 'FFTSA_TRACE' .. string.char(0)
    local hits, nxt = fftsa.nl.nfind(1000, 9000, want, 777)
    -- The request, byte for byte: four header words then the needle in four more, first byte
    -- in the top of the first.
    --
    -- THE FOURTH WORD CARRIES TWO FIELDS, which is the one place this wire format is not
    -- obvious. The image reads the needle length as the low half and the scan step as the high
    -- half -- `flen = (fb[3] << 16) >> 16` and `fstep = fb[3] >> 16` -- and it does that with
    -- shifts rather than a mask because a 0xFFFF literal in the C file is indistinguishable
    -- from an address to the firmware-address gate. Pack them the wrong way round and the
    -- image searches for a 4-byte needle with a step of eleven, finds nothing for ever, and
    -- nothing else in the suite notices.
    local STEP = fftsa.nl.NFIND_STEP or 1
    local expect = be(1000) .. be(9000) .. be(777)
                   .. be(string.len(want) + STEP * 65536)
    local wi
    for wi = 0, 3 do
      local acc = 0
      local bi
      for bi = 1, 4 do
        local k = wi * 4 + bi
        local c = 0
        if k <= string.len(want) then c = string.byte(want, k) end
        acc = acc * 256 + c
      end
      expect = expect .. be(acc)
    end
    check('the native search marshals its request byte for byte',
          REQ == expect and sawmode == fftsa.nl.MODE_FIND,
          string.format('%d request byte(s), %s, mode=%s, step=%d',
                        REQ and string.len(REQ) or -1,
                        REQ == expect and 'identical' or 'DIFFERENT', tostring(sawmode),
                        STEP))
    -- AND THE STEP IS IN THE HIGH HALF, stated separately from the byte compare so that a
    -- packing that happens to agree with a hand-written expectation still has to put the two
    -- fields where the image looks for them.
    do
      local w4 = 0
      local bi
      for bi = 13, 16 do w4 = w4 * 256 + string.byte(REQ, bi) end
      check('the step is the high half of the length word and the length the low half',
            math.floor(w4 / 65536) == STEP and math.mod(w4, 65536) == string.len(want),
            string.format('word 4 = %d: step %d, len %d', w4, math.floor(w4 / 65536),
                          math.mod(w4, 65536)))
    end
    -- A 4-STEP SCAN OF AN UNALIGNED RANGE ALIGNS UPWARD AND SAYS SO. Rounding the start
    -- silently moves it past bytes the caller believes were searched, which is the same defect
    -- as a short read reported as an absence -- so the aligned start comes back as `next` on
    -- an empty result and the caller resumes from there.
    if STEP == 4 then
      REQ = nil
      local uh, un = fftsa.nl.nfind(1001, 9000, want, 777)
      local rlo = 0
      local bi
      if REQ ~= nil then for bi = 1, 4 do rlo = rlo * 256 + string.byte(REQ, bi) end end
      check('an unaligned range is aligned upward rather than rounded in silence',
            rlo == 1004 and uh ~= nil,
            string.format('asked from 1001, searched from %d', rlo))
      -- And a range with no aligned start left in it is refused with a reason, rather than
      -- answering "nothing here" about bytes it never looked at.
      local sh, sn = fftsa.nl.nfind(1001, 1003, want, 777)
      check('a range too short to align is refused with a reason, not reported empty',
            sh ~= nil and table.getn(sh) == 0 and sn == 1003
            and fftsa.nl.find_why ~= nil,
            string.format('%s hit(s), next=%s, why=%s',
                          sh and table.getn(sh) or 'nil', tostring(sn),
                          tostring(fftsa.nl.find_why)))
    end
    check('and decodes the hits and the resume address back out',
          hits ~= nil and table.getn(hits) == 2 and hits[1] == H1 and hits[2] == H2
          and nxt == NX,
          string.format('%s hit(s) %s %s, next=%s',
                        hits and table.getn(hits) or 'nil',
                        hits and table.getn(hits) > 0 and tostring(hits[1]) or '-',
                        hits and table.getn(hits) > 1 and tostring(hits[2]) or '-',
                        tostring(nxt)))
    -- A needle longer than the block can carry is refused, not truncated: a truncated needle
    -- matches more than it should and the caller cannot tell.
    local long = fftsa.nl.nfind(1000, 9000, string.rep('x', 17), 0)
    check('a needle over the block size is refused rather than truncated',
          long == nil and fftsa.nl.find_why ~= nil, tostring(fftsa.nl.find_why))
    fftsa.nl.ready, fftsa.nl.entry = keepready, keepentry
    fftsa.nl.find_addr, fftsa.nl.FIND_WORDS = keepfa, keepfw
    fftsa.nl.FIND_MAX, fftsa.nl.call_native = keepfm, keepcn
    fftsa.nl.write_params, ki.memwrite, ki.memread = keepwp, keepmw, keepmr
    fftsa.nl.nfind = keepemu
    fftsa.nl.NFIND = keepnf
    -- AND IT IS CLAMPED TO MEASURED MEMORY, NOT TO THE BACKSTOP. Conflating the two
    -- bluescreened the instrument at PC=0022D200: the backstop is the span Lua may ASK
    -- ki.memread about, and ki.memread answers nil for anything unmapped, while the image
    -- loads directly and faults. So a range beyond the measured top must come back as no
    -- hits, having scanned nothing, rather than as a fault.
    do
      local kml, kmh = fftsa.nl.map_lo, fftsa.nl.map_hi
      local asked = nil
      local kn = fftsa.nl.nfind
      local kr, kfa = fftsa.nl.ready, fftsa.nl.find_addr
      local knf2, kmb = fftsa.nl.NFIND, fftsa.nl.map_bounds
      -- The clamp still has to be right, because it is what a safe range would be handed to.
      -- Armed and given measured bounds only for the length of these two cases.
      fftsa.nl.NFIND = true
      fftsa.nl.map_bounds = function() return 1000, 9000 end
      fftsa.nl.ready, fftsa.nl.find_addr = true, 4096
      fftsa.nl.map_lo, fftsa.nl.map_hi = 1000, 9000
      fftsa.nl.nfind = function(a, b) asked = { a, b }; return {}, b end
      local past = fftsa.nl._finds_native(20000, 30000, 'abcd')
      check('a range past the measured top of memory scans nothing',
            past ~= nil and table.getn(past) == 0 and asked == nil,
            'asked=' .. (asked and (tostring(asked[1]) .. '..' .. tostring(asked[2]))
                         or 'nothing'))
      asked = nil
      fftsa.nl._finds_native(500, 30000, 'abcd')
      check('and a range that straddles it is clamped to what was measured',
            asked ~= nil and asked[1] == 1000 and asked[2] == 9000,
            'asked=' .. (asked and (tostring(asked[1]) .. '..' .. tostring(asked[2]))
                         or 'nothing'))
      fftsa.nl.map_lo, fftsa.nl.map_hi, fftsa.nl.nfind = kml, kmh, kn
      fftsa.nl.ready, fftsa.nl.find_addr = kr, kfa
      fftsa.nl.NFIND, fftsa.nl.map_bounds = knf2, kmb
      -- AND THE SHIPPED DEFAULT IS OFF, with no probe left that could fault. Two bluescreens
      -- at PC=0022D200 came from bounding the image's loads by the backstop and then from
      -- probing outward to find the edge of memory -- ki.memread does not validate, so the
      -- probe is itself what falls off the end.
      -- THE LUA RING SWEEP SHIPS FORBIDDEN. PX_SWEEP is armed by this block only, to drive
      -- the ladder the bind path still shares; the shipped value is false, so a frame that
      -- has no pointer and no cache gets the native search or nothing.
      check('the Lua ring sweep is not permitted in the shipped module', (function()
        local fh = io.open('tsp/native_link.tsp', 'r')
        if fh == nil then return false, 'cannot read the module' end
        local body = fh:read('*a')
        fh:close()
        -- No knob at all, and the pixel path's seek requires the image.
        local off = string.find(body, 'fftsa.nl.PX_SWEEP = false', 1, true) ~= nil
        local on = string.find(body, 'fftsa.nl.PX_SWEEP = true', 1, true) ~= nil
        local native = string.find(body, 'nl.NFIND and mlo ~= nil and nl.ready', 1, true) ~= nil
        return off and not on and native,
               'ships false=' .. tostring(off) .. ' any true=' .. tostring(on)
               .. ' native-gated=' .. tostring(native)
      end)())
    end
  end

  do
    -- NO FRAME OF THE SEARCH MAY READ WITHOUT BOUND, and this is the gate each of the four
    -- cost bugs needed and none of them had. Every one was the same shape: an iteration count
    -- taken from the heap with an IPC round trip in the body, inside a frame that cannot be
    -- interrupted -- 257 peek32 for each name hit, 29 memread for each frequency hit, a holder
    -- sweep over the whole of DRAM, and a dense slice re-walked for ever. Each was found by the
    -- operator losing minutes of bench time to it, one at a time. Counting the reads per frame
    -- turns the whole class into one assertion.
    --
    -- Driven from idle so the frames cover seeking, the header walk, the map and the engaged
    -- draw -- every path a frame can take.
    fftsa.nl.px_restart('read budget')
    FFTSA_PXRING, FFTSA_PXSEED = nil, nil
    fftsa.nl.rd_peak_calls, fftsa.nl.rd_peak_bytes = 0, 0
    -- THE RUNNING FIGURES TOO, not just the peaks. rd_frame_reset moves the frame that just
    -- ended into last= and zeroes the accumulator, so last= read after a px_try is the
    -- PREVIOUS frame's -- and on the first iteration it is whatever the block before this one
    -- left behind. This gate read 1031 KB against a 1024 KB ceiling for exactly that reason:
    -- the figure was another block's and no frame here had ever exceeded the budget.
    fftsa.nl.nf_peak_bytes, fftsa.nl.nf_last_bytes = 0, 0
    fftsa.nl._nf_bytes, fftsa.nl._nf_secs = 0, 0
    fftsa.nl.rd_last_calls, fftsa.nl.rd_last_bytes = 0, 0
    fftsa.nl._rd_calls, fftsa.nl._rd_bytes = 0, 0
    local f, worst, worstb, at = nil, 0, 0, nil
    for f = 1, 150 do
      fftsa.nl.px_try(DB, HZ, NSEG, 'TB', 9000 + f, GID)
      if (fftsa.nl.rd_last_calls or 0) > worst then
        worst = fftsa.nl.rd_last_calls
        at = fftsa.nl.px.state
      end
      if (fftsa.nl.rd_last_bytes or 0) > worstb then worstb = fftsa.nl.rd_last_bytes end
    end
    -- One more frame so the last one's accumulator is moved into the peak rather than left
    -- unexamined, and the module's own running maximum is the figure judged -- the same one
    -- the About page reports.
    fftsa.nl.px_try(DB, HZ, NSEG, 'TB', 9000 + 151, GID)
    local worstnf = fftsa.nl.nf_peak_bytes or 0
    -- A BACKSTOP, AND ONLY THAT. This fixture's heap is not dense in either needle, so a
    -- reintroduced per-item read cost does not necessarily show up here -- measured: putting
    -- the 257-peek name walk back left this gate reading 10 per frame and passing. What catches
    -- that class is the per-site read counts above, one for each loop in the module that
    -- reads. This one exists to catch a NEW loop nobody thought to count.
    --
    -- Twice the allowance, because a loop asks the budget AFTER a read and so may overshoot by
    -- one item, and because px_map's window is a single large read of its own.
    check('no frame of the search reads without bound',
          worst > 0 and worst <= fftsa.nl.RD_MAX_CALLS * 2,
          string.format('worst frame %d reads (%d KB), allowance %d, worst state %s',
                        worst, math.floor(worstb / 1024), fftsa.nl.RD_MAX_CALLS,
                        tostring(at)))
    -- AND NEITHER DOES THE IMAGE, which now has its own allowance. Moving the scanned bytes
    -- off the read account is what let the slice grow to the hardware's speed; without a bound
    -- of its own that is an unbounded scan inside a frame, which is the same defect in a new
    -- place. The ceiling is a slice that would cost 40 ms even at ki.memread's 25 MB/s.
    check('and the image scans no more in a frame than the timed budget allows',
          worstnf > 0 and worstnf <= fftsa.nl.PX_NBUDGET_MAX,
          string.format('worst frame scanned %d KB, ceiling %d KB',
                        math.floor(worstnf / 1024),
                        math.floor(fftsa.nl.PX_NBUDGET_MAX / 1024)))
  end

  -- ---- the slice is sized by the clock, not by a figure in the tree -----------
  do
    local keepb, keepr = fftsa.nl.px_nbudget, fftsa.nl.px_nrate
    local keepnf = fftsa.nl.nfind
    local keepa, keepbb = fftsa.nl.px_nb_a, fftsa.nl.px_nb_b
    fftsa.nl.px_nbudget, fftsa.nl.px_nrate = fftsa.nl.PX_NBUDGET_MIN, nil
    -- AND THE TWO FIT SAMPLES, because they are what decides which arm of px_nb_note runs.
    -- With a pair already standing from the block above, a note that cannot be timed took the
    -- fitted arm instead of the doubling arm and this gate tested the wrong one.
    fftsa.nl.px_nb_a, fftsa.nl.px_nb_b = nil, nil
    -- With an image the slice is the timed budget; without one it is the read path's figure,
    -- because then the search IS ki.memread.
    local withimg = fftsa.nl.px_budget()
    fftsa.nl.nfind = nil
    local without = fftsa.nl.px_budget()
    fftsa.nl.nfind = keepnf
    check('the slice size follows which engine is doing the searching',
          withimg == fftsa.nl.px_nbudget and without == fftsa.nl.PX_BUDGET,
          string.format('image=%d read path=%d', withimg, without))
    -- A slice too fast to time doubles, which is how a budget set from a Lua read's rate
    -- climbs to the image's without anybody asserting what the image's rate is.
    fftsa.nl.px_nb_note(262144, 0)
    local doubled = fftsa.nl.px_nbudget
    check('a slice the clock cannot resolve doubles the next one',
          doubled == 524288, string.format('%d KB', math.floor(doubled / 1024)))
    -- AND A SIZE NOTED OVER AND OVER ALTERNATES rather than climbing, because two samples of
    -- the same size cannot separate the fixed cost from the rate. The alternation is what
    -- produces the second point: one frame at the floor, the next at twice it, and the fit
    -- lands on the frame after that. Noting one size for ever is a frame that is not following
    -- the budget, and then nothing is learned -- which is the honest outcome, not a runaway.
    local i, lowest, highest = nil, nil, nil
    for i = 1, 20 do
      fftsa.nl.px_nb_note(262144, 0)
      local b = fftsa.nl.px_nbudget
      if lowest == nil or b < lowest then lowest = b end
      if highest == nil or b > highest then highest = b end
    end
    check('a size noted over and over alternates instead of climbing',
          lowest == fftsa.nl.PX_NBUDGET_MIN and highest == fftsa.nl.PX_NBUDGET_MIN * 2
          and fftsa.nl.px_nrate == nil,
          string.format('%d KB to %d KB over 20 notes, rate=%s',
                        math.floor(lowest / 1024), math.floor(highest / 1024),
                        tostring(fftsa.nl.px_nrate)))
    -- A FIT FROM AN IMPOSSIBLE RATE IS CLAMPED, not believed. The budget is a frame's time
    -- turned into bytes, and the one thing it may never be is larger than the ceiling -- a
    -- frame cannot be interrupted, so a slice sized from a mistimed pair would be a scan with
    -- no bound inside it.
    fftsa.nl.px_nb_a, fftsa.nl.px_nb_b, fftsa.nl.px_nrate = nil, nil, nil
    fftsa.nl.px_nb_note(262144, 0.000001)
    fftsa.nl.px_nb_note(1048576, 0.000002)
    check('a fit from a rate too high to be real is clamped to the ceiling',
          fftsa.nl.px_nbudget == fftsa.nl.PX_NBUDGET_MAX and fftsa.nl.px_nrate ~= nil,
          string.format('%d KB of %d KB at %.0f MB/s',
                        math.floor(fftsa.nl.px_nbudget / 1024),
                        math.floor(fftsa.nl.PX_NBUDGET_MAX / 1024),
                        fftsa.nl.px_nrate / 1048576))
    -- AND AN OVERHEAD THAT EATS THE WHOLE FRAME LEAVES THE FLOOR, not a negative slice. This
    -- is the case the two-point fit exists for: the time a frame spends adjudicating hits is
    -- fixed cost, and if it alone exceeds the target then no slice size helps.
    fftsa.nl.px_nb_a, fftsa.nl.px_nb_b, fftsa.nl.px_nrate = nil, nil, nil
    fftsa.nl.px_nb_note(262144, fftsa.nl.PX_NMS * 4)
    fftsa.nl.px_nb_note(1048576, fftsa.nl.PX_NMS * 4 + 0.001)
    check('an overhead larger than the frame target leaves the slice on its floor',
          fftsa.nl.px_nbudget == fftsa.nl.PX_NBUDGET_MIN
          and (fftsa.nl.px_nover or 0) > fftsa.nl.PX_NMS,
          string.format('%d KB, overhead %.1f ms against a %.1f ms target',
                        math.floor(fftsa.nl.px_nbudget / 1024),
                        (fftsa.nl.px_nover or 0) * 1000, fftsa.nl.PX_NMS * 1000))
    -- A TIMED PAIR SETS THE BUDGET FROM THE RATE, and the floor is what stops a slow frame
    -- collapsing the slice to nothing. 4 MB/s for a 30 ms target is 126 KB, below the floor,
    -- so the floor is the answer -- and 4 MB/s is not a made-up figure: it is what this
    -- reported on the glass at 9.05 on the launch where the whole slice was timed instead of
    -- the scan, with ninety-one name hits charged to the bytes the image had scanned.
    --
    -- Its own pair, because a fit needs two points at distinct sizes with a positive slope,
    -- and a pair left standing from the gate above gives a negative one -- a larger slice
    -- recorded as faster -- which produces no fit at all and no rate to divide by.
    fftsa.nl.px_nb_a, fftsa.nl.px_nb_b, fftsa.nl.px_nrate = nil, nil, nil
    local RATE = 4194304
    fftsa.nl.px_nb_note(262144, 262144 / RATE)
    fftsa.nl.px_nb_note(1048576, 1048576 / RATE)
    check('a timed slice sizes the next one from the measured rate, and clamps it',
          fftsa.nl.px_nbudget == fftsa.nl.PX_NBUDGET_MIN
          and fftsa.nl.px_nrate ~= nil
          and fftsa.nl.px_nrate > RATE * 0.99 and fftsa.nl.px_nrate < RATE * 1.01,
          string.format('%d KB at %.1f MB/s, wanted the %d KB floor at %.1f MB/s',
                        math.floor(fftsa.nl.px_nbudget / 1024),
                        (fftsa.nl.px_nrate or 0) / 1048576,
                        math.floor(fftsa.nl.PX_NBUDGET_MIN / 1024), RATE / 1048576))
    -- A sample too small to be the scan is not a measurement of the scan.
    fftsa.nl.px_nbudget, fftsa.nl.px_nrate = 524288, nil
    fftsa.nl.px_nb_note(4096, 0.5)
    check('a slice too small to be the scan is not believed',
          fftsa.nl.px_nbudget == 524288 and fftsa.nl.px_nrate == nil,
          string.format('%d KB, rate=%s', math.floor(fftsa.nl.px_nbudget / 1024),
                        tostring(fftsa.nl.px_nrate)))
    fftsa.nl.px_nbudget, fftsa.nl.px_nrate = keepb, keepr
    fftsa.nl.px_nb_a, fftsa.nl.px_nb_b = keepa, keepbb
  end

  -- ---- the name needle's retirement, and how long its counters live ----------
  --
  -- A freed trace object keeps the buffer name, so on an instrument the app has been run on
  -- the needle matches every corpse of every previous run -- 1424 of them in one boot. It is
  -- retired after PX_NAME_FAIL hits that produce no candidate at all, and the frequency needle
  -- carries on, because a freed ring holds zeros and the frequencies can only match a live one.
  --
  -- THE COUNTER AND THE FLAG MUST HAVE THE SAME LIFETIME. px_restart clears the flag -- a
  -- restart means the plan or the traces changed, so the corpse count says nothing about the
  -- pass ahead -- and it used to leave the count alone. The needle was then revived by every
  -- restart and re-condemned at once by hits from the passes before it. Measured on the glass
  -- at 9.14 from a clean boot: re=4, nh=69, namedead=69, noname=1, by=freq, win=13/17,
  -- swept=27MB, eng=10.6s, with the ring inside the instance band that the ladder tries third.
  -- Seventeen hits a pass, condemned by a bound of sixty-four.
  do
    fftsa.nl.px_restart('name needle')
    FFTSA_PXRING, FFTSA_PXSEED = nil, nil
    local p = fftsa.nl.px
    p.nhall = 0
    -- One short of the bound, and nothing may be retired yet.
    p.namehits, p.ncand, p.noname = fftsa.nl.PX_NAME_FAIL - 1, 0, nil
    fftsa.nl.px_try(DB, HZ, NSEG, 'TB', 14001, GID)
    local under = p.noname
    -- At the bound, and it is.
    p.namehits, p.ncand, p.noname = fftsa.nl.PX_NAME_FAIL, 0, nil
    fftsa.nl.px_try(DB, HZ, NSEG, 'TB', 14002, GID)
    check('the name needle is retired at its bound and not before',
          under == nil and p.noname == true and p.namedead ~= nil,
          string.format('under=%s at=%s namedead=%s', tostring(under), tostring(p.noname),
                        tostring(p.namedead)))
    -- A RESTART REVIVES IT, COUNTERS AND ALL. The flag alone is not a reprieve.
    local hitsbefore = p.namehits
    fftsa.nl.px.swept = fftsa.nl.PX_NAME_GIVEUP * 4
    fftsa.nl.px.sweptpass = fftsa.nl.PX_NAME_GIVEUP * 4
    fftsa.nl.px_restart('traces rebound')
    check('a restart revives the name needle and zeroes the counts that condemned it',
          p.noname == nil and (p.namehits or 0) == 0 and (p.ncand or 0) == 0
          and (p.sweptpass or 0) == 0 and (p.nhall or 0) == hitsbefore,
          string.format('noname=%s nh=%s ncand=%s sweptpass=%s nhall=%s of %d before',
                        tostring(p.noname), tostring(p.namehits), tostring(p.ncand),
                        tostring(p.sweptpass), tostring(p.nhall), hitsbefore))
    -- AND THE SESSION'S SWEPT TOTAL DOES NOT CONDEMN IT EITHER, which is the bug that cost the
    -- most. The byte bound asks whether THIS pass has swept far enough without a hit to
    -- conclude the name is not in memory. Asked of the cumulative total it answers yes on the
    -- first slice of every pass after the second -- the total is already past the bound whatever
    -- the pass has done -- so on a launch that restarts while the app builds its screens, the
    -- pass with the live trace object in it runs without the only needle that says which trace.
    --
    -- swept stays cumulative, because that is the honest figure for what was scanned and the
    -- report shows both. Only the judgement is per pass.
    do
      local gaveup1 = p.gaveup or 0
      p.swept = fftsa.nl.PX_NAME_GIVEUP * 4
      p.sweptpass, p.namehits, p.ncand, p.noname = 0, 0, 0, nil
      fftsa.nl.px_seek(HZ, NSEG, 4096, nil)
      check('a session total past the byte bound does not condemn a pass that is inside it',
            p.noname == nil and (p.gaveup or 0) == gaveup1
            and (p.sweptpass or 0) < fftsa.nl.PX_NAME_GIVEUP,
            string.format('swept=%d of a %d bound, this pass %d, noname=%s',
                          p.swept, fftsa.nl.PX_NAME_GIVEUP, p.sweptpass or 0,
                          tostring(p.noname)))
    end
    -- AND THE CORPSE COUNT NO LONGER CONDEMNS IT, which is the regression itself: with the
    -- count left cumulative the first frame after the restart retired it again.
    --
    -- Asserted on `gaveup`, which only the corpse branch increments. The needle has two other
    -- ways to be condemned -- a whole ladder swept with no hit at all, and PX_NAME_GIVEUP
    -- bytes with no hit -- and both are correct and may well fire in a fixture whose ladder is
    -- small enough to finish a lap in one frame. Asserting on `noname` alone would be a gate on
    -- all three at once, which would pass or fail for reasons that have nothing to do with the
    -- count under test.
    local gaveup0 = p.gaveup or 0
    p.namehits, p.ncand = fftsa.nl.PX_NAME_FAIL - 1, 0
    fftsa.nl.px_try(DB, HZ, NSEG, 'TB', 14003, GID)
    check('and the corpses counted before the restart no longer condemn it after one',
          (p.gaveup or 0) == gaveup0,
          string.format('gaveup %d -> %d with nh=%s and nhall=%s', gaveup0,
                        p.gaveup or 0, tostring(p.namehits), tostring(p.nhall)))
    fftsa.nl.px_restart('name needle done')
  end

  -- ---- the subscriber table: the trace without searching for it ---------------
  --
  -- graph_trace_add calls bufsub_subscribe(0x407F, graph, trace+0x08, &routing_element), which
  -- copies the NAME to slot+0x08, the graph to slot+0x34 and the routing element's ADDRESS to
  -- slot+0x40. So the slot is name_address - 8 and the trace is *(*(slot+0x40)) -- no table
  -- base, no stride, no slot count, and nothing that depends on the display handle.
  --
  -- Confirmed on a DMM6500 at 1.7.17a with the app running: slot 00D67CD0 kind 0000407F
  -- graph 03134A28 p4 03134EC0, *(p4) = 0352D4B0, trace+0x08 = FFTSA_TRACE, trace+0x00 =
  -- 03134A28, trace+0x30 = 00D67CD0, trace+0x1F0 = 0352D6D0..03537488 count 510, and
  -- trace+0x220 = 0352D6D0. Every link confirms another.
  do
    local SUBW = fftsa.nl.PX_SUB_LO
    local SLOT = SUBW + 2048
    local SGRAPH = TLO - 8192
    local SP4 = SGRAPH + fftsa.nl.PX_ROUTE_LO + 4
    -- THE DECOY, BELOW THE SLOT SO IT IS FOUND FIRST. The c2c request record holds a copy of
    -- the name and a pointer to the current slot, and it sits below the table -- measured, two
    -- name hits in the window, the first at 00D67598 whose first word read back 00D67CD0, the
    -- live slot's own address. A search that took the first hit would have followed it.
    local DECOY = SUBW + 1024
    local function wrstr(at, str)
      local i
      for i = 0, string.len(str) - 1 do
        local a = at + i
        local w = a - math.mod(a, 4)
        local old4 = IMG[w] or string.rep(string.char(0), 4)
        local k = a - w + 1
        IMG[w] = string.sub(old4, 1, k - 1) .. string.sub(str, i + 1, i + 1)
                 .. string.sub(old4, k + 1)
      end
    end
    local NM = fftsa.nl.PX_NAME .. string.char(0)
    local function wire(kind, p4, back, sub)
      build(nil)
      tracefix()
      fftsa.nl.px_subslot = nil
      fftsa.nl.px_subfinds = 0
      fftsa.nl.px_subwin = nil
      fftsa.nl.sub_walkdone = nil
      wr32(DECOY, SLOT)
      wrstr(DECOY + fftsa.nl.PX_SUB_NAME, NM)
      wr32(SLOT, kind)
      wrstr(SLOT + fftsa.nl.PX_SUB_NAME, NM)
      wr32(SLOT + fftsa.nl.PX_SUB_GRAPH, SGRAPH)
      wr32(SLOT + fftsa.nl.PX_SUB_P4, p4)
      wr32(SP4, TLO)
      wr32(TLO + fftsa.nl.PX_TR_GRAPH, back)
      wr32(TLO + fftsa.nl.PX_TR_SUB, sub)
    end

    wire(fftsa.nl.PX_SUB_KIND, SP4, SGRAPH, SLOT)
    local got = fftsa.nl.px_sub_slot()
    check('the slot is found by the name, and the decoy below it is passed over',
          got == SLOT and (fftsa.nl.sub_hits or 0) == 2,
          string.format('slot=%s wanted %X, %s name hit(s)', tostring(got) and
                        (got and string.format('%X', got) or 'nil'), SLOT,
                        tostring(fftsa.nl.sub_hits)))
    local gs = fftsa.nl.px_from_bufsub()
    local g = nil
    local gi
    for gi = 1, table.getn(gs) do
      if gs[gi].stride == STRIDE then g = gs[gi] end
    end
    check('the chain reaches the trace object with no search at all',
          g ~= nil and g.lo == TRING and g.hdr == TBOUND and g.via_sub == true,
          g ~= nil and string.format('ring %X hdr %X via_sub=%s', g.lo, g.hdr,
                                     tostring(g.via_sub))
          or string.format('%d candidate(s), why=%s', table.getn(gs),
                           tostring(fftsa.nl.sub_why)))
    -- A TRACE OUTSIDE THE APP'S OWN SPAN IS STILL THE RIGHT TRACE.
    --
    -- Measured on the glass at 9.24, second run of a boot: the chain found the right slot and
    -- the right trace and px_live refused it 209 times -- `3E0EF30 outside 11EB018..3C8C7C8` --
    -- because the span is built from addresses THIS APP has read and the trace object belongs
    -- to the display task, which on a relaunch allocated above it. The route never engaged, so
    -- the sweep ran: swept=126MB, nh=538, under 3 fps at 2048 points.
    --
    -- The span is not a map of what is mapped. ki.memread is: it validates and refuses where
    -- ki.peek32 faults, which is what the abandoned Lua sweep relied on over hundreds of
    -- megabytes. So the chain reads through _rdw and the confirmed trace JOINS the span.
    do
      local keepml, keepmh = fftsa.nl.map_lo, fftsa.nl.map_hi
      local keepok = fftsa.nl.sub_trace_ok
      wire(fftsa.nl.PX_SUB_KIND, SP4, SGRAPH, SLOT)
      fftsa.nl.px_subslot, fftsa.nl.px_subwin, fftsa.nl.px_subfinds = nil, nil, 0
      fftsa.nl.sub_trace_ok = nil
      -- A span that excludes the trace entirely, which is what a relaunch produced.
      fftsa.nl.map_lo, fftsa.nl.map_hi = TLO + 1048576, TLO + 2097152
      fftsa.nl._map_age = 0
      local out9 = fftsa.nl.px_from_bufsub()
      local g9, gi9 = nil, nil
      for gi9 = 1, table.getn(out9) do
        if out9[gi9].stride == STRIDE then g9 = out9[gi9] end
      end
      check('a trace outside the app own span is read anyway, and joins it',
            g9 ~= nil and g9.lo == TRING and fftsa.nl.sub_trace_ok == TLO,
            g9 ~= nil and string.format('ring %X, span now includes %X', g9.lo,
                                        fftsa.nl.sub_trace_ok or 0)
            or string.format('%d candidate(s), why=%s', table.getn(out9),
                             tostring(fftsa.nl.sub_why)))
      -- THE TWO HALVES SEPARATELY, because the end-to-end check above passes either way: the
      -- span re-derivation unions several of this app's own addresses and in this fixture they
      -- happen to reach the trace. A gate that cannot fail when the mechanism is removed is
      -- not testing the mechanism.
      do
        local keeplo, keephi = fftsa.nl.map_lo, fftsa.nl.map_hi
        fftsa.nl.map_lo, fftsa.nl.map_hi = TLO + 1048576, TLO + 2097152
        fftsa.nl._map_age = 0
        -- One: it is px_live that refuses an address outside the span, not _wg -- _wg is
        -- gated on the BACKSTOP, the whole proven DRAM extent, which was my mistaken premise
        -- when writing this. So the mechanism is that the chain no longer consults px_live and
        -- reads through _rdw, which goes through the firmware's validating read path.
        local lived = fftsa.nl.px_live(TLO + fftsa.nl.PX_TRACE_BNDS)
        local byr = fftsa.nl._rdw(TLO + fftsa.nl.PX_TRACE_BNDS)
        check('px_live refuses an address outside the span that memread reads fine',
              lived == false and byr == TRING,
              string.format('px_live=%s _rdw=%s wanted %X', tostring(lived), tostring(byr),
                            TRING))
        -- Two: the span. A confirmed trace is one of the addresses map_bounds unions.
        fftsa.nl.sub_trace_ok = nil
        fftsa.nl.map_lo, fftsa.nl.map_hi = nil, nil
        fftsa.nl._map_age = fftsa.nl.MAP_REFRESH
        local lo0, hi0 = fftsa.nl.map_bounds()
        local FAR = 251658240
        fftsa.nl.sub_trace_ok = FAR
        fftsa.nl.map_lo, fftsa.nl.map_hi = nil, nil
        fftsa.nl._map_age = fftsa.nl.MAP_REFRESH
        local lo1, hi1 = fftsa.nl.map_bounds()
        check('a confirmed trace widens the span that px_from_trace is judged against',
              lo0 ~= nil and lo1 ~= nil and hi1 > hi0 and FAR < hi1 and FAR >= lo1
              and fftsa.nl.px_live(FAR) == true,
              string.format('%X..%X without it, %X..%X with %X', lo0 or 0, hi0 or 0,
                            lo1 or 0, hi1 or 0, FAR))
        fftsa.nl.sub_trace_ok = nil
        fftsa.nl.map_lo, fftsa.nl.map_hi = keeplo, keephi
        fftsa.nl._map_age = 0
      end
      fftsa.nl.map_lo, fftsa.nl.map_hi = keepml, keepmh
      fftsa.nl.sub_trace_ok = keepok
      fftsa.nl._map_age = 0
    end
    -- A CORPSE KEEPS ITS NAME AND ITS POINTER. Unsubscribe clears only the kind, and removing
    -- one of several equivalent subscribers can leave -2 there rather than zero. So liveness is
    -- the kind being exactly 0x407F, and this is the gate that says so: with the kind cleared,
    -- the slot still carries a perfectly good name and a perfectly good chain behind it.
    wire(0, SP4, SGRAPH, SLOT)
    local dead = fftsa.nl.px_from_bufsub()
    local deadslot = fftsa.nl.px_sub_slot()
    check('a slot whose kind has been cleared is refused, name and chain notwithstanding',
          table.getn(dead) == 0 and deadslot == nil and fftsa.nl.sub_why ~= nil,
          string.format('%d candidate(s), slot=%s, why=%s', table.getn(dead),
                        tostring(deadslot), tostring(fftsa.nl.sub_why)))
    -- And -2 is not liveness either, which is the case a "non-zero kind" test would pass.
    -- Written as the unsigned word the firmware actually leaves there: peek32 hands back a hex
    -- string and tonumber makes it 4294967294, never a negative.
    wire(4294967294, SP4, SGRAPH, SLOT)
    local rep = fftsa.nl.px_from_bufsub()
    check('a removed representative holding -2 is refused as well',
          table.getn(rep) == 0, string.format('%d candidate(s), why=%s', table.getn(rep),
                                              tostring(fftsa.nl.sub_why)))
    -- THE CROSS-CHECK BETWEEN THE TWO WORDS. slot+0x40 must point inside the routing array of
    -- the widget named by slot+0x34, and the firmware wrote those two words from different
    -- stores. A slot holding anything else is refused WITHOUT the dereference.
    wire(fftsa.nl.PX_SUB_KIND, SGRAPH + fftsa.nl.PX_ROUTE_HI + 64, SGRAPH, SLOT)
    local out = fftsa.nl.px_from_bufsub()
    check('a routing pointer outside the widget is refused without being followed',
          table.getn(out) == 0 and fftsa.nl.sub_why ~= nil,
          tostring(fftsa.nl.sub_why))
    -- AND THE TRACE HAS TO POINT BACK AT BOTH. Either half failing means the slot and the trace
    -- disagree -- a torn read while the display task removes a trace, or a corpse whose kind has
    -- not been cleared yet -- and a name match is not enough to believe the chain.
    wire(fftsa.nl.PX_SUB_KIND, SP4, SGRAPH + 16, SLOT)
    local bg = fftsa.nl.px_from_bufsub()
    check('a trace that names a different graph is refused',
          table.getn(bg) == 0 and fftsa.nl.sub_why ~= nil, tostring(fftsa.nl.sub_why))
    wire(fftsa.nl.PX_SUB_KIND, SP4, SGRAPH, SLOT + 296)
    local bs2 = fftsa.nl.px_from_bufsub()
    check('a trace that names a different subscription is refused',
          table.getn(bs2) == 0 and fftsa.nl.sub_why ~= nil, tostring(fftsa.nl.sub_why))
    -- THE WINDOW IS READ ONCE. The slot address is kept and re-checked with a single word,
    -- because a 64 KB read every frame would put the route back in the same class of cost as
    -- the thing it replaces.
    wire(fftsa.nl.PX_SUB_KIND, SP4, SGRAPH, SLOT)
    fftsa.nl.px_from_bufsub()
    -- THE INVARIANT IS THAT THE WINDOW IS NOT RE-READ, not that the walk is short. Counting
    -- reads conflated the two and broke when the chain moved from peek32 to memread -- the
    -- same number of IPC round trips through a different primitive. So this watches for a read
    -- of the WINDOW's size, which is the expensive thing being avoided.
    local wins = 0
    local km = ki.memread
    ki.memread = function(a, n)
      if tonumber(n, 16) == fftsa.nl.PX_SUB_BYTES then wins = wins + 1 end
      return km(a, n)
    end
    fftsa.nl.px_from_bufsub()
    ki.memread = km
    check('a second attempt re-checks the slot rather than re-reading the window',
          wins == 0, string.format('%d window-sized read(s) on the second attempt', wins))
    -- AN EMPTY RING IS "NOT FILLED YET", NOT "DEAD", AND THE ROUTE MUST OUTLIVE IT.
    --
    -- px_from_name's last test is `cnt >= 1`. For a heap search that IS the corpse test and it
    -- is right: a freed ring holds zeros. For this route it is wrong, because the slot's kind
    -- is live and the trace points back at both the graph and the slot -- so an empty ring means
    -- the appends have not been through it yet.
    --
    -- Measured on the glass at 9.17: sub=D67CD0/2hit reached the right trace on the first
    -- frames, was refused on the empty ring, and was never offered again because the idle arm
    -- stops running once the state latches to 'seek'. The search then found that same trace's
    -- own +0x220 twenty-six megabytes later. eng=4.7s/23f.
    --
    -- So the gate is not "does it work" -- that is above -- but "is it still asked once the
    -- state has latched", which is what px_seek now does on every frame of the search.
    do
      wire(fftsa.nl.PX_SUB_KIND, SP4, SGRAPH, SLOT)
      -- An empty ring: the count word the header carries, zeroed.
      wr32(TBOUND + fftsa.nl.HDR_COUNT, 0)
      local empty = fftsa.nl.px_from_bufsub()
      check('a slot whose ring is still empty yields nothing, and says so without giving up',
            table.getn(empty) == 0 and fftsa.nl.px_subslot == SLOT,
            string.format('%d candidate(s), slot still %s',
                          table.getn(empty),
                          fftsa.nl.px_subslot and string.format('%X', fftsa.nl.px_subslot)
                          or 'nil'))
      -- And the SEARCH arm asks again. Driven with the state already latched to 'seek', which
      -- is the state the idle arm cannot run in and where the route used to be abandoned.
      tracefix()
      fftsa.nl.px.state = 'seek'
      local gs2 = fftsa.nl.px_seek(HZ, NSEG, 4096, nil)
      local g2, gi2 = nil, nil
      for gi2 = 1, table.getn(gs2 or {}) do
        if gs2[gi2].via_sub == true then g2 = gs2[gi2] end
      end
      check('the search arm asks the subscriber slot again once the ring has filled',
            g2 ~= nil and g2.lo == TRING and fftsa.nl.px.via == 'sub',
            g2 ~= nil and string.format('ring %X via=%s', g2.lo, tostring(fftsa.nl.px.via))
            or string.format('%d candidate(s) from px_seek, why=%s',
                             table.getn(gs2 or {}), tostring(fftsa.nl.sub_why)))
      -- The window budget is per PASS, not per session: a restart rebinds the traces, so reads
      -- spent looking for the old subscription say nothing about the new one. Left cumulative,
      -- it was exhausted by earlier blocks of this very suite.
      fftsa.nl.px_subfinds = fftsa.nl.PX_SUB_FINDS + 1
      fftsa.nl.px_subslot = nil
      local spent = fftsa.nl.px_sub_slot()
      fftsa.nl.px_restart('budget')
      fftsa.nl.px_subslot = nil
      local after = fftsa.nl.px_sub_slot()
      check('a restart gives the window budget back, and keeps nothing stale',
            spent == nil and after == SLOT,
            string.format('spent=%s after a restart=%s', tostring(spent),
                          after and string.format('%X', after) or 'nil'))
    end
    -- A KNOWN SLOT SUPPRESSES THE SWEEP, which is where the time actually went.
    --
    -- Measured at 9.19: swept=10MB/0pass -- the pass that engaged scanned nothing, and the
    -- 10 MB was spent in the frames before the last rebind on an object that was then freed.
    -- The app rebinds its traces while building its screens (re=5, "the drawn window moved
    -- from 368C938+510 to 368C938+59" after "traces rebound"), so a sweep running alongside a
    -- known slot is racing a target that keeps moving and discards everything it finds.
    do
      wire(fftsa.nl.PX_SUB_KIND, SP4, SGRAPH, SLOT)
      wr32(TBOUND + fftsa.nl.HDR_COUNT, 0)       -- the ring not filled yet
      fftsa.nl.px_sub_slot()                     -- so the slot is known
      fftsa.nl.px.state = 'seek'
      fftsa.nl.px.subwait = 0
      local sw0 = fftsa.nl.px.swept or 0
      fftsa.nl.px_try(DB, HZ, NSEG, 'TB', 15001, nil)
      check('a known slot with an unfilled ring waits instead of sweeping',
            (fftsa.nl.px.swept or 0) == sw0 and fftsa.nl.px.state == 'idle'
            and (fftsa.nl.px.subwait or 0) == 1,
            string.format('swept %d -> %d, state=%s, subwait=%s', sw0,
                          fftsa.nl.px.swept or 0, tostring(fftsa.nl.px.state),
                          tostring(fftsa.nl.px.subwait)))
      -- AND THE WAIT IS BOUNDED, or a build whose slot means something else never searches.
      local keepok = fftsa.nl.px_subok
      fftsa.nl.px_subok = nil
      fftsa.nl.px.subwait = fftsa.nl.PX_SUB_WAIT
      fftsa.nl.px.state = 'seek'
      fftsa.nl.px_try(DB, HZ, NSEG, 'TB', 15002, nil)
      check('and the wait is bounded, so the sweep still runs if the ring never fills',
            (fftsa.nl.px.swept or 0) > sw0,
            string.format('swept %d -> %d after %d frames of waiting', sw0,
                          fftsa.nl.px.swept or 0, fftsa.nl.PX_SUB_WAIT))
      -- UNLESS THE CHAIN HAS ALREADY ANSWERED ONCE on this instrument, in which case the
      -- sweep has nothing to add: whatever it finds is the object the slot already names. This
      -- is what makes "no scans once it is in fast mode" hold across a drop, not just while
      -- the path is engaged.
      local sw1 = fftsa.nl.px.swept or 0
      fftsa.nl.px_subok = true
      fftsa.nl.px.subwait = fftsa.nl.PX_SUB_WAIT * 10
      fftsa.nl.px.state = 'seek'
      fftsa.nl.px_try(DB, HZ, NSEG, 'TB', 15003, nil)
      check('a route that has answered once retires the sweep for the session',
            (fftsa.nl.px.swept or 0) == sw1 and fftsa.nl.px.state == 'idle',
            string.format('swept %d -> %d with subwait=%s, state=%s', sw1,
                          fftsa.nl.px.swept or 0, tostring(fftsa.nl.px.subwait),
                          tostring(fftsa.nl.px.state)))
      fftsa.nl.px_subok = keepok
      tracefix()
    end
    -- ---- NO SEARCHING ONCE THE F IS ON THE GLASS ----------------------------
    --
    -- sg_fast_text returns "" unless px.state == 'on' (tsp/spectrum_graph.tsp), so the F is
    -- shown exactly when the path is engaged. px_try's engaged arm returns px_frame at once and
    -- no search code is reachable from it -- this gate is what keeps that true, by counting the
    -- calls rather than by reading the control flow.
    --
    -- Measured on the glass at 9.20: swept=0MB/0pass for the whole launch and rd=0/0KB on the
    -- engaged frame. The 34.8 MB in nf= is the one-off bind-time descriptor discovery, which
    -- runs before any frame and is not the pixel path.
    do
      wire(fftsa.nl.PX_SUB_KIND, SP4, SGRAPH, SLOT)
      tracefix()
      -- Engage through the ordinary route, so this is the real engaged state and not a field
      -- poked into place.
      fftsa.nl.px.state = 'seek'
      local calls, n2 = 0, nil
      while n2 == nil and calls < 40 do
        calls = calls + 1
        n2 = fftsa.nl.px_try(DB, HZ, NSEG, 'TB', 16000 + calls, nil)
      end
      local onstate = fftsa.nl.px.state
      local sw2 = fftsa.nl.px.swept or 0
      -- Now count everything a frame could spend while the F is up.
      local finds, reads, peeks = 0, 0, 0
      local kf, km, kp = fftsa.nl.FINDS, ki.memread, ki.peek32
      fftsa.nl.FINDS = function(a, b, c) finds = finds + 1; return kf(a, b, c) end
      ki.memread = function(a, b) reads = reads + 1; return km(a, b) end
      ki.peek32 = function(a) peeks = peeks + 1; return kp(a) end
      local drew, f2, whys = 0, nil, ''
      for f2 = 1, 12 do
        if fftsa.nl.px_try(DB, HZ, NSEG, 'TB', 17000 + f2, nil) == NSEG then
          drew = drew + 1
        else
          whys = whys .. ' f' .. tostring(f2) .. '=' .. tostring(fftsa.nl.px.whyframe
                 or fftsa.nl.px.why)
        end
      end
      fftsa.nl.FINDS, ki.memread, ki.peek32 = kf, km, kp
      -- WHAT IS ASSERTED IS THE SEARCHING, NOT THE STABILITY. This fixture's ring is static:
      -- nothing advances the firmware's own reference point, so after a few frames the drift
      -- check correctly refuses the map -- "the map is 294.0 px out on the firmware's own
      -- point" -- and the path cycles. That is the fixture, not the product; on the instrument
      -- the display task maintains the ring and the F stays up. Pinning the frame count here
      -- would be pinning the harness's limitation.
      --
      -- What this gate exists for is the guarantee the operator asked for: once the F is on the
      -- glass there is no search work. Zero FINDS and a swept figure that does not move say
      -- that, and they say it whether or not the frames in between drew.
      check('once the F is up, an engaged frame searches nothing and sweeps nothing',
            onstate == 'on' and drew > 0 and finds == 0
            and (fftsa.nl.px.swept or 0) == sw2,
            string.format('state=%s, %d/12 frames drew, %d FINDS, swept %d -> %d, '
                          .. '%d memread %d peek32%s', tostring(onstate), drew, finds, sw2,
                          fftsa.nl.px.swept or 0, reads, peeks, whys))
      -- AND WHAT A DROP COSTS. px_restart sends the path back to idle, holds PX_HOLD frames of
      -- plain appends -- an engaged frame wrote pixel triples rather than values, so the two no
      -- longer describe the same spectrum and nothing can be fitted until a few ordinary passes
      -- have been through -- and then re-walks the slot. With the chain already proven there is
      -- no sweep in any of it.
      local sw3 = fftsa.nl.px.swept or 0
      finds = 0
      fftsa.nl.FINDS = function(a, b, c) finds = finds + 1; return kf(a, b, c) end
      fftsa.nl.px_dropframe('the drawn window moved')
      local held = fftsa.nl.px.hold or 0
      local back, f3 = nil, nil
      for f3 = 1, 20 do
        if back == nil and fftsa.nl.px.state == 'on' then back = f3 end
        fftsa.nl.px_try(DB, HZ, NSEG, 'TB', 18000 + f3, nil)
      end
      fftsa.nl.FINDS = kf
      -- Same scoping: that it came BACK is asserted, not that it stayed, for the reason above.
      check('a drop holds for PX_HOLD frames, then re-engages with no search of any kind',
            held == fftsa.nl.PX_HOLD and back ~= nil and finds == 0
            and (fftsa.nl.px.swept or 0) == sw3,
            string.format('held=%d of %d, back at frame %s, %d FINDS, swept %d -> %d, state=%s',
                          held, fftsa.nl.PX_HOLD, tostring(back), finds, sw3,
                          fftsa.nl.px.swept or 0, tostring(fftsa.nl.px.state)))
    end
    -- ---- A MODEL WHOSE LAYOUT IS NOT THE 6500'S -----------------------------
    --
    -- There is no DMM7510 on the bench and there will not be one before this ships, so the
    -- 7510 arm has to be exercised here or not at all. Its display code IS the same
    -- architecture -- rom/rom7519.zx, header disp7510_r, flattening to RAM 0..0xD03000 with
    -- S$BE at 0x00170F30, S$BA at 0x00171520, PEG Main at 0x0016E398 and defbuffer1 beside
    -- them -- but every address and offset is unknown.
    --
    -- So this builds a table that shares NOTHING with the 6500's: a different place, a
    -- different kind constant, a different name offset, and the trace reached through a
    -- different word of the slot. The route has to find it anyway, because the only thing it
    -- is allowed to rely on is a name this app chose itself.
    do
      local FLO = fftsa.nl.PX_SUB_FROM + 2 * fftsa.nl.PX_SUB_STEP
      local FSLOT = FLO + 4096
      local FNAME = 16                       -- not the 6500's 8
      local FKIND = 25000                    -- not 0x407F
      local FP4 = 96                         -- not 0x40, and no graph word at 0x34
      local function wrstr2(at, str)
        local i
        for i = 0, string.len(str) - 1 do
          local a = at + i
          local w = a - math.mod(a, 4)
          local old4 = IMG[w] or string.rep(string.char(0), 4)
          local k = a - w + 1
          IMG[w] = string.sub(old4, 1, k - 1) .. string.sub(str, i + 1, i + 1)
                   .. string.sub(old4, k + 1)
        end
      end
      local keepd, keepa, keepl = fftsa.nl.PX_SUB_DERIVE, fftsa.nl.PX_SUB_ANYKIND,
                                  fftsa.nl.PX_SUB_LADDER
      fftsa.nl.PX_SUB_DERIVE, fftsa.nl.PX_SUB_ANYKIND = true, true
      fftsa.nl.PX_SUB_LADDER = true
      build(nil)
      tracefix()
      fftsa.nl.px_subslot, fftsa.nl.px_subwin = nil, nil
      fftsa.nl.px_subfinds, fftsa.nl.sub_walkdone = 0, nil
      fftsa.nl.sub_walkat, fftsa.nl.sub_hits, fftsa.nl.sub_first = 0, nil, nil
      wr32(FSLOT, FKIND)
      wrstr2(FSLOT + FNAME, fftsa.nl.PX_NAME .. string.char(0))
      -- One level only on this model: the slot word points straight at the trace.
      wr32(FSLOT + FP4, TLO)
      -- The walk resumes across frames, so give it the frames it needs.
      local gs3, tries = {}, 0
      while table.getn(gs3) == 0 and tries < 60 do
        tries = tries + 1
        fftsa.nl.rd_frame_reset()
        gs3 = fftsa.nl.px_from_bufsub()
      end
      local g3, gi3 = nil, nil
      for gi3 = 1, table.getn(gs3) do
        if gs3[gi3].stride == STRIDE then g3 = gs3[gi3] end
      end
      check('an unknown model: the name is found by ladder and the offsets are derived',
            g3 ~= nil and g3.lo == TRING and fftsa.nl.px_subslot == FSLOT
            and fftsa.nl.sub_nameoff == FNAME and fftsa.nl.sub_derived == true,
            g3 ~= nil and string.format('ring %X, slot %X, nameoff=%s, p4off=%s, %s level(s)',
                                        g3.lo, fftsa.nl.px_subslot or 0,
                                        tostring(fftsa.nl.sub_nameoff),
                                        tostring(fftsa.nl.sub_p4off),
                                        tostring(fftsa.nl.sub_levels))
            or string.format('%d tries, slot=%s, why=%s', tries,
                             tostring(fftsa.nl.px_subslot), tostring(fftsa.nl.sub_why)))
      -- AND ON THE 6500 ARM NONE OF THAT IS ALLOWED TO RUN, because every figure there is
      -- measured and a derivation could only make it slower or less certain.
      fftsa.nl.PX_SUB_DERIVE, fftsa.nl.PX_SUB_ANYKIND = false, false
      fftsa.nl.PX_SUB_LADDER = false
      fftsa.nl.px_subslot, fftsa.nl.px_subwin = nil, nil
      fftsa.nl.px_subfinds, fftsa.nl.sub_derived = 0, nil
      local reads2 = 0
      local km2 = ki.memread
      ki.memread = function(a, b) reads2 = reads2 + 1; return km2(a, b) end
      local none = fftsa.nl.px_from_bufsub()
      local again = fftsa.nl.px_from_bufsub()
      ki.memread = km2
      check('on a 6500 a missing name costs one window read and no ladder',
            table.getn(none) == 0 and table.getn(again) == 0 and reads2 <= 2
            and fftsa.nl.sub_derived == nil,
            string.format('%d memread(s) for two attempts, derived=%s, why=%s', reads2,
                          tostring(fftsa.nl.sub_derived), tostring(fftsa.nl.sub_why)))
      -- THE 6500 MUST NOT BE SLOWED BY ANY OF THIS, which is the operator's requirement and
      -- the reason all three knobs default off: an instrument whose model this module fails to
      -- recognise gets the measured path, not the exploratory one.
      check('the unknown-model machinery is off unless a model asks for it',
            keepd == false and keepa == false and keepl == false,
            string.format('derive=%s anykind=%s ladder=%s', tostring(keepd), tostring(keepa),
                          tostring(keepl)))
      -- AND WHAT A 6500 FRAME PAYS FOR THE ROUTE, counted. Once the slot is known this is a
      -- re-check and a walk: one word for the kind, the graph and the routing pointer, the
      -- element, the two back-pointers, and the name. A regression here is the route turning
      -- into something that has to be rationed per frame, which is the whole thing it replaced.
      fftsa.nl.PX_SUB_DERIVE, fftsa.nl.PX_SUB_ANYKIND = keepd, keepa
      fftsa.nl.PX_SUB_LADDER = keepl
      wire(fftsa.nl.PX_SUB_KIND, SP4, SGRAPH, SLOT)
      fftsa.nl.px_subslot, fftsa.nl.px_subwin, fftsa.nl.px_subfinds = nil, nil, 0
      fftsa.nl.px_from_bufsub()
      local r6, p6 = 0, 0
      local km6, kp6 = ki.memread, ki.peek32
      ki.memread = function(a, b) r6 = r6 + 1; return km6(a, b) end
      ki.peek32 = function(a) p6 = p6 + 1; return kp6(a) end
      local got6 = fftsa.nl.px_from_bufsub()
      ki.memread, ki.peek32 = km6, kp6
      -- THE WINDOW VALUES THEMSELVES, independently of the fixture.
      --
      -- Every gate above places its synthetic slot at whatever PX_SUB_LO happens to be, so a
      -- model selection that was reversed, or dropped, would still pass all of them. These two
      -- assert the measured numbers outright: 0x00D60000 for a DMM6500, whose table is at
      -- 0x00D67708 (1.7.17a) and 0x00D67A48 (1.7.18a); 0x00510000 for a DMM7510, whose table is
      -- at 0x005189C8 with 64 slots of 0x100 -- read out of rom7519's own loader mapping, where
      -- RAM address equals flattened-image offset.
      check('the compiled windows are the measured ones, and each holds its table',
            fftsa.nl.PX_SUB_LO == 14024704 and fftsa.nl.PX_SUB_LO_7510 == 5308416
            and fftsa.nl.PX_SUB_BYTES == 65536
            and 14024704 <= 14055176 and 14055176 < 14024704 + 65536
            and 5308416 <= 5343688 and 5343688 + 64 * 256 < 5308416 + 65536,
            string.format('6500 %X, 7510 %X, %d bytes', fftsa.nl.PX_SUB_LO,
                          fftsa.nl.PX_SUB_LO_7510, fftsa.nl.PX_SUB_BYTES))
      -- A GUARDED READ CAN ANSWER nil, AND A DIAGNOSTIC MAY NOT RAISE ON IT. hx is
      -- string.format('%X', v), so a refused back-pointer read would have thrown inside the
      -- frame instead of reaching the About page with its reason -- in the one path whose whole
      -- job is to explain itself on a model nobody can measure.
      do
        wire(fftsa.nl.PX_SUB_KIND, SP4, SGRAPH, SLOT)
        fftsa.nl.px_subslot, fftsa.nl.px_subwin = nil, nil
        fftsa.nl.px_subfinds = 0
        -- An unreadable trace: the routing element points somewhere _wg refuses.
        wr32(SP4, 2)
        local raised = nil
        local okc, errc = pcall(function() return fftsa.nl.px_from_bufsub() end)
        if not okc then raised = tostring(errc) end
        check('an unreadable pointer in the chain reports a reason instead of raising',
              raised == nil and fftsa.nl.sub_why ~= nil,
              raised or tostring(fftsa.nl.sub_why))
        wr32(SP4, TLO)
      end
      -- ROUND TRIPS, NOT PRIMITIVES. ki.memread and ki.peek32 each cost one trip through the
      -- firmware's read path, and the chain reads through memread now rather than peek32
      -- because memread validates and refuses where peek32 faults. Counting them separately
      -- made this gate fail on a change that moved cost from one column to the other without
      -- adding any.
      check('a 6500 call walks the known slot in a handful of round trips, and no window read',
            table.getn(got6) > 0 and (r6 + p6) <= 20,
            string.format('%d candidate(s), %d round trip(s): %d memread, %d peek32',
                          table.getn(got6), r6 + p6, r6, p6))
      -- AND THE SAME COUNTED OVER A WHOLE px_try FRAME, which is the figure the operator's
      -- requirement is about. The route is called from the idle arm AND from px_seek, so a
      -- frame can walk the chain twice -- a count taken on one call does not prove a per-frame
      -- cost, and it was being quoted as though it did.
      do
        wire(fftsa.nl.PX_SUB_KIND, SP4, SGRAPH, SLOT)
        fftsa.nl.px_subslot, fftsa.nl.px_subwin, fftsa.nl.px_subfinds = nil, nil, 0
        fftsa.nl.px.state = 'seek'
        local c6 = 0
        while fftsa.nl.px.state ~= 'on' and c6 < 40 do
          c6 = c6 + 1
          fftsa.nl.px_try(DB, HZ, NSEG, 'TB', 19000 + c6, nil)
        end
        local onstate6 = fftsa.nl.px.state
        local ra, pa = 0, 0
        local kma, kpa = ki.memread, ki.peek32
        ki.memread = function(a, b) ra = ra + 1; return kma(a, b) end
        ki.peek32 = function(a) pa = pa + 1; return kpa(a) end
        fftsa.nl.px_try(DB, HZ, NSEG, 'TB', 19500, nil)
        local re, pe = ra, pa
        fftsa.nl.px.state = 'seek'
        fftsa.nl.px_try(DB, HZ, NSEG, 'TB', 19600, nil)
        ki.memread, ki.peek32 = kma, kpa
        -- An engaged frame is NOT zero reads and should not be asserted as such: it reads the
        -- ring's own cursors to check the map still describes the window being drawn -- the
        -- drift check, which is what refuses a map that has gone stale rather than drawing a
        -- wrong spectrum. Two reads. What must be zero in fast mode is SEARCHING, which the
        -- gate above counts as FINDS calls and swept bytes.
        check('a 6500 engaged frame costs two round trips, and a searching one a handful',
              onstate6 == 'on' and (re + pe) <= 2
              and ((ra - re) + (pa - pe)) <= 24,
              string.format('engaged %d round trip(s); searching %d',
                            re + pe, (ra - re) + (pa - pe)))
      end
      -- THE DECOY MUST NOT WIN UNDER THE LOOSE KIND TEST. The c2c request record carries the
      -- name with a pointer to the live slot 8 bytes before it, and it sits BELOW the table, so
      -- a forward search finds it first. A plausible non-zero word satisfies the loose test and
      -- a slot address is plausible -- so a single pass would cache the decoy and never reach
      -- the real slot behind it. Exact kind has to be exhausted across every hit first.
      do
        local keepa2 = fftsa.nl.PX_SUB_ANYKIND
        fftsa.nl.PX_SUB_ANYKIND = true
        wire(fftsa.nl.PX_SUB_KIND, SP4, SGRAPH, SLOT)
        fftsa.nl.px_subslot, fftsa.nl.px_subwin, fftsa.nl.px_subfinds = nil, nil, 0
        local pick = fftsa.nl.px_sub_slot()
        check('the loose kind test does not let the decoy win over an exact match',
              pick == SLOT and fftsa.nl.sub_loose ~= true,
              string.format('picked %s, wanted the real slot %X, loose=%s',
                            pick and string.format('%X', pick) or 'nil', SLOT,
                            tostring(fftsa.nl.sub_loose)))
        fftsa.nl.PX_SUB_ANYKIND = keepa2
      end
      -- /chain AND /mapped ARE DIFFERENT CLAIMS, and the labels were on each other's condition.
      -- /chain is the chain closing and handing over geometry; /mapped is px_map accepting that
      -- geometry against the app's own 510 frequencies. Swapped, a launch whose frequencies
      -- never matched reported the route as mapped -- which is the one thing the field exists
      -- to distinguish, on a model where a screenshot is all anyone will ever send back.
      do
        wire(fftsa.nl.PX_SUB_KIND, SP4, SGRAPH, SLOT)
        fftsa.nl.px_subok = nil
        fftsa.nl.px.via, fftsa.nl.px.from = 'sub', nil
        local chained = fftsa.nl.px_str()
        fftsa.nl.px_subok = true
        local mapped = fftsa.nl.px_str()
        local c_has = string.find(chained, '/chain', 1, true) ~= nil
        local c_no = string.find(chained, '/mapped', 1, true) == nil
        local m_has = string.find(mapped, '/mapped', 1, true) ~= nil
        check('a closed chain says /chain, and only an accepted map says /mapped',
              c_has and c_no and m_has,
              string.format('chain=%s, chain-only-is-not-mapped=%s, after-map=%s',
                            tostring(c_has), tostring(c_no), tostring(m_has)))
        fftsa.nl.px_subok = nil
      end
      -- AND THE ROUTE DOES NOT OUTLIVE THE SESSION THAT EARNED IT. px_clear runs on every
      -- restart; leaving via and from set meant the next pass reported via=sub and a closed
      -- chain while its own chain had never been asked.
      do
        fftsa.nl.px.via, fftsa.nl.px.from = 'sub', 'sub'
        fftsa.nl.px_subok = nil
        fftsa.nl.px_restart('the route must not outlive the session')
        local after = fftsa.nl.px_str()
        check('a restart drops the route it engaged through, so no later page claims it',
              fftsa.nl.px.via == nil and fftsa.nl.px.from == nil
              and string.find(after, '/chain', 1, true) == nil,
              string.format('via=%s from=%s, page still claims /chain=%s',
                            tostring(fftsa.nl.px.via), tostring(fftsa.nl.px.from),
                            tostring(string.find(after, '/chain', 1, true) ~= nil)))
      end
      -- A FAILING WINDOW IS ADJUDICATED A CALL AT A TIME. Where the name offset is unknown a
      -- hit costs one read per candidate offset, so twelve hits against twelve offsets is 144
      -- round trips -- three times the whole per-frame allowance, spent without a yield. That
      -- is the same bug class as PX_NAME_FAIL at 512, which measured a relaunch under 3 fps.
      -- The hits are kept as addresses, so what is left resumes without re-reading the window.
      do
        local keepd = fftsa.nl.PX_SUB_DERIVE
        fftsa.nl.PX_SUB_DERIVE = true
        wire(0, SP4, SGRAPH, SLOT)
        fftsa.nl.px_subslot, fftsa.nl.px_subwin, fftsa.nl.px_subfinds = nil, nil, 0
        fftsa.nl.sub_hitlist, fftsa.nl.sub_map, fftsa.nl.sub_mapat = nil, nil, nil
        -- Counting BOTH primitives, because _wg reads through peek32 and the window through
        -- memread: a count of one of them is not a count of round trips, which is the cost.
        local reads, wins = 0, 0
        local km, kp = ki.memread, ki.peek32
        ki.memread = function(a, n)
          reads = reads + 1
          if tonumber(n, 16) == fftsa.nl.PX_SUB_BYTES then wins = wins + 1 end
          return km(a, n)
        end
        ki.peek32 = function(a)
          reads = reads + 1
          return kp(a)
        end
        local first = fftsa.nl.px_sub_slot()
        local pending, reads1 = fftsa.nl.sub_hitlist, reads
        local calls = 1
        while fftsa.nl.sub_hitlist ~= nil and calls < 40 do
          fftsa.nl.px_sub_slot()
          calls = calls + 1
        end
        ki.memread, ki.peek32 = km, kp
        check('a failing window is adjudicated a call at a time, not in one burst',
              first == nil and pending ~= nil and calls > 1
              and reads1 <= fftsa.nl.PX_SUB_JUDGE + 12 and wins == 1,
              string.format('%d read(s) in the first call, %d call(s), %d window read(s)',
                            reads1, calls, wins))
        -- AND THE DUMP DESCRIBES A GENUINE SLOT, NOT THE DECOY. The c2c request record sits
        -- BELOW the table, so a forward search meets it first; dumping the first hit described
        -- the one structure already known, in the field whose job is to show where an
        -- unmeasured model's fields really are.
        check('the neighbourhood dump is taken from the last hit, not the leading decoy',
              fftsa.nl.sub_mapat == SLOT + fftsa.nl.PX_SUB_NAME,
              string.format('dumped around %s, decoy at %X, real slot name at %X',
                            fftsa.nl.sub_mapat
                            and string.format('%X', fftsa.nl.sub_mapat) or 'nil',
                            DECOY + fftsa.nl.PX_SUB_NAME, SLOT + fftsa.nl.PX_SUB_NAME))
        fftsa.nl.PX_SUB_DERIVE = keepd
        fftsa.nl.sub_hitlist, fftsa.nl.sub_map, fftsa.nl.sub_mapat = nil, nil, nil
      end
      -- AND ON A 6500 THE WHOLE COST IS ONE READ A HIT, because the name offset is known: it
      -- was read off bufsub_subscribe and is slot+8 on both builds that have been dumped. The
      -- twelve candidate offsets exist for a model that moved the field, and spending them on a
      -- model that did not is what made a failing window cost twelve reads a hit.
      do
        local keepd2 = fftsa.nl.PX_SUB_DERIVE
        fftsa.nl.PX_SUB_DERIVE = false
        wire(0, SP4, SGRAPH, SLOT)
        fftsa.nl.px_subslot, fftsa.nl.px_subwin, fftsa.nl.px_subfinds = nil, nil, 0
        fftsa.nl.sub_hitlist = nil
        -- The REPEATED cost, with the neighbourhood dump already taken. A launch may re-read
        -- the window PX_SUB_FINDS times and only the first of them pays for the dump, which
        -- scans 65 words looking for ten pointer-like ones.
        fftsa.nl.sub_map = 'already taken'
        local tries = 0
        local kp2 = ki.peek32
        ki.peek32 = function(a)
          tries = tries + 1
          return kp2(a)
        end
        local none = fftsa.nl.px_sub_slot()
        ki.peek32 = kp2
        check('on a 6500 a hit that is not a slot costs one read, not one per offset',
              none == nil and tries <= 2 and fftsa.nl.sub_hitlist == nil,
              string.format('%d read(s) to reject 2 hits, finished in one call=%s',
                            tries, tostring(fftsa.nl.sub_hitlist == nil)))
        fftsa.nl.PX_SUB_DERIVE = keepd2
      end
      fftsa.nl.px_subslot, fftsa.nl.px_subwin = nil, nil
      fftsa.nl.px_subfinds, fftsa.nl.sub_walkdone = 0, nil
    end
    fftsa.nl.px_subslot = nil
    fftsa.nl.px_restart('subscriber done')
  end

  ki.memwrite, buffer.write = nil, nil
  FFTSA_PXRING, fftsa.nl.arena = nil, nil
  fftsa.nl.nfind = SAVED_NF
  fftsa.nl.ready, fftsa.nl.find_addr = SAVED_RDY, SAVED_FA
  fftsa.nl.map_lo, fftsa.nl.map_hi = nil, nil
  fftsa.nl.px_restart('suite done')
  tostring = SAVEDT
end

-- ---- the reduced arrays, and the decibels on demand ------------------------
--
-- nl.reduce used to decode both arrays on every frame. The decibels are 255 values at a float
-- decode each, about 8.5 ms, and an engaged pixel frame reads NONE of them: the image writes
-- the ring from the same array in the arena. So the decode moved behind nl.reduce_db, and
-- what has to be gated is that the skip is safe as well as cheap -- a skipped frame must be
-- unable to present as the last frame it decoded.
do
  local nl = fftsa.nl
  local NSEG = 6
  -- Decimal, because Lua 5.0.2 rejects a hex literal at parse time.
  local DBAT, HZAT = 60000000, 60001024
  local DBV = { -100, -92.5, -85, -40.25, -88, -110 }
  local HZV = { 100, 200, 300, 400, 500, 600 }
  local keep = { rd = ki.memread, db = nl.red_db, hz = nl.red_hz,
                 nm = nl.nseg_max, sz = nl.SIZEOF_REAL, red = nl._red,
                 fails = nl.db_fails }
  local function packed(t)
    local o, i = {}, nil
    for i = 1, NSEG do o[i] = nl._f32_pack(t[i]) end
    return table.concat(o)
  end
  local STORE = { [DBAT] = packed(DBV), [HZAT] = packed(HZV) }
  local READS = {}
  ki.memread = function(ah, lh)
    local a, n = tonumber(ah, 16), tonumber(lh, 16)
    READS[table.getn(READS) + 1] = a
    local base = nil
    if a >= DBAT and a < DBAT + NSEG * 4 then base = DBAT
    elseif a >= HZAT and a < HZAT + NSEG * 4 then base = HZAT end
    if base == nil then return nil end
    return string.sub(STORE[base], a - base + 1, a - base + n)
  end
  local function reads_at(x)
    local c, i = 0, nil
    for i = 1, table.getn(READS) do
      if READS[i] == x then c = c + 1 end
    end
    return c
  end
  local function matches(t, want)
    local i
    if t == nil then return false end
    for i = 1, NSEG do
      if t[i] == nil or math.abs(t[i] - want[i]) > 0.01 then return false end
    end
    return true
  end

  nl.red_db, nl.red_hz = DBAT, HZAT
  nl.nseg_max, nl.SIZEOF_REAL = 32, 4
  nl._red, nl.db_fails = nil, nil

  READS = {}
  local r = nl.reduce(NSEG)
  check('the default reduction still decodes both arrays, as every old caller expects',
        r ~= nil and matches(r.db, DBV) and matches(r.hz, HZV) and reads_at(DBAT) == 1,
        string.format('db=%s hz=%s reads=%d', tostring(r ~= nil and matches(r.db, DBV)),
                      tostring(r ~= nil and matches(r.hz, HZV)), reads_at(DBAT)))

  READS = {}
  local r2 = nl.reduce(NSEG, false)
  check('a skipped reduction never reads the decibels, and leaves none to read',
        r2 ~= nil and reads_at(DBAT) == 0 and r2.db[1] == nil and matches(r2.hz, HZV),
        string.format('reads=%d db[1]=%s hz=%s', reads_at(DBAT),
                      tostring(r2 ~= nil and r2.db[1]),
                      tostring(r2 ~= nil and matches(r2.hz, HZV))))

  READS = {}
  local d = nl.reduce_db()
  local first = reads_at(DBAT)
  local again = nl.reduce_db()
  check('the decibels decode once on demand, and a second ask costs no read',
        matches(d, DBV) and first == 1 and again == d and reads_at(DBAT) == 1,
        string.format('values=%s reads=%d then %d same=%s', tostring(matches(d, DBV)),
                      first, reads_at(DBAT), tostring(again == d)))

  -- THE CASE THAT WOULD BE INVISIBLE. The array is reused frame to frame, so a skip that
  -- left the previous values in it would draw last frame's spectrum for ever -- a frozen
  -- trace with nothing on the glass to report it.
  local MOVED = { -1, -2, -3, -4, -5, -6 }
  STORE[DBAT] = packed(MOVED)
  READS = {}
  local r3 = nl.reduce(NSEG, false)
  check('a skipped reduction cannot present as the last frame it decoded',
        r3 ~= nil and r3.db[1] == nil and reads_at(DBAT) == 0,
        string.format('db[1]=%s reads=%d', tostring(r3 ~= nil and r3.db[1]),
                      reads_at(DBAT)))
  check('and the on-demand decode reads this reduction rather than the cached one',
        matches(nl.reduce_db(), MOVED), 'values moved and were re-read')

  -- A short read refuses the whole array and counts itself, because a half-filled spectrum
  -- is a nil reaching buffer.write.reading, which is a posted event per point.
  STORE[DBAT] = string.sub(packed(DBV), 1, 8)
  local r4 = nl.reduce(NSEG, false)
  local f0 = nl.db_fails or 0
  local d4 = nl.reduce_db()
  check('a short decibel read refuses whole, leaves nothing readable, and is counted',
        d4 == nil and r4 ~= nil and r4.db[1] == nil and (nl.db_fails or 0) == f0 + 1,
        string.format('d=%s db[1]=%s fails=%s -> %s', tostring(d4),
                      tostring(r4 ~= nil and r4.db[1]), tostring(f0),
                      tostring(nl.db_fails)))
  check('and the eager form fails the whole reduction on the same read',
        nl.reduce(NSEG) == nil)

  ki.memread = keep.rd
  nl.red_db, nl.red_hz = keep.db, keep.hz
  nl.nseg_max, nl.SIZEOF_REAL = keep.nm, keep.sz
  nl._red, nl.db_fails = keep.red, keep.fails
end

ki.peek32, ki.memread, tostring = SAVED_PEEK, SAVED_READ, SAVED_TOSTR

print()
print(string.format('%d passed, %d failed', pass, fail))
os.exit(fail == 0 and 0 or 1)
