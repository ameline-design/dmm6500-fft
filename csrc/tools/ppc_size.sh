#!/bin/sh
# Text and data size of dsp.c cross-compiled for the target: 32-bit big-endian PowerPC.
#
# The e300c4 is a 603e derivative, so -mcpu=603e is the closest CPU clang models. Compiled
# -ffreestanding because there is no PowerPC sysroot here; the library needs five headers and
# clang supplies four of them freestanding (stddef, stdint, limits, float), so only math.h and
# string.h are stubbed below, declaring exactly the functions dsp.c calls. The stubs change no
# code generation -- they are declarations -- so the byte counts are the real ones.
#
# Reports the band-pass build and the low-pass-only build (-DDSP_BANDPASS=0) so the cost of the
# band-pass is a measured difference rather than an estimate.
#
# Usage: csrc/tools/ppc_size.sh
set -e

CLANG=${CLANG:-/opt/homebrew/opt/llvm/bin/clang}
SIZE=${SIZE:-/opt/homebrew/opt/llvm/bin/llvm-size}
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

printf '%-22s %10s %10s %10s\n' configuration text rodata data
for opt in -O2 -Os; do
    for bp in 1 0; do
        obj="$STUB/dsp_${opt}_bp${bp}.o"
        "$CLANG" $FLAGS "$opt" -DDSP_BANDPASS=$bp -I"$STUB" -I"$HERE" -c -o "$obj" "$HERE/dsp.c"
        # sysv output is one section a line. rodata matches every .rodata* PREFIX and
        # .data.rel.ro: naming the suffixes individually missed .rodata.cst4, which holds
        # every float literal, and .data.rel.ro, which holds the string table a switch over
        # return codes compiles to. Together they were 836 of 1104 bytes, so the figure this
        # printed was a quarter of the real one.
        text=$("$SIZE" --format=sysv "$obj" | awk '$1==".text"{print $2}')
        rodata=$("$SIZE" --format=sysv "$obj" |
                 awk 'index($1,".rodata")==1||$1==".data.rel.ro"{s+=$2}END{print s+0}')
        data=$("$SIZE" --format=sysv "$obj" | awk '$1==".data"||$1==".sdata"||$1==".sdata2"{s+=$2}END{print s+0}')
        label="$opt $([ "$bp" = 1 ] && echo 'band-pass' || echo 'low-pass only')"
        printf '%-22s %10s %10s %10s\n' "$label" "${text:-0}" "$rodata" "$data"
    done
done

echo
echo "target check:"
"$CLANG" $FLAGS -O2 -DDSP_BANDPASS=1 -I"$STUB" -I"$HERE" -c -o "$STUB/chk.o" "$HERE/dsp.c"
/opt/homebrew/opt/llvm/bin/llvm-readobj --file-headers "$STUB/chk.o" |
    grep -E 'Class|DataEncoding|Machine' | sed 's/^ */  /'
echo
echo "external references (nothing here may be new to the firmware):"
/opt/homebrew/opt/llvm/bin/llvm-nm --undefined-only "$STUB/chk.o" | sed 's/^ */  /'
