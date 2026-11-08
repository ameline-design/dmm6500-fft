/*
 * dsp_native.c  --  lua_CFunction glue between native_link and dsp.c.
 *
 * Compiled for PowerPC e300c4 (big-endian) and loaded into the instrument's heap via
 * the mechanism in tsp/native_link.tsp.
 *
 * Load address and relocation
 * ---------------------------
 * The binary lands at a heap address chosen at startup, so it has to tolerate being
 * somewhere other than where it was linked.  Function calls are PC-relative and need
 * nothing, but on PPC32 a data reference is `lis rX,hi` + `lfd fY,lo(rX)` -- an absolute
 * address fixed at link time.  dsp.c alone emits 355 of those, for its float constants,
 * its string table and its window coefficient table.
 *
 * They are fixed up at install time: the build emits a relocation table beside the
 * binary, and nl.relocate() patches each immediate for the real load address before the
 * first call.  See csrc/tools/emit_reloc.py and fftsa.nl.relocate.
 *
 * Because relocation runs, this file may use globals -- their absolute references are
 * patched like any other.  The math function pointers below are globals for that reason;
 * threading them through every dsp.c call site would be the alternative.
 *
 * Memory safety
 * -------------
 * Every address this code writes through arrives from Lua in the params struct, so
 * every one is validated before use, at entry, against two independent bounds:
 *
 *   1. The region Lua declares it owns (params->wr_lo .. wr_hi), which is the chunk
 *      storage of buffers the app allocated.
 *   2. A compiled-in backstop of the documented heap extent, so a params struct that
 *      is garbage cannot widen the window.
 *
 * A write that fails either test aborts the call with a negative status.  Nothing is
 * written before every pointer has passed, so a refusal leaves memory untouched.
 *
 * Params struct  (matches tsp/native_link.tsp nl.write_params)
 * -----------------------------------------------------------
 * Field order here and in write_params must agree exactly; see DSP_NATIVE_PARAM_WORDS.
 *
 * Firmware addresses
 * ------------------
 * None.  The params address is patched into dspn_params_addr at install time, the status
 * is returned through a field of the struct rather than through lua_pushnumber, and the
 * six math entry points arrive in the struct from FNF, which finds them at runtime.  So
 * the image never reads the Lua stack and nothing in it is pinned to a firmware build.
 *
 * Build
 * -----
 *   cmake -B build-ppc -DCMAKE_TOOLCHAIN_FILE=csrc/toolchain-ppc-clang.cmake \
 *         -DDSP_DST_NATIVE=ON
 *   cmake --build build-ppc --target dsp_native_bin
 */

#include <stddef.h>
#include <stdint.h>
#include "dsp.h"

typedef double (*math1_fn)(double);

/* The params struct address, written here by fftsa.nl.init once the image is relocated
 * and before anything calls it.  A global rather than a Lua argument because reading an
 * argument means calling lua_tostring and a hex parser, which are firmware addresses; the
 * address is fixed for the life of an install, so there is nothing to pass per call.
 *
 * Volatile because nothing in this translation unit writes it and the write comes from
 * outside the program.  The loader finds the slot by symbol: csrc/tools/emit_reloc.py
 * emits its offset as fftsa.nl.PARAMS_SLOT. */
volatile uint32_t dspn_params_addr;

/* The address bounds and the predicates built on them.  In a header of their own so the
 * host suite tests the code that ships rather than a copy of it; see
 * test/dsp_native_bounds_test.cc, which covers every forbidden region by name. */
#include "dsp_native_bounds.h"

#define BACKSTOP_LO  DSPN_DRAM_LO
#define BACKSTOP_HI  DSPN_DRAM_END
#define DRAM_END     DSPN_DRAM_END

/* Status pushed back to Lua.  Non-negative is a bin count; negative is a refusal. */
#define DSPN_OK            0
#define DSPN_EMAGIC      (-1)
#define DSPN_EBOUNDS     (-2)
#define DSPN_EPLAN       (-3)
#define DSPN_EGEOM       (-4)
#define DSPN_ECAPTURE    (-5)
#define DSPN_EOUTPUT     (-6)
#define DSPN_EDESC       (-7)
#define DSPN_EARENA      (-8)
#define DSPN_ESCRATCH    (-9)
#define DSPN_ERUN       (-10)
#define DSPN_EMATH      (-11)
#define DSPN_EREDUCE    (-12)
#define DSPN_ERESULT    (-13)

/* What Lua writes into p->status before the call, and no exit here ever writes.  Reading
 * it back afterwards means the call did not return through any of them. */
#define DSPN_STATUS_UNSET  0x7FFFFFFF

/* Report and return.  Zero Lua results, because the status does not travel on the Lua
 * stack: pushing one would mean calling lua_pushnumber, a firmware address. */
#define RET(v)  do { *st = (uint32_t)(int32_t)(v); return 0; } while (0)

#define DSP_NATIVE_MAGIC  0x44535031U   /* 'DSP1' */

