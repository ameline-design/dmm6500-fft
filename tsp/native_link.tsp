-- native_link.tsp -- load the native DSP binary into heap and make it callable.
--
-- Called once at startup; sets fftsa.nl.ready when the native path is available. Every
-- failure is recorded and swallowed, and the app reports it from the frame that needs it.
--
-- No firmware address is written down here, and none is compared against either. The six
-- libm entries come from FNT and resolve_math, which find them in the code of Lua's own
-- math wrappers by the company each call keeps; the ki.peek8 closure and its f pointer come
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
  fn        = {},     -- firmware math addresses resolved by resolve_math
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

-- The native side's compiled backstop, also overwritten from the image. Zero here so an
-- un-generated module refuses every address rather than accepting every address.
fftsa.nl.BACKSTOP_LO = 0
fftsa.nl.BACKSTOP_HI = 0

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

-- And the forward direction, as the four big-endian bytes a single-precision store leaves.
-- Needed to search memory for a value the app put there: the display task keeps its trace as
-- float32, so a double packed the double way matches nothing.
--
-- Rounding is to nearest with ties to even, which is what frsp does on this core -- a needle
-- one bit out is a needle that is not found, and the failure looks like "the ring is not in
-- memory" rather than like a rounding bug. csrc/tools/check_f32.py checks every case below
-- against struct.pack.
local function f32_pack(x)
  local sign = 0
  if x < 0 then sign = 128; x = -x end
  -- A NaN loses every ordered comparison, so it has to go before any of them.
  if x ~= x then return string.char(sign + 127, 192, 0, 0) end
  if x == 0 then return string.char(sign, 0, 0, 0) end
  if x + x == x then return string.char(sign + 127, 128, 0, 0) end
  local m, e = math.frexp(x)              -- 0.5 <= m < 1 and x = m * 2^e
  local eb, f = e + 126, nil              -- 2m is the 1.f form, so its exponent is e - 1
  if eb <= 0 then
    -- Subnormal: the value is f * 2^-149 with f below 2^23, so the significand is the whole
    -- of it and the exponent field is zero. A round that carries into 2^23 lands on the
    -- smallest normal, which the carry below already handles.
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

-- ---------------------------------------------------------------------------
-- Find the firmware math entries behind the Lua math wrappers.
--
-- The entries move between models as well as between builds, so nothing here is compared
-- against an address. What identifies the library call is the company it keeps.
--
-- Every math wrapper is the same shape: ten calls into the Lua VM, the library function if
-- it has one, then lua_pushnumber. math.abs, math.deg and math.rad have no library function
-- -- abs on a double is a sign-bit clear and the other two are one multiply, all three
-- inlined -- so every target they reach is VM glue by construction, and that is a property
-- of the Lua source rather than of the link map. Take their targets as the glue set, and a
-- one-argument wrapper's library entry is its one target outside it.
--
-- Measured on three images: DMM6500 1.7.17a and 1.7.18a, where the block sits at 0x002026F8
-- and 0x002026E0, and the DMM7510 1.7.16 function list, where it sits at 0x000CDD34. All
-- three are 13,228 bytes, function for function, in the same order. On both 6500 builds the
-- glue set is nine targets, every one-argument wrapper contains all nine, and the one target
-- outside it is the eleventh bl of twelve.
-- ---------------------------------------------------------------------------

-- The ceiling on one wrapper, not its length: the scan stops at the wrapper's blr, and the
-- longest of these is 0x16C bytes, 91 words. One memread rather than a peek a word at a
-- time, the scan needing the whole body and a round trip costing what a few peeks do.
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
    -- bl: primary opcode 18 with LK set and AA clear. Testing both low bits refuses bla,
    -- whose field is an absolute address and not the displacement this reads it as.
    if math.floor(n / 67108864) == 18 and math.mod(n, 4) == 1 then
      local r = math.mod(math.floor(n / 4), 16777216)
      if r >= 8388608 then r = r - 16777216 end
      table.insert(out, math.mod(w + i * 4 + r * 4, 4294967296))
    end
    if n == 1317011488 then break end   -- blr: the wrapper's one exit
  end
  return out
end

-- The six dsp.c calls, the wrappers that reach no library function at all, and the wider set
-- the cross-check needs. MATH_GLUE is what makes this work; MATH_CENSUS only confirms it.
fftsa.nl.MATH_NAMES  = { 'sin', 'cos', 'sqrt', 'log10', 'floor', 'ceil' }
fftsa.nl.MATH_GLUE   = { 'abs', 'deg', 'rad' }
fftsa.nl.MATH_CENSUS = { 'sin', 'cos', 'sqrt', 'log10', 'floor', 'ceil',
                         'tan', 'log', 'exp', 'asin', 'acos', 'atan' }

