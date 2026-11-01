#!/bin/sh
# Per-symbol text size of dsp.c cross-compiled for the target, so a claim about which
# function costs what is measured rather than apportioned by eye. Same stubs, flags and
# target as ppc_size.sh -- see that script for why they change no code generation.
#
# Usage: csrc/tools/ppc_symsize.sh [optimisation]      (default -O2)
set -e

CLANG=${CLANG:-/opt/homebrew/opt/llvm/bin/clang}
NM=${NM:-/opt/homebrew/opt/llvm/bin/llvm-nm}
SIZE=${SIZE:-/opt/homebrew/opt/llvm/bin/llvm-size}
OPT=${1:--O2}
HERE=$(cd "$(dirname "$0")/.." && pwd)
STUB=$(mktemp -d)
trap 'rm -rf "$STUB"' EXIT

cat > "$STUB/math.h" <<'EOF'
#ifndef STUB_MATH_H
#define STUB_MATH_H
double sin(double);
double cos(double);
double sqrt(double);
double log10(double);
double floor(double);
double ceil(double);
double fabs(double);
float sinf(float);
float cosf(float);
float sqrtf(float);
float log10f(float);
#define isfinite(x) __builtin_isfinite(x)
#endif
EOF

cat > "$STUB/string.h" <<'EOF'
#ifndef STUB_STRING_H
#define STUB_STRING_H
typedef unsigned long size_t_stub_unused;
void *memset(void *, int, unsigned long);
void *memcpy(void *, const void *, unsigned long);
#endif
EOF

FLAGS="--target=powerpc-unknown-eabi -mcpu=603e -ffreestanding -std=c99 -ffp-contract=off"
OBJ="$STUB/dsp.o"
"$CLANG" $FLAGS "$OPT" -DDSP_BANDPASS=1 -I"$STUB" -I"$HERE" -c -o "$OBJ" "$HERE/dsp.c"

echo "dsp.c at $OPT, powerpc-unknown-eabi -mcpu=603e"
echo
printf '%8s  %-10s %s\n' bytes kind symbol
# posix format is "name kind value size" with both numbers in hex. Converted in python
# because BWK awk, which is what macOS ships, has no strtonum.
"$NM" --print-size --format=posix "$OBJ" | python3 -I -c '
import sys
KIND = {"T": "text", "t": "text", "r": "rodata", "R": "rodata", "d": "data", "D": "data"}
rows = []
for line in sys.stdin:
    f = line.split()
    if len(f) >= 4 and f[1] in KIND:
        rows.append((int(f[3], 16), KIND[f[1]], f[0]))
for n, k, s in sorted(rows, reverse=True):
    print("%8d  %-10s %s" % (n, k, s))
print("%8d  %-10s %s" % (sum(n for n, k, _ in rows if k == "text"), "text", "== TOTAL"))
'

echo
echo "section totals:"
"$SIZE" --format=sysv "$OBJ" | awk 'NR>2 && $2 ~ /^[0-9]+$/ {printf "  %-18s %8d\n", $1, $2}'
