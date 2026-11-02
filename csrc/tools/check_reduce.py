#!/usr/bin/env python3
"""Gate: fftsa.nl.reduce in tsp/native_link.tsp, against struct.pack.

Every point on the spectrum crosses from the compiled path to the graph through this
function: it reads the two reduced arrays out of the arena and the frame writes them with
buffer.write.reading. A value decoded wrong is a plausible wrong trace rather than a
refusal, and a nil that got through would reach buffer.write.reading as a nil argument,
which is a posted event per point.

The function under test is extracted from the shipping module, not copied into this file,
because a copy is a thing that passes while the original has moved. The byte images are
built here by struct.pack rather than tabulated, and the fake ki.memread serves them.

Run under Lua 5.0.2, which is the interpreter on the instrument.

    python3 -I csrc/tools/check_reduce.py
    python3 -I csrc/tools/check_reduce.py /tmp/broken.tsp    # prove it can fail
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

# Two spans: the packing helpers the decode needs, and the function itself. Markers rather
# than line numbers, and a miss is a failure rather than a silent empty extraction.
SPANS = [
    ('local function hx', '\n-- An IEEE-754 binary64 as the two'),
    ('local function u32_pack', '\nfftsa.nl._f64_unpack'),
    ('function fftsa.nl.reduce(nseg)', "\n-- Describe a buffer's storage"),
]

# The arena addresses the fake memread answers for, and the gap between the two arrays:
# nl.init lays red_hz out one nseg_max of reals above red_db.
DB_ADDR = 0x03500000
NSEG_MAX = 680
HZ_ADDR = DB_ADDR + NSEG_MAX * 8

# Decibel values and frequencies of the shape dsp_reduce produces: the axis floor and
# ceiling it clamps to, a bin width at the rates the app offers, and the awkward ones.
DB = [-120.0, -119.5, 20.0, 0.0, -0.001, -73.25, -1.0 / 3.0, 1e-9, -99.9999999]
HZ = [0.0, 1953.125, 61.03515625, 1000000.0 / 512.0, 49800.0, 1.0 / 3.0, 1e-9,
      123456.789, 500000.0]

PRELUDE = """fftsa = { nl = {} }
local MEM = {}
-- Bytes asked for, counted so a case can assert what a call leaves unread. The frequencies
-- are decoded once a plan, and a cache that silently stopped working would return the right
-- trace while costing what it was built to save -- invisible to a value comparison.
RBYTES = 0
-- Serves any address inside a region, so a read that runs off the end comes back short
-- rather than nil -- which is what the length check exists for. An address in no region
-- reads nothing, as ki.memread does outside mapped memory.
ki = { memread = function(addr, len)
  local a, n = tonumber(addr, 16), tonumber(len, 16)
  if a == nil or n == nil then return nil end
  RBYTES = RBYTES + n
  local base, s = nil, nil
  local b, v
  for b, v in pairs(MEM) do
    if a >= b and a < b + string.len(v) then base, s = b, v end
  end
  if s == nil then return nil end
  local off = a - base
  return string.sub(s, off + 1, off + n)
end }
function setmem(a, s) MEM[a] = s end
"""


def extract(module):
    with open(module, 'r') as f:
        src = f.read()
    out = []
    for head, tail in SPANS:
        a = src.find(head)
        b = src.find(tail, a + 1)
        if a < 0 or b < a:
            raise SystemExit('%s not found in %s; markers are %r and %r'
                             % (head, module, head, tail))
        out.append(src[a:b])
    return '\n'.join(out)


def image(values):
    return b''.join(struct.pack('>d', v) for v in values)


def esc(data):
    # Lua 5.0.2 has no \xNN, so every byte goes in as a decimal escape.
    return ''.join('\\%d' % b for b in data)


def build(module):
    body = extract(module)

    db_img = image(DB)
    hz_img = image(HZ)
    n = len(DB)
    cases = []

    # Round trip: every value back bit-exact, in both arrays, at the real count.
    cases.append(('round trip %d points' % n, """
setmem(%d, '%s'); setmem(%d, '%s')
local nl = fftsa.nl
nl.red_db, nl.red_hz, nl.nseg_max, nl.SIZEOF_REAL = %d, %d, %d, 8
local r = nl.reduce(%d)
if r == nil then return 'reduce returned nil' end
if r.nseg ~= %d then return 'nseg ' .. tostring(r.nseg) end
local want_db = {%s}
local want_hz = {%s}
local i
for i = 1, %d do
  if r.db[i] ~= want_db[i] then
    return string.format('db[%%d] %%.17g wanted %%.17g', i, r.db[i], want_db[i])
  end
  if r.hz[i] ~= want_hz[i] then
    return string.format('hz[%%d] %%.17g wanted %%.17g', i, r.hz[i], want_hz[i])
  end
