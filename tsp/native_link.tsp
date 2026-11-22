-- Load, relocate and call the PowerPC DSP image. Resolve callable firmware addresses at runtime;
-- validate model-specific layouts and scan bounds before using them.

fftsa = fftsa or {}
fftsa.nl = {
  ready     = false,  -- true once the binary is loaded, relocated and the plan is built
  fn        = {},
  tramp     = 0,
  entry     = 0,      -- heap address of dsp_native_run, which is image offset 0
  code_base = 0,
  params    = 0,
  code_buf  = nil,    -- buffer whose chunk storage holds the image, trampoline, params
  plan_buf  = nil,    -- buffer whose chunk storage holds the plan, arena and scratch
  peek8_cls = 0,
  peek8_f   = 0,      -- original ki.peek8 f pointer, for restore
  nmax      = 0,
  last_rc   = nil,
}

-- Native status: nonnegative counts are results; negative values are refusals.
fftsa.nl.RC = {
  EMAGIC = -1, EBOUNDS = -2, EPLAN = -3, EGEOM = -4, ECAPTURE = -5,
  EOUTPUT = -6, EDESC = -7, EARENA = -8, ERUN = -10, EMATH = -11,
  EREDUCE = -12, ERESULT = -13, EFIND = -14,
}

-- MODE_INIT adds PLAN_BASE to DSP errors to keep them distinct from wrapper errors.
fftsa.nl.PLAN_BASE = -100
fftsa.nl.PLAN_RC = {
  EARG = -1, EPOW2 = -2, ENOMEM = -3, EUNSUPPORTED = -4, ESHORT = -5,
  EBETA = -6, EDECLINE = -7, EALIGN = -8, EZONE = -9, EDIRTY = -10,
  ESEG = -11,
}

-- Report both the status name and the native source line that returned it.
function fftsa.nl.rc_name(rc)
  if type(rc) ~= 'number' then return tostring(rc) end
  local at = ''
  if rc ~= 0 and type(fftsa.nl.fail_at) == 'number' and fftsa.nl.fail_at ~= 0 then
    at = '@' .. tostring(fftsa.nl.fail_at)
  end
  local k, v
  if rc <= fftsa.nl.PLAN_BASE then
    for k, v in pairs(fftsa.nl.PLAN_RC) do
      if v == rc - fftsa.nl.PLAN_BASE then
        return tostring(rc) .. ' plan ' .. k .. at
      end
    end
    return tostring(rc) .. ' plan?' .. at
  end
  for k, v in pairs(fftsa.nl.RC) do
    if v == rc then return tostring(rc) .. ' ' .. k .. at end
  end
  return tostring(rc) .. at
end

-- Ignore harmonics of both 50 and 60 Hz when selecting the fundamental.
fftsa.nl.MAINS_BOTH = -1

fftsa.nl.MODE_INIT  = 1
fftsa.nl.MODE_RUN   = 2
fftsa.nl.MODE_SEGS  = 4
-- Byte-pattern search, confined to the validated span supplied by Lua.
fftsa.nl.MODE_FIND  = 5
-- Write graph Y pixels directly from the native reduction array.
fftsa.nl.MODE_PX    = 6

fftsa.nl.MAGIC = 1146310705   -- 0x44535031, 'DSP1'

fftsa.nl.FFT_FOURSTEP = 1

-- Reading-buffer storage is allocated in fixed 32 KiB payloads.
fftsa.nl.CHUNK_BYTES = 32768

-- Chunk bases can be only 16-byte aligned. Round to 32 and reserve one alignment unit
-- so MODE_SEGS and MODE_INIT agree on usable bytes.
fftsa.nl.SEG_BYTES = 32768 - 32

local function align32(v) return v + math.mod(32 - math.mod(v, 32), 32) end
fftsa.nl.PARAM_WORDS = 55

-- The embedded module supplies the target ABI sizes; zero defaults refuse use without it.
fftsa.nl.SIZEOF_PLAN   = 0
fftsa.nl.SIZEOF_PARAMS = 0
fftsa.nl.SIZEOF_REAL   = 0

-- The embedded image supplies the compiled DRAM bounds.
fftsa.nl.BACKSTOP_LO = 0
fftsa.nl.BACKSTOP_HI = 0

fftsa.nl.RES_PEAKS   = 0
fftsa.nl.RES_DOUBLES = 0

fftsa.nl.PX_WORDS  = 0
fftsa.nl.PX_MAXREC = 0
fftsa.nl.PX_HDR    = 0

-- Picker index to DSP_WINDOW_*; independent of the firmware DSP enum.
fftsa.nl.WIN = {}
fftsa.nl.WIN[1] = 1    -- DSP_WINDOW_HANN
fftsa.nl.WIN[2] = 2    -- DSP_WINDOW_BLACKMAN
fftsa.nl.WIN[3] = 3    -- DSP_WINDOW_BLACKMAN_HARRIS
fftsa.nl.WIN[4] = 4    -- DSP_WINDOW_KAISER

function fftsa.nl.win_to_native(wi)
  local k = fftsa.nl.WIN[wi]
  if k == nil then k = fftsa.nl.WIN[1] end
  return k
end

fftsa.nl.fw_seen = nil

-- Cache-flush code from csrc/flush_tramp.S. TRAMP_RANGE holds the address and byte count;
-- do not edit the assembled literal by hand.
fftsa.nl._TRAMP = '\072\000\000\012\000\000\000\000\000\000\000\000\125\104\002\166\072\000\000\005\125\040\002\166\128\105\255\240\128\137\255\244\125\104\003\166\040\004\000\000\065\130\000\068\124\163\034\020\056\165\000\031\084\165\000\052\084\099\000\052\124\102\027\120\124\000\024\108\056\099\000\032\124\003\040\064\065\128\255\244\124\000\004\172\124\000\055\172\056\198\000\032\124\006\040\064\065\128\255\244\124\000\004\172\076\000\001\044\056\096\000\000\078\128\000\032'
fftsa.nl.TRAMP_RANGE = 4

-- An unchanged status means the call did not report a result.
fftsa.nl.STATUS_UNSET = 2147483647

-- The generated module replaces these placeholders before native startup.
fftsa.nl._DSP_CODE = nil
fftsa.nl._DSP_RELOC = nil
fftsa.nl._DSP_CODE_B64 = nil
fftsa.nl._DSP_CODE_B64_LEN = 0
fftsa.nl._DSP_RELOC_B64 = nil
fftsa.nl._DSP_RELOC_B64_LEN = 0
fftsa.nl._DSP_RELOC_BSS_HI = 0

-- Both base64 blobs omit padding; explicit byte lengths trim the decoded tail.
local B64A = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
local b64map = nil

-- Lua 5.0.2 returns only one byte per string.byte call; decode with a gsub callback.
local function b64decode(s, len)
  if s == nil or len == nil then return nil end
  local slen = string.len(s)
  if math.mod(slen, 4) ~= 0 then return nil end
  -- Validate first: gsub can leave the original text in place if a callback returns nil.
  if string.find(s, '[^A-Za-z0-9+/]') ~= nil then return nil end
  if b64map == nil then
    b64map = {}
    local i
    for i = 1, 64 do b64map[string.sub(B64A, i, i)] = i - 1 end
  end
  local v = b64map
  local out = string.gsub(s, '(.)(.)(.)(.)', function(c1, c2, c3, c4)
    local a, b, c, d = v[c1], v[c2], v[c3], v[c4]
    return string.char(a * 4 + math.floor(b / 16),
                       math.mod(b, 16) * 16 + math.floor(c / 4),
                       math.mod(c, 4) * 64 + d)
  end)
  if string.len(out) < len then return nil end
  return string.sub(out, 1, len)
end
fftsa.nl._b64decode = b64decode

-- Normalize negative words to unsigned 32-bit before packing.
local function u32_pack(v)
  v = math.mod(v, 4294967296)
  if v < 0 then v = v + 4294967296 end
  local b4 = math.mod(v, 256); v = math.floor(v / 256)
  local b3 = math.mod(v, 256); v = math.floor(v / 256)
  local b2 = math.mod(v, 256)
  local b1 = math.mod(math.floor(v / 256), 256)
  return string.char(b1, b2, b3, b4)
end

local function u32_at(s, p)
  local b1 = string.byte(s, p)
  local b2 = string.byte(s, p + 1)
  local b3 = string.byte(s, p + 2)
  local b4 = string.byte(s, p + 3)
  return ((b1 * 256 + b2) * 256 + b3) * 256 + b4
end

local function hx(v) return string.format('%X', v) end
local function hxn(v)
  if type(v) ~= 'number' then return tostring(v) end
  return string.format('%X', v)
end

-- Pack binary64 as two big-endian words. Subnormals flush to zero.
local function f64_words(x)
  local sign = 0
  if x < 0 then sign = 2147483648; x = -x end
  if x ~= x then return sign + 2146959360, 0 end        -- 0x7FF80000, quiet NaN
  if x == 0 then return sign, 0 end
  if x + x == x then return sign + 2146435072, 0 end    -- 0x7FF00000
  local m, e = math.frexp(x)              -- 0.5 <= m < 1 and x = m * 2^e
  local eb = e + 1022                     -- biased exponent of the 1.f form, which is 2m
  if eb >= 2047 then return sign + 2146435072, 0 end
  if eb <= 0 then return sign, 0 end
  local f  = m * 2 - 1                    -- the 52-bit significand, 0 <= f < 1
  local hi = math.floor(f * 1048576)      -- its top 20 bits
  return sign + eb * 1048576 + hi, math.floor((f * 1048576 - hi) * 4294967296)
end
fftsa.nl._f64_words = f64_words

-- Firmware C function pointers must lie inside .text.
fftsa.nl.TEXT_LO = 16384      -- 0x00004000
fftsa.nl.TEXT_HI = 5402624    -- 0x00527000

function fftsa.nl._text_ok(a)
  return type(a) == 'number' and a >= fftsa.nl.TEXT_LO and a < fftsa.nl.TEXT_HI
end

local function align8(v) return v + math.mod(8 - math.mod(v, 8), 8) end

-- Round up to keep allocations on separate cache lines.
local function align32(v) return v + math.mod(32 - math.mod(v, 32), 32) end

-- Cache operations touch every 32-byte line that intersects the range.
local function line_lo(a) return a - math.mod(a, 32) end
local function line_hi(a, n) return line_lo(a + n - 1) + 32 end

-- Progress breadcrumbs for nl.init when tracing is enabled.
local function trace(tag, a, b)
  if not fftsa.nl.trace then return end
  local s = 'NLT|' .. tostring(tag)
  if a ~= nil then s = s .. '|' .. tostring(a) end
  if b ~= nil then s = s .. '|' .. tostring(b) end
  print(s)
end

-- Read only addresses whose DRAM provenance the caller already established.
local function W(addr)
  return tonumber(ki.peek32(hx(addr)), 16)
end

local function f64_pack(x)
  local hi, lo = f64_words(x)
  return u32_pack(hi) .. u32_pack(lo)
end

-- Check both words using mapped reads; a matching exponent alone proves nothing.
local function eq64(addr, v)
  local hi, lo = f64_words(v)
  local g = fftsa.nl._wg
  return g(addr) == hi and g(addr + 4) == lo
end

-- Decode a big-endian binary64 without depending on host byte order.
local function f64_unpack(s, p)
  local b1 = string.byte(s, p)
  local b2 = string.byte(s, p + 1)
  local sign = 1
  if b1 >= 128 then sign = -1; b1 = b1 - 128 end
  local eb = b1 * 16 + math.floor(b2 / 16)
  local m = ((math.mod(b2, 16) * 256 + string.byte(s, p + 2)) * 256
             + string.byte(s, p + 3)) * 4294967296 + u32_at(s, p + 4)
  if eb == 2047 then return nil end
  if eb == 0 then return sign * math.ldexp(m, -1074) end
  return sign * math.ldexp(m + 4503599627370496, eb - 1075)
end
fftsa.nl._f64_unpack = f64_unpack

local function f32_unpack(s, p)
  local b1 = string.byte(s, p)
  local b2 = string.byte(s, p + 1)
  local sign = 1
  if b1 >= 128 then sign = -1; b1 = b1 - 128 end
  local eb = b1 * 2 + math.floor(b2 / 128)
  local m = (math.mod(b2, 128) * 256 + string.byte(s, p + 2)) * 256
            + string.byte(s, p + 3)
  if eb == 255 then return nil end
  if eb == 0 then return sign * math.ldexp(m, -149) end
  return sign * math.ldexp(m + 8388608, eb - 150)
end
fftsa.nl._f32_unpack = f32_unpack

-- Encode float32 with nearest-even rounding so scan needles match stored values.
local function f32_pack(x)
  local sign = 0
  if x < 0 then sign = 128; x = -x end
  if x ~= x then return string.char(sign + 127, 192, 0, 0) end
  if x == 0 then return string.char(sign, 0, 0, 0) end
  if x + x == x then return string.char(sign + 127, 128, 0, 0) end
  local m, e = math.frexp(x)              -- 0.5 <= m < 1 and x = m * 2^e
  local eb, f = e + 126, nil              -- 2m is the 1.f form, so its exponent is e - 1
  if eb <= 0 then
    -- Subnormals have no implicit leading bit; encode them in units of 2^-149.
    eb, f = 0, math.ldexp(x, 149)
  else
    f = (m * 2 - 1) * 8388608
  end
  local fi = math.floor(f)
  local r = f - fi
  if r > 0.5 then fi = fi + 1
  elseif r == 0.5 and math.mod(fi, 2) == 1 then fi = fi + 1 end
  if fi >= 8388608 then fi = fi - 8388608; eb = eb + 1 end
  if eb >= 255 then return string.char(sign + 127, 128, 0, 0) end
  return string.char(sign + math.floor(eb / 2),
                     math.mod(eb, 2) * 128 + math.floor(fi / 65536),
                     math.mod(math.floor(fi / 256), 256),
                     math.mod(fi, 256))
end
fftsa.nl._f32_pack = f32_pack

-- Resolve libm through Lua math wrappers: remove shared helper calls and require one distinct
-- target per wrapper. Capture every target before installing any math pointer.

-- Bound the wrapper scan and stop at its return instruction.
fftsa.nl.SCAN_WORDS = 256

function fftsa.nl.FNT(fn)
  local s = tostring(fn)
  local _, e = string.find(s, ': ')
  if not e then return nil end
  local c = tonumber(string.sub(s, e + 1), 16)
  if not c then return nil end
  local w = W(c + 12)
  if not w then return nil end
  local nw = fftsa.nl.SCAN_WORDS
  local body = ki.memread(hx(w), hx(nw * 4))
  if body == nil or string.len(body) < nw * 4 then return nil end
  local out, i = {}, nil
  for i = 0, nw - 1 do
    local n = u32_at(body, i * 4 + 1)
    -- Accept relative bl only; the absolute branch encoding does not use a PC-relative offset.
    if math.floor(n / 67108864) == 18 and math.mod(n, 4) == 1 then
      local r = math.mod(math.floor(n / 4), 16777216)
      if r >= 8388608 then r = r - 16777216 end
      table.insert(out, math.mod(w + i * 4 + r * 4, 4294967296))
    end
    if n == 1317011488 then break end   -- blr: the wrapper's one exit
  end
  return out
end

fftsa.nl.MATH_NAMES  = { 'sin', 'cos', 'sqrt', 'log10', 'floor', 'ceil' }
fftsa.nl.MATH_GLUE   = { 'abs', 'deg', 'rad' }
fftsa.nl.MATH_CENSUS = { 'sin', 'cos', 'sqrt', 'log10', 'floor', 'ceil',
                         'tan', 'log', 'exp', 'asin', 'acos', 'atan' }

-- Require a minimum shared-helper census before trusting a unique target.
fftsa.nl.GLUE_MIN = 6

function fftsa.nl.resolve_math()
  local nl = fftsa.nl
  local fn = nl.fn
  local v = nil
  if localnode ~= nil then v = localnode.version end
  nl.fw_seen = tostring(v)

  local i, k = nil, nil
  for i = 1, table.getn(nl.MATH_NAMES) do fn[nl.MATH_NAMES[i]] = nil end
  nl.math_pos, nl.math_odd = {}, nil

  local glue, nglue = {}, 0
  for i = 1, table.getn(nl.MATH_GLUE) do
    local f = math[nl.MATH_GLUE[i]]
    if f ~= nil then
      local ts = nl.FNT(f)
      if ts ~= nil then
        for k = 1, table.getn(ts) do
          if not glue[ts[k]] then
            glue[ts[k]] = true
            nglue = nglue + 1
          end
        end
      end
    end
  end
  nl.nglue = nglue
  if nglue < nl.GLUE_MIN then return 0 end

  -- Gather targets from all wrappers to distinguish common glue from individual math bodies.
  local tg, out = {}, {}
  for i = 1, table.getn(nl.MATH_CENSUS) do
    local nm = nl.MATH_CENSUS[i]
    if math[nm] ~= nil then
      local ts = nl.FNT(math[nm])
      if ts ~= nil then
        local have, left, pos = {}, {}, {}
        for k = 1, table.getn(ts) do
          have[ts[k]] = true
          if not glue[ts[k]] and not pos[ts[k]] then
            pos[ts[k]] = k
            table.insert(left, ts[k])
          end
        end
        local whole, g = true, nil
        for g in pairs(glue) do
          if not have[g] then whole = false end
        end
        if whole and table.getn(left) > 0 then
          tg[nm] = ts
          out[nm] = left
          nl.math_pos[nm] = pos[left[1]]
        end
      end
    end
  end

  -- Resolve a function only when precisely one target remains after excluding glue.
  local found = 0
  for i = 1, table.getn(nl.MATH_NAMES) do
    local nm = nl.MATH_NAMES[i]
    local left = out[nm]
    if left ~= nil and table.getn(left) == 1 and nl._text_ok(left[1]) then
      fn[nm] = left[1]
      found = found + 1
      if nl.math_pos[nm] ~= table.getn(tg[nm]) - 1 then nl.math_odd = true end
    end
  end

  -- One firmware address cannot implement two different requested operations.
  local seen = {}
  for i = 1, table.getn(nl.MATH_NAMES) do
    local a = fn[nl.MATH_NAMES[i]]
    if a ~= nil then seen[a] = (seen[a] or 0) + 1 end
  end
  for i = 1, table.getn(nl.MATH_NAMES) do
    local nm = nl.MATH_NAMES[i]
    local a = fn[nm]
    if a ~= nil and seen[a] > 1 then
      fn[nm] = nil
      found = found - 1
    end
  end
  return found
end

function fftsa.nl.fw_probe(words)
  local fn = fftsa.nl.fn
  local names = fftsa.nl.MATH_NAMES
  local n = words or 4
  local out, i, j = '', nil, nil
  for i = 1, table.getn(names) do
    local a = fn[names[i]]
    out = out .. names[i] .. ' '
    if a == nil then
      out = out .. 'unresolved'
    else
      out = out .. string.format('%X:', a)
      for j = 0, n - 1 do
        local w = W(a + j * 4)
        if w == nil then out = out .. '????????'
        else out = out .. string.format('%08X', w) end
      end
    end
    out = out .. ' '
  end
  return tostring(fftsa.nl.fw_seen) .. ' ' .. out
end

-- Relocate big-endian absolute words and halfwords. PC-relative branches need no fixup;
-- zero the BSS, which has no bytes in the image file.
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
      repl  = u32_pack(final)
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
  if r ~= rlen + 1 then return nil, 'relocation table is not whole entries' end
  n = n + 1; out[n] = string.sub(image, pos)
  local patched = table.concat(out)
  if bss_hi ~= nil and bss_hi > string.len(patched) then
    local z = {}
    local i
    for i = 1, bss_hi - string.len(patched) do z[i] = '\000' end
    patched = patched .. table.concat(z)
  end
  return patched
end

-- Heap search windows use nearby live Lua objects as anchors and stay inside DRAM bounds.
fftsa.nl.ANCHOR_NEAR = 25165824         -- 24 MB either side
fftsa.nl.ANCHOR_FAR  = 134217728        -- 128 MB either side
fftsa.nl.DRAM_END = 268435456

-- Parse the address printed for a collectable firmware Lua value.
function fftsa.nl.obj_addr(o)
  local t = tostring(o)
  if type(t) ~= 'string' then return nil end
  local h = string.gsub(t, '^.*:%s*', '')
  h = string.gsub(h, '^0[xX]', '')
  local a = tonumber(h, 16)
  if a == nil or a <= 0 then return nil end
  return a
end

function fftsa.nl.heap_anchor()
  return fftsa.nl.obj_addr({})
end

-- Check alignment and DRAM bounds before a direct word read; this does not prove mapping.
function fftsa.nl._wg(addr)
  if type(addr) ~= 'number' then return nil end
  if addr <= 0 or math.mod(addr, 4) ~= 0 then return nil end
  local lo, hi = fftsa.nl.BACKSTOP_LO, fftsa.nl.BACKSTOP_HI
  if lo == nil or hi == nil or lo >= hi then lo, hi = 0, fftsa.nl.DRAM_END end
  if addr < lo or addr + 4 > hi then return nil end
  fftsa.nl.rd_note(4)
  return tonumber(ki.peek32(hx(addr)), 16)
end

-- Follow buffer.CClassRef to its native instance. Use a mapped read for pointers
-- obtained from firmware structures rather than treating a range check as proof of mapping.
function fftsa.nl._rdw(addr)
  local nl = fftsa.nl
  if type(addr) ~= 'number' or addr <= 0 or math.mod(addr, 4) ~= 0 then return nil end
  local lo, hi = nl.BACKSTOP_LO, nl.BACKSTOP_HI
  if lo == nil or hi == nil or lo >= hi then lo, hi = 0, nl.DRAM_END end
  if addr < lo or addr + 4 > hi then return nil end
  local s = nil
  local ok = pcall(function() s = ki.memread(hx(addr), '4') end)
  nl.rd_note(4)
  if not ok or type(s) ~= 'string' or string.len(s) < 4 then return nil end
  return ((string.byte(s, 1) * 256 + string.byte(s, 2)) * 256
          + string.byte(s, 3)) * 256 + string.byte(s, 4)
end

function fftsa.nl.cclass(buf)
  if type(buf) ~= 'table' and type(buf) ~= 'userdata' then return nil end
  local mt = getmetatable(buf)
  if type(mt) ~= 'table' then return nil end
  local ref = mt.CClassRef
  if ref == nil then return nil end
  local p = fftsa.nl.obj_addr(ref)
  if p == nil then return nil end
  return fftsa.nl._wg(p)
end

-- The instance header lists column pointers in a terminated array of 16-byte entries.
fftsa.nl.INST_CHAIN = 16
fftsa.nl.CHAIN_MAX = 8

function fftsa.nl.col_ptrs(inst)
  local out, n = {}, 0
  if inst == nil then return out end
  local k
  for k = 0, fftsa.nl.CHAIN_MAX - 1 do
    local rec = inst + fftsa.nl.INST_CHAIN + k * 16
    local id = fftsa.nl._wg(rec + 4)
    if id == nil or id == 0 then return out end
    local i
    for i = 8, 12, 4 do
      local p = fftsa.nl._wg(rec + i)
      if p ~= nil and p > 0 then n = n + 1; out[n] = p end
    end
  end
  return out
end

function fftsa.nl.sweep_windows()
  local nl = fftsa.nl
  local lo, hi = nl.BACKSTOP_LO, nl.BACKSTOP_HI
  if lo == nil or hi == nil or lo >= hi then lo, hi = 0, nl.DRAM_END end
  local a = nl.heap_anchor()
  local out = {}
  local n = 0
  if a ~= nil and a > lo and a < hi then
    local clamp = function(x, y)
      if x < lo then x = lo end
      if y > hi then y = hi end
      if x >= y then return nil end
      return { x, y }
    end
    local w1 = clamp(a - nl.ANCHOR_NEAR, a + nl.ANCHOR_NEAR)
    local w2 = clamp(a - nl.ANCHOR_FAR, a + nl.ANCHOR_FAR)
    if w1 ~= nil then n = n + 1 out[n] = w1 end
    if w2 ~= nil then n = n + 1 out[n] = w2 end
  end
  if n == 0 then out[1] = { lo, hi } end
  nl.last_windows = out
  return out
end

-- Search near the buffer instance, columns and known storage before widening to heap bounds.
fftsa.nl.TIGHT = 262144  -- 256 KiB either side
fftsa.nl.MID   = 4194304                -- 4 MB either side

function fftsa.nl._clamp_win(x, y, lo, hi)
  if x < lo then x = lo end
  if y > hi then y = hi end
  if x >= y then return nil end
  return { x, y }
end

function fftsa.nl.scan_windows(buf, elem0)
  local nl = fftsa.nl
  local lo, hi = nl.BACKSTOP_LO, nl.BACKSTOP_HI
  if lo == nil or hi == nil or lo >= hi then lo, hi = 0, nl.DRAM_END end
  local out, n = {}, 0
  local add = function(x, y)
    local w = nl._clamp_win(x, y, lo, hi)
    if w == nil then return end
    local i
    for i = 1, n do
      if out[i][1] == w[1] and out[i][2] == w[2] then return end
    end
    n = n + 1
    out[n] = w
  end

  local inst = nl.cclass(buf)
  if buf ~= nil then nl.inst = inst end
  local centres, cn = {}, 0
  local push = function(c)
    if c ~= nil and c > 0 then cn = cn + 1; centres[cn] = c end
  end
  push(inst)
  push(elem0)
  local cp = nl.col_ptrs(inst)
  local i
  for i = 1, table.getn(cp) do push(cp[i]) end
  push(nl.arena)
  for i = 1, cn do add(centres[i] - nl.TIGHT, centres[i] + nl.TIGHT) end

  -- Keep distant anchors in separate windows to avoid scanning the gap.
  for i = 1, 2 do
    local c = centres[i]
    if c ~= nil then
      add(c - nl.MID, c - nl.TIGHT)
      add(c + nl.TIGHT, c + nl.MID)
    end
  end

  local sw = nl.sweep_windows()
  for i = 1, table.getn(sw) do add(sw[i][1], sw[i][2]) end

  add(lo, hi)
  nl.last_windows = out
  return out
end

function fftsa.nl.windows_str()
  local w = fftsa.nl.last_windows
  if w == nil then return 'windows=none' end
  local o, i = 'windows=', nil
  for i = 1, table.getn(w) do
    if i > 2 then
      o = o .. ',+' .. tostring(table.getn(w) - 2)
      return o
    end
    if i > 1 then o = o .. ',' end
    o = o .. hx(w[i][1]) .. '..' .. hx(w[i][2])
  end
  return o
end

