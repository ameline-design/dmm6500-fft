-- native_link.tsp -- load the native DSP binary into heap and make it callable.
--
-- Called once at startup; sets fftsa.nl.ready when the native path is available.
-- Falls back silently on any failure: the app then uses dsp.spectrum as before.
--
-- No firmware address is written down here. The six libm entries come from FNF, which
-- finds them in the code of Lua's own math wrappers; the ki.peek8 closure and its f
-- pointer come from tostring and a read; the trampoline is self-contained PowerPC that
-- flushes the cache itself; and neither it nor the image reads the Lua stack, so the two
-- helpers that used to transport their arguments are not needed. What the call reports
-- comes back through a word of the params struct.
--
-- What remains firmware-shaped is ranges and layouts, not entry points: the .text extent
-- in TEXT_LO and TEXT_HI, the heap extent the image is compiled with, the closure's f at
-- +12 and the reading-buffer descriptor offsets. Every one of those is a test that
-- refuses, so a build that moves them loses the native path and keeps the interpreter.
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

-- THE ALLOCATOR ONLY GUARANTEES 16-BYTE ALIGNMENT, AND DSP_ALIGN IS 32. Measured payload
-- addresses alternate: 0x360D600 and 0x3613180 are 32-aligned, 0x36055F0, 0x360B170 and
-- 0x3603C90 are 16-aligned. dsp_native_run refuses a misaligned segment with DSPN_EBOUNDS,
-- so an arena built straight from the chunk vector works or fails depending on which
-- payload the allocator happened to put first -- it passed three times and then failed,
-- which is a coin flip rather than a regression.
--
-- So every segment base is rounded up to 32 and the usable size drops by one alignment
-- unit. SEG_BYTES stays a multiple of DSP_ALIGN, and rounding up adds at most 31, so
-- align32(payload) + SEG_BYTES never leaves the payload. The same value has to go to
-- MODE_SEGS as to MODE_INIT, or the chunk count is computed for a size the arena does not
-- have.
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

-- Picker index to DSP_WINDOW_*, the enum in csrc/dsp.h. A SEPARATE MAP FROM
-- fftsa.win_dsp, which goes to Keithley's dsp.WINDOW_*. The two enums coincide today and
-- nothing holds them together: spectrum_app.tsp:49 spells out what a mismatch costs --
-- the wrong window selected with nothing on the glass to say so, every amplitude out by a
-- scalloping factor. Our side of the seam gets its own map for the same reason theirs
-- does, and the window_enum gate compares this table against dsp.h so a renumbering is a
-- build failure rather than a measurement error. Index-parallel to fftsa.win_names.
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

-- The cache-flush trampoline, assembled from csrc/flush_tramp.S. It pushes a range out of
-- the D-cache with dcbst, invalidates the same range in the I-cache with icbi and isyncs,
-- all in instructions of its own, so it depends on no firmware address. It takes no Lua
-- arguments: the range is the two words at TRAMP_RANGE, which nl.flush writes before the
-- call and the code reaches through a bl/mflr pair.
--
-- Position-independent and relocation-free, which csrc/tools/emit_tramp.py checks when it
-- regenerates this literal. That tool is also the gate that keeps the two in step; the
-- bytes are not editable by hand.
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
-- Base64, so the image costs 1.37 characters a byte in the archive instead of 4.
--
-- ki.memwrite takes its length from lua_strlen rather than strlen, so the embedded NULs a
-- binary is full of survive a Lua string either way; what does not survive is Lua 5.0.2
-- having no \xNN escape, which leaves decimal as the only literal form for raw bytes. The
-- archive's source is read and parsed at every app launch, where this is decoded once in
-- nl.init. The byte figures move with every rebuild of the image; the ratio does not.
--
-- No padding and no tail case: embed_native.py pads the binary to a multiple of three and
-- emits the true length beside it, so this is a flat four-to-three mapping and the length
-- trims the padding. A tail case would be a branch nothing exercises until the day the
-- image length changes residue.
-- ---------------------------------------------------------------------------
local B64A = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
local b64map = nil

