#!/usr/bin/env python3
"""Host-side tests for the TSP algorithms, re-implemented in Python.

The transform here is SUPERSEDED, and this file is no longer the primary gate.

It used to claim everything was ported 1:1 from the .tsp modules. That stopped
being true on 2026-10-23: the FFT below is the old radix-2 transform producing
MAGNITUDE, while tsp/fft_core.tsp now runs a packed N/2 complex transform
producing POWER. The two no longer correspond, and nothing re-ports this when
the Lua changes -- which is how a stale port becomes worse than no port, because
it keeps passing and reassuring.

Use tools/test_tsp.lua instead. It runs the SHIPPED Lua under Lua 5.0.2, the
instrument's own dialect, so it catches a whole class of faults this cannot:
hex literals, '#', {...}, string methods, string.match. Every one of those
passes on a host interpreter and fails on the instrument, and that gap cost a
full afternoon of popped errors. The Lua suite also carries a direct-DFT
cross-check over every bin plus eighteen independently computed reference values
pinned as literals -- strictly better evidence than a re-implementation, which
can be wrong in the same way twice.

Still sound here, because they have not diverged: the peak picker, the
window/bin clamping, the options validation and the sample-rate choice. The FFT
section wants re-porting or deleting; it is kept only because deleting it now
would take those with it.
"""
import math
import sys

FAIL = []


def check(name, cond, detail=''):
    print(('  PASS  ' if cond else '  FAIL  ') + name + (('   ' + detail) if detail else ''))
    if not cond:
        FAIL.append(name)


# --------------------------------------------------------------------------
# fft_core.tsp, ported (1-based lists; index 0 is padding and unused)
# --------------------------------------------------------------------------
class FFT:
    def init(self, N):
        self.n = N
        twopi_over = 2 * math.pi / (N - 1)
        self.win = [0.0] * (N + 1)
        wsum = 0.0
        for i in range(1, N + 1):
            w = 0.5 - 0.5 * math.cos(twopi_over * (i - 1))
            self.win[i] = w
            wsum += w
        self.cg = wsum / N                       # exact coherent gain

        self.swp_a, self.swp_b = [0] * (N + 1), [0] * (N + 1)
        n, j = 0, 0
        for i in range(0, N - 1):
            if i < j:
                n += 1
                self.swp_a[n], self.swp_b[n] = i + 1, j + 1
            k = N // 2
            while k <= j:
                j -= k
                k = k // 2
            j += k
        self.nswp = n

        self.twr, self.twi = [0.0] * (N * 2), [0.0] * (N * 2)
        idx, ln = 0, 4
        while ln <= N:
            half = ln // 2
            ang = -2 * math.pi / ln
            for m in range(0, half):
                idx += 1
                self.twr[idx] = math.cos(ang * m)
                self.twi[idx] = math.sin(ang * m)
            ln *= 2

    def load(self, readings):
        N = self.n
        self.re = [0.0] * (N + 1)
        self.im = [0.0] * (N + 1)
        mean = 0.0
        for i in range(1, N + 1):
            v = readings[i - 1]
            self.re[i] = v
            mean += v
        mean = mean / N
        for i in range(1, N + 1):
            self.re[i] = (self.re[i] - mean) * self.win[i]
            self.im[i] = 0.0

    def run(self):
        N, re, im = self.n, self.re, self.im
        for s in range(1, self.nswp + 1):
            a, b = self.swp_a[s], self.swp_b[s]
            re[a], re[b] = re[b], re[a]
        for i in range(1, N + 1, 2):
            a, b = re[i], re[i + 1]
            re[i], re[i + 1] = a + b, a - b
        ln, base = 4, 0
        while ln <= N:
            half = ln // 2
            for i in range(0, N, ln):
                ti = base
                for m in range(1, half + 1):
                    ti += 1
                    a, b = i + m, i + m + half
                    wr, wi = self.twr[ti], self.twi[ti]
                    xr, xi = re[b], im[b]
                    vr = xr * wr - xi * wi
                    vi = xr * wi + xi * wr
                    ar, ai = re[a], im[a]
                    re[b], im[b] = ar - vr, ai - vi
                    re[a], im[a] = ar + vr, ai + vi
            base += half
            ln *= 2

    def magnitude(self):
        N = self.n
        half = N // 2
        k = 2 / (N * self.cg)
        self.mag = [None] * (half + 2)
        for i in range(1, half + 1):
            self.mag[i] = math.sqrt(self.re[i] ** 2 + self.im[i] ** 2) * k
        return half


