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
  EOUTPUT = -6, EDESC = -7, EARENA = -8, ERUN = -10, EMATH = -11,
  EREDUCE = -12, ERESULT = -13, EFIND = -14,
}

-- THE OTHER ERROR SPACE, forwarded through the same status word.
--
-- MODE_INIT hands back whatever dsp_plan_init_segs returned, and dsp.h's DSP_E* set is small
-- negatives like this one: DSP_EBETA is -6 and so is RC.EOUTPUT, so a Kaiser beta the plan
-- builder refused used to be reported as an output-geometry fault. There is one word and no
-- room for a tag, so the image SHIFTS a forwarded negative by PLAN_BASE and rc_name subtracts
-- it again. Every code in csrc/dsp.h's enum is named here; csrc/tools/check_rc.py holds the
-- two lists together, this file being the only place they could drift apart.
fftsa.nl.PLAN_BASE = -100
fftsa.nl.PLAN_RC = {
  EARG = -1, EPOW2 = -2, ENOMEM = -3, EUNSUPPORTED = -4, ESHORT = -5,
  EBETA = -6, EDECLINE = -7, EALIGN = -8, EZONE = -9, EDIRTY = -10,
  ESEG = -11,
}

-- A return code as its name, for anything an operator reads. "rc=-11" needs this file open
-- beside it; "rc=-11 EMATH" says a libm entry was refused, which is actionable from the
-- glass. The table is written name-to-number because that is how the code uses it, so this
-- walks it rather than keeping a second copy that could disagree.
-- The line of dsp_native.c that returned goes on the end as @NNN, and it is the half that
-- places a fault: there are 31 refusal sites against thirteen codes, and DSPN_ECAPTURE alone
-- has three sites with ten conditions among them. So the code names the stage and the line
-- names the test. Four characters on a settings line that holds 70, and placing one rc=-5
-- cost a hand-decoded hex dump of a descriptor without it.
function fftsa.nl.rc_name(rc)
  if type(rc) ~= 'number' then return tostring(rc) end
  local at = ''
  if rc ~= 0 and type(fftsa.nl.fail_at) == 'number' and fftsa.nl.fail_at ~= 0 then
    at = '@' .. tostring(fftsa.nl.fail_at)
  end
  local k, v
  -- The forwarded space first, and named as such: "plan EBETA" says the refusal came from the
  -- plan builder and not from the wrapper, which is the distinction the raw numbers lost.
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

-- DSP_THD_MAINS_* from csrc/dsp.h. Hum at a multiple of the selected mains frequency is
-- passed over when the fundamental is sought, and BOTH discounts 50 and 60. The image also
-- takes 50 or 60 alone; this app has no mains setting and sends BOTH on every frame, so the
-- other two are not named here.
fftsa.nl.MAINS_BOTH = -1

fftsa.nl.MODE_INIT  = 1
fftsa.nl.MODE_RUN   = 2
fftsa.nl.MODE_SEGS  = 4
-- The byte-pattern search, run in the image because Lua cannot afford it: there a sweep is
-- ki.memread per 32 KB over the control path at 25 MB/s measured, so one pass over the
-- backstop is 800 frames of the budget a frame can spare. Native code is in the same address
-- space and loads memory directly -- no IPC, no block, no budget.
fftsa.nl.MODE_FIND  = 5
-- The graph ring's y pixels, written in the image from the reduction's own array. What it
-- replaces in Lua is a loop over the trace columns, a second over the ring slots, a
-- table.concat of three pieces per record and one 28 KB ki.memwrite -- 9.6 ms measured for
-- the memwrite alone at 510 records, against a multiply, a clamp and three stores per record
-- here. Nothing is copied in to make the call: the decibels are already in the arena, which
-- is where dsp_reduce put them.
fftsa.nl.MODE_PX    = 6

fftsa.nl.MAGIC = 1146310705   -- 0x44535031, 'DSP1'

-- DSP_FFT_* from csrc/dsp.h. Four-step is the default there and the only one measured on the
-- instrument, and the only one this side sends. The host equivalence tests run radix-2 as well,
-- through the C enum rather than through here.
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
fftsa.nl.PARAM_WORDS = 55

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

-- Shape of the graph ring block, also from the image: its total words, the slot-map entries
-- it can hold and the header words before that map. Zero until the generated module loads,
-- which leaves the ring write unavailable and the frame on its Lua writer.
fftsa.nl.PX_WORDS  = 0
fftsa.nl.PX_MAXREC = 0
fftsa.nl.PX_HDR    = 0

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
-- The same, for a value that came from a GUARDED read and may therefore be nil. hx would raise
-- on it, and the places that format one are all diagnostics in the frame path -- so a refused
-- read would have thrown inside the frame instead of reaching the About page with its reason.
local function hxn(v)
  if type(v) ~= 'number' then return tostring(v) end
  return string.format('%X', v)
end

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
--
-- THROUGH THE GUARD, not through W. The content scan confirms a candidate at its far
-- indices, which is the hit plus 255 strides -- 8160 bytes at a 32-byte element -- and a hit
-- can sit anywhere in the swept window including its last word. Measured from a hit at
-- BACKSTOP_HI - 32: the confirmation reached 8128 bytes PAST the top of DRAM, which is an
-- unguarded lwz and a bluescreen. W's own contract says every address it is handed comes
-- from inside the window, and this is the one caller for which that was never true.
--
-- nil reads as not-equal, which is the right answer and not a compromise: a record whose
-- tail is outside the backstop is one the native side could not read either, so refusing it
-- here is the same refusal one step earlier.
local function eq64(addr, v)
  local hi, lo = f64_words(v)
  local g = fftsa.nl._wg
  return g(addr) == hi and g(addr + 4) == lo
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
  nl.nglue = nglue
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
  fftsa.nl.rd_note(4)
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
-- ONE WORD FROM A POINTER A FIRMWARE STRUCTURE HANDED US.
--
-- WHAT MAKES THIS SAFE IS THE BOUNDS, NOT THE PRIMITIVE, and getting that backwards cost two
-- changes in a row. ki.memread is `lua_pushlstring(L, (const char *)addr, count)` -- a straight
-- copy from wherever the address parsed to -- and peek8/16/32 end in the load itself. NEITHER
-- validates an address, so neither is the safe alternative to the other.
--
-- What decides whether a load faults is the BATs the boot code programs, and DRAM is ONE BAT:
-- 0x00000000..0x10000000, all 256 MB of it, mapped read/write. There is no unmapped hole inside
-- it to hit. So an aligned read anywhere in the backstop cannot take a data storage interrupt,
-- and a pointer followed out of a firmware structure needs no proof that its target is mapped.
-- Every bluescreen on record came from an address OUTSIDE the five mapped ranges, and from one
-- cause: a numeric argument rendered in decimal and then parsed as hex.
--
-- px_live was therefore the wrong gate, and it cost the whole route on a relaunch. Its span is
-- built from addresses THIS APP has read -- useful for rejecting a garbage widget pointer, no
-- use at all as a fault guard. Measured at 9.24 run 2: the chain found the right slot and the
-- right trace and px_live refused it 209 times, `3E0EF30 outside 11EB018..3C8C7C8`, because the
-- display task had allocated above the app's own allocations. The comment on px_live predicted
-- exactly that and I walked into it from the other side.
--
-- So this reads through memread, which costs the same single round trip as peek32 and returns
-- the bytes without a hex round-trip, and it applies the SAME bounds _wg does -- including the
-- lower one. Without that it would read the vector area, which is mapped and meaningless.
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
  -- A decibel decode that failed draws nothing and says nothing anywhere else: the frame
  -- keeps the previous trace and carries on. Zero is the normal reading.
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
  -- The four the DMM7510 report could not answer: how much of the sweep reached memory, where
  -- the addresses it did find are, what the derived pass made of them, and the words
  -- themselves -- which is what makes the layout settleable from one grab instead of a round
  -- trip to another continent for each field.
  o = o .. ' | ' .. nl.sweep_str() .. ' ' .. nl.hits_str()
  o = o .. ' ' .. nl.desc_off_str() .. ' der[' .. tostring(nl._der_why) .. ']'
  o = o .. ' sig[' .. tostring(nl._sig_why) .. ']'
  o = o .. ' buf=' .. tostring(nl._desc_buf) .. ' cp=' .. tostring(nl._ncol)
  -- The element stride the content scan measured, and element 0. This is the figure that
  -- decides whether the native read is possible at all, it is per model -- a DMM7510's
  -- STYLE_STANDARD element is 20 bytes where a DMM6500's is 24 -- and it survives a failed
  -- descriptor walk, which is when it is most wanted. Without it on the page it has to be
  -- decoded out of the hit dump a word at a time.
  o = o .. ' str=' .. tostring(nl._stor_stride)
  o = o .. ' e0=' .. (nl._stor_elem0 ~= nil and hx(nl._stor_elem0) or 'nil')
  -- THE GEOMETRY THE NATIVE CALL WAS ACTUALLY HANDED, which is what every capture-side
  -- refusal is a judgement on. Without it a refusal names a test whose inputs are not on the
  -- page, and each one costs a round trip to another continent to ask for one more figure.
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

-- How much of a sweep reached memory. A window can run past the end of DRAM and a block can
-- come back nil or short, neither of which is an error here -- but "swept everything and the
-- needle is not there" and "swept almost nothing" are the same report without these counters,
-- and they call for opposite fixes. A DMM7510 reported 30 raw hits and no descriptor, which
-- either answer explains.
fftsa.nl._sw_blocks, fftsa.nl._sw_nil, fftsa.nl._sw_short, fftsa.nl._sw_bytes = 0, 0, 0, 0

function fftsa.nl.sweep_reset()
  local nl = fftsa.nl
  nl._sw_blocks, nl._sw_nil, nl._sw_short, nl._sw_bytes = 0, 0, 0, 0
end

-- Megabytes, because the figure an operator has to read off the glass and compare against a
-- heap size is the order of magnitude, and a byte count of nine digits costs a line.
function fftsa.nl.sweep_str()
  local nl = fftsa.nl
  return 'read=' .. tostring(math.floor((nl._sw_bytes or 0) / 1048576)) .. 'MB/'
         .. tostring(nl._sw_blocks) .. 'blk nil=' .. tostring(nl._sw_nil)
         .. ' short=' .. tostring(nl._sw_short)
end

-- ---------------------------------------------------------------------------
-- WHAT A FRAME IS ALLOWED TO READ, counted rather than reasoned about.
--
-- Four separate costs in this module turned out to be an iteration count taken from the heap
-- with an IPC round trip in the body, inside a frame that cannot be interrupted: 257 peek32 per
-- name hit, 29 memread per frequency hit, an unbudgeted whole-DRAM holder sweep, and a slice
-- re-walked for ever. Each was found on the glass, one at a time. Bounding them one at a time
-- is how the fourth came to exist.
--
-- Every read in the module reports its size here, and the FRAME-DRIVEN loops answer to it:
-- px_seek's slice walk and its per-hit walk stop when the allowance is spent and carry on next
-- frame with their cursors intact.
--
-- IT IS NOT ENFORCED INSIDE FINDS, and that distinction is the point. FINDS is also the
-- descriptor discovery that nl_bind runs at Apply, where sweeping for a second or two is the
-- expected cost and there is no frame to protect -- gating it there made bind fail outright.
-- What bounds a single FINDS call is its caller's slice, which is PX_BUDGET. Likewise
-- find_ring_header is bounded by HDR_BELOW + HDR_ABOVE, 320 KB in ten blocks.
--
-- The accounting is the half that matters most. A loop that forgets to ask the budget still
-- cannot run away unseen, because its reads land in peak= on the diagnostic page.
fftsa.nl.RD_MAX_CALLS = 48
fftsa.nl.RD_MAX_BYTES = 393216          -- 384 KB, about 15 ms at the measured 25 MB/s

fftsa.nl._rd_calls, fftsa.nl._rd_bytes = 0, 0

-- Called at the top of every entry point that reads, keyed on the caller's own timestamp.
--
-- KEYED, AND NOT LEFT TO THE CALLER TO REMEMBER. The first form of this was a call in
-- sg_pix_draw, which meant anything else driving px_try -- a probe, a test, a future caller --
-- never refilled the allowance, so the search stalled permanently after its first 48 reads.
-- A budget whose refill is somebody else's job is not a budget. Both halves of a frame take
-- their own stamp from sg_stamp, so each gets its own allowance and neither can be starved by
-- the other.
function fftsa.nl.rd_frame(t)
  local nl = fftsa.nl
  if t ~= nil and t == nl._rd_t then return false end
  nl._rd_t = t
  -- The measured span's age, in frames, which is the only frame counter in the module and the
  -- only place a frame boundary is known.
  nl._map_age = (nl._map_age or 0) + 1
  nl.rd_frame_reset()
  return true
end

-- Keeps the frame just ended as last= and the worst ever as peak=, which is the figure that
-- says whether anything is running away.
function fftsa.nl.rd_frame_reset()
  local nl = fftsa.nl
  if (nl._rd_calls or 0) > (nl.rd_peak_calls or 0) then nl.rd_peak_calls = nl._rd_calls end
  if (nl._rd_bytes or 0) > (nl.rd_peak_bytes or 0) then nl.rd_peak_bytes = nl._rd_bytes end
  -- AND A PEAK FOR SEARCH FRAMES ALONE. peak= is dominated by the bind-time descriptor
  -- discovery, which runs before any frame does and so lands in the first frame's account:
  -- 6779 calls and 132 MB, which is not a frame and cannot be compared with a 48-call
  -- allowance. Without a figure that excludes it there is no way to tell whether a search frame
  -- is reading forty-eight times or six thousand.
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

-- THE IMAGE'S BYTES ARE NOT READ BYTES, and keeping them apart is what lets the search run at
-- the speed of the hardware.
--
-- RD_MAX_BYTES bounds the IPC a frame may spend: each ki.memread is a round trip through the
-- firmware's read path at 25 MB/s, and 384 KB of it is 15 ms. The image's scan shares none of
-- that -- one round trip sets up the request and the loop then loads DRAM directly -- so the
-- same byte count costs a different time, and charging it to the read allowance stopped the
-- native slice at a Lua slice's size. The round trip is still counted, with no bytes against
-- it; the bytes are counted here and bounded by px_nbudget, which is timed.
function fftsa.nl.nf_note(bytes, secs)
  local nl = fftsa.nl
  nl._nf_bytes = (nl._nf_bytes or 0) + (bytes or 0)
  -- AND THE TIME THE SCAN ITSELF TOOK, which is not the time the slice took.
  --
  -- px_nb_note used to be handed the clock either side of the whole px_seek call, and I argued
  -- that attributing the adjudication to the scan only made the budget smaller, so it was safe.
  -- It is not safe. Measured on the glass at 9.05, two launches apart: nh=2 gave @28MB/s and an
  -- 846 KB slice; nh=91 gave @4MB/s and the slice back on its floor. Ninety-one name hits is
  -- ninety-one window reads through the firmware, and charging those to the bytes the image
  -- scanned collapses the budget exactly when there is most range left to cover.
  --
  -- So the scan is timed where it happens, around the image call and nothing else.
  nl._nf_secs = (nl._nf_secs or 0) + (secs or 0)
end

-- Has this frame read enough? Asked by every resumable loop in the search.
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
  -- The image's own account, and the budget the clock settled it on. Reported because the
  -- whole of the native search's speed is in these two figures and neither is asserted
  -- anywhere: nf= is what one frame scanned, nb= what the next frame may.
  if (nl.nf_peak_bytes or 0) > 0 then
    o = o .. string.format(' nf=%dKB/%dKB nb=%dKB', math.floor((nl.nf_last_bytes or 0) / 1024),
                           math.floor((nl.nf_peak_bytes or 0) / 1024),
                           math.floor((nl.px_nbudget or 0) / 1024))
    if nl.px_nrate ~= nil then
      o = o .. string.format(' @%.0fMB/s', nl.px_nrate / 1048576)
    end
    -- The fixed cost, which is the figure that explains the budget: it is what the target has
    -- to clear before a bigger slice buys anything at all.
    if nl.px_nover ~= nil then
      o = o .. string.format(' oh=%.1fms', nl.px_nover * 1000)
    end
  end
  return o
end
-- ---------------------------------------------------------------------------

fftsa.nl.SWEEP_BLOCK = 32768

-- Prefer the image. One place, so every caller of FINDS gets it -- the ring search and the
-- bind-time descriptor discovery alike -- without any of them knowing.
--
-- The contract is FINDS', not nfind's: every hit in the range, not the first thirty-two. So
-- this loops on the resume address the image returns. Each call is bounded by FIND_MAX hits
-- and by NFIND_CAP bytes, and `next` strictly advances, so it terminates.
--
-- AND IT NEVER RETURNS EARLY, which the first version did on the read budget. A partial answer
-- from FINDS is indistinguishable from "the needle is not in this range", so a caller moves
-- its cursor past bytes nothing looked at -- the same defect that cost 981 MB of sweeping when
-- a confirmation was dropped instead of returned. What keeps a frame a frame is the CALLER's
-- range: px_seek slices at PX_BUDGET, and bind-time discovery is not in a frame at all.
-- THE NATIVE SEARCH IS OFF, AND PROBING FOR THE EDGE OF MEMORY IS WHY.
--
-- Three attempts, two bluescreens at PC=0022D200, and the premise was wrong from the start.
--
-- The first bounded the image's find loop by the BACKSTOP, 0x3000..0x10000000. That is the span
-- the LUA side may ask about, not the span that is mapped: DRAM ends far below it and the image
-- loads directly, so the scan walked off the end. Data storage interrupt.
--
-- The second tried to MEASURE the mapped range, probing outward with ki.memread until a read
-- refused. There is no such refusal. nl._wg's own comment in this file says it outright --
-- "ki.peek32 is an lwz with no validation, so a bad address is a precise data storage
-- interrupt and a bluescreen" -- and ki.memread is no different. The probe meant to find the
-- edge of memory is itself the thing that falls off it, which is why that attempt crashed
-- before a single frame was drawn.
--
-- So neither a probe nor the backstop can establish this. What would: a range mapped by
-- CONSTRUCTION -- the chunk payloads this app already owns, or heap bounds read out of the
-- firmware's own allocator structures rather than guessed at from outside. Until there is one,
-- the Lua sweep runs. It is slow and it has never once crashed, because every address it hands
-- ki.memread comes from a window something else already proved.
-- THE LUA SWEEP LOOP IS NOT REACHABLE FROM THE PIXEL PATH. There is no knob for it, because a
-- knob is a configuration in which it runs: operator, 2026-11-11, "The LUA sweep loop is NEVER
-- acceptable." One pass over the backstop at 25 MB/s is 800 frames.
--
-- So the pixel path engages by pointer or by cache, and if it must search, the image does it.
-- FINDS_NATIVE_ONLY is set for the duration of a px_seek slice and makes FINDS answer nil
-- rather than reaching for the loop -- nil, not an empty table, because "no hits here" would
-- move the caller's cursor past bytes nothing looked at.
--
-- The loop itself stays in FINDS for the bind-time descriptor discovery, which is one search at
-- Apply and has always worked. The offline suite emulates the image rather than enabling the
-- loop, so nothing in the pixel path's tests depends on a path the app cannot take.
fftsa.nl.FINDS_NATIVE_ONLY = false

-- Suite-only, and false in the app. The offline tests drive the ladder that bind-time
-- descriptor discovery shares; the app has no way to set this and the gate below asserts the
-- shipped value, so there is no configuration of the APP in which the Lua loop runs.
fftsa.nl.PX_SWEEP = false

-- Frames the pointer route is given before anything else is tried. It needs the app to have
-- allocated enough for px_live to have a span, which takes a few frames from launch, and the
-- hold after each restart spaces them out. Thirty is a couple of seconds and it costs a few
-- reads a frame.
fftsa.nl.PX_PTR_TRIES = 30

fftsa.nl.NFIND = true

-- THE RANGE, FROM ADDRESSES THIS MODULE HAS ALREADY DEREFERENCED.
--
-- Not a probe. Every address below is one something has read successfully this session, so each
-- is mapped by evidence rather than by assumption:
--
--   the heap anchor      a live Lua table's own storage, via tostring
--   the C++ instance     the trace buffer's, through its metatable's CClassRef
--   the chunk payloads   handed over by the firmware's allocator and written every frame
--   the plan arena       allocated by this app and written by the image already
--   a confirmed ring     found and validated by a previous search, if there was one
--
-- The span between the lowest and highest of them is one allocator region, so the memory
-- between two live allocations is heap and is mapped. That is the whole claim, and it is a
-- different kind of claim from "the backstop says 256 MB" or "probe until a read refuses":
-- both of those reasoned about memory nothing had touched.
--
-- Two or more distinct addresses are required -- one gives no span -- and the result is
-- clamped to the backstop as a second line. Narrow is fine: it is where this app's own
-- allocations live, which is where the display task's allocations live too, and every ring
-- found on this bench has been inside it.
fftsa.nl.MAP_MIN_SPAN = 65536

-- Frames a measured span is kept before it is taken again.
--
-- IT IS MEASURED TOO EARLY TO BE FINAL, and everything downstream is clamped to it: the range
-- the image is given, and px_live's gate on every dereference. The first answer can come
-- before the buffer has its chunks, so the span can be narrower than the heap the display task
-- is allocating in -- and a span frozen below the ring is a session that can never find it.
--
-- So it is re-derived on a cadence and UNIONED with what was already known. Every address in
-- either half was dereferenced successfully, so the union is still a span of proven memory and
-- it can only widen. Sixteen frames is about a second, and the twenty-four reads it costs land
-- in one frame of the sixteen rather than in every one.
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
  -- THE TRACE THE SUBSCRIBER CHAIN CONFIRMED. The span is otherwise built from addresses this
  -- APP has read, and the trace object belongs to the display task -- so on a relaunch it can
  -- sit outside, and px_from_trace would refuse the one answer the chain had already proved.
  -- It is added only after the slot's kind matched, the routing pointer lay inside the named
  -- graph's array, and the trace pointed back at both: at that point the firmware has told us
  -- three times over where its object is, and a memread of it has succeeded.
  -- BOTH ENDS OF WHAT WILL BE READ FROM IT. The span's ceiling is max(known) and px_live asks
  -- for `addr < hi`, so noting the trace's own address sets the ceiling TO it and still refuses
  -- it -- the widening would have done nothing for the one address it was added for. Noting the
  -- end of the range px_from_name walks is what actually covers the object.
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
  -- A re-derivation that comes up short does not throw away a span that stood: the addresses
  -- that made it were read successfully, and the age is reset so the cost is not paid again on
  -- the next call.
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
  -- The union with what was already known, which is what makes this widen and never narrow.
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

function fftsa.nl._finds_native(lo, hi, pat)
  local nl = fftsa.nl
  if not nl.NFIND then return nil end
  if nl.nfind == nil or not nl.ready then return nil end
  -- CLAMPED TO MEASURED MEMORY, not to the backstop. Outside it there is nothing to find and
  -- a load would fault, so a range wholly outside answers "no hits" -- which is what the Lua
  -- sweep answers there too, by skipping the blocks ki.memread refuses.
  local mlo, mhi = nl.map_bounds()
  if mlo == nil then return nil end
  if lo < mlo then lo = mlo end
  if hi > mhi then hi = mhi end
  if hi <= lo + string.len(pat) then return {} end
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
    -- The bytes the image actually scanned, so swept= and nf= tell the truth. Accounted but
    -- NOT obeyed: this must finish the caller's range.
    --
    -- The round trip is charged to the read allowance with no bytes against it, because that
    -- is what it costs -- one request write, one call, one answer read. The bytes are charged
    -- to the image's own account, which px_nbudget bounds from the clock.
    nl._sw_bytes = (nl._sw_bytes or 0) + (nxt - at)
    nl._sw_blocks = (nl._sw_blocks or 0) + 1
    nl.rd_note(0)
    nl.nf_note(nxt - at, el)
    at = nxt
  end
  return out
end

function fftsa.nl.FINDS(lo, hi, pat)
  local nl  = fftsa.nl
  -- The image first. nil means there is none, or it refused, and the Lua sweep below is what
  -- every build before the native search shipped with.
  local nat = nl._finds_native(lo, hi, pat)
  if nat ~= nil then return nat end
  -- The pixel path takes native or nothing: an empty table here would read as "the needle is
  -- not in this range" and move its cursor past bytes nothing looked at.
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
    -- Advance by what came back, not by what was asked for. A block answering short with the
    -- step taken from the request leaves everything between them unsearched -- on a 268 MB
    -- sweep that is most of it -- and the sweep still reports the hits it did reach, so the
    -- caller sees "swept and absent" for a needle it never looked at. _sw_short counts it.
    local nexta
    if got >= pl then
      -- Terminate on the tail rather than on the step, or the overlap subtraction
      -- leaves the address unchanged and the loop never ends.
      if a + got >= hi then break end
      nexta = a + got - (pl - 1)
    else
      -- Nothing usable came back: step over the block rather than re-reading it. want is at
      -- least one byte while a < hi, so this always advances.
      nexta = a + want
    end
    if nexta <= a then nexta = a + want end
    a = nexta
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
  fftsa.nl.sweep_reset()
  for wi = 1, table.getn(windows) do
    local hits = fftsa.nl.FINDS(windows[wi][1], windows[wi][2], needle)
    nhits = nhits + table.getn(hits)
    local k
    for k = 1, table.getn(hits) do
      local h = hits[k]
      -- 4 and not 16: element 0 is not the chunk payload, so the allocator's guarantee does
      -- not reach it, and a 16-byte filter rejects real storage -- the trace buffer's element
      -- 0 is measurable at 0x037C71C8. Not 8 either: a 20-byte element puts half the readings
      -- in a record on a 4-aligned address, so the firmware is not loading them 8-aligned and
      -- element 0 need not be. The discrimination is the extras and the far readings below.
      if math.mod(h, 4) == 0 then
        -- Candidate strides 32, 24 and 20, all three unconditionally: they are the element
        -- sizes this firmware uses -- WRITABLE_FULL 32 on both models, STANDARD 24 on a
        -- DMM6500 and 20 on a DMM7510 -- and 32 is the only one that can hold the extra
        -- value at +20. The discovered offsets after them cover an element none of the three
        -- matches, and they can only be measured where readings 1 and 2 differ -- with every
        -- reading equal each offset matches and the list fills with noise, which is a quiet
        -- capture at 4.5 digits. 20 is in the list for exactly that case: a DMM7510 reported
        -- "no stride confirmed ... eq12=true", a quiet capture whose stride the discovery
        -- loop never ran to find. Each candidate still gets the full confirmation, and
        -- describe() checks the winner against the descriptor's elemsize.
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
                       .. ' ' .. fftsa.nl.sweep_str()
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

-- The descriptor field offsets, named rather than spelled out at each use so the derived
-- route below has something to compare what it found against, and so the one place that
-- matters -- the native cursor rewind, which writes at compiled offsets -- can refuse a
-- layout that is not the one the image was built for.
--
-- DOFF is the DMM6500's and the only one anything may be written at. DOFF_7510 is where the
-- same fields were found on a DMM7510 1.7.16a: vec, stor, s1, s2 and cap all 8 lower, es, pc
-- and nc unmoved. Read off three error pages, from two different buffers in two different
-- boots, after the derived route had already answered with them -- so it is that route's
-- finding written down, which is what lets the signature route below answer on that model
-- without the readings having to differ.
--
-- WHAT THE IMAGES DO AND DO NOT SETTLE. notes/firmware/structmatch.py finds the initialiser
-- 1044 bytes byte-identical at 6500 1.7.18 file offset 0x3F2AFC and 7510 1.7.16a 0x221DE4,
-- which was once read as proving the layout identical on both. It does not: that function
-- stores to EVERY 4-byte displacement from 0x04 to 0x94, as an unrolled init of a 16-byte
-- strided array -- r11 to 0x2C,0x3C,..,0x9C and r12 to 0x30,0x40,..,0x90 -- and a function
-- that writes every slot in a range cannot say which slot is which field. The 16-byte period
-- is visible in the records themselves: on the 7510 the words at +0x4C..+0x58 and +0x5C..+0x68
-- repeat the same (owner, ptr, ptr, count) shape, so the pair this module calls two owner
-- self-pointers is the owner field of two CONSECUTIVE array entries, and the 8 between the
-- models is where the array starts.
--
-- So these are two measured offset sets and not a derivation. Nothing rests on them being
-- right: every candidate is confirmed by content -- the storage pointer has to equal the
-- element 0 the scan measured, two words have to equal the base, and the geometry has to tile
-- a power-of-two payload -- so a wrong set fails to find rather than finding something wrong.
-- The route that needs no table at all is _derive_desc, and making the signature route derive
-- its base the same way would retire both of these.
fftsa.nl.DOFF = { es = 8, pc = 12, nc = 16, vec = 68, stor = 72, s1 = 84, s2 = 100,
                  cap = 116 }