typedef struct {
    uint32_t magic;        /* DSP_NATIVE_MAGIC, or the struct was never written     */
    uint32_t mode;         /* DSPN_MODE_INIT or DSPN_MODE_RUN                       */

    /* The plan, the capture and the graph buffer are three separate allocations, so
     * each gets its own window rather than one span loose enough to cover all three. */
    uint32_t wr_lo;        /* plan struct, arena and scratch                        */
    uint32_t wr_hi;        /* one past the end                                      */
    uint32_t rd_lo;        /* capture chunk storage, read only                      */
    uint32_t rd_hi;
    uint32_t out_lo;       /* graph buffer chunk storage                            */
    uint32_t out_hi;

    /* The plan arena, as chunk payloads. Chunk payloads are placed independently by the
     * allocator, so a multi-chunk arena is not one region and dsp_plan_init_segs is what
     * lays the arrays out across them. One chunk is just nsegs == 1. */
    uint32_t seg_bytes;    /* payload size of one chunk, a multiple of DSP_ALIGN     */
    uint32_t nsegs;        /* chunks given to the arena                             */
    uint32_t segs_addr;    /* nsegs big-endian words: the payload addresses         */

    uint32_t plan_addr;    /* dsp_plan, initialised by dsp_plan_init at startup      */
    uint32_t src_flat;     /* unread.  The record is read in place through cap_vec,  */
                           /* so there is no de-strided copy; the field stays because */
                           /* the struct is a wire format and removing it would shift */
                           /* every word after it.  write_params sends zero.          */

    uint32_t cap_chunk1;   /* capture chunk payloads, reading at +0                  */
    uint32_t cap_chunk2;   /* 0 when the capture fits one chunk                     */
    uint32_t cap_n;        /* samples, a power of two                               */
    uint32_t cap_perchunk; /* elements per chunk, from the descriptor               */
    uint32_t cap_stride;   /* capture element size in bytes.  NOT ASSUMED TO BE 32: */
                           /* a STYLE_STANDARD buffer stores no extra value and is  */
                           /* smaller, and the capture is one.  Measured by          */
                           /* nl._find_storage and cross-checked against the         */
                           /* descriptor's own field.                                */
    uint32_t cap_vec;      /* chunk pointer vector: cap_nchunks big-endian words.    */
                           /* A 16,384-sample record at 24 bytes an element is 12     */
                           /* chunks, so two payload addresses do not reach it.       */
    uint32_t cap_nchunks;  /* chunks the record spans, at most DSP_MAX_SRC_BLOCKS     */

    uint32_t out_chunk1;   /* graph buffer chunk payloads                           */
    uint32_t out_chunk2;
    uint32_t out_perchunk;
    uint32_t out_desc;     /* column descriptor base; the fields written are at the  */
                           /* offsets below, so one address is validated not three   */

    /* What the call reports, read back by Lua with one ki.memread.  Lua writes
     * DSPN_STATUS_UNSET into it before the call and every exit here overwrites it, so a
     * status still reading unset says the call never reached an exit at all.  That is
     * what a branch into the wrong place looks like from Lua, where a return value
     * cannot distinguish it from a clean run. */
    uint32_t status;

    /* Firmware math addresses resolved by FNF; copied into the globals below.      */
    uint32_t sin_addr;
    uint32_t cos_addr;
    uint32_t sqrt_addr;
    uint32_t log10_addr;
    uint32_t floor_addr;
    uint32_t ceil_addr;

    /* DSPN_MODE_INIT only.  beta arrives scaled by 1000 because the struct is packed
     * from Lua as big-endian words; milli-resolution is far finer than the window needs,
     * and it was settled before the word-pair form below existed. */
    uint32_t init_kind;
    uint32_t init_beta_milli;
    uint32_t init_decim;
    uint32_t init_method;

    /* DSPN_MODE_RUN output stage.  The graph reads nseg (dB, Hz) points, not bins, so the
     * run path finishes with dsp_reduce and writes its two arrays into the output buffer's
     * reading and extra-value fields.  Writing the bins instead put volts-squared on a
     * decibel axis. */
    uint32_t red_nseg;       /* trace points; 1..DSP_NSEG_MAX, and the output must hold  */
                             /* one more, for the slot the cursor rewind points at       */
    uint32_t red_k0;         /* first bin of the displayed window                        */
    uint32_t red_k1;         /* last bin, inclusive                                      */
    uint32_t red_db;         /* scratch, red_nseg dsp_real                               */
    uint32_t red_hz;         /* scratch, red_nseg dsp_real                               */
    uint32_t red_sense;      /* dsp_bandmap::sense, +1 or -1, as an int32                 */

    /* Doubles, as big-endian halves.  Lua 5.0.2 has no way to lay out an IEEE754 double,
     * so each arrives as the pair of words math.frexp built; pw_double reassembles them.
     * The decibel window and the voltage floor are graph parameters and the frequency map
     * is measured per frame, so none of them survives a scaled integer: a milli-hertz bin
     * width is 3% out at the rates the narrow spans use. */
    uint32_t red_f0_hi,     red_f0_lo;      /* dsp_bandmap::f0, hertz at bin 0          */
    uint32_t red_binhz_hi,  red_binhz_lo;   /* dsp_bandmap::binhz                       */
    uint32_t red_dbmin_hi,  red_dbmin_lo;   /* trace floor                              */
    uint32_t red_dbmax_hi,  red_dbmax_lo;   /* trace ceiling                            */
    uint32_t red_vfloor_hi, red_vfloor_lo;  /* floor in volts, squared by dsp_reduce    */

    /* The results block: everything a frame produces that is not the trace. */
    uint32_t res_addr;     /* DSPN_RES_BYTES of scratch, 8-aligned                      */
    uint32_t res_npk;      /* peaks to rank, 0..DSPN_RES_PEAKS                          */
    uint32_t res_mains;    /* DSP_THD_MAINS_*, as an int32; -1 is BOTH                  */
} dsp_native_params;

#define DSPN_MODE_INIT   1U
#define DSPN_MODE_RUN    2U
#define DSPN_MODE_BYTES  3U   /* report dsp_plan_bytes and stop; reads nothing but the  */
                              /* params struct, and writes nothing but its status word  */
#define DSPN_MODE_SEGS   4U   /* report dsp_plan_segs for seg_bytes, the same way       */

/* Chunks the arena may span. At the largest n a single chunk can hold an array for, the
 * layout needs six, so this is generous; it bounds a stack array in dsp_native_run. */
#define DSPN_MAX_SEGS    32U

