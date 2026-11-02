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
 * Firmware addresses (1.7.17a -- update for other builds)
 * ------------------------------------------------------
 * LUA_TOSTRING  0x0021E868   lua_tostring(L, n) -> const char* in r3
 * HEXPARSE      0x004BFE9C   hexparse(str, &err) -> uint32 in r3
 * lua_pushnumber arrives in the params struct; FNF resolves it at startup.
 *
 * Build
 * -----
 *   cmake -B build-ppc -DCMAKE_TOOLCHAIN_FILE=csrc/toolchain-ppc-clang.cmake \
 *         -DDSP_DST_NATIVE=ON
 *   cmake --build build-ppc --target dsp_native_bin
 */

#include <stdint.h>
#include "dsp.h"

/* lua_tostring(lua_State *L, int n) -> const char *  1.7.17a */
#define LUA_TOSTRING_ADDR  0x0021E868u

/* hexparse(const char *str, int *err) -> uint32_t    1.7.17a */
#define HEXPARSE_ADDR      0x004BFE9Cu

typedef const char *(*lua_tostring_fn)(void *, int);
typedef uint32_t    (*hexparse_fn)(const char *, int *);
typedef void        (*lua_pushnumber_fn)(void *, double);
typedef double      (*math1_fn)(double);

/* The address bounds and the predicates built on them.  In a header of their own so the
 * host suite tests the code that ships rather than a copy of it; see
 * test/dsp_native_bounds_test.cc, which covers every forbidden region by name. */
#include "dsp_native_bounds.h"

#define HEAP_LO   DSPN_HEAP_LO
#define HEAP_HI   DSPN_HEAP_HI
#define DRAM_END  DSPN_DRAM_END

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
    uint32_t src_flat;     /* scratch for the de-strided capture, cap_n doubles      */

    uint32_t cap_chunk1;   /* capture chunk payloads, stride 32, reading at +0       */
    uint32_t cap_chunk2;   /* 0 when the capture fits one chunk                     */
    uint32_t cap_n;        /* samples, a power of two                               */
    uint32_t cap_perchunk; /* elements per chunk, from the descriptor               */

    uint32_t out_chunk1;   /* graph buffer chunk payloads                           */
    uint32_t out_chunk2;
    uint32_t out_perchunk;
    uint32_t out_desc;     /* column descriptor base; the fields written are at the  */
                           /* offsets below, so one address is validated not three   */

    uint32_t lua_pushnumber_addr;

    /* Firmware math addresses resolved by FNF; copied into the globals below.      */
    uint32_t sin_addr;
    uint32_t cos_addr;
    uint32_t sqrt_addr;
    uint32_t log10_addr;
    uint32_t floor_addr;
    uint32_t ceil_addr;

    /* DSPN_MODE_INIT only.  beta arrives scaled by 1000 because the struct is packed
     * from Lua as big-endian words and Lua 5.0.2 has no way to lay out an IEEE754
     * double; milli-resolution is far finer than the window needs. */
    uint32_t init_kind;
    uint32_t init_beta_milli;
    uint32_t init_decim;
    uint32_t init_method;
} dsp_native_params;

#define DSPN_MODE_INIT   1U
#define DSPN_MODE_RUN    2U
#define DSPN_MODE_BYTES  3U   /* report dsp_plan_bytes and stop; touches no memory */
#define DSPN_MODE_SEGS   4U   /* report dsp_plan_segs for seg_bytes; touches no memory */

/* Chunks the arena may span. At the largest n a single chunk can hold an array for, the
 * layout needs six, so this is generous; it bounds a stack array in dsp_native_run. */
#define DSPN_MAX_SEGS    32U

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
 *
 * Initialised, not tentative: without the initialiser this is a common definition that
 * lands in .bss as zeros and reports nothing.
 */
const uint32_t dsp_native_sizes[4] = {
    (uint32_t)sizeof(dsp_plan),
    (uint32_t)sizeof(dsp_native_params),
    (uint32_t)sizeof(dsp_real),
    (uint32_t)DSP_ALIGN
};

/* Words in the struct; write_params must pack exactly this many. */
#define DSP_NATIVE_PARAM_WORDS  32

/* Column descriptor field offsets, from fwmem-BUFFER.md.  The write cursor and two of
 * the copies of n.  The remaining fields the descriptor carries -- the second iterator,
 * the lagging pointer and index, and four further copies of n -- are not written yet;
 * experiment E7 measures whether the graph needs them before the notify holds. */
