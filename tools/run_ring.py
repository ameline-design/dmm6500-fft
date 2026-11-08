#!/usr/bin/env python3
"""Load the working tree with fftsa.sg_ring on, and judge the axis before the trace.

The ring removes the fill window rather than shrinking it: capacity equals the points a pass
writes, so the cursor returns to slot 1 every pass and the buffer is never partially
populated. A paint landing mid-pass then draws this frame mixed with the last -- a tear
rather than a dropout.

This has to be a fresh build, not a live reallocation. Replacing the trace buffers on a live
graph freezes the trace at the frame it fired (tsp/spectrum_graph.tsp, above sg_free_old),
which is exactly what a probe doing it by hand produced. So sg_ring goes on before
fftsa.start(), and the allocation happens ahead of the first bind.

THE AXIS IS THE GATE and is judged first: an axis that moves is worse than the flicker being
fixed. It is sampled once per real frame from inside the app, because a host query lands in
the frame timer's digitize and answers "a command from another interface is running".

    python3 -u -I tools/run_ring.py --ring
    python3 -u -I tools/run_ring.py            # same build, ring off, for the baseline
"""
import argparse
import os
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SIB = '/Users/ameline/Work/GitHub/dmm6500-serial-decode'
sys.path.insert(0, os.path.join(SIB, 'tools'))
sys.path.insert(0, os.path.join(ROOT, 'tools'))
from dmmrun import DMM                                                   # noqa: E402
import screenshot                                                        # noqa: E402

# The archive's order, which is the only order the app is ever tested in.
MODULES = [('fftcore', 'tsp/fft_core.tsp'),
           ('specui', 'tsp/spectrum_ui.tsp'),
           ('specgr', 'tsp/spectrum_graph.tsp'),
           ('natlink', 'tsp/native_link.tsp'),
           ('natcode', 'tsp/native_code.tsp'),
           ('dsplua', 'tsp/dsp_lua.tsp'),
           ('specapp', 'tsp/spectrum_app.tsp')]

# Judged rectangles. The x label row and the dB column only -- NOT the THD line below them,
# which carries live figures and changes every frame whatever the axis does.
AXISX = '100, 342, 780, 360'
AXISY = '8, 55, 95, 340'


def ask(d, cmd, tag, tries=6, timeout=90):
    r = None
    for _ in range(tries):
        r = d.q(cmd, timeout=timeout)
        if r is not None and str(r).startswith(tag):
            return str(r)
        time.sleep(1)
    raise SystemExit('DESYNC(%s) last=%r' % (tag, r))


def ready(d, tries=20):
    for _ in range(tries):
        if d.q("print('P')", timeout=30) == 'P':
            return True
        time.sleep(2)
    raise SystemExit('instrument not answering')


def load_file(d, name, path):
    """One named script a module, sent line by line, then run. A torn load falls back
    silently, so each one is required to report its own name back."""
    with open(path) as fh:
        src = fh.read()
    d.q('if %s ~= nil then pcall(function() script.delete(%s) end) %s = nil end'
        % (name, name, name), timeout=30)
    d.drain()
    d.send('loadscript ' + name)
    for ln in src.splitlines():
        d.send(ln)
    d.send('endscript')
    time.sleep(0.4)
    r = d.q('%s() print("%s-ok")' % (name, name), timeout=240)
    if r != '%s-ok' % name:
        raise SystemExit('module %s did not load: %r' % (name, r))
    return r


def park(d):
    """run_app.py's slot, a field rather than a bare global: apps and firmware share one
    Lua environment here."""
    d.exec('if fftsa.saved_frame == nil then fftsa.saved_frame = fftsa.frame end '
           'fftsa.frame = function() end')
    time.sleep(0.3)


def unpark(d):
    d.exec('if fftsa.saved_frame ~= nil then fftsa.frame = fftsa.saved_frame '
           'fftsa.saved_frame = nil end')
    time.sleep(0.3)


