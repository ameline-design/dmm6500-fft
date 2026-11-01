-- native_link.tsp -- resolve library addresses and install the native DSP function.
--
-- Called once at startup; sets fftsa.nl.ready when the native path is available.
-- Falls back silently on any failure: the app then uses dsp.spectrum as before.
--
-- Nothing here is version-specific except the trampoline bytes and the addresses that
-- FNF resolves.  The trampoline bytes encode calls to dcbst_icbi_isync_range at
-- 0x004A9840 (1.7.17a); rebuild the trampoline from probe_codexec.py for other builds.
--
-- Lua 5.0.2: no '#', no hex literals, no string.byte multi-return, math.mod not fmod.

fftsa = fftsa or {}
fftsa.nl = {
  ready     = false,   -- true once the trampoline and DSP function are installed
  fn        = {},      -- GHS C math addresses: sin, cos, sqrt, log, ...
  tramp     = 0,       -- heap address of the 164-byte cache-flush trampoline
  dsp_entry = 0,       -- heap address of dsp_native_run entry point (CODE_BASE + 4)
  code_base = 0,       -- heap address of the binary start (CODE_BASE + 0 = params_addr slot)
  params    = 0,       -- heap address of the dsp_native_params struct
  code_buf  = nil,     -- buffer whose chunk storage holds the binary and the params struct
  plan_buf  = nil,     -- buffer whose chunk storage holds the dsp_plan arena
  peek8_cls = 0,       -- ki.peek8 closure address
  peek8_f   = 0,       -- original ki.peek8 f pointer (for restore)
}

-- The 164-byte cache-flush trampoline for 1.7.17a.
-- Reads two hex strings from the Lua stack (address, count) and calls
-- dcbst_icbi_isync_range(addr, count) at 0x004A9840.
-- Position-independent; rebuild with probe_codexec.py for other firmware versions.
fftsa.nl._TRAMP = '\148\033\255\208\124\008\002\166\144\001\000\052\147\225\000\044\147\193\000\040\124\127\027\120\056\128\000\001\061\128\000\033\097\140\232\104\125\137\003\166\078\128\004\033\056\129\000\008\061\128\000\075\097\140\254\156\125\137\003\166\078\128\004\033\124\126\027\120\127\227\251\120\056\128\000\002\061\128\000\033\097\140\232\104\125\137\003\166\078\128\004\033\056\129\000\008\061\128\000\075\097\140\254\156\125\137\003\166\078\128\004\033\124\100\027\120\127\195\243\120\061\128\000\074\097\140\152\064\125\137\003\166\078\128\004\033\056\096\000\000\128\001\000\052\124\008\003\166\131\225\000\044\131\193\000\040\056\033\000\048\078\128\000\032'

-- The compiled native DSP function (set to a string of PPC bytes before nl.init).
-- Nil means "no binary yet"; nl.init still installs the trampoline but leaves
-- nl.ready false until the binary is provided and the app is restarted.
fftsa.nl._DSP_CODE = nil

-- FNF: scan a Form E closure's .text handler for the first bl to >= 0x00400000.
-- That address is the underlying GHS C function (double f1 -> double f1).
-- Works across builds as long as the Lua math wrapper structure is preserved.
function fftsa.nl.FNF(fn)
  local s = tostring(fn)
  local _, e = string.find(s, ': ')
  if not e then return nil end
  local c = tonumber(string.sub(s, e+1), 16)
  if not c then return nil end
  local w = tonumber(ki.peek32(string.format('%X', c+12)), 16)
  if not w then return nil end
  for i = 0, 255 do
    local pc = w + i*4
    local n = tonumber(ki.peek32(string.format('%X', pc)), 16)
    if n == nil then return nil end
    if math.floor(n/67108864) == 18 and math.mod(n,2) == 1 then
      local r = math.mod(math.floor(n/4), 16777216)
      if r >= 8388608 then r = r - 16777216 end
      local t = math.mod(pc + r*4, 4294967296)
      if t >= 4194304 then return t end   -- 0x00400000
    end
  end
  return nil