-- string.gsub with a function rather than a loop over string.byte: the pattern scan and
-- the assembly of the result both happen in C, so this is one Lua call per four
-- characters instead of four string.byte calls plus a table store. The map is keyed by the
-- CHARACTER, which is what the captures are, so there is no string.byte at all.
local function b64decode(s, len)
  if s == nil or len == nil then return nil end
  local slen = string.len(s)
  if math.mod(slen, 4) ~= 0 then return nil end
  -- Validated before the substitution, not inside it: a function replacement that returns
  -- nil leaves the match in place, so one stray character would pass silently through as
  -- itself rather than failing.
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
-- first. The params struct is a wire format and Lua 5.0.2 has no way to lay out a double,
-- so every double in it crosses as a word pair; pw_double in dsp_native.c reassembles one.
--
-- math.frexp and math.ldexp are both present on 1.7.17a, measured rather than assumed. The
-- arithmetic is exact: every multiply is by a power of two, so nothing rounds and the
-- result is the bit pattern a host would have written. Checked against struct.pack in
-- csrc/tools/test_f64.lua, including the signs, the infinities and a NaN.
--
-- SUBNORMALS FLUSH TO ZERO, and so does anything whose exponent overflows, to an infinity.
-- The smallest normal is 2.2e-308; what crosses here is a frequency, a decibel limit or a
-- voltage floor, and the closest any of them comes is the squared voltage floor at 1e-18.
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
-- nl.init is one Lua call that installs code and then branches into it, so when it
-- bluescreens the Lua state goes with the instrument and there is nothing left to ask.
-- A PC on the glass in the heap says only that something executed garbage, and init has
-- three places that branch to a heap address. print() in TSP reaches the socket as the
-- statement runs, so a trace crosses the wire BEFORE the crash and the last line received
-- names the step. That is the only diagnostic available here short of splitting init into
-- separately-callable stages, which is worth doing for nl.reinit but would not have been
-- worth doing blind.
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
-- An infinity or a NaN comes back as NIL rather than as a number. Neither can be written
-- to a display field -- a refused graph parameter is a modal dialog -- and this firmware's
-- comparisons are not IEEE for a NaN, so a NaN that got past here would not be caught by
-- the usual v ~= v test downstream either.
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

-- The same, out of four big-endian bytes, for a single-precision image. The reduced trace
-- is the one place dsp_real crosses to Lua as its own width: everything else in the wire
-- format is a double whatever the image was built in.
--
-- Subnormals decode exactly here rather than flushing, because unlike f64_words this is a
-- read and the values are a decibel figure and a frequency. An infinity or a NaN comes back
-- as nil, on the same grounds as above.
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
-- FNF: find the firmware function behind a Lua math wrapper.
--
-- Scans a Form E closure's .text handler for the first bl targeting >= 0x00400000;
-- that is the GHS C function, double in f1 to double in f1. Works across builds as
-- long as the wrapper structure is preserved.
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
  -- Recorded, not tested against anything: every address below is found by reading this
  -- build's own code, so a build this has never seen either yields six addresses or
  -- yields fewer and loses the native path.
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
-- Reading the entry back is the only check available on an address FNF derived: two of
-- them answering the same address, or one landing somewhere that is not a function
-- prologue, is visible here and nowhere else.
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
-- On PPC32 every data reference is `lis rX,hi` plus a `lo(rX)` access, an absolute
-- address fixed at link time, and clang's PPC backend has no small-data addressing to
-- avoid that. The image is linked at zero, so each relocation target doubles as an
-- offset into it, and patching is target plus load address.
--
-- The patch is applied to the Lua string before it is written, so the instrument sees
-- one ki.memwrite rather than one per relocation. Verified against hand-computed
-- answers in csrc/tools/test_relocate.lua, including the ha carry boundary.
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

-- Element storage of a buffer, by content scan over the buffer's OWN first readings.
--
-- No fixed sentinel. The needle is reading 1 as the eight bytes the element holds, so this
-- works on a capture as well as on a buffer seeded for the purpose -- and two buffers
-- seeded alike cannot be mistaken for one another, which they could when the needle was
-- the literal 1000001.0 in every call. Only the order of the writes kept that apart: the
-- image landed on the code buffer's sentinel before the plan buffer was scanned for the
-- same one.
--
-- Returns the slot 0 address, or nil. Two passes: the arena recent allocations land in
-- first, then the wider heap. The narrow pass is 32 MB rather than 126 MB and has found it
-- every time so far.
--
-- CONFIRMATION USES THE EXTRA VALUES AS WELL AS THE READINGS. fftsa.sg_mkbuf seeds the
-- trace buffer with the axis floor in every element and a distinct extra in each, so
-- readings alone match at every element and the scan returns whichever lies lowest in
-- memory -- which for a two-chunk buffer is not element 0, because the second payload is
-- often below the first. A trace shifted by a whole chunk is still a plausible trace.
-- Readings nl.init seeds a buffer it means to find. It has to be at least the largest
-- FAR_INDEX below, or the one check that no small record can imitate does not apply to the
-- buffers we create for ourselves -- which are exactly the ones whose readings are a
-- regular series and so most likely to be mimicked by a statistics record. 256 writes is
-- under two milliseconds, once, at install.
fftsa.nl.SEED_READS = 256

-- Consecutive readings a hit is confirmed against, and the far indices confirmed as well.
-- Six consecutive values prove very little; the same series still holding at index 256
-- proves an array of at least that many. Both are cheap -- seven double comparisons a
-- candidate -- where confirming all 256 would be 510 peek32 calls per hit.
local READ_CONFIRM = 6
local FAR_INDEX = { 64, 256 }