-- Summarize native startup, buffer geometry and reduction failures for on-device reports.
function fftsa.nl.diag()
  local nl = fftsa.nl
  local o = 'model=' .. tostring(localnode.model) .. ' fw=' .. tostring(localnode.version)
  o = o .. ' why=' .. tostring(nl.why)
  o = o .. ' | ready=' .. tostring(nl.ready) .. ' entry=' .. tostring(nl.entry)
  o = o .. ' rc=' .. tostring(nl.last_rc) .. ' spent=' .. tostring(nl.boot_spent)
  if nl.db_fails ~= nil then o = o .. ' dbfail=' .. tostring(nl.db_fails) end
  o = o .. ' | backstop=' .. hx(nl.BACKSTOP_LO or 0) .. '..' .. hx(nl.BACKSTOP_HI or 0)
  o = o .. ' anchor=' .. hx(nl.heap_anchor() or 0) .. ' ' .. nl.windows_str()
  o = o .. ' | glue=' .. tostring(nl.nglue) .. '/' .. tostring(nl.GLUE_MIN)
  local np, k = 0, nil
  if nl.math_pos ~= nil then for k in pairs(nl.math_pos) do np = np + 1 end end
  o = o .. ' mathpos=' .. tostring(np) .. ' odd=' .. tostring(nl.math_odd)
  o = o .. ' inst=' .. hx(nl.inst or 0) .. ' arena=' .. hx(nl.arena or 0)
  o = o .. ' | chunk=' .. tostring(nl.chunk_span) .. '/' .. tostring(nl.CHUNK_BYTES)
  o = o .. ' raw=' .. tostring(nl._raw_n) .. ' hits=' .. tostring(nl._hit_n)
  o = o .. ' win=' .. tostring(nl._win_hit) .. ' first[' .. tostring(nl._hit_why) .. ']'
  o = o .. ' | ' .. nl.sweep_str() .. ' ' .. nl.hits_str()
  o = o .. ' ' .. nl.desc_off_str() .. ' der[' .. tostring(nl._der_why) .. ']'
  o = o .. ' sig[' .. tostring(nl._sig_why) .. ']'
  o = o .. ' buf=' .. tostring(nl._desc_buf) .. ' cp=' .. tostring(nl._ncol)
  o = o .. ' str=' .. tostring(nl._stor_stride)
  o = o .. ' e0=' .. (nl._stor_elem0 ~= nil and hx(nl._stor_elem0) or 'nil')
  -- Report the capture geometry actually passed to native code.
  local c = fftsa.nl_cap
  if c == nil then
    o = o .. ' cap[none]'
  else
    o = o .. ' cap[es=' .. tostring(c.elemsize) .. ' pc=' .. tostring(c.perchunk)
             .. ' nc=' .. tostring(c.nchunks) .. ' c1=' .. hx(c.chunk1 or 0)
             .. ' vec=' .. hx(c.vec or 0) .. ' ' .. hx(c.lo or 0) .. '..' .. hx(c.hi or 0)
             .. ']'
  end
  o = o .. ' geom[' .. tostring(nl._geom_why) .. ']'
  o = o .. ' | ' .. nl.hit_dump_str()
  o = o .. ' | plan=' .. tostring(nl.SIZEOF_PLAN) .. ' params=' .. tostring(nl.SIZEOF_PARAMS)
  o = o .. ' real=' .. tostring(nl.SIZEOF_REAL) .. ' align=' .. tostring(nl.DSP_ALIGN)
  local i
  o = o .. ' | libm '
  for i = 1, table.getn(nl.MATH_NAMES) do
    local nm = nl.MATH_NAMES[i]
    local a = nl.fn ~= nil and nl.fn[nm] or nil
    o = o .. nm .. '=' .. (a ~= nil and hx(a) or 'NIL')
    if i < table.getn(nl.MATH_NAMES) then o = o .. ' ' end
  end
  return o
end

function fftsa.nl._no(why)
  fftsa.nl.why = why
  return false
end

-- Count returned bytes and incomplete reads rather than nominal sweep size.
fftsa.nl._sw_blocks, fftsa.nl._sw_nil, fftsa.nl._sw_short, fftsa.nl._sw_bytes = 0, 0, 0, 0

function fftsa.nl.sweep_reset()
  local nl = fftsa.nl
  nl._sw_blocks, nl._sw_nil, nl._sw_short, nl._sw_bytes = 0, 0, 0, 0
end

function fftsa.nl.sweep_str()
  local nl = fftsa.nl
  return 'read=' .. tostring(math.floor((nl._sw_bytes or 0) / 1048576)) .. 'MB/'
         .. tostring(nl._sw_blocks) .. 'blk nil=' .. tostring(nl._sw_nil)
         .. ' short=' .. tostring(nl._sw_short)
end

-- Budget resumable per-frame scans, not the synchronous buffer discovery at bind time.
fftsa.nl.RD_MAX_CALLS = 48
fftsa.nl.RD_MAX_BYTES = 393216  -- 384 KiB per frame

fftsa.nl._rd_calls, fftsa.nl._rd_bytes = 0, 0

-- A shared frame timestamp gives all search stages one accounting window.
function fftsa.nl.rd_frame(t)
  local nl = fftsa.nl
  if t ~= nil and t == nl._rd_t then return false end
  nl._rd_t = t
  nl._map_age = (nl._map_age or 0) + 1
  nl.rd_frame_reset()
  return true
end

function fftsa.nl.rd_frame_reset()
  local nl = fftsa.nl
  if (nl._rd_calls or 0) > (nl.rd_peak_calls or 0) then nl.rd_peak_calls = nl._rd_calls end
  if (nl._rd_bytes or 0) > (nl.rd_peak_bytes or 0) then nl.rd_peak_bytes = nl._rd_bytes end
  if nl.px ~= nil and nl.px.state ~= nil and nl.px.state ~= 'on' and nl._rd_t ~= nil then
    if (nl._rd_calls or 0) > (nl.rd_speak_calls or 0) then
      nl.rd_speak_calls = nl._rd_calls
    end
  end
  nl.rd_last_calls, nl.rd_last_bytes = nl._rd_calls, nl._rd_bytes
  nl._rd_calls, nl._rd_bytes = 0, 0
  if (nl._nf_bytes or 0) > (nl.nf_peak_bytes or 0) then nl.nf_peak_bytes = nl._nf_bytes end
  nl.nf_last_bytes = nl._nf_bytes
  nl._nf_bytes = 0
  nl._nf_secs = 0
end

function fftsa.nl.rd_note(bytes)
  local nl = fftsa.nl
  nl._rd_calls = (nl._rd_calls or 0) + 1
  nl._rd_bytes = (nl._rd_bytes or 0) + (bytes or 0)
end

-- Count bytes scanned by the image separately from bytes returned by Lua memory reads.
function fftsa.nl.nf_note(bytes, secs)
  local nl = fftsa.nl
  nl._nf_bytes = (nl._nf_bytes or 0) + (bytes or 0)
  nl._nf_secs = (nl._nf_secs or 0) + (secs or 0)
end

function fftsa.nl.rd_over()
  local nl = fftsa.nl
  return (nl._rd_calls or 0) >= nl.RD_MAX_CALLS
      or (nl._rd_bytes or 0) >= nl.RD_MAX_BYTES
end

function fftsa.nl.rd_str()
  local nl = fftsa.nl
  local o = string.format('rd=%d/%dKB peak=%d/%dKB srch=%d', nl.rd_last_calls or 0,
                          math.floor((nl.rd_last_bytes or 0) / 1024), nl.rd_peak_calls or 0,
                          math.floor((nl.rd_peak_bytes or 0) / 1024),
                          nl.rd_speak_calls or 0)
  if (nl.nf_peak_bytes or 0) > 0 then
    o = o .. string.format(' nf=%dKB/%dKB nb=%dKB', math.floor((nl.nf_last_bytes or 0) / 1024),
                           math.floor((nl.nf_peak_bytes or 0) / 1024),
                           math.floor((nl.px_nbudget or 0) / 1024))
    if nl.px_nrate ~= nil then
      o = o .. string.format(' @%.0fMB/s', nl.px_nrate / 1048576)
    end
    if nl.px_nover ~= nil then
      o = o .. string.format(' oh=%.1fms', nl.px_nover * 1000)
    end
  end
  return o
end

fftsa.nl.SWEEP_BLOCK = 32768

-- FINDS prefers native search. Bind-time buffer discovery may use a bounded Lua fallback;
-- pixel discovery requires native search outside offline tests.
fftsa.nl.FINDS_NATIVE_ONLY = false

-- Offline tests can enable the Lua pixel sweep without a native image.
fftsa.nl.PX_SWEEP = false

fftsa.nl.PX_PTR_TRIES = 30

fftsa.nl.NFIND = true

-- Derive live scan bounds from already-dereferenced addresses; guessed pointers do not
-- establish mapping. Keep confirmed trace storage in the span.
fftsa.nl.MAP_MIN_SPAN = 65536

fftsa.nl.MAP_REFRESH = 16

function fftsa.nl.map_bounds()
  local nl = fftsa.nl
  if nl.map_lo ~= nil and (nl._map_age or 0) < nl.MAP_REFRESH then
    return nl.map_lo, nl.map_hi
  end
  local known, n = {}, 0
  local function add(v)
    if type(v) == 'number' and v > 0 then
      n = n + 1
      known[n] = v
    end
  end
  add(nl.heap_anchor())
  add(nl.sub_trace_ok)
  if nl.sub_trace_ok ~= nil then add(nl.sub_trace_ok + nl.PX_NAME_SCAN) end
  add(nl.inst)
  add(nl.arena)
  add(nl.params)
  add(nl.find_addr)
  add(nl.res_addr)
  local c = nl.px_cache_get()
  if c ~= nil then
    add(c.lo)
    add(c.hi)
  end
  local cp = nl.col_ptrs(nl.inst)
  local i
  if type(cp) == 'table' then
    for i = 1, table.getn(cp) do add(cp[i]) end
  end
  -- A refresh without enough anchors keeps the last valid span.
  local function keep(why)
    nl.map_why = why
    nl._map_age = 0
    if nl.map_lo ~= nil then return nl.map_lo, nl.map_hi end
    return nil
  end
  if n < 2 then
    return keep('only ' .. tostring(n) .. ' address known to be live; need two for a span')
  end
  local lo, hi = known[1], known[1]
  for i = 2, n do
    if known[i] < lo then lo = known[i] end
    if known[i] > hi then hi = known[i] end
  end
  if nl.map_lo ~= nil then
    if nl.map_lo < lo then lo = nl.map_lo end
    if nl.map_hi > hi then hi = nl.map_hi end
  end
  local blo, bhi = nl.BACKSTOP_LO, nl.BACKSTOP_HI
  if blo == nil or bhi == nil or blo >= bhi then blo, bhi = 0, nl.DRAM_END end
  if lo < blo then lo = blo end
  if hi > bhi then hi = bhi end
  if hi - lo < nl.MAP_MIN_SPAN then
    return keep('live addresses span only ' .. tostring(hi - lo) .. ' bytes')
  end
  nl.map_lo, nl.map_hi = lo, hi
  nl._map_age = 0
  nl.map_why = nil
  return lo, hi
end

fftsa.nl.NFIND_CAP = 4194304

-- Buffer discovery may reach beyond the live graph span, within the buffer heap bounds.
function fftsa.nl._buffer_heap_bounds()
  if localnode == nil or localnode.model ~= 'DMM7510' then return nil end
  local v = localnode.version
  if v ~= '1.7.16a' and v ~= '1.7.18a' then return nil end
  return 9052160, 260710400             -- 0x008A2000 .. 0x0F8A2000
end

function fftsa.nl._finds_native(lo, hi, pat, heap_lo, heap_hi)
  local nl = fftsa.nl
  if not nl.NFIND then return nil end
  if nl.nfind == nil or not nl.ready then return nil end
  local mlo, mhi = heap_lo, heap_hi
  if mlo == nil then mlo, mhi = nl.map_bounds() end
  if mlo == nil then return nil end
  if lo < mlo then lo = mlo end
  if hi > mhi then hi = mhi end
  if hi < lo + string.len(pat) then return {} end
  if nl.find_addr == nil or nl.find_addr == 0 then return nil end
  if string.len(pat) > (nl.NFIND_PAT_MAX or 0) then return nil end
  local out, n, at = {}, 0, lo
  while at + string.len(pat) <= hi do
    local t0 = os.clock()
    local hits, nxt = nl.nfind(at, hi, pat, nl.NFIND_CAP)
    local el = os.clock() - t0
    if hits == nil then return nil end
    local k
    for k = 1, table.getn(hits) do
      n = n + 1
      out[n] = hits[k]
    end
    if nxt == nil or nxt <= at then return out end
    -- Budget native slices using the image's actual progress, including refused reads.
    nl._sw_bytes = (nl._sw_bytes or 0) + (nxt - at)
    nl._sw_blocks = (nl._sw_blocks or 0) + 1
    nl.rd_note(0)
    nl.nf_note(nxt - at, el)
    at = nxt
  end
  return out
end

function fftsa.nl.FINDS(lo, hi, pat, buffer_search)
  local nl  = fftsa.nl
  local hlo, hhi
  if buffer_search then hlo, hhi = nl._buffer_heap_bounds() end
  if hlo ~= nil then
    lo, hi = math.max(lo, hlo), math.min(hi, hhi)
    if hi < lo + string.len(pat) then return {} end
  end
  local nat = nl._finds_native(lo, hi, pat, hlo, hhi)
  if nat ~= nil then return nat end
  if nl.FINDS_NATIVE_ONLY then return nil end
  local a   = lo
  local out = {}
  local n   = 0
  local pl  = string.len(pat)
  while a < hi do
    local want = fftsa.nl.SWEEP_BLOCK
    if a + want > hi then want = hi - a end
    local s = ki.memread(hx(a), hx(want))
    nl.rd_note(want)
    local got = 0
    nl._sw_blocks = nl._sw_blocks + 1
    if s == nil then
      nl._sw_nil = nl._sw_nil + 1
    else
      got = string.len(s)
      nl._sw_bytes = nl._sw_bytes + got
      if got < want then nl._sw_short = nl._sw_short + 1 end
      local i = 1
      while true do
        local j = string.find(s, pat, i, true)
        if j == nil then break end
        n = n + 1; out[n] = a + j - 1
        i = j + 1
      end
    end
    -- Advance by returned bytes and overlap only enough to catch a split needle.
    local nexta
    if got >= pl then
      -- Stop at the tail before subtracting overlap so the final slice cannot repeat.
      if a + got >= hi then break end
      nexta = a + got - (pl - 1)
    else
      nexta = a + want
    end
    if nexta <= a then nexta = a + want end
    a = nexta
  end
  return out
end

-- Locate element 0 by matching distinctive samples and checking the stride on distant elements.

-- Seed code and plan buffers with distinct readings and extras for content discovery.
fftsa.nl.SEED_READS = 256

local READ_CONFIRM = 6
local FAR_INDEX = { 64, 256 }

function fftsa.nl._find_storage(buf, has_extras)
  local n = buf.n
  fftsa.nl._stor_why = nil
  if n == nil or n < READ_CONFIRM then
    fftsa.nl._stor_why = 'short record n=' .. tostring(n)
    return nil
  end
  local rd, ex = {}, nil
  local i
  for i = 1, READ_CONFIRM do
    rd[i] = buf.readings[i]
    if rd[i] == nil then return nil end
  end
  if has_extras then
    ex = {}
    for i = 1, 3 do
      ex[i] = buf.extravalues[i]
      if ex[i] == nil then return nil end
    end
  end
  -- Include distant samples to distinguish the full capture from a small staging copy.
  local far, fn = {}, 0
  for i = 1, table.getn(FAR_INDEX) do
    local j = FAR_INDEX[i]
    if j > READ_CONFIRM and j <= n then
      fn = fn + 1
      far[fn] = j
      if buf.readings[j] == nil then return nil end
    end
  end
  local needle = f64_pack(rd[1])
  local windows = fftsa.nl.scan_windows(buf, nil)
  local wi
  local nhits = 0
  fftsa.nl.sweep_reset()
  for wi = 1, table.getn(windows) do
    local hits = fftsa.nl.FINDS(windows[wi][1], windows[wi][2], needle, true)
    nhits = nhits + table.getn(hits)
    local k
    for k = 1, table.getn(hits) do
      local h = hits[k]
      -- Element zero need only be four-byte aligned; allocator alignment applies to the chunk base.
      if math.mod(h, 4) == 0 then
        -- Try all supported record strides; the same prefix can fit more than one.
        local cands, cn = { 32, 24, 20 }, 3
        if rd[2] ~= rd[1] then
          local off
          for off = 8, 64, 4 do
            if off ~= 32 and off ~= 24 and off ~= 20 and eq64(h + off, rd[2]) then
              cn = cn + 1; cands[cn] = off
            end
          end
        end
        local ci
        for ci = 1, cn do
          local s = cands[ci]
          local good = true
          for i = 2, READ_CONFIRM do
            if not eq64(h + (i - 1) * s, rd[i]) then good = false end
          end
          for i = 1, fn do
            if not eq64(h + (far[i] - 1) * s, buf.readings[far[i]]) then good = false end
          end
          if ex ~= nil then
            if s < 28 then good = false
            else
              for i = 1, 3 do
                if not eq64(h + (i - 1) * s + 20, ex[i]) then good = false end
              end
            end
          end
          if good then return h, s end
        end
      end
    end
  end
  fftsa.nl._stor_why = 'no stride confirmed n=' .. tostring(n) .. ' hits=' .. tostring(nhits)
                       .. ' eq12=' .. tostring(rd[2] == rd[1])
                       .. ' x=' .. tostring(has_extras)
                       .. ' ' .. fftsa.nl.sweep_str()
  return nil
end

-- Validate the descriptor fields together, including chunk count and vector coverage.
function fftsa.nl._chunk_span(elemsize, perchunk)
  if elemsize == nil or perchunk == nil then return nil end
  if elemsize < 8 or perchunk < 1 then return nil end
  local p = 4096
  while p <= 1048576 do
    if elemsize * perchunk <= p and elemsize * (perchunk + 1) > p then return p end
    p = p * 2
  end
  return nil
end

-- Descriptor layouts may be read on either model. Cursor writes require the native image's layout.
fftsa.nl.DOFF = { es = 8, pc = 12, nc = 16, vec = 68, stor = 72, s1 = 84, s2 = 100,
                  cap = 116 }
fftsa.nl.DOFF_7510 = { es = 8, pc = 12, nc = 16, vec = 60, stor = 64, s1 = 76, s2 = 92,
                       cap = 108 }

-- Try known descriptor layouts in order, checking each against the same storage and size constraints.
fftsa.nl.DOFF_SETS = { fftsa.nl.DOFF, fftsa.nl.DOFF_7510 }

-- Track the layout that matched so callers can refuse an incompatible cursor write.
fftsa.nl.doff_used = nil

function fftsa.nl._read_desc_1(base, elem0, D, note)
  if base == nil then return nil end
  local nl = fftsa.nl
  local g = nl._wg
  if g(base + D.stor) ~= elem0 then return nil end
  if g(base + D.s1) ~= base or g(base + D.s2) ~= base then return nil end
  local elemsize = g(base + D.es)
  local perchunk = g(base + D.pc)
  local nchunks  = g(base + D.nc)
  -- A chunk holds floor(payload bytes / element size) complete records.
  local span = nl._chunk_span(elemsize, perchunk)
  if note then
    nl._hit_n = (nl._hit_n or 0) + 1
    if nl._hit_why == nil then
      nl._hit_why = 'es=' .. tostring(elemsize) .. ' pc=' .. tostring(perchunk)
                    .. ' nc=' .. tostring(nchunks) .. ' span=' .. tostring(span)
    end
  end
  if elemsize == nil or perchunk == nil or nchunks == nil then return nil end
  if nchunks < 1 or nchunks >= 4096 or elemsize < 8 or perchunk < 1 then return nil end
  if span == nil then return nil end
  nl.chunk_span = span
  nl.doff_used = D
  return base, elemsize, perchunk, g(base + D.vec), nchunks
end

function fftsa.nl._read_desc(base, elem0)
  if base == nil then return nil end
  local si
  for si = 1, table.getn(fftsa.nl.DOFF_SETS) do
    local b, es, pc, v, nc = fftsa.nl._read_desc_1(base, elem0, fftsa.nl.DOFF_SETS[si])
    if b ~= nil then return b, es, pc, v, nc end
  end
  return nil
end

-- Compute a descriptor base from its storage-pointer offset, then validate the full record.
function fftsa.nl._read_desc_from_stor(h, elem0, note)
  if h == nil then return nil end
  local si
  for si = 1, table.getn(fftsa.nl.DOFF_SETS) do
    local D = fftsa.nl.DOFF_SETS[si]
    local b, es, pc, v, nc = fftsa.nl._read_desc_1(h - D.stor, elem0, D, note)
    if b ~= nil then return b, es, pc, v, nc end
  end
  return nil
end

-- Reset both discovery diagnostics and layout attribution for the new buffer.
function fftsa.nl.desc_report_reset(buf)
  local nl = fftsa.nl
  nl._hit_n, nl._hit_why, nl._raw_n, nl._win_hit = 0, nil, 0, nil
  nl._raw_at, nl._der_why, nl.desc_off = {}, nil, nil
  nl._der_best, nl._der_best_n = nil, -1
  nl._ncol = nil
  nl.doff_used = nil
  nl._desc_buf = 'cap' .. tostring(buf ~= nil and buf.capacity or nil)
                 .. '/n' .. tostring(buf ~= nil and buf.n or nil)
end

-- Derive descriptor fields relative to the storage hit. Cross-check the self pointer, stride,
-- chunk capacity and vector before treating the record as a descriptor.

fftsa.nl.DERIVE_BACK, fftsa.nl.DERIVE_FWD = 256, 320
fftsa.nl.DERIVE_SELF_MIN = 2
-- Bound the chunk-vector walk independently of any candidate count field.
fftsa.nl.DERIVE_NC_MAX = 1024

-- A candidate payload must be four-byte aligned, in range and readable.
function fftsa.nl._payload_ok(a)
  if type(a) ~= 'number' or a == 0 then return false end
  if math.mod(a, 4) ~= 0 then return false end
  return fftsa.nl._wg(a) ~= nil
end

function fftsa.nl._derive_desc(h, elem0, stride)
  local nl = fftsa.nl
  local g = nl._wg
  if h == nil or type(h) ~= 'number' or math.mod(h, 4) ~= 0 then return nil end
  if type(stride) ~= 'number' or stride < 8 then return nil end
  local back, fwd = nl.DERIVE_BACK, nl.DERIVE_FWD
  local v, k = {}, nil
  for k = -back, fwd, 4 do v[k] = g(h + k) end

  -- The descriptor's self-pointer gives a candidate start relative to the hit.
  local base, nself = nil, 0
  for k = -back, fwd, 4 do
    local b = v[k]
    if b ~= nil and b > 0 and math.mod(b, 4) == 0 and b <= h and h - b <= back then
      local c, k2 = 0, nil
      for k2 = -back, fwd, 4 do
        if v[k2] == b then c = c + 1 end
      end
      if c > nself then base, nself = b, c end
    end
  end
  if nl._der_best == nil or nself > nl._der_best_n then
    nl._der_best, nl._der_best_n = h, nself
  end
  if base == nil or nself < nl.DERIVE_SELF_MIN then
    nl._der_why = 'no self-pointer pair within ' .. tostring(back) .. ' of ' .. hx(h)
    return nil
  end

  local s1off, s2off = nil, nil
  for k = -back, fwd, 4 do
    if v[k] == base then
      if s1off == nil then s1off = h + k - base
      elseif s2off == nil then s2off = h + k - base end
    end
  end

  -- Only interpret fields wholly inside the neighborhood already read.
  local at = function(off)
    local kk = base + off - h
    if kk < -back or kk > fwd then return nil end
    return v[kk]
  end
  local span_hi = h + fwd - base

  -- The element size must equal the measured stride; the adjacent capacity must fit a chunk.
  local off_es, perchunk, span = nil, nil, nil
  local off
  for off = 0, span_hi - 4, 4 do
    if at(off) == stride then
      local pc = at(off + 4)
      local sp = nl._chunk_span(stride, pc)
      if sp ~= nil then off_es, perchunk, span = off, pc, sp end
    end
    if off_es ~= nil then break end
  end
  if off_es == nil then
    nl._der_why = 'no elemsize=' .. tostring(stride) .. ' with a payload-filling perchunk in '
                  .. hx(base) .. '+0..' .. tostring(span_hi)
    return nil
  end

  -- A chunk vector must start with the proved element-zero payload.
  local off_vec, vec = nil, nil
  for off = 0, span_hi, 4 do
    local p = at(off)
    if p ~= nil and p > 0 and math.mod(p, 4) == 0 and g(p) == elem0 then
      off_vec, vec = off, p
      break
    end
  end
  if off_vec == nil then
    nl._der_why = 'no word pointing at ' .. hx(elem0) .. ' in ' .. hx(base) .. '+0..'
                  .. tostring(span_hi)
    return nil
  end

  -- The chunk count must agree with the contiguous plausible vector entries.
  local m = 0
  while m < nl.DERIVE_NC_MAX do
    if not nl._payload_ok(g(vec + m * 4)) then break end
    m = m + 1
  end
  local off_nc = nil
  for off = 0, span_hi, 4 do
    if at(off) == m and m >= 1 then
      off_nc = off
      break
    end
  end
  if off_nc == nil then
    nl._der_why = 'no word equal to the ' .. tostring(m) .. ' plausible entries of the vector '
                  .. 'at ' .. hx(vec)
    return nil
  end
  local nchunks = m

  nl.chunk_span = span
  nl.desc_off = { es = off_es, pc = off_es + 4, nc = off_nc, vec = off_vec,
                  stor = h - base, s1 = s1off, s2 = s2off, self_n = nself }
  nl.doff_used = nil
  nl._der_why = nil
  return base, stride, perchunk, vec, nchunks
end

-- Rewind may store only at the compiled descriptor offsets, even when data reads use derived offsets.
function fftsa.nl.desc_off_ok(d)
  local nl = fftsa.nl
  local D = nl.DOFF
  if d == nil then return false end
  local o = d.dderived
  if o ~= nil then
    return o.es == D.es and o.pc == D.pc and o.nc == D.nc
           and o.vec == D.vec and o.stor == D.stor
  end
  return d.doff ~= nil and d.doff == D
end

function fftsa.nl.desc_off_str()
  local nl = fftsa.nl
  local o = nl.desc_off
  if o == nil then
    local u = nl.doff_used
    if u == nil then return 'doff=none' end
    if u == nl.DOFF then return 'doff=compiled' end
    return 'doff=stor' .. hx(u.stor) .. ',vec' .. hx(u.vec) .. ',cap' .. hx(u.cap)
  end
  return 'doff=stor' .. hx(o.stor) .. ',es' .. hx(o.es) .. ',nc' .. hx(o.nc)
         .. ',vec' .. hx(o.vec) .. ',s' .. hx(o.s1 or 0) .. '/' .. hx(o.s2 or 0)
         .. ',n' .. tostring(o.self_n)
end

fftsa.nl.DUMP_LO, fftsa.nl.DUMP_HI = -72, 68

function fftsa.nl.hit_dump_str()
  local nl = fftsa.nl
  local h = nl._der_best
  if h == nil then
    local d = nl._raw_at
    if d == nil then return 'dump=none' end
    h = d[1]
  end
  if h == nil then return 'dump=none' end
  local o, k = 'dump' .. hx(h) .. tostring(nl.DUMP_LO) .. '[', nil
  for k = nl.DUMP_LO, nl.DUMP_HI, 4 do
    if k > nl.DUMP_LO then o = o .. ' ' end
    local w = nl._wg(h + k)
    if w == nil then o = o .. '-' else o = o .. hx(w) end
  end
  return o .. ']'
end

fftsa.nl.HITS_KEEP, fftsa.nl.HITS_SHOW = 64, 6

function fftsa.nl.hits_str()
  local nl = fftsa.nl
  local d = nl._raw_at
  if d == nil or table.getn(d) == 0 then return 'at=none' end
  local o, i = 'at=', nil
  for i = 1, table.getn(d) do
    if i > nl.HITS_SHOW then return o .. '+' .. tostring(table.getn(d) - nl.HITS_SHOW) end
    if i > 1 then o = o .. ',' end
    o = o .. hx(d[i])
  end
  return o
end

