#!/usr/bin/env python3
"""Why does the pixel map go stale?

The pixel path fits a map from decibels to y pixels out of the firmware's own records, then
checks it every frame against one pixel the firmware wrote for a decibel the app chose. On a
DMM6500 that check fires repeatedly -- 14 re-engagements over 105 frames, the map reading
5 to 13 pixels out -- so either the firmware's scale is moving under the fit or the point the
check compares against is not the point it thinks it is.

The trace object answers it. GRAPH.md 3.1 puts the y range at +0x198..+0x1C0, the y
pixels-per-unit at +0x1B8 and the log-y flag at +0x1C8, all inside the object the pointer
route already reaches. So this samples that block AND the fitted map AND the measured drift
together: if the block moves when the drift grows, the fix is to READ the scale every frame
instead of fitting it once, and the map can never go stale again.

Nothing is assumed about which word is which. The block is dumped raw and decoded both ways,
as float and as integer, and the correlation is what names the field.

THE APP MUST BE LAUNCHED FROM THE KEY, or its frame timer never fires with a socket open.

    python3 -u -I tools/probe_pixdrift.py
    python3 -u -I tools/probe_pixdrift.py --secs 40 --poll 0.4
"""
import os
import struct
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import dmmrun  # noqa: E402


def opt(flag, default, cast=float):
    if flag in sys.argv:
        return cast(sys.argv[sys.argv.index(flag) + 1])
    return default


SECS = opt('--secs', 30.0)
POLL = opt('--poll', 0.5)
# The window to dump, relative to the trace object. 0x140..0x1D0 covers the x range block,
# the y range block and the log flag, which is every scale field GRAPH.md names.
LO, HI = 0x140, 0x1D0


def ask(d, cmd, tag, secs=240):
    """Deadline-paced. A refusal is the normal answer against a live app."""
    assert '\n' not in cmd, 'statements must be one line'
    assert len(cmd) < 1000, 'one-line probes die past 1024 bytes: %d' % len(cmd)
    d.drain()
    d.send(cmd)
    end = time.time() + secs
    last, resends = None, 0
    while time.time() < end:
        t0 = time.time()
        r = d.line(min(15.0, max(0.5, end - time.time())))
        if r is None:
            if time.time() - t0 < 0.05:
                time.sleep(0.2)
            continue
        last = str(r)
        if last.startswith(tag):
            return last
        if 'another interface' in last:
            resends += 1
            time.sleep(0.2)
            d.drain()
            d.send(cmd)
    raise SystemExit('DESYNC(%s) last=%r after %d refusals' % (tag, last, resends))


def one(*parts):
    return ' '.join(p.strip() for p in parts)


def f32(w):
    return struct.unpack('>f', struct.pack('>I', w))[0]


def disarm(d):
    try:
        print('disarm  : %s' % ask(d, one("do fftsa.sg_pix = false",
                                          "if fftsa ~= nil and fftsa.nl ~= nil",
                                          "and fftsa.nl.px_off ~= nil then",
                                          "fftsa.nl.px_off('drift probe exited') end",
                                          "print('OF|' .. tostring(fftsa.sg_pix)) end"),
                                   'OF|', secs=240))
    except Exception as exc:                                         # noqa: BLE001
        print('disarm  : FAILED (%s) -- run: fftsa.sg_pix = false' % type(exc).__name__)


def main():
    d = dmmrun.DMM(timeout=180, recover=False)
    try:
        v = ask(d, one("print('A|' .. tostring(fftsa ~= nil and fftsa.VERSION)",
                       ".. '|' .. tostring(fftsa ~= nil and fftsa.halted)",
                       ".. '|' .. tostring(fftsa ~= nil and fftsa.timer ~= nil))"),
                'A|', secs=120).split('|')
        print('app     : v%s halted=%s timer=%s' % (v[1], v[2], v[3]))
        if v[2] == 'true':
            raise SystemExit('the app is HALTED')
        if v[3] != 'true':
            raise SystemExit('no frame timer: launch the app FROM THE KEY, not over the socket')
        return run(d)
    finally:
        disarm(d)
        d.close()


