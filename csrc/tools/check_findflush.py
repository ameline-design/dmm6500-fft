#!/usr/bin/env python3
"""Gate: fftsa.nl.find_flush locates a range-flush routine by its instructions.

The cache-flush routine is the one firmware address the native path cannot do without and
cannot be handed: the image is written to the heap and then branched into, and the bytes
have to reach memory and the stale instruction lines have to go before that branch. Pinning
the address to one build means a firmware upgrade turns the call into a branch to whatever
occupies that address now, which is a bluescreen and not a refusal.

So the routine is identified by what it does -- dcbst over the range, icbi over the same
range, isync before returning. This gate builds a PowerPC text image with a flush routine
planted in it, plus the decoys that make the search non-trivial, and requires the sweep to
return the planted entry. The instrument's own text cannot be read here, so what is proven
is the method and the decoding, not the answer on any particular build.

The function under test is extracted from the shipping module, not copied, because a copy
is a thing that passes while the original has moved.

    python3 -I csrc/tools/check_findflush.py
    python3 -I csrc/tools/check_findflush.py --self-test
"""
import os
import struct
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MODULE = os.path.join(ROOT, 'tsp', 'native_link.tsp')
LUA502 = os.environ.get('LUA502',
                        os.path.expanduser('~/tmp/lua502/lua-5.0.2/bin/lua'))

HEAD = 'fftsa.nl.OP_ISYNC'
TAIL = '\n-- ---------------------------------------------------------------------------\n-- Relocation.'

PRELUDE = """fftsa = { nl = { TEXT_LO = 0, TEXT_HI = 0 } }
local MEM = {}
local function hx(v) return string.format('%X', v) end
ki = {
  memread = function(addr, len)
    local a, n = tonumber(addr, 16), tonumber(len, 16)
    local b, v
    for b, v in pairs(MEM) do
      if a >= b and a < b + string.len(v) then
        return string.sub(v, a - b + 1, a - b + n)
      end
    end
    return nil
  end,
  peek32 = function(addr)
    local a = tonumber(addr, 16)
    local b, v
    for b, v in pairs(MEM) do
      if a >= b and a + 4 <= b + string.len(v) then
        local o = a - b + 1
        local w = 0
        local i
        for i = 0, 3 do w = w * 256 + string.byte(v, o + i) end
        return string.format('%08X', w)
      end
    end
    return nil
  end,
}
local function W(addr) return tonumber(ki.peek32(hx(addr)), 16) end
function setmem(a, s) MEM[a] = s end
"""

# PowerPC words. Register fields vary on purpose, so the masks have to ignore them.
BLR = 0x4E800020
NOP = 0x60000000
ISYNC = 0x4C00012C
SYNC = 0x7C0004AC
MFLR_R0 = 0x7C0802A6


def x31(xo, ra=3, rb=4):
    """Primary opcode 31 with extended opcode xo, in registers ra and rb."""
    return (31 << 26) | (ra << 16) | (rb << 11) | (xo << 1)


DCBST = x31(54, ra=9, rb=11)
ICBI = x31(982, ra=7, rb=8)


def asm(words):
    return b''.join(struct.pack('>I', w) for w in words)


def image():
    """A text image: the planted flush routine, and four decoys around it."""
    base = 0x00004000
    words = []
    marks = {}

    def put(name=None):
        if name:
            marks[name] = base + 4 * len(words)

    # A plain function that returns, so the sweep has a preceding blr to stop at.
    words += [MFLR_R0, 0x38600000, BLR]

    # Decoy 1: an isync with no cache ops near it -- a context switch or an mtmsr sequence.
    words += [0x7C000124, ISYNC, 0x38600000, BLR]

    # Decoy 2: dcbst without icbi, which is a data-only writeback helper.
    words += [DCBST, SYNC, ISYNC, 0x38600000, BLR]

    # Decoy 3: icbi without dcbst, an instruction-only invalidate.
    words += [ICBI, ISYNC, 0x38600000, BLR]

    # Padding the entry search has to skip.
    words += [NOP, NOP]

    # The routine. Entry, a loop issuing both cache ops, then sync/isync and return.
    put('flush')
    words += [MFLR_R0, 0x7C0903A6]            # prologue, mtctr
    words += [DCBST, 0x38A50020]              # dcbst; addi r5,r5,32
    words += [0x4200FFF8]                     # bdnz back
    words += [SYNC]
    words += [ICBI, 0x38A50020, 0x4200FFF8]
    words += [SYNC, ISYNC]
    words += [0x38600000, BLR]

    # A trailing function, so the planted one is not last in the image.
    words += [MFLR_R0, 0x38600001, BLR]

    return base, asm(words), marks


def esc(data):
    return ''.join('\\%d' % b for b in data)


def extract(module):
    with open(module, 'r') as f:
        src = f.read()
    a = src.find(HEAD)
    b = src.find(TAIL, a + 1)
    if a < 0 or b < a:
        raise SystemExit('find_flush not found in %s; markers are %r and %r'
                         % (module, HEAD, TAIL))
    return src[a:b]


