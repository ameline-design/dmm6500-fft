/*
 * dsp_native_bounds.h -- address bounds for the native DSP entry point.
 *
 * Every address dsp_native_run writes through arrives from Lua, so each is tested here
 * before use. The predicates are in a header of their own because they are the part
 * whose arithmetic has to be right and the part the instrument cannot safely be used to
 * test: asking the DMM whether a write to a device register is refused is itself the
 * dangerous operation. test/dsp_native_bounds_test.cc exercises them on the host.
 *
 * What is compiled in here is the address map the processor and the board give us, not
 * the one a firmware build gives us:
 *
 *   .vectors  0x00000000-0x00003000   exception vectors, never ours to write
 *   .text     0x00004000-TEXT_HI      running instruction stream, never written; the one
 *                                     section span that holds across models, and below
 *                                     every measured build's heap floor
 *   DRAM end  0x10000000
 *   MMIO      0x80000000, 0x90000000, 0xA0000000, 1 MB each: never touched, not even
 *                                     read, because a load from a device register has
 *                                     side effects
 *   flash     0xFE000000-0xFFFFFFFF   never written
 *
 * Section addresses are deliberately not here. They differ per model -- a DMM7510's heap
 * runs 7.6 MB below and 32.4 MB above a DMM6500's, 17% of it -- so a compiled section
 * bound refuses good addresses on a model it was not measured on, and the app then works
 * or fails by where the allocator happened to land a buffer. The bound that does the
 * work is the window Lua declares in the params struct, derived each run from the chunk
 * vector of the buffer being written, which is the allocator's own answer and so is tight
 * on any model. A write must pass that, this, and the per-chunk containment test below.
 *
 * .text is the exception: it is a call target rather than a destination, the span is a
 * property of the image the app is running against, and TEXT_HI holds with 6 KB to spare
 * across every 6500 and 7510 build measured.
 */
#ifndef DSP_NATIVE_BOUNDS_H
#define DSP_NATIVE_BOUNDS_H

#include <stdint.h>

#define DSPN_DRAM_LO   0x00003000U
#define DSPN_DRAM_END  0x10000000U
#define DSPN_TEXT_LO   0x00004000U
#define DSPN_TEXT_HI   0x00527000U

/* One reading-buffer chunk payload.  0x8010 is the allocator's block size, not a pitch:
 * payloads are placed independently and the second can sit below the first.  So a window
 * covering several chunks necessarily also covers whatever lies between them, and the
 * window alone is not a tight enough bound for a chunk access. */
#define DSPN_CHUNK_BYTES  32768U

/* The longest chunk vector a capture buffer may own.
 *
 * NOT the number of blocks a record spans.  That is DSP_MAX_SRC_BLOCKS, and it bounds the
 * pointer array dsp_src carries.  A buffer's vector is as long as its CAPACITY needs, and
 * the record using it is usually a small part of that: 65,536 readings of 24 bytes is 49
 * entries and of 20 bytes is 41, while a 2048-sample record out of either spans 2.  The two
 * figures are a factor of twenty apart at the short counts, which is why they cannot share
 * a bound -- capping the vector length at DSP_MAX_SRC_BLOCKS refused a DMM6500's own capture
 * outright, measured on the instrument as DSPN_ECAPTURE.
 *
 * The bound exists so that `nchunks * 4`, the byte length the vector's range test is given,
 * cannot wrap a uint32 and present as a zero-length range -- which dspn_range_ok permits at
 * any address, the vector page and the device registers included.  4096 is the figure
 * native_link.tsp's _read_desc_1 refuses a descriptor at, so the two sides agree on it. */
#define DSPN_MAX_NCHUNKS  4096U

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

/* Writable at all: DRAM, less the exception vectors and less the running instruction
 * stream.  That excludes MMIO, flash and the unmapped gap above DRAM by being outside
 * DRAM, and .text by name.
 *
 * .text is in here and the data sections are not, because the span of .text is the one
 * section figure that holds across models: every 6500 and 7510 build measured starts it
 * at 0x00004000 and ends it below TEXT_HI, and every one of them puts the heap floor
 * ABOVE TEXT_HI -- 0x008A2000 on a 7510, 0x01034000 on the oldest 6500 -- so refusing
 * this span costs no legitimate address anywhere.  A .data or .bss bound has no such
 * margin: those addresses differ per model, and compiling one in would refuse good heap
 * on a model it was not measured on.  Keeping those off is the declared window's job. */
static int dspn_backstop_ok(uint32_t a, uint32_t n)
{
    if (dspn_range_ok(a, n, DSPN_DRAM_LO, DSPN_DRAM_END) == 0) { return 0; }
    /* The wrap case is already refused above, so a + n cannot have wrapped here. */
    if (a < DSPN_TEXT_HI && a + n > DSPN_TEXT_LO) { return 0; }
    return 1;
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
    return (dspn_range_ok(a, n, lo, hi) != 0 && dspn_backstop_ok(a, n) != 0) ? 1 : 0;
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