fftsa.nl.DOFF_7510 = { es = 8, pc = 12, nc = 16, vec = 60, stor = 64, s1 = 76, s2 = 92,
                       cap = 108 }

-- Every layout to try, the compiled one first.
--
-- WHY A SECOND SET COSTS NO FALSE POSITIVE, stated correctly: it is not that the two sets
-- space those three words differently -- they do not, s1 and s2 are stor+12 and stor+28 in
-- both, and cap-32 and cap-16 in both. It is the VALUE the self-pointers have to hold. From
-- a sweep hit h the base is h-72 at one set and h-64 at the other, and the word at h+12 has
-- to equal whichever one is being tried, so at most one set can confirm. That is a stronger
-- property than the spacing claim and it is the one that holds.
--
-- It holds only for the two routes that anchor on a hit. _read_desc takes a base the caller
-- already has and tries each set at it, and a single base CAN satisfy both -- so the order
-- here is what decides, and the compiled set being first is what makes that safe. The order
-- is also per hit and not global: the layout loop is inside the hit loop, so a second-set
-- match on an earlier hit beats a first-set match on a later one.
--
-- And on the signature route there is one fewer check than it looks. elem0 is read FROM
-- base+stor there, so _read_desc_1's storage-pointer test is an identity on that path, which
-- also makes describe's "elemsize must equal the measured stride" cross-check compare the
-- descriptor's figure with itself. geom_ok is what closes that: it asks the firmware for the
-- readings at a chunk boundary, which no descriptor field can satisfy by agreeing with
-- itself.
fftsa.nl.DOFF_SETS = { fftsa.nl.DOFF, fftsa.nl.DOFF_7510 }

-- Which set last answered, so desc_off_ok() can refuse a write at offsets the image does not
-- use. nil until a descriptor has been read.
fftsa.nl.doff_used = nil

-- One candidate layout, read at D's offsets.
--
-- Every read here is guarded, not raw. A base reaching this is a word the firmware handed us
-- -- a cached one, a sweep hit, or a pointer out of the instance's column chain -- and only the
-- sweep hit is known to be in DRAM at all. An unguarded peek32 on the other two is an lwz on an
-- arbitrary address, which is a precise data storage interrupt and a bluescreen.
--
-- note belongs to the sweep's hit loop and to nothing else. It counts a candidate that got
-- past the two owner self-pointers and names the first one's geometry, which is what tells
-- "the sweep found the storage address but the record is shaped differently" from "the sweep
-- never covered it" -- the distinction a DMM7510 report could not make. The other callers
-- search on a different needle, so counting their candidates in the same two fields would
-- make the figure on the error page mean two things.
function fftsa.nl._read_desc_1(base, elem0, D, note)
  if base == nil then return nil end
  local nl = fftsa.nl
  local g = nl._wg
  if g(base + D.stor) ~= elem0 then return nil end     -- 0x48, the storage pointer
  if g(base + D.s1) ~= base or g(base + D.s2) ~= base then return nil end
  local elemsize = g(base + D.es)
  local perchunk = g(base + D.pc)
  local nchunks  = g(base + D.nc)
  -- The element size is a runtime field and need not divide the payload: a STYLE_STANDARD
  -- element of 24 bytes puts 1365 in a 32,768-byte payload, filling 32,760 and leaving 8
  -- spare, and one of 20 puts 1638 there for the same 8. So the test is a fit rather than an
  -- exact product, and _chunk_span finds which payload size it is a fit for.
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
  -- The chunk count comes back with the vector because a caller indexing it has no other way
  -- to know where it ends, and an entry too far returns whatever follows in the heap -- which
  -- could pass the backstop and be written to.
  return base, elemsize, perchunk, g(base + D.vec), nchunks
end

-- Every candidate layout, from a base the caller already believes is a descriptor base --
-- a cached one, or a pointer out of the instance's column chain.
function fftsa.nl._read_desc(base, elem0)
  if base == nil then return nil end
  local si
  for si = 1, table.getn(fftsa.nl.DOFF_SETS) do
    local b, es, pc, v, nc = fftsa.nl._read_desc_1(base, elem0, fftsa.nl.DOFF_SETS[si])
    if b ~= nil then return b, es, pc, v, nc end
  end
  return nil
end

-- Every candidate layout, from a word that holds the storage pointer. The base follows from
-- each layout's own stor offset, so the hit is tried at each distance rather than at one --
-- which is what a sweep hit needs, because the hit is the only address it knows.
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

-- The descriptor half of the report, cleared. Both halves of describe() sweep, and the
-- descriptor half does not run at all when the storage half fails -- so without this the
-- error page carries the PREVIOUS buffer's hits, dump and derived offsets beside this
-- buffer's storage failure. A DMM7510 grab read that way names the wrong buffer and the
-- wrong element size.
function fftsa.nl.desc_report_reset(buf)
  local nl = fftsa.nl
  nl._hit_n, nl._hit_why, nl._raw_n, nl._win_hit = 0, nil, 0, nil
  nl._raw_at, nl._der_why, nl.desc_off = {}, nil, nil
  nl._der_best, nl._der_best_n = nil, -1
  nl._ncol = nil
  -- The layout attribution goes with the rest of it. Leaving it attached to a buffer whose
  -- descriptor was never read is the same staleness, and it is the one field desc_off_ok()
  -- decides a write on.
  nl.doff_used = nil
  -- Which buffer this was, and how far the instance's column chain got. Both are invisible in
  -- the report otherwise: a chain that walked nothing and one that walked eight records give
  -- the same window count once the ladder's later stages are added, and the capacity says
  -- whether the buffer the allocator built is the one that was asked for.
  nl._desc_buf = 'cap' .. tostring(buf ~= nil and buf.capacity or nil)
                 .. '/n' .. tostring(buf ~= nil and buf.n or nil)
end

-- ---------------------------------------------------------------------------
-- The descriptor with its field offsets derived rather than assumed.
--
-- A DMM7510 1.7.16 reported 30 raw hits of a confirmed element 0 and not one of them a
-- descriptor by the test above, with the sweep covering the whole backstop. Either the words
-- holding that address were never read, which fftsa.nl.sweep_str now reports, or the layout is
-- not the one measured on a DMM6500 -- and the second is answerable here without a second
-- instrument.
--
-- Nothing below is an offset this module knows. Given one address where the storage pointer
-- was found, it reads the neighbourhood once and derives:
--
--   base      the value that appears at two or more of those words AND is the address they
--             are measured from, which is what an owner self-pointer is
--   stor      base to the storage pointer, from the hit
--   es, pc    a pair of adjacent words whose first equals the stride the content scan
--             MEASURED and whose second makes a power-of-two chunk payload with it
--   vec       a word that points at a word holding elem0, which is what a chunk vector's
--             entry 0 is
--   nc        a word in 1..4095 that counts exactly the leading vector entries which are
--             plausible payloads, the next one not being
--
-- Each term is confirmed against something already measured, so none of them rests on
-- another's being right. The caller gets the same five values _read_desc returns, plus the
-- offsets, and refuses the native cursor rewind if they are not the compiled set.
-- ---------------------------------------------------------------------------

-- How far either side of a storage-pointer hit the descriptor can reach. On the measured
-- layout the hit sits 0x48 above the base, so the geometry fields are 0x40 BELOW it and the
-- two self-pointers 0x0C and 0x1C above. A base is only accepted within BACK of the hit, so
-- these two spans always cover base..base+0x140 wherever in the record the hit falls.
fftsa.nl.DERIVE_BACK, fftsa.nl.DERIVE_FWD = 256, 320
fftsa.nl.DERIVE_SELF_MIN = 2
-- The longest chunk vector this will walk. 16,384 readings of 24 bytes is twelve chunks and a
-- capture has been measured at 49, so this is two orders of margin and bounds the walk at
-- about a third of a second rather than leaving it to a field that could be any word.
fftsa.nl.DERIVE_NC_MAX = 1024

-- Is a word a plausible chunk payload address? In the backstop, 4-aligned, and readable.
-- Nothing here authenticates it -- that is what entry 0 matching elem0 does -- it only
-- bounds how far a vector walk may go.
function fftsa.nl._payload_ok(a)
  if type(a) ~= 'number' or a == 0 then return false end
  -- 4 and not 8. This asked for 8 because a payload holds doubles the firmware loads
  -- directly, and that premise is gone: a 20-byte element leaves half of them 4-aligned,
  -- which is why dsp_native.c admits a 4-aligned payload base. An 8-byte test here would
  -- end the vector walk early on such a model and refuse a descriptor that is good.
  if math.mod(a, 4) ~= 0 then return false end
  return fftsa.nl._wg(a) ~= nil
end

function fftsa.nl._derive_desc(h, elem0, stride)
  local nl = fftsa.nl
  local g = nl._wg
  if h == nil or type(h) ~= 'number' or math.mod(h, 4) ~= 0 then return nil end
  if type(stride) ~= 'number' or stride < 8 then return nil end
  local back, fwd = nl.DERIVE_BACK, nl.DERIVE_FWD
  -- One guarded read a word over the neighbourhood, kept against its offset from the hit.
  -- 145 reads, which is why this runs only after the measured layout has answered nothing.
  local v, k = {}, nil
  for k = -back, fwd, 4 do v[k] = g(h + k) end

  -- The base. An owner self-pointer is a word whose value is the address the record starts
  -- at, so the base is a value that both lies at or below the hit, within reach of it, and
  -- appears at more than one of these words. Taking the most-repeated candidate rather than
  -- the first keeps a single coincidental word from winning over a real pair.
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
  -- The hit that got furthest, for the dump on the error page. Which hit to show cannot be
  -- decided by position -- the chunk vector holds the storage address too, and on a DMM6500
  -- so does allocator bookkeeping -- so it is the one whose neighbourhood looked most like a
  -- record that is worth the characters.
  if nl._der_best == nil or nself > nl._der_best_n then
    nl._der_best, nl._der_best_n = h, nself
  end
  if base == nil or nself < nl.DERIVE_SELF_MIN then
    nl._der_why = 'no self-pointer pair within ' .. tostring(back) .. ' of ' .. hx(h)
    return nil
  end

  -- Which two words those were, for the report and for the rewind gate. They are not a cache
  -- re-validation: the cached-base path goes through _read_desc, which tries DOFF_SETS and
  -- not these, so a model reached only by this route does re-sweep on a later describe()
  -- whose storage cache has missed. DOFF_7510 is why the DMM7510 no longer needs this route;
  -- the next model that does will need the cache path taught to carry derived offsets.
  local s1off, s2off = nil, nil
  for k = -back, fwd, 4 do
    if v[k] == base then
      if s1off == nil then s1off = h + k - base
      elseif s2off == nil then s2off = h + k - base end
    end
  end

  -- Offsets from the base now, bounded by what was read: a field the window does not cover is
  -- nil rather than a fresh read, so this cannot wander.
  local at = function(off)
    local kk = base + off - h
    if kk < -back or kk > fwd then return nil end
    return v[kk]
  end
  local span_hi = h + fwd - base

  -- es and pc: the first adjacent pair whose element size is the stride the content scan
  -- measured. That is the lock -- a word that happens to equal the stride with a neighbour
  -- that happens to fill a payload is the only false positive left, and describe() checks
  -- elemsize against the stride again on the way out.
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

  -- vec: a word pointing at a word that holds elem0. A chunk vector's entry 0 is chunk 0's
  -- payload, and chunk 0's payload is where element 0 is -- which is the address the content
  -- scan confirmed against eleven readings. One indirection, content-checked.
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

  -- nc: a word equal to the number of leading vector entries that are plausible payloads.
  --
  -- Walking the vector alone cannot find its end -- one entry past it is whatever the heap
  -- holds next, and a plausible word there reads as another chunk -- and a field alone cannot
  -- be told from any other small integer in the record. So the walk is done once, capped, and
  -- the count has to equal exactly what it reached. A vector whose next word also looks like a
  -- payload therefore refuses rather than overruns, and says which figure it refused.
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
  -- Cleared, because this route did not read a candidate layout and a value left here would
  -- be the one some earlier buffer matched.
  nl.doff_used = nil
  nl._der_why = nil
  return base, stride, perchunk, vec, nchunks
end

-- Do the derived offsets agree with the layout the native image writes at? The cursor rewind
-- in dsp_native.c stores at compiled displacements from the descriptor base, so a model whose
-- descriptor is shaped differently must not be handed one -- the fields it would overwrite
-- belong to whatever is really there.
-- THE DESCRIPTOR IS THE ARGUMENT, and an absent answer refuses.
--
-- This decides a write at displacements compiled into the image, and it used to decide it
-- from module state: which layout any buffer was read at most recently, with nil -- the state
-- every _find_desc entry resets to -- meaning permit. The caller holds a descriptor; that is
-- what has to be judged. With two layouts in the search the stale case stopped being
-- harmless: DOFF_7510's two self-pointers are at 76 and 92, which are exactly the
-- DESC_IT1_PTR and DESC_IT2_PTR the rewind in dsp_native.c stores at, so a write permitted
-- against the wrong layout would overwrite both owner pointers of a live column descriptor.
function fftsa.nl.desc_off_ok(d)
  local nl = fftsa.nl
  local D = nl.DOFF
  if d == nil then return false end
  local o = d.dderived
  if o ~= nil then                        -- the derived route answered, with its own offsets
    return o.es == D.es and o.pc == D.pc and o.nc == D.nc
           and o.vec == D.vec and o.stor == D.stor
  end
  -- Otherwise a candidate layout answered and it has to be the compiled one. A descriptor
  -- carrying neither is one this cannot place, which is a refusal and not a default.
  return d.doff ~= nil and d.doff == D
end

function fftsa.nl.desc_off_str()
  local nl = fftsa.nl
  local o = nl.desc_off
  if o == nil then
    -- Which candidate layout answered. 'measured' could not say, and the two sets differ by
    -- 8 in four fields -- so which of them a model matched is the layout finding itself.
    local u = nl.doff_used
    if u == nil then return 'doff=none' end
    if u == nl.DOFF then return 'doff=compiled' end
    return 'doff=stor' .. hx(u.stor) .. ',vec' .. hx(u.vec) .. ',cap' .. hx(u.cap)
  end
  return 'doff=stor' .. hx(o.stor) .. ',es' .. hx(o.es) .. ',nc' .. hx(o.nc)
         .. ',vec' .. hx(o.vec) .. ',s' .. hx(o.s1 or 0) .. '/' .. hx(o.s2 or 0)
         .. ',n' .. tostring(o.self_n)
end

-- The words around the hit the derived pass got furthest with.
--
-- This is the one diagnostic that lets a layout be worked out rather than guessed, and it is
-- here because the channel is a screen grab from another continent: asking for one more
-- figure costs a day, so the figures go on the glass now. The window spans the measured
-- layout's own fields as seen from the storage pointer -- elemsize, perchunk and the chunk
-- count sit 0x40 below it, the chunk vector 4 below, and the two self-pointers 0x0C and 0x1C
-- above -- so whatever shape this model's record has, these words contain it.
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

-- The distinct raw hits a report shows, and how many are kept to re-examine. The windows
-- overlap by design -- every tight one lies inside the backstop -- so the same word is found
-- several times and a raw count alone overstates how many places hold the address.
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
  -- hits with no confirmed one means the layout is not the one measured, which is what the
  -- derived pass below then answers. The DMM7510 report had only the one count.
  nl.desc_report_reset(buf)
  nl.sweep_reset()
  local seen, nseen = {}, 0
  local windows = fftsa.nl.scan_windows(buf, elem0)
  -- The chain pointers as the descriptor itself, before any sweeping. On a DMM6500 this does
  -- not answer: a sweep for the descriptor's own address found four references and all four
  -- were inside the descriptor or in allocator bookkeeping, so nothing outside it points at
  -- it. It is here because it costs three guarded reads a pointer against _read_desc's own
  -- validation, scan_windows has already walked the chain, and a model where one of those
  -- pointers is the descriptor gets it for nothing.
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
    local hits = fftsa.nl.FINDS(windows[wi][1], windows[wi][2], needle)
    nl._raw_n = nl._raw_n + table.getn(hits)
    local k
    for k = 1, table.getn(hits) do
      -- Kept for the derived pass and for the report, deduplicated: the same word is found
      -- once per window containing it, and a second examination of it proves nothing twice.
      if seen[hits[k]] == nil and nseen < nl.HITS_KEEP then
        nseen = nseen + 1
        seen[hits[k]] = true
        nl._raw_at[nseen] = hits[k]
      end
      -- Every candidate layout, each from the base its own stor offset puts the record at.
      -- A DMM7510's record is a DMM6500's with eight bytes gone ahead of the chunk vector, so
      -- its descriptor sits 8 lower than one offset alone looks and matched nothing there.
      local b, es, pc, v, nc = fftsa.nl._read_desc_from_stor(hits[k], elem0, true)
      if b ~= nil then
        nl._desc_of, nl._desc_at = elem0, b
        -- Which stage answered, and where: the next buffer gets a tight window around this
        -- arena, so at most one call ever pays for the wide stages.
        nl._win_hit, nl.arena = wi, b
        return b, es, pc, v, nc
      end
    end
  end

  -- Nothing matched the measured layout. The same hits again, with every offset derived from
  -- the data instead -- which is the half of "the sweep found the address but no descriptor"
  -- that a DMM6500 cannot answer, because its layout is the one being assumed.
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
-- Two adjacent big-endian words make a specific needle, and _read_desc_1 applies the same
-- validation as the other route. 878 hits on the instrument, exactly one a descriptor.
--
-- The capacity's offset is a field of each candidate layout, because this route is the one a
-- quiet capture depends on and it answers nothing when the offset is wrong. A DMM7510 found
-- 58 hits of the pair and no descriptor at 0x74, where its own capacity is at 0x6C.
function fftsa.nl._find_desc_by_sig(buf)
  local nl = fftsa.nl
  nl._sig_why = nil
  -- The descriptor half of the report belongs to the buffer being described, and this is one
  -- of the three paths that can resolve one. When this route answers, _find_desc is never
  -- called and so never resets it -- and this is the CAPTURE's primary route, so the page
  -- would carry the previous buffer's identity, hit list, dump and element size beside a
  -- successful bind. Measured: buffer B resolving at a 20-byte element while the page read
  -- cap4096/n1024 and es=32.
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
    local hits = fftsa.nl.FINDS(windows[wi][1], windows[wi][2], needle)
    nhits = nhits + table.getn(hits)
    local k
    for k = 1, table.getn(hits) do
      local si
      for si = 1, table.getn(nl.DOFF_SETS) do
        local D = nl.DOFF_SETS[si]
        local base = hits[k] - D.cap
        -- The storage pointer this layout would put in that record, taken as the content the
        -- rest of the validation is against: elem0 is not known here, which is the whole
        -- point of the route -- a quiet capture cannot be identified by its readings.
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
  -- Named, because this route failing used to leave no trace at all: the caller fell through
  -- to the content scan and reported whatever that said, so a capture buffer whose signature
  -- was never found read exactly like one whose readings could not be confirmed.
  nl._sig_why = 'cap=' .. tostring(cap) .. '/n=' .. tostring(n) .. ' sig hits=' .. tostring(nhits)
                .. ' ' .. nl.sweep_str()
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

  -- TWO SEARCHES, AND THE STRIDE COMES FROM CANDIDATES RATHER THAN FROM A HIT DIFFERENCE.
  --
  -- FINDS matches its own needle. The pattern is a live Lua string in the swept heap, so every
  -- search returns one hit that is the needle's own storage -- measured by searching for three
  -- dB values never appended anywhere and getting exactly one hit each. Differencing two
  -- needles' hits therefore produces a meaningless stride, and when two 8-byte needles happen
  -- to be interned 56 bytes apart it produces a CONVINCING one: that is how 120 records of
  -- float were written over Lua's string table, which bluescreened at 0x0022D270 in
  -- luaS_newlstr walking a chain through an overwritten next pointer.
  --
  -- The needle is re-interned on every call, so a self-hit lands somewhere different each
  -- search while a real record does not move. Two searches and an intersection is the lock,
  -- and it costs one extra sweep rather than any knowledge of where the Lua heap is.
  local windows = nl.scan_windows(nil, nil)
  -- WINDOW BY WINDOW, AND STOP AT THE FIRST ONE THAT CONFIRMS A CANDIDATE.
  --
  -- Sweeping the whole ladder before confirming anything cost 41 s, measured repeatedly -- and
  -- the ring is about 40 KB from nl.arena, which stage 1 already puts a tight window around.
  -- The last stage is the whole 268 MB backstop and is where almost all of that time goes, so
  -- stopping as soon as a candidate stands up skips it.
  --
  -- BOTH LOCKS SURVIVE BEING APPLIED PER WINDOW. The two searches still drop a needle's own
  -- storage, because the needle is re-interned per search wherever it lands; the stride
  -- confirmation still rejects one. What changes is only how much memory is read before the
  -- answer is believed.
  --
  -- `full` sweeps the whole ladder anyway and is the caller's fallback: stopping early can
  -- stop on a window that holds the 28-byte staging ring and not the trace ring, and the only
  -- thing that tells those apart is the header, which the caller looks for. So a caller that
  -- finds no header among the fast candidates asks again with full set.
  local out, nout = {}, 0
  local h1n, h2n, nsall = 0, 0, 0
  local wi
  for wi = 1, table.getn(windows) do
    local lo, hi = windows[wi][1], windows[wi][2]
    local h1 = nl.FINDS(lo, hi, n1)
    h1n = h1n + table.getn(h1)
    -- THE SECOND SEARCH ONLY WHERE THE FIRST FOUND SOMETHING.
    --
    -- It sweeps the same window again so that a hit which MOVED between the two can be
    -- dropped: the needle is a live Lua string in the heap being searched, so every search
    -- returns its own storage. But a window with no hits has nothing to intersect, and
    -- sweeping it twice was half of a 41 s find -- the backstop alone is 268 MB.
    --
    -- The lock is not weakened. What actually caught the self-hit pair that bluescreened the
    -- instrument was the STRIDE confirmation below, not the intersection; the intersection is
    -- defence in depth over the same candidates, and candidates only exist where h1 is
    -- non-empty. So the window that would have been excused is a window with nothing in it.
    local h2 = {}
    if table.getn(h1) > 0 then
      h2 = nl.FINDS(lo, hi, n1)
      h2n = h2n + table.getn(h2)
    end
    -- Deduped as well as intersected. The ladder's windows overlap, so one address comes back
    -- once per window it falls in, and without this the confirm loop runs that many times over
    -- for nothing -- a handful of hits became 29 candidates on the first run of it.
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
    -- EVERY confirmed candidate in this window, not the first. The buffer-side staging ring
    -- holds the same two float32 pairs in a 28-byte record, appended in the same order, so it
    -- confirms at a stride just as well -- and it is not what the widget draws.
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

-- The whole discovery: the records, then the header that identifies which candidate is the
-- display task's ring rather than a staging ring that looks like one.
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
  -- The fast search stops at the first window that confirms anything, and that window can
  -- hold the staging ring and not the trace ring. Only the header tells them apart, so a
  -- fast pass with no header is exactly the case the whole ladder exists for.
  --
  -- UNLESS IT ALREADY SWEPT THE LOT. Measured 2026-11-09: the window that confirmed first was
  -- the LAST one, the whole backstop -- the ring is not reliably near any centre scan_windows
  -- has when it is called with no buffer. Re-running the full ladder then costs a second 42 s
  -- to read the same memory and reach the same answer.
  if not full and nl.ring_win ~= nil and nl.ring_win < nl.ring_nwin then
    return nl.find_ring(sentinels, true)
  end
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

-- THE SAME THREE OFFSETS, DERIVED, FOR A MODEL THEY HAVE NOT BEEN READ OFF.
--
-- The three above are the DMM6500's, read off its 1.7.17a image, and they stay the 6500's
-- mechanism: it works there and nothing here changes it. They are the last assumed constants
-- in the name route -- everything else about the trace object is already searched for, which is
-- why that route is the one a new model can take.
--
-- A DMM7510 cannot use them. Its GUI object is a different size (no mulli by 0x260 anywhere in
-- its image), its table base is not findable by the scan that found the 6500's, and matching
-- the 6500's accessor into it scores 9 words of 40 against a flat tail -- so there is no
-- pointer route there and no image-read offsets either.
--
-- But the cursor words identify themselves, because the ring they describe is already known by
-- the time they are wanted. Two of them are POINTERS INTO THAT RING, record-aligned, and the
-- third is its record COUNT. That is a strong enough shape to find, and a wrong answer cannot
-- survive px_map, which still has to match 510 exact float32 frequencies of this app's own axis
-- before a byte is written.
--
-- Ambiguity is refused rather than resolved by preference: more than one offset answering for a
-- role means this object does not say which, and the next candidate is cheaper than a guess.
fftsa.nl.PX_HDR_SCAN = 64
-- Frames a candidate's cursor offsets get to resolve themselves before it is abandoned. Each
-- costs one read, and two consecutive frames with an append between them is the whole test, so
-- this is generous: it covers a frame the fill skipped and a candidate seen mid-wrap.
fftsa.nl.PX_HDR_TRIES = 12

-- THE CURSOR OFFSETS, FROM WHAT THE WORDS DO RATHER THAN WHERE THEY SIT.
--
-- ring_header has said how to do this since it was written: "a caller proves the field order by
-- CAUSE rather than by layout: read this, append one reading, read it again. The count must
-- rise by one and the write cursor advance by exactly one stride. Nothing else in memory does
-- that." Shape cannot -- against the 6500, where the answer is known to be 8/12/20, four
-- ordered pairs of record-aligned pointers fit the two cursors.
--
-- Two samples a frame apart, with the fill appending between them. What each role does:
--
--   while the ring is FILLING   count rises by 1, write advances one stride, oldest sits still
--   once the ring is FULL       count holds at nrec, and both cursors advance one stride
--
-- So the filling regime separates all three outright, and the full regime separates the count
-- but may leave the two cursors doing the same thing. That is reported rather than resolved:
-- the oldest cursor sitting still is the only positive evidence that tells it from the write
-- cursor, and without it nothing is written. A trace object is not somewhere to guess at an
-- offset -- a wrong word is how PegRect::operator& on a freed widget is reached.
--
-- Returns true once g carries h_old, h_wr and h_cnt. Otherwise false, with g.h_why saying what
-- it is still waiting for, which is what reaches the About page.
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
  -- Which regime, from the count alone.
  local filling = (c1 == c0 + 1)
  if not filling and not (c1 == n and c0 == n) then
    g.h_why = 'the count went ' .. tostring(c0) .. ' to ' .. tostring(c1)
              .. ', neither filling nor full'
    return false
  end
  -- Every pair still standing after this frame's evidence.
  local keep, nk, i = {}, 0, nil
  for i = 1, table.getn(g.h_pairs) do
    local pr = g.h_pairs[i]
    local o0, o1 = at(prev, pr[1]), at(blk, pr[1])
    local w0, w1 = at(prev, pr[2]), at(blk, pr[2])
    if o0 ~= nil and o1 ~= nil and w0 ~= nil and w1 ~= nil then
      local ok = false
      if filling then
        -- The oldest sits still and the write advances exactly one record.
        ok = (o1 == o0) and (w1 == w0 + sv)
      else
        -- Full: both advance one record, and the pair is still only separable if the oldest
        -- can be told from the write some other way. It cannot, so this regime narrows the
        -- field without ever settling it.
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
  -- THE GUARD, AND IT IS WHAT MAKES TRYING THIS ON A 6500 SAFE.
  --
  -- Where the offsets are known from the model's own image, a derived triple that disagrees
  -- with them is wrong by definition, and what it would do next is write four bytes into the
  -- wrong word of a live trace object. So it is refused and counted, the candidate is dropped,
  -- and the operator sees differ= climb on the About page.
  --
  -- On a model whose offsets were never measured there is nothing to compare against and the
  -- guard does not apply: there, the cause test and px_map's 510 frequency matches are the
  -- whole of the evidence.
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

-- This geometry's cursor offsets, or the measured constants when it carries none. One place,
-- so every reader of the header agrees with whatever the candidate was found with.
function fftsa.nl.hdr_offs(g)
  local nl = fftsa.nl
  if type(g) == 'table' and g.h_old ~= nil and g.h_wr ~= nil and g.h_cnt ~= nil then
    return g.h_old, g.h_wr, g.h_cnt
  end
  return nl.HDR_OLD, nl.HDR_WRITE, nl.HDR_COUNT