def build(module):
    body = extract(module)
    base, img, marks = image()
    want = marks['flush']
    lo, hi = base, base + len(img)
    cases = []

    cases.append(('the planted routine is found, and nothing else is', """
setmem(%d, '%s')
local a, seen = fftsa.nl.find_flush(%d, %d, 256, 96)
if a ~= %d then return string.format('found %%s, wanted %%d (seen %%s)',
                                    tostring(a), %d, tostring(seen)) end
if seen ~= 1 then return 'candidates seen: ' .. tostring(seen) end
return nil
""" % (base, esc(img), lo, hi, want, want)))

    # The sweep must not depend on where the chunk boundaries fall: every instruction is
    # 4-aligned and chunks are a multiple of four, so no window is lost at a seam.
    cases.append(('the answer is the same at every chunk size', """
setmem(%d, '%s')
local sizes = {4, 8, 16, 64, 256, 1024, 65536}
local i
for i = 1, 7 do
  local a = fftsa.nl.find_flush(%d, %d, sizes[i], 96)
  if a ~= %d then
    return string.format('chunk %%d found %%s', sizes[i], tostring(a))
  end
end
return nil
""" % (base, esc(img), lo, hi, want)))

    # An isync that is not 4-aligned is data, not an instruction.
    unaligned = b'\x00' + struct.pack('>I', ISYNC) + asm([DCBST, ICBI, ISYNC, BLR]) * 0
    cases.append(('an unaligned isync in data is not a candidate', """
setmem(%d, '%s')
local a, seen = fftsa.nl.find_flush(%d, %d, 256, 96)
if a ~= nil then return 'found ' .. tostring(a) .. ' in data' end
if seen ~= 0 then return 'candidates ' .. tostring(seen) end
return nil
""" % (base, esc(struct.pack('>I', NOP) + unaligned + struct.pack('>I', NOP)),
       base, base + 4 + len(unaligned) + 4)))

    # Two different routines means the sweep cannot tell which is wanted.
    base2, img2, marks2 = image()
    doubled = img2 + img2
    cases.append(('two candidates is refused rather than guessed', """
setmem(%d, '%s')
local a, seen = fftsa.nl.find_flush(%d, %d, 256, 96)
if a ~= nil then return 'picked ' .. tostring(a) .. ' from two' end
if seen < 2 then return 'only saw ' .. tostring(seen) end
return nil
""" % (base2, esc(doubled), base2, base2 + len(doubled))))

    # The register fields are masked: the same routine in different registers still matches.
    alt = []
    for w in struct.unpack('>%dI' % (len(img) // 4), img):
        if w == DCBST:
            alt.append(x31(54, ra=31, rb=2))
        elif w == ICBI:
            alt.append(x31(982, ra=0, rb=30))
        else:
            alt.append(w)
    cases.append(('the cache ops match in any register pair', """
setmem(%d, '%s')
local a = fftsa.nl.find_flush(%d, %d, 256, 96)
if a ~= %d then return 'found ' .. tostring(a) end
return nil
""" % (base, esc(asm(alt)), lo, hi, want)))

    # A window too short to reach back past the cache ops establishes nothing.
    cases.append(('a window shorter than the routine finds nothing', """
setmem(%d, '%s')
local a = fftsa.nl.find_flush(%d, %d, 256, 2)
if a ~= nil then return 'found ' .. tostring(a) .. ' with a 2-word window' end
return nil
""" % (base, esc(img), lo, hi)))

    lua = [PRELUDE, body, 'local fails = 0']
    for name, src in cases:
        lua.append("""
do
  local why = (function() %s end)()
  if why == nil then print('  PASS  %s')
  else print('  FAIL  %s   ' .. why); fails = fails + 1 end
end""" % (src, name, name))
    lua.append("print(string.format('%d cases, %%d failed', fails))" % len(cases))
    lua.append('if fails > 0 then os.exit(1) end')
    return '\n'.join(lua), len(cases)


def run(module):
    lua, ncases = build(module)
    with tempfile.NamedTemporaryFile('w', suffix='.lua', delete=False) as f:
        f.write(lua)
        path = f.name
    try:
        r = subprocess.run([LUA502, path], capture_output=True, text=True)
    finally:
        os.unlink(path)
    return r, ncases


# Each mutation has to break at least one case: a gate whose cases pass against a wrong
# sweep is the failure worth testing for.
MUTATIONS = [
    ('the icbi requirement', 'if not (icbi and dcbst) then return nil end',
     'if not dcbst then return nil end'),
    ('the alignment test', 'if math.mod(i - 1, 4) == 0 then',
     'if true then'),
    ('the two-candidate refusal', 'elseif found ~= e then return nil, seen end',
     'elseif found ~= e then found = e end'),
    ('the extended opcode', 'return math.mod(w, 2048) == xo',
     'return math.mod(w, 2048) >= 0'),
]


def self_test():
    with open(MODULE, 'r') as f:
        src = f.read()
    bad = 0
    for name, old, new in MUTATIONS:
        if src.count(old) != 1:
            print('  FAIL  %s   %r appears %d times' % (name, old, src.count(old)))
            bad += 1
            continue
        with tempfile.NamedTemporaryFile('w', suffix='.tsp', delete=False) as f:
            f.write(src.replace(old, new))
            path = f.name
        try:
            r, _ = run(path)
        finally:
            os.unlink(path)
        if r.returncode == 0:
            print('  FAIL  %s   the gate passed a broken sweep' % name)
            bad += 1
        else:
            print('  PASS  %s   caught' % name)
    if bad:
        raise SystemExit('%d of %d mutations went unnoticed' % (bad, len(MUTATIONS)))
    print('find_flush self-test: %d mutations caught' % len(MUTATIONS))


def main():
    if '--self-test' in sys.argv[1:]:
        self_test()
        return
    module = sys.argv[1] if len(sys.argv) > 1 else MODULE
    r, ncases = run(module)
    sys.stdout.write(r.stdout)
    if r.stderr:
        sys.stderr.write(r.stderr)
    if r.returncode != 0:
        raise SystemExit('find_flush gate failed')
    print('find_flush: %d cases pass' % ncases)


if __name__ == '__main__':
    main()
