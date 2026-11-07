-- native_link.tsp -- load the native DSP binary into heap and make it callable.
--
-- Called once at startup; sets fftsa.nl.ready when the native path is available. Every
-- failure is recorded and swallowed, and the app reports it from the frame that needs it.
--
-- No firmware address is written down here. The six libm entries come from FNF, which finds
-- them in the code of Lua's own math wrappers; the ki.peek8 closure and its f pointer come
-- from tostring and a read; the trampoline is self-contained PowerPC that flushes the cache
-- itself. Neither it nor the image reads the Lua stack, and what the call reports comes back
-- through a word of the params struct.
--
-- What remains firmware-shaped is ranges and layouts, not entry points: the .text extent in
-- TEXT_LO and TEXT_HI, the heap extent the image is compiled with, the closure's f at +12
-- and the reading-buffer descriptor offsets. Every one of those is a test that refuses, so a
-- build that moves them loses the native path.
--
-- Lua 5.0.2: no '#', no hex literals, no multi-return string.byte, math.mod not fmod.

fftsa = fftsa or {}
fftsa.nl = {
  ready     = false,  -- true once the binary is loaded, relocated and the plan is built
  fn        = {},     -- firmware math addresses resolved by FNF
  tramp     = 0,      -- heap address of the cache-flush trampoline
  entry     = 0,      -- heap address of dsp_native_run, which is image offset 0
  code_base = 0,      -- heap address the image is loaded at
  params    = 0,      -- heap address of the dsp_native_params struct
  code_buf  = nil,    -- buffer whose chunk storage holds the image, trampoline, params
  plan_buf  = nil,    -- buffer whose chunk storage holds the plan, arena and scratch
  peek8_cls = 0,      -- ki.peek8 closure address
  peek8_f   = 0,      -- original ki.peek8 f pointer, for restore
  nmax      = 0,      -- largest n the arena found at startup can hold
  last_rc   = nil,    -- status from the most recent native call
}

-- Status codes dsp_native.c writes into the params struct. Non-negative is a result.
fftsa.nl.RC = {
  EMAGIC = -1, EBOUNDS = -2, EPLAN = -3, EGEOM = -4, ECAPTURE = -5,
  EOUTPUT = -6, EDESC = -7, EARENA = -8, ESCRATCH = -9, ERUN = -10, EMATH = -11,
  EREDUCE = -12, ERESULT = -13,
}

-- DSP_THD_MAINS_* from csrc/dsp.h. Hum at a multiple of the selected mains frequency is
-- passed over when the fundamental is sought; BOTH discounts 50 and 60.
fftsa.nl.MAINS_BOTH = -1
fftsa.nl.MAINS_A    = 50
fftsa.nl.MAINS_B    = 60

fftsa.nl.MODE_INIT  = 1
fftsa.nl.MODE_RUN   = 2
fftsa.nl.MODE_BYTES = 3
fftsa.nl.MODE_SEGS  = 4

fftsa.nl.MAGIC = 1146310705   -- 0x44535031, 'DSP1'

-- DSP_FFT_* from csrc/dsp.h. Four-step is the default there and the only one measured on
-- the instrument; radix-2 is kept because the equivalence tests run both.
fftsa.nl.FFT_RADIX2   = 0
fftsa.nl.FFT_FOURSTEP = 1

-- Chunk payload is a fixed 32,768 bytes; 1024 elements follows from 32768/32.
fftsa.nl.CHUNK_BYTES = 32768

-- The allocator only guarantees 16-byte alignment and DSP_ALIGN is 32: measured payload
-- addresses alternate between the two, and dsp_native_run refuses a misaligned segment
-- with DSPN_EBOUNDS, so an arena built straight from the chunk vector is a coin flip.
--
-- Every segment base is therefore rounded up to 32 and the usable size drops by one
-- alignment unit. SEG_BYTES stays a multiple of DSP_ALIGN and rounding up adds at most 31,
-- so align32(payload) + SEG_BYTES never leaves the payload. The same value has to go to
-- MODE_SEGS as to MODE_INIT, or the chunk count is computed for a size the arena lacks.
fftsa.nl.SEG_BYTES = 32768 - 32

local function align32(v) return v + math.mod(32 - math.mod(v, 32), 32) end
fftsa.nl._align32 = align32
fftsa.nl.PARAM_WORDS = 54

-- Overwritten by the generated dsp_native_reloc.lua, which reads them out of the linked
-- image. Not literals to rely on: the target is 32-bit big-endian PowerPC with 4-byte
-- pointers, so sizeof(dsp_plan) is 1024 there against 1120 on a 64-bit host.
fftsa.nl.SIZEOF_PLAN   = 0
fftsa.nl.SIZEOF_PARAMS = 0
fftsa.nl.SIZEOF_REAL   = 0

-- Heap bounds, also overwritten from the image. Zero here so an un-generated module
-- refuses every address rather than accepting every address.
fftsa.nl.HEAP_LO = 0
fftsa.nl.HEAP_HI = 0

-- Shape of the results block, also from the image: the peak slots it holds and the total
-- doubles Lua reads back out of it. Zero until the generated module loads, which makes
-- nl.results() refuse rather than decode a block of some other size.
fftsa.nl.RES_PEAKS   = 0
fftsa.nl.RES_DOUBLES = 0

-- Picker index to DSP_WINDOW_*, the enum in csrc/dsp.h, and a separate map from
-- fftsa.win_dsp, which goes to dsp.WINDOW_*. The two enums coincide today and nothing holds
-- them together, so each side of the seam carries its own map; the window_enum gate
-- compares this table against dsp.h, making a renumbering a build failure rather than a
-- measurement error. Index-parallel to fftsa.win_names.
fftsa.nl.WIN = {}
fftsa.nl.WIN[1] = 1    -- DSP_WINDOW_HANN
fftsa.nl.WIN[2] = 2    -- DSP_WINDOW_BLACKMAN
fftsa.nl.WIN[3] = 3    -- DSP_WINDOW_BLACKMAN_HARRIS
fftsa.nl.WIN[4] = 4    -- DSP_WINDOW_KAISER

-- Falls back to Hann on an index with no mapping, which is what fftsa.win_to_dsp does on
-- the other side. A silent fallback is wrong but bounded; an unmapped nil reaches the
-- params struct as a zero and selects DSP_WINDOW_RECT, which is no window at all.
function fftsa.nl.win_to_native(wi)
  local k = fftsa.nl.WIN[wi]
  if k == nil then k = fftsa.nl.WIN[1] end
  return k
end

-- What localnode.version answered, for a probe to report. Nothing is gated on it.
fftsa.nl.fw_seen = nil

-- The cache-flush trampoline, assembled from csrc/flush_tramp.S: dcbst out of the D-cache,
-- icbi and isync over the same range in the I-cache, in instructions of its own, so it
-- depends on no firmware address. It takes no Lua arguments -- the range is the two words at
-- TRAMP_RANGE, which nl.flush writes before the call and the code reaches through a bl/mflr
-- pair. Position-independent and relocation-free, which csrc/tools/emit_tramp.py checks when
-- it regenerates this literal. The bytes are not editable by hand.
fftsa.nl._TRAMP = '\072\000\000\012\000\000\000\000\000\000\000\000\125\104\002\166\072\000\000\005\125\040\002\166\128\105\255\240\128\137\255\244\125\104\003\166\040\004\000\000\065\130\000\068\124\163\034\020\056\165\000\031\084\165\000\052\084\099\000\052\124\102\027\120\124\000\024\108\056\099\000\032\124\003\040\064\065\128\255\244\124\000\004\172\124\000\055\172\056\198\000\032\124\006\040\064\065\128\255\244\124\000\004\172\076\000\001\044\056\096\000\000\078\128\000\032'
fftsa.nl.TRAMP_RANGE = 4

-- What write_params leaves in the status word, and no exit of dsp_native_run writes. A
-- status still reading this after a call means the call never reached an exit.
fftsa.nl.STATUS_UNSET = 2147483647

-- The compiled image and its relocation table, both generated by
-- csrc/tools/emit_reloc.py and embedded by tools/embed_native.py as base64. Nil means no
-- binary in the archive: nl.init still resolves addresses and installs the trampoline, but
-- leaves nl.ready false.
--
-- _DSP_CODE and _DSP_RELOC are the decoded bytes, filled once by nl.init.
fftsa.nl._DSP_CODE = nil
fftsa.nl._DSP_RELOC = nil
fftsa.nl._DSP_CODE_B64 = nil
fftsa.nl._DSP_CODE_B64_LEN = 0
fftsa.nl._DSP_RELOC_B64 = nil
fftsa.nl._DSP_RELOC_B64_LEN = 0
fftsa.nl._DSP_RELOC_BSS_LO = 0
fftsa.nl._DSP_RELOC_BSS_HI = 0

