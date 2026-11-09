#!/usr/bin/env python3
"""Why the ring search finds candidates and no header for any of them.

px_seek confirms a record stride from the app's own appends and then needs a header to tell the
trace ring from the staging ring that looks exactly like it. On the instrument the candidates
come and the headers do not, and the state machine has nowhere to put the reason -- so this
runs the same two calls from the socket and prints what each candidate is and what the header
search said about it.

Read only. The app's frame timer does not fire while this is connected, which is what makes it
safe to ask about the same records twice.

    python3 -u -I tools/probe_pixhdr.py
"""

import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import dmmrun  # noqa: E402


def ask(d, cmd, tag, timeout=900):
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


# The sentinels the app itself would use: the trace buffer's own first four points, which are
# what sg_fill appended and so what the ring holds.
SEED = one(
    "do local b = fftsa.sg_buf ZS = {}",
    "local i for i = 1, 4 do ZS[i] = { db = b.readings[i], hz = b.extravalues[i] } end",
    "fftsa.nl.px_restart('hdr probe')",
    "print('SD|' .. string.format('%.6f,%.6f,%.6f,%.6f', ZS[1].db, ZS[2].db, ZS[3].db,",
    "ZS[4].db) .. '|' .. string.format('%.1f,%.1f', ZS[1].hz, ZS[2].hz)) end")

# One slice, as big as the caller asks for, and every confirmation it produced.
#
# The varying number is concatenated in rather than reached through Python's % operator: a Lua
# string.format inside text that is itself %-formatted needs its percents doubled, and a
# doubled percent in text that turns out NOT to be formatted reaches Lua literally. Keeping
# every statement free of Python formatting removes the distinction, and notes/firmware/
# audit_probe.py then has nothing to warn about either way.
def slice_cmd(budget):
    return one(
        "do local nl = fftsa.nl",
        "ZC = nl.px_seek(ZS, " + str(budget) + ", fftsa.sg_buf)",
        "local o, i = '', nil",
        "for i = 1, table.getn(ZC) do",
        "o = o .. string.format(' %X/%d', ZC[i].val0, ZC[i].stride) end",
        "print('SL|' .. tostring(table.getn(ZC)) .. '|' .. tostring(nl.px.wi)",
        ".. '|' .. string.format('%X', nl.px.at or 0)",
        ".. '|' .. tostring(math.floor((nl.px.swept or 0) / 1048576)) .. 'MB|' .. o) end")


# And what the header search makes of each one.
def hdr_cmd(k):
    return one(
        "do local nl = fftsa.nl local g = ZC[" + str(k) + "]",
        "if g == nil then print('HD|none') return end",
        "local h = nl.find_ring_header(g)",
        "if h == nil then print('HD|nil|' .. tostring(nl.ring_hdrs) .. '|'",
        ".. tostring(nl.ring_why)) return end",
        "print('HD|ok|' .. tostring(nl.ring_hdrs) .. '|'",
        ".. string.format('%X..%X nrec=%d ov=%d ox=%d hdr=%X', g.lo, g.hi, g.nrec,",
        "g.ov, g.ox, g.hdr)) end")


def main():
    d = dmmrun.DMM(timeout=300, recover=False)
    for _ in range(30):
        r = d.q("print('A|' .. tostring(fftsa ~= nil and fftsa.nl ~= nil "
                "and type(fftsa.nl.px_seek) == 'function'))", timeout=30)
        if r is not None and str(r).startswith('A|true'):
            break
        time.sleep(1.0)
    else:
        raise SystemExit('the app is not answering with a usable px_seek')

    print('seed   : %s' % ask(d, SEED, 'SD|', timeout=120)[3:])
    print('         (db1..db4 | hz1,hz2 -- the app\'s own first four columns)')
    print()

    for slice_no in range(1, 40):
        r = ask(d, slice_cmd(4194304), 'SL|', timeout=900).strip().split('|')
        n, wi, at, swept, cands = int(r[1]), r[2], r[3], r[4], r[5]
        print('slice %2d: window %s at %s, %s swept, %d confirmations%s'
              % (slice_no, wi, at, swept, n, cands))
        for k in range(1, n + 1):
            h = ask(d, hdr_cmd(k), 'HD|', timeout=600).strip().split('|')
            if h[1] == 'ok':
                print('   cand %d: HEADER FOUND, %s consistent -- %s' % (k, h[2], h[3]))
                print()
                print('This is the geometry the app needs. px_map can be run against it.')
                return 0
            print('   cand %d: no header (%s consistent) -- %s' % (k, h[2], h[3]))
        if n == 0 and swept.startswith('0MB') and slice_no > 2:
            pass
    print()
    print('No candidate carried a header in any slice tried.')
    return 1


if __name__ == '__main__':
    sys.exit(main())
