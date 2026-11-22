/*
 * Freestanding PowerPC entry point. Lua supplies a big-endian params block; the entry
 * validates every range before passing it to the DSP library or writing a display record.
 */

#include <stddef.h>
#include <stdint.h>
#include "dsp.h"

typedef double (*math1_fn)(double);

/* Lua patches dspn_params_addr before calling the relocated image. Keep the slot exported. */
volatile uint32_t dspn_params_addr;

#include "dsp_native_bounds.h"

#include "dsp_native_px.h"

#define BACKSTOP_LO  DSPN_DRAM_LO
#define BACKSTOP_HI  DSPN_DRAM_END
#define DRAM_END     DSPN_DRAM_END

/* Nonnegative status is a result count; negative status is a refusal. */
#define DSPN_EMAGIC      (-1)
#define DSPN_EBOUNDS     (-2)
#define DSPN_EPLAN       (-3)
#define DSPN_EGEOM       (-4)
#define DSPN_ECAPTURE    (-5)
#define DSPN_EOUTPUT     (-6)
#define DSPN_EDESC       (-7)
#define DSPN_EARENA      (-8)

#define DSPN_ERUN       (-10)
#define DSPN_EMATH      (-11)
#define DSPN_EREDUCE    (-12)
#define DSPN_ERESULT    (-13)

#define DSPN_EFIND      (-14)

/* Shift plan-builder failures into a separate status range before returning them to Lua. */
#define DSPN_PLAN_BASE (-100)

/* An unchanged status sentinel means the entry point did not report a result. */
#define DSPN_STATUS_UNSET  0x7FFFFFFF

/* Return no Lua values. Record the native refusal's source line alongside its status. */
#define RET(v)  do { *fl = (uint32_t)__LINE__; *st = (uint32_t)(int32_t)(v); return 0; } \
                while (0)

#define DSP_NATIVE_MAGIC  0x44535031U   /* 'DSP1' */