-- Returns the slot 0 address and the MEASURED element stride, or nil.
--
-- has_extras IS THE CALLER'S KNOWLEDGE, not something to discover. Reading .extravalues on
-- a STYLE_STANDARD buffer posts event 4927 and the firmware puts a MODAL DIALOG on the
-- glass for it, over the running app. pcall does not help -- the firmware posts where it
-- does not raise, so the call succeeds and returns nil while the operator gets a dialog.
-- Every caller created the buffer it is asking about and knows the style it asked for.
function fftsa.nl._find_storage(buf, has_extras)
  local n = buf.n
  if n == nil or n < READ_CONFIRM then return nil end
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
  -- READINGS FROM THE FAR END, which is what no small record can imitate. The firmware
  -- keeps separate 16-byte records of the same values -- the extra-value records and the
  -- statistics accumulators -- and a seeded buffer's first six readings were MEASURED at
  -- stride 16 at an address that is not element storage at all.
  --
  -- The largest index is 256, which is inside the FIRST chunk whatever the element size
  -- turns out to be: the smallest plausible element is 8 bytes, which still puts 4096 in a
  -- chunk. Only indices the buffer actually has are used.
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
  for wi = 1, table.getn(windows) do
    local hits = fftsa.nl.FINDS(windows[wi][1], windows[wi][2], needle)
    local k
    for k = 1, table.getn(hits) do
      local h = hits[k]
      -- 8, NOT 16. The reading at +0 is a double the firmware itself loads, so element 0
      -- is 8-aligned; it is NOT 16-aligned, which a 16-byte filter cost an hour to learn --
      -- the trace buffer's element 0 was measured at 0x037C71C8 and refused by its own
      -- scan. Element 0 is not the chunk payload, so the allocator's guarantee does not
      -- reach it. This rejects nothing real and costs nothing; the discrimination is the
      -- extras and the far readings below.
      if math.mod(h, 8) == 0 then
        -- CANDIDATE STRIDES, 32 FIRST AND PREFERRED. 32 is what a WRITABLE_FULL element
        -- measures, the extra value at +20 only exists in an element that long, and
        -- assuming it was load-bearing: measuring the stride from the spacing of the
        -- readings instead found a 16-byte record holding the same six values. So 32 is
        -- tried first and the measured offsets are the fallback, for a STYLE_STANDARD
        -- buffer whose element really is smaller. Each candidate gets the FULL
        -- confirmation before it is accepted.
        local cands, cn = { 32 }, 1
        if rd[2] ~= rd[1] then
          local off
          for off = 8, 64, 4 do
            if off ~= 32 and eq64(h + off, rd[2]) then cn = cn + 1; cands[cn] = off end
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
          -- every reading in it is the same. They only exist in an element long enough to
          -- hold one, so a buffer that HAS them is a buffer whose element is at least 28 --
          -- which makes this a stride test as well as a value test.
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
  return nil
end

-- The column descriptor for a buffer, from its element storage address.
-- Steps 3 to 5 of the recipe in fwmem-BUFFER.md: find the storage address as a word,
-- the descriptor starts 0x48 below it, then confirm with the two self-pointers and the
-- chunk geometry. Returns descriptor base, elemsize, perchunk, chunk vector.
-- The descriptor fields, from a base this function did not have to search for. Split out so
-- the words can be re-read without the sweep below: they are five peek32, and re-reading
-- them is how a caller picks up a chunk vector that has lengthened. The validation is the
-- same, so a base that no longer describes this buffer is refused here and the caller
-- sweeps again.
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
  -- its second, which the tree measures at about a minute. Keyed on the storage address, so
  -- a buffer whose storage moved misses, and _read_desc refuses a base that no longer points
  -- back at elem0 even if the key matched.
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
        -- PERCHUNK IS HOW MANY ELEMENTS FIT IN A CHUNK, NOT CHUNK_BYTES / 32. The payload
        -- is a fixed 32,768 bytes but the element size is a runtime field, and a
        -- STYLE_STANDARD element is 24 -- measured -- which does not divide it: 1365
        -- elements fill 32,760 and leave 8 spare. Demanding an exact product was demanding
        -- a 32-byte element, so the capture buffer's descriptor was refused and the native
        -- path silently fell back. The test below still pins perchunk exactly: one more
        -- element would not fit.
        if elemsize ~= nil and perchunk ~= nil and nchunks ~= nil and
           nchunks > 0 and nchunks < 4096 and elemsize >= 8 and perchunk > 0 and
           elemsize * perchunk <= fftsa.nl.CHUNK_BYTES and
           elemsize * (perchunk + 1) > fftsa.nl.CHUNK_BYTES then
          -- 0x44 is the chunk vector. The count comes back with it because a caller
          -- indexing the vector has no other way to know where it ends: reading one
          -- entry too far returns whatever follows it in the heap, and an address that
          -- happens to land in the heap would pass the backstop and be written to.
          nl._desc_of, nl._desc_at = elem0, base
          return base, elemsize, perchunk, W(base + 68), nchunks
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
  -- THE WORD COUNT AGAINST THE STRUCT THE COMPILER LAID OUT. PARAM_WORDS is a number in
  -- this file and SIZEOF_PARAMS comes out of the linked image, so this is the one check
  -- that catches a field added on one side only -- which would otherwise shift every word
  -- after it and hand dsp_native_run a valid-looking address for something else entirely.
  -- Skipped when SIZEOF_PARAMS is zero, which is a module with no generated code to run.
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
  -- Whether the branch returned normally, which is all the return value can say: both
  -- pieces of native code leave zero Lua values, so r is nil on success and nil on a
  -- raised error. What they computed is read out of memory afterwards.
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
  -- Refuse to flush the trampoline's own range. icbi on a line the CPU is executing from,
  -- followed by isync, forces a re-fetch mid-function; that is the fault behind two
  -- bluescreens. The caller has no business asking for it -- the barrier alone bootstraps
  -- a fresh line -- so this is a refusal rather than a special case.
  --
  -- Line by line, not byte by byte. The flush works in whole lines, so a range ending a
  -- few bytes short of the trampoline still invalidates its first line, and a byte test
  -- passes that straight through. The image's length is whatever the compiler makes it.
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