# --------------------------------------------------------------------------
# spectrum_ui.tsp / spectrum_graph.tsp / spectrum_app.tsp, ported
# --------------------------------------------------------------------------
def find_peaks(mag, nbins, count, kmin=None, kmax=None):
    bi, bv = [0] * (count + 1), [-1.0] * (count + 1)
    if kmin is None or kmin < 2:
        kmin = 2
    if kmax is None or kmax > nbins:
        kmax = nbins
    for k in range(kmin, kmax + 1):
        m = mag[k] if k < len(mag) else None
        if m is not None:
            ml = mag[k - 1] if 0 <= k - 1 < len(mag) else None
            mr = mag[k + 1] if k + 1 < len(mag) else None
            if ml is None:
                ml = -1
            if mr is None:
                mr = -1
            if m > ml and m >= mr:
                if m > bv[count]:
                    s = count
                    while s > 1 and m > bv[s - 1]:
                        bv[s], bi[s] = bv[s - 1], bi[s - 1]
                        s -= 1
                    bv[s], bi[s] = m, k
    return bi, bv


def window_bins(flo, fhi, nbins, binhz):
    if binhz is None or binhz <= 0:
        return 1, nbins
    # Low edge rounds UP, matching sg_window_bins: rounding down re-admits the DC
    # bin for any start below one bin width, including the 10 Hz floor.
    kmin = math.ceil(flo / binhz) + 1
    kmax = math.floor(fhi / binhz) + 1
    if kmin < 1:
        kmin = 1
    if kmin > nbins:
        kmin = nbins
    if kmax > nbins:
        kmax = nbins
    if kmax < kmin:
        kmax = kmin
    return kmin, kmax


def pick_fscale(fhi):
    s = 1000
    if fhi is None or fhi <= 0:
        return s
    while fhi / s >= 59:
        s *= 10
    return s


def options_apply(cur_flo, cur_fhi, field_lo, field_hi):
    """The validated pair assignment from fftsa.options_apply()."""
    nlo, nhi = cur_flo, cur_fhi
    if field_hi is not None and field_hi > 0:
        nhi = field_hi
    if field_lo is not None and field_lo >= 0:
        nlo = field_lo
    if nlo >= nhi:
        nlo = 0
    return nlo, nhi


RATES = [1000, 10000, 20000, 50000, 100000, 200000, 500000, 1000000]


def pick_fs(fhi):
    for r in RATES:
        if r / 2 >= fhi:
            return r
    return RATES[-1]


# --------------------------------------------------------------------------
def sine(n, fs, f, amp, dc=0.0):
    return [dc + amp * math.sin(2 * math.pi * f * i / fs) for i in range(n)]