-- ---------------------------------------------------------------------------
-- Base64, so the image costs 1.37 characters a byte in the archive instead of the 4 that
-- decimal escapes take -- Lua 5.0.2 has no \xNN, and the archive's source is parsed at
-- every launch where this is decoded once in nl.init.
--
-- No padding and no tail case: embed_native.py pads the binary to a multiple of three and
-- emits the true length beside it, so this is a flat four-to-three mapping and the length
-- trims the padding. A tail case would be a branch nothing exercises until the day the
-- image length changes residue.
-- ---------------------------------------------------------------------------
local B64A = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
local b64map = nil

-- string.gsub with a function rather than a loop over string.byte: the scan and the
-- assembly both happen in C, so this is one Lua call per four characters. The map is keyed
-- by the character, which is what the captures are, so there is no string.byte at all.
local function b64decode(s, len)
  if s == nil or len == nil then return nil end
  local slen = string.len(s)
  if math.mod(slen, 4) ~= 0 then return nil end
  -- Validated before the substitution and not inside it: a function replacement returning
  -- nil leaves the match in place, so a stray character would pass through as itself.
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

-- ---------------------------------------------------------------------------
-- Byte packing helpers.
-- ---------------------------------------------------------------------------

-- Two's complement for a negative v, which math.mod alone does not give: it is fmod and
-- keeps the sign, so math.mod(-1, 2^32) is -1 and string.char would then be handed -1 and
-- raise. dsp_bandmap.sense is -1 in an odd Nyquist zone, so this is reachable.
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

-- An IEEE-754 binary64 as the two 32-bit halves the target reads it back from, high half
-- first: the params struct is a wire format and Lua 5.0.2 cannot lay out a double, so every
-- double in it crosses as a word pair and pw_double in dsp_native.c reassembles one.
--
-- The arithmetic is exact, every multiply being by a power of two, so the result is the bit
-- pattern a host would have written; csrc/tools/test_f64.lua checks it against struct.pack,
-- signs, infinities and a NaN included. Subnormals flush to zero and an overflowing
-- exponent to an infinity, which nothing crossing here comes near: the smallest value is
-- the squared voltage floor at 1e-18 against a smallest normal of 2.2e-308.
local function f64_words(x)
  local sign = 0
  if x < 0 then sign = 2147483648; x = -x end
  -- A NaN first: it loses every ordered comparison below, so no later test can find it.
  if x ~= x then return sign + 2146959360, 0 end        -- 0x7FF80000, quiet NaN
  if x == 0 then return sign, 0 end
  -- Doubling leaves only zero and an infinity unchanged, and zero is gone. Lua 5.0.2 has
  -- no math.huge to compare against.
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

-- Firmware .text, where a lua_CFunction pointer must land. Anything else written into a
-- closure's f is a jump into data on the next call.
fftsa.nl.TEXT_LO = 16384      -- 0x00004000
fftsa.nl.TEXT_HI = 5402624    -- 0x00527000

function fftsa.nl._text_ok(a)
  return type(a) == 'number' and a >= fftsa.nl.TEXT_LO and a < fftsa.nl.TEXT_HI
end

local function align8(v) return v + math.mod(8 - math.mod(v, 8), 8) end

-- To a cache line. A flush works in whole lines, so anything that must not be invalidated
-- along with the image has to start on a line the image does not reach into.
local function align32(v) return v + math.mod(32 - math.mod(v, 32), 32) end
fftsa.nl._align32 = align32

-- The 32-byte line a byte belongs to, and one past the last line a range touches. The
-- range a flush covers is wider than the range asked for, by up to 31 bytes at each end.
local function line_lo(a) return a - math.mod(a, 32) end
local function line_hi(a, n) return line_lo(a + n - 1) + 32 end

-- Progress breadcrumbs for nl.init, off unless fftsa.nl.trace is set.
--
-- nl.init installs code and then branches into it, so a bluescreen takes the Lua state with
-- the instrument and there is nothing left to ask; a PC on the glass in the heap says only
-- that something executed garbage, and init has three places that branch to a heap address.
-- print() in TSP reaches the socket as the statement runs, so a trace crosses the wire
-- before the crash and the last line received names the step.
local function trace(tag, a, b)
  if not fftsa.nl.trace then return end
  local s = 'NLT|' .. tostring(tag)
  if a ~= nil then s = s .. '|' .. tostring(a) end
  if b ~= nil then s = s .. '|' .. tostring(b) end
  print(s)
end

-- Read a word from the instrument, or nil. Reads are DRAM-only by construction here:
-- every address passed in comes from the heap scan window or a descriptor inside it.
local function W(addr)
  return tonumber(ki.peek32(hx(addr)), 16)
end

-- A double as the eight bytes the target stores it as, for a content scan.
local function f64_pack(x)
  local hi, lo = f64_words(x)
  return u32_pack(hi) .. u32_pack(lo)
end

-- Is the double at addr this value? Both halves, so a shared exponent is not a match.
-- addr need only be 4-aligned, which is what the extra value at element+20 is.
local function eq64(addr, v)
  local hi, lo = f64_words(v)
  return W(addr) == hi and W(addr + 4) == lo
end

-- The inverse of f64_words, out of eight big-endian bytes at p in s. ldexp rather than a
-- power: m + 2^52 is at most 2^53 - 1 and so exact, and scaling by a power of two rounds
-- nothing, which makes the round trip bit-exact. check_f64.py tests both directions.
--
-- An infinity or a NaN comes back as nil rather than as a number: neither can be written to
-- a display field, a refused graph parameter being a modal dialog, and this firmware's
-- comparisons are not IEEE for a NaN, so the usual v ~= v test downstream would miss it.
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

-- The same, out of four big-endian bytes, for a single-precision image. The reduced trace is
-- the one place dsp_real crosses to Lua as its own width; everything else in the wire format
-- is a double whatever the image was built in. Subnormals decode exactly rather than
-- flushing, this being a read, and an infinity or a NaN comes back as nil as above.
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

-- ---------------------------------------------------------------------------
-- FNF: find the firmware function behind a Lua math wrapper, by scanning a Form E closure's
-- .text handler for the first bl targeting >= 0x00400000. That is the GHS C function,
-- double in f1 to double in f1, and it works across builds as long as the wrapper's shape
-- is preserved.
-- ---------------------------------------------------------------------------
function fftsa.nl.FNF(fn)
  local s = tostring(fn)
  local _, e = string.find(s, ': ')
  if not e then return nil end
  local c = tonumber(string.sub(s, e + 1), 16)
  if not c then return nil end
  local w = W(c + 12)
  if not w then return nil end
  local i
  for i = 0, 255 do
    local pc = w + i * 4
    local n = W(pc)
    if n == nil then return nil end
    if math.floor(n / 67108864) == 18 and math.mod(n, 2) == 1 then
      local r = math.mod(math.floor(n / 4), 16777216)
      if r >= 8388608 then r = r - 16777216 end
      local t = math.mod(pc + r * 4, 4294967296)
      if t >= 4194304 then return t end   -- 0x00400000
    end
  end
  return nil
end

-- Resolve the six functions dsp.c calls. Returns the count found.
fftsa.nl.MATH_NAMES = { 'sin', 'cos', 'sqrt', 'log10', 'floor', 'ceil' }

function fftsa.nl.resolve_math()
  local fn = fftsa.nl.fn
  -- Recorded and not tested against anything: every address below is found by reading this
  -- build's own code, so an unseen build either yields six or loses the native path.
  local v = nil
  if localnode ~= nil then v = localnode.version end
  fftsa.nl.fw_seen = tostring(v)
  local names = fftsa.nl.MATH_NAMES
  local found = 0
  local k
  for k = 1, table.getn(names) do
    local nm = names[k]
    fn[nm] = fftsa.nl.FNF(math[nm])
    if fn[nm] then found = found + 1 end
  end
  return found
end

-- The resolved math addresses and the first words at each, as hex, for a probe to report.
-- Reading the entry back is the only check available on an address FNF derived: two of them
-- answering alike, or one landing somewhere that is not a prologue, shows up only here.
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

-- ---------------------------------------------------------------------------
-- Relocation.
--
-- On PPC32 every data reference is `lis rX,hi` plus a `lo(rX)` access, an absolute address
-- fixed at link time, and clang's PPC backend has no small-data addressing to avoid that.
-- The image is linked at zero, so each relocation target doubles as an offset into it and
-- patching is target plus load address.
--
-- The patch is applied to the Lua string before it is written, so the instrument sees one
-- ki.memwrite rather than one per relocation. csrc/tools/test_relocate.lua checks it against
-- hand-computed answers, the ha carry boundary included.
-- ---------------------------------------------------------------------------
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
  -- .bss has no file contents; the loader is what zeroes it.
  if bss_hi ~= nil and bss_hi > string.len(patched) then
    local z = {}
    local i
    for i = 1, bss_hi - string.len(patched) do z[i] = '\000' end
    patched = patched .. table.concat(z)
  end
  return patched
