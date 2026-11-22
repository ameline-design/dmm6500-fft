/* Exercise the real native entry point on the host, with wire addresses mapped into a test arena. */
#include <dlfcn.h>
#include <math.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define DSPN_HOST 1
unsigned char *dspn_host_base;

/* Undefine the fortified memset macro before including the freestanding definition. */
#undef memset

#include "../dsp_native.c"

/* Model the target's address windows with offsets into one writable host allocation. */
#define ARENA_BYTES  0x800000U
#define P_AT         0x3000U     /* the params struct: DRAM is all it must be */

/* Place all plan and scratch allocations in the declared writable window. */
#define W_AT         0x600000U
#define W_BYTES      0x100000U
#define SEGV_AT      0x600000U   /* the vector of segment addresses */
#define PLAN_AT      0x601000U   /* dsp_plan */
#define DB_AT        0x602000U   /* red_db, red_nseg of dsp_real */
#define HZ_AT        0x603000U   /* red_hz */
#define RES_AT       0x604000U   /* the results block, 8-aligned */
#define CAPV_AT      0x605000U   /* the capture's chunk vector */
#define SEG_AT       0x610000U   /* the arena's first segment payload */
#define SEG_BYTES    0x40000U
#define MAX_SEGS_HERE 4U         /* what the window above has room for */

/* Model independent capture chunks in their own read window. */
#define R_AT         0x700000U
#define R_BYTES      0x80000U
#define CAP_CHUNKS   4U
#define CAP_PITCH    0x10000U

/* Use callable test tokens inside the target's accepted .text interval. */
#define FN_SIN       (DSPN_TEXT_LO + 0x100U)
#define FN_COS       (DSPN_TEXT_LO + 0x200U)
#define FN_SQRT      (DSPN_TEXT_LO + 0x300U)
#define FN_LOG10     (DSPN_TEXT_LO + 0x400U)
#define FN_FLOOR     (DSPN_TEXT_LO + 0x500U)
#define FN_CEIL      (DSPN_TEXT_LO + 0x600U)

static int failures;
static int checks;

/* Resolve host libm symbols past the image's own wrappers to avoid recursion. */
static uintptr_t host_libm(const char *name)
{
    void *q = dlsym(RTLD_NEXT, name);
    if (q == NULL) {
        printf("  the host has no %s to lend the image\n", name);
        abort();
    }
    return (uintptr_t)q;
}

/* Make an unexpected math token fail visibly instead of selecting a random function. */
static double fp_unmapped(double x)
{
    (void)x;
    printf("  dspn_host_fp: the image called an entry this test never installed\n");
    abort();
}

uintptr_t dspn_host_fp(uint32_t a)
{
    const math1_fn unmapped = fp_unmapped;
    switch (a) {
    case FN_SIN:   return host_libm("sin");
    case FN_COS:   return host_libm("cos");
    case FN_SQRT:  return host_libm("sqrt");
    case FN_LOG10: return host_libm("log10");
    case FN_FLOOR: return host_libm("floor");
    case FN_CEIL:  return host_libm("ceil");
    default:       break;
    }
    return (uintptr_t)unmapped;
}

/* Generate the fixture sine through host libm, not through the image's wrapper. */
static double real_sin(double x)
{
    static math1_fn f;
    if (f == NULL) {
        const uintptr_t a = host_libm("sin");
        f = (math1_fn)a;
    }
    return f(x);
}

static void ok(const char *name, int cond, const char *fmt, ...)
    __attribute__((format(printf, 3, 4)));

static void ok(const char *name, int cond, const char *fmt, ...) {
    va_list ap;
    checks++;
    printf("  %-58s %s", name, cond ? "ok" : "FAILED");
    if (fmt != NULL) {
        printf("   ");
        va_start(ap, fmt);
        vprintf(fmt, ap);
        va_end(ap);
    }
    printf("\n");
    if (!cond) { failures++; }
}

