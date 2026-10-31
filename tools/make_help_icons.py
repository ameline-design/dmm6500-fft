#!/usr/bin/env python3
"""Generate bright variants of the button icons, for use as help-screen illustrations.

The button icons are drawn for a dark button face: measured, they are opaque RGB with a
#282828 background and #9D9D9D line work. On a help screen, whose background is black, that
reads as a dark tile with mid-grey content against white body text -- the icon is the hardest
thing on the screen to see, which is the opposite of what an illustration is for.

There is no alpha, so nothing placed behind them helps. This remaps the two levels instead:

    out = (in - 40) * 255 / (157 - 40), clamped

which sends the background to black, so the tile disappears into the screen, and the line
work to white, so it matches the body text. Anti-aliased edges in between scale with it, so
the glyph keeps its shape.

Writes assets/help<name>.png beside the originals. The packager embeds whatever
`fftsa.img_* = "name"` declares and refuses a declaration with no file or a file nothing
declares, so adding one of these means declaring it in the same change.

    python3 -I tools/make_help_icons.py
"""
import os
import struct
import sys
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASSETS = os.path.join(ROOT, 'assets')

LO, HI = 40, 157          # the measured background and line-work levels
PAIRS = [('fftcog.png', 'helpcog.png'),
         ('fftlockc.png', 'helplockc.png'),
         ('fftlocko.png', 'helplocko.png')]


def read_png(path):
    d = open(path, 'rb').read()
    if d[:8] != b'\x89PNG\r\n\x1a\n':
        raise SystemExit('%s is not a PNG' % path)
    w, h, depth, ctype = struct.unpack('>IIBB', d[16:26])
    if depth != 8 or ctype != 2:
        raise SystemExit('%s is %d-bit type %d; this expects 8-bit RGB' % (path, depth, ctype))
    idat, i = b'', 8
    while i < len(d):
        ln = struct.unpack('>I', d[i:i + 4])[0]
        if d[i + 4:i + 8] == b'IDAT':
            idat += d[i + 8:i + 8 + ln]
        i += 12 + ln
    raw = zlib.decompress(idat)
    # Filter type 0 on every scanline is what png_icon() in package_tspa.py writes and what
    # these were produced by; anything else would need the full unfilter.
    stride = w * 3 + 1
    rows = []
    for y in range(h):
        if raw[y * stride] != 0:
            raise SystemExit('%s scanline %d uses filter %d; only 0 is handled'
                             % (path, y, raw[y * stride]))
        rows.append(bytearray(raw[y * stride + 1:(y + 1) * stride]))
    return w, h, rows


def write_png(path, w, h, rows):
    raw = bytearray()
    for r in rows:
        raw.append(0)
        raw.extend(r)

    def chunk(typ, data):
        return (struct.pack('>I', len(data)) + typ + data
                + struct.pack('>I', zlib.crc32(typ + data) & 0xffffffff))

    png = b'\x89PNG\r\n\x1a\n'
    png += chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
    png += chunk(b'IDAT', zlib.compress(bytes(raw), 9))
    png += chunk(b'IEND', b'')
    open(path, 'wb').write(png)


def main():
    span = float(HI - LO)
    for src, dst in PAIRS:
        sp = os.path.join(ASSETS, src)
        w, h, rows = read_png(sp)
        for r in rows:
            for i in range(len(r)):
                v = int(round((r[i] - LO) * 255.0 / span))
                r[i] = 0 if v < 0 else (255 if v > 255 else v)
        dp = os.path.join(ASSETS, dst)
        write_png(dp, w, h, rows)
        print('  %-14s -> %-14s %dx%d  %d bytes'
              % (src, dst, w, h, os.path.getsize(dp)))


if __name__ == '__main__':
    main()
