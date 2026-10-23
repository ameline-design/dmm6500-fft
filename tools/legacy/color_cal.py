#!/usr/bin/env python3
"""Determine display.setpixel()'s colour encoding empirically.

Symptom: writing 0x00FF00 (which should be pure green) renders as black, and the
canvas allocated by the 7-argument display.create() starts mid-grey rather than
showing the uploaded PNG's pixels. So neither the colour format nor the initial
buffer contents match the obvious assumption.

Method: paint horizontal bands with a set of candidate colour values, screenshot
the panel over LXI, and read the ACTUAL rgb of each band back out of the PNG.
That converts guesswork into a lookup table.
"""
import base64
import struct
import sys
import time
import zlib

sys.path.insert(0, __file__.rsplit('/', 1)[0])
from dmmrun import DMM, clear_dead_sockets   # noqa: E402
from screenshot import capture               # noqa: E402

W, H = 720, 400
IMG_X, IMG_Y = 40, 45          # canvas origin on the 800x480 panel

# Candidate values, chosen to discriminate between encodings:
#   0xRRGGBB      -> pure R/G/B bands appear in their own colour
#   8-bit index   -> only the low byte matters, so 0x00FF00 == 0x000000
#   RGB565        -> 0x07E0 is green, 0xF800 red, 0x001F blue
CANDIDATES = [
    ('0xFFFFFF', 0xFFFFFF),
    ('0xFF0000', 0xFF0000),
    ('0x00FF00', 0x00FF00),
    ('0x0000FF', 0x0000FF),
    ('0x000000', 0x000000),
    ('0x0000FF_low', 0x0000FF),
    ('0xFF (255)', 0xFF),
    ('0x1F (31)', 0x1F),
    ('0x07E0 565g', 0x07E0),
    ('0xF800 565r', 0xF800),
    ('0x001F 565b', 0x001F),
    ('0xFFFF', 0xFFFF),
    ('1', 1),
    ('2', 2),
    ('4', 4),
    ('8', 8),
    ('16', 16),
    ('32', 32),
    ('64', 64),
    ('128', 128),
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


def read_png(path):
    """Minimal PNG reader for our own 8-bit truecolour screenshots."""
    data = open(path, 'rb').read()
    pos = 8
    w = h = None
    idat = b''
    while pos < len(data):
        ln = struct.unpack('>I', data[pos:pos + 4])[0]
        tag = data[pos + 4:pos + 8]
        payload = data[pos + 8:pos + 8 + ln]
        if tag == b'IHDR':
            w, h = struct.unpack('>II', payload[:8])
        elif tag == b'IDAT':
            idat += payload
        elif tag == b'IEND':
            break
        pos += 12 + ln
    raw = zlib.decompress(idat)
    stride = w * 3
    rows = []
    prev = bytearray(stride)
    p = 0
    for _ in range(h):
        f = raw[p]
        p += 1
        line = bytearray(raw[p:p + stride])
        p += stride
        if f == 1:
            for i in range(3, stride):
                line[i] = (line[i] + line[i - 3]) & 0xFF
        elif f == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif f == 3:
            for i in range(stride):
                a = line[i - 3] if i >= 3 else 0
                line[i] = (line[i] + ((a + prev[i]) >> 1)) & 0xFF
        elif f == 4:
            for i in range(stride):
                a = line[i - 3] if i >= 3 else 0
                b = prev[i]
                c = prev[i - 3] if i >= 3 else 0
                pp = a + b - c
                pa, pb, pc = abs(pp - a), abs(pp - b), abs(pp - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 0xFF
        rows.append(bytes(line))
        prev = line
    return w, h, rows


def main():
    clear_dead_sockets()
    d = DMM(timeout=90)
    d.q('reset()')
    d.q('display.lightstate = display.STATE_LCD_100')
    d.q('eventlog.clear()')
    d.q('scr = display.create(display.ROOT, display.OBJ_SCREEN, "COLOR CAL") '
        'display.changescreen(scr)')

    b64 = png_b64(W, H)
    d.send('loadimage ccv')
    for i in range(0, len(b64), 900):
        d.send(b64[i:i + 900])
    d.send('endimage')
    time.sleep(1.5)
    print('canvas:', d.q(f'cim = display.create(scr, display.OBJ_IMAGE, {IMG_X}, {IMG_Y}, '
                         f'"ccv", {W}, {H}) print("id=" .. tostring(cim))', timeout=60))

    band = H // len(CANDIDATES)
    print(f'painting {len(CANDIDATES)} bands of {band} px ...')
    for i, (label, val) in enumerate(CANDIDATES):
        y0 = i * band
        y1 = min(y0 + band - 1, H - 1)
        r = d.q(f'local sp=display.setpixel '
                f'for y = {y0}, {y1} do for x = 0, {W - 1}, 2 do sp(cim, x, y, {val}) end end '
                f'print("band{i}")', timeout=240)
        print(f'  band {i:2} {label:14} = {val:#08x} -> {r}')
    d.q('display.flush(cim)', timeout=60)
    time.sleep(1.5)

    path = '/tmp/color_cal.png'
    capture(path)
    w, h, rows = read_png(path)
    print(f'\nscreenshot {w}x{h}; sampling each band at panel x={IMG_X + W // 2}')
    sx = IMG_X + W // 2
    print(f'{"band":>4} {"requested":>14} {"value":>10}   actual RGB')
    for i, (label, val) in enumerate(CANDIDATES):
        py = IMG_Y + i * band + band // 2
        if py >= h:
            continue
        off = sx * 3
        r, g, b = rows[py][off], rows[py][off + 1], rows[py][off + 2]
        print(f'{i:>4} {label:>14} {val:#010x}   #{r:02X}{g:02X}{b:02X}')

    # Also sample an untouched corner to learn the initial buffer colour.
    py = IMG_Y + 2
    off = (IMG_X + 1) * 3
    print(f'\nuntouched canvas pixel: #{rows[py][off]:02X}{rows[py][off+1]:02X}'
          f'{rows[py][off+2]:02X}  (this is what a fresh buffer contains)')
    print('log:', d.q('if eventlog.getcount()>0 then print(eventlog.next()) '
                      'else print("clean") end', timeout=40))
    d.close()
    return 0


if __name__ == '__main__':
    sys.exit(main())