static dsp_native_params *params(void) {
    return (dsp_native_params *)(void *)(dspn_host_base + P_AT);
}

/* Start with a valid params block so each refusal test can perturb one condition. */
static void setup(uint32_t mode) {
    dsp_native_params *p = params();
    memset(p, 0, sizeof(*p));
    p->magic   = DSP_NATIVE_MAGIC;
    p->mode    = mode;
    p->wr_lo   = W_AT;          p->wr_hi  = W_AT + W_BYTES;
    p->rd_lo   = W_AT;          p->rd_hi  = W_AT + W_BYTES;
    p->out_lo  = W_AT;          p->out_hi = W_AT + W_BYTES;
    p->status  = 0xDEADBEEFU;
    p->fail_at = 0U;
    dspn_params_addr = P_AT;
}

static int32_t run_status(void) {
    dsp_native_run(NULL);
    return (int32_t)params()->status;
}

/* Use the host union word order, matching pw_double on this build. */
static void pack_double(double v, uint32_t *w0, uint32_t *w1)
{
    union { double d; uint32_t w[2]; } u;
    u.d = v;
    *w0 = u.w[0];
    *w1 = u.w[1];
}

/* Set perchunk to the number of complete elements that fit a payload. */
static uint32_t per_chunk(uint32_t stride)
{
    return DSPN_CHUNK_BYTES / stride;
}

static uint32_t cap_chunk_at(uint32_t i)
{
    return R_AT + i * CAP_PITCH;
}

/* Copy doubles as bytes because a 20-byte stride does not align every sample to eight bytes. */
static void cap_put(uint32_t first, uint32_t per, uint32_t stride, int i, double v)
{
    const uint32_t chunk = (uint32_t)i / per;
    const uint32_t idx   = (uint32_t)i % per;
    const uint32_t a     = (chunk == 0U ? first : cap_chunk_at(chunk)) + idx * stride;
    memcpy(dspn_host_base + a, &v, sizeof v);
}

/* Use the same packed params for plan initialization and frame execution. */
static void setup_frame(uint32_t mode, int n, uint32_t nsegs, uint32_t stride, uint32_t skew,
                        uint32_t nseg, int m, double binhz)
{
    dsp_native_params *p = params();
    uint32_t *segv = (uint32_t *)(void *)(dspn_host_base + SEGV_AT);
    uint32_t *capv = (uint32_t *)(void *)(dspn_host_base + CAPV_AT);
    uint32_t s;

    setup(mode);
    p->rd_lo = R_AT;  p->rd_hi = R_AT + R_BYTES;

    p->seg_bytes = SEG_BYTES;
    p->nsegs     = nsegs;
    p->segs_addr = SEGV_AT;
    for (s = 0U; s < nsegs; s++) { segv[s] = SEG_AT + s * SEG_BYTES; }
    p->plan_addr = PLAN_AT;

    p->cap_n        = (uint32_t)n;
    p->cap_stride   = stride;
    p->cap_perchunk = per_chunk(stride);
    /* Exercise a first sample inside a chunk, not just one at the payload base. */
    p->cap_chunk1   = cap_chunk_at(0U) + skew;
    p->cap_vec      = CAPV_AT;
    p->cap_nchunks  = CAP_CHUNKS;
    for (s = 0U; s < CAP_CHUNKS; s++) { capv[s] = cap_chunk_at(s); }

    p->sin_addr   = FN_SIN;
    p->cos_addr   = FN_COS;
    p->sqrt_addr  = FN_SQRT;
    p->log10_addr = FN_LOG10;
    p->floor_addr = FN_FLOOR;
    p->ceil_addr  = FN_CEIL;

    p->init_kind        = (uint32_t)DSP_WINDOW_HANN;
    p->init_beta_milli  = 0U;
    p->init_decim       = 1U;
    p->init_method      = (uint32_t)DSP_FFT_RADIX2;

    /* out_desc == 0 selects reduction without writing a firmware reading buffer. */
    p->out_desc = 0U;

    p->red_nseg  = nseg;
    p->red_k0    = 0U;
    p->red_k1    = m > 0 ? (uint32_t)(m - 1) : 0U;
    p->red_db    = DB_AT;
    p->red_hz    = HZ_AT;
    p->red_sense = 1U;
    pack_double(0.0,    &p->red_f0_hi,     &p->red_f0_lo);
    pack_double(binhz,  &p->red_binhz_hi,  &p->red_binhz_lo);
    pack_double(-120.0, &p->red_dbmin_hi,  &p->red_dbmin_lo);
    pack_double(0.0,    &p->red_dbmax_hi,  &p->red_dbmax_lo);
    pack_double(1e-9,   &p->red_vfloor_hi, &p->red_vfloor_lo);

    p->res_addr  = RES_AT;
    p->res_npk   = 4U;
    p->res_mains = (uint32_t)(int32_t)DSP_THD_MAINS_BOTH;
}

