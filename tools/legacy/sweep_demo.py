#!/usr/bin/env python3
"""Sweep the generator back and forth and watch the live spectrum track it.

Reuses the spectrum-analyser app that is ALREADY built on the instrument (from a
prior run_graph.py run) — it does NOT reset, reload, or rebuild anything, so it
adds zero build-cycle churn and therefore zero extra crash risk.

For each frequency step it: sets the generator, runs a couple of DMM frames to
refresh the display, reports the detected peak, and (on the first pass) grabs a
screenshot so the peak's motion can be verified.
"""
import argparse
import sys
import time

sys.path.insert(0, __file__.rsplit('/', 1)[0])
from dmmrun import DMM, clear_dead_sockets   # noqa: E402
from screenshot import capture               # noqa: E402
from siglent import SDG                      # noqa: E402


def app_present(d):
    return (d.q('print(type(sa_frame))') == 'function'
            and d.q('print(tostring(SG_GRAPH))') not in ('nil', None))


def one_step(d, g, freq, vpp):
    """Set the generator, refresh the display, return the detected peak (Hz, Vpk)."""
    g.sine(freq, vpp, ch=1)
    g.output(True, ch=1, load='HZ')
    time.sleep(0.35)
    # A couple of settling frames, then one reporting frame.
    d.exec('sa_frame(0) sa_frame(0)', timeout=60)
    line = d.q('sa_frame(1)', timeout=60)   # prints "FRAME ... peak bin B = F Hz @ V Vpk"
    peak_hz, peak_v = None, None
    if line and 'peak bin' in line:
        try:
            after = line.split('peak bin', 1)[1]
            peak_hz = float(after.split('=')[1].split('Hz')[0])
            peak_v = float(after.split('@')[1].split('Vpk')[0])
        except (IndexError, ValueError):
            pass
    return peak_hz, peak_v


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--lo', type=float, default=5000.0)
    ap.add_argument('--hi', type=float, default=25000.0)
    ap.add_argument('--steps', type=int, default=9, help='steps in each half-sweep')
    ap.add_argument('--passes', type=int, default=3, help='back-and-forth passes')
    ap.add_argument('--vpp', type=float, default=2.0)
    a = ap.parse_args()

    # Build the up-then-down frequency list for one pass.
    up = [a.lo + (a.hi - a.lo) * i / (a.steps - 1) for i in range(a.steps)]
    down = list(reversed(up[1:-1]))
    one_pass = up + down

    clear_dead_sockets()
    d = DMM(timeout=90)
    if not app_present(d):
        print('The spectrum app is not built on the instrument. Run '
              'tools/run_graph.py once first, then re-run this sweep.')
        d.close()
        return 2
    print('reusing the already-built app (no rebuild) — SG_GRAPH =',
          d.q('print(tostring(SG_GRAPH))'))

    g = SDG()
    print('generator :', g.idn())

    print(f'\nsweeping {a.lo/1000:.1f}-{a.hi/1000:.1f} kHz, '
          f'{len(one_pass)} steps/pass, {a.passes} passes\n')
    shot_n = 0
    for p in range(a.passes):
        for i, f in enumerate(one_pass):
            hz, v = one_step(d, g, f, a.vpp)
            tag = ''
            if hz is not None:
                err = hz - f
                tag = f'peak {hz:8.1f} Hz ({err:+6.1f})  {v:.4f} Vpk'
            # Screenshot a spread of the first pass only, to keep it quick.
            if p == 0 and i % 2 == 0:
                path = f'/tmp/sweep_{shot_n:02d}.png'
                capture(path)
                shot_n += 1
                tag += f'   -> {path}'
            print(f'  pass {p+1} set {f:8.1f} Hz   {tag}')

    # Leave the generator on a steady mid-band tone.
    mid = (a.lo + a.hi) / 2
    g.sine(mid, a.vpp, ch=1)
    g.output(True, ch=1, load='HZ')
    g.close()
    print(f'\ngenerator parked at {mid/1000:.1f} kHz; captured {shot_n} screenshots')
    print('eventlog:', d.q('if eventlog.getcount()>0 then print(eventlog.next()) '
                           'else print("clean") end', timeout=40))
    d.close()
    return 0


if __name__ == '__main__':
    sys.exit(main())
