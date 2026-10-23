#!/usr/bin/env python3
"""Benchmark and validate the optimised FFT core against the naive version.

Checks two things:
  1. correctness - a known tone must land in the right bin at the right amplitude
  2. speed       - per-stage timings at the sizes the app might use

Loads tsp/fft_core.tsp onto the instrument. Note that `loadscript`/`endscript`
only STORES a script; the chunk must be RUN once for its functions to be
defined. That is why the helper runs the script after loading it.
"""
import sys
import time

sys.path.insert(0, __file__.rsplit('/', 1)[0])
from dmmrun import DMM, clear_dead_sockets   # noqa: E402
from siglent import SDG                      # noqa: E402

CORE = __file__.rsplit('/', 2)[0] + '/tsp/fft_core.tsp'

BENCH = r'''
function bench_one(N, fs, buf)
  timer.cleartime()
  fft_init(N)
  local t_init = timer.gettime()

  dmm.digitize.func       = dmm.FUNC_DIGITIZE_VOLTAGE
  dmm.digitize.range      = 10
  dmm.digitize.samplerate = fs
  dmm.digitize.aperture   = 1e-6
  dmm.digitize.count      = N
  buf.clear()

  timer.cleartime()
  dmm.digitize.read(buf)
  local t_acq = timer.gettime()

  -- true sample rate from timestamps: the readback lies for some rates
  local n  = buf.n
  local t1 = buf.relativetimestamps[1]
  local tN = buf.relativetimestamps[n]
  local fs_actual = (n-1)/(tN-t1)

  timer.cleartime()
  local mean, pp = fft_load(buf)
  local t_load = timer.gettime()

  timer.cleartime()
  fft_run()
  local t_fft = timer.gettime()

  timer.cleartime()
  local half = fft_magnitude()
  local t_mag = timer.gettime()

  -- peak bin (skip DC)
  timer.cleartime()
  local bm, bk = -1, -1
  local mag = fft_mag
  for i = 2, half do
    local m = mag[i]
    if m > bm then bm, bk = m, i-1 end
  end
  local t_pk = timer.gettime()

  local total = t_acq + t_load + t_fft + t_mag + t_pk
  print(string.format(
    "N=%-5d init=%.3f acq=%.3f load=%.3f fft=%.3f mag=%.3f pk=%.3f | TOTAL=%.3f s (%.2f fps)",
    N, t_init, t_acq, t_load, t_fft, t_mag, t_pk, total, 1/total))
  print(string.format(
    "        fs_actual=%.1f Hz  bin=%.2f Hz  peak: bin %d = %.1f Hz @ %.4f Vpk (%.4f Vpp)  pp_raw=%.4f",
    fs_actual, fs_actual/N, bk, bk*fs_actual/N, bm, bm*2, pp))
end

function bench_synth(N)
  -- correctness check with a synthetic two-tone, no hardware involved
  fft_init(N)
  local re, win = fft_re, fft_win
  local pi, sin = math.pi, math.sin
  local k1, k2 = 32, 100          -- exact bin centres
  for i = 1, N do
    local t = (i-1)/N
    re[i] = (1.0*sin(2*pi*k1*t) + 0.5*sin(2*pi*k2*t)) * win[i]
    fft_im[i] = 0
  end
  fft_run()
  local half = fft_magnitude()
  local s = ""
  for i = 1, half do
    if fft_mag[i] > 0.05 then
      s = s .. string.format("bin%d=%.4f ", i-1, fft_mag[i])
    end
  end
  print(string.format("SYNTH N=%d expect bin%d=1.0000 bin%d=0.5000 -> %s", N, k1, k2, s))
end
'''


def main():
    clear_dead_sockets()
    d = DMM(timeout=120)
    d.q('reset()')
    d.q('eventlog.clear()')

    core = open(CORE).read()
    print('loading fft_core.tsp ...')
    d.send('loadscript fftcore')
    for ln in core.splitlines():
        d.send(ln)
    d.send('endscript')
    time.sleep(0.5)
    # A stored script must be RUN once before its functions exist.
    d.q('fftcore() print("core loaded")', timeout=60)
    print('  fft_init type :', d.q('print(type(fft_init))'))
    print('  log           :', d.q('if eventlog.getcount()>0 then print(eventlog.next()) '
                                   'else print("clean") end', timeout=40))
    d.q('eventlog.clear()')

    d.load_script('bench', BENCH, run=False)
    d.q('bench() print("bench loaded")', timeout=60)

    print('\n=== correctness (synthetic, no hardware) ===')
    for N in (512, 1024):
        d.drain()
        d.send(f'bench_synth({N})')
        print(' ', d.line(180))

    print('\n=== real acquisition, 12.5 kHz 2 Vpp tone ===')
    g = SDG()
    g.sine(12500, 2.0, ch=1)
    g.output(True, ch=1, load='HZ')
    g.close()
    time.sleep(1.0)

    d.q('cap = buffer.make(20000, buffer.STYLE_STANDARD)', timeout=60)
    for N, fs in ((512, 100000), (1024, 100000), (2048, 100000)):
        d.drain()
        d.send(f'bench_one({N}, {fs}, cap)')
        for _ in range(2):
            print(' ', d.line(240))

    print('\nlog:', d.q('if eventlog.getcount()>0 then print(eventlog.next()) '
                        'else print("clean") end', timeout=40))
    d.q('eventlog.clear()')
    d.close()
    return 0


if __name__ == '__main__':
    sys.exit(main())