-- Call native code at addr and read back the status it wrote into the params struct.
--
-- Returns the status as a signed number, or nil and a reason. Three distinct failures and
-- each says which: the branch raised, the word could not be read, and the word still
-- holds STATUS_UNSET -- the last meaning the code ran and returned without passing
-- through any exit of dsp_native_run, which is what landing in the wrong place looks
-- like from here.
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

-- Every failure exit from nl.init comes through here. Deleting the buffers is not enough:
-- nl.entry, nl.tramp and nl.params point into chunk storage that the delete frees, so a
-- later via_peek8 through a stale nl.entry would branch into whatever the allocator hands
-- out next. call_dsp is gated on nl.ready and that stays false, but a dangling function
-- pointer sitting in a module table is a trap, not a guard. peek8_cls and peek8_f are kept
-- deliberately: restore_peek8 needs them, and they are firmware addresses, not heap.
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
-- Init. Called once per boot, at startup, before any frame.
--
-- Once per boot is now a CONSERVATIVE RULE RATHER THAN A NECESSARY ONE. It was written when
-- a second install wedged the interpreter, which the trampoline flushing its own range is
-- what caused; with that removed, an image rewritten over an already-fetched range and
-- flushed through the trampoline was measured computing correctly. The guard stays because
-- nothing needs a second install -- nl.reinit re-plans without one -- so relaxing it would
-- buy nothing and give up a backstop.
--
-- barrier_buf is accepted and validated but not used as the barrier. init fills its own
-- code buffer with three readings and uses that, because buffer.getstats is the barrier
-- only when it makes the service-task call and on an empty buffer it need not -- and the
-- caller's buffer is empty more often than not.
--
-- Returns true with nl.ready set, or false with every heap-derived field nil'd.
-- ---------------------------------------------------------------------------
function fftsa.nl.init(barrier_buf, want_n, kind, beta, decim, method, want_nseg)
  local nl = fftsa.nl

  -- ONE INSTALL PER BOOT, AND A MODULE FIELD CANNOT ENFORCE IT. fftsa.start() calls this
  -- on every app start, and a stop/restart with no power cycle reloads the script, so any
  -- flag kept in nl is gone while the heap code and its I-cache lines are not. A second
  -- install at a fresh address wedges the interpreter: the IPC barrier drains the store
  -- buffer to DRAM but does not invalidate the I-cache, and the trampoline cannot flush a
  -- replacement for itself. A Lua global is the only storage scoped to the boot rather
  -- than to the script, so that is what holds it.
  --
  -- Refusing leaves the app on dsp.spectrum -- degraded, and the alternative is an
  -- instrument that answers ping and nothing else. NLBOOT is shared with the probes on
  -- purpose: both install heap code, so either blocks the other.
  --
  -- THIS IS THE FIRST STATEMENT, ahead of nl.ready = false, so a refusal cannot damage an
  -- install that is already working. Within one script session a second call would
  -- otherwise clear ready on a good install and drop the app to the fallback for no
  -- reason.
  if NLBOOT ~= nil then
    nl.boot_spent = true
    return false
  end
  nl.boot_spent = false

  nl.ready = false
  -- want_n sizes the ARENA, so it is the largest count the app can ask for and not the one
  -- in force: nl.reinit re-plans for anything at or below it without touching the heap,
  -- and a count above it has no arena to be planned into.
  want_n = want_n or 512
  want_nseg = want_nseg or 255

  -- Decoded once and kept: the base64 is what the archive carries and this is the only
  -- place that turns it into bytes. A second init reuses the decode rather than paying
  -- for it again.
  if nl._DSP_CODE == nil and nl._DSP_CODE_B64 ~= nil then
    trace('b64', nl._DSP_CODE_B64_LEN, nl._DSP_RELOC_B64_LEN)
    nl._DSP_CODE  = b64decode(nl._DSP_CODE_B64, nl._DSP_CODE_B64_LEN)
    nl._DSP_RELOC = b64decode(nl._DSP_RELOC_B64, nl._DSP_RELOC_B64_LEN)
    trace('b64.ok', nl._DSP_CODE ~= nil and string.len(nl._DSP_CODE) or 'nil')
  end
  if nl._DSP_CODE == nil or string.len(nl._DSP_CODE) == 0 then return false end
  if nl._DSP_RELOC == nil then return false end
  -- Zero or nil means the generated module never loaded, and every size below would be
  -- wrong in a way that still produces addresses. PARAMS_SLOT and STATUS_OFF are in the
  -- list because without them the image gets no params address and reports nothing: that
  -- is a call into code whose one pointer is zero, which is worth refusing here rather
  -- than discovering at the entry.
  if nl.SIZEOF_REAL == 0 or nl.SIZEOF_PLAN == 0 or nl.SIZEOF_PARAMS == 0 or
     nl.RES_DOUBLES == 0 or nl.RES_PEAKS == 0 or
     nl.PARAMS_SLOT == nil or nl.PARAMS_SLOT == 0 or
     nl.STATUS_OFF == nil or nl.STATUS_OFF == 0 then
    return false
  end

  -- No array has to fit a chunk whole: dsp_plan_init_segs cuts one too long for a segment
  -- into slices, and the transform reads the capture in place rather than de-striding it.
  -- What bounds n is the number of chunks the image reports from dsp_plan_segs at step 7,
  -- against DSPN_MAX_SEGS; a count needing more is refused there. DSP_N_MAX is the
  -- library's own ceiling.
  local nmax = 65536
  nl.nceil = nmax
  -- The plan struct has a chunk to itself, which is the one size still checked here: it
  -- grew when the slice tables went into it.
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
  -- This value is written back into a live lua_CFunction pointer by every redirect, so
  -- it is the most dangerous number in the module and it is validated before it is kept.
  -- A single transport read is not enough: a desynchronised socket once returned a heap
  -- address here, the restore wrote it into the dispatch path, and the next call executed
  -- a deleted buffer's stale readings -- bc at +0 fell through to an illegal 0x00000000
  -- at +4, PC 0x03518424. Two agreeing reads, both inside firmware .text, or refuse.
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
  -- confirms a hit against that many and refuses a buffer it cannot tell apart element
  -- from element.
  local k
  for k = 1, fftsa.nl.SEED_READS do
    buffer.write.reading(cb, 1000000 + k, 3000000 + k, k, 0)
  end

  -- THE BARRIER USES cb, THE BUFFER THIS FUNCTION JUST FILLED, NOT THE CALLER'S.
  -- buffer.getstats is the barrier only when it actually makes the service-task call,
  -- and on an empty buffer it need not. Passing defbuffer1, empty after a power cycle,
  -- bluescreened the instrument once: the trampoline had not reached DRAM, the I-cache
  -- filled from stale heap and the CPU executed a deleted buffer's readings. The caller
  -- cannot be trusted to hand over a live buffer -- fftsa.start() passes fftsa.cap,
  -- which is empty until the first capture completes -- so init no longer depends on it.
  -- barrier_buf is still accepted, and validated rather than used, so a caller that
  -- passes something unusable is told rather than crashed.
  if barrier_buf ~= nil and barrier_buf.n == nil then return fftsa.nl._abort(cb) end
  local bar = cb
  if bar.n == nil or bar.n < 1 then return fftsa.nl._abort(cb) end
  buffer.getstats(bar)

  trace('scan.code')
  -- true: cb is STYLE_WRITABLE_FULL, seeded with distinct readings AND distinct extras.
  local code_base, code_stride = nl._find_storage(cb, true)
  if code_stride ~= nil and code_stride ~= 32 then
    -- The layout below places the trampoline and the params struct by byte offset inside
    -- this chunk, which is true whatever the element size is -- but a WRITABLE_FULL element
    -- being anything but 32 would mean the measured layout has moved under us.
    trace('code.stride.BAD', code_stride)
    return fftsa.nl._abort(cb)
  end
  if not code_base then return fftsa.nl._abort(cb) end
  trace('code_base', hx(code_base))
  nl.code_buf  = cb
  nl.code_base = code_base

  -- 4. Layout, derived from the image rather than fixed: the image is tens of
  --    kilobytes, so a trampoline at a fixed +256 sits inside it.
  --
  -- The trampoline starts on a cache line, aligned on the absolute address rather than on
  -- an offset, so it holds whatever the chunk payload is aligned to. The flush of the
  -- image rounds up to a whole line, and the image ends wherever the compiler leaves it:
  -- without this, flushing the image invalidates the trampoline's first line while the
  -- CPU is fetching from it. nl.flush refuses that case too, so a layout mistake costs an
  -- unflushed image rather than a bluescreen.
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

  -- 5. Trampoline first, so later writes can be flushed properly. Its own first
  --    execution rides on the IPC barrier alone.
  --
  -- The boot is claimed here, in its own statement, before the first write rather than
  -- after the last. A failure or a wedge from this point on has still consumed the one
  -- install the boot allows, so refusing a retry that might have been safe is the right
  -- way round: that costs a power cycle, and allowing one that is not costs a wedge and a
  -- power cycle. Nothing clears NLBOOT, including _abort.
  NLBOOT = tramp_at
  trace('tramp.write', hx(tramp_at), string.len(nl._TRAMP))
  ki.memwrite(hx(tramp_at), nl._TRAMP)
  buffer.getstats(bar)

  -- Confirm the bytes are where we think before branching to them. A read goes through the
  -- D-cache so this cannot prove DRAM visibility -- that is the barrier's job -- but it does
  -- catch a write that landed somewhere else entirely, which otherwise costs a bluescreen
  -- and a power cycle to discover.
  local back = ki.memread(hx(tramp_at), hx(string.len(nl._TRAMP)))
  if back ~= nl._TRAMP then
    trace('tramp.readback.BAD', (back == nil) and 'nil' or string.len(back))
    return fftsa.nl._abort(cb)
  end
  trace('tramp.readback.ok')

  nl.tramp = tramp_at
  -- The trampoline is never flushed, and nl.flush refuses a range covering it. icbi on a
  -- line the core is executing from, followed by isync, re-fetches the instruction stream
  -- mid-function; that is the fault behind two bluescreens, PC trampoline+64 in one of
  -- them. It does not need flushing either: the barrier above puts the bytes in DRAM, and
  -- a line that has not been instruction-fetched since boot fills from there. It earns
  -- its keep on other ranges, which is what the image needs.
  trace('tramp.ok')

  -- 6. The image, patched for this load address.
  local img, err = nl.relocate(nl._DSP_CODE, nl._DSP_RELOC, code_base,
                               nl._DSP_RELOC_BSS_HI)
  if img == nil then return fftsa.nl._abort(cb) end
  trace('img.reloc', string.len(img))
  -- The params address into the word the image reads it from, patched into the bytes
  -- before they are written so the image is never in memory with the slot unset. The
  -- offset comes out of the linked image, from the symbol, so it follows a rebuild.
  if nl.PARAMS_SLOT == nil or nl.PARAMS_SLOT == 0 or
     nl.PARAMS_SLOT + 4 > string.len(img) then
    trace('params.slot.BAD', tostring(nl.PARAMS_SLOT))
    return fftsa.nl._abort(cb)
  end
  img = string.sub(img, 1, nl.PARAMS_SLOT) .. u32_pack(params_at) ..
        string.sub(img, nl.PARAMS_SLOT + 5)
  trace('params.slot', nl.PARAMS_SLOT, hx(params_at))
  ki.memwrite(hx(code_base), img)

  -- The slot read back before anything is called. It is the one pointer the image takes
  -- on trust, and the entry writes a word through it: an address that landed wrong but
  -- still inside the heap would pass the bounds test there and put that word in somebody
  -- else's allocation. Four bytes to rule it out.
  local slot = ki.memread(hx(code_base + nl.PARAMS_SLOT), hx(4))
  if slot == nil or string.len(slot) < 4 or u32_at(slot, 1) ~= params_at then
    trace('params.slot.readback.BAD', (slot == nil) and 'nil' or hx(u32_at(slot, 1)))
    return fftsa.nl._abort(cb)
  end
  buffer.getstats(bar)
  -- The image is a different range from the trampoline, so this is the trampoline's
  -- legitimate use. The result is checked: a silent failure here leaves the I-cache able
  -- to serve stale lines for the image, which is a wrong answer rather than a fault.
  --
  -- A failure is not fatal on a first install, because the image's lines have not been
  -- fetched since boot either and the barrier covers them -- which is why this worked
  -- before the flush result was ever examined. It is recorded rather than ignored.
  trace('img.flush')
  nl.flushed = flush(code_base, string.len(img))
  trace('img.flush.ok', tostring(nl.flushed))
  nl.entry = code_base
  trace('img.ok')

  -- 7. How many chunks the arena needs, asked of the binary rather than guessed.
  --    The arrays are laid out one per chunk by dsp_plan_init_segs, so the arena does
  --    not need contiguous memory -- which it could not have, since chunk payloads are
  --    placed independently by the allocator.
  -- SEG_BYTES, the same value MODE_INIT gets. Asking with CHUNK_BYTES would compute a
  -- chunk count for an arena 32 bytes per segment larger than the one actually built.
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

  -- 8. Plan buffer: one chunk per segment, one for the plan struct and the de-strided
  --    capture, and one for the reduction's two arrays. Three lifetimes, three chunks:
  --    sharing the host chunk would make the largest n depend on the largest trace, and a
  --    refusal there reads as "the native path is unavailable" with nothing to say which
  --    of the two sizes was the one that did not fit.
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

  -- The vector has to actually hold the entries about to be read out of it. The chunk
  -- count is the descriptor's own field at +0x10, so this is the allocator's answer and
  -- not an inference from the capacity asked for. Without it, one entry past the end
  -- returns whatever follows the vector in the heap, and a value that happened to look
  -- like a heap address would pass the native backstop and be written through -- into
  -- somebody else's allocation.
  if pdesc.nchunks == nil or pdesc.nchunks < chunks_wanted then
    return fftsa.nl._abort(cb, pb)
  end
  nl.plan_buf = pb

  -- Chunk payload addresses from the vector. They are not in address order and not
  -- adjacent; dsp_plan_init_segs does not care, and nothing here may assume otherwise.
  -- Each is checked against the heap here as well as by the native entry point, so a
  -- bad vector is a refusal from Lua rather than a status code from a call that has
  -- already been handed the address.
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

  -- Segment bases rounded up to DSP_ALIGN. The allocator only guarantees 16 and dsp.c
  -- needs 32, so a raw payload is refused with DSPN_EBOUNDS half the time depending on
  -- which one the allocator put first. The raw payloads still define the window below --
  -- the rounding loses addressable bytes at the front of a segment, not permission.
  local segbase = {}
  for i = 1, nseg do
    segbase[i] = align32(payload[i])
    if (segbase[i] - payload[i]) + nl.SEG_BYTES > nl.CHUNK_BYTES then
      return fftsa.nl._abort(cb, pb)
    end
  end

  -- The first nseg chunks are the arena, then the plan struct, then the reduction's two
  -- arrays. The struct has its chunk to itself: the transform reads the capture in place,
  -- so there is no de-strided copy to place after it, and the room for that copy -- n
  -- doubles -- is what used to bound n at 4092 whatever the arena could hold.
  local host      = align32(payload[nseg + 1])
  local plan_addr = host
  if (host - payload[nseg + 1]) + align8(nl.SIZEOF_PLAN) > nl.CHUNK_BYTES then
    return fftsa.nl._abort(cb, pb)
  end

  -- dsp_reduce writes nseg entries into each of db and hz, and the trace count is a
  -- front-panel choice, so the room is reserved for the largest the app can ask for
  -- rather than for the one in force. Both are dsp_real, four bytes in the shipped image;
  -- SIZEOF_REAL comes out of the image so a single-precision build moves it.
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
  trace('done')
  return true
