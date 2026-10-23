#!/usr/bin/env python3
"""Decide the render architecture: how many objects, and how to batch repaints.

Conservative rewrite. The previous version created ~700 line objects in tight
loops and left the instrument hung; every hang and both firmware panics this
session followed heavy, rapid object creation. So this version:

  * uses 128 display columns instead of 256 (FFT keeps 256 bins for resolution;
    adjacent bins are aggregated by max for display, which is what a real
    analyser does)
  * paces creation with a short delay every 16 objects to let the display
    processor's message queue drain
  * deletes its screens on the way out so repeated runs do not accumulate state
  * measures A and B on one screen first, and only builds the second screen for
    the double-buffer test if those succeeded

Candidates:
  A  update all marks on the visible screen (baseline)
  B  setstate(scr, STATE_INVISIBLE) -> update -> STATE_VISIBLE
  C  double buffer: update hidden screen, changescreen() to swap
"""
import sys
import time

sys.path.insert(0, __file__.rsplit('/', 1)[0])
from dmmrun import DMM, clear_dead_sockets   # noqa: E402
from screenshot import capture               # noqa: E402

NB = 128                 # display columns
X0, TOP, BOT = 14, 50, 300
STEP = 6                 # 14 + 127*6 = 776, inside the 1..798 limit
FRAMES = 10

SETUP = r'''
-- Create `nb` short trace marks on a new screen, pacing creation so the display
-- processor is not flooded (rapid unpaced creation has hung this instrument).
function mk_screen(title, nb, x0, bot, step, colour)
  local scr = display.create(display.ROOT, display.OBJ_SCREEN, title)
  local marks = {}
  for i = 1, nb do
    local x = x0 + (i-1)*step
    if x > 796 then x = 796 end
    local ln = display.create(scr, display.OBJ_LINE, x, bot, x+step-2, bot)
    display.setcolor(ln, colour)
    display.setthickness(ln, 3)
    marks[i] = ln
    if math.mod(i, 16) == 0 then delay(0.02) end
  end
  return scr, marks
end

function shuffle(marks, nb, x0, top, bot, step, seed)
  local setpos = display.setposition
  local mod = math.mod
  for i = 1, nb do
    local y = top + mod(i*37 + seed*61, bot-top-4)
    local x = x0 + (i-1)*step
    if x > 796 then x = 796 end
    setpos(marks[i], x, y, x+step-2, y)
  end
end

function bench_A(marks, nb, x0, top, bot, step, frames)
  timer.cleartime()
  for f = 1, frames do shuffle(marks, nb, x0, top, bot, step, f) end
  local el = timer.gettime()
  print(string.format("A visible       nb=%d  %.1f ms/frame  (%.1f fps)",
    nb, el/frames*1000, frames/el))
end

function bench_B(scr, marks, nb, x0, top, bot, step, frames)
  timer.cleartime()
  for f = 1, frames do
    display.setstate(scr, display.STATE_INVISIBLE)
    shuffle(marks, nb, x0, top, bot, step, f)
    display.setstate(scr, display.STATE_VISIBLE)
  end
  local el = timer.gettime()
  print(string.format("B hide/show     nb=%d  %.1f ms/frame  (%.1f fps)",
    nb, el/frames*1000, frames/el))
end

function bench_C(sA, mA, sB, mB, nb, x0, top, bot, step, frames)
  timer.cleartime()
  for f = 1, frames do
    if math.mod(f,2) == 1 then
      shuffle(mB, nb, x0, top, bot, step, f)
      display.changescreen(sB)
    else
      shuffle(mA, nb, x0, top, bot, step, f)
      display.changescreen(sA)
    end
  end
  local el = timer.gettime()
  print(string.format("C doublebuffer  nb=%d  %.1f ms/frame  (%.1f fps)",
    nb, el/frames*1000, frames/el))
end
'''


def alive(d):
    try:
        return d.q('print("P")', timeout=25) == 'P'
    except Exception:
        return False


def main():
    clear_dead_sockets()
    d = DMM(timeout=180)
    d.q('reset()')
    d.q('display.lightstate = display.STATE_LCD_100')
    d.q('eventlog.clear()')
    d.load_script('bb2', SETUP, run=False)
    print('setup     :', d.q('bb2() print("ok")', timeout=120))

    print(f'screen A ({NB} marks, paced)...')
    print(' ', d.q(f'scrA, mA = mk_screen("SPEC A", {NB}, {X0}, {BOT}, {STEP}, 0x00FF00) '
                   f'display.changescreen(scrA) print("A=" .. tostring(scrA))', timeout=300))
    if not alive(d):
        print('instrument unresponsive after creating screen A')
        return 2
    print('  log     :', d.q('if eventlog.getcount()>0 then print(eventlog.next()) '
                             'else print("clean") end', timeout=40))
    d.q('eventlog.clear()')

    for label, cmd in (
        ('A', f'bench_A(mA, {NB}, {X0}, {TOP}, {BOT}, {STEP}, {FRAMES})'),
        ('B', f'bench_B(scrA, mA, {NB}, {X0}, {TOP}, {BOT}, {STEP}, {FRAMES})'),
    ):
        d.drain()
        d.send(cmd)
        print(' ', d.line(600))
        if not alive(d):
            print(f'instrument died during {label}')
            return 2
        d.q('eventlog.clear()')

    print(f'screen B (double buffer, {NB} marks)...')
    print(' ', d.q(f'scrB, mB = mk_screen("SPEC B", {NB}, {X0}, {BOT}, {STEP}, 0x00FF00) '
                   f'print("B=" .. tostring(scrB))', timeout=300))
    if not alive(d):
        print('instrument unresponsive after creating screen B')
        return 2
    d.drain()
    d.send(f'bench_C(scrA, mA, scrB, mB, {NB}, {X0}, {TOP}, {BOT}, {STEP}, {FRAMES})')
    print(' ', d.line(600))
    print('  log     :', d.q('if eventlog.getcount()>0 then print(eventlog.next()) '
                             'else print("clean") end', timeout=40))
    d.q('eventlog.clear()')

    time.sleep(1.0)
    print('screenshot:', capture('/tmp/batch2.png'))

    # Clean up so repeated runs do not accumulate screens/objects.
    d.q('display.changescreen(display.SCREEN_HOME)', timeout=30)
    d.q('pcall(function() display.delete(scrA) end) '
        'pcall(function() display.delete(scrB) end)', timeout=60)
    print('cleanup   :', d.q('print("done")', timeout=30))
    d.close()
    return 0


if __name__ == '__main__':
    sys.exit(main())
