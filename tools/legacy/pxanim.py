#!/usr/bin/env python3
"""Animate a pixel-drawn trace and measure the real achievable frame rate.

Establishes the numbers the spectrum app needs:
  - cost per pixel write
  - cost of clearing the previous trace (the expensive part of animation)
  - achievable fps at the app's target canvas size

Key technique for animation: do NOT repaint the whole canvas each frame. Keep
the previous y per column and erase only that one pixel, then draw the new one.
That makes a frame cost 2*W writes instead of W*H.
"""
import base64
import struct
import sys
import time
import zlib

sys.path.insert(0, __file__.rsplit('/', 1)[0])
from dmmrun import DMM, clear_dead_sockets   # noqa: E402
from screenshot import capture               # noqa: E402

BG = (0x10, 0x14, 0x20)


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


def upload(d, name, w, h):
    b64 = png_b64(w, h)
    d.send(f'loadimage {name}')
    for i in range(0, len(b64), 900):
        d.send(b64[i:i + 900])
    d.send('endimage')
    time.sleep(1.2)


ANIM = r'''
-- Animate a travelling wave, erasing only the previous pixel per column.
-- prev[] holds last y per column so a frame costs 2*W writes, not W*H.
function anim(id, w, h, frames, colour, bg)
  local floor, sin, pi = math.floor, math.sin, math.pi
  local sp = display.setpixel
  local prev = {}
  local mid, amp = floor(h/2), floor(h/2) - 4
  for x = 0, w-1 do prev[x] = -1 end
  timer.cleartime()
  for f = 1, frames do
    local ph = f * 0.35
    for x = 0, w-1 do
      local y = floor(mid + amp * sin(2*pi*x/120 + ph) * (1 - x/(w*1.6)))
      local p = prev[x]
      if p ~= y then
        if p >= 0 then sp(id, x, p, bg) end
        sp(id, x, y, colour)
        prev[x] = y
      end
    end
    display.flush(id)
  end
  local el = timer.gettime()
  print(string.format("ANIM %dx%d %d frames in %.3f s = %.2f fps (%.1f ms/frame)",
        w, h, frames, el, frames/el, el/frames*1000))
end

-- Cost of a full-canvas clear, for comparison.
function clearcost(id, w, h, bg)
  local sp = display.setpixel
  timer.cleartime()
  for y = 0, h-1 do for x = 0, w-1 do sp(id, x, y, bg) end end
  local el = timer.gettime()
  print(string.format("FULL CLEAR %dx%d (%d px) = %.3f s (%.2f us/px)",
        w, h, w*h, el, el/(w*h)*1e6))
end

-- Single-row write cost, isolated.
function rowcost(id, w, y, colour)
  local sp = display.setpixel
  timer.cleartime()
  for x = 0, w-1 do sp(id, x, y, colour) end
  local t1 = timer.gettime()
  timer.cleartime()
  display.flush(id)
  local t2 = timer.gettime()
  print(string.format("ROW %d px = %.4f s (%.2f us/px) | flush = %.4f s",
        w, t1, t1/w*1e6, t2))
end
'''


def main():
    clear_dead_sockets()
    d = DMM(timeout=90)
    d.q('reset()')
    d.q('display.lightstate = display.STATE_LCD_100')
    d.q('eventlog.clear()')
    d.q('scr = display.create(display.ROOT, display.OBJ_SCREEN, "FFT PIXEL BENCH") '
        'display.changescreen(scr)')
    d.load_script('pxa', ANIM, run=False)

    bgint = (BG[0] << 16) | (BG[1] << 8) | BG[2]

    for (w, h, x, y) in ((750, 380, 25, 60), (750, 500, 25, 60)):
        print(f'\n=== canvas {w} x {h} ===')
        name = f'cv{w}x{h}'
        upload(d, name, w, h)
        r = d.q(f'im = display.create(scr, display.OBJ_IMAGE, {x}, {y}, "{name}", {w}, {h}) '
                f'print("id=" .. tostring(im))', timeout=60)
        print('  image        :', r)
        if not r or 'id=' not in str(r):
            print('  create failed; log:',
                  d.q('if eventlog.getcount()>0 then print(eventlog.next()) else print("clean") end'))
            continue
        d.q('eventlog.clear()')
        print('  row cost     :', d.q(f'rowcost(im, {w}, 20, 0x00FF66)', timeout=240))
        print('  anim         :', d.q(f'anim(im, {w}, {h}, 20, 0x00FF66, {bgint})', timeout=600))
        print('  log          :', d.q('if eventlog.getcount()>0 then print(eventlog.next()) '
                                      'else print("clean") end', timeout=40))
        d.q('eventlog.clear()')
        time.sleep(0.8)
        capture(f'/tmp/px_anim_{w}x{h}.png')
        print(f'  screenshot   : /tmp/px_anim_{w}x{h}.png')

    print('\n=== full-canvas clear cost (why we erase per-column instead) ===')
    print(' ', d.q(f'clearcost(im, 750, 500, {bgint})', timeout=900))
    d.q('eventlog.clear()')
    d.close()
    return 0


if __name__ == '__main__':
    sys.exit(main())