end

-- ---------------------------------------------------------------------------
-- Re-plan without reinstalling.
--
-- Only MODE_INIT depends on the sample count, the window and the beta, and all three are
-- front-panel choices: fftsa.apply() moves them on a press. The code, the trampoline, the
-- params struct and the arena are all exactly where init left them, so a press costs one
-- write_params and one call rather than a content scan, a relocation and an install -- and
-- an install is the thing that cannot be repeated without the trampoline being right.
--
-- The arena was sized for the count init was given, so this only goes DOWN from nl.nmax.
-- A larger count has no arena to be planned into and is refused here rather than left to
-- dsp_plan_init_segs, which would zero the plan and leave the app with a status code.
--
-- nl.ready is cleared for the duration: a frame dispatched from the timer between the
-- write and the return would otherwise run against a plan being rebuilt under it.
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
-- Run one frame. Returns the TRACE POINT count, which is what the app reports as nseg, or
-- nil with nl.last_rc set. Not the bin count: the run ends in dsp_reduce.
--
-- cap and out each describe one buffer's chunk storage:
--   chunk1, chunk2   payload addresses, chunk2 zero when one chunk holds it all
--   perchunk         elements per chunk, from the descriptor
--   lo, hi           the span the native code may touch in that buffer
--   out.desc         the column descriptor base, for the cursor rewind
--
-- Chunk payloads are placed independently by the allocator: 0x8010 is the block size, not
-- a pitch, and the second payload can sit below the first. So lo and hi span from the
-- lowest payload to the highest plus CHUNK_BYTES, and the native side additionally requires
-- each strided access to stay inside the chunk it starts in -- the span alone would permit
-- whatever else lives between two scattered payloads.
-- ---------------------------------------------------------------------------
-- red carries the reduction, which is everything the trace depends on and nothing the plan
-- does: nseg, the bin window k0..k1 (ZERO BASED, where the Lua implementation's bins are
-- one based), the decibel limits, the voltage floor, and the bin-to-hertz map. binhz is
-- measured per frame off the capture's own timestamps, so it is not a constant and does not
-- belong in the plan.
function fftsa.nl.call_dsp(cap, out, red)
  local nl = fftsa.nl
  if not nl.ready then return nil end
  if cap == nil or red == nil then return nil end
  -- The record is read in place through the chunk vector, so a descriptor without one is
  -- refused here rather than reaching the entry point as a zero address.
  if cap.vec == nil or cap.nchunks == nil or cap.nchunks < 1 then return nil end
  -- Checked here as well as natively, because a refusal from dsp_native_run arrives as a
  -- status code after the params have been written and reads the same as a bad address.
  local ns = red.nseg
  if ns == nil or ns < 1 or nl.nseg_max == nil or ns > nl.nseg_max then return nil end
  if red.binhz == nil or not (red.binhz > 0) then return nil end
  if red.k0 == nil or red.k1 == nil or red.k0 < 0 or red.k1 < red.k0 then return nil end
  if red.dbmin == nil or red.dbmax == nil or not (red.dbmin < red.dbmax) then return nil end
  -- out nil asks for the reduction and nothing else. The trace reaches the graph through
  -- buffer.write.reading, so there is nothing for the primitive to write into a reading
  -- buffer, and a descriptor of zero is what tells it so -- which also means no content
  -- scan to find that buffer's storage.
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
-- ONE ki.memread for the whole block and a decode per value, rather than a pair of peek32
-- per double or a reading buffer of its own. A buffer would need a chunk, a content scan
-- to find it and a window to validate, and Lua can only read as many elements as the
-- descriptor says are present -- so the scalars would have to live inside the trace the
-- graph plots.
--
-- The tables are allocated once and refilled, because this runs in a frame and the house
-- rule is to allocate at Apply. The peak tables are cleared to nil past the count found,
-- so a frame that finds fewer peaks than the last one cannot leave a stale row on screen.
--
-- Returns nil when there is nothing to read, which is what the caller gets before the
-- first run and after a failure. thd, snr and noise are nil when the measurement did not
-- apply: 0 dB and 0% are both real answers, so the native side sends a flag per figure
-- rather than a sentinel value.
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
-- display task works from its own copy of a bound buffer and buffer.write.reading is what
-- feeds it. No notify call reaches a write it never saw.
--
-- A value that does not decode to a finite number fails the whole call rather than leaving
-- a hole, because a nil reaching buffer.write.reading is a posted event per point.
--
-- The tables are allocated once and refilled, since this runs in a frame. The decibels are
-- refilled every call and the frequencies only when the plan behind them moves.
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
  -- change one. They are decoded once a plan rather than once a frame, which is half the
  -- values this call used to carry.
  --
  -- The two elements read here are those same two numbers -- element 1 is f0 and element 2
  -- is f0 + fstep -- so an equal pair, at an equal count and an equal address, is the same
  -- series to the last bit. Asking the array rather than recomputing the series from the
  -- span keeps one owner of the arithmetic: a cache that agreed with a formula here and not
  -- with the primitive would plot the right trace against the wrong axis.
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
  -- The two halves cost orders of magnitude apart, so they are cached apart. Finding
  -- storage sweeps the heap window, and its answer is a property of the allocation, which
  -- only a replacement can move -- so it is kept against the buffer it was measured on.
  -- Both halves sweep the heap, and both are cached, against different keys. Finding
  -- storage is keyed on the buffer, since only a replacement moves it. Finding the
  -- descriptor is keyed on the storage address, inside _find_desc, and its five words are
  -- re-read every call -- which is what makes calling describe() again cheap, and is how a
  -- chunk vector that lengthened is picked up. A chunk left outside lo..hi would be a
  -- refusal from the entry point on every frame.
  local nl = fftsa.nl
  local elem0, stride
  if nl._stor_of == buf and nl._stor_x == has_extras and nl._stor_elem0 ~= nil then
    elem0, stride = nl._stor_elem0, nl._stor_stride
  else
    nl._stor_of, nl._stor_x, nl._stor_elem0, nl._stor_stride = nil, nil, nil, nil
    elem0, stride = nl._find_storage(buf, has_extras)
    if elem0 then
      nl._stor_of, nl._stor_x = buf, has_extras
      nl._stor_elem0, nl._stor_stride = elem0, stride
    end
  end
  if not elem0 then return nil end
  local desc, elemsize, perchunk, vec, nchunks = fftsa.nl._find_desc(elem0)
  if not desc then return nil end
  -- TWO INDEPENDENT ANSWERS TO THE SAME QUESTION, so they have to agree: the stride the
  -- content scan measured from the spacing of the readings, and the element size the
  -- descriptor states. Disagreement means the hit is not this buffer's storage, or the
  -- descriptor is not this buffer's descriptor, and either way nothing below is safe.
  if elemsize ~= stride then return nil end
  -- The window must cover both payloads, and they are scattered: the second is often
  -- BELOW the first, measured at 0x360D600 and 0x36055F0. Taking hi from the second
  -- unconditionally gave hi < lo, which dsp_native_run rejects as EBOUNDS, so the native
  -- path would have failed closed on every frame and fallen back to dsp.spectrum. Span
  -- from the lowest to the highest, the same way nl.init does it.
  local ch2 = 0
  local lo  = elem0
  local hi  = elem0 + fftsa.nl.CHUNK_BYTES
  -- Every chunk the vector holds, because the native side reads the record in place and a
  -- long one spans many: 16,384 readings of 24 bytes is twelve chunks. The window is what
  -- it validates each payload address against, so a chunk left out of lo..hi is a refusal
  -- from the entry point rather than a bad read.
  --
  -- Bounded by the descriptor's own chunk count at +0x10, not by the capacity asked for.
  -- Reading one entry past the end returns whatever follows the vector in the heap, and a
  -- value that happened to look like a heap address would widen the window -- loosening
  -- the confinement instead of failing closed.
  if vec ~= nil and nchunks ~= nil and nchunks >= 1 then
    local i
    for i = 1, nchunks do
      local a = W(vec + (i - 1) * 4)
      if a == nil or a == 0 then return nil end
      if a < lo then lo = a end
      if a + fftsa.nl.CHUNK_BYTES > hi then hi = a + fftsa.nl.CHUNK_BYTES end
      if i == 2 then ch2 = a end
    end
  end
  return { chunk1 = elem0, chunk2 = ch2, perchunk = perchunk,
           elemsize = elemsize, desc = desc, vec = vec, nchunks = nchunks,
           lo = lo, hi = hi }
end
