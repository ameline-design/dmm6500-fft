#!/usr/bin/env python3
"""fftsa.nl._f32_pack against struct.pack('>f'), both directions, under Lua 5.0.2 itself.

The display task keeps its trace as float32, so finding a value the app put there means
packing it the way the hardware did -- round to nearest, ties to even, which is frsp. A needle
one bit out is simply not found, and that failure reads as "the ring is not in memory" rather
than as a rounding bug, so this is checked rather than assumed.

Every case goes through the real interpreter the instrument runs, not through a host float
library: tools/lint_tsp.py cannot see arithmetic and the host's double is not the question.

    python3 -u -I csrc/tools/check_f32.py
"""
import os
import struct
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
LUA = os.path.expanduser('~/tmp/lua502/lua-5.0.2/bin/lua')

# The app's own quantities first -- dB from the floor to full scale, and every frequency a
# 50 kHz span puts on an axis -- then the cases that break a naive packer: exact ties, the
# subnormal range, the normal/subnormal boundary, and an overflow.
CASES = []
CASES += [-120.0, -115.78624725, -110.6, -100.0, -60.0, -20.0, -0.5, 0.0, 20.0]
CASES += [0.0, 1.0, 2.0, 0.1, 254.24284363, 1000.0, 1024.0, 12345.6789, 50000.0, 65536.0]
CASES += [1.0 / 3.0, 2.0 / 3.0, 1e-3, 1e3, 3.14159265358979, -3.14159265358979]
# Ties. A double exactly half way between two float32 values rounds to the even one, and
# these are built to be exactly that: 1 + (2k+1) * 2^-24.
CASES += [1.0 + (2 * k + 1) * 2.0 ** -24 for k in range(6)]
CASES += [2.0 ** 23 + 0.5, 2.0 ** 23 + 1.5, 2.0 ** 24 + 1.0, 2.0 ** 24 + 3.0]
# Subnormal, the smallest normal, and either side of the boundary.
CASES += [2.0 ** -149, 3.0 * 2.0 ** -149, 2.0 ** -140, 2.0 ** -126,
          2.0 ** -126 * (1 - 2.0 ** -24), 2.0 ** -150, 2.0 ** -200]
# Overflow to infinity, and the largest finite float32.
CASES += [3.4028234663852886e38, 1e39, -1e39, 3.5e38]
CASES += [-c for c in list(CASES)]

LUA_SRC = """
fftsa, ki, buffer, display, dmm = {}, {}, {}, {}, {}
assert(loadfile('tsp/native_link.tsp'))()
local pack = fftsa.nl._f32_pack
local unpack = fftsa.nl._f32_unpack
local vals = {%s}
local i
for i = 1, table.getn(vals) do
  local s = pack(vals[i])
  local o, k = '', nil
  for k = 1, 4 do o = o .. string.format('%%02X', string.byte(s, k)) end
  local back = unpack(s, 1)
  print(o .. ' ' .. (back == nil and 'nil' or string.format('%%.17g', back)))
end
"""


def main():
    if not os.path.exists(LUA):
        print('Lua 5.0.2 is not at %s -- the host interpreter proves nothing here' % LUA)
        return 2
    src = LUA_SRC % ', '.join(repr(float(c)) for c in CASES)
    p = subprocess.run([LUA, '-'], input=src, capture_output=True, text=True, cwd=ROOT)
    if p.returncode != 0:
        print(p.stdout)
        print(p.stderr)
        return 2
    got = [l.split() for l in p.stdout.strip().splitlines()]
    if len(got) != len(CASES):
        print('expected %d lines, got %d' % (len(CASES), len(got)))
        return 2
    bad = 0
    for v, (hexs, backs) in zip(CASES, got):
        # struct.pack refuses an overflow rather than saturating, which is the one place the
        # reference has to be written out rather than asked for: frsp gives an infinity.
        try:
            want = struct.pack('>f', v).hex().upper()
        except OverflowError:
            want = ('FF800000' if v < 0 else '7F800000')
        # A negative zero cannot reach the packer: Lua 5.0.2 folds -0.0 to +0.0, so the
        # value does not exist on the instrument and the sign bit has nothing to carry.
        # Checked as +0 rather than skipped, so a packer that invented a sign would fail.
        if v == 0:
            want = '00000000'
        # The round trip, as a value: a packer can get the bytes right and the exponent bias
        # wrong in a way that only shows up on decode.
        wantback = struct.unpack('>f', bytes.fromhex(want))[0]
        okb = hexs == want
        okv = (backs != 'nil' and abs(float(backs) - wantback) <= 0) or \
              (backs == 'nil' and (wantback != wantback or abs(wantback) == float('inf')))
        if not (okb and okv):
            bad += 1
            print('  %-26.17g  got %s %s   want %s %.17g'
                  % (v, hexs, backs, want, wantback))
    print('%d values, %d wrong' % (len(CASES), bad))
    if bad:
        print('f32_pack does not match frsp, so a memory needle built from it will not be found')
        return 1
    print('f32_pack matches struct.pack(">f") on every case, round trip included')
    return 0


if __name__ == '__main__':
    sys.exit(main())
