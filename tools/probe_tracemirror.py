#!/usr/bin/env python3
"""Find the display task's copy of the trace, whatever format it is in.

The graph does not paint from the bound buffer: 255 element values replaced in place with
the descriptor untouched were invisible, and one append then drew exactly that one point. So
the task keeps its own copy and the append is what feeds it. A sweep for the stored reading's
bit patterns -- the double and the float32 -- found it in only three places, all accounted
for, which proves the copy does NOT hold the readings' bit patterns. It holds something
derived: plot-space coordinates, or scaled integers. A content search cannot find that.

A differential one can, in any representation. Per region, four fills alternating two
values, and a block has to differ across ALL THREE transitions:

    ZF(-120) s1 = read
    ZF(-20)  s2 = read     differs(s1,s2)
    ZF(-120) s3 = read     differs(s2,s3)
    ZF(-20)  s4 = read     differs(s3,s4)

Anything holding 255 copies of the value tracks it on every transition, whatever the
representation -- doubles, floats, 16-bit scaled, pixel rows. A single control pass is NOT
enough: 6 MB holds about 98,000 64-byte blocks, so something changing sporadically lands in
one diff and misses another by chance, and the first run of this probe reported nine such
blocks in a row at 0x00F19080 that showed zero differing words when re-read. Three
transitions is three coin flips. The timestamp advances on every fill either way, so it
cannot single out a value-tracking block.

Diffing happens on the instrument; only block offsets cross the socket. Coarse blocks first,
descending only into those that moved, so a quiet region costs one comparison.

EVERY STATEMENT IS ONE LINE. The control socket is line based and a multi-line statement is
parsed a line at a time, which is a syntax error and leaves the app parked.

    python3 -u -I tools/probe_tracemirror.py --region bss
    python3 -u -I tools/probe_tracemirror.py --region heap
"""
import argparse
import os
import sys
import time

SIB = '/Users/ameline/Work/GitHub/dmm6500-serial-decode'
sys.path.insert(0, os.path.join(SIB, 'tools'))
sys.path.insert(0, os.path.join(SIB, 'notes', 'firmware'))
from dmmrun import DMM                                                   # noqa: E402
from fwguard import Guard                                                # noqa: E402

IMAGE = '/tmp/fw1717a/flash17.bin'
SLICE = 0x400000          # 4 MB a pass; three of these are held on the instrument at once
COARSE = 65536            # compared whole first
FINE = 64                 # and descended into at this granularity
LO_DB, HI_DB = -120.0, -20.0


def ask(d, cmd, tag, tries=8, timeout=180):
    assert '\n' not in cmd, 'statements must be one line'
    r = None
    for _ in range(tries):
        r = d.q(cmd, timeout=timeout)
        if r is not None and str(r).startswith(tag):
            return str(r)
        time.sleep(2)
    raise SystemExit('DESYNC(%s) last=%r' % (tag, r))


def one(*parts):
    """Join into a single line, which is the only form the execute path accepts."""
    return ' '.join(p.strip() for p in parts)


def install(d):
    # ZF fills the ring with a constant dB and a FIXED set of X values, so between two fills
    # only the reading and the timestamp differ. The fold shape is kept so the buffer is left
    # in the state the app's own frame leaves it in.
    ask(d, one("do function ZF(v) local tb = fftsa.sg_buf",
               "local wr = buffer.write.reading",
               "local room = math.floor(tb.capacity / 2)",
               "local t, i = fftsa.sg_stamp, nil",
               "for i = 1, room do wr(tb, v, 1000 + i, t + i, 0) end",
               "for i = 1, room do wr(tb, v, 1000 + room + 1 - i, t + room + i, 0) end",
               "fftsa.sg_stamp = t + 2 * room return tb.n end print('F1|ok') end"), 'F1|')
    # DIFF reports the offsets at which two strings differ, coarse blocks first.
    ask(d, one("do function DIFF(a, b, base) local out, n = '', 0",
               "local len = string.len(a) local i = 1",
               "while i <= len do",
               "local j = i + %d - 1 if j > len then j = len end" % COARSE,
               "if string.sub(a, i, j) ~= string.sub(b, i, j) then",
               "local k = i while k <= j do",
               "local m = k + %d - 1 if m > j then m = j end" % FINE,
               "if string.sub(a, k, m) ~= string.sub(b, k, m) then",
               "n = n + 1 if n <= 40 then",
               "out = out .. string.format('%X ', base + k - 1) end end",
               "k = k + %d end end" % FINE,
               "i = i + %d end" % COARSE,
               "return n, out end print('F2|ok') end"), 'F2|')