-- The smallest glue set worth believing. Nine on both measured builds; a sample that yields
-- a handful has not found the wrappers, and treating it as complete would leave most of a
-- wrapper's VM calls looking like library entries.
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

  -- 1. The glue set, off the wrappers that call no library function.
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
  nl.glue, nl.nglue = glue, nglue
  if nglue < nl.GLUE_MIN then return 0 end

  -- 2. Each census wrapper's targets, and the ones not in the glue set. Every wrapper has
  --    to contain the whole glue set: a sample that is not the shared part is not glue, and
  --    the difference below would then be most of the wrapper.
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

  -- 3. Exactly one target outside the glue set, or the name goes unresolved: a wrapper whose
  --    shape has changed has to lose the native path rather than hand out an address nothing
  --    has checked. In .text as well, which is what dspn_text_ok in the image tests the same
  --    six against -- refused here the launch says so, where the image answering EMATH is an
  --    app already on the glass and a frame that never arrives.
  local found = 0
  for i = 1, table.getn(nl.MATH_NAMES) do
    local nm = nl.MATH_NAMES[i]
    local left = out[nm]
    if left ~= nil and table.getn(left) == 1 and nl._text_ok(left[1]) then
      fn[nm] = left[1]
      found = found + 1
      -- Recorded, not required: on both measured builds the pick is the eleventh bl of
      -- twelve, the last being lua_pushnumber, and a build where it is not has changed shape
      -- in a way worth seeing in fw_probe. Not a gate, because a build that inlined the push
      -- would put the library call last and be refused for no reason.
      if nl.math_pos[nm] ~= table.getn(tg[nm]) - 1 then nl.math_odd = true end
    end
  end

  -- 4. Two names answering one address is the failure fw_probe was written to show. Checked
  --    rather than reported: if it appears, the six are not six functions. Both copies go,
  --    not the second one -- a shared address says neither name was identified, so keeping
  --    whichever came first would be a guess with a count that looked like progress.
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

-- The resolved math addresses and the first words at each, as hex, for a probe to report.
-- resolve_math now refuses two names answering alike, so this is for reading the entries
-- back: one landing somewhere that is not a prologue shows up only here, and nl.math_odd
-- records a build whose library call is not where both measured ones put it.
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
-- Where the heap is cannot be compiled in. A DMM6500 1.7.16-1.7.18 puts .heap at
-- 0x01036000..0x0D836000 and a DMM7510 1.7.16 at 0x008A2000..0x0F8A2000, so a window pair
-- measured on one model leaves about 45% of the other's heap unswept, and describe() answers
-- nil for a buffer the allocator placed there.
--
-- Lua's own objects come from the same allocator as reading-buffer storage, so tostring({})
-- is a heap address for free, on any model, with no section table and no scan. Measured on a
-- DMM6500 1.7.17a: a fresh table at 0x0387F730, fftsa.sg_buf's object at 0x03132A28 and
-- fftsa.cap's at 0x0328EFB8, against descriptors at 0x035BC570 and 0x0367F4A0 and a chunk
-- vector at 0x03676E60 -- the whole working set inside 7.6 MB. The first window is that
-- spread with threefold room, so the common case costs what a 32 MB window costs; the second
-- is everything the compiled backstop permits, for a heap that scatters further than measured.
fftsa.nl.ANCHOR_NEAR = 25165824         -- 24 MB either side
fftsa.nl.ANCHOR_FAR  = 134217728        -- 128 MB either side
-- The top of DRAM, which is the board and not a firmware build -- the same figure
-- dsp_native_bounds.h compiles in. Used only when the generated module has not loaded and
-- the backstop is still zero: clamping to a zero range would answer with no windows at all,
-- and describe() is also called at runtime by nl_bind, where refusing to sweep is worse than
-- sweeping wide.
fftsa.nl.DRAM_END = 268435456

-- The address inside what tostring() prints for a collectable Lua value: 'table: 3550a18',
-- 'userdata: 353b010', either with or without an 0x. Nil for anything that prints no address,
-- which is every value with a __tostring and every number and string.
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

-- One word, refused rather than faulted for an address that is not a 4-aligned DRAM one.
-- ki.peek32 is an lwz with no validation, so a bad address is a precise data storage
-- interrupt and a bluescreen -- and unlike the sweep, whose addresses all come out of a
-- window it chose, the routes below start from a pointer the firmware gave us and follow it.
function fftsa.nl._wg(addr)
  if type(addr) ~= 'number' then return nil end
  if addr <= 0 or math.mod(addr, 4) ~= 0 then return nil end
  local lo, hi = fftsa.nl.BACKSTOP_LO, fftsa.nl.BACKSTOP_HI
  if lo == nil or hi == nil or lo >= hi then lo, hi = 0, fftsa.nl.DRAM_END end
  if addr < lo or addr + 4 > hi then return nil end
  return tonumber(ki.peek32(hx(addr)), 16)
end