end

-- ---------------------------------------------------------------------------
-- Content scan over a heap range. A normal function rather than a loadstring, so the
-- packager's luac gate checks it like any other code.
-- ---------------------------------------------------------------------------
function fftsa.nl.FINDS(lo, hi, pat)
  local a   = lo
  local out = {}
  local n   = 0
  local pl  = string.len(pat)
  while a < hi do
    local step = 32768
    if a + step > hi then step = hi - a end
    local s = ki.memread(hx(a), hx(step))
    if s ~= nil then
      local i = 1
      while true do
        local j = string.find(s, pat, i, true)
        if j == nil then break end
        n = n + 1; out[n] = a + j - 1
        i = j + 1
      end
    end
    -- Terminate on the tail rather than on the step, or the overlap subtraction
    -- leaves the address unchanged and the loop never ends.
    if a + step >= hi then break end
    a = a + step - (pl - 1)
  end
  return out
end

-- Element storage of a buffer, by content scan over the buffer's own first readings.
--
-- No fixed sentinel: the needle is reading 1 as the eight bytes the element holds, so this
-- works on a capture as well as on a buffer seeded for the purpose, and two buffers seeded
-- alike cannot be mistaken for one another. Two passes, the arena recent allocations land
-- in first and then the wider heap, the narrow pass being 32 MB rather than 126 MB.
--
-- Confirmation uses the extra values as well as the readings, because fftsa.sg_mkbuf seeds
-- the trace buffer with the axis floor in every element and a distinct extra in each:
-- readings alone match at every element and the scan then returns whichever lies lowest in
-- memory, which for a two-chunk buffer need not be element 0. A trace shifted by a whole
-- chunk is still a plausible trace.

-- Readings nl.init seeds into a buffer it means to find, which has to be at least the
-- largest FAR_INDEX below or the check no small record can imitate does not cover the
-- buffers this module creates for itself -- exactly the ones whose readings are a regular
-- series and so the likeliest to be mimicked by a statistics record. 256 writes is under
-- two milliseconds, once, at install.
fftsa.nl.SEED_READS = 256

-- Consecutive readings a hit is confirmed against, and the far indices confirmed as well.
-- Six consecutive values prove very little; the same series still holding at index 256
-- proves an array of at least that many. Both are cheap -- seven double comparisons a
-- candidate -- where confirming all 256 would be 510 peek32 calls per hit.
local READ_CONFIRM = 6
local FAR_INDEX = { 64, 256 }

-- Returns the slot 0 address and the measured element stride, or nil.
--
-- has_extras is the caller's knowledge and not something to discover: reading .extravalues
-- on a STYLE_STANDARD buffer posts event 4927, for which the firmware puts a modal dialog
-- on the glass over the running app, and pcall does not help where it posts rather than
-- raises. Every caller created the buffer it is asking about.
function fftsa.nl._find_storage(buf, has_extras)
  -- Which term failed, for whoever reports the refusal: a sweep that answers only nil leaves
  -- the caller saying "no descriptor" with nothing to act on.
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
  -- Readings from the far end, which no small record can imitate: the firmware keeps
  -- separate 16-byte records of the same values -- extra-value records, statistics
  -- accumulators -- and a seeded buffer's first six readings are measurable at stride 16 at
  -- an address that is not element storage at all. The largest index, 256, is inside the
  -- first chunk whatever the element size is, the smallest plausible element of 8 bytes
  -- still putting 4096 in a chunk. Only indices the buffer has are used.
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
  local windows = {
    { 50331648, 83886080 },     -- 0x03000000 - 0x05000000
    { 17825792, 150994944 },    -- 0x01100000 - 0x09000000, both inside .heap
  }
  local wi
  local nhits = 0
  for wi = 1, table.getn(windows) do
    local hits = fftsa.nl.FINDS(windows[wi][1], windows[wi][2], needle)
    nhits = nhits + table.getn(hits)
    local k
    for k = 1, table.getn(hits) do
      local h = hits[k]
      -- 8 and not 16: the reading at +0 is a double the firmware itself loads, so element 0
      -- is 8-aligned and nothing more. It is not the chunk payload, so the allocator's
      -- guarantee does not reach it, and a 16-byte filter rejects real storage -- the trace
      -- buffer's element 0 is measurable at 0x037C71C8. The discrimination is the extras and
      -- the far readings below.
      if math.mod(h, 8) == 0 then
        -- Candidate strides 32 and 24, both unconditionally: they are the two element sizes
        -- this firmware uses, WRITABLE_FULL and STANDARD, and 32 is the only one that can
        -- hold the extra value at +20. The discovered offsets after them cover an element
        -- neither size matches, and they can only be measured where readings 1 and 2 differ
        -- -- with every reading equal each offset matches and the list fills with noise,
        -- which is a quiet capture at 4.5 digits. Each candidate still gets the full
        -- confirmation, and describe() checks the winner against the descriptor's elemsize.
        local cands, cn = { 32, 24 }, 2
        if rd[2] ~= rd[1] then
          local off
          for off = 8, 64, 4 do
            if off ~= 32 and off ~= 24 and eq64(h + off, rd[2]) then
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
          -- The far readings, which is the check a 16-byte record cannot pass.
          for i = 1, fn do
            if not eq64(h + (far[i] - 1) * s, buf.readings[far[i]]) then good = false end
          end
          -- The extra values, which also tell two elements of a seeded buffer apart when
          -- every reading in it is the same. They only fit an element of at least 28, so
          -- this is a stride test as well as a value test.
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
  return nil
end

-- The descriptor fields, from a base the caller already has. Five peek32, so re-reading
-- them is how a caller picks up a chunk vector that has lengthened, without the sweep
-- below. Confirmed by the two self-pointers and the chunk geometry, so a base that no
-- longer describes this buffer is refused here and the caller sweeps again. Returns the
-- base, elemsize, perchunk, the chunk vector and the chunk count.
function fftsa.nl._read_desc(base, elem0)
  if base == nil then return nil end
  if W(base + 72) ~= elem0 then return nil end     -- 0x48, the storage pointer
  if W(base + 84) ~= base or W(base + 100) ~= base then return nil end
  local elemsize = W(base + 8)
  local perchunk = W(base + 12)
  local nchunks  = W(base + 16)
  if elemsize == nil or perchunk == nil or nchunks == nil then return nil end
  if nchunks < 1 or nchunks >= 4096 or elemsize < 8 or perchunk < 1 then return nil end
  if elemsize * perchunk > fftsa.nl.CHUNK_BYTES then return nil end
  if elemsize * (perchunk + 1) <= fftsa.nl.CHUNK_BYTES then return nil end
  return base, elemsize, perchunk, W(base + 68), nchunks
end

function fftsa.nl._find_desc(elem0)
  -- The cached base first, re-validated rather than trusted. This is the expensive half of
  -- describe(): the sweep below walks 33 MB as 32 kB reads on its first window and 133 MB on
  -- its second, about a minute. Keyed on the storage address, so a buffer whose storage
  -- moved misses, and _read_desc refuses a stale base even if the key matched.
  local nl = fftsa.nl
  if nl._desc_of == elem0 then
    local b, es, pc, v, nc = nl._read_desc(nl._desc_at, elem0)
    if b ~= nil then return b, es, pc, v, nc end
    nl._desc_of, nl._desc_at = nil, nil
  end
  local needle = u32_pack(elem0)
  local windows = {
    { 50331648, 83886080 },
    { 17825792, 150994944 },
  }
  local wi
  for wi = 1, table.getn(windows) do
    local hits = fftsa.nl.FINDS(windows[wi][1], windows[wi][2], needle)
    local k
    for k = 1, table.getn(hits) do
      local base = hits[k] - 72       -- 0x48
      local s1 = W(base + 84)         -- 0x54, owner self-pointer
      local s2 = W(base + 100)        -- 0x64, second self-pointer
      if s1 == base and s2 == base then
        local elemsize = W(base + 8)
        local perchunk = W(base + 12)
        local nchunks  = W(base + 16)   -- 0x10, chunk count
        -- perchunk is how many elements fit in a chunk, which is not CHUNK_BYTES / 32: the
        -- payload is a fixed 32,768 bytes but the element size is a runtime field, and a
        -- STYLE_STANDARD element of 24 does not divide it -- 1365 elements fill 32,760 and
        -- leave 8 spare. So the test is a fit and not an exact product, and it still pins
        -- perchunk exactly, one more element not fitting.
        if elemsize ~= nil and perchunk ~= nil and nchunks ~= nil and
           nchunks > 0 and nchunks < 4096 and elemsize >= 8 and perchunk > 0 and
           elemsize * perchunk <= fftsa.nl.CHUNK_BYTES and
           elemsize * (perchunk + 1) > fftsa.nl.CHUNK_BYTES then
          -- 0x44 is the chunk vector. The count comes back with it because a caller
          -- indexing the vector has no other way to know where it ends, and an entry too
          -- far returns whatever follows in the heap -- which could pass the backstop and
          -- be written to.
          nl._desc_of, nl._desc_at = elem0, base
          return base, elemsize, perchunk, W(base + 68), nchunks
        end
      end
    end
  end
  return nil