typedef struct {
    uint32_t magic;        /* DSP_NATIVE_MAGIC, or the struct was never written     */
    uint32_t mode;         /* DSPN_MODE_* */

    /* Keep separate allowed windows for plan, capture and graph output allocations. */
    uint32_t wr_lo;        /* plan struct, arena and scratch                        */
    uint32_t wr_hi;        /* one past the end                                      */
    uint32_t rd_lo;        /* capture chunk storage, read only                      */
    uint32_t rd_hi;
    uint32_t out_lo;       /* graph buffer chunk storage                            */
    uint32_t out_hi;

    /* Arena segments are independent chunk payloads, not one contiguous allocation. */
    uint32_t seg_bytes;    /* payload size of one chunk, a multiple of DSP_ALIGN     */
    uint32_t nsegs;        /* chunks given to the arena                             */
    uint32_t segs_addr;    /* nsegs big-endian words: the payload addresses         */

    uint32_t plan_addr;    /* dsp_plan, initialised by dsp_plan_init at startup      */

    uint32_t cap_chunk1;   /* capture chunk payloads, reading at +0                  */
    uint32_t cap_n;        /* samples, a power of two                               */
    uint32_t cap_perchunk; /* elements per chunk, from the descriptor               */
    uint32_t cap_stride;   /* Capture stride in bytes; checked against the descriptor and confirmed data. */

    uint32_t cap_vec;      /* Chunk pointer vector: cap_nchunks big-endian words. */

    uint32_t cap_nchunks;  /* entries in cap_vec, not just chunks the record touches */

    uint32_t out_chunk1;   /* graph buffer chunk payloads                           */
    uint32_t out_chunk2;
    uint32_t out_perchunk;
    uint32_t out_desc;     /* Base of the column descriptor used for optional cursor rewind. */

    /* Lua initializes status to DSPN_STATUS_UNSET before every call. */
    uint32_t status;

    uint32_t sin_addr;
    uint32_t cos_addr;
    uint32_t sqrt_addr;
    uint32_t log10_addr;
    uint32_t floor_addr;
    uint32_t ceil_addr;

    /* MODE_INIT takes beta in thousandths so the packed params remain whole words. */
    uint32_t init_kind;
    uint32_t init_beta_milli;
    uint32_t init_decim;
    uint32_t init_method;

    /* MODE_RUN emits nseg trace points. A firmware output buffer needs one extra rewind slot. */
    uint32_t red_nseg;       /* Trace point count (1..DSP_NSEG_MAX). */

    uint32_t red_k0;         /* first bin of the displayed window                        */
    uint32_t red_k1;         /* last bin, inclusive                                      */
    uint32_t red_db;         /* scratch, red_nseg dsp_real                               */
    uint32_t red_hz;         /* scratch, red_nseg dsp_real                               */
    uint32_t red_sense;      /* dsp_bandmap::sense, +1 or -1, as an int32                 */

    /* Split floating-point inputs into big-endian high and low words. */
    uint32_t red_f0_hi,     red_f0_lo;      /* dsp_bandmap::f0, hertz at bin 0          */
    uint32_t red_binhz_hi,  red_binhz_lo;   /* dsp_bandmap::binhz                       */
    uint32_t red_dbmin_hi,  red_dbmin_lo;   /* trace floor                              */
    uint32_t red_dbmax_hi,  red_dbmax_lo;   /* trace ceiling                            */
    uint32_t red_vfloor_hi, red_vfloor_lo;  /* floor in volts, squared by dsp_reduce    */

    uint32_t res_addr;     /* DSPN_RES_BYTES of scratch, 8-aligned                      */
    uint32_t res_npk;      /* peaks to rank, 0..DSPN_RES_PEAKS                          */
    uint32_t res_mains;    /* DSP_THD_MAINS_*, as an int32; -1 is BOTH                  */

    /* Source line of the refusal, recorded by RET. Zero means no recorded site. */
    uint32_t fail_at;

    /* FIND words: lo, hi, cap, packed step/length, four needle words, then next, count and hits. */
    uint32_t find_addr;

    /* PX words: lo, hi, ring, stride, yoff, nrec, ymax, ay and by as word pairs, then 1-based indices. */
    uint32_t px_addr;
} dsp_native_params;

#define DSPN_MODE_INIT   1U
#define DSPN_MODE_RUN    2U
#define DSPN_MODE_SEGS   4U   /* report dsp_plan_segs for seg_bytes, the same way       */
#define DSPN_MODE_FIND   5U   /* Byte-pattern search over a bounded memory range. */

#define DSPN_MODE_PX     6U   /* Write graph Y pixels from the reduction array. */

/* A needle fits in four words; cap output to the reserved hit vector. */
#define DSPN_FIND_PAT    16U
#define DSPN_FIND_MAX    32U
#define DSPN_FIND_WORDS  (10U + DSPN_FIND_MAX)
#define DSPN_FIND_BYTES  (DSPN_FIND_WORDS * 4U)

/* Maximum independently allocated chunks backing the plan arena. */
#define DSPN_MAX_SEGS    32U

/* Bound slot-map length and ring stride before computing byte extents. */
#define DSPN_PX_MAXREC      1024U
#define DSPN_PX_STRIDE_MAX  4096U
#define DSPN_PX_YMAX        4095U
#define DSPN_PX_HDR         11U
#define DSPN_PX_WORDS       (DSPN_PX_HDR + DSPN_PX_MAXREC)
#define DSPN_PX_BYTES       (DSPN_PX_WORDS * 4U)

/*
 * Result ABI: double amplitude/frequency pairs, then ten double scalars with validity flags.
 * Peak-bin integers and element-width offsets/amplitudes at the tail are native scratch only.
 */
#define DSPN_RES_PEAKS    16
#define DSPN_RES_SCALARS  10
#define DSPN_RES_DOUBLES  (2 * DSPN_RES_PEAKS + DSPN_RES_SCALARS)
#define DSPN_RES_BYTES    ((uint32_t)DSPN_RES_DOUBLES * 8U \
                           + (uint32_t)DSPN_RES_PEAKS * 4U \
                           + 2U * (uint32_t)DSPN_RES_PEAKS * (uint32_t)sizeof(dsp_real))

