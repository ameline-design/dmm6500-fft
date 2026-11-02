#!/usr/bin/env python3
"""Gate: the archive's base64 image decodes, under Lua 5.0.2, to the bytes that were built.

tsp/native_code.tsp carries the compiled image as base64 because decimal escapes cost four
characters a byte and base64 costs 1.34 -- 125 KB of script source down to 43 KB, read and
parsed at every app launch. The price is a decoder, and a decoder is a place a wrong byte
comes from. A wrong byte in a 27 KB PowerPC image is not a failure to load: it is one
instruction or one float constant quietly different, which relocation then places perfectly
and the CPU executes.

So this runs the decoder THE INSTRUMENT RUNS, extracted from tsp/native_link.tsp rather
than copied here, over the blob the archive actually carries, and compares the result byte
for byte with build-ppc/dsp_native.bin. Both ends of the pipe:

  * Python's base64 of the emitted text must equal the built binary -- that is the encoder;
  * Lua 5.0.2's decoder must produce the same bytes -- that is the decoder.

    python3 -I csrc/tools/check_b64.py
    python3 -I csrc/tools/check_b64.py --self-test
"""
import base64
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MODULE = os.path.join(ROOT, 'tsp', 'native_link.tsp')
GENERATED = os.path.join(ROOT, 'tsp', 'native_code.tsp')
BIN = os.path.join(ROOT, 'build-ppc', 'dsp_native.bin')
LUA502 = os.environ.get('LUA502',
                        os.path.expanduser('~/tmp/lua502/lua-5.0.2/bin/lua'))

HEAD = 'local B64A ='
TAIL = '\nfftsa.nl._b64decode'
LEN_RE = r'^fftsa\.nl\.%s_LEN\s*=\s*(\d+)'
BLOB_RE = r"^fftsa\.nl\.%s = table\.concat\(\{\n(.*?)\n\}\)"


def extract(path, head, tail):
    with open(path) as f:
        src = f.read()
    a = src.find(head)
    b = src.find(tail)
    if a < 0 or b < a:
        raise SystemExit('%r .. %r not found in %s' % (head, tail, path))
    return src[a:b]


def blob(gen, name):
    """The base64 text and the declared length, out of the generated module."""
    m = re.search(LEN_RE % re.escape(name), gen, re.M)
    if m is None:
        raise SystemExit('%s_LEN not found in %s' % (name, GENERATED))
    length = int(m.group(1))
    m = re.search(BLOB_RE % re.escape(name), gen, re.M | re.S)
    if m is None:
        raise SystemExit('%s not found in %s' % (name, GENERATED))
    text = ''.join(re.findall(r"'([^']*)',", m.group(1)))
    return text, length


def lua_decode(decoder, gen_path, out_path):
    """Decode both blobs with the instrument's own decoder, into one file."""
    script = """
fftsa = { nl = {} }
%s
assert(dofile('%s') ~= false)
local nl = fftsa.nl
local img = b64decode(nl._DSP_CODE_B64, nl._DSP_CODE_B64_LEN)
local rel = b64decode(nl._DSP_RELOC_B64, nl._DSP_RELOC_B64_LEN)
if img == nil or rel == nil then print('DECODE-NIL') os.exit(1) end
local f = assert(io.open('%s', 'wb'))
f:write(img)
f:write(rel)
f:close()
print(string.len(img), string.len(rel))
""" % (decoder, gen_path, out_path)
    fd, path = tempfile.mkstemp(suffix='.lua', prefix='check_b64_')
    try:
        with os.fdopen(fd, 'w') as f:
            f.write(script)
        r = subprocess.run([LUA502, path], capture_output=True, text=True)
        if r.returncode != 0:
            return None, (r.stdout + r.stderr).strip()
        return r.stdout.strip(), None
    finally:
        os.unlink(path)