end

-- The descriptor from the buffer's capacity and n, which are descriptor fields at +0x74 and
-- +0x78 rather than values in the record. Returns the descriptor base, element 0, and the
-- same geometry _find_desc returns.
--
-- This goes first because the content scan identifies storage by the readings it holds, and
-- a record whose readings are all identical cannot tell one of its chunks from another:
-- confirmation at any stride passes everywhere, so the scan returns the lowest-addressed
-- chunk and that is not chunk 0. Measured on a shorted input, the scan answered 32,520 bytes
-- low -- exactly one chunk of 1355 elements -- and no descriptor references that address, so
-- the bind failed one step later with the storage half reporting success. A quiet or shorted
-- input is ordinary, so the capture buffer needs a route that ignores the signal.
--
-- Two adjacent big-endian words make a specific needle, and _read_desc applies the same
-- validation as the other route. 878 hits on the instrument, exactly one a descriptor.
function fftsa.nl._find_desc_by_sig(buf)
  local nl = fftsa.nl
  local cap, n = buf.capacity, buf.n
  if type(cap) ~= 'number' or type(n) ~= 'number' or cap < 1 or n < 1 then return nil end
  local needle = u32_pack(cap) .. u32_pack(n)
  local windows = {
    { 50331648, 83886080 },
    { 17825792, 150994944 },
  }
  local wi
  for wi = 1, table.getn(windows) do
    local hits = fftsa.nl.FINDS(windows[wi][1], windows[wi][2], needle)
    local k
    for k = 1, table.getn(hits) do
      local base = hits[k] - 116          -- 0x74, the capacity field
      local elem0 = W(base + 72)          -- 0x48, the storage pointer
      if elem0 ~= nil and elem0 ~= 0 then
        local b, es, pc, v, nc = nl._read_desc(base, elem0)
        if b ~= nil then
          nl._desc_of, nl._desc_at = elem0, base
          return base, elem0, es, pc, v, nc
        end
      end
    end
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- Params struct. Field order must match dsp_native_params in dsp_native.c exactly.
-- ---------------------------------------------------------------------------
function fftsa.nl.write_params(t)
  local fn = fftsa.nl.fn
  -- The word count against the struct the compiler laid out: PARAM_WORDS is a number in
  -- this file and SIZEOF_PARAMS comes out of the linked image, so this is the one check that
  -- catches a field added on one side only -- which would shift every word after it and hand
  -- dsp_native_run a valid-looking address for something else. Skipped when SIZEOF_PARAMS is
  -- zero, which is a module with no generated code to run.
  if fftsa.nl.SIZEOF_PARAMS ~= 0 and
     fftsa.nl.PARAM_WORDS * 4 ~= fftsa.nl.SIZEOF_PARAMS then
    return false
  end
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
    t.src_flat or 0,              -- unused: the capture is read in place
    t.cap_chunk1 or 0, t.cap_chunk2 or 0, t.cap_n or 0, t.cap_perchunk or 0,
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
  }
  if table.getn(w) ~= fftsa.nl.PARAM_WORDS then return false end
  local parts = {}
  local i
  for i = 1, table.getn(w) do parts[i] = u32_pack(w[i]) end
  ki.memwrite(hx(fftsa.nl.params), table.concat(parts))
  return true
end

-- ---------------------------------------------------------------------------
-- Redirect ki.peek8 to a heap address, call it, and restore in both exits.
--
-- The restore writes back the pointer captured before the redirect, never a recomputed
-- one, so a failure inside the call cannot leave ki.peek8 pointing at our code.
-- ---------------------------------------------------------------------------
local function via_peek8(addr)
  local nl = fftsa.nl
  if nl.peek8_cls == 0 then return false, 'no closure' end
  -- Checked on the way in, not just at capture: the restore below is unconditional, so
  -- if this is wrong the redirect must not happen at all.
  if not nl._text_ok(nl.peek8_f) then return false, 'restore value not in .text' end
  local slot = hx(nl.peek8_cls + 12)
  local orig = string.format('%08X', nl.peek8_f)
  ki.poke32(slot, string.format('%08X', addr))
  -- No arguments. Neither the trampoline nor the image reads the Lua stack, so there is
  -- nothing to pass; both take what they need from memory Lua wrote beforehand.
  local ok, r = pcall(ki.peek8)
  ki.poke32(slot, orig)
  -- Whether the branch returned normally is all the return value can say: both pieces of
  -- native code leave zero Lua values, so r is nil either way and what they computed is
  -- read out of memory afterwards.
  fftsa.nl.last_call = ok
  if not ok then
    fftsa.nl.last_err = tostring(r)
    return false, r
  end
  fftsa.nl.last_err = nil
  return true
end
fftsa.nl._via_peek8 = via_peek8

-- Flush written code out of the D-cache and invalidate the I-cache for it.
local function flush(addr, len)
  local nl = fftsa.nl
  if nl.tramp == nil or nl.tramp == 0 then return false end
  if addr == nil or len == nil or len <= 0 then return false end
  -- Refuse to flush the trampoline's own range: icbi on a line the CPU is executing from,
  -- followed by isync, forces a re-fetch mid-function, which bluescreens. Tested line by
  -- line and not byte by byte, because the flush works in whole lines -- a range ending a
  -- few bytes short of the trampoline still invalidates its first line, and a byte test
  -- would pass that straight through.
  local tlo = nl.tramp
  if line_hi(addr, len) > line_lo(tlo) and
     line_lo(addr) < line_hi(tlo, string.len(nl._TRAMP)) then
    return false
  end
  -- The range, into the two words the trampoline loads it from. A plain store read back by
  -- a plain load on the same core, so it needs no barrier of its own.
  ki.memwrite(hx(tlo + nl.TRAMP_RANGE), u32_pack(addr) .. u32_pack(len))
  via_peek8(tlo)
  return nl.last_call == true
end
fftsa.nl.flush = flush

-- Call native code at addr and read back the status it wrote into the params struct, as a
-- signed number, or nil and a reason. Three distinct failures, each naming itself: the
-- branch raised, the word could not be read, or the word still holds STATUS_UNSET -- which
-- means the code returned without passing any exit of dsp_native_run, and that is what
-- landing in the wrong place looks like from here.
local function call_native(addr)
  local nl = fftsa.nl
  local function refuse(why)
    nl.last_err = why
    return nil, why
  end
  if nl.params == nil or nl.params == 0 then return refuse('no params') end
  if nl.STATUS_OFF == nil or nl.STATUS_OFF == 0 then return refuse('no status offset') end
  local ok, err = via_peek8(addr)
  if not ok then return nil, err end
  local s = ki.memread(hx(nl.params + nl.STATUS_OFF), hx(4))
  if s == nil or string.len(s) < 4 then return refuse('status unreadable') end
  local v = u32_at(s, 1)
  if v == nl.STATUS_UNSET then return refuse('no status') end
  if v >= 2147483648 then v = v - 4294967296 end
  return v
end
fftsa.nl.call_native = call_native

-- Put ki.peek8 back. Refuses rather than writing a value that is not a .text address:
-- a restore that writes garbage is worse than no restore, because the closure still
-- works until something calls it.
function fftsa.nl.restore_peek8()
  local nl = fftsa.nl
  if nl.peek8_cls == 0 then return false end
  if not nl._text_ok(nl.peek8_f) then return false end
  ki.poke32(hx(nl.peek8_cls + 12), string.format('%08X', nl.peek8_f))
  return true
end

-- Every failure exit from nl.init comes through here, and deleting the buffers is not
-- enough: nl.entry, nl.tramp and nl.params point into chunk storage the delete frees, so a
-- later via_peek8 through a stale nl.entry would branch into whatever the allocator hands
-- out next. peek8_cls and peek8_f are kept, restore_peek8 needing them, and they are
-- firmware addresses rather than heap.
function fftsa.nl._abort(cb, pb)
  local nl = fftsa.nl
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