-- A buffer's native instance, from the buffer itself rather than from a search.
--
-- A reading buffer is a Lua table with no own keys whose metatable carries CClassRef, a
-- userdata of one pointer: the C++ instance. getmetatable is unprotected on this firmware, so
-- the whole walk is two steps and no sweeping. This matters because the instance comes from
-- the C++ allocator, which is the allocator that places the column descriptors -- measured
-- 19 KB apart -- while tostring({}) anchors on the Lua allocator, which on a DMM7510 put
-- every window it chose in the wrong part of a 251 MB heap.
--
-- The pointer is read through _wg, so a metatable shaped differently on some other build
-- answers nil and the caller falls back to the sweep.
function fftsa.nl.cclass(buf)
  if type(buf) ~= 'table' and type(buf) ~= 'userdata' then return nil end
  local mt = getmetatable(buf)
  if type(mt) ~= 'table' then return nil end
  local ref = mt.CClassRef
  if ref == nil then return nil end
  local p = fftsa.nl.obj_addr(ref)
  if p == nil then return nil end
  -- The Udata holds one pointer and tostring already gave the payload, so the instance is at
  -- payload+0. Adding 16 here lands in the next object and dereferencing that faults.
  return fftsa.nl._wg(p)
end

-- The per-column pointers the instance lists. Its header is a NUL-terminated list of 16-byte
-- records (previous id, this id, two pointers), ids 9 and 14 being the reading and extra-value
-- columns of a STYLE_WRITABLE_FULL buffer. Every capture so far put the column descriptor
-- within a couple of hundred KB of these, so they are the cheapest window there is.
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
  -- No anchor means tostring() did not give an address. Sweeping everything the backstop
  -- allows is slow, and it is the only thing left that can still succeed.
  if n == 0 then out[1] = { lo, hi } end
  nl.last_windows = out
  return out
end

-- Windows for a buffer's own storage and descriptor, cheapest first and covering everything.
--
-- A DMM7510 1.7.16 reported a confirmed element 0 at 0x0158D7C0 with no descriptor anywhere in
-- the two anchored windows. The descriptor layout is not the difference: the function that
-- initialises +0x44, +0x48, +0x54, +0x64, +0x74 and the four copies of n is byte-identical in
-- the 6500 1.7.17a and 7510 1.7.16 images, 1044 bytes of it. So the descriptor was simply
-- outside what tostring({}) could reach -- the anchored pair covers 143 MB of a heap that runs
-- to 248 MB -- and the fix is which windows get swept, in which order.
--
-- Four stages. The first three are each a fraction of a second and are where both models are
-- expected to answer; the last is minutes and is there so that nothing in DRAM is unreachable,
-- because a slow start beats a refusal.
fftsa.nl.TIGHT = 262144                 -- 256 KB either side, the measured arena distance
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

  -- Stage 1: the buffer's own C++ instance, its column pointers, the storage address if the
  -- caller has one, and whichever arena a descriptor was last found in.
  local inst = nl.cclass(buf)
  -- Only when there is a buffer to ask. A ring search passes none, and blanking this would
  -- both empty the error page's inst= and point the next descriptor call's chain walk at
  -- nothing.
  if buf ~= nil then nl.inst = inst end
  local centres, cn = {}, 0
  local push = function(c)
    if c ~= nil and c > 0 then cn = cn + 1; centres[cn] = c end
  end
  -- The instance and the storage first, because those are the two the widening stage uses:
  -- they are what the descriptor is known to sit near. The column pointers and the cached
  -- arena follow, tight only.
  push(inst)
  push(elem0)
  local cp = nl.col_ptrs(inst)
  local i
  for i = 1, table.getn(cp) do push(cp[i]) end
  push(nl.arena)
  for i = 1, cn do add(centres[i] - nl.TIGHT, centres[i] + nl.TIGHT) end

  -- Stage 2: the two strongest centres, widened. Two bands rather than one window, so this
  -- never re-reads what stage 1 covered.
  for i = 1, 2 do
    local c = centres[i]
    if c ~= nil then
      add(c - nl.MID, c - nl.TIGHT)
      add(c + nl.TIGHT, c + nl.MID)
    end
  end

  -- Stage 3: the anchored pair, unchanged. This is the whole of what 8.46 swept, so a model
  -- that works today keeps working even if every route above answers nothing.
  local sw = nl.sweep_windows()
  for i = 1, table.getn(sw) do add(sw[i][1], sw[i][2]) end

  -- Stage 4: everything the backstop allows. Minutes, and only reached when the app was
  -- otherwise going to refuse to start.
  add(lo, hi)
  nl.last_windows = out
  return out
end

function fftsa.nl.windows_str()
  local w = fftsa.nl.last_windows
  if w == nil then return 'windows=none' end
  local o, i = 'windows=', nil
  -- Two, then a count: this goes on the error page for an operator to photograph, and a
  -- four-stage ladder is a dozen ranges that would push everything after it off the glass.
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

