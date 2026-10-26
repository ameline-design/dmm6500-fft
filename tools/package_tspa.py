#!/usr/bin/env python3
"""Package the FFT spectrum analyser as a single .tspa TTI App for the DMM6500.

Concatenates the four TSP modules into one `loadscript` wrapper with an App
manifest, an auto-start entry point, an EVENT_ENDAPP cleanup hook, and an
embedded base64 PNG icon -- matching the Keithley example .tspa apps
(loadscript / -- $manifest / endscript, then loadimage / <base64> / endimage).

The modules are script BODIES (they populate the single `fftsa` table), so opening
the App runs the concatenated definitions and then fftsa.start().
"""
import base64
import os
import re
import struct
import subprocess
import sys
import tempfile
import textwrap
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# The instrument's parser is Lua 5.0.2 and a parse error ANYWHERE in the archive
# leaves fftsa nil, so every later call raises -286 on the panel. Host Lua accepts
# plenty that it does not (hex literals, '#', string methods), so the only reliable
# gate is 5.0.2's own compiler, run over the assembled script rather than the modules
# one at a time -- concatenation is where an unterminated comment would swallow the
# next module. Set LUA502_LUAC to move it; set FFT_NO_GATE=1 only to package
# deliberately broken code for a test.
LUA502_LUAC = os.environ.get('LUA502_LUAC',
                             os.path.expanduser('~/tmp/base/out/lua502/bin/luac'))
NAME = 'FFT_Spectrum'          # internal script name (loadscript <NAME>)
ICON = 'fft_icon'              # icon name (matches -- $Icon and loadimage)
OUT = os.path.join(ROOT, 'FFT_Spectrum.tspa')
MODULES = ['tsp/fft_core.tsp', 'tsp/spectrum_ui.tsp',
           'tsp/spectrum_graph.tsp', 'tsp/spectrum_app.tsp']

# Panel icons: assets/<name>.png, embedded as their own loadimage block. The names are
# NOT listed here -- script_images() reads them out of the modules' `fftsa.img_* = "name"`
# declarations, because a name that exists on only one side of this is a blank button on
# the glass and nothing else. Matched both ways: a declared name with no file is a
# failure, and so is a file nothing declares.
ASSETS = os.path.join(ROOT, 'assets')
IMG_DECL = re.compile(r'^\s*fftsa\.img_\w+\s*=\s*"([^"]+)"', re.M)

MANIFEST = [
    ('Title', 'FFT Spectrum Analyser'),
    # All three are tested and working. The DMM6500 and DAQ6510 share the same
    # boards; the DMM7510 has a better digitizer and analog front end. All of
    # them reach the digitizer as dmm.digitize, the only instrument namespace
    # this app uses.
    #
    # DMM7510 is absent from Keithley's documented value set (2450, 2460, 2461,
    # 2470, DMM6500, DAQ6510), but it installs and runs, so the published list is
    # incomplete.
    #
    # No SMU: an SMU reaches its measurement subsystem as smu.*, so the app would
    # install and then fail at the first capture.
    ('Product', 'DMM6500, DAQ6510, DMM7510'),
    ('Tag', 'FFT, Spectrum, Digitize, Audio'),
    ('Description', 'On-instrument FFT spectrum analyser: digitize mode + FFT '
                    'with a live graph, top-6 peaks, and a touch options form '
                    '(start/stop frequency, input range).'),
    # Tracks the repo's git tag, so the version in MENU > Manage Apps identifies which
    # tree is installed. Bump it with the tag, or an install cannot be told from the one
    # it replaced.
    ('Version', '2.2'),
    # Stated minimum firmware. Kept low deliberately: the app is developed against
    # 1.7.17a, and if the installer compares this field as a STRING then "1.7.3c"
    # sorts above "1.7.17a" and the app refuses to install on the very unit it was
    # written on. "1.7.0" is satisfied under either a string or a numeric compare.
    ('Requires', '1.7.0'),
    ('Icon', ICON),
]

ENTRY = '''
-- ==================== TTI App entry point ====================
-- fftsa.start() builds the screens, hooks End App (EVENT_ENDAPP -> fftsa.cleanup)
-- as soon as the spectrum screen exists, configures the hardware and arms the
-- frame timer -- all under pcall, so a failure part-way through tears its own
-- display objects back down instead of stranding them until the next power cycle.
fftsa.start()
'''