-- ---------------------------------------------------------------------------
-- Init. Called once per boot, at startup, before any frame. Once per boot is conservative
-- rather than necessary, and it stays because nothing needs a second install: nl.reinit
-- re-plans without one, so relaxing it would buy nothing and give up a backstop.
--
-- barrier_buf is accepted and validated but not used as the barrier. init fills its own code
-- buffer and barriers on that, because buffer.getstats is the barrier only when it makes the
-- service-task call, which on an empty buffer it need not -- and the caller's buffer is
-- empty more often than not.
--
-- Returns true with nl.ready set, or false with every heap-derived field nil'd.
-- ---------------------------------------------------------------------------
function fftsa.nl.init(barrier_buf, want_n, kind, beta, decim, method, want_nseg)
  local nl = fftsa.nl

  -- One install per boot, and a module field cannot enforce it: fftsa.start() calls this on
  -- every app start and a stop/restart with no power cycle reloads the script, so any flag
  -- kept in nl is gone while the heap code and its I-cache lines are not. A second install
  -- at a fresh address wedges the interpreter, the IPC barrier draining the store buffer to
  -- DRAM without invalidating the I-cache and the trampoline being unable to flush a
  -- replacement for itself. A Lua global is the only storage scoped to the boot rather than
  -- the script. NLBOOT is shared with the probes on purpose: both install heap code, so
  -- either blocks the other.
  --
  -- The first statement, ahead of nl.ready = false, so a refusal cannot damage an install
  -- that is already working: within one script session a second call would otherwise clear
  -- ready on a good install.
  if NLBOOT ~= nil then
    nl.boot_spent = true
    -- Spent means installed, not unusable: nl.reattach resumes the install this boot already
    -- made, which is what lets a relaunch run compiled at all. It validates before it
    -- believes and answers false on any doubt.
    if nl.reattach(want_n, kind, beta, decim, method) then return true end
    return false
  end
  nl.boot_spent = false

  nl.ready = false
  -- want_n sizes the arena, so it is the largest count the app can ask for and not the one
  -- in force: nl.reinit re-plans for anything at or below it without touching the heap,
  -- and a count above it has no arena to be planned into.
  want_n = want_n or 512
  want_nseg = want_nseg or 255

  -- Decoded once and kept: the base64 is what the archive carries, and this is the only
  -- place that turns it into bytes.
  if nl._DSP_CODE == nil and nl._DSP_CODE_B64 ~= nil then
    trace('b64', nl._DSP_CODE_B64_LEN, nl._DSP_RELOC_B64_LEN)
    nl._DSP_CODE  = b64decode(nl._DSP_CODE_B64, nl._DSP_CODE_B64_LEN)
    nl._DSP_RELOC = b64decode(nl._DSP_RELOC_B64, nl._DSP_RELOC_B64_LEN)
    trace('b64.ok', nl._DSP_CODE ~= nil and string.len(nl._DSP_CODE) or 'nil')
  end
  if nl._DSP_CODE == nil or string.len(nl._DSP_CODE) == 0 then return false end
  if nl._DSP_RELOC == nil then return false end
  -- Zero or nil means the generated module never loaded, and every size below would then be
  -- wrong in a way that still produces addresses. PARAMS_SLOT and STATUS_OFF are in the list
  -- because without them the image gets no params address and reports nothing, which is a
  -- call into code whose one pointer is zero.
  if nl.SIZEOF_REAL == 0 or nl.SIZEOF_PLAN == 0 or nl.SIZEOF_PARAMS == 0 or
     nl.RES_DOUBLES == 0 or nl.RES_PEAKS == 0 or
     nl.PARAMS_SLOT == nil or nl.PARAMS_SLOT == 0 or
     nl.STATUS_OFF == nil or nl.STATUS_OFF == 0 then
    return false
  end

  -- No array has to fit a chunk whole: dsp_plan_init_segs cuts one too long for a segment
  -- into slices, and the transform reads the capture in place. What bounds n is the chunk
  -- count dsp_plan_segs reports at step 7 against DSPN_MAX_SEGS, and a count needing more is
  -- refused there. DSP_N_MAX is the library's own ceiling.
  local nmax = 65536
  nl.nceil = nmax
  -- The plan struct has a chunk to itself, which is the one size still checked here.
  if align8(nl.SIZEOF_PLAN) + 32 > nl.CHUNK_BYTES then
    trace('size.plan', nl.SIZEOF_PLAN)
    return false
  end
  -- Two arrays of want_nseg dsp_real share the reduction chunk with the results block,
  -- whose size is fixed by the image. DSPN_RES_BYTES in dsp_native.c, computed from the
  -- same two figures rather than sent across as a third.
  local res_bytes = nl.RES_DOUBLES * 8 + nl.RES_PEAKS * 4
                    + 2 * nl.RES_PEAKS * nl.SIZEOF_REAL
  nl.nseg_ceil = math.floor((nl.CHUNK_BYTES - 32 - res_bytes) / (2 * nl.SIZEOF_REAL))
  if want_n > nmax or want_nseg < 2 or want_nseg > nl.nseg_ceil then
    trace('size.refused', want_n, want_nseg)
    return false
  end

  -- 1. Firmware math addresses. All six are needed; dsp.c calls every one.
  trace('math')
  if nl.resolve_math() < 6 then return false end
  trace('math.ok')

  -- 2. The ki.peek8 closure, and its original f pointer.
  local s = tostring(ki.peek8)
  local _, e = string.find(s, ': ')
  if not e then return false end
  local cls = tonumber(string.sub(s, e + 1), 16)
  if not cls then return false end
  -- This value is written back into a live lua_CFunction pointer by every redirect, so it
  -- is validated before it is kept, and one transport read is not enough: a desynchronised
  -- socket can return a heap address here, which the restore then writes into the dispatch
  -- path. Two agreeing reads, both inside firmware .text, or refuse.
  local orig_f = W(cls + 12)
  if orig_f == nil then return false end
  if not fftsa.nl._text_ok(orig_f) then return false end
  if W(cls + 12) ~= orig_f then return false end
  nl.peek8_cls = cls
  nl.peek8_f   = orig_f

  -- 3. Code buffer. Capacity 1024 is exactly one chunk, so the span below is known to
  --    be one allocation rather than relying on how a short buffer is sized.
  local cb = buffer.make(1024, buffer.STYLE_WRITABLE_FULL)
  buffer.write.format(cb, buffer.UNIT_VOLT, buffer.DIGITS_6_5,
                      buffer.UNIT_VOLT, buffer.DIGITS_6_5)
  -- Distinct readings and distinct extras, nl.SEED_READS of each, because _find_storage
  -- confirms a hit against that many and refuses a buffer it cannot tell element from
  -- element.
  local k
  for k = 1, fftsa.nl.SEED_READS do
    buffer.write.reading(cb, 1000000 + k, 3000000 + k, k, 0)
  end

  -- The barrier uses cb, the buffer this function just filled, and not the caller's:
  -- buffer.getstats is the barrier only when it makes the service-task call, which on an
  -- empty buffer it need not, and an empty one bluescreens the instrument -- the trampoline
  -- never reaching DRAM, the I-cache filling from stale heap. fftsa.start() passes
  -- fftsa.cap, empty until the first capture, so barrier_buf is validated and not used.
  if barrier_buf ~= nil and barrier_buf.n == nil then return fftsa.nl._abort(cb) end
  local bar = cb
  if bar.n == nil or bar.n < 1 then return fftsa.nl._abort(cb) end
  buffer.getstats(bar)

  trace('scan.code')
  -- true: cb is STYLE_WRITABLE_FULL, seeded with distinct readings and distinct extras.
  local code_base, code_stride = nl._find_storage(cb, true)
  if code_stride ~= nil and code_stride ~= 32 then
    -- The layout below places the trampoline and the params struct by byte offset inside
    -- this chunk, which holds whatever the element size is -- but a WRITABLE_FULL element
    -- of anything but 32 means the measured layout has moved.
    trace('code.stride.BAD', code_stride)
    return fftsa.nl._abort(cb)
  end
  if not code_base then return fftsa.nl._abort(cb) end
  trace('code_base', hx(code_base))
  nl.code_buf  = cb
  nl.code_base = code_base

  -- 4. Layout, derived from the image rather than fixed: the image is tens of kilobytes, so
  --    a trampoline at a fixed +256 would sit inside it.
  --
  -- The trampoline starts on a cache line, aligned on the absolute address so it holds
  -- whatever the chunk payload is aligned to. The image's flush rounds up to a whole line
  -- and the image ends wherever the compiler leaves it, so without this, flushing the image
  -- invalidates the trampoline's first line while the CPU is fetching from it. nl.flush
  -- refuses that case as well, so a layout mistake costs an unflushed image.
  local img_span   = align8(nl._DSP_RELOC_BSS_HI)
  if img_span < align8(string.len(nl._DSP_CODE)) then
    img_span = align8(string.len(nl._DSP_CODE))
  end
  local tramp_at   = align32(code_base + img_span)
  local params_at  = tramp_at + align8(string.len(nl._TRAMP))
  local span       = (params_at - code_base) + nl.PARAM_WORDS * 4
  if span > nl.CHUNK_BYTES then return fftsa.nl._abort(cb) end
  nl.params = params_at
  trace('layout', hx(tramp_at), hx(params_at))

  -- 5. Trampoline first, so later writes can be flushed properly. Its own first execution
  --    rides on the IPC barrier alone.
  --
  -- The boot is claimed here, before the first write rather than after the last: a failure
  -- or a wedge from this point on has still consumed the one install the boot allows, and
  -- refusing a retry that might have been safe costs a power cycle where allowing one that
  -- is not costs a wedge and a power cycle. Nothing clears NLBOOT, _abort included.
  NLBOOT = tramp_at
  trace('tramp.write', hx(tramp_at), string.len(nl._TRAMP))
  ki.memwrite(hx(tramp_at), nl._TRAMP)
  buffer.getstats(bar)

  -- Confirm the bytes are where they are expected before branching to them. A read goes
  -- through the D-cache, so this proves nothing about DRAM visibility -- the barrier's job
  -- -- but it catches a write that landed elsewhere, which otherwise costs a bluescreen.
  local back = ki.memread(hx(tramp_at), hx(string.len(nl._TRAMP)))
  if back ~= nl._TRAMP then
    trace('tramp.readback.BAD', (back == nil) and 'nil' or string.len(back))
    return fftsa.nl._abort(cb)
  end
  trace('tramp.readback.ok')

  nl.tramp = tramp_at
  -- The trampoline is never flushed, and nl.flush refuses a range covering it: icbi on a
  -- line the core is executing from, followed by isync, re-fetches the instruction stream
  -- mid-function, which bluescreens at trampoline+64. It needs no flush either -- the
  -- barrier above puts the bytes in DRAM and a line not instruction-fetched since boot
  -- fills from there.
  trace('tramp.ok')

  -- 6. The image, patched for this load address.
  local img, err = nl.relocate(nl._DSP_CODE, nl._DSP_RELOC, code_base,
                               nl._DSP_RELOC_BSS_HI)
  if img == nil then return fftsa.nl._abort(cb) end
  trace('img.reloc', string.len(img))
  -- The params address into the word the image reads it from, patched into the bytes before
  -- they are written so the image is never in memory with the slot unset. The offset comes
  -- from the linked image's symbol, so it follows a rebuild.
  if nl.PARAMS_SLOT == nil or nl.PARAMS_SLOT == 0 or
     nl.PARAMS_SLOT + 4 > string.len(img) then
    trace('params.slot.BAD', tostring(nl.PARAMS_SLOT))
    return fftsa.nl._abort(cb)
  end
  img = string.sub(img, 1, nl.PARAMS_SLOT) .. u32_pack(params_at) ..
        string.sub(img, nl.PARAMS_SLOT + 5)
  trace('params.slot', nl.PARAMS_SLOT, hx(params_at))
  ki.memwrite(hx(code_base), img)

  -- The slot read back before anything is called: it is the one pointer the image takes on
  -- trust and the entry writes a word through it, so an address that landed wrong but still
  -- inside the heap would pass the bounds test there. Four bytes to rule it out.
  local slot = ki.memread(hx(code_base + nl.PARAMS_SLOT), hx(4))
  if slot == nil or string.len(slot) < 4 or u32_at(slot, 1) ~= params_at then
    trace('params.slot.readback.BAD', (slot == nil) and 'nil' or hx(u32_at(slot, 1)))
    return fftsa.nl._abort(cb)
  end
  buffer.getstats(bar)
  -- The image is a different range from the trampoline, so this is the trampoline's
  -- legitimate use. Recorded rather than ignored, because a silent failure leaves the
  -- I-cache able to serve stale lines for the image, which is a wrong answer and not a
  -- fault. Not fatal on a first install, where the image's lines have not been fetched
  -- since boot either and the barrier covers them.
  trace('img.flush')
  nl.flushed = flush(code_base, string.len(img))
  trace('img.flush.ok', tostring(nl.flushed))
  nl.entry = code_base
  trace('img.ok')

  -- 7. How many chunks the arena needs, asked of the binary rather than guessed. The arrays
  --    are laid out one per chunk by dsp_plan_init_segs, so the arena needs no contiguous
  --    memory -- which it could not have, the allocator placing chunk payloads
  --    independently. SEG_BYTES, the same value MODE_INIT gets: asking with CHUNK_BYTES
  --    would count chunks for an arena 32 bytes per segment larger than the one built.
  nl.write_params({ mode = nl.MODE_SEGS, cap_n = want_n,
                    seg_bytes = nl.SEG_BYTES,
                    init_decim = decim or 1, init_method = method or 0 })
  trace('call.segs', hx(code_base), hx(nl.params))
  local nseg = call_native(code_base)
  trace('call.segs.ret', tostring(nseg))
  if type(nseg) ~= 'number' or nseg <= 0 then
    -- Zero means no chunk can hold one of the arrays: the window is n * 8 bytes, so
    -- this is the bound on n rather than a failure of the mechanism.
    nl.nmax = 0
    return fftsa.nl._abort(cb)
  end

  -- 8. Plan buffer: one chunk per segment, one for the plan struct, one for the reduction's
  --    two arrays. Three lifetimes, three chunks -- sharing the host chunk would make the
  --    largest n depend on the largest trace, and the refusal would not say which of the
  --    two sizes failed to fit.
  local chunks_wanted = nseg + 2
  local pb = buffer.make(chunks_wanted * 1024, buffer.STYLE_WRITABLE_FULL)
  buffer.write.format(pb, buffer.UNIT_VOLT, buffer.DIGITS_6_5,
                      buffer.UNIT_VOLT, buffer.DIGITS_6_5)
  for k = 1, fftsa.nl.SEED_READS do
    buffer.write.reading(pb, 2000000 + k, 4000000 + k, k, 0)
  end
  buffer.getstats(bar)

  trace('scan.plan')
  -- STYLE_WRITABLE_FULL, so it does store extra values and asking for them is safe.
  local pdesc = nl.describe(pb, true)
  if pdesc == nil or pdesc.vec == nil then return fftsa.nl._abort(cb, pb) end
  trace('plan.desc', hx(pdesc.chunk1), tostring(pdesc.nchunks))

  -- The vector has to hold the entries about to be read out of it. The chunk count is the
  -- descriptor's own field at +0x10, so this is the allocator's answer and not an inference
  -- from the capacity asked for: one entry past the end returns whatever follows in the
  -- heap, and anything that looks like a heap address passes the native backstop.
  if pdesc.nchunks == nil or pdesc.nchunks < chunks_wanted then
    return fftsa.nl._abort(cb, pb)
  end
  nl.plan_buf = pb

  -- Chunk payload addresses from the vector. They are neither in address order nor
  -- adjacent, which dsp_plan_init_segs does not care about and nothing here may assume.
  -- Each is checked against the heap here as well as by the native entry point, so a bad
  -- vector is a refusal from Lua rather than a status code from a call already handed it.
  local payload = {}
  local i
  for i = 1, chunks_wanted do
    local a = W(pdesc.vec + (i - 1) * 4)
    if a == nil or a == 0 then
      return fftsa.nl._abort(cb, pb)
    end
    if a < nl.HEAP_LO or a + nl.CHUNK_BYTES > nl.HEAP_HI then
      return fftsa.nl._abort(cb, pb)
    end
    payload[i] = a
  end

  -- Segment bases rounded up to DSP_ALIGN: the allocator guarantees 16 and dsp.c needs 32,
  -- so a raw payload is refused with DSPN_EBOUNDS half the time. The raw payloads still
  -- define the window below, the rounding losing addressable bytes and not permission.
  local segbase = {}
  for i = 1, nseg do
    segbase[i] = align32(payload[i])
    if (segbase[i] - payload[i]) + nl.SEG_BYTES > nl.CHUNK_BYTES then
      return fftsa.nl._abort(cb, pb)
    end
  end

  -- The first nseg chunks are the arena, then the plan struct, then the reduction's two
  -- arrays. The struct has its chunk to itself, and nothing shares it: the transform reads
  -- the capture in place, so there is no de-strided copy to place after it.
  local host      = align32(payload[nseg + 1])
  local plan_addr = host
  if (host - payload[nseg + 1]) + align8(nl.SIZEOF_PLAN) > nl.CHUNK_BYTES then
    return fftsa.nl._abort(cb, pb)
  end

  -- dsp_reduce writes nseg entries into each of db and hz, and the trace count is a
  -- front-panel choice, so the room is for the largest the app can ask for rather than the
  -- one in force. Both are dsp_real, and SIZEOF_REAL comes out of the image.
  local red_host = align32(payload[nseg + 2])
  local red_db   = red_host
  local red_hz   = red_host + want_nseg * nl.SIZEOF_REAL
  -- The results block follows the two arrays. 8-aligned, which the native side requires
  -- because it reads and writes it as doubles: red_host is 32-aligned and both arrays are
  -- a whole number of dsp_real, so the sum is.
  local res_addr = red_hz + want_nseg * nl.SIZEOF_REAL
  if (res_addr - payload[nseg + 2]) + res_bytes > nl.CHUNK_BYTES then
    return fftsa.nl._abort(cb, pb)
  end

  -- The segment vector itself, in the code buffer above the params struct.
  local segs_addr = nl.params + align8(nl.PARAM_WORDS * 4)
  if (segs_addr - code_base) + nseg * 4 > nl.CHUNK_BYTES then
    return fftsa.nl._abort(cb, pb)
  end
  local sv = {}
  for i = 1, nseg do sv[i] = u32_pack(segbase[i]) end
  trace('segs.write', hx(segs_addr), nseg)
  ki.memwrite(hx(segs_addr), table.concat(sv))

  -- The writable window has to cover every chunk of this buffer, and the chunks are
  -- scattered, so it spans from the lowest to the highest.
  local lo, hi = payload[1], payload[1]
  for i = 2, chunks_wanted do
    if payload[i] < lo then lo = payload[i] end
    if payload[i] > hi then hi = payload[i] end
  end
  nl.wr_lo = lo
  nl.wr_hi = hi + nl.CHUNK_BYTES

  -- 9. Build the plan across the chunks.
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
    return fftsa.nl._abort(cb, pb)
  end

  nl.plan_addr = plan_addr
  nl.seg_bytes = nl.SEG_BYTES
  nl.nsegs     = nseg
  nl.segs_addr = segs_addr
  nl.red_db    = red_db
  nl.red_hz    = red_hz
  nl.res_addr  = res_addr
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

