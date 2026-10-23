#!/usr/bin/env python3
"""Build the interactive spectrum app and verify its options engine from the host.

The touch dialogs (app_options) need a physical finger, so this does NOT call
them (that would block on the panel). Instead it exercises the thing underneath
them — app_apply() with different (start, stop, range) settings — and screenshots
each, which proves the whole reconfiguration path end to end. It then arms the
autonomous timer so the app keeps running for the user to press Options.

One build cycle. No destroy/rebuild loop.
"""
import sys
import time

sys.path.insert(0, __file__.rsplit('/', 1)[0])
from dmmrun import DMM, clear_dead_sockets   # noqa: E402
from screenshot import capture               # noqa: E402
from siglent import SDG                      # noqa: E402

ROOT = __file__.rsplit('/', 2)[0]
MODULES = [('fftcore', 'tsp/fft_core.tsp'),
           ('specui', 'tsp/spectrum_ui.tsp'),
           ('specgr', 'tsp/spectrum_graph.tsp'),
           ('specapp', 'tsp/spectrum_app.tsp')]


def load_file(d, name, path):
    src = open(path).read()
    d.q(f'if {name} ~= nil then pcall(function() script.delete({name}) end) {name} = nil end',
        timeout=30)
    d.drain()
    d.send('loadscript ' + name)
    for ln in src.splitlines():
        d.send(ln)
    d.send('endscript')
    time.sleep(0.4)
    return d.q(f'{name}() print("{name}-ok")', timeout=150)


def alive(d):
    try:
        return d.q('print("P")', timeout=30) == 'P'
    except Exception:
        return False


def config(d, flo, fhi, rng, frames, shot, label):
    """Set options directly (bypassing the touch dialog), apply, run frames, shoot."""
    d.exec(f'APP_FLO={flo} APP_FHI={fhi} APP_RANGE={rng}', timeout=30)
    d.q('app_apply() print(string.format("applied fs=%d bin=%.2f range=%g", '
        'APP_FS, APP_BINHZ, APP_RANGE))', timeout=120)
    for _ in range(frames):
        d.exec('app_frame()', timeout=60)
    line = d.q('app_frame() '  # one reporting frame
               'local nb=APP_N/2 local bi,bv=ui_find_peaks(nb,5) '
               'print(string.format("peak %.1f Hz @ %.4f Vpk", (bi[1]-1)*APP_BINHZ, bv[1]))',
               timeout=90)
    time.sleep(1.2)
    capture(shot)
    print(f'  {label:28} -> {line}   {shot}')
    return alive(d)


def main():
    g = SDG()
    g.sine(12500, 2.0, ch=1)
    g.output(True, ch=1, load='HZ')
    g.close()
    print('generator : 12500 Hz 2 Vpp')

    clear_dead_sockets()
    d = DMM(timeout=180)
    d.q('reset()')
    d.q('display.lightstate = display.STATE_LCD_100')
    d.q('eventlog.clear()')

    print('modules   :')
    for name, path in MODULES:
        print(f'  {name:8}: {load_file(d, name, f"{ROOT}/{path}")}')
    print('  log     :', d.q('if eventlog.getcount()>0 then print(eventlog.next()) '
                             'else print("clean") end', timeout=40))
    d.q('eventlog.clear()')

    # Clean any prior app/screen, then build ONCE.
    d.q('pcall(function() app_stop() end) print("cleaned")', timeout=120)
    if not alive(d):
        print('unresponsive after cleanup'); return 2
    print('build     :', d.q('app_build() print("scr="..tostring(SG_SCR)..'
                             '" btn="..tostring(app_optbtn))', timeout=300))
    print('  log     :', d.q('if eventlog.getcount()>0 then print(eventlog.next()) '
                             'else print("clean") end', timeout=40))
    d.q('eventlog.clear()')
    if not alive(d):
        print('unresponsive after build'); return 2

    print('\n=== options engine: apply 3 configurations from the host ===')
    ok = True
    ok &= config(d, 0, 50000, 10, 4, '/tmp/opt_full.png',  'full span 0-50k, 10V')
    if ok:
        ok &= config(d, 0, 25000, 1, 4, '/tmp/opt_half.png',  'span 0-25k (finer bins), 1V')
    if ok:
        ok &= config(d, 8000, 16000, 10, 4, '/tmp/opt_zoom.png', 'zoom 8-16k, 10V')

    if ok:
        print('\n=== arm autonomous timer (app now runs on its own) ===')
        # back to a sensible default view, then arm the timer
        d.exec('APP_FLO=0 APP_FHI=50000 APP_RANGE=10', timeout=30)
        d.q('app_apply() print("reapplied")', timeout=120)
        print('  arm     :', d.q('app_arm(0.2) print("armed period=0.2s")', timeout=60))
        time.sleep(2.0)
        capture('/tmp/opt_live.png')
        print('  live shot -> /tmp/opt_live.png')

    print('\nlog:', d.q('if eventlog.getcount()>0 then print(eventlog.next()) '
                        'else print("clean") end', timeout=40))
    d.close()
    print('\nApp left running on the instrument. Press "Options" on the panel to '
          'set Start/Stop frequency and Input Range.')
    return 0 if ok else 2


if __name__ == '__main__':
    sys.exit(main())
