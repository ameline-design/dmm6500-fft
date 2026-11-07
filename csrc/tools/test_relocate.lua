-- test_relocate.lua -- offline check of the relocation applier under Lua 5.0.2.
--
-- The applier runs on the instrument and a wrong patch reads the wrong address
-- silently, so it is verified here against hand-computed answers first.
--
--   ~/tmp/lua502/lua-5.0.2/bin/lua csrc/tools/test_relocate.lua

fftsa = { nl = {} }

-- The function under test, copied from tsp/native_link.tsp. Kept identical so this
-- file tests what ships; a divergence here is a divergence in the thing being proved.
local function u32_at(s, p)
  local b1 = string.byte(s, p)
  local b2 = string.byte(s, p + 1)
  local b3 = string.byte(s, p + 2)
  local b4 = string.byte(s, p + 3)
  return ((b1 * 256 + b2) * 256 + b3) * 256 + b4
end

function fftsa.nl.relocate(image, reloc, code_base, bss_hi)
  local out  = {}
  local n    = 0
  local pos  = 1
  local ilen = string.len(image)
  local rlen = string.len(reloc)
  local r    = 1
  while r + 8 <= rlen + 1 do
    local kind   = string.byte(reloc, r)
    local field  = u32_at(reloc, r + 1)
    local target = u32_at(reloc, r + 5)
    local final  = math.mod(code_base + target, 4294967296)
    local repl, width
    if kind == 1 then
      local b4 = math.mod(final, 256)
      local v3 = math.floor(final / 256)
      local b3 = math.mod(v3, 256)
      local v2 = math.floor(v3 / 256)
      local b2 = math.mod(v2, 256)
      local b1 = math.mod(math.floor(v2 / 256), 256)
      repl  = string.char(b1, b2, b3, b4)
      width = 4
    else
      local half
      if kind == 2 then
        half = math.mod(final, 65536)
      else
        half = math.mod(math.floor((final + 32768) / 65536), 65536)
      end
      repl  = string.char(math.floor(half / 256), math.mod(half, 256))
      width = 2
    end
    if field < 0 or field + width > ilen then return nil, 'field out of range' end
    if field + 1 < pos then return nil, 'relocations overlap or are unsorted' end
    n = n + 1; out[n] = string.sub(image, pos, field)
    n = n + 1; out[n] = repl
    pos = field + width + 1
    r = r + 9
  end
  if r ~= rlen + 1 then return nil, 'relocation table is not a whole number of entries' end
  n = n + 1; out[n] = string.sub(image, pos)
  local patched = table.concat(out)
  if bss_hi ~= nil and bss_hi > string.len(patched) then
    local pad = bss_hi - string.len(patched)
    local z = {}
    local i
    for i = 1, pad do z[i] = '\000' end
    patched = patched .. table.concat(z)
  end
  return patched
end

-- ---------------------------------------------------------------------------

local fails = 0
local function check(name, got, want)
  if got ~= want then
    fails = fails + 1
    print(string.format('FAIL %s: got %s want %s',
                        name, tostring(got), tostring(want)))
  else
    print('ok   ' .. name)
  end
end

local function hex(s)
  local t = {}
  local i
  for i = 1, string.len(s) do
    t[i] = string.format('%02X', string.byte(s, i))
  end
  return table.concat(t)
end

-- Hex of n bytes at 0-based byte offset off. A hand-computed expectation is as able to be
-- wrong as the code it checks, so the offsets here are the ones the ABI documents.
local function at(s, off, n)
  return hex(string.sub(s, off + 1, off + n))
end

local function pack_entry(kind, field, target)
  local function u32(v)
    local b4 = math.mod(v, 256); v = math.floor(v / 256)
    local b3 = math.mod(v, 256); v = math.floor(v / 256)
    local b2 = math.mod(v, 256)
    local b1 = math.mod(math.floor(v / 256), 256)
    return string.char(b1, b2, b3, b4)
  end
  return string.char(kind) .. u32(field) .. u32(target)
end

