#!/usr/bin/env python3
"""Confirm the setpixel recipe visually and measure its throughput.

THE RECIPE (undocumented; not in either supplied display doc):

    display.create(parent, display.OBJ_IMAGE, x, y, "name", WIDTH, HEIGHT)
    display.setpixel(imgid, x, y, 0xRRGGBB)     -- 0-based coords
    display.flush()

The trailing WIDTH/HEIGHT args are what allocate the addressable pixel buffer.
Omit them and every write fails with
    1130 Parameter x/y, expected value from 0 to -1
because the bounds check derives max = width-1 = -1.

Also times the two candidate plot paths so the app can pick the faster one.
"""
import base64
import struct
import sys
import time
import zlib

sys.path.insert(0, __file__.rsplit('/', 1)[0])
from dmmrun import DMM, clear_dead_sockets   # noqa: E402
from screenshot import capture               # noqa: E402

W, H = 600, 260


def png_b64(w, h, rgb=(0, 0, 40)):
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
    d = DMM(timeout=60)
    d.q('reset()')
    d.q('display.lightstate = display.STATE_LCD_100')
    d.q('eventlog.clear()')
    d.q('scr = display.create(display.ROOT, display.OBJ_SCREEN, "SETPIXEL WORKS") '
        'display.changescreen(scr)')

    b64 = png_b64(W, H)
    d.send('loadimage cvx')
    for i in range(0, len(b64), 900):
        d.send(b64[i:i + 900])
    d.send('endimage')
    time.sleep(1.0)

    # The winning form: explicit width/height.
    r = d.q(f'img = display.create(scr, display.OBJ_IMAGE, 100, 100, "cvx", {W}, {H}) '
            f'print("id=" .. tostring(img))', timeout=45)
    print('image object   :', r)
    d.q('eventlog.clear()')

    d.q('display.setpixel(img, 0, 0, 0xFF0000)', timeout=40)
    print('single pixel   :', d.q('if eventlog.getcount()>0 then print(eventlog.next()) '
                                  'else print("ACCEPTED") end', timeout=40))
    d.q('eventlog.clear()')

    # Throughput of raw pixel writes.
    bench = ('timer.cleartime() '
             f'for x = 0, {W - 1} do display.setpixel(img, x, 10, 0x00FF00) end '
             'local t = timer.gettime() '
             f'print(string.format("%d px in %.4f s = %.1f us/px", {W}, t, t/{W}*1e6))')
    print('throughput     :', d.q(bench, timeout=180))

    # Time a flush separately - is the paint deferred?
    print('flush cost     :', d.q('timer.cleartime() display.flush() '
                                  'print(string.format("%.4f s", timer.gettime()))', timeout=60))

    # Draw a real spectrum-like trace: a decaying sine, one pixel per column.
    draw = (f'timer.cleartime() '
            f'for x = 0, {W - 1} do '
            f'  local v = math.sin(2*math.pi*x/90) * math.exp(-x/{W * 0.8}) '
            f'  local y = math.floor({H // 2} + v * {H // 2 - 6}) '
            f'  display.setpixel(img, x, y, 0x00FF66) '
            f'end '
            f'display.flush() '
            f'print(string.format("trace %d cols in %.4f s", {W}, timer.gettime()))')
    print('draw trace     :', d.q(draw, timeout=180))
    print('eventlog       :', d.q('if eventlog.getcount()>0 then print(eventlog.next()) '
                                  'else print("clean") end', timeout=40))

    time.sleep(1.5)
    print('screenshot     :', capture('/tmp/px_works.png'))
    d.q('eventlog.clear()')
    d.close()
    return 0


if __name__ == '__main__':
    sys.exit(main())
