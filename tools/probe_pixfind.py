#!/usr/bin/env python3
"""Find the ring from the app's OWN appends, with the trace buffer giving the centres.

Two changes from probe_ringfind, and each is the difference between a 42 s search and a
fraction of a second:

  THE NEEDLE IS THE APP'S OWN SPECTRUM. probe_ringfind appends four sentinels and waits 1.5 s
  for the display task to drain them. A frame cannot do either. But the fill has just written
  the whole pass through the same call, so records already in the ring hold db[1], db[2], db[3]
  in CONSECUTIVE slots -- the ascending lap writes them in order -- and four of them confirm a
  stride exactly as four sentinels do. Measured on the day: db[1] occurs twice in a 510-record
  pass, once per lap of the fold, so it is as selective a needle as a sentinel is.

  THE CENTRES COME FROM THE TRACE BUFFER. nl.find_ring calls scan_windows(nil, nil), which has
  no buffer to ask, so stage 1 offers one centre -- the cached arena -- and stages 2 and 3
  widen around it. The ring is the display task's allocation for ITS SUBSCRIPTION TO THIS
  BUFFER, so the buffer's own C++ instance and column pointers are the better centres, and
  scan_windows already builds the ladder around them when it is handed the buffer.

Everything runs inside ONE statement per phase, which is what makes it safe to measure with
frames live: the interpreter is single-threaded, so a frame cannot run while the statement
does, and the dB values the needle was built from cannot be overwritten half way through.

Read only. No cursor, no count, no record is written.

    python3 -u -I tools/probe_pixfind.py
    python3 -u -I tools/probe_pixfind.py --full      # sweep the whole ladder, do not stop early
"""

import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import dmmrun  # noqa: E402

FULL = 'true' if '--full' in sys.argv else 'false'


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


def require_app(d):
    for _ in range(30):
        r = d.q(one("print('A|' .. tostring(fftsa ~= nil and fftsa.nl ~= nil",
                    "and type(fftsa.nl.find_ring) == 'function') .. '|'",
                    ".. tostring(fftsa ~= nil and fftsa.VERSION))"), timeout=30)
        if r is not None and str(r).startswith('A|true'):
            return str(r).split('|')[2]
        time.sleep(1.0)
    raise SystemExit('the app is not answering with a usable nl')


# The ladder scan_windows builds when it is given the trace buffer, as addresses and sizes, so
# that a window index in the result below can be read as a place rather than a number.
WINDOWS = one(
    "do local w = fftsa.nl.scan_windows(fftsa.sg_buf, nil)",
    "local o, i = '', nil",
    "for i = 1, table.getn(w) do",
    "o = o .. string.format('%d:%X-%X:%dK ', i, w[i][1], w[i][2],",
    "math.floor((w[i][2] - w[i][1]) / 1024)) end",
    "print('WN|' .. tostring(table.getn(w)) .. '|' .. o) end")

# The find, from the buffer's own first four readings. extravalues carries the Hz the same
# append wrote, so the x confirmation inside _ring_confirm has the frequency it needs without
# the probe knowing anything about the axis.
FIND = one(
    "do local nl, b = fftsa.nl, fftsa.sg_buf",
    "local s, i = {}, nil",
    "for i = 1, 4 do s[i] = { db = b.readings[i], hz = b.extravalues[i] } end",
    "nl.sweep_reset()",
    "local t0 = os.clock()",
    "local g = nl.find_ring(s, %s)" % FULL,
    "local t1 = os.clock()",
    "if g == nil then print('FD|nil|' .. string.format('%.3f', t1 - t0)",
    ".. '|' .. tostring(nl.ring_why) .. '|' .. tostring(nl.ring_win)",
    ".. '/' .. tostring(nl.ring_nwin) .. '|' .. nl.sweep_str()) return end",
    "print('FD|ok|' .. string.format('%.3f', t1 - t0)",
    ".. '|' .. string.format('%X,%d,%d,%d,%X,%X,%X', g.val0, g.stride, g.ov, g.ox,",
    "g.lo, g.hi, g.hdr) .. '|' .. tostring(nl.ring_win) .. '/' .. tostring(nl.ring_nwin)",
    ".. '|' .. nl.sweep_str() .. '|' .. tostring(g.nrec)) end")


def main():
    d = dmmrun.DMM(timeout=300, recover=False)
    ver = require_app(d)
    print('app    : v%s, frames left running' % ver)

    w = ask(d, WINDOWS, 'WN|', timeout=120).strip().split('|')
    print('ladder : %s windows' % w[1])
    for part in w[2].split():
        print('         %s' % part)

    r = ask(d, FIND, 'FD|', timeout=900).strip().split('|')
    if r[1] == 'nil':
        print('find   : FAILED in %ss, window %s' % (r[2], r[4]))
        print('   why : %s' % r[3])
        print('  swept: %s' % r[5])
        return 1
    print('find   : %ss, window %s, %s' % (r[2], r[4], r[6] + ' records'))
    print('  swept: %s' % r[5])
    print('  ring : val0,stride,ov,ox,lo,hi,hdr = %s' % r[3])
    f = r[3].split(',')
    print()
    print('  --ring %s' % r[3])
    print('  ring spans %08X..%08X, header at %08X'
          % (int(f[4], 16), int(f[5], 16), int(f[6], 16)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
