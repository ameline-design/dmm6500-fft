/* The image's entry point, on the host.
 *
 * dsp_native.c is built for powerpc-unknown-elf and entered by redirecting ki.peek8, so
 * until now nothing could call dsp_native_run and look at what it returned. Thirty-one
 * refusal sites, the mode dispatch and the status word were covered by reading alone -- which
 * is how DSP_EBETA came to be reported as DSPN_EOUTPUT for as long as it was.
 *
 * WHAT MAKES THIS POSSIBLE. Every address in dsp_native_params is a uint32_t, and a 64-bit
 * host reserves the low 4 GB, so no real pointer fits. DSPN_HOST switches DSPN_P and DSPN_A
 * (dsp_native_bounds.h) from the identity to base-relative, so the struct's addresses become
 * OFFSETS into one arena this file owns. The bounds checks are then exercised for real: an
 * offset inside DSPN_DRAM_LO..DSPN_DRAM_END passes the same comparison it passes on the
 * instrument, and one outside is refused by it.
 *
 * The shipped source is INCLUDED rather than linked, so the struct, the status codes and the
 * macros are the ones the image is built from and not a copy that could drift. The target
 * build is unaffected: with DSPN_HOST unset the macros are the cast this file always did, and
 * the built image is byte for byte the one built before they existed.
 *
 * THE MATH ENTRIES. sin_addr and the five beside it carry code addresses the loader resolved,
 * which an arena offset is not, so DSPN_FP goes through dspn_host_fp below: the six addresses
 * the caller puts in the struct are tokens, mapped here to the host's own libm. text_ok still
 * runs against the address in the struct, ahead of the mode dispatch, so the six still have
 * to sit inside the firmware text span to reach anything -- the token is what gets called,
 * not what gets validated.
 *
 * That is what makes a SUCCEEDING MODE_INIT and MODE_RUN reachable, and they are what the
 * frame actually does. The run path is exercised at both element layouts the two instruments
 * use: a DMM6500's 24-byte STYLE_STANDARD element, 8-aligned throughout, and a DMM7510's
 * 20-byte element, which leaves every other reading 4-aligned and is the case dsp_src_at
 * assembles a double from two word loads for. Nothing but reading covered that before.
 *
 * NOT bit-exactness against the instrument: the firmware's libm is not the host's and a
 * transcendental differs in the last places, so the figures here are checked against the
 * signal that was generated, with a tolerance, rather than against a recorded answer.
 */
#include <dlfcn.h>
#include <math.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define DSPN_HOST 1
unsigned char *dspn_host_base;

/* The shipped source DEFINES memset -- it has to, the target links no libc -- and this host
 * fortifies it into a macro, which turns the definition into a syntax error. The macro goes,
 * not the definition: the one under test is the one the image carries. */
#undef memset

#include "../dsp_native.c"

/* THE ARENA, AND WHY IT IS THIS BIG.
 *
 * Offsets have to satisfy the real bounds checks, and those are not just the DRAM window:
 * dspn_write_ok excludes DSPN_TEXT_LO..DSPN_TEXT_HI, 0x4000 to 0x527000, because that is the
 * firmware's own text and a write into it is not recoverable. So anything the image will
 * WRITE has to sit above 0x527000, which is what sets the size here -- an arena that merely
 * cleared DSPN_DRAM_LO was refused at the segment check, correctly.
 *
 * The params struct is different: it is only required to be in DRAM, so it goes below the
 * text at 0x3000, which is where the backstop starts. */
#define ARENA_BYTES  0x800000U
#define P_AT         0x3000U     /* the params struct: DRAM is all it must be */

/* The writable window, clear of DSPN_TEXT_HI, and what is placed in it. The plan, the two
 * reduction arrays and the results block all have to miss the arena -- dsp_plan_init carves
 * its arrays out of the segment bases and would overwrite anything else there -- so they sit
 * below it with the arena at the top. */
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