end
return nil
""" % (DB_ADDR, esc(db_img), HZ_ADDR, esc(hz_img),
       DB_ADDR, HZ_ADDR, NSEG_MAX, n, n,
       ','.join('%.17g' % v for v in DB), ','.join('%.17g' % v for v in HZ), n)))

    # The tables are reused across calls, and a shorter run must not leave the previous
    # run's tail where the write loop would read it.
    cases.append(('the table is the same object across calls', """
setmem(%d, '%s'); setmem(%d, '%s')
local nl = fftsa.nl
nl.red_db, nl.red_hz, nl.nseg_max, nl.SIZEOF_REAL = %d, %d, %d, 8
local a = nl.reduce(%d)
local first = a.db
local b = nl.reduce(2)
if b == nil then return 'second call returned nil' end
if b.db ~= first then return 'a fresh table per call' end
if b.nseg ~= 2 then return 'nseg ' .. tostring(b.nseg) end
if b.db[1] ~= %.17g or b.hz[2] ~= %.17g then return 'wrong values after the short call' end
return nil
""" % (DB_ADDR, esc(db_img), HZ_ADDR, esc(hz_img),
       DB_ADDR, HZ_ADDR, NSEG_MAX, n, DB[0], HZ[1])))

    # The frequencies are an affine series the plan fixes, so they are decoded once a plan and
    # reused. Two properties matter. The steady state must not re-read the array -- that is
    # the whole point, and nothing about the returned values would show its loss. And a plan
    # whose series differs must be noticed, or the trace plots against the wrong axis. The
    # detector reads elements 1 and 2, which are f0 and f0 + fstep, so it is exercised on each
    # of them on its own: a key that watched only one would pass a test that moved both.
    # One element moved per variant, so each case can only be caught by the half of the key
    # that watches that element. Moving both would let either half pass the pair.
    hz_f0 = [HZ[0] + 1.0] + HZ[1:]
    hz_fstep = [HZ[0], HZ[1] + 7.0] + HZ[2:]

    cases.append(('the frequencies are decoded once a plan, not once a call', """
setmem(%d, '%s'); setmem(%d, '%s')
local nl = fftsa.nl
nl.red_db, nl.red_hz, nl.nseg_max, nl.SIZEOF_REAL = %d, %d, %d, 8
if nl.reduce(%d) == nil then return 'first call returned nil' end
RBYTES = 0
local r = nl.reduce(%d)
if r == nil then return 'second call returned nil' end
-- The decibels in full, plus a two-element probe of the frequencies. Re-reading the whole
-- frequency array would add as much again.
local want = %d * 8 + 16
if RBYTES ~= want then
  return string.format('%%d bytes on the second call, wanted %%d', RBYTES, want)
end
local want_hz = {%s}
local i
for i = 1, %d do
  if r.hz[i] ~= want_hz[i] then
    return string.format('hz[%%d] %%.17g wanted %%.17g', i, r.hz[i], want_hz[i])
  end
end
return nil
""" % (DB_ADDR, esc(db_img), HZ_ADDR, esc(hz_img),
       DB_ADDR, HZ_ADDR, NSEG_MAX, n, n, n,
       ','.join('%.17g' % v for v in HZ), n)))

    for label, vals in (('f0', hz_f0), ('fstep', hz_fstep)):
        cases.append(('a plan with a new %s refills the frequencies' % label, """
setmem(%d, '%s'); setmem(%d, '%s')
local nl = fftsa.nl
nl.red_db, nl.red_hz, nl.nseg_max, nl.SIZEOF_REAL = %d, %d, %d, 8
if nl.reduce(%d) == nil then return 'the first plan returned nil' end
setmem(%d, '%s')
local r = nl.reduce(%d)
if r == nil then return 'the second plan returned nil' end
local want_hz = {%s}
local i
for i = 1, %d do
  if r.hz[i] ~= want_hz[i] then
    return string.format('hz[%%d] %%.17g wanted %%.17g', i, r.hz[i], want_hz[i])
  end