/* The results block.  The peaks and the distortion measurement, as plain doubles that Lua
 * reads with one ki.memread and decodes with math.ldexp.
 *
 * Not a reading buffer, which is how the trace comes back: a buffer would need a chunk of
 * its own, a content scan to find it and a window to validate, and Lua can only read as
 * many elements as the descriptor says are present -- so the scalars would have to sit
 * inside the trace the graph plots.
 *
 * Layout, big-endian doubles:
 *   [0, 2*DSPN_RES_PEAKS)   peaks, amplitude in volts then frequency in hertz, strongest
 *                           first; zero beyond the count reported
 *   then DSPN_RES_SCALARS:  npeaks, thd, thd_ok, snr_db, snr_ok, noise_db, noise_ok,
 *                           f0_hz, amp0, nbins
 *
 * The validity flags are values of their own because 0 dB and 0% are both figures a real
 * spectrum produces, so there is no in-band sentinel -- the same reason ::dsp_thdn carries
 * its own flags rather than zeroing what it did not measure.
 *
 * Past the doubles, and not read by Lua, are dsp_peaks' three output arrays. They live
 * here rather than on the stack because the stack belongs to a firmware task and its size
 * is not known; 320 bytes of it is not a bet worth taking for no gain.
 */
#define DSPN_RES_PEAKS    16
#define DSPN_RES_SCALARS  10
#define DSPN_RES_DOUBLES  (2 * DSPN_RES_PEAKS + DSPN_RES_SCALARS)
#define DSPN_RES_BYTES    ((uint32_t)DSPN_RES_DOUBLES * 8U \
                           + (uint32_t)DSPN_RES_PEAKS * 4U \
                           + 2U * (uint32_t)DSPN_RES_PEAKS * (uint32_t)sizeof(dsp_real))

/* Sizes the Lua side has to agree with, exported so they come from the compiler that
 * built this image rather than from a host build.  The target is 32-bit big-endian
 * PowerPC: a pointer is 4 bytes, so sizeof(dsp_plan) is 1024 here against 1120 on a
 * 64-bit host, and a figure copied from a host build is wrong by 96 bytes.
 *
 * emit_reloc.py reads these out of the linked image and writes them into the generated
 * Lua, so native_link.tsp carries no struct size of its own.
 *
 *   [0] sizeof(dsp_plan)
 *   [1] sizeof(dsp_native_params)
 *   [2] sizeof(dsp_real)
 *   [3] DSP_ALIGN
 *   [4] DSPN_DRAM_LO
 *   [5] DSPN_DRAM_END
 *   [6] DSPN_RES_PEAKS
 *   [7] DSPN_RES_DOUBLES
 *   [8] offsetof(dsp_native_params, status)
 *
 * The backstop bounds are here so the Lua side can sanity-check an address before passing
 * it in, without a second copy of the numbers to drift: a Lua literal and this header
 * would diverge silently the first time one of them changed, and both sides would still
 * look self-consistent. The results-block shape is here for the same reason: Lua
 * reserves the memory and decodes what lands in it, so it needs both figures and must not
 * hold a second copy. And the status offset, because the word Lua reads back after a call
 * has to be the word this file writes, which means not counting the fields twice.
 *
 * Initialised, not tentative: without the initialiser this is a common definition that
 * lands in .bss as zeros and reports nothing.
 */
const uint32_t dsp_native_sizes[9] = {
    (uint32_t)sizeof(dsp_plan),
    (uint32_t)sizeof(dsp_native_params),
    (uint32_t)sizeof(dsp_real),
    (uint32_t)DSP_ALIGN,
    (uint32_t)DSPN_DRAM_LO,
    (uint32_t)DSPN_DRAM_END,
    (uint32_t)DSPN_RES_PEAKS,
    (uint32_t)DSPN_RES_DOUBLES,
    (uint32_t)offsetof(dsp_native_params, status)
};

/* Words in the struct; write_params must pack exactly this many. */
#define DSP_NATIVE_PARAM_WORDS  54

/* Column descriptor field offsets, from the table in fwmem-BUFFER.md.
 *
 * ALL OF THEM, which is what it takes.  Writing the two iterators alone was measured
 * leaving `buf.n` at the seeded 680 after a run that wrote 127 points: the count Lua reads
 * is +0x78, and the descriptor keeps three more copies of it at +0x80, +0x84 and +0x88.
 * Nothing on the trace path caught that -- 127 correct points were read back out of a
 * buffer that still said 680 -- so the trace would have plotted 553 stale segments at the
 * seeded frequencies, which are small numbers and would have piled up against the left
 * edge of the plot at the axis floor.
 *
 * +0x54 and +0x64 are the iterators' owner pointers, both equal to the descriptor base,
 * and +0x74 is a capacity that does not move.  Those three are deliberately not written.
 * +0x14 and +0x7C are not identified and are left alone.
 */
#define DESC_IT1_PTR    0x4CU   /* iterator 1: element pointer, the write cursor */
#define DESC_IT1_IDX    0x50U   /* iterator 1: index */
#define DESC_IT1_CHUNK  0x58U   /* iterator 1: current chunk payload */
#define DESC_IT2_PTR    0x5CU   /* iterator 2, identical to iterator 1 */
#define DESC_IT2_IDX    0x60U
#define DESC_IT2_CHUNK  0x68U
#define DESC_LAST_PTR   0x6CU   /* last written element */
#define DESC_LAST_IDX   0x70U   /* its index */
#define DESC_N          0x78U   /* n, the count buffer.n reports */
#define DESC_N_1        0x80U   /* and three more copies of it */
#define DESC_N_2        0x84U
#define DESC_N_3        0x88U
#define DESC_SPAN       0x8CU   /* past the last field written */

/* -------------------------------------------------------------------------
 * Bounds helpers.  Each takes a byte range and answers whether it is permitted.
 * A zero-length range is permitted anywhere: it touches nothing.
 * -------------------------------------------------------------------------*/

#define range_ok(a, n, lo, hi)  dspn_range_ok((a), (n), (lo), (hi))
#define text_ok(a)              dspn_text_ok(a)

