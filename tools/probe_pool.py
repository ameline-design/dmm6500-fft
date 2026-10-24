#!/usr/bin/env python3
"""Does fftsa.apply() leak display-object pool slots?

apply() calls sg_rebind(), which is graph.removeall followed by graph.add. If a
bound trace holds a pool slot that removeall does not return, every Apply press
costs objects, and once display.create starts returning nil the app has no error
path left either -- show_error is itself a create. That failure would be
Apply-count dependent and window-INDEPENDENT, which fits an unexplained exit far
better than anything specific to one window's coefficients.

The census does not allocate until exhaustion, which would be destructive. It
relies on display.delete returning the handle for reuse -- measured, 2000
create/delete cycles run clean -- so a create/delete pair hands back the SAME handle
every time while nothing else is consuming them. If the handle climbs, something is.

The probe object is a child of the app's own spectrum screen, so creating it never
changes which screen is on show, and it is deleted immediately.

Read-only with respect to the operator's settings: Apply is pressed with whatever
the fields already hold, so the span, range and window come back unchanged.

    python3 -I tools/probe_pool.py [--presses 12]
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dmmrun import DMM                                          # noqa: E402

# One statement per line, each well under the 1024-byte one-line probe ceiling.
CENSUS = ('do if fftsa.sg_scr == nil then print("H=noscreen") return end '
          'local h = display.create(fftsa.sg_scr, display.OBJ_TEXT, 8, 430, "", '
          '0, display.FONT_SMALL) print("H=" .. tostring(h)) '
          'if h ~= nil then display.delete(h) end end')


def census(d, tag):
    r = d.q(CENSUS)
    h = None
    for tok in str(r).split():
        if tok.startswith('H='):
            h = tok[2:]
    print('  %-22s handle %s' % (tag, h))
    return h


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--presses', type=int, default=12)
    a = ap.parse_args()

    d = DMM(timeout=120)
    try:
        print(' ', d.q('print(localnode.model .. " fw " .. localnode.version)'))
        # The handle, not the table. A stopped app -- which is what End App leaves --
        # keeps fftsa in TSP memory with every display handle nil, and probing that
        # posts event 1138 for each nil parent or nil field: 133 of them on
        # 2026-10-23, because the first version of this check tested whether
        # "table/nil" contained "table".
        ready = str(d.q('print(tostring(fftsa ~= nil and fftsa.sg_scr ~= nil '
                        'and fftsa.optscr ~= nil))')).strip()
        print('  app built:', ready)
        if 'true' not in ready:
            raise SystemExit('the app is not BUILT -- fftsa.sg_scr or fftsa.optscr '
                             'is nil, which is what End App leaves behind. Probing '
                             'it posts an event per nil handle. Open the app, then '
                             'run this again.')
        print('  settings before:', d.q('print(fftsa.opt_info_text())'))
        d.q('eventlog.clear()')

        base = census(d, 'before any Apply')
        handles = [base]
        for i in range(a.presses):
            d.q('fftsa.options_apply()')
            handles.append(census(d, 'after Apply %d' % (i + 1)))

        print('  settings after: ', d.q('print(fftsa.opt_info_text())'))
        print('  delete refusals:', d.q('print(tostring(fftsa.delfails))'))
        print('  frame errors:   ', d.q('print(tostring(fftsa.errcount) .. " last=" '
                                        '.. tostring(fftsa.lasterr))'))
        print('  events:         ', d.q('print(eventlog.getcount())'))
        ev = d.q('do local n = eventlog.getcount() local s = "" '
                 'for i = 1, n do s = s .. "|" .. tostring(eventlog.next()) end '
                 'print(s) end')
        print('  event text:     ', ev)

        nums = [int(h) for h in handles if h and h.isdigit()]
        print('')
        if len(nums) < 2:
            print('  VERDICT: could not read handles -- inconclusive')
        elif nums[-1] == nums[0]:
            print('  VERDICT: handle steady at %d over %d presses. The rebind is NOT '
                  'leaking pool slots.' % (nums[0], a.presses))
        else:
            print('  VERDICT: handle climbed %d -> %d over %d presses, %.2f per '
                  'press. The Apply path IS consuming pool objects.'
                  % (nums[0], nums[-1], a.presses,
                     (nums[-1] - nums[0]) / float(a.presses)))
    finally:
        d.close()


if __name__ == '__main__':
    main()
