#!/usr/bin/env python3
"""Find the display task's trace ring from the app's own appends, then ask whether writing it draws.

This is the bypass the graph investigation exists for. Every other route is closed, each
measured: no bulk write is registered, display.setvalue refuses a graph with event 1717, the
buffer-side staging ring's pending count cannot be pre-loaded because the push SETS it, and an
in-place buffer write draws nothing because the display task works from its own copy. That copy
is a ring of records, and nothing has ever written it.

Two phases, deliberately separated.

READ ONLY, the default. Appends four sentinel readings through the sanctioned path, then calls
fftsa.nl.find_ring_records and find_ring_header on the instrument and prints what they found.
Nothing is written. It answers: can the ring be found at all, is the stride what a 6500 showed,
and is the header identified uniquely.

    python3 -u -I tools/probe_ringfind.py

THE WRITE EXPERIMENT, --write. Saves a run of records, writes an unmistakable dB into them,
fires one append to provoke a repaint, and compares a checksum of the plot interior. It answers
the one question the whole design rests on: does the widget draw from these records, or does it
redraw from something else and leave them as a cache nobody reads.

    python3 -u -I tools/probe_ringfind.py --write
    python3 -u -I tools/probe_ringfind.py --write --nrec 64 --db -20

Everything written is restored first in the finally block, before anything else that can fail
-- the 2350 lesson. Only the two float32 fields of a record are touched: no pointer, no cursor,
no count, so the worst case is a wrong value drawn rather than a freed-widget fault.

NO PARKING IS NEEDED AND NONE IS ATTEMPTED. A socket session suppresses display event dispatch,
so the app's frame timer stops firing the moment this connects, the spectrum screen stays on the
glass with its last trace, and the ring keeps the contents that trace was drawn from. Four
attempts at parking the frame loop over the socket failed before that was understood.
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
PLOT = (100, 60, 780, 340)

# Exactly representable in float32, so the needle the finder builds is the bit pattern the
# firmware stored and not a rounding of it. Distinct dB values, because the stride is measured
# from the distance between two of them.
SENTINELS = [(-100.0, 1024.0), (-101.0, 2048.0), (-102.0, 4096.0), (-103.0, 8192.0)]


def opt(flag, default, cast=int):
    return cast(sys.argv[sys.argv.index(flag) + 1]) if flag in sys.argv else default


DO_WRITE = '--write' in sys.argv
NREC = opt('--nrec', 32)
WDB = opt('--db', -20.0, float)


def ask(d, cmd, tag, tries=14, timeout=600):
    assert '\n' not in cmd, 'statements must be one line'
    assert len(cmd) < 1000, 'one-line probes die past 1024 bytes: %d' % len(cmd)
    r = None
    for _ in range(tries):
        r = d.q(cmd, timeout=timeout)
        if r is not None and str(r).startswith(tag):
            return str(r)
        time.sleep(1.3)
    raise SystemExit('DESYNC(%s) last=%r' % (tag, r))


def one(*parts):
    return ' '.join(p.strip() for p in parts)


def luachars(b):
    """Bytes as a string.char(...) call, so nothing binary crosses the wire."""
    return 'string.char(' + ','.join(str(x) for x in b) + ')'


def f32(v):
    return struct.pack('>f', v)


def require_app(d):
    """The app has to be live AND new enough to carry the finder, or this measures nothing."""
    for _ in range(20):
        r = d.q(one("print('A|' .. tostring(fftsa ~= nil and fftsa.nl ~= nil",
                    "and type(fftsa.nl.find_ring_records) == 'function')",
                    ".. '|' .. tostring(fftsa ~= nil and fftsa.sg_buf ~= nil))"), timeout=30)
        if r is not None and str(r).startswith('A|true|true'):
            return True
        if r is not None and str(r).startswith('A|false'):
            raise SystemExit('this build has no fftsa.nl.find_ring_records -- needs 8.53 or later')
        time.sleep(1.5)
    raise SystemExit('the app is not answering; is it running on the spectrum screen?')


def sumplot(d):
    x1, y1, x2, y2 = PLOT
    return ask(d, "print('C|' .. tostring(ki.display.getchecksum(%d,%d,%d,%d)))"
               % (x1, y1, x2, y2), 'C|', timeout=60)[2:].strip()


def append_sentinels(d):
    """Through buffer.write.reading, which is the only call the display task reads."""
    for i, (db, hz) in enumerate(SENTINELS):
        ask(d, one("do local b = fftsa.sg_buf",
                   "fftsa.sg_stamp = (fftsa.sg_stamp or 0) + 1",
                   "buffer.write.reading(b, %.1f, %.1f, fftsa.sg_stamp, 0)" % (db, hz),
                   "print('W|%d') end" % (i + 1)), 'W|%d' % (i + 1), timeout=120)


def main():
    g = Guard(IMAGE)
    d = DMM(recover=False, timeout=600)
    saved = None
    ring = {}
    try:
        d.drain()
        require_app(d)
        st = ask(d, one("do local b = fftsa.sg_buf",
                        "print('S|' .. tostring(b.n) .. ',' .. tostring(b.capacity)",
                        ".. ',' .. tostring(fftsa.sg_ncol) .. ',' .. tostring(fftsa.sg_fold)",
                        ".. ',' .. tostring(fftsa.sg_flo_hz) .. ',' .. tostring(fftsa.sg_fhi_hz)",
                        ".. ',' .. tostring(fftsa.n)) end"), 'S|')
        print('state : %s' % st[2:])
        print('        n,capacity,ncol,fold,flo,fhi,fft')

        append_sentinels(d)
        print('seed  : four sentinels appended through buffer.write.reading')

        sent = ' '.join("{db=%.1f,hz=%.1f}" % (db, hz) for db, hz in SENTINELS)
        t0 = time.time()
        # The records first, reported with how many candidates confirmed: the buffer-side
        # staging ring holds the same two float32 pairs in a 28-byte record and confirms at a
        # stride just as well, so a single candidate and a dozen are different situations.
        r = ask(d, one("do RS = {%s}" % sent,
                       "local g = fftsa.nl.find_ring_records(RS)",
                       "if g == nil then print('R|nil|' .. tostring(fftsa.nl.ring_why)) return end",
                       "local c, o, i = fftsa.nl.ring_cands, '', nil",
                       "for i = 1, table.getn(c) do",
                       "o = o .. ' ' .. string.format('%X', c[i].val0) .. '/' .. c[i].stride end",
                       "print('R|ok|' .. tostring(table.getn(c)) .. ','",
                       ".. tostring(fftsa.nl.ring_hits) .. ',' .. o) end"), 'R|')
        print('find  : %.1f s' % (time.time() - t0))
        if r.startswith('R|nil'):
            print('records: NOT FOUND -- %s' % r[6:])
            print()
            print('The value needle is the sentinel dB packed as float32 twice. Not finding it')
            print('means either the record does not hold two adjacent copies, or the windows')
            print('scan_windows chose do not reach the display task\'s allocation.')
            return
        ncand, hits, lst = r[5:].split(',', 2)
        print('records: %s candidate%s, needle hits %s --%s'
              % (ncand, '' if ncand == '1' else 's', hits, lst))

        h = ask(d, one("do local g = fftsa.nl.find_ring(RS)",
                       "if g == nil then print('H|nil|' .. tostring(fftsa.nl.ring_why)",
                       ".. '|' .. tostring(fftsa.nl.ring_hdrs)) return end",
                       "RG = g",
                       "print('H|ok|' .. tostring(g.hdr) .. ',' .. tostring(g.lo)",
                       ".. ',' .. tostring(g.hi) .. ',' .. tostring(g.nrec)",
                       ".. ',' .. tostring(g.ov) .. ',' .. tostring(g.ox)",
                       ".. ',' .. tostring(g.val0) .. ',' .. tostring(g.stride)",
                       ".. ',' .. tostring(g.dx)) end"), 'H|')
        if h.startswith('H|nil'):
            print('header : NOT FOUND -- %s' % h[6:])
            print()
            print('Record candidates confirmed but none of them is a ring with a findable')
            print('header. The staging ring keeps its bounds at +0x8C and +0x94, which are not')
            print('adjacent, so a candidate with no header is very likely that one.')
        else:
            hdr, lo, hi, nrec, ov, ox, val0, stride, dx = (int(x) for x in h[5:].split(','))
            ring = dict(val0=val0, stride=stride, dx=dx, hdr=hdr, lo=lo, hi=hi, nrec=nrec)
            print('records: val0 0x%08X  stride %d  value->x %+d' % (val0, stride, dx))
            print('header : 0x%08X  ring 0x%08X..0x%08X  %d records  value at +0x%X  x at +0x%X'
                  % (hdr, lo, hi, nrec, ov, ox))
            print('        header sits 0x%X below the ring' % (lo - hdr))

            # THE FIELD ORDER BY CAUSE, NOT BY LAYOUT. One append has to raise the count by one
            # and advance the write cursor by exactly one stride. Nothing else in memory does.
            b = ask(d, one("do local v = fftsa.nl.ring_header(RG)",
                           "print('B|' .. tostring(v.count) .. ',' .. tostring(v.write)",
                           ".. ',' .. tostring(v.oldest)) end"), 'B|')
            c0, w0, o0 = (int(x) for x in b[2:].split(','))
            ask(d, one("do fftsa.sg_stamp = (fftsa.sg_stamp or 0) + 1",
                       "buffer.write.reading(fftsa.sg_buf, -104.0, 16384.0, fftsa.sg_stamp, 0)",
                       "print('P|1') end"), 'P|1', timeout=120)
            b = ask(d, one("do local v = fftsa.nl.ring_header(RG)",
                           "print('B|' .. tostring(v.count) .. ',' .. tostring(v.write)",
                           ".. ',' .. tostring(v.oldest)) end"), 'B|')
            c1, w1, o1 = (int(x) for x in b[2:].split(','))
            dc, dw = c1 - c0, (w1 - w0) % (hi - lo)
            print('cause  : one append moved count %+d and the write cursor %+d bytes (stride %d)'
                  % (dc, dw, ring['stride']))
            if dw == ring['stride']:
                print('        the cursor field is confirmed by cause')
            else:
                print('        THE CURSOR FIELD IS NOT CONFIRMED -- do not write the header')
            if c1 == c0 and c0 == nrec:
                print('        the count is already at the ring size, so it has stopped moving')

        if not DO_WRITE:
            print()
            print('Read only. Rerun with --write to answer whether the widget draws from these')
            print('records. That writes two float32 fields per record and restores them.')
            return

        # ---- the experiment ----------------------------------------------------------
        if 'lo' not in ring:
            print()
            print('No header, so the run to write cannot be bounded inside the ring. Refusing.')
            return
        for i, stmt in enumerate(g.tsp()):
            ask(d, stmt.replace('\n', ' '), 'KG|%d' % (i + 1), timeout=60)
        print('guard  : installed')

        v0, s, dxv = ring['val0'], ring['stride'], ring['dx']
        # How many records fit between val0 and the end of the ring, so no write leaves it.
        room = (ring['hi'] - max(v0, v0 + dxv) - 8) // s + 1
        n = min(NREC, room)
        if n < 1:
            print('no room above val0 inside the ring; rerun after the next frame')
            return
        print('write  : %d records from 0x%08X at %.1f dB (room for %d)' % (n, v0, WDB, room))

        lo8 = min(v0, v0 + dxv)
        span = max(v0, v0 + dxv) + 8 + (n - 1) * s - lo8
        ask(d, "print('O|' .. tostring(KG.own(%d,%d)))" % (lo8, span), 'O|')
        saved = []
        for k in range(n):
            a = v0 + k * s
            r = ask(d, one("do local s = KG.read(%d, 8)" % a,
                           "if s == nil then print('X|nil') return end",
                           "local o, i = '', nil",
                           "for i = 1, 8 do o = o .. string.format('%02X', string.byte(s, i)) end",
                           "print('X|' .. o) end"), 'X|', timeout=60)
            if r[2:].strip() == 'nil':
                raise SystemExit('cannot read record %d, so it must not be written' % k)
            saved.append((a, bytes.fromhex(r[2:].strip())))
        print('saved  : %d value fields read back for restore' % len(saved))

        before = sumplot(d)
        ask(d, "do KG.armed = true print('M|' .. tostring(KG.armed)) end", 'M|')
        pat = f32(WDB) * 2
        for a, _ in saved:
            r = ask(d, "print('V|' .. tostring(KG.write(%d, %s)))" % (a, luachars(pat)), 'V|')
            if not r.startswith('V|true'):
                raise SystemExit('the guard refused a write at 0x%08X: %s' % (a, r))
        print('wrote  : %d records' % len(saved))

        # One append to provoke the repaint, then let the display task run. It only runs while
        # Lua is blocked, which is what delay() is for.
        ask(d, one("do fftsa.sg_stamp = (fftsa.sg_stamp or 0) + 1",
                   "buffer.write.reading(fftsa.sg_buf, -105.0, 32768.0, fftsa.sg_stamp, 0)",
                   "delay(0.4) print('P|2') end"), 'P|2', timeout=120)
        after = sumplot(d)
        print()
        print('plot   : before %s  after %s  -> %s'
              % (before, after, 'CHANGED' if after != before else 'same'))
        if after != before:
            print('THE WIDGET DRAWS FROM THESE RECORDS. The bypass is real: one native write a')
            print('frame replaces 510 appends. Take a screenshot before the restore below.')
        else:
            print('No change. Either the widget recomputes from somewhere else, or the repaint')
            print('did not happen -- check that one append alone changes the plot at all before')
            print('concluding the records are not what is drawn.')
    finally:
        # RESTORE FIRST, before the guard is disarmed and before anything else can fail.
        if saved:
            for a, b in saved:
                d.q("print('R|' .. tostring(KG.write(%d, %s)))" % (a, luachars(b)), timeout=60)
            print('restore: %d records put back' % len(saved))
        d.q('do KG.armed = false KG.wb = nil end', timeout=30)
        d.q('RS, RG = nil, nil', timeout=30)
        d.close()


if __name__ == '__main__':
    main()