end
return nil
""" % (DB_ADDR, esc(db_img), HZ_ADDR, esc(hz_img),
       DB_ADDR, HZ_ADDR, NSEG_MAX, n,
       HZ_ADDR, esc(image(vals)), n,
       ','.join('%.17g' % v for v in vals), n)))

    # Fails closed, one case per refusal. Each must be nil, not a table with a hole and not
    # an error: the caller falls back to the interpreted primitive on nil.
    refusals = [
        ('nseg above the planned maximum', 'nl.reduce(%d)' % (NSEG_MAX + 1)),
        ('nseg zero', 'nl.reduce(0)'),
        ('nseg negative', 'nl.reduce(-1)'),
        ('nseg nil', 'nl.reduce(nil)'),
        ('a single-precision image', 'nl.SIZEOF_REAL = 4; return nl.reduce(%d)' % n),
        ('an unplanned arena', 'nl.red_db = nil; return nl.reduce(%d)' % n),
        ('no frequency array', 'nl.red_hz = nil; return nl.reduce(%d)' % n),
        ('a short read', 'nl.red_db = %d; return nl.reduce(%d)'
                         % (DB_ADDR + 8, n)),
        ('an address that reads nothing', 'nl.red_hz = %d; return nl.reduce(%d)'
                                         % (DB_ADDR + 0x1000, n)),
    ]
    for name, stmt in refusals:
        body_stmt = stmt if stmt.startswith('nl.') and 'return' in stmt else 'return ' + stmt
        cases.append(('refused: ' + name, """
setmem(%d, '%s'); setmem(%d, '%s')
local nl = fftsa.nl
nl.red_db, nl.red_hz, nl.nseg_max, nl.SIZEOF_REAL = %d, %d, %d, 8
local r = (function() %s end)()
if r ~= nil then return 'returned a table' end
return nil
""" % (DB_ADDR, esc(db_img), HZ_ADDR, esc(hz_img),
       DB_ADDR, HZ_ADDR, NSEG_MAX, body_stmt)))

    # An infinity and a NaN in the array: f64_unpack returns nil for both, and the whole
    # call has to fail rather than hand the frame a table with a hole in it.
    for name, pattern in (('an infinity', 0x7FF0000000000000),
                          ('a quiet NaN', 0x7FF8000000000000)):
        poisoned = bytearray(db_img)
        poisoned[16:24] = struct.pack('>Q', pattern)
        cases.append(('refused: %s among the decibels' % name, """
setmem(%d, '%s'); setmem(%d, '%s')
local nl = fftsa.nl
nl.red_db, nl.red_hz, nl.nseg_max, nl.SIZEOF_REAL = %d, %d, %d, 8
local r = nl.reduce(%d)
if r ~= nil then return 'returned a table' end
if nl.reduce(2) == nil then return 'the clean head is refused too' end
return nil
""" % (DB_ADDR, esc(bytes(poisoned)), HZ_ADDR, esc(hz_img),
       DB_ADDR, HZ_ADDR, NSEG_MAX, n)))

    lua = [PRELUDE, body, 'local fails = 0']
    for name, src in cases:
        lua.append("""
do
  local why = (function() %s end)()
  if why == nil then print('  PASS  %s')
  else print('  FAIL  %s   ' .. why); fails = fails + 1 end
end""" % (src, name, name))
    lua.append("""
print(string.format('%d cases, %d failed', """ + str(len(cases)) + """, fails))
if fails > 0 then os.exit(1) end""")
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


# Each mutation has to break at least one case above. A gate whose cases all pass against a
# wrong module is the failure mode worth testing for. The first four are faults the decode
# could acquire -- a wrong stride through either image, a short read taken as a whole one,
# the finite check dropped. The last three are the cache: one per input of its key, so a key
# that watched the count and the address but not the series would be caught, plus a cache
# that stops hitting, which costs what it was built to save and shows in nothing it returns.
MUTATIONS = [
    ('the decibel stride', 'db[i] = v\n    p = p + 8', 'db[i] = v\n    p = p + 4'),
    ('the frequency stride', 'hz[i] = f\n      p = p + 8', 'hz[i] = f\n      p = p + 4'),
    ('a short read accepted', 'string.len(sd) ~= nbytes', 'string.len(sd) < 0'),
    ('the finite check dropped', 'if v == nil then return nil end',
     'if v ~= nil and v == nil then return nil end'),
    ('the cache ignores f0', ' or r.hz_1 ~= h1', ''),
    ('the cache ignores fstep', ' or r.hz_2 ~= h2', ''),
    ('the cache never hits', 'if r.hz_nseg ~= nseg or', 'if true or'),
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
            print('  FAIL  %s   the gate passed a broken module' % name)
            bad += 1
        else:
            print('  PASS  %s   caught' % name)
    if bad:
        raise SystemExit('%d of %d mutations went unnoticed' % (bad, len(MUTATIONS)))
    print('reduce self-test: %d mutations caught' % len(MUTATIONS))


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
        raise SystemExit('reduce gate failed')
    print('reduce: %d cases pass' % ncases)


if __name__ == '__main__':
    main()