def main():
    N = 512
    fft = FFT()
    fft.init(N)

    print('FFT core')
    check('coherent gain is exact (N-1)/(2N), not 0.5',
          abs(fft.cg - (N - 1) / (2 * N)) < 1e-12,
          f'cg={fft.cg:.9f} vs 0.5 (err {abs(0.5 - fft.cg) / 0.5 * 100:.3f}%)')

    # 12.5 kHz at 100 kS/s lands exactly on a bin (bin 65 of 256), 1 V amplitude.
    fs, f0, amp = 100000, 12500, 1.0
    fft.load(sine(N, fs, f0, amp, dc=2.5))
    fft.run()
    nb = fft.magnitude()
    binhz = fs / N
    peak_k = max(range(1, nb + 1), key=lambda k: fft.mag[k])
    check('peak lands in the correct bin', abs((peak_k - 1) * binhz - f0) <= binhz,
          f'bin {peak_k} = {(peak_k - 1) * binhz:.1f} Hz (bin width {binhz:.2f})')
    err = abs(fft.mag[peak_k] - amp) / amp * 100
    check('amplitude accurate to <0.5% with exact gain', err < 0.5,
          f'{fft.mag[peak_k]:.6f} V vs {amp} V ({err:.3f}% error)')
    approx = fft.mag[peak_k] * fft.cg / 0.5
    check('assuming a coherent gain of 0.5 is measurably worse',
          abs(approx - amp) > abs(fft.mag[peak_k] - amp),
          f'0.5 gives {approx:.6f} V ({abs(approx - amp) / amp * 100:.3f}%)')
    check('DC removed (bin 1 far below the tone)', fft.mag[1] < fft.mag[peak_k] * 1e-3,
          f'dc bin {fft.mag[1]:.3e} with a 2.5 V offset present')

    print('\nfind_peaks')
    bi, bv = find_peaks(fft.mag, nb, 6)
    check('strongest peak is the tone', bi[1] == peak_k, f'bi[1]={bi[1]}')
    check('peaks come back sorted, strongest first',
          all(bv[i] >= bv[i + 1] for i in range(1, 6)))

    # Bin 1 is DC, so bin 2 is the first real frequency bin and must be reportable.
    fft.load(sine(N, fs, binhz, 1.0))
    fft.run()
    fft.magnitude()
    bi2, _ = find_peaks(fft.mag, nb, 6)
    check('a tone in bin 2 is reportable', bi2[1] == 2,
          f'bi[1]={bi2[1]} (bin 2 = {binhz:.1f} Hz)')

    # Windowing: a strong out-of-window tone must NOT be reported.
    mixed = [a + b for a, b in zip(sine(N, fs, 12000, 0.2), sine(N, fs, 40000, 1.0))]
    fft.load(mixed)
    fft.run()
    fft.magnitude()
    allp, _ = find_peaks(fft.mag, nb, 6)
    kmin, kmax = window_bins(8000, 16000, nb, binhz)
    winp, _ = find_peaks(fft.mag, nb, 6, kmin, kmax)
    f_all = (allp[1] - 1) * binhz
    f_win = (winp[1] - 1) * binhz
    check('unwindowed search reports the off-screen 40 kHz tone', abs(f_all - 40000) < binhz,
          f'{f_all:.0f} Hz')
    check('windowed search reports only the on-screen 12 kHz tone',
          abs(f_win - 12000) < binhz, f'{f_win:.0f} Hz (window {kmin}..{kmax})')
    check('no reported peak falls outside the window',
          all(winp[p] == 0 or kmin <= winp[p] <= kmax for p in range(1, 7)))

    print('\nwindow_bins clamping')
    nbins = 256
    kmin, kmax = window_bins(499000, 500, nbins, binhz)   # flo > fhi
    check('inverted span still yields in-range bins', 1 <= kmin <= nbins and 1 <= kmax <= nbins,
          f'kmin={kmin} kmax={kmax} nbins={nbins}')
    check('inverted span cannot index past the magnitude array', kmax <= nbins and kmin <= nbins)
    kmin, kmax = window_bins(0, 50000, nbins, binhz)
    check('normal full span spans the whole spectrum', kmin == 1 and kmax == nbins,
          f'{kmin}..{kmax}')
    kmin, kmax = window_bins(8000, 16000, nbins, binhz)
    check('zoom window maps to the right bins',
          abs((kmin - 1) * binhz - 8000) < binhz and abs((kmax - 1) * binhz - 16000) < binhz,
          f'{kmin}..{kmax} = {(kmin - 1) * binhz:.0f}..{(kmax - 1) * binhz:.0f} Hz')
    check('binhz of zero degrades safely', window_bins(0, 5e4, nbins, 0) == (1, nbins))
    for lo, hi in [(0, 50000), (499000, 500), (16000, 8000), (0, 0), (500000, 500000)]:
        k0, k1 = window_bins(lo, hi, nbins, binhz)
        if not (1 <= k0 <= nbins and 1 <= k1 <= nbins and k1 >= k0):
            check(f'span ({lo},{hi}) stays in range', False, f'{k0}..{k1}')
            break
    else:
        check('every adversarial span stays in range and non-empty', True)

    print('\noptions_apply pair validation')
    lo, hi = options_apply(8000, 16000, 8000, 5000)    # drop stop below current start
    check('lowering stop below start resets start to DC', lo == 0 and hi == 5000,
          f'flo={lo} fhi={hi}')
    check('  ...and the resulting span is valid', lo < hi)
    lo, hi = options_apply(0, 50000, 8000, 16000)
    check('a normal zoom is accepted unchanged', lo == 8000 and hi == 16000, f'{lo}..{hi}')
    lo, hi = options_apply(8000, 16000, 20000, 16000)   # start above stop
    check('start above stop resets start to DC', lo == 0 and hi == 16000, f'{lo}..{hi}')
    lo, hi = options_apply(8000, 16000, None, None)     # unreadable fields
    check('unreadable fields keep the current settings', lo == 8000 and hi == 16000)
    bad = [(a, b) for a in (0, 500, 8000, 499000) for b in (500, 16000, 500000)
           if not (lambda r: r[0] < r[1])(options_apply(8000, 16000, a, b))]
    check('no field combination can produce flo >= fhi', not bad, str(bad[:3]))

    print('\naxis scale (the 60 s label rollover)')
    check('50 kHz span labels directly in kHz', pick_fscale(50000) == 1000)
    check('50 kHz span stays under the 60 s rollover', 50000 / pick_fscale(50000) < 59)
    for fhi in (500, 5000, 50000, 58999, 60000, 100000, 500000, 1000000):
        s = pick_fscale(fhi)
        if fhi / s >= 59:
            check(f'{fhi} Hz span avoids MM:SS labels', False, f'scale {s} -> {fhi / s:.1f} s')
            break
    else:
        check('every span up to 1 MHz avoids MM:SS labels', True)
    check('500 kHz uses a x10 kHz scale', pick_fscale(500000) == 10000,
          f'500 kHz -> {500000 / pick_fscale(500000):.1f} label-seconds')

    print('\nsample-rate choice')
    check('fs covers Nyquist for every span',
          all(pick_fs(f) / 2 >= f for f in (500, 5000, 25000, 50000, 250000, 500000)))
    check('50 kHz span picks 100 kS/s', pick_fs(50000) == 100000)
    check('over-range span falls back to the top rate', pick_fs(9e9) == 1000000)

    print()
    if FAIL:
        print(f'{len(FAIL)} FAILURE(S): ' + ', '.join(FAIL))
        return 1
    print('all algorithm tests passed')
    return 0


if __name__ == '__main__':
    sys.exit(main())
