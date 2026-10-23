#!/usr/bin/env python3
"""Bottom-up validation of the SDG2122X -> DMM6500 signal path.

Stage 1: generator emits known DC offsets, DMM reads them with DCV.
Stage 2: generator emits known sine frequencies, DMM counts them with ACV frequency.
Stage 3: generator emits a known sine amplitude, DMM measures ACV RMS.

Each stage asserts the DMM reading against the commanded value, so a failure
localises the problem (cabling, control, or scaling) before any FFT work.

No calibration commands are issued to either instrument.
"""
import sys
import time

sys.path.insert(0, __file__.rsplit('/', 1)[0])
from dmmrun import DMM          # noqa: E402
from siglent import SDG         # noqa: E402

# 75 ohm coax into the DMM's ~10 Mohm DCV input is effectively unterminated,
# so the generator is set to high-Z load and we expect ~1:1 amplitude.
LOAD = 'HZ'


def stage1_dc(g, d):
    print('\n=== STAGE 1: DC voltages (generator DC offset -> DMM DCV) ===')
    d.q('reset()')
    d.q('dmm.measure.func = dmm.FUNC_DC_VOLTAGE')
    d.q('dmm.measure.range = 10')
    d.q('dmm.measure.nplc = 1')
    d.q('dmm.measure.autozero.enable = dmm.ON')

    ok = True
    for want in (0.0, 0.5, 1.0, -1.0, 2.5, -2.5, 5.0):
        # DC output: a sine of ~0 amplitude with the desired offset.
        g.write(f'C1:BSWV WVTP,DC,OFST,{want}')
        g.output(True, ch=1, load=LOAD)
        time.sleep(0.8)
        got = d.q('print(dmm.measure.read())', timeout=25)
        try:
            got_v = float(got)
        except (TypeError, ValueError):
            print(f'  set {want:+.3f} V -> UNPARSEABLE {got!r}')
            ok = False
            continue
        # 10 V range, 1 yr spec is ~0.003% rdg + 0.0005% rng; allow generous
        # slack for generator DC accuracy (its own spec is ~1% + 2 mV).
        tol = max(0.05, abs(want) * 0.02)
        good = abs(got_v - want) <= tol
        ok &= good
        print(f'  set {want:+.3f} V -> read {got_v:+.6f} V  '
              f'(err {got_v - want:+.4f})  {"OK" if good else "FAIL"}')
    return ok


def stage2_freq(g, d):
    print('\n=== STAGE 2: AC frequency (generator sine -> DMM frequency counter) ===')
    d.q('reset()')
    d.q('dmm.measure.func = dmm.FUNC_ACV_FREQUENCY')

    ok = True
    for want in (100.0, 1000.0, 10e3, 100e3, 250e3):
        g.sine(want, 2.0, ch=1)
        g.output(True, ch=1, load=LOAD)
        time.sleep(1.0)
        got = d.q('print(dmm.measure.read())', timeout=25)
        try:
            got_f = float(got)
        except (TypeError, ValueError):
            print(f'  set {want:>10.1f} Hz -> UNPARSEABLE {got!r}')
            ok = False
            continue
        good = abs(got_f - want) <= max(1.0, want * 0.001)
        ok &= good
        print(f'  set {want:>10.1f} Hz -> read {got_f:>12.3f} Hz  '
              f'({(got_f - want) / want * 1e6:+.1f} ppm)  {"OK" if good else "FAIL"}')
    return ok


def stage3_acv(g, d):
    print('\n=== STAGE 3: AC amplitude (generator Vpp -> DMM ACV RMS) ===')
    d.q('reset()')
    d.q('dmm.measure.func = dmm.FUNC_AC_VOLTAGE')
    d.q('dmm.measure.range = 10')

    ok = True
    for vpp in (0.5, 1.0, 2.0, 5.0):
        g.sine(1000.0, vpp, ch=1)
        g.output(True, ch=1, load=LOAD)
        time.sleep(1.2)
        got = d.q('print(dmm.measure.read())', timeout=25)
        try:
            got_v = float(got)
        except (TypeError, ValueError):
            print(f'  set {vpp:.2f} Vpp -> UNPARSEABLE {got!r}')
            ok = False
            continue
        want_rms = vpp / 2 / (2 ** 0.5)
        good = abs(got_v - want_rms) <= max(0.01, want_rms * 0.05)
        ok &= good
        print(f'  set {vpp:.2f} Vpp (expect {want_rms:.4f} Vrms) -> '
              f'read {got_v:.6f} Vrms  {"OK" if good else "FAIL"}')
    return ok


def main():
    g = SDG()
    print('generator:', g.idn())
    d = DMM()
    print('dmm      :', d.q('print(localnode.model .. " fw " .. localnode.version)'))

    results = {
        'DC path': stage1_dc(g, d),
        'AC frequency': stage2_freq(g, d),
        'AC amplitude': stage3_acv(g, d),
    }

    # Leave the generator in a safe, quiet state.
    g.write('C1:BSWV WVTP,DC,OFST,0')
    g.output(False, ch=1, load=LOAD)

    print('\n=== SUMMARY ===')
    for k, v in results.items():
        print(f'  {k:<14}: {"PASS" if v else "FAIL"}')
    errs = d.errors()
    print('  eventlog      :', errs if errs else 'clear')
    g.close()
    d.close()
    return 0 if all(results.values()) else 1


if __name__ == '__main__':
    sys.exit(main())