function fftsa.nl._find_desc(elem0, buf, stride)
  -- Revalidate the cached descriptor against the storage address before reusing it.
  local nl = fftsa.nl
  if nl._desc_of == elem0 then
    local b, es, pc, v, nc = nl._read_desc(nl._desc_at, elem0)
    if b ~= nil then return b, es, pc, v, nc end
    nl._desc_of, nl._desc_at = nil, nil
  end
  local needle = u32_pack(elem0)
  nl.desc_report_reset(buf)
  nl.sweep_reset()
  local seen, nseen = {}, 0
  local windows = fftsa.nl.scan_windows(buf, elem0)
  -- Follow buffer-owned pointers before trying a sweep.
  local cand = fftsa.nl.col_ptrs(nl.inst)
  nl._ncol = table.getn(cand)
  local ci
  for ci = 1, table.getn(cand) do
    local b, es, pc, v, nc = nl._read_desc(cand[ci], elem0)
    if b ~= nil then
      nl._desc_of, nl._desc_at = elem0, b
      nl._win_hit, nl.arena = 0, b
      return b, es, pc, v, nc
    end
  end
  local wi
  for wi = 1, table.getn(windows) do
    local hits = fftsa.nl.FINDS(windows[wi][1], windows[wi][2], needle, true)
    nl._raw_n = nl._raw_n + table.getn(hits)
    local k
    for k = 1, table.getn(hits) do
      -- Keep unique hits for the derived layout and failure report.
      if seen[hits[k]] == nil and nseen < nl.HITS_KEEP then
        nseen = nseen + 1
        seen[hits[k]] = true
        nl._raw_at[nseen] = hits[k]
      end
      local b, es, pc, v, nc = fftsa.nl._read_desc_from_stor(hits[k], elem0, true)
      if b ~= nil then
        nl._desc_of, nl._desc_at = elem0, b
        nl._win_hit, nl.arena = wi, b
        return b, es, pc, v, nc
      end
    end
  end

  -- Reuse the hits to derive the layout when the known layouts fail.
  if stride ~= nil then
    local di
    for di = 1, table.getn(nl._raw_at) do
      local b, es, pc, v, nc = nl._derive_desc(nl._raw_at[di], elem0, stride)
      if b ~= nil then
        nl._desc_of, nl._desc_at = elem0, b
        nl._win_hit, nl.arena = -1, b
        return b, es, pc, v, nc
      end
    end
  end
  return nil
end

-- The signature path finds a descriptor by the buffer's capacity/count pair, then validates
-- its storage against sample content before accepting either address.
function fftsa.nl._find_desc_by_sig(buf)
  local nl = fftsa.nl
  nl._sig_why = nil
  nl.desc_report_reset(buf)
  local cap, n = buf.capacity, buf.n
  if type(cap) ~= 'number' or type(n) ~= 'number' or cap < 1 or n < 1 then
    nl._sig_why = 'cap=' .. tostring(cap) .. ' n=' .. tostring(n)
    return nil
  end
  local needle = u32_pack(cap) .. u32_pack(n)
  local windows = fftsa.nl.scan_windows(buf, nil)
  local wi
  local nhits = 0
  nl.sweep_reset()
  for wi = 1, table.getn(windows) do
    local hits = fftsa.nl.FINDS(windows[wi][1], windows[wi][2], needle, true)
    nhits = nhits + table.getn(hits)
    local k
    for k = 1, table.getn(hits) do
      local si
      for si = 1, table.getn(nl.DOFF_SETS) do
        local D = nl.DOFF_SETS[si]
        local base = hits[k] - D.cap
        local elem0 = fftsa.nl._wg(base + D.stor)
        if elem0 ~= nil and elem0 ~= 0 then
          local b, es, pc, v, nc = nl._read_desc_1(base, elem0, D)
          if b ~= nil then
            nl._desc_of, nl._desc_at = elem0, base
            nl._win_hit, nl.arena = wi, base
            return base, elem0, es, pc, v, nc
          end
        end
      end
    end
  end
  nl._sig_why = 'cap=' .. tostring(cap) .. '/n=' .. tostring(n) .. ' sig hits=' .. tostring(nhits)
                .. ' ' .. nl.sweep_str()
  return nil
end

-- Display ring discovery: confirm records against known appends, then prove the header
-- and field offsets before any writes.

fftsa.nl.REC_MIN, fftsa.nl.REC_MAX = 16, 128
fftsa.nl.RING_MIN, fftsa.nl.RING_MAX = 8, 4096

function fftsa.nl.find_ring_records(sentinels, full)
  local nl = fftsa.nl
  nl.ring_why = nil
  local ns = sentinels ~= nil and table.getn(sentinels) or 0
  if ns < 3 then
    nl.ring_why = 'need 3 sentinels, got ' .. tostring(ns)
    return nil
  end
  local pat, i = {}, nil
  for i = 1, ns do
    local s = sentinels[i]
    if s == nil or type(s.db) ~= 'number' or type(s.hz) ~= 'number' then
      nl.ring_why = 'sentinel ' .. tostring(i) .. ' is not a db/hz pair'
      return nil
    end
    pat[i] = f32_pack(s.db)
  end
  if pat[1] == pat[2] then
    nl.ring_why = 'sentinels 1 and 2 pack to the same float32'
    return nil
  end
  local n1 = pat[1] .. pat[1]

  -- Intersect the two sentinel searches by candidate stride rather than subtracting arbitrary hits.
  local windows = nl.scan_windows(nil, nil)
  -- Try windows in order; stop only after validating candidates in the current window.
  local out, nout = {}, 0
  local h1n, h2n, nsall = 0, 0, 0
  local wi
  for wi = 1, table.getn(windows) do
    local lo, hi = windows[wi][1], windows[wi][2]
    local h1 = nl.FINDS(lo, hi, n1)
    h1n = h1n + table.getn(h1)
    -- Search for the second needle only in windows containing the first.
    local h2 = {}
    if table.getn(h1) > 0 then
      h2 = nl.FINDS(lo, hi, n1)
      h2n = h2n + table.getn(h2)
    end
    local stable, ns = {}, 0
    local a, b
    for a = 1, table.getn(h1) do
      local seen, keep = false, false
      for b = 1, table.getn(h2) do
        if h1[a] == h2[b] then keep = true end
      end
      if keep then
        for b = 1, ns do
          if stable[b] == h1[a] then seen = true end
        end
        for b = 1, nout do
          if out[b].val0 == h1[a] then seen = true end
        end
        if not seen then ns = ns + 1; stable[ns] = h1[a] end
      end
    end
    nsall = nsall + ns
    -- Keep every valid stride in the window; a staging ring can match the same sentinel.
    local ci, sv
    for ci = 1, ns do
      for sv = nl.REC_MIN, nl.REC_MAX, 4 do
        local g = nl._ring_confirm(stable[ci], sv, sentinels, pat)
        if g ~= nil then nout = nout + 1; out[nout] = g end
      end
    end
    nl.ring_win, nl.ring_nwin = wi, table.getn(windows)
    if nout > 0 and not full then break end
  end
  nl.ring_hits = h1n .. '/' .. h2n .. '/' .. nsall
  nl.ring_cands = out
  if nout == 0 then
    nl.ring_why = 'no stride between ' .. nl.REC_MIN .. ' and ' .. nl.REC_MAX
                  .. ' confirmed, hits ' .. tostring(nl.ring_hits)
    return nil
  end
  return out[1]
end

function fftsa.nl.find_ring(sentinels, full)
  local nl = fftsa.nl
  if nl.find_ring_records(sentinels, full) == nil then return nil end
  local c = nl.ring_cands
  local i
  for i = 1, table.getn(c) do
    if nl.find_ring_header(c[i]) ~= nil then
      nl.ring_why = nil
      return c[i]
    end
  end
  nl.ring_why = 'no header for any of ' .. tostring(table.getn(c)) .. ' record candidates: '
                .. tostring(nl.ring_why)
  -- A narrow search can find records without their owner header; widen before giving up.
  if not full and nl.ring_win ~= nil and nl.ring_win < nl.ring_nwin then
    return nl.find_ring(sentinels, true)
  end
  return nil
end

-- Confirm every sentinel in one read and derive the X offset within the candidate records.
function fftsa.nl._ring_confirm(val0, stride, sentinels, pat)
  local nl = fftsa.nl
  local ns = table.getn(sentinels)
  local span = (ns - 1) * stride + 8
  local blk = ki.memread(hx(val0), hx(span))
  if blk == nil or string.len(blk) < span then return nil end
  local i
  for i = 1, ns do
    local at = (i - 1) * stride + 1
    if string.sub(blk, at, at + 7) ~= pat[i] .. pat[i] then return nil end
  end
  local xp = f32_pack(sentinels[1].hz)
  local one = ki.memread(hx(val0 - stride), hx(2 * stride))
  if one == nil or string.len(one) < 2 * stride then return nil end
  local p2 = f32_pack(sentinels[2].hz)
  local xn, at = xp .. xp, 1
  while true do
    local j = string.find(one, xn, at, true)
    if j == nil then return nil end
    local dx = j - 1 - stride
    -- Validate the X offset on another record so adjacent bytes cannot impersonate it.
    local x2 = ki.memread(hx(val0 + stride + dx), hx(8))
    if x2 ~= nil and x2 == p2 .. p2 then
      return { val0 = val0, stride = stride, dx = dx, nconf = ns }
    end
    at = j + 1
  end
end

-- Find the owner header from record addresses and stride, not by assuming a header address.
fftsa.nl.HDR_BELOW, fftsa.nl.HDR_ABOVE = 262144, 65536
fftsa.nl.HDR_OLD, fftsa.nl.HDR_WRITE, fftsa.nl.HDR_COUNT = 8, 12, 20

-- Use fixed DMM6500 cursor offsets and derive them on DMM7510 before allowing writes.
fftsa.nl.PX_HDR_SCAN = 64
fftsa.nl.PX_HDR_TRIES = 12

-- Advance the ring with one append and classify cursor fields by what actually moves.
function fftsa.nl.px_hdr_resolve(g)
  local nl = fftsa.nl
  if g == nil or g.hdr == nil or g.h_cnt == nil or g.h_pairs == nil then return false end
  if g.h_old ~= nil then return true end
  local want = nl.PX_HDR_SCAN + 4
  local blk = ki.memread(hx(g.hdr), hx(want))
  nl.rd_note(want)
  if blk == nil or string.len(blk) < want then
    g.h_why = 'header window read gave ' .. tostring(blk ~= nil and string.len(blk) or 0)
    return false
  end
  local prev = g.h_prev
  g.h_prev = blk
  if prev == nil then
    g.h_why = 'first sample taken, the next frame says which word moved'
    return false
  end
  local at = function(s, o)
    if o < 0 or o + 4 > string.len(s) then return nil end
    return u32_at(s, o + 1)
  end
  local sv, n = g.stride, g.nrec
  local c0, c1 = at(prev, g.h_cnt), at(blk, g.h_cnt)
  if c0 == nil or c1 == nil then
    g.h_why = 'the count offset is outside the window'
    return false
  end
  local filling = (c1 == c0 + 1)
  if not filling and not (c1 == n and c0 == n) then
    g.h_why = 'the count went ' .. tostring(c0) .. ' to ' .. tostring(c1)
              .. ', neither filling nor full'
    return false
  end
  local keep, nk, i = {}, 0, nil
  for i = 1, table.getn(g.h_pairs) do
    local pr = g.h_pairs[i]
    local o0, o1 = at(prev, pr[1]), at(blk, pr[1])
    local w0, w1 = at(prev, pr[2]), at(blk, pr[2])
    if o0 ~= nil and o1 ~= nil and w0 ~= nil and w1 ~= nil then
      local ok = false
      if filling then
        ok = (o1 == o0) and (w1 == w0 + sv)
      else
        -- At capacity, both cursors advance; their relative positions must still identify their roles.
        ok = (o1 == o0 + sv) and (w1 == w0 + sv)
      end
      if ok then
        nk = nk + 1
        keep[nk] = pr
      end
    end
  end
  g.h_pairs = keep
  if nk == 0 then
    g.h_why = 'no cursor pair behaved like one across the append'
    return false
  end
  if nk > 1 or not filling then
    g.h_why = tostring(nk) .. ' pair(s) still fit'
    if not filling then g.h_why = g.h_why .. ' and the ring is full, so neither cursor is idle' end
    return false
  end
  -- On a known layout, refuse an incompatible derived cursor map rather than writing through it.
  if nl.hdr_known and (keep[1][1] ~= nl.HDR_OLD or keep[1][2] ~= nl.HDR_WRITE
                       or g.h_cnt ~= nl.HDR_COUNT) then
    nl.hdr_differ = (nl.hdr_differ or 0) + 1
    nl.hdr_why = string.format('cause gave %d/%d/%d, this model measures %d/%d/%d',
                               keep[1][1], keep[1][2], g.h_cnt,
                               nl.HDR_OLD, nl.HDR_WRITE, nl.HDR_COUNT)
    g.h_why = nl.hdr_why
    return false
  end
  g.h_old, g.h_wr = keep[1][1], keep[1][2]
  g.h_why = nil
  nl.hdr_resolved = (nl.hdr_resolved or 0) + 1
  if nl.hdr_known then nl.hdr_agree = (nl.hdr_agree or 0) + 1 end
  return true
end

function fftsa.nl.hdr_offs(g)
  local nl = fftsa.nl
  if type(g) == 'table' and g.h_old ~= nil and g.h_wr ~= nil and g.h_cnt ~= nil then
    return g.h_old, g.h_wr, g.h_cnt
  end
  return nl.HDR_OLD, nl.HDR_WRITE, nl.HDR_COUNT
end

fftsa.nl.PX_HDR_DERIVE = false

-- Compare derived and known offsets without changing the active layout in shadow mode.
fftsa.nl.PX_HDR_CHECK = true
fftsa.nl.hdr_agree, fftsa.nl.hdr_differ = 0, 0
fftsa.nl.hdr_why = nil

-- Collect one count offset and candidate cursor pairs for later validation by movement.
function fftsa.nl.px_hdr_roles(rd, lo, hi, sv, n)
  local nl = fftsa.nl
  local ptrs, cnts, np, nc = {}, {}, 0, 0
  local o
  -- Exclude the two known bounds words when classifying cursor roles.
  for o = 8, nl.PX_HDR_SCAN, 4 do
    local v = rd(o)
    if v ~= nil then
      if v >= lo and v <= hi and math.mod(v - lo, sv) == 0 then
        np = np + 1
        ptrs[np] = o
      end
      if v >= 1 and v <= n then
        nc = nc + 1
        cnts[nc] = o
      end
    end
  end
  if nc ~= 1 then return nil end
  local pairs2, npair, a, b = {}, 0, nil, nil
  for a = 1, np do
    for b = 1, np do
      if ptrs[b] > ptrs[a] and ptrs[a] ~= cnts[1] and ptrs[b] ~= cnts[1] then
        npair = npair + 1
        pairs2[npair] = { ptrs[a], ptrs[b] }
      end
    end
  end
  if npair == 0 then return nil end
  return cnts[1], pairs2
end

-- rd(off) reads a header word; lo, hi, stride and count describe the ring being proved.
function fftsa.nl.px_hdr_derive(rd, lo, hi, sv, n)
  local nl = fftsa.nl
  local olds, wrs, cnts, no, nw, nc = {}, {}, {}, 0, 0, 0
  local o
  for o = 0, nl.PX_HDR_SCAN, 4 do
    local v = rd(o)
    if v ~= nil then
      if v >= lo and v < hi and math.mod(v - lo, sv) == 0 then
        no = no + 1
        olds[no] = o
      end
      if v >= lo and v <= hi and math.mod(v - lo, sv) == 0 then
        nw = nw + 1
        wrs[nw] = o
      end
      if v == n then
        nc = nc + 1
        cnts[nc] = o
      end
    end
  end
  if nc ~= 1 then
    return nil, tostring(nc) .. ' offsets hold the record count'
  end
  -- A unique cursor pair must fit the expected order; ambiguity is a refusal.
  local a, b
  for a = 1, no do
    for b = 1, nw do
      if wrs[b] > olds[a] and olds[a] ~= cnts[1] and wrs[b] ~= cnts[1] then
        local a2, b2, pairs2 = nil, nil, 0
        local c, d
        for c = 1, no do
          for d = 1, nw do
            if wrs[d] > olds[c] and olds[c] ~= cnts[1] and wrs[d] ~= cnts[1] then
              pairs2 = pairs2 + 1
              a2, b2 = olds[c], wrs[d]
            end
          end
        end
        if pairs2 ~= 1 then
          return nil, tostring(pairs2) .. ' cursor pairs fit'
        end
        return a2, b2, cnts[1]
      end
    end
  end
  return nil, 'no ordered cursor pair inside the ring'
end

function fftsa.nl.find_ring_header(g)
  local nl = fftsa.nl
  nl.ring_why = nil
  if g == nil or g.val0 == nil or g.stride == nil then
    nl.ring_why = 'no record geometry to find a header from'
    return nil
  end
  local v, s = g.val0, g.stride
  local lo = v - nl.HDR_BELOW
  if lo < nl.BACKSTOP_LO then lo = nl.BACKSTOP_LO end
  local hi = v + nl.HDR_ABOVE
  local found, nfound = nil, 0
  -- Search only where a bounds pair could bracket the observed record.
  local maxspan = nl.RING_MAX * s
  local pre, np = {}, 0
  local t = math.floor(v / 65536)
  local lot = math.floor((v - maxspan) / 65536)
  if lot < 0 then lot = 0 end
  local k
  for k = lot, t do
    np = np + 1
    pre[np] = string.char(math.mod(math.floor(k / 256), 256), math.mod(k, 256))
  end
  local a = lo
  while a < hi do
    local step = 32768
    if a + step > hi then step = hi - a end
    local blk = ki.memread(hx(a), hx(step))
    nl.rd_note(step)
    if blk ~= nil then
      local pi
      for pi = 1, np do
        local i = 1
        while true do
          local j = string.find(blk, pre[pi], i, true)
          if j == nil then break end
          local at = a + j - 1
          if math.mod(at, 4) == 0 and at + 24 <= a + step then
            local c = nl._ring_hdr_ok(at, blk, j, g)
            if c ~= nil then
              nfound = nfound + 1
              if found == nil then found = c end
            end
          end
          i = j + 1
        end
      end
    end
    if a + step >= hi then break end
    -- Overlap slices by the header width so a candidate cannot straddle an unread boundary.
    a = a + step - 24
  end
  nl.ring_hdrs = nfound
  if found == nil then
    nl.ring_why = 'no ring header near the record, ' .. tostring(np) .. ' prefixes swept'
    return nil
  end
  if nfound > 1 then
    nl.ring_why = tostring(nfound) .. ' candidate headers, so none is identified'
    return nil
  end
  g.hdr = found.hdr
  g.lo, g.hi, g.nrec = found.lo, found.hi, found.nrec
  -- Derive field offsets from the proved ring base before calculating writable records.
  g.ov, g.ox = found.ov, found.ox
  return g
end

function fftsa.nl._ring_hdr_ok(at, blk, j, g)
  local nl = fftsa.nl
  local v, s = g.val0, g.stride
  local w = function(off)
    local p = j + off
    if p + 3 <= string.len(blk) then return u32_at(blk, p) end
    return nl._wg(at + off)
  end
  local lo, hi = w(0), w(4)
  if lo == nil or hi == nil or hi <= lo then return nil end
  local span = hi - lo
  if math.mod(span, s) ~= 0 then return nil end
  local n = span / s
  if n < nl.RING_MIN or n > nl.RING_MAX then return nil end
  if v < lo or v >= hi then return nil end
  local ov = math.mod(v - lo, s)
  local ox = math.mod(ov + g.dx, s)
  if ov + 8 > s or ox + 8 > s then return nil end
  local old, wr, cnt = w(nl.HDR_OLD), w(nl.HDR_WRITE), w(nl.HDR_COUNT)
  if old == nil or wr == nil or cnt == nil then return nil end
  if old < lo or old >= hi or math.mod(old - lo, s) ~= 0 then return nil end
  if wr < lo or wr >= hi or math.mod(wr - lo, s) ~= 0 then return nil end
  if cnt < 1 or cnt > n then return nil end
  return { hdr = at, lo = lo, hi = hi, nrec = n, ov = ov, ox = ox }
end

function fftsa.nl.ring_header(g)
  local nl = fftsa.nl
  if g == nil or g.hdr == nil then return nil end
  local eho, ehw, ehc = nl.hdr_offs(g)
  return { lo = nl._wg(g.hdr), hi = nl._wg(g.hdr + 4),
           oldest = nl._wg(g.hdr + eho),
           write = nl._wg(g.hdr + ehw),
           count = nl._wg(g.hdr + ehc) }
end

-- Pixel fill: map the live ring's frequency slots, update Y values in place, and request
-- repaint without advancing the cursor. Appends continue until the map is proven.

fftsa.nl.PX_BUDGET = 262144

-- Give native scans their own byte and time budget rather than charging them as Lua reads.
fftsa.nl.PX_NMS = 0.030
fftsa.nl.PX_NBUDGET_MIN = 262144
-- Cap estimated throughput so a noisy fit cannot monopolize a frame.
fftsa.nl.PX_NBUDGET_MAX = 2097152
-- Ignore timings for slices too small to measure reliably.
fftsa.nl.PX_NB_SAMPLE = 65536
fftsa.nl.px_nbudget = 262144

function fftsa.nl.px_budget()
  local nl = fftsa.nl
  if nl.NFIND and nl.ready and nl.nfind ~= nil then
    return nl.px_nbudget or nl.PX_NBUDGET_MIN
  end
  return nl.PX_BUDGET
end

-- Estimate slice time as fixed overhead plus time per byte; use two sufficiently different sizes.
fftsa.nl.px_nb_a, fftsa.nl.px_nb_b = nil, nil     -- two (bytes, secs) samples, distinct sizes

function fftsa.nl.px_nb_note(bytes, secs)
  local nl = fftsa.nl
  if type(bytes) ~= 'number' or bytes < nl.PX_NB_SAMPLE then return end
  if type(secs) ~= 'number' or secs < 0 then return end
  local a = nl.px_nb_a
  if a == nil then
    nl.px_nb_a = { bytes, secs }
  elseif bytes > a[1] * 1.1 or bytes < a[1] * 0.9 then
    nl.px_nb_b = { bytes, secs }
  else
    nl.px_nb_a = { bytes, secs }
  end
  local b = nil
  local p, q = nl.px_nb_a, nl.px_nb_b
  if p ~= nil and q ~= nil and q[1] ~= p[1] then
    local dt, db = q[2] - p[2], q[1] - p[1]
    if db < 0 then
      db, dt = -db, -dt
    end
    if dt > 0 then
      local rate = db / dt
      local oh = p[2] - p[1] / rate
      if oh < 0 then oh = 0 end
      nl.px_nrate, nl.px_nover = rate, oh
      local room = nl.PX_NMS - oh
      if room <= 0 then
        b = nl.PX_NBUDGET_MIN
      else
        b = math.floor(room * rate)
      end
    end
  end
  if b == nil then
    -- Alternate slice sizes until there is enough data to fit the overhead and rate.
    local cur = nl.px_nbudget or nl.PX_NBUDGET_MIN
    if cur > nl.PX_NBUDGET_MIN then
      b = nl.PX_NBUDGET_MIN
    else
      b = nl.PX_NBUDGET_MIN * 2
    end
  end
  if b < nl.PX_NBUDGET_MIN then b = nl.PX_NBUDGET_MIN end
  if b > nl.PX_NBUDGET_MAX then b = nl.PX_NBUDGET_MAX end
  nl.px_nbudget = b
end
-- Leave oversized windows to the bounded backstop pass.
fftsa.nl.PX_WIN_MAX = 4194304
fftsa.nl.PX_WIN_CHEAP = 1048576
-- Require enough dB spread to distinguish the mapping from integer pixel quantization.
fftsa.nl.PX_SPAN_MIN = 20
fftsa.nl.PX_RESID_MAX = 1.5
-- Permit a small residual when comparing the firmware's quantized pixel to the fitted map.
fftsa.nl.PX_DRIFT_MAX = 3
fftsa.nl.PX_DRIFT_RUN = 5
fftsa.nl.PX_YMAX = 479
fftsa.nl.PX_PIX_MAX = 8191
-- Require a minimum fraction of usable inliers before accepting a fit.
fftsa.nl.PX_FIT_FRAC = 0.95
-- Require X to cross enough of the plotting area to distinguish it from a short Y run.
fftsa.nl.PX_DRAW_MIN = 128
fftsa.nl.PX_DRAW_RATIO = 4
-- Limit attempts to map any one candidate ring.
fftsa.nl.PX_MAP_TRIES = 8
fftsa.nl.PX_SLIP_MAX = 8
-- Wait for appends to refill the ring after dropping a previously engaged map.
fftsa.nl.PX_HOLD = 4
-- Tolerate transient cursor-command refusals before dropping the fast path.
fftsa.nl.PX_CURSOR_RUN = 5

fftsa.nl.px = { state = 'idle' }

-- Track initial engagement separately from re-engagement after a restart.
fftsa.nl.t_first, fftsa.nl.pre_frames = nil, 0
fftsa.nl.eng_secs, fftsa.nl.eng_frames = nil, nil
fftsa.nl.eng_last, fftsa.nl.eng_lastf = nil, nil

function fftsa.nl.px_engaged()
  local nl = fftsa.nl
  if nl.t_first == nil then return end
  local el = os.clock() - nl.t_first
  local fr = nl.pre_frames or 0
  if nl.eng_secs == nil then
    nl.eng_secs, nl.eng_frames = el, fr
  end
  nl.eng_last, nl.eng_lastf = el - (nl.t_restart_el or 0), fr - (nl.pre_at_restart or 0)
end

function fftsa.nl.px_clear()
  local p = fftsa.nl.px
  p.g, p.idx, p.ytab, p.yb, p.T = nil, nil, nil, nil, nil
  p.ay, p.by, p.nrec, p.lo, p.hdr, p.stride = nil, nil, nil, nil, nil, nil
  p.yoff, p.xoff, p.ov, p.ox, p.nseg = nil, nil, nil, nil, nil
  p.resid, p.span, p.hz1, p.hz2 = nil, nil, nil, nil
  p.drift, p.slot, p.slotdb, p.maptries = 0, nil, nil, 0
  p.slotprev = nil
  p.xcol, p.cands, p.curfail = nil, nil, 0
  p.slicehits, p.slicefrom = nil, nil
  p.cachetries = 0
  -- Discard the route and native write block with the geometry they describe.
  p.via, p.from = nil, nil
  p.nat, p.nat_why, p.natwrote = false, nil, nil
end

-- Keep the last drop reason through search retries; clear it on engagement.
function fftsa.nl.px_ptr_ok()
  fftsa.nl.px.ptrtries = 0
end

function fftsa.nl.px_off(why)
  local nl = fftsa.nl
  nl.px_clear()
  nl.px.state = 'off'
  nl.px.why = why
  return nil
end

function fftsa.nl.px_dropframe(why)
  fftsa.nl.px.whyframe = why
  return fftsa.nl.px_restart(why)
end

-- A wait keeps the candidate and budget state; a restart discards the current search.
function fftsa.nl.px_wait(why)
  local nl = fftsa.nl
  nl.px.state = 'idle'
  nl.px.why = why
  nl.px.waits = (nl.px.waits or 0) + 1
  return nil
end

function fftsa.nl.px_restart(why)
  local nl = fftsa.nl
  local laps = nl.px.restarts
  local drew = nl.px.state == 'on'
  nl.px_clear()
  nl.px.state = 'idle'
  nl.px.why = why
  nl.px.restarts = (laps or 0) + 1
  nl.px.re_prev = nl.px.re_last
  nl.px.re_last = why
  if nl.t_first ~= nil then
    nl.t_restart_el = os.clock() - nl.t_first
    nl.pre_at_restart = nl.pre_frames or 0
  end
  nl.px.hold = 0
  if drew then nl.px.hold = nl.PX_HOLD end
  nl.px.wins, nl.px.wi, nl.px.at = nil, nil, nil
  -- Keep the once-per-session backstop result, but reset per-pass cursors and pending hits.
  nl.px.nhall = (nl.px.nhall or 0) + (nl.px.namehits or 0)
  nl.px.noname, nl.px.namehits, nl.px.ncand = nil, 0, 0
  nl.px.sweptpass = 0
  nl.px_subfinds = 0
  nl.px.subwait = 0
  nl.px_subwin = nil
  nl.sub_hitlist, nl.sub_hitat, nl.sub_hitround = nil, nil, nil
  return nil
