#!/usr/bin/env python3
"""Moving sine wave at 750x500 - bright green on near-black, 2 px thick.

Measures the real achievable frame rate for the spectrum app's plot path.

Two visibility fixes over the first attempt:
  - canvas background is near-black (was mid-grey, which washed out the trace)
  - trace is full-brightness green and 2 px tall (the panel's pixels are tiny)

Animation technique: remember the previous y per column and erase only that,
so a frame costs ~2*W writes instead of W*H.
"""
import base64
import struct
import sys
import time
import zlib

sys.path.insert(0, __file__.rsplit('/', 1)[0])
from dmmrun import DMM, clear_dead_sockets   # noqa: E402
from screenshot import capture               # noqa: E402

W, H = 750, 500
BG = (0x00, 0x00, 0x08)                       # near black for max contrast
BGI = (BG[0] << 16) | (BG[1] << 8) | BG[2]
GREEN = 0x00FF00                              # full brightness


def png_b64(w, h, rgb=BG):
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
    d.q('scr = display.create(display.ROOT, display.OBJ_SCREEN, "SINE 750x500") '
        'display.changescreen(scr)')

    b64 = png_b64(W, H)
    d.send('loadimage cvA')
    for i in range(0, len(b64), 900):
        d.send(b64[i:i + 900])
    d.send('endimage')
    time.sleep(1.5)
    print('image    :', d.q(
        f'im = display.create(scr, display.OBJ_IMAGE, 25, 55, "cvA", {W}, {H}) '
        f'print("id=" .. tostring(im))', timeout=60))
    d.q('eventlog.clear()')

    print('row cost :', d.q(
        f'local sp = display.setpixel timer.cleartime() '
        f'for x = 0, {W-1} do sp(im, x, 20, {GREEN}) end '
        f'local t1 = timer.gettime() '
        f'timer.cleartime() display.flush(im) local t2 = timer.gettime() '
        f'print(string.format("%d px = %.4f s (%.2f us/px)  flush = %.4f s", '
        f'{W}, t1, t1/{W}*1e6, t2))', timeout=300))
    d.q('eventlog.clear()')

    frames = 25
    anim = (
        f'local sp, floor, sin, pi = display.setpixel, math.floor, math.sin, math.pi '
        f'local prev = {{}} '
        f'for x = 0, {W-1} do prev[x] = -1 end '
        f'local mid, amp = {H//2}, {H//2 - 8} '
        f'timer.cleartime() '
        f'for f = 1, {frames} do '
        f'  local ph = f*0.4 '
        f'  for x = 0, {W-1} do '
        f'    local y = floor(mid + amp*sin(2*pi*x/140 + ph)*(1 - x/({W}*1.7))) '
        f'    local p = prev[x] '
        f'    if p ~= y then '
        f'      if p >= 0 then sp(im,x,p,{BGI}) sp(im,x,p+1,{BGI}) end '
        f'      sp(im,x,y,{GREEN}) sp(im,x,y+1,{GREEN}) '
        f'      prev[x] = y '
        f'    end '
        f'  end '
        f'  display.flush(im) '
        f'end '
        f'local el = timer.gettime() '
        f'print(string.format("ANIM {W}x{H}  %d frames  %.3f s = %.2f fps '
        f'(%.1f ms/frame)", {frames}, el, {frames}/el, el/{frames}*1000))')
    print('anim     :', d.q(anim, timeout=900))
    print('log      :', d.q('if eventlog.getcount()>0 then print(eventlog.next()) '
                            'else print("clean") end', timeout=40))
    d.q('eventlog.clear()')
    time.sleep(1.0)
    print('shot     :', capture('/tmp/px_sine750.png'))
    d.close()
    return 0


if __name__ == '__main__':
    sys.exit(main())
