#!/usr/bin/env python3
"""Gate: nl.flush refuses any range whose cache lines reach the trampoline.

The trampoline is executing while it flushes. icbi on a line the core is fetching from,
followed by isync, re-fetches the instruction stream mid-function, and that is the fault
behind two bluescreens -- which ki.reboot cannot recover.

The trap is that a flush covers whole 32-byte lines while the range asked for does not.
The image is as long as the compiler makes it, so a request ending a few bytes short of
the trampoline still invalidates the trampoline's first line. A byte-interval test passes
that straight through and the refusal never fires.

So this runs the real nl.flush, extracted from tsp/native_link.tsp rather than copied,
against a mock ki that records what it was asked to do, and requires:

  * a range ending inside the trampoline's first line is refused, with nothing written
    and no call made -- the case a byte test misses;
  * a range ending exactly on the line boundary below it is allowed;
  * a range starting inside the trampoline is refused, which is the obvious case;
  * an allowed flush writes the start and the length, big-endian, at TRAMP_RANGE, and
    calls the trampoline's own address and nothing else;
  * a zero or negative length is refused before anything is written.

    python3 -I csrc/tools/check_flush_range.py
    python3 -I csrc/tools/check_flush_range.py --self-test
"""
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MODULE = os.path.join(ROOT, 'tsp', 'native_link.tsp')
LUA502 = os.environ.get('LUA502',
                        os.path.expanduser('~/tmp/lua502/lua-5.0.2/bin/lua'))

# The helpers the refusal is built on, and the function itself. Taken as two slices of the
# module so the code under test is the code that ships.
HELPERS = ('local function align8(v)', '\n-- Progress breadcrumbs')
FLUSH = ('-- Flush written code out of the D-cache',
         '\nfftsa.nl.flush = flush')

# A trampoline placed 24 bytes into a line, so the line below it starts at 0x1000 and the
# image can be made to end inside it.
HARNESS = r"""
fftsa = { nl = {} }
local function trace() end
%(helpers)s

-- Enough of ki to record what the real flush does, and nothing it does not use.
CALLS = {}
WROTE = {}
ki = {}
function ki.memwrite(addr, data) table.insert(WROTE, {addr, data}) end
function ki.memread() return nil end
function ki.poke32() end
function ki.peek8() end

local function via_peek8(addr) table.insert(CALLS, addr) fftsa.nl.last_call = true
  return true end
local function u32_pack(v)
  v = math.mod(v, 4294967296)
  if v < 0 then v = v + 4294967296 end
  local b4 = math.mod(v, 256); v = math.floor(v / 256)
  local b3 = math.mod(v, 256); v = math.floor(v / 256)
  local b2 = math.mod(v, 256)
  local b1 = math.mod(math.floor(v / 256), 256)
  return string.char(b1, b2, b3, b4)
end
local function hx(v) return string.format('%%X', v) end

%(flush)s

local nl = fftsa.nl
nl.TRAMP_RANGE = 4
nl._TRAMP = string.rep('\000', 116)
nl.tramp = 4096 + 24          -- 24 bytes into the line at 0x1000

local function try(lo, len)
  CALLS, WROTE = {}, {}
  local ok = flush(lo, len)
  return ok, table.getn(CALLS), table.getn(WROTE), WROTE[1], CALLS[1]
end

-- A range ending 20 bytes below the trampoline, which shares its first line.
local ok1, c1 = try(2048, (4096 + 4) - 2048)
-- A range ending exactly at the line below it. The start and the length differ, so a
-- packer that swapped them would show.
local ok2, c2, w2, rec2, call2 = try(1024, 4096 - 1024)
-- A range starting inside the trampoline.
local ok3, c3 = try(4096 + 32, 64)
-- A zero length.
local ok4, c4, w4 = try(2048, 0)

print(string.format('shares_line=%%s,%%d line_below=%%s,%%d,%%d inside=%%s,%%d zero=%%s,%%d',
                    tostring(ok1), c1, tostring(ok2), c2, w2, tostring(ok3), c3,
                    tostring(ok4), w4))
if rec2 ~= nil then
  local b = ''
  local i
  for i = 1, string.len(rec2[2]) do
    b = b .. string.format('%%02X', string.byte(rec2[2], i))
  end
  print('wrote ' .. rec2[1] .. ' ' .. b)
  print('called ' .. tostring(call2))
end
"""