end

-- Which values the path USES. False on a DMM6500, where they are known and measured, and the
-- mechanism that works there is left alone. nl_bind sets it from the model.
fftsa.nl.PX_HDR_DERIVE = false

-- SHADOW MODE, which is how the derivation earns the right to replace the constants.
--
-- On a 6500 the answer is known, so the derivation can be run beside the constants and the two
-- compared on every candidate, on real hardware, with nothing depending on the result. Agreement
-- over many launches is the evidence that would let PX_HDR_DERIVE become the only path and the
-- three constants go; a single disagreement says exactly which object it failed on.
--
-- It costs no reads: the words are already in the window px_from_name has read.
fftsa.nl.PX_HDR_CHECK = true
fftsa.nl.hdr_agree, fftsa.nl.hdr_differ = 0, 0
fftsa.nl.hdr_why = nil

-- THE ROLES, AS A COUNT OFFSET AND A SHORTLIST OF CURSOR PAIRS.
--
-- What one frame's words can honestly say. The count is a single offset in practice -- the only
-- word holding a plausible record count -- and the two cursors are any ordered pair of
-- record-aligned pointers into the ring, of which the 6500 yields four. px_hdr_resolve then
-- settles the pair by appending a reading and watching.
--
-- Returns nil when the count is not unique: without it the regime cannot be read and the whole
-- test loses its clock.
function fftsa.nl.px_hdr_roles(rd, lo, hi, sv, n)
  local nl = fftsa.nl
  local ptrs, cnts, np, nc = {}, {}, 0, 0
  local o
  -- Offsets 0 and 4 are the bounds pair this header was found BY, so they are known and are
  -- not cursor candidates. Leaving them in is not harmless: the low bound is a record-aligned
  -- pointer into the ring that never moves, which is exactly what an idle oldest cursor looks
  -- like, so it pairs with the real write cursor and makes the answer ambiguous for ever.
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
  -- One count offset, or the regime cannot be read. A pointer-shaped word is never also a
  -- plausible count on this firmware -- the ring lives far above n -- so the two sets are
  -- disjoint and a word cannot hold both roles.
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

-- lo, hi, sv and n are the ring this header must describe; rd(off) reads a word at an offset
-- from the bounds pair. Returns the three offsets, or nil and a reason.
function fftsa.nl.px_hdr_derive(rd, lo, hi, sv, n)
  local nl = fftsa.nl
  local olds, wrs, cnts, no, nw, nc = {}, {}, {}, 0, 0, 0
  local o
  for o = 0, nl.PX_HDR_SCAN, 4 do
    local v = rd(o)
    if v ~= nil then
      -- A record-aligned pointer inside the ring is the oldest-record cursor; the write cursor
      -- may also sit one past the end, which is how a full lap reads.
      if v >= lo and v < hi and math.mod(v - lo, sv) == 0 then
        no = no + 1
        olds[no] = o
      end
      if v >= lo and v <= hi and math.mod(v - lo, sv) == 0 then
        nw = nw + 1
        wrs[nw] = o
      end
      -- The count, and only the count: a full ring, which it is by the time the path looks.
      -- Any small integer would otherwise answer, and there is no shortage of those.
      if v == n then
        nc = nc + 1
        cnts[nc] = o
      end
    end
  end
  if nc ~= 1 then
    return nil, tostring(nc) .. ' offsets hold the record count'
  end
  -- The two cursors are the same shape, so they are told apart by order, which is what the
  -- 6500's own layout does: oldest first, write after it.
  local a, b
  for a = 1, no do
    for b = 1, nw do
      if wrs[b] > olds[a] and olds[a] ~= cnts[1] and wrs[b] ~= cnts[1] then
        -- A second pair would make this a guess.
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
  local eho, ehw, ehc = nl.hdr_offs(g)
  return { lo = nl._wg(g.hdr), hi = nl._wg(g.hdr + 4),
           oldest = nl._wg(g.hdr + eho),
           write = nl._wg(g.hdr + ehw),
           count = nl._wg(g.hdr + ehc) }
end

-- ---------------------------------------------------------------------------
-- The pixel fill: one memwrite a frame in place of 510 appends.
--
-- A frame reaches the glass through buffer.write.reading, one call a point at about 80 us:
-- 39 ms of a 100 ms frame spent on IPC round trips. The display task does not read the
-- buffer. It keeps its own ring of 56-byte records, one pushed per append, and what it draws
-- is not the reading but the two PIXEL triples the firmware computed when the append arrived:
--
--   rec +0x00  x pixel, int32, three identical copies
--   rec +0x0C  y pixel, int32, three identical copies
--   rec +0x18  two zero words
--   rec +0x20  value float32 twice   +0x28 flags   +0x2C x float32 twice   +0x34 2.0f
--
-- ki.memwrite is memcpy with no destination check, so the whole ring goes in one call. The
-- measured ladder for a 510-record pass: 39 ms of appends, 19.3 ms writing a record at a
-- time, 9.6 ms as one block.
--
-- WHAT MAKES IT CHEAP IS THAT EVERY SLOT KEEPS ITS FREQUENCY. The ring is 721 records and a
-- pass is 510, so continuing to append would rotate the slot-to-column assignment by 211
-- every frame and every x pixel would have to be rewritten with it. Engaged, a frame appends
-- ONCE: the cursor moves one record and every other slot keeps the x pixel, the frequency and
-- the flags it already held. So the assignment is solved once, only the y triples are
-- rewritten each frame, and the picture stays the one the appends drew.
--
-- THE ONE APPEND IS NOT OPTIONAL, and it does two jobs. A record written behind the task's
-- back sets no dirty flag, so nothing repaints until an append posts a message. And the record
-- it writes is the firmware's own pixel for a decibel this code knows, which is the only
-- continuing check that the map has not gone stale -- the map cannot be re-fitted once the
-- appends stop, because nothing else on the instrument computes a pixel. It is appended at the
-- frequency the slot it lands in already carries, so it draws the point this code would have
-- drawn there and is not a perturbation.
--
-- NOTHING HERE IS A HARDCODED OFFSET. The stride, the value field and the x field come from
-- the search. The y triple is identified by fitting each repeating triple in a record against
-- the value the same record carries. The map's slope and intercept are least squares over the
-- whole ring. A model whose plot geometry has never been measured gets the same treatment as
-- the one this was written on.
-- ---------------------------------------------------------------------------

-- Bytes a frame sweeps while seeking. 25 MB/s measured on the instrument's own clock, so this
-- is about 10 ms of a 100 ms frame: the search costs a tenth of the frame rate while it runs
-- and nothing once it answers.
fftsa.nl.PX_BUDGET = 262144

-- AND THE SAME TEN MILLISECONDS IN BYTES WHEN THE IMAGE IS DOING THE SEARCHING, which is a
-- different number and nothing in this tree knows which.
--
-- PX_BUDGET is 256 KB because ki.memread manages 25 MB/s through the firmware's read path. The
-- image does not use that path: it loads DRAM directly from a register-based loop. So the same
-- slice costs a different time, and charging the image's bytes against a Lua read's allowance
-- made the search a tenth as fast as the hardware it runs on.
--
-- It is not guessed. The slice starts at the Lua figure and is TIMED: px_nb_note takes the
-- bytes the image reported scanned and the clock either side, and sizes the next slice to land
-- on PX_NMS. A slice too fast for os.clock to resolve is itself evidence -- the budget doubles
-- until one is slow enough to measure -- and the ceiling is a slice that would still cost only
-- 40 ms if the image turned out no faster than ki.memread, so being wrong in either direction
-- costs part of one frame.
--
-- Three megabytes is the instance window. At the ceiling that is three frames.
-- The time a slice may cost. IT MUST EXCEED THE FIXED OVERHEAD or the controller saturates
-- again: at 10 ms, with the round trip alone measuring around 20, (target - overhead) is
-- negative and every slice collapses to the floor. 30 ms of a 66 ms frame, while searching
-- only and for under a second, buys engagement in a handful of frames instead of thirty-odd --
-- and the app is on the append path the whole time anyway.
--
-- The ceiling stays 1 MB and is now safe by construction rather than by guess: the slice is
-- sized from a MEASURED rate, so a megabyte is only ever asked for when a megabyte fits in the
-- room the target leaves.
fftsa.nl.PX_NMS = 0.030
fftsa.nl.PX_NBUDGET_MIN = 262144
-- THE CEILING MAY NOT BE THE BINDING CONSTRAINT, or the fit above is decorative.
--
-- Measured on the glass at 9.13: `nb=1024KB @72MB/s oh=2.9ms`. A 30 ms target less 2.9 ms of
-- overhead at 72 MB/s is 1.95 MB, and the slice was pinned at 1024 KB -- so the clock had
-- measured a slice twice the size of the one the path was allowed to ask for, and half the
-- hardware's speed was being left on the floor by a figure in the tree. That is exactly the
-- defect timing the slice was meant to remove.
--
-- Two megabytes: it clears the 1.95 MB the measurement asks for, and it keeps the worst case
-- a frame cannot be interrupted for at about 28 ms at the measured rate. PX_NMS is the bound
-- now, which is the one that knows what a frame can afford.
fftsa.nl.PX_NBUDGET_MAX = 2097152
-- Bytes a frame must have scanned before its timing is believed. Below this the clock reads
-- mostly the round trip and the adjudication, not the scan.
fftsa.nl.PX_NB_SAMPLE = 65536
fftsa.nl.px_nbudget = 262144

-- The slice size for this frame: the image's if there is one, otherwise the read path's.
function fftsa.nl.px_budget()
  local nl = fftsa.nl
  if nl.NFIND and nl.ready and nl.nfind ~= nil then
    return nl.px_nbudget or nl.PX_NBUDGET_MIN
  end
  return nl.PX_BUDGET
end

-- A SLICE COSTS AN OVERHEAD PLUS A RATE, AND TREATING IT AS A RATE ALONE PINNED THE BUDGET.
--
-- Measured on the glass at 8.99 and again at 9.01: nb=256KB @13MB/s, the budget sitting on its
-- floor while the search swept 9 to 11 MB -- thirty-odd frames, and most of the time to engage.
--
-- 13 MB/s is not a scan rate. Native code loading DRAM directly cannot be slower than
-- ki.memread's 25 MB/s through the firmware's own read path. It is the average of a fixed cost
-- and a fast scan, and 256 KB at that average is 21 ms against a 10 ms target -- so the
-- controller was SATURATED. Every slice overshot, it could only ever ask for less, the floor
-- was the one thing holding the budget up, and it could never try a bigger slice and so never
-- discover that a bigger slice is nearly free.
--
--   t = overhead + bytes / rate
--
-- Two slice sizes solve that, and the search provides them for nothing: until two distinct
-- sizes have been timed the budget alternates between the floor and twice the floor. After
-- that the slice is (target - overhead) * rate, so the fixed cost is paid once a frame instead
-- of being charged against the bytes.
--
-- If the overhead alone exceeds the target, no slice size helps and the floor is the answer.
fftsa.nl.px_nb_a, fftsa.nl.px_nb_b = nil, nil     -- two (bytes, secs) samples, distinct sizes

function fftsa.nl.px_nb_note(bytes, secs)
  local nl = fftsa.nl
  if type(bytes) ~= 'number' or bytes < nl.PX_NB_SAMPLE then return end
  if type(secs) ~= 'number' or secs < 0 then return end
  -- Two samples, kept only if their byte counts differ enough to separate the fixed cost from
  -- the rate. The forced alternation below makes that a factor of two.
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
    -- The rate comes from the SLOPE: the part of the cost the bytes are responsible for.
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
    -- Not enough to fit yet, so alternate the size and let the next frame give the second
    -- point. Nothing is inferred from one sample, because one sample cannot tell a fixed cost
    -- from a slow scan -- which is exactly the mistake this replaces.
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
-- A window wider than this is left to the one backstop pass at the end of the ladder, which
-- covers it anyway. scan_windows ends with three overlapping wide stages; sweeping all of them
-- would read 60 MB twice over on the boots where the tight windows miss.
fftsa.nl.PX_WIN_MAX = 4194304
-- A window at or under this is one frame's slice, so it is tried before anything that has to
-- justify itself on where the ring is likely to be. Trying it and being wrong has cost a frame,
-- which is below the resolution of the thing being optimised.
fftsa.nl.PX_WIN_CHEAP = 1048576
-- The fit has to span this many decibels before it is believed. Pixels are integers, so a
-- narrow span fits a slope badly and the unfitted points still agree: a 3 dB spread once fitted
-- 1.667 px/dB against a true 2, and the points left out predicted within 0.67 px. A span test
-- is what catches that; a residual test alone does not.
fftsa.nl.PX_SPAN_MIN = 20
fftsa.nl.PX_RESID_MAX = 1.5
-- The firmware's own point, read back each frame, may differ from the prediction by this much
-- before the map is called stale. One pixel is rounding; three is a moved axis.
fftsa.nl.PX_DRIFT_MAX = 3
fftsa.nl.PX_DRIFT_RUN = 5
-- Panel rows, which is what a y pixel is clamped to. Writing one outside the plot would draw
-- outside the plot: the widget clamps a below-floor READING, and a pixel written here has
-- already been past that.
fftsa.nl.PX_YMAX = 479
-- A PIXEL IS A SMALL INTEGER, and a word in a triple that is not one is not a pixel.
--
-- One record of 721 came back with 54,099,264 at the x triple -- a heap address, in a slot
-- whose frequency and decibels were both sound. Least squares has no defence against that: the
-- slope for the x pixel against frequency came out -4.41 instead of 0.0138, and the residual
-- it was judged on was 5.4e7, so the x triple could not be identified and the map was refused
-- on a ring that was entirely correct apart from that one word. Measured 2026-11-09.
--
-- Generous, because the point is to exclude an address and not to assume a panel size.
fftsa.nl.PX_PIX_MAX = 8191
-- How much of the window has to be usable, and has to fit, before a fit is believed. The
-- outlier above is 0.2% of a window; a structure that merely resembles a ring is not going to
-- come within a pixel on 95% of 510 records.
fftsa.nl.PX_FIT_FRAC = 0.95
-- How many pixels a triple has to sweep before it can be called the frequency axis, and how
-- far clear of the other triple it has to be.
--
-- "The y pixel is not affine in frequency" is not a discriminator, because a trace can be very
-- nearly a straight line. Measured 2026-11-09 on an input with no signal: every column sat on
-- the axis floor, so the y pixel was CONSTANT, a constant is affine in anything, and both
-- triples came back fitting frequency on all 510 records. A flat trace also fits with a peak
-- in it -- one column out of 510 is 0.2% and passes a 95% inlier test.
--
-- What does separate them is how far the fitted line travels: the frequency axis crosses the
-- plot, about 680 px, and the decibel axis against frequency travels however much the trace
-- happens to tilt, which is tens of pixels for a sloping noise floor and none for a flat one.
fftsa.nl.PX_DRAW_MIN = 128
fftsa.nl.PX_DRAW_RATIO = 4
-- A candidate that confirms a stride but whose ring will not map is abandoned after this many
-- frames, and the sweep carries on from where it was.
fftsa.nl.PX_MAP_TRIES = 8
-- How far the task's own cursors may drift before the window is called somebody else's. One
-- append moves them by one record a frame, which is what this exists to absorb; a jump of more
-- than a few records means something other than this frame is feeding the ring.
fftsa.nl.PX_SLIP_MAX = 8
-- Frames of plain appending after a drop, before the search is allowed to map again.
--
-- The map is fitted by comparing the y triple against the value field of the SAME record, and
-- an engaged frame writes the y triples and not the values -- so after even one pixel frame the
-- two no longer describe the same spectrum and nothing can be fitted from them. The appends
-- rewrite both together, so a couple of frames of them puts the ring back in a state a map can
-- be derived from. Measured 2026-11-09: a re-map straight after a drop refused with "no value
-- field the y triple is affine in", every time.
fftsa.nl.PX_HOLD = 4
-- Consecutive refused cursor calls before the path is torn down rather than the frame skipped.
-- The repaint is a synchronous call into the GUI task, so a busy task can refuse one; losing
-- the whole map over that is what makes a frame rate oscillate instead of settling.
fftsa.nl.PX_CURSOR_RUN = 5

fftsa.nl.px = { state = 'idle' }

-- HOW LONG IT TOOK TO ENGAGE, measured on the instrument's own clock.
--
-- Every figure for this so far has come off a stopwatch -- "8 seconds", "13 seconds", "about 2"
-- -- against a frame rate that is itself changing while the search runs. That is not accurate
-- enough to tell a fix from noise, and two of the last three changes were judged on it.
--
-- So: the clock at the first frame the path ever sees, and the elapsed time and frame count at
-- the first engage. Kept on the module rather than on px, because px_clear runs on every
-- restart and the question is "how long from launch", not "how long since the last restart".
-- The LAST engage is kept too: a re-engage after a size change is a different measurement and
-- the two were being conflated.
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
  -- Since the last restart, which is what a size change costs.
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
  -- The route that engaged goes with the geometry it engaged through. Left set, these two
  -- outlive the session that earned them, and the next pass reports a route it is not using:
  -- via=sub and /chain on a launch whose chain never closed.
  p.via, p.from = nil, nil
  -- And the image's ring block, which describes the geometry above. Left set, px_write would
  -- call with a block naming a ring this map no longer believes in.
  p.nat, p.nat_why, p.natwrote = false, nil, nil
end

-- Cleared only when the path actually engages: px_clear runs on every restart, and a counter
-- reset there would let the pointer route be retried for ever.
function fftsa.nl.px_ptr_ok()
  fftsa.nl.px.ptrtries = 0
end

-- Off for the rest of the session, with the reason kept for the error and About pages. The
-- frame then fills by appending, which is what every build before this one did.
function fftsa.nl.px_off(why)
  local nl = fftsa.nl
  nl.px_clear()
  nl.px.state = 'off'
  nl.px.why = why
  return nil
end

-- A frame dropping the path, with its reason kept where the search cannot overwrite it.
--
-- px_restart puts the reason in p.why, and the search runs later in the SAME frame and writes
-- its own there -- so the reason a frame gave up was never readable. It is the one reason that
-- matters most: everything else is a search that has not finished yet.
function fftsa.nl.px_dropframe(why)
  fftsa.nl.px.whyframe = why
  return fftsa.nl.px_restart(why)
end

-- WAITING IS NOT RESTARTING, and conflating them cost fourteen seconds to engage.
--
-- px_restart exists for "the geometry was wrong or the plan changed", and it throws away the
-- window ladder's cursor -- p.wins, p.wi and p.at -- because after a plan change the ladder is
-- the wrong ladder. It also resets cachetries, so the cheap routes get their frames again.
--
-- Neither applies while the module is simply not ready yet. Nothing about the plan has changed
-- and nothing about the ladder is stale: the install has not finished reattaching, or the span
-- has not got two live addresses in it. Using px_restart there discarded the search's position
-- on every frame it waited, so the ladder began again at window one each time and the search
-- made no progress while the waiting lasted. Measured on the glass at 8.97: fourteen seconds
-- from launch to the F appearing, against three to five in 8.95 where the same wait ended in
-- px_off after thirty frames.
--
-- So this holds the state exactly as it is and only records why.
function fftsa.nl.px_wait(why)
  local nl = fftsa.nl
  nl.px.state = 'idle'
  nl.px.why = why
  nl.px.waits = (nl.px.waits or 0) + 1
  return nil
end

-- Back to the start without giving up: the geometry was wrong or the plan changed, and the
-- next frame begins the search again. Counters survive, so a report says how many times.
function fftsa.nl.px_restart(why)
  local nl = fftsa.nl
  local laps = nl.px.restarts
  -- Was it ever drawing? That is what decides whether there is anything to wait for, and it
  -- has to be read before px_clear.
  local drew = nl.px.state == 'on'
  nl.px_clear()
  nl.px.state = 'idle'
  nl.px.why = why
  nl.px.restarts = (laps or 0) + 1
  -- KEPT WHERE THE ENGAGE CANNOT WIPE IT. p.why is cleared by px_map on every attempt, so by
  -- the time an operator reads the page the reasons the path restarted are gone -- and the
  -- restart count alone cost a day: re=4 with the ring inside the first window said the ladder
  -- had been thrown away four times, and nothing said what did it. The last two reasons are
  -- enough to name the mechanism without keeping a log.
  nl.px.re_prev = nl.px.re_last
  nl.px.re_last = why
  if nl.t_first ~= nil then
    nl.t_restart_el = os.clock() - nl.t_first
    nl.pre_at_restart = nl.pre_frames or 0
  end
  -- PX_HOLD frames of plain appends before a map may be attempted again, and ONLY after a
  -- session that drew. An engaged frame writes the y triples and not the values, so straight
  -- after a drop the two no longer describe the same spectrum and nothing can be fitted from
  -- them. A launch has never drawn -- sg_bind restarts the path while building the screen --
  -- so holding there waits four frames for a divergence that cannot exist.
  nl.px.hold = 0
  if drew then nl.px.hold = nl.PX_HOLD end
  nl.px.wins, nl.px.wi, nl.px.at = nil, nil, nil
  -- backstop_done is NOT cleared: it records that the whole of DRAM has been walked once in
  -- this session, and a plan change is no reason to do it again.
  -- The name is tried again from scratch. noname is only a record of one ladder having been
  -- swept without finding it, and a restart means the plan or the traces changed.
  --
  -- AND THE COUNTERS THAT CONDEMN IT GO WITH IT, or the reprieve is not one.
  --
  -- A freed trace object keeps the buffer name, so the needle matches every corpse of every
  -- previous run, and PX_NAME_FAIL retires it after that many hits that produce no candidate.
  -- Clearing the flag here while leaving namehits and ncand cumulative gave the retirement a
  -- SESSION's lifetime and the reprieve a PASS's: the needle was revived by every restart and
  -- then re-condemned by corpses counted in the passes before it.
  --
  -- Measured on the glass at 9.14 from a clean boot: re=4, nh=69, namedead=69, noname=1,
  -- by=freq, win=13/17, swept=27MB, eng=10.6s. Sixty-nine hits over four passes is about
  -- seventeen a pass, so no single pass came near the bound that was applied -- and the pass
  -- that mattered, the one after the last rebind with the live trace object in memory, ran
  -- without the only needle that can say WHICH trace. The ring was at inst+5.25 MB, inside the
  -- instance band the ladder tries third, and the name would have named it there.
  --
  -- The session total is kept, both for the report and because it still bounds the thing
  -- PX_NAME_FAIL was added for: a path that restarted every frame would otherwise revive the
  -- needle every frame and never retire it at all.
  nl.px.nhall = (nl.px.nhall or 0) + (nl.px.namehits or 0)
  nl.px.noname, nl.px.namehits, nl.px.ncand = nil, 0, 0
  nl.px.sweptpass = 0
  -- AND THE SUBSCRIBER ROUTE'S WINDOW BUDGET, for the same reason as everything above it: a
  -- restart means the traces were rebound, so the subscription is a NEW one and reads spent
  -- looking for the old one say nothing about it. The cached slot address is deliberately NOT
  -- cleared -- the table is static and the slot is re-checked with one word, so keeping it is
  -- what makes the route cost nothing on the frames after a restart.
  nl.px_subfinds = 0
  nl.px.subwait = 0
  -- AND THE WINDOW LADDER'S CURSOR, for the fourth time today the same rule: a counter that
  -- bounds a search must not outlive the thing it is searching for. A restart means the traces
  -- were rebound, so the compiled window is worth re-reading before the ladder is walked again.
  -- Left to run on, it spent itself during the first pass and every later pass reported "the
  -- ladder is spent" having read nothing.
  nl.px_subwin = nil
  -- And the half-adjudicated hit list, by the same rule: the hits are addresses in the window
  -- read for the PREVIOUS subscription, so finishing them after a rebind spends reads on slots
  -- that cannot name the new trace, and holds off the window read that could.
  nl.sub_hitlist, nl.sub_hitat, nl.sub_hitround = nil, nil, nil
  return nil
end

-- The ladder, cheap windows first and one pass over everything last.
-- THE TRACE OBJECT CARRIES THE BUFFER'S NAME, and that is a far better needle than any
-- reading.
--
-- The display task allocates one trace object per display.graph.add -- 0x14220 bytes on the
-- GUI side, appended to the graph widget's null-terminated trace array -- and the record ring
-- lives INSIDE it, at a fixed offset, behind a small header of bounds and cursors. The
-- distance from that header to the ring measured 0x30 on every boot this app has been found
-- on, which is what the layout says it should be.
--
-- Near the front of the same object is the buffer's NAME, as a NUL-terminated string. This app
-- creates its trace buffer into a bare global for exactly that reason -- a buffer the display
-- task cannot name is subscribed as defbuffer1 instead, and the graph then draws defbuffer1 on
-- defbuffer1's units -- so the name is known, unique and chosen by this app: FFTSA_TRACE.
--
-- WHY IT BEATS SEARCHING FOR READINGS. Every failure the reading search met today is absent
-- here:
--
--   * it does not wait for the display task. An append lands in a staging ring and is copied
--     across later, so at the end of a fill the trace ring still holds the PREVIOUS pass and a
--     needle built from this frame's decibels matches nothing. The name is there from the
--     moment the trace is created.
--   * it does not care what the spectrum looks like. A trace pinned flat on the axis floor
--     offers no distinct values to search for and no decibel span to fit; the name is the same
--     either way.
--   * it cannot be confused with the staging ring, which holds the same floats in the same
--     order in a 28-byte record and confirmed a stride just as well.
--   * it says WHICH trace. The marker trace is a second object of the same shape; it carries
--     FFTSA_MARK.
--
-- And one hit yields the whole geometry by arithmetic rather than by further searching: no
-- stride to try, no header to scan for, no candidate list to work through.
--
-- NOTHING IS ASSUMED FROM THE LAYOUT. The distance from the name to the bounds pair is
-- DERIVED: a bounded walk forward from the hit for two adjacent words that are a plausible
-- ring -- the second above the first, their difference a whole number of records, the count and
-- both cursors consistent with them -- which is the same test the record route applies, over a
-- kilobyte instead of three hundred.
fftsa.nl.PX_NAME = 'FFTSA_TRACE'
-- How far past the name the bounds pair may sit. The layout puts the name at +0x08 and the
-- bounds at +0x1F0, so 0x1E8; this is that with room for a build that moved a field.
fftsa.nl.PX_NAME_SCAN = 1024

-- Every geometry a trace object whose name was found at `at` could have.
--
-- A LIST, because the bounds do not fix the stride. The span between them is a whole number of
-- records at more than one record size -- the measured ring is 40,376 bytes, which is 721
-- records of 56 and also 1,442 of 28 -- and nothing in the header says which. So each plausible
-- stride is returned and px_map adjudicates: a wrong stride cuts the records in the wrong
-- places and its x field then holds a frequency this plan does not have, in almost every slot.
--
-- Same shape as the record route's output, so px_map takes either without knowing which found
-- it: lo, hi, nrec, stride, hdr.
-- ONE READ FOR THE WHOLE NEIGHBOURHOOD, not a word at a time.
--
-- nl._wg is ki.peek32, which is an IPC round trip per word, and this walk is 257 of them for
-- every hit it is given. A slice carrying tens of aligned hits is then tens of thousands of
-- round trips inside a single frame, and the frame cannot be interrupted: measured on the
-- glass as a 4 to 5 second stall while the search ran, and about five seconds to engage at
-- 1024 points. The window is a kilobyte. Read it once and the walk is arithmetic in a string.
--
-- Clamped rather than refused at the top of DRAM, so a hit near the end still gets whatever
-- of its window exists -- w() answers nil past what came back, which is what _wg did for an
-- address outside the backstop.
function fftsa.nl.px_from_name(at)
  local nl = fftsa.nl
  local out, nout = {}, 0
  -- _wg refuses an unaligned address, so the old walk read nothing at all from an unaligned
  -- hit. Saying so here costs one test instead of 257.
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
      -- The ring sits inside this very object, just past its own bounds words, so a pair that
      -- points anywhere else is some other structure that happens to be ordered.
      if lo > h and lo - h < nl.PX_NAME_SCAN and math.mod(span, 4) == 0 then
        local sv
        for sv = nl.REC_MIN, nl.REC_MAX, 4 do
          if math.mod(span, sv) == 0 then
            local n = span / sv
            if n >= nl.RING_MIN and n <= nl.RING_MAX then
              -- The cursor offsets: the 6500's measured constants, or derived for a model they
              -- have never been read off. Shadow mode runs the derivation either way and only
              -- records whether it agreed, which is what will decide whether the constants are
              -- needed at all.
              local ho, hw, hc = nl.HDR_OLD, nl.HDR_WRITE, nl.HDR_COUNT
              local rd = function(x) return w(o + x) end
              -- A DERIVING MODEL TAKES THE ROLES UNRESOLVED and settles them by cause in the
              -- map state, where there are frames and an append between them. All that is
              -- wanted here is the count offset and the pairs worth testing.
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
                  -- Counted either way. A refusal is a result: it is what says the single-frame
                  -- shape is not enough on this object, which is the figure that decides
                  -- whether the derivation can ever replace the constants.
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
                -- Unresolved: the count is known, the cursors are a short list. The checks the
                -- resolved branch makes below are exactly what px_hdr_resolve will make, one
                -- append apart, so nothing is lost by not making them here.
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
        -- The first bounds pair that stands up at all is the one: a second, further on, would
        -- be inside the ring itself.
        if nout > 0 then return out end
      end
    end
  end
  return out
