/*
 * dsp_native_bounds.h -- address bounds for the native DSP entry point.
 *
 * Every address dsp_native_run writes through arrives from Lua, so each is tested here
 * before use. The predicates are in a header of their own because they are the part
 * whose arithmetic has to be right and the part the instrument cannot safely be used to
 * test: asking the DMM whether a write to a device register is refused is itself the
 * dangerous operation. test/dsp_native_bounds_test.cc exercises them on the host.
 *
 * The constants come from the 1.7.17a section table, documented in fwmem-SAFETY.md:
 *
 *   .vectors  0x00000000              exception vectors
 *   .text     0x00004000-0x0052567C   running instruction stream
 *   .rodata   0x005256C0-0x006E4F6C
 *   .data     0x006E4F70-0x009C6A3C
 *   .bss      0x009C6A40-0x00FE5548
 *   buffers   adjacent to .bss        splash, flash, ethernet, debug: live I/O
 *   .heap     0x01036000-0x0D836000   the only writable region
 *   stacks    0x0D836000-0x0D84A000   .stack .kstack .cstack .mcstack
 *   above     0x0D84A000-0x0FFFFFFF   page table and unmapped gaps
 *   DRAM end  0x10000000
 *   MMIO      0x80000000, 0x90000000, 0xA0000000, 1 MB each: never touched, not even
 *                                     read, because a load from a device register has
 *                                     side effects
 *   flash     0xFE000000-0xFFFFFFFF   never written
 *
 * They shift between firmware builds and are a backstop only: the primary bound is the
 * window Lua declares in the params struct, re-derived from the section table each run.
 * A write must pass both.
 */
#ifndef DSP_NATIVE_BOUNDS_H
#define DSP_NATIVE_BOUNDS_H

#include <stdint.h>

#define DSPN_HEAP_LO   0x01036000U
#define DSPN_HEAP_HI   0x0D836000U
#define DSPN_DRAM_END  0x10000000U
#define DSPN_TEXT_LO   0x00004000U
#define DSPN_TEXT_HI   0x00527000U

/* One reading-buffer chunk payload.  0x8010 is the allocator's block size, not a pitch:
 * payloads are placed independently and the second can sit below the first.  So a window
 * covering several chunks necessarily also covers whatever lies between them, and the
 * window alone is not a tight enough bound for a chunk access. */
#define DSPN_CHUNK_BYTES  32768U

/* Is [a, a+n) wholly inside [lo, hi)?  A zero-length range touches nothing and is
 * permitted anywhere; a range that wraps at 32 bits is not. */
static int dspn_range_ok(uint32_t a, uint32_t n, uint32_t lo, uint32_t hi)
{
    uint32_t e = a + n;
    if (n == 0U) { return 1; }
    if (e < a)   { return 0; }
    if (a < lo)  { return 0; }
    if (e > hi)  { return 0; }
    return 1;
}

/* Writable at all: the documented heap, which excludes .text, .rodata, .data, .bss, the
 * I/O buffers below the heap, the four call stacks above it, MMIO and flash. */
static int dspn_heap_ok(uint32_t a, uint32_t n)
{
    return dspn_range_ok(a, n, DSPN_HEAP_LO, DSPN_HEAP_HI);
}

/* Readable at all: DRAM. Everything at or above 0x10000000 is refused, which covers the
 * unmapped gap, all three MMIO windows and flash. */
static int dspn_dram_ok(uint32_t a, uint32_t n)
{
    return dspn_range_ok(a, n, 0U, DSPN_DRAM_END);
}

/* A resolved library address has to point into firmware .text. */
static int dspn_text_ok(uint32_t a)
{
    return (a >= DSPN_TEXT_LO && a < DSPN_TEXT_HI) ? 1 : 0;
}

/* The two-sided test every write goes through: inside the window Lua declared, and
 * inside the backstop. */
static int dspn_write_ok(uint32_t a, uint32_t n, uint32_t lo, uint32_t hi)
{
    return (dspn_range_ok(a, n, lo, hi) != 0 && dspn_heap_ok(a, n) != 0) ? 1 : 0;
}

/* The read equivalent, for capture storage. */
static int dspn_read_ok(uint32_t a, uint32_t n, uint32_t lo, uint32_t hi)
{
    return (dspn_range_ok(a, n, lo, hi) != 0 && dspn_dram_ok(a, n) != 0) ? 1 : 0;
}

/* k elements of `stride` bytes from base, with the multiply guarded against wrapping. */
static int dspn_stride_ok(uint32_t base, uint32_t k, uint32_t stride,
                          uint32_t lo, uint32_t hi, int writable)
{
    if (k == 0U)         { return 1; }
    if (stride == 0U)    { return 0; }
    if (k > 0xFFFFFFFFU / stride) { return 0; }
    return (writable != 0) ? dspn_write_ok(base, k * stride, lo, hi)
                           : dspn_read_ok(base, k * stride, lo, hi);
}

/* A strided walk over one chunk payload: inside the declared window, AND inside the single
 * chunk it starts in.  The second test is what the window cannot do.  Payloads are
 * scattered, so a window covering two of them also covers whatever the allocator put
 * between -- for the pair measured on the instrument, 0x360D600 and 0x36055F0, the span is
 * 65,552 bytes to hold 32,768 bytes of payload each, and 16 bytes of block header in
 * between are not ours.  Without this, a walk could start at one payload and stride across
 * that header into the other, and the window would permit it.
 *
 * It bounds the extent from the base; it does NOT authenticate the base.  There is no list
 * of real payloads here, so an address in the inter-payload header looks like a chunk base
 * and a short walk from it is accepted.  dsp_native_run only ever passes cap_chunk1/2 and
 * out_chunk1/2 straight from the params struct, so a bad base means Lua declared a bad
 * payload -- the same trust boundary as declaring a bad window.  Hence this tightens the
 * window rather than replacing it, and both tests have to pass.
 *
 * base == 0 means "this buffer has no second chunk", which is only consistent with k == 0;
 * a positive count from a null base is a caller bug and is refused rather than clamped. */
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