end

-- Build the math function address table from the Lua standard library.
-- Returns the number of addresses found.
function fftsa.nl.resolve_math()
  local fn = fftsa.nl.fn
  local names = {
    'sin', 'cos', 'sqrt', 'exp', 'log', 'log10',
    'tan', 'asin', 'acos', 'atan', 'atan2', 'floor', 'ceil',
  }
  local found = 0
  local k
  for k = 1, table.getn(names) do
    local nm = names[k]
    local addr = fftsa.nl.FNF(math[nm])
    fn[nm] = addr
    if addr then found = found + 1 end
  end
  -- lua_pushnumber is resolved from a function that wraps it; pick math.sqrt's wrapper
  -- and scan for the call with the opposite direction (wrapper calls pushnumber after
  -- the computation).  For now, use the known 1.7.17a address as the fallback.
  fn.lua_pushnumber = 2223908  -- 0x0021EF24 on 1.7.17a (confirmed by disassembly)
  return found
end

-- FINDS helper (content scan over a heap range).
-- Installed once; see probe_chunkhdr.py for the full implementation.
-- NOTE: no Python % on this string, so %08X is a Lua format specifier.
function fftsa.nl._install_finds()
  FINDS = nil
  -- one statement, under the 1024-byte limit
  local r = nil   -- the statement that defines FINDS is sent by nl.init()
  return false    -- FINDS is installed by the caller below
end

-- Unpack a 4-byte big-endian string at position p in str (1-based Lua index).
local function u32_at(str, p)
  local b1, b2, b3, b4 =
    string.byte(str, p), string.byte(str, p+1),
    string.byte(str, p+2), string.byte(str, p+3)
  return ((b1*256 + b2)*256 + b3)*256 + b4
end

-- Pack a uint32 as 4 big-endian bytes.
local function u32_pack(v)
  v = math.mod(v, 4294967296)
  local b4 = math.mod(v, 256); v = math.floor(v/256)
  local b3 = math.mod(v, 256); v = math.floor(v/256)
  local b2 = math.mod(v, 256)
  local b1 = math.floor(v/256)
  return string.char(b1, b2, b3, b4)
end

-- Build and write the dsp_native_params struct.
-- Field order matches dsp_native.c dsp_native_params exactly.
-- Math function addresses are resolved by FNF at startup; memcpy/memset/fabs
-- are implemented directly in dsp_native.c and need no address here.
function fftsa.nl.write_params(cap_ch1, cap_ch2, cap_n,
                                out_ch1, out_ch2,
                                out_cursor, out_n0, out_n1,
                                plan_addr)
  local fn = fftsa.nl.fn
  local s = u32_pack(fn.lua_pushnumber or 0)
           -- math functions (firmware .text, resolved at startup by FNF)
           .. u32_pack(fn.sin   or 0)
           .. u32_pack(fn.cos   or 0)
           .. u32_pack(fn.tan   or 0)
           .. u32_pack(fn.asin  or 0)
           .. u32_pack(fn.acos  or 0)
           .. u32_pack(fn.atan  or 0)
           .. u32_pack(fn.atan2 or 0)
           .. u32_pack(fn.sqrt  or 0)
           .. u32_pack(fn.exp   or 0)
           .. u32_pack(fn.log   or 0)
           .. u32_pack(fn.log10 or 0)
           .. u32_pack(fn.floor or 0)
           .. u32_pack(fn.ceil  or 0)
           -- per-frame data
           .. u32_pack(cap_ch1 or 0)
           .. u32_pack(cap_ch2 or 0)
           .. u32_pack(cap_n or 0)
           .. u32_pack(out_ch1 or 0)
           .. u32_pack(out_ch2 or 0)
           .. u32_pack(out_cursor or 0)
           .. u32_pack(out_n0 or 0)
           .. u32_pack(out_n1 or 0)
           .. u32_pack(plan_addr or 0)
  ki.memwrite(string.format('%X', fftsa.nl.params), s)
