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
local VEC = 56000000
local function place_desc(base, elem0, elemsize, perchunk, nchunks, cap, n)
  WORDS[base + 72] = elem0
  WORDS[base + 84] = base
  WORDS[base + 100] = base
  WORDS[base + 8] = elemsize
  WORDS[base + 12] = perchunk
  WORDS[base + 16] = nchunks
  WORDS[base + 68] = VEC          -- 0x44, the chunk vector
  WORDS[base + 116] = cap         -- +0x74
  WORDS[base + 120] = n           -- +0x78
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
  for i = 1, table.getn(DESCS) do
    local dd = DESCS[i]
    if pat == sigof(dd.cap, dd.n) then m = m + 1; out[m] = dd.base + 116 end
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
local live = readings(0.125, 0.1875)
place_record(TRUE_E0, 24, live)
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
  ki.memread = function(ah, lh)
    local a, n = tonumber(ah, 16), tonumber(lh, 16)
    if a == nil or n == nil or n <= 0 then return nil end
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

  local h = fftsa.nl.find_ring_header(g)
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

ki.peek32, ki.memread, tostring = SAVED_PEEK, SAVED_READ, SAVED_TOSTR

print()
print(string.format('%d passed, %d failed', pass, fail))
os.exit(fail == 0 and 0 or 1)