/* Writable: inside the plan window Lua declared, and inside the documented heap. */
static int wr_ok(const dsp_native_params *p, uint32_t a, uint32_t n)
{
    return dspn_write_ok(a, n, p->wr_lo, p->wr_hi);
}

/* Strided element ranges: k elements of `stride` bytes from base.  The capture is read
 * and the output is written, so the two sides go through different gates.
 *
 * Both bases are chunk payloads, so both go through the per-chunk form: the declared
 * window has to cover every chunk of the buffer and the chunks are scattered, which makes
 * the window wider than the payloads it is there to describe. Requiring the walk to stay
 * inside the one chunk it starts in closes that gap. */
static int stride_ok_out(const dsp_native_params *p, uint32_t base,
                         uint32_t k, uint32_t stride)
{
    return dspn_chunk_stride_ok(base, k, stride, p->out_lo, p->out_hi, 1);
}

static int stride_ok_rd(const dsp_native_params *p, uint32_t base,
                        uint32_t k, uint32_t stride)
{
    return dspn_chunk_stride_ok(base, k, stride, p->rd_lo, p->rd_hi, 0);
}

/* -------------------------------------------------------------------------
 * Math functions dsp.c calls.  The firmware's GHS library provides them at
 * addresses FNF resolves at startup; these globals are filled from the params
 * struct on entry and are valid because relocation has patched the references
 * to them.  All take and return a double in f1.
 * -------------------------------------------------------------------------*/
static math1_fn g_sin;
static math1_fn g_cos;
static math1_fn g_sqrt;
static math1_fn g_log10;
static math1_fn g_floor;
static math1_fn g_ceil;

double sin(double x)   { return g_sin(x);   }
double cos(double x)   { return g_cos(x);   }
double sqrt(double x)  { return g_sqrt(x);  }
double log10(double x) { return g_log10(x); }
double floor(double x) { return g_floor(x); }
double ceil(double x)  { return g_ceil(x);  }

/* fabs is a sign-bit clear, cheaper inline than a call through the table. */
double fabs(double x) { return x < 0.0 ? -x : x; }

/*
 * memset is the only C runtime function dsp.c calls, at seven sites, all of the form
 * memset(p, 0, sizeof(*p)) on a struct.  Three of those zero a caller-supplied out
 * struct, which dsp.c's callers put on the stack, and dsp.c documents that zeroing as a
 * contract: a caller that reads the struct after an error sees zeros rather than the
 * previous frame's figures.
 *
 * So this is deliberately unguarded.  A bounds test here would refuse the stack writes
 * and break that contract silently -- the struct would be left uninitialised with the
 * return code unchanged, which the caller cannot detect.  Confinement belongs at the
 * entry point, where the untrusted addresses actually arrive, and that is where
 * dsp_native_run does it.
 */
void *memset(void *s, int c, size_t n)
{
    unsigned char *p = (unsigned char *)s;
    while (n--) { *p++ = (unsigned char)c; }
    return s;
}

/* -------------------------------------------------------------------------
 * Reading buffer element access: elements of `stride` bytes, reading double at +0.
 * -------------------------------------------------------------------------*/

static void rb_write(uint32_t ch1, uint32_t ch2, uint32_t perchunk, int k, double v)
{
    uint32_t idx = (uint32_t)k;
    uint32_t base = (idx < perchunk) ? ch1 : ch2;
    uint32_t off  = (idx < perchunk) ? idx : (idx - perchunk);
    *(double *)(uintptr_t)(base + off * 32U) = v;
}

/* The extra value, a double at +20 in a 32-byte element: 4-aligned and not 8, which is
 * measured rather than assumed -- fwmem-BUFFER.md:90 has the raw element.  Written as two
 * words, because a `double *` the compiler is entitled to assume is 8-aligned would not be
 * one here, and that is undefined whatever the hardware does with the store. */
static void rb_write_extra(uint32_t ch1, uint32_t ch2, uint32_t perchunk, int k, double v)
{
    union { double d; uint32_t w[2]; } u;
    uint32_t idx  = (uint32_t)k;
    uint32_t base = (idx < perchunk) ? ch1 : ch2;
    uint32_t off  = (idx < perchunk) ? idx : (idx - perchunk);
    uint32_t *p   = (uint32_t *)(uintptr_t)(base + off * 32U + 20U);
    u.d = v;
    p[0] = u.w[0];
    p[1] = u.w[1];
}

/* Address of element k, and the payload the chunk it lands in starts at.  Both for the
 * cursor rewind: the descriptor's iterators carry a pointer, an index and the chunk. */
static uint32_t rb_addr(uint32_t ch1, uint32_t ch2, uint32_t perchunk, uint32_t k)
{
    return (k < perchunk) ? (ch1 + k * 32U) : (ch2 + (k - perchunk) * 32U);
}

static uint32_t rb_chunk(uint32_t ch1, uint32_t ch2, uint32_t perchunk, uint32_t k)
{
    return (k < perchunk) ? ch1 : ch2;
}

/* A double from the two big-endian halves Lua packed it as.  A union rather than a cast
 * through `double *`: the params struct is word-aligned, so a double field in it need not
 * be 8-aligned and reading one that way is undefined.  Word order is high half first,
 * which is the target's own, so the pair reads the same way the instrument stores it. */
static double pw_double(uint32_t hi, uint32_t lo)
{
    union { double d; uint32_t w[2]; } u;
    u.w[0] = hi;
    u.w[1] = lo;
    return u.d;
}

/* Byte ranges.  Both callers have already bounded each range inside the backstop, so neither
 * sum can wrap.  A zero-length range touches nothing and so overlaps nothing. */
static int overlaps(uint32_t a, uint32_t an, uint32_t b, uint32_t bn)
{
    if (an == 0U || bn == 0U) { return 0; }
    return (a < b + bn) && (b < a + an);
}

