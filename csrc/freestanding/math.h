/* Math declarations for the freestanding PowerPC image; dsp_native.c supplies the definitions. */
#ifndef DSP_FREESTANDING_MATH_H
#define DSP_FREESTANDING_MATH_H

double sin(double x);
double cos(double x);
double sqrt(double x);
double log10(double x);
double floor(double x);
double ceil(double x);
double fabs(double x);

#define isfinite(x) __builtin_isfinite(x)
#define isnan(x)    __builtin_isnan(x)
#define isinf(x)    __builtin_isinf(x)

#endif
