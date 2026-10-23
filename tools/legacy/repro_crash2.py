#!/usr/bin/env python3
"""Second reproduction attempt: script reload churn + memory pressure.

Round 1 (repro_crash.py) ruled out the obvious display-state hypotheses:
duplicate loadimage names, accumulated custom screens, multiple OBJ_IMAGE objects
on one image name, and all of those combined. All survived.

What round 1 did NOT exercise, and what the crashing run did:

  A. repeated loadscript/endscript of the SAME script names, each followed by
     running the chunk, with script.delete() + nil in between. This is what
     produced the unexplained `-104 Data type error` immediately before the
     panic.
  B. large Lua table allocation (fft_init builds ~5 tables of N entries plus a
     flattened twiddle list) repeated across reloads, i.e. real heap churn on the
     app processor, while display objects also accumulate.
  C. the two together, which is exactly the crashing sequence.

Everything is logged to disk after each step so a panic still tells us where.
"""
import base64
import struct
import sys
import time
import zlib

sys.path.insert(0, __file__.rsplit('/', 1)[0])
from dmmrun import DMM, clear_dead_sockets   # noqa: E402

LOG = '/tmp/repro_crash2.log'
ROOT = __file__.rsplit('/', 2)[0]
W, H = 750, 360


def note(msg):
    line = f'{time.strftime("%H:%M:%S")} {msg}'
    print(line, flush=True)
    with open(LOG, 'a') as fh:
        fh.write(line + '\n')
        fh.flush()


def png_b64(w, h, rgb=(0, 0, 8)):
    raw = b''.join(b'\x00' + bytes(rgb) * w for _ in range(h))

    def ch(t, p):
        return (struct.pack('>I', len(p)) + t + p
                + struct.pack('>I', zlib.crc32(t + p) & 0xffffffff))

    return base64.b64encode(
        b'\x89PNG\r\n\x1a\n'
        + ch(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
        + ch(b'IDAT', zlib.compress(raw, 6))
        + ch(b'IEND', b'')).decode()


def alive(d):
    try:
        return d.q('print("PING")', timeout=20) == 'PING'
    except Exception as e:
        note(f'    !! link dead: {type(e).__name__}: {e}')
        return False


def evlog(d, label):
    try:
        m = d.q('if eventlog.getcount() > 0 then print(eventlog.next()) '
                'else print("clean") end', timeout=25)
        if m != 'clean':
            note(f'    LOG[{label}]: {m}')
        d.q('eventlog.clear()', timeout=20)
        return m
    except Exception as e:
        note(f'    LOG[{label}]: unreadable ({type(e).__name__})')
        return None


def reload_script(d, name, src):
    """The exact teardown/reload idiom used by the crashing run."""
    d.q(f'if {name} ~= nil then pcall(function() script.delete({name}) end) '
        f'{name} = nil end', timeout=30)
    d.drain()
    d.send('loadscript ' + name)
    for ln in src.splitlines():
        d.send(ln)
    d.send('endscript')
    time.sleep(0.4)
    return d.q(f'{name}() print("{name}-ok")', timeout=90)


def stageA(d):
    note('STAGE A: reload the same two script names 6x, running each chunk')
    core = open(f'{ROOT}/tsp/fft_core.tsp').read()
    spec = open(f'{ROOT}/tsp/spectrum.tsp').read()
    for i in range(1, 7):
        r1 = reload_script(d, 'fftcore', core)
        r2 = reload_script(d, 'spectrum', spec)
        note(f'  reload {i}: {r1} / {r2}')
        evlog(d, f'A{i}')
        if not alive(d):
            return False
    return True


def stageB(d):
    note('STAGE B: repeated fft_init(512/1024/2048) - large table churn')
    for i in range(1, 7):
        for N in (512, 1024, 2048):
            try:
                r = d.q(f'fft_init({N}) print("N=" .. FFT_N .. " nswp=" .. fft_nswp)',
                        timeout=240)
            except Exception as e:
                note(f'  fft_init({N}) killed the link: {type(e).__name__}')
                return False
            note(f'  round {i} fft_init({N}): {r}')
            evlog(d, f'B{i}-{N}')
            if not alive(d):
                return False
        mem = d.q('print(memory.available())', timeout=30)
        note(f'  round {i} memory.available(): {mem}')
    return True


def stageC(d):
    note('STAGE C: crashing sequence, repeated - reload scripts + image + screen + canvas')
    core = open(f'{ROOT}/tsp/fft_core.tsp').read()
    spec = open(f'{ROOT}/tsp/spectrum.tsp').read()
    b64 = png_b64(W, H)
    for i in range(1, 8):
        note(f'  --- round {i} ---')
        r1 = reload_script(d, 'fftcore', core)
        r2 = reload_script(d, 'spectrum', spec)
        note(f'    scripts: {r1} / {r2}')
        evlog(d, f'C{i}-scripts')
        if not alive(d):
            return False

        d.send('loadimage spcv')
        for k in range(0, len(b64), 900):
            d.send(b64[k:k + 900])
        d.send('endimage')
        time.sleep(1.5)
        if not alive(d):
            note('    died during/after loadimage')
            return False
        evlog(d, f'C{i}-image')

        try:
            r = d.q(f'SP_W = {W} SP_H = {H} '
                    f'sp_setup("spcv", 256, "REPRO {i}") '
                    f'print("img=" .. tostring(sp_img))', timeout=90)
        except Exception as e:
            note(f'    *** sp_setup killed the link: {type(e).__name__}: {e}')
            return False
        note(f'    sp_setup: {r}')
        evlog(d, f'C{i}-setup')
        if not alive(d):
            return False

        try:
            r = d.q(f'fft_init(512) '
                    f'for x = 0, 300 do display.setpixel(sp_img, x, 20, 0x00FF00) end '
                    f'display.flush(sp_img) print("drew")', timeout=180)
        except Exception as e:
            note(f'    *** draw killed the link: {type(e).__name__}: {e}')
            return False
        note(f'    fft+draw: {r}')
        evlog(d, f'C{i}-draw')
        if not alive(d):
            return False
        mem = d.q('print(memory.available())', timeout=30)
        note(f'    memory.available(): {mem}')
    return True


def main():
    open(LOG, 'w').close()
    note('=== reproduction attempt #2 ===')
    clear_dead_sockets()
    d = DMM(timeout=120)
    note(f'connected: {d.q("print(localnode.model, localnode.version)")}')
    d.q('display.lightstate = display.STATE_LCD_100', timeout=20)
    d.q('eventlog.clear()', timeout=20)
    note(f'memory.available() at start: {d.q("print(memory.available())", timeout=30)}')

    for name, fn in (('A', stageA), ('B', stageB), ('C', stageC)):
        try:
            ok = fn(d)
        except Exception as e:
            note(f'*** STAGE {name} KILLED THE LINK: {type(e).__name__}: {e}')
            note('*** REPRODUCED')
            return 2
        if not ok:
            note(f'*** STAGE {name} left the instrument unresponsive - REPRODUCED')
            return 2
        note(f'  stage {name} survived')

    note('=== not reproduced ===')
    try:
        d.restore_display()
        d.close()
    except Exception:
        pass
    return 0


if __name__ == '__main__':
    sys.exit(main())