-- Everything about the native path a failure report needs, in one string the panel can hold.
-- An operator on a model we have never run on can only send back what is on the glass, so
-- the screen has to carry the state rather than name a log to go and read.
function fftsa.nl.diag()
  local nl = fftsa.nl
  local o = 'model=' .. tostring(localnode.model) .. ' fw=' .. tostring(localnode.version)
  o = o .. ' why=' .. tostring(nl.why)
  o = o .. ' | ready=' .. tostring(nl.ready) .. ' entry=' .. tostring(nl.entry)
  o = o .. ' rc=' .. tostring(nl.last_rc) .. ' spent=' .. tostring(nl.boot_spent)
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
  o = o .. ' | plan=' .. tostring(nl.SIZEOF_PLAN) .. ' params=' .. tostring(nl.SIZEOF_PARAMS)
  o = o .. ' real=' .. tostring(nl.SIZEOF_REAL) .. ' align=' .. tostring(nl.DSP_ALIGN)
  -- Which of the six resolved, by name: one missing entry is enough to stop the install, and
  -- the census is the part that differs between models.
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

-- A refusal that names itself. init has a dozen ways to give up before the native call is
-- ever made, and without a reason the panel reports the same "ready=false entry=nil rc=nil"
-- for every one of them -- which is what a DMM7510 1.7.16 reported, with nothing to act on.
function fftsa.nl._no(why)
  fftsa.nl.why = why
  return false
end

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
  local windows = fftsa.nl.scan_windows(buf, nil)
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
-- The chunk payload size is the allocator's figure, not ours. A DMM6500 uses 32,768 bytes;
-- another model need not, and a DMM7510 1.7.16 rejected a perfectly good descriptor because
-- the two tests below demanded that exact number.
--
-- perchunk is how many elements fit one payload, so the payload is the power of two perchunk
-- exactly fills: elemsize * perchunk fits it, and one more element does not. That still pins
-- perchunk as tightly as the old pair did -- it just does not assume which payload size it is
-- pinning against. Identification does not rest on this anyway: +0x48 holding elem0 and the
-- two self-pointers at +0x54 and +0x64 both equalling base are three independent checks.
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

-- Every read here is guarded, not raw. A base reaching this is a word the firmware handed us
-- -- a cached one, a sweep hit, or a pointer out of the instance's column chain -- and only the
-- sweep hit is known to be in DRAM at all. An unguarded peek32 on the other two is an lwz on an
-- arbitrary address, which is a precise data storage interrupt and a bluescreen.
function fftsa.nl._read_desc(base, elem0)
  if base == nil then return nil end
  local g = fftsa.nl._wg
  if g(base + 72) ~= elem0 then return nil end     -- 0x48, the storage pointer
  if g(base + 84) ~= base or g(base + 100) ~= base then return nil end
  local elemsize = g(base + 8)
  local perchunk = g(base + 12)
  local nchunks  = g(base + 16)
  if elemsize == nil or perchunk == nil or nchunks == nil then return nil end
  if nchunks < 1 or nchunks >= 4096 or elemsize < 8 or perchunk < 1 then return nil end
  local span = fftsa.nl._chunk_span(elemsize, perchunk)
  if span == nil then return nil end
  fftsa.nl.chunk_span = span
  return base, elemsize, perchunk, g(base + 68), nchunks
end

