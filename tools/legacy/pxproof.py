#!/usr/bin/env python3
"""Prove out display.setpixel: does it work, on what object, and how fast?

Determines whether the undocumented display.setpixel can be used as a fast
plotting path for the spectrum trace, instead of buffer.write.reading() +
the built-in graph (measured at ~80 us/point, 21-24% of a frame).

Draws a sine trace into an image object and screenshots it, so "it worked" is
demonstrated visually rather than inferred from the absence of an error.
"""
import base64
import struct
import sys
import time
import zlib

sys.path.insert(0, __file__.rsplit('/', 1)[0])
from dmmrun import DMM, clear_dead_sockets   # noqa: E402
from screenshot import capture               # noqa: E402

W, H = 600, 300


def make_png_b64(w, h, rgb=(0, 0, 40)):
    """Minimal solid-colour 24-bit PNG, base64 encoded for `loadimage`."""
    raw = b''.join(b'\x00' + bytes(rgb) * w for _ in range(h))

    def chunk(tag, payload):
        return (struct.pack('>I', len(payload)) + tag + payload
                + struct.pack('>I', zlib.crc32(tag + payload) & 0xffffffff))

    png = (b'\x89PNG\r\n\x1a\n'
           + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
           + chunk(b'IDAT', zlib.compress(raw, 6))
           + chunk(b'IEND', b''))
    return base64.b64encode(png).decode()


def log(d, label):
    msg = d.q('if eventlog.getcount() > 0 then print(eventlog.next()) '
              'else print("clean") end', timeout=40)
    print(f'  {label:14}: {msg}')
    d.q('eventlog.clear()')
    return msg


def main():
    clear_dead_sockets()
    d = DMM(timeout=60)
    d.q('reset()')
    d.q('display.lightstate = display.STATE_LCD_100')
    d.q('eventlog.clear()')
    d.q('scr = display.create(display.ROOT, display.OBJ_SCREEN, "SETPIXEL PROOF") '
        'display.changescreen(scr)')

    print('loading canvas image...')
    b64 = make_png_b64(W, H)
    d.send('loadimage canvas')
    for i in range(0, len(b64), 900):
        d.send(b64[i:i + 900])
    d.send('endimage')
    time.sleep(1.2)
    log(d, 'loadimage')

    r = d.q('local ok,id = pcall(function() return '
            'display.create(scr, display.OBJ_IMAGE, 100, 90, "canvas") end) '
            'if ok and id then img = id print("id=" .. tostring(id)) '
            'else print("CREATE_FAIL " .. tostring(id)) end', timeout=60)
    print(f'  image object  : {r}')
    log(d, 'create')
    if not r or 'id=' not in str(r):
        print('cannot create image object - stopping')
        d.close()
        return 1

    d.q(f'display.setpixel(img, 10, 10, 0xFF0000)', timeout=40)
    accepted = log(d, 'single pixel')

    bench = ('timer.cleartime() '
             'for x = 1, 2000 do '
             '  display.setpixel(img, math.mod(x, 600) + 1, 50, 0x00FF00) end '
             'local t1 = timer.gettime() '
             'timer.cleartime() display.flush() local t2 = timer.gettime() '
             'print(string.format("2000px=%.4fs (%.1fus/px)  flush=%.4fs", '
             't1, t1/2000*1e6, t2))')
    print(f'  throughput    : {d.q(bench, timeout=240)}')
    log(d, 'bench')

    draw = ('for x = 1, 600 do '
            '  local y = math.floor(150 + 120*math.sin(2*math.pi*x/150)) '
            '  display.setpixel(img, x, y, 0x00FF66) end '
            'display.flush() print("trace drawn")')
    print(f'  draw trace    : {d.q(draw, timeout=240)}')
    log(d, 'draw')

    time.sleep(1.5)
    print('  screenshot    :', capture('/tmp/px_proof.png'))
    print('  verdict       :', 'pixel writes accepted'
          if 'clean' in str(accepted) or 'ACCEPT' in str(accepted)
          else f'rejected -> {accepted}')
    d.close()
    return 0


if __name__ == '__main__':
    sys.exit(main())