/* Place the fixture tone exactly on a bin to isolate wrapper amplitude and frequency. */
static void fill_tone(int n, uint32_t stride, uint32_t skew, double fs, double f, double amp)
{
    const double two_pi = 6.283185307179586476925286766559;
    const uint32_t per   = per_chunk(stride);
    const uint32_t first = cap_chunk_at(0U) + skew;
    int i;
    for (i = 0; i < n; i++) {
        cap_put(first, per, stride, i, amp * real_sin(two_pi * f * (double)i / fs));
    }
}

static const double *res_doubles(void)
{
    return (const double *)(const void *)(dspn_host_base + RES_AT);
}

static int trace_argmax(uint32_t nseg)
{
    const dsp_real *db = (const dsp_real *)(const void *)(dspn_host_base + DB_AT);
    uint32_t k;
    uint32_t best = 0U;
    for (k = 1U; k < nseg; k++) {
        if (db[k] > db[best]) { best = k; }
    }
    return (int)best;
}

/* Exercise plan build, capture, reduction and peaks with the supplied element layout. */
static void frame_case(const char *what, uint32_t stride, uint32_t skew)
{
    const int    n     = 2048;
    const double fs    = 102400.0;
    const double f     = 6400.0;          /* bin 128 of 1024, exactly */
    const double amp   = 1.0;
    const uint32_t nseg = 256U;
    const double binhz = fs / (double)n;
    const int    kwant = (int)(f / binhz);
    char name[96];
    int nsegs_needed;
    int32_t st;
    const dsp_plan *plan;
    int m, seg_want, seg_got;
    const double *res;

    nsegs_needed = dsp_plan_segs(n, 1, DSP_FFT_RADIX2, (size_t)SEG_BYTES);
    snprintf(name, sizeof name, "%s: the arena takes %d segment(s) of this size", what,
             nsegs_needed);
    ok(name, nsegs_needed > 0 && (uint32_t)nsegs_needed <= MAX_SEGS_HERE,
       "dsp_plan_segs=%d", nsegs_needed);
    if (nsegs_needed <= 0 || (uint32_t)nsegs_needed > MAX_SEGS_HERE) { return; }

    setup_frame(DSPN_MODE_INIT, n, (uint32_t)nsegs_needed, stride, skew, nseg, 0, binhz);
    st = run_status();
    snprintf(name, sizeof name, "%s: MODE_INIT builds the plan", what);
    ok(name, st == 0, "status=%d @%u", st, params()->fail_at);
    if (st != 0) { return; }

    plan = (const dsp_plan *)(const void *)(dspn_host_base + PLAN_AT);
    m = plan->m;
    snprintf(name, sizeof name, "%s: the plan reports n/2 bins", what);
    ok(name, plan->n == n && m == n / 2, "n=%d m=%d", plan->n, m);

    fill_tone(n, stride, skew, fs, f, amp);

    setup_frame(DSPN_MODE_RUN, n, (uint32_t)nsegs_needed, stride, skew, nseg, m, binhz);
    st = run_status();
    snprintf(name, sizeof name, "%s: MODE_RUN answers the trace length", what);
    ok(name, st == (int32_t)nseg, "status=%d wanted %u @%u", st, nseg, params()->fail_at);
    if (st != (int32_t)nseg) { return; }

    res = res_doubles();

    snprintf(name, sizeof name, "%s: it reports the bins it transformed", what);
    ok(name, res[2 * DSPN_RES_PEAKS + 9] > (double)(m - 1) - 0.5 &&
             res[2 * DSPN_RES_PEAKS + 9] < (double)m + 0.5,
       "nbins=%.0f wanted %d", res[2 * DSPN_RES_PEAKS + 9], m);

    snprintf(name, sizeof name, "%s: it ranked the peaks it was asked for", what);
    ok(name, res[2 * DSPN_RES_PEAKS + 0] > 0.5, "npeaks=%.0f", res[2 * DSPN_RES_PEAKS + 0]);

    /* Use bin-width tolerance on the measured peak frequency. */
    snprintf(name, sizeof name, "%s: the strongest peak is the tone", what);
    ok(name, fabs(res[1] - f) < binhz, "f=%.2f Hz wanted %.2f +-%.2f", res[1], f, binhz);

    /* Peak amplitude is returned in volts; the trace is in dBV. */
    snprintf(name, sizeof name, "%s: and its amplitude is the amplitude sent in", what);
    ok(name, fabs(res[0] - amp) < 0.05 * amp, "amp=%.4f V wanted %.4f", res[0], amp);

    seg_want = kwant / (m / (int)nseg);
    seg_got  = trace_argmax(nseg);
    snprintf(name, sizeof name, "%s: the trace peaks in the segment holding the tone", what);
    ok(name, seg_got >= seg_want - 1 && seg_got <= seg_want + 1,
       "segment %d wanted %d of %u", seg_got, seg_want, nseg);
}

