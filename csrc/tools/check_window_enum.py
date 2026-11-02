#!/usr/bin/env python3
"""Require fftsa.nl.WIN in native_link.tsp to agree with DSP_WINDOW_* in dsp.h.

The picker index and the window enum are different numbers that happen to coincide.
spectrum_app.tsp:49 records what a mismatch costs: the wrong window selected, with nothing
on the glass to say so and every amplitude out by a scalloping factor. The app already
keeps an explicit index-to-enum map for Keithley's dsp.WINDOW_*; native_link.tsp keeps one
for ours, and a hand-maintained map is only as good as whatever checks it.

So this is a gate rather than a comment. It fails if dsp.h renumbers an enumerator, if a
window is added to one side and not the other, or if the Lua map is not index-parallel to
the four windows the picker offers.

    python3 -I csrc/tools/check_window_enum.py --root .
"""
import argparse
import os
import re
import sys

# The four the picker offers, in index order. RECT is deliberately absent: the shipped Lua
# refuses it, so index 1 is HANN and there is no index 0.
PICKER = ['HANN', 'BLACKMAN', 'BLACKMAN_HARRIS', 'KAISER']


def enum_from_header(path):
    """DSP_WINDOW_* names to values, following `= N` assignments."""
    with open(path) as fh:
        text = fh.read()
    out = {}
    nxt = 0
    for name, val in re.findall(r'DSP_WINDOW_([A-Z_]+)\s*(?:=\s*(\d+))?', text):
        if name == 'COUNT':
            continue
        if val:
            nxt = int(val)
        if name not in out:
            out[name] = nxt
        nxt += 1
    return out


def map_from_lua(path):
    """fftsa.nl.WIN[i] = v, as an index-to-value dict."""
    with open(path) as fh:
        text = fh.read()
    return {int(i): int(v)
            for i, v in re.findall(r'fftsa\.nl\.WIN\[(\d+)\]\s*=\s*(\d+)', text)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--root', default='.')
    args = ap.parse_args()

    header = os.path.join(args.root, 'csrc', 'dsp.h')
    lua = os.path.join(args.root, 'tsp', 'native_link.tsp')
    for p in (header, lua):
        if not os.path.exists(p):
            sys.exit('missing %s' % p)

    enum = enum_from_header(header)
    win = map_from_lua(lua)
    bad = []

    for name in PICKER:
        if name not in enum:
            bad.append('dsp.h has no DSP_WINDOW_%s, but the picker offers it' % name)

    if sorted(win) != list(range(1, len(PICKER) + 1)):
        bad.append('fftsa.nl.WIN indices are %s, expected 1..%d'
                   % (sorted(win), len(PICKER)))

    for i, name in enumerate(PICKER, start=1):
        want = enum.get(name)
        got = win.get(i)
        if want is None or got is None:
            continue
        mark = 'ok  ' if got == want else 'FAIL'
        print('  %s WIN[%d] = %-2d  DSP_WINDOW_%-16s = %d' % (mark, i, got, name, want))
        if got != want:
            bad.append('WIN[%d] is %d but DSP_WINDOW_%s is %d' % (i, got, name, want))

    # RECT must stay out of the map: it is the value an unmapped index would produce, and
    # selecting it means no window at all rather than an obviously wrong one.
    if enum.get('RECT') in win.values():
        bad.append('DSP_WINDOW_RECT (%d) appears in the map; the picker excludes it'
                   % enum['RECT'])

    if bad:
        print('\n'.join('  ' + b for b in bad))
        sys.exit(1)
    print('  window enum agrees across the seam (%d windows)' % len(PICKER))


if __name__ == '__main__':
    main()