end

-- Resolve name hits to plausible trace bounds, then validate geometry against the current axis.
fftsa.nl.PX_NAME = 'FFTSA_TRACE'
fftsa.nl.PX_NAME_SCAN = 1024

-- A bounds pair can admit multiple strides; read the neighborhood once and return candidates.
function fftsa.nl.px_from_name(at)
  local nl = fftsa.nl
  local out, nout = {}, 0
  -- Align the read independently of the byte offset where the name matched.
  if type(at) ~= 'number' or at <= 0 or math.mod(at, 4) ~= 0 then return out end
  local blo, bhi = nl.BACKSTOP_LO, nl.BACKSTOP_HI
  if blo == nil or bhi == nil or blo >= bhi then blo, bhi = 0, nl.DRAM_END end
  if at < blo then return out end
  local want = nl.PX_NAME_SCAN + nl.HDR_COUNT + 4
  if at + want > bhi then want = bhi - at end
  if want < 8 then return out end
  local blk = ki.memread(hx(at), hx(want))
  nl.rd_note(want)
  if blk == nil then return out end
  local got = string.len(blk)
  local w = function(off)
    if off < 0 or off + 4 > got then return nil end
    return u32_at(blk, off + 1)
  end
  local o
  for o = 0, nl.PX_NAME_SCAN, 4 do
    local h = at + o
    local lo, hi = w(o), w(o + 4)
    if lo ~= nil and hi ~= nil and hi > lo then
      local span = hi - lo
      -- An inline ring must sit after its own bounds fields, in the same trace object.
      if lo > h and lo - h < nl.PX_NAME_SCAN and math.mod(span, 4) == 0 then
        local sv
        for sv = nl.REC_MIN, nl.REC_MAX, 4 do
          if math.mod(span, sv) == 0 then
            local n = span / sv
            if n >= nl.RING_MIN and n <= nl.RING_MAX then
              local ho, hw, hc = nl.HDR_OLD, nl.HDR_WRITE, nl.HDR_COUNT
              local rd = function(x) return w(o + x) end
              -- On deriving models, defer the cursor choice until the append proves it.
              local pend = nil
              if nl.PX_HDR_DERIVE then
                local cands, pairs = nl.px_hdr_roles(rd, lo, hi, sv, n)
                if cands ~= nil then
                  hc, pend = cands, pairs
                  ho, hw = nil, nil
                end
              end
              if nl.PX_HDR_CHECK or (nl.PX_HDR_DERIVE and pend == nil) then
                local do_, dw, dc = nl.px_hdr_derive(rd, lo, hi, sv, n)
                if do_ == nil then
                  nl.hdr_differ = nl.hdr_differ + 1
                  nl.hdr_why = tostring(dw)
                else
                  if do_ == nl.HDR_OLD and dw == nl.HDR_WRITE and dc == nl.HDR_COUNT then
                    nl.hdr_agree = nl.hdr_agree + 1
                    nl.hdr_why = nil
                  else
                    nl.hdr_differ = nl.hdr_differ + 1
                    nl.hdr_why = string.format('derived %d/%d/%d, constants %d/%d/%d',
                                               do_, dw, dc, nl.HDR_OLD, nl.HDR_WRITE,
                                               nl.HDR_COUNT)
                  end
                  if nl.PX_HDR_DERIVE then ho, hw, hc = do_, dw, dc end
                end
              end
              if pend ~= nil then
                local cnt = w(o + hc)
                if cnt ~= nil and cnt >= 1 and cnt <= n then
                  nout = nout + 1
                  out[nout] = { lo = lo, hi = hi, nrec = n, stride = sv, hdr = h,
                                name_at = at, name_off = o,
                                h_cnt = hc, h_pairs = pend }
                end
              else
                local old = w(o + ho)
                local wr = w(o + hw)
                local cnt = w(o + hc)
                if old ~= nil and wr ~= nil and cnt ~= nil
                   and old >= lo and old < hi and math.mod(old - lo, sv) == 0
                   and wr >= lo and wr <= hi and math.mod(wr - lo, sv) == 0
                   and cnt >= 1 and cnt <= n then
                  nout = nout + 1
                  out[nout] = { lo = lo, hi = hi, nrec = n, stride = sv, hdr = h,
                                name_at = at, name_off = o,
                                h_old = ho, h_wr = hw, h_cnt = hc }
                end
              end
            end
          end
        end
        if nout > 0 then return out end
      end
    end
  end
  return out
end

-- Pointer route: follow a display object entry to its widget and require a trace with our buffer name.
fftsa.nl.PX_TRACE_NAME  = 8          -- 0x08, buffer name, 32 bytes
fftsa.nl.PX_TRACE_BNDS  = 496        -- 0x1F0, ring base and end
fftsa.nl.PX_GRAPH_TRACE = 1004       -- 0x3EC, the widget's null-terminated trace array
fftsa.nl.PX_OBJ_STRIDE  = 608        -- 0x260, GUI object table stride
-- Read the widget pointer at its field offset, not from the first entry word.
fftsa.nl.PX_OBJ_WIDGET  = 80         -- 0x50, the widget pointer inside a table entry

-- Subscriber route: match the trace buffer name, follow the widget's routing pointer,
-- and require the trace to point back at both the widget and the subscription slot.
fftsa.nl.PX_SUB = true
-- First subscriber window on DMM6500. A matching name still needs the full pointer proof.
fftsa.nl.PX_SUB_LO    = 14024704     -- 0x00D60000, the DMM6500
fftsa.nl.PX_SUB_BYTES = 65536        -- 64 KB
-- First subscriber window on DMM7510; the same name and pointer checks apply.
fftsa.nl.PX_SUB_LO_7510 = 5308416    -- 0x00510000
-- If the model allows it, widen the subscriber search in bounded, resumable windows.
fftsa.nl.PX_SUB_DERIVE = false
fftsa.nl.PX_SUB_LADDER = false
-- A different kind may be tried only when the relaxed profile still proves the entire chain.
fftsa.nl.PX_SUB_ANYKIND = false
fftsa.nl.PX_SUB_STEP  = 1048576      -- 1 MB a frame
fftsa.nl.PX_SUB_FROM  = 1048576      -- 0x00100000, clear of .text's start
fftsa.nl.PX_SUB_TO    = 16777216     -- 0x01000000, the 6500's heap floor and well past .bss
fftsa.nl.PX_SUB_KIND  = 16511        -- 0x407F, a graph-trace subscription
fftsa.nl.PX_SUB_NAME  = 8            -- 0x08, the name within a slot
fftsa.nl.PX_SUB_GRAPH = 52           -- 0x34, the graph widget
fftsa.nl.PX_SUB_P4    = 64           -- 0x40, the ADDRESS of the widget's routing element
-- The routing pointer must refer to an aligned element inside the widget's routing array.
fftsa.nl.PX_ROUTE_LO  = 1176         -- 0x498
fftsa.nl.PX_ROUTE_HI  = 1332         -- 0x534
fftsa.nl.PX_TR_GRAPH  = 0            -- trace+0x00, the trace's own graph back-pointer
fftsa.nl.PX_TR_SUB    = 48           -- trace+0x30, the subscription handle: the slot address
-- Bound the name hits to adjudicate; another record can contain the same buffer name.
fftsa.nl.PX_SUB_HITS  = 12
-- Cache the slot and revalidate it on reuse instead of re-reading the whole window.
fftsa.nl.PX_SUB_FINDS = 32
-- Budget per-call pointer reads independently of the subscriber window read.
fftsa.nl.PX_SUB_JUDGE = 16
-- Give a known slot time to fill its ring before falling back to a scan.
fftsa.nl.PX_SUB_WAIT = 24

-- A freed slot can retain its name: confirm the subscription kind and pointers.
function fftsa.nl.px_sub_slot()
  local nl = fftsa.nl
  local want = nl.PX_NAME .. string.char(0)
  if nl.px_subslot ~= nil then
    -- Recheck a cached slot against the kind it was accepted with.
    local wantk = nl.sub_kind or nl.PX_SUB_KIND
    if nl._wg(nl.px_subslot) == wantk then return nl.px_subslot end
    nl.px_subslot, nl.sub_trace = nil, nil
    nl.sub_why = 'the slot stopped reading as the kind it was found with'
  end
  -- Finish pending hits before fetching the next window.
  if nl.sub_hitlist ~= nil then return nl.px_sub_judge() end
  -- A bounded subscriber-window read has its own budget.
  nl.px_subfinds = (nl.px_subfinds or 0) + 1
  if nl.px_subfinds > nl.PX_SUB_FINDS then
    nl.sub_why = 'the name is not in the window, ' .. tostring(nl.PX_SUB_FINDS)
                 .. ' reads spent'
    return nil
  end
  -- Try the model's window first, then resume the ladder one window at a time.
  local wlo, wn = nl.PX_SUB_LO, nl.PX_SUB_BYTES
  if nl.px_subwin ~= nil then
    if not nl.PX_SUB_LADDER then
      nl.sub_why = 'the name is not in the compiled window'
      return nil
    end
    wlo, wn = nl.px_subwin, nl.PX_SUB_STEP
    if wlo >= nl.PX_SUB_TO then
      nl.sub_why = 'the ladder is spent: no name anywhere in the static region'
      return nil
    end
  end
  nl.sub_at = wlo
  local blob = nil
  local ok = pcall(function()
    blob = ki.memread(hx(wlo), hx(wn))
  end)
  nl.rd_note(wn)
  if nl.px_subwin == nil then
    nl.px_subwin = nl.PX_SUB_FROM
  else
    nl.px_subwin = wlo + wn
  end
  if not ok or type(blob) ~= 'string' then
    nl.sub_why = 'the read at ' .. hx(wlo) .. ' was refused'
    return nil
  end
  nl.sub_len, nl.sub_want = string.len(blob), wn
  -- Try exact-kind hits before weaker candidates and validate either against the same routing chain.
  local at, seen = 1, 0
  local hits, nh = {}, 0
  nl.sub_hits = nl.sub_hits or 0
  while seen < nl.PX_SUB_HITS do
    local f = string.find(blob, want, at, true)
    if f == nil then break end
    seen = seen + 1
    at = f + 1
    nh = nh + 1
    hits[nh] = wlo + f - 1
    nl.sub_hits = (nl.sub_hits or 0) + 1
    if nl.sub_first == nil then nl.sub_first = hits[nh] end
  end
  nl.sub_wincap = seen >= nl.PX_SUB_HITS
  nl.sub_hitlist, nl.sub_hitat, nl.sub_hitround = hits, 1, 1
  return nl.px_sub_judge()
end

-- Resume hit adjudication at the last examined candidate.
function fftsa.nl.px_sub_judge()
  local nl = fftsa.nl
  local hits = nl.sub_hitlist
  if hits == nil then return nil end
  local nh = table.getn(hits)
  -- Scan alternate slot offsets only when the profile allows deriving the layout.
  local offs = nl.PX_SUB_NAMEOFFS
  if not nl.PX_SUB_DERIVE then offs = { nl.PX_SUB_NAME } end
  local noffs = table.getn(offs)
  local nread = 0
  while nl.sub_hitround <= 2 do
    if nl.sub_hitround == 2 and not nl.PX_SUB_ANYKIND then break end
    while nl.sub_hitat <= nh do
      if nread > 0 and (nread + noffs) > nl.PX_SUB_JUDGE then
        nl.sub_why = 'hit ' .. tostring(nl.sub_hitat) .. ' of ' .. tostring(nh)
                     .. ' still to try in round ' .. tostring(nl.sub_hitround)
        return nil
      end
      local na = hits[nl.sub_hitat]
      local d
      for d = 1, noffs do
        local slot = na - offs[d]
        local kw = nil
        if slot > 0 and math.mod(slot, 4) == 0 then
          kw = nl._wg(slot)
          nread = nread + 1
        end
        local livekind = kw == nl.PX_SUB_KIND
        if nl.sub_hitround == 2 and (not livekind) and kw ~= nil and kw ~= 0
           and kw ~= 4294967294 and kw < nl.DRAM_END then
          livekind = true
        end
        if livekind then
          nl.px_subslot = slot
          nl.sub_nameoff = offs[d]
          nl.sub_kind = kw
          nl.sub_loose = nl.sub_hitround == 2
          nl.sub_why = nil
          nl.sub_hitlist, nl.sub_hitat, nl.sub_hitround = nil, nil, nil
          return slot
        end
      end
      nl.sub_hitat = nl.sub_hitat + 1
    end
    nl.sub_hitround = nl.sub_hitround + 1
    nl.sub_hitat = 1
  end
  -- Keep one rejected neighborhood and its hit address for diagnostics.
  if nl.sub_map == nil and nh > 0 then nl.sub_map = nl.px_sub_dump(hits[nh]) end
  nl.sub_why = tostring(nl.sub_hits) .. ' name hit(s) through ' .. hx(nl.px_subwin)
               .. ', none a live graph trace'
  nl.sub_hitlist, nl.sub_hitat, nl.sub_hitround = nil, nil, nil
  return nil
end

fftsa.nl.PX_SUB_NAMEOFFS = { 8, 12, 16, 4, 20, 24, 32, 40, 48, 52, 56, 64 }

fftsa.nl.PX_SUB_DUMP = 10
function fftsa.nl.px_sub_dump(na)
  local nl = fftsa.nl
  nl.sub_mapat = na
  local out, n = '', 0
  local d
  for d = -64, 192, 4 do
    if n >= nl.PX_SUB_DUMP then break end
    local a = na + d
    if a > 0 and math.mod(a, 4) == 0 then
      local w = nl._wg(a)
      if w ~= nil and w > 65536 and w < nl.DRAM_END then
        n = n + 1
        out = out .. ' ' .. tostring(d) .. ':' .. hx(w)
      end
    end
  end
  return hx(na) .. out
end

-- Derive the graph and routing fields only when both lead to a named, readable trace.
fftsa.nl.PX_SUB_WALK = 128           -- bytes of a slot to consider, from 0
function fftsa.nl.px_sub_pairs(slot)
  local nl = fftsa.nl
  local want = nl.PX_NAME .. string.char(0)
  local at = nl.sub_walkat or 0
  while at <= nl.PX_SUB_WALK do
    local p4 = nl._wg(slot + at)
    at = at + 4
    if p4 ~= nil and p4 > 65536 and p4 < nl.DRAM_END and math.mod(p4, 4) == 0 then
      -- The slot stores the address of a widget routing entry, which holds the trace pointer.
      local k
      for k = 1, 2 do
        local t = p4
        -- A valid-looking pointer does not prove mapping; read the name and full trace neighborhood safely.
        if k == 2 then t = nl._rdw(p4) end
        if t ~= nil and t > 65536 and t < nl.DRAM_END and math.mod(t, 4) == 0 then
          local got = nil
          pcall(function()
            got = ki.memread(hx(t + nl.PX_TRACE_NAME), hx(string.len(want)))
          end)
          nl.rd_note(string.len(want))
          if got == want then
            nl.sub_walkat = 0
            nl.sub_p4off = at - 4
            nl.sub_levels = k
            nl.sub_trace_ok = t
            nl._map_age = nl.MAP_REFRESH
            nl.map_lo, nl.map_hi = nil, nil
            return t
          end
        end
      end
    end
    if nl.px_obj_over() then
      nl.sub_walkat = at
      return nil
    end
  end
  nl.sub_walkat = 0
  nl.sub_walkdone = true
  return nil
end

-- Follow the slot's widget and route to the trace, validating every link.
function fftsa.nl.px_from_bufsub()
  local nl = fftsa.nl
  if nl.PX_SUB == false then
    nl.sub_why = 'not attempted on this model'
    return {}
  end
  nl.sub_tries = (nl.sub_tries or 0) + 1
  local slot = nl.px_sub_slot()
  if slot == nil then return {} end
  local tr = nl.px_sub_fixed(slot)
  local fixed = tr ~= nil
  if tr == nil then
    -- Try deriving the slot's pointer fields only after the fixed-offset chain fails.
    if nl.PX_SUB_DERIVE and not nl.sub_walkdone then
      tr = nl.px_sub_pairs(slot)
      if tr ~= nil then nl.sub_derived = true end
    end
    if tr == nil then return {} end
  end
  local g = nl.px_from_trace(tr, fixed)
  if table.getn(g) == 0 then
    local cnt = nl._wg(tr + nl.PX_TRACE_BNDS + nl.HDR_COUNT)
    local tail = ' after ' .. tostring(nl.sub_tries) .. ' try/tries'
    if cnt == 0 then
      nl.sub_why = 'trace ' .. hx(tr) .. ' ring is empty' .. tail
    else
      nl.sub_why = 'trace ' .. hx(tr) .. ' ring count ' .. hxn(cnt) .. ', '
                   .. tostring(nl.ptr_why) .. tail
    end
    nl.sub_lastwhy = nl.sub_why
    return {}
  end
  local k
  for k = 1, table.getn(g) do
    g[k].via_ptr = true
    g[k].via_sub = true
  end
  nl.sub_why = nil
  nl.sub_trace = tr
  return g
end

-- Fixed subscriber route for the compiled layout; reject any broken back-reference.
function fftsa.nl.px_sub_fixed(slot)
  local nl = fftsa.nl
  local graph = nl._rdw(slot + nl.PX_SUB_GRAPH)
  local p4 = nl._rdw(slot + nl.PX_SUB_P4)
  if graph == nil or p4 == nil or graph <= 0 or p4 <= 0 then
    nl.sub_why = 'slot ' .. hx(slot) .. ' has no graph or no routing pointer'
    return nil
  end
  -- Before following the route pointer, prove it is inside the widget's routing array.
  if p4 < graph + nl.PX_ROUTE_LO or p4 > graph + nl.PX_ROUTE_HI
     or math.mod(p4, 4) ~= 0 then
    nl.sub_why = hxn(p4) .. ' is not inside the routing array of ' .. hxn(graph)
    return nil
  end
  -- Use a mapped read for a pointer read from firmware data.
  local tr = nl._rdw(p4)
  if tr == nil or tr == 0 then
    nl.sub_why = 'the routing element at ' .. hxn(p4) .. ' is ' .. tostring(tr)
    return nil
  end
  local back = nl._rdw(tr + nl.PX_TR_GRAPH)
  local sub = nl._rdw(tr + nl.PX_TR_SUB)
  if back ~= graph then
    nl.sub_why = 'trace ' .. hx(tr) .. ' names graph ' .. hxn(back) .. ', not ' .. hx(graph)
    return nil
  end
  if sub ~= slot then
    nl.sub_why = 'trace ' .. hx(tr) .. ' names subscription ' .. hxn(sub)
                 .. ', not ' .. hx(slot)
    return nil
  end
  -- Extend live bounds only after the named trace and its back-references agree.
  if nl.sub_trace_ok ~= tr then
    nl.sub_trace_ok = tr
    nl._map_age = nl.MAP_REFRESH
    nl.map_lo, nl.map_hi = nil, nil
  end
  return tr
end

-- GUI table bases are search hints, not proof. Validate the entry, widget and named trace.
fftsa.nl.PX_OBJTAB_HINTS = { 13727904, 13728736 }  -- DMM6500 GUI table candidates
-- Bound the walk of the null-terminated trace array.
fftsa.nl.PX_TRACE_MAX   = 8

-- Require both a readable trace object and the owning buffer's name.
function fftsa.nl.px_live(addr)
  local nl = fftsa.nl
  if type(addr) ~= 'number' or addr <= 0 or math.mod(addr, 4) ~= 0 then
    nl.live_why = 'not a 4-aligned address: ' .. tostring(addr)
    return false
  end
  local lo, hi = nl.map_bounds()
  if lo == nil then
    nl.live_why = 'no measured span: ' .. tostring(nl.map_why)
    return false
  end
  if addr >= lo and addr < hi then return true end
  nl.live_why = string.format('%s outside %s..%s', hx(addr), hx(lo), hx(hi))
  return false
end

-- A validated subscriber can locate the two inline draw banks; read and check both sets of bounds.
function fftsa.nl.px_from_banks(tr, at)
  local nl = fftsa.nl
  local stride, nrec = 56, 721
  local a, b = tr + 544, tr + 41424       -- inline banks at +0x220 and +0xA1D0
  local span = stride * nrec
  local hdr = tr + nl.PX_TRACE_BNDS
  local blo, bhi = nl.BACKSTOP_LO, nl.BACKSTOP_HI
  if blo == nil or bhi == nil or blo >= bhi then blo, bhi = 0, nl.DRAM_END end
  if hdr < blo or b + span > bhi then return nil end
  local h = ki.memread(hx(hdr), '20')     -- 32 bytes, including both pairs of bounds
  nl.rd_note(32)
  if h == nil or string.len(h) ~= 32 then return nil end
  local lo, hi = u32_at(h, 1), u32_at(h, 5)
  local alt = u32_at(h, 25)
  if not ((lo == a and alt == b) or (lo == b and alt == a))
     or hi ~= lo + span or u32_at(h, 29) ~= alt + span then return nil end
  local old, wr, cnt = u32_at(h, nl.HDR_OLD + 1), u32_at(h, nl.HDR_WRITE + 1),
                       u32_at(h, nl.HDR_COUNT + 1)
  if old < lo or old >= hi or math.mod(old - lo, stride) ~= 0
     or wr < lo or wr > hi or math.mod(wr - lo, stride) ~= 0
     or cnt < 1 or cnt > nrec then return nil end
  return { lo = lo, hi = hi, nrec = nrec, stride = stride, hdr = hdr,
           name_at = at, name_off = hdr - at,
           h_old = nl.HDR_OLD, h_wr = nl.HDR_WRITE, h_cnt = nl.HDR_COUNT }
end

function fftsa.nl.px_from_trace(tr, fixed_subscriber)
  local nl = fftsa.nl
  if type(tr) ~= 'number' or tr <= 0 or math.mod(tr, 4) ~= 0 then return {} end
  if not nl.px_live(tr) or not nl.px_live(tr + nl.PX_TRACE_NAME + 32) then
    nl.ptr_why = 'trace object not live: ' .. tostring(nl.live_why)
    return {}
  end
  local at = tr + nl.PX_TRACE_NAME
  local want = nl.PX_NAME .. string.char(0)
  local got = ki.memread(hx(at), hx(string.len(want)))
  if got ~= want then
    nl.ptr_why = 'trace at ' .. hx(tr) .. ' does not carry this buffer name'
    return {}
  end
  if fixed_subscriber and not nl.model_7510 and not nl.PX_HDR_DERIVE then
    local g = nl.px_from_banks(tr, at)
    if g ~= nil then return {g} end
  end
  return nl.px_from_name(at)
end

-- Walk the widget's trace array until a null pointer or the configured limit.
function fftsa.nl.px_from_graph(gr)
  local nl = fftsa.nl
  if type(gr) ~= 'number' or gr <= 0 then
    nl.ptr_why = 'widget pointer is ' .. tostring(gr)
    return {}
  end
  if not nl.px_live(gr) or not nl.px_live(gr + nl.PX_GRAPH_TRACE + 4 * nl.PX_TRACE_MAX) then
    nl.ptr_why = 'widget not live: ' .. tostring(nl.live_why)
    return {}
  end
  local i
  for i = 0, nl.PX_TRACE_MAX - 1 do
    local tr = nl._wg(gr + nl.PX_GRAPH_TRACE + i * 4)
    if tr == nil or tr == 0 then
      nl.ptr_why = 'trace slot ' .. tostring(i) .. ' of the widget is '
                   .. tostring(tr) .. ', and none before it carried the name'
      return {}
    end
    local g = nl.px_from_trace(tr)
    if table.getn(g) > 0 then
      local k
      for k = 1, table.getn(g) do g[k].via_ptr = true end
      return g
    end
  end
  return {}
end

-- Start with the table base that last confirmed this app's trace.
function fftsa.nl.px_bases()
  local nl = fftsa.nl
  local out, n = {}, 0
  if nl.px_objbase ~= nil then
    n = n + 1
    out[n] = nl.px_objbase
  end
  local hs = nl.PX_OBJTAB_HINTS
  if type(hs) == 'table' then
    local i
    for i = 1, table.getn(hs) do
      if type(hs[i]) == 'number' and hs[i] > 0 and hs[i] ~= nl.px_objbase then
        n = n + 1
        out[n] = hs[i]
      end
    end
  end
  return out
end

-- Try the graph handle first, then other entries; the handle need not be the table index.
fftsa.nl.PX_OBJ_SCAN = 128

-- Give the table walk only a share of frame reads so other discovery still runs.
fftsa.nl.PX_OBJ_CALLS = 16

function fftsa.nl.px_obj_over()
  local nl = fftsa.nl
  return (nl._rd_calls or 0) >= nl.PX_OBJ_CALLS or nl.rd_over()
end

function fftsa.nl.px_entry(base, id)
  local nl = fftsa.nl
  local gr = nl._wg(base + id * nl.PX_OBJ_STRIDE + nl.PX_OBJ_WIDGET)
  if gr == nil or gr == 0 then return {} end
  return nl.px_from_graph(gr)
end

-- Resume one cursor over candidate table bases and entry IDs; revalidate the resulting trace.
function fftsa.nl.px_from_ptr(gid)
  local nl = fftsa.nl
  local p = nl.px
  if nl.PX_PTR == false then return {} end
  local bs = nl.px_bases()
  local nb = table.getn(bs)
  if nb == 0 then return {} end
  local i
  for i = 1, nb do
    if type(gid) == 'number' and gid >= 0 then
      local g = nl.px_entry(bs[i], gid)
      if table.getn(g) > 0 then
        p.objscan = 0
        nl.px_objbase, nl.px_objid = bs[i], gid
        return g
      end
    end
    if nl.px_obj_over() then return {} end
  end
  local at = p.objscan or 0
  local total = nb * nl.PX_OBJ_SCAN
  while at < total do
    local bi = math.floor(at / nl.PX_OBJ_SCAN) + 1
    local id = math.mod(at, nl.PX_OBJ_SCAN)
    at = at + 1
    if id ~= gid then
      local g = nl.px_entry(bs[bi], id)
      if table.getn(g) > 0 then
        p.objscan = 0
        nl.px_objbase, nl.px_objid = bs[bi], id
        nl.px_objfound = 'id ' .. tostring(id) .. ' not the handle ' .. tostring(gid)
        return g
      end
    end
    if nl.px_obj_over() then
      p.objscan = at
      return {}
    end
  end
  p.objscan = 0
  p.objdone = true
  return {}
end

-- The pointer route uses configured table hints only. If they fail, use other discovery routes.

-- Search around the last confirmed ring before widening.
fftsa.nl.PX_SEED_NEAR = 4194304
fftsa.nl.PX_SEED_SPAN_MAX = 16777216
-- Limit bytes spent looking for the name before switching to a frequency needle.
fftsa.nl.PX_NAME_GIVEUP = 16777216
-- Bound rejected name hits per pass and per slice; freed traces can retain the same name.
fftsa.nl.PX_NAME_FAIL = 64
fftsa.nl.PX_HITS_PER_SLICE = 64
-- Give pointer and cached geometry a bounded retry window while appends fill the ring.
fftsa.nl.PX_CACHE_TRIES = 8

-- Repoint a validated series in place when FFT length changes its column frequencies.
fftsa.nl.PX_REPOINT = true

-- Try sub-windows relative to the current buffer instance before broad heap windows.
-- This orders the search only; the candidate still needs independent confirmation.
fftsa.nl.PX_INST_WIN = true
fftsa.nl.PX_INST_BANDS = { { -2097152, 2097152 }, { 2097152, 6291456 }, { 6291456, 8388608 } }