int main(void) {
    unsigned char *arena = calloc(1, ARENA_BYTES);
    if (arena == NULL) { printf("no arena\n"); return 1; }
    dspn_host_base = arena;

    printf("dsp_native_run on the host\n");

    /* An invalid params address must be refused without dereferencing it, including status. */
    {
        setup(DSPN_MODE_SEGS);
        uint32_t keep = params()->status;
        dspn_params_addr = DSPN_DRAM_LO - 4U;     /* below the backstop */
        int rc = dsp_native_run(NULL);
        ok("a params address below the backstop writes no status",
           rc == 0 && params()->status == keep, "rc=%d status unchanged=%d",
           rc, params()->status == keep);
        dspn_params_addr = P_AT;
    }

    {
        setup(DSPN_MODE_SEGS);
        params()->magic = DSP_NATIVE_MAGIC ^ 1U;
        int32_t st = run_status();
        ok("a wrong magic is EMAGIC, with the line that said so",
           st == DSPN_EMAGIC && params()->fail_at > 0U,
           "status=%d wanted %d, @%u", st, DSPN_EMAGIC, params()->fail_at);
    }

    /* MODE_SEGS returns an unsigned count and does not remap it into the plan-error space. */
    {
        setup(DSPN_MODE_SEGS);
        params()->cap_n     = 2048U;
        params()->seg_bytes = 32768U;
        params()->init_decim = 1U;
        int32_t st = run_status();
        ok("MODE_SEGS answers a chunk count", st > 0, "status=%d", st);
    }

    /* Invalid sizing returns zero, not a forwarded negative error. */
    {
        setup(DSPN_MODE_SEGS);
        params()->cap_n     = 2048U;
        params()->seg_bytes = 0U;            /* no segment size */
        params()->init_decim = 1U;
        int32_t a = run_status();
        setup(DSPN_MODE_SEGS);
        params()->cap_n     = 3U;            /* not a power of two */
        params()->seg_bytes = 32768U;
        params()->init_decim = 1U;
        int32_t b = run_status();
        ok("MODE_SEGS never answers a negative, so it needs no shift",
           a == 0 && b == 0, "seg_bytes=0 -> %d, n=3 -> %d", a, b);
    }

    /* An unassigned mode must not fall through to RUN. */
    {
        setup(3U);
        int32_t st = run_status();
        ok("the unassigned mode 3 is refused", st < 0, "status=%d", st);
        setup(99U);
        st = run_status();
        ok("an unknown mode is refused", st < 0, "status=%d", st);
    }

    /* A malformed search reports EFIND, distinct from bad params magic. */
    {
        setup(DSPN_MODE_FIND);
        params()->find_addr = W_AT;

        memset(dspn_host_base + W_AT, 0, 64);
        int32_t st = run_status();
        ok("a zero needle length is EFIND, not EMAGIC",
           st == DSPN_EFIND, "status=%d wanted %d", st, DSPN_EFIND);

        setup(DSPN_MODE_FIND);
        params()->find_addr = DSPN_DRAM_LO - 4U;    /* the block itself out of range */
        st = run_status();
        ok("a find block outside the backstop is refused", st < 0, "status=%d", st);
    }

    /* A bad math token must be refused before indirect calls. */
    {
        const int nsegs = dsp_plan_segs(2048, 1, DSP_FFT_RADIX2, (size_t)SEG_BYTES);
        setup_frame(DSPN_MODE_INIT, 2048, (uint32_t)nsegs, 24U, 0U, 256U, 0, 50.0);
        params()->sin_addr = DSPN_TEXT_HI;      /* one past the span */
        int32_t st = run_status();
        ok("a math entry outside the text span is EMATH",
           st == DSPN_EMATH, "status=%d wanted %d @%u", st, DSPN_EMATH, params()->fail_at);
    }

    /* A rejected Kaiser beta reports DSP_EBETA in the forwarded error range. */
    {
        setup(DSPN_MODE_INIT);
        params()->cap_n       = 2048U;
        params()->seg_bytes   = SEG_BYTES;
        params()->nsegs       = 1U;
        params()->segs_addr   = SEGV_AT;
        /* Use a real aligned segment so the failure comes from planner validation, not bounds checks. */
        *(uint32_t *)(void *)(dspn_host_base + SEGV_AT) = SEG_AT;
        params()->plan_addr   = PLAN_AT;
        params()->init_decim  = 1U;
        params()->sin_addr    = FN_SIN;
        params()->cos_addr    = FN_COS;
        params()->sqrt_addr   = FN_SQRT;
        params()->log10_addr  = FN_LOG10;
        params()->floor_addr  = FN_FLOOR;
        params()->ceil_addr   = FN_CEIL;
        params()->init_kind   = (uint32_t)DSP_WINDOW_KAISER;
        params()->init_beta_milli = 999000U;    /* far outside DSP_KAISER_BETA_MAX */
        int32_t st = run_status();
        ok("a plan refusal comes back shifted out of the wrapper's space",
           st == DSP_EBETA + DSPN_PLAN_BASE,
           "status=%d wanted %d @%u (DSP_EBETA %d + PLAN_BASE %d)",
           st, DSP_EBETA + DSPN_PLAN_BASE, params()->fail_at, DSP_EBETA, DSPN_PLAN_BASE);
        ok("and it is not mistakable for the wrapper's own -6",
           st != DSPN_EOUTPUT, "status=%d DSPN_EOUTPUT=%d", st, DSPN_EOUTPUT);
    }

    /* Run complete frames for both supported capture element layouts. */
    frame_case("6500 element, 24 bytes", 24U, 4U);
    frame_case("7510 element, 20 bytes", 20U, 4U);

    /* Also exercise an aligned capture that fits a single payload. */
    frame_case("8-aligned record start", 24U, 0U);

    printf("%d check(s), %d failure(s)\n", checks, failures);
    free(arena);
    return failures == 0 ? 0 : 1;
}
