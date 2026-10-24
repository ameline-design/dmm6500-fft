#!/usr/bin/env python3
"""Offline test of probe_pool.classify(), over the census series it can see.

No socket: probe_pool imports DMM inside main(), so importing it here opens
nothing. Run from the repo root:

    python3 -I tools/test_probe_pool.py

The seven series below are the realistic ones. Four of them -- the clean case,
the pool dry from press 1, a volunteered event line, and a handle that climbs
and returns -- were all reported as "NOT leaking" by the version that dropped
every non-numeric token and compared the first surviving handle with the last.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_pool                                                # noqa: E402

FAIL = []


def check(name, cond, detail=''):
    print(('  PASS  ' if cond else '  FAIL  ') + name + (('   ' + detail) if detail else ''))
    if not cond:
        FAIL.append(name)


# (name, census series baseline-first, expected verdict, a word the text must carry)
CASES = [
    ('clean, no leak',
     ['412', '412', '412', '412', '412'], False, 'NOT leaking'),
    ('leaks one per press',
     ['412', '413', '414', '415', '416'], True, 'consuming pool objects'),
    ('leaks, then the pool runs dry',
     ['412', '413', '414', 'nil', 'nil'], True, 'pool is exhausted'),
    ('pool dry from press 1',
     ['412', 'nil', 'nil', 'nil', 'nil'], True, 'pool is exhausted'),
    ('one volunteered event line ate a census',
     ['412', None, '413', '414', '415'], True, 'consuming pool objects'),
    ('a volunteered line with no climb around it',
     ['412', None, '412', '412', '412'], None, 'cannot be ruled out'),
    ('handle climbs then returns',
     ['412', '413', '414', '413', '412'], True, 'consumed and returned'),
    ('no app screen midway',
     ['412', '412', 'noscreen', '412', '412'], None, 'stopped being built'),
]


def main():
    print('probe_pool.classify()')
    for name, series, want, word in CASES:
        got, text = probe_pool.classify(series)
        check(name, got is want, '%s -> %s' % (probe_pool._fmt(series), text))
        check('  ...and the text names the mechanism', word in text, word)

    print('\ncensus_token()')
    check('a plain census reply yields the handle',
          probe_pool.census_token('H=412') == '412')
    check('an exhausted pool yields the nil token, not None',
          probe_pool.census_token('H=nil') == probe_pool.DRY)
    check('a torn-down app yields the noscreen token',
          probe_pool.census_token('H=noscreen') == probe_pool.NOSCREEN)
    check('a volunteered event line yields None, not a handle',
          probe_pool.census_token('1131 Parameter, frac, expected 0 to 0.9999999')
          is None)
    check('None in, None out', probe_pool.census_token(None) is None)

    print('\nthe two statements that must not go through q()')
    src = open(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                            'probe_pool.py')).read()
    for stmt in ("eventlog.clear()", "fftsa.options_apply()",
                 "localnode.showevents = 0"):
        check("'%s' is sent with exec(), which appends a sentinel" % stmt,
              ("d.exec('" + stmt + "')") in src)
        check("  ...and not with q(), which would block for its whole timeout",
              ("d.q('" + stmt + "')") not in src)

    print('')
    if FAIL:
        print('%d FAILURE(S): %s' % (len(FAIL), ', '.join(FAIL)))
        return 1
    print('all probe_pool tests passed')
    return 0


if __name__ == '__main__':
    sys.exit(main())
