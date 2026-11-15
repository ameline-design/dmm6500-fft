#!/usr/bin/env python3
"""Gate: the Lua params packer against the C struct it is a wire format for.

dsp_native_params is written by fftsa.nl.write_params as a flat sequence of big-endian
words and read by dsp_native_run as a struct. Nothing in either language connects the two,
and a field added, removed or moved on one side only shifts every word after it -- so
dsp_native_run reads cap_chunk1 out of what Lua wrote as plan_addr, which is a heap address
that passes the bounds test and is simply the wrong one. That is a wrong answer or a write
into somebody else's allocation, not a refusal, which is why this is a build gate.

Three things are checked:

  * the C field count, the Lua word count and fftsa.nl.PARAM_WORDS all agree, and so does
    sizeof(dsp_native_params) where a generated module reports it;
  * position by position, the Lua expression names the C field it stands for -- via the
    alias table below for the words that cannot, being a constant, a resolved firmware
    address or half of a double;
  * each double's two halves come from f64_words of the matching field, so swapping two
    pairs is caught rather than passing on the alias alone.

And the same for the SECOND wire format the native path carries: the graph ring block, whose
header dsp_native_run reads as pb[0], pb[1], ... and fftsa.nl.px_block packs as a flat table.
It fails the same way -- a word inserted on one side shifts every one after it, so the image
reads the record stride out of what Lua wrote as the field offset, and the y triples land
somewhere plausible inside the ring rather than nowhere.  The Lua side checks the COUNT at
runtime against the figure the image reports; what it cannot see is two words transposed, and
that is what the order check here is for.

    python3 -I csrc/tools/check_params_layout.py
    python3 -I csrc/tools/check_params_layout.py --self-test
"""
import os
import re
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CSRC = os.path.join(ROOT, 'csrc', 'dsp_native.c')
MODULE = os.path.join(ROOT, 'tsp', 'native_link.tsp')
GENERATED = os.path.join(ROOT, 'tsp', 'native_code.tsp')

# Words whose Lua expression cannot carry the C field's name. Everything absent from here
# is required to mention its own field name, so forgetting to add an entry is a failure.
ALIAS = {
    'magic': 'MAGIC',
    'status': 'STATUS_UNSET',
    'sin_addr': 'fn.sin',
    'cos_addr': 'fn.cos',
    'sqrt_addr': 'fn.sqrt',
    'log10_addr': 'fn.log10',
    'floor_addr': 'fn.floor',
    'ceil_addr': 'fn.ceil',
    'red_f0_hi': 'f0h', 'red_f0_lo': 'f0l',
    'red_binhz_hi': 'bwh', 'red_binhz_lo': 'bwl',
    'red_dbmin_hi': 'dnh', 'red_dbmin_lo': 'dnl',
    'red_dbmax_hi': 'dxh', 'red_dbmax_lo': 'dxl',
    'red_vfloor_hi': 'vfh', 'red_vfloor_lo': 'vfl',
}

# The ring block's header, C name to the Lua expression that fills it. Every word is here
# because not one of them can carry its own C name: the C side names locals and the Lua side
# names fields of the px state.
PX_ALIAS = {
    'plo': 'g.lo',
    'phi': 'g.hi',
    'ring': 'lo',
    'stride': 'stride',
    'yoff': 'yoff',
    'nrec': 'nrec',
    'ymax': 'nl.PX_YMAX',
    'ay_hi': 'ayh', 'ay_lo': 'ayl',
    'by_hi': 'byh', 'by_lo': 'byl',
}

STRUCT_RE = re.compile(r'typedef struct \{(.*?)\} dsp_native_params;', re.S)
FIELD_RE = re.compile(r'^\s*uint32_t\s+([^;]+);', re.M)
WORDS_RE = re.compile(r'\n  local w = \{(.*?)\n  \}', re.S)
PW_RE = re.compile(r'^fftsa\.nl\.PARAM_WORDS\s*=\s*(\d+)', re.M)
SIZEOF_RE = re.compile(r'^fftsa\.nl\.SIZEOF_PARAMS\s*=\s*(\d+)', re.M)
HALVES_RE = re.compile(r'local (\w+), (\w+) = f64_words\(t\.(\w+) or 0\)')


