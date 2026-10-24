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

The operator's span, range and window come back unchanged: Apply is pressed with
whatever the fields already hold. One instrument setting is written --
localnode.showevents, which has to be off for eventlog.next() to return anything at
all -- and it is restored in the finally block.

    python3 -I tools/probe_pool.py [--presses 12]

classify() below is pure, and tools/test_probe_pool.py drives it over the census
series this probe can actually see. DMM is imported inside main(), so importing
this file opens nothing.
"""
import argparse

# Census tokens that are not handles. Each one is a measurement in its own right,
# which is why classify() names them instead of filtering them out: 'nil' is the
# condition this probe exists to detect.
DRY = 'nil'              # display.create returned nil -- the pool is exhausted
NOSCREEN = 'noscreen'    # fftsa.sg_scr is nil -- the app is not built any more

# One statement per line, each well under the 1024-byte one-line probe ceiling.
CENSUS = ('do if fftsa.sg_scr == nil then print("H=noscreen") return end '
          'local h = display.create(fftsa.sg_scr, display.OBJ_TEXT, 8, 430, "", '
          '0, display.FONT_SMALL) print("H=" .. tostring(h)) '
          'if h ~= nil then display.delete(h) end end')

# eventlog.next() returns six values; tostring() of the call keeps only the first,
# which is the number, so a label reading "event text" used to carry no text.
EVENTS = ('do local n = eventlog.getcount() local s = "" '
          'for i = 1, n do local num, msg, sev = eventlog.next() '
          's = s .. "|" .. tostring(num) .. " " .. tostring(msg) end '
          'print(n .. " events " .. s) end')


def census_token(reply):
    """The token after H= in a reply, or None if the reply carries none.

    dmmrun.q returns the first line it receives and this instrument volunteers
    event lines, so a census can come back as somebody else's text. That is a lost
    measurement, not a zero.
    """
    for tok in str(reply).split():
        if tok.startswith('H='):
            return tok[2:]
    return None


def classify(handles):
    """Verdict from a census series, baseline first.

    Returns (leaking, text): True, False, or None for inconclusive.

    The order matters. An exhausted pool is the leak fully realised, so it is
    checked before any arithmetic -- the earlier version dropped every
    non-numeric token and then compared the first surviving handle with the
    last, which reported "NOT leaking" for a pool that was dry from press 1.
    A gap cannot hide a climb that is still visible in what came back, so a
    visible climb is reported despite gaps; a flat readable series WITH gaps
    cannot rule a leak out, and says so.
    """
    n = len(handles)
    if n < 2:
        return None, 'only %d census(es) -- inconclusive' % n
    presses = n - 1
    for i, h in enumerate(handles):
        if h == DRY:
            return True, ('display.create returned nil at census %d of %d: the '
                          'pool is exhausted. That is the leak, fully realised. '
                          'Series: %s' % (i, presses, _fmt(handles)))
    for i, h in enumerate(handles):
        if h == NOSCREEN:
            return None, ('fftsa.sg_scr was nil at census %d of %d, so the app '
                          'stopped being built part way through -- inconclusive. '
                          'Series: %s' % (i, presses, _fmt(handles)))
    nums, gaps = [], 0
    for h in handles:
        if h is not None and str(h).isdigit():
            nums.append(int(h))
        else:
            gaps += 1
    if len(nums) < 2:
        return None, ('only %d of %d censuses came back as a handle -- '
                       'inconclusive. Series: %s' % (len(nums), n, _fmt(handles)))
    peak, first, last = max(nums), nums[0], nums[-1]
    gaptxt = '' if not gaps else (' (%d census(es) unreadable)' % gaps)
    if peak > first:
        extra = ''
        if last <= first:
            extra = (' -- and came back to %d, so the slots were consumed and '
                     'returned rather than held' % last)
        return True, ('handle climbed %d -> %d over %d presses, %.2f per press%s. '
                      'The Apply path is consuming pool objects%s. Series: %s'
                      % (first, peak, presses, (peak - first) / float(presses),
                         gaptxt, extra, _fmt(handles)))
    if gaps:
        return None, ('no climb across the %d readable censuses, and %d unreadable, '
                      'so a leak cannot be ruled out -- inconclusive. Series: %s'
                      % (len(nums), gaps, _fmt(handles)))
    return False, ('handle steady at %d over %d presses. The rebind is NOT leaking '
                   'pool slots. Series: %s' % (first, presses, _fmt(handles)))


def _fmt(handles):
    return ' '.join('-' if h is None else str(h) for h in handles)


def main():
    from dmmrun import DMM

    ap = argparse.ArgumentParser()
    ap.add_argument('--presses', type=int, default=12)
    a = ap.parse_args()

    d = DMM(timeout=120)
    showev = None
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
        # With showevents on, eventlog.next() never returns an event: the events are
        # read automatically and sent to the interface (Ref manual, eventlog.next,
        # Details). This bench volunteers event lines, so leaving it on would print
        # "0 events" and lose the measurement the probe exists to take.
        showev = str(d.q('print(tostring(localnode.showevents))')).strip()
        print('  localnode.showevents:', showev)
        if showev != '0':
            print('    turning it off for the run; restored at the end')
            d.exec('localnode.showevents = 0')
        # exec, not q: these print nothing, and q() on a silent statement blocks for
        # its whole 30 s timeout and returns None -- 6.5 minutes over 12 presses,
        # with no way to tell whether the Apply ran.
        d.exec('eventlog.clear()')
        # Read before as well as after, or a non-zero count cannot be attributed to
        # the presses rather than to earlier history.
        before = d.q('print(tostring(fftsa.delfails) .. " " '
                     '.. tostring(fftsa.errcount))')
        print('  delfails/errcount before:', before)

        handles = [census_token(d.q(CENSUS))]
        print('  %-22s handle %s' % ('before any Apply', handles[0]))
        for i in range(a.presses):
            if not d.exec('fftsa.options_apply()'):
                print('  Apply %d: no sentinel came back' % (i + 1))
            handles.append(census_token(d.q(CENSUS)))
            print('  %-22s handle %s' % ('after Apply %d' % (i + 1), handles[-1]))

        print('  settings after: ', d.q('print(fftsa.opt_info_text())'))
        print('  delfails/errcount after: ',
              d.q('print(tostring(fftsa.delfails) .. " " '
                  '.. tostring(fftsa.errcount))'), '(before:', before + ')')
        print('  event log:      ', d.q(EVENTS))

        leaking, text = classify(handles)
        print('')
        print('  VERDICT: ' + text)
        if leaking is None:
            print('  (inconclusive: nothing here settles the hypothesis)')
    finally:
        if showev is not None and showev != '0':
            d.exec('localnode.showevents = ' + showev)
        d.close()


if __name__ == '__main__':
    main()