#define DESC_CURSOR  0x4CU
#define DESC_N_0     0x50U
#define DESC_N_1     0x60U
#define DESC_SPAN    0x64U   /* past the last field written */

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
static double rb_read(uint32_t ch1, uint32_t ch2, uint32_t perchunk, int k)
{
    uint32_t idx = (uint32_t)k;
    uint32_t base = (idx < perchunk) ? ch1 : ch2;
    uint32_t off  = (idx < perchunk) ? idx : (idx - perchunk);
    return *(const double *)(uintptr_t)(base + off * 32U);
}

static void rb_write(uint32_t ch1, uint32_t ch2, uint32_t perchunk, int k, double v)
{
    uint32_t idx = (uint32_t)k;
    uint32_t base = (idx < perchunk) ? ch1 : ch2;
    uint32_t off  = (idx < perchunk) ? idx : (idx - perchunk);
    *(double *)(uintptr_t)(base + off * 32U) = v;
}

/* Address of element k, for the cursor rewind. */
static uint32_t rb_addr(uint32_t ch1, uint32_t ch2, uint32_t perchunk, uint32_t k)
{
    return (k < perchunk) ? (ch1 + k * 32U) : (ch2 + (k - perchunk) * 32U);
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
 * Arg 1 on the Lua stack: the params struct address, as a hex string.
 * Pushes one number: the bin count, or a negative DSPN_* status.
 * -------------------------------------------------------------------------*/
int dsp_native_run(void *L)
{
    lua_tostring_fn lts = (lua_tostring_fn)(uintptr_t)LUA_TOSTRING_ADDR;
    hexparse_fn     hp  = (hexparse_fn)(uintptr_t)HEXPARSE_ADDR;
    lua_pushnumber_fn push;
    const dsp_native_params *p;
    const dsp_plan *plan;
    dsp_plan *plan_w;
    double *src;
    uint32_t paddr;
    uint32_t segs[DSPN_MAX_SEGS];
    uint32_t seg_bytes = 0U;
    int parse_err = 0;
    int n, m, nbins, k, nsegs = 0;

    const char *arg1 = lts(L, 1);
    if (arg1 == NULL) { return 0; }
    paddr = hp(arg1, &parse_err);
    if (parse_err) { return 0; }

    /* The params struct itself must be in the heap before it is dereferenced. */
    if (!range_ok(paddr, (uint32_t)sizeof(dsp_native_params), HEAP_LO, HEAP_HI)) {
        return 0;
    }
    p = (const dsp_native_params *)(uintptr_t)paddr;

    /* Nothing can be reported without a way to push, so this is checked first and a
     * failure is a silent return rather than a status. */
    if (!text_ok(p->lua_pushnumber_addr)) { return 0; }
    push = (lua_pushnumber_fn)(uintptr_t)p->lua_pushnumber_addr;

    if (p->magic != DSP_NATIVE_MAGIC) { push(L, (double)DSPN_EMAGIC); return 1; }

    /* Arena sizing, answered before any bound is examined because it dereferences
     * nothing: it is how Lua learns how much storage to find in the first place, so
     * requiring a valid arena to ask would be circular. Both are pure arithmetic. */
    if (p->mode == DSPN_MODE_BYTES) {
        push(L, (double)dsp_plan_bytes((int)p->cap_n, (int)p->init_decim,
                                       (int)p->init_method));
        return 1;
    }
    if (p->mode == DSPN_MODE_SEGS) {
        push(L, (double)dsp_plan_segs((int)p->cap_n, (int)p->init_decim,
                                      (int)p->init_method, (size_t)p->seg_bytes));
        return 1;
    }

    /* The declared windows have to be sane in themselves, and inside the backstop,
     * before they are trusted to validate anything else. */
    if (p->wr_lo  >= p->wr_hi  || p->wr_lo  < HEAP_LO || p->wr_hi  > HEAP_HI ||
        p->out_lo >= p->out_hi || p->out_lo < HEAP_LO || p->out_hi > HEAP_HI ||
        p->rd_lo  >= p->rd_hi  || p->rd_hi > DRAM_END) {
        push(L, (double)DSPN_EBOUNDS); return 1;
    }

    /* The arena's chunks.  Copied into a local array rather than used in place: the
     * params field is a uint32 vector, and reading it as void*[] would rely on a pointer
     * being exactly four bytes.  That is true on this target and is still the wrong thing
     * to depend on silently. */
    if (p->nsegs == 0U || p->nsegs > DSPN_MAX_SEGS ||
        p->seg_bytes == 0U || (p->seg_bytes & (DSP_ALIGN - 1U)) != 0U) {
        push(L, (double)DSPN_EBOUNDS); return 1;
    }
    if (!range_ok(p->segs_addr, p->nsegs * 4U, HEAP_LO, HEAP_HI)) {
        push(L, (double)DSPN_EBOUNDS); return 1;
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
                push(L, (double)DSPN_EBOUNDS); return 1;
            }
        }
    }

    /* Math addresses, before anything calls through them. */
    if (!text_ok(p->sin_addr)  || !text_ok(p->cos_addr)   || !text_ok(p->sqrt_addr) ||
        !text_ok(p->log10_addr)|| !text_ok(p->floor_addr) || !text_ok(p->ceil_addr)) {
        push(L, (double)DSPN_EMATH); return 1;
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
    if (!wr_ok(p, p->plan_addr, (uint32_t)sizeof(dsp_plan))) {
        push(L, (double)DSPN_EPLAN); return 1;
    }
    {
        int s;
        for (s = 0; s < nsegs; s++) {
            if (p->plan_addr < segs[s] + seg_bytes &&
                (p->plan_addr + (uint32_t)sizeof(dsp_plan)) > segs[s]) {
                push(L, (double)DSPN_EPLAN); return 1;
            }
        }
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
        push(L, (double)rc);
        return 1;
    }

    if (p->mode != DSPN_MODE_RUN) { push(L, (double)DSPN_EBOUNDS); return 1; }

    m = plan->m;
    if (plan->n == 0 || plan->n != n || m <= 0 || p->cap_perchunk == 0U ||
        p->out_perchunk == 0U) {
        push(L, (double)DSPN_EGEOM); return 1;
    }

    if (!plan_ptrs_ok(plan, segs, nsegs, seg_bytes)) {
        push(L, (double)DSPN_EARENA); return 1;
    }

    /* Scratch for the de-strided capture: n doubles, contiguous, and it must not
     * overlap the arena -- dsp.c's overlap checks assume src is separate. */
    if (!wr_ok(p, p->src_flat, (uint32_t)n * 8U)) {
        push(L, (double)DSPN_ESCRATCH); return 1;
    }
    {
        int s;
        for (s = 0; s < nsegs; s++) {
            if (p->src_flat < segs[s] + seg_bytes &&
                (p->src_flat + (uint32_t)n * 8U) > segs[s]) {
                push(L, (double)DSPN_ESCRATCH); return 1;
            }
        }
    }

    /* Capture storage: read only, and only within what Lua declared. */
    {
        uint32_t in_first  = (uint32_t)n < p->cap_perchunk ? (uint32_t)n : p->cap_perchunk;
        uint32_t in_second = (uint32_t)n - in_first;
        if (!stride_ok_rd(p, p->cap_chunk1, in_first, 32U) ||
            !stride_ok_rd(p, p->cap_chunk2, in_second, 32U)) {
            push(L, (double)DSPN_ECAPTURE); return 1;
        }
    }

    /* Output storage: written, so the output window and the heap backstop. */
    {
        uint32_t o_first  = (uint32_t)m < p->out_perchunk ? (uint32_t)m : p->out_perchunk;
        uint32_t o_second = (uint32_t)m - o_first;
        if (!stride_ok_out(p, p->out_chunk1, o_first, 32U) ||
            !stride_ok_out(p, p->out_chunk2, o_second, 32U)) {
            push(L, (double)DSPN_EOUTPUT); return 1;
        }
    }

    /* The descriptor is a separate allocation from the chunk storage, so it is checked
     * against the heap backstop rather than the bulk window, and only its base is
     * trusted: the field offsets are compiled in. */
    if (!range_ok(p->out_desc, DESC_SPAN, HEAP_LO, HEAP_HI)) {
        push(L, (double)DSPN_EDESC); return 1;
    }

    /* Every address has passed.  From here on memory is touched. */
    src = (double *)(uintptr_t)p->src_flat;
    for (k = 0; k < n; k++) {
        src[k] = rb_read(p->cap_chunk1, p->cap_chunk2, p->cap_perchunk, k);
    }

    nbins = dsp_spectrum_run(plan_w, src, n, NULL);
    if (nbins <= 0) { push(L, (double)DSPN_ERUN); return 1; }

    for (k = 0; k < m; k++) {
        rb_write(p->out_chunk1, p->out_chunk2, p->out_perchunk, k,
                 (double)plan->pwr[k]);
    }

    /* Cursor rewind: tell the firmware m elements are present without a buffer.clear().
     * The cursor points at the slot after the last written element, which is why it is
     * computed from m rather than m-1. */
    *(volatile uint32_t *)(uintptr_t)(p->out_desc + DESC_CURSOR) =
        rb_addr(p->out_chunk1, p->out_chunk2, p->out_perchunk, (uint32_t)m);
    *(volatile uint32_t *)(uintptr_t)(p->out_desc + DESC_N_0) = (uint32_t)m;
    *(volatile uint32_t *)(uintptr_t)(p->out_desc + DESC_N_1) = (uint32_t)m;

    push(L, (double)nbins);
    return 1;
}