def strip_comments(s):
    s = re.sub(r'/\*.*?\*/', '', s, flags=re.S)
    return re.sub(r'//[^\n]*', '', s)


def c_fields(src):
    m = STRUCT_RE.search(src)
    if not m:
        raise SystemExit('dsp_native_params not found in %s' % CSRC)
    names = []
    for decl in FIELD_RE.findall(strip_comments(m.group(1))):
        for one in decl.split(','):
            names.append(one.strip())
    return names


def lua_words(src):
    m = WORDS_RE.search(src)
    if not m:
        raise SystemExit('the `local w = {` table was not found in write_params')
    body = re.sub(r'--[^\n]*', '', m.group(1))
    return [w.strip() for w in body.replace('\n', ' ').split(',') if w.strip()]


PX_PLAIN_RE = re.compile(r'^\s*(\w+)\s*=\s*pb\[(\d+)\];', re.M)
PX_PAIR_RE = re.compile(r'^\s*(\w+)\s*=\s*pw_double\(pb\[(\d+)\], pb\[(\d+)\]\);', re.M)
PX_LUA_RE = re.compile(r'\n  local b = \{(.*?)\}\n', re.S)
PX_HDR_RE = re.compile(r'^#define DSPN_PX_HDR\s+(\d+)U', re.M)


def px_reads(src):
    """The header words dsp_native_run reads, in index order, as C names.

    From the assignments rather than from the comment above them: a comment can be right
    while the code is not, and it is the code that decides where the stride comes from.
    """
    at = {}
    for name, i in PX_PLAIN_RE.findall(src):
        at[int(i)] = name
    for name, hi, lo in PX_PAIR_RE.findall(src):
        at[int(hi)] = name + '_hi'
        at[int(lo)] = name + '_lo'
    if not at:
        raise SystemExit('no pb[] reads found in %s' % CSRC)
    return [at.get(i) for i in range(max(at) + 1)]


def px_words(src):
    m = PX_LUA_RE.search(src)
    if not m:
        raise SystemExit('the `local b = {` table was not found in px_block')
    body = re.sub(r'--[^\n]*', '', m.group(1))
    return [w.strip() for w in body.replace('\n', ' ').split(',') if w.strip()]


def check_px(csrc, lua):
    """The ring block: the C reads, the Lua packs, and DSPN_PX_HDR says how many."""
    bad = []
    reads = px_reads(strip_comments(csrc))
    words = px_words(lua)
    hdr = PX_HDR_RE.search(csrc)
    if not hdr:
        bad.append('DSPN_PX_HDR not found in %s' % CSRC)
    elif int(hdr.group(1)) != len(reads):
        bad.append('DSPN_PX_HDR is %s, the image reads %d header words'
                   % (hdr.group(1), len(reads)))
    if len(words) != len(reads):
        bad.append('px_block packs %d block words, the image reads %d'
                   % (len(words), len(reads)))
    for i, name in enumerate(reads):
        if i >= len(words):
            break
        if name is None:
            bad.append('block word %d is read by nothing in the image' % i)
            continue
        want = PX_ALIAS.get(name)
        if want is None:
            bad.append('block word %d is read as %r, which has no entry in PX_ALIAS'
                       % (i, name))
        elif words[i] != want:
            bad.append('block word %d is %r, expected %r (read as %s)'
                       % (i, words[i], want, name))
    return reads, bad


