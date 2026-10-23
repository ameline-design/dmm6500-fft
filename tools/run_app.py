#!/usr/bin/env python3
"""Build the interactive spectrum app ONCE on a fresh instrument and verify it.

Single build cycle (crash rule: one build per power cycle). Loads the four
modules, starts the app (build + apply + arm timer), screenshots the spectrum,
then exercises the touch OPTIONS FORM from the host (seed fields, read them back,
screenshot the form, apply a zoom, return to full span). Leaves the app running.
"""
import sys
import time

sys.path.insert(0, __file__.rsplit('/', 1)[0])
from dmmrun import DMM, clear_dead_sockets   # noqa: E402
from screenshot import capture               # noqa: E402
from siglent import SDG                       # noqa: E402

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


def log(d):
    return d.q('if eventlog.getcount()>0 then print(eventlog.next()) '
               'else print("clean") end', timeout=40)


def cap(d, path, live=False, tries=3):
    """Reliable LXI grab. The frame timer floods the display processor and can
    starve the web server (capture times out), so pause the frame function first
    (parked in fftsa.saved_frame), optionally take ONE fresh frame, grab, then
    restore. The park slot is a field of fftsa, not a bare global: apps and
    firmware share one Lua environment on this box."""
    d.exec('if fftsa.saved_frame==nil then fftsa.saved_frame=fftsa.frame end '
           'fftsa.frame=function() end')
    time.sleep(0.25)
    if live:
        try:
            d.q('fftsa.saved_frame()', timeout=60)
        except Exception:
            pass
        time.sleep(0.3)
    ok = False
    for i in range(tries):
        try:
            capture(path); ok = True; break
        except Exception as e:
            print('    cap retry', i, type(e).__name__); time.sleep(1.3)
    # NOTE: deliberately does NOT thaw -- the whole verification runs frozen to
    # avoid host/timer contention; main() thaws once at the very end.
    return ok


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
    print('  log     :', log(d))
    d.q('eventlog.clear()')

    d.q('pcall(function() fftsa.stop() end) print("cleaned")', timeout=120)
    if not alive(d):
        print('unresponsive after cleanup'); return 2

    # ---- the one build ----
    print('start     :', d.q('fftsa.start()', timeout=300))
    print('  log     :', log(d))
    d.q('eventlog.clear()')
    # Freeze the frame loop for the whole verification: while the timer runs, its
    # per-frame digitize collides with host queries ("a command from another
    # interface is running"). Thawed at the very end so the app runs on its own.
    d.exec('fftsa.saved_frame = fftsa.frame  fftsa.frame = function() end')
    time.sleep(0.4)
    if not alive(d):
        print('unresponsive after start'); return 2

    cap(d, '/tmp/app_spectrum.png', live=True)
    print('  spectrum -> /tmp/app_spectrum.png')

    # ---- learn the edit-option index base (0- vs 1-based) ----
    print('\n=== options form ===')
    for idx in (1, 2, 3):
        got = d.q(f'display.setvalue(fftsa.opt_rng, {idx}) print(display.getvalue(fftsa.opt_rng))', timeout=40)
        print(f'  setvalue({idx}) -> getvalue = {got}')

    # ---- open the form, screenshot it (timer is idle on the options screen) ----
    d.q('fftsa.options() print("opened")', timeout=60)
    time.sleep(0.8)
    cap(d, '/tmp/app_options.png')
    print('  form     -> /tmp/app_options.png')
    print('  fields   :', d.q('print(string.format("flo=%s fhi=%s rng=%s",'
                              ' tostring(display.getvalue(fftsa.opt_flo)),'
                              ' tostring(display.getvalue(fftsa.opt_fhi)),'
                              ' tostring(display.getvalue(fftsa.opt_rng))))', timeout=40))

    # ---- apply a zoom via the form path (seed fields, then fftsa.options_apply) ----
    d.q('display.setvalue(fftsa.opt_flo, 8000) display.setvalue(fftsa.opt_fhi, 16000) '
        'display.setvalue(fftsa.opt_rng, 3) print("seeded")', timeout=40)
    d.q('fftsa.options_apply() print(string.format("applied flo=%g fhi=%g range=%g fs=%d bin=%.2f",'
        ' fftsa.flo, fftsa.fhi, fftsa.range, fftsa.fs, fftsa.binhz))', timeout=120)
    cap(d, '/tmp/app_zoom.png', live=True)
    print('  zoom 8-16k -> /tmp/app_zoom.png')
    # Search the DISPLAYED window, exactly as fftsa.frame_body() does, so this
    # reports the peak that is actually on screen and not an off-screen tone.
    print('  zoom peak:', d.q('local nb=fftsa.n/2 '
        'local k0,k1=fftsa.sg_window_bins(nb,fftsa.binhz) '
        'local bi,bv=fftsa.find_peaks(nb,fftsa.sg_npeak,k0,k1) '
        'print(string.format("%.3f kHz @ %.4f V  (bins %d..%d)", '
        '(bi[1]-1)*fftsa.binhz/1000, bv[1], k0, k1))', timeout=90))

    # ---- back to full span, leave running ----
    d.q('fftsa.flo=0 fftsa.fhi=50000 fftsa.range=10 fftsa.apply() print("full")', timeout=120)
    cap(d, '/tmp/app_full.png', live=True)
    print('  full 0-50k -> /tmp/app_full.png')

    # thaw -> the app now runs autonomously for the user
    d.q('display.changescreen(fftsa.sg_scr) print("spec")')
    d.exec('fftsa.frame = fftsa.saved_frame  fftsa.saved_frame = nil')
    # Frame health: errcount should stay at 0 (the pcall guard records dropped
    # frames) and shortreads counts captures rejected for coming back partial.
    print('\ncounters  :', d.q('print(string.format("errcount=%d shortreads=%d lasterr=%s",'
                               ' fftsa.errcount, fftsa.shortreads,'
                               ' tostring(fftsa.lasterr)))', timeout=40))
    print('log       :', log(d))
    d.close()
    print('\nApp left running. Press "Options" on the panel for the touch form.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