-- Case 1: a word32 relocation. target 0x00001234 at load base 0x03500000
-- becomes 0x03501234.
do
  local image = string.rep('\000', 16)
  local reloc = pack_entry(1, 4, 4660)              -- 0x1234
  local out = fftsa.nl.relocate(image, reloc, 55574528)  -- 0x03500000
  check('word32 patch', at(out, 4, 4), '03501234')
  check('word32 length', string.len(out), 16)
end

-- Case 2: half-lo and half-ha for a positive low half.
-- final = 0x03501234: ha = 0x0350, lo = 0x1234. No carry.
do
  local image = string.rep('\000', 16)
  local reloc = pack_entry(3, 0, 4660) .. pack_entry(2, 4, 4660)
  local out = fftsa.nl.relocate(image, reloc, 55574528)
  check('half-ha no carry', at(out, 0, 2), '0350')
  check('half-lo no carry', at(out, 4, 2), '1234')
end

-- Case 3: the carry case, which is the whole reason HA exists.
-- final = 0x0350FFFF. The low half loads as the sign-extended -1, so the high half
-- must be 0x0351 for lis+addi to reach 0x0350FFFF. ha = (final + 0x8000) >> 16.
do
  local image = string.rep('\000', 8)
  local reloc = pack_entry(3, 0, 65535) .. pack_entry(2, 4, 65535)
  local out = fftsa.nl.relocate(image, reloc, 55574528)
  check('half-ha with carry', at(out, 0, 2), '0351')
  check('half-lo with carry', at(out, 4, 2), 'FFFF')
end

-- Case 4: exactly on the boundary, low half = 0x8000, the first value that carries.
do
  local image = string.rep('\000', 4)
  local reloc = pack_entry(3, 0, 32768)
  local out = fftsa.nl.relocate(image, reloc, 0)
  check('half-ha boundary 0x8000', at(out, 0, 2), '0001')
end
do
  local image = string.rep('\000', 4)
  local reloc = pack_entry(3, 0, 32767)
  local out = fftsa.nl.relocate(image, reloc, 0)
  check('half-ha boundary 0x7FFF', at(out, 0, 2), '0000')
end

-- Case 5: surrounding bytes are preserved exactly.
do
  local image = '\170\187\000\000\204\221'
  local reloc = pack_entry(2, 2, 0)
  local out = fftsa.nl.relocate(image, reloc, 4660)
  check('neighbours preserved', hex(out), 'AABB1234CCDD')
end

-- Case 6: .bss padding past the end of the image.
do
  local image = '\001\002\003\004'
  local out = fftsa.nl.relocate(image, '', 0, 8)
  check('bss padded', hex(out), '0102030400000000')
end

-- Case 7: refusals. A field past the end, and a truncated table.
do
  local r1 = fftsa.nl.relocate('\000\000', pack_entry(1, 0, 0), 0)
  check('refuses field past end', r1, nil)
  local r2 = fftsa.nl.relocate(string.rep('\000', 16), '\001\000\000', 0)
  check('refuses truncated table', r2, nil)
end

-- Case 8: idempotence. Patching a patched image for the same base is a no-op, which is
-- what lets the image be re-patched for a new load address.
do
  local image = string.rep('\000', 16)
  local reloc = pack_entry(1, 4, 4660)
  local once  = fftsa.nl.relocate(image, reloc, 55574528)
  local twice = fftsa.nl.relocate(once, reloc, 55574528)
  check('idempotent', hex(twice), hex(once))
end

-- Case 9: a realistic count, to show the cost is linear and the result stable.
do
  local parts = {}
  local i
  for i = 1, 355 do parts[i] = string.char(0, 0, 0, 0) end
  local image = table.concat(parts)
  local rp = {}
  for i = 1, 355 do rp[i] = pack_entry(2, (i - 1) * 4, i) end
  local out = fftsa.nl.relocate(image, table.concat(rp), 0)
  check('355 relocations, length preserved', string.len(out), string.len(image))
  check('355 relocations, last value', at(out, 354 * 4, 2), '0163')
end

print('')
if fails == 0 then
  print('all relocation applier checks passed')
else
  print(string.format('%d check(s) failed', fails))
  os.exit(1)
end