/* The capture, in a read window of its own: chunk payloads, DSPN_CHUNK_BYTES each, placed
 * apart the way the allocator places them rather than end to end. */
#define R_AT         0x700000U
#define R_BYTES      0x80000U
#define CAP_CHUNKS   4U
#define CAP_PITCH    0x10000U

/* The six math tokens. Inside DSPN_TEXT_LO..DSPN_TEXT_HI, because that is what text_ok
 * demands, and never dereferenced as addresses -- dspn_host_fp maps them. */
#define FN_SIN       (DSPN_TEXT_LO + 0x100U)
#define FN_COS       (DSPN_TEXT_LO + 0x200U)
#define FN_SQRT      (DSPN_TEXT_LO + 0x300U)
#define FN_LOG10     (DSPN_TEXT_LO + 0x400U)
#define FN_FLOOR     (DSPN_TEXT_LO + 0x500U)
#define FN_CEIL      (DSPN_TEXT_LO + 0x600U)

static int failures;
static int checks;

/* THE ENTRIES HAVE TO BE FETCHED PAST THE IMAGE'S OWN.
 *
 * dsp_native.c DEFINES sin, cos, sqrt, log10, floor and ceil, each one dispatching through
 * the global the params struct filled -- that is how dsp.c, compiled freestanding against
 * csrc/freestanding/math.h, reaches the firmware's libm without linking one. Those
 * definitions are in this translation unit and they are strong, so the name sin here is the
 * shim, and the linker binds dsp.c's calls to it as well.
 *
 * Which means returning &sin from dspn_host_fp points the shim at itself. Measured, not
 * reasoned: a hang in a two-instruction loop inside sin. RTLD_NEXT is what asks for the
 * entry AFTER this image's own, which is the host's real libm. */
static uintptr_t host_libm(const char *name)
{
    void *q = dlsym(RTLD_NEXT, name);
    if (q == NULL) {
        printf("  the host has no %s to lend the image\n", name);
        abort();
    }
    return (uintptr_t)q;
}

/* A token the image asks for and this file did not install. Returned rather than refused so
 * that the failure is a loud abort at the call, not a jump to address zero: an unmapped entry
 * means this file set up the struct wrongly, and that is worth saying out loud. */
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

/* A sine for this file's own use, for the same reason: calling sin here would go through the
 * shim, whose global points at whatever the last call installed. */
static double real_sin(double x)
{
    static math1_fn f;
    if (f == NULL) {
        const uintptr_t a = host_libm("sin");
        f = (math1_fn)a;
    }
    return f(x);
}

/* Declared printf-like, so the compiler checks the call sites rather than this file
 * suppressing the check that it should be passing. */
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

/* A struct that gets past the magic and the window checks, so a test can perturb one thing
 * and see one refusal. Deliberately NOT a runnable configuration: cap_n of zero means the run
 * path refuses on geometry, which is what the modes under test want anyway. */
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

/* The two words of a double, in the order pw_double reassembles them.
 *
 * The field names are the target's: there, w[0] is the IEEE754 high half and Lua packs it
 * first. Here they are simply the two words in memory order, which is what pw_double copies
 * them back as, so the value round-trips on either endianness without this file knowing
 * which one it is on. */
static void pack_double(double v, uint32_t *w0, uint32_t *w1)
{
    union { double d; uint32_t w[2]; } u;
    u.d = v;
    *w0 = u.w[0];
    *w1 = u.w[1];
}

/* Elements per chunk, the descriptor's own invariant: as many as fit, and one more must not.
 * 24 bytes gives 1365 and 20 gives 1638, which are the two instruments' STYLE_STANDARD
 * figures. Computed rather than written down, so a stride added here cannot be inconsistent
 * with what the image will accept. */
static uint32_t per_chunk(uint32_t stride)
{
    return DSPN_CHUNK_BYTES / stride;
}

