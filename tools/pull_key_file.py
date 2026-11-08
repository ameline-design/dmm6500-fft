#!/usr/bin/env python3
"""Read a file off the instrument's USB key over the control socket.

The counterpart to push_tspa.py, and it exists for one reason: a screen capture saved from
the front panel freezes a transient the LXI grab cannot catch -- at 16,384 samples and up the
frame timer starves the web server and every HTTP grab times out.

Bytes come back hex, 400 at a time, because the control socket is line based and the reply
has to stay inside one line.

"r" FIRST, and "rb" only as a fallback: measured, this firmware refuses "rb" with event -224,
Illegal parameter value, which raises a dialog on the glass. The file API not raising does not
mean it stays quiet -- io.open returns nil AND posts.

    python3 -u -I tools/pull_key_file.py --name /usb1/img1108_001033.png --out /tmp/x.png
"""
import argparse
import binascii
import os
import sys
import time

sys.path.insert(0, os.path.join('/Users/ameline/Work/GitHub/dmm6500-serial-decode', 'tools'))
from dmmrun import DMM          # noqa: E402

CHUNK = 400                     # 800 hex characters, inside the one-line reply budget


def ask(d, cmd, tag, tries=6, timeout=90):
    r = None
    for _ in range(tries):
        r = d.q(cmd, timeout=timeout)
        if r is not None and str(r).startswith(tag):
            return str(r)
        time.sleep(1)
    raise SystemExit('DESYNC(%s) last=%r' % (tag, r))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--name', required=True)
    ap.add_argument('--out', required=True)
    a = ap.parse_args()
    d = DMM(recover=False, timeout=180)
    try:
        print('exists :', ask(d, 'print("X|"..tostring(fs.is_file("%s")))' % a.name, 'X|'))
        mode = None
        for m in ('r', 'rb'):
            r = ask(d, 'do local f = io.open("%s", "%s") '
                       'print("M|"..tostring(f ~= nil)) '
                       'if f ~= nil then RF = f end end' % (a.name, m), 'M|')
            print('  mode %-2s -> %s' % (m, r.split('|')[1]))
            if r.split('|')[1] == 'true':
                mode = m
                break
        if mode is None:
            raise SystemExit('io.open refused every mode; the file API never raises, so '
                             'there is nothing more to read out of it')
        out = bytearray()
        while True:
            r = ask(d, 'do local s = RF:read(%d) '
                       'if s == nil or string.len(s) == 0 then print("H|") else '
                       'print("H|"..string.gsub(s, "(.)", function(c) '
                       'return string.format("%%02X", string.byte(c)) end)) end end' % CHUNK,
                    'H|', timeout=120)
            hexs = r[2:].strip()
            if hexs == '':
                break
            out += binascii.unhexlify(hexs)
            if len(out) % 20000 < CHUNK:
                print('  %d bytes' % len(out))
        ask(d, 'do RF:close() RF = nil print("C|closed") end', 'C|')
        with open(a.out, 'wb') as fh:
            fh.write(out)
        print('wrote %s (%d bytes)' % (a.out, len(out)))
    finally:
        d.close()


if __name__ == '__main__':
    main()
