#!/usr/bin/env python3
"""Gate: the Lua double packer in tsp/native_link.tsp against struct.pack.

Every double the native path takes -- the bin width, the frequency of bin 0, the two
decibel limits, the voltage floor -- crosses as the word pair f64_words builds, and a wrong
pair is a plausible wrong number rather than a refusal. dsp_reduce would then plot a trace
nobody could tell was mislabelled.

The function under test is EXTRACTED FROM THE SHIPPING MODULE, not copied into this file:
csrc/tools/test_relocate.lua carries its own copy of the relocation applier and says so,
and a copy is a thing that passes while the original has moved. The expectations are
computed here by struct.pack rather than tabulated, for the same reason.

Run under Lua 5.0.2, which is the interpreter on the instrument. math.frexp has been a
different function in later versions and brew's Lua proves nothing about 5.0.2.

    python3 -I csrc/tools/check_f64.py
    python3 -I csrc/tools/check_f64.py /tmp/broken.tsp    # prove it can fail
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

# The whole run of packing helpers, from the word packer to the double reader. Taken as
# one span rather than function by function: f64_pack needs u32_pack and f64_unpack needs
# u32_at, and cherry-picking them here would be a third place that has to agree.
HEAD = 'local function u32_pack'
TAIL = '\nfftsa.nl._f64_unpack'
PRELUDE = 'fftsa = { nl = {} }\nki = nil\n'

# Values that actually cross: bin widths at the rates the app offers, the decibel window,
# the voltage floor and its square, and the awkward ones either side of them.
EXACT = [
    0.0, 1.0, -1.0, 2.0, -2.0, 0.5, 0.25,
    1e-9, 1e-18, 1e9, 1e18,
    -120.0, -140.0, 20.0, 0.001, -0.001,
    61.03515625, 1953.125, 1000000.0 / 16384.0, 1000000.0 / 512.0,
    1.0 / 3.0, 2.0 / 3.0, 3.141592653589793, 2.718281828459045,
    1.7976931348623157e308, 2.2250738585072014e-308,
    4.9e-11, 1.0000000000000002,
]

# Documented divergences, asserted rather than skipped. A subnormal flushes to zero and an
# overflow saturates, and both are outside the range any graph parameter reaches.
SPECIAL = [
    ('5e-324 subnormal flushes to zero', '5e-324', 0x00000000, 0x00000000),
    ('-5e-324 keeps its sign', '-5e-324', 0x80000000, 0x00000000),
    ('1/0 is an infinity', '1/0', 0x7FF00000, 0x00000000),
    ('-1/0 is a negative infinity', '-1/0', 0xFFF00000, 0x00000000),
    ('0/0 is a quiet NaN', '0/0', 0x7FF80000, 0x00000000),
]


def extract(module):
    with open(module, 'r') as f:
        src = f.read()
    a = src.find(HEAD)
    b = src.find(TAIL)
    if a < 0 or b < a:
        raise SystemExit('f64_words not found in %s; markers are %r and %r'
                         % (module, HEAD, TAIL))
    return src[a:b]


def run_lua(body, exprs):
    """Print 'hi lo' for each expression, under the extracted functions.

    Also round-trips every value back through f64_unpack, which is what nl.results()
    decodes the peaks and the distortion figures with: a packer that is right and a reader
    that is not would put plausible wrong numbers in the peak table.
    """
    lines = [PRELUDE, body, '']
    for e in exprs:
        # The two halves, then the value f64_unpack reads back out of those same bytes.
        # Lua only reports; this file decides what the answer should have been.
        lines.append("do local h, l = f64_words(%s) "
                     "local b = f64_unpack(u32_pack(h) .. u32_pack(l), 1) "
                     "print(h, l, (b == nil) and 'nil' or string.format('%%.17g', b)) end"
                     % e)
    fd, path = tempfile.mkstemp(suffix='.lua', prefix='check_f64_')
    try:
        with os.fdopen(fd, 'w') as f:
            f.write('\n'.join(lines) + '\n')
        r = subprocess.run([LUA502, path], capture_output=True, text=True)
        if r.returncode != 0:
            raise SystemExit('lua 5.0.2 failed:\n' + r.stdout + r.stderr)
        out = [ln for ln in r.stdout.splitlines() if ln.strip()]
        if len(out) != len(exprs):
            raise SystemExit('expected %d lines, got %d:\n%s'
                             % (len(exprs), len(out), r.stdout))
        rows = []
        for ln in out:
            h, l, back = ln.split()
            # Lua 5.0.2 prints a whole double as '%.14g', so 2147483648 comes back
            # exactly but a 10-digit value may arrive as 4.2949672955e+09.
            rows.append((int(float(h)), int(float(l)),
                         None if back == 'nil' else float(back)))
        return rows
    finally:
        os.unlink(path)


def main():
    if not os.path.exists(LUA502):
        raise SystemExit('no Lua 5.0.2 at %s -- a later Lua accepts code the instrument '
                         'rejects and its math.frexp is a different function. Set LUA502.'
                         % LUA502)
    module = sys.argv[1] if len(sys.argv) > 1 else MODULE
    body = extract(module)
    bad = 0

    def roundtrip(label, hi, lo, back):
        """f64_unpack has to return what those two halves mean, and nil exactly where the
        exponent field is all ones -- an infinity or a NaN, neither of which may reach a
        display field."""
        want = struct.unpack('>d', struct.pack('>II', hi, lo))[0]
        allones = (hi >> 20) & 0x7FF == 0x7FF
        if allones:
            if back is not None:
                print('  BAD %-34s f64_unpack returned %r for a non-finite' % (label, back))
                return 1
            return 0
        if back is None or back != want:
            print('  BAD %-34s f64_unpack gave %r, the bytes mean %r' % (label, back, want))
            return 1
        return 0

    exprs = ['%r' % v for v in EXACT]
    got = run_lua(body, exprs)
    for v, (hi, lo, back) in zip(EXACT, got):
        whi, wlo = struct.unpack('>II', struct.pack('>d', v))
        if (hi, lo) != (whi, wlo):
            print('  BAD %-24r lua %08X %08X  want %08X %08X'
                  % (v, hi, lo, whi, wlo))
            bad += 1
        bad += roundtrip(repr(v), hi, lo, back)

    got = run_lua(body, [e for (_, e, _, _) in SPECIAL])
    for (name, _, whi, wlo), (hi, lo, back) in zip(SPECIAL, got):
        if (hi, lo) != (whi, wlo):
            print('  BAD %-34s lua %08X %08X  want %08X %08X'
                  % (name, hi, lo, whi, wlo))
            bad += 1
        bad += roundtrip(name, hi, lo, back)

    total = len(EXACT) + len(SPECIAL)
    if bad:
        print('f64_words: %d problem(s) over %d values' % (bad, total))
        return 1
    print('f64_words: %d values bit-exact against struct.pack, and every one reads back '
          'through f64_unpack' % total)
    return 0


if __name__ == '__main__':
    sys.exit(main())
