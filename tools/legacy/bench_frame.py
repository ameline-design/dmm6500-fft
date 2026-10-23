#!/usr/bin/env python3
"""Measure the real end-to-end spectrum-analyser frame rate on the instrument.

Times acquire -> FFT -> magnitude -> peak-pick -> pixel draw for a live signal,
so the number reported is the actual achievable display update rate rather than
a sum of isolated micro-benchmarks.
"""
import base64
import struct
import sys
import time
import zlib

sys.path.insert(0, __file__.rsplit('/', 1)[0])
from dmmrun import DMM, clear_dead_sockets   # noqa: E402
from siglent import SDG                      # noqa: E402

ROOT = __file__.rsplit('/', 2)[0]
W, H = 750, 360
BG = (0x00, 0x00, 0x08)
N = 512          # -> 256 bins
FS = 100000      # exact rate (102400 is NOT achievable on this hardware)


def png_b64(w, h, rgb=BG):
    raw = b''.join(b'\x00' + bytes(rgb) * w for _ in range(h))

    def ch(t, p):
        return (struct.pack('>I', len(p)) + t + p
                + struct.pack('>I', zlib.crc32(t + p) & 0xffffffff))

    return base64.b64encode(
        b'\x89PNG\r\n\x1a\n'
        + ch(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
        + ch(b'IDAT', zlib.compress(raw, 6))
        + ch(b'IEND', b'')).decode()


FRAME = r'''
-- One full frame, instrumented. Returns nothing; prints a timing line.
function frame_once(nbins, fs, buf, report)
  local t_acq, t_load, t_fft, t_mag, t_pk, t_draw

  timer.cleartime()
  buf.clear()                        -- else the buffer fills and read() errors 4915
  dmm.digitize.read(buf)
  t_acq = timer.gettime()

  timer.cleartime()
  local mean, pp = fft_load(buf)
  t_load = timer.gettime()

  timer.cleartime()
  fft_run()
  t_fft = timer.gettime()

  timer.cleartime()
  fft_magnitude()
  t_mag = timer.gettime()

  timer.cleartime()
  local bm, bk = -1, -1
  local mag = fft_mag
  for i = 2, nbins do
    local m = mag[i]
    if m > bm then bm, bk = m, i-1 end
  end
  t_pk = timer.gettime()

  timer.cleartime()
  sp_draw_trace(nbins)
  t_draw = timer.gettime()

  local total = t_acq + t_load + t_fft + t_mag + t_pk + t_draw
  if report == 1 then
    print(string.format(
      "acq=%.4f load=%.4f fft=%.4f mag=%.4f pk=%.4f draw=%.4f | TOTAL=%.4f s = %.2f fps",
      t_acq, t_load, t_fft, t_mag, t_pk, t_draw, total, 1/total))
    print(string.format("        peak bin %d = %.1f Hz @ %.4f Vpk   dc=%.4f pp=%.4f",
      bk, bk*fs/(nbins*2), bm, mean, pp))
  end
  return total
end

-- Sustained rate over several frames (first frame is atypical: bars grow from 0).
function frame_bench(nbins, fs, buf, frames)
  frame_once(nbins, fs, buf, 0)      -- warm up: first frame has nothing to erase
  timer.cleartime()
  for i = 1, frames do
    frame_once(nbins, fs, buf, 0)
  end
  local el = timer.gettime()
  print(string.format("SUSTAINED %d frames in %.3f s = %.2f fps (%.1f ms/frame)",
    frames, el, frames/el, el/frames*1000))
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
    return d.q(f'{name}() print("{name} ok")', timeout=90)


def main():
    clear_dead_sockets()
    d = DMM(timeout=120)
    d.q('reset()')
    d.q('display.lightstate = display.STATE_LCD_100')
    d.q('eventlog.clear()')

    print('loading TSP modules...')
    print('  fft_core :', load_file(d, 'fftcore', f'{ROOT}/tsp/fft_core.tsp'))
    print('  spectrum :', load_file(d, 'spectrum', f'{ROOT}/tsp/spectrum.tsp'))
    print('  log      :', d.q('if eventlog.getcount()>0 then print(eventlog.next()) '
                              'else print("clean") end', timeout=40))
    d.q('eventlog.clear()')

    print('uploading canvas...')
    b64 = png_b64(W, H)
    d.send('loadimage spcv')
    for i in range(0, len(b64), 900):
        d.send(b64[i:i + 900])
    d.send('endimage')
    time.sleep(1.5)

    d.q(f'SP_W = {W} SP_H = {H}', timeout=30)
    print('setup    :', d.q(f'sp_setup("spcv", {N // 2}, "DMM6500 SPECTRUM") '
                            f'print("img=" .. tostring(sp_img))', timeout=90))
    print('log      :', d.q('if eventlog.getcount()>0 then print(eventlog.next()) '
                            'else print("clean") end', timeout=40))
    d.q('eventlog.clear()')

    print(f'init fft N={N} ...')
    print('  ', d.q(f'fft_init({N}) print("nswp=" .. fft_nswp)', timeout=180))

    # Configure the digitizer once; the frame loop only calls read().
    d.q(f'dmm.digitize.func = dmm.FUNC_DIGITIZE_VOLTAGE '
        f'dmm.digitize.range = 10 '
        f'dmm.digitize.samplerate = {FS} '
        f'dmm.digitize.aperture = 1e-6 '
        f'dmm.digitize.count = {N}', timeout=60)
    # Buffer must comfortably exceed N: digitize.read() appends, and a buffer
    # exactly N deep overflows on the second frame (4915).
    d.q(f'cap = buffer.make({N * 4}, buffer.STYLE_STANDARD)', timeout=60)

    g = SDG()
    g.sine(12500, 2.0, ch=1)
    g.output(True, ch=1, load='HZ')
    g.close()
    time.sleep(1.0)

    d.load_script('frm', FRAME, run=False)
    d.q('frm() print("frame fns ok")', timeout=90)

    print('\n=== single instrumented frame ===')
    d.drain()
    d.send(f'frame_once({N // 2}, {FS}, cap, 1)')
    for _ in range(2):
        print(' ', d.line(240))

    print('\n=== sustained frame rate ===')
    d.drain()
    d.send(f'frame_bench({N // 2}, {FS}, cap, 20)')
    print(' ', d.line(600))

    print('\nlog:', d.q('if eventlog.getcount()>0 then print(eventlog.next()) '
                        'else print("clean") end', timeout=40))
    d.q('eventlog.clear()')

    from screenshot import capture
    time.sleep(0.8)
    print('screenshot:', capture('/tmp/spectrum_live.png'))
    d.close()
    return 0


if __name__ == '__main__':
    sys.exit(main())