/* Export the target compiler's sizes and offsets for the Lua loader; keep this table through linking. */
const uint32_t dsp_native_sizes[14] = {
    (uint32_t)sizeof(dsp_plan),
    (uint32_t)sizeof(dsp_native_params),
    (uint32_t)sizeof(dsp_real),
    (uint32_t)DSP_ALIGN,
    (uint32_t)DSPN_DRAM_LO,
    (uint32_t)DSPN_DRAM_END,
    (uint32_t)DSPN_RES_PEAKS,
    (uint32_t)DSPN_RES_DOUBLES,
    (uint32_t)offsetof(dsp_native_params, status),
    (uint32_t)offsetof(dsp_native_params, fail_at),
    (uint32_t)DSPN_FIND_WORDS,
    (uint32_t)DSPN_FIND_MAX,
    (uint32_t)DSPN_PX_WORDS,
    (uint32_t)DSPN_PX_MAXREC
};

#define DSP_NATIVE_PARAM_WORDS  55

/* Cursor rewind updates both iterator copies, the last-written slot and every copy of the count. */
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

/* Bounds checks operate on half-open byte ranges; zero length touches nothing. */

#define range_ok(a, n, lo, hi)  dspn_range_ok((a), (n), (lo), (hi))
#define text_ok(a)              dspn_text_ok(a)

/* Writes must satisfy both the caller's window and the compiled DRAM bounds. */
static int wr_ok(const dsp_native_params *p, uint32_t a, uint32_t n)
{
    return dspn_write_ok(a, n, p->wr_lo, p->wr_hi);
}

/* Check the complete strided extent, not just the address of its first element. */
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

/* Resolve the firmware math entry points before calling them through these wrappers. */
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

double fabs(double x) { return x < 0.0 ? -x : x; }

/* Freestanding memset for the DSP library; no external C runtime is linked. */
void *memset(void *s, int c, size_t n)
{
    unsigned char *p = (unsigned char *)s;
    while (n--) { *p++ = (unsigned char)c; }
    return s;
}

/* Reading-buffer elements have a double reading at offset zero. */

static void rb_write(uint32_t ch1, uint32_t ch2, uint32_t perchunk, int k, double v)
{
    uint32_t idx = (uint32_t)k;
    uint32_t base = (idx < perchunk) ? ch1 : ch2;
    uint32_t off  = (idx < perchunk) ? idx : (idx - perchunk);
    *(double *)DSPN_P(base + off * 32U) = v;
}

/* The extra double at offset 20 is only four-byte aligned; use two word stores. */
static void rb_write_extra(uint32_t ch1, uint32_t ch2, uint32_t perchunk, int k, double v)
{
    union { double d; uint32_t w[2]; } u;
    uint32_t idx  = (uint32_t)k;
    uint32_t base = (idx < perchunk) ? ch1 : ch2;
    uint32_t off  = (idx < perchunk) ? idx : (idx - perchunk);
    uint32_t *p   = (uint32_t *)DSPN_P(base + off * 32U + 20U);
    u.d = v;
    p[0] = u.w[0];
    p[1] = u.w[1];
}

/* Return both the requested element and its chunk base for cursor rewind. */
static uint32_t rb_addr(uint32_t ch1, uint32_t ch2, uint32_t perchunk, uint32_t k)
{
    return (k < perchunk) ? (ch1 + k * 32U) : (ch2 + (k - perchunk) * 32U);
}

static uint32_t rb_chunk(uint32_t ch1, uint32_t ch2, uint32_t perchunk, uint32_t k)
{
    return (k < perchunk) ? ch1 : ch2;
}

/* Reassemble a double through a union; the params words need not be double-aligned. */
static double pw_double(uint32_t hi, uint32_t lo)
{
    union { double d; uint32_t w[2]; } u;
    u.w[0] = hi;
    u.w[1] = lo;
    return u.d;
}

