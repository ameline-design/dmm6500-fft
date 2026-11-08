#!/usr/bin/env python3
"""Stage records into the subscription ring ourselves, and let ONE append flush them all.

probe_substage.py established the ring and the record from ground truth: subscription slot 0
at descriptor+0xF68, a 22,400-byte ring of 28-byte records, and for a numeric axis the record
is [0, dB, dB, 0, Hz, Hz, 2.0] as big-endian float32 with the flags word zero.

bufpub_append_hook drains `pending` (+0xA0) records starting at the read cursor (+0x10),
eight to a message, and it runs INLINE on the appending thread -- measured: a single append
moved the write cursor exactly 28 bytes and left pending at zero. So there is no concurrent
reader of this ring and staging into it without taking the lock at +0x70 is safe.

If this works, the per-frame fill stops being 510 blocking IPC round trips at ~76 us and
becomes one memwrite plus one append, with the hook posting about 64 asynchronous messages.

THE TEST. With frames parked:

    R = read cursor, W = write cursor, P = pending     (expect R == W, P == 0)
    write K records at W
    set write cursor to W + K*28, set pending to K
    one buffer.write.reading                            (stages record K+1, fires the drain)
    expect: read cursor advanced (K+1)*28, pending back to 0, plot interior changed

The records are a flat line at a dB the spectrum never reaches, spread across the span, so a
repaint is unmistakable on the glass and in the checksum.

EVERY STATEMENT IS ONE LINE, and under 1000 bytes.

    python3 -u -I tools/probe_substage_bulk.py
    python3 -u -I tools/probe_substage_bulk.py --k 64 --db -15
"""
import argparse
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
NSUB = 0xF64
RECSIZE = 0x1C
RING_BYTES = 0x5780
# The plot interior only. Hashing the whole screen is useless here: the THD line, the peak
# table and the frame rate all change on their own.
PLOT = (100, 60, 780, 340)
HEX_PER_STMT = 880          # keeps each accumulate statement comfortably under 1000 bytes


def ask(d, cmd, tag, tries=12, timeout=120):
    assert '\n' not in cmd, 'statements must be one line'
    assert len(cmd) < 1000, 'one-line probes die past 1024 bytes: %d' % len(cmd)
    r = None
    for _ in range(tries):
        r = d.q(cmd, timeout=timeout)
        if r is not None and str(r).startswith(tag):
            return str(r)
        time.sleep(1.5)
    raise SystemExit('DESYNC(%s) last=%r' % (tag, r))


def park(d):
    """Park the frame loop, confirming by state rather than by reply.

    A running frame loop holds the interpreter, so the park statement's own reply is usually
    swallowed even though the statement runs -- measured at 1.9 fps, where one frame occupies
    most of a 525 ms period, and five consecutive queries came back empty before anything
    answered. So this sends it without expecting a reply and polls until the state says it
    took."""
    stmt = ("do if fftsa.saved_frame == nil then fftsa.saved_frame = fftsa.frame "
            "fftsa.frame = function() end end end")
    for _ in range(30):
        d.drain()
        d.send(stmt)
        time.sleep(0.4)
        r = d.q("print('K|' .. tostring(fftsa.saved_frame ~= nil))", timeout=20)
        if r is not None and str(r).startswith('K|true'):
            return True
        time.sleep(1)
    raise SystemExit('could not park the frame loop; the app may not be running')


def unpark(d):
    stmt = ("do if fftsa.saved_frame ~= nil then fftsa.frame = fftsa.saved_frame "
            "fftsa.saved_frame = nil end end")
    for _ in range(30):
        d.drain()
        d.send(stmt)
        time.sleep(0.4)
        r = d.q("print('K|' .. tostring(fftsa.saved_frame == nil))", timeout=20)
        if r is not None and str(r).startswith('K|true'):
            return True
        time.sleep(1)
    return False


def one(*parts):
    return ' '.join(p.strip() for p in parts)


