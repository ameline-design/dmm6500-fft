#!/usr/bin/env python3
"""Find the display task's trace ring from the app's own appends, then ask whether writing it draws.

This is the bypass the graph investigation exists for. Every other route is closed, each
measured: no bulk write is registered, display.setvalue refuses a graph with event 1717, the
buffer-side staging ring's pending count cannot be pre-loaded because the push SETS it, and an
in-place buffer write draws nothing because the display task works from its own copy. That copy
is a ring of records, and nothing has ever written it.

Three phases, deliberately separated, each answering one thing.

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

Only the two float32 fields of a record are touched: no pointer, no cursor, no count, so the
worst case is a wrong value drawn rather than a freed-widget fault.

THE WHOLE PASS, --pass. The per-frame path, prototyped here rather than in the app. It writes
every record of one pass from the app's own trace shifted in dB, sets the count and both
cursors so the geometry is the same every pass, fires one append, times the write on the
instrument's clock and compares the plot. One run then answers all three questions the app
cannot be written without: do the records draw, is the cursor convention right, and what does a
pass cost -- which is what decides whether the Lua form is worth shipping or whether the write
has to be native.

    python3 -u -I tools/probe_ringfind.py --pass
    python3 -u -I tools/probe_ringfind.py --pass --shift 20 --hold 8

Everything written is restored first in the finally block, before anything else that can fail
-- the 2350 lesson -- and the header goes back before the records, because an inconsistent
cursor is the part that cannot be left behind.

PARKING IS REQUIRED AND THIS DOES NOT DO IT -- FIX THAT BEFORE USING IT AGAIN.

A socket session does NOT stop the app's frame timer. Measured 2026-11-09: sg_stamp advanced
82,110 counts with a probe connected, so every sentinel appended here is overwritten within
about 100 ms, long before a sweep reaches it. Two runs of this probe were invalidated that way
and reported a desync that looked like a refusal.

Parking FROM the socket DOES work, which an earlier note denied -- 4.2 s and 6 refusals of
persistent retrying, then sg_stamp froze:

    do if fftsa.saved_frame == nil then fftsa.saved_frame = fftsa.frame
    fftsa.frame = function() end end print('P|' .. tostring(fftsa.saved_frame ~= nil)) end

Confirm it by reading sg_stamp twice, not by that statement's own reply.

AND THE QUESTION THIS WAS BUILT TO ANSWER IS ANSWERED, AND IT IS NO. Writing the float value of
a record inside the drawn window changes nothing on the glass: writes read back present,
repaint confirmed by the triggering append's own point appearing, values absent, twice. See
docs/PERFORMANCE.md. What is still open is only what the two int32 triples at record
+0x00..0x1F are -- pixel coordinates is the hypothesis.
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
DO_PASS = '--pass' in sys.argv
# --pass writes a widget's cursors, which is the one step here that is not just a value.
# Requiring the word is not ceremony: the nearest thing to it, leaving a SUBSCRIPTION ring's
# cursors advanced, ended in a modal 2350 that only a power cycle cleared.
SAY_YES = '--yes' in sys.argv
NREC = opt('--nrec', 32)
WDB = opt('--db', -20.0, float)
SHIFT = opt('--shift', 20.0, float)
HOLD = opt('--hold', 0.0, float)


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


def whole_pass(d, ring):
    """One pass written the way a frame would write it, timed and then undone.

    This is the prototype for the app's per-frame path, and it is here rather than in the app
    because three things have to be true before that code is worth writing and none of them is
    knowable offline: that the records are what the widget draws, that resetting the count and
    both cursors every pass keeps the geometry fixed, and that the write is cheap enough to be
    worth doing in Lua at all.

    The values come off the app's own trace shifted in dB, so the picture should be the same
    curve lifted bodily. A synthetic shape would also answer "did anything change", but not
    "did the RIGHT thing change", and a shift is the one change that is unmistakable at a
    glance and impossible to produce by accident.
    """
    lo, hi, s, hdr = ring['lo'], ring['hi'], ring['stride'], ring['hdr']
    ov, ox, nrec = ring['ov'], ring['ox'], ring['nrec']
    # One pass is what the app plots, bounded by the ring and leaving the slot the triggering
    # append will take.
    r = ask(d, one("do print('N|' .. tostring(fftsa.sg_ncol) .. ',' .. tostring(fftsa.sg_buf.n)",
                   ".. ',' .. tostring(fftsa.sg_buf.capacity)) end"), 'N|')
    ncol, bn, bcap = (int(x) for x in r[2:].split(','))
    n = min(ncol, nrec - 1, bn)
    if n < 8:
        print('pass   : only %d points available, not enough to judge' % n)
        return
    # A ring this short is not the one the display task draws a spectrum from, and the thing
    # it is most likely to be instead is the buffer-side staging ring -- whose cursors are
    # the ones that must never be left moved. The header test already separates them; this is
    # the second lock on the same door.
    if nrec < 64:
        print('pass   : the ring holds only %d records, which is too few to be the trace '
              'ring. Refusing to write it.' % nrec)
        return
    # Fused or split. On a 6500 the value pair, the flags and the x pair are 20 contiguous
    # bytes, so one write a record does it; anywhere else it is two. Halving the call count
    # matters because the calls are the cost.
    fuse = (ox == ov + 12)
    print('pass   : %d records, %s write a record, span 0x%X..0x%X'
          % (n, 'one fused 20-byte' if fuse else 'two 8-byte', lo, hi))

    # THE CURSOR CONVENTION, DERIVED. The measured header had write = lo + 254*stride with
    # count = 255, so the cursor points at the LAST written record and not one past it -- but
    # that is one observation on one build. Taking the offset between the live cursor and the
    # live count and preserving it means the convention never has to be assumed.
    lv = ask(d, one("do local v = fftsa.nl.ring_header(RG)",
                    "print('L|' .. tostring(v.count) .. ',' .. tostring(v.write)) end"), 'L|')
    c0, w0 = (int(x) for x in lv[2:].split(','))
    coff = (w0 - lo) // s - c0
    print('cursor : live count %d, write at record %d, so the cursor sits %+d from the count'
          % (c0, (w0 - lo) // s, coff))

    ask(d, "print('O|' .. tostring(KG.own(%d,%d)))" % (hdr, hi - hdr), 'O|')
    # SAVED ON THE INSTRUMENT, not over the wire: the records are 14 kB and the socket moves
    # 110 kB/s, so a host-side copy would cost a second each way and a restore that slow is a
    # restore that might not happen.
    # The addresses are formatted HERE, not on the instrument: a string.format('%X', ...)
    # inside a Python %-formatted fragment has its escape eaten before Lua sees it, which
    # audit_probe.py exists to catch and did.
    ask(d, one("do ZS = ki.memread('%X', '%X')" % (lo, hi - lo),
               "ZH = {KG.w(%d), KG.w(%d), KG.w(%d), KG.w(%d), KG.w(%d)}"
               % (hdr, hdr + 4, hdr + 8, hdr + 12, hdr + 20),
               "print('S|' .. tostring(string.len(ZS)) .. ',' .. tostring(ZH[5])) end"), 'S|')
    print('saved  : the whole ring and five header words, on the instrument')

    # The writer, defined once so the timing is of the loop and not of the definition.
    if fuse:
        body = ("local fl = string.sub(ki.memread(string.format('%X', lo + ov + 8), '4'), 1, 4) "
                "for i = 1, n do local a = lo + (i - 1) * s "
                "local v = P(b.readings[i] + dsh) local x = P(b.extravalues[i]) "
                "KG.write(a + ov, v .. v .. fl .. x .. x) end")
    else:
        body = ("for i = 1, n do local a = lo + (i - 1) * s "
                "local v = P(b.readings[i] + dsh) local x = P(b.extravalues[i]) "
                "KG.write(a + ov, v .. v) KG.write(a + ox, x .. x) end")
    ask(d, one("do function ZW(lo, s, ov, ox, n, dsh)",
               "local b, P, i = fftsa.sg_buf, fftsa.nl._f32_pack, nil",
               body,
               "end print('F|1') end"), 'F|1')

    before = sumplot(d)
    ask(d, "do KG.armed = true print('M|' .. tostring(KG.armed)) end", 'M|')
    t = ask(d, one("do local c = os.clock local t0 = c()",
                   "ZW(%d, %d, %d, %d, %d, %.1f)" % (lo, s, ov, ox, n, SHIFT),
                   "local t1 = c()",
                   "KG.p32(%d, %d) KG.p32(%d, %d) KG.p32(%d, %d)"
                   % (hdr + 20, n, hdr + 8, lo, hdr + 12, lo + (n + coff) * s),
                   "local t2 = c()",
                   "print(string.format('T|%.2f|%.2f', (t1-t0)*1000, (t2-t1)*1000)) end"),
            'T|', timeout=300)
    wms, hms = (float(x) for x in t[2:].split('|'))
    print('timing : %d records in %.2f ms, header in %.2f ms -- %.1f us a record'
          % (n, wms, hms, wms * 1000.0 / n))

    ask(d, one("do fftsa.sg_stamp = (fftsa.sg_stamp or 0) + 1",
               "buffer.write.reading(fftsa.sg_buf, -105.0, 32768.0, fftsa.sg_stamp, 0)",
               "delay(0.4) print('P|3') end"), 'P|3', timeout=120)
    after = sumplot(d)
    print('plot   : before %s  after %s  -> %s'
          % (before, after, 'CHANGED' if after != before else 'same'))
    hv = ask(d, one("do local v = fftsa.nl.ring_header(RG)",
                    "print('A2|' .. tostring(v.count) .. ',' .. tostring(v.write)",
                    ".. ',' .. tostring(v.oldest)) end"), 'A2|')
    print('header : after the triggering append, count,write,oldest = %s'
          % hv.split('|', 1)[1])
    if after != before:
        print()
        print('THE PER-FRAME PATH WORKS. %.2f ms a pass against about 39 ms for 510 appends.'
              % (wms + hms))
        print('Look at the glass: the curve should be the same shape lifted %.0f dB.' % SHIFT)
    else:
        print()
        print('The plot did not change. Before concluding the records are not what is drawn,')
        print('check that one ordinary append alone changes this checksum at all.')
    if HOLD > 0:
        print('hold   : %.0f s on the glass before the restore' % HOLD)
        ask(d, "do delay(%.1f) print('Y|1') end" % HOLD, 'Y|1', timeout=int(HOLD) + 60)

    # RESTORE: the header first, because an inconsistent cursor is the part that must not be
    # left behind, then the records. Each in its own statement so one failing does not skip
    # the other.
    # Each in its own call and each in its own try, so a failure in one does not skip the
    # rest. The header goes first: an inconsistent cursor is the part that must not be left
    # behind, and a stale record is only a wrong value drawn for one frame.
    for label, stmt, t in (
        ('header', one("do KG.p32(%d, ZH[1]) KG.p32(%d, ZH[2]) KG.p32(%d, ZH[3])"
                       % (hdr, hdr + 4, hdr + 8),
                       "KG.p32(%d, ZH[4]) KG.p32(%d, ZH[5])" % (hdr + 12, hdr + 20),
                       "print('Z2|1') end"), 60),
        ('records', "print('Z3|' .. tostring(KG.write(%d, ZS)))" % lo, 120),
        ('guard', 'do KG.armed = false KG.wb = nil ZS, ZH, ZW = nil, nil, nil end', 60),
    ):
        try:
            d.q(stmt, timeout=t)
        except Exception as e:                                       # noqa: BLE001
            print('restore: %s FAILED -- %s' % (label, e))
            print('         the app rewrites every record on its next frame, so closing this')
            print('         socket and letting frames resume recovers the picture.')
    print('restore: header and all %d bytes of records put back' % (hi - lo))


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

        # COMMAS. A Lua table constructor separates entries with ',' or ';', and joining
        # these with a space built a statement that is not Lua at all -- the instrument
        # printed nothing, every retry, and the probe reported a desync with last=None. The
        # stub harness could not see it either, because it answered by tag without caring
        # whether the statement parsed. It runs luac -p over every statement now.
        sent = ', '.join("{db=%.1f,hz=%.1f}" % (db, hz) for db, hz in SENTINELS)
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
            ring = dict(val0=val0, stride=stride, dx=dx, hdr=hdr, lo=lo, hi=hi, nrec=nrec,
                        ov=ov, ox=ox)
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

        # THE WHOLE RECORD, both of the first two, as bytes and as decoded float32. The
        # question the write experiment cannot settle on its own is what the bytes outside the
        # two fields are for: if +0x00..0x1F holds pixel coordinates the widget computed at
        # append time, then writing the value and the x changes a cache nobody reads back, and
        # the bypass needs those recomputed too. Printing them is what makes that judgeable
        # instead of guessed.
        if 'lo' in ring:
            v0, s, dxv = ring['val0'], ring['stride'], ring['dx']
            base = v0 - ring['ov']
            print()
            print('the first two SENTINEL records in full, of %d in the ring. These are the'
                  % ring['nrec'])
            print('ones whose contents are known, which is what makes the other bytes readable.')
            for k in range(2):
                a = base + k * s
                r = ask(d, one("do local s = ki.memread('%X', '%X')" % (a, s),
                               "if s == nil then print('D|nil') return end",
                               "local o, i = '', nil",
                               "for i = 1, string.len(s) do",
                               "o = o .. string.format('%02X', string.byte(s, i)) end",
                               "print('D|' .. o) end"), 'D|', timeout=120)
                if r[2:].strip() == 'nil':
                    print('  rec %d  unreadable' % k)
                    continue
                b = bytes.fromhex(r[2:].strip())
                print('  rec %d  0x%08X' % (k, a))
                for off in range(0, len(b), 16):
                    print('    +0x%02X  %s' % (off, ' '.join('%02X' % x for x in b[off:off + 16])))
                for off in range(0, len(b) - 3, 4):
                    f = struct.unpack('>f', b[off:off + 4])[0]
                    tag = ''
                    if off == ring['ov'] or off == ring['ov'] + 4:
                        tag = '  <- value'
                    elif off == ring['ox'] or off == ring['ox'] + 4:
                        tag = '  <- x'
                    if tag or (1e-6 < abs(f) < 1e9):
                        print('    +0x%02X  %-16.6g %08X%s'
                              % (off, f, struct.unpack('>I', b[off:off + 4])[0], tag))

        if not (DO_WRITE or DO_PASS):
            print()
            print('Read only. --write answers whether the widget draws from these records.')
            print('--pass prototypes the whole per-frame path and times it.')
            return

        # ---- the experiments ---------------------------------------------------------
        if 'lo' not in ring:
            print()
            print('No header, so nothing can be bounded inside the ring. Refusing to write.')
            return
        for i, stmt in enumerate(g.tsp()):
            ask(d, stmt.replace('\n', ' '), 'KG|%d' % (i + 1), timeout=60)
        print('guard  : installed')

        if DO_PASS:
            if not SAY_YES:
                print()
                print('--pass writes %d records AND the ring header: the count and both'
                      % min(255, ring.get('nrec', 0)))
                print('cursors. Everything is saved on the instrument first and restored in')
                print('the finally, but a widget cursor is not a value -- add --yes to run it.')
                return
            whole_pass(d, ring)
            if not DO_WRITE:
                return

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
                d.q("print('Z1|' .. tostring(KG.write(%d, %s)))" % (a, luachars(b)),
                    timeout=60)
            print('restore: %d records put back' % len(saved))
        d.q('do KG.armed = false KG.wb = nil end', timeout=30)
        d.q('RS, RG = nil, nil', timeout=30)
        d.close()


if __name__ == '__main__':
    main()