-- ---------------------------------------------------------------------------
-- Keeping an install across a relaunch.
--
-- The code, the trampoline, the params struct and the arena all live in the chunk storage of
-- two reading buffers, and a reading buffer outlives the script that made it. So a relaunch
-- has not lost the install, only the Lua side of it: the module body rebuilds fftsa.nl and
-- takes every address with it. Nothing but a power cycle clears a global, which is where
-- NLBOOT already lives, so the addresses go beside it. That is what lets a second launch in
-- one power cycle run compiled, and it needs no second install, so the hazard the
-- one-install-per-boot rule exists for never arises.
--
-- Scalars, the two buffer handles, and fn, which holds the resolved firmware math addresses.
-- Functions are deliberately not copied: they have to come from the module being loaded, or
-- a relaunch would run the previous build's Lua.
--
-- _stor_of goes too, and it is the capture buffer's handle rather than one of this module's,
-- because it is describe()'s cache key. The address that cache holds is a number and
-- survives anyway, but without the key the `_stor_of == buf` test fails and describe()
-- discards a still-valid address to sweep the heap again. Safe because apply() keeps that
-- buffer for the power cycle, so its storage cannot have moved, and a handle for a buffer
-- that did go compares unequal to the live one.
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

-- A buffer the firmware has dropped raises on a capacity read, which is the only liveness
-- test there is: the handle itself goes on answering.
local function buf_alive(b)
  if b == nil then return false end
  local ok, cap = pcall(function() return b.capacity end)
  return ok and type(cap) == 'number' and cap > 0
