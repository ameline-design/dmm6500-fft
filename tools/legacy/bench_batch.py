#!/usr/bin/env python3
"""Find the fastest way to update 256 trace marks without visible tearing.

Problem: display.setposition() repaints immediately, so moving 256 marks one at a
time is both slow and visibly "crawls" across the screen. The firmware exposes no
suspend/defer/batch primitive for repaints (checked: DISPLAY_LOCK et al. are
localnode.accesslock() front-panel values, and there are no
suspend/resume/batch/defer strings in the display code).

Candidates measured here:
  A  baseline - update all 256 marks on the visible screen
  B  setstate(screen, STATE_INVISIBLE) -> update -> STATE_VISIBLE
  C  double buffer - two identical screens; update the hidden one, then
     changescreen() to swap. One repaint per frame instead of 256.
  D  fewer marks (128 / 64) to quantify how cost scales with object count
"""
import sys
import time

sys.path.insert(0, __file__.rsplit('/', 1)[0])
from dmmrun import DMM, clear_dead_sockets   # noqa: E402
from screenshot import capture               # noqa: E402

NB = 256
X0, TOP, BOT, STEP = 14, 50, 300, 3

SETUP = r'''
-- Build one screen full of short trace marks. Returns screen id and mark table.
function mk_screen(title, nb, x0, top, bot, step, colour)
  local scr = display.create(display.ROOT, display.OBJ_SCREEN, title)
  local marks = {}
  for i = 1, nb do
    local x = x0 + (i-1)*step
    if x > 796 then x = 796 end
    local ln = display.create(scr, display.OBJ_LINE, x, bot, x+2, bot)
    display.setcolor(ln, colour)
    display.setthickness(ln, 2)
    marks[i] = ln
  end
  return scr, marks
end

-- Move every mark to a pseudo-random height (worst case: all of them change).
function shuffle(marks, nb, x0, top, bot, step, seed)
  local setpos = display.setposition
  local mod, floor = math.mod, math.floor
  for i = 1, nb do
    local y = top + mod(i*37 + seed*61, bot-top-4)
    local x = x0 + (i-1)*step
    if x > 796 then x = 796 end
    setpos(marks[i], x, y, x+2, y)
  end
end

function bench_visible(marks, nb, x0, top, bot, step, frames)
  timer.cleartime()
  for f = 1, frames do shuffle(marks, nb, x0, top, bot, step, f) end
  local el = timer.gettime()
  print(string.format("A visible      nb=%d %d frames %.3f s = %.1f ms/frame (%.1f fps)",
    nb, frames, el, el/frames*1000, frames/el))
end

function bench_hidden(scr, marks, nb, x0, top, bot, step, frames)
  timer.cleartime()
  for f = 1, frames do
    display.setstate(scr, display.STATE_INVISIBLE)
    shuffle(marks, nb, x0, top, bot, step, f)
    display.setstate(scr, display.STATE_VISIBLE)
  end
  local el = timer.gettime()
  print(string.format("B hide/show    nb=%d %d frames %.3f s = %.1f ms/frame (%.1f fps)",
    nb, frames, el, el/frames*1000, frames/el))
end

function bench_double(scrA, mA, scrB, mB, nb, x0, top, bot, step, frames)
  timer.cleartime()
  for f = 1, frames do
    if math.mod(f,2) == 1 then
      shuffle(mB, nb, x0, top, bot, step, f)
      display.changescreen(scrB)
    else
      shuffle(mA, nb, x0, top, bot, step, f)
      display.changescreen(scrA)
    end
  end
  local el = timer.gettime()
  print(string.format("C doublebuffer nb=%d %d frames %.3f s = %.1f ms/frame (%.1f fps)",
    nb, frames, el, el/frames*1000, frames/el))
end
'''


def main():
    clear_dead_sockets()
    d = DMM(timeout=180)
    d.q('reset()')
    d.q('display.lightstate = display.STATE_LCD_100')
    d.q('eventlog.clear()')
    d.load_script('bb', SETUP, run=False)
    print('setup:', d.q('bb() print("ok")', timeout=120))

    print(f'creating screen A ({NB} marks, ~3 s)...')
    print(' ', d.q(f'scrA, mA = mk_screen("BATCH A", {NB}, {X0}, {TOP}, {BOT}, {STEP}, 0x00FF00) '
                   f'display.changescreen(scrA) print("A=" .. tostring(scrA))', timeout=300))
    print('creating screen B (double buffer)...')
    print(' ', d.q(f'scrB, mB = mk_screen("BATCH B", {NB}, {X0}, {TOP}, {BOT}, {STEP}, 0x00FF00) '
                   f'print("B=" .. tostring(scrB))', timeout=300))
    d.q('eventlog.clear()')

    for label, cmd in (
        ('A', f'bench_visible(mA, {NB}, {X0}, {TOP}, {BOT}, {STEP}, 10)'),
        ('B', f'bench_hidden(scrA, mA, {NB}, {X0}, {TOP}, {BOT}, {STEP}, 10)'),
        ('C', f'bench_double(scrA, mA, scrB, mB, {NB}, {X0}, {TOP}, {BOT}, {STEP}, 10)'),
    ):
        d.drain()
        d.send(cmd)
        print(' ', d.line(600))
        log = d.q('if eventlog.getcount()>0 then print(eventlog.next()) else print("-") end',
                  timeout=40)
        if log != '-':
            print(f'    log[{label}]: {log}')
        d.q('eventlog.clear()')

    # D: how does cost scale with the number of marks?
    print('\nD scaling with object count:')
    for nb in (128, 64):
        d.q(f'scrD, mD = mk_screen("D{nb}", {nb}, {X0}, {TOP}, {BOT}, {STEP*2}, 0x00FF00) '
            f'display.changescreen(scrD)', timeout=300)
        d.drain()
        d.send(f'bench_visible(mD, {nb}, {X0}, {TOP}, {BOT}, {STEP*2}, 10)')
        print(' ', d.line(600))
        d.q('eventlog.clear()')

    time.sleep(1.0)
    print('\nscreenshot:', capture('/tmp/batch.png'))
    d.close()
    return 0


if __name__ == '__main__':
    sys.exit(main())