function fftsa.nl.px_inst_wins()
  local nl = fftsa.nl
  local out, n = {}, 0
  if not nl.PX_INST_WIN then return out end
  local a = nl.inst
  if type(a) ~= 'number' or a <= 0 then return out end
  local i
  for i = 1, table.getn(nl.PX_INST_BANDS) do
    local lo = a + nl.PX_INST_BANDS[i][1]
    local hi = a + nl.PX_INST_BANDS[i][2]
    if lo < 0 then lo = 0 end
    if hi > lo then
      n = n + 1
      out[n] = { lo, hi }
    end
  end
  return out
end

function fftsa.nl.px_seed()
  local c = fftsa.nl.px_cache_get()
  if c == nil or type(c.lo) ~= 'number' or c.lo <= 0 then return nil end
  return c.lo
end

function fftsa.nl.px_windows(buf)
  local nl = fftsa.nl
  local blo, bhi = nl.BACKSTOP_LO, nl.BACKSTOP_HI
  if blo == nil or bhi == nil or blo >= bhi then blo, bhi = 0, nl.DRAM_END end
  local out, n = {}, 0
  local add = function(x, y)
    local w = nl._clamp_win(x, y, blo, bhi)
    if w == nil then return end
    local i
    for i = 1, n do
      if out[i][1] == w[1] and out[i][2] == w[2] then return end
    end
    n = n + 1
    out[n] = w
  end
  local slo, shi = nl.px_seed_learned()
  if slo ~= nil and shi - slo <= nl.PX_SEED_SPAN_MAX then
    add(slo - nl.PX_SEED_NEAR, shi + nl.PX_SEED_NEAR)
  end
  local seed = nl.px_seed()
  if seed ~= nil then
    add(seed, seed + nl.PX_SEED_NEAR)
    add(seed - nl.PX_SEED_NEAR, seed)
  end
  local all = nl.scan_windows(buf, nil)
  local i
  for i = 1, table.getn(all) do
    if all[i][2] - all[i][1] <= nl.PX_WIN_MAX then add(all[i][1], all[i][2]) end
  end
  local iw = nl.px_inst_wins()
  local ii
  for ii = 1, table.getn(iw) do add(iw[ii][1], iw[ii][2]) end
  add(blo, bhi)
  -- Try cheap windows before widening to the validated heap span.
  local cheap, band, rest = {}, {}, {}
  local nc2, nb2, nr2 = 0, 0, 0
  local inband = function(w)
    local k
    for k = 1, table.getn(iw) do
      if iw[k][1] == w[1] and iw[k][2] == w[2] then return true end
    end
    return false
  end
  for i = 1, n do
    local w = out[i]
    if w[2] - w[1] <= nl.PX_WIN_CHEAP then
      nc2 = nc2 + 1
      cheap[nc2] = w
    elseif inband(w) then
      nb2 = nb2 + 1
      band[nb2] = w
    else
      nr2 = nr2 + 1
      rest[nr2] = w
    end
  end
  local bywidth = function(a, b) return (a[2] - a[1]) < (b[2] - b[1]) end
  table.sort(cheap, bywidth)
  table.sort(rest, bywidth)
  local seq, ns = {}, 0
  local g
  for g = 1, 3 do
    local src = cheap
    if g == 2 then src = band end
    if g == 3 then src = rest end
    local k
    for k = 1, table.getn(src) do
      ns = ns + 1
      seq[ns] = src[k]
    end
  end
  return seq
end

-- Search one budgeted slice per frame. Try the buffer name, then frequency needles that
-- remain stable while the display is a frame behind. Keep all confirmed geometries.

-- Select a nonzero frequency needle; zero bytes are common in memory.
function fftsa.nl.px_xneedle(hz, nseg)
  if hz == nil or nseg == nil or nseg < 8 then return nil end
  local best, bestscore = nil, -1
  local j
  for j = 1, nseg - 3 do
    local p = f32_pack(hz[j])
    local score, k = 0, nil
    for k = 1, 4 do
      if string.byte(p, k) ~= 0 then score = score + 1 end
    end
    if hz[j] == hz[j + 1] or hz[j + 1] == hz[j + 2] or hz[j + 2] == hz[j + 3] then
      score = -1
    end
    if score > bestscore then best, bestscore = j, score end
  end
  if best == nil or bestscore < 1 then return nil end
  local xs, i = {}, nil
  for i = 1, 4 do xs[i] = f32_pack(hz[best + i - 1]) end
  return xs, best
end

-- Read four records together to check every possible stride against known frequencies.
function fftsa.nl.px_xconfirm_all(xat, xs)
  local nl = fftsa.nl
  local n = table.getn(xs)
  if type(xat) ~= 'number' or n < 2 then return {} end
  local blo, bhi = nl.BACKSTOP_LO, nl.BACKSTOP_HI
  if blo == nil or bhi == nil or blo >= bhi then blo, bhi = 0, nl.DRAM_END end
  if xat < blo then return {} end
  local want = (n - 1) * nl.REC_MAX + 8
  if xat + want > bhi then want = bhi - xat end
  if want < 8 then return {} end
  local blk = ki.memread(hx(xat), hx(want))
  nl.rd_note(want)
  if blk == nil then return {} end
  local got = string.len(blk)
  local out, nout = {}, 0
  local sv
  for sv = nl.REC_MIN, nl.REC_MAX, 4 do
    local span = (n - 1) * sv + 8
    if span <= got then
      local ok, i = true, nil
      for i = 1, n do
        local at = (i - 1) * sv + 1
        if string.sub(blk, at, at + 7) ~= xs[i] .. xs[i] then
          ok = false
          break
        end
      end
      if ok then
        nout = nout + 1
        out[nout] = { val0 = xat, stride = sv, dx = 0, nconf = n }
      end
    end
  end
  return out
end

function fftsa.nl.px_seek(hz, nseg, budget, buf)
  local nl = fftsa.nl
  local p = nl.px
  local out, nout = {}, 0
  -- Try pointer discovery before scanning. A matching table entry still needs a named trace.
  do
    local bysub = nl.px_from_bufsub()
    if table.getn(bysub) > 0 then
      p.via = 'sub'
      return bysub
    end
  end
  if nl.px_objbase ~= nil and p.gid ~= nil then
    local byptr = nl.px_from_ptr(p.gid)
    if table.getn(byptr) > 0 then
      p.via = 'ptr'
      return byptr
    end
    nl.px_objbase = nil
    p.ptr_lost = (p.ptr_lost or 0) + 1
  end
  -- First scan for the trace's name; if that fails, search for its frequency records.
  local n1 = nl.PX_NAME .. string.char(0)
  local byname, xs = true, nil
  -- Reset per-pass limits without discarding cumulative search diagnostics.
  if (not p.noname) and (p.sweptpass or 0) >= nl.PX_NAME_GIVEUP
     and (p.namehits or 0) == 0 then
    p.noname = true
    p.gaveup = (p.gaveup or 0) + 1
  end
  if (not p.noname) and (p.namehits or 0) >= nl.PX_NAME_FAIL
     and (p.ncand or 0) == 0 then
    p.noname = true
    p.gaveup = (p.gaveup or 0) + 1
    p.namedead = p.namehits
  end
  if p.noname then
    local j
    xs, j = nl.px_xneedle(hz, nseg)
    byname = false
    if xs == nil then
      p.degen = (p.degen or 0) + 1
      return out
    end
    p.xcol = j
    n1 = xs[1] .. xs[1]
  end
  if p.wins == nil then
    p.wins = nl.px_windows(buf)
    p.wi, p.at, p.swept = 1, p.wins[1][1], p.swept or 0
  end
  local left = budget
  while left > 0 and not nl.rd_over() do
    local w = p.wins[p.wi]
    if w == nil then
      p.wins, p.wi, p.at = nil, nil, nil
      p.laps = (p.laps or 0) + 1
      if (p.namehits or 0) == 0 then p.noname = true end
      return out
    end
    -- The broad backstop scan runs at most once per session.
    if w[2] - w[1] > nl.PX_WIN_MAX and p.backstop_done then
      p.wi = p.wi + 1
      p.at = nil
      if p.wins[p.wi] ~= nil then p.at = p.wins[p.wi][1] end
    elseif p.at == nil or p.at < w[1] or p.at + 8 > w[2] then
      if w[2] - w[1] > nl.PX_WIN_MAX and p.at ~= nil then p.backstop_done = true end
      p.wi = p.wi + 1
      p.at = nil
      if p.wins[p.wi] ~= nil then p.at = p.wins[p.wi][1] end
    else
      local lo = p.at
      local hi = lo + left
      if hi > w[2] then hi = w[2] end
      -- Adjudicate pending hits before reading another slice.
      local h, hfrom = p.slicehits, p.slicefrom or 1
      if h == nil then
        h, hfrom = nl.FINDS(lo, hi, n1), 1
        p.swept = p.swept + (hi - lo)
        p.sweptpass = (p.sweptpass or 0) + (hi - lo)
        left = left - (hi - lo)
        -- Overlap by the needle tail so a match can cross a slice boundary.
        p.at = hi - 7
      end
      local k, sv
      for k = hfrom, table.getn(h) do
        p.hits = (p.hits or 0) + 1
        if byname then
          p.namehits = (p.namehits or 0) + 1
          local gs = nl.px_from_name(h[k])
          local gi
          for gi = 1, table.getn(gs) do
            nout = nout + 1
            out[nout] = gs[gi]
          end
        else
          local gs = nl.px_xconfirm_all(h[k], xs)
          local gi
          for gi = 1, table.getn(gs) do
            nout = nout + 1
            out[nout] = gs[gi]
          end
        end
        if (k - hfrom + 1) >= nl.PX_HITS_PER_SLICE or nl.rd_over() then
          p.slicehits, p.slicefrom = h, k + 1
          p.hitcap = (p.hitcap or 0) + 1
          return out
        end
      end
      p.slicehits, p.slicefrom = nil, nil
      if nout > 0 then return out end
    end
  end
  return out
end

-- A pixel field repeats the same word three times in a record.
function fftsa.nl.px_triples_common(blk, nrec, stride, k)
  local step = math.floor(nrec / k)
  if step < 1 then step = 1 end
  local keep, s = nil, nil
  for s = 1, nrec, step do
    local tr = fftsa.nl.px_triples(string.sub(blk, (s - 1) * stride + 1, s * stride), stride)
    if keep == nil then
      keep = tr
    else
      local both, n, i, j = {}, 0, nil, nil
      for i = 1, table.getn(keep) do
        for j = 1, table.getn(tr) do
          if keep[i] == tr[j] then
            n = n + 1
            both[n] = keep[i]
          end
        end
      end
      keep = both
    end
    if table.getn(keep) == 0 then return keep end
  end
  if keep == nil then keep = {} end
  return keep
end

function fftsa.nl.px_triples(rec, stride)
  local out, n, prev = {}, 0, nil
  local o
  for o = 0, stride - 12, 4 do
    local a = u32_at(rec, o + 1)
    if a == u32_at(rec, o + 5) and a == u32_at(rec, o + 9) then
      if prev == nil or o - prev > 8 then
        n = n + 1
        out[n] = o
      end
      prev = o
    end
  end
  return out
end

-- Center the least-squares fit and require enough inliers within the pixel tolerance.
function fftsa.nl.px_fit(ys, xs, n, tol)
  local sx, sy, m = 0, 0, 0
  local xlo, xhi = nil, nil
  local s
  for s = 1, n do
    if xs[s] ~= nil and ys[s] ~= nil then
      sx = sx + xs[s]
      sy = sy + ys[s]
      m = m + 1
      if xlo == nil or xs[s] < xlo then xlo = xs[s] end
      if xhi == nil or xs[s] > xhi then xhi = xs[s] end
    end
  end
  if m < 8 or xlo == nil or xhi <= xlo then return nil end
  local mx, my = sx / m, sy / m
  local sxx, sxy = 0, 0
  for s = 1, n do
    if xs[s] ~= nil and ys[s] ~= nil then
      local dx = xs[s] - mx
      sxx = sxx + dx * dx
      sxy = sxy + dx * (ys[s] - my)
    end
  end
  if sxx <= 0 then return nil end
  local a = sxy / sxx
  local b = my - a * mx
  local worst, nin = 0, 0
  for s = 1, n do
    if xs[s] ~= nil and ys[s] ~= nil then
      local e = a * xs[s] + b - ys[s]
      if e < 0 then e = -e end
      if e > worst then worst = e end
      if tol == nil or e <= tol then nin = nin + 1 end
    end
  end
  return a, b, worst, xhi - xlo, m, nin
end

function fftsa.nl.px_words(blk, nrec, stride, o)
  local out, s, hi = {}, nil, fftsa.nl.PX_PIX_MAX
  for s = 1, nrec do
    local w = u32_at(blk, (s - 1) * stride + o + 1)
    if w <= hi then out[s] = w end
  end
  return out
end

function fftsa.nl.px_floats(blk, nrec, stride, o)
  local out, s = {}, nil
  for s = 1, nrec do
    out[s] = f32_unpack(blk, (s - 1) * stride + o + 1)
  end
  return out
end

-- Map the drawn window, not every allocated slot. A frequency slot must match exactly as
-- float32, and X and Y fields must prove separate affine maps before a write is enabled.
function fftsa.nl.px_map(g, hz, nseg)
  local nl = fftsa.nl
  local p = nl.px
  p.why = nil
  if g == nil or g.lo == nil or g.hi == nil or g.nrec == nil or g.hdr == nil then
    p.why = 'no ring geometry to map'
    return false
  end
  local stride, ox = g.stride, g.ox
  if stride == nil or stride < nl.REC_MIN then
    p.why = 'record stride ' .. tostring(stride) .. ' is not usable'
    return false
  end
  if ox ~= nil and ox + 8 > stride then
    p.why = 'x field at ' .. tostring(ox) .. ' does not fit a ' .. tostring(stride)
            .. '-byte record'
    return false
  end
  local gho, ghw, ghc = nl.hdr_offs(g)
  local lo = nl._wg(g.hdr + gho)
  local cnt = nl._wg(g.hdr + ghc)
  if lo == nil or cnt == nil or cnt < nl.RING_MIN or cnt > g.nrec then
    p.why = 'header count ' .. tostring(cnt) .. ' is not 8..' .. tostring(g.nrec)
    return false
  end
  if lo < g.lo or lo + cnt * stride > g.hi or math.mod(lo - g.lo, stride) ~= 0 then
    p.why = 'the drawn window ' .. hx(lo) .. '+' .. tostring(cnt)
            .. ' is not inside the ring'
    return false
  end
  local span = cnt * stride
  -- Prove the entire block writable before updating any records.
  local blo, bhi = nl.BACKSTOP_LO, nl.BACKSTOP_HI
  if blo == nil or bhi == nil or blo >= bhi then blo, bhi = 0, nl.DRAM_END end
  if lo < blo or lo + span > bhi then
    p.why = 'window ' .. hx(lo) .. '+' .. tostring(span) .. ' is outside the backstop'
    return false
  end
  local blk = ki.memread(hx(lo), hx(span))
  nl.rd_note(span)
  if blk == nil or string.len(blk) ~= span then
    p.why = 'window read gave ' .. tostring(blk ~= nil and string.len(blk) or 0)
            .. ' of ' .. tostring(span)
    return false
  end

  local key, j = {}, nil
  for j = 1, nseg do key[f32_pack(hz[j])] = j end

  -- Derive the frequency field if the discovery route did not identify it.
  if ox == nil then
    local o, s2
    for o = 0, stride - 4, 4 do
      local all = true
      for s2 = 1, cnt do
        local b2 = (s2 - 1) * stride
        if key[string.sub(blk, b2 + o + 1, b2 + o + 4)] == nil then
          all = false
          break
        end
      end
      if all then
        ox = o
        break
      end
    end
    if ox == nil then
      p.why = 'no field in a ' .. tostring(stride) .. '-byte record holds this plan'
              .. ' frequency in all ' .. tostring(cnt) .. ' slots'
      return false
    end
    g.ox = ox
  end
  local idx, miss, s, xv = {}, 0, nil, {}
  for s = 1, cnt do
    local base = (s - 1) * stride
    local k = key[string.sub(blk, base + ox + 1, base + ox + 4)]
    if k == nil then
      miss = miss + 1
    else
      idx[s] = k
      xv[s] = hz[k]
    end
  end
  if miss > 0 then
    p.why = tostring(miss) .. ' of ' .. tostring(cnt)
            .. ' slots carry a frequency this plan does not have'
    return false
  end

  -- Fit the X pixel triple against the frequency stored in the same record.
  local need = nl.PX_FIT_FRAC * cnt
  local tr = nl.px_triples_common(blk, cnt, stride, 8)
  local xoff, yoff, nleft = nil, nil, 0
  local xa, xb = nil, nil
  local best, second = 0, 0
  local rep, i = '', nil
  for i = 1, table.getn(tr) do
    local ws = nl.px_words(blk, cnt, stride, tr[i])
    local a, b, w, sp, m, nin = nl.px_fit(ws, xv, cnt, nl.PX_RESID_MAX)
    if a == nil then
      rep = rep .. ' ' .. tostring(tr[i]) .. ':flat'
    else
      -- Require the fitted X line to span the plot rather than a nearly constant field.
      local rng = a * sp
      if rng < 0 then rng = -rng end
      rep = rep .. string.format(' %d:in%d/%d/%.0fpx', tr[i], nin, m, rng)
      if nin >= need and rng > best then
        second = best
        best = rng
        xoff = tr[i]
        xa, xb = a, b
      elseif rng > second then
        second = rng
      end
    end
  end
  if xoff == nil or best < nl.PX_DRAW_MIN or best < nl.PX_DRAW_RATIO * second then
    p.why = 'the x pixel is not identified at ' .. hx(lo) .. '/' .. tostring(stride)
            .. ', triples vs frequency --' .. rep
    return false
  end
  for i = 1, table.getn(tr) do
    if tr[i] ~= xoff then
      nleft = nleft + 1
      yoff = tr[i]
    end
  end
  if nleft ~= 1 then
    p.why = tostring(nleft) .. ' triples left after the x pixel at ' .. tostring(xoff)
            .. ', need exactly 1 --' .. rep
    return false
  end

  -- Identify the value field by its affine fit to the Y triple, excluding the frequency field.
  local yw = nl.px_words(blk, cnt, stride, yoff)
  local ov, ay, by, resid, dbspan = nil, nil, nil, nil, nil
  local o
  for o = 0, stride - 8, 4 do
    if o ~= ox and string.sub(blk, o + 1, o + 4) == string.sub(blk, o + 5, o + 8) then
      local vs = nl.px_floats(blk, cnt, stride, o)
      local a, b, w, sp, m, nin = nl.px_fit(yw, vs, cnt, nl.PX_RESID_MAX)
      local rng = nil
      if a ~= nil then
        rng = a * sp
        if rng < 0 then rng = -rng end
      end
      if a ~= nil and nin >= need and sp >= nl.PX_SPAN_MIN
         and rng >= nl.PX_SPAN_MIN then
        if ov ~= nil then
          p.why = 'the value field is ambiguous: ' .. tostring(ov) .. ' and ' .. tostring(o)
          return false
        end
        ov, ay, by, resid, dbspan = o, a, b, w, sp
      end
    end
  end
  if ov == nil then
    p.why = 'no value field the y triple at ' .. tostring(yoff) .. ' is affine in, over '
            .. tostring(nl.PX_SPAN_MIN) .. ' dB'
    return false
  end

  -- Retain the record bytes the pixel update does not own.
  local T = {}
  for s = 1, cnt do
    local base = (s - 1) * stride
    T[3 * s - 2] = string.sub(blk, base + 1, base + yoff)
    T[3 * s - 1] = string.sub(blk, base + yoff + 1, base + yoff + 12)
    T[3 * s] = string.sub(blk, base + yoff + 13, base + stride)
  end
  -- Precompute packed Y triples for the panel rows.
  local ytab, y = {}, nil
  local c, fl, md = string.char, math.floor, math.mod
  for y = 0, nl.PX_YMAX do
    local w = c(md(fl(y / 16777216), 256), md(fl(y / 65536), 256),
                md(fl(y / 256), 256), md(y, 256))
    ytab[y] = w .. w .. w
  end
  p.g, p.lo, p.hdr, p.stride, p.nrec = g, lo, g.hdr, stride, cnt
  p.ov, p.ox, p.yoff, p.xoff, p.nseg = ov, ox, yoff, xoff, nseg
  -- Cache the frequency series as origin and step for later retune checks.
  p.hz1, p.hz2 = hz[1], hz[2]
  p.ay, p.by, p.resid, p.span = ay, by, resid, dbspan
  p.idx, p.ytab, p.T, p.yb = idx, ytab, T, {}
  p.drift, p.slot, p.slotdb, p.slotprev = 0, nil, nil, nil
  -- Repoint only within the range used to fit the X axis.
  p.axf, p.bxf = xa, xb
  local fmin, fmax = nil, nil
  for s = 1, cnt do
    local v = xv[s]
    if v ~= nil then
      if fmin == nil or v < fmin then fmin = v end
      if fmax == nil or v > fmax then fmax = v end
    end
  end
  p.fmin, p.fmax = fmin, fmax
  if xa ~= nil and fmin ~= nil then
    local a1 = xa * fmin + xb
    local a2 = xa * fmax + xb
    if a1 <= a2 then
      p.xpmin, p.xpmax = math.floor(a1), math.floor(a2 + 0.5)
    else
      p.xpmin, p.xpmax = math.floor(a2), math.floor(a1 + 0.5)
    end
  end
  -- Cache a validated native write block; Lua can still draw if it is unavailable.
  nl.px_block()
  return true
end

-- Patch only the fields outside the independently written Y triple.
function fftsa.nl.px_putrec(s, off, bytes)
  local p = fftsa.nl.px
  if p.T == nil or p.yoff == nil or p.stride == nil then return false end
  local n = string.len(bytes)
  local yoff, stride = p.yoff, p.stride
  if type(off) ~= 'number' or off < 0 or off + n > stride then return false end
  if off + n <= yoff then
    local i = 3 * s - 2
    local cur = p.T[i]
    if cur == nil or string.len(cur) ~= yoff then return false end
    p.T[i] = string.sub(cur, 1, off) .. bytes .. string.sub(cur, off + n + 1)
    return true
  end
  if off >= yoff + 12 then
    local i = 3 * s
    local cur = p.T[i]
    if cur == nil then return false end
    local base = off - (yoff + 12)
    if base + n > string.len(cur) then return false end
    p.T[i] = string.sub(cur, 1, base) .. bytes .. string.sub(cur, base + n + 1)
    return true
  end
  return false
end

function fftsa.nl.px_triple(v)
  local c, fl, md = string.char, math.floor, math.mod
  local w = c(md(fl(v / 16777216), 256), md(fl(v / 65536), 256),
              md(fl(v / 256), 256), md(v, 256))
  return w .. w .. w
end

-- Repoint a new frequency series only if the existing plot geometry can represent it.
-- Refresh X in Lua on that frame; subsequent writes can update Y only.
function fftsa.nl.px_repoint(hz, nseg)
  local nl = fftsa.nl
  local p = nl.px
  p.rp_why = nil
  if not nl.PX_REPOINT then
    p.rp_why = 're-pointing is switched off'
    return false
  end
  if p.nseg ~= nseg or p.nrec == nil then
    p.rp_why = 'the column count moved, so the permutation is not this one'
    return false
  end
  if p.axf == nil or p.ox == nil or p.xoff == nil or p.idx == nil or p.T == nil then
    p.rp_why = 'no frequency axis kept from the map'
    return false
  end
  local f1, fn = hz[1], hz[nseg]
  if type(f1) ~= 'number' or type(fn) ~= 'number' then
    p.rp_why = 'the series has no ends'
    return false
  end
  -- Require both ends to stay within a column of the old span: repoint is not an axis change.
  if p.fmin == nil or p.fmax == nil then
    p.rp_why = 'no fitted axis range'
    return false
  end
  local marg = 0
  if nseg > 1 then marg = (p.fmax - p.fmin) / (nseg - 1) end
  if f1 < p.fmin - marg or f1 > p.fmin + marg
     or fn < p.fmax - marg or fn > p.fmax + marg then
    p.rp_why = 'the series ends moved, so the axis was retuned rather than re-gridded'
    return false
  end
  local fl = math.floor
  local s
  for s = 1, p.nrec do
    local k = p.idx[s]
    local f = nil
    if k ~= nil then f = hz[k] end
    if f == nil then
      p.rp_why = 'slot ' .. tostring(s) .. ' maps to no column'
      return false
    end
    local xp = fl(p.axf * f + p.bxf + 0.5)
    if xp < p.xpmin then xp = p.xpmin end
    if xp > p.xpmax then xp = p.xpmax end
    if not nl.px_putrec(s, p.ox, nl._f32_pack(f))
       or not nl.px_putrec(s, p.xoff, nl.px_triple(xp)) then
      p.rp_why = 'the x fields do not fit the held image at slot ' .. tostring(s)
      return false
    end
  end
  p.hz1, p.hz2 = hz[1], hz[2]
  p.repoints = (p.repoints or 0) + 1
  p.rp_why = nil
  return true
end

-- Native and Lua writers share the same sample-to-row mapping.
fftsa.nl.PX_NATIVE = true

-- Pack ring bounds, stride, fit and slot map for the native Y-pixel writer.
function fftsa.nl.px_block()
  local nl = fftsa.nl
  local p = nl.px
  p.nat, p.nat_why, p.natwrote = false, nil, nil
  if not nl.ready or nl.entry == nil or nl.entry == 0 then
    p.nat_why = 'no install'
    return false
  end
  if nl.px_addr == nil or nl.px_addr == 0 or (nl.PX_WORDS or 0) == 0
     or (nl.PX_HDR or 0) == 0 or (nl.PX_MAXREC or 0) == 0 then
    p.nat_why = 'the image carries no ring block'
    return false
  end
  local g = p.g
  local lo, stride, yoff, nrec = p.lo, p.stride, p.yoff, p.nrec
  local ay, by, idx, nseg = p.ay, p.by, p.idx, p.nseg
  if g == nil or g.lo == nil or g.hi == nil or lo == nil or stride == nil or yoff == nil
     or nrec == nil or ay == nil or by == nil or idx == nil or nseg == nil then
    p.nat_why = 'no mapped geometry'
    return false
  end
  if nrec > nl.PX_MAXREC then
    p.nat_why = 'the drawn window is ' .. tostring(nrec) .. ' records against the '
                .. tostring(nl.PX_MAXREC) .. ' the image holds'
    return false
  end
  local ayh, ayl = f64_words(ay)
  local byh, byl = f64_words(by)
  local b = { g.lo, g.hi, lo, stride, yoff, nrec, nl.PX_YMAX, ayh, ayl, byh, byl }
  -- Check the packed header against the word count exported by the image.
  if table.getn(b) ~= nl.PX_HDR then
    p.nat_why = 'the block header is ' .. tostring(table.getn(b)) .. ' words against the '
                .. tostring(nl.PX_HDR) .. ' the image reads'
    return false
  end
  local s
  for s = 1, nrec do
    local k = idx[s]
    if type(k) ~= 'number' or k < 1 or k > nseg then
      p.nat_why = 'slot ' .. tostring(s) .. ' maps to column ' .. tostring(k)
      return false
    end
    b[nl.PX_HDR + s] = k
  end
  local parts = {}
  for s = 1, nl.PX_HDR + nrec do parts[s] = u32_pack(b[s]) end
  ki.memwrite(hx(nl.px_addr), table.concat(parts))
  p.nat, p.natwrote = true, 0
  return true
end

