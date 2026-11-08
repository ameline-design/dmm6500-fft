#!/usr/bin/env python3
"""The subscription staging ring: find it, and learn the 28-byte record from ground truth.

The append hook does not read the reading buffer. bufpub_append_hook (0x002BC8BC on 1.7.17a)
drains 28-byte records out of a ring the SUBSCRIPTION owns, and the display side copies each
one verbatim into its 56-byte trace record at +0x1C. So the way to feed the graph without
510 blocking round trips is to stage the records ourselves and let one append flush them.

Decompiled field map, all offsets from the subscription base and the base itself derived from
the buffer descriptor -- no firmware addresses:

    desc + 0xF60   lock the hook takes for a drain
    desc + 0xF64   number of subscriptions installed
    desc + 0xF68   subscription slot 0, stride 0xE48

    sub  + 0x10    read cursor, advanced 0x1C a record, wraps at +0x94 to +0x8C
    sub  + 0x70    lock
    sub  + 0x78    enabled; zero drains nothing
    sub  + 0x84    record size, 0x1C
    sub  + 0x8C    ring start, malloc(0x5780) = 800 records
    sub  + 0x90    write cursor
    sub  + 0x94    ring end
    sub  + 0xA0    pending count, decremented per record drained

What this measures rather than assumes: which word of the record carries the dB value and
which carries the Hz, and in what encoding. The static read says value/min/max are floats at
+0x00/+0x04/+0x08, flags at +0x0C and the x value at +0x10/+0x14, but "two floats on a
numeric axis" is ambiguous for a single x, and this app binds ELEMENT_DATA for y and
ELEMENT_EXTRA for x. One append with values that cannot occur naturally settles it.

Read-only apart from that one sanctioned buffer.write.reading. Nothing is written through
ki.memwrite.

EVERY STATEMENT IS ONE LINE. The control socket is line based; a multi-line statement is
parsed a line at a time, which is a syntax error and leaves the app parked.

    python3 -u -I tools/probe_substage.py
"""
import os
import struct
import sys
import time

SIB = '/Users/ameline/Work/GitHub/dmm6500-serial-decode'
sys.path.insert(0, os.path.join(SIB, 'tools'))
sys.path.insert(0, os.path.join(SIB, 'notes', 'firmware'))
from dmmrun import DMM                                                   # noqa: E402
from fwguard import Guard                                                # noqa: E402

IMAGE = '/tmp/fw1717a/flash17.bin'

SUB0, STRIDE = 0xF68, 0xE48
LOCK, NSUB = 0xF60, 0xF64
RECSIZE = 0x1C
RING_BYTES = 0x5780

# Values that cannot arise from a real spectrum, so whichever words hold them are identified
# beyond doubt. -42.5 and 12345.0 are both exact in float32.
NEEDLE_DB, NEEDLE_HZ = -42.5, 12345.0


def ask(d, cmd, tag, tries=8, timeout=120):
    assert '\n' not in cmd, 'statements must be one line'
    assert len(cmd) < 1000, 'one-line probes die past 1024 bytes: %d' % len(cmd)
    r = None
    for _ in range(tries):
        r = d.q(cmd, timeout=timeout)
        if r is not None and str(r).startswith(tag):
            return str(r)
        time.sleep(2)
    raise SystemExit('DESYNC(%s) last=%r' % (tag, r))


def one(*parts):
    return ' '.join(p.strip() for p in parts)


def words(blob):
    n = len(blob) // 4
    return struct.unpack('>%dI' % n, blob[:n * 4])


def f32(u):
    return struct.unpack('>f', struct.pack('>I', u))[0]


def hexs(d, addr, n):
    """KG.read returns the bytes; only the hex crosses the socket."""
    r = ask(d, one("do local s = KG.read(%d, %d)" % (addr, n),
                   "if s == nil then print('X|nil') return end",
                   "local o, i = '', nil",
                   "for i = 1, string.len(s) do",
                   "o = o .. string.format('%02X', string.byte(s, i)) end",
                   "print('X|' .. o) end"), 'X|')
    body = r[2:].strip()
    if body == 'nil':
        return None
    return bytes.fromhex(body)


