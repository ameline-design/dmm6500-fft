#!/usr/bin/env python3
"""What a background ring search costs per frame, and where the ring sits relative to the anchors.

Three numbers decide whether the pixel fill can ship, and none of them is known:

  1. BYTES PER SECOND that nl.FINDS sustains, measured on the instrument's own clock inside
     one statement, so the socket's latency and the frame timer are both excluded. A frame has
     about 20 ms to spare at 2048; the search budget per frame is that figure times this rate.

  2. HOW FAR the ring is from each anchor the app already has -- nl.arena, nl.inst, the column
     pointers, heap_anchor(). If the ring is reliably within a megabyte of one of them, the
     search is a fraction of a second and there is no state machine to write at all.

  3. WHETHER THE APP'S OWN SPECTRUM WORKS AS THE NEEDLE. The probe seeds four sentinels and
     waits for a drain; the app cannot, so it has to search for the dB values it has just
     appended. Consecutive records hold consecutive dB, so four of them confirm a stride the
     same way four sentinels do -- if the values are distinct enough to be a needle at all.
     That is a property of the spectrum on the day and is measured, not assumed.

Read only. Nothing is written, no cursor is touched, and frames are left running throughout --
the live frame rate is the condition the answer has to hold under.

    python3 -u -I tools/probe_pixbudget.py
"""

import os
import struct
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import dmmrun  # noqa: E402


def ask(d, cmd, tag, timeout=600):
    """Send once, wait for a tagged reply, re-send only on a refusal.

    A refusal means the statement never ran and the frame timer holds the interpreter; silence
    means it is running and a second copy would run it twice. The two need opposite handling.
    """
    assert '\n' not in cmd, 'statements must be one line'
    assert len(cmd) < 1000, 'one-line probes die past 1024 bytes: %d' % len(cmd)
    d.drain()
    d.send(cmd)
    t_end = time.time() + timeout
    last, resends = None, 0
    while time.time() < t_end:
        t_read = time.time()
        r = d.line(min(20.0, t_end - time.time()))
        if r is None:
            if time.time() - t_read < 0.05:
                time.sleep(0.25)
            continue
        last = str(r)
        if last.startswith(tag):
            return last
        if 'another interface' in last:
            resends += 1
            if resends > 400:
                break
            d.drain()
            d.send(cmd)
    raise SystemExit('DESYNC(%s) last=%r after %d refusals' % (tag, last, resends))


def one(*parts):
    return ' '.join(p.strip() for p in parts)


def require_app(d):
    for _ in range(30):
        r = d.q(one("print('A|' .. tostring(fftsa ~= nil and fftsa.nl ~= nil",
                    "and type(fftsa.nl.FINDS) == 'function') .. '|'",
                    ".. tostring(fftsa ~= nil and fftsa.VERSION))"), timeout=30)
        if r is not None and str(r).startswith('A|true'):
            return str(r).split('|')[2]
        time.sleep(1.0)
    raise SystemExit('the app is not answering with a usable nl')


def anchors(d):
    """Every centre the app could search around, plus the backstop it is confined to."""
    r = ask(d, one("do local nl = fftsa.nl",
                   "local cp = nl.col_ptrs(nl.inst)",
                   "local o, i = '', nil",
                   "for i = 1, table.getn(cp) do o = o .. ',' .. string.format('%X', cp[i]) end",
                   "print('AN|' .. string.format('%X', nl.BACKSTOP_LO or 0)",
                   ".. '|' .. string.format('%X', nl.BACKSTOP_HI or 0)",
                   ".. '|' .. string.format('%X', nl.arena or 0)",
                   ".. '|' .. string.format('%X', nl.inst or 0)",
                   ".. '|' .. string.format('%X', nl.heap_anchor() or 0)",
                   ".. '|' .. o) end"), 'AN|', timeout=120)
    f = r.strip().split('|')
    out = {'backstop_lo': int(f[1], 16), 'backstop_hi': int(f[2], 16),
           'arena': int(f[3], 16), 'inst': int(f[4], 16), 'heap': int(f[5], 16),
           'cols': [int(x, 16) for x in f[6].split(',') if x]}
    return out


