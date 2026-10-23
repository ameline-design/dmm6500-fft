#!/usr/bin/env python3
"""Measure TRUE display update latency, not Lua enqueue time.

Why this exists: display.setposition() is asynchronous. Lua timing says 128 mark
moves cost 3.2 ms, but watching the panel shows the repaint sweeping across for
roughly half a second. So every display benchmark taken from inside Lua has been
measuring how fast we can queue messages, not how fast the display processor can
paint them.

Two honest measurement methods, both host-side:
  1. ki.display.getpixel(x, y) polling - move a mark to a known spot, then poll
     that pixel until it changes colour. Gives per-update latency.
  2. wall-clock around a batch plus a screenshot to confirm the final state.

Also compares the two candidate render paths on equal terms:
  LINES : N coloured OBJ_LINE marks moved with display.setposition()
  GRAPH : the built-in graph screen fed from a WRITABLE_FULL buffer, which the
          firmware renders as a single trace (one repaint, not N)
"""
import sys
import time

sys.path.insert(0, __file__.rsplit('/', 1)[0])
from dmmrun import DMM, clear_dead_sockets   # noqa: E402
from screenshot import capture               # noqa: E402

X0, TOP, BOT = 14, 60, 300


def alive(d):
    try:
        return d.q('print("P")', timeout=25) == 'P'
    except Exception:
        return False


def cleanup(d, names):
    """Delete screens/objects so repeated runs cannot accumulate state."""
    for n in names:
        d.q(f'pcall(function() if {n} ~= nil then display.delete({n}) end end) {n} = nil',
            timeout=60)
    d.q('display.changescreen(display.SCREEN_HOME)', timeout=30)


def measure_latency(d, nmarks, step):
    """True latency for moving `nmarks` marks, via getpixel polling."""
    # Park all marks at the bottom, wait for quiescence.
    d.q(f'for i = 1, {nmarks} do local x = {X0} + (i-1)*{step} '
        f'display.setposition(mk[i], x, {BOT}, x+{step}-2, {BOT}) end', timeout=120)
    time.sleep(2.0)

    # Probe point: where mark 1 will land after the move.
    probe_x, probe_y = X0 + 1, TOP + 20
    before = d.q(f'print(ki.display.getpixel({probe_x}, {probe_y}))', timeout=30)

    t0 = time.time()
    d.q(f'for i = 1, {nmarks} do local x = {X0} + (i-1)*{step} '
        f'display.setposition(mk[i], x, {TOP+20}, x+{step}-2, {TOP+20}) end', timeout=120)
    t_enqueue = time.time() - t0

    # Poll the LAST mark's destination: it is painted last, so this measures the
    # full sweep rather than just the first object.
    last_x = X0 + (nmarks - 1) * step + 1
    deadline = time.time() + 20
    t_paint = None
    while time.time() < deadline:
        v = d.q(f'print(ki.display.getpixel({last_x}, {TOP+20}))', timeout=30)
        try:
            if v is not None and int(float(v)) > 0x004000:   # green-ish appeared
                t_paint = time.time() - t0
                break
        except (TypeError, ValueError):
            pass
    return t_enqueue, t_paint, before


def main():
    clear_dead_sockets()
    d = DMM(timeout=180)
    d.q('reset()')
    d.q('display.lightstate = display.STATE_LCD_100')
    d.q('eventlog.clear()')

    results = []
    for nmarks, step in ((128, 6), (64, 12), (32, 24)):
        print(f'\n=== LINES: {nmarks} marks, pitch {step} ===')
        d.q(f'scr = display.create(display.ROOT, display.OBJ_SCREEN, "TRUE {nmarks}") '
            f'display.changescreen(scr)', timeout=60)
        # paced creation
        d.q(f'mk = {{}} '
            f'for i = 1, {nmarks} do local x = {X0} + (i-1)*{step} '
            f'  mk[i] = display.create(scr, display.OBJ_LINE, x, {BOT}, x+{step}-2, {BOT}) '
            f'  display.setcolor(mk[i], 0x00FF00) display.setthickness(mk[i], 3) '
            f'  if math.mod(i,16) == 0 then delay(0.02) end end print("built")',
            timeout=300)
        if not alive(d):
            print('  instrument unresponsive after creation - stopping')
            return 2

        enq, paint, before = measure_latency(d, nmarks, step)
        pf = f'{paint*1000:.0f} ms' if paint else 'NOT SEEN in 20 s'
        fps = f'{1/paint:.1f}' if paint else '-'
        print(f'  enqueue (Lua) : {enq*1000:.0f} ms')
        print(f'  TRUE paint    : {pf}   -> {fps} fps')
        results.append((nmarks, enq, paint))
        capture(f'/tmp/true_{nmarks}.png')
        cleanup(d, ['scr'])
        d.q('eventlog.clear()')
        if not alive(d):
            print('  instrument unresponsive after cleanup - stopping')
            return 2

    print('\n=== GRAPH: built-in graph screen from a WRITABLE_FULL buffer ===')
    d.q('pcall(function() spec = nil end)', timeout=30)
    d.q('spec = buffer.make(300, buffer.STYLE_WRITABLE_FULL) '
        'buffer.write.format(spec, buffer.UNIT_VOLT, buffer.DIGITS_4_5, '
        '                          buffer.UNIT_HERTZ, buffer.DIGITS_6_5)', timeout=90)
    d.q('display.changescreen(display.SCREEN_GRAPH)', timeout=60)
    r = d.q('pcall(function() display.graph.removeall(display.SCREEN_GRAPH) end) '
            'local ok = pcall(function() display.graph.add(display.SCREEN_GRAPH, spec, '
            'display.ELEMENT_DATA, spec, display.ELEMENT_EXTRA) end) print("addok=" .. tostring(ok))',
            timeout=90)
    print('  graph.add   :', r)
    print('  log         :', d.q('if eventlog.getcount()>0 then print(eventlog.next()) '
                                 'else print("clean") end', timeout=40))
    d.q('eventlog.clear()')

    for trial in range(3):
        t0 = time.time()
        d.q(f'spec.clear() '
            f'for k = 1, 256 do '
            f'  local v = 0.001 + 0.5*math.exp(-((k-{60+trial*20})^2)/40) '
            f'  buffer.write.reading(spec, v, (k-1)*195.3) end', timeout=180)
        enq = time.time() - t0
        print(f'  trial {trial}: 256 points enqueued in {enq*1000:.0f} ms')
    time.sleep(2.5)
    capture('/tmp/true_graph.png')
    print('  screenshot  : /tmp/true_graph.png')

    print('\n=== summary (TRUE paint latency) ===')
    for nmarks, enq, paint in results:
        pf = f'{paint*1000:7.0f} ms  {1/paint:5.1f} fps' if paint else '   not observed'
        print(f'  {nmarks:>4} marks: enqueue {enq*1000:6.0f} ms | paint {pf}')

    d.q('display.changescreen(display.SCREEN_HOME)', timeout=30)
    d.q('eventlog.clear()')
    d.close()
    return 0


if __name__ == '__main__':
    sys.exit(main())