def grab(tag):
    path = '/tmp/ring2_%s.png' % tag
    screenshot.capture(path)
    print('  grab        %s' % path)
    return path


def census(d, seconds):
    """Sample both axis rectangles once per real frame, from inside the app, and report how
    many distinct values each saw. One value means the axis never moved."""
    d.exec('fftsa.ax_seen = {} fftsa.ax_n = 0 '
           'if fftsa.saved_frame == nil then fftsa.saved_frame = fftsa.frame end '
           'fftsa.frame = function() fftsa.saved_frame() '
           'local a = tostring(ki.display.getchecksum(%s)) '
           'local b = tostring(ki.display.getchecksum(%s)) '
           'local k = a .. "/" .. b '
           'if fftsa.ax_seen[k] == nil then fftsa.ax_seen[k] = 0 end '
           'fftsa.ax_seen[k] = fftsa.ax_seen[k] + 1 '
           'fftsa.ax_n = fftsa.ax_n + 1 end' % (AXISX, AXISY))
    time.sleep(seconds)
    r = ask(d, "do local n, s = 0, '' local k, v "
               "for k, v in pairs(fftsa.ax_seen) do n = n + 1 "
               "s = s .. k .. '=' .. tostring(v) .. ' ' end "
               "print('AX|' .. tostring(fftsa.ax_n) .. '|' .. tostring(n) .. '|' .. s) end",
            'AX|')
    unpark(d)
    parts = r.split('|')
    frames, distinct = int(parts[1]), int(parts[2])
    print('  frames %d, distinct axis states %d' % (frames, distinct))
    print('  %s' % parts[3].strip()[:200])
    return frames, distinct


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--ring', action='store_true', help='enable fftsa.sg_ring before start')
    ap.add_argument('--seconds', type=float, default=12.0)
    a = ap.parse_args()
    d = DMM(recover=False, timeout=240)
    try:
        ready(d)
        print('clean  : %s' % d.q('pcall(function() fftsa.stop() end) '
                                  'fftsa = nil print("cleaned")', timeout=180))
        print('modules:')
        for name, path in MODULES:
            print('  %-8s %s' % (name, load_file(d, name, os.path.join(ROOT, path))))
        d.exec('eventlog.clear()')

        if a.ring:
            print('ring   :', ask(d, "fftsa.sg_ring = true "
                                     "print('RG|'..tostring(fftsa.sg_ring)..'|cap='"
                                     "..tostring(fftsa.sg_ring_cap()))", 'RG|'))
        # 900 s: start() installs the native image, and that costs heap content scans.
        print('start  : %s' % d.q('fftsa.start() print("started")', timeout=900))
        print('  log  : %s' % d.q('if eventlog.getcount() > 0 then print(eventlog.next()) '
                                  'else print("clean") end', timeout=60))
        print('state  :', ask(d, "do local b = fftsa.sg_buf "
                                 "print('B|cap='..tostring(b.capacity)..' n='"
                                 "..tostring(b.n)..' fill='..tostring(b.fillmode)"
                                 "..' si='..tostring(b.startindex)..' ei='"
                                 "..tostring(b.endindex)..' ncol='..tostring(fftsa.sg_ncol)"
                                 "..' ring='..tostring(fftsa.sg_ring)) end", 'B|'))

        print('\n=== the axis gate, %.0f s of real frames ===' % a.seconds)
        frames, distinct = census(d, a.seconds)
        if distinct <= 1:
            print('  AXIS STEADY')
        else:
            print('  AXIS MOVED -- the ring is refused on your standing rule')

        print('\n=== the picture ===')
        park(d)
        grab('ring' if a.ring else 'base')
        unpark(d)
        print('\nLeft running. Look at the trace: a bright line along the bottom rule would')
        print('be the wrap seam clamping to the axis floor instead of clipping.')
    finally:
        d.close()


if __name__ == '__main__':
    main()