-- Return the records written by native code; nil selects the Lua writer.
function fftsa.nl.px_write(nseg)
  local nl = fftsa.nl
  local p = nl.px
  if not p.nat or not nl.PX_NATIVE then return nil end
  if not nl.ready or nl.entry == nil or nl.entry == 0 then return nil end
  if nseg ~= p.nseg or p.nrec == nil then return nil end
  local ok = nl.write_params({
    mode = nl.MODE_PX,
    wr_lo = nl.wr_lo, wr_hi = nl.wr_hi,
    rd_lo = nl.wr_lo, rd_hi = nl.wr_hi,
    seg_bytes = nl.seg_bytes, nsegs = nl.nsegs, segs_addr = nl.segs_addr,
    plan_addr = nl.plan_addr,
    red_db = nl.red_db, red_nseg = nseg,
    px_addr = nl.px_addr,
  })
  if not ok then
    p.nat, p.nat_why = false, 'write_params refused'
    return nil
  end
  -- Keep the last DSP status separate from pixel writer results.
  local rc = nl.call_native(nl.entry)
  -- Require the complete record count, not just a nonnegative result.
  if type(rc) ~= 'number' or rc ~= p.nrec then
    p.nat = false
    p.nat_why = 'rc=' .. nl.rc_name(rc) .. ' wanted ' .. tostring(p.nrec)
    return nil
  end
  p.natwrote = (p.natwrote or 0) + 1
  return rc
end

-- Draw through the current map; nil requests the append fallback.
function fftsa.nl.px_frame(db, hz, nseg, tb, t)
  local nl = fftsa.nl
  nl.rd_frame(t)
  local p = nl.px
  if p.nseg ~= nseg then
    return nl.px_dropframe('nseg moved from ' .. tostring(p.nseg) .. ' to ' .. tostring(nseg))
  end
  -- If X changed, use Lua for this frame because the native block only writes Y.
  local repointed = false
  if p.hz1 ~= hz[1] or p.hz2 ~= hz[2] then
    if not nl.px_repoint(hz, nseg) then
      local w = 'the frequency series moved under the slot map'
      if p.rp_why ~= nil then w = w .. ': ' .. tostring(p.rp_why) end
      return nl.px_dropframe(w)
    end
    repointed = true
  end
  local stride, nrec, lo = p.stride, p.nrec, p.lo
  -- Read live cursors before calculating where a repaint append would land.
  local h = ki.memread(hx(p.hdr), hx(24))
  if h == nil or string.len(h) < 24 then
    return nl.px_dropframe('header read gave ' .. tostring(h ~= nil and string.len(h) or 0))
  end
  if p.g ~= nil and p.g.lo ~= nil and p.g.hi ~= nil
     and (u32_at(h, 1) ~= p.g.lo or u32_at(h, 5) ~= p.g.hi) then
    return nl.px_dropframe('the displayed bank changed')
  end
  -- Restore the validated draw window before writing; cursor drift can address a different pass.
  local h_old, h_wr, h_cnt = nl.hdr_offs(p.g)
  local old0, cnt0 = u32_at(h, h_old + 1), u32_at(h, h_cnt + 1)
  local slip = (old0 - lo) / stride
  if slip < 0 then slip = -slip end
  if slip > nl.PX_SLIP_MAX or math.mod(old0 - lo, stride) ~= 0
     or cnt0 < nrec or cnt0 > nrec + nl.PX_SLIP_MAX then
    return nl.px_dropframe('the drawn window moved from ' .. hx(lo) .. '+' .. tostring(nrec)
                           .. ' to ' .. hx(old0) .. '+' .. tostring(cnt0))
  end
  local wr = lo + nrec * stride
  local function putback(off, want)
    ki.memwrite(hx(p.hdr + off),
                string.char(math.mod(math.floor(want / 16777216), 256),
                            math.mod(math.floor(want / 65536), 256),
                            math.mod(math.floor(want / 256), 256),
                            math.mod(want, 256)))
  end
  if old0 ~= lo or cnt0 ~= nrec then
    putback(h_old, lo)
    putback(h_cnt, nrec)
    p.restored = (p.restored or 0) + 1
  end
  putback(h_wr, wr)
  -- Compare the map with firmware's own rendered row from the repaint marker.
  if p.slot ~= nil and p.slotdb ~= nil then
    local pv = ki.memread(hx(lo + (p.slot - 1) * stride + p.yoff), hx(4))
    if pv ~= nil and string.len(pv) >= 4 then
      -- Accept either adjacent pass: the display task can lag the append by one pass.
      local pix = u32_at(pv, 1)
      local e = p.ay * p.slotdb + p.by - pix
      if e < 0 then e = -e end
      if p.slotprev ~= nil then
        local e2 = p.ay * p.slotprev + p.by - pix
        if e2 < 0 then e2 = -e2 end
        if e2 < e then e = e2 end
      end
      p.lastdrift = e
      if e > nl.PX_DRIFT_MAX then
        p.drift = (p.drift or 0) + 1
        if p.drift >= nl.PX_DRIFT_RUN then
          return nl.px_dropframe('the map is ' .. string.format('%.1f', e)
                               .. " px out on the firmware's own point")
        end
      else
        p.drift = 0
      end
    end
  end
  local idx = p.idx
  local wrote = nil
  if not repointed then wrote = nl.px_write(nseg) end
  if wrote == nil then
    -- Decode dB only for the Lua writer; the native writer consumes the reduction in place.
    db = nl.db_now(db)
    if db == nil then
      return nl.px_dropframe('the decibels did not decode for the Lua ring write')
    end
    local T, ytab, yb = p.T, p.ytab, p.yb
    local ay, by, ymax = p.ay, p.by, nl.PX_YMAX
    local fl = math.floor
    local j
    for j = 1, nseg do
      local y = fl(ay * db[j] + by + 0.5)
      if y < 0 then y = 0 end
      if y > ymax then y = ymax end
      yb[j] = ytab[y]
    end
    local s
    for s = 1, nrec do
      T[3 * s - 1] = yb[idx[s]]
    end
    ki.memwrite(hx(lo), table.concat(T))
  end
  -- Repaint without shifting X in a cursor slot.
  local slot = (wr - lo) / stride + 1
  local k = idx[slot]
  if k == nil then k = 1 end
  -- Probe the map with a fixed dB value so display lag does not change the validation input.
  if fftsa.sg_pix_repaint == 'cursor' and p.gid ~= nil then
    -- Repaint requests are rate-limited independently of ring writes.
    local gap = fftsa.sg_repaint_min or 0
    local now = os.clock()
    if gap > 0 and p.rp_at ~= nil and now - p.rp_at < gap then
      p.rpskip = (p.rpskip or 0) + 1
      p.frames = (p.frames or 0) + 1
      return nseg
    end
    local ok = pcall(function()
      display.graph.cursor(p.gid, display.CURSOR_VERTICAL, 9.9e37, 9.9e37)
    end)
    if not ok then
      -- A transient repaint refusal does not invalidate already written pixels.
      p.curfail = (p.curfail or 0) + 1
      if p.curfail < nl.PX_CURSOR_RUN then
        p.frames = (p.frames or 0) + 1
        return nseg
      end
      return nl.px_dropframe('display.graph.cursor refused ' .. tostring(p.curfail)
                             .. ' times running on handle ' .. tostring(p.gid))
    end
    p.curfail = 0
    p.rp_at = now
    p.slot, p.slotdb, p.slotprev = nil, nil, nil
    p.frames = (p.frames or 0) + 1
    p.repaints = (p.repaints or 0) + 1
    return nseg
  end
  -- In append mode, emit the actual value for that slot to preserve the visible trace.
  db = nl.db_now(db)
  if db == nil then
    return nl.px_dropframe('the decibels did not decode for the repaint append')
  end
  buffer.write.reading(tb, db[k], hz[k], t, 0)
  p.slotprev, p.slot, p.slotdb = p.slotdb, slot, db[k]
  p.frames = (p.frames or 0) + 1
  return nseg
end

-- Keep geometry across relaunches, but validate the live object before using cached addresses.
fftsa.nl.PX_CACHE_KEY = true

-- Optional diagnostics: scan for references to the trace object and then to its ring.
fftsa.nl.PX_PTRHUNT = false
fftsa.nl.PTRHUNT_MAX = 96
fftsa.nl.PTRHUNT_FILE = '/usb1/FFTSA_PTR.txt'

-- Target the trace object first; pointers may reference its owner rather than the ring payload.
function fftsa.nl.px_hunt_target()
  local nl = fftsa.nl
  local p = nl.px
  if nl.ph_level ~= 2 and p.g ~= nil and p.g.name_at ~= nil then
    return p.g.name_at - nl.PX_TRACE_NAME, 'trace'
  end
  return p.lo, 'ring'
end

function fftsa.nl.px_ptrhunt()
  local nl = fftsa.nl
  local p = nl.px
  if not nl.PX_PTRHUNT or nl.ph_done then return end
  if p.state ~= 'on' or p.lo == nil then return end
  local mlo, mhi = nl.map_bounds()
  if mlo == nil then return end
  local want, kind = nl.px_hunt_target()
  if want == nil then return end
  if nl.ph_at == nil then
    nl.ph_at, nl.ph_hits, nl.ph_n, nl.ph_ring = mlo, {}, 0, want
    nl.ph_kind = kind
  end
  if nl.ph_ring ~= want then
    nl.ph_at, nl.ph_hits, nl.ph_n, nl.ph_ring = mlo, {}, 0, want
    nl.ph_kind = kind
  end
  local lo = nl.ph_at
  local hi = lo + nl.px_budget()
  if hi > mhi then hi = mhi end
  if hi <= lo then
    nl.ph_done = true
    pcall(nl.px_ptrhunt_save)
    return
  end
  local got = nl.FINDS(lo, hi, u32_pack(nl.ph_ring))
  if got ~= nil then
    local i
    for i = 1, table.getn(got) do
      -- Exclude the ring payload itself from pointer-reference counts.
      local rhi = p.hi or (p.lo + p.nrec * p.stride)
      if got[i] < p.lo or got[i] >= rhi then
        if nl.ph_n < nl.PTRHUNT_MAX then
          nl.ph_n = nl.ph_n + 1
          nl.ph_hits[nl.ph_n] = got[i]
        end
      end
    end
  end
  nl.ph_at = hi
  if hi >= mhi then
    pcall(nl.px_ptrhunt_save)
    if nl.ph_level ~= 2 then
      nl.ph_level, nl.ph_at = 2, nil
    else
      nl.ph_done = true
    end
  end
end

function fftsa.nl.px_ptrhunt_save()
  local nl = fftsa.nl
  if nl.ph_hits == nil then return false end
  local body = tostring(nl.ph_kind or '?') .. '=' .. hx(nl.ph_ring or 0)
               .. ' ring=' .. hx(nl.px.lo or 0) .. ' inst=' .. hx(nl.inst or 0)
               .. ' gid=' .. tostring(nl.px.gid) .. ' at='
  local i
  for i = 1, nl.ph_n do
    if i > 1 then body = body .. ',' end
    body = body .. hx(nl.ph_hits[i])
  end
  body = body .. '\n'
  return pcall(function()
    if file.usbdriveexists() ~= 1 then error('no key', 0) end
    local fh = io.open(nl.PTRHUNT_FILE, 'a')
    if fh == nil then error('open refused', 0) end
    fh:write(body)
    fh:close()
  end)
end

fftsa.nl.PX_CACHE_DIR  = '/usb1'
fftsa.nl.PX_CACHE_NAME = 'FFTSA_PX.txt'
fftsa.nl.PX_CACHE_FILE = '/usb1/FFTSA_PX.txt'

-- The seed is only a search-order hint. Persist confirmed geometry and the learned span, not guesses.

function fftsa.nl.px_seed_span()
  if type(FFTSA_PXSEED) ~= 'string' then return nil end
  local f, n = {}, 0
  local w
  for w in string.gfind(FFTSA_PXSEED, '[0-9]+') do
    n = n + 1
    f[n] = tonumber(w)
  end
  if n ~= 2 or f[1] == nil or f[2] == nil or f[1] <= 0 or f[2] < f[1] then return nil end
  return f[1], f[2]
end

function fftsa.nl.px_seed_learned()
  return fftsa.nl.px_seed_span()
end

function fftsa.nl.px_seed_note(lo)
  if type(lo) ~= 'number' or lo <= 0 then return end
  local a, b = fftsa.nl.px_seed_learned()
  if a == nil then a, b = lo, lo end
  if lo < a then a = lo end
  if lo > b then b = lo end
  FFTSA_PXSEED = string.format('%d,%d', a, b)
end

-- Cache six geometry fields and two span bounds in a single record.
function fftsa.nl.px_cache_save()
  local nl = fftsa.nl
  if not nl.PX_CACHE_KEY then return false end
  local a, b = nl.px_seed_learned()
  if type(FFTSA_PXRING) ~= 'string' or a == nil then return false end
  local body = FFTSA_PXRING .. ',' .. tostring(a) .. ',' .. tostring(b) .. '\n'
  -- Write the key cache only when a confirmed record changes.
  if body == nl._px_saved then return false end
  local ok = pcall(function()
    if file.usbdriveexists() ~= 1 then error('no key', 0) end
    local fh = io.open(nl.PX_CACHE_FILE, 'w')
    if fh == nil then error('open refused', 0) end
    fh:write(body)
    fh:close()
  end)
  if ok then nl._px_saved = body end
  nl.px_save_why = nil
  if not ok then nl.px_save_why = 'save refused' end
  return ok
end

-- Load the key cache once per launch and preserve already-known boot state.
function fftsa.nl.px_cache_load()
  local nl = fftsa.nl
  if nl._px_loaded then return false end
  nl._px_loaded = true
  if not nl.PX_CACHE_KEY then return false end
  local got = false
  pcall(function()
    -- Check existence before opening a cache file; a missing file can post a modal event.
    if file.usbdriveexists() ~= 1 then
      nl.px_load_why = 'no key in the slot'
      return
    end
    local t = fs.readdir(nl.PX_CACHE_DIR)
    if t == nil then
      nl.px_load_why = 'cannot list ' .. tostring(nl.PX_CACHE_DIR)
      return
    end
    local there, k, v = false, nil, nil
    for k, v in pairs(t) do
      if tostring(v) == nl.PX_CACHE_NAME then there = true end
    end
    if not there then
      nl.px_load_why = 'no record on the key yet'
      return
    end
    local fh = io.open(nl.PX_CACHE_FILE, 'r')
    if fh == nil then
      nl.px_load_why = 'open for read refused'
      return
    end
    local body = fh:read(256)
    fh:close()
    if type(body) ~= 'string' then return end
    local f, n = {}, 0
    local w
    for w in string.gfind(body, '[0-9]+') do
      n = n + 1
      f[n] = tonumber(w)
    end
    if n < 8 then return end
    if FFTSA_PXRING == nil then
      FFTSA_PXRING = string.format('%d,%d,%d,%d,%d,%d', f[1], f[2], f[3], f[4], f[5], f[6])
    end
    if FFTSA_PXSEED == nil and f[7] > 0 and f[8] >= f[7] then
      FFTSA_PXSEED = string.format('%d,%d', f[7], f[8])
    end
    got = true
  end)
  return got
end

function fftsa.nl.px_cache_put(g)
  FFTSA_PXRING = string.format('%d,%d,%d,%d,%d,%d',
                               g.lo, g.hi, g.nrec, g.stride, g.ox, g.hdr)
  fftsa.nl.px_seed_note(g.lo)
  pcall(fftsa.nl.px_cache_save)
end

function fftsa.nl.px_cache_get()
  if type(FFTSA_PXRING) ~= 'string' then return nil end
  local f, n = {}, 0
  local w
  for w in string.gfind(FFTSA_PXRING, '[-0-9]+') do
    n = n + 1
    f[n] = tonumber(w)
  end
  if n ~= 6 then return nil end
  -- Derive the value offset from the live ring instead of caching it.
  return { lo = f[1], hi = f[2], nrec = f[3], stride = f[4], ox = f[5], hdr = f[6] }
end

-- Drive acquisition of a ring map each frame; nil leaves plotting to the append path.
function fftsa.nl.px_try(db, hz, nseg, tb, t, gid)
  local nl = fftsa.nl
  nl.rd_frame(t)
  local p = nl.px
  local st = p.state
  if nl.t_first == nil then nl.t_first = os.clock() end
  if st ~= 'on' then nl.pre_frames = (nl.pre_frames or 0) + 1 end
  if st == 'off' then return nil end
  if type(gid) == 'number' then
    -- A changed graph handle invalidates the cached table-entry lookup.
    if p.gid ~= nil and p.gid ~= gid then
      nl.px_objbase = nil
      p.objdone, p.objscan = nil, 0
    end
    p.gid = gid
  end
  if st == 'on' then return nl.px_frame(db, hz, nseg, tb, t) end
  if nseg == nil or nseg < 8 then return nil end
  if st == 'idle' then
    -- Let plain appends refill the ring during the hold before attempting another map.
    if (p.hold or 0) > 0 then
      p.hold = p.hold - 1
      return nil
    end
    pcall(nl.px_cache_load)
    -- Retry cheap routes while the ring fills with the current plan's frequencies.
    local tried = false
    local cands, nc = {}, 0
    -- Try the subscriber first; it needs only the buffer name, not a display handle.
    do
      local bs = nl.px_from_bufsub()
      local bi
      for bi = 1, table.getn(bs) do
        nc = nc + 1
        cands[nc] = { g = bs[bi], from = 'sub' }
      end
    end
    if p.gid ~= nil then
      local bp = nl.px_from_ptr(p.gid)
      local bi
      for bi = 1, table.getn(bp) do
        nc = nc + 1
        cands[nc] = { g = bp[bi], from = 'ptr' }
      end
    end
    local c = nl.px_cache_get()
    if c ~= nil then
      nc = nc + 1
      cands[nc] = { g = c, from = 'cache' }
    end
    local ci
    for ci = 1, nc do
      tried = true
      local g = cands[ci].g
      -- Pointer routes leave the X offset to the mapper; cached geometry may already supply it.
      if cands[ci].from == 'ptr' or cands[ci].from == 'sub' then g.ox = nil end
      if nl.px_map(g, hz, nseg) then
        p.state = 'on'
        nl.px_engaged()
        p.from = cands[ci].from
        -- Suppress sweeps only after the subscriber's candidate passes the live slot map.
        if cands[ci].from == 'sub' then nl.px_subok = true end
        if g.name_at ~= nil then p.needle = 'name' end
        nl.px_ptr_ok()
        nl.px_cache_put(g)
        return nl.px_frame(db, hz, nseg, tb, t)
      end
    end
    -- Run cheap retries and bounded search concurrently; the first validated map wins.
    if tried then
      p.cachetries = (p.cachetries or 0) + 1
      if p.cachetries < nl.PX_CACHE_TRIES then st = 'seek' end
    elseif p.gid ~= nil and nl.PX_PTR ~= false and not p.objdone then
      -- Keep the table walk resumable only while a display handle makes that route available.
      st = 'seek'
    end
    if st ~= 'seek' then
      p.state = 'seek'
      st = 'seek'
    end
  end
  if st == 'seek' then
    -- Try the subscriber again before checking whether native search is ready.
    do
      local bysub = nl.px_from_bufsub()
      if table.getn(bysub) > 0 then
        p.via = 'sub'
        p.cands, p.state = bysub, 'hdr'
        p.ncand = (p.ncand or 0) + table.getn(bysub)
        return nil
      end
      -- Wait for a known slot's ring to fill; a scan cannot make the data arrive sooner.
      if nl.px_subslot ~= nil then
        p.subwait = (p.subwait or 0) + 1
        -- Once the subscriber route has worked, revalidate it instead of sweeping after a rebind.
        if nl.px_subok or p.subwait <= nl.PX_SUB_WAIT then
          return nl.px_wait('the subscriber slot is known, waiting for its ring: '
                            .. tostring(nl.sub_why))
        end
      end
    end
    local mlo = nl.map_bounds()
    if not ((nl.NFIND and mlo ~= nil and nl.ready) or nl.PX_SWEEP) then
      -- Refresh mapped bounds and retry pointer discovery if native search is unavailable.
      nl.map_lo, nl.map_hi = nil, nil
      p.ptrtries = (p.ptrtries or 0) + 1
      if p.ptrtries < nl.PX_PTR_TRIES then
        return nl.px_wait('no pointer yet, try ' .. tostring(p.ptrtries))
      end
      -- Count retries for diagnostics; startup timing is not a permanent refusal.
      p.ptrcap = (p.ptrcap or 0) + 1
      local w = 'no pointer, no cache, and no native search yet, waiting '
                .. tostring(p.ptrtries)
      if nl.map_why ~= nil then w = w .. ': ' .. tostring(nl.map_why) end
      return nl.px_wait(w)
    end
    nl.FINDS_NATIVE_ONLY = not nl.PX_SWEEP
    -- Size later slices using the bytes and time reported by native search.
    local b0, s0 = nl._nf_bytes or 0, nl._nf_secs or 0
    local c = nl.px_seek(hz, nseg, nl.px_budget(), tb)
    nl.px_nb_note((nl._nf_bytes or 0) - b0, (nl._nf_secs or 0) - s0)
    nl.FINDS_NATIVE_ONLY = false
    if c == nil then
      -- A search refusal can be temporary during native reattach; restart instead of disabling it.
      p.nrefuse = (p.nrefuse or 0) + 1
      return nl.px_restart('the native search refused: ' .. tostring(nl.find_why))
    end
    if c == nil or table.getn(c) == 0 then return nil end
    p.cands, p.state = c, 'hdr'
    p.ncand = (p.ncand or 0) + table.getn(c)
    return nil
  end
  -- Limit header validation to one candidate per frame.
  if st == 'hdr' then
    local c = p.cands
    if c == nil or table.getn(c) == 0 then
      p.cands, p.state = nil, 'seek'
      return nil
    end
    local g = c[table.getn(c)]
    table.remove(c)
    -- Name-derived geometry already carries bounds and header; record hits still need both.
    p.needle = 'freq'
    if g.name_at ~= nil then p.needle = 'name' end
    if g.hdr ~= nil and g.lo ~= nil then
      g.ox = nil
      p.g, p.state, p.maptries = g, 'map', 0
      return nil
    end
    if nl.find_ring_header(g) ~= nil then
      g.ox = math.mod(g.val0 - g.lo, g.stride)
      p.g, p.state, p.maptries = g, 'map', 0
    else
      p.why = 'header: ' .. tostring(nl.ring_why)
    end
    return nil
  end
  if st == 'map' then
    -- Resolve cursor roles before constructing a writable map.
    if p.g ~= nil and p.g.h_pairs ~= nil and p.g.h_old == nil then
      if nl.px_hdr_resolve(p.g) then
        p.maptries, p.hdrtries = 0, 0
        return nil
      end
      p.hdrtries = (p.hdrtries or 0) + 1
      if p.hdrtries >= nl.PX_HDR_TRIES then
        p.why = 'the cursor offsets did not resolve: ' .. tostring(p.g.h_why)
        p.g, p.state, p.hdrtries = nil, 'hdr', 0
      end
      return nil
    end
    if nl.px_map(p.g, hz, nseg) then
      p.state = 'on'
      nl.px_engaged()
      p.from = p.via or 'search'
      if p.from == 'sub' then nl.px_subok = true end
      nl.px_cache_put(p.g)
      return nl.px_frame(db, hz, nseg, tb, t)
    end
    p.maptries = (p.maptries or 0) + 1
    if p.maptries >= nl.PX_MAP_TRIES then
      p.g, p.state = nil, 'hdr'
    end
    return nil
  end
  return nil
end

