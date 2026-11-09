#!/usr/bin/env python3
"""Press a front-panel key over the LXI web interface, and grab the glass either side of it.

THE REASON THIS EXISTS. A modal firmware dialog over a running app cannot be dismissed from the
control socket: every statement comes back "FAILURE: A command from another interface is
running, use ABORT to stop it", and ABORT clears the dialog's command without clearing the
dialog. display.waitevent is not an option either -- it blocks and wedges the interpreter, and
a zero timeout means forever. What dismisses a dialog is a key, and the web front panel presses
real keys.

From the instrument's own /script/ajax_inc.js and /script/vfplib.js:

    POST /ajax_proc  function=7  button=<n>  session=<id>    press
    POST /ajax_proc  function=8  button=<n>  session=<id>    release
    POST /ajax_proc  function=2  x1=<x> y1=<y> session=<id>  touch down
    POST /ajax_proc  function=3  x1=<x> y1=<y> session=<id>  touch up

    Home 1  Menu 2  Button3 3  Help 4  Enter 5  Exit 6  Function 7  Trigger 8
    TerminalSwitch 9  Output 10

A press is NOT a socket command, so it does not abort a running trigger model -- but a readback
is, so never poll the result from the same host thread that is holding a statement open.

Say in any writeup that this is an INJECTED press, not a finger.

    python3 -u -I tools/panel_key.py --key exit
    python3 -u -I tools/panel_key.py --key exit --repeat 2 --shot /tmp/dlg.png
    python3 -u -I tools/panel_key.py --touch 503,272      (a coordinate from a LIVE grab)
"""
import argparse
import sys
import time
import urllib.request

sys.path.insert(0, __file__.rsplit('/', 1)[0])
from screenshot import HOST, USER, PASSWORD, start_session, grab_tga, tga_to_png  # noqa: E402

KEYS = {'home': 1, 'menu': 2, 'button3': 3, 'help': 4, 'enter': 5, 'exit': 6,
        'function': 7, 'trigger': 8, 'terminal': 9, 'output': 10}


def post(op, host, fields):
    body = '&'.join('%s=%s' % kv for kv in fields).encode()
    req = urllib.request.Request(
        'http://%s/ajax_proc' % host, data=body,
        headers={'Content-Type': 'application/x-www-form-urlencoded',
                 'Cache-Control': 'no-cache'})
    return op.open(req, timeout=10).read().decode(errors='replace')


def press(op, host, session, button, hold=0.08):
    """Down then up. A press with no release leaves the key held, and the firmware then
    repeats it."""
    post(op, host, [('function', 7), ('button', button), ('session', session)])
    time.sleep(hold)
    post(op, host, [('function', 8), ('button', button), ('session', session)])


def touch(op, host, session, x, y, hold=0.08):
    post(op, host, [('function', 2), ('x1', x), ('y1', y), ('session', session)])
    time.sleep(hold)
    post(op, host, [('function', 3), ('x1', x), ('y1', y), ('session', session)])


def shot(op, host, session, path):
    """The framebuffer, through the SAME session: a second session freezes the first's."""
    tga_to_png(grab_tga(session, op, host), path)
    return path


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--key', choices=sorted(KEYS))
    ap.add_argument('--touch', help='x,y from a LIVE grab, never from an old one')
    ap.add_argument('--repeat', type=int, default=1)
    ap.add_argument('--shot', help='write a grab here after the press')
    ap.add_argument('--before', help='write a grab here before the press')
    ap.add_argument('--host', default=HOST)
    a = ap.parse_args()
    if not a.key and not a.touch:
        ap.error('--key or --touch')

    session, op = start_session(a.host, USER, PASSWORD)
    print('session: %d' % session)
    if a.before:
        print('before : %s' % shot(op, a.host, session, a.before))
    for i in range(a.repeat):
        if a.key:
            press(op, a.host, session, KEYS[a.key])
            print('press  : %s (%d of %d)' % (a.key, i + 1, a.repeat))
        else:
            x, y = (int(v) for v in a.touch.split(','))
            touch(op, a.host, session, x, y)
            print('touch  : %d,%d (%d of %d)' % (x, y, i + 1, a.repeat))
        time.sleep(0.5)
    if a.shot:
        time.sleep(0.6)
        print('after  : %s' % shot(op, a.host, session, a.shot))
    return 0


if __name__ == '__main__':
    sys.exit(main())