def check(csrc_path, module_path, generated_path):
    with open(csrc_path) as f:
        csrc = f.read()
    with open(module_path) as f:
        lua = f.read()
    fields = c_fields(csrc)
    words = lua_words(lua)
    bad = []

    pw = PW_RE.search(lua)
    if not pw:
        bad.append('fftsa.nl.PARAM_WORDS not found in %s' % module_path)
    elif int(pw.group(1)) != len(fields):
        bad.append('PARAM_WORDS is %s, struct has %d fields'
                   % (pw.group(1), len(fields)))
    if len(words) != len(fields):
        bad.append('write_params packs %d words, struct has %d fields'
                   % (len(words), len(fields)))

    if os.path.exists(generated_path):
        with open(generated_path) as f:
            gen = f.read()
        so = SIZEOF_RE.search(gen)
        if so and int(so.group(1)) != 4 * len(fields):
            bad.append('SIZEOF_PARAMS is %s in the generated module, struct is %d bytes '
                       '-- rebuild the dsp_native_bin target'
                       % (so.group(1), 4 * len(fields)))

    halves = {}
    for hi, lo, base in HALVES_RE.findall(lua):
        halves[hi] = (base, 'hi')
        halves[lo] = (base, 'lo')

    for i, name in enumerate(fields):
        if i >= len(words):
            break
        want = ALIAS.get(name, name)
        if want not in words[i]:
            bad.append('word %d is %r, expected it to name %r (field %s)'
                       % (i, words[i], want, name))
            continue
        if name in ('magic',) or not name.startswith('red_'):
            continue
        # A double's halves: the local has to come from f64_words of this very field.
        for suffix in ('_hi', '_lo'):
            if name.endswith(suffix):
                base, half = halves.get(words[i], (None, None))
                if base != name[:-len(suffix)] or half != suffix[1:]:
                    bad.append('word %d (%s) is %r, which f64_words fills from %r'
                               % (i, name, words[i], base))

    _, pxbad = check_px(csrc, lua)
    bad.extend(pxbad)
    return fields, words, bad


def self_test():
    """Three plausible slips, each of which must be caught."""
    with open(CSRC) as f:
        csrc = f.read()
    with open(MODULE) as f:
        lua = f.read()
    cases = [
        ('a C field added with no Lua word',
         csrc.replace('    uint32_t red_nseg;',
                      '    uint32_t red_future;\n    uint32_t red_nseg;'), lua),
        ('two Lua words transposed',
         csrc, lua.replace('t.red_k0 or 0, t.red_k1 or 0,',
                           't.red_k1 or 0, t.red_k0 or 0,')),
        ('two double pairs swapped',
         csrc, lua.replace('f0h, f0l, bwh, bwl,', 'bwh, bwl, f0h, f0l,')),
        ('the ring block read one word further along',
         csrc.replace('        yoff   = pb[4];', '        yoff   = pb[5];'), lua),
        ('two ring block words transposed in Lua',
         csrc, lua.replace('lo, stride, yoff, nrec,', 'lo, yoff, stride, nrec,')),
        ('a ring block word added in Lua only',
         csrc, lua.replace('nl.PX_YMAX, ayh', 'nl.PX_YMAX, 0, ayh')),
    ]
    rc = 0
    for name, c, l in cases:
        if c == csrc and l == lua:
            print('  CANARY DID NOT APPLY: %s' % name)
            rc = 1
            continue
        cd = tempfile.mkdtemp(prefix='params_canary_')
        cp, lp = os.path.join(cd, 'c.c'), os.path.join(cd, 'l.tsp')
        with open(cp, 'w') as f:
            f.write(c)
        with open(lp, 'w') as f:
            f.write(l)
        _, _, bad = check(cp, lp, os.path.join(cd, 'absent.tsp'))
        if bad:
            print('  caught: %-32s (%s)' % (name, bad[0][:60]))
        else:
            print('  MISSED: %s' % name)
            rc = 1
    return rc


def main():
    if '--self-test' in sys.argv:
        rc = self_test()
        print('self-test %s' % ('passed' if rc == 0 else 'FAILED'))
        return rc
    fields, words, bad = check(CSRC, MODULE, GENERATED)
    for b in bad:
        print('  %s' % b)
    if bad:
        print('params layout: %d problem(s)' % len(bad))
        return 1
    reads, _ = check_px(open(CSRC).read(), open(MODULE).read())
    print('params layout: %d words agree field for field, and the ring block %d'
          % (len(fields), len(reads)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