function fftsa.nl.px_str()
  local nl = fftsa.nl
  local p = nl.px
  local o = 'px=' .. tostring(p.state)
  -- Report the active route even when discovery has never engaged.
  if nl.model_7510 ~= nil then
    o = o .. ' m='
    if nl.model_7510 then o = o .. '7510' else o = o .. '6500' end
  end
  if nl.eng_secs ~= nil then
    o = o .. string.format(' eng=%.1fs/%df', nl.eng_secs, nl.eng_frames or 0)
    if nl.eng_last ~= nil and nl.eng_last < nl.eng_secs - 0.05 then
      o = o .. string.format(' last=%.1fs/%df', nl.eng_last, nl.eng_lastf or 0)
    end
  elseif nl.pre_frames ~= nil and nl.pre_frames > 0 then
    o = o .. string.format(' trying=%.1fs/%df',
                           os.clock() - (nl.t_first or os.clock()), nl.pre_frames)
  end
  if nl.px_load_why ~= nil then o = o .. ' loadwhy=' .. tostring(nl.px_load_why) end
  if nl.px_save_why ~= nil then o = o .. ' savewhy=' .. tostring(nl.px_save_why) end
  if nl.PX_PTR == false then o = o .. ' ptr=0' end
  if nl.PX_HDR_DERIVE then o = o .. ' der=1' end
  if fftsa.sg_pix_armed ~= nil then
    local ok, armed = pcall(fftsa.sg_pix_armed)
    if ok then
      o = o .. ' arm='
      if armed then o = o .. '1' else o = o .. '0' end
    end
  end
  if p.lo ~= nil then
    o = o .. ' ring=' .. hx(p.lo) .. '/' .. tostring(p.nrec) .. 'x' .. tostring(p.stride)
        .. ' x@' .. tostring(p.xoff) .. ' y@' .. tostring(p.yoff)
        .. ' v@' .. tostring(p.ov) .. ' xf@' .. tostring(p.ox)
  end
  if p.needle ~= nil then o = o .. ' by=' .. tostring(p.needle) end
  if p.xcol ~= nil then o = o .. ' col=' .. tostring(p.xcol) end
  if p.ay ~= nil then
    o = o .. string.format(' map=%.4f*db%+.2f r=%.2f sp=%.0f', p.ay, p.by, p.resid, p.span)
  end
  if p.frames ~= nil then o = o .. ' n=' .. tostring(p.frames) end
  if p.rpskip ~= nil then o = o .. ' rpskip=' .. tostring(p.rpskip) end
  -- Report which writer is active and why the native writer may be unavailable.
  if p.nat and not nl.PX_NATIVE then
    o = o .. ' nw=off'
  elseif p.nat then
    o = o .. ' nw=' .. tostring(p.natwrote or 0)
  elseif p.nat_why ~= nil then
    o = o .. ' nw=0/' .. tostring(p.nat_why)
  end
  if p.from ~= nil then o = o .. ' via=' .. tostring(p.from) end
  if nl.px_objbase ~= nil then
    o = o .. ' obj=' .. hx(nl.px_objbase) .. '+' .. tostring(nl.px_objid) .. 'x'
        .. tostring(nl.PX_OBJ_STRIDE)
    if nl.px_objfound ~= nil then o = o .. '[' .. tostring(nl.px_objfound) .. ']' end
  end
  if p.gid ~= nil then o = o .. ' gid=' .. tostring(p.gid) end
  if p.ptr_lost ~= nil then o = o .. ' ptrlost=' .. tostring(p.ptr_lost) end
  -- Keep pointer-route failures visible even when the search uses another route.
  if nl.px_objbase == nil and nl.ptr_why ~= nil then
    o = o .. ' ptrwhy=' .. tostring(nl.ptr_why)
    o = o .. ' objscan=' .. tostring(p.objscan or 0) .. '/'
        .. tostring(table.getn(nl.px_bases()) * nl.PX_OBJ_SCAN)
  end
  o = o .. ' ' .. nl.rd_str()
  o = o .. ' swept=' .. tostring(math.floor((p.swept or 0) / 1048576)) .. 'MB'
  o = o .. '/' .. tostring(math.floor((p.sweptpass or 0) / 1048576)) .. 'pass'
  if p.wins ~= nil and p.wi ~= nil then
    local w = p.wins[p.wi]
    o = o .. ' win=' .. tostring(p.wi) .. '/' .. tostring(table.getn(p.wins))
    if w ~= nil then
      o = o .. '[' .. hx(w[1]) .. '+' .. tostring(math.floor((w[2] - w[1]) / 1048576)) .. 'MB]'
    end
    if p.at ~= nil then o = o .. ' at=' .. hx(p.at) end
    local iw = nl.px_inst_wins()
    local bpos, nbp = '', 0
    local bi2
    for bi2 = 1, table.getn(p.wins) do
      local k2
      for k2 = 1, table.getn(iw) do
        if iw[k2][1] == p.wins[bi2][1] and iw[k2][2] == p.wins[bi2][2] then
          nbp = nbp + 1
          if nbp > 1 then bpos = bpos .. ',' end
          bpos = bpos .. tostring(bi2)
        end
      end
    end
    if nbp == 0 then bpos = 'none' end
    o = o .. ' band=' .. bpos .. '/' .. tostring(table.getn(iw))
    if p.lo ~= nil and nl.inst ~= nil then
      local d = p.lo - nl.inst
      local sg = '+'
      if d < 0 then
        sg = '-'
        d = -d
      end
      o = o .. ' ring@inst' .. sg .. string.format('%.2fMB', d / 1048576)
    end
  end
  if nl.inst ~= nil then o = o .. ' inst=' .. hx(nl.inst) end
  -- Include subscriber profile, checked windows and refusal reasons in every report.
  o = o .. ' sub='
  if nl.px_subslot ~= nil then
    o = o .. hx(nl.px_subslot)
    if nl.sub_trace ~= nil then o = o .. '>' .. hx(nl.sub_trace) end
  else
    o = o .. '0'
  end
  if nl.sub_hits ~= nil then o = o .. '/' .. tostring(nl.sub_hits) .. 'hit' end
  if (nl.sub_tries or 0) > 0 then o = o .. '/' .. tostring(nl.sub_tries) .. 'try' end
  if nl.px.from == 'sub' or nl.px.via == 'sub' then o = o .. '/chain' end
  if nl.px_subok then o = o .. '/mapped' end
  o = o .. ' subcfg=' .. tostring(nl.sub_profile or '?') .. '@' .. hx(nl.PX_SUB_LO)
      .. '+' .. tostring(math.floor(nl.PX_SUB_BYTES / 1024)) .. 'KB'
  if nl.sub_len ~= nil and nl.sub_want ~= nil and nl.sub_len ~= nl.sub_want then
    o = o .. ' short=' .. tostring(nl.sub_len) .. '/' .. tostring(nl.sub_want)
  end
  if nl.sub_wincap then o = o .. ' hitcap' end
  if nl.sub_loose then o = o .. ' loosekind' end
  if nl.px_subwin ~= nil then o = o .. ' subw=' .. hx(nl.sub_at or 0) .. '>' ..
                                   hx(nl.px_subwin) end
  if nl.sub_nameoff ~= nil and nl.sub_nameoff ~= nl.PX_SUB_NAME then
    o = o .. ' nameoff=' .. tostring(nl.sub_nameoff)
  end
  if nl.sub_kind ~= nil and nl.sub_kind ~= nl.PX_SUB_KIND then
    o = o .. ' kind=' .. hx(nl.sub_kind)
  end
  if nl.sub_derived then
    o = o .. ' derived=' .. tostring(nl.sub_p4off) .. '/' .. tostring(nl.sub_levels) .. 'lv'
  end
  local sw = nl.sub_why or nl.sub_lastwhy
  if sw ~= nil then o = o .. '[' .. tostring(sw) .. ']' end
  if nl.sub_map ~= nil and not nl.px_subok then
    o = o .. ' submap=' .. hxn(nl.sub_mapat) .. ':' .. nl.sub_map
  end
  if p.hits ~= nil then o = o .. ' hit=' .. tostring(p.hits) end
  if p.ncand ~= nil then o = o .. ' cand=' .. tostring(p.ncand) end
  if p.cands ~= nil then o = o .. '/' .. tostring(table.getn(p.cands)) .. 'left' end
  if p.degen ~= nil then o = o .. ' flat=' .. tostring(p.degen) end
  if p.lastdrift ~= nil then o = o .. string.format(' d=%.1f', p.lastdrift) end
  if p.namehits ~= nil then o = o .. ' nh=' .. tostring(p.namehits) end
  if (p.nhall or 0) > 0 then o = o .. '/' .. tostring(p.nhall) .. 'all' end
  if p.namedead ~= nil then o = o .. ' namedead=' .. tostring(p.namedead) end
  if p.noname then o = o .. ' noname=1' end
  -- Report derived cursor roles and their validation state.
  if (nl.hdr_agree or 0) + (nl.hdr_differ or 0) + (nl.hdr_resolved or 0) > 0
     or nl.PX_HDR_DERIVE then
    o = o .. string.format(' hdr=%d/%d/%d', nl.hdr_agree or 0, nl.hdr_differ or 0,
                           nl.hdr_resolved or 0)
  end
  if p.hdrtries ~= nil then o = o .. ' ht=' .. tostring(p.hdrtries) end
  if p.g ~= nil and p.g.h_pairs ~= nil then
    o = o .. ' hp=' .. tostring(table.getn(p.g.h_pairs))
    if p.g.h_why ~= nil then o = o .. ' hpwhy=' .. tostring(p.g.h_why) end
  end
  if nl.hdr_why ~= nil then o = o .. ' hdrwhy=' .. tostring(nl.hdr_why) end
  if p.hdr ~= nil then
    local h = ki.memread(hx(p.hdr), hx(24))
    if h ~= nil and string.len(h) >= 24 then
      local so, sw, sc = nl.hdr_offs(p.g)
      o = o .. string.format(' hdrd=%d/%d/%d', so, sw, sc)
      o = o .. ' hdr[old=' .. hx(u32_at(h, so + 1))
          .. ' wr=' .. hx(u32_at(h, sw + 1))
          .. ' n=' .. tostring(u32_at(h, sc + 1)) .. ']'
    end
  end
  if nl.ph_hits ~= nil then
    o = o .. ' hunt' .. tostring(nl.ph_level or 1) .. '='
        .. tostring(nl.ph_kind or '?') .. '/' .. tostring(nl.ph_n or 0)
    if not nl.ph_done then o = o .. '@' .. hx(nl.ph_at or 0) end
    local i
    for i = 1, nl.ph_n do
      o = o .. ' ' .. hx(nl.ph_hits[i])
    end
  end
  if p.whyframe ~= nil then o = o .. ' frame=' .. tostring(p.whyframe) end
  if p.laps ~= nil then o = o .. ' laps=' .. tostring(p.laps) end
  if p.restarts ~= nil then
    o = o .. ' re=' .. tostring(p.restarts)
    if p.re_last ~= nil then o = o .. '[' .. tostring(p.re_last) end
    if p.re_prev ~= nil then o = o .. ' <- ' .. tostring(p.re_prev) end
    if p.re_last ~= nil then o = o .. ']' end
  end
  if p.why ~= nil then o = o .. ' why=' .. tostring(p.why) end
  return o
end

-- Params are an ABI: pack fields in dsp_native_params order and check the image's word count.
function fftsa.nl.write_params(t)
  local fn = fftsa.nl.fn
  if fftsa.nl.SIZEOF_PARAMS ~= 0 and
     fftsa.nl.PARAM_WORDS * 4 ~= fftsa.nl.SIZEOF_PARAMS then
    fftsa.nl.wp_why = 'params layout: ' .. tostring(fftsa.nl.PARAM_WORDS)
                      .. ' words against a ' .. tostring(fftsa.nl.SIZEOF_PARAMS)
                      .. '-byte struct'
    return false
  end
  fftsa.nl.wp_why = nil
  local f0h, f0l = f64_words(t.red_f0 or 0)
  local bwh, bwl = f64_words(t.red_binhz or 0)
  local dnh, dnl = f64_words(t.red_dbmin or 0)
  local dxh, dxl = f64_words(t.red_dbmax or 0)
  local vfh, vfl = f64_words(t.red_vfloor or 0)
  local w = {
    fftsa.nl.MAGIC,
    t.mode or 0,
    t.wr_lo or 0, t.wr_hi or 0,
    t.rd_lo or 0, t.rd_hi or 0,
    t.out_lo or 0, t.out_hi or 0,
    t.seg_bytes or 0, t.nsegs or 0, t.segs_addr or 0,
    t.plan_addr or 0,
    t.cap_chunk1 or 0, t.cap_n or 0, t.cap_perchunk or 0,
    t.cap_stride or 32,
    t.cap_vec or 0, t.cap_nchunks or 0,
    t.out_chunk1 or 0, t.out_chunk2 or 0, t.out_perchunk or 0, t.out_desc or 0,
    fftsa.nl.STATUS_UNSET,
    fn.sin or 0, fn.cos or 0, fn.sqrt or 0,
    fn.log10 or 0, fn.floor or 0, fn.ceil or 0,
    t.init_kind or 0, t.init_beta_milli or 0,
    t.init_decim or 1, t.init_method or 0,
    t.red_nseg or 0, t.red_k0 or 0, t.red_k1 or 0,
    t.red_db or 0, t.red_hz or 0, t.red_sense or 1,
    f0h, f0l, bwh, bwl, dnh, dnl, dxh, dxl, vfh, vfl,
    t.res_addr or 0, t.res_npk or 0, t.res_mains or 0,
    -- Native code reports the C source line in fail_at for each status.
    t.fail_at or 0,
    -- Search and pixel blocks are referenced by pointer; neither is inline in the params.
    t.find_addr or 0,
    t.px_addr or 0,
  }
  if table.getn(w) ~= fftsa.nl.PARAM_WORDS then return false end
  local parts = {}
  local i
  for i = 1, table.getn(w) do parts[i] = u32_pack(w[i]) end
  ki.memwrite(hx(fftsa.nl.params), table.concat(parts))
  return true
end

-- Redirect the Lua C closure, invoke it without arguments, and restore it on either exit.
local function via_peek8(addr)
  local nl = fftsa.nl
  if nl.peek8_cls == 0 then return false, 'no closure' end
  -- Require a valid original firmware .text pointer before installing a temporary target.
  if not nl._text_ok(nl.peek8_f) then return false, 'restore value not in .text' end
  local slot = hx(nl.peek8_cls + 12)
  local orig = string.format('%08X', nl.peek8_f)
  ki.poke32(slot, string.format('%08X', addr))
  local ok, r = pcall(ki.peek8)
  ki.poke32(slot, orig)
  fftsa.nl.last_call = ok
  if not ok then
    return false, r
  end
  return true
end

-- Flush written code out of the D-cache and invalidate its I-cache lines.
local function flush(addr, len)
  local nl = fftsa.nl
  if nl.tramp == nil or nl.tramp == 0 then return false end
  if addr == nil or len == nil or len <= 0 then return false end
  -- Refuse any flush whose cache lines intersect the executing trampoline.
  local tlo = nl.tramp
  if line_hi(addr, len) > line_lo(tlo) and
     line_lo(addr) < line_hi(tlo, string.len(nl._TRAMP)) then
    return false
  end
  -- Write the address and length into the trampoline's argument words before calling it.
  ki.memwrite(hx(tlo + nl.TRAMP_RANGE), u32_pack(addr) .. u32_pack(len))
  via_peek8(tlo)
  return nl.last_call == true
end
fftsa.nl.flush = flush

-- Call the image and read the status and diagnostic line from the params block.
local function call_native(addr)
  local nl = fftsa.nl
  local function refuse(why)
    return nil, why
  end
  if nl.params == nil or nl.params == 0 then return refuse('no params') end
  if nl.STATUS_OFF == nil or nl.STATUS_OFF == 0 then return refuse('no status offset') end
  local ok, err = via_peek8(addr)
  if not ok then return nil, err end
  local s = ki.memread(hx(nl.params + nl.STATUS_OFF), hx(4))
  if s == nil or string.len(s) < 4 then return refuse('status unreadable') end
  nl.fail_at = nil
  if nl.FAIL_OFF ~= nil and nl.FAIL_OFF ~= 0 then
    local f = ki.memread(hx(nl.params + nl.FAIL_OFF), hx(4))
    if f ~= nil and string.len(f) >= 4 then
      local fv = u32_at(f, 1)
      if fv ~= 0 then nl.fail_at = fv end
    end
  end
  local v = u32_at(s, 1)
  if v == nl.STATUS_UNSET then return refuse('no status') end
  if v >= 2147483648 then v = v - 4294967296 end
  return v
end
fftsa.nl.call_native = call_native

-- Restore the original closure entry only if it remains a valid firmware text address.
function fftsa.nl.restore_peek8()
  local nl = fftsa.nl
  if nl.peek8_cls == 0 then return false end
  if not nl._text_ok(nl.peek8_f) then return false end
  ki.poke32(hx(nl.peek8_cls + 12), string.format('%08X', nl.peek8_f))
  return true
end

-- Restore the closure before deleting buffers that might still own a call target.
function fftsa.nl._abort(cb, pb, why)
  local nl = fftsa.nl
  nl.why = why or 'unspecified'
  if pb ~= nil then pcall(function() buffer.delete(pb) end) end
  if cb ~= nil then pcall(function() buffer.delete(cb) end) end
  nl.ready     = false
  nl.entry     = nil
  nl.tramp     = nil
  nl.params    = nil
  nl.code_buf  = nil
  nl.code_base = nil
  nl.plan_buf  = nil
  nl.plan_addr = nil
  nl.segs_addr = nil
  return false
end

-- Install once per boot, or reattach a validated install. Seed a nonempty code buffer
-- for the actual service-task barrier; barrier_buf is validated but not used for it.
function fftsa.nl.init(barrier_buf, want_n, kind, beta, decim, method, want_nseg)
  local nl = fftsa.nl

  -- Select the pixel lookup and cursor policy by model. DMM6500 uses known cursor offsets
  -- and a GUI table route; DMM7510 derives cursor roles and allows subscriber fallbacks.
  nl.model_7510 = false
  if localnode ~= nil and localnode.model ~= nil then
    nl.model_7510 = string.find(tostring(localnode.model), '7510', 1, true) ~= nil
  end
  nl.PX_HDR_DERIVE = nl.model_7510
  nl.PX_PTR = not nl.model_7510
  -- On DMM7510 allow alternate slot layouts, kinds and windows; all still need proof.
  if nl.model_7510 then nl.PX_SUB_LO = nl.PX_SUB_LO_7510 end
  nl.sub_profile = '6500'
  if nl.model_7510 then nl.sub_profile = '7510' end
  nl.PX_SUB_DERIVE = nl.model_7510
  nl.PX_SUB_ANYKIND = nl.model_7510
  nl.PX_SUB_LADDER = nl.model_7510
  nl.hdr_known = not nl.model_7510
  -- FFTSA_HDRDERIVE overrides the model default; nil uses the model policy.
  if FFTSA_HDRDERIVE ~= nil then nl.PX_HDR_DERIVE = FFTSA_HDRDERIVE end
  if FFTSA_PTRHUNT ~= nil then nl.PX_PTRHUNT = FFTSA_PTRHUNT end

  -- NLBOOT survives script reloads and prevents a second heap-code install this boot.
  -- Check it before clearing ready so a redundant call cannot disable a live install.
  if NLBOOT ~= nil then
    nl.boot_spent = true
    -- Revalidate the stashed pointers and layout before reusing the image.
    if nl.reattach(want_n, kind, beta, decim, method) then return true end
    return nl._no('one install per boot is spent and reattach refused: the earlier '
                  .. 'install is gone or no longer validates')
  end
  nl.boot_spent = false

  nl.ready = false
  -- Size the arena for the maximum requested FFT, not just the first frame.
  want_n = want_n or 512
  want_nseg = want_nseg or 255

  if nl._DSP_CODE == nil and nl._DSP_CODE_B64 ~= nil then
    trace('b64', nl._DSP_CODE_B64_LEN, nl._DSP_RELOC_B64_LEN)
    nl._DSP_CODE  = b64decode(nl._DSP_CODE_B64, nl._DSP_CODE_B64_LEN)
    nl._DSP_RELOC = b64decode(nl._DSP_RELOC_B64, nl._DSP_RELOC_B64_LEN)
    trace('b64.ok', nl._DSP_CODE ~= nil and string.len(nl._DSP_CODE) or 'nil')
  end
  if nl._DSP_CODE == nil or string.len(nl._DSP_CODE) == 0 then
    return nl._no('native_code.tsp did not load: no image')
  end
  if nl._DSP_RELOC == nil then
    return nl._no('native_code.tsp did not load: no relocation table')
  end
  -- Require ABI metadata before computing any target address or calling into the image.
  if nl.SIZEOF_REAL == 0 or nl.SIZEOF_PLAN == 0 or nl.SIZEOF_PARAMS == 0 or
     nl.RES_DOUBLES == 0 or nl.RES_PEAKS == 0 or
     nl.PARAMS_SLOT == nil or nl.PARAMS_SLOT == 0 or
     nl.STATUS_OFF == nil or nl.STATUS_OFF == 0 then
    return nl._no('generated sizes are zero or nil: real=' .. tostring(nl.SIZEOF_REAL)
                  .. ' plan=' .. tostring(nl.SIZEOF_PLAN) .. ' params='
                  .. tostring(nl.SIZEOF_PARAMS) .. ' slot=' .. tostring(nl.PARAMS_SLOT)
                  .. ' status=' .. tostring(nl.STATUS_OFF))
  end

  -- The transform can span multiple chunks; the image's segment count bounds allocation.
  local nmax = 65536
  if align8(nl.SIZEOF_PLAN) + 32 > nl.CHUNK_BYTES then
    trace('size.plan', nl.SIZEOF_PLAN)
    return nl._no('plan struct of ' .. tostring(nl.SIZEOF_PLAN)
                  .. ' bytes does not leave a chunk room for alignment')
  end
  -- Size the reduction chunk for both arrays, results, the search block and the pixel block.
  local res_bytes = nl.RES_DOUBLES * 8 + nl.RES_PEAKS * 4
                    + 2 * nl.RES_PEAKS * nl.SIZEOF_REAL
  local blk_bytes = (nl.FIND_WORDS or 0) * 4 + (nl.PX_WORDS or 0) * 4
  nl.nseg_ceil = math.floor((nl.CHUNK_BYTES - 32 - res_bytes - blk_bytes)
                            / (2 * nl.SIZEOF_REAL))
  if want_n > nmax or want_nseg < 2 or want_nseg > nl.nseg_ceil then
    trace('size.refused', want_n, want_nseg)
    return nl._no('size refused: n=' .. tostring(want_n) .. ' max=' .. tostring(nmax)
                  .. ' nseg=' .. tostring(want_nseg) .. ' ceil=' .. tostring(nl.nseg_ceil))
  end

  -- Resolve all six libm entry points.
  trace('math')
  local nmath = nl.resolve_math()
  if nmath < 6 then
    return nl._no('resolve_math found ' .. tostring(nmath) .. ' of 6 libm entries: glue='
                  .. tostring(nl.nglue) .. ' need>=' .. tostring(nl.GLUE_MIN)
                  .. ' mathpos=' .. tostring(nl.math_pos) .. ' odd=' .. tostring(nl.math_odd))
  end
  trace('math.ok')

  -- Locate the ki.peek8 closure and its original function pointer.
  local s = tostring(ki.peek8)
  local _, e = string.find(s, ': ')
  if not e then return nl._no('ki.peek8 does not tostring to an address: ' .. tostring(s)) end
  local cls = tonumber(string.sub(s, e + 1), 16)
  if not cls then return nl._no('ki.peek8 address will not parse as hex: ' .. tostring(s)) end
  -- Require two matching reads of the restore pointer and confirm its .text range.
  local orig_f = W(cls + 12)
  if orig_f == nil then
    return nl._no('cannot read the ki.peek8 f pointer at ' .. hx(cls + 12))
  end
  if not fftsa.nl._text_ok(orig_f) then
    return nl._no('ki.peek8 f pointer ' .. hx(orig_f) .. ' is outside .text '
                  .. hx(nl.TEXT_LO) .. '..' .. hx(nl.TEXT_HI))
  end
  if W(cls + 12) ~= orig_f then
    return nl._no('the ki.peek8 f pointer read back differently: transport is unreliable')
  end
  nl.peek8_cls = cls
  nl.peek8_f   = orig_f

  -- Allocate one full chunk for code, params and trampoline.
  local cb = buffer.make(1024, buffer.STYLE_WRITABLE_FULL)
  buffer.write.format(cb, buffer.UNIT_VOLT, buffer.DIGITS_6_5,
                      buffer.UNIT_VOLT, buffer.DIGITS_6_5)
  local k
  for k = 1, fftsa.nl.SEED_READS do
    buffer.write.reading(cb, 1000000 + k, 3000000 + k, k, 0)
  end

  -- Issue the barrier on the seeded code buffer: an empty buffer can skip the task round-trip.
  if barrier_buf ~= nil and barrier_buf.n == nil then
    return fftsa.nl._abort(cb, nil, 'the barrier buffer passed in has no n: it is not a '
                           .. 'live reading buffer')
  end
  local bar = cb
  if bar.n == nil or bar.n < 1 then
    return fftsa.nl._abort(cb, nil, 'the code buffer seeded to ' .. tostring(bar.n)
                           .. ' readings, so buffer.write.reading is not storing')
  end
  buffer.getstats(bar)

  trace('scan.code')
  local code_base, code_stride = nl._find_storage(cb, true)
  if code_stride ~= nil and code_stride ~= 32 then
    trace('code.stride.BAD', code_stride)
    return fftsa.nl._abort(cb, nil, 'the code buffer element is ' .. tostring(code_stride)
                           .. ' bytes, not 32, so the trampoline and params layout inside '
                           .. 'its chunk has moved')
  end
  if not code_base then
    return fftsa.nl._abort(cb, nil, 'code buffer: no storage found -- '
                           .. tostring(nl._stor_why) .. ' inst=' .. hx(nl.inst or 0)
                           .. ' ' .. fftsa.nl.windows_str())
  end
  trace('code_base', hx(code_base))
  nl.code_buf  = cb
  nl.code_base = code_base

  -- Derive the load layout from image size and ABI metadata. Keep the trampoline on separate
  -- cache lines from the native code it invalidates.
  local img_span   = align8(nl._DSP_RELOC_BSS_HI)
  if img_span < align8(string.len(nl._DSP_CODE)) then
    img_span = align8(string.len(nl._DSP_CODE))
  end
  local tramp_at   = align32(code_base + img_span)
  local params_at  = tramp_at + align8(string.len(nl._TRAMP))
  local span       = (params_at - code_base) + nl.PARAM_WORDS * 4
  if span > nl.CHUNK_BYTES then
    return fftsa.nl._abort(cb, nil, 'the image, trampoline and params need '
                           .. tostring(span) .. ' bytes of a ' .. tostring(nl.CHUNK_BYTES)
                           .. '-byte chunk')
  end
  nl.params = params_at
  trace('layout', hx(tramp_at), hx(params_at))

  -- Install the trampoline first and verify its bytes before branching to it.
  NLBOOT = tramp_at
  trace('tramp.write', hx(tramp_at), string.len(nl._TRAMP))
  ki.memwrite(hx(tramp_at), nl._TRAMP)
  buffer.getstats(bar)

  local back = ki.memread(hx(tramp_at), hx(string.len(nl._TRAMP)))
  if back ~= nl._TRAMP then
    trace('tramp.readback.BAD', (back == nil) and 'nil' or string.len(back))
    return fftsa.nl._abort(cb, nil, 'the trampoline read back '
                           .. ((back == nil) and 'nil' or tostring(string.len(back)))
                           .. ' bytes of ' .. tostring(string.len(nl._TRAMP))
                           .. ' at ' .. hx(tramp_at) .. ': the write landed elsewhere')
  end
  trace('tramp.readback.ok')

  nl.tramp = tramp_at
  -- Do not flush the trampoline with itself; the code flush must exclude its cache lines.
  trace('tramp.ok')

  local img, err = nl.relocate(nl._DSP_CODE, nl._DSP_RELOC, code_base,
                               nl._DSP_RELOC_BSS_HI)
  if img == nil then
    return fftsa.nl._abort(cb, nil, 'relocation refused: ' .. tostring(err))
  end
  trace('img.reloc', string.len(img))
  -- Patch the params pointer before writing the image; verify the slot before the first call.
  if nl.PARAMS_SLOT == nil or nl.PARAMS_SLOT == 0 or
     nl.PARAMS_SLOT + 4 > string.len(img) then
    trace('params.slot.BAD', tostring(nl.PARAMS_SLOT))
    return fftsa.nl._abort(cb, nil, 'the params slot is ' .. tostring(nl.PARAMS_SLOT)
                           .. ' in an image of ' .. tostring(string.len(img))
                           .. ': the generated module does not match the image')
  end
  img = string.sub(img, 1, nl.PARAMS_SLOT) .. u32_pack(params_at) ..
        string.sub(img, nl.PARAMS_SLOT + 5)
  trace('params.slot', nl.PARAMS_SLOT, hx(params_at))
  ki.memwrite(hx(code_base), img)

  local slot = ki.memread(hx(code_base + nl.PARAMS_SLOT), hx(4))
  if slot == nil or string.len(slot) < 4 or u32_at(slot, 1) ~= params_at then
    trace('params.slot.readback.BAD', (slot == nil) and 'nil' or hx(u32_at(slot, 1)))
    return fftsa.nl._abort(cb, nil, 'the params slot read back '
                           .. ((slot == nil) and 'nil' or hx(u32_at(slot, 1)))
                           .. ' and not ' .. hx(params_at) .. ': the image landed wrong')
  end
  buffer.getstats(bar)
  -- Flush only the image range, not the trampoline range.
  trace('img.flush')
  nl.flushed = flush(code_base, string.len(img))
  trace('img.flush.ok', tostring(nl.flushed))
  nl.entry = code_base
  trace('img.ok')

  -- Ask the image how many arena chunks the configuration requires.
  nl.write_params({ mode = nl.MODE_SEGS, cap_n = want_n,
                    seg_bytes = nl.SEG_BYTES,
                    init_decim = decim or 1, init_method = method or 0 })
  trace('call.segs', hx(code_base), hx(nl.params))
  local nseg = call_native(code_base)
  trace('call.segs.ret', tostring(nseg))
  if type(nseg) ~= 'number' or nseg <= 0 then
    nl.nmax = 0
    return fftsa.nl._abort(cb, nil, 'MODE_SEGS answered ' .. tostring(nseg)
                           .. ' segments for n=' .. tostring(want_n) .. ' at '
                           .. tostring(nl.SEG_BYTES) .. ' bytes a segment: no chunk holds '
                           .. 'one of the arrays')
  end

  -- Allocate arena chunks, a plan chunk and a shared reduction/scratch chunk.
  local chunks_wanted = nseg + 2
  local pb = buffer.make(chunks_wanted * 1024, buffer.STYLE_WRITABLE_FULL)
  buffer.write.format(pb, buffer.UNIT_VOLT, buffer.DIGITS_6_5,
                      buffer.UNIT_VOLT, buffer.DIGITS_6_5)
  for k = 1, fftsa.nl.SEED_READS do
    buffer.write.reading(pb, 2000000 + k, 4000000 + k, k, 0)
  end
  buffer.getstats(bar)

  trace('scan.plan')
  local pdesc = nl.describe(pb, true)
  if pdesc == nil or pdesc.vec == nil then
    return fftsa.nl._abort(cb, pb, 'plan: ' .. tostring(nl._stor_why)
                           .. ' want=' .. tostring(chunks_wanted) .. 'ch for '
                           .. tostring(nseg) .. 'seg')
  end
  trace('plan.desc', hx(pdesc.chunk1), tostring(pdesc.nchunks))

  -- Validate the vector length before reading payload pointers.
  if nl.chunk_span ~= nil and nl.chunk_span ~= nl.CHUNK_BYTES then
    return fftsa.nl._abort(cb, pb, 'this model has a ' .. tostring(nl.chunk_span)
                           .. '-byte chunk payload, not ' .. tostring(nl.CHUNK_BYTES)
                           .. ' -- elemsize=' .. tostring(pdesc.elemsize)
                           .. ' perchunk=' .. tostring(pdesc.perchunk))
  end
  if pdesc.nchunks == nil or pdesc.nchunks < chunks_wanted then
    return fftsa.nl._abort(cb, pb, 'plan buffer has ' .. tostring(pdesc.nchunks)
                           .. ' chunks, needs ' .. tostring(chunks_wanted))
  end
  nl.plan_buf = pb

  -- The chunk vector supplies payload addresses in logical order, not address order.
  local payload = {}
  local i
  for i = 1, chunks_wanted do
    local a = W(pdesc.vec + (i - 1) * 4)
    if a == nil or a == 0 then
      return fftsa.nl._abort(cb, pb, 'chunk ' .. tostring(i) .. ' of '
                             .. tostring(chunks_wanted) .. ' is a null payload')
    end
    if a < nl.BACKSTOP_LO or a + nl.CHUNK_BYTES > nl.BACKSTOP_HI then
      return fftsa.nl._abort(cb, pb, 'chunk ' .. tostring(i) .. ' at ' .. hx(a)
                             .. ' is outside the backstop ' .. hx(nl.BACKSTOP_LO)
                             .. '..' .. hx(nl.BACKSTOP_HI))
    end
    payload[i] = a
  end

  -- Align arena bases to DSP_ALIGN inside the allocated payloads.
  local segbase = {}
  for i = 1, nseg do
    segbase[i] = align32(payload[i])
    if (segbase[i] - payload[i]) + nl.SEG_BYTES > nl.CHUNK_BYTES then
      return fftsa.nl._abort(cb, pb, 'segment ' .. tostring(i) .. ': ' .. tostring(nl.SEG_BYTES)
                             .. ' bytes will not fit a chunk after 32-byte alignment')
    end
  end

  -- Lay out the arena, plan, reduction, results and scratch in the checked chunk windows.
  local host      = align32(payload[nseg + 1])
  local plan_addr = host
  if (host - payload[nseg + 1]) + align8(nl.SIZEOF_PLAN) > nl.CHUNK_BYTES then
    return fftsa.nl._abort(cb, pb, 'plan struct of ' .. tostring(nl.SIZEOF_PLAN)
                           .. ' bytes will not fit a chunk')
  end

  local red_host = align32(payload[nseg + 2])
  local red_db   = red_host
  local red_hz   = red_host + want_nseg * nl.SIZEOF_REAL
  -- Align the results block for double stores.
  local res_addr = red_hz + want_nseg * nl.SIZEOF_REAL
  local find_bytes = (nl.FIND_WORDS or 0) * 4
  local find_addr = res_addr + res_bytes
  local px_bytes = (nl.PX_WORDS or 0) * 4
  local px_addr = find_addr + find_bytes
  if (res_addr - payload[nseg + 2]) + res_bytes + find_bytes + px_bytes > nl.CHUNK_BYTES then
    return fftsa.nl._abort(cb, pb, 'reduction arrays plus a ' .. tostring(res_bytes)
                           .. '-byte results block, a ' .. tostring(find_bytes)
                           .. '-byte find block and a ' .. tostring(px_bytes)
                           .. '-byte ring block will not fit a chunk')
  end

  -- Store the segment vector in the code buffer after the params.
  local segs_addr = nl.params + align8(nl.PARAM_WORDS * 4)
  if (segs_addr - code_base) + nseg * 4 > nl.CHUNK_BYTES then
    return fftsa.nl._abort(cb, pb, 'the ' .. tostring(nseg)
                           .. '-entry segment vector will not fit above the params struct')
  end
  local sv = {}
  for i = 1, nseg do sv[i] = u32_pack(segbase[i]) end
  trace('segs.write', hx(segs_addr), nseg)
  ki.memwrite(hx(segs_addr), table.concat(sv))

  -- The writable window must cover all payloads; individual chunks need not be contiguous.
  local lo, hi = payload[1], payload[1]
  for i = 2, chunks_wanted do
    if payload[i] < lo then lo = payload[i] end
    if payload[i] > hi then hi = payload[i] end
  end
  nl.wr_lo = lo
  nl.wr_hi = hi + nl.CHUNK_BYTES

  nl.write_params({
    mode = nl.MODE_INIT,
    wr_lo = nl.wr_lo, wr_hi = nl.wr_hi,
    rd_lo = nl.wr_lo, rd_hi = nl.wr_hi,
    out_lo = nl.wr_lo, out_hi = nl.wr_hi,
    seg_bytes = nl.SEG_BYTES, nsegs = nseg, segs_addr = segs_addr,
    plan_addr = plan_addr, cap_n = want_n,
    init_kind = kind or 1,
    init_beta_milli = math.floor((beta or 0) * 1000),
    init_decim = decim or 1, init_method = method or 0,
  })
  trace('call.init')
  local rc = call_native(code_base)
  trace('call.init.ret', tostring(rc))
  nl.last_rc = rc
  if rc ~= 0 then
    return fftsa.nl._abort(cb, pb, 'MODE_INIT refused with rc=' .. nl.rc_name(rc))
  end

  nl.plan_addr = plan_addr
  nl.seg_bytes = nl.SEG_BYTES
  nl.nsegs     = nseg
  nl.segs_addr = segs_addr
  nl.red_db    = red_db
  nl.red_hz    = red_hz
  nl.res_addr  = res_addr
  nl.find_addr = find_addr
  nl.px_addr   = px_addr
  nl.nseg_max  = want_nseg
  nl.kind      = kind or 1
  nl.beta      = beta or 0
  nl.decim     = decim or 1
  nl.method    = method or 0
  nl.n         = want_n
  nl.nmax      = want_n
  nl.ready     = true
  nl.stash()
  trace('done')
  return true