def png_icon(W=60, H=60):
    """RGB PNG (pure stdlib): a green spectrum trace with 'FFT' in magenta over it,
    rendered at 8x and box-downsampled to W x H so the edges are anti-aliased."""
    import math
    SS = 8                               # supersample; box-downsampled below -> AA
    HW, HH = W * SS, H * SS
    hi = bytearray(HW * HH * 3)          # black background, at SSx

    def hset(x, y, r, g, b):
        if 0 <= x < HW and 0 <= y < HH:
            i = (y * HW + x) * 3
            hi[i], hi[i + 1], hi[i + 2] = r, g, b

    # Green spectrum trace (heights in W/H units, rasterised at SSx).
    def col_h(xr):
        peak = (H - 12) * math.exp(-((xr - W * 0.5) ** 2) / 40.0)
        wob = 4 * (0.5 + 0.5 * math.sin(xr * 0.9))
        return max(0.0, min(H - 4.0, 5 + peak + wob))
    for hx in range(3 * SS, (W - 3) * SS):
        top = int((H - 2) * SS - col_h(hx / SS) * SS)
        for hy in range(top, (H - 2) * SS):
            hi[(hy * HW + hx) * 3 + 1] = 255      # green channel

    # "FFT" (5x7 bitmap glyphs) in magenta with a black halo, centred.
    font = {
        'F': ["11111", "10000", "10000", "11110", "10000", "10000", "10000"],
        'T': ["11111", "00100", "00100", "00100", "00100", "00100", "00100"],
    }
    text = "FFT"
    s, gap = 3 * SS, 3 * SS               # glyph-pixel size and inter-glyph gap
    gw = 5 * s
    total_w = len(text) * gw + (len(text) - 1) * gap
    x0, y0 = (HW - total_w) // 2, (HH - 7 * s) // 2
    lit, cx = set(), x0
    for chn in text:
        rows = font[chn]
        for ry in range(7):
            for rx in range(5):
                if rows[ry][rx] == '1':
                    for sy in range(s):
                        for sx in range(s):
                            lit.add((cx + rx * s + sx, y0 + ry * s + sy))
        cx += gw + gap
    halo = SS                            # ~1 final px of black outline
    for (x, y) in lit:
        for dx in range(-halo, halo + 1):
            for dy in range(-halo, halo + 1):
                if (x + dx, y + dy) not in lit:
                    hset(x + dx, y + dy, 0, 0, 0)
    for (x, y) in lit:
        hset(x, y, 255, 0, 255)

    # Box-downsample each SSxSS block to one pixel -> anti-aliased W x H.
    img = bytearray(W * H * 3)
    n = SS * SS
    for oy in range(H):
        for ox in range(W):
            r = g = b = 0
            for dy in range(SS):
                base = ((oy * SS + dy) * HW + ox * SS) * 3
                for dx in range(SS):
                    k = base + dx * 3
                    r += hi[k]; g += hi[k + 1]; b += hi[k + 2]
            j = (oy * W + ox) * 3
            img[j], img[j + 1], img[j + 2] = r // n, g // n, b // n

    raw = bytearray()
    for y in range(H):
        raw.append(0)                       # filter byte per scanline
        raw.extend(img[y * W * 3:(y + 1) * W * 3])

    def chunk(typ, data):
        return (struct.pack('>I', len(data)) + typ + data
                + struct.pack('>I', zlib.crc32(typ + data) & 0xffffffff))

    png = b'\x89PNG\r\n\x1a\n'
    png += chunk(b'IHDR', struct.pack('>IIBBBBB', W, H, 8, 2, 0, 0, 0))  # 8-bit RGB
    png += chunk(b'IDAT', zlib.compress(bytes(raw), 9))
    png += chunk(b'IEND', b'')
    return png


def png_size(blob, path):
    """Width and height out of the IHDR, and a refusal for anything shaped wrong.
    loadimage documents "standard PNG format (compressed 24 bit with Alpha)" and the
    firmware's loader reports nothing when it declines one, so the check belongs here."""
    if blob[:8] != b'\x89PNG\r\n\x1a\n' or blob[12:16] != b'IHDR':
        raise SystemExit('%s is not a PNG' % path)
    w, h, depth, ctype = struct.unpack('>IIBB', blob[16:26])
    if depth != 8 or ctype not in (2, 6):
        raise SystemExit('%s is %d-bit colour type %d; loadimage takes 8-bit RGB or RGBA'
                         % (path, depth, ctype))
    return w, h


