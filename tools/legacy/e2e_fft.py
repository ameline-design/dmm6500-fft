#!/usr/bin/env python3
"""End-to-end FFT validation: SDG2122X tone -> DMM6500 digitizer -> on-box FFT.

Sweeps a set of known tones and checks that the on-instrument FFT reports the
right frequency and amplitude for each. fs/N is chosen so the test tones land on
exact bin centres, which removes scalloping loss from the amplitude assertion.
"""
import sys
import time

sys.path.insert(0, __file__.rsplit('/', 1)[0])
from dmmrun import DMM          # noqa: E402
from siglent import SDG         # noqa: E402

N = 4096
FS = 102400            # -> 25 Hz bins
BIN = FS / N

# (frequency, Vpp). Frequencies are exact multiples of BIN (25 Hz).
TONES = [
    (1000.0, 2.0),
    (5000.0, 2.0),
    (10000.0, 1.0),
    (25000.0, 2.0),
    (40000.0, 2.0),
]

# TSP: capture N samples then FFT in place, printing peak bin + amplitude.
FFT_SCRIPT = r'''
function fftcap(N, fs)
  local sin, cos, pi, floor, sqrt = math.sin, math.cos, math.pi, math.floor, math.sqrt
  dmm.digitize.func       = dmm.FUNC_DIGITIZE_VOLTAGE
  dmm.digitize.range      = 10
  dmm.digitize.samplerate = fs
  dmm.digitize.aperture   = dmm.APERTURE_AUTO
  dmm.digitize.count      = N
  defbuffer1.clear()
  dmm.digitize.read(defbuffer1)

  local re, im, mean = {}, {}, 0
  local rd = defbuffer1.readings
  for i = 1, N do local v = rd[i]; re[i] = v; mean = mean + v end
  mean = mean / N
  local vmin, vmax = re[1], re[1]
  for i = 1, N do
    if re[i] < vmin then vmin = re[i] end
    if re[i] > vmax then vmax = re[i] end
  end
  -- DC removal + Hann window (coherent gain 0.5)
  for i = 1, N do
    local w = 0.5 - 0.5*cos(2*pi*(i-1)/(N-1))
    re[i] = (re[i] - mean) * w
    im[i] = 0
  end
  timer.cleartime()
  local j = 0
  for i = 0, N-2 do
    if i < j then
      re[i+1], re[j+1] = re[j+1], re[i+1]
      im[i+1], im[j+1] = im[j+1], im[i+1]
    end
    local k = floor(N/2)
    while k <= j do j = j - k; k = floor(k/2) end
    j = j + k
  end
  local len = 2
  while len <= N do
    local half = floor(len/2)
    local ang = -2*pi/len
    local twr, twi = {}, {}
    for m = 0, half-1 do twr[m+1] = cos(ang*m); twi[m+1] = sin(ang*m) end
    for i = 0, N-1, len do
      for m = 0, half-1 do
        local a = i+m+1
        local b = a+half
        local wr, wi = twr[m+1], twi[m+1]
        local xr, xi = re[b], im[b]
        local vr = xr*wr - xi*wi
        local vi = xr*wi + xi*wr
        re[b] = re[a] - vr; im[b] = im[a] - vi
        re[a] = re[a] + vr; im[a] = im[a] + vi
      end
    end
    len = len * 2
  end
  local el = timer.gettime()
  local bm, bk = -1, -1
  local half = floor(N/2)
  for k = 2, half do            -- skip DC bin
    local m = sqrt(re[k]*re[k] + im[k]*im[k])*2/N/0.5
    if m > bm then bm, bk = m, k-1 end
  end
  print(string.format("RESULT %d %.6f %.6f %.6f %.4f", bk, bm, vmin, vmax, el))
end
'''


def main():
    g = SDG()
    print('generator:', g.idn())
    d = DMM()
    print('dmm      :', d.q('print(localnode.model .. " " .. localnode.version)'))
    d.q('reset()')
    d.load_script('fftcap', FFT_SCRIPT, run=False)

    print(f'\nN={N}  fs={FS}  bin={BIN:.2f} Hz\n')
    hdr = (f'{"set Hz":>9} {"set Vpp":>8} | {"peak Hz":>10} {"err Hz":>8} '
           f'{"Vpp meas":>9} {"raw pp":>8} {"fft s":>6}  verdict')
    print(hdr)
    print('-' * len(hdr))

    allok = True
    for freq, vpp in TONES:
        g.sine(freq, vpp, ch=1)
        g.output(True, ch=1, load='HZ')
        time.sleep(1.0)
        d.drain()
        d.send(f'fftcap({N}, {FS})')
        line = None
        for _ in range(6):
            line = d.line(120)
            if line is None or line.startswith('RESULT'):
                break
        if not line or not line.startswith('RESULT'):
            print(f'{freq:>9.0f} {vpp:>8.2f} | no RESULT line: {line!r}')
            allok = False
            continue
        _, bk, bm, vmin, vmax, el = line.split()
        bk, bm, vmin, vmax, el = int(bk), float(bm), float(vmin), float(vmax), float(el)
        peak_hz = bk * BIN
        meas_vpp = bm * 2
        raw_pp = vmax - vmin
        f_ok = abs(peak_hz - freq) <= BIN
        a_ok = abs(meas_vpp - vpp) <= max(0.05, vpp * 0.05)
        ok = f_ok and a_ok
        allok &= ok
        print(f'{freq:>9.0f} {vpp:>8.2f} | {peak_hz:>10.1f} {peak_hz - freq:>8.1f} '
              f'{meas_vpp:>9.4f} {raw_pp:>8.4f} {el:>6.3f}  '
              f'{"OK" if ok else ("FREQ!" if not f_ok else "AMPL!")}')

    g.write('C1:BSWV WVTP,DC,OFST,0')
    g.output(False, ch=1, load='HZ')
    g.close()
    errs = d.errors()
    print('\neventlog:', errs if errs else 'clear')
    print('VERDICT :', 'ALL PASS' if allok else 'FAILURES PRESENT')
    d.close()
    return 0 if allok else 1


if __name__ == '__main__':
    sys.exit(main())
