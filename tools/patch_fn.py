#!/usr/bin/env python3
"""Replace ONE function in a running app, from the source file it lives in.

An iteration on the instrument costs a reboot, a relaunch and a sample-count press -- three
minutes, and on a key-launched app it costs the operator a trip to the panel. Reloading the
whole module is not an alternative: native_link.tsp opens with `fftsa.nl = {`, so re-running it
discards the install this boot already made and the app has to re-attach.

One function can be sent on its own. What stops it being trivial is that the module's helpers
are FILE-LOCALS -- hx, u32_at, f32_pack and the rest are invisible to a separately loaded
chunk -- so a prelude redefines the few a function needs. They are small and exact; anything
larger is exposed on fftsa.nl already.

THE TEXT COMES OUT OF THE FILE, never retyped. That is the whole discipline here: a patch typed
by hand is a second implementation, and the one that gets tested is not the one that ships.

    python3 -u -I tools/patch_fn.py --fn fftsa.nl.px_frame
    python3 -u -I tools/patch_fn.py --fn fftsa.nl.px_map --file tsp/native_link.tsp
"""

import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import dmmrun  # noqa: E402


def opt(flag, default):
    if flag in sys.argv:
        return sys.argv[sys.argv.index(flag) + 1]
    return default


# The file-locals a patched function may reach for, as exact copies of the originals. Kept here
# rather than read out of the module because the originals are locals of its chunk and nothing
# can see them; each is short enough to be checked by eye against the source.
PRELUDE = [
    "local function u32_at(s, p)",
    "  local b1 = string.byte(s, p)",
    "  local b2 = string.byte(s, p + 1)",
    "  local b3 = string.byte(s, p + 2)",
    "  local b4 = string.byte(s, p + 3)",
    "  return ((b1 * 256 + b2) * 256 + b3) * 256 + b4",
    "end",
    "local function hx(v) return string.format('%X', v) end",
    "local f32_pack, f32_unpack = fftsa.nl._f32_pack, fftsa.nl._f32_unpack",
]


def extract(path, name):
    """The function's text, from its `function <name>(` line to the `end` in column one."""
    src = open(path).read().splitlines()
    head = 'function ' + name + '('
    start = None
    for i, ln in enumerate(src):
        if ln.startswith(head):
            start = i
            break
    if start is None:
        raise SystemExit('no line starting "%s" in %s' % (head, path))
    for j in range(start + 1, len(src)):
        if src[j] == 'end':
            return src[start:j + 1]
    raise SystemExit('no closing "end" in column one for %s' % name)


def main():
    name = opt('--fn', None)
    if name is None:
        raise SystemExit('--fn fftsa.nl.px_frame')
    path = os.path.join(os.path.dirname(HERE), opt('--file', 'tsp/native_link.tsp'))
    body = extract(path, name)
    print('patch  : %s, %d lines from %s' % (name, len(body), os.path.basename(path)))
    over = [ln for ln in PRELUDE + body if len(ln) >= 1024]
    if over:
        raise SystemExit('a line is too long for the execute path: %r' % over[0][:60])

    d = dmmrun.DMM(timeout=180, recover=False)
    for _ in range(60):
        r = d.q("print('A|' .. tostring(fftsa ~= nil and fftsa.nl ~= nil))", timeout=30)
        if r is not None and str(r).startswith('A|true'):
            break
        time.sleep(0.4)
    else:
        raise SystemExit('the app is not answering')

    # A fresh script name each time: script.delete on a name the app is running from is how a
    # live launch gets torn out from under itself.
    sname = 'zpatch'
    d.q('if %s ~= nil then pcall(function() script.delete(%s) end) %s = nil end'
        % (sname, sname, sname), timeout=30)
    d.drain()
    d.send('loadscript ' + sname)
    for ln in PRELUDE + body:
        d.send(ln)
    d.send("print('PT|' .. tostring(type(" + name + ")))")
    d.send('endscript')
    time.sleep(0.4)
    r = d.q(sname + '()', timeout=120)
    print('loaded : %s' % r)
    if r is None or 'function' not in str(r):
        raise SystemExit('the patch did not define %s' % name)
    print('       : the running app now holds this build of %s' % name)
    return 0


if __name__ == '__main__':
    sys.exit(main())