end

-- Resume the install this boot already made. Returns true with nl.ready set, or false
-- having changed nothing that matters.
--
-- Four things are checked before any of it is believed, the alternative to a refusal being
-- a call into whatever now occupies those addresses:
--
--   1. both buffers are still alive, so their chunk storage is still this module's
--   2. the trampoline's own bytes still match the literal this module carries
--   3. the params address still sits in the image's slot
--   4. reinit, which calls the installed code, returns a zero status
--
-- 2 matters most: it reads the heap where the image was written and compares it with what
-- was written there, so an overwritten image fails before anything is called.
function fftsa.nl.reattach(want_n, kind, beta, decim, method)
  local nl = fftsa.nl
  local s = NLSTASH
  if type(s) ~= 'table' then return false end
  -- Everything the checks below need, from the stash rather than from nl: the stash is what
  -- the install actually used, and a relaunch reloads the modules in an order this has no
  -- business depending on.
  if s.entry == nil or s.params == nil or s.tramp == nil or s.code_base == nil
     or s.PARAMS_SLOT == nil or s.TRAMP_RANGE == nil or s._TRAMP == nil then
    return false
  end
  if not buf_alive(s.code_buf) or not buf_alive(s.plan_buf) then
    trace('reattach.dead')
    return false
  end
  -- The trampoline's code, byte for byte, read back rather than trusted -- every byte
  -- except the two range words at nl.TRAMP_RANGE, which are its arguments: nl.flush writes
  -- the address and the length into them before each call, so the zeros the literal carries
  -- there are stale from the first flush onwards. One-based here, so the words occupy
  -- TRAMP_RANGE+1 through TRAMP_RANGE+8 and the code resumes at TRAMP_RANGE+9.
  local want = s._TRAMP
  local got = ki.memread(hx(s.tramp), hx(string.len(want)))
  local head, tail = s.TRAMP_RANGE, s.TRAMP_RANGE + 9
  if string.len(got) ~= string.len(want)
     or string.sub(got, 1, head) ~= string.sub(want, 1, head)
     or string.sub(got, tail) ~= string.sub(want, tail) then
    trace('reattach.tramp', hx(s.tramp))
    return false
  end
  -- The params address, in the word the image reads it from.
  local slot = W(s.code_base + s.PARAMS_SLOT)
  if slot ~= s.params then
    trace('reattach.params', hx(slot or 0))
    return false
  end
  local k, v
  for k, v in pairs(s) do nl[k] = v end
  nl.ready = false
  -- And the plan, rebuilt by the code itself. A count above what the arena was sized for
  -- is refused in there, which is the same answer init would have given.
  if not nl.reinit(want_n or s.n, kind, beta, decim, method) then
    trace('reattach.replan', tostring(nl.last_rc))
    nl.ready = false
    return false
  end
  nl.reattached = true
  trace('reattach.ok', hx(s.entry))
  return true
end