def check(gen_path, require_bin=True, module=None):
    with open(gen_path) as f:
        gen = f.read()
    img_b64, img_len = blob(gen, '_DSP_CODE_B64')
    rel_b64, rel_len = blob(gen, '_DSP_RELOC_B64')
    bad = []

    # The encoder, against the binary the compiler produced.
    want_img = base64.b64decode(img_b64)[:img_len]
    if require_bin:
        if not os.path.exists(BIN):
            raise SystemExit('no %s -- build the dsp_native_bin target first' % BIN)
        with open(BIN, 'rb') as f:
            built = f.read()
        if want_img != built:
            bad.append('the emitted base64 does not decode to dsp_native.bin '
                       '(%d bytes against %d)' % (len(want_img), len(built)))
    want_rel = base64.b64decode(rel_b64)[:rel_len]

    # The decoder the instrument runs.
    decoder = extract(module or MODULE, HEAD, TAIL)
    out = tempfile.mkstemp(suffix='.bin', prefix='check_b64_')
    os.close(out[0])
    try:
        rep, err = lua_decode(decoder, gen_path, out[1])
        if rep is None:
            bad.append('lua 5.0.2 decode failed: %s' % err)
        else:
            with open(out[1], 'rb') as f:
                got = f.read()
            if got != want_img + want_rel:
                n = min(len(got), len(want_img + want_rel))
                where = next((i for i in range(n)
                              if got[i] != (want_img + want_rel)[i]), n)
                bad.append('the Lua decode differs from base64 at byte %d '
                           '(%d bytes against %d)'
                           % (where, len(got), len(want_img) + len(want_rel)))
            elif rep.split() != ['%d' % img_len, '%d' % rel_len]:
                bad.append('lengths reported as %r, declared as %d %d'
                           % (rep, img_len, rel_len))
    finally:
        os.unlink(out[1])
    return img_len, rel_len, bad


def self_test():
    """Two canaries, one for each half, because neither half catches the other's fault.

    A corrupted blob is caught only by the comparison against the built binary: both the
    Lua decoder and Python's would decode the corrupted text the same way and agree with
    each other. A broken decoder is caught only by the Lua-against-Python comparison, which
    the binary check cannot see at all.
    """
    d = tempfile.mkdtemp(prefix='b64_canary_')
    rc = 0

    with open(GENERATED) as f:
        gen = f.read()
    m = re.search(r"^(fftsa\.nl\._DSP_CODE_B64 = table\.concat\(\{\n')(..)", gen, re.M)
    if m is None:
        raise SystemExit('could not find the first base64 characters to corrupt')
    swapped = m.group(2)[1] + m.group(2)[0]
    if swapped == m.group(2):
        raise SystemExit('the first two base64 characters are equal; pick another canary')
    p = os.path.join(d, 'native_code.tsp')
    with open(p, 'w') as f:
        f.write(gen[:m.start(2)] + swapped + gen[m.end(2):])
    _, _, bad = check(p)
    if bad:
        print('  caught: two transposed base64 characters (%s)' % bad[0][:52])
    else:
        print('  MISSED: two transposed base64 characters')
        rc = 1

    with open(MODULE) as f:
        src = f.read()
    broken = src.replace('math.mod(b, 16) * 16', 'math.mod(b, 15) * 16')
    if broken == src:
        print('  CANARY DID NOT APPLY: the decoder expression has moved')
        return 1
    q = os.path.join(d, 'native_link.tsp')
    with open(q, 'w') as f:
        f.write(broken)
    _, _, bad = check(GENERATED, module=q)
    if bad:
        print('  caught: a wrong mask in the decoder    (%s)' % bad[0][:52])
    else:
        print('  MISSED: a wrong mask in the decoder')
        rc = 1
    return rc


def main():
    if not os.path.exists(LUA502):
        raise SystemExit('no Lua 5.0.2 at %s -- a later Lua accepts code the instrument '
                         'rejects. Set LUA502.' % LUA502)
    if '--self-test' in sys.argv:
        rc = self_test()
        print('self-test %s' % ('passed' if rc == 0 else 'FAILED'))
        return rc
    img_len, rel_len, bad = check(GENERATED)
    for b in bad:
        print('  %s' % b)
    if bad:
        return 1
    print('base64 blob: %d bytes of image and %d of relocations decode byte for byte '
          'under Lua 5.0.2' % (img_len, rel_len))
    return 0


if __name__ == '__main__':
    sys.exit(main())
