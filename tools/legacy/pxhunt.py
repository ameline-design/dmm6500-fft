#!/usr/bin/env python3
"""Find a setpixel target whose pixel buffer is actually addressable.

Error 1130 "Parameter x, expected value from 0 to -1" on an OBJ_IMAGE means the
bounds check derived max_x = width-1 = -1, i.e. the object reports zero pixel
width. The object id is accepted (no 1703), so the remaining question is which
object exposes real pixel dimensions.

Hypotheses tested here, in order of cheapness:
  H1  x/y are 0-based and something else is off -> try (0,0) explicitly
  H2  the image must be shown/realised before its buffer exists -> flush, wait
  H3  argument order is (img, y, x, colour) or includes a plane/index
  H4  OBJ_GRAPH / OBJ_RECT / built-in screens expose a pixel buffer
  H5  a *larger* declared image, or one drawn at 1:1, reports nonzero width
Each probe reports the exact event-log line, which is the real signal.
"""
import base64
import struct
import sys
import time
import zlib

sys.path.insert(0, __file__.rsplit('/', 1)[0])
from dmmrun import DMM, clear_dead_sockets   # noqa: E402


def make_png_b64(w, h, rgb=(0, 0, 60)):
    raw = b''.join(b'\x00' + bytes(rgb) * w for _ in range(h))

    def chunk(tag, payload):
        return (struct.pack('>I', len(payload)) + tag + payload
                + struct.pack('>I', zlib.crc32(tag + payload) & 0xffffffff))

    png = (b'\x89PNG\r\n\x1a\n'
           + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
           + chunk(b'IDAT', zlib.compress(raw, 6))
           + chunk(b'IEND', b''))
    return base64.b64encode(png).decode()


def upload(d, name, w, h):
    b64 = make_png_b64(w, h)
    d.send(f'loadimage {name}')
    for i in range(0, len(b64), 900):
        d.send(b64[i:i + 900])
    d.send('endimage')
    time.sleep(1.0)


def probe(d, label, code):
    """Run code, return the first event-log line (or 'clean')."""
    d.q('eventlog.clear()')
    d.q(code, timeout=60)
    msg = d.q('if eventlog.getcount() > 0 then print(eventlog.next()) '
              'else print("clean") end', timeout=40)
    d.q('eventlog.clear()')
    txt = str(msg)
    if '\t' in txt:
        txt = txt.split('\t')[0] + ' ' + txt.split('\t')[1]
    print(f'  {label:34} -> {txt}')
    return txt


def main():
    clear_dead_sockets()
    d = DMM(timeout=60)
    d.q('reset()')
    d.q('display.lightstate = display.STATE_LCD_100')
    d.q('eventlog.clear()')
    d.q('scr = display.create(display.ROOT, display.OBJ_SCREEN, "PX HUNT") '
        'display.changescreen(scr)')

    print('== H1/H2: image object, coordinate origin and realisation ==')
    upload(d, 'cv', 600, 300)
    d.q('img = display.create(scr, display.OBJ_IMAGE, 100, 90, "cv")')
    probe(d, 'setpixel(img,0,0,red)', 'display.setpixel(img,0,0,0xFF0000)')
    probe(d, 'flush then setpixel(img,0,0)',
          'display.flush() delay(0.3) display.setpixel(img,0,0,0xFF0000)')
    probe(d, 'setstate ENABLE then setpixel',
          'display.setstate(img, display.STATE_ENABLE) delay(0.3) '
          'display.setpixel(img,5,5,0xFF0000)')

    print('== H3: argument shape ==')
    probe(d, 'setpixel(img,1,1,255,0,0)', 'display.setpixel(img,1,1,255,0,0)')
    probe(d, 'setpixel(img,0,1,1,red) (plane?)',
          'display.setpixel(img,0,1,1,0xFF0000)')
    probe(d, 'getpixel(img,0,0)',
          'local ok,v = pcall(function() return display.getpixel(img,0,0) end) '
          'print("getpixel:", ok, tostring(v))')

    print('== H4: other object types ==')
    d.q('rect = display.create(scr, display.OBJ_RECT, 20, 250, 200, 100)')
    probe(d, 'OBJ_RECT', 'display.setpixel(rect,1,1,0xFF0000)')
    d.q('grf = display.create(scr, display.OBJ_GRAPH, 300, 250, 300, 150)')
    probe(d, 'OBJ_GRAPH', 'display.setpixel(grf,1,1,0xFF0000)')
    probe(d, 'SCREEN_HOME', 'display.setpixel(display.SCREEN_HOME,1,1,0xFF0000)')
    probe(d, 'scr (custom screen)', 'display.setpixel(scr,1,1,0xFF0000)')
    probe(d, 'SCREEN_GRAPH', 'display.setpixel(display.SCREEN_GRAPH,1,1,0xFF0000)')

    print('== H5: does the image report a size at all? ==')
    for expr in ('display.getvalue(img)',
                 'display.format(0,"",display.NFORMAT_INTEGER,6)'):
        r = d.q(f'local ok,v = pcall(function() return {expr} end) '
                f'print(ok, tostring(v))', timeout=40)
        print(f'  {expr:34} -> {r}')
    d.q('eventlog.clear()')
    d.close()
    return 0


if __name__ == '__main__':
    sys.exit(main())