def words(blob):
    return struct.unpack('>%dI' % (len(blob) // 4), blob[:len(blob) // 4 * 4])


def hexs(d, addr, n):
    r = ask(d, one("do local s = KG.read(%d, %d)" % (addr, n),
                   "if s == nil then print('X|nil') return end",
                   "local o, i = '', nil",
                   "for i = 1, string.len(s) do",
                   "o = o .. string.format('%02X', string.byte(s, i)) end",
                   "print('X|' .. o) end"), 'X|')
    body = r[2:].strip()
    return None if body == 'nil' else bytes.fromhex(body)


def record(db, hz):
    """One wire record, exactly the shape the firmware wrote for a numeric axis."""
    return (struct.pack('>f', 0.0) + struct.pack('>f', db) + struct.pack('>f', db)
            + struct.pack('>I', 0) + struct.pack('>f', hz) + struct.pack('>f', hz)
            + struct.pack('>f', 2.0))


def sum_plot(d):
    x1, y1, x2, y2 = PLOT
    r = ask(d, "print('C|' .. tostring(ki.display.getchecksum(%d,%d,%d,%d)))"
            % (x1, y1, x2, y2), 'C|')
    return r[2:].strip()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--k', type=int, default=32, help='records to stage')
    ap.add_argument('--db', type=float, default=-20.0, help='dB for the staged line')
    a = ap.parse_args()

    g = Guard(IMAGE)
    d = DMM(recover=False, timeout=240)
    base, R = None, None
    try:
        d.drain()
        print('park  : %s' % ask(d, one("do if fftsa.saved_frame == nil then",
                                        "fftsa.saved_frame = fftsa.frame",
                                        "fftsa.frame = function() end end print('PK|parked') end"),
                                 'PK|', tries=25)[3:])
        st = ask(d, one("do local b = fftsa.sg_buf",
                        "print('S|' .. tostring(b.n) .. ',' .. tostring(b.capacity)",
                        ".. ',' .. tostring(fftsa.sg_flo_hz) .. ',' .. tostring(fftsa.sg_fhi_hz)) end"), 'S|')
        n, cap, flo, fhi = st[2:].split(',')
        print('state : trace %s/%s points, span %s..%s Hz' % (n, cap, flo, fhi))
        flo, fhi = float(flo), float(fhi)

        for i, stmt in enumerate(g.tsp()):
            ask(d, stmt.replace('\n', ' '), 'KG|%d' % (i + 1), timeout=60)
        print('guard : installed')

        r = ask(d, one("do local t = fftsa.nl.describe(fftsa.sg_buf, true)",
                       "if t == nil then print('D|nil') return end",
                       "print('D|' .. tostring(t.desc)) end"), 'D|')
        desc = int(r[2:].split(',')[0])
        nsub = words(hexs(d, desc + NSUB, 4))[0]
        if nsub < 1:
            raise SystemExit('no subscription installed; is a trace bound?')

        base = None
        for s in range(nsub):
            b = desc + SUB0 + s * STRIDE
            w = words(hexs(d, b, 0xA4))
            if w[0x84 // 4] == RECSIZE and w[0x94 // 4] - w[0x8C // 4] == RING_BYTES:
                base = b
                break
        if base is None:
            raise SystemExit('no slot matched recsize 0x1C with a 0x5780 ring')

        w = words(hexs(d, base, 0xA4))
        R, W, P = w[0x10 // 4], w[0x90 // 4], w[0xA0 // 4]
        lo, hi = w[0x8C // 4], w[0x94 // 4]
        print('sub   : 0x%08X  ring 0x%08X..0x%08X' % (base, lo, hi))
        print('cursor: read 0x%08X  write 0x%08X  pending %d' % (R, W, P))
        if R != W or P != 0:
            print('  not idle; the hook has work outstanding. Staging now would interleave.')
            raise SystemExit('refusing to stage into a ring that is not drained')
        need = a.k * RECSIZE
        if W + need > hi:
            raise SystemExit('staging %d records from 0x%08X would wrap; rerun when the '
                             'cursor is lower' % (a.k, W))

        blob = b''.join(record(a.db, flo + (fhi - flo) * i / float(max(1, a.k - 1)))
                        for i in range(a.k))
        assert len(blob) == need
        print('stage : %d records, %d bytes, flat at %.1f dB across the span'
              % (a.k, need, a.db))

        before = sum_plot(d)
        print('plot  : checksum before %s' % before)

        # Accumulate the blob as hex, then one guarded write. The window is declared to be
        # exactly the records, so a slip cannot reach the structure fields.
        ask(d, one("do function H2B(h) local o, i = '', nil",
                   "for i = 1, string.len(h), 2 do",
                   "o = o .. string.char(tonumber(string.sub(h, i, i + 1), 16)) end",
                   "return o end ZB = '' print('H|ok') end"), 'H|')
        hx = blob.hex().upper()
        for i in range(0, len(hx), HEX_PER_STMT):
            ask(d, "do ZB = ZB .. H2B('%s') print('A|' .. tostring(string.len(ZB))) end"
                % hx[i:i + HEX_PER_STMT], 'A|')
        got = ask(d, "print('Z|' .. tostring(string.len(ZB)))", 'Z|')
        print('blob  : %s bytes assembled on the instrument' % got[2:])
        if int(got[2:]) != need:
            raise SystemExit('blob is %s bytes, wanted %d' % (got[2:], need))

        wr = ask(d, one("do KG.armed = true",
                        "local ok1 = KG.own(%d, %d)" % (W, need),
                        "local ok2 = KG.write(%d, ZB)" % W,
                        "print('W|' .. tostring(ok1) .. ',' .. tostring(ok2)) end"), 'W|')
        print('write : own=%s write=%s' % tuple(wr[2:].split(',')[:2]))
        if 'false' in wr[2:]:
            raise SystemExit('guarded write refused')

        cu = ask(d, one("do local ok1 = KG.own(%d, 4)" % (base + 0x90),
                        "local okA = KG.p32(%d, %d)" % (base + 0x90, W + need),
                        "local ok2 = KG.own(%d, 4)" % (base + 0xA0),
                        "local okB = KG.p32(%d, %d)" % (base + 0xA0, a.k),
                        "print('U|' .. tostring(okA) .. ',' .. tostring(okB)) end"), 'U|')
        print('cursor: set write=0x%08X pending=%d  (%s)' % (W + need, a.k, cu[2:]))
        if 'false' in cu[2:]:
            raise SystemExit('cursor update refused')

        # Did the writes stick at all? The drain consuming one record and leaving pending at
        # zero is consistent with two different things -- the cursor write never landing, or
        # the push path overwriting pending rather than incrementing it -- and they are told
        # apart by reading the fields back before anything appends.
        wv = words(hexs(d, base, 0xA4))
        print('verify: write 0x%08X pending %d   (wanted 0x%08X and %d)'
              % (wv[0x90 // 4], wv[0xA0 // 4], W + need, a.k))
        if wv[0xA0 // 4] != a.k:
            print('        the pending write did not stick, so nothing below is about the hook')
        stg = hexs(d, W, RECSIZE)
        print('rec[0]: %s   %s' % (stg.hex(), 'as staged' if stg == blob[:RECSIZE]
                                   else 'NOT WHAT WAS STAGED'))

        # The one append. It stages record K+1 and fires the drain for all K+1.
        ap2 = ask(d, one("do local ok, e = pcall(buffer.write.reading, fftsa.sg_buf,",
                         "%f, %f, fftsa.sg_stamp + 1, 0)" % (a.db, fhi),
                         "fftsa.sg_stamp = fftsa.sg_stamp + 1",
                         "print('P|' .. tostring(ok) .. ',' .. tostring(e)) end"), 'P|')
        print('append: %s' % ap2[2:])

        w2 = words(hexs(d, base, 0xA4))
        R2, W2, P2 = w2[0x10 // 4], w2[0x90 // 4], w2[0xA0 // 4]
        moved = (R2 - R) // RECSIZE
        print('cursor: read 0x%08X -> 0x%08X (%d records)  write 0x%08X  pending %d'
              % (R, R2, moved, W2, P2))

        after = sum_plot(d)
        print('plot  : checksum after  %s' % after)
        print()
        if moved >= a.k + 1 and P2 == 0:
            print('DRAINED ALL %d. One append flushed every staged record -- the hook does'
                  % (a.k + 1))
            print('not care who filled the ring, only what pending says.')
        elif moved <= 1:
            print('The hook drained only %d record. Pending was not honoured as expected;'
                  % max(moved, 0))
            print('read +0xA0 and +0x10 again and check nothing reset them.')
        else:
            print('Partial drain: %d of %d. Look at the batching bound (0xEF / 0x1C = 8).'
                  % (moved, a.k + 1))
        print('plot interior %s' % ('CHANGED, so the glass followed'
                                    if after != before else
                                    'identical -- cursors moved but nothing repainted'))
    finally:
        # RESTORE THE RING CURSORS FIRST, before anything else can fail.
        #
        # Staging moves sub+0x90 and sub+0xA0, and the firmware's push carries on from
        # whatever it finds in them. Leaving them advanced puts the read and write cursors
        # permanently out of step: the subscription's accounting stops adding up, and the
        # service task reports 2350 "SPLT command message lost" as a modal dialog that
        # reappears on OK, blocks the socket AND the web panel, and clears only on a power
        # cycle. Measured the hard way on 2026-11-08.
        if base is not None and R is not None:
            try:
                rr = ask(d, one("do local ok1 = KG.own(%d, 4)" % (base + 0x90),
                                "local okA = KG.p32(%d, %d)" % (base + 0x90, R),
                                "local ok2 = KG.own(%d, 4)" % (base + 0xA0),
                                "local okB = KG.p32(%d, 0)" % (base + 0xA0),
                                "print('X|' .. tostring(okA) .. ',' .. tostring(okB)) end"),
                         'X|', tries=20)
                print('restore: write=0x%08X pending=0  (%s)' % (R, rr[2:]))
            except SystemExit as e:
                print('restore: FAILED (%s)' % e)
                print('         THE RING IS LEFT ADVANCED -- power cycle before using the app')
        ask(d, one("do ZB, H2B = nil, nil if fftsa.saved_frame ~= nil then",
                   "fftsa.frame = fftsa.saved_frame fftsa.saved_frame = nil end",
                   "print('UP|running') end"), 'UP|', tries=25)
        try:
            x = ask(d, "print('T|' .. tostring(fftsa.acq_tick_n))", 'T|', tries=20)
            time.sleep(3)
            y = ask(d, "print('T|' .. tostring(fftsa.acq_tick_n))", 'T|', tries=20)
            print('unpark: acquisitions %s then %s -- %s'
                  % (x[2:], y[2:], 'running' if x != y else 'NOT ADVANCING'))
        except SystemExit as e:
            print('unpark: could not confirm (%s)' % e)
        d.close()


if __name__ == '__main__':
    main()
