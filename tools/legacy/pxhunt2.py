#!/usr/bin/env python3
"""Second pass at a fast draw path, guided by the firmware object-type table.

The firmware's display object-type table lists types absent from both supplied
docs: WINDOW, FAST_TEXT, STATIC_LABEL, SEP, ITEM_LIST. It also confirms IMAGE is
the only bitmap-ish type, which matches `pixel` sitting beside `image` in the
attribute table.

Earlier result: setpixel on an OBJ_IMAGE gives
  1130 Parameter x, expected value from 0 to -1
i.e. the id IS accepted (no 1717 type rejection) but the object reports zero
pixel width. So the question is how to get an image whose buffer is addressable.

Probes:
  A  undocumented OBJ_* type ids exist? (probe display.OBJ_WINDOW etc.)
  B  image created with explicit width/height args
  C  image drawn from a PNG whose dimensions are declared differently
  D  setpixel BEFORE vs AFTER the image is realised on a visible screen
  E  1-based vs 0-based, and whether y is bounded the same way
"""
import base64
import struct
import sys
import time
import zlib

sys.path.insert(0, __file__.rsplit('/', 1)[0])
from dmmrun import DMM, clear_dead_sockets   # noqa: E402


def png_b64(w, h, rgb=(0, 0, 60)):
    raw = b''.join(b'\x00' + bytes(rgb) * w for _ in range(h))

    def ch(t, p):
        return (struct.pack('>I', len(p)) + t + p
                + struct.pack('>I', zlib.crc32(t + p) & 0xffffffff))

    return base64.b64encode(
        b'\x89PNG\r\n\x1a\n'
        + ch(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
        + ch(b'IDAT', zlib.compress(raw, 6))
        + ch(b'IEND', b'')).decode()


def upload(d, name, w, h):
    b64 = png_b64(w, h)
    d.send(f'loadimage {name}')
    for i in range(0, len(b64), 900):
        d.send(b64[i:i + 900])
    d.send('endimage')
    time.sleep(1.0)


def probe(d, label, code, timeout=45):
    d.q('eventlog.clear()')
    out = d.q(code, timeout=timeout)
    msg = d.q('if eventlog.getcount() > 0 then print(eventlog.next()) '
              'else print("CLEAN") end', timeout=40)
    t = str(msg)
    if '\t' in t:
        parts = t.split('\t')
        t = f'{parts[0]} {parts[1]}'
    mark = '   <<< ACCEPTED' if 'CLEAN' in t else ''
    extra = f'   [{out}]' if out and out != 'None' else ''
    print(f'  {label:38} -> {t}{mark}{extra}')
    d.q('eventlog.clear()')
    return t


def main():
    clear_dead_sockets()
    d = DMM(timeout=60)
    d.q('reset()')
    d.q('display.lightstate = display.STATE_LCD_100')
    d.q('eventlog.clear()')

    print('== A: do the undocumented OBJ_* constants exist? ==')
    for name in ('OBJ_WINDOW', 'OBJ_FAST_TEXT', 'OBJ_STATIC_LABEL', 'OBJ_SEP',
                 'OBJ_ITEM_LIST', 'OBJ_SWIPE_CUSTOM', 'OBJ_POPUP_MENU'):
        print(f'  display.{name:18} -> {d.q(f"print(tostring(display.{name}))")}')

    d.q('scr = display.create(display.ROOT, display.OBJ_SCREEN, "PX HUNT 2") '
        'display.changescreen(scr)')

    print('\n== B/D: image object, realisation order, coordinate base ==')
    upload(d, 'cv2', 400, 200)
    d.q('img = display.create(scr, display.OBJ_IMAGE, 60, 80, "cv2")')
    probe(d, 'setpixel(img,0,0)', 'display.setpixel(img,0,0,0xFF0000)')
    probe(d, 'after flush+delay',
          'display.flush() delay(0.5) display.setpixel(img,0,0,0xFF0000)')
    probe(d, 'y first: setpixel(img,0,0) again',
          'display.setpixel(img,1,0,0xFF0000)')
    probe(d, 'negative probe setpixel(img,-1,0)',
          'display.setpixel(img,-1,0,0xFF0000)')

    print('\n== C: image created with explicit size args ==')
    for extra in ('60, 300, "cv2", 400, 200', '60, 300, "cv2", 400',
                  '60, 300, "cv2", 0, 0, 400, 200'):
        r = d.q(f'local ok,id = pcall(function() return '
                f'display.create(scr, display.OBJ_IMAGE, {extra}) end) '
                f'if ok and id then img2 = id print("id=" .. tostring(id)) '
                f'else print("FAIL") end', timeout=45)
        if r and 'id=' in str(r):
            probe(d, f'create({extra[:22]}...) setpixel', 'display.setpixel(img2,0,0,0xFF0000)')
        else:
            print(f'  create({extra[:30]:32}) -> {r}')
        d.q('eventlog.clear()')

    print('\n== E: what does the image report about itself? ==')
    for expr in ('display.getvalue(img)', 'display.getpixel(img,0,0)'):
        print(f'  {expr:30} -> '
              f'{d.q(f"local ok,v = pcall(function() return {expr} end) print(ok, tostring(v))", timeout=40)}')
    d.q('eventlog.clear()')
    d.close()
    return 0


if __name__ == '__main__':
    sys.exit(main())