function fftsa.nl._find_desc(elem0, buf)
  -- The cached base first, re-validated rather than trusted. Keyed on the storage address, so
  -- a buffer whose storage moved misses, and _read_desc refuses a stale base even if the key
  -- matched. This is the expensive half of describe() when the ladder has to escalate, so the
  -- cache is what keeps a second describe() of the same buffer free.
  local nl = fftsa.nl
  if nl._desc_of == elem0 then
    local b, es, pc, v, nc = nl._read_desc(nl._desc_at, elem0)
    if b ~= nil then return b, es, pc, v, nc end
    nl._desc_of, nl._desc_at = nil, nil
  end
  local needle = u32_pack(elem0)
  -- Two counts, because they fail differently and the panel has to tell them apart. _raw_n is
  -- how many times the storage address appears at all: zero means the descriptor is outside
  -- every window swept. _hit_n is how many of those passed the two owner self-pointers: raw
  -- hits with no confirmed one would mean the layout moved, which the image comparison says it
  -- has not. The DMM7510 report had only the one count and it could not separate the two.
  nl._hit_n, nl._hit_why, nl._raw_n, nl._win_hit = 0, nil, 0, nil
  local windows = fftsa.nl.scan_windows(buf, elem0)
  -- The chain pointers as the descriptor itself, before any sweeping. On a DMM6500 this does
  -- not answer: a sweep for the descriptor's own address found four references and all four
  -- were inside the descriptor or in allocator bookkeeping, so nothing outside it points at
  -- it. It is here because it costs three guarded reads a pointer against _read_desc's own
  -- validation, scan_windows has already walked the chain, and a model where one of those
  -- pointers is the descriptor gets it for nothing.
  local cand = fftsa.nl.col_ptrs(nl.inst)
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
    local hits = fftsa.nl.FINDS(windows[wi][1], windows[wi][2], needle)
    nl._raw_n = nl._raw_n + table.getn(hits)
    local k
    for k = 1, table.getn(hits) do
      local base = hits[k] - 72       -- 0x48
      local s1 = fftsa.nl._wg(base + 84)    -- 0x54, owner self-pointer
      local s2 = fftsa.nl._wg(base + 100)   -- 0x64, second self-pointer
      if s1 == base and s2 == base then
        local elemsize = fftsa.nl._wg(base + 8)
        local perchunk = fftsa.nl._wg(base + 12)
        local nchunks  = fftsa.nl._wg(base + 16)   -- 0x10, chunk count
        -- The element size is a runtime field and need not divide the payload: a
        -- STYLE_STANDARD element of 24 bytes puts 1365 in a 32,768-byte payload, filling
        -- 32,760 and leaving 8 spare. So the test is a fit rather than an exact product, and
        -- _chunk_span finds which payload size it is a fit for instead of assuming.
        local span = fftsa.nl._chunk_span(elemsize, perchunk)
        nl._hit_n = (nl._hit_n or 0) + 1
        if nl._hit_why == nil then
          nl._hit_why = 'es=' .. tostring(elemsize) .. ' pc=' .. tostring(perchunk)
                        .. ' nc=' .. tostring(nchunks) .. ' span=' .. tostring(span)
        end
        if elemsize ~= nil and perchunk ~= nil and nchunks ~= nil and
           nchunks > 0 and nchunks < 4096 and span ~= nil then
          nl.chunk_span = span
          -- 0x44 is the chunk vector. The count comes back with it because a caller
          -- indexing the vector has no other way to know where it ends, and an entry too
          -- far returns whatever follows in the heap -- which could pass the backstop and
          -- be written to.
          nl._desc_of, nl._desc_at = elem0, base
          -- Which stage answered, and where: the next buffer gets a tight window around this
          -- arena, so at most one call ever pays for the wide stages.
          nl._win_hit, nl.arena = wi, base
          return base, elemsize, perchunk, fftsa.nl._wg(base + 68), nchunks
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
  local windows = fftsa.nl.scan_windows(buf, nil)
  local wi
  for wi = 1, table.getn(windows) do
    local hits = fftsa.nl.FINDS(windows[wi][1], windows[wi][2], needle)
    local k
    for k = 1, table.getn(hits) do
      local base = hits[k] - 116          -- 0x74, the capacity field
      local elem0 = fftsa.nl._wg(base + 72)   -- 0x48, the storage pointer
      if elem0 ~= nil and elem0 ~= 0 then
        local b, es, pc, v, nc = nl._read_desc(base, elem0)
        if b ~= nil then
          nl._desc_of, nl._desc_at = elem0, base
          nl._win_hit, nl.arena = wi, base
          return base, elem0, es, pc, v, nc
        end
      end
    end
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- The display task's own trace ring.
--
-- What the graph widget draws is not the buffer and not the buffer-side staging ring. It is a
-- ring of records the display task keeps, fed one record per buffer.write.reading, and writing
-- it directly is the only way past 510 blocking appends a frame: no bulk write exists, the
-- staging ring's pending count cannot be pre-loaded because the push sets it, and
-- display.setvalue refuses a graph with event 1717. All three measured.
--
-- NOTHING HERE IS A COMPILED ADDRESS AND NOTHING HERE IS AN ASSUMED OFFSET. The record stride
-- and the distance between a record's value and its x are both derived, because a DMM7510's
-- have never been measured and the operator's instruction is not to assume them. What is
-- assumed is only that the records are evenly spaced and hold the two fields as float32 pairs,
-- and the cross-check below fails closed if even that is wrong.
-- ---------------------------------------------------------------------------

-- A record is this far apart at most, and a ring holds between these many. Both are bounds on
-- a search rather than knowledge: the one measured geometry is 721 records of 56 bytes.
fftsa.nl.REC_MIN, fftsa.nl.REC_MAX = 16, 128
fftsa.nl.RING_MIN, fftsa.nl.RING_MAX = 8, 4096