end

-- ---------------------------------------------------------------------------
-- THE RING BY POINTER, WHICH IS WHAT A SCAN SHOULD NEVER HAVE BEEN DOING.
--
-- notes/firmware/graph/GRAPH.md gives the whole chain, statically recovered from the image:
-- the GUI object table is indexed by the same id Lua holds as a display handle, the graph
-- widget keeps its traces in a null-terminated pointer array at +0x3EC, and a trace object
-- carries its buffer name at +0x08, the ring bounds at +0x1F0 and the ring itself at +0x220.
-- So from fftsa.sg_graph the ring is three reads, and the sweep this module has been paying
-- -- tens of megabytes and half a minute per launch -- buys nothing the table does not give.
--
-- NO ADDRESS IS CARRIED. Only distances within structures, each used for one step of a walk
-- that is checked at every step, and the table's own base is DERIVED from a ring the search
-- has already confirmed: trace is ring-0x220, the word holding trace is graph+0x3EC, the word
-- holding graph is the table entry, and the entry is base+id*0x260. Two four-byte sweeps, once
-- per boot, against one content sweep per launch.
--
-- The forward walk re-validates rather than trusts the cache: the name has to be this app's
-- buffer, the bounds pair has to bracket the ring at the documented distance, and the cursors
-- have to be consistent with both. A base that has gone stale therefore refuses and the
-- content route runs, which is also what happens on a build whose layout differs.
fftsa.nl.PX_TRACE_NAME  = 8          -- 0x08, buffer name, 32 bytes
fftsa.nl.PX_TRACE_BNDS  = 496        -- 0x1F0, ring base and end
fftsa.nl.PX_GRAPH_TRACE = 1004       -- 0x3EC, the widget's null-terminated trace array
fftsa.nl.PX_OBJ_STRIDE  = 608        -- 0x260, GUI object table stride
-- THE WIDGET POINTER IS NOT THE FIRST WORD OF THE ENTRY. notes/firmware/graph/GRAPH.md:178:
-- the table is `0x00D17BE0 + id*0x260`, with the widget pointer at `+0x50`, the parameter
-- block at `+0x20`, the type byte at `+8`. Reading the entry's first word, which is what this
-- did, is why the pointer route never engaged: the derivation that followed then searched for
-- whatever word held the widget and found an arbitrary one in the heap, and its forward check
-- could not tell -- it reads back the very word the base came from, so `base + id*stride` is
-- that word by construction whatever it was.
fftsa.nl.PX_OBJ_WIDGET  = 80         -- 0x50, the widget pointer inside a table entry

-- THE FIRMWARE KEEPS A STATIC TABLE OF BUFFER SUBSCRIPTIONS, INDEXED BY THE BUFFER NAME WE
-- CHOSE OURSELVES, AND IT REACHES THE TRACE OBJECT IN THREE READS.
--
-- This replaces searching DRAM for the ring. Measured on the glass at 9.16, clean boot:
-- eng=3.1s/21f with swept=27MB, the name needle finally surviving long enough to name the ring.
-- The route below reads 64 KB once and dereferences three pointers.
--
-- How it works, read off the decompiled firmware and then confirmed on the instrument:
--
--   graph_trace_add (0x0002D3C4) creates the 0x14220-byte trace object, stores it in the
--   widget's trace array, and calls
--
--       bufsub_subscribe(0x407F, graph, trace+0x08, &routing_element)   (0x000B4708)
--
--   which allocates a slot in a STATIC table and -- before its switch on the kind -- copies the
--   NAME to slot+0x08, the graph to slot+0x34 and the routing element's ADDRESS to slot+0x40.
--   So slot+0x40 is not an index: one dereference gives the array element, a second gives the
--   trace object.
--
-- Measured on a DMM6500 at 1.7.17a with the app running at 2048 points:
--
--   slot 00D67CD0   kind 0000407F   graph 03134A28   p4 03134EC0
--   *(p4)       = 0352D4B0          the trace object
--   trace+0x08  = FFTSA_TRACE       the name again
--   trace+0x00  = 03134A28          the graph, matching slot+0x34
--   trace+0x30  = 00D67CD0          the subscription handle, matching the slot
--   trace+0x1F0 = 0352D6D0..03537488 count 510, and 0352D6D0 is trace+0x220
--
-- Every link confirms another, which is what makes this safe to dereference. The ring address
-- is the one the search spends 27 MB finding.
--
-- NO TABLE BASE IS NEEDED. The slot is name_address - 8, so a hit anywhere in the window names
-- its own slot and the base, the stride and the slot count all stop mattering. That is what
-- makes this survive a firmware change: measured, 1.7.17a has the table at 0x00D67708 and
-- 1.7.18a at 0x00D67A48 -- the same 0x340 .bss delta as the GUI object table -- and this route
-- does not care which.
--
-- A WINDOW, NOT AN ADDRESS, and it is the only firmware figure here. Under the operator's rule
-- of 2026-11-10 a start address may be compiled in where being wrong costs performance and
-- never correctness: this one only decides where to look for a string, a wrong window costs one
-- 64 KB read, and nothing is believed until the chain above closes on itself and px_map has
-- matched 510 float32 frequencies of this app's own axis.
fftsa.nl.PX_SUB = true
-- 0x00D60000 .. 0x00D70000. The two measured tables sit at 0x00D67708 (1.7.17a) and
-- 0x00D67A48 (1.7.18a), 64 slots of 296 bytes reach 0x00D6C448, and the c2c decoy is at
-- 0x00D67598 -- so this covers every one of them with room either side. The first figure
-- written here was 13893632, which is 0x00D40000 and covers NONE of it; the firmware-address
-- gate refused it for being an undeclared DRAM literal and that is how the miss was caught
-- rather than by a run on the instrument that found nothing.
fftsa.nl.PX_SUB_LO    = 14024704     -- 0x00D60000, the DMM6500
fftsa.nl.PX_SUB_BYTES = 65536        -- 64 KB
-- AND THE DMM7510'S, read out of its own image rather than guessed.
--
-- Its display code is a separate payload: rom/rom7519.zx, S-record header `disp7510_r`. The
-- loader's section table at flash 0xFF702E00 maps the application sections by subtracting
-- 0xFF200000, so RAM address equals flattened-image offset -- the same relation the DMM6500
-- has, confirmed there against four strings whose RAM addresses are independently known.
--
-- In those terms, at 1.7.16a: the subscribe function is at 0x00043A0C, its table at 0x005189C8
-- with the count 0x50 below at 0x00518978, 64 slots, and a stride of 0x100 rather than the
-- 6500's 0x128 -- expressed in the code as both `addi 256` and `slwi 8`. The stride does not
-- matter to this route, which takes the slot from the name hit; what matters is that the NAME,
-- the GRAPH and the ROUTING POINTER sit at +0x08, +0x34 and +0x40 exactly as on the 6500, and
-- the graph-trace kind is the same 0x407F. The eight trace and widget offsets this route and
-- px_from_trace use are unchanged too.
--
-- So a DMM7510 needs a different window and nothing else. 0x00510000 for 64 KB holds the table
-- and all 64 of its slots, and lies wholly inside that build's .bss (0x004FFDC0..0x005E9C10).
fftsa.nl.PX_SUB_LO_7510 = 5308416    -- 0x00510000
-- AND A LADDER OF WIDER WINDOWS FOR A MODEL WHOSE TABLE IS SOMEWHERE ELSE.
--
-- The window above is where a DMM6500 keeps it, and on that model the first read answers. On a
-- model with no measured address the table is still STATIC -- below the heap, in .bss -- so it
-- is reachable by reading that region and searching the bytes for a name this app chose. One
-- megabyte a frame is a 40 ms read at the measured 25 MB/s, the cursor is kept across frames,
-- and it happens once a launch.
--
-- This is not the abandoned Lua sweep. That swept the HEAP, hundreds of megabytes, for a
-- needle that moved between launches. This reads a bounded static region for a string whose
-- presence does not depend on where any allocation went, and it stops at the first hit that
-- validates.
--
-- A DMM7510's display code is a separate payload: rom/rom7519.zx, S-record header `disp7510_r`,
-- flattening to RAM 0..0xD03000 with the subscription tags present -- S$BE at 0x00170F30, S$BA
-- at 0x00171520, S$BB at 0x00171528, PEG Main at 0x0016E398, defbuffer1 beside them at
-- 0x00171034. So the mechanism is there and only its addresses are unknown, which is what this
-- ladder is for.
-- Derive the slot's field offsets when the compiled ones do not close the chain. Off on a
-- DMM6500, where they are read off the firmware and measured on the glass; on by default
-- elsewhere, because the alternative is having no route at all on a model nobody can measure.
fftsa.nl.PX_SUB_DERIVE = false
-- Walk a ladder of wider windows when the compiled one misses. Off on a DMM6500 for the reason
-- in px_sub_slot; on elsewhere, where there is no measured address to compile in.
fftsa.nl.PX_SUB_LADDER = false
-- Accept a slot whose kind word is not PX_SUB_KIND, provided everything else closes.
--
-- 0x407F is the DMM6500's graph-trace subscription kind and the kind word is the cheap liveness
-- filter -- unsubscribe clears it, so it rejects corpses in one read. On a model whose constant
-- is unknown that filter cannot be applied, and the route would simply never start. Dropping it
-- is safe because it is not what makes the chain believable: a candidate still has to reach an
-- object carrying this app's buffer name, present a ring whose base word equals its own +0x220,
-- and match 510 float32 frequencies of this app's axis in px_map before a byte is written -- and
-- a freed ring holds zeros, so it can match none of them.
fftsa.nl.PX_SUB_ANYKIND = false
fftsa.nl.PX_SUB_STEP  = 1048576      -- 1 MB a frame
fftsa.nl.PX_SUB_FROM  = 1048576      -- 0x00100000, clear of .text's start
fftsa.nl.PX_SUB_TO    = 16777216     -- 0x01000000, the 6500's heap floor and well past .bss
fftsa.nl.PX_SUB_KIND  = 16511        -- 0x407F, a graph-trace subscription
fftsa.nl.PX_SUB_NAME  = 8            -- 0x08, the name within a slot
fftsa.nl.PX_SUB_GRAPH = 52           -- 0x34, the graph widget
fftsa.nl.PX_SUB_P4    = 64           -- 0x40, the ADDRESS of the widget's routing element
-- The routing array the element must lie in, as offsets within the widget. 40 elements, written
-- at the cursor in graph+0x538 and wrapping, so the index says nothing -- but the RANGE
-- cross-checks slot+0x40 against slot+0x34, and the two came from different firmware stores.
fftsa.nl.PX_ROUTE_LO  = 1176         -- 0x498
fftsa.nl.PX_ROUTE_HI  = 1332         -- 0x534
fftsa.nl.PX_TR_GRAPH  = 0            -- trace+0x00, the trace's own graph back-pointer
fftsa.nl.PX_TR_SUB    = 48           -- trace+0x30, the subscription handle: the slot address
-- Name hits to examine. The window holds at least one DECOY: the c2c request record at
-- DAT_00d678d0/0xd8 carries both a copy of the name and a pointer to the current slot, and it
-- sits BELOW the table -- so it is found FIRST by a forward search. Measured: two hits, the
-- first at 00D67598 whose "kind" word read back 00D67CD0, which is the live slot's address.
-- Taking the first hit would have followed the decoy.
fftsa.nl.PX_SUB_HITS  = 12
-- Window reads a launch. The slot address is kept once found and re-checked with ONE word, so
-- this bounds only the case where the name is not in the window at all -- a model whose table
-- is elsewhere, where re-reading 64 KB every frame for the whole session would be the cost of
-- being wrong rather than one read.
fftsa.nl.PX_SUB_FINDS = 32
-- Guarded reads one call may spend deciding which of a window's name hits is a slot, before it
-- saves its place and lets the frame go. Where the name offset is known that covers every hit
-- the window can hold; where it is not, a hit costs one read per candidate offset and this is
-- what keeps a failing window from spending 144 round trips without a yield.
fftsa.nl.PX_SUB_JUDGE = 16
-- Frames to wait for a known slot's ring to fill before sweeping anyway. The ring fills from
-- the app's own appends, so this is a couple of frames in practice; the bound exists for a
-- build where a slot reads as live and the chain behind it means something else. Reset by
-- px_restart, because a rebind makes a new subscription and the frames spent on the old one
-- say nothing about it.
fftsa.nl.PX_SUB_WAIT = 24

-- The subscriber slot for this app's trace buffer, or nil. One bounded read and a string
-- search, both of which happen once: the slot address is kept and re-validated by the caller.
--
-- A CORPSE KEEPS ITS NAME. Unsubscribing clears a slot's KIND but does not erase the name or
-- slot+0x40, and removing one of several equivalent subscribers can leave -2 in the kind rather
-- than zero. So liveness is kind == 0x407F exactly, never "non-zero" -- the same trap the ring's
-- name needle fell into with 87 corpses in a single pass.
function fftsa.nl.px_sub_slot()
  local nl = fftsa.nl
  local want = nl.PX_NAME .. string.char(0)
  -- The slot this launch already found, re-checked rather than re-searched.
  if nl.px_subslot ~= nil then
    -- RE-CHECKED AGAINST THE KIND IT WAS ACCEPTED WITH, not against the compiled one. On a
    -- DMM6500 those are the same word. On a model whose constant is unknown they are not, so
    -- re-checking against 0x407F threw the slot away on the frame after it was found and sent
    -- the ladder round again -- measured offline as the name being found on try 4 and the route
    -- still reporting "none a live graph trace" on try 5.
    local wantk = nl.sub_kind or nl.PX_SUB_KIND
    if nl._wg(nl.px_subslot) == wantk then return nl.px_subslot end
    nl.px_subslot, nl.sub_trace = nil, nil
    nl.sub_why = 'the slot stopped reading as the kind it was found with'
  end
  -- An adjudication a frame ran out of budget for is finished before any window is read again.
  -- The hits are addresses, so resuming costs nothing, and a second attempt within one frame
  -- continues the list instead of reading the window a second time.
  if nl.sub_hitlist ~= nil then return nl.px_sub_judge() end
  -- The window read itself is ONE call and is deliberately not charged against rd_over: this is
  -- the route that makes the search unnecessary, and gating it would let whichever engine ran
  -- earlier in the frame starve the best answer. Only the adjudication, which is where the
  -- round trips multiply, takes a share of the frame.
  nl.px_subfinds = (nl.px_subfinds or 0) + 1
  if nl.px_subfinds > nl.PX_SUB_FINDS then
    nl.sub_why = 'the name is not in the window, ' .. tostring(nl.PX_SUB_FINDS)
                 .. ' reads spent'
    return nil
  end
  -- WHICH WINDOW THIS FRAME. The compiled one first, then the ladder, one a frame, resuming
  -- where it left off -- so a model whose table is elsewhere is not charged a 15 MB read in a
  -- single uninterruptible frame.
  local wlo, wn = nl.PX_SUB_LO, nl.PX_SUB_BYTES
  if nl.px_subwin ~= nil then
    -- THE LADDER IS FOR A MODEL WITH NO MEASURED ADDRESS, and only for one.
    --
    -- On a DMM6500 the compiled window is where the table is on both builds that have been
    -- read, and a later build moves it by a .bss delta of a few hundred bytes -- well inside
    -- 64 KB. Walking 15 MB behind that window there would cost fifteen frames of 1 MB reads
    -- before the search got going, which the offline suite measured as the search engaging
    -- after fifteen frames instead of under eight. So the 6500 reads its one window, and if
    -- that misses, sub_why says so and the search carries the job as it always did.
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
  -- Advance the ladder whatever happened, so a region the firmware refuses does not stall it.
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
  -- EVERY HIT, EXACT KIND FIRST, AND ONLY THEN ANYTHING LOOSER.
  --
  -- The window holds a DECOY: the c2c request record carries a copy of the name with a pointer
  -- to the current slot eight bytes before it, so it has a slot's shape and it sits BELOW the
  -- table -- found first by a forward search. On the 6500 the exact kind rejects it in one read.
  -- Under PX_SUB_ANYKIND a plausible non-zero word is enough, and the decoy's word is a slot
  -- ADDRESS, which is plausible -- so a single pass that accepted the looser test on the first
  -- hit would select the decoy, cache it, and never reach the genuine slot behind it. Measured
  -- on the 6500: two hits, the decoy first, its first word reading back the live slot's address.
  --
  -- So the hits are collected, then tried in two rounds. The 7510's kind is known to be the
  -- same 0x407F, so the loose round is a fallback for a build that changed it and never a
  -- shortcut past a slot that would have matched exactly.
  --
  -- The hits are collected as ADDRESSES and the window string is then dropped, so the rounds
  -- can be charged to the frame budget and resumed on a later frame without reading the window
  -- again. A hit costs up to one read per candidate name offset: twelve hits against twelve
  -- offsets is 144 round trips, three times the whole per-frame allowance, and spending them
  -- in one uninterruptible frame is the fault that PX_NAME_FAIL at 512 already cost a build.
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

-- One frame's share of adjudicating the name hits a window produced, resuming where the last
-- frame stopped. Returns the slot, or nil with the reason -- and keeps sub_hitlist set while
-- there is anything left to try, which is what px_sub_slot tests to know not to read again.
function fftsa.nl.px_sub_judge()
  local nl = fftsa.nl
  local hits = nl.sub_hitlist
  if hits == nil then return nil end
  local nh = table.getn(hits)
  -- ONE OFFSET WHERE THE OFFSET IS KNOWN. The twelve candidates exist to cover a model that
  -- moved the field; on a DMM6500 the name is at slot+8, read off bufsub_subscribe and the same
  -- in both builds. Trying all twelve against every hit is what made a failing window cost
  -- twelve hits times twelve offsets -- 144 round trips, three times the whole per-frame
  -- allowance, in one uninterruptible frame. With one offset the measured 6500 case is two
  -- reads: the decoy rejected, the slot found.
  local offs = nl.PX_SUB_NAMEOFFS
  if not nl.PX_SUB_DERIVE then offs = { nl.PX_SUB_NAME } end
  local noffs = table.getn(offs)
  local nread = 0
  while nl.sub_hitround <= 2 do
    if nl.sub_hitround == 2 and not nl.PX_SUB_ANYKIND then break end
    while nl.sub_hitat <= nh do
      -- A CALL'S SHARE, not a frame's. The route also runs at bind time, where thousands of
      -- reads have already been spent and no frame boundary has passed, so charging this
      -- against rd_over would refuse the best answer precisely when it is wanted. The list
      -- holds addresses, so what is left resumes on the next call for nothing.
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
  -- Every hit tried in every round. Keep one neighbourhood for the report, because on a model
  -- whose layout differs that dump is what settles the offsets without another run.
  --
  -- THE LAST HIT, NOT THE FIRST. The c2c request record carries a copy of the name BELOW the
  -- table, so a forward search meets the decoy first and the genuine slots after it -- measured
  -- on the 6500 as two hits with the decoy leading. Dumping the first described the decoy in
  -- the one field whose job is to show where a new model's fields really are.
  if nl.sub_map == nil and nh > 0 then nl.sub_map = nl.px_sub_dump(hits[nh]) end
  nl.sub_why = tostring(nl.sub_hits) .. ' name hit(s) through ' .. hx(nl.px_subwin)
               .. ', none a live graph trace'
  nl.sub_hitlist, nl.sub_hitat, nl.sub_hitround = nil, nil, nil
  return nil
end

-- Offsets of the name within a slot to try, in order. 8 is the DMM6500's, read off
-- bufsub_subscribe. The others cost one guarded read each and cover a model that moved the
-- field, which is cheaper than being unable to start at all.
fftsa.nl.PX_SUB_NAMEOFFS = { 8, 12, 16, 4, 20, 24, 32, 40, 48, 52, 56, 64 }

-- WHAT IS AROUND A NAME HIT THAT DID NOT VALIDATE, as offset:value pairs for the report.
--
-- This is the diagnostic that is meant to make ONE report from a DMM7510 enough. The chain is
-- kind at slot+0, name at slot+8, graph at slot+0x34 and a pointer to the widget's routing
-- element at slot+0x40 -- all DMM6500 figures. If a 7510 report shows the name found but no
-- slot, these words are what say where its fields really are: the same arithmetic that settled
-- the 6500 from one grab, where the name sitting exactly five strides plus eight above a
-- candidate base confirmed the stride, the field offset and the inter-build delta at once.
--
-- Only words that could be pointers are kept, so the line stays short enough to read off a
-- photograph of the screen.
fftsa.nl.PX_SUB_DUMP = 10
function fftsa.nl.px_sub_dump(na)
  local nl = fftsa.nl
  -- Which hit these words belong to. Offsets without the address they are measured from cannot
  -- be checked against anything, and the window holds a decoy as well as the slots.
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

-- WHICH WORDS OF A SLOT HOLD THE GRAPH AND THE ROUTING POINTER, derived rather than assumed.
--
-- +0x34 and +0x40 are DMM6500 figures, read off bufsub_subscribe. A model that moved them makes
-- the whole route unavailable, and there is no DMM7510 on the bench to measure -- so when the
-- compiled pair does not close the chain, the slot's own words are tried until one pair does.
--
-- What makes this safe without knowing anything is that the TEST is the chain closing on itself:
-- a candidate p4 has to point at a word that points at an object whose +0x08 carries THIS app's
-- buffer name, and that object then has to present a ring whose base word equals its own +0x220
-- and match 510 float32 frequencies of this app's axis in px_map before a byte is written. A
-- wrong pair cannot pass those; it costs three guarded reads to reject.
--
-- Bounded per frame by the walk's own share of the read allowance, with the cursor kept, so a
-- model that needs the whole range does not spend an uninterruptible frame on it.
fftsa.nl.PX_SUB_WALK = 128           -- bytes of a slot to consider, from 0
function fftsa.nl.px_sub_pairs(slot)
  local nl = fftsa.nl
  local want = nl.PX_NAME .. string.char(0)
  local at = nl.sub_walkat or 0
  while at <= nl.PX_SUB_WALK do
    local p4 = nl._wg(slot + at)
    at = at + 4
    if p4 ~= nil and p4 > 65536 and p4 < nl.DRAM_END and math.mod(p4, 4) == 0 then
      -- Two levels, which is what the DMM6500 does: slot+0x40 holds the ADDRESS of the
      -- widget's routing element, and that element holds the trace. One level is tried too, for
      -- a model that stores the trace pointer itself.
      local k
      for k = 1, 2 do
        local t = p4
        -- _wg GUARDS ALIGNMENT AND RANGE, NOT MAPPED-NESS, and that distinction is a
        -- bluescreen here. ki.peek32 is an lwz with no validation, so an address inside DRAM
        -- that nothing has mapped is a precise data storage interrupt -- which ki.reboot cannot
        -- recover. Every other route dereferences pointers the firmware handed us; this one
        -- walks a slot's BYTES, so each word is arbitrary until proven. px_live is the proof:
        -- the address has to lie in a span this module has already read successfully.
        if k == 2 then t = nl._rdw(p4) end
        -- And the WHOLE range px_from_name will read, not just the name field: it walks
        -- PX_NAME_SCAN bytes forward looking for a bounds pair, and proving only through the
        -- name would leave that walk reading on an exploratory candidate's authority.
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
            -- The name read succeeded, so the region is mapped and it is ours.
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

-- The trace object through the subscriber slot. Three reads, each checked against something the
-- firmware wrote somewhere else, then the ordinary name and geometry validation.
function fftsa.nl.px_from_bufsub()
  local nl = fftsa.nl
  if nl.PX_SUB == false then
    nl.sub_why = 'not attempted on this model'
    return {}
  end
  -- NOT CACHED PER FRAME, deliberately. This is called from the top of the seek arm and again
  -- from px_seek, so a frame where both run walks the chain twice -- eight guarded reads, which
  -- rd_note accounts for and RD_MAX_CALLS bounds. A once-a-frame cache keyed on the read
  -- stamp saved those eight reads and introduced a way to wedge: any caller that does not
  -- advance the stamp gets the first answer for ever, and the offline suite -- which calls this
  -- directly, several times, within one stamp -- is exactly that caller. The window read, which
  -- is the cost worth avoiding, is already cached by px_sub_slot.
  nl.sub_tries = (nl.sub_tries or 0) + 1
  local slot = nl.px_sub_slot()
  if slot == nil then return {} end
  local tr = nl.px_sub_fixed(slot)
  if tr == nil then
    -- THE COMPILED OFFSETS DID NOT CLOSE THE CHAIN, so derive the pair from the slot's own
    -- words. On a DMM6500 this never runs. On a model that moved the fields it is the
    -- difference between the route working and the route being unavailable, and the test is
    -- the chain closing on this app's own buffer name rather than on any figure from an image.
    if nl.PX_SUB_DERIVE and not nl.sub_walkdone then
      tr = nl.px_sub_pairs(slot)
      if tr ~= nil then nl.sub_derived = true end
    end
    if tr == nil then return {} end
  end
  local g = nl.px_from_trace(tr)
  if table.getn(g) == 0 then
    -- THE REASON px_from_trace GAVE, not a presumed one. An empty ring is the usual cause on
    -- the early frames -- px_from_name's last test is cnt >= 1, the corpse test, right for a
    -- heap search and wrong for a chain that has already closed on itself -- but it is not the
    -- only one, and reporting it as though it were would send a reader after the wrong thing.
    -- The count is named only when it was actually read and is actually zero.
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

-- The trace from a slot using the offsets read off the DMM6500's bufsub_subscribe, with every
-- cross-check the firmware's own stores make available. nil means this pair does not close.
function fftsa.nl.px_sub_fixed(slot)
  local nl = fftsa.nl
  local graph = nl._rdw(slot + nl.PX_SUB_GRAPH)
  local p4 = nl._rdw(slot + nl.PX_SUB_P4)
  if graph == nil or p4 == nil or graph <= 0 or p4 <= 0 then
    nl.sub_why = 'slot ' .. hx(slot) .. ' has no graph or no routing pointer'
    return nil
  end
  -- THE CROSS-CHECK THAT MAKES THE SECOND DEREFERENCE SAFE. slot+0x40 has to point inside the
  -- routing array of the very widget named by slot+0x34, and those two words were written by
  -- different stores in the firmware. A slot holding anything else is refused unread.
  if p4 < graph + nl.PX_ROUTE_LO or p4 > graph + nl.PX_ROUTE_HI
     or math.mod(p4, 4) ~= 0 then
    nl.sub_why = hxn(p4) .. ' is not inside the routing array of ' .. hxn(graph)
    return nil
  end
  -- READ, NOT PROVEN-THEN-READ. See _rdw: memread validates and refuses, where peek32 faults,
  -- and px_live's span is the app's own allocations rather than a map of what is mapped.
  local tr = nl._rdw(p4)
  if tr == nil or tr == 0 then
    nl.sub_why = 'the routing element at ' .. hxn(p4) .. ' is ' .. tostring(tr)
    return nil
  end
  -- And the trace has to point back at both of them. Either failing means the slot and the
  -- trace disagree -- a torn read while the display task removes a trace, or a corpse whose
  -- kind has not been cleared yet -- and nothing is believed on a name alone.
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
  -- Three mutual confirmations and a successful read: the span may now include it, which is
  -- what lets px_from_trace read the name and px_from_name walk to the bounds.
  if nl.sub_trace_ok ~= tr then
    nl.sub_trace_ok = tr
    nl._map_age = nl.MAP_REFRESH
    nl.map_lo, nl.map_hi = nil, nil
  end
  return tr
end

