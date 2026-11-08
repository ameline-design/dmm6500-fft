#!/usr/bin/env python3
"""What the trace fill is made of, and how much of it is not the append.

The fill is the biggest controllable cost in the frame: a fixed ~41 ms at every sample count,
which is half the controllable work at 2048 and 5% of it at 32768. buffer.write.reading is
the only way points reach the glass and there is no bulk form, so the question is not whether
the appends can go but how much of the 41 ms is the appends and how much is the Lua loop
around them.

Four variants, each writing the same number of points into the bound buffer with frames
parked, timed on the instrument's own clock:

  A  the shipped fold, clamp branch and table reads and all
  B  the same without the per-point clamp, which costs 2 x nseg comparisons a frame
  C  constant arguments, no table reads at all -- the append floor
  D  one lap, for what halving the pass would be worth

A - C bounds what any micro-optimisation can win. If that is small, the 41 ms is the IPC
round trip and the loop is not worth touching.

    python3 -u -I tools/probe_fillcost.py
"""
import os
import sys
import time

sys.path.insert(0, os.path.join('/Users/ameline/Work/GitHub/dmm6500-serial-decode', 'tools'))
from dmmrun import DMM          # noqa: E402

REPS = 5                        # each variant timed this many times; the median is reported


def ask(d, cmd, tag, tries=8, timeout=120):
    r = None
    for _ in range(tries):
        r = d.q(cmd, timeout=timeout)
        if r is not None and str(r).startswith(tag):
            return str(r)
        time.sleep(2)
    raise SystemExit('DESYNC(%s) last=%r' % (tag, r))


# Each body writes `cap` points into the ring and leaves the cursor where it found it, so the
# buffer is in the same state afterwards whichever variant ran.
BODIES = {
    'A shipped fold': """
      local last = n local i
      for i = 1, room do local j = i if j > last then j = last end
        wr(tb, db[j], hz[j], t + i, 0) end
      for i = 1, room do local j = room + 1 - i if j > last then j = last end
        wr(tb, db[j], hz[j], t + room + i, 0) end""",
    'B no clamp branch': """
      local i
      for i = 1, room do wr(tb, db[i], hz[i], t + i, 0) end
      for i = 1, room do local j = room + 1 - i
        wr(tb, db[j], hz[j], t + room + i, 0) end""",
    'C constant args': """
      local i
      for i = 1, room do wr(tb, -100, 1000, t + i, 0) end
      for i = 1, room do wr(tb, -100, 1000, t + room + i, 0) end""",
    'D one lap only': """
      local i
      for i = 1, room do wr(tb, db[i], hz[i], t + i, 0) end""",
}


def main():
    d = DMM(recover=False, timeout=240)
    try:
        print('park  :', ask(d, "do if fftsa.saved_frame == nil then "
                                "fftsa.saved_frame = fftsa.frame "
                                "fftsa.frame = function() end end print('PK|parked') end",
                            'PK|'))
        print('state :', ask(d, "do local b = fftsa.sg_buf "
                                "print('S|N='..tostring(fftsa.n)..' cap='"
                                "..tostring(b.capacity)..' ncol='..tostring(fftsa.sg_ncol)"
                                "..' ring='..tostring(fftsa.sg_ring)) end", 'S|'))
        # The arrays the real fill reads, built once so the timing does not include them.
        ask(d, "do ZD, ZH = {}, {} local i "
               "for i = 1, fftsa.sg_ncol do ZD[i] = -100 + i * 0.01 "
               "ZH[i] = fftsa.sg_flo_hz + i * 100 end print('AR|'..tostring(table.getn(ZD))) end",
            'AR|')
        print()
        res = {}
        for name in ('A shipped fold', 'B no clamp branch', 'C constant args',
                     'D one lap only'):
            body = BODIES[name]
            times = []
            for _ in range(REPS):
                r = ask(d, "do local tb = fftsa.sg_buf local wr = buffer.write.reading "
                           "local db, hz = ZD, ZH local n = fftsa.sg_ncol "
                           "local room = math.floor(tb.capacity / 2) "
                           "local t = fftsa.sg_stamp "
                           "local t0 = os.clock() %s local t1 = os.clock() "
                           "fftsa.sg_stamp = t + tb.capacity "
                           "print(string.format('T|%%.6f', t1 - t0)) end" % body, 'T|')
                times.append(float(r.split('|')[1]))
            times.sort()
            med = times[len(times) // 2]
            res[name] = med
            pts = 255 if name.startswith('D') else 510
            print('  %-20s %7.2f ms   %6.1f us a point   (%d points)'
                  % (name, med * 1000.0, med * 1e6 / pts, pts))
        print()
        a, b, c, dd = (res['A shipped fold'], res['B no clamp branch'],
                       res['C constant args'], res['D one lap only'])
        print('  clamp branch costs       %6.2f ms  (A - B)' % ((a - b) * 1000.0))
        print('  table reads cost         %6.2f ms  (B - C)' % ((b - c) * 1000.0))
        print('  everything but the call  %6.2f ms  (A - C)' % ((a - c) * 1000.0))
        print('  halving the pass saves   %6.2f ms  (A - D)' % ((a - dd) * 1000.0))
        print()
        print('  the append floor is %.1f us a point, so %.0f%% of the fill is the IPC call'
              % (c * 1e6 / 510, 100.0 * c / a))
    finally:
        ask(d, "do ZD, ZH = nil, nil if fftsa.saved_frame ~= nil then "
               "fftsa.frame = fftsa.saved_frame fftsa.saved_frame = nil end "
               "print('UP|running') end", 'UP|')
        d.close()


if __name__ == '__main__':
    main()