-- Find the records the display task is drawing, from values only this app could have appended.
--
-- sentinels is the list of {db, hz} pairs just appended, in order, at least three of them with
-- distinct db values. The needle is a db packed as float32 TWICE, because the record holds two
-- copies of it side by side, and eight bytes of a specific float is not something the heap is
-- full of.
--
-- Returns a geometry table or nil, with nl.ring_why saying which term failed:
--   val0    address of sentinel 1's value field
--   stride  bytes between consecutive records, measured from two sentinels
--   dx      value field to x field, measured, and signed -- the x may precede the value
--   nconf   how many sentinels were confirmed at that geometry
function fftsa.nl.find_ring_records(sentinels)
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
  local n1, n2 = pat[1] .. pat[1], pat[2] .. pat[2]

  -- Both needles over the same windows. The second is what gives the stride: the display task
  -- appends in order, so sentinel 2's record is exactly one stride above sentinel 1's.
  local windows = nl.scan_windows(nil, nil)
  local h1, h2, wi = {}, {}, nil
  for wi = 1, table.getn(windows) do
    local a = nl.FINDS(windows[wi][1], windows[wi][2], n1)
    local b = nl.FINDS(windows[wi][1], windows[wi][2], n2)
    local k
    for k = 1, table.getn(a) do h1[table.getn(h1) + 1] = a[k] end
    for k = 1, table.getn(b) do h2[table.getn(h2) + 1] = b[k] end
    if table.getn(h1) > 0 and table.getn(h2) > 0 then break end
  end
  nl.ring_hits = table.getn(h1) .. '/' .. table.getn(h2)
  if table.getn(h1) == 0 or table.getn(h2) == 0 then
    nl.ring_why = 'value needle not in memory, hits ' .. tostring(nl.ring_hits)
    return nil
  end

  -- EVERY confirmed candidate, not the first. The buffer-side staging ring holds the same two
  -- float32 pairs in a 28-byte record, appended in the same order, so it confirms at a stride
  -- just as well -- and it is not what the widget draws. Only the header tells them apart, and
  -- the staging ring has no adjacent bounds pair to find, so the caller walks the list.
  local out, nout = {}, 0
  local a, b
  for a = 1, table.getn(h1) do
    for b = 1, table.getn(h2) do
      local s = h2[b] - h1[a]
      if s >= nl.REC_MIN and s <= nl.REC_MAX and math.mod(s, 4) == 0 then
        local g = nl._ring_confirm(h1[a], s, sentinels, pat)
        if g ~= nil then nout = nout + 1; out[nout] = g end
      end
    end
  end
  nl.ring_cands = out
  if nout == 0 then
    nl.ring_why = 'no stride between ' .. nl.REC_MIN .. ' and ' .. nl.REC_MAX
                  .. ' confirmed, hits ' .. tostring(nl.ring_hits)
    return nil
  end
  return out[1]
end

-- The whole discovery: the records, then the header that identifies which candidate is the
-- display task's ring rather than a staging ring that looks like one.
function fftsa.nl.find_ring(sentinels)
  local nl = fftsa.nl
  if nl.find_ring_records(sentinels) == nil then return nil end
  local c = nl.ring_cands
  local i
  for i = 1, table.getn(c) do
    if nl.find_ring_header(c[i]) ~= nil then
      nl.ring = c[i]
      nl.ring_why = nil
      return c[i]
    end
  end
  nl.ring_why = 'no header for any of ' .. tostring(table.getn(c)) .. ' record candidates: '
                .. tostring(nl.ring_why)
  return nil
end

-- Every sentinel at the proposed geometry, read as one block, plus the x field's offset.
-- Reading the whole span once rather than a field at a time is what makes a wrong candidate
-- cheap: a block that does not hold sentinel 3 is rejected on one memread.
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
  -- The x field, by searching one record's worth of bytes for the x the same append carried.
  -- Its offset comes back relative to the value field, which is all a writer needs: the record
  -- base, and therefore the offsets the firmware's own header uses, are never required.
  local xp = f32_pack(sentinels[1].hz)
  local one = ki.memread(hx(val0 - stride), hx(2 * stride))
  if one == nil or string.len(one) < 2 * stride then return nil end
  local p2 = f32_pack(sentinels[2].hz)
  local xn, at = xp .. xp, 1
  while true do
    local j = string.find(one, xn, at, true)
    if j == nil then return nil end
    local dx = j - 1 - stride
    -- Confirm the offset on a DIFFERENT record, because the eight bytes before the record can
    -- hold anything and the first match need not be the field. Every match is tried, so a
    -- decoy ahead of the real one costs one eight-byte read rather than the whole geometry.
    local x2 = ki.memread(hx(val0 + stride + dx), hx(8))
    if x2 ~= nil and x2 == p2 .. p2 then
      return { val0 = val0, stride = stride, dx = dx, nconf = ns }
    end
    at = j + 1
  end
end

-- The ring's own header, found from a record address and the stride rather than from an
-- offset. A writer needs it for the count and the cursors: the records alone are a picture
-- the task will overwrite from wherever its cursor happens to sit.
--
-- The header starts with the two bounds as adjacent words, which is what makes it findable:
-- a word pair (lo, hi) with hi above lo, their difference a whole number of records, and the
-- record we have already confirmed inside it. The two cursors and the count then have to be
-- consistent with those bounds, which is what rejects an unrelated pair.
--
-- The scan is local and bounded. The header measured 40 KB below the ring on a 6500 1.7.17a,
-- and the ring is at most RING_MAX records long, so a window either side of the record covers
-- it without sweeping anything.
fftsa.nl.HDR_BELOW, fftsa.nl.HDR_ABOVE = 262144, 65536
fftsa.nl.HDR_OLD, fftsa.nl.HDR_WRITE, fftsa.nl.HDR_COUNT = 8, 12, 20

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
  -- The candidate bounds are a pointer whose value is within one ring of the record, so its
  -- top half is one of a handful of values. Searching for those two bytes jumps between
  -- candidate positions instead of testing every word: a 2-byte prefix lands about five times
  -- in 320 KB, against 80,000 word positions to test blind.
  local maxspan = nl.RING_MAX * s
  local pre, np = {}, 0
  local t = math.floor(v / 65536)
  local lot = math.floor((v - maxspan) / 65536)
  -- Clamped, because a record below maxspan from zero makes this negative and math.mod keeps
  -- the sign -- string.char would then be handed a negative byte and RAISE, inside bind.
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
    -- Overlap by the longest structure a test reads, or a header straddling a slice edge is
    -- missed -- the same tail case FINDS has.
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
  -- The field offsets inside a record, which only the ring start can give. A writer does not
  -- need them -- it addresses fields relative to val0 -- but a report that names them is how
  -- an operator on an unmeasured model can say what their instrument's record looks like.
  g.ov, g.ox = found.ov, found.ox
  return g