-- A COMPILED-IN HINT FOR THE TABLE BASE, under the operator's rule of 2026-11-10: a start
-- address may be compiled in as long as being wrong costs "a small bit of performance. Never
-- correctness."
--
-- It costs six reads to be wrong here, and that holds by construction rather than by care.
-- Nothing is believed on the hint's authority: the entry has to hold a plausible pointer, the
-- widget's trace array has to lead to a trace object, that trace has to carry THIS app's
-- buffer name, its bounds have to bracket a ring whose cursors agree, and px_map still has to
-- match 510 exact float32 frequencies of this app's own axis before a byte is written. A wrong
-- base fails at the name and the search runs exactly as it did before.
--
-- A LIST, BECAUSE THE TABLE MOVES WITH THE BUILD AND NOT WITH THE BOOT.
--
-- Both of these were read out of the firmware images rather than guessed, by finding the one
-- `mulli` by 0x260 that has a base load beside it: image offset +53550 in both builds, one site
-- each. 1.7.17a holds 0x00D178A0 and 1.7.18a holds 0x00D17BE0, and the 0x340 between them is
-- exactly the .bss delta already measured between those two builds -- so the table is in .bss
-- and this is a section shift, not a redesign.
--
-- That matters because the first version of this compiled in the 1.7.18a address while the
-- instrument runs 1.7.17a, so the walk read the wrong entry, found no trace and fell through to
-- the search every time: 40 seconds to engage, measured on the glass.
--
-- Trying both costs three reads for the one that is wrong, and a build in neither list falls
-- back to the search exactly as before. Static addresses, so unlike the ring they do not move
-- between boots, which is what makes them worth compiling in at all.
fftsa.nl.PX_OBJTAB_HINTS = { 13727904, 13728736 }   -- 0x00D178A0 1.7.17a, 0x00D17BE0 1.7.18a
-- Traces on one graph. The array is null-terminated, so this only bounds the walk; the app
-- binds two, the spectrum and the markers.
fftsa.nl.PX_TRACE_MAX   = 8

-- Is this address a trace object belonging to this app's buffer? Name first, because it is
-- the one field that says WHICH trace -- the marker trace is the same shape and carries
-- FFTSA_MARK -- and then the geometry, through the same walk the name route uses.
-- Is this a pointer worth dereferencing?
--
-- nl._wg CHECKS ALIGNMENT AND THE BACKSTOP, AND NEITHER IS A TEST OF WHETHER THE ADDRESS IS
-- MAPPED. ki.peek32 is a plain load -- _wg's own comment says so -- so a word inside the
-- backstop but outside real memory is a data storage interrupt and a bluescreen.
--
-- The table walk reads a widget pointer out of every entry it tries, and most entries are
-- unused, so most of those words are whatever the GUI left there. Following one unguarded
-- crashed the instrument at PC=0022D200.
--
-- So a pointer is only followed if it lands between addresses this module has ALREADY
-- dereferenced successfully -- see map_bounds. That is the same bound the native search needed
-- and the same reason: evidence, not documentation.
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
  -- THE REFUSAL, WITH THE SPAN IT WAS JUDGED AGAINST.
  --
  -- This gate is what stops the table walk following a garbage widget pointer into unmapped
  -- memory -- PC=0022D200, three times. It is also the most likely reason the pointer route
  -- answers nothing, because the span is derived from THIS APP's allocations and the widget
  -- is the display task's. Those are the same heap on this bench, but a launch where the
  -- app's allocations sit well above the GUI's would refuse every widget and say nothing.
  nl.live_why = string.format('%s outside %s..%s', hx(addr), hx(lo), hx(hi))
  return false
end

function fftsa.nl.px_from_trace(tr)
  local nl = fftsa.nl
  if type(tr) ~= 'number' or tr <= 0 or math.mod(tr, 4) ~= 0 then return {} end
  -- The trace object itself, and the whole name field, inside proven memory.
  if not nl.px_live(tr) or not nl.px_live(tr + nl.PX_TRACE_NAME + 32) then
    nl.ptr_why = 'trace object not live: ' .. tostring(nl.live_why)
    return {}
  end
  local at = tr + nl.PX_TRACE_NAME
  -- The name as the firmware holds it: NUL-terminated inside a 32-byte field.
  local want = nl.PX_NAME .. string.char(0)
  local got = ki.memread(hx(at), hx(string.len(want)))
  if got ~= want then
    nl.ptr_why = 'trace at ' .. hx(tr) .. ' does not carry this buffer name'
    return {}
  end
  -- And the geometry, from the bounds pair the layout puts at +0x1F0. px_from_name walks
  -- forward from the name for a pair that stands up, which lands on exactly that word
  -- without this having to assume it did.
  return nl.px_from_name(at)
end

-- The graph widget's traces, by pointer. Null-terminated, so a zero ends it.
function fftsa.nl.px_from_graph(gr)
  local nl = fftsa.nl
  if type(gr) ~= 'number' or gr <= 0 then
    nl.ptr_why = 'widget pointer is ' .. tostring(gr)
    return {}
  end
  -- The widget pointer came out of a table entry that may never have been used. Nothing is
  -- read through it until it is known to be in memory something has already touched.
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

-- The ring from the display handle, through the cached table base. Three guarded reads and a
-- validation, which is the whole point of having derived the base.
-- Every table base worth trying: the one this instrument confirmed, then the compiled hint.
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

-- Entries to try beyond the handle itself. An entry is a few guarded reads to reject, so the
-- whole table is cheaper than one sweep slice -- and the walk resumes across frames, so the
-- count costs frames rather than a frame.
--
-- 128 rather than 64: the handle is not the index, and the app alone creates screens, buttons,
-- images and two graphs before the display task's own objects are counted. A table whose right
-- entry sits above the limit reads exactly like a table with no answer in it, and the cost of
-- being wrong that way was 41 MB of sweeping.
fftsa.nl.PX_OBJ_SCAN = 128

-- THE SHARE OF A FRAME'S READ ALLOWANCE THE WALK MAY SPEND, and the whole engage time turned
-- on it.
--
-- The walk and the search run in the SAME frame: the idle arm falls through to the seek arm
-- rather than returning, so that neither waits for the other. But the walk runs FIRST, and
-- px_seek's loop is gated on rd_over() -- it has to be, because adjudicating a hit reads --
-- so a walk that spent the whole allowance left the search unable to take a single slice in
-- every frame the walk was running. The frames were not overlapped. They were taken.
--
-- Measured on the glass, three builds:
--
--   9.05   eng=2.0s/14f   a bug starved the walk to one frame
--   9.07   eng=4.2s/23f   the walk got its frames, and PX_OBJ_SCAN went 64 to 128
--   9.12   eng=2.9s/20f   swept=3MB, so the search was not short of range to cover
--
-- Sixteen of the forty-eight. The walk reaches the whole table in about three times as many
-- frames and costs the search nothing, because a frame whose slice turns up no hit needs
-- almost no reads at all -- the image's bytes are on their own account. The search is the
-- route that has answered on this instrument; the walk is the route that would answer for
-- free if it ever did. That ordering is what the share encodes.
fftsa.nl.PX_OBJ_CALLS = 16

-- Has the walk had its share of this frame? Separate from rd_over so that the two bounds
-- cannot be confused: this one protects the search from the walk, rd_over protects the frame
-- from both.
function fftsa.nl.px_obj_over()
  local nl = fftsa.nl
  return (nl._rd_calls or 0) >= nl.PX_OBJ_CALLS or nl.rd_over()
end

-- One table entry: the widget it names, and whether that widget owns this app's trace.
function fftsa.nl.px_entry(base, id)
  local nl = fftsa.nl
  local gr = nl._wg(base + id * nl.PX_OBJ_STRIDE + nl.PX_OBJ_WIDGET)
  if gr == nil or gr == 0 then return {} end
  return nl.px_from_graph(gr)
end

-- The ring from the display handle -- and from the neighbouring entries if the handle is not
-- the index.
--
-- THE HANDLE BEING THE TABLE INDEX IS THE ONE LINK IN THIS CHAIN WITH NO EVIDENCE BEHIND IT.
-- GRAPH.md asserts it and everything else it asserts was confirmed against this build's image:
-- the base 0x00D178A0 from the code that loads it, the 0x260 stride from the mulli beside it,
-- the widget at entry +0x50 from 29 field reads off a computed entry, the trace array at
-- widget +0x3EC from 50 reads inside the graph widget's own methods. The index is the only
-- part that cannot be read out of an image, because it is a runtime value.
--
-- So it is not trusted. The handle is tried first, then the table is walked, and the entry
-- that is kept is the one whose widget owns a trace carrying THIS app's buffer name. That is
-- a derivation rather than an assumption, it costs four reads an entry to reject, and the id
-- it finds is remembered so later launches go straight to it.
function fftsa.nl.px_from_ptr(gid)
  local nl = fftsa.nl
  local p = nl.px
  -- NO TABLE, NO POINTER ROUTE. The bases are the 6500's .bss addresses, read off its image.
  -- On a model without them this is three guarded reads a frame that can never answer, so it
  -- is not attempted and the name route carries the whole job.
  if nl.PX_PTR == false then return {} end
  local bs = nl.px_bases()
  local nb = table.getn(bs)
  if nb == 0 then return {} end
  -- The handle first, on every base: it is what the layout says should work.
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
  -- THEN THE TABLE, AND IT RESUMES. One cursor over the whole (base, id) space, kept across
  -- frames: 64 entries at a few reads each is more than one frame's allowance, so a walk that
  -- restarted at zero every frame would try the same low ids for ever and never reach a high
  -- one. The first form of this did exactly that, and its own comment claimed otherwise.
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
  -- Spent. Back to the start, so a later launch with a different table tries again -- and
  -- RECORDED as spent, which is what lets the caller stop waiting for it.
  --
  -- The cursor alone cannot say: it is zeroed both before the first entry and after the last,
  -- so "mid-walk" and "finished" look identical. A caller that held the path in idle while the
  -- cursor was non-zero therefore held it for ever, the walk restarting from zero each time it
  -- completed. Caught by the offline suite rather than on the glass.
  p.objscan = 0
  p.objdone = true
  return {}
end

-- THE TABLE BASE IS NOT DERIVED, AND THAT IS DELIBERATE.
--
-- It used to be, by searching for the word that holds the widget pointer and subtracting. Two
-- things were wrong with it. The forward check was vacuous -- `base + id*stride` reads back the
-- word the base was derived from, so it confirmed nothing whatever that word was -- and the
-- search was looking in the wrong place: the table is STATIC, in low memory below the heap,
-- about 47 MB from a ring in the GUI heap, so a bounded search near the ring could never reach
-- it and an unbounded one is the thing that bluescreened the instrument.
--
-- So the base comes from PX_OBJTAB_HINT, or from this instrument's own record on the key once
-- a base has answered. Both are validated the same way, by walking forward to a trace that
-- carries this app's buffer name. A base that does not is simply not used, and the search runs
-- as it did before.

-- How far either side of the last confirmed ring to look before anything else.
--
-- An Apply frees the trace objects and takes new ones from the display task's pool of thirty
-- 0x14220-byte objects -- one allocation run 2.4 MB wide -- so the ring moves to a NEIGHBOUR
-- of the old one. A window this far either side of what was confirmed last therefore holds the
-- new one, which is what turns a span or size change from a walk over the backstop into a
-- handful of slices.
fftsa.nl.PX_SEED_NEAR = 4194304
-- Past this the learned span has stopped being a hint and the exact-ring windows are used
-- instead. A span grown to tens of megabytes is not telling us anything the backstop does not.
fftsa.nl.PX_SEED_SPAN_MAX = 16777216
-- Bytes the NAME needle may sweep without one hit before the lap switches to the frequency
-- series. The name says WHICH trace and keeps its precedence absolutely, but it does not get
-- an unbounded pass: the trace object carries the name the subscription was made under, and on
-- a launch where that was not this app's buffer the name is simply not in memory.
fftsa.nl.PX_NAME_GIVEUP = 16777216
-- Name hits that produce no candidate before the needle is abandoned for the frequency series.
-- A freed trace object keeps the buffer name, so on an instrument the app has been run on this
-- is a count of corpses -- 1424 of them measured in one boot. Sixty-four is well past any
-- plausible number of LIVE traces carrying one buffer's name, and costs a read each.
-- PER PASS, and a restart resets it: a restart means the traces were rebound, so the corpses
-- counted before it say nothing about the pass ahead. The runaway this bounds -- nh=1424 in one
-- boot, 121 frames and 58 seconds still searching -- happened WITHIN a pass, so a per-pass
-- bound is the one that stops it. A session bound on top of this was tried and removed: it
-- condemned the needle on a fixture that restarts often, which is the same defect in a new
-- place, and the restart count is on the diagnostic page where a restart loop would be visible
-- as what it is.
-- Measured on the glass at 9.15 from a clean boot: nh=87 in ONE pass, all refused, with the
-- live object's name sitting in window 14 of 17. Sixty-four condemned the needle before the
-- ladder reached it. A hit costs one window read, so the bound belongs where that cost becomes
-- real -- hundreds, not tens -- and the runaway it guards was 1424.
-- SIXTY-FOUR, AND THE REASON 512 WAS WRONG IS WORTH KEEPING.
--
-- It was raised to 512 on the argument that a name hit costs one window read, so the bound
-- belonged "in the hundreds, not the tens". That measured the cost PER HIT and never the cost
-- PER FRAME. PX_HITS_PER_SLICE lets a single uninterruptible frame adjudicate 64 of them, and
-- at a window read each that is about 190 ms -- so a relaunch, which is where the corpses are,
-- went to under 3 fps at 2048 points with nh=538 and swept=126MB. A fresh boot has almost no
-- freed trace objects and never showed it.
fftsa.nl.PX_NAME_FAIL = 64
-- Hits one slice may adjudicate in one frame. Each costs one read now rather than 29, but the
-- count is the heap's to choose and a frame cannot be interrupted.
fftsa.nl.PX_HITS_PER_SLICE = 64
-- Frames the pointer route and the cached geometry are given before the search starts. px_map
-- needs the ring to hold this plan's frequencies, which it cannot on the frame after a
-- relaunch -- the trace object has only just been created and the display task lags a pass
-- behind the appends that fill it -- so the first attempt fails whatever the address, and says
-- nothing about whether it was right.
fftsa.nl.PX_CACHE_TRIES = 8

-- Re-point the series in place when the FFT size moves it, rather than dropping the path. On
-- its own knob because it is the one thing here that writes a field the firmware wrote, so a
-- single assignment from the socket puts the old drop-and-search behaviour back for a boot.
fftsa.nl.PX_REPOINT = true

-- WHERE THE RING IS, RELATIVE TO SOMETHING THIS LAUNCH ALREADY KNOWS.
--
-- The ring is a display-task allocation, so its address is not predictable from the last one:
-- five confirmations sit in a band whose gaps share no factor with the 0x14220 trace object.
-- What does place it is the trace buffer's own C++ instance, which this module already has
-- through the buffer's metatable -- derived per launch, already dereferenced, and not specific
-- to a model or a firmware build.
--
-- THE FIRST VERSION OF THIS GOT THE DIRECTION WRONG, from two samples:
--
--   ring 037566C8   inst 0377B628   -0.14 MB     8.78
--   ring 036809B0   inst 03776730   -0.96 MB     8.94
--   ring 03930960   inst 0326FE48   +7.08 MB     8.99
--   ring 036D2E78   inst 030CA030   +6.03 MB     9.01
--   ring 0375B9C0   inst 0352E650   +2.25 MB     9.03
--
-- Both of the first two were below, so the window was inst-2MB..inst+1MB, and the next two
-- were six to seven megabytes ABOVE -- it missed outright and the ladder swept 11 MB and then
-- 9 MB. Ordering sub-bands by where the ring was last time then put +4..+8 MB first, and the
-- fifth launch put it at +2.25 MB, in the sub-band tried last.
--
-- FIVE SAMPLES SPAN -1 TO +7 MB WITH NO CLUSTER, so the offset is not predictable and ordering
-- by recency is chasing noise. The band is inst-2MB to inst+8MB, covering all five, and it is
-- swept in ADDRESS ORDER. It is offered as three windows because a window wider than
-- PX_WIN_MAX is taken by px_seek for the backstop pass and deferred to last, which would throw
-- away the precedence the band exists for.
--
-- What makes the band affordable is not its order but the scan rate: measured at 8 MB/s with a
-- byte-at-a-time search, 10 MB was over a second of scanning; word-aligned and word-compared
-- it is a fraction of that. Window placement was never the lever it looked like.
--
-- Being wrong costs the slices spent on it and nothing else. Like every window here it only
-- ORDERS the ladder: whatever it turns up still has to carry this app's buffer name, present
-- cursors that agree, and match 510 exact float32 frequencies of this app's own axis in px_map
-- before a byte is written.
fftsa.nl.PX_INST_WIN = true
-- The band, as offsets from inst, in the order they are tried. Each is at most PX_WIN_MAX wide.
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

-- The last ring this app confirmed, from the geometry cache. Only its address is wanted: the
-- rest of that record is stale the moment the trace objects are replaced, which is exactly the
-- case this exists for.
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
  -- The instance-anchored window first, because it is the only one derived from THIS launch's
  -- allocator state rather than from a previous launch's answer. Three megabytes, and on the
  -- two launches where both addresses were recorded the ring was inside it both times.
  -- THE LEARNED SPAN FIRST, because it records the quantity we actually want.
  --
  -- The span is every ring address this instrument has confirmed, widened by PX_SEED_NEAR
  -- either side to absorb the pool handing out a different trace object next launch. It used
  -- to come second, behind a band anchored on the trace buffer's C++ instance, and that order
  -- was built on two samples where inst looked like the stable one.
  --
  -- Seven samples say the opposite. Measured at 9.04 and 9.05, one launch apart:
  --
  --   ring 30B26A8   inst 30CDAD0      ring - inst =  -0.11 MB
  --   ring 30B7920   inst 11EB6F0      ring - inst = +32.2  MB
  --
  -- The RING moved 21 KB. The instance moved 32 megabytes. Across every launch recorded the
  -- ring sits in a band around 0x30B0000..0x3930000 and inst is the thing that jumps, so the
  -- band was anchored on the less stable of the two quantities -- and each time it missed, the
  -- width and the ordering got blamed instead of the anchor.
  local slo, shi = nl.px_seed_learned()
  if slo ~= nil and shi - slo <= nl.PX_SEED_SPAN_MAX then
    add(slo - nl.PX_SEED_NEAR, shi + nl.PX_SEED_NEAR)
  end
  -- Then the last exact ring, upward then downward, for the span having grown too wide to be
  -- a hint at all.
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
  -- CHEAP WINDOWS, THEN THE INSTANCE BAND, THEN WIDTH. Two measured failures bound this
  -- ordering from both sides, and either rule alone produces the other's failure.
  --
  --   9.08  eng=9.0s/41f  swept=29MB   the ring 86 KB from inst, inside a 256 KB buffer-side
  --                                    window -- which sat behind a learned span grown to
  --                                    23 MB. Ordered by how much each window's source was
  --                                    trusted, a cheap window waited on an expensive one.
  --
  --   9.13  eng=18.6s/63f swept=35MB   the ring at inst+4.48 MB, inside instance band 2 --
  --                                    which sorted to window 15 of 17 because it is 4 MB
  --                                    wide. Ordered purely by width, the window most likely
  --                                    to be right waited on fourteen that were not.
  --
  -- So neither trust nor width is the quantity. The quantity is expected bytes scanned before
  -- the ring is found, and for windows tried in sequence that is minimised by ordering on
  -- WIDTH DIVIDED BY THE CHANCE OF BEING RIGHT. Three groups come out of that:
  --
  --   1. Anything at or under PX_WIN_CHEAP is one slice. It costs so little that its chance
  --      of being right hardly enters -- try them all first, narrowest first, and a wrong
  --      guess has cost a frame.
  --   2. The instance band. It is the only window derived from THIS launch's allocator state
  --      rather than from a previous launch's answer, and across the launches recorded the
  --      ring has been inside it far more often than in any single buffer-side window: at
  --      -0.11, +2.25, +4.48 and +6 to +7 MB of eight recorded, against one at +32 MB. Ten
  --      megabytes in address order, and at the measured rate that is a few frames.
  --   3. Everything else by width, the backstop falling out last because it is the widest.
  --
  -- The learned span is still demoted by this: it only ever widens, so it leaves group 1
  -- early and is then judged on width like any other wide window.
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

-- One budgeted slice of the search, resumable across frames.
--
-- THE NEEDLE IS THE FREQUENCY AXIS, and the reason is a one-frame lag that nothing else can be
-- made robust against.
--
-- The obvious needle is the decibels the fill has just written: db[1], db[2], db[3] go into
-- consecutive slots, so four of them confirm a stride the way four sentinels do. It does not
-- work from inside a frame. An append does not write the trace ring -- it pushes a 28-byte
-- record into a buffer-side STAGING ring and posts a message, and the display task copies it
-- across only when it runs, which is while the Lua thread is blocked. So at the end of a fill
-- the staging ring holds this pass and the trace ring still holds the LAST one.
--
-- Measured 2026-11-09, sweeping the window the ring is in with the frame's own decibels: the
-- slice holding the staging ring confirmed at a 28-byte stride, and the slice holding the trace
-- ring confirmed nothing. probe_ringfind met the same thing from the other side and answered it
-- with delay(1.5) after appending, which a frame cannot afford.
--
-- The frequencies have no lag. nl.reduce fixes them as an affine series the primitive derives
-- before its segment loop and then caches, so hz is the same series bit for bit in every frame
-- and every pass -- and the ascending lap writes hz[j], hz[j+1], hz[j+2] into consecutive
-- records whichever pass wrote them. A slice over the ring confirms in any frame, however far
-- behind the display task is.
--
-- EVERY confirmed geometry from the slice is returned, not the first.
--
-- A hit confirms at more than one stride, and the first one is the wrong one: the staging ring
-- carries the same floats in the same order in a 28-byte record, and 28 comes first in the
-- REC_MIN..REC_MAX walk. Only the header tells them apart, so returning the first confirmation
-- and discarding it when it has no header throws away the real geometry found in the same slice
-- and moves the cursor past it -- 981 MB swept and reported absent, measured.
--
-- An empty list means the budget ran out with nothing, and the cursor is left where it stopped.

-- Which four columns to look for, and the eight bytes to look for them with.
--
-- A frequency of zero packs to four zero bytes, and eight zero bytes are everywhere in memory
-- -- including two words inside every record of the ring itself. So the column is chosen for
-- the bit pattern it gives rather than taken from the start of the band: the most non-zero
-- bytes wins, and four consecutive columns have to be distinct or no stride can be confirmed.
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

-- Four consecutive records holding four known frequencies, read as one block: a wrong stride
-- costs one memread.
-- EVERY CANDIDATE STRIDE OFF ONE READ.
--
-- One read per candidate stride walks REC_MIN..REC_MAX in fours -- 29 round trips for every
-- hit -- and the frequency needle takes as many hits in a slice as the heap happens to hold.
-- Measured on the glass at 0.1 fps at 2048 points, ten seconds inside a single frame, as soon
-- as the name cap made this route run routinely instead of only after a whole ladder. It is
-- the same defect as a peek per element in the name walk, and it is why there is one read
-- here and not a loop of them.
--
-- The widest stride needs (n-1)*REC_MAX + 8 bytes, 392 for four needles, so one read covers
-- all of them and the test becomes arithmetic in a string.
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
        -- val0 is the x field and dx is zero: this confirmed on the x and nothing else, and
        -- px_map derives the value field itself.
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
  -- THE POINTER FIRST, and it costs three reads. Once the object table's base has been
  -- the compiled hint or this instrument's own record -- the handle the app holds leads to the
  -- ring without sweeping anything. Re-validated on the way through, so a base that has gone
  -- stale falls through to the sweep rather than answering wrongly.
  -- THE SUBSCRIBER SLOT, EVERY FRAME OF THE SEARCH, and this is what the route was missing.
  --
  -- It is tried in the idle arm too, but the idle arm stops running once p.state latches to
  -- 'seek' -- so the route got only the first few frames of a launch, which are exactly the
  -- frames where it cannot succeed. px_from_name's last test is `cnt >= 1`: the ring must hold
  -- a record. For a heap search that test IS the corpse test, and it is right -- a freed ring
  -- holds zeros. For this route it is wrong: the slot's kind is live, the trace points back at
  -- the graph the slot names and at the slot itself, so an empty ring means the appends have
  -- not been through it yet, not that the object is dead.
  --
  -- Measured on the glass at 9.17: sub=D67CD0/2hit found the right slot and the right trace --
  -- the ring the search went on to find 26 MB later was that trace's own +0x220 -- and the
  -- candidate was refused on an empty ring and never offered again. eng=4.7s/23f.
  --
  -- Once the slot is known this costs one word to re-check and about seven more to walk, so it
  -- can run on every frame until the ring fills.
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
    -- Stale: the base survives a relaunch but not a firmware change or a moved table.
    nl.px_objbase = nil
    p.ptr_lost = (p.ptr_lost or 0) + 1
  end
  -- The name next. It is longer, it is unique to this app, and it is in memory whatever the
  -- display task and the spectrum are doing -- see px_from_name. The frequency series stays as
  -- the second needle, for a build that does not keep the name where this can reach it.
  -- THE NAME FIRST, BUT NOT TO THE END OF DRAM.
  --
  -- The name is the better needle -- unique to this app, present whatever the display task and
  -- the spectrum are doing, and it says WHICH trace, which the frequencies cannot: the marker
  -- trace is the same shape and the staging ring holds the same floats in the same order. So it
  -- keeps its precedence absolutely and nothing is adjudicated beside it.
  --
  -- What it does not get is an unbounded pass. The trace object carries the name the
  -- subscription was made under, and on a launch where that was not this app's buffer the name
  -- is simply not in memory -- measured on the glass at 8.80, swept=276MB with laps=1 and the
  -- frequency needle then finding the ring in the seed window almost at once. 268 MB to learn
  -- that the first needle does not work today. PX_NAME_GIVEUP bounds that to the windows worth
  -- trying, and the lap carries on with the other needle instead of starting over.
  local n1 = nl.PX_NAME .. string.char(0)
  local byname, xs = true, nil
  -- PER PASS, NOT PER SESSION. p.swept is the honest cumulative total of bytes scanned and is
  -- what the report shows; judging the needle on it condemned the needle on the FIRST slice of
  -- every pass after the second, because by then the total already exceeded the bound whatever
  -- the pass itself had done. Measured on the glass at 9.14: re=4, swept=27MB against a 16 MB
  -- bound, by=freq, and the ring sitting in the instance band the ladder tries third with its
  -- name in memory the whole time.
  if (not p.noname) and (p.sweptpass or 0) >= nl.PX_NAME_GIVEUP
     and (p.namehits or 0) == 0 then
    p.noname = true
    p.gaveup = (p.gaveup or 0) + 1
  end
  -- AND IT GIVES UP ON HITS THAT GO NOWHERE, not only on finding nothing.
  --
  -- The condition above asks whether the name is in memory at all. It is the wrong question on
  -- an instrument the app has been run on before: a trace object that has been freed KEEPS the
  -- buffer name, so the needle matches every corpse of every previous run. Measured on the
  -- glass at 9.10 after many launches in one boot: nh=1424, laps=2, 121 frames and 58 seconds
  -- still searching, every candidate refused with "header count 0" -- a zeroed ring, which is
  -- exactly what a dead object looks like. On a fresh boot the same needle gets 2 hits.
  --
  -- The frequency needle cannot make that mistake. It matches the ring's CONTENT -- this
  -- plan's own frequencies in consecutive slots -- and a freed ring holds zeros, so it can only
  -- ever match a live one. The name says which trace and keeps its precedence while it is
  -- earning it; once this many hits have produced no candidate at all, it is not.
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
      -- The ladder is spent. The name found nothing, so the next lap uses the other needle --
      -- and if that fails too, laps simply counts how many times round it has been.
      p.wins, p.wi, p.at = nil, nil, nil
      p.laps = (p.laps or 0) + 1
      -- A record of the name having been absent for a whole ladder, for the report. It no
      -- longer gates anything: both needles run on every slice now.
      if (p.namehits or 0) == 0 then p.noname = true end
      return out
    end
    -- THE ONE LONG SCAN HAPPENS ONCE A SESSION. The ladder's last window is the backstop --
    -- the whole of DRAM -- and a restart used to rewind to the start of the ladder, so every
    -- plan change paid it again. It is offered until it has been walked through once and never
    -- after: the seed and buffer-side windows are small and worth re-trying, that one is not.
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
      -- HITS CARRIED OVER FROM A SLICE A FRAME COULD NOT FINISH, consumed before any new read.
      -- Re-walking the slice to find them again is exactly the repeat this must never do: the
      -- first form of this reset the slice cursor instead of keeping the hits, so a dense slice
      -- was swept, abandoned and swept again for ever -- 0.8 fps and no progress, measured.
      local h, hfrom = p.slicehits, p.slicefrom or 1
      if h == nil then
        h, hfrom = nl.FINDS(lo, hi, n1), 1
        p.swept = p.swept + (hi - lo)
        p.sweptpass = (p.sweptpass or 0) + (hi - lo)
        left = left - (hi - lo)
        -- Overlap by the needle's tail, or a record straddling a slice edge is never matched.
        -- Past the window's end this leaves at+8 above w[2], which advances the window above.
        p.at = hi - 7
      end
      local k, sv
      for k = hfrom, table.getn(h) do
        p.hits = (p.hits or 0) + 1
        if byname then
          p.namehits = (p.namehits or 0) + 1
          -- One hit, every geometry it could be, by arithmetic. No header to go looking for:
          -- the bounds come out of a bounded walk forward from the name.
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
        -- A SLICE MAY NOT COST AN UNBOUNDED NUMBER OF READS. Both routes are one read per hit
        -- now, but the hit count is whatever the heap holds and a frame cannot be interrupted.
        -- The remaining hits are KEPT, not rediscovered.
        if (k - hfrom + 1) >= nl.PX_HITS_PER_SLICE or nl.rd_over() then
          p.slicehits, p.slicefrom = h, k + 1
          p.hitcap = (p.hitcap or 0) + 1
          return out
        end
      end
      p.slicehits, p.slicefrom = nil, nil
      -- Returned as soon as this slice has anything, so the header tries start on the next
      -- frame rather than after the rest of the budget.
      if nout > 0 then return out end
    end
  end
  return out