/* Ranges are already bounded by the DRAM backstop, so the end-address sums cannot wrap. */
static int overlaps(uint32_t a, uint32_t an, uint32_t b, uint32_t bn)
{
    if (an == 0U || bn == 0U) { return 0; }
    return (a < b + bn) && (b < a + an);
}

/* Test against each chunk of the arena; the chunks need not be adjacent. */
static int hits_arena(uint32_t a, uint32_t n, const uint32_t *segs, int nsegs,
                      uint32_t seg_bytes)
{
    int s;
    for (s = 0; s < nsegs; s++) {
        if (overlaps(a, n, segs[s], seg_bytes)) { return 1; }
    }
    return 0;
}

/* Check the plan's top-level array bases; plan initialization establishes the slice extents. */
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
        uint32_t a = DSPN_A(ptrs[i]);
        int inside = 0;
        if (a == 0U) { continue; }
        /* Check one byte at the base, not the array's full extent. */
        for (s = 0; s < nsegs; s++) {
            if (range_ok(a, 1U, segs[s], segs[s] + seg_bytes)) { inside = 1; break; }
        }
        if (!inside) { return 0; }
    }
    /* The native entry point must not call a callback supplied through the plan. */
    if (pl->yield != NULL) { return 0; }
    return 1;
}

/* The relocated entry reads its params slot and returns status through memory, not the Lua stack. */
int dsp_native_run(void *L)
{
    const dsp_native_params *p;
    volatile uint32_t *st;
    volatile uint32_t *fl;
    const dsp_plan *plan;
    dsp_plan *plan_w;
    dsp_src cap_src;
    uint32_t paddr;
    uint32_t segs[DSPN_MAX_SEGS];
    uint32_t seg_bytes = 0U;

    int n, m, nbins, k, nsegs = 0, ntrace = 0;

    (void)L;

    paddr = dspn_params_addr;

    /* Validate the params address before loading any field or writing status. */
    if (!range_ok(paddr, (uint32_t)sizeof(dsp_native_params), BACKSTOP_LO, BACKSTOP_HI)) {
        return 0;
    }
    p = (const dsp_native_params *)DSPN_P(paddr);

    st = (volatile uint32_t *)DSPN_P(paddr + offsetof(dsp_native_params, status));

    fl = (volatile uint32_t *)DSPN_P(paddr + offsetof(dsp_native_params, fail_at));

    if (p->magic != DSP_NATIVE_MAGIC) { RET(DSPN_EMAGIC); }

    /* Arena sizing uses only the already-validated params block. */
    if (p->mode == DSPN_MODE_SEGS) {
        RET(dsp_plan_segs((int)p->cap_n, (int)p->init_decim,
                          (int)p->init_method, (size_t)p->seg_bytes));
    }

    /* FIND needs neither a capture nor a plan. Validate its block and scan window separately. */
    if (p->mode == DSPN_MODE_FIND) {
        volatile uint32_t *fb;
        const unsigned char *hay;
        unsigned char pat[DSPN_FIND_PAT];
        uint32_t flo, fhi, fcap, flen, fstep, nhit, pos, scanned, i;

        if (!range_ok(p->find_addr, DSPN_FIND_BYTES, BACKSTOP_LO, BACKSTOP_HI)) {
            RET(DSPN_EBOUNDS);
        }
        fb = (volatile uint32_t *)DSPN_P(p->find_addr);

        flo  = fb[0];
        fhi  = fb[1];
        fcap = fb[2];
        /* Use shifts to unpack bytes without introducing an address-shaped literal. */
        flen  = (fb[3] << 16) >> 16;
        fstep = fb[3] >> 16;
        if (flen == 0U || flen > DSPN_FIND_PAT) { RET(DSPN_EFIND); }
        for (i = 0U; i < flen; i++) {
            pat[i] = (unsigned char)((fb[4U + (i >> 2)] >> (24U - 8U * (i & 3U))) & 0xFFU);
        }

        if (flo < BACKSTOP_LO) { flo = BACKSTOP_LO; }
        if (fhi > BACKSTOP_HI) { fhi = BACKSTOP_HI; }
        if (fcap == 0U) { fcap = fhi > flo ? fhi - flo : 0U; }

        nhit = 0U;
        scanned = 0U;
        pos = flo;
        /* Accept a scan step of 1, 2 or 4 bytes. Use word compares on the aligned path. */
        if (fstep == 0U) { fstep = 1U; }
        if (fstep != 1U && fstep != 2U && fstep != 4U) { RET(DSPN_EFIND); }
        if (fstep == 4U && (flo & 3U) != 0U) { RET(DSPN_EFIND); }
        {
            uint32_t pw0 = 0U;
            uint32_t wordwise = (flen >= 4U && fstep == 4U) ? 1U : 0U;
            if (wordwise) {
                pw0 = ((uint32_t)pat[0] << 24) | ((uint32_t)pat[1] << 16)
                      | ((uint32_t)pat[2] << 8) | (uint32_t)pat[3];
            }
            while (pos + flen <= fhi && scanned < fcap && nhit < DSPN_FIND_MAX) {
                if (wordwise) {
                    if (*(const uint32_t *)DSPN_P(pos) == pw0) {
                        hay = (const unsigned char *)DSPN_P(pos);
                        for (i = 4U; i < flen; i++) {
                            if (hay[i] != pat[i]) { break; }
                        }
                        if (i == flen) {
                            fb[10U + nhit] = pos;
                            nhit++;
                        }
                    }
                } else {
                    hay = (const unsigned char *)DSPN_P(pos);
                    for (i = 0U; i < flen; i++) {
                        if (hay[i] != pat[i]) { break; }
                    }
                    if (i == flen) {
                        fb[10U + nhit] = pos;
                        nhit++;
                    }
                }
                pos += fstep;
                scanned += fstep;
            }
        }
        fb[8] = pos;
        fb[9] = nhit;
        RET((int32_t)nhit);
    }

    /* Validate declared windows against the backstop before using them to prove addresses. */
    if (p->wr_lo  >= p->wr_hi  || p->wr_lo  < BACKSTOP_LO || p->wr_hi  > BACKSTOP_HI ||
        p->rd_lo  >= p->rd_hi  || p->rd_hi > DRAM_END) {
        RET(DSPN_EBOUNDS);
    }
    /* Only direct output writes require a valid graph-buffer window. */
    if (p->out_desc != 0U &&
        (p->out_lo >= p->out_hi || p->out_lo < BACKSTOP_LO || p->out_hi > BACKSTOP_HI)) {
        RET(DSPN_EBOUNDS);
    }

    /* Copy the integer segment addresses into a local pointer array after validation. */
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
        const uint32_t *vec = (const uint32_t *)DSPN_P(p->segs_addr);
        int s;
        for (s = 0; s < nsegs; s++) {
            segs[s] = vec[s];

            if (!wr_ok(p, segs[s], seg_bytes) ||
                (segs[s] & (DSP_ALIGN - 1U)) != 0U) {
                RET(DSPN_EBOUNDS);
            }
        }
    }

    /* PX uses the plan window and arena exclusions, but does not read a capture or call libm. */
    if (p->mode == DSPN_MODE_PX) {
        const uint32_t *pb;
        const dsp_real *db;
        uint32_t plo, phi, ring, stride, yoff, nrec, ymax, span, rbytes;
        double ay, by;

        /* The pixel block is word-aligned and read-only. */
        if ((p->px_addr & 3U) != 0U ||
            !range_ok(p->px_addr, DSPN_PX_BYTES, BACKSTOP_LO, BACKSTOP_HI)) {
            RET(DSPN_EBOUNDS);
        }
        pb     = (const uint32_t *)DSPN_P(p->px_addr);
        plo    = pb[0];
        phi    = pb[1];
        ring   = pb[2];
        stride = pb[3];
        yoff   = pb[4];
        nrec   = pb[5];
        ymax   = pb[6];
        ay     = pw_double(pb[7], pb[8]);
        by     = pw_double(pb[9], pb[10]);

        /* Bound the record dimensions before multiplying them or selecting the Y triple. */
        if (nrec == 0U || nrec > DSPN_PX_MAXREC ||
            stride == 0U || stride > DSPN_PX_STRIDE_MAX || (stride & 3U) != 0U ||
            yoff > stride || (yoff & 3U) != 0U || yoff + 12U > stride ||
            (ring & 3U) != 0U || ymax == 0U || ymax > DSPN_PX_YMAX) {
            RET(DSPN_EGEOM);
        }
        span = nrec * stride;   /* both bounded above, so this cannot wrap */

        /* The display ring has its own allowed window, distinct from the plan and scratch. */
        if (plo >= phi || plo < BACKSTOP_LO || phi > BACKSTOP_HI ||
            !dspn_write_ok(ring, span, plo, phi)) {
            RET(DSPN_EBOUNDS);
        }
        /* The ring must not overlap scratch, params or any of the arena segments. */
        if (hits_arena(ring, span, segs, nsegs, seg_bytes) ||
            overlaps(ring, span, p->plan_addr, (uint32_t)sizeof(dsp_plan)) ||
            overlaps(ring, span, paddr, (uint32_t)sizeof(dsp_native_params)) ||
            overlaps(ring, span, p->px_addr, DSPN_PX_BYTES)) {
            RET(DSPN_EBOUNDS);
        }

        /* Read the native reduction in place after checking its range and alignment. */
        rbytes = p->red_nseg * (uint32_t)sizeof(dsp_real);
        if (p->red_nseg == 0U || p->red_nseg > (uint32_t)DSP_NSEG_MAX ||
            (p->red_db & ((uint32_t)sizeof(dsp_real) - 1U)) != 0U ||
            !wr_ok(p, p->red_db, rbytes) ||
            overlaps(ring, span, p->red_db, rbytes)) {
            RET(DSPN_EREDUCE);
        }

        /* Validate the whole slot map before writing any records. */
        if (!dspn_px_map_ok(pb + DSPN_PX_HDR, nrec, p->red_nseg)) { RET(DSPN_EGEOM); }
        db = (const dsp_real *)DSPN_P(p->red_db);
        dspn_px_fill(DSPN_P(ring), stride, yoff, nrec, ymax, ay, by,
                     pb + DSPN_PX_HDR, db);
        RET((int32_t)nrec);
    }

    if (!text_ok(p->sin_addr)  || !text_ok(p->cos_addr)   || !text_ok(p->sqrt_addr) ||
        !text_ok(p->log10_addr)|| !text_ok(p->floor_addr) || !text_ok(p->ceil_addr)) {
        RET(DSPN_EMATH);
    }
    g_sin   = (math1_fn)DSPN_FP(p->sin_addr);
    g_cos   = (math1_fn)DSPN_FP(p->cos_addr);
    g_sqrt  = (math1_fn)DSPN_FP(p->sqrt_addr);
    g_log10 = (math1_fn)DSPN_FP(p->log10_addr);
    g_floor = (math1_fn)DSPN_FP(p->floor_addr);
    g_ceil  = (math1_fn)DSPN_FP(p->ceil_addr);

    /* Keep the writable plan struct separate from the arrays the arena backs. */
    if (!wr_ok(p, p->plan_addr, (uint32_t)sizeof(dsp_plan)) ||
        hits_arena(p->plan_addr, (uint32_t)sizeof(dsp_plan), segs, nsegs, seg_bytes)) {
        RET(DSPN_EPLAN);
    }
    plan   = (const dsp_plan *)DSPN_P(p->plan_addr);
    plan_w = (dsp_plan *)DSPN_P(p->plan_addr);

    n = (int)p->cap_n;

    /* A failed plan build leaves a zeroed plan that RUN will refuse. */
    if (p->mode == DSPN_MODE_INIT) {

        void *segv[DSPN_MAX_SEGS];
        int rc, s;
        for (s = 0; s < nsegs; s++) { segv[s] = (void *)DSPN_P(segs[s]); }
        rc = dsp_plan_init_segs(plan_w, segv, nsegs, (size_t)seg_bytes,
                                n,
                                (int)p->init_kind,
                                (double)p->init_beta_milli / 1000.0,
                                (int)p->init_decim,
                                (int)p->init_method);
        /* Remap negative planner codes before reporting them in the wrapper's status word. */
        RET(rc < 0 ? rc + DSPN_PLAN_BASE : rc);
    }

    if (p->mode != DSPN_MODE_RUN) { RET(DSPN_EBOUNDS); }

    m = plan->m;
    if (plan->n == 0 || plan->n != n || m <= 0 || p->cap_perchunk == 0U) {
        RET(DSPN_EGEOM);
    }

    if (!plan_ptrs_ok(plan, segs, nsegs, seg_bytes)) {
        RET(DSPN_EARENA);
    }

    /* Read capture samples in place through the descriptor's chunk vector. */
    {
        uint32_t nch = p->cap_nchunks, want, i, left = (uint32_t)n;
        if (p->cap_perchunk == 0U || p->cap_stride < 8U || (p->cap_stride & 3U) != 0U ||
            p->cap_stride * p->cap_perchunk > DSPN_CHUNK_BYTES ||
            p->cap_stride * (p->cap_perchunk + 1U) <= DSPN_CHUNK_BYTES) {
            RET(DSPN_ECAPTURE);
        }
        /* The vector may cover more chunks than the requested record; address only the ones it touches. */
        want = ((uint32_t)n + p->cap_perchunk - 1U) / p->cap_perchunk;
        /* Bound the descriptor's vector length separately from the record's block count before multiplying. */
        if (nch == 0U || nch >= DSPN_MAX_NCHUNKS ||
            want > nch || want > (uint32_t)DSP_MAX_SRC_BLOCKS ||
            (p->cap_vec & 3U) != 0U ||
            !range_ok(p->cap_vec, nch * 4U, BACKSTOP_LO, BACKSTOP_HI)) {
            RET(DSPN_ECAPTURE);
        }
        for (i = 0; i < (uint32_t)DSP_MAX_SRC_BLOCKS; i++) {
            cap_src.blk[i] = NULL;
        }
        {
            const uint32_t *cvec = (const uint32_t *)DSPN_P(p->cap_vec);
            for (i = 0; i < want; i++) {
                /* The first sample can sit inside its chunk. Bound that partial block using the actual start offset. */
                const uint32_t base = (i == 0U) ? p->cap_chunk1 : cvec[i];
                const uint32_t take = (left < p->cap_perchunk) ? left : p->cap_perchunk;
                if ((base & 3U) != 0U || !stride_ok_rd(p, base, take, p->cap_stride)) {
                    RET(DSPN_ECAPTURE);
                }
                cap_src.blk[i] = (const unsigned char *)DSPN_P(base);
                left -= take;
            }
        }
        cap_src.nblock = (int)want;
        cap_src.per    = (int)p->cap_perchunk;
        cap_src.stride = (int)p->cap_stride;
        cap_src.len    = n;
    }

    /* Validate reduction geometry before converting the unsigned wire fields to signed indices. */
    ntrace = (int)p->red_nseg;
    if (p->red_nseg == 0U || p->red_nseg > (uint32_t)DSP_NSEG_MAX ||
        p->red_k0 >= (uint32_t)m || p->red_k1 >= (uint32_t)m ||
        p->red_k1 < p->red_k0) {
        RET(DSPN_EREDUCE);
    }

    /* Check all reduction outputs and results against each other and the arena. */
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

    /* A zero out_desc selects reduction only, leaving drawing to the Lua graph path. */
    if (p->out_desc != 0U) {
        uint32_t want     = p->red_nseg + 1U;
        uint32_t o_first  = want < p->out_perchunk ? want : p->out_perchunk;
        uint32_t o_second = want - o_first;
        if (p->out_perchunk == 0U ||
            !stride_ok_out(p, p->out_chunk1, o_first, 32U) ||
            !stride_ok_out(p, p->out_chunk2, o_second, 32U)) {
            RET(DSPN_EOUTPUT);
        }
        /* The descriptor is not in the output payload window; validate it separately before rewind. */
        if (!range_ok(p->out_desc, DESC_SPAN, BACKSTOP_LO, BACKSTOP_HI) ||
            (p->out_desc & 3U) != 0U ||
            hits_arena(p->out_desc, DESC_SPAN, segs, nsegs, seg_bytes)) {
            RET(DSPN_EDESC);
        }
    }

    nbins = dsp_spectrum_run_src(plan_w, &cap_src, n, NULL);
    if (nbins <= 0) { RET(DSPN_ERUN); }

    /* Reduce to one peak-preserving maximum and frequency per trace segment. */
    {
        dsp_bandmap map;
        dsp_real *db = (dsp_real *)DSPN_P(p->red_db);
        dsp_real *hz = (dsp_real *)DSPN_P(p->red_hz);

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
        /* Store dB as the reading and frequency as extra, matching the firmware graph binding. */
        if (p->out_desc != 0U) {
            for (k = 0; k < ntrace; k++) {
                rb_write(p->out_chunk1, p->out_chunk2, p->out_perchunk, k, (double)db[k]);
                rb_write_extra(p->out_chunk1, p->out_chunk2, p->out_perchunk, k,
                               (double)hz[k]);
            }
        }
    }

    /* Compute peaks and distortion over the same plotted window as the trace. */
    {
        double   *res   = (double *)DSPN_P(p->res_addr);
        int      *pbin  = (int *)DSPN_P(p->res_addr
                                             + (uint32_t)DSPN_RES_DOUBLES * 8U);
        dsp_real *pfrac = (dsp_real *)DSPN_P(p->res_addr
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
                /* Map the fractional peak bin to hertz, preserving the fitted offset and band direction. */
                res[2 * k]     = (double)pamp[k];
                res[2 * k + 1] = rf0 + (double)sense
                                 * ((double)pbin[k] + (double)pfrac[k]) * binhz;
            }
        }
        res[s + 0] = (double)npk;
        /* A refusal leaves the associated validity flag clear; numeric zeros are not validity signals. */
        if (dsp_thd_noise_vec(&plan->pwr_v, nbins, (int)p->red_k0, (int)p->red_k1, plan->kdc,
                          binhz, (int)(int32_t)p->res_mains, &plan->ip, &td) == DSP_OK) {
            res[s + 1] = td.thd;
            res[s + 2] = (td.signal != 0 && td.nharm > 0) ? 1.0 : 0.0;
            res[s + 3] = td.snr_db;
            res[s + 4] = (td.signal != 0) ? 1.0 : 0.0;
            res[s + 5] = td.noise_db;
            res[s + 6] = (td.nnoise > 0) ? 1.0 : 0.0;
            /* Fundamental frequency assumes no decimation, as used by the instrument app. */
            res[s + 7] = td.f0_hz;
            res[s + 8] = td.amp0;
        }
        res[s + 9] = (double)nbins;
    }

    /* Set the firmware's read/write cursors without clearing the currently drawn trace. */
    if (p->out_desc != 0U) {
        const uint32_t ch1 = p->out_chunk1, ch2 = p->out_chunk2;
        const uint32_t per = p->out_perchunk;
        const uint32_t nt  = (uint32_t)ntrace;
        const uint32_t cur = rb_addr(ch1, ch2, per, nt);
        const uint32_t chk = rb_chunk(ch1, ch2, per, nt);
        volatile uint32_t *dsc = (volatile uint32_t *)DSPN_P(p->out_desc);
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
