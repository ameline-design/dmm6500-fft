/*
 * string.h -- the subset of <string.h> dsp.c uses, for the freestanding PPC target.
 *
 * memset is the only one; dsp_native.c defines it.  See the note there on why it is not
 * bounds-checked.
 */
#ifndef DSP_FREESTANDING_STRING_H
#define DSP_FREESTANDING_STRING_H

#include <stddef.h>

void *memset(void *s, int c, size_t n);

#endif