def extract(src, head, tail):
    a = src.find(head)
    b = src.find(tail)
    if a < 0 or b < a:
        raise SystemExit('%r .. %r not found in %s' % (head, tail, MODULE))
    return src[a:b]


def run(src):
    script = HARNESS % {'helpers': extract(src, *HELPERS),
                        'flush': extract(src, *FLUSH)}
    with tempfile.NamedTemporaryFile('w', suffix='.lua', delete=False) as fh:
        fh.write(script)
        path = fh.name
    try:
        p = subprocess.run([LUA502, path], capture_output=True, text=True)
    finally:
        os.unlink(path)
    if p.returncode != 0:
        return None, (p.stdout + p.stderr).strip()
    return p.stdout, None


EXPECT_FLAGS = ('shares_line=false,0 line_below=true,1,1 inside=false,0 zero=false,0')
# The start, then the length, as the two big-endian words the trampoline loads: 0x400 and
# 0x1000 - 0x400 = 0xC00.
EXPECT_WROTE = 'wrote 101C 0000040000000C00'
EXPECT_CALL = 'called 4120'


def judge(out):
    bad = []
    lines = [l for l in out.splitlines() if l.strip()]
    if not lines:
        return ['the harness printed nothing']
    if lines[0] != EXPECT_FLAGS:
        bad.append('refusals wrong:\n  want %s\n  got  %s' % (EXPECT_FLAGS, lines[0]))
    if len(lines) < 3:
        bad.append('the allowed flush wrote or called nothing')
        return bad
    if lines[1] != EXPECT_WROTE:
        bad.append('range words wrong:\n  want %s\n  got  %s' % (EXPECT_WROTE, lines[1]))
    if lines[2] != EXPECT_CALL:
        bad.append('called the wrong address:\n  want %s\n  got  %s'
                   % (EXPECT_CALL, lines[2]))
    return bad


def main():
    src = open(MODULE).read()

    if '--self-test' in sys.argv:
        # The byte-interval test is the defect this gate exists for: it is what the
        # refusal looked like before the lines were taken into account, and it passes
        # every other case here.
        cases = [
            ('a byte-interval refusal',
             lambda s: re.sub(
                 r'  if line_hi\(addr, len\) > line_lo\(tlo\) and\n'
                 r'     line_lo\(addr\) < line_hi\(tlo, string\.len\(nl\._TRAMP\)\) then\n'
                 r'    return false\n  end\n',
                 '  if addr < tlo + string.len(nl._TRAMP) and addr + len > tlo then\n'
                 '    return false\n  end\n', s)),
            ('no refusal at all',
             lambda s: re.sub(
                 r'  if line_hi\(addr, len\) > line_lo\(tlo\) and\n'
                 r'     line_lo\(addr\) < line_hi\(tlo, string\.len\(nl\._TRAMP\)\) then\n'
                 r'    return false\n  end\n', '', s)),
            ('a length swapped for the address',
             lambda s: s.replace('u32_pack(addr) .. u32_pack(len)',
                                 'u32_pack(len) .. u32_pack(addr)')),
            ('the range written at the entry instead of TRAMP_RANGE',
             lambda s: s.replace('hx(tlo + nl.TRAMP_RANGE)', 'hx(tlo)')),
        ]
        out, err = run(src)
        if err is not None or judge(out):
            print('FAIL the tree itself does not pass: %s' % (err or judge(out)[0]))
            return 1
        ok = True
        for name, mutate in cases:
            mutated = mutate(src)
            if mutated == src:
                print('FAIL %s: the mutation did not apply' % name)
                ok = False
                continue
            out, err = run(mutated)
            if err is not None or judge(out):
                print('ok   caught %s' % name)
            else:
                print('FAIL missed %s' % name)
                ok = False
        return 0 if ok else 1

    out, err = run(src)
    if err is not None:
        print('FAIL the harness did not run: %s' % err)
        return 1
    bad = judge(out)
    for line in bad:
        print('FAIL ' + line)
    if bad:
        return 1
    print('flush range: a line-sharing request is refused, a line-aligned one is allowed, '
          'and the range words go to the trampoline')
    return 0


if __name__ == '__main__':
    sys.exit(main())