def throughput(d, lo, nbytes):
    """FINDS over nbytes, timed on the instrument. The needle cannot match, so the cost is
    the read and the scan and nothing else: a hit list that grows would charge the caller for
    string churn that a real search over cold memory does not pay."""
    r = ask(d, one("do local nl = fftsa.nl",
                   "local pat = string.char(0x5A,0xA5,0x3C,0xC3,0x5A,0xA5,0x3C,0xC3)",
                   "nl.sweep_reset()",
                   "local t0 = os.clock()",
                   "local h = nl.FINDS(%d, %d, pat)" % (lo, lo + nbytes),
                   "local t1 = os.clock()",
                   "print('TP|' .. string.format('%.4f', t1 - t0)",
                   ".. '|' .. tostring(table.getn(h))",
                   ".. '|' .. tostring(nl._sw_bytes) .. '|' .. tostring(nl._sw_blocks)",
                   ".. '|' .. tostring(nl._sw_nil) .. '|' .. tostring(nl._sw_short)) end"),
             'TP|', timeout=600)
    f = r.strip().split('|')
    return {'s': float(f[1]), 'hits': int(f[2]), 'bytes': int(f[3]),
            'blocks': int(f[4]), 'nil': int(f[5]), 'short': int(f[6])}


def needle_quality(d):
    """The app's own spectrum as a needle: are the first few dB values distinct, and how many
    times does the leading one appear in the pass it just wrote?

    The app searches for f32(db[1]) doubled and confirms db[2..4] at a stride. That fails if
    db[1] == db[2] (the finder refuses it outright) and it is slow if db[1] repeats across the
    band. Both are properties of the spectrum on the day.
    """
    r = ask(d, one("do local b = fftsa.sg_buf",
                   "if b == nil or b.n == nil or b.n < 8 then print('NQ|nil') return end",
                   "local n = b.n",
                   "local o, i = '', nil",
                   "for i = 1, 6 do o = o .. ',' .. string.format('%.4f', b.readings[i]) end",
                   "local dup, j = 0, nil",
                   "for j = 1, n do if b.readings[j] == b.readings[1] then dup = dup + 1 end end",
                   "print('NQ|' .. tostring(n) .. '|' .. tostring(dup) .. '|' .. o) end"),
             'NQ|', timeout=120)
    return r.strip()


def main():
    d = dmmrun.DMM(timeout=120, recover=False)
    ver = require_app(d)
    print('app    : v%s, frames left running' % ver)

    a = anchors(d)
    print('backstop: %08X..%08X  (%.1f MB)'
          % (a['backstop_lo'], a['backstop_hi'],
             (a['backstop_hi'] - a['backstop_lo']) / 1048576.0))
    print('anchors : arena=%08X inst=%08X heap=%08X cols=%s'
          % (a['arena'], a['inst'], a['heap'],
             ' '.join('%08X' % c for c in a['cols'])))

    base = a['arena'] or a['backstop_lo']
    print()
    print('FINDS throughput, needle absent, on the instrument clock:')
    for kb in (32, 256, 1024, 4096):
        t = throughput(d, base, kb * 1024)
        rate = (t['bytes'] / t['s'] / 1048576.0) if t['s'] > 0 else 0.0
        print('  %6d KB  %7.1f ms  %6.1f MB/s  blocks=%d nil=%d short=%d'
              % (kb, 1000 * t['s'], rate, t['blocks'], t['nil'], t['short']))

    print()
    print('needle  : %s' % needle_quality(d))
    print('  (n, times db[1] repeats in the pass, then db[1..6])')


if __name__ == '__main__':
    main()