end

-- Offsets in a record where three consecutive words are equal.
--
-- The two pixel fields are the only repeating shape in the 56 bytes -- the value and the x
-- float are PAIRS -- so this finds them without knowing the layout. Overlapping offsets inside
-- one run are dropped: a y pixel of zero beside the two zero words would otherwise report a
-- second triple that is three quarters padding.
-- The offsets that are a triple in EVERY record sampled, which is what a field is.
--
-- One record is not enough. The first record of the ring is the band's first column, and at dc
-- the x float is zero and the flags beside it are zero -- so three consecutive zero words
-- appear where no field is, and a third triple is reported at the flags. Intersecting over
-- records spread through the window removes it: a real field is a triple wherever you look.
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

-- Least squares of one per-slot series against another, centred so the normal equations do not
-- cancel: 721 records of about -100 dB give a sum of squares near 5e9 against a variance term
-- near 1e7, and the centred form never forms either.
--
-- Returns slope, intercept, worst residual, the span of the independent variable, the count,
-- and how many of them fall within tol. nil when fewer than eight slots are usable or the
-- independent variable does not vary -- a constant field fits everything and must never be
-- taken as a map.
--
-- THE INLIER COUNT IS WHAT CALLERS JUDGE ON, not the worst residual: a single word that is not
-- a pixel moves the worst residual by seven orders of magnitude. px_words drops the word that
-- caused that one, and this is the second line of defence for whatever the first one misses.
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

-- One record field across the window, as a per-slot array. Words for a pixel triple, float32
-- for a value or a frequency. A word outside PX_PIX_MAX comes back nil, so the fit skips it
-- rather than being dragged across the plot by it.
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

-- Everything the frame needs, solved once from the ring the appends have already filled: which
-- slot carries which column, which triple is the decibel axis, and the map onto it. Returns true
-- when all of it stands up.
--
-- NOTHING HERE DEPENDS ON WHICH FRAME WROTE A RECORD, which is what makes it safe to run while
-- the display task is an unknown distance behind. Every term is either a frequency -- the same
-- series in every pass -- or a comparison between two fields of the SAME record:
--
--   the slot map        the x field against this plan's own frequencies, exact float32
--   which triple is x   the x triple against the x field in the same record, affine by
--                       construction, so it fits to half a pixel and the y triple does not
--   which triple is y   whichever one is left, there having to be exactly one
--   the decibel map     the y triple against the value field in the same record
--   the value field     the offset the y triple turns out to be affine in, over a wide
--                       enough span to have fitted a slope at all
--
-- THE SLOT MAP IS AN EXACT FLOAT32 MATCH, not a nearest-frequency search, and 721 exact matches
-- against a 255-member set is also the confirmation that this is the right ring: nothing else in
-- memory is a permutation of the app's own axis.
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
  -- ONLY THE DRAWN WINDOW, which is not the whole ring.
  --
  -- The ring is 721 records and the header reported count 510 with oldest at the ring start:
  -- the trace buffer is FILL_CONTINUOUS at a capacity of exactly one pass, so the cursor
  -- returns to slot 1 every pass and the task mirrors it. The 211 records past the count have
  -- never been written and mapping them finds no frequency in them. Measured 2026-11-09.
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
  -- THE ONE BOUNDS TEST BEFORE ANYTHING IS WRITTEN. px_frame writes the whole block with a
  -- plain ki.memwrite, which is memcpy and validates nothing, so the range is checked here --
  -- once, where a refusal costs a fallback rather than a frame -- against the same backstop
  -- every other write in this module answers to.
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

  -- The slot map, and the confirmation, in one pass.
  local key, j = {}, nil
  for j = 1, nseg do key[f32_pack(hz[j])] = j end

  -- WHERE THE X FIELD IS, when the caller did not say. The record route finds it while
  -- confirming a stride; the name route never looks at a record, so it is derived here -- the
  -- one offset whose four bytes are a member of THIS plan's frequency series in every slot.
  -- A permutation of the app's own axis, 510 slots deep, is not something another field can
  -- imitate. The x is stored twice side by side, so the lower of the two matches wins.
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
    -- Ordinary immediately after a retune or a launch: the window still holds slots the new
    -- plan has not written yet, and two frames of appends clear them. The caller retries.
    p.why = tostring(miss) .. ' of ' .. tostring(cnt)
            .. ' slots carry a frequency this plan does not have'
    return false
  end

  -- Which triple is which. The x pixel is an affine function of the x field in the same record
  -- whatever the spectrum does, so it is the one that can be named first; the y pixel is a
  -- function of the decibels, which are not affine in frequency unless the trace is a straight
  -- line. Never test any of this against a ramp.
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
      -- How far the fitted line travels across the plot, which is the term that tells the
      -- frequency axis from a trace that merely looks like a straight line.
      local rng = a * sp
      if rng < 0 then rng = -rng end
      rep = rep .. string.format(' %d:in%d/%d/%.0fpx', tr[i], nin, m, rng)
      if nin >= need and rng > best then
        second = best
        best = rng
        xoff = tr[i]
        -- KEPT, because it is the frequency axis itself and it was being thrown away.
        --
        -- This fit is pixel = a * frequency + b over every slot in the drawn window, which is
        -- the firmware's own x axis as a formula. With it the path can place a frequency it
        -- has never drawn, which is what lets an FFT size change re-point the series in place
        -- instead of dropping the path and searching again.
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

  -- The value field, and the decibel map with it: the offset the y triple is affine in. A
  -- doubled float32 is the shape, a wide span is what makes a slope mean anything, and the two
  -- zero words -- constant, so they fit nothing -- are what the span test is for.
  local yw = nl.px_words(blk, cnt, stride, yoff)
  local ov, ay, by, resid, dbspan = nil, nil, nil, nil, nil
  local o
  for o = 0, stride - 8, 4 do
    -- Never the x field. It is a doubled float32 that spans the whole band, so against a trace
    -- that happens to be flat the y triple fits it perfectly with a slope of nothing -- and the
    -- map that came out of that would put every column on one row. Measured against a fixture
    -- whose spectrum was deliberately flat.
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

  -- The pieces, sliced out of the records the app itself wrote, so the x pixels, the value, the
  -- x float and the flags stay the firmware's own. Only the middle piece is rewritten.
  local T = {}
  for s = 1, cnt do
    local base = (s - 1) * stride
    T[3 * s - 2] = string.sub(blk, base + 1, base + yoff)
    T[3 * s - 1] = string.sub(blk, base + yoff + 1, base + yoff + 12)
    T[3 * s] = string.sub(blk, base + yoff + 13, base + stride)
  end
  -- Every y a panel row can be, built once. A frame then stores table entries and formats
  -- nothing: the 19.3 ms of a per-record write was mostly string.format and string.char.
  local ytab, y = {}, nil
  local c, fl, md = string.char, math.floor, math.mod
  for y = 0, nl.PX_YMAX do
    local w = c(md(fl(y / 16777216), 256), md(fl(y / 65536), 256),
                md(fl(y / 256), 256), md(y, 256))
    ytab[y] = w .. w .. w
  end
  p.g, p.lo, p.hdr, p.stride, p.nrec = g, lo, g.hdr, stride, cnt
  p.ov, p.ox, p.yoff, p.xoff, p.nseg = ov, ox, yoff, xoff, nseg
  -- The frequency series, as the two numbers that fix it. nl.reduce forms every frequency as
  -- f0 + c * fstep and keys its own cache on exactly this pair, so an equal pair at an equal
  -- count is the same axis to the last bit. The slot map is a permutation of that axis and
  -- means nothing against another one: a retune that happened to keep nseg would otherwise
  -- draw the new spectrum at the old frequencies, correctly and silently.
  p.hz1, p.hz2 = hz[1], hz[2]
  p.ay, p.by, p.resid, p.span = ay, by, resid, dbspan
  p.idx, p.ytab, p.T, p.yb = idx, ytab, T, {}
  p.drift, p.slot, p.slotdb, p.slotprev = 0, nil, nil, nil
  -- The frequency axis as a formula, and the range it was fitted over. px_repoint will only
  -- interpolate inside that range: outside it the fit is an extrapolation of a line nothing
  -- measured there, and the axis could have been retuned rather than the series re-gridded.
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
  -- The image's copy of all of it, so a frame writes the ring with one call instead of
  -- assembling 28 KB in Lua. A refusal here is not a refusal of the map: the Lua writer draws
  -- the same picture and px_block says on the About page why it is the one running.
  nl.px_block()
  return true
end

-- Patch bytes into one record of the held image, outside the y triple.
--
-- The image in p.T is three pieces a record: the prefix the app's own write left, the y triple
-- a frame rewrites, and the suffix. The x pixel and the x float both live in a piece this does
-- not own, so re-pointing the series means editing those pieces rather than the ring.
--
-- A field straddling the y triple is refused rather than split. None does on this firmware --
-- the triples are 4-aligned and so are the fields -- and a half-written float is the kind of
-- thing that draws a point at the wrong place in a way no check downstream would catch.
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

-- A pixel as the firmware stores one: the same word three times over.
function fftsa.nl.px_triple(v)
  local c, fl, md = string.char, math.floor, math.mod
  local w = c(md(fl(v / 16777216), 256), md(fl(v / 65536), 256),
              md(fl(v / 256), 256), md(v, 256))
  return w .. w .. w
end

-- RE-POINT THE SERIES INSTEAD OF DROPPING THE PATH.
--
-- An FFT size change moves every plotted frequency, because the column frequencies come off
-- the bin width. Nothing else moves: the graph, the widget, the trace object, the ring, the
-- span and both axes are the same, and so is the column count. The slot map is a permutation
-- of the series, so the old form of this dropped the path and searched again -- seconds of
-- appending for a graph that was, as the operator put it, displaying a line at the same scale.
--
-- What actually has to change is the two fields that say WHERE a slot is: the x float the slot
-- map keys on, and the x pixel the widget draws at. Both are this code's to write -- they sit
-- in the held image either side of the y triple -- and the frequency axis kept at map time
-- turns a frequency into its pixel. So the series is re-pointed in place: no search, no hold,
-- no frame of appending, and the permutation is untouched, which keeps the fold's geometry.
--
-- Refused, leaving the caller to drop, when anything beyond the series has moved: a different
-- column count is a different permutation, and a frequency outside the fitted range means the
-- axis itself was retuned and the fit no longer describes it.
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
  -- BOTH ENDS STAY PUT, give or take one column. This is what tells a re-gridded series from
  -- a retuned axis, and it is the whole licence for reusing the fit.
  --
  -- A re-grid changes the STEP and not the ends: a finer bin grid moves the first and last
  -- column by a fraction of a column, the span either side of them being the same. A retune
  -- moves the ends, because the ends are the span. So each end is held to the end it was
  -- fitted at, within one column -- one column of extrapolation on a line fitted across every
  -- slot in the window is bounded and harmless, and the pixel is clamped to the measured ends
  -- regardless.
  --
  -- Asking only that the new series lie INSIDE the fitted range does not distinguish the two,
  -- and fails in one direction only: a narrowed span leaves every new frequency inside the old
  -- range, so a one-sided test passes while the widget has been re-pinned underneath it. Every
  -- column then takes its pixel from a line fitted to the old span, lands within a few columns
  -- of one end and clamps there -- a drawn trace, with nothing refused and the decibel fit
  -- still reading healthy. A widened span is caught either way, which is why widening a span
  -- draws correctly and narrowing it does not.
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

-- Whether the ring write runs in the image or in Lua. A LIVE KNOB, because the two draw the
-- same picture at very different costs and the comparison is made on the glass: one
-- assignment from the socket moves a running app from one writer to the other without a
-- rebuild, which is how the saving gets measured rather than asserted.
--
-- It gates the CALL and not the block, so flipping it either way takes effect on the next
-- frame. Gating the block instead would mean a session that started with it off could never
-- be turned on, the block being written once per map.
fftsa.nl.PX_NATIVE = true

-- ---------------------------------------------------------------------------
-- THE RING WRITE IN THE IMAGE, and the block it reads.
--
-- A pass is 510 twelve-byte patches. In Lua that is a loop over the trace columns to pick
-- each row's triple out of a prebuilt table, a second loop over the ring slots to place them,
-- a table.concat of 1530 pieces and one ki.memwrite of 28 KB -- 9.6 ms measured for the
-- memwrite alone. The image does the same work as a multiply, a clamp and three stores per
-- record, reading the decibels out of the arena where dsp_reduce left them, so nothing is
-- copied in to make the call.
--
-- NOTHING IN THE BLOCK CHANGES FROM FRAME TO FRAME, which is why it is written once here
-- rather than packed per frame. The ring, the stride, the two field offsets, the slot map and
-- the row map are all settled by px_map and hold until px_map runs again; px_repoint rewrites
-- the x fields of the held image and leaves every one of them alone.
--
-- THE WINDOW THE BLOCK DECLARES IS THE WHOLE RING, from the bounds pair in the trace object,
-- while the records written are the drawn window the ring header reports. Two different
-- sources, which is the point: a header that has crept cannot take the write outside the ring
-- the object says it owns. wr_lo..wr_hi is not that window and could not be -- it describes
-- the arena, and widening it to cover the ring would weaken every test it gates.
-- ---------------------------------------------------------------------------
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
  -- The header width against the image's own figure, for the same reason write_params checks
  -- PARAM_WORDS: a word added on one side only shifts the slot map, and the image would then
  -- read a column index out of a row map.
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

-- One frame's ring write, in the image. Returns the records written, or nil to leave the
-- caller its Lua writer.
--
-- The params struct is packed in full rather than poked: one 228-byte ki.memwrite costs the
-- same round trip as a four-byte one, and the alternative is a mode word that depends on the
-- last MODE_RUN having left every other field right.
--
-- ONE REFUSAL RETIRES IT. A persistent refusal would otherwise cost the call on top of the
-- Lua write that has to follow it, every frame for the rest of the session, and the reason
-- would never be read -- so the reason is kept where the About page shows it and the path
-- stops asking.
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
  -- nl.last_rc is deliberately NOT written here. Two callers read it as the status of the
  -- last SPECTRUM run -- the demotion message, and the About page's rc= -- and both would
  -- otherwise read a ring record count, which is positive too and so reads as a run that
  -- went fine. This call's status goes to nat_why, which px_str shows beside nw=.
  local rc = nl.call_native(nl.entry)
  -- The record count and not just a non-negative status: the image reports what it wrote, so
  -- a short write is a refusal here rather than a picture nothing accounted for.
  if type(rc) ~= 'number' or rc ~= p.nrec then
    p.nat = false
    p.nat_why = 'rc=' .. nl.rc_name(rc) .. ' wanted ' .. tostring(p.nrec)
    return nil
  end
  p.natwrote = (p.natwrote or 0) + 1
  return rc
end

-- One frame. Returns the points drawn, or nil to leave the caller its append path.
--
-- tb and t are the caller's: the trace buffer and the one timestamp this frame may use. The
-- reserve-before-write discipline that keeps event 4924 off the glass lives in sg_fill, which
-- owns sg_stamp, and splitting it across two files is how a reservation comes to be recorded
-- after the write it was meant to cover.
function fftsa.nl.px_frame(db, hz, nseg, tb, t)
  local nl = fftsa.nl
  nl.rd_frame(t)
  local p = nl.px
  if p.nseg ~= nseg then
    return nl.px_dropframe('nseg moved from ' .. tostring(p.nseg) .. ' to ' .. tostring(nseg))
  end
  -- Whether this frame re-pointed, which decides which writer lays the block down: the x
  -- fields the re-point rewrote live outside the y triple and only the Lua writer carries
  -- them to the ring.
  local repointed = false
  if p.hz1 ~= hz[1] or p.hz2 ~= hz[2] then
    -- An FFT size change moves every column frequency and nothing else. Re-point the two x
    -- fields in place and keep drawing; drop only if something beyond the series moved.
    if not nl.px_repoint(hz, nseg) then
      local w = 'the frequency series moved under the slot map'
      if p.rp_why ~= nil then w = w .. ': ' .. tostring(p.rp_why) end
      return nl.px_dropframe(w)
    end
    repointed = true
  end
  local stride, nrec, lo = p.stride, p.nrec, p.lo
  -- The cursor, which says where the repaint's own append will land. Read rather than tracked:
  -- one memread of 24 bytes against a count that would drift silently if anything else ever
  -- appended.
  local h = ki.memread(hx(p.hdr), hx(24))
  if h == nil or string.len(h) < 24 then
    return nl.px_dropframe('header read gave ' .. tostring(h ~= nil and string.len(h) or 0))
  end
  -- THE WINDOW IS PUT BACK, every frame, before anything is written.
  --
  -- One append moves the task's window: count is already the whole pass, so oldest advances a
  -- record and the window slides onto slots the task has NEVER written -- 211 of the 721 in the
  -- ring are virgin, and one more would enter the drawn window every frame, to be drawn against
  -- an x pixel of zero. The trace would lose a column a frame to the left edge.
  --
  -- Putting them back immediately after the append does not work. The task consumes the staged
  -- record while the Lua thread is blocked, which may be during that very call or at the next
  -- one, so a restore written straight afterwards lands before the advance about half the time
  -- and is simply overwritten. Measured: 90 pixel frames, the window crept anyway, count
  -- reached 511. HERE it is deterministic -- a whole frame has passed, the task has certainly
  -- consumed, and the three words go back to what px_map validated.
  --
  -- The write cursor is parked one slot PAST the window on purpose. The record the append
  -- leaves there is never drawn, so its value cannot perturb the picture, and it is the one
  -- record in the ring this code never overwrites -- which is what makes it a clean place to
  -- read the firmware's own pixel back from and check the map against.
  -- This geometry's cursor offsets. The 6500's constants unless the candidate carried derived
  -- ones, which is what lets a model they were never measured on take the same frame path.
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
  -- THE MAP, CHECKED AGAINST THE FIRMWARE'S OWN ANSWER. The previous frame appended a decibel
  -- this code knows into a slot it knows, and the firmware wrote the pixel. Read it back before
  -- the block write covers it.
  if p.slot ~= nil and p.slotdb ~= nil then
    local pv = ki.memread(hx(lo + (p.slot - 1) * stride + p.yoff), hx(4))
    if pv ~= nil and string.len(pv) >= 4 then
      -- AGAINST EITHER PASS, because the display task lags a pass behind the appends: the
      -- pixel here is the firmware's answer for this frame's append or for the one before,
      -- and which it is cannot be read from the record. So both are tried and the smaller
      -- error stands. A map that is genuinely stale is out on BOTH; a lag is out on one.
      --
      -- Without this the check measured the spectrum instead of the map. Measured over 20 s
      -- with the path engaged: the firmware's own scale block at trace+0x140..0x1D0 did not
      -- move one word and the fitted map moved 0.0013 px a dB, while this reported 0.21 to
      -- 14.48 px frame to frame -- which is 1.86 px a dB times a noise floor wobbling a few
      -- dB a frame, and nothing to do with the map.
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
  -- THE RING WRITE, in the image where there is one: a multiply, a clamp and three stores per
  -- record, reading the decibels where dsp_reduce left them.
  --
  -- The Lua writer below is not a fallback nobody runs. It is what a build with no image
  -- uses, and it is the ONLY form that lays down a RE-POINTED series -- the x pixel and the x
  -- float sit in the held image's other two pieces and the ring write touches neither -- so a
  -- frame that re-pointed writes the whole block from here. That is also what keeps the held
  -- image's y pieces from going stale: they are refreshed by the one writer that reads them.
  local wrote = nil
  if not repointed then wrote = nl.px_write(nseg) end
  if wrote == nil then
    -- The decibels, decoded here because this is the only arm that reads them. An engaged
    -- frame never reaches it, which is the whole saving: the image writes the ring from the
    -- same array in the arena and the spectrum never passes through Lua.
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
  -- The repaint. At the frequency the cursor's slot already carries, so the firmware draws the
  -- point this code would have drawn there, and its pixel is next frame's check on the map.
  --
  -- Outside the window the appended record is never drawn, which is cleaner still -- the
  -- message is posted either way -- so any column will do and the one that exists is used.
  local slot = (wr - lo) / stride + 1
  local k = idx[slot]
  if k == nil then k = 1 end
  -- A CONSTANT DECIBEL, NOT THIS FRAME'S. The display task lags a pass behind the appends, so
  -- the pixel read back next frame can be the one the firmware wrote for an earlier append --
  -- and with a spectrum value there, "earlier" means a different decibel. Against a noise
  -- floor that moves a few dB a frame, at 1.86 px a dB, that is several pixels of pure signal
  -- noise, and the drift check read it as the map going stale.
  --
  -- Measured 2026-11-09 over 20 s with the path engaged: every word of the firmware's own
  -- scale block at trace+0x140..0x1D0 was CONSTANT and the fitted map moved by 0.0013 px a dB,
  -- while this check reported 0.21 to 14.48 px frame to frame. It was measuring the spectrum,
  -- not the map.
  --
  -- The first frame's value at this slot, kept: a real spectrum value, so it is inside the
  -- axis and can never be clamped, and the same one every frame after, so which append the
  -- firmware's pixel came from stops mattering.
  --
  -- THE CURSOR, NOT AN APPEND, when sg_pix_repaint says so.
  --
  -- The append exists only to make the display task repaint. It is also the one thing that
  -- MOVES the task's oldest-record cursor, and that is what makes the trace wrong: the widget
  -- draws in storage order and the x pixels are the firmware's, so a window starting at slot
  -- j runs x[j]..x[n] then x[1].. and the line doubles back across the plot. Measured on the
  -- glass at 8.72: correct about one frame in three. Restoring the cursor at the top of the
  -- next frame loses the race with the task.
  --
  -- display.graph.cursor sets a cursor position and is SYNCHRONOUS -- it waits for the GUI
  -- task to acknowledge -- so it is a repaint provocation that touches no record. The value is
  -- the firmware's own OFF sentinel for a cursor (notes/firmware/graph/GRAPH.md 4.5: "a value
  -- >= 9e37 switches that cursor off"), so it draws nothing and is a legal value rather than
  -- an out-of-range one, which on a graph parameter would be a modal dialog.
  --
  -- 9.9e37 and not 9e37, which is the threshold itself: a double rounded into a float32 can
  -- land either side of a bound it sits exactly on, and on the low side this is a cursor at
  -- 9e37 rather than a cursor switched off. 9.9e37 clears the test from above with the whole
  -- float32 range to spare, and it is the sentinel the rest of the app already uses.
  --
  -- With no append the ring's cursors never move, so there is no race to lose and nothing to
  -- restore. The drift check goes with it: it needs a pixel the firmware wrote for a decibel
  -- this code chose, and without an append there is no such pixel. What still guards the map
  -- is what identified the ring in the first place -- 510 exact float matches of the x field
  -- against this app's own axis.
  if fftsa.sg_pix_repaint == 'cursor' and p.gid ~= nil then
    -- Rate-limited when asked, which bounds how deep the task's repaint queue can get. The
    -- pixels for this pass are already in the ring, so a suppressed provocation shows them on
    -- the next one; what it does not do is add another request to a queue already too long.
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
      -- A REFUSAL IS NOT A REASON TO TEAR THE PATH DOWN. The pixels for this pass are already
      -- in the ring; what failed is the provocation to show them, so the glass keeps the
      -- previous picture for a frame and the next cursor shows both. Restarting instead costs
      -- a re-map and the frames of appending that go with it, and a transient refusal would
      -- then read as a frame rate that will not settle.
      --
      -- Only a RUN of them means the GUI is not going to answer, and that is worth a restart.
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
  --
  -- THE VALUE MUST BE THE ONE THE SLOT WOULD DRAW. A constant was tried here to steady the
  -- drift check below and it DREW: the parked record is outside the window this code restores,
  -- but the window the task draws from can include it for a frame, and a constant decibel at
  -- that frequency is then a visible wrong point with a line running back to it -- a wrap
  -- across the plot. Measured on the glass at 8.72.
  --
  -- So the append carries what the spectrum has there, and the lag is handled where it
  -- actually bites, in the check.
  -- THE APPEND MODE PAYS THE DECODE, all 255 values for the one it writes. It is kept only so
  -- the two repaint provocations can be compared on the glass without a rebuild, and 'cursor'
  -- is what ships -- so the cost sits where the comparison is made rather than in a one-value
  -- read path nothing else would use.
  db = nl.db_now(db)
  if db == nil then
    return nl.px_dropframe('the decibels did not decode for the repaint append')
  end
  buffer.write.reading(tb, db[k], hz[k], t, 0)
  p.slotprev, p.slot, p.slotdb = p.slotdb, slot, db[k]
  p.frames = (p.frames or 0) + 1
  return nseg
end

-- The cached geometry, in a global with the lifetime that suits it: the display task allocates
-- a ring per trace object, so the address holds for the life of the launch and a relaunch in
-- the same boot usually gets the same one back. px_map re-validates it from content before a
-- byte is written -- 721 exact float32 matches against the app's own axis -- so a stale cache
-- costs one ring read and falls through to the search.
-- WHERE THIS INSTRUMENT ACTUALLY PUTS THE RING, learned and kept across power cycles.
--
-- No address is in the tree and none could be: the file holds what a search already confirmed
-- on this machine, and anything read back out of it is validated by px_map -- 510 exact float32
-- matches of the x field against this app's own axis -- before a byte is written. A stale or
-- wrong file therefore costs one 28 KB read and falls through to the search, which is the same
-- cost as having no file at all.
--
-- Two things are kept. The exact geometry, which is worth trying directly and is usually
-- right across a relaunch. And the SPAN of every ring address ever confirmed, widened by each
-- new one, which is what survives the trace objects moving: the display task hands out a pool
-- of thirty, so the address varies between launches, and across this bench it has varied over
-- about 2 MB. The span plus PX_SEED_NEAR either side is the first window the ladder tries.
-- THE KEY FILE IS OFF BY DEFAULT, and it is off because of what it cost on the glass.
--
-- 8.80 shipped it on. io.open for read on a file that does not exist -- which is every first
-- launch -- POSTS event 2203, and a posted event is a modal dialog over the running app that
-- stops the frames and blocks the socket. pcall was no defence: the file API posts rather than
-- raises. Clearing it took a trip to the options screen and back.
--
-- The existence test is settled now -- the directory is listed rather than the file opened --
-- and the record is what makes a cold boot avoid scanning at all, which is the whole point. So
-- it is on. Still a live knob, so it can be taken out of the picture from the socket on one
-- boot rather than a rebuild.
fftsa.nl.PX_CACHE_KEY = true