def main():
    g = Guard(IMAGE)
    d = DMM(recover=False, timeout=240)
    try:
        d.drain()
        # Park BEFORE anything else. A running frame loop holds the interpreter and queries
        # come back empty until it stops -- measured: five consecutive nil replies, then
        # everything worked, because the park had taken effect despite its own reply being
        # swallowed. So this is the one statement that must tolerate that, and the liveness
        # proof moves to the unpark at the end where the counter can be watched.
        print('park  : %s' % ask(d, one("do if fftsa.saved_frame == nil then",
                                        "fftsa.saved_frame = fftsa.frame",
                                        "fftsa.frame = function() end end print('PK|parked') end"),
                                 'PK|', tries=20)[3:])

        # With the loop parked, these prove the app is a healthy running instance rather than
        # a half-initialised one: a full trace buffer, a live descriptor, a computed frame rate.
        st = ask(d, one("do local b = fftsa.sg_buf",
                        "print('S|' .. tostring(b.n) .. ',' .. tostring(b.capacity)",
                        ".. ',' .. tostring(fftsa.fps) .. ',' .. tostring(fftsa.acq_tick_n)) end"), 'S|')
        n, cap, fps, ticks = st[2:].split(',')
        print('state : trace %s/%s points, %s fps, %s acquisitions' % (n, cap, fps, ticks))
        if n == 'nil' or n == '0':
            raise SystemExit('the trace buffer is empty; this is not a running app')

        for i, stmt in enumerate(g.tsp()):
            ask(d, stmt.replace('\n', ' '), 'KG|%d' % (i + 1), timeout=60)
        print('guard : installed')

        r = ask(d, one("do local t = fftsa.nl.describe(fftsa.sg_buf, true)",
                       "if t == nil then print('D|nil') return end",
                       "print('D|' .. tostring(t.desc) .. ',' .. tostring(t.elemsize)",
                       ".. ',' .. tostring(t.perchunk) .. ',' .. tostring(t.nchunks)) end"), 'D|')
        if r[2:].startswith('nil'):
            raise SystemExit('describe() refused; no descriptor, nothing to measure')
        desc = int(r[2:].split(',')[0])
        print('desc  : 0x%08X  (elemsize,perchunk,nchunks = %s)'
              % (desc, ','.join(r[2:].split(',')[1:])))

        hdr = words(hexs(d, desc + LOCK, 8))
        print('lock  : 0x%08X   subscriptions installed: %d' % (hdr[0], hdr[1]))
        nsub = hdr[1]
        if nsub < 1 or nsub > 8:
            raise SystemExit('subscription count %d is not plausible; offsets are wrong' % nsub)

        chosen = None
        for s in range(nsub):
            base = desc + SUB0 + s * STRIDE
            w = words(hexs(d, base, 0xA4))
            rd, lk, en = w[0x10 // 4], w[0x70 // 4], w[0x78 // 4]
            rs, lo, wr, hi, pend = (w[0x84 // 4], w[0x8C // 4], w[0x90 // 4],
                                    w[0x94 // 4], w[0xA0 // 4])
            ok = (rs == RECSIZE and lo != 0 and hi - lo == RING_BYTES)
            print('sub %d : base 0x%08X  recsize %d  ring 0x%08X..0x%08X (%d)  %s'
                  % (s, base, rs, lo, hi, hi - lo, 'MATCHES' if ok else 'no'))
            print('        read 0x%08X  write 0x%08X  pending %d  enabled %d  lock 0x%08X'
                  % (rd, wr, pend, en, lk))
            if ok and chosen is None:
                chosen = (base, lo, hi, wr, pend, rs)

        if chosen is None:
            raise SystemExit('no slot matched recsize 0x1C with a 0x5780 ring')
        base, lo, hi, wr0, pend0, rs = chosen
        print()
        print('chosen: sub 0x%08X, write cursor at 0x%08X, %d pending' % (base, wr0, pend0))

        before = hexs(d, wr0, RECSIZE)
        print('before: %s' % before.hex())

        # One sanctioned append, with values that cannot occur in a real spectrum. The hook
        # fires synchronously and drains it, which advances the read cursor and clears
        # pending -- but the bytes stay in the ring, so the record is still there to read.
        st = ask(d, one("do local ok, e = pcall(buffer.write.reading, fftsa.sg_buf,",
                        "%f, %f, fftsa.sg_stamp + 1, 0)" % (NEEDLE_DB, NEEDLE_HZ),
                        "fftsa.sg_stamp = fftsa.sg_stamp + 1",
                        "print('W|' .. tostring(ok) .. ',' .. tostring(e)) end"), 'W|')
        print('append: %s' % st[2:])

        w = words(hexs(d, base, 0xA4))
        wr1, pend1 = w[0x90 // 4], w[0xA0 // 4]
        print('cursor: write 0x%08X -> 0x%08X (%+d bytes)   pending %d -> %d'
              % (wr0, wr1, wr1 - wr0, pend0, pend1))

        after = hexs(d, wr0, RECSIZE)
        print('after : %s' % after.hex())
        print()
        if after == before:
            print('The record did not land at the write cursor. Either +0x90 is not the write')
            print('cursor or the staging happens elsewhere; dump the whole ring next.')
            return
        print('%-7s %-12s %-14s %-14s %s' % ('wire', 'word', 'as float32', 'as int32', 'note'))
        for k in range(0, RECSIZE, 4):
            u = struct.unpack('>I', after[k:k + 4])[0]
            fv = f32(u)
            note = ''
            if abs(fv - NEEDLE_DB) < 1e-6:
                note = '<== the dB value'
            elif abs(fv - NEEDLE_HZ) < 1e-3:
                note = '<== the Hz value'
            elif u == int(NEEDLE_HZ):
                note = '<== Hz as an integer'
            print('+0x%02X   0x%08X   %-14.6g %-14d %s' % (k, u, fv, u if u < 2**31 else u - 2**32, note))
    finally:
        ask(d, one("do if fftsa.saved_frame ~= nil then",
                   "fftsa.frame = fftsa.saved_frame fftsa.saved_frame = nil end",
                   "print('UP|running') end"), 'UP|', tries=20)
        # The liveness proof: with the loop restored the acquisition counter has to move.
        try:
            a = ask(d, "print('T|' .. tostring(fftsa.acq_tick_n))", 'T|', tries=20)
            time.sleep(3)
            b = ask(d, "print('T|' .. tostring(fftsa.acq_tick_n))", 'T|', tries=20)
            print('unpark: acquisitions %s then %s -- %s'
                  % (a[2:], b[2:], 'running' if a != b else 'NOT ADVANCING, check the glass'))
        except SystemExit as e:
            print('unpark: could not confirm the counter is advancing (%s)' % e)
        d.close()


if __name__ == '__main__':
    main()