def run(d):
    ask(d, one("do fftsa.sg_pix = true",
               "if fftsa.nl.px_restart ~= nil then fftsa.nl.px_restart('drift probe') end",
               "print('ON|' .. tostring(fftsa.sg_pix)) end"), 'ON|', secs=240)
    print('armed   : waiting for px=on')
    t0 = time.time()
    while time.time() - t0 < 180:
        d.close()
        time.sleep(1.0)
        d._open()
        st = ask(d, "print('ST|' .. tostring(fftsa.nl.px.state))", 'ST|', secs=120)[3:]
        if st == 'on':
            break
        if st == 'off':
            raise SystemExit('the path switched itself off: %s'
                             % ask(d, "print('W|' .. tostring(fftsa.nl.px.why))", 'W|')[2:])
    else:
        raise SystemExit('did not engage in 180 s')
    print('engaged : %.1fs' % (time.time() - t0))
    print()

    # The map, the drift, and the firmware's own scale block, in ONE statement so they
    # describe the same instant. A map read a frame apart from the drift it is blamed for
    # is two measurements of two different things.
    # ALWAYS PRINTS, whatever state the path is in. The path re-engages constantly, so p.lo
    # goes nil between one statement and the next -- and an arithmetic error on nil prints a
    # Lua error the reader does not match, which reads from here as a dead instrument. Every
    # field is defaulted and the memread is skipped rather than attempted when there is no
    # ring, so a dropped frame is DATA here and not a desync.
    stmt = one("do local p = fftsa.nl.px local b = ''",
               "if p.lo ~= nil then",
               "b = ki.memread(string.format('%%X', p.lo - 544 + %d)," % LO,
               "string.format('%%X', %d)) or '' end" % (HI - LO),
               "print('D|' .. string.format('%.6f', p.ay or 0)",
               ".. '|' .. string.format('%.4f', p.by or 0)",
               ".. '|' .. string.format('%.2f', p.lastdrift or -1)",
               ".. '|' .. tostring(p.frames or 0) .. '|' .. tostring(p.restarts or 0)",
               ".. '|' .. tostring(p.state) .. '|' .. string.format('%.3f', p.slotdb or 0)",
               ".. '|' .. b) end")
    rows = []
    t0 = time.time()
    while time.time() - t0 < SECS:
        r = ask(d, stmt, 'D|', secs=180)
        f = r[2:].split('|')
        blob = f[7] if len(f) > 7 else ''
        words = []
        for i in range(0, min(len(blob), (HI - LO) * 2), 8):
            try:
                words.append(int(blob[i:i + 8], 16))
            except ValueError:
                words.append(0)
        rows.append((time.time() - t0, float(f[0]), float(f[1]), float(f[2]),
                     f[3], f[4], f[5], float(f[6]), words))
        time.sleep(POLL)

    print('%-7s %-10s %-9s %-7s %-6s %-4s' % ('t', 'ay', 'by', 'drift', 'frames', 'restarts'))
    for t, ay, by, dr, fr, re, slot, sdb, w in rows:
        print('%6.1f  %-10.6f %-9.4f %-7.2f %-6s %-4s state=%-5s db=%.2f  %s' %
              (t, ay, by, dr, fr, re, slot, sdb,
               'no ring' if not w else ''))

    # WHICH WORDS MOVED. That is the whole question: a scale field that changes while the
    # fitted map does not is the staleness, and its offset names the field to read instead.
    print()
    print('words in trace+0x%X..0x%X that CHANGED across the run:' % (LO, HI))
    rows = [r for r in rows if r[8]]
    n = min(len(r[8]) for r in rows) if rows else 0
    moved = 0
    for i in range(n):
        vals = [r[8][i] for r in rows]
        if len(set(vals)) > 1:
            moved += 1
            off = LO + i * 4
            print('  +0x%03X  %d distinct   first=%08X (%.6g)  last=%08X (%.6g)'
                  % (off, len(set(vals)), vals[0], f32(vals[0]), vals[-1], f32(vals[-1])))
    if moved == 0:
        print('  NONE. The firmware scale block is constant, so the map is not going stale')
        print('  because the scale moved -- look at the slot/phase the check compares against.')
    print()
    print('did the fitted map move?  ay %s   by %s'
          % ('MOVED' if len(set(round(r[1], 6) for r in rows)) > 1 else 'constant',
             'MOVED' if len(set(round(r[2], 4) for r in rows)) > 1 else 'constant'))
    drifts = [r[3] for r in rows if r[3] >= 0]
    if drifts:
        print('drift     min %.2f  max %.2f  mean %.2f px'
              % (min(drifts), max(drifts), sum(drifts) / len(drifts)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
