/*
 * Address predicates shared by the freestanding entry point and its host tests.
 * A declared window can restrict but never expand the compiled memory bounds.
 */
#ifndef DSP_NATIVE_BOUNDS_H
#define DSP_NATIVE_BOUNDS_H

#include <stdint.h>

#define DSPN_DRAM_LO   0x00003000U
#define DSPN_DRAM_END  0x10000000U
#define DSPN_TEXT_LO   0x00004000U
#define DSPN_TEXT_HI   0x00527000U

/* A 32 KiB payload is not an address stride: allocator chunks are independent. */
#define DSPN_CHUNK_BYTES  32768U

/* The wire ABI stores 32-bit addresses. Host tests translate those offsets into a backing array. */
#ifdef DSPN_HOST
extern unsigned char *dspn_host_base;
extern uintptr_t dspn_host_fp(uint32_t a);

/* Preserve the null address independently of the host arena base. */
static uint32_t dspn_host_addr(const void *q)
{
    if (q == NULL) { return 0U; }
    return (uint32_t)((uintptr_t)q - (uintptr_t)dspn_host_base);
}
#define DSPN_P(a)  ((uintptr_t)dspn_host_base + (uintptr_t)(a))
#define DSPN_A(q)  dspn_host_addr(q)
/* Cast a pointer-sized integer, not the return expression of the translation function. */
#define DSPN_FP(a) (dspn_host_fp(a) + (uintptr_t)0)
#else
#define DSPN_P(a)  ((uintptr_t)(a))
#define DSPN_A(q)  ((uint32_t)(uintptr_t)(q))
#define DSPN_FP(a) ((uintptr_t)(a))
#endif

/* Cap descriptor vector length independently of the number of blocks in one DSP record. */
#define DSPN_MAX_NCHUNKS  4096U

/* Empty ranges touch nothing. Refuse wrapped endpoints before testing containment. */
static int dspn_range_ok(uint32_t a, uint32_t n, uint32_t lo, uint32_t hi)
{
    uint32_t e = a + n;
    if (n == 0U) { return 1; }
    if (e < a)   { return 0; }
    if (a < lo)  { return 0; }
    if (e > hi)  { return 0; }
    return 1;
}

/* The backstop permits DRAM except for exception vectors and firmware text. */
static int dspn_backstop_ok(uint32_t a, uint32_t n)
{
    if (dspn_range_ok(a, n, DSPN_DRAM_LO, DSPN_DRAM_END) == 0) { return 0; }

    if (a < DSPN_TEXT_HI && a + n > DSPN_TEXT_LO) { return 0; }
    return 1;
}

/* Reads may cover DRAM but not unmapped gaps or device windows. */
static int dspn_dram_ok(uint32_t a, uint32_t n)
{
    return dspn_range_ok(a, n, 0U, DSPN_DRAM_END);
}

/* Check the firmware text range; this predicate does not check alignment. */
static int dspn_text_ok(uint32_t a)
{
    return (a >= DSPN_TEXT_LO && a < DSPN_TEXT_HI) ? 1 : 0;
}

/* Check both the declared window and compiled writable range. */
static int dspn_write_ok(uint32_t a, uint32_t n, uint32_t lo, uint32_t hi)
{
    return (dspn_range_ok(a, n, lo, hi) != 0 && dspn_backstop_ok(a, n) != 0) ? 1 : 0;
}

static int dspn_read_ok(uint32_t a, uint32_t n, uint32_t lo, uint32_t hi)
{
    return (dspn_range_ok(a, n, lo, hi) != 0 && dspn_dram_ok(a, n) != 0) ? 1 : 0;
}

/* Guard the strided byte-count multiply before checking the range. */
static int dspn_stride_ok(uint32_t base, uint32_t k, uint32_t stride,
                          uint32_t lo, uint32_t hi, int writable)
{
    if (k == 0U)         { return 1; }
    if (stride == 0U)    { return 0; }
    if (k > 0xFFFFFFFFU / stride) { return 0; }
    return (writable != 0) ? dspn_write_ok(base, k * stride, lo, hi)
                           : dspn_read_ok(base, k * stride, lo, hi);
}

/* Check the strided walk against both the declared window and the specific chunk it starts in. */
static int dspn_chunk_stride_ok(uint32_t base, uint32_t k, uint32_t stride,
                                uint32_t lo, uint32_t hi, int writable)
{
    if (k == 0U)    { return 1; }
    if (base == 0U) { return 0; }
    if (base > 0xFFFFFFFFU - DSPN_CHUNK_BYTES) { return 0; }
    if (dspn_stride_ok(base, k, stride, base, base + DSPN_CHUNK_BYTES, writable) == 0) {
        return 0;
    }
    return dspn_stride_ok(base, k, stride, lo, hi, writable);
}

#endif
