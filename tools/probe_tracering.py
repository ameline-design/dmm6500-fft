#!/usr/bin/env python3
"""Find the display task's trace object and read the ring the widget actually draws from.

This is the bypass the whole investigation is for. Points cannot reach the graph except one
per buffer.write.reading, and the buffer-side staging ring cannot be pre-loaded -- the push
SETS its pending count rather than incrementing it, measured. But the data the widget DRAWS
lives somewhere else: the trace object's own ring, 720 records of 56 bytes, and nothing has
ever tried writing that.

From the decompile (notes/firmware/graph/fns8.c, graph_fn_22140_timer at 0x00022140):

    trace + 0x08    the buffer name, 32 bytes   <- how this finds it, with no fw address
    trace + 0x208   ring start
    trace + 0x20C   ring end
    trace + 0x210   oldest cursor
    trace + 0x214   write cursor, advanced 0x38 a record
    trace + 0x218   record count, capped at 0x2D0 = 720
    trace + 0x220   the ring, 56-byte records
    graph + 0x5B0   pending-repaint flag

and within a record, the 28 bytes the buffer side sends land at +0x1C:

    rec + 0x1C   zero        rec + 0x28  flags      rec + 0x34  one word
    rec + 0x20   value f32   rec + 0x2C  x f32
    rec + 0x24   value f32   rec + 0x30  x f32

READ ONLY. Nothing here writes. It answers three questions:

  1. Is the trace object findable by its buffer name, so no firmware address is needed?
  2. Does its ring hold the current spectrum as float32 at the offsets above?
  3. What are the count and cursors, so a write would know what to set?

Only then is writing it worth trying, and the 2350 lesson applies to that: cursors and counts
get restored before anything else can fail.

    python3 -u -I tools/probe_tracering.py
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
NAME_OFF = 0x08
REC = 0x38                       # 56 bytes a record
RING_OFF = 0x220        # the doc's figure; the real ring is a pointer at +0x208
CAP = 0x2D0                      # 720 records


def ask(d, cmd, tag, tries=16, timeout=180):
    assert '\n' not in cmd, 'statements must be one line'
    assert len(cmd) < 1000, 'one-line probes die past 1024 bytes: %d' % len(cmd)
    r = None
    for _ in range(tries):
        r = d.q(cmd, timeout=timeout)
        if r is not None and str(r).startswith(tag):
            return str(r)
        time.sleep(1.3)
    raise SystemExit('DESYNC(%s) last=%r' % (tag, r))


def require_idle(d):
    """Frames must already be stopped, and the operator stops them from the panel.

    Parking over the socket does not work and it was tried four times: the frame loop holds
    the interpreter, so the very statement that would stop it is refused with "a command from
    another interface is running". The app parents its frame timer to the spectrum screen, so
    OPENING OPTIONS OR ABOUT STOPS FRAMES -- and the trace object and its ring stay intact
    while that screen is up. That is the way in, and it costs no socket contention at all.
    """
    for _ in range(20):
        r = d.q("print('I|' .. tostring(fftsa ~= nil))", timeout=25)
        if r is not None and str(r).startswith('I|true'):
            return True
        time.sleep(1.5)
    raise SystemExit('the interpreter is busy -- open Options or About on the panel to stop '
                     'frames, then run this again')


def one(*parts):
    return ' '.join(p.strip() for p in parts)


def hexs(d, addr, n):
    r = ask(d, one("do local s = KG.read(%d, %d)" % (addr, n),
                   "if s == nil then print('X|nil') return end",
                   "local o, i = '', nil",
                   "for i = 1, string.len(s) do",
                   "o = o .. string.format('%02X', string.byte(s, i)) end",
                   "print('X|' .. o) end"), 'X|')
    b = r[2:].strip()
    return None if b == 'nil' else bytes.fromhex(b)


def f32(u):
    return struct.unpack('>f', struct.pack('>I', u))[0]


def main():
    g = Guard(IMAGE)
    d = DMM(recover=False, timeout=240)
    try:
        d.drain()
        require_idle(d)
        print('idle  : interpreter free, frames stopped')
        st = ask(d, one("do local b = fftsa.sg_buf",
                        "print('S|' .. tostring(b.n) .. ',' .. tostring(b.capacity)",
                        ".. ',' .. tostring(fftsa.sg_flo_hz) .. ',' .. tostring(fftsa.sg_fhi_hz)",
                        ".. ',' .. tostring(fftsa.sg_ncol)) end"), 'S|')
        n, cap, flo, fhi, ncol = st[2:].split(',')
        print('state : trace %s/%s points, span %s..%s Hz, %s columns'
              % (n, cap, flo, fhi, ncol))

        for i, stmt in enumerate(g.tsp()):
            ask(d, stmt.replace('\n', ' '), 'KG|%d' % (i + 1), timeout=60)
        print('guard : installed')

        # The trace object by its buffer name. 82,464 bytes come from the same allocator as
        # everything else, so the sweep anchors on tostring({}) exactly as describe() does.
        r = ask(d, one("do local a = fftsa.nl.heap_anchor()",
                       "local w = fftsa.nl.sweep_windows()",
                       "print('A|' .. tostring(a) .. ',' .. tostring(table.getn(w))",
                       ".. ',' .. tostring(w[1][1]) .. ',' .. tostring(w[1][2])) end"), 'A|')
        _, nw, w1lo, w1hi = r[2:].split(',')
        print('sweep : anchor window 0x%08X..0x%08X (%s windows)'
              % (int(w1lo), int(w1hi), nw))

        # EVERY window, not just the first. A trace object is 82 KB and removeall/add leaves
        # stale ones behind, so the live one need not be the first hit or in the near window.
        # Most hits are the app's own Lua source sitting in memory, which is why each
        # candidate is judged by its ring rather than by the name alone.
        lst = ''
        total = 0
        for wi in range(1, int(nw) + 1):
            hits = ask(d, one("do local w = fftsa.nl.sweep_windows()",
                              "local h = fftsa.nl.FINDS(w[%d][1], w[%d][2], 'FFTSA_TRACE')" % (wi, wi),
                              "local o, k = '', nil",
                              "for k = 1, table.getn(h) do",
                              "if k <= 40 then o = o .. string.format('%X ', h[k]) end end",
                              "print('H|' .. tostring(table.getn(h)) .. '|' .. o) end"),
                       'H|', timeout=600)
            c, l = hits[2:].split('|')
            print('name  : window %d, %s occurrences' % (wi, c))
            total += int(c)
            lst = lst + ' ' + l.strip()
        if total == 0:
            raise SystemExit('the name is nowhere in the swept windows')

        # A trace object has the name at +0x08, so each hit is a candidate base at hit-8.
        # The ring bounds are what confirm it: end - start is 720 * 56 = 40320.
        print()
        print('%-12s %-10s %-10s %-8s %-7s %s' % ('base', 'ringlo', 'ringhi', 'span',
                                                  'count', 'verdict'))
        best = None
        for tok in lst.split():
            base = int(tok, 16) - NAME_OFF
            w = hexs(d, base + 0x208, 0x1C)
            if w is None:
                print('0x%08X   unreadable' % base)
                continue
            lo, hi, old, wr, cnt2 = struct.unpack('>IIIII', w[:20])
            span = hi - lo if hi > lo else 0
            # The ring start is a POINTER, not a fixed offset: measured at base + 0xA1D0 on
            # 1.7.17a, so requiring base + 0x220 rejects the real object. What identifies it
            # is the SPAN -- a whole number of 56-byte records, 720 or 721 of them, the
            # extra slot being the usual ring spare above the 0x2D0 count cap.
            nrec = span // REC if REC else 0
            okring = (span == nrec * REC and nrec in (CAP, CAP + 1)
                      and lo > 0x100000 and hi > lo)
            print('0x%08X   %08X   %08X   %-8d %-7d %s'
                  % (base, lo, hi, span, cnt2,
                     '%d records of %d' % (nrec, REC) if okring else 'no'))
            if okring:
                # A live trace has records in it. An empty one is a stale allocation from an
                # earlier removeall/add, and writing that would paint nothing.
                if best is None or (cnt2 > 0 and best[5] == 0):
                    best = (base, lo, hi, old, wr, cnt2)
        if best is None:
            print()
            print('No candidate had a 40320-byte ring. Either the name sits at a different')
            print('offset on this build or the trace object is outside the swept window.')
            return
        base, lo, hi, old, wr, cnt2 = best
        print()
        print('trace : 0x%08X  ring 0x%08X..0x%08X  oldest 0x%08X  write 0x%08X  count %d'
              % (base, lo, hi, old, wr, cnt2))
        print('        ring sits at base + 0x%X, not the +0x%X the notes give'
              % (lo - base, RING_OFF))

        # The decisive read: do the records hold this frame's spectrum as float32?
        k = 6
        blob = hexs(d, lo, k * REC)
        print()
        print('%-6s %-12s %-12s %-10s %-12s %s'
              % ('rec', 'value f32', 'value2 f32', 'flags', 'x f32', 'x2 f32'))
        for i in range(k):
            rec = blob[i * REC:(i + 1) * REC]
            v1, v2 = struct.unpack('>II', rec[0x20:0x28])
            fl, = struct.unpack('>I', rec[0x28:0x2C])
            x1, x2 = struct.unpack('>II', rec[0x2C:0x34])
            print('%-6d %-12.4g %-12.4g 0x%08X %-12.6g %-.6g'
                  % (i, f32(v1), f32(v2), fl, f32(x1), f32(x2)))
        print()
        print('If the x column walks the span and the value column looks like dB, this is the')
        print('ring the widget draws and writing it is the bypass: one memwrite for a whole')
        print('pass, with the count set to exactly one pass so nothing stale is drawn.')
    finally:
        # Nothing to restore: frames were never parked from here.
        d.close()


if __name__ == '__main__':
    main()
