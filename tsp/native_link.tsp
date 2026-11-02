-- native_link.tsp -- load the native DSP binary into heap and make it callable.
--
-- Called once at startup; sets fftsa.nl.ready when the native path is available.
-- Falls back silently on any failure: the app then uses dsp.spectrum as before.
--
-- Version-specific pieces: the trampoline bytes, which encode a call to
-- dcbst_icbi_isync_range at 0x004A9840 (1.7.17a), and the two firmware addresses
-- compiled into dsp_native.c. Everything else is resolved at runtime.
--
-- Lua 5.0.2: no '#', no hex literals, no multi-return string.byte, math.mod not fmod.

fftsa = fftsa or {}
fftsa.nl = {
  ready     = false,  -- true once the binary is loaded, relocated and the plan is built
  fn        = {},     -- firmware math addresses resolved by FNF
  tramp     = 0,      -- heap address of the 164-byte cache-flush trampoline
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

-- Status codes dsp_native.c pushes back. Non-negative is a result.
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
fftsa.nl.PARAM_WORDS = 51

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

-- The 164-byte cache-flush trampoline for 1.7.17a. Reads two hex strings from the Lua
-- stack (address, count) and calls dcbst_icbi_isync_range. Position-independent: it has
-- no data references and reaches the firmware through lis/ori/mtctr/bctrl.
-- Rebuild with probe_codexec.py for other firmware versions.
fftsa.nl._TRAMP = '\148\033\255\208\124\008\002\166\144\001\000\052\147\225\000\044\147\193\000\040\124\127\027\120\056\128\000\001\061\128\000\033\097\140\232\104\125\137\003\166\078\128\004\033\056\129\000\008\061\128\000\075\097\140\254\156\125\137\003\166\078\128\004\033\124\126\027\120\127\227\251\120\056\128\000\002\061\128\000\033\097\140\232\104\125\137\003\166\078\128\004\033\056\129\000\008\061\128\000\075\097\140\254\156\125\137\003\166\078\128\004\033\124\100\027\120\127\195\243\120\061\128\000\074\097\140\152\064\125\137\003\166\078\128\004\033\056\096\000\000\128\001\000\052\124\008\003\166\131\225\000\044\131\193\000\040\056\033\000\048\078\128\000\032'

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
-- Base64, so the image is 1.34 characters a byte in the archive instead of 4.
--
-- ki.memwrite takes its length from lua_strlen rather than strlen, so the embedded NULs a
-- binary is full of survive a Lua string; what does not survive is Lua 5.0.2 having no
-- \xNN escape, which left decimal as the only literal form and made 27 KB of image into
-- 109 KB of script source. That source is read and parsed at every app launch. This is
-- decoded once, in nl.init.
--
-- NO PADDING AND NO TAIL CASE: embed_native.py pads the binary to a multiple of three and
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
function fftsa.nl.resolve_math()
  local fn = fftsa.nl.fn
  local names = { 'sin', 'cos', 'sqrt', 'log10', 'floor', 'ceil' }
  local found = 0
  local k
  for k = 1, table.getn(names) do
    local nm = names[k]
    fn[nm] = fftsa.nl.FNF(math[nm])
    if fn[nm] then found = found + 1 end
  end
  -- lua_pushnumber is not behind a math wrapper, so it is the one address FNF cannot
  -- reach. Confirmed by disassembly: li r0,3; stfd f1,8(r11).
  fn.lua_pushnumber = 2223908   -- 0x0021EF24 on 1.7.17a
  return found
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
-- Elements _find_storage confirms a hit against, and so the number of readings nl.init
-- seeds a buffer with. One name, because a seed shorter than the confirmation makes the
-- scan refuse the very buffer it was seeded for.
fftsa.nl.SEED_READS = 6
local READ_CONFIRM = fftsa.nl.SEED_READS

function fftsa.nl._find_storage(buf)
  local n = buf.n
  if n == nil or n < READ_CONFIRM then return nil end
  local rd, ex = {}, nil
  local i
  for i = 1, READ_CONFIRM do
    rd[i] = buf.readings[i]
    if rd[i] == nil then return nil end
  end
  -- A STYLE_STANDARD buffer has no extra values, and reading the attribute is the only way
  -- to find out; a refusal there is an answer, not a failure.
  local ok, e = pcall(function()
    return { buf.extravalues[1], buf.extravalues[2], buf.extravalues[3] }
  end)
  if ok and e[1] ~= nil and e[2] ~= nil and e[3] ~= nil then ex = e end
  -- Nothing to discriminate on: identical readings and no extras means every element
  -- matches and the first hit decides, which is a guess. Refuse instead.
  if ex == nil then
    local differs = false
    for i = 2, READ_CONFIRM do
      if rd[i] ~= rd[1] then differs = true end
    end
    if not differs then return nil end
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
      local good = true
      for i = 2, READ_CONFIRM do
        if not eq64(h + (i - 1) * 32, rd[i]) then good = false end
      end
      if good and ex ~= nil then
        for i = 1, 3 do
          if not eq64(h + (i - 1) * 32 + 20, ex[i]) then good = false end
        end
      end
      if good then return h end
    end
  end
  return nil
end

-- The column descriptor for a buffer, from its element storage address.
-- Steps 3 to 5 of the recipe in fwmem-BUFFER.md: find the storage address as a word,
-- the descriptor starts 0x48 below it, then confirm with the two self-pointers and the
-- chunk geometry. Returns descriptor base, elemsize, perchunk, chunk vector.
function fftsa.nl._find_desc(elem0)
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
        if elemsize ~= nil and perchunk ~= nil and nchunks ~= nil and
           nchunks > 0 and nchunks < 4096 and
           elemsize * perchunk == fftsa.nl.CHUNK_BYTES then
          -- 0x44 is the chunk vector. The count comes back with it because a caller
          -- indexing the vector has no other way to know where it ends: reading one
          -- entry too far returns whatever follows it in the heap, and an address that
          -- happens to land in the heap would pass the backstop and be written to.
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
    t.src_flat or 0,
    t.cap_chunk1 or 0, t.cap_chunk2 or 0, t.cap_n or 0, t.cap_perchunk or 0,
    t.out_chunk1 or 0, t.out_chunk2 or 0, t.out_perchunk or 0, t.out_desc or 0,
    fn.lua_pushnumber or 0,
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
local function via_peek8(addr, a1, a2)
  local nl = fftsa.nl
  if nl.peek8_cls == 0 then return nil, 'no closure' end
  -- Checked on the way in, not just at capture: the restore below is unconditional, so
  -- if this is wrong the redirect must not happen at all.
  if not nl._text_ok(nl.peek8_f) then return nil, 'restore value not in .text' end
  local slot = hx(nl.peek8_cls + 12)
  local orig = string.format('%08X', nl.peek8_f)
  ki.poke32(slot, string.format('%08X', addr))
  local ok, r
  if a2 ~= nil then
    ok, r = pcall(ki.peek8, a1, a2)
  else
    ok, r = pcall(ki.peek8, a1)
  end
  ki.poke32(slot, orig)
  -- nl.last_call records whether the branch returned normally, because the return value
  -- cannot. The trampoline ends in `li r3,0`, so a successful flush yields zero Lua values
  -- and r is nil -- which is precisely what a raised error produces here too. Three runs
  -- of probe_native.py reported the self-flush "clean" on the strength of a nil that
  -- proved nothing, and it went into the notes as an established result. Callers that care
  -- whether the code actually ran must read nl.last_call, not the return value.
  fftsa.nl.last_call = ok
  if not ok then
    fftsa.nl.last_err = tostring(r)
    return nil, r
  end
  fftsa.nl.last_err = nil
  return r
end
fftsa.nl._via_peek8 = via_peek8

-- Flush written code out of the D-cache and invalidate the I-cache for it.
local function flush(addr, len)
  local nl = fftsa.nl
  if nl.tramp == nil or nl.tramp == 0 then return false end
  if addr == nil or len == nil or len <= 0 then return false end
  -- REFUSE TO FLUSH THE TRAMPOLINE'S OWN RANGE. icbi on a line the CPU is executing from,
  -- followed by isync, forces a re-fetch mid-function; that is the fault behind two
  -- bluescreens. The caller has no business asking for it -- the barrier alone bootstraps
  -- a fresh line -- so this is a refusal rather than a special case.
  local tlo = nl.tramp
  local thi = nl.tramp + string.len(nl._TRAMP)
  if addr < thi and addr + len > tlo then return false end
  via_peek8(nl.tramp, hx(addr), hx(len))
  -- last_call, not the return value: the trampoline returns zero Lua values on success, so
  -- nil cannot distinguish a clean flush from a raised error.
  return nl.last_call == true
end
fftsa.nl.flush = flush

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
  nl.src_flat  = nil
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
  -- Zero means the generated module never loaded, and every size below would be wrong in
  -- a way that still produces addresses.
  if nl.SIZEOF_REAL == 0 or nl.SIZEOF_PLAN == 0 or nl.SIZEOF_PARAMS == 0 or
     nl.RES_DOUBLES == 0 or nl.RES_PEAKS == 0 then
    return false
  end

  -- THE CHUNK IS WHAT BOUNDS n, and the bound is computed from the sizes the image
  -- reports rather than written down. The de-strided capture is n doubles and has to be
  -- contiguous, so it has to fit one 32 KB chunk behind the plan struct; separately
  -- dsp_plan_init_segs puts the window, n entries of dsp_real, in a chunk of its own.
  -- With dsp_real as double that is 2048 for both, the next power of two over. Single
  -- precision would double it, which is one of the things that build variant is for.
  local nmax = math.floor((nl.CHUNK_BYTES - 32 - align8(nl.SIZEOF_PLAN)) / 8)
  local sgmax = math.floor((nl.CHUNK_BYTES - 32) / nl.SIZEOF_REAL)
  if nmax > sgmax then nmax = sgmax end
  nl.nceil = nmax
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
  local code_base = nl._find_storage(cb)
  if not code_base then return fftsa.nl._abort(cb) end
  trace('code_base', hx(code_base))
  nl.code_buf  = cb
  nl.code_base = code_base

  -- 4. Layout, derived from the image rather than fixed: the image is tens of
  --    kilobytes, so a trampoline at a fixed +256 sits inside it.
  local img_span   = align8(nl._DSP_RELOC_BSS_HI)
  if img_span < align8(string.len(nl._DSP_CODE)) then
    img_span = align8(string.len(nl._DSP_CODE))
  end
  local tramp_at   = code_base + img_span
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
  -- NO SELF-FLUSH. The trampoline used to be asked to flush its own range as its first
  -- act, and that is what bluescreened twice: dcbst_icbi_isync_range runs icbi on the
  -- cache lines the CPU is executing from and then isync, which forces a re-fetch of the
  -- instruction stream in the middle of the function. PC 0x035DA468 was trampoline+64, an
  -- `mr r30,r3` that cannot fault as a data access but can certainly fail to be fetched.
  --
  -- It was never needed either. probe_tramp.py ran a 184-byte stub at a heap address with
  -- the barrier alone and no flush of any kind, and it returned correct values -- the first
  -- instruction fetch of a line that has not been fetched since boot snoops the D-cache,
  -- so the barrier is sufficient to bootstrap. The trampoline earns its keep flushing
  -- OTHER ranges, which is what the image needs; it must never be pointed at itself.
  trace('tramp.ok')

  -- 6. The image, patched for this load address.
  local img, err = nl.relocate(nl._DSP_CODE, nl._DSP_RELOC, code_base,
                               nl._DSP_RELOC_BSS_HI)
  if img == nil then return fftsa.nl._abort(cb) end
  trace('img.reloc', string.len(img))
  ki.memwrite(hx(code_base), img)
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
  local nseg = via_peek8(code_base, hx(nl.params))
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
  local pdesc = nl.describe(pb)
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

  -- The first nseg chunks are the arena. Then the plan struct with the de-strided capture
  -- after it, and the reduction's two arrays in a chunk of their own.
  local host      = align32(payload[nseg + 1])
  local plan_addr = host
  local src_flat  = host + align8(nl.SIZEOF_PLAN)
  if (src_flat - payload[nseg + 1]) + want_n * 8 > nl.CHUNK_BYTES then
    return fftsa.nl._abort(cb, pb)
  end

  -- dsp_reduce writes nseg entries into each of db and hz, and the trace count is a
  -- front-panel choice, so the room is reserved for the largest the app can ask for
  -- rather than for the one in force. Both are dsp_real, which is double in this build;
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
    plan_addr = plan_addr, src_flat = src_flat, cap_n = want_n,
    init_kind = kind or 1,
    init_beta_milli = math.floor((beta or 0) * 1000),
    init_decim = decim or 1, init_method = method or 0,
  })
  trace('call.init')
  local rc = via_peek8(code_base, hx(nl.params))
  trace('call.init.ret', tostring(rc))
  nl.last_rc = rc
  if rc ~= 0 then
    return fftsa.nl._abort(cb, pb)
  end

  nl.plan_addr = plan_addr
  nl.seg_bytes = nl.SEG_BYTES
  nl.nsegs     = nseg
  nl.segs_addr = segs_addr
  nl.src_flat  = src_flat
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
    plan_addr = nl.plan_addr, src_flat = nl.src_flat, cap_n = want_n,
    init_kind = kind,
    init_beta_milli = math.floor(beta * 1000),
    init_decim = decim, init_method = method,
  })
  if not ok then return false end
  local rc = via_peek8(nl.entry, hx(nl.params))
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
  if cap == nil or out == nil or red == nil then return nil end
  -- Checked here as well as natively, because a refusal from dsp_native_run arrives as a
  -- status code after the params have been written and reads the same as a bad address.
  local ns = red.nseg
  if ns == nil or ns < 1 or nl.nseg_max == nil or ns > nl.nseg_max then return nil end
  if red.binhz == nil or not (red.binhz > 0) then return nil end
  if red.k0 == nil or red.k1 == nil or red.k0 < 0 or red.k1 < red.k0 then return nil end
  if red.dbmin == nil or red.dbmax == nil or not (red.dbmin < red.dbmax) then return nil end

  local ok = nl.write_params({
    mode = nl.MODE_RUN,
    wr_lo = nl.wr_lo, wr_hi = nl.wr_hi,
    rd_lo = cap.lo, rd_hi = cap.hi,
    out_lo = out.lo, out_hi = out.hi,
    seg_bytes = nl.seg_bytes, nsegs = nl.nsegs, segs_addr = nl.segs_addr,
    plan_addr = nl.plan_addr, src_flat = nl.src_flat,
    cap_chunk1 = cap.chunk1, cap_chunk2 = cap.chunk2,
    cap_n = nl.n, cap_perchunk = cap.perchunk,
    out_chunk1 = out.chunk1, out_chunk2 = out.chunk2,
    out_perchunk = out.perchunk, out_desc = out.desc,
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

  local r = via_peek8(nl.entry, hx(nl.params))
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

-- Describe a buffer's storage for call_dsp, from the content scan and descriptor walk.
-- Returns nil if either step fails, so a caller cannot build a half-filled table.
function fftsa.nl.describe(buf)
  local elem0 = fftsa.nl._find_storage(buf)
  if not elem0 then return nil end
  local desc, elemsize, perchunk, vec, nchunks = fftsa.nl._find_desc(elem0)
  if not desc then return nil end
  -- The window must cover both payloads, and they are scattered: the second is often
  -- BELOW the first, measured at 0x360D600 and 0x36055F0. Taking hi from the second
  -- unconditionally gave hi < lo, which dsp_native_run rejects as EBOUNDS, so the native
  -- path would have failed closed on every frame and fallen back to dsp.spectrum. Span
  -- from the lowest to the highest, the same way nl.init does it.
  local ch2 = 0
  local lo  = elem0
  local hi  = elem0 + fftsa.nl.CHUNK_BYTES
  -- ONLY WHEN THE DESCRIPTOR SAYS THERE IS A SECOND CHUNK. A one-chunk buffer -- which is
  -- any capacity up to 1024 elements, so both of the app's -- has a one-entry vector, and
  -- reading past it returns whatever follows in the heap. That value would widen lo..hi,
  -- which is the window the native side validates every write against, so it loosens the
  -- confinement rather than failing closed.
  if vec ~= nil and nchunks ~= nil and nchunks > 1 then
    local second = W(vec + 4)
    if second ~= nil and second ~= 0 then
      ch2 = second
      if second < lo then lo = second end
      if second + fftsa.nl.CHUNK_BYTES > hi then hi = second + fftsa.nl.CHUNK_BYTES end
    end
  end
  return { chunk1 = elem0, chunk2 = ch2, perchunk = perchunk,
           elemsize = elemsize, desc = desc, vec = vec, nchunks = nchunks,
           lo = lo, hi = hi }
end