/* Does a range touch the arena?  dsp_plan_init carves its arrays out of the segment bases,
 * so anything else placed inside one is overwritten the next time the plan is built -- or,
 * for the reduction's scratch, overwrites the bins it is reducing. */
static int hits_arena(uint32_t a, uint32_t n, const uint32_t *segs, int nsegs,
                      uint32_t seg_bytes)
{
    int s;
    for (s = 0; s < nsegs; s++) {
        if (overlaps(a, n, segs[s], seg_bytes)) { return 1; }
    }
    return 0;
}

/* -------------------------------------------------------------------------
 * Confine every pointer the plan carries to the chunks the arena was built from.
 *
 * dsp.c writes through these, so this bound is what keeps its stores inside memory we
 * own.  NULL is permitted: the arena holds only what its own decomposition reads, so the
 * arrays belonging to the other method are NULL by design.
 * -------------------------------------------------------------------------*/
static int plan_ptrs_ok(const dsp_plan *pl, const uint32_t *segs, int nsegs,
                        uint32_t seg_bytes)
{
    const void *const ptrs[20] = {
        pl->w,    pl->swp_a, pl->swp_b, pl->sw1_a, pl->sw1_b,
        pl->sw2_a, pl->sw2_b, pl->twr,  pl->twi,   pl->utr,
        pl->uti,  pl->re,    pl->im,    pl->wkr,   pl->wki,
        pl->blkr, pl->blki,  pl->pwr,   pl->h,     pl->fir_out
    };
    int i, s;
    for (i = 0; i < 20; i++) {
        uint32_t a = (uint32_t)(uintptr_t)ptrs[i];
        int inside = 0;
        if (a == 0U) { continue; }
        /* Inside one of the segments. With a segmented arena there is no single range to
         * test against, and an array that straddled two would pass a span test while
         * sitting partly in the gap between them. */
        for (s = 0; s < nsegs; s++) {
            if (range_ok(a, 1U, segs[s], segs[s] + seg_bytes)) { inside = 1; break; }
        }
        if (!inside) { return 0; }
    }
    /* A yield callback would be a call through a params-derived pointer; refuse it. */
    if (pl->yield != NULL) { return 0; }
    return 1;
}

/* -------------------------------------------------------------------------
 * Entry point.
 *
 * Takes no Lua arguments and returns none.  The params struct is at dspn_params_addr,
 * patched in at install time, and p->status is where the bin count or the negative
 * DSPN_* refusal goes.
 * -------------------------------------------------------------------------*/