static uint32_t cap_chunk_at(uint32_t i)
{
    return R_AT + i * CAP_PITCH;
}

/* One reading into the capture, at the element layout the params describe. memcpy because a
 * 20-byte element puts half of them on a 4-boundary and a double store there is not this
 * host's to make -- which is the case dsp_src_at exists for. */
static void cap_put(uint32_t first, uint32_t per, uint32_t stride, int i, double v)
{
    const uint32_t chunk = (uint32_t)i / per;
    const uint32_t idx   = (uint32_t)i % per;
    const uint32_t a     = (chunk == 0U ? first : cap_chunk_at(chunk)) + idx * stride;
    memcpy(dspn_host_base + a, &v, sizeof v);
}

/* The whole struct for a real frame, both modes. mode is the only thing the two calls
 * differ in, which is what the image expects: Lua packs one struct per frame and changes the
 * mode word. */
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
    /* The record does not start at the base of its chunk, which is why cap_chunk1 is a field
     * of its own and the vector's first entry is never read. skew is 4-aligned and not 8, the
     * residue a content scan really lands on. */
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

    /* out_desc zero asks for the reduction and nothing else, which is what the app does: it
     * writes the trace into the graph's own ring itself, through MODE_PX. */
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

/* A tone, exactly on a bin so that the window leaks nothing and the amplitude the peak
 * finder reports is the amplitude that went in. */
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

/* The strongest trace point, which is what the eye reads off the graph. */
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

