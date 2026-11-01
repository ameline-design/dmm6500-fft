-- relocate_image.lua -- run the shipping relocation applier over a real image.
--
-- Loads tsp/native_link.tsp itself, so what runs here is the function that runs on the
-- instrument rather than a copy of it. tools/check_reloc.py then compares the output
-- against the same objects linked at the same address: if they agree, the applier does
-- exactly what a linker would have done.
--
--   lua relocate_image.lua <native_link.tsp> <image.bin> <table.bin> <base_hex> <out.bin>

local module_path = arg[1]
local image_path  = arg[2]
local table_path  = arg[3]
local base_hex    = arg[4]
local out_path    = arg[5]

if not (module_path and image_path and table_path and base_hex and out_path) then
  io.stderr:write('usage: relocate_image.lua <module> <image> <table> <base_hex> <out>\n')
  os.exit(2)
end

-- The module defines functions and tables and calls nothing, so it loads outside the
-- instrument. Anything that touched ki at load time would fail here, which is itself
-- worth knowing.
dofile(module_path)

if type(fftsa) ~= 'table' or type(fftsa.nl) ~= 'table'
   or type(fftsa.nl.relocate) ~= 'function' then
  io.stderr:write('native_link.tsp did not define fftsa.nl.relocate\n')
  os.exit(1)
end

local function slurp(p)
  local fh = io.open(p, 'rb')
  if not fh then
    io.stderr:write('cannot open ' .. p .. '\n')
    os.exit(1)
  end
  local s = fh:read('*a')
  fh:close()
  return s
end

local image = slurp(image_path)
local reloc = slurp(table_path)
local base  = tonumber(base_hex, 16)

local patched, err = fftsa.nl.relocate(image, reloc, base, nil)
if patched == nil then
  io.stderr:write('relocate refused: ' .. tostring(err) .. '\n')
  os.exit(1)
end
if string.len(patched) ~= string.len(image) then
  io.stderr:write(string.format('length changed: %d -> %d\n',
                                string.len(image), string.len(patched)))
  os.exit(1)
end

local fh = io.open(out_path, 'wb')
fh:write(patched)
fh:close()
