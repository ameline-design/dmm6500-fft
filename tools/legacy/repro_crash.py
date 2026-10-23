#!/usr/bin/env python3
"""Staged attempt to reproduce the 2026-08-10 DMM6500 firmware panic.

The crash (front panel: PC = 002F751C, V01.07.17) happened while creating a
custom screen + OBJ_IMAGE pixel canvas in a session that had ALREADY uploaded an
image of the same name and created other custom screens. The same call sequence
had succeeded minutes earlier from a clean boot, so the suspicion is accumulated
display/image state rather than the call itself.

Rather than blindly re-crashing, this escalates one variable at a time and
records progress to a log file after every step, so if the instrument dies the
log still shows exactly which step did it.

STAGES
  1  duplicate loadimage name, no new screens          (primary suspect)
  2  many custom screens, single image                 (screen accumulation)
  3  many OBJ_IMAGE objects on the same image name     (object accumulation)
  4  full combination, as in the crashing run

Between stages the instrument is pinged; the first stage that stops answering is
the reproducer. Run with --stage N to run a single stage only.
"""
import argparse
import base64
import struct
import sys
import time
import zlib

sys.path.insert(0, __file__.rsplit('/', 1)[0])
from dmmrun import DMM, clear_dead_sockets   # noqa: E402

LOG = '/tmp/repro_crash.log'
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


def upload(d, name):
    b64 = png_b64(W, H)
    d.send(f'loadimage {name}')
    for i in range(0, len(b64), 900):
        d.send(b64[i:i + 900])
    d.send('endimage')
    time.sleep(1.5)


def alive(d):
    try:
        return d.q('print("PING")', timeout=20) == 'PING'
    except Exception as e:
        note(f'    !! instrument not answering: {type(e).__name__}: {e}')
        return False


def evlog(d, label):
    try:
        m = d.q('if eventlog.getcount() > 0 then print(eventlog.next()) '
                'else print("clean") end', timeout=25)
        note(f'    log[{label}]: {m}')
        d.q('eventlog.clear()', timeout=20)
    except Exception as e:
        note(f'    log[{label}]: unreadable ({type(e).__name__})')


def stage1(d):
    """Duplicate loadimage name in one power-on session."""
    note('STAGE 1: duplicate loadimage name (same name twice, no power cycle)')
    upload(d, 'dup1')
    note('  first upload done')
    if not alive(d):
        return False
    evlog(d, 's1-upload1')
    upload(d, 'dup1')          # same name again - the primary suspect
    note('  SECOND upload of the same name done')
    if not alive(d):
        return False
    evlog(d, 's1-upload2')
    return True


def stage2(d):
    """Several custom screens, never deleted."""
    note('STAGE 2: create 6 custom screens without deleting any')
    for i in range(1, 7):
        r = d.q(f'sc{i} = display.create(display.ROOT, display.OBJ_SCREEN, "S{i}") '
                f'print("scr{i}=" .. tostring(sc{i}))', timeout=40)
        note(f'  screen {i}: {r}')
        if not alive(d):
            return False
    evlog(d, 's2')
    return True


def stage3(d):
    """Several image objects bound to the same image name."""
    note('STAGE 3: 4 OBJ_IMAGE objects on one image name, 7-arg form')
    d.q('shost = display.create(display.ROOT, display.OBJ_SCREEN, "HOST") '
        'display.changescreen(shost)', timeout=40)
    for i in range(1, 5):
        r = d.q(f'io{i} = display.create(shost, display.OBJ_IMAGE, 20, 60, "dup1", {W}, {H}) '
                f'print("img{i}=" .. tostring(io{i}))', timeout=40)
        note(f'  image object {i}: {r}')
        if not alive(d):
            return False
    evlog(d, 's3')
    return True


def stage4(d):
    """Full combination, mirroring the crashing run."""
    note('STAGE 4: full combination (reload scripts, re-upload image, new screen+canvas)')
    for rnd in range(1, 4):
        note(f'  round {rnd}')
        upload(d, 'spcv')
        if not alive(d):
            return False
        r = d.q(f'zs{rnd} = display.create(display.ROOT, display.OBJ_SCREEN, "Z{rnd}") '
                f'display.changescreen(zs{rnd}) '
                f'zi{rnd} = display.create(zs{rnd}, display.OBJ_IMAGE, 45, 60, "spcv", {W}, {H}) '
                f'print("z{rnd} img=" .. tostring(zi{rnd}))', timeout=60)
        note(f'    screen+canvas: {r}')
        if not alive(d):
            return False
        # exercise the pixel path too
        r = d.q(f'for x = 0, 200 do display.setpixel(zi{rnd}, x, 10, 0x00FF00) end '
                f'display.flush(zi{rnd}) print("drew")', timeout=60)
        note(f'    pixels: {r}')
        if not alive(d):
            return False
        evlog(d, f's4-r{rnd}')
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--stage', type=int, default=0, help='run only this stage')
    a = ap.parse_args()

    open(LOG, 'w').close()
    note('=== reproduction attempt begins ===')
    clear_dead_sockets()
    d = DMM(timeout=90)
    note(f'connected: {d.q("print(localnode.model, localnode.version)")}')
    d.q('display.lightstate = display.STATE_LCD_100', timeout=20)
    d.q('eventlog.clear()', timeout=20)

    stages = {1: stage1, 2: stage2, 3: stage3, 4: stage4}
    order = [a.stage] if a.stage else [1, 2, 3, 4]

    for s in order:
        try:
            ok = stages[s](d)
        except Exception as e:
            note(f'*** STAGE {s} KILLED THE LINK: {type(e).__name__}: {e}')
            note('*** REPRODUCED - this is the trigger')
            return 2
        if not ok:
            note(f'*** STAGE {s} left the instrument unresponsive')
            note('*** REPRODUCED - this is the trigger')
            return 2
        note(f'  stage {s} survived')

    note('=== all stages survived; crash NOT reproduced ===')
    try:
        d.restore_display()
        d.close()
    except Exception:
        pass
    return 0


if __name__ == '__main__':
    sys.exit(main())