def script_images(body):
    """The panel icons the script asks for, as (name, PNG bytes), from its own
    `fftsa.img_* = "name"` declarations matched against assets/."""
    names = []
    for n in IMG_DECL.findall(body):
        if n not in names:
            names.append(n)
    have = []
    if os.path.isdir(ASSETS):
        have = sorted(f[:-4] for f in os.listdir(ASSETS) if f.endswith('.png'))
    missing = [n for n in names if n not in have]
    if missing:
        raise SystemExit('declared in tsp/ with no assets/<name>.png: '
                         + ', '.join(missing))
    unused = [n for n in have if n not in names]
    if unused:
        raise SystemExit('in assets/ but no fftsa.img_* names it: ' + ', '.join(unused))
    images = []
    for n in names:
        path = os.path.join(ASSETS, n + '.png')
        with open(path, 'rb') as f:
            blob = f.read()
        w, h = png_size(blob, path)
        # The script centres each icon on its button from constants of its own, and nothing
        # else notices when a replaced PNG stops matching them -- the icon just sits off
        # centre. The real dimensions are right here, so require the source to mention
        # them: a 28x34 that becomes 32x40 fails the package instead of the eye.
        if '%dx%d' % (w, h) not in body:
            raise SystemExit('assets/%s.png is %dx%d and no module mentions that size; '
                             'the centring constants in tsp/ are stale' % (n, w, h))
        print('  image: %-9s %2dx%-2d  %5d bytes' % (n, w, h, len(blob)))
        images.append((n, blob))
    return images


def emit_image(out, name, blob):
    """One loadimage block. The second token links the image to the script, which is
    what makes the instrument save and delete the two together."""
    out.append('loadimage %s %s' % (name, NAME))
    out.extend(textwrap.wrap(base64.b64encode(blob).decode('ascii'), 76))
    out.append('endimage')


def gate(body):
    """Refuse to write an archive the instrument could not parse. Fails closed: a
    missing 5.0.2 compiler is a failure, not a skip, because the whole point is that
    host Lua's verdict does not transfer."""
    if os.environ.get('FFT_NO_GATE') == '1':
        print('  GATE SKIPPED (FFT_NO_GATE=1)')
        return
    lint = subprocess.run([sys.executable, '-I', os.path.join(ROOT, 'tools/lint_tsp.py')]
                          + [os.path.join(ROOT, m) for m in MODULES],
                          capture_output=True, text=True)
    if lint.returncode != 0:
        raise SystemExit('lint_tsp.py rejected the modules:\n' + lint.stdout + lint.stderr)
    if not os.path.exists(LUA502_LUAC):
        raise SystemExit('no Lua 5.0.2 compiler at %s -- the host Lua on PATH is a '
                         'later version and accepts code the instrument rejects. Set '
                         'LUA502_LUAC.' % LUA502_LUAC)
    fd, path = tempfile.mkstemp(suffix='.lua', prefix='tspa_gate_')
    try:
        with os.fdopen(fd, 'w') as f:
            f.write(body)
        r = subprocess.run([LUA502_LUAC, '-p', path], capture_output=True, text=True)
        if r.returncode != 0:
            raise SystemExit('Lua 5.0.2 cannot parse the assembled script:\n'
                             + r.stdout + r.stderr)
    finally:
        os.unlink(path)
    print('  gate: lint clean, and Lua 5.0.2 parses the assembled script')


def main():
    out = []
    out.append('loadscript ' + NAME)
    for k, v in MANIFEST:
        out.append('-- $%s: %s' % (k, v))
    out.append('')

    for m in MODULES:
        out.append('-- ================= %s =================' % m)
        with open(os.path.join(ROOT, m)) as f:
            for ln in f.read().split('\n'):
                out.append(ln.rstrip('\r'))
        out.append('')

    for ln in ENTRY.strip('\n').split('\n'):
        out.append(ln)
    out.append('endscript')

    # Everything between the two wrapper lines is what the instrument compiles.
    body = '\n'.join(out[1:-1]) + '\n'
    gate(body)

    # The App icon first, generated rather than stored because it is one drawing this
    # file already owns; then the panel icons the script names.
    emit_image(out, ICON, png_icon())
    images = script_images(body)
    for name, blob in images:
        emit_image(out, name, blob)

    text = '\r\n'.join(out) + '\r\n'        # CRLF, like the Keithley examples
    with open(OUT, 'w', newline='') as f:
        f.write(text)
    print('wrote %s (%d bytes, %d lines)' % (OUT, len(text), len(out)))
    print('  script: %s   icon: %s   modules: %d   panel icons: %d'
          % (NAME, ICON, len(MODULES), len(images)))


if __name__ == '__main__':
    main()