/* One whole frame at one element layout: build the plan, fill the capture, transform,
 * reduce, rank. The figures are checked against the signal generated, not against a recorded
 * answer -- the instrument's libm is not this host's. */
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

    /* MODE_INIT, succeeding. Everything above this in the file refuses before the window
     * table is built; this is the first call that reaches the math entries at all. */
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

    /* The strongest peak, in hertz through the band map the caller supplied. One bin of
     * tolerance: the sub-bin estimate is a real number and the tone sits on a bin centre. */
    snprintf(name, sizeof name, "%s: the strongest peak is the tone", what);
    ok(name, fabs(res[1] - f) < binhz, "f=%.2f Hz wanted %.2f +-%.2f", res[1], f, binhz);

    /* Volts, not volts-squared and not decibels: writing the bins here instead of the
     * reduction put volts-squared on a decibel axis once. */
    snprintf(name, sizeof name, "%s: and its amplitude is the amplitude sent in", what);
    ok(name, fabs(res[0] - amp) < 0.05 * amp, "amp=%.4f V wanted %.4f", res[0], amp);

    /* The trace the graph draws, which is the reduction and not the bins. k0..k1 is every
     * bin, so each trace point covers m/nseg of them. */
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

    /* THE PARAMS STRUCT ITSELF, refused before it is dereferenced. Nothing is written,
     * because the word that would carry a status is inside the struct this refuses to trust. */
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

    /* The magic, which is the first thing any mode passes through. */
    {
        setup(DSPN_MODE_SEGS);
        params()->magic = DSP_NATIVE_MAGIC ^ 1U;
        int32_t st = run_status();
        ok("a wrong magic is EMAGIC, with the line that said so",
           st == DSPN_EMAGIC && params()->fail_at > 0U,
           "status=%d wanted %d, @%u", st, DSPN_EMAGIC, params()->fail_at);
    }

    /* MODE_SEGS: pure arithmetic, and the one forward that is deliberately NOT shifted. */
    {
        setup(DSPN_MODE_SEGS);
        params()->cap_n     = 2048U;
        params()->seg_bytes = 32768U;
        params()->init_decim = 1U;
        int32_t st = run_status();
        ok("MODE_SEGS answers a chunk count", st > 0, "status=%d", st);
    }

    /* The claim the shift rests on: dsp_plan_segs converts every invalid configuration to 0,
     * so it has no negative to forward and shifting MODE_SEGS would be unreachable. Checked
     * rather than read, because the whole PLAN_BASE design depends on it. */
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

    /* An unassigned mode. 3 was DSPN_MODE_BYTES and is now free; it must refuse rather than
     * fall into the run path. */
    {
        setup(3U);
        int32_t st = run_status();
        ok("the unassigned mode 3 is refused", st < 0, "status=%d", st);
        setup(99U);
        st = run_status();
        ok("an unknown mode is refused", st < 0, "status=%d", st);
    }

    /* MODE_FIND refusing its OWN arguments. It used to answer DSP_EARG, which is -1 and so
     * read back as EMAGIC -- a bad needle length reported as a corrupt params struct. */
    {
        setup(DSPN_MODE_FIND);
        params()->find_addr = W_AT;
        /* flen is the first word of the find block; zero is refused. */
        memset(dspn_host_base + W_AT, 0, 64);
        int32_t st = run_status();
        ok("a zero needle length is EFIND, not EMAGIC",
           st == DSPN_EFIND, "status=%d wanted %d", st, DSPN_EFIND);

        setup(DSPN_MODE_FIND);
        params()->find_addr = DSPN_DRAM_LO - 4U;    /* the block itself out of range */
        st = run_status();
        ok("a find block outside the backstop is refused", st < 0, "status=%d", st);
    }

    /* The math entries, refused before anything calls through them -- which is what makes
     * every refusal above reachable with no math at all.
     *
     * A WHOLE ARENA HAS TO BE PRESENTED TO REACH THIS TEST. The arena is validated first, so
     * a struct carrying only a bad sin_addr refuses at the segment check instead and the
     * check passes for the wrong reason; written without the arena, this one reported
     * EBOUNDS @798. */
    {
        const int nsegs = dsp_plan_segs(2048, 1, DSP_FFT_RADIX2, (size_t)SEG_BYTES);
        setup_frame(DSPN_MODE_INIT, 2048, (uint32_t)nsegs, 24U, 0U, 256U, 0, 50.0);
        params()->sin_addr = DSPN_TEXT_HI;      /* one past the span */
        int32_t st = run_status();
        ok("a math entry outside the text span is EMATH",
           st == DSPN_EMATH, "status=%d wanted %d @%u", st, DSPN_EMATH, params()->fail_at);
    }

    /* THE FORWARDED SPACE, which is the whole reason this file exists. dsp_plan_init_segs
     * refuses a Kaiser beta before it builds anything, and that refusal is DSP_EBETA, -6 --
     * the same number as DSPN_EOUTPUT. It has to come back shifted. */
    {
        setup(DSPN_MODE_INIT);
        params()->cap_n       = 2048U;
        params()->seg_bytes   = SEG_BYTES;
        params()->nsegs       = 1U;
        params()->segs_addr   = SEGV_AT;
        /* The vector holds the payload's address, which has to be writable inside the window
         * and DSP_ALIGN-aligned -- both checked by the image, and getting it wrong is how this
         * test first refused at @814 instead of reaching the plan builder. */
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

    /* A WHOLE FRAME, at both instruments' element layouts.
     *
     * 24 bytes is a DMM6500's STYLE_STANDARD element and every reading in it is 8-aligned.
     * 20 bytes is a DMM7510's, and it walks every 4-aligned residue, so half the readings
     * take dsp_src_at's two-word assembly instead of a single load. The record starts
     * 4 bytes into its first chunk in both cases, which is a residue a content scan really
     * lands on and which the single-load path must not assume away. */
    frame_case("6500 element, 24 bytes", 24U, 4U);
    frame_case("7510 element, 20 bytes", 20U, 4U);

    /* And the same capture read as one 8-aligned block from the chunk base, which is the
     * shape every figure in docs/PERFORMANCE.md was measured on. */
    frame_case("8-aligned record start", 24U, 0U);

    printf("%d check(s), %d failure(s)\n", checks, failures);
    free(arena);
    return failures == 0 ? 0 : 1;
}