-- ---------------------------------------------------------------------------
-- WHAT POINTS AT THE RING.
--
-- Operator's idea, 2026-11-13: "If we know where the data is, we can look for a pointer to it.
-- If that pointer is in a predictable place, we win."
--
-- It inverts the whole problem. Six launches put the ring at effectively random addresses
-- across a 15 MB band, so no window is narrow and every search costs ten frames or more. But
-- the ring is not floating free: the display task reached it somehow, so SOMETHING holds its
-- address. Find the words equal to it and one of them is that something.
--
-- What makes this worth doing now is the scan rate. A 4-byte needle over the measured span at
-- the rate the image manages since the step and word-compare went in is a fraction of a second,
-- spread over frames at the same budget the ring search uses.
--
-- This is an EXPERIMENT and it is off by default: it runs once per session when armed, after
-- the path has engaged and the ring address is therefore known and validated. The hits go to
-- the About page and to their own file on the key, so the addresses from several launches can
-- be compared -- a hit at the same address twice is a static location and the end of searching;
-- a hit at the same offset from inst, or from the object table, is nearly as good.
--
-- Nothing is read or written through anything it finds. It only records.
fftsa.nl.PX_PTRHUNT = false
-- Hits one level of the hunt may record. Twenty-four filled up on the first run and truncated
-- the scan at 53 MB, so the holders above that were never seen -- and the whole value of this
-- is comparing the full set between launches.
fftsa.nl.PTRHUNT_MAX = 96
fftsa.nl.PTRHUNT_FILE = '/usb1/FFTSA_PTR.txt'

-- WHICH ADDRESS TO HUNT, AND WHY IT IS NOT THE RING.
--
-- The chain the pointer route walks is known and three links long: the object table entry holds
-- the widget, the widget's array holds the trace objects, and the trace object holds the ring.
-- The last link is read on every engage -- px_from_name finds the name and walks forward to the
-- bounds pair, which IS the ring address. So hunting the ring would rediscover the link we
-- already have.
--
-- The broken link is the first one. This launch neither the handle's entry nor any of 256 ids
-- held a widget owning our trace, so the table is not being indexed the way the code assumes.
--
-- Hunting the TRACE OBJECT is what repairs that. A word equal to the trace object's address is
-- a slot in some widget's array, and the widget is then that address minus the array offset and
-- a slot -- which gives a widget address to hunt in turn, whose holder is the table entry. Two
-- hunts, and the second one yields base + id*stride + 0x50 directly: enough to say what the
-- real base and id are, or that the table is not how our graph is reached at all.
--
-- The ring is hunted too, second, because it costs one more pass and answers the operator's
-- original question -- whether anything outside the trace object holds it.
function fftsa.nl.px_hunt_target()
  local nl = fftsa.nl
  local p = nl.px
  -- The trace object, from the name hit that found it: the name sits at a known offset inside
  -- the object, so the object's base is the hit minus that offset.
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
  -- The target moved under us, so the hits collected so far are about a different address.
  if nl.ph_ring ~= want then
    nl.ph_at, nl.ph_hits, nl.ph_n, nl.ph_ring = mlo, {}, 0, want
    nl.ph_kind = kind
  end
  -- One slice a frame, the same budget the ring search uses, and the same read accounting.
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
      -- Not inside the ring's own storage: a record that happened to hold the base would
      -- answer here and mean nothing.
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
    -- Level one was the trace object; level two is the ring, which answers whether anything
    -- outside the trace object holds it. After that there is nothing further to ask here.
    if nl.ph_level ~= 2 then
      nl.ph_level, nl.ph_at = 2, nil
    else
      nl.ph_done = true
    end
  end
end

-- Appended, not overwritten: the whole point is comparing launches.
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

-- WHERE TO LOOK FIRST ON AN INSTRUMENT THAT HAS NEVER TOLD US is not a compiled-in address.
--
-- It was two, the span this bench's ring had occupied -- 0x3600000 to 0x3800000 -- allowed
-- under the operator's rule that a start address may be compiled in as long as being wrong
-- costs "a small bit of performance. Never correctness." They are gone because px_inst_win
-- does the same job better: it is derived from the trace buffer's own instance every launch,
-- so it holds on a machine this bench has never seen, needs no exception to the no-firmware-
-- addresses rule, and is 3 MB rather than 2 MB of guess plus the whole ladder behind it.
--
-- So the span below is this instrument's own record and nothing else. With no record, there is
-- no span, and the instance window is the first thing tried.

-- The learned span, as the two numbers that bound it.
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

-- What this instrument has actually confirmed. The same numbers as px_seed_span, under the
-- name the window ladder and the key file use, so that "learned" stays a distinct idea from
-- "derived": the span is a record of past answers and px_inst_win is a measurement of this
-- launch.
function fftsa.nl.px_seed_learned()
  return fftsa.nl.px_seed_span()
end

-- Widen it with a ring that has just been confirmed.
function fftsa.nl.px_seed_note(lo)
  if type(lo) ~= 'number' or lo <= 0 then return end
  local a, b = fftsa.nl.px_seed_learned()
  if a == nil then a, b = lo, lo end
  if lo < a then a = lo end
  if lo > b then b = lo end
  FFTSA_PXSEED = string.format('%d,%d', a, b)
end