-- ---------------------------------------------------------------------------
-- Re-plan without reinstalling.
--
-- Only MODE_INIT depends on the sample count, the window and the beta, and all three are
-- front-panel choices. The code, the trampoline, the params struct and the arena are where
-- init left them, so a press costs one write_params and one call rather than a content
-- scan, a relocation and an install.
--
-- The arena was sized for the count init was given, so this only goes down from nl.nmax: a
-- larger count has no arena to be planned into and is refused here rather than left to
-- dsp_plan_init_segs, which would zero the plan and answer with a status code.
--
-- nl.ready is cleared for the duration, or a frame dispatched from the timer between the
-- write and the return would run against a plan being rebuilt under it.
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- Run one frame. Returns the trace point count, which is what the app reports as nseg, or
-- nil with nl.last_rc set. Not the bin count: the run ends in dsp_reduce.
--
-- cap and out each describe one buffer's chunk storage:
--   chunk1, chunk2   payload addresses, chunk2 zero when one chunk holds it all
--   perchunk         elements per chunk, from the descriptor
--   lo, hi           the span the native code may touch in that buffer
--   out.desc         the column descriptor base, for the cursor rewind
--
-- Chunk payloads are placed independently by the allocator -- 0x8010 is the block size and
-- not a pitch, so the second payload can sit below the first. lo and hi therefore span from
-- the lowest payload to the highest plus CHUNK_BYTES, and the native side additionally
-- requires each strided access to stay inside the chunk it starts in, the span alone
-- permitting whatever else lives between two scattered payloads.
--
-- red carries the reduction, which is everything the trace depends on and nothing the plan
-- does: nseg, the bin window k0..k1 (zero based, where the Lua implementation's bins are one
-- based), the decibel limits, the voltage floor and the bin-to-hertz map. binhz is measured
-- per frame off the capture's timestamps, so it is not a constant and is not in the plan.
-- ---------------------------------------------------------------------------
function fftsa.nl.call_dsp(cap, out, red)
  local nl = fftsa.nl
  if not nl.ready then return nil end
  if cap == nil or red == nil then return nil end
  -- The record is read in place through the chunk vector, so a descriptor without one is
  -- refused here rather than reaching the entry point as a zero address.
  if cap.vec == nil or cap.nchunks == nil or cap.nchunks < 1 then return nil end
  -- Checked here as well as natively, a refusal from dsp_native_run arriving as a status
  -- code after the params are written and reading the same as a bad address.
  local ns = red.nseg
  if ns == nil or ns < 1 or nl.nseg_max == nil or ns > nl.nseg_max then return nil end
  if red.binhz == nil or not (red.binhz > 0) then return nil end
  if red.k0 == nil or red.k1 == nil or red.k0 < 0 or red.k1 < red.k0 then return nil end
  if red.dbmin == nil or red.dbmax == nil or not (red.dbmin < red.dbmax) then return nil end
  -- out nil asks for the reduction and nothing else. The trace reaches the graph through
  -- buffer.write.reading, so the primitive has nothing to write into a reading buffer, and
  -- a descriptor of zero is what tells it so -- and so no content scan for that storage.
  local out_lo, out_hi, out_ch1, out_ch2, out_per, out_desc = 0, 0, 0, 0, 0, 0
  if out ~= nil then
    out_lo, out_hi = out.lo, out.hi
    out_ch1, out_ch2, out_per, out_desc = out.chunk1, out.chunk2, out.perchunk, out.desc
    if out_desc == nil or out_desc == 0 then return nil end
  end

  local ok = nl.write_params({
    mode = nl.MODE_RUN,
    wr_lo = nl.wr_lo, wr_hi = nl.wr_hi,
    rd_lo = cap.lo, rd_hi = cap.hi,
    out_lo = out_lo, out_hi = out_hi,
    seg_bytes = nl.seg_bytes, nsegs = nl.nsegs, segs_addr = nl.segs_addr,
    plan_addr = nl.plan_addr,
    cap_chunk1 = cap.chunk1, cap_chunk2 = cap.chunk2,
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

-- ---------------------------------------------------------------------------
-- The figures the last run produced that are not the trace: the ranked peaks, and the
-- distortion and noise measurement.
--
-- One ki.memread for the whole block and a decode per value, rather than a pair of peek32
-- per double or a reading buffer of its own -- a buffer would need a chunk, a content scan
-- to find it and a window to validate, and Lua can only read as many elements as the
-- descriptor says are present, so the scalars would have to live inside the plotted trace.
--
-- The tables are allocated once and refilled, this running in a frame, and the peak tables
-- are cleared to nil past the count found so a frame that finds fewer peaks than the last
-- cannot leave a stale row on screen.
--
-- Returns nil when there is nothing to read, which is what a caller gets before the first
-- run and after a failure. thd, snr and noise are nil where the measurement did not apply:
-- 0 dB and 0% are both real answers, so the native side sends a flag per figure.
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- The reduced trace the last run produced: one decibel value per segment and the frequency
-- of each, in two tables for the caller to write with buffer.write.reading.
--
-- That write is the only route onto a graph. The native side can put the same numbers into
-- the bound buffer's chunk storage and rewind its descriptor -- the buffer then reads back
-- correct from Lua and buf.n says the right count -- and the graph stays blank, because the
-- display task works from its own copy and no notify call reaches a write it never saw.
--
-- A value that does not decode to a finite number fails the whole call rather than leaving a
-- hole, a nil reaching buffer.write.reading being a posted event per point. The tables are
-- allocated once and refilled, this running in a frame: the decibels every call and the
-- frequencies only when the plan behind them moves.
-- ---------------------------------------------------------------------------
function fftsa.nl.reduce(nseg)
  local nl = fftsa.nl
  if nl.red_db == nil or nl.red_hz == nil then return nil end
  if nseg == nil or nl.nseg_max == nil or nseg < 1 or nseg > nl.nseg_max then return nil end
  -- The reduced arrays are dsp_real, so their width comes from the image rather than from
  -- here. A decoder picked for the wrong width reads a plausible wrong trace, not a
  -- refusal, so an image reporting neither width is refused outright.
  local sz = nl.SIZEOF_REAL
  local f_unpack
  if sz == 8 then f_unpack = f64_unpack
  elseif sz == 4 then f_unpack = f32_unpack
  else return nil end
  local nbytes = nseg * sz
  local sd = ki.memread(hx(nl.red_db), hx(nbytes))
  if sd == nil or string.len(sd) ~= nbytes then return nil end
  if nl._red == nil then nl._red = { db = {}, hz = {} } end
  local r = nl._red
  local db, hz = r.db, r.hz
  local i, p
  -- The frequencies are an affine series the plan fixes: the primitive forms every one as
  -- f0 + c * fstep from two numbers it derives before the segment loop, so no sample can
  -- change one and they are decoded once a plan rather than once a frame. The two elements
  -- read here are those same two numbers, so an equal pair at an equal count and address is
  -- the same series to the last bit. Asking the array rather than recomputing the series
  -- from the span keeps one owner of the arithmetic: a cache agreeing with a formula here
  -- and not with the primitive would plot the right trace against the wrong axis.
  local probe = 2 * sz
  if nseg < 2 then probe = sz end
  local sp = ki.memread(hx(nl.red_hz), hx(probe))
  if sp == nil or string.len(sp) ~= probe then return nil end
  local h1 = f_unpack(sp, 1)
  local h2 = nil
  if nseg >= 2 then h2 = f_unpack(sp, 1 + sz) end
  if h1 == nil or (nseg >= 2 and h2 == nil) then return nil end
  -- The width is in the key as well, because an image rebuilt in the other precision keeps
  -- the same arena addresses: the series would read as unchanged while every stride moved.
  if r.hz_nseg ~= nseg or r.hz_at ~= nl.red_hz or r.hz_sz ~= sz
     or r.hz_1 ~= h1 or r.hz_2 ~= h2 then
    -- Cleared before the read, so a short read or an undecodable value cannot leave the
    -- key describing a table that was only half refilled.
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
  p = 1
  for i = 1, nseg do
    local v = f_unpack(sd, p)
    if v == nil then return nil end
    db[i] = v
    p = p + sz
  end
  r.nseg = nseg
  return r
end

-- Describe a buffer's storage for call_dsp, from the content scan and descriptor walk.
-- Returns nil if either step fails, so a caller cannot build a half-filled table.
function fftsa.nl.describe(buf, has_extras)
  -- Both halves sweep the heap and both are cached, against different keys. Finding storage
  -- is keyed on the buffer, since only a replacement moves it. Finding the descriptor is
  -- keyed on the storage address, inside _find_desc, and its five words are re-read every
  -- call -- which is what makes calling describe() again cheap, and is how a chunk vector
  -- that has lengthened is picked up.
  local nl = fftsa.nl
  local elem0, stride
  -- Carried out of the signature route, which returns the descriptor with the address.
  local sdesc, selemsize, sperchunk, svec, snchunks
  if nl._stor_of == buf and nl._stor_x == has_extras and nl._stor_elem0 ~= nil then
    elem0, stride = nl._stor_elem0, nl._stor_stride
  else
    nl._stor_of, nl._stor_x, nl._stor_elem0, nl._stor_stride = nil, nil, nil, nil
    nl._stor_why = nil
    -- The signature route for a buffer with no extra values, which is the capture: its
    -- readings are whatever was on the input, and an all-identical record defeats a content
    -- scan. It answers with the descriptor too, so the second sweep is skipped. The buffers
    -- init creates are seeded distinctly and carry extras, so they keep the content route.
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
  if not elem0 then return nil end
  local desc, elemsize, perchunk, vec, nchunks = sdesc, selemsize, sperchunk, svec, snchunks
  if desc == nil then
    desc, elemsize, perchunk, vec, nchunks = fftsa.nl._find_desc(elem0)
  end
  -- Each of the two halves names itself: _find_storage sets _stor_why on its own failures
  -- and clears it on the way in, so without these the caller reports "nil" for a refusal
  -- that happened here.
  if not desc then
    nl._stor_why = 'no descriptor for elem0=' .. hx(elem0) .. ' stride=' .. tostring(stride)
    return nil
  end
  -- Two independent answers to the same question, so they have to agree: the stride measured
  -- from the spacing of the readings, and the element size the descriptor states.
  -- Disagreement means one of the two is not this buffer's, and nothing below is then safe.
  if elemsize ~= stride then
    nl._stor_why = 'elemsize ' .. tostring(elemsize) .. ' disagrees with stride '
                   .. tostring(stride) .. ' at elem0=' .. hx(elem0)
    return nil
  end
  -- The window must cover every payload, and they are scattered -- the second often sits
  -- below the first -- so it spans from the lowest to the highest, the way nl.init does it.
  -- Taking hi from the second gives hi < lo, which dsp_native_run rejects as EBOUNDS.
  local ch2 = 0
  local lo  = elem0
  local hi  = elem0 + fftsa.nl.CHUNK_BYTES
  -- Every chunk the vector holds, because the native side reads the record in place and a
  -- long one spans many: 16,384 readings of 24 bytes is twelve chunks. The window is what it
  -- validates each payload address against, so a chunk left out of lo..hi is a refusal from
  -- the entry point on every frame. Bounded by the descriptor's own chunk count at +0x10 and
  -- not by the capacity asked for: one entry past the end returns whatever follows in the
  -- heap, and anything looking like a heap address would widen the window.
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
  return { chunk1 = elem0, chunk2 = ch2, perchunk = perchunk,
           elemsize = elemsize, desc = desc, vec = vec, nchunks = nchunks,
           lo = lo, hi = hi }
end