end

-- One candidate, judged entirely on consistency. Six terms, and the value field's own address
-- is NOT one of them being on the record grid: that address is a field inside a record, not a
-- record base, so its distance from the ring start is the field offset and is a multiple of
-- nothing. What it does have to satisfy is that both eight-byte fields fit inside one record
-- at the offsets already measured, which is the term that replaces it.
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
  -- Where the two fields sit inside a record, and whether they both fit in one.
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

-- The header as five numbers. A caller proves the field order by CAUSE rather than by layout:
-- read this, append one reading, read it again. The count must rise by one and the write
-- cursor advance by exactly one stride. Nothing else in memory does that.
function fftsa.nl.ring_header(g)
  local nl = fftsa.nl
  if g == nil or g.hdr == nil then return nil end
  return { lo = nl._wg(g.hdr), hi = nl._wg(g.hdr + 4),
           oldest = nl._wg(g.hdr + nl.HDR_OLD),
           write = nl._wg(g.hdr + nl.HDR_WRITE),
           count = nl._wg(g.hdr + nl.HDR_COUNT) }
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
function fftsa.nl._abort(cb, pb, why)
  local nl = fftsa.nl
  -- Every caller names its own refusal. Without this the panel reports "rc=nil nil" and the
  -- nine ways init can give up before the native call are indistinguishable from each other.
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
    return nl._no('one install per boot is spent and reattach refused: the earlier '
                  .. 'install is gone or no longer validates')
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
  if nl._DSP_CODE == nil or string.len(nl._DSP_CODE) == 0 then
    return nl._no('native_code.tsp did not load: no image')
  end
  if nl._DSP_RELOC == nil then
    return nl._no('native_code.tsp did not load: no relocation table')
  end
  -- Zero or nil means the generated module never loaded, and every size below would then be
  -- wrong in a way that still produces addresses. PARAMS_SLOT and STATUS_OFF are in the list
  -- because without them the image gets no params address and reports nothing, which is a
  -- call into code whose one pointer is zero.
  if nl.SIZEOF_REAL == 0 or nl.SIZEOF_PLAN == 0 or nl.SIZEOF_PARAMS == 0 or
     nl.RES_DOUBLES == 0 or nl.RES_PEAKS == 0 or
     nl.PARAMS_SLOT == nil or nl.PARAMS_SLOT == 0 or
     nl.STATUS_OFF == nil or nl.STATUS_OFF == 0 then
    return nl._no('generated sizes are zero or nil: real=' .. tostring(nl.SIZEOF_REAL)
                  .. ' plan=' .. tostring(nl.SIZEOF_PLAN) .. ' params='
                  .. tostring(nl.SIZEOF_PARAMS) .. ' slot=' .. tostring(nl.PARAMS_SLOT)
                  .. ' status=' .. tostring(nl.STATUS_OFF))
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
    return nl._no('plan struct of ' .. tostring(nl.SIZEOF_PLAN)
                  .. ' bytes does not leave a chunk room for alignment')
  end
  -- Two arrays of want_nseg dsp_real share the reduction chunk with the results block,
  -- whose size is fixed by the image. DSPN_RES_BYTES in dsp_native.c, computed from the
  -- same two figures rather than sent across as a third.
  local res_bytes = nl.RES_DOUBLES * 8 + nl.RES_PEAKS * 4
                    + 2 * nl.RES_PEAKS * nl.SIZEOF_REAL
  nl.nseg_ceil = math.floor((nl.CHUNK_BYTES - 32 - res_bytes) / (2 * nl.SIZEOF_REAL))
  if want_n > nmax or want_nseg < 2 or want_nseg > nl.nseg_ceil then
    trace('size.refused', want_n, want_nseg)
    return nl._no('size refused: n=' .. tostring(want_n) .. ' max=' .. tostring(nmax)
                  .. ' nseg=' .. tostring(want_nseg) .. ' ceil=' .. tostring(nl.nseg_ceil))
  end

  -- 1. Firmware math addresses. All six are needed; dsp.c calls every one.
  trace('math')
  local nmath = nl.resolve_math()
  if nmath < 6 then
    return nl._no('resolve_math found ' .. tostring(nmath) .. ' of 6 libm entries: glue='
                  .. tostring(nl.nglue) .. ' need>=' .. tostring(nl.GLUE_MIN)
                  .. ' mathpos=' .. tostring(nl.math_pos) .. ' odd=' .. tostring(nl.math_odd))
  end
  trace('math.ok')

  -- 2. The ki.peek8 closure, and its original f pointer.
  local s = tostring(ki.peek8)
  local _, e = string.find(s, ': ')
  if not e then return nl._no('ki.peek8 does not tostring to an address: ' .. tostring(s)) end
  local cls = tonumber(string.sub(s, e + 1), 16)
  if not cls then return nl._no('ki.peek8 address will not parse as hex: ' .. tostring(s)) end
  -- This value is written back into a live lua_CFunction pointer by every redirect, so it
  -- is validated before it is kept, and one transport read is not enough: a desynchronised
  -- socket can return a heap address here, which the restore then writes into the dispatch
  -- path. Two agreeing reads, both inside firmware .text, or refuse.
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
  if pdesc == nil or pdesc.vec == nil then
    return fftsa.nl._abort(cb, pb, 'plan buffer: no descriptor found by sweep -- '
                           .. tostring(nl._stor_why) .. ' raw=' .. tostring(nl._raw_n)
                           .. ' hits=' .. tostring(nl._hit_n)
                           .. ' first[' .. tostring(nl._hit_why) .. ']'
                           .. ' inst=' .. hx(nl.inst or 0)
                           .. ' anchor=' .. hx(nl.heap_anchor() or 0)
                           .. ' ' .. fftsa.nl.windows_str())
  end
  trace('plan.desc', hx(pdesc.chunk1), tostring(pdesc.nchunks))

  -- The vector has to hold the entries about to be read out of it. The chunk count is the
  -- descriptor's own field at +0x10, so this is the allocator's answer and not an inference
  -- from the capacity asked for: one entry past the end returns whatever follows in the
  -- heap, and anything that looks like a heap address passes the native backstop.
  -- Everything below lays the plan out against nl.CHUNK_BYTES, and the compiled image
  -- bounds a strided walk with DSPN_CHUNK_BYTES, so a payload of some other size cannot be
  -- used even though the descriptor is now recognised. Reported with the real figure, which
  -- is what parameterising both sides would need.
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

  -- Chunk payload addresses from the vector. They are neither in address order nor
  -- adjacent, which dsp_plan_init_segs does not care about and nothing here may assume.
  -- Each is checked against the backstop here as well as by the native entry point, so a
  -- bad vector is a refusal from Lua rather than a status code from a call already handed
  -- it. These addresses are the allocator's own answer, read from the descriptor's chunk
  -- vector, and they are what the writable window below is derived from -- so this is a
  -- sanity check on the descriptor, not the bound that keeps a write off firmware.
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

  -- Segment bases rounded up to DSP_ALIGN: the allocator guarantees 16 and dsp.c needs 32,
  -- so a raw payload is refused with DSPN_EBOUNDS half the time. The raw payloads still
  -- define the window below, the rounding losing addressable bytes and not permission.
  local segbase = {}
  for i = 1, nseg do
    segbase[i] = align32(payload[i])
    if (segbase[i] - payload[i]) + nl.SEG_BYTES > nl.CHUNK_BYTES then
      return fftsa.nl._abort(cb, pb, 'segment ' .. tostring(i) .. ': ' .. tostring(nl.SEG_BYTES)
                             .. ' bytes will not fit a chunk after 32-byte alignment')
    end
  end

  -- The first nseg chunks are the arena, then the plan struct, then the reduction's two
  -- arrays. The struct has its chunk to itself, and nothing shares it: the transform reads
  -- the capture in place, so there is no de-strided copy to place after it.
  local host      = align32(payload[nseg + 1])
  local plan_addr = host
  if (host - payload[nseg + 1]) + align8(nl.SIZEOF_PLAN) > nl.CHUNK_BYTES then
    return fftsa.nl._abort(cb, pb, 'plan struct of ' .. tostring(nl.SIZEOF_PLAN)
                           .. ' bytes will not fit a chunk')
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
    return fftsa.nl._abort(cb, pb, 'reduction arrays plus a ' .. tostring(res_bytes)
                           .. '-byte results block will not fit a chunk')
  end

  -- The segment vector itself, in the code buffer above the params struct.
  local segs_addr = nl.params + align8(nl.PARAM_WORDS * 4)
  if (segs_addr - code_base) + nseg * 4 > nl.CHUNK_BYTES then
    return fftsa.nl._abort(cb, pb, 'the ' .. tostring(nseg)
                           .. '-entry segment vector will not fit above the params struct')
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
    return fftsa.nl._abort(cb, pb, 'MODE_INIT refused with rc=' .. tostring(rc))
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
    desc, elemsize, perchunk, vec, nchunks = fftsa.nl._find_desc(elem0, buf)
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
