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
# Loaded and run in this order, one named script each. THE SAME ORDER AS
# tools/package_tspa.py's MODULES, which is what the archive ships and so the only order
# the app is ever tested in: natlink creates fftsa.nl and natcode assigns the compiled
# image into it, so natcode has to follow it, and both have to precede specapp, which
# reaches nl.init from fftsa.start().
#
# dsplua has to precede specapp and it is NOT optional: THE DMM6500 HAS NO FIRMWARE dsp
# MODULE. Measured on 1.7.17a -- `dsp` is nil, so with this file out of the list specapp
# raises at load (-286, "attempt to index global `dsp'") on the window enum map, and the app
# never appears. dsp.* is the interface this app is written against; dsp_lua.tsp is what
# provides it, and the compiled image is a faster implementation of the same work, not a
# replacement for the names.
MODULES = [('fftcore', 'tsp/fft_core.tsp'),
           ('specui', 'tsp/spectrum_ui.tsp'),
           ('specgr', 'tsp/spectrum_graph.tsp'),
           ('natlink', 'tsp/native_link.tsp'),
           ('natcode', 'tsp/native_code.tsp'),
           ('dsplua', 'tsp/dsp_lua.tsp'),
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
            d.exec('fftsa.saved_frame()', timeout=120)
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
    # The generator is a convenience, not a dependency: with it the screenshots show a
    # known tone, without it the app is verified against whatever is on the leads, which
    # is mains pickup and the instrument's own floor. Refusing to run at all when it is
    # switched off meant no app test rather than a slightly weaker one, and the weaker one
    # still exercises every path the app has.
    try:
        g = SDG()
        g.sine(12500, 2.0, ch=1)
        g.output(True, ch=1, load='HZ')
        g.close()
        print('generator : 12500 Hz 2 Vpp')
    except Exception as exc:
        print('generator : unreachable (%s) -- running against the open leads'
              % type(exc).__name__)

    clear_dead_sockets()
    d = DMM(timeout=180)

    # ONE RUN PER BOOT, AND THE TOOL HAS TO SAY SO. fftsa.nl.init installs heap code and
    # claims the NLBOOT global, which nothing but a restart clears, so a second run comes
    # back with the native path refused -- ready=false, nmax=0, rc=nil -- and every figure
    # below describing the interpreted path instead. That reads as a regression in the
    # native path and is not one. The app's own screen set is one build per power cycle for
    # the same reason: a create/delete cycle risks part of the 463-object pool.
    spent = d.q("print('BT|'..tostring(NLBOOT))", timeout=30)
    if spent != 'BT|nil':
        print('boot      : already spent (NLBOOT=%s)' % (spent or '?')[3:])
        print('            A second run in one boot cannot install the native path, and')
        print('            every reading below would describe the fallback. Restart first:')
        print('            python3 -u -I ../dmm6500-serial-decode/notes/firmware/'
              'dmmreboot.py')
        d.close()
        return 2
    print('boot      : clean')

    d.exec('reset()', timeout=60)
    # 25%, the lowest step above off. The LXI screenshot does not read the backlight, so
    # nothing here needs the panel bright.
    d.exec('display.lightstate = display.STATE_LCD_25')
    d.exec('eventlog.clear()')
    # The app's single global, dropped before the modules are reloaded. A previous run that
    # raised part-way through a module leaves fftsa holding whatever it had defined by then,
    # and the fields a half-loaded module left behind are indistinguishable from the ones
    # this load is about to write.
    d.exec('fftsa = nil')

    print('modules   :')
    for name, path in MODULES:
        print(f'  {name:8}: {load_file(d, name, f"{ROOT}/{path}")}')
    print('  log     :', log(d))
    d.exec('eventlog.clear()')

    d.q('pcall(function() fftsa.stop() end) print("cleaned")', timeout=120)
    if not alive(d):
        print('unresponsive after cleanup'); return 2

    # ---- the one build ----
    # 900 s, not 300: start() installs the native image, and that costs FOUR content scans
    # over the heap -- two inside nl.init to find the code and plan buffers, two more in
    # nl_bind for the capture and trace buffers. Each is about a minute. A timeout shorter
    # than the work does not just lose the answer: the late reply arrives while the next
    # query is waiting and every read after it is one behind.
    print('start     :', d.q('fftsa.start()', timeout=900))
    print('  log     :', log(d))
    d.exec('eventlog.clear()')
    # Freeze the frame loop for the whole verification: while the timer runs, its
    # per-frame digitize collides with host queries ("a command from another
    # interface is running"). Thawed at the very end so the app runs on its own.
    d.exec('fftsa.saved_frame = fftsa.frame  fftsa.frame = function() end')
    time.sleep(0.4)
    if not alive(d):
        print('unresponsive after start'); return 2

    cap(d, '/tmp/app_spectrum.png', live=True)
    print('  spectrum -> /tmp/app_spectrum.png')

    # ---- which primitive produced that spectrum ----
    # Asked rather than assumed: a native path that failed to install falls back silently,
    # which is the point of the fallback and also the thing that would make every
    # measurement below describe the wrong implementation.
    print('\n=== native path ===')
    # The build, and the words at the four addresses that belong to it. Nothing verifies
    # those addresses before use, so a refusal here names the build it refused.
    print('  firmware :', d.q(
        'if fftsa.nl == nil then print("no nl table") else '
        'print(fftsa.nl.fw_probe(2)) end', timeout=60))
    print('  state    :', d.q(
        'local nl = fftsa.nl '
        'if nl == nil then print("no nl table") else '
        'print(string.format("ready=%s n=%s nmax=%s nseg_max=%s bound=%s rc=%s err=%s", '
        'tostring(nl.ready), tostring(nl.n), tostring(nl.nmax), tostring(nl.nseg_max), '
        'tostring(fftsa.nl_cap ~= nil), tostring(nl.last_rc), '
        'tostring(fftsa.nl_lasterr))) end', timeout=60))
    # nl_res is set by the frame body only on the native path, and cleared at the head of
    # every frame, so this says which path ran the frame just captured.
    print('  live     :', d.q(
        'local r = fftsa.nl_res '
        'if r == nil then print("fell back to dsp.spectrum") else '
        'print(string.format("native: npk=%d nbins=%s thd=%s snr=%s floor=%s", '
        'r.npk, tostring(r.nbins), tostring(r.thd), tostring(r.snr), '
        'tostring(r.noise))) end', timeout=60))
    # The capture's storage as the bind resolved it. Its element size is the interesting
    # figure: STYLE_STANDARD stores no extra value, so it is not 32, and the primitive
    # strides by whatever this says. The trace buffer is not scanned for -- its points go
    # through buffer.write.reading -- so there is nothing to report for it.
    print('  capture  :', d.q(
        'local c = fftsa.nl_cap '
        'if c == nil then print("unbound") else '
        'print(string.format("elem %d perchunk %d chunks %s at %X", '
        'c.elemsize, c.perchunk, tostring(c.nchunks), c.chunk1)) end', timeout=60))
    print('  phases   :', d.q('print(fftsa.phases())', timeout=60))
    print('  trace    :', d.q(
        'print(string.format("nwrote=%s n=%s first=(%.2f dB, %.1f Hz) last=(%.2f dB, %.1f Hz)", '
        'tostring(fftsa.sg_nwrote), tostring(fftsa.sg_buf.n), '
        'fftsa.sg_buf.readings[1], fftsa.sg_buf.extravalues[1], '
        'fftsa.sg_buf.readings[fftsa.sg_buf.n], '
        'fftsa.sg_buf.extravalues[fftsa.sg_buf.n]))', timeout=60))
    print('  peaks    :', d.q(
        'if fftsa.pk_hz == nil then print("no frame has run") else '
        'local t = {} local i '
        'for i = 1, fftsa.sg_npeak do '
        'if fftsa.pk_hz[i] == nil then t[i] = "-" else '
        't[i] = string.format("%.0fHz/%.4gV", fftsa.pk_hz[i], fftsa.pk_v[i]) end end '
        'print(table.concat(t, "  ")) end', timeout=60))
    # The line as the glass shows it, through the same two shims the display uses, so a
    # native path reporting nothing would read "---" here rather than silently.
    print('  thd line :', d.q(
        'do local thd, snr, nf = fftsa.distortion() '
        'if thd ~= nil then thd = thd * 100 end '
        'print(fftsa.sg_thd_text(thd, snr, nf, fftsa.plan_n(), fftsa.overrange)) end',
        timeout=60))
    # One frame, timed on the instrument's own clock, with the timer frozen so nothing
    # else is competing for the interpreter.
    print('  frame    :', d.q(
        'local t0 = os.clock() local i for i = 1, 5 do fftsa.saved_frame() end '
        'print(string.format("%.1f ms a frame over five, n=%d", '
        '(os.clock() - t0) * 200, fftsa.n))', timeout=300))

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
    # The peak the app is showing, from the tables the peak block reads, so the figure is
    # the one on the glass whichever path produced it. fftsa.find_peaks walks the
    # interpreted power array, which the compiled path never fills.
    print('  zoom peak:', d.q('local hz,v=fftsa.pk_hz,fftsa.pk_v '
        'local k0,k1=fftsa.sg_window_bins(fftsa.n/2,fftsa.binhz) '
        'print(string.format("%.3f kHz @ %.4f V  (bins %d..%d, %s)", '
        '(hz[1] or 0)/1000, v[1] or 0, k0, k1, '
        'fftsa.nl_frame and "compiled" or "interpreted"))', timeout=90))

    # ---- a sample count press, which is what nl.reinit exists for ----
    # The arena is sized once per boot for fftsa.nl_nmax; a count at or below it re-plans
    # with one params write and one call, where an install would need a fresh boot. 16384
    # is above the ceiling and has to fall back cleanly rather than fail.
    print('\n=== sample count ===')
    for n in (1024, 16384, 512):
        print('  n=%-5d :' % n, d.q(
            'fftsa.n = %d fftsa.apply() '
            'print(string.format("nl.ready=%%s nl.n=%%s bound=%%s binhz=%%.3f", '
            'tostring(fftsa.nl.ready), tostring(fftsa.nl.n), '
            'tostring(fftsa.nl_usable()), fftsa.binhz))' % n, timeout=300))
        print('          ', d.q('fftsa.saved_frame() '
                                'if fftsa.nl_res == nil then print("  frame: dsp.spectrum") '
                                'else print(string.format("  frame: native, npk=%d", '
                                'fftsa.nl_res.npk)) end', timeout=300))

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