end

-- Stash the live buffers and ABI metadata across script reloads; reattach validates before reuse.
function fftsa.nl.stash()
  local nl, out = fftsa.nl, {}
  local k, v
  for k, v in pairs(nl) do
    local t = type(v)
    if t == 'number' or t == 'string' or t == 'boolean' then
      out[k] = v
    elseif k == 'fn' and t == 'table' then
      local fn, k2, v2 = {}, nil, nil
      for k2, v2 in pairs(v) do
        if type(v2) == 'number' then fn[k2] = v2 end
      end
      out[k] = fn
    elseif k == 'code_buf' or k == 'plan_buf' or k == '_stor_of' then
      out[k] = v
    end
  end
  NLSTASH = out
  return true
end

-- Read capacity under pcall to check whether firmware still owns a buffer handle.
local function buf_alive(b)
  if b == nil then return false end
  local ok, cap = pcall(function() return b.capacity end)
  return ok and type(cap) == 'number' and cap > 0
end

-- Reattach only if the stored buffers, code and pointers still validate; rebuild the plan in place.
function fftsa.nl.reattach(want_n, kind, beta, decim, method)
  local nl = fftsa.nl
  local s = NLSTASH
  if type(s) ~= 'table' then return false end
  if s.entry == nil or s.params == nil or s.tramp == nil or s.code_base == nil
     or s.PARAMS_SLOT == nil or s.TRAMP_RANGE == nil or s._TRAMP == nil then
    return false
  end
  if not buf_alive(s.code_buf) or not buf_alive(s.plan_buf) then
    trace('reattach.dead')
    return false
  end
  -- Check the trampoline bytes before making any call through the recovered install.
  local want = s._TRAMP
  local got = ki.memread(hx(s.tramp), hx(string.len(want)))
  local head, tail = s.TRAMP_RANGE, s.TRAMP_RANGE + 9
  if string.len(got) ~= string.len(want)
     or string.sub(got, 1, head) ~= string.sub(want, 1, head)
     or string.sub(got, tail) ~= string.sub(want, tail) then
    trace('reattach.tramp', hx(s.tramp))
    return false
  end
  local slot = W(s.code_base + s.PARAMS_SLOT)
  if slot ~= s.params then
    trace('reattach.params', hx(slot or 0))
    return false
  end
  local k, v
  for k, v in pairs(s) do nl[k] = v end
  nl.ready = false
  if not nl.reinit(want_n or s.n, kind, beta, decim, method) then
    trace('reattach.replan', tostring(nl.last_rc))
    nl.ready = false
    return false
  end
  trace('reattach.ok', hx(s.entry))
  return true
end

-- Replan in the original arena without reinstalling the image.
function fftsa.nl.reinit(want_n, kind, beta, decim, method)
  local nl = fftsa.nl
  if nl.entry == nil or nl.entry == 0 then return false end
  if nl.plan_addr == nil or nl.segs_addr == nil or nl.nsegs == nil then return false end
  want_n = want_n or nl.n
  if nl.nmax == nil or want_n > nl.nmax or want_n < 2 then return false end
  kind   = kind or nl.kind
  beta   = beta or nl.beta
  decim  = decim or nl.decim
  method = method or nl.method

  nl.ready = false
  local ok = nl.write_params({
    mode = nl.MODE_INIT,
    wr_lo = nl.wr_lo, wr_hi = nl.wr_hi,
    rd_lo = nl.wr_lo, rd_hi = nl.wr_hi,
    out_lo = nl.wr_lo, out_hi = nl.wr_hi,
    seg_bytes = nl.seg_bytes, nsegs = nl.nsegs, segs_addr = nl.segs_addr,
    plan_addr = nl.plan_addr, cap_n = want_n,
    init_kind = kind,
    init_beta_milli = math.floor(beta * 1000),
    init_decim = decim, init_method = method,
  })
  if not ok then return false end
  local rc = call_native(nl.entry)
  nl.last_rc = rc
  if rc ~= 0 then return false end
  nl.n      = want_n
  nl.kind   = kind
  nl.beta   = beta
  nl.decim  = decim
  nl.method = method
  nl.ready  = true
  return true
end

-- Pass the capture geometry to native DSP and return its plotted segment count or refusal.
function fftsa.nl.call_dsp(cap, out, red)
  local nl = fftsa.nl
  if not nl.ready then return nil end
  if cap == nil or red == nil then return nil end
  -- A chunk vector is required because native DSP reads capture data in place.
  if cap.vec == nil or cap.nchunks == nil or cap.nchunks < 1 then return nil end
  local ns = red.nseg
  if ns == nil or ns < 1 or nl.nseg_max == nil or ns > nl.nseg_max then return nil end
  if red.binhz == nil or not (red.binhz > 0) then return nil end
  if red.k0 == nil or red.k1 == nil or red.k0 < 0 or red.k1 < red.k0 then return nil end
  if red.dbmin == nil or red.dbmax == nil or not (red.dbmin < red.dbmax) then return nil end
  -- A nil output requests reduction only; Lua owns graph scheduling.
  local out_lo, out_hi, out_ch1, out_ch2, out_per, out_desc = 0, 0, 0, 0, 0, 0
  if out ~= nil then
    out_lo, out_hi = out.lo, out.hi
    out_ch1, out_ch2, out_per, out_desc = out.chunk1, out.chunk2, out.perchunk, out.desc
    if out_desc == nil or out_desc == 0 then return nil end
    -- Direct cursor writes require descriptor offsets matching those compiled into the image.
    if not nl.desc_off_ok(out) then return nil end
  end

  local ok = nl.write_params({
    mode = nl.MODE_RUN,
    wr_lo = nl.wr_lo, wr_hi = nl.wr_hi,
    rd_lo = cap.lo, rd_hi = cap.hi,
    out_lo = out_lo, out_hi = out_hi,
    seg_bytes = nl.seg_bytes, nsegs = nl.nsegs, segs_addr = nl.segs_addr,
    plan_addr = nl.plan_addr,
    cap_chunk1 = cap.chunk1,
    cap_n = nl.n, cap_perchunk = cap.perchunk, cap_stride = cap.elemsize,
    cap_vec = cap.vec, cap_nchunks = cap.nchunks,
    out_chunk1 = out_ch1, out_chunk2 = out_ch2,
    out_perchunk = out_per, out_desc = out_desc,
    red_nseg = ns, red_k0 = red.k0, red_k1 = red.k1,
    red_db = nl.red_db, red_hz = nl.red_hz,
    red_sense = red.sense or 1,
    red_f0 = red.f0 or 0, red_binhz = red.binhz,
    red_dbmin = red.dbmin, red_dbmax = red.dbmax,
    red_vfloor = red.vfloor or 0,
    res_addr = nl.res_addr,
    res_npk = red.npk or 0,
    res_mains = red.mains or nl.MAINS_BOTH,
  })
  if not ok then return nil end

  local r = call_native(nl.entry)
  nl.last_rc = r
  if type(r) ~= 'number' or r < 0 then return nil end
  return r
end

-- Native search scans a bounded slice and returns progress plus candidate addresses.
fftsa.nl.NFIND_PAT_MAX = 16
-- Search needles are word-aligned, so native comparisons advance four bytes.
fftsa.nl.NFIND_STEP = 4
fftsa.nl._nf_mul = { 16777216, 65536, 256, 1 }

function fftsa.nl.nfind(lo, hi, pat, cap)
  local nl = fftsa.nl
  nl.find_why = nil
  if not nl.ready or nl.entry == nil or nl.entry == 0 then
    nl.find_why = 'no native image'
    return nil
  end
  if nl.find_addr == nil or nl.find_addr == 0 or (nl.FIND_WORDS or 0) == 0 then
    nl.find_why = 'no find block reserved'
    return nil
  end
  if type(pat) ~= 'string' then
    nl.find_why = 'needle is not a string'
    return nil
  end
  local plen = string.len(pat)
  if plen < 1 or plen > nl.NFIND_PAT_MAX then
    nl.find_why = 'needle is ' .. tostring(plen) .. ' bytes, not 1..'
                  .. tostring(nl.NFIND_PAT_MAX)
    return nil
  end
  if type(lo) ~= 'number' or type(hi) ~= 'number' or hi <= lo then
    nl.find_why = 'range is not lo < hi'
    return nil
  end
  -- Pack the needle into big-endian words with the first byte in the high bits.
  local pw, i = { 0, 0, 0, 0 }, nil
  for i = 1, plen do
    local wi = math.floor((i - 1) / 4) + 1
    pw[wi] = pw[wi] + string.byte(pat, i) * nl._nf_mul[math.mod(i - 1, 4) + 1]
  end
  -- Keep the scan step explicit; clamp alignment and progress to the actual span.
  local step = nl.NFIND_STEP or 1
  if step == 4 and math.mod(lo, 4) ~= 0 then
    local up = lo + (4 - math.mod(lo, 4))
    if up + plen > hi then
      nl.find_why = 'range too short to align'
      return {}, hi
    end
    lo = up
  end
  ki.memwrite(hx(nl.find_addr),
              u32_pack(lo) .. u32_pack(hi) .. u32_pack(cap or 0)
              .. u32_pack(plen + step * 65536)
              .. u32_pack(pw[1]) .. u32_pack(pw[2]) .. u32_pack(pw[3]) .. u32_pack(pw[4]))
  if not nl.write_params({ mode = nl.MODE_FIND, find_addr = nl.find_addr }) then
    nl.find_why = 'write_params refused'
    return nil
  end
  local n = nl.call_native(nl.entry)
  if type(n) ~= 'number' or n < 0 then
    nl.find_why = 'rc=' .. tostring(n) .. ' at line ' .. tostring(nl.fail_at)
    return nil
  end
  if n > (nl.FIND_MAX or 0) then
    nl.find_why = 'image reported ' .. tostring(n) .. ' hits, over FIND_MAX'
    return nil
  end
  local got = ki.memread(hx(nl.find_addr + 32), hx(8 + n * 4))
  if got == nil or string.len(got) < 8 then
    nl.find_why = 'could not read the answer back'
    return nil
  end
  local out, k = {}, nil
  for k = 1, n do out[k] = u32_at(got, 9 + (k - 1) * 4) end
  nl.nfind_calls = (nl.nfind_calls or 0) + 1
  return out, u32_at(got, 1)
end

-- Decode the ranked peaks and distortion results separately from the trace.
function fftsa.nl.results()
  local nl = fftsa.nl
  if nl.res_addr == nil or nl.RES_DOUBLES == 0 then return nil end
  local nbytes = nl.RES_DOUBLES * 8
  local s = ki.memread(hx(nl.res_addr), hx(nbytes))
  if s == nil or string.len(s) ~= nbytes then return nil end
  if nl._res == nil then
    nl._res = { hz = {}, v = {} }
  end
  local r  = nl._res
  local np = nl.RES_PEAKS
  local sc = 2 * np * 8 + 1              -- first scalar, 1-based byte offset
  local npk = f64_unpack(s, sc)
  if npk == nil or npk < 0 then npk = 0 end
  if npk > np then npk = np end
  local i
  for i = 1, npk do
    r.v[i]  = f64_unpack(s, (2 * i - 2) * 8 + 1)
    r.hz[i] = f64_unpack(s, (2 * i - 1) * 8 + 1)
  end
  for i = npk + 1, np do
    r.v[i], r.hz[i] = nil, nil
  end
  r.npk   = npk
  r.thd   = nil
  r.snr   = nil
  r.noise = nil
  if f64_unpack(s, sc + 16) == 1 then r.thd   = f64_unpack(s, sc + 8)  end
  if f64_unpack(s, sc + 32) == 1 then r.snr   = f64_unpack(s, sc + 24) end
  if f64_unpack(s, sc + 48) == 1 then r.noise = f64_unpack(s, sc + 40) end
  r.f0_hz = f64_unpack(s, sc + 56)
  r.amp0  = f64_unpack(s, sc + 64)
  r.nbins = f64_unpack(s, sc + 72)
  return r
end

local function red_unpack()
  local sz = fftsa.nl.SIZEOF_REAL
  if sz == 8 then return f64_unpack, 8 end
  if sz == 4 then return f32_unpack, 4 end
  return nil, nil
end

-- Keep packed dB until the Lua writer or append path actually needs those values.
fftsa.nl._db_none = {}

local function db_failed()
  local nl = fftsa.nl
  nl.db_fails = (nl.db_fails or 0) + 1
  return nil
end

-- Decode dB from the captured reduction, not from a newer frame's native array.
function fftsa.nl.reduce_db()
  local nl = fftsa.nl
  local r = nl._red
  if r == nil or r.nseg == nil or nl.red_db == nil then return nil end
  if r.db ~= nil and r.db ~= nl._db_none then return r.db end
  local f_unpack, sz = red_unpack()
  if f_unpack == nil then return nil end
  local nseg = r.nseg
  local nbytes = nseg * sz
  local sd = ki.memread(hx(nl.red_db), hx(nbytes))
  if sd == nil or string.len(sd) ~= nbytes then return db_failed() end
  if r.db_buf == nil then r.db_buf = {} end
  local db = r.db_buf
  local i, p = nil, 1
  for i = 1, nseg do
    local v = f_unpack(sd, p)
    if v == nil then return db_failed() end
    db[i] = v
    p = p + sz
  end
  r.db = db
  return db
end

function fftsa.nl.db_now(db)
  local nl = fftsa.nl
  local r = nl._red
  if r ~= nil and r.nseg ~= nil then
    if r.db ~= nil and r.db ~= nl._db_none then return r.db end
    return nl.reduce_db()
  end
  if db ~= nil and db[1] ~= nil then return db end
  return nil
end

-- Return the reduced trace. The native writer can consume dB in place; Lua reconstructs
-- the affine frequency series from the same reduction parameters.
function fftsa.nl.reduce(nseg, want_db)
  local nl = fftsa.nl
  if nl.red_db == nil or nl.red_hz == nil then return nil end
  if nseg == nil or nl.nseg_max == nil or nseg < 1 or nseg > nl.nseg_max then return nil end
  local f_unpack, sz = red_unpack()
  if f_unpack == nil then return nil end
  local nbytes = nseg * sz
  if nl._red == nil then nl._red = { hz = {} } end
  local r = nl._red
  local hz = r.hz
  local i, p
  local probe = 2 * sz
  if nseg < 2 then probe = sz end
  local sp = ki.memread(hx(nl.red_hz), hx(probe))
  if sp == nil or string.len(sp) ~= probe then return nil end
  local h1 = f_unpack(sp, 1)
  local h2 = nil
  if nseg >= 2 then h2 = f_unpack(sp, 1 + sz) end
  if h1 == nil or (nseg >= 2 and h2 == nil) then return nil end
  -- Include real width in the cache key so float and double images cannot reuse the same decode.
  if r.hz_nseg ~= nseg or r.hz_at ~= nl.red_hz or r.hz_sz ~= sz
     or r.hz_1 ~= h1 or r.hz_2 ~= h2 then
    -- Clear stale output before attempting a new decode.
    r.hz_nseg, r.hz_at, r.hz_sz, r.hz_1, r.hz_2 = nil, nil, nil, nil, nil
    local sf = ki.memread(hx(nl.red_hz), hx(nbytes))
    if sf == nil or string.len(sf) ~= nbytes then return nil end
    p = 1
    for i = 1, nseg do
      local f = f_unpack(sf, p)
      if f == nil then return nil end
      hz[i] = f
      p = p + sz
    end
    r.hz_nseg, r.hz_at, r.hz_sz = nseg, nl.red_hz, sz
    r.hz_1, r.hz_2 = h1, h2
  end
  r.nseg = nseg
  r.db = nl._db_none
  if want_db == nil or want_db then
    if nl.reduce_db() == nil then return nil end
  end
  return r
end

-- Prove the descriptor arithmetic against firmware readings at each touched chunk boundary
-- and the final element, not just the matching first word.
fftsa.nl.GEOM_CHUNKS_MAX = 32          -- DSP_MAX_SRC_BLOCKS; a record cannot span more

fftsa.nl.ES_CANDIDATES = { 8, 12, 16, 20, 24, 28, 32, 36, 40, 44, 48 }

-- Test element sizes against the second chunk boundary to diagnose a stride mismatch.
function fftsa.nl._es_fit(buf, d)
  local nl = fftsa.nl
  if buf == nil or d == nil or d.vec == nil then return nil end
  local n = buf.n
  if type(n) ~= 'number' then return nil end
  local c1 = nl._wg(d.vec + 4)
  if c1 == nil or c1 == 0 then return nil end
  local i
  for i = 1, table.getn(nl.ES_CANDIDATES) do
    local es = nl.ES_CANDIDATES[i]
    local pc = math.floor(nl.CHUNK_BYTES / es)
    if pc >= 1 and pc < n then
      local v = buf.readings[pc + 1]
      if v ~= nil and eq64(c1, v) then return es, pc end
    end
  end
  return nil
end

function fftsa.nl.geom_ok(buf, d)
  local nl = fftsa.nl
  nl._geom_why, nl._geom_n = nil, nil
  if buf == nil or d == nil then return true end
  local n, pc, es = buf.n, d.perchunk, d.elemsize
  if type(n) ~= 'number' or type(pc) ~= 'number' or type(es) ~= 'number' then return true end
  if n < 1 or pc < 1 or es < 8 then return true end
  -- Use the same block/element arithmetic as native DSP, including the actual element-zero offset.
  local function at(j)
    local k = math.floor(j / pc)
    if k == 0 then return d.chunk1 + j * es end
    if d.vec == nil or k >= nl.GEOM_CHUNKS_MAX then return nil end
    local b = W(d.vec + k * 4)
    if b == nil or b == 0 then return nil end
    return b + math.mod(j, pc) * es
  end
  local want, nw = {}, 0
  local j = 0
  while j < n and nw < nl.GEOM_CHUNKS_MAX do
    nw = nw + 1; want[nw] = j
    j = j + pc
  end
  local last0 = pc - 1
  if last0 >= n then last0 = n - 1 end
  if last0 > 0 then nw = nw + 1; want[nw] = last0 end
  local i
  for i = 1, nw do
    j = want[i]
    local v = buf.readings[j + 1]
    local a = at(j)
    if v == nil then
      nl._geom_why = 'reading ' .. tostring(j + 1) .. ' of ' .. tostring(n) .. ' reads nil'
      return false
    end
    if a == nil then
      nl._geom_why = 'no chunk for element ' .. tostring(j) .. ' pc=' .. tostring(pc)
      return false
    end
    if not eq64(a, v) then
      nl._geom_why = 'reading ' .. tostring(j + 1) .. ' is not at ' .. hx(a)
                     .. ' for es=' .. tostring(es) .. ' pc=' .. tostring(pc)
      local fes, fpc = nl._es_fit(buf, d)
      if fes ~= nil then
        nl._geom_why = nl._geom_why .. ' -- fits es=' .. tostring(fes)
                       .. ' pc=' .. tostring(fpc)
      end
      return false
    end
  end
  nl._geom_n = nw
  return true
end

function fftsa.nl.describe(buf, has_extras)
  -- Cache the storage proof and descriptor separately; each has a different identity key.
  local nl = fftsa.nl
  local elem0, stride
  local sdesc, selemsize, sperchunk, svec, snchunks
  if nl._stor_of == buf and nl._stor_x == has_extras and nl._stor_elem0 ~= nil then
    elem0, stride = nl._stor_elem0, nl._stor_stride
  else
    nl._stor_of, nl._stor_x, nl._stor_elem0, nl._stor_stride = nil, nil, nil, nil
    nl._stor_why = nil
    -- Capture buffers have no extra values, so try their capacity/count signature first.
    if not has_extras then
      local b, e0, es, pc, v, nc = nl._find_desc_by_sig(buf)
      if b ~= nil then
        elem0, stride = e0, es
        sdesc, selemsize, sperchunk, svec, snchunks = b, es, pc, v, nc
      end
    end
    if elem0 == nil then elem0, stride = nl._find_storage(buf, has_extras) end
    if elem0 then
      nl._stor_of, nl._stor_x = buf, has_extras
      nl._stor_elem0, nl._stor_stride = elem0, stride
    end
  end
  if not elem0 then
    nl.desc_report_reset(buf)
    return nil
  end
  local desc, elemsize, perchunk, vec, nchunks = sdesc, selemsize, sperchunk, svec, snchunks
  if desc == nil then
    -- Feed the independently measured stride into descriptor layout derivation.
    desc, elemsize, perchunk, vec, nchunks = fftsa.nl._find_desc(elem0, buf, stride)
  end
  if not desc then
    nl._stor_why = 'no descriptor for elem0=' .. hx(elem0) .. ' stride=' .. tostring(stride)
    return nil
  end
  -- The content-scan stride and descriptor element size must agree.
  if elemsize ~= stride then
    nl._stor_why = 'elemsize ' .. tostring(elemsize) .. ' disagrees with stride '
                   .. tostring(stride) .. ' at elem0=' .. hx(elem0)
    return nil
  end
  -- Cover every scattered payload in the readable window, not just the first chunk.
  local ch2 = 0
  local lo  = elem0
  local hi  = elem0 + fftsa.nl.CHUNK_BYTES
  if vec ~= nil and nchunks ~= nil and nchunks >= 1 then
    local i
    for i = 1, nchunks do
      local a = W(vec + (i - 1) * 4)
      if a == nil or a == 0 then
        nl._stor_why = 'chunk ' .. tostring(i) .. ' of ' .. tostring(nchunks) .. ' reads '
                       .. tostring(a) .. ' at vec=' .. hx(vec)
        return nil
      end
      if a < lo then lo = a end
      if a + fftsa.nl.CHUNK_BYTES > hi then hi = a + fftsa.nl.CHUNK_BYTES end
      if i == 2 then ch2 = a end
    end
  end
  -- Carry the validated layout with the descriptor so write permission is checked per buffer.
  local d = { chunk1 = elem0, chunk2 = ch2, perchunk = perchunk,
              elemsize = elemsize, desc = desc, vec = vec, nchunks = nchunks,
              lo = lo, hi = hi, doff = nl.doff_used, dderived = nl.desc_off }
  -- Compare computed addresses with live firmware readings before handing geometry to native DSP.
  if not fftsa.nl.geom_ok(buf, d) then
    nl._stor_why = 'geometry does not address the readings -- ' .. tostring(nl._geom_why)
    return nil
  end
  return d
end