end

-- Find the element storage of a buffer using a content scan over +-8 MB.
-- Requires FINDS to be installed and 3 readings already written to buf.
-- Returns element slot 0 address, or nil.
function fftsa.nl._find_storage(buf)
  -- needle: reading[1] = 1000001.0 big-endian double
  local needle = '\065\046\132\130\000\000\000\000'
  local hlo    = 17825792   -- 0x01100000
  local hhi    = 150994944  -- 0x09000000
  if not (type(FINDS) == 'function') then return nil end
  local r = FINDS(hlo, hhi, needle)
  if not r or string.len(r) == 0 then return nil end
  -- Walk hits (space-separated 8-char hex addresses) for the element array.
  local pos = 1
  while pos <= string.len(r) do
    local sp = string.find(r, ' ', pos, true)
    if not sp then sp = string.len(r)+1 end
    local hs = string.sub(r, pos, sp-1)
    pos = sp + 1
    if string.len(hs) == 8 then
      local h = tonumber(hs, 16)
      if h then
        -- reading[2] = 1000002.0: high word 0x412E8484
        local v2 = tonumber(ki.peek32(string.format('%X', h+32)), 16)
        local v2lo = tonumber(ki.peek32(string.format('%X', h+36)), 16)
        if v2 and v2 == tonumber('412E8484', 16) and v2lo == 0 then
          -- reading[3] = 1000003.0: high word 0x412E8486
          local v3 = tonumber(ki.peek32(string.format('%X', h+64)), 16)
          if v3 and v3 == tonumber('412E8486', 16) then
            return h
          end
        end
      end
    end
  end
  return nil
end

-- Install the FINDS content-scan helper on the instrument.
-- Returns true if FINDS became available.
function fftsa.nl._ensure_finds()
  if type(FINDS) == 'function' then return true end
  -- one statement under the 1024-byte limit; no Python % so %08X is Lua
  local r = nil
  -- Uses ki.memread directly, not KG.read: KG is only available on the instrument
  -- during a probe session, not inside a packaged .tspa application.
  r = (loadstring or load)(
    "do function FINDS(lo,hi,pat) local a=lo local out={} local pl=string.len(pat) "
    .. "while a<hi do local n=32768 if a+n>hi then n=hi-a end "
    .. "local s=ki.memread(string.format('%X',a),string.format('%X',n)) "
    .. "if s~=nil then local i=1 "
    .. "while true do local j=string.find(s,pat,i,true) if j==nil then break end "
    .. "table.insert(out,a+j-1) i=j+1 end end "
    .. "if a+n>=hi then break end a=a+n-(pl-1) end "
    .. "local t={} local k for k=1,table.getn(out) do "
    .. "t[k]=string.format('%08X ',out[k]) end return table.concat(t) end end")
  if r then r() end
  return type(FINDS) == 'function'
end

