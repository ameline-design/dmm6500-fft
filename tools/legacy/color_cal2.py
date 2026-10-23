#!/usr/bin/env python3
"""Decode display.setpixel()'s colour argument - SAFE, low-volume version.

The first attempt crashed the instrument: it queued ~144 000 setpixel calls
before flushing. Evidence says setpixel is fire-and-forget IPC to the display
processor (10.9 us/call is too fast for a round trip, flush measures 0.0000 s,
and we have previously seen "1706 Message dropped from display queue"), so a
large unflushed batch can overrun the queue and panic the display CPU.

This version therefore:
  * uses a small canvas (240x180)
  * writes at most ~600 pixels per band
  * flushes after EVERY band and sleeps to let the queue drain
  * pings the instrument between bands and aborts at the first sign of trouble

Hypothesis under test: the value is 32-bit with an alpha channel, so a value with
a zero top byte (0x00FF00) is fully transparent - which is exactly why "green"
rendered as the untouched background. ARGB predicts 0xFF00FF00 shows green.
"""
import base64
import struct
import sys
import time
import zlib

sys.path.insert(0, __file__.rsplit('/', 1)[0])
from dmmrun import DMM, clear_dead_sockets   # noqa: E402
from screenshot import capture               # noqa: E402
from color_cal import read_png               # noqa: E402

W, H = 240, 180
IMG_X, IMG_Y = 60, 60
BAND_STEP = 4          # write every 4th pixel in x -> 60 writes per row
ROWS_PER_BAND = 6      # -> ~360 writes per band, well under any queue limit

TESTS = [
    ('opaque green  ARGB', 0xFF00FF00),
    ('opaque red    ARGB', 0xFFFF0000),
    ('opaque blue   ARGB', 0xFF0000FF),
    ('opaque white  ARGB', 0xFFFFFFFF),
    ('green<<8     RGBA', 0x00FF00FF),
    ('red<<8       RGBA', 0xFF0000FF),
    ('bare green        ', 0x0000FF00),
    ('bare red          ', 0x00FF0000),
    ('all bits set      ', 0xFFFFFFFF),
    ('opaque black  ARGB', 0xFF000000),
]


def png_b64(w, h, rgb=(0, 0, 0)):
    raw = b''.join(b'\x00' + bytes(rgb) * w for _ in range(h))

    def ch(t, p):
        return (struct.pack('>I', len(p)) + t + p
                + struct.pack('>I', zlib.crc32(t + p) & 0xffffffff))

    return base64.b64encode(
        b'\x89PNG\r\n\x1a\n'
        + ch(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
        + ch(b'IDAT', zlib.compress(raw, 6))
        + ch(b'IEND', b'')).decode()


def main():
    clear_dead_sockets()
    d = DMM(timeout=90)
    d.q('reset()')
    d.q('display.lightstate = display.STATE_LCD_100')
    d.q('eventlog.clear()')
    d.q('scr = display.create(display.ROOT, display.OBJ_SCREEN, "COLOR CAL 2") '
        'display.changescreen(scr)')

    b64 = png_b64(W, H)
    d.send('loadimage cc2')
    for i in range(0, len(b64), 900):
        d.send(b64[i:i + 900])
    d.send('endimage')
    time.sleep(1.5)
    print('canvas:', d.q(f'cim = display.create(scr, display.OBJ_IMAGE, {IMG_X}, {IMG_Y}, '
                         f'"cc2", {W}, {H}) print("id=" .. tostring(cim))', timeout=60))

    band = H // len(TESTS)
    ok = True
    for i, (label, val) in enumerate(TESTS):
        y0 = i * band
        y1 = min(y0 + ROWS_PER_BAND - 1, H - 1)
        # ~360 writes, then flush immediately and let the display drain.
        r = d.q(f'local sp = display.setpixel '
                f'for y = {y0}, {y1} do '
                f'  for x = 0, {W - 1}, {BAND_STEP} do sp(cim, x, y, {val}) end '
                f'end '
                f'display.flush(cim) print("b{i}")', timeout=90)
        alive = d.q('print("P")', timeout=25) == 'P'
        log = d.q('if eventlog.getcount()>0 then print(eventlog.next()) else print("-") end',
                  timeout=30)
        d.q('eventlog.clear()', timeout=20)
        print(f'  band {i} {label} {val:#010x} -> {r}  alive={alive}  log={log}')
        if not alive:
            print('  ABORTING: instrument stopped responding')
            ok = False
            break
        time.sleep(0.5)          # let the display queue drain

    if not ok:
        return 2

    time.sleep(1.2)
    path = '/tmp/color_cal2.png'
    capture(path)
    w, h, rows = read_png(path)
    print(f'\nscreenshot {w}x{h}')
    print(f'{"band":>4} {"meaning":>20} {"value":>12}   actual RGB')
    sx = IMG_X + 4                       # a written column (x=4 is a multiple of 4)
    for i, (label, val) in enumerate(TESTS):
        py = IMG_Y + i * band + 1
        if py >= h:
            continue
        off = sx * 3
        r, g, b = rows[py][off], rows[py][off + 1], rows[py][off + 2]
        print(f'{i:>4} {label:>20} {val:#010x}   #{r:02X}{g:02X}{b:02X}')

    off = (IMG_X + 1) * 3               # x=1 is never written (step 4)
    py = IMG_Y + 1
    print(f'\nuntouched pixel: #{rows[py][off]:02X}{rows[py][off+1]:02X}{rows[py][off+2]:02X}'
          f'   <- initial buffer colour')
    d.close()
    return 0


if __name__ == '__main__':
    sys.exit(main())
