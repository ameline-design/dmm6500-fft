/*
 * math.h -- the subset of <math.h> dsp.c uses, for the freestanding PPC target.
 *
 * The cross build runs with -ffreestanding against a bare powerpc-unknown-elf triple,
 * which has no C library headers at all.  dsp.c needs declarations for the functions it
 * calls and the classification macros it tests; the definitions come from dsp_native.c,
 * which forwards each one to the firmware's GHS math library.
 *
 * Only on the include path for the DSP_DST_NATIVE target.  Host builds use the real
 * header and link libm.
 */
#ifndef DSP_FREESTANDING_MATH_H
#define DSP_FREESTANDING_MATH_H

double sin(double x);
double cos(double x);
double sqrt(double x);
double log10(double x);
double floor(double x);
double ceil(double x);
double fabs(double x);

/* Compiled inline by clang; no library call and no firmware address needed. */
#define isfinite(x) __builtin_isfinite(x)
#define isnan(x)    __builtin_isnan(x)
#define isinf(x)    __builtin_isinf(x)

#endif