-- Main init. Called once at app startup before any frame processing.
-- barrier_buf: any existing buffer (needed for the IPC barrier).
-- Returns true if the native path is ready.
function fftsa.nl.init(barrier_buf)
  local nl = fftsa.nl
  nl.ready = false

  -- 1. Resolve library function addresses.
  if nl.resolve_math() < 5 then return false end

  -- 2. Locate ki.peek8's closure.
  local s = tostring(ki.peek8)
  local _, e = string.find(s, ': ')
  if not e then return false end
  local cls = tonumber(string.sub(s, e+1), 16)
  if not cls then return false end
  local orig_f = tonumber(ki.peek32(string.format('%X', cls+12)), 16)
  if not orig_f then return false end
  nl.peek8_cls = cls
  nl.peek8_f   = orig_f

  -- 3. Ensure the content-scan helper is installed.
  if not nl._ensure_finds() then return false end

  -- 4. Allocate a code buffer.  Capacity 256 elements = 8192 bytes of chunk storage.
  --    Layout in chunk 1 (starts at code_base):
  --      [0x00]  4 bytes: dsp_native_params_addr slot (CODE_BASE + 0)
  --      [0x04]  dsp_native_run entry point            (CODE_BASE + 4)
  --      [0x100] 164 bytes: cache-flush trampoline
  --      remaining: dsp_native_params struct (40 bytes)
  local cb = buffer.make(256, buffer.STYLE_WRITABLE_FULL)
  buffer.write.format(cb, buffer.UNIT_VOLT, buffer.DIGITS_6_5,
                      buffer.UNIT_VOLT, buffer.DIGITS_6_5)
  local k
  for k = 1, 3 do
    buffer.write.reading(cb, 1000000+k, 3000000+k, k, 0)
  end
  buffer.getstats(barrier_buf)

  local code_base = nl._find_storage(cb)
  if not code_base then
    buffer.delete(cb)
    return false
  end
  nl.code_buf  = cb
  nl.code_base = code_base

  -- 5. Install the trampoline at code_base + 256 (8 element slots past the binary).
  --    The binary is installed later; the trampoline goes here to avoid overlap.
  local tramp_addr = code_base + 256
  ki.memwrite(string.format('%X', tramp_addr), nl._TRAMP)
  buffer.getstats(barrier_buf)

  -- Bootstrap the trampoline: use only the IPC barrier for the first execution.
  local orig_h = ki.peek32(string.format('%X', cls+12))
  ki.poke32(string.format('%X', cls+12), string.format('%08X', tramp_addr))
  ki.peek8(string.format('%X', tramp_addr),
           string.format('%X', string.len(nl._TRAMP)))
  ki.poke32(string.format('%X', cls+12), orig_h)
  nl.tramp = tramp_addr

  -- 6. The params struct lives at code_base + 512 (16 element slots from start).
  nl.params = code_base + 512

  -- 7. Install the DSP function bytes if provided.
  --    The binary is purely .text: dsp_native_run is at offset 0 (CODE_BASE).
  --    The params address is passed as arg 1 via the Lua stack, not via a global.
  if nl._DSP_CODE ~= nil and string.len(nl._DSP_CODE) > 0 then
    local dsp_code = nl._DSP_CODE
    ki.memwrite(string.format('%X', code_base), dsp_code)
    buffer.getstats(barrier_buf)
    -- Flush the DSP binary via the trampoline.
    local orig_h2 = ki.peek32(string.format('%X', cls+12))
    ki.poke32(string.format('%X', cls+12), string.format('%08X', tramp_addr))
    ki.peek8(string.format('%X', code_base),
             string.format('%X', string.len(dsp_code)))
    ki.poke32(string.format('%X', cls+12), orig_h2)

    nl.dsp_entry = code_base   -- entry at binary offset 0
    nl.ready     = true
  end

  return nl.ready
end

-- Redirect ki.peek8 to the native DSP function, call it with the params address,
-- and restore.  Returns the bin count (an integer), or nil on failure.
function fftsa.nl.call_dsp()
  local nl = fftsa.nl
  if not nl.ready then return nil end
  local cls_hex    = string.format('%X', nl.peek8_cls + 12)
  local orig_hex   = string.format('%08X', nl.peek8_f)
  local params_hex = string.format('%X', nl.params)
  ki.poke32(cls_hex, string.format('%08X', nl.dsp_entry))
  -- Arg 1 on the Lua stack: the params struct address as a hex string.
  -- dsp_native_run parses it with lua_tostring + hexparse (firmware addresses).
  local result = ki.peek8(params_hex)
  ki.poke32(cls_hex, orig_hex)
  return result
end

-- Restore ki.peek8 to its original f pointer.  Called from the finally block
-- of any code path that may have redirected it.
function fftsa.nl.restore_peek8()
  if fftsa.nl.peek8_cls ~= 0 then
    ki.poke32(string.format('%X', fftsa.nl.peek8_cls + 12),
              string.format('%08X', fftsa.nl.peek8_f))
  end
end
