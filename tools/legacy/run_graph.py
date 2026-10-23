#!/usr/bin/env python3
"""Run the graph-based spectrum analyser and report honest, wall-clock timing.

Architecture (see tsp/spectrum_graph.tsp for the measured justification):
  digitize -> DC removal + Hann window -> FFT -> magnitude -> top-5 peaks
  -> refill one WRITABLE_FULL buffer -> firmware repaints one OBJ_GRAPH

Stability rules enforced here, because the instrument has been crashed three times
by display-message floods and object accumulation:
  * sg_destroy() runs BEFORE building, so screens/objects never accumulate
  * frame rate is measured by host wall clock, not Lua timers (display writes are
    asynchronous, so Lua timing understates the real cost badly)
  * the instrument is pinged between phases and the run aborts if it stops
    answering, rather than pressing on and risking a panic
"""
import argparse
import sys
import time

sys.path.insert(0, __file__.rsplit('/', 1)[0])
from dmmrun import DMM, clear_dead_sockets   # noqa: E402
from screenshot import capture               # noqa: E402
from siglent import SDG                      # noqa: E402

ROOT = __file__.rsplit('/', 2)[0]

MAIN = r'''
SA_N, SA_NBINS, SA_FS, SA_BINHZ = 512, 256, 100000, 0
sa_buf, sa_fs = nil, 0

function sa_measure_fs(buf)
  local n = buf.n
  if n < 4 then return 0 end
  local t1, tN = buf.relativetimestamps[1], buf.relativetimestamps[n]
  if tN <= t1 then return 0 end
  return (n - 1) / (tN - t1)
end

function sa_init(fs, N, range)
  SA_N, SA_NBINS, SA_FS = N, N/2, fs
  fft_init(N)
  dmm.digitize.func       = dmm.FUNC_DIGITIZE_VOLTAGE
  dmm.digitize.range      = range          -- FIXED: autorange invalidates a capture
  dmm.digitize.samplerate = fs
  dmm.digitize.aperture   = 1e-6           -- minimum: avoids the AUTO sinc roll-off
  dmm.digitize.count      = N
  if sa_buf == nil then sa_buf = buffer.make(N*4, buffer.STYLE_STANDARD) end
  sa_buf.clear()
  dmm.digitize.read(sa_buf)
  sa_fs   = sa_measure_fs(sa_buf)           -- never trust the readback
  SA_BINHZ = sa_fs / N
  sg_set_labels(sa_fs)
  -- Acquisition retargets the graph, so rebind our spectrum buffer AFTER the
  -- first digitize rather than before it. Do NOT call sg_update() here: the FFT
  -- has not produced magnitudes yet, so fft_mag[k] is nil and the comparison
  -- raises "attempt to compare nil with number". The buffer already holds the
  -- primed flat line from sg_build, which is all the binding needs.
  sg_rebind()
  print(string.format("SA_INIT N=%d bins=%d fs_req=%d fs_true=%.1f bin=%.3f Hz",
        N, SA_NBINS, fs, sa_fs, SA_BINHZ))
end

-- One frame. Returns nothing; prints only when asked.
function sa_frame(report)
  sa_buf.clear()
  dmm.digitize.read(sa_buf)
  local mean, pp = fft_load(sa_buf)
  fft_run()
  fft_magnitude()
  local bi, bv = ui_find_peaks(SA_NBINS, 5)
  sg_update(SA_NBINS, SA_BINHZ)
  sg_bind_min()                      -- digitize.read() detaches the trace; re-bind
  sg_show_peaks(bi, bv, 5, SA_BINHZ)
  if report == 1 then
    print(string.format("FRAME dc=%.4f pp=%.4f peak bin %d = %.1f Hz @ %.5f Vpk",
      mean, pp, bi[1], (bi[1]-1)*SA_BINHZ, bv[1]))
  end
end

function sa_frames(n)
  for i = 1, n do sa_frame(0) end
  print("BATCH_DONE " .. n)
end
'''


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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--tone', type=float, default=12500.0)
    ap.add_argument('--vpp', type=float, default=2.0)
    ap.add_argument('--fs', type=int, default=100000)
    ap.add_argument('--n', type=int, default=512)
    ap.add_argument('--range', type=float, default=10)
    ap.add_argument('--frames', type=int, default=10)
    ap.add_argument('--shot', default='/tmp/spec_graph.png')
    ap.add_argument('--no-gen', action='store_true')
    a = ap.parse_args()

    if not a.no_gen:
        g = SDG()
        g.sine(a.tone, a.vpp, ch=1)
        g.output(True, ch=1, load='HZ')
        g.close()
        print(f'generator : {a.tone} Hz {a.vpp} Vpp')

    clear_dead_sockets()
    d = DMM(timeout=180)
    d.q('reset()')
    d.q('display.lightstate = display.STATE_LCD_100')
    d.q('eventlog.clear()')

    print('modules   :')
    for name, path in (('fftcore', 'tsp/fft_core.tsp'),
                       ('specui', 'tsp/spectrum_ui.tsp'),
                       ('specgr', 'tsp/spectrum_graph.tsp')):
        print(f'  {name:8}: {load_file(d, name, f"{ROOT}/{path}")}')
    print('  log     :', d.q('if eventlog.getcount()>0 then print(eventlog.next()) '
                             'else print("clean") end', timeout=40))
    d.q('eventlog.clear()')
    d.load_script('samain', MAIN, run=False)
    print('  samain  :', d.q('samain() print("ok")', timeout=150))

    # Always destroy before building: object accumulation destabilises the unit.
    print('cleanup   :', d.q('pcall(function() sg_destroy() end) print("done")', timeout=120))
    if not alive(d):
        print('instrument unresponsive after cleanup')
        return 2

    print('build UI  :', d.q(f'sg_build("DMM6500 FFT SPECTRUM", {a.n // 2}) '
                             f'print("scr=" .. tostring(SG_SCR) .. " graph=" .. tostring(SG_GRAPH))',
                             timeout=300))
    print('  log     :', d.q('if eventlog.getcount()>0 then print(eventlog.next()) '
                             'else print("clean") end', timeout=40))
    d.q('eventlog.clear()')
    if not alive(d):
        print('instrument unresponsive after build')
        return 2

    d.drain()
    d.send(f'sa_init({a.fs}, {a.n}, {a.range})')
    print('init      :', d.line(300))

    d.drain()
    d.send('sa_frame(1)')
    print('one frame :', d.line(300))
    print('  log     :', d.q('if eventlog.getcount()>0 then print(eventlog.next()) '
                             'else print("clean") end', timeout=40))
    d.q('eventlog.clear()')

    # Honest frame rate: host wall clock around a batch of frames.
    print(f'\ntiming {a.frames} frames (host wall clock)...')
    t0 = time.time()
    d.drain()
    d.send(f'sa_frames({a.frames})')
    line = d.line(int(a.frames * 4000) + 600)
    el = time.time() - t0
    print(f'  {line}')
    print(f'  wall clock: {el:.2f} s for {a.frames} frames '
          f'= {el/a.frames*1000:.0f} ms/frame = {a.frames/el:.2f} fps')
    d.q(f'sg_status(string.format("%.2f fps", {a.frames/el:.4f}))', timeout=40)

    print('  log     :', d.q('if eventlog.getcount()>0 then print(eventlog.next()) '
                             'else print("clean") end', timeout=40))
    d.q('eventlog.clear()')
    time.sleep(2.0)
    print('screenshot:', capture(a.shot))
    d.close()
    return 0


if __name__ == '__main__':
    sys.exit(main())