def pass_region(d, lo, hi, label):
    print('%s 0x%08X..0x%08X, %d MB' % (label, lo, hi, (hi - lo) // (1024 * 1024)))
    found = []
    a = lo
    while a < hi:
        ln = min(SLICE, hi - a)
        q = ask(d, one("do ZF(%f) local s1 = KG.read(%d, %d)" % (LO_DB, a, ln),
                       "ZF(%f) local s2 = KG.read(%d, %d)" % (HI_DB, a, ln),
                       "ZF(%f) local s3 = KG.read(%d, %d)" % (LO_DB, a, ln),
                       "ZF(%f) local s4 = KG.read(%d, %d)" % (HI_DB, a, ln),
                       "if s1 == nil or s4 == nil then print('D|nil||') return end",
                       "local n1, o1 = DIFF(s1, s2, %d)" % a,
                       "local n2, o2 = DIFF(s2, s3, %d)" % a,
                       "local n3, o3 = DIFF(s3, s4, %d)" % a,
                       "s1, s2, s3, s4 = nil, nil, nil, nil",
                       "print('D|' .. tostring(n1) .. ',' .. tostring(n2) .. ',' .. tostring(n3)",
                       ".. '|' .. o1 .. '#' .. o2 .. '#' .. o3) end"),
                 'D|', timeout=420)
        bits = q[2:].split('|')
        if bits[0] == 'nil':
            print('  0x%08X  refused' % a)
            a += SLICE
            continue
        counts = bits[0]
        sets = [set(s.split()) for s in (bits[1].split('#') + ['', '', ''])[:3]]
        cand = sorted(sets[0] & sets[1] & sets[2])
        if any(s for s in sets) or cand:
            print('  0x%08X  moved %-14s tracked all three: %s'
                  % (a, counts, ' '.join(cand[:8]) or 'none'))
        for x in cand:
            found.append(int(x, 16))
        a += SLICE
    return found


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--region', default='bss', choices=('bss', 'heap', 'both'))
    a = ap.parse_args()
    g = Guard(IMAGE)
    d = DMM(recover=False, timeout=300)
    try:
        d.drain()
        for i, stmt in enumerate(g.tsp()):
            ask(d, stmt.replace('\n', ' '), 'KG|%d' % (i + 1), timeout=60)
        print('guard :  installed')
        print('park  : ', ask(d, one("do if fftsa.saved_frame == nil then",
                                     "fftsa.saved_frame = fftsa.frame",
                                     "fftsa.frame = function() end end print('PK|parked') end"),
                              'PK|'))
        install(d)
        regions = []
        if a.region in ('bss', 'both'):
            regions.append(('bss  ', g.named['.bss']))
        if a.region in ('heap', 'both'):
            regions.append(('heap ', g.named['.heap']))
        hits = []
        for label, (lo, hi) in regions:
            hits += pass_region(d, lo, hi, label)
        print()
        if not hits:
            print('No block moved with the value and not with the fill. In this region the')
            print('task copy is either absent or not in DRAM.')
        else:
            print('%d candidate block(s):' % len(hits))
            for h in sorted(hits)[:40]:
                print('  0x%08X' % h)
    finally:
        ask(d, one("do ZF, DIFF = nil, nil if fftsa.saved_frame ~= nil then",
                   "fftsa.frame = fftsa.saved_frame fftsa.saved_frame = nil end",
                   "print('UP|running') end"), 'UP|')
        d.close()


if __name__ == '__main__':
    main()
