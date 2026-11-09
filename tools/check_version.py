#!/usr/bin/env python3
"""The app's version is written in two places, and they have to agree.

tools/package_tspa.py puts a Version field in the archive manifest, which is what MENU >
Manage Apps shows and what tells one install from the one it replaced. tsp/spectrum_app.tsp
carries fftsa.VERSION, which is what the error page prints and what goes into the report
written to the USB key.

They are separate because neither side can read the other: the manifest is built by a host
script and the TSP runs on the instrument with no access to it. So a bump applied to one and
not the other makes every failure report name the wrong build -- which is worse than naming
none, because a report from a model we cannot test on is matched to a fix by that figure
alone.

    python3 -I tools/check_version.py
    python3 -I tools/check_version.py --self-test
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MANIFEST = os.path.join(ROOT, 'tools', 'package_tspa.py')
APP = os.path.join(ROOT, 'tsp', 'spectrum_app.tsp')

MANIFEST_RE = re.compile(r"\(\s*'Version'\s*,\s*'([^']+)'\s*\)")
APP_RE = re.compile(r"^\s*fftsa\.VERSION\s*=\s*'([^']+)'", re.M)


def one(path, pattern, what):
    """The single match, or a stated reason there is not exactly one.

    Zero matches and two matches are different faults with the same symptom if either is
    allowed to pass: the first means the field was renamed, the second that a copy was left
    behind and the file now says two things.
    """
    with open(path, 'r') as fh:
        src = fh.read()
    got = pattern.findall(src)
    if len(got) == 1:
        return got[0], None
    return None, '%s: %d matches for %s, expected exactly 1' % (
        os.path.relpath(path, ROOT), len(got), what)


def check():
    mv, why = one(MANIFEST, MANIFEST_RE, "the manifest Version field")
    if why is not None:
        return [why]
    av, why = one(APP, APP_RE, "fftsa.VERSION")
    if why is not None:
        return [why]
    if mv != av:
        return ['the archive manifest says Version %s and tsp/spectrum_app.tsp says '
                'fftsa.VERSION = %s -- the error page and the report written to the key '
                'would name a build that is not this one' % (mv, av)]
    # The minor part stays two digits for the same reason package_tspa.py states: the field
    # may be compared as a string, where "8.9" sorts above "8.10".
    parts = mv.split('.')
    if len(parts) != 2 or not parts[0].isdigit() or not parts[1].isdigit():
        return ['version %r is not major.minor' % mv]
    if len(parts[1]) < 2:
        return ['version %r has a one-digit minor, which sorts above a two-digit one as a '
                'string and would read as newer than it is' % mv]
    return []


def self_test():
    """The checker has to fail the cases it exists for, not merely pass the current tree."""
    cases = [
        ("('Version', '8.59'),", "fftsa.VERSION = '8.59'", 0, 'agreeing'),
        ("('Version', '8.60'),", "fftsa.VERSION = '8.59'", 1, 'manifest bumped alone'),
        ("('Version', '8.59'),", "fftsa.VERSION = '8.60'", 1, 'app bumped alone'),
        ("('Version', '8.9'),", "fftsa.VERSION = '8.9'", 1, 'one-digit minor'),
        ("('Version', '8.59'),", "-- no version here", 1, 'app field renamed'),
        ("('Version', '8.59'),", "fftsa.VERSION = '8.59'\nfftsa.VERSION = '8.59'",
         1, 'a second copy left behind'),
    ]
    bad = 0
    for manifest, app, want, name in cases:
        nm = len(MANIFEST_RE.findall(manifest))
        na = len(APP_RE.findall(app))
        if nm != 1 or na != 1:
            got = 1
        else:
            mv, av = MANIFEST_RE.findall(manifest)[0], APP_RE.findall(app)[0]
            minor = mv.split('.')[-1]
            got = 1 if (mv != av or len(minor) < 2) else 0
        mark = 'ok  ' if got == want else 'FAIL'
        if got != want:
            bad += 1
        print('  %s %-28s expected %d, got %d' % (mark, name, want, got))
    return bad


def main():
    if '--self-test' in sys.argv:
        bad = self_test()
        print('check_version self-test: %s' % ('FAILED' if bad else 'all cases as expected'))
        return 1 if bad else 0
    bad = check()
    for b in bad:
        print('check_version: %s' % b)
    if bad:
        return 1
    with open(APP, 'r') as fh:
        v = APP_RE.findall(fh.read())[0]
    print('check_version: manifest and tsp agree at %s' % v)
    return 0


if __name__ == '__main__':
    sys.exit(main())