int dsp_native_run(void *L)
{
    const dsp_native_params *p;
    volatile uint32_t *st;
    const dsp_plan *plan;
    dsp_plan *plan_w;
    dsp_src cap_src;
    uint32_t paddr;
    uint32_t segs[DSPN_MAX_SEGS];
    uint32_t seg_bytes = 0U;
    /* nsegs counts the arena's chunks and ntrace the trace points dsp_reduce writes. Two
     * different things one letter apart, so neither is called nseg. */
    int n, m, nbins, k, nsegs = 0, ntrace = 0;

    /* The lua_State is not used: no argument is read and no result is pushed. */
    (void)L;

    paddr = dspn_params_addr;

    /* The params struct itself must be in writable DRAM before it is dereferenced. */
    if (!range_ok(paddr, (uint32_t)sizeof(dsp_native_params), BACKSTOP_LO, BACKSTOP_HI)) {
        return 0;
    }
    p = (const dsp_native_params *)(uintptr_t)paddr;

    /* The one word written through a pointer the caller did not supply.  It is inside the
     * struct the test above proved to be in DRAM, so it needs no window of its own. */
    st = (volatile uint32_t *)(uintptr_t)(paddr + offsetof(dsp_native_params, status));

    if (p->magic != DSP_NATIVE_MAGIC) { RET(DSPN_EMAGIC); }

    /* Arena sizing, answered before any bound is examined because it dereferences
     * nothing beyond the struct already proved to be in DRAM: it is how Lua learns
     * how much storage to find in the first place, so requiring a valid arena to ask
     * would be circular. Both are pure arithmetic. */
    if (p->mode == DSPN_MODE_BYTES) {
        RET(dsp_plan_bytes((int)p->cap_n, (int)p->init_decim,
                           (int)p->init_method));
    }
    if (p->mode == DSPN_MODE_SEGS) {
        RET(dsp_plan_segs((int)p->cap_n, (int)p->init_decim,
                          (int)p->init_method, (size_t)p->seg_bytes));
    }

    /* The declared windows have to be sane in themselves, and inside the backstop,
     * before they are trusted to validate anything else. */
    if (p->wr_lo  >= p->wr_hi  || p->wr_lo  < BACKSTOP_LO || p->wr_hi  > BACKSTOP_HI ||
        p->rd_lo  >= p->rd_hi  || p->rd_hi > DRAM_END) {
        RET(DSPN_EBOUNDS);
    }
    /* The output window only has to be anything when a reading buffer is being written,
     * which out_desc is what says.  A caller writing the trace itself declares none. */
    if (p->out_desc != 0U &&
        (p->out_lo >= p->out_hi || p->out_lo < BACKSTOP_LO || p->out_hi > BACKSTOP_HI)) {
        RET(DSPN_EBOUNDS);
    }

    /* The arena's chunks.  Copied into a local array rather than used in place: the
     * params field is a uint32 vector, and reading it as void*[] would rely on a pointer
     * being exactly four bytes.  That is true on this target and is still the wrong thing
     * to depend on silently. */
    if (p->nsegs == 0U || p->nsegs > DSPN_MAX_SEGS ||
        p->seg_bytes == 0U || (p->seg_bytes & (DSP_ALIGN - 1U)) != 0U) {
        RET(DSPN_EBOUNDS);
    }
    if (!range_ok(p->segs_addr, p->nsegs * 4U, BACKSTOP_LO, BACKSTOP_HI)) {
        RET(DSPN_EBOUNDS);
    }
    nsegs = (int)p->nsegs;
    seg_bytes = p->seg_bytes;
    {
        const uint32_t *vec = (const uint32_t *)(uintptr_t)p->segs_addr;
        int s;
        for (s = 0; s < nsegs; s++) {
            segs[s] = vec[s];
            /* Written through by dsp.c, so the full writable test, plus the alignment
             * every array inside it inherits. */
            if (!wr_ok(p, segs[s], seg_bytes) ||
                (segs[s] & (DSP_ALIGN - 1U)) != 0U) {
                RET(DSPN_EBOUNDS);
            }
        }
    }

    /* Math addresses, before anything calls through them. */
    if (!text_ok(p->sin_addr)  || !text_ok(p->cos_addr)   || !text_ok(p->sqrt_addr) ||
        !text_ok(p->log10_addr)|| !text_ok(p->floor_addr) || !text_ok(p->ceil_addr)) {
        RET(DSPN_EMATH);
    }
    g_sin   = (math1_fn)(uintptr_t)p->sin_addr;
    g_cos   = (math1_fn)(uintptr_t)p->cos_addr;
    g_sqrt  = (math1_fn)(uintptr_t)p->sqrt_addr;
    g_log10 = (math1_fn)(uintptr_t)p->log10_addr;
    g_floor = (math1_fn)(uintptr_t)p->floor_addr;
    g_ceil  = (math1_fn)(uintptr_t)p->ceil_addr;

    /* The plan struct is written by dsp_plan_init, so it needs the writable test.  It
     * must not sit inside the arena: dsp_plan_init carves the arena from its base and
     * would overwrite a plan placed there. */
    if (!wr_ok(p, p->plan_addr, (uint32_t)sizeof(dsp_plan)) ||
        hits_arena(p->plan_addr, (uint32_t)sizeof(dsp_plan), segs, nsegs, seg_bytes)) {
        RET(DSPN_EPLAN);
    }
    plan   = (const dsp_plan *)(uintptr_t)p->plan_addr;
    plan_w = (dsp_plan *)(uintptr_t)p->plan_addr;

    n = (int)p->cap_n;

    /* Build the plan and stop.  dsp_plan_init zeroes the plan before any refusal, so a
     * non-zero return leaves p->n == 0 and the run path below refuses on geometry. */
    if (p->mode == DSPN_MODE_INIT) {
        /* void* rather than uint32: dsp_plan_init_segs takes pointers, and building the
         * array here keeps the type pun out of it. */
        void *segv[DSPN_MAX_SEGS];
        int rc, s;
        for (s = 0; s < nsegs; s++) { segv[s] = (void *)(uintptr_t)segs[s]; }
        rc = dsp_plan_init_segs(plan_w, segv, nsegs, (size_t)seg_bytes,
                                n,
                                (int)p->init_kind,
                                (double)p->init_beta_milli / 1000.0,
                                (int)p->init_decim,
                                (int)p->init_method);
        RET(rc);
    }

    if (p->mode != DSPN_MODE_RUN) { RET(DSPN_EBOUNDS); }

    m = plan->m;
    if (plan->n == 0 || plan->n != n || m <= 0 || p->cap_perchunk == 0U) {
        RET(DSPN_EGEOM);
    }

    if (!plan_ptrs_ok(plan, segs, nsegs, seg_bytes)) {
        RET(DSPN_EARENA);
    }

    /* Capture storage, read in place through the chunk vector.
     *
     * Two payload addresses do not reach a long record: at 24 bytes an element a chunk
     * holds 1365, so 16,384 samples span twelve.  Reading in place is also what removes
     * the de-strided copy -- n contiguous doubles, 131 kB at 16,384, longer than any
     * segment -- from the frame.
     *
     * The stride is the capture's own element size, not 32: a STYLE_STANDARD buffer stores
     * no extra value and is smaller.  It has to tile the chunk exactly, which is the
     * descriptor's own invariant, so a stride that fails it is not this buffer's.  And it
     * has to be a multiple of eight, as does every payload base: the elements are then as
     * aligned as the base and the double load inside dsp.c is legal.  A 4-aligned stride
     * is refused here rather than read as a pair of words, which is what the copy did. */
    {
        uint32_t nch = p->cap_nchunks, want, i, left = (uint32_t)n;
        if (p->cap_perchunk == 0U || p->cap_stride < 8U || (p->cap_stride & 7U) != 0U ||
            p->cap_stride * p->cap_perchunk > DSPN_CHUNK_BYTES ||
            p->cap_stride * (p->cap_perchunk + 1U) <= DSPN_CHUNK_BYTES) {
            RET(DSPN_ECAPTURE);
        }
        /* Blocks the record actually occupies, which is what dsp_src addresses; nch is the
         * vector's length and only has to be at least that. */
        want = ((uint32_t)n + p->cap_perchunk - 1U) / p->cap_perchunk;
        if (nch == 0U || want > nch || want > (uint32_t)DSP_MAX_SRC_BLOCKS ||
            (p->cap_vec & 3U) != 0U ||
            !range_ok(p->cap_vec, nch * 4U, BACKSTOP_LO, BACKSTOP_HI)) {
            RET(DSPN_ECAPTURE);
        }
        for (i = 0; i < (uint32_t)DSP_MAX_SRC_BLOCKS; i++) {
            cap_src.blk[i] = NULL;
        }
        {
            const uint32_t *cvec = (const uint32_t *)(uintptr_t)p->cap_vec;
            for (i = 0; i < want; i++) {
                /* Element 0 is where the content scan found it, not where the first chunk's
                 * payload begins: it is measured 8-aligned against a 16-aligned payload, so
                 * the record does not start at the base of its chunk.  Later chunks hold
                 * elements from their payload base.  That is the mapping the two-chunk form
                 * used and had verified on the instrument, generalised to a long record;
                 * taking the first block from the vector as well would read a fixed offset
                 * early and be a wrong spectrum rather than a refusal. */
                const uint32_t base = (i == 0U) ? p->cap_chunk1 : cvec[i];
                const uint32_t take = (left < p->cap_perchunk) ? left : p->cap_perchunk;
                if ((base & 7U) != 0U || !stride_ok_rd(p, base, take, p->cap_stride)) {
                    RET(DSPN_ECAPTURE);
                }
                cap_src.blk[i] = (const unsigned char *)(uintptr_t)base;
                left -= take;
            }
        }
        cap_src.nblock = (int)want;
        cap_src.per    = (int)p->cap_perchunk;
        cap_src.stride = (int)p->cap_stride;
        cap_src.len    = n;
    }

    /* The reduction's geometry, all of it unsigned so the int casts below cannot turn a
     * large word into a negative index.  k0 and k1 are bounded by m rather than by the
     * nbins the run reports, because m is the length of the array they index and that is
     * known before anything is touched; dsp_reduce clamps k1 to its own nbins as well. */
    ntrace = (int)p->red_nseg;
    if (p->red_nseg == 0U || p->red_nseg > (uint32_t)DSP_NSEG_MAX ||
        p->red_k0 >= (uint32_t)m || p->red_k1 >= (uint32_t)m ||
        p->red_k1 < p->red_k0) {
        RET(DSPN_EREDUCE);
    }

    /* The reduction's two output arrays and the results block.  dsp_reduce's own overlap
     * test compares db and hz with each other and with the bins; what it cannot know is
     * whether they are memory this call is allowed to write, or whether they sit where the
     * plan's arrays live.  The results block is 8-aligned because it is a double array. */
    {
        const uint32_t rbytes = p->red_nseg * (uint32_t)sizeof(dsp_real);
        const uint32_t pbytes = (uint32_t)sizeof(dsp_plan);
        if (!wr_ok(p, p->red_db, rbytes) || !wr_ok(p, p->red_hz, rbytes) ||
            hits_arena(p->red_db, rbytes, segs, nsegs, seg_bytes) ||
            hits_arena(p->red_hz, rbytes, segs, nsegs, seg_bytes) ||
            overlaps(p->red_db, rbytes, p->plan_addr, pbytes) ||
            overlaps(p->red_hz, rbytes, p->plan_addr, pbytes)) {
            RET(DSPN_EREDUCE);
        }
        if (p->res_npk > (uint32_t)DSPN_RES_PEAKS || (p->res_addr & 7U) != 0U ||
            !wr_ok(p, p->res_addr, DSPN_RES_BYTES) ||
            hits_arena(p->res_addr, DSPN_RES_BYTES, segs, nsegs, seg_bytes) ||
            overlaps(p->res_addr, DSPN_RES_BYTES, p->plan_addr, pbytes) ||
            overlaps(p->res_addr, DSPN_RES_BYTES, p->red_db, rbytes) ||
            overlaps(p->res_addr, DSPN_RES_BYTES, p->red_hz, rbytes)) {
            RET(DSPN_ERESULT);
        }
    }

    /* out_desc zero asks for the reduction and nothing else: the two arrays are filled and
     * no reading buffer is touched.  That is what the caller wants when it writes the trace
     * itself, which it has to -- a graph draws from the display task's own copy of a bound
     * buffer, fed by buffer.write.reading, so points put straight into chunk storage are
     * never drawn.  Asking for the write as well costs a content scan at startup to find
     * that storage, and the write is then overwritten.
     *
     * Output storage, when it is asked for: written, so the output window and the
     * backstop.  The trace is nseg points and not m bins -- the reduction is what the graph
     * reads -- and one element beyond it has to exist too, because the cursor rewind stores
     * the address of the slot after the last one written. */
    if (p->out_desc != 0U) {
        uint32_t want     = p->red_nseg + 1U;
        uint32_t o_first  = want < p->out_perchunk ? want : p->out_perchunk;
        uint32_t o_second = want - o_first;
        if (p->out_perchunk == 0U ||
            !stride_ok_out(p, p->out_chunk1, o_first, 32U) ||
            !stride_ok_out(p, p->out_chunk2, o_second, 32U)) {
            RET(DSPN_EOUTPUT);
        }
        /* The descriptor is a separate allocation from the chunk storage, so it is checked
         * against the backstop rather than the bulk window, and only its base is
         * trusted: the field offsets are compiled in.  4-aligned because the rewind writes
         * it as words, and clear of the arena, which it would otherwise be free to
         * overwrite. */
        if (!range_ok(p->out_desc, DESC_SPAN, BACKSTOP_LO, BACKSTOP_HI) ||
            (p->out_desc & 3U) != 0U ||
            hits_arena(p->out_desc, DESC_SPAN, segs, nsegs, seg_bytes)) {
            RET(DSPN_EDESC);
        }
    }

    /* Every address has passed.  From here on memory is touched. */
    nbins = dsp_spectrum_run_src(plan_w, &cap_src, n, NULL);
    if (nbins <= 0) { RET(DSPN_ERUN); }

    /* Bins to the trace the graph reads: nseg maxima, in decibels, against the segment's
     * own frequency.  dsp_reduce rather than a loop here, because it is the reduction the
     * host suite covers -- the NaN handling, the descending Nyquist zone and the floor are
     * all necessary and none of them is obvious. */
    {
        dsp_bandmap map;
        dsp_real *db = (dsp_real *)(uintptr_t)p->red_db;
        dsp_real *hz = (dsp_real *)(uintptr_t)p->red_hz;
        /* zone is the fold the decimation produced, and dsp_reduce reads f0, binhz and
         * sense only; Lua does not send one rather than send a figure nothing uses. */
        map.f0    = pw_double(p->red_f0_hi, p->red_f0_lo);
        map.binhz = pw_double(p->red_binhz_hi, p->red_binhz_lo);
        map.sense = (int)(int32_t)p->red_sense;
        map.zone  = 0;
        if (dsp_reduce_vec(&plan->pwr_v, nbins, (int)p->red_k0, (int)p->red_k1, ntrace, &map,
                       pw_double(p->red_dbmin_hi, p->red_dbmin_lo),
                       pw_double(p->red_dbmax_hi, p->red_dbmax_lo),
                       pw_double(p->red_vfloor_hi, p->red_vfloor_lo),
                       db, hz) != ntrace) {
            RET(DSPN_EREDUCE);
        }
        /* The decibel value in the reading field and the frequency in the extra value,
         * which is the pair display.graph.add was given at build time. */
        if (p->out_desc != 0U) {
            for (k = 0; k < ntrace; k++) {
                rb_write(p->out_chunk1, p->out_chunk2, p->out_perchunk, k, (double)db[k]);
                rb_write_extra(p->out_chunk1, p->out_chunk2, p->out_perchunk, k,
                               (double)hz[k]);
            }
        }
    }

    /* The figures that are not the trace: the ranked peaks and the distortion measurement,
     * over the same bins and the same window the reduction used.  Neither writes to the
     * bins.  Both are what the app's peak table and its THD line read, and without them a
     * native frame would leave dsp.peak and dsp.distortion to post "no spectrum yet" once
     * per peak per frame -- nothing on this path sets the Lua implementation's dsp.ran. */
    {
        double   *res   = (double *)(uintptr_t)p->res_addr;
        int      *pbin  = (int *)(uintptr_t)(p->res_addr
                                             + (uint32_t)DSPN_RES_DOUBLES * 8U);
        dsp_real *pfrac = (dsp_real *)(uintptr_t)(p->res_addr
                                                  + (uint32_t)DSPN_RES_DOUBLES * 8U
                                                  + (uint32_t)DSPN_RES_PEAKS * 4U);
        dsp_real *pamp  = pfrac + DSPN_RES_PEAKS;
        const double binhz = pw_double(p->red_binhz_hi, p->red_binhz_lo);
        const double rf0   = pw_double(p->red_f0_hi, p->red_f0_lo);
        const int sense = (int)(int32_t)p->red_sense;
        const int want  = (int)p->res_npk;
        const int s = 2 * DSPN_RES_PEAKS;
        dsp_thdn td;
        int npk = 0;
        for (k = 0; k < DSPN_RES_DOUBLES; k++) { res[k] = 0.0; }
        if (want > 0) {
            npk = dsp_peaks_vec(&plan->pwr_v, nbins, (int)p->red_k0, (int)p->red_k1, plan->kdc,
                            want, &plan->ip, pbin, pfrac, pamp);
            if (npk < 0) { npk = 0; }
            for (k = 0; k < npk; k++) {
                /* The map applied to a fractional bin, which dsp_bin_hz cannot take: the
                 * sub-bin offset is the part a caller could not recover from the trace. */
                res[2 * k]     = (double)pamp[k];
                res[2 * k + 1] = rf0 + (double)sense
                                 * ((double)pbin[k] + (double)pfrac[k]) * binhz;
            }
        }
        res[s + 0] = (double)npk;
        /* A refusal leaves every figure zero with its flag clear, which is what an
         * unmeasured distortion is: 0% and 0 dB are both real answers, so the flags are
         * the only honest way to say "not measured". */
        if (dsp_thd_noise_vec(&plan->pwr_v, nbins, (int)p->red_k0, (int)p->red_k1, plan->kdc,
                          binhz, (int)(int32_t)p->res_mains, &plan->ip, &td) == DSP_OK) {
            res[s + 1] = td.thd;
            res[s + 2] = (td.signal != 0 && td.nharm > 0) ? 1.0 : 0.0;
            res[s + 3] = td.snr_db;
            res[s + 4] = (td.signal != 0) ? 1.0 : 0.0;
            res[s + 5] = td.noise_db;
            res[s + 6] = (td.nnoise > 0) ? 1.0 : 0.0;
            /* f0_hz is bins times binhz, so it ignores the band map's offset and sense;
             * that is exact while decim is 1 and wrong in a folded zone. */
            res[s + 7] = td.f0_hz;
            res[s + 8] = td.amp0;
        }
        res[s + 9] = (double)nbins;
    }

    /* Cursor rewind: tell the firmware ntrace elements are present without a
     * buffer.clear(), which is what would let the graph paint a half-filled trace.  The
     * iterators point at the slot AFTER the last written element, which is why they are
     * computed from ntrace and the lagging pair from ntrace-1. */
    if (p->out_desc != 0U) {
        const uint32_t ch1 = p->out_chunk1, ch2 = p->out_chunk2;
        const uint32_t per = p->out_perchunk;
        const uint32_t nt  = (uint32_t)ntrace;
        const uint32_t cur = rb_addr(ch1, ch2, per, nt);
        const uint32_t chk = rb_chunk(ch1, ch2, per, nt);
        volatile uint32_t *dsc = (volatile uint32_t *)(uintptr_t)p->out_desc;
        dsc[DESC_IT1_PTR   / 4U] = cur;
        dsc[DESC_IT1_IDX   / 4U] = nt;
        dsc[DESC_IT1_CHUNK / 4U] = chk;
        dsc[DESC_IT2_PTR   / 4U] = cur;
        dsc[DESC_IT2_IDX   / 4U] = nt;
        dsc[DESC_IT2_CHUNK / 4U] = chk;
        dsc[DESC_LAST_PTR  / 4U] = rb_addr(ch1, ch2, per, nt - 1U);
        dsc[DESC_LAST_IDX  / 4U] = nt - 1U;
        dsc[DESC_N         / 4U] = nt;
        dsc[DESC_N_1       / 4U] = nt;
        dsc[DESC_N_2       / 4U] = nt;
        dsc[DESC_N_3       / 4U] = nt;
    }

    RET(ntrace);
}