-- Eight numbers on one line: the six of the geometry then the two of the span. Read back with
-- gfind rather than a read format, because the only read form this firmware is known to take
-- is a byte count.
function fftsa.nl.px_cache_save()
  local nl = fftsa.nl
  if not nl.PX_CACHE_KEY then return false end
  -- LEARNED only. Writing the built-in hint to the key would promote a guess about an unknown
  -- machine into this machine's own record, and the next boot would read it back as fact.
  local a, b = nl.px_seed_learned()
  if type(FFTSA_PXRING) ~= 'string' or a == nil then return false end
  local body = FFTSA_PXRING .. ',' .. tostring(a) .. ',' .. tostring(b) .. '\n'
  -- Written only when it changed. A confirmed geometry is re-put on every engage and the key
  -- is flash.
  if body == nl._px_saved then return false end
  local ok = pcall(function()
    -- The one file.* call that is documented to work, and the key can be out of the slot: a
    -- write with no key posts event 2203 over the running app.
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

-- Once per launch, and only into globals that are absent: a relaunch in the same boot already
-- has better information in memory than the file can hold.
function fftsa.nl.px_cache_load()
  local nl = fftsa.nl
  if nl._px_loaded then return false end
  nl._px_loaded = true
  if not nl.PX_CACHE_KEY then return false end
  local got = false
  pcall(function()
    -- OPENING A FILE THAT IS NOT THERE POSTS 2203 ON THE GLASS, and the first launch on any
    -- instrument is exactly that case: there is no record to read until one has been written.
    -- pcall is no defence, because the file API posts rather than raises -- so the existence
    -- has to be settled without an open.
    --
    -- fs.readdir on a directory that exists costs no events, which is why it is the test here
    -- and fs.is_file is not: is_file on an absent path is unmeasured, and the whole point is
    -- to not find out the expensive way. The table is 0-BASED, so pairs and not getn.
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
  -- No value offset: px_map derives that from the ring every time, so caching it would be
  -- storing a number nothing reads against the chance of it being wrong.
  return { lo = f[1], hi = f[2], nrec = f[3], stride = f[4], ox = f[5], hdr = f[6] }
end

-- The whole path, driven one frame at a time. Returns the points drawn, or nil when the
-- caller still has to append.
-- gid is the app's OBJ_GRAPH display handle, and the buffer is the trace buffer. Both are
-- the caller's to supply: they are what the pointer route needs and this module has no way
-- to know either. Passed every call rather than stashed once, so a relaunch's new handle
-- arrives without anything having to invalidate the old one.
function fftsa.nl.px_try(db, hz, nseg, tb, t, gid)
  local nl = fftsa.nl
  nl.rd_frame(t)
  local p = nl.px
  local st = p.state
  -- The launch clock, and the frames spent not yet drawing. Both are the module's, so a
  -- restart does not reset them: the figure wanted is from the first frame of the app.
  if nl.t_first == nil then nl.t_first = os.clock() end
  if st ~= 'on' then nl.pre_frames = (nl.pre_frames or 0) + 1 end
  if st == 'off' then return nil end
  if type(gid) == 'number' then
    -- A handle that has changed takes the derived base with it: the table is indexed by id,
    -- so an entry read at the wrong one is some other object.
    if p.gid ~= nil and p.gid ~= gid then
      nl.px_objbase = nil
      -- And the walk is worth repeating: a new handle means the objects behind the table
      -- changed, which is the one event that can put this app's trace under a different entry.
      p.objdone, p.objscan = nil, 0
    end
    p.gid = gid
  end
  if st == 'on' then return nl.px_frame(db, hz, nseg, tb, t) end
  if nseg == nil or nseg < 8 then return nil end
  if st == 'idle' then
    -- The hold, counted in frames that have appended: px_try runs after the fill, so one call
    -- is one pass of appends through the ring. Until it is spent, every frame appends and
    -- nothing is mapped -- which is what puts the values and the pixels back in step.
    if (p.hold or 0) > 0 then
      p.hold = p.hold - 1
      return nil
    end
    -- The key's record, once per launch: a power cycle loses every global, and without this
    -- the first search of a boot starts at the bottom of the ladder with nothing learned.
    pcall(nl.px_cache_load)
    -- THE CACHE GETS MORE THAN ONE FRAME, and that is the difference between a relaunch
    -- engaging at once and sweeping tens of megabytes.
    --
    -- px_map requires every slot of the drawn window to carry a frequency this plan has. On a
    -- relaunch the trace object has only just been created, so the ring holds nothing of this
    -- plan until the appends have been through it -- and the display task lags a pass behind
    -- those. So the cached geometry is certain to fail on the first frame, whether or not it is
    -- still the right address. Trying it once and dropping to the sweep threw away the one
    -- answer that costs no reading: measured on the glass, a relaunch took 20 seconds and
    -- about 50 MB to find a ring the cache could have named.
    --
    -- A retry is one window read and a slot walk, and the fill below is running the whole time,
    -- so each attempt is better informed than the last.
    -- THE POINTER FIRST, THEN THE CACHE, AND NEITHER COSTS A SCAN.
    --
    -- px_from_ptr is three guarded reads per table base and the bases are the one this
    -- instrument confirmed and the compiled hint. The cached geometry is one window read. Both
    -- are name-validated on the way through, and both are worth retrying for a few frames
    -- rather than once, because px_map needs the ring to hold THIS plan's frequencies and on
    -- the frame after a relaunch it cannot: the trace object has only just been created and the
    -- display task lags a pass behind the appends that fill it.
    --
    -- Only when both have been given their frames does the sweep start. That is the difference
    -- between engaging in three frames and scanning tens of megabytes, measured as 35 to 45
    -- seconds on the glass at 2048 points.
    local tried = false
    local cands, nc = {}, 0
    -- THE SUBSCRIBER TABLE FIRST, because it needs nothing from this app but the buffer name it
    -- chose, and it reaches the trace in one 64 KB read and three dereferences that each confirm
    -- another. It does not need the display handle, which is what every other pointer route has
    -- waited on and what has never been the table index.
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
      -- The pointer route reports bounds and a header but never looked at a record, so the x
      -- field is px_map's to derive. The cache carries one and px_map keeps it.
      if cands[ci].from == 'ptr' or cands[ci].from == 'sub' then g.ox = nil end
      if nl.px_map(g, hz, nseg) then
        p.state = 'on'
        nl.px_engaged()
        p.from = cands[ci].from
        -- PROVEN ONLY WHEN IT HAS DRAWN. This retires the sweep for the session, so setting it
        -- where the chain merely produced geometry let a candidate that never mapped retire it:
        -- a freed trace keeps its name AND its back-pointers, so a corpse pair can be
        -- self-consistent and yield plausible geometry. px_map refusing a zeroed ring is what
        -- separates them, so this belongs on the far side of px_map and nowhere earlier.
        if cands[ci].from == 'sub' then nl.px_subok = true end
        if g.name_at ~= nil then p.needle = 'name' end
        nl.px_ptr_ok()
        nl.px_cache_put(g)
        return nl.px_frame(db, hz, nseg, tb, t)
      end
    end
    -- AND THE SEARCH RUNS IN THE SAME FRAMES, which is the difference between adding these
    -- costs up and overlapping them.
    --
    -- The cheap routes are worth several frames each: the cached geometry because px_map needs
    -- the ring to hold this plan's frequencies and cannot on the frame after a relaunch, and
    -- the table walk because it is more entries than a frame's reads. But they were spent
    -- BEFORE the search started, so their frames were pure latency when they failed.
    --
    -- Measured on the glass at 9.07: eng=4.2s/23f, of which about eight frames were a table
    -- walk that ran all 256 entries and found nothing, then eleven were the search. Nothing
    -- about them conflicts -- the walk spends the read allowance, the search spends the image's
    -- own byte budget, and both are already bounded per frame -- so `st` falls through to the
    -- seek arm below rather than returning, and p.state stays 'idle' so the cheap routes are
    -- retried next frame. Whichever answers first wins, and neither waits for the other.
    if tried then
      p.cachetries = (p.cachetries or 0) + 1
      if p.cachetries < nl.PX_CACHE_TRIES then st = 'seek' end
    elseif p.gid ~= nil and nl.PX_PTR ~= false and not p.objdone then
      -- THE TABLE WALK IS MID-FLIGHT, SO LET IT FINISH.
      --
      -- px_from_ptr walks the whole (base, id) space with a cursor kept across frames, because
      -- 128 entries at a few guarded reads each is more than one frame's allowance. But `tried`
      -- is only true when a candidate already EXISTS, so a clean start -- no cached geometry,
      -- and the walk not yet at the right entry -- fell straight through to the search on the
      -- FIRST frame. The resumable walk got exactly one frame and its cursor was then never
      -- looked at again.
      --
      -- Measured on the glass at 9.06: eng=11.6s/72f, swept=41MB, window 12 of 17, and
      -- ptrwhy='trace slot 1 of the widget is 0, and none before it carried the name' -- the
      -- handle's entry was the wrong widget, which is the case the walk exists for.
      --
      -- Guarded on the route EXISTING, not just on the walk being unfinished. Without a
      -- display handle px_from_ptr is never called, so the walk can never start and never
      -- finish -- and holding on "not finished" held for ever. The offline suite drives px_try
      -- with no handle, which is exactly that case, and caught it.
      --
      -- A walk still owing entries means the frame is spent on them. The
      -- whole walk is a few hundred reads against a search that was sweeping tens of
      -- megabytes, and when it answers it answers with no scanning at all -- and the base it
      -- finds is remembered and written to the key, so later launches skip even the walk.
      st = 'seek'
    end
    if st ~= 'seek' then
      -- Both cheap routes are spent, so this is the search's state from here on.
      p.state = 'seek'
      st = 'seek'
    end
  end
  if st == 'seek' then
    -- THE LUA RING SWEEP IS ABANDONED, by decision on 2026-11-11: unusably slow and it will
    -- never ship. 25 MB/s over ki.memread is 800 frames for one pass of the backstop, and a
    -- day of tuning its ladder, hints and caps never made the time to engage predictable.
    --
    -- So engagement is the pointer route or the cached geometry, both of which dereference a
    -- handful of addresses and scan nothing. If neither answers, the path does not engage and
    -- the fill below appends -- correct, and only slower. The sweep below stays in the file
    -- because the bind-time descriptor discovery shares it; nothing in the pixel path calls it.
    -- NATIVE OR NOTHING. The Lua sweep is abandoned, so if the image cannot search -- no
    -- install, or no span of proven memory to search in -- the path switches off and the fill
    -- appends. That is correct and only slower, and it is the honest answer rather than
    -- eighty seconds of scanning.
    -- NOT OFF -- RETRY. Measured on the glass: px_from_ptr answers correctly once the app is
    -- warm (base 0x00D178A0, id 52, ring 0x03680BD0, twelve live addresses) and refuses on the
    -- first frames, because px_live needs a span of already-dereferenced addresses and there
    -- are not yet enough of them. Switching the path off for the session over that threw away
    -- a route that was about to work: the app ran the whole session on the append path with
    -- why='no pointer and no usable cache'.
    --
    -- So the span is dropped and re-derived -- it is a few reads, and it widens as the app
    -- allocates -- and the path goes back to idle to try the pointer again next frame.
    -- THE SUBSCRIBER SLOT BEFORE THE SEARCH'S READINESS GATE, because it needs none of what
    -- that gate waits for.
    --
    -- Below, a frame with no native image returns px_wait and never reaches px_seek -- so the
    -- route that walks three pointers from a static table was being held behind the reattach of
    -- an image it does not use. Measured on the glass at 9.18: via=sub engaged, correctly, after
    -- sixteen frames and 10 MB of scanning, with the slot and the trace both right from the
    -- start. The scanning was not how it was found; it was what it was waiting behind.
    do
      local bysub = nl.px_from_bufsub()
      if table.getn(bysub) > 0 then
        p.via = 'sub'
        p.cands, p.state = bysub, 'hdr'
        p.ncand = (p.ncand or 0) + table.getn(bysub)
        return nil
      end
      -- AND IF THE SLOT IS KNOWN, DO NOT SWEEP. Waiting is the whole answer here.
      --
      -- A slot that reads as a live graph trace is the firmware's own statement of where this
      -- app's trace object is. If the chain behind it has not yielded geometry yet, the reason
      -- is in sub_why and it is always the same one: the ring has no records in it, because the
      -- appends have not been through it. Scanning DRAM cannot make that true sooner, and
      -- whatever it finds is the same object.
      --
      -- Measured on the glass at 9.19, clean boot: eng=2.9s/17f with last=1.2s/5f and
      -- swept=10MB/0pass. The pass that engaged swept NOTHING -- the route answered with no
      -- scanning at all -- and the 10 MB was spent in the frames before the last rebind, on an
      -- object that was then freed. re=5, the reasons reading "the drawn window moved from
      -- 368C938+510 to 368C938+59" after "traces rebound": the app rebinds its traces while it
      -- builds its screens, so the search was racing a target that kept moving and every
      -- megabyte of it was discarded.
      --
      -- Bounded, because "wait for a ring that never fills" must not be forever: after
      -- PX_SUB_WAIT frames the sweep runs anyway, which is what a build whose slot means
      -- something else would need.
      if nl.px_subslot ~= nil then
        p.subwait = (p.subwait or 0) + 1
        -- NO BOUND ONCE THE ROUTE HAS ANSWERED. The bound exists for a build where a slot
        -- reads as a live graph trace and the chain behind it means something else -- on an
        -- instrument where the chain has closed, waiting is strictly better than sweeping,
        -- because whatever a sweep finds is the object the slot already names. This is what
        -- makes "no scans once it is in fast mode" hold across a drop and not just while
        -- engaged: a rebind sends the path back to idle, and from there it walks the slot
        -- again rather than searching.
        if nl.px_subok or p.subwait <= nl.PX_SUB_WAIT then
          return nl.px_wait('the subscriber slot is known, waiting for its ring: '
                            .. tostring(nl.sub_why))
        end
      end
    end
    local mlo = nl.map_bounds()
    if not ((nl.NFIND and mlo ~= nil and nl.ready) or nl.PX_SWEEP) then
      -- No search available. Retry the POINTER rather than giving up: it answers once the app
      -- is warm, and the span px_live needs widens as the app allocates. The span is dropped
      -- so it is re-derived from whatever is live now.
      nl.map_lo, nl.map_hi = nil, nil
      p.ptrtries = (p.ptrtries or 0) + 1
      if p.ptrtries < nl.PX_PTR_TRIES then
        return nl.px_wait('no pointer yet, try ' .. tostring(p.ptrtries))
      end
      -- AND IT DOES NOT GIVE UP, because what it is waiting for arrives late.
      --
      -- This switched the path off for the session after PX_PTR_TRIES frames. Measured on the
      -- glass at 8.96: px=off, re=33, why='no pointer, no cache, and no native search' -- and
      -- on the SAME diagnostic line, ready=true with a live entry. The image was installed and
      -- the span derived fine (no reason appended, so map_why was nil); both simply became
      -- true after the thirty frames this had already spent. The path was off for a session
      -- whose search was available the whole time bar the first second.
      --
      -- Thirty frames is a guess about how long the app takes to warm up. Switching off
      -- permanently on a guess is the one thing that cannot be recovered from, and staying
      -- idle costs three guarded reads a frame and a fill that appends -- which is what the
      -- app did for its whole life before this path existed. So it keeps trying, and the
      -- counter becomes a report rather than a deadline.
      p.ptrcap = (p.ptrcap or 0) + 1
      local w = 'no pointer, no cache, and no native search yet, waiting '
                .. tostring(p.ptrtries)
      if nl.map_why ~= nil then w = w .. ': ' .. tostring(nl.map_why) end
      return nl.px_wait(w)
    end
    nl.FINDS_NATIVE_ONLY = not nl.PX_SWEEP
    -- Timed, so the next slice is sized by what this one cost rather than by what a Lua read
    -- would have cost. The bytes are the image's own report of what it scanned.
    local b0, s0 = nl._nf_bytes or 0, nl._nf_secs or 0
    local c = nl.px_seek(hz, nseg, nl.px_budget(), tb)
    nl.px_nb_note((nl._nf_bytes or 0) - b0, (nl._nf_secs or 0) - s0)
    nl.FINDS_NATIVE_ONLY = false
    if c == nil then
      -- Not off for the session, for the same reason as the gate above: a refusal here is the
      -- image having no find block reserved or no span to search, and on a run that REATTACHED
      -- to the install a previous launch made -- one install per boot -- those arrive when the
      -- reattach finishes, not when the first frame runs.
      p.nrefuse = (p.nrefuse or 0) + 1
      return nl.px_restart('the native search refused: ' .. tostring(nl.find_why))
    end
    if c == nil or table.getn(c) == 0 then return nil end
    p.cands, p.state = c, 'hdr'
    p.ncand = (p.ncand or 0) + table.getn(c)
    return nil
  end
  -- ONE HEADER SEARCH A FRAME, and every candidate gets one.
  --
  -- The header is what tells the trace ring from the 28-byte staging ring, which holds the same
  -- two float32 pairs in the same order and so confirms a stride just as well. It is a bounded
  -- scan of a few hundred kilobytes, which is a frame's worth on its own -- so the candidates
  -- are worked through one per frame rather than all in the frame that found them.
  if st == 'hdr' then
    local c = p.cands
    if c == nil or table.getn(c) == 0 then
      p.cands, p.state = nil, 'seek'
      return nil
    end
    local g = c[table.getn(c)]
    table.remove(c)
    -- A name-derived geometry already has its bounds and its header; only the record route
    -- has to go looking for one.
    -- Which needle this candidate came from. px_from_name stamps name_at; the frequency
    -- route does not. Reported, because "engaged on the name" and "engaged on the
    -- frequencies" are different confidences in the same answer.
    p.needle = 'freq'
    if g.name_at ~= nil then p.needle = 'name' end
    if g.hdr ~= nil and g.lo ~= nil then
      g.ox = nil
      p.g, p.state, p.maptries = g, 'map', 0
      return nil
    end
    if nl.find_ring_header(g) ~= nil then
      -- val0 is the x field, so the offset the header check measured for it IS the x offset.
      -- The value field is not needed here and px_map derives it.
      g.ox = math.mod(g.val0 - g.lo, g.stride)
      p.g, p.state, p.maptries = g, 'map', 0
    else
      p.why = 'header: ' .. tostring(nl.ring_why)
    end
    return nil
  end
  if st == 'map' then
    -- THE CURSOR OFFSETS, BY CAUSE, before anything is mapped or written.
    --
    -- A candidate from a deriving model arrives with its count offset and a list of cursor
    -- pairs that fit the shape, because shape cannot separate the two cursors -- measured
    -- against the 6500, four pairs fit. What separates them is what each one DOES when a
    -- reading is appended, and the fill is appending on every one of these frames.
    --
    -- Spent here rather than in px_from_name because it needs two frames, and this state
    -- already has frames to spend: the map cannot be fitted until the ring holds this plan's
    -- frequencies anyway.
    if p.g ~= nil and p.g.h_pairs ~= nil and p.g.h_old == nil then
      if nl.px_hdr_resolve(p.g) then
        p.maptries, p.hdrtries = 0, 0
        return nil
      end
      p.hdrtries = (p.hdrtries or 0) + 1
      if p.hdrtries >= nl.PX_HDR_TRIES then
        -- The ring is not saying which word is which. Nothing is written on a guess, so this
        -- candidate is abandoned and the next one gets its turn.
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
      -- The candidate confirmed a stride and carried a header and still will not map, so it is
      -- not this trace's ring. The other candidates from the same slice get their turn before
      -- the sweep carries on from where it stopped.
      p.g, p.state = nil, 'hdr'
    end
    return nil
  end
  return nil
end

-- The state as one field for the error and About pages.
function fftsa.nl.px_str()
  local nl = fftsa.nl
  local p = nl.px
  local o = 'px=' .. tostring(p.state)
  -- WHICH PATH IS IN FORCE, UNCONDITIONALLY, and that is the point of it being here.
  --
  -- Everything below that describes a candidate is gated on there being one. On the model this
  -- was written for there always is, so it never mattered; on a model where the path never
  -- engages, every one of those fields is absent and the page says nothing about why -- which
  -- is exactly the case that cannot be debugged any other way. An operator on a DMM7510 can
  -- only send back what is on the glass.
  --
  -- So the configuration comes first and always: the model the module decided it is, whether
  -- the pointer route is available, whether the offsets are being derived, and whether the
  -- caller is arming the path at all. A 7510 report that opens 'px=off m=7510 ptr=0 der=1
  -- arm=1' has already answered four questions.
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
    -- Not engaged yet: how long it has been trying, which is the figure to read while it is
    -- still going rather than after it gives up.
    o = o .. string.format(' trying=%.1fs/%df',
                           os.clock() - (nl.t_first or os.clock()), nl.pre_frames)
  end
  -- WHY THE KEY'S RECORD DID NOT SHORTEN THE SEARCH, which is the question eng= raises and
  -- cannot answer on its own. The geometry on the key is what turns a 72 MB sweep into a
  -- read, so a slow engage is either a record that was not there or one that was not
  -- believed, and those are different faults. The load reason is kept apart from the save
  -- reason because a save that succeeds afterwards would otherwise erase why the load missed.
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
  -- Repaints suppressed by the rate limit, so the knob's effect is readable on the glass.
  if p.rpskip ~= nil then o = o .. ' rpskip=' .. tostring(p.rpskip) end
  -- WHICH WRITER IS LAYING THE RING DOWN, and why it is not the image's. The two draw the
  -- same picture at very different costs -- one call against 28 KB assembled in Lua -- so a
  -- frame rate that does not match the build is read off this field first.
  if p.nat and not nl.PX_NATIVE then
    o = o .. ' nw=off'
  elseif p.nat then
    o = o .. ' nw=' .. tostring(p.natwrote or 0)
  elseif p.nat_why ~= nil then
    o = o .. ' nw=0/' .. tostring(p.nat_why)
  end
  if p.from ~= nil then o = o .. ' via=' .. tostring(p.from) end
  -- The derived table base, and why it is absent. This is the figure that turns a sweep per
  -- launch into three reads, so whether it was derived is the thing to read off the glass.
  if nl.px_objbase ~= nil then
    o = o .. ' obj=' .. hx(nl.px_objbase) .. '+' .. tostring(nl.px_objid) .. 'x'
        .. tostring(nl.PX_OBJ_STRIDE)
    if nl.px_objfound ~= nil then o = o .. '[' .. tostring(nl.px_objfound) .. ']' end
  end
  if p.gid ~= nil then o = o .. ' gid=' .. tostring(p.gid) end
  if p.ptr_lost ~= nil then o = o .. ' ptrlost=' .. tostring(p.ptr_lost) end
  -- WHY THE POINTER ROUTE ANSWERED NOTHING. It is O(1) and independent of where the ring
  -- sits, so when it works the search never runs; when it does not, the page has to say which
  -- step gave up. Absent obj= with no reason beside it cost a day of looking at the search.
  if nl.px_objbase == nil and nl.ptr_why ~= nil then
    o = o .. ' ptrwhy=' .. tostring(nl.ptr_why)
    -- How far the table walk got. Zero after a walk that found nothing means it finished and
    -- the table really has no entry owning this app's trace; a number mid-range means it is
    -- still going, which is a completely different thing to read off the glass.
    o = o .. ' objscan=' .. tostring(p.objscan or 0) .. '/'
        .. tostring(table.getn(nl.px_bases()) * nl.PX_OBJ_SCAN)
  end
  o = o .. ' ' .. nl.rd_str()
  -- Unconditional, both of them. A path that never engaged is the case that needs these most:
  -- how far the search got, and whether the window it is in is the instance band or the
  -- backstop. Without the window there is no telling a search still working through a narrow
  -- band from one that has fallen through to 268 MB.
  -- THE SESSION'S TOTAL AND THIS PASS'S, as two figures. swept is cumulative across restarts,
  -- which is what made 34 MB look like a search problem when the ladder had been thrown away
  -- four times -- and worse, what condemned the name needle on the first slice of every later
  -- pass. A reader cannot tell those apart from one number.
  o = o .. ' swept=' .. tostring(math.floor((p.swept or 0) / 1048576)) .. 'MB'
  o = o .. '/' .. tostring(math.floor((p.sweptpass or 0) / 1048576)) .. 'pass'
  if p.wins ~= nil and p.wi ~= nil then
    local w = p.wins[p.wi]
    o = o .. ' win=' .. tostring(p.wi) .. '/' .. tostring(table.getn(p.wins))
    if w ~= nil then
      o = o .. '[' .. hx(w[1]) .. '+' .. tostring(math.floor((w[2] - w[1]) / 1048576)) .. 'MB]'
    end
    if p.at ~= nil then o = o .. ' at=' .. hx(p.at) end
    -- WHERE THE INSTANCE BAND ACTUALLY IS IN THE LADDER THIS LAUNCH BUILT, and where the ring
    -- turned out to be relative to inst. Three launches were spent inferring both from win= and
    -- an address, and the inference was wrong at least once: the ladder is ordered to put the
    -- band third, and the only way to know it did is to read it off the instrument.
    --
    -- Printed as the band's positions and the ring's offset in megabytes, so "the band was
    -- never in the ladder", "the band was there and the ring was not in it" and "the band was
    -- there, held the ring, and was swept too early" are three different lines rather than
    -- three readings of the same one.
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
  -- THE SUBSCRIBER ROUTE, ALWAYS, because it is the route that should make the search
  -- unnecessary and a path that fell back to scanning has to say why it could not use it.
  o = o .. ' sub='
  if nl.px_subslot ~= nil then
    o = o .. hx(nl.px_subslot)
    if nl.sub_trace ~= nil then o = o .. '>' .. hx(nl.sub_trace) end
  else
    o = o .. '0'
  end
  if nl.sub_hits ~= nil then o = o .. '/' .. tostring(nl.sub_hits) .. 'hit' end
  if (nl.sub_tries or 0) > 0 then o = o .. '/' .. tostring(nl.sub_tries) .. 'try' end
  -- The live reason, or the last one that stood before it engaged. A route that succeeded on
  -- its fifteenth attempt has to be able to say what the first fourteen were waiting for.
  -- /chain means the chain closed and handed over geometry. /mapped means px_map accepted it
  -- and the path drew. They are different claims and a report that conflates them says the
  -- route worked on a launch where the frequencies never matched.
  if nl.px.from == 'sub' or nl.px.via == 'sub' then o = o .. '/chain' end
  if nl.px_subok then o = o .. '/mapped' end
  -- WHICH PROFILE AND WHICH WINDOW. A 7510 report reading 0hit cannot otherwise show that the
  -- 7510 window was the one actually read.
  o = o .. ' subcfg=' .. tostring(nl.sub_profile or '?') .. '@' .. hx(nl.PX_SUB_LO)
      .. '+' .. tostring(math.floor(nl.PX_SUB_BYTES / 1024)) .. 'KB'
  -- And what the read actually returned, because a short read with no hits and a full read with
  -- no hits are different findings.
  -- Against the window ACTUALLY READ. A ladder window is 1 MB and the compiled one 64 KB, so
  -- comparing every read against the compiled size reported each full ladder read as short --
  -- in the one line whose job is to say whether the read was complete.
  if nl.sub_len ~= nil and nl.sub_want ~= nil and nl.sub_len ~= nl.sub_want then
    o = o .. ' short=' .. tostring(nl.sub_len) .. '/' .. tostring(nl.sub_want)
  end
  -- And whether THIS window hit the cap, not whether the launch's running total has passed it.
  if nl.sub_wincap then o = o .. ' hitcap' end
  if nl.sub_loose then o = o .. ' loosekind' end
  -- WHAT A REPORT FROM A MODEL THIS HAS NEVER RUN ON HAS TO CARRY. Where it looked, what it
  -- found, which offsets it ended up using, and -- if the name was there but no slot was -- the
  -- pointer-like words around the first hit, which is what settles the layout without another
  -- run. The 6500's whole layout came out of one grab by exactly this arithmetic.
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
  -- Hits and candidates, because without them a search that finds the ring and rejects it
  -- reads exactly like a search that never reached it. That is how the staging-ring stride
  -- came to look like 981 MB of absence.
  if p.hits ~= nil then o = o .. ' hit=' .. tostring(p.hits) end
  if p.ncand ~= nil then o = o .. ' cand=' .. tostring(p.ncand) end
  if p.cands ~= nil then o = o .. '/' .. tostring(table.getn(p.cands)) .. 'left' end
  if p.degen ~= nil then o = o .. ' flat=' .. tostring(p.degen) end
  if p.lastdrift ~= nil then o = o .. string.format(' d=%.1f', p.lastdrift) end
  -- THE NAME, which is the first question on a new model: if this app's buffer name is not in
  -- memory the trace object is not laid out as assumed and nothing downstream can work. Zero
  -- hits with a swept figure behind it is a completely different fault from hits that are all
  -- rejected, and the two read identically without this.
  -- THIS PASS'S HITS AND THE SESSION'S, as two figures. One number cannot say whether the
  -- needle was condemned by what this pass found or by what earlier passes did, and that is the
  -- distinction that cost ten seconds to engage: nh=69 across four passes read as a pass that
  -- had had its chances, when no pass had seen more than about seventeen.
  if p.namehits ~= nil then o = o .. ' nh=' .. tostring(p.namehits) end
  if (p.nhall or 0) > 0 then o = o .. '/' .. tostring(p.nhall) .. 'all' end
  if p.namedead ~= nil then o = o .. ' namedead=' .. tostring(p.namedead) end
  if p.noname then o = o .. ' noname=1' end
  -- The cursor-offset derivation, ALWAYS, because on a deriving model this is the mechanism
  -- most likely to be what stopped. agree/differ/resolved, then what the last one was waiting
  -- for, then how many cursor pairs the candidate in hand still has in play.
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
    -- NAMED, because this is the refusal a layout change is relied on to produce. Both
    -- numbers go in it: a pair that disagrees is a Lua from one build meeting an image from
    -- another, which inside one power cycle is what re-attaching across an install looks
    -- like, and "write_params refused" alone would send the reader to the wrong place.
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
    -- The image writes the line of dsp_native.c that refused into fail_at. Written here as
    -- well, and zero, because that is what keeps a line from the PREVIOUS call being read as
    -- this one's; a caller has no reason to set it.
    t.fail_at or 0,
    -- The find block, for DSPN_MODE_FIND. A pointer and not the block itself: the block is
    -- forty-two words of search state and this struct is packed on every frame, most of which
    -- do no searching. Zero when the caller has none, which the image treats as a refusal
    -- rather than reading address zero.
    t.find_addr or 0,
    -- And the graph ring block, for DSPN_MODE_PX. Addressed for the same reason, and with a
    -- stronger one: nothing in it changes from frame to frame, so a frame that draws writes
    -- the mode and calls.
    t.px_addr or 0,
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
    return false, r
  end
  return true
end

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
    return nil, why
  end
  if nl.params == nil or nl.params == 0 then return refuse('no params') end
  if nl.STATUS_OFF == nil or nl.STATUS_OFF == 0 then return refuse('no status offset') end
  local ok, err = via_peek8(addr)
  if not ok then return nil, err end
  local s = ki.memread(hx(nl.params + nl.STATUS_OFF), hx(4))
  if s == nil or string.len(s) < 4 then return refuse('status unreadable') end
  -- WHICH test refused, read before the code is interpreted so it is kept even on the
  -- paths that return early below. A status code names the stage; the line names the test.
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

-- Put ki.peek8 back. Refuses rather than writing a value that is not a .text address:
-- a restore that writes garbage is worse than no restore, because the closure still
-- works until something calls it.
--
-- The app never calls this. The redirect is meant to outlive a run -- a relaunch re-attaches
-- to the installed code rather than installing it again, which is the only route a second
-- launch in one boot has -- so undoing it at teardown would break the next launch. This is
-- the manual undo, for a socket session that wants the interpreter's own peek8 back.
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

  -- WHICH MODEL'S PIXEL PATH. Settled here, once, because this is the one entry point the app
  -- calls at start and the model cannot change under a running app.
  --
  -- A DMM6500 keeps the mechanism that works there: the measured cursor offsets, and the
  -- pointer route through the GUI object table. A DMM7510 has neither -- its object is a
  -- different size and its table is not in reach of the scan that found the 6500's -- so it
  -- takes the name route with the offsets derived, which is the one route whose every other
  -- term is already searched for rather than assumed.
  --
  -- The shadow check runs on both. On a 6500 it compares the derivation against the known
  -- constants with nothing depending on the result, which is how the derivation earns the right
  -- to replace them.
  nl.model_7510 = false
  if localnode ~= nil and localnode.model ~= nil then
    nl.model_7510 = string.find(tostring(localnode.model), '7510', 1, true) ~= nil
  end
  nl.PX_HDR_DERIVE = nl.model_7510
  nl.PX_PTR = not nl.model_7510
  -- EVERY DMM6500 FIGURE IS MEASURED; EVERY DMM7510 FIGURE IS UNKNOWN. So the 6500 uses the
  -- compiled offsets and the compiled kind and nothing else, and another model is allowed to
  -- derive both -- the chain still has to close on this app's own buffer name and px_map still
  -- has to match 510 frequencies, so a wrong derivation costs reads and never correctness.
  -- The window is per model and measured on both. The three fallbacks below stay ON for a
  -- 7510 and OFF for a 6500: on the 6500 every figure is confirmed on the glass, so a
  -- derivation could only be slower or less certain, while on a model nobody can measure they
  -- are what turns "the compiled window moved in a later build" from a dead route into a
  -- slower one. None of them runs while the compiled window answers.
  if nl.model_7510 then nl.PX_SUB_LO = nl.PX_SUB_LO_7510 end
  nl.sub_profile = '6500'
  if nl.model_7510 then nl.sub_profile = '7510' end
  nl.PX_SUB_DERIVE = nl.model_7510
  nl.PX_SUB_ANYKIND = nl.model_7510
  nl.PX_SUB_LADDER = nl.model_7510
  -- Whether this model's cursor offsets are known from its own image. The 6500's are; nothing
  -- else's is. The guard in px_hdr_resolve rests on this, and it is what makes trying the
  -- derived route on a 6500 safe to do at all.
  nl.hdr_known = not nl.model_7510
  -- OVERRIDABLE, AND A GLOBAL SO IT SURVIVES AN APPLY. This function runs on every Apply, so a
  -- knob kept in nl would be put back to the model default by the next one -- and the point of
  -- trying the derived route on a 6500 is to turn it on from the socket mid-session, and off
  -- again, without a rebuild.
  --
  --   FFTSA_HDRDERIVE = true    derive on this instrument, whatever the model
  --   FFTSA_HDRDERIVE = false   use the measured constants
  --   FFTSA_HDRDERIVE = nil     the model decides, which is what ships
  if FFTSA_HDRDERIVE ~= nil then nl.PX_HDR_DERIVE = FFTSA_HDRDERIVE end
  if FFTSA_PTRHUNT ~= nil then nl.PX_PTRHUNT = FFTSA_PTRHUNT end

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
  -- The find block and the graph ring block share that chunk too, so the ceiling counts them
  -- as well. Without the ring block it was over by a kilobyte, and the figure a refusal
  -- quotes has to be the room that actually exists.
  local blk_bytes = (nl.FIND_WORDS or 0) * 4 + (nl.PX_WORDS or 0) * 4
  nl.nseg_ceil = math.floor((nl.CHUNK_BYTES - 32 - res_bytes - blk_bytes)
                            / (2 * nl.SIZEOF_REAL))
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
  -- true: cb is STYLE_WRITABLE_FULL, seeded with distinct readings and distinct extras.
  local code_base, code_stride = nl._find_storage(cb, true)
  if code_stride ~= nil and code_stride ~= 32 then
    -- The layout below places the trampoline and the params struct by byte offset inside
    -- this chunk, which holds whatever the element size is -- but a WRITABLE_FULL element
    -- of anything but 32 means the measured layout has moved.
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
  if span > nl.CHUNK_BYTES then
    return fftsa.nl._abort(cb, nil, 'the image, trampoline and params need '
                           .. tostring(span) .. ' bytes of a ' .. tostring(nl.CHUNK_BYTES)
                           .. '-byte chunk')
  end
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
    return fftsa.nl._abort(cb, nil, 'the trampoline read back '
                           .. ((back == nil) and 'nil' or tostring(string.len(back)))
                           .. ' bytes of ' .. tostring(string.len(nl._TRAMP))
                           .. ' at ' .. hx(tramp_at) .. ': the write landed elsewhere')
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
  if img == nil then
    return fftsa.nl._abort(cb, nil, 'relocation refused: ' .. tostring(err))
  end
  trace('img.reloc', string.len(img))
  -- The params address into the word the image reads it from, patched into the bytes before
  -- they are written so the image is never in memory with the slot unset. The offset comes
  -- from the linked image's symbol, so it follows a rebuild.
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

  -- The slot read back before anything is called: it is the one pointer the image takes on
  -- trust and the entry writes a word through it, so an address that landed wrong but still
  -- inside the heap would pass the bounds test there. Four bytes to rule it out.
  local slot = ki.memread(hx(code_base + nl.PARAMS_SLOT), hx(4))
  if slot == nil or string.len(slot) < 4 or u32_at(slot, 1) ~= params_at then
    trace('params.slot.readback.BAD', (slot == nil) and 'nil' or hx(u32_at(slot, 1)))
    return fftsa.nl._abort(cb, nil, 'the params slot read back '
                           .. ((slot == nil) and 'nil' or hx(u32_at(slot, 1)))
                           .. ' and not ' .. hx(params_at) .. ': the image landed wrong')
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
    return fftsa.nl._abort(cb, nil, 'MODE_SEGS answered ' .. tostring(nseg)
                           .. ' segments for n=' .. tostring(want_n) .. ' at '
                           .. tostring(nl.SEG_BYTES) .. ' bytes a segment: no chunk holds '
                           .. 'one of the arrays')
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
    -- Only what diag() does not already carry. nl.why is reported THROUGH diag -- it prints
    -- it as why= -- so the sweep counts, the hit list, the derived offsets, the window ladder
    -- and the word dump would all appear twice, which cost four of the thirteen lines the
    -- glass has.
    return fftsa.nl._abort(cb, pb, 'plan: ' .. tostring(nl._stor_why)
                           .. ' want=' .. tostring(chunks_wanted) .. 'ch for '
                           .. tostring(nseg) .. 'seg')
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
  -- And the find block after it, for MODE_FIND. Words, so 4-aligned is enough, and res_bytes
  -- is a whole number of doubles so the sum stays 8-aligned for anything that follows.
  local find_bytes = (nl.FIND_WORDS or 0) * 4
  local find_addr = res_addr + res_bytes
  -- Then the graph ring block, for MODE_PX: the ring geometry and the slot map. Words again,
  -- and the largest of the four because the map is one entry per ring record.
  local px_bytes = (nl.PX_WORDS or 0) * 4
  local px_addr = find_addr + find_bytes
  if (res_addr - payload[nseg + 2]) + res_bytes + find_bytes + px_bytes > nl.CHUNK_BYTES then
    return fftsa.nl._abort(cb, pb, 'reduction arrays plus a ' .. tostring(res_bytes)
                           .. '-byte results block, a ' .. tostring(find_bytes)
                           .. '-byte find block and a ' .. tostring(px_bytes)
                           .. '-byte ring block will not fit a chunk')
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
    -- The cursor rewind in the image stores at displacements compiled into it. If the
    -- descriptor was identified with offsets derived from the data and they are not those,
    -- the fields it would write belong to something else -- which is how a freed-widget
    -- bluescreen is reached. The app passes out = nil and asks for the reduction only, so
    -- this refuses a call no caller makes today rather than permitting one.
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

-- ---------------------------------------------------------------------------
-- THE SEARCH, IN THE IMAGE.
--
-- Returns the hit addresses and where to resume, or nil. One memwrite of the request, one
-- call, one memread of the answer -- against ki.memread per 32 KB block and a string.find per
-- block in Lua, which is what makes a sweep cost 800 frames instead of one.
--
-- cap bounds the bytes this call scans, so a frame stays a frame: the image is fast but it
-- still runs to completion before the Lua thread resumes, and a frame cannot be interrupted.
-- Zero means the whole range. The resume address comes back either way, so a caller walks a
-- large range across frames the same way px_seek already walks its ladder.
--
-- The range is CLAMPED to the backstop inside the image rather than refused. ki.memread goes
-- through a firmware path that validates; a load from the image does not, and an unmapped
-- address is a data storage interrupt and a bluescreen -- so the clamp is what lets a caller
-- hand over a window that runs off the end of DRAM.
-- ---------------------------------------------------------------------------
fftsa.nl.NFIND_PAT_MAX = 16
-- Bytes the image steps between comparisons. Four, because every needle this module uses is a
-- 4-aligned record field -- see nfind. One would be correct and four times slower; the image
-- refuses anything that is not 1, 2 or 4 rather than rounding it.
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
  -- The needle as four big-endian words, first byte in the top of the first. Multiplication
  -- and not a shift: Lua 5.0 has no shift operator and bit.* is the firmware's, not this
  -- module's to depend on here.
  local pw, i = { 0, 0, 0, 0 }, nil
  for i = 1, plen do
    local wi = math.floor((i - 1) / 4) + 1
    pw[wi] = pw[wi] + string.byte(pat, i) * nl._nf_mul[math.mod(i - 1, 4) + 1]
  end
  -- THE STEP, STATED, because the image will not assume it.
  --
  -- Every needle this module searches for is a field of a record at lo + k*stride + ox, and
  -- both stride and ox are multiples of four wherever they are derived -- REC_MIN..REC_MAX
  -- steps by 4 and the x field is found on a 4-aligned scan. So a match can only begin
  -- word-aligned, and saying so is worth four times the scan rate.
  --
  -- A needle that is not known to be aligned must pass 1, and an unaligned LO is refused by
  -- the image rather than rounded: rounding would move the start past bytes the caller thinks
  -- were searched, which is the same defect as a short read reported as an absence.
  local step = nl.NFIND_STEP or 1
  if step == 4 and math.mod(lo, 4) ~= 0 then
    -- Align upward and tell the caller where it really started, by returning that as `next`
    -- on an empty result. Rounding silently is what this must never do.
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
  -- next and the hits, in one read: word 8 of the block onward.
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

-- The decoder for the reduced arrays, and its width.
--
-- The arrays are dsp_real, so the width comes from the image rather than from here: a decoder
-- picked for the wrong one reads a plausible wrong trace and not a refusal. An image
-- reporting neither width answers nil, and both callers refuse outright on that.
local function red_unpack()
  local sz = fftsa.nl.SIZEOF_REAL
  if sz == 8 then return f64_unpack, 8 end
  if sz == 4 then return f32_unpack, 4 end
  return nil, nil
end

-- WHAT STANDS IN FOR THE DECIBELS UNTIL SOMEBODY ASKS FOR THEM.
--
-- They travel as a plain array through four functions, so "has this frame's spectrum been
-- decoded?" has to be a question about the table itself and not about a flag somewhere else.
-- An empty table is the answer: the first index gives nil, so a reader that forgot to ask
-- fails at once instead of drawing the PREVIOUS frame's spectrum, which is a frozen trace
-- nothing on the glass would report.
--
-- Shared and never written. Nothing may put a value in it.
fftsa.nl._db_none = {}

-- A refused decode, counted where the About page can report it. Returns nil, which is what
-- every caller of reduce_db tests, so the count never changes an answer.
local function db_failed()
  local nl = fftsa.nl
  nl.db_fails = (nl.db_fails or 0) + 1
  return nil
end

-- ---------------------------------------------------------------------------
-- The decibels of the reduction already read, decoded on demand.
--
-- 255 values at a ki.memread and a float decode each, measured at about 8.5 ms of a frame --
-- and on an engaged frame NOTHING IN LUA READS THEM. The image writes the ring from the same
-- array, in the arena, where dsp_reduce left it; the trace never passes through Lua at all.
-- Only three things want them: the append fill, which is what runs when the pixel path has
-- not engaged; the Lua ring writer, which a frame that re-points the series uses; and the
-- repaint's one append, in 'append' mode. Each asks here, and a frame that asks twice pays
-- once.
--
-- A value that does not decode fails the whole call rather than leaving a hole: a nil
-- reaching buffer.write.reading is a posted event per point. The array is installed only
-- after the last value lands, so a failure part way leaves the empty stand-in in place and
-- the caller sees nil rather than a half-filled spectrum.
-- ---------------------------------------------------------------------------
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

-- The decibels, decoded if they are not already.
--
-- THE REDUCTION'S OWN STATE DECIDES, not the argument, wherever there is a reduction to ask.
-- Installing the empty stand-in changes r.db but cannot revoke a reference somebody already
-- took to the buffer behind it, so a caller holding last frame's array could hand it back and
-- be believed -- and that is exactly the frozen trace the stand-in exists to prevent. No
-- path in this tree keeps such an alias across a frame; asking the reduction rather than the
-- argument is what keeps that a fact about the code rather than a property to maintain.
--
-- The argument is taken only when there is no reduction at all, which is the interpreted path
-- and the offline suites: there the array arrives filled and nothing else can supply it.
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

-- ---------------------------------------------------------------------------
-- The reduced trace the last run produced: one decibel value per segment and the frequency
-- of each, in two tables for the caller to write with buffer.write.reading.
--
-- That write is the only route onto a graph. The native side can put the same numbers into
-- the bound buffer's chunk storage and rewind its descriptor -- the buffer then reads back
-- correct from Lua and buf.n says the right count -- and the graph stays blank, because the
-- display task works from its own copy and no notify call reaches a write it never saw.
--
-- THE DECIBELS ARE NOT DECODED HERE unless want_db says so, and the app says so only when
-- something is going to read them. Default true, so a caller that does not know about the
-- argument gets what this always did.
--
-- The frequencies are decoded whichever way: every caller needs them, the pixel path included
-- -- it compares the first two against the series its slot map was built on, which is how an
-- FFT size change is noticed -- and they only move when the plan behind them does, so they
-- cost a 8-byte probe on the frames that matter and nothing on the rest.
--
-- The tables are allocated once and refilled, this running in a frame.
-- ---------------------------------------------------------------------------
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
  r.nseg = nseg
  -- The stand-in goes in before the decode is attempted, not after it fails, so there is no
  -- window in which r.db still points at the last frame's values.
  r.db = nl._db_none
  if want_db == nil or want_db then
    if nl.reduce_db() == nil then return nil end
  end
  return r
end

-- ---------------------------------------------------------------------------
-- Does the derived geometry actually address the firmware's own readings?
--
-- Everything above identifies the record from two or three agreeing figures, and that is
-- enough to be confident and not enough to be sure. The element size is a RUNTIME field --
-- a sum of the widths of whatever columns a style enables, which no constant in the firmware
-- image records -- so it is per model and cannot be looked up. A DMM6500's is 24 and a
-- DMM7510 1.7.16a reads 20, and the second figure rests on a descriptor whose three geometry
-- words agree with each other. A wrong element size does not refuse: it reads the wrong bytes
-- as samples and draws a plausible, wrong spectrum.
--
-- So this asks the firmware. Element j of the record is at blk[j / perchunk] + (j % perchunk)
-- * elemsize, which is exactly what dsp_src_at computes, so checking that address against
-- buf.readings[j + 1] tests the mapping the native call will actually use:
--
--   * every chunk the record occupies, at its first element -- which pins PERCHUNK, because
--     at perchunk 1638 chunk 1 begins at reading 1639 and at 1365 it begins at 1366
--   * the last element of chunk 0 -- which pins ELEMSIZE across a whole chunk, where the
--     content scan's far indices reach element 256 and no further
--
-- Two readings and a stride confirm on a periodic input at more than one spacing; a chunk
-- boundary does not, because a wrong element size moves it by hundreds of elements.
--
-- About a dozen comparisons, at Apply and never in a frame. It costs the DMM6500 the same
-- dozen and gains it the same guarantee: the one failure this module had no symptom for was
-- a chunk mapping that reads the inter-chunk header back as samples.
fftsa.nl.GEOM_CHUNKS_MAX = 32          -- DSP_MAX_SRC_BLOCKS; a record cannot span more

-- Element sizes to try when the geometry does not fit, smallest first. Every multiple of 4
-- from a bare double to 48: the figure is a runtime sum of the widths of whatever columns a
-- style enables, so it is not drawn from a list the firmware holds and a model may use one
-- nobody has seen.
fftsa.nl.ES_CANDIDATES = { 8, 12, 16, 20, 24, 28, 32, 36, 40, 44, 48 }

-- Which element size WOULD put the right reading at the second chunk's base.
--
-- The refusal below says the geometry is wrong. This says what it probably is, which is the
-- figure a fix needs rather than the figure that failed. A chunk boundary is what makes it
-- answerable at all: perchunk is CHUNK_BYTES/elemsize, so each candidate predicts a
-- DIFFERENT reading index at the same address -- 1366 at 24 bytes, 1639 at 20 -- and only the
-- true one matches. Eleven candidates and two reads each, on the failing path only.
--
-- This is the figure that cost a session: a DMM7510 reported rc=-5 and settling the element
-- size took a hand-decoded hex dump of the descriptor and an argument about design priors.
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
    -- Elements that fit one payload, which is what perchunk means.
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
  -- Both cleared on the way in: _geom_n is how many indices were confirmed, and a stale one
  -- reads as this call having checked something when it returned before looking.
  nl._geom_why, nl._geom_n = nil, nil
  if buf == nil or d == nil then return true end
  local n, pc, es = buf.n, d.perchunk, d.elemsize
  if type(n) ~= 'number' or type(pc) ~= 'number' or type(es) ~= 'number' then return true end
  if n < 1 or pc < 1 or es < 8 then return true end
  -- Which address holds element j, by the native side's own arithmetic. blk[0] is the
  -- record's first element and not the chunk payload, which is why it is carried separately.
  local function at(j)
    local k = math.floor(j / pc)
    if k == 0 then return d.chunk1 + j * es end
    if d.vec == nil or k >= nl.GEOM_CHUNKS_MAX then return nil end
    local b = W(d.vec + k * 4)
    if b == nil or b == 0 then return nil end
    return b + math.mod(j, pc) * es
  end
  -- The indices to confirm: the first element of every chunk the record reaches, and the
  -- last element of chunk 0. Zero-based j, so reading index is j + 1.
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
      -- Both figures and the index, because this is where a per-model element size is
      -- settled: the reading the firmware reports at an index against what is at the address
      -- es and pc put it at. es=20 and es=24 disagree first at the second chunk's base.
      nl._geom_why = 'reading ' .. tostring(j + 1) .. ' is not at ' .. hx(a)
                     .. ' for es=' .. tostring(es) .. ' pc=' .. tostring(pc)
      -- And what would fit, when that is answerable. A refusal naming the right figure is
      -- one grab; a refusal naming only the wrong one is a round trip for each guess.
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
  if not elem0 then
    -- Nothing was looked for, so nothing may be reported: _find_desc never ran, and without
    -- this the error page shows the last buffer that DID reach it -- its hits, its dump, its
    -- derived offsets -- beside this buffer's storage failure.
    nl.desc_report_reset(buf)
    return nil
  end
  local desc, elemsize, perchunk, vec, nchunks = sdesc, selemsize, sperchunk, svec, snchunks
  if desc == nil then
    -- The stride goes with it: the derived route locks the element-size field against the
    -- figure the content scan measured, which is the only thing it has that is not an offset.
    desc, elemsize, perchunk, vec, nchunks = fftsa.nl._find_desc(elem0, buf, stride)
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
  -- Which layout this was read at travels WITH the descriptor, so a caller asking whether
  -- it may be written to is answered about the descriptor it holds rather than about
  -- whichever buffer was described last.
  local d = { chunk1 = elem0, chunk2 = ch2, perchunk = perchunk,
              elemsize = elemsize, desc = desc, vec = vec, nchunks = nchunks,
              lo = lo, hi = hi, doff = nl.doff_used, dderived = nl.desc_off }
  -- The last gate, and the only one that asks the firmware rather than the record. Refused
  -- here rather than left to the native call: a geometry that addresses the wrong bytes is
  -- not refused there, it draws a wrong spectrum.
  if not fftsa.nl.geom_ok(buf, d) then
    nl._stor_why = 'geometry does not address the readings -- ' .. tostring(nl._geom_why)
    return nil
  end
  return d
end
