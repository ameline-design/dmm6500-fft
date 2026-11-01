/* dsp.c -- see dsp.h. A translation of tsp/fft_core.tsp, tsp/spectrum_ui.tsp's peak
 * finder and tsp/spectrum_graph.tsp's segment reduction.
 *
 * Inner loops are written as explicit multiply-accumulate expressions over pointers the
 * loop advances, with two or more independent chains wherever a chain exists, because the
 * target's FPU issues one single-precision multiply-add a cycle through a three-stage
 * pipeline and a single dependent chain stalls every third instruction. Sums that run over
 * a whole record -- the window sum, the weighted mean, the gain-table cosines, the FIR --
 * accumulate in double.
 */

#include "dsp.h"

#include <float.h>  /* FLT_MAX, DBL_MAX; freestanding C99 provides it */
#include <limits.h> /* INT_MAX, INT_MIN; freestanding C99 provides it */
#include <math.h>
#include <stdint.h> /* uintptr_t only; freestanding C99 provides it */
#include <string.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

/* Multiply by these rather than dividing by the constant: each folds, so no divide is
 * executed. A power of two is written as the literal at the site, 0.5 for 2.0. INV_M_PI
 * follows the guard above so it tracks whichever M_PI is in force. */
#define INV_M_PI    (1.0 / M_PI)
#define INV_DSP_GHX (1.0 / DSP_GHX)
#define INV_DSP_DN  (1.0 / (double)DSP_DN)

/* Transcendentals at the element precision.
 *
 * The e300c4's FPU is built around a single-precision multiply-add array, so the single
 * entry points are the cheaper ones -- a shorter polynomial, each term a single-precision
 * multiply-add. They are also accurate enough, which is the part that had to be measured
 * rather than assumed: against a double reference the gain table comes out 1.6e-9 relative
 * and the twiddles 2.4e-7 absolute, which puts a twiddle-induced spur at -132 dB against the
 * -103 dB floor the single-precision transform already has. 29 dB of margin.
 *
 * The double build keeps the double entry points, because its whole purpose is to measure
 * what double precision buys; single-precision trig there would cap its noise floor at -132
 * and the comparison would measure the library's trig instead of its arithmetic.
 *
 * floor and ceil stay double either way: they are exact, and the single versions would only
 * narrow the range they accept. Define DSP_NO_SINGLE_MATH to use the double entry points in
 * both builds -- a libm without sinf/cosf/sqrtf/log10f needs it, and those four are the only
 * external references this choice adds.
 */
#if defined(DSP_DOUBLE) || defined(DSP_NO_SINGLE_MATH)
#define DSP_SIN(x)   sin(x)
#define DSP_COS(x)   cos(x)
#define DSP_SQRT(x)  sqrt(x)
#define DSP_LOG10(x) log10(x)
#else
#define DSP_SIN(x)   ((double)sinf((float)(x)))
#define DSP_COS(x)   ((double)cosf((float)(x)))
#define DSP_SQRT(x)  ((double)sqrtf((float)(x)))
#define DSP_LOG10(x) ((double)log10f((float)(x)))
#endif

/* Largest magnitude dsp_real holds. A double outside it is undefined to convert, not merely
 * rounded to an infinity, so anything computed in double and stored into an output array is
 * checked against this first. */
#ifdef DSP_DOUBLE
#define DSP_REAL_MAX DBL_MAX
#else
#define DSP_REAL_MAX FLT_MAX
#endif

/* A caller-supplied limit or scale has to be an ordinary finite number. These reach the trace
 * buffer directly, and a non-finite value there is a refused graph parameter and a modal
 * dialog on the front panel. Two ways in, which is why the test is for finiteness and not
 * just for a NaN: a NaN defeats any range test written as a negation, and an infinity passes
 * `> 0.0` and then makes `0 * binhz` a NaN. */
static int dsp_finite(const double v) {
    return isfinite(v) != 0;
}

/* Finite and representable in dsp_real. The second half matters in the single build, where a
 * perfectly good double can exceed FLT_MAX: converting it is undefined rather than saturating,
 * so the value is refused before the store rather than after. */
static int dsp_storable(const double v) {
    /* Cast, not promoted: FLT_MAX is a float, and -Wdouble-promotion is on because an
     * implicit widening is how a precision decision goes unrecorded. */
    return isfinite(v) != 0 && v <= (double)DSP_REAL_MAX && v >= -(double)DSP_REAL_MAX;
}

/* Halving a non-negative int, as a shift. Signed division by two is not one instruction: C
 * rounds toward zero, so the compiler must add the sign bit in first. Every value halved in
 * this file is a count or an index. None of them sits in an inner loop -- the inner loops
 * have no divides at all -- so this is about the code the compiler emits, not a measured
 * saving. */
static int dsp_half(const int v) {
    return (int)((unsigned)v >> 1U);
}

/* Odd test without a signed bitwise operand. */
static int dsp_is_odd(const int v) {
    return ((unsigned)v & 1U) != 0U;
}

#if DSP_CHECK_OVERLAP
/* Do two objects share a byte? Every caller below knows both bases and both lengths from its
 * own arguments, so this is the real overlap test rather than a comparison of bases.
 *
 * Through uintptr_t: comparing unrelated pointers with < is undefined, where converting and
 * comparing integers is merely implementation-defined, and is well behaved on any target with
 * a flat address space. Subtracting the smaller from the larger keeps it clear of the overflow
 * that `pa + na` would risk at the top of the range.
 *
 * Applied only to pairs where at least one side is written. Two read-only buffers sharing
 * bytes cannot produce a wrong answer, so checking them would cost code for no failure. */
static int dsp_overlaps(const void *a, const size_t na, const void *b, const size_t nb) {
    uintptr_t pa, pb;
    if (a == NULL || b == NULL || na == 0U || nb == 0U)
        return 0;
    pa = (uintptr_t)a;
    pb = (uintptr_t)b;
    if (pa == pb)
        return 1;
    if (pa < pb)
        return (pb - pa) < (uintptr_t)na;
    return (pa - pb) < (uintptr_t)nb;
}
#endif /* DSP_CHECK_OVERLAP */

/* floor() and ceil() to int, with the range check inside instead of at each call site.
 *
 * A cast applied straight to a function result is what -Wbad-function-cast flags. Converting
 * an out-of-range double to int is undefined, and not benignly so: clang at -O1 emits a trap
 * for it where other levels return a clamp. Routing every conversion through here lets that
 * flag stay on, so an unguarded one is a build failure.
 *
 * Callers still bound their own quotients, and that is where the meaning is: a filter
 * transition too narrow to realise is refused, not clamped. These two only guarantee the
 * arithmetic is defined when a caller has not. */
static int dsp_ifloor(const double v) {
    const double f = floor(v);
    /* Positives, so a NaN takes the first branch rather than falling through both. */
    if (!(f >= (double)INT_MIN))
        return INT_MIN;
    if (!(f <= (double)INT_MAX))
        return INT_MAX;
    return (int)f;
}

static int dsp_iceil(const double v) {
    const double f = ceil(v);
    if (!(f >= (double)INT_MIN))
        return INT_MIN;
    if (!(f <= (double)INT_MAX))
        return INT_MAX;
    return (int)f;
}

/* The one definition with external linkage that is not a function. DSP_DOUBLE changes the
 * element type of every array in the interface, and a caller compiled without it against a
 * library compiled with it links without complaint, so there has to be something to compare. */
const int dsp_real_size = (int)sizeof(dsp_real);

/* ------------------------------------------------------------------------- */
/* windows                                                                   */
/* ------------------------------------------------------------------------- */

/* Index-parallel to the DSP_WINDOW_* enum: a0 - a1*cos + a2*cos2 - a3*cos3. Kaiser has no
 * entry, which is how dsp_window tells it apart. */
static const double dsp_wincos[DSP_WINDOW_COUNT][4] = {
    {1.0, 0.0, 0.0, 0.0},                 /* RECT */
    {0.5, 0.5, 0.0, 0.0},                 /* HANN */
    {0.42, 0.5, 0.08, 0.0},               /* BLACKMAN */
    {0.35875, 0.48829, 0.14128, 0.01168}, /* BLACKMAN_HARRIS */
    {0.0, 0.0, 0.0, 0.0},                 /* KAISER: unused */
};

/* I0 by its power series, sum of ((x/2)^k / k!)^2. The term ratio is (x/2)^2/k^2, so the
 * series rises until k passes x/2 and converges only after: the cap has to clear that, not
 * just the point the terms get small. Beta 18 stops itself at 33 terms, DSP_KAISER_BETA_MAX
 * at 166. */
#define DSP_I0_TERMS 200

/* dk carries k as a double rather than converting it twice a term. Exact: k is far under
 * 2^53, so adding 1.0 never rounds, and the quotient is the one the conversion gave. The
 * conversion is a store and a load on a core with no direct move between the integer and
 * floating register files, and this runs up to 33 terms for each of n/2 window samples. */
static double dsp_bessel_i0(const double x) {
    const double hh = (x * 0.5) * (x * 0.5);
    double t = 1.0, s = 1.0, dk = 0.0;
    int k;
    for (k = 1; k <= DSP_I0_TERMS; k++) {
        dk += 1.0;
        t = t * hh / (dk * dk);
        s += t;
        if (t < s * 1e-17)
            return s;
    }
    return s;
}

int dsp_window(dsp_real *DSP_RESTRICT w, const int n, const int kind, const double beta) {
    double di;
    int half, i;
    if (w == NULL || n < 2)
        return DSP_EARG;
    if (kind < 0 || kind >= DSP_WINDOW_COUNT)
        return DSP_EARG;
    half = dsp_half(n + 1);

    if (kind == DSP_WINDOW_KAISER) {
        double i0b, inv_i0b, ustep;
        /* Both bounds as positives, so a NaN beta fails them rather than passing two
         * negated comparisons and reaching the series. */
        if (!(beta >= DSP_KAISER_BETA_MIN) || !(beta <= DSP_KAISER_BETA_MAX))
            return DSP_EBETA;
        i0b = dsp_bessel_i0(beta);
        if (!(i0b > 0.0))
            return DSP_EBETA;
        inv_i0b = 1.0 / i0b;
        /* Both reciprocals hoisted: the window spans u in [-1,1] in steps of 2/(n-1), and
         * every sample is scaled by the same I0(beta). */
        ustep = 2.0 / (double)(n - 1);
        /* di holds i exactly, so u is the value the conversion gave and the int-to-double
         * stays out of the loop. Not u += ustep: that accumulates rounding along the
         * window, where this does not. */
        for (i = 0, di = 0.0; i < half; i++, di += 1.0) {
            double u = ustep * di - 1.0;
            double s = 1.0 - u * u;
            double v;
            if (s < 0.0)
                s = 0.0;
            v = dsp_bessel_i0(beta * DSP_SQRT(s)) * inv_i0b;
            w[i] = (dsp_real)v;
            w[n - 1 - i] = (dsp_real)v;
        }
    } else {
        const double *c = dsp_wincos[kind];
        const double step = 2.0 * M_PI / (double)(n - 1);
        for (i = 0, di = 0.0; i < half; i++, di += 1.0) {
            const double t = step * di;
            double v = c[0] - c[1] * DSP_COS(t) + c[2] * DSP_COS(2.0 * t) -
                       c[3] * DSP_COS(3.0 * t);
            w[i] = (dsp_real)v;
            w[n - 1 - i] = (dsp_real)v;
        }
    }
    return DSP_OK;
}

/* ------------------------------------------------------------------------- */
/* interpolation tables                                                      */
/* ------------------------------------------------------------------------- */

/* G(x) from the window samples in use. The window is symmetric about (n-1)/2, so the full
 * sum is twice the half sum and only n/2 cosines are evaluated. */
/* inv_wsum rather than wsum: this runs DSP_GN + DSP_KDCN + 1 times per plan against one
 * window sum, so the reciprocal is formed once by the caller. */
static double dsp_gain_at(const dsp_real *w, const int n, const double x, const double inv_wsum) {
    const double ctr = 0.5 * (double)(n - 1);
    const double a = 2.0 * M_PI * x / (double)n;
    double s = 0.0, d;
    int half = dsp_half(n), i;
    /* d carries (double)i - ctr, incremented rather than converted. Exact at every step:
     * ctr is a half-integer at most n/2, so the sum needs a fraction bit and 15 integer
     * bits against 53. This is the hottest conversion in a plan -- n/2 of them for each of
     * DSP_GN + DSP_KDCN + 1 calls, and on the target the conversion goes through memory. */
    for (i = 0, d = -ctr; i < half; i++, d += 1.0)
        s += (double)w[i] * DSP_COS(a * d);
    s = 2.0 * s * inv_wsum;
    return s < 0.0 ? -s : s;
}

/* A lookup and, for Kaiser, one square root. No table and no window samples: the half-width
 * is a property of the window's shape, not of the record length. */
int dsp_window_lobe(const int kind, const double beta) {
    switch (kind) {
    /* Rect nulls at one bin and Hann at two; two is the minimum the contract names, so
     * they share an answer. */
    case DSP_WINDOW_RECT:
    case DSP_WINDOW_HANN:
        return 2;
    case DSP_WINDOW_BLACKMAN:
        return 3;
    case DSP_WINDOW_BLACKMAN_HARRIS:
        return 4;
    case DSP_WINDOW_KAISER: {
        /* The first null is at sqrt(1 + (beta/pi)^2) bins. Refused betas never reach a
         * plan, but the argument is reachable, so a NaN must not come out as an int. */
        double a, v;
        if (!dsp_finite(beta) || !(beta >= 0.0))
            return 2;
        a = beta * INV_M_PI;
        v = DSP_SQRT(1.0 + a * a);   /* three digits is plenty for a ceil() */
        return dsp_iceil(v) < 2 ? 2 : dsp_iceil(v);
    }
    default:
        return 0;
    }
}

static int dsp_win_tables(const dsp_real *w, const int n, dsp_interp *ip, int *kdc_out) {
    double rt[DSP_DN + 1];
    double wsum = 0.0, inv_wsum;
    int one, nd, mono, j, jd, b, kdc;
    const int half = dsp_half(n);

    for (j = 0; j < half; j++)
        wsum += (double)w[j];
    wsum = 2.0 * wsum;
    if (!(wsum > 0.0))
        return DSP_EARG;

    inv_wsum = 1.0 / wsum;
    for (j = 0; j <= DSP_GN; j++)
        ip->gtab[j] = dsp_gain_at(w, n, (double)j * DSP_GHX, inv_wsum);

    /* one and nd are node counts, not lengths: one bin and half a bin. */
    one = dsp_ifloor(INV_DSP_GHX + 0.5);
    nd = dsp_ifloor(0.5 * INV_DSP_GHX + 0.5);
    /* The grid has to reach 1.5 bins; at the shipped constants it reaches exactly that.
     * Shrinking DSP_GN without raising DSP_GHX would read past the end of gtab. */
    if (one + nd > DSP_GN || nd > DSP_DN)
        return DSP_EARG;

    for (jd = 0; jd <= nd; jd++) {
        const double cc = ip->gtab[jd], rr = ip->gtab[one - jd], ll = ip->gtab[one + jd];
        rt[jd] = (rr - ll) / (ll + 2.0 * cc + rr);
    }

    mono = 1;
    for (jd = 1; jd <= nd; jd++)
        if (rt[jd] <= rt[jd - 1])
            mono = 0;
    ip->mono = mono;
    for (j = 0; j <= DSP_DN; j++)
        ip->dtab[j] = 0.0;
    if (mono && rt[nd] > 0.0) {
        /* Inverted onto a grid uniform in r, so a lookup is an index rather than a search. */
        const double hr = rt[nd] * INV_DSP_DN;
        double target = 0.0;
        int mm;
        jd = 0;
        for (mm = 0; mm <= DSP_DN; mm++, target += hr) {
            double r0, r1, f = 0.0;
            while (jd < nd - 1 && rt[jd + 1] < target)
                jd++;
            r0 = rt[jd];
            r1 = rt[jd + 1];
            if (r1 > r0)
                f = (target - r0) / (r1 - r0);
            ip->dtab[mm] = ((double)jd + f) * DSP_GHX;
        }
        ip->dtab[DSP_DN] = (double)nd * DSP_GHX;
        ip->dhr = hr;
        ip->inv_dhr = 1.0 / hr;
    } else {
        ip->dhr = 0.0;
        ip->inv_dhr = 0.0;
    }

    /* How far up from DC dsp_load's mean removal reaches. Removing a weighted mean of
     * D + A*G(b)*cos(phase) takes 2*A*G(b)^2 out of the tone's own bin: at bin 1 a 1.000 V
     * tone reads 0.589 V under Hann. The largest b, not the first, since G is not
     * monotonic. */
    kdc = 0;
    for (b = 1; b <= DSP_KDCN; b++) {
        double s = dsp_gain_at(w, n, (double)b, inv_wsum);
        if (2.0 * s * s > DSP_DCTOL)
            kdc = b;
    }
    *kdc_out = kdc;
    return DSP_OK;
}

double dsp_win_gain(const dsp_interp *ip, double d) {
    double t, a;
    int m;
    if (ip == NULL)
        return 1.0;
    if (d < 0.0)
        d = -d;
    t = d * INV_DSP_GHX;
    /* The index is bounded after the conversion, not the quotient before it, because that is
     * the bound the table actually needs and a static analyser can follow it. dsp_ifloor is
     * total -- it clamps rather than converting an out-of-range double, which is undefined and
     * traps at -O1 -- so a NaN arrives here as INT_MIN and a huge offset as INT_MAX, and both
     * land on the same clamp as an offset past the end of the grid. */
    m = dsp_ifloor(t);
    if (m < 0 || m >= DSP_GN)
        return ip->gtab[DSP_GN];
    a = ip->gtab[m];
    return a + (t - (double)m) * (ip->gtab[m + 1] - a);
}

int dsp_win_offset(const dsp_interp *ip, double r, double *d_out) {
    double t, d;
    int neg = 0, m;
    if (ip == NULL || d_out == NULL)
        return DSP_EARG;
    /* Gated on the step, scaled by its reciprocal: dhr is the sentinel the table documents
     * and inv_dhr is formed with it, once a plan rather than once a line. */
    if (!(ip->dhr > 0.0))
        return DSP_EDECLINE;
    if (r < 0.0) {
        r = -r;
        neg = 1;
    }
    t = r * ip->inv_dhr;
    /* The index bounded after the conversion, as in dsp_win_gain and for the same reasons. */
    m = dsp_ifloor(t);
    if (m < 0 || m >= DSP_DN) {
        d = ip->dtab[DSP_DN];
    } else {
        const double a = ip->dtab[m];
        d = a + (t - (double)m) * (ip->dtab[m + 1] - a);
    }
    *d_out = neg ? -d : d;
    return DSP_OK;
}

int dsp_peak_interp(const dsp_interp *ip, const dsp_real *DSP_RESTRICT pwr, const int k, const int nbins,
                    double *d_out, double *amp_out) {
    double pc, pl, pr, cc, ll, rr, den, d, g;
    if (ip == NULL || pwr == NULL)
        return DSP_EARG;
#if DSP_CHECK_OVERLAP
    /* Both outputs in one object would have the amplitude overwrite the offset, and either
     * inside the bins would blank a bin still to be read. nbins bounds pwr only after the
     * check below, so the extent used here is the three bins this actually touches. */
    if (dsp_overlaps(d_out, sizeof(*d_out), amp_out, sizeof(*amp_out)))
        return DSP_EARG;
#endif
    /* Before the subtraction below, which overflows at INT_MIN. A spectrum of fewer than
     * three bins has no interior bin to estimate from, which is the same answer. */
    if (nbins < 3)
        return DSP_EDECLINE;
    if (k < 1 || k >= nbins - 1)
        return DSP_EDECLINE;
    pc = (double)pwr[k];
    pl = (double)pwr[k - 1];
    pr = (double)pwr[k + 1];
    if (!(pc > 0.0) || !(pl >= 0.0) || !(pr >= 0.0))
        return DSP_EDECLINE;
    cc = DSP_SQRT(pc);
    ll = DSP_SQRT(pl);
    rr = DSP_SQRT(pr);
    den = ll + 2.0 * cc + rr;
    if (!(den > 0.0))
        return DSP_EDECLINE;
    if (dsp_win_offset(ip, (rr - ll) / den, &d) != DSP_OK)
        return DSP_EDECLINE;
    g = dsp_win_gain(ip, d);
    if (d_out != NULL)
        *d_out = d;
    if (amp_out != NULL)
        *amp_out = (g > 0.0) ? cc / g : cc;
    return DSP_OK;
}

/* ------------------------------------------------------------------------- */
/* arena layout                                                              */
/* ------------------------------------------------------------------------- */

typedef struct {
    size_t w, swp_a, swp_b, sw1_a, sw1_b, sw2_a, sw2_b, twr, twi, utr, uti,
        re, im, wkr, wki, blkr, blki, pwr, h, fir_out, total;
} dsp_layout;

/* The walk's state. `seg` is 0 for one contiguous arena, which is what dsp_plan_bytes and
 * dsp_plan_init ask for and the only behaviour this had before segments existed.
 *
 * With a non-zero `seg` the offsets returned are into a virtual space laid out as
 * consecutive segments, so `off / seg` selects the segment and `off % seg` is the position
 * inside it. That keeps every array flat and contiguous -- the transform is unchanged --
 * and confines the whole question to this walk. */
typedef struct {
    size_t at;
    size_t seg;
    int    fail; /* an array larger than one segment; no placement exists */
} dsp_walk;

static size_t dsp_bump(dsp_walk *wk, const size_t bytes) {
    const size_t need = (bytes + (DSP_ALIGN - 1U)) & ~(size_t)(DSP_ALIGN - 1U);
    size_t off = wk->at;
    if (wk->seg != 0U && need != 0U) {
        size_t within;
        /* Arrays are never split, so one has to fit a segment whole. The caller turns this
         * into DSP_ESEG rather than laying out something that straddles. */
        if (need > wk->seg) {
            wk->fail = 1;
            return 0;
        }
        within = off % wk->seg;
        if (within + need > wk->seg)
            off += wk->seg - within; /* skip the tail; start of the next segment */
    }
    wk->at = off + need;
    return off;
}

/* Both bounds matter. Without the upper one the layout walk wrapped a 32-bit size_t and
 * dsp_plan_bytes under-reported by four orders; see DSP_N_MAX. */
static int dsp_is_pow2(const int n) {
    return n >= 4 && n <= DSP_N_MAX && ((unsigned)n & ((unsigned)n - 1U)) == 0U;
}

/* Four-step factors, m1 the smaller: the gather's strided footprint is then m1 cache
 * blocks per array, and the sub-transform it feeds stays well inside 32 kB. */
static void dsp_fs_factors(const int m, int *m1, int *m2) {
    unsigned bits = 0, t;
    /* Unsigned throughout: a shift of a signed value is implementation-defined once the sign
     * bit is involved, and these are all counts. */
    for (t = (unsigned)m; t > 1U; t >>= 1U)
        bits++;
    *m1 = (int)(1U << (bits / 2U));
    *m2 = m / *m1;
}

/* Bit-reversal as a swap list over 0..len-1; only the pairs that move are kept, and
 * disjoint pairs out of len indices means never more than len/2 of them. */
static int dsp_build_swaps(const int len, int *a, int *b) {
    int ns = 0, i;
    unsigned j = 0;
    for (i = 0; i <= len - 2; i++) {
        if ((unsigned)i < j) {
            a[ns] = i;
            b[ns] = (int)j;
            ns++;
        }
        {
            unsigned kk = (unsigned)len >> 1U;
            while (kk <= j) {
                j -= kk;
                kk >>= 1U;
            }
            j += kk;
        }
    }
    return ns;
}

/* Does the four-step work at this size, or does dsp_rfft substitute radix-2? The gather and
 * the scatter step a whole DSP_FS_BLOCK of columns with no partial case, so m2 has to reach
 * one block; DSP_FS_MIN is the separate, larger size it starts paying off at. */
static int dsp_fs_usable(const int m, const int m2) {
    return m2 >= DSP_FS_BLOCK && m >= DSP_FS_MIN;
}

/* Which decomposition the arena is built for, after the small-size substitution. Resolved
 * once here so the layout and the dispatch cannot disagree about what was allocated.
 *
 * Takes a method its callers have already range-checked; both do so before they get here, so
 * repeating it would add a branch nothing can reach. */
static int dsp_method_of(const int m, const int m2, const int method) {
    if (method == DSP_FFT_FOURSTEP && !dsp_fs_usable(m, m2))
        return DSP_FFT_RADIX2;
    return method;
}

/* Which decomposition a built plan holds the arrays for. The two ask for disjoint extras --
 * radix-2 the swap list over m, the four-step an intermediate matrix plus a gather block and
 * the factor swap lists -- so the arena identifies its own method. */
static int dsp_method_built(const dsp_plan *p) {
    if (p->wkr != NULL && p->blkr != NULL && p->sw1_a != NULL)
        return DSP_FFT_FOURSTEP;
    return DSP_FFT_RADIX2;
}

/* One walk, used by dsp_plan_bytes and dsp_plan_init alike so the two cannot disagree.
 *
 * Sized for the one decomposition asked for, not for both. The arrays are not a superset of
 * each other -- radix-2 wants the bit-reversal swap list over m and nothing else, the
 * four-step wants an m-point intermediate matrix plus a gather block and the two factor swap
 * lists -- so sizing for the union carries whichever the plan will not run: at n = 16,384 in
 * single that is the 32,768-byte swap list, 8 % of the arena.
 * An offset of 0 means the array was not allocated and the plan's pointer stays NULL. */
static int dsp_layout_of(int n, const int decim, const int method, const size_t seg_bytes,
                         dsp_layout *lay) {
    dsp_walk wk;
    size_t r = sizeof(dsp_real);
    int m, ntw, m1, m2, meth;
    if (decim < 1 || decim > DSP_DECIM_MAX)
        return DSP_EARG;
    if (method < 0 || method >= DSP_FFT_COUNT)
        return DSP_EARG;
    if (!dsp_is_pow2(n))
        return DSP_EPOW2;
    /* A segment smaller than the alignment, or not a multiple of it, would put arrays off a
     * DSP_ALIGN boundary however well aligned the segment bases are. */
    if (seg_bytes != 0U && (seg_bytes < DSP_ALIGN || (seg_bytes & (DSP_ALIGN - 1U)) != 0U))
        return DSP_EARG;
    wk.at = 0;
    wk.seg = seg_bytes;
    wk.fail = 0;
    m = dsp_half(n);
    ntw = (m >= 4) ? m - 2 : 1; /* stages len=4..m contribute len/2 each: m-2 in total */
    dsp_fs_factors(m, &m1, &m2);
    meth = dsp_method_of(m, m2, method);
    lay->w     = dsp_bump(&wk, (size_t)n * r);
    /* Radix-2's own swap list, needed when it is the decomposition or when the four-step has
     * substituted it. */
    if (meth == DSP_FFT_RADIX2) {
        lay->swp_a = dsp_bump(&wk, (size_t)dsp_half(m) * sizeof(int));
        lay->swp_b = dsp_bump(&wk, (size_t)dsp_half(m) * sizeof(int));
    } else {
        lay->swp_a = 0;
        lay->swp_b = 0;
    }
    /* The four-step bit-reverses its two factors instead, which is m1/2 + m2/2 against m/2. */
    if (meth == DSP_FFT_FOURSTEP) {
        lay->sw1_a = dsp_bump(&wk, (size_t)(dsp_half(m1) + 1) * sizeof(int));
        lay->sw1_b = dsp_bump(&wk, (size_t)(dsp_half(m1) + 1) * sizeof(int));
        lay->sw2_a = dsp_bump(&wk, (size_t)(dsp_half(m2) + 1) * sizeof(int));
        lay->sw2_b = dsp_bump(&wk, (size_t)(dsp_half(m2) + 1) * sizeof(int));
    } else {
        lay->sw1_a = 0;
        lay->sw1_b = 0;
        lay->sw2_a = 0;
        lay->sw2_b = 0;
    }
    lay->twr   = dsp_bump(&wk, (size_t)ntw * r);
    lay->twi   = dsp_bump(&wk, (size_t)ntw * r);
    lay->utr   = dsp_bump(&wk, (size_t)m * r);
    lay->uti   = dsp_bump(&wk, (size_t)m * r);
    lay->re    = dsp_bump(&wk, (size_t)m * r);
    lay->im    = dsp_bump(&wk, (size_t)m * r);
    /* The four-step's intermediate matrix and its gather block. Radix-2 is in place and
     * wants neither. */
    if (meth == DSP_FFT_FOURSTEP) {
        lay->wkr  = dsp_bump(&wk, (size_t)m * r);
        lay->wki  = dsp_bump(&wk, (size_t)m * r);
        lay->blkr = dsp_bump(&wk, (size_t)(DSP_FS_BLOCK * m1) * r);
        lay->blki = dsp_bump(&wk, (size_t)(DSP_FS_BLOCK * m1) * r);
    } else {
        lay->wkr  = 0;
        lay->wki  = 0;
        lay->blkr = 0;
        lay->blki = 0;
    }
    lay->pwr   = dsp_bump(&wk, (size_t)m * r);
    lay->h     = dsp_bump(&wk, (size_t)DSP_FIR_MAXTAPS * r);
    /* Only when something will decimate. The read budget stops allowing even decim 2 from
     * n = 3906 up -- (DSP_FIR_MAXM - maxtaps)/(n-1) falls below 2 there -- so this is
     * nothing at every count the application offers above 2048. */
    lay->fir_out = (decim > 1) ? dsp_bump(&wk, (size_t)n * sizeof(double)) : 0;
    /* Checked once at the end rather than at every bump: the walk records the failure and
     * keeps going, so there is one place that turns it into a status. */
    if (wk.fail)
        return DSP_ESEG;
    lay->total = wk.at;
    return DSP_OK;
}

size_t dsp_plan_bytes(const int n, const int decim, const int method) {
    dsp_layout lay;
    if (dsp_layout_of(n, decim, method, 0U, &lay) != DSP_OK)
        return 0;
    return lay.total;
}

int dsp_plan_segs(const int n, const int decim, const int method, const size_t seg_bytes) {
    dsp_layout lay;
    size_t segs;
    if (seg_bytes == 0U)
        return 0;
    if (dsp_layout_of(n, decim, method, seg_bytes, &lay) != DSP_OK)
        return 0;
    /* lay.total is the end of the last array in the virtual space, and no array straddles a
     * boundary, so the ceiling divide is the count. */
    segs = (lay.total + seg_bytes - 1U) / seg_bytes;
    if (segs > (size_t)DSP_N_MAX)
        return 0;
    return (int)segs;
}

/* Where an offset lands. With seg == 0 the virtual space is the one arena and this is the
 * addition it always was; otherwise the offset splits into a segment index and a position
 * inside it. Every array is whole, so one pointer per array is all the transform ever needs
 * and no inner loop learns about segments. */
static void *dsp_seg_at(void *const *segs, const size_t seg_bytes, const size_t off) {
    if (seg_bytes == 0U)
        return (void *)((unsigned char *)segs[0] + off);
    return (void *)((unsigned char *)segs[off / seg_bytes] + (off % seg_bytes));
}

/* The shared body of dsp_plan_init and dsp_plan_init_segs.
 *
 * seg_bytes == 0 is the flat case: segs holds one base and flat_bytes is its size, which is
 * what gets compared against the layout. Otherwise nsegs segments of seg_bytes each are
 * available and the count is what gets compared. */
static int dsp_plan_build(dsp_plan *p, void *const *segs, const int nsegs, const size_t seg_bytes,
                          const size_t flat_bytes, int n, const int kind, const double beta,
                          const int decim, const int method) {
    dsp_layout lay;
    int m, rc, i, idx, len, half, kdc, meth, si;
    double wsum, di;

    if (p == NULL)
        return DSP_EARG;
    /* Before every other check, not after them, so that every refusal below leaves the plan
     * entirely zero. That is what the header promises, and what stops a caller which ignores
     * the return code from running a frame on the pointers of a plan it has already released:
     * p->n == 0 fails dsp_spectrum_run's guard and p->m == 0 fails dsp_rfft's. */
    memset(p, 0, sizeof(*p));
    if (segs == NULL || nsegs < 1)
        return DSP_EARG;
    for (si = 0; si < nsegs; si++) {
        if (segs[si] == NULL)
            return DSP_EARG;
    }
#if DSP_CHECK_OVERLAP
    /* The plan against its own arena. Both extents are arguments, so this is checkable, and
     * the failure it prevents is the worst in the library: the carve-up below writes table
     * pointers into p while the tables themselves are built in the arena, so a plan sitting
     * inside its arena has its own pointers overwritten by window samples and every later
     * call reads whatever that left. Every segment is checked, not just the first. */
    for (si = 0; si < nsegs; si++) {
        if (dsp_overlaps(p, sizeof(*p), segs[si], (seg_bytes == 0U) ? flat_bytes : seg_bytes))
            return DSP_EARG;
    }
#endif
    rc = dsp_layout_of(n, decim, method, seg_bytes, &lay);
    if (rc != DSP_OK)
        return rc;
    if (seg_bytes == 0U) {
        if (flat_bytes < lay.total)
            return DSP_ENOMEM;
    } else {
        if ((size_t)nsegs * seg_bytes < lay.total)
            return DSP_ENOMEM;
    }
    /* Every base, for the same reason the flat case checks its one: the offsets are aligned
     * within a segment, so a misaligned base misaligns every array in it. */
    for (si = 0; si < nsegs; si++) {
        if (((uintptr_t)segs[si] & (uintptr_t)(DSP_ALIGN - 1)) != 0)
            return DSP_EALIGN;
    }

    m = dsp_half(n);
    dsp_fs_factors(m, &p->m1, &p->m2);
    /* The decomposition the arena was sized for, with the small-size substitution already
     * applied, so dsp_rfft dispatches on a method whose arrays are certain to be there.
     * dsp_layout_of has range-checked `method` by this point. */
    meth = dsp_method_of(m, p->m2, method);
    p->n      = n;
    p->m      = m;
    p->kind   = kind;
    p->beta   = beta;
    p->decim  = decim;
    p->method = meth;
    p->w     = (dsp_real *)dsp_seg_at(segs, seg_bytes, lay.w);
    p->twr   = (dsp_real *)dsp_seg_at(segs, seg_bytes, lay.twr);
    p->twi   = (dsp_real *)dsp_seg_at(segs, seg_bytes, lay.twi);
    p->utr   = (dsp_real *)dsp_seg_at(segs, seg_bytes, lay.utr);
    p->uti   = (dsp_real *)dsp_seg_at(segs, seg_bytes, lay.uti);
    p->re    = (dsp_real *)dsp_seg_at(segs, seg_bytes, lay.re);
    p->im    = (dsp_real *)dsp_seg_at(segs, seg_bytes, lay.im);
    p->pwr   = (dsp_real *)dsp_seg_at(segs, seg_bytes, lay.pwr);
    p->h     = (dsp_real *)dsp_seg_at(segs, seg_bytes, lay.h);
    /* The rest only exist for the decomposition that reads them, by the same conditions the
     * layout used. A pointer left NULL is an array this plan did not pay for. */
    if (meth == DSP_FFT_RADIX2) {
        p->swp_a = (int *)dsp_seg_at(segs, seg_bytes, lay.swp_a);
        p->swp_b = (int *)dsp_seg_at(segs, seg_bytes, lay.swp_b);
    }
    if (meth == DSP_FFT_FOURSTEP) {
        p->sw1_a = (int *)dsp_seg_at(segs, seg_bytes, lay.sw1_a);
        p->sw1_b = (int *)dsp_seg_at(segs, seg_bytes, lay.sw1_b);
        p->sw2_a = (int *)dsp_seg_at(segs, seg_bytes, lay.sw2_a);
        p->sw2_b = (int *)dsp_seg_at(segs, seg_bytes, lay.sw2_b);
        p->wkr   = (dsp_real *)dsp_seg_at(segs, seg_bytes, lay.wkr);
        p->wki   = (dsp_real *)dsp_seg_at(segs, seg_bytes, lay.wki);
        p->blkr  = (dsp_real *)dsp_seg_at(segs, seg_bytes, lay.blkr);
        p->blki  = (dsp_real *)dsp_seg_at(segs, seg_bytes, lay.blki);
    }
    p->fir_out = (decim > 1) ? (double *)dsp_seg_at(segs, seg_bytes, lay.fir_out) : NULL;

    rc = dsp_window(p->w, n, kind, beta);
    if (rc != DSP_OK) {
        memset(p, 0, sizeof(*p));
        return rc;
    }

    /* The scale comes from the window sum. Assuming n/2 for Hann rather than summing it
     * reads every amplitude 0.2 % low at n = 512. */
    wsum = 0.0;
    for (i = 0; i < n; i++)
        wsum += (double)p->w[i];
    if (!(wsum > 0.0)) {
        memset(p, 0, sizeof(*p));
        return DSP_EARG;
    }
    p->wsum = wsum;
    p->cg = wsum / (double)n;
    /* Volts would be 2/(n*cg); the untangle leaves every bin doubled, so 1/(n*cg), squared
     * because the output is power. */
    {
        const double iw = 1.0 / wsum; /* one divide, squared */
        p->ksq = iw * iw;
    }

    rc = dsp_win_tables(p->w, n, &p->ip, &kdc);
    if (rc != DSP_OK) {
        memset(p, 0, sizeof(*p));
        return rc;
    }
    p->kdc = kdc;
    p->mono = p->ip.mono;
    p->ip.lobe = dsp_window_lobe(kind, beta);

    /* Bit-reversal as swap lists, one per transform length the plan can run: m for the
     * in-place radix-2, and the two four-step factors. Keeping them out of the frame matters
     * -- the Gold-Rader walk has an unpredictable branch per element, and running it inside
     * the four-step's inner passes cost 2.5x on the host measurement. */
    if (p->swp_a != NULL)
        p->nswp = dsp_build_swaps(m, p->swp_a, p->swp_b);
    if (p->sw1_a != NULL) {
        p->nsw1 = dsp_build_swaps(p->m1, p->sw1_a, p->sw1_b);
        p->nsw2 = dsp_build_swaps(p->m2, p->sw2_a, p->sw2_b);
    }

    /* Butterfly twiddles, flattened stage-major: the stage with half-length h occupies the
     * next h entries. Stage 1 (len 2) has twiddle 1 and needs none. Because the layout is
     * stage-major and every four-step factor divides m, the table for a sub-transform of
     * length L is the first L-2 entries of this one, which is what lets the four-step reuse it
     * without a second table. */
    idx = 0;
    for (len = 4; len <= m; len *= 2) {
        const double ang = -2.0 * M_PI / (double)len;
        half = dsp_half(len);
        /* One angle a step, formed from an exact double i rather than a conversion, and
         * reused by both calls instead of converting twice. */
        for (i = 0, di = 0.0; i < half; i++, di += 1.0) {
            const double t = ang * di;
            p->twr[idx] = (dsp_real)DSP_COS(t);
            p->twi[idx] = (dsp_real)DSP_SIN(t);
            idx++;
        }
    }

    {
        const double ang = -2.0 * M_PI / (double)n;
        for (i = 0, di = 0.0; i < m; i++, di += 1.0) {
            const double t = ang * di;
            p->utr[i] = (dsp_real)DSP_COS(t);
            p->uti[i] = (dsp_real)DSP_SIN(t);
        }
    }
    return DSP_OK;
}

int dsp_plan_init(dsp_plan *p, void *arena, const size_t bytes, int n, const int kind, const double beta,
                  const int decim, const int method) {
    /* An lvalue so the one-segment case can share dsp_plan_build's interface. A NULL arena
     * still reaches the segs[0] == NULL test and comes back DSP_EARG. */
    void *one = arena;
    return dsp_plan_build(p, &one, 1, 0U, bytes, n, kind, beta, decim, method);
}

int dsp_plan_init_segs(dsp_plan *p, void *const *segs, const int nsegs, const size_t seg_bytes, int n,
                       const int kind, const double beta, const int decim, const int method) {
    /* Zero would mean the flat case, where nsegs and seg_bytes say nothing about how much
     * memory there is. Callers with one contiguous block want dsp_plan_init. */
    if (seg_bytes == 0U) {
        if (p != NULL)
            memset(p, 0, sizeof(*p));
        return DSP_EARG;
    }
    return dsp_plan_build(p, segs, nsegs, seg_bytes, 0U, n, kind, beta, decim, method);
}

int dsp_plan_set_fir(dsp_plan *p, const dsp_real *h, const int ntaps) {
    int i;
    if (p == NULL || p->n < 4 || p->h == NULL)
        return DSP_EARG;
    if (ntaps < 0 || ntaps > DSP_FIR_MAXTAPS)
        return DSP_EARG;
    if (ntaps > 0 && h == NULL)
        return DSP_EARG;
    /* Taps on a plan that does not decimate are refused HERE, at configure time, rather
     * than ignored in every frame. dsp_spectrum_run filters only where the decimation makes
     * it necessary, and dsp_plan_init gives a decim-1 plan no output buffer to filter into,
     * so accepting them promised a filter that could never run: a 500 Hz tone passed a
     * 2-20 kHz band-pass at -0.08 dBV with nothing in any return value to say so. */
    if (ntaps > 0 && p->decim < 2)
        return DSP_EARG;
    /* h is copied rather than aliased: the taps live in the arena the plan already owns, so
     * the caller's design buffer can be a local and nothing outlives it. */
    for (i = 0; i < ntaps; i++)
        p->h[i] = h[i];
    p->ntaps = ntaps;
    return ntaps;
}

int dsp_plan_set_yield(dsp_plan *p, const dsp_yield_fn fn, void *ctx) {
    if (p == NULL || p->n < 4)
        return DSP_EARG;
    p->yield = fn;
    p->yield_ctx = ctx;
    return DSP_OK;
}

/* One null test per boundary, of which there are a fixed few a frame. Not in any inner loop:
 * the display task needs to run a handful of times across a frame, not per bin. */
static void dsp_do_yield(const dsp_plan *p) {
    if (p->yield != NULL)
        p->yield(p->yield_ctx);
}

/* ------------------------------------------------------------------------- */
/* load                                                                      */
/* ------------------------------------------------------------------------- */

int dsp_load(const double *DSP_RESTRICT x, const int n, const dsp_real *DSP_RESTRICT w, const double wsum,
             dsp_real *DSP_RESTRICT re, dsp_real *DSP_RESTRICT im, double *mean_out) {
    double s0 = 0.0, s1 = 0.0, mean;
    int i, k, m;
    if (x == NULL || w == NULL || re == NULL || im == NULL)
        return DSP_EARG;
    if (!dsp_is_pow2(n))
        return DSP_EPOW2;
    /* Its own code: a window sum that is not positive is an argument this cannot divide by,
     * and reporting it as EPOW2 named the one argument that was fine. */
    if (!(wsum > 0.0))
        return DSP_EARG;
    m = dsp_half(n);
#if DSP_CHECK_OVERLAP
    /* The two halves of the packed record against each other and against the source and the
     * window they are built from. The packing loop reads x[i] and w[i] while writing re[k]
     * and im[k] with k behind i, so an overlap reads samples it has already replaced. */
    {
        const size_t zh = (size_t)m * sizeof(*re);
        const size_t zx = (size_t)n * sizeof(*x);
        const size_t zw = (size_t)n * sizeof(*w);
        if (dsp_overlaps(re, zh, im, zh) || dsp_overlaps(re, zh, x, zx)
            || dsp_overlaps(re, zh, w, zw) || dsp_overlaps(im, zh, x, zx)
            || dsp_overlaps(im, zh, w, zw)
            || dsp_overlaps(mean_out, sizeof(*mean_out), x, zx)
            || dsp_overlaps(mean_out, sizeof(*mean_out), w, zw)
            || dsp_overlaps(mean_out, sizeof(*mean_out), re, zh)
            || dsp_overlaps(mean_out, sizeof(*mean_out), im, zh))
            return DSP_EARG;
    }
#endif
    /* Two chains, split over the even and odd samples, which is also the pairing the packing
     * loop below wants, so the record is walked the same way twice. */
    for (i = 0; i < n; i += 2) {
        s0 = s0 + x[i] * (double)w[i];
        s1 = s1 + x[i + 1] * (double)w[i + 1];
    }
    mean = (s0 + s1) / wsum;
    /* The subtraction happens in double and rounds once into the complex array: in the
     * single build that is what keeps the pedestal residue at the rounding of the products
     * rather than at the rounding of a difference of two large numbers. */
    for (k = 0, i = 0; k < m; k++, i += 2) {
        re[k] = (dsp_real)((x[i] - mean) * (double)w[i]);
        im[k] = (dsp_real)((x[i + 1] - mean) * (double)w[i + 1]);
    }
    if (mean_out != NULL)
        *mean_out = mean;
    return DSP_OK;
}

/* ------------------------------------------------------------------------- */
/* transform: two decompositions                                             */
/* ------------------------------------------------------------------------- */

/* Textbook in-place radix-2, decimation in time, bit reversal from the swap list. Streams
 * both arrays once per stage, so at 16,384 samples it moves 64 kB through a 32 kB cache
 * thirteen times. Kept as the accuracy and traffic baseline. */
static void fft_radix2(dsp_real *DSP_RESTRICT re, dsp_real *DSP_RESTRICT im, const int m,
                       const int *DSP_RESTRICT swp_a, const int *DSP_RESTRICT swp_b, const int nswp,
                       const dsp_real *DSP_RESTRICT twr, const dsp_real *DSP_RESTRICT twi) {
    int s, i, len, half, base;
    for (s = 0; s < nswp; s++) {
        const int a = swp_a[s], b = swp_b[s];
        dsp_real t = re[a];
        re[a] = re[b];
        re[b] = t;
        t = im[a];
        im[a] = im[b];
        im[b] = t;
    }

    for (i = 0; i < m; i += 2) {
        dsp_real ar = re[i], ai = im[i], br = re[i + 1], bi = im[i + 1];
        re[i] = ar + br;
        im[i] = ai + bi;
        re[i + 1] = ar - br;
        im[i + 1] = ai - bi;
    }

    base = 0;
    for (len = 4; len <= m; len *= 2) {
        half = dsp_half(len);
        for (i = 0; i < m; i += len) {
            const dsp_real *tr = twr + base, *ti = twi + base;
            dsp_real *ar = re + i, *ai = im + i;
            dsp_real *br = ar + half, *bi = ai + half;
            int mm = half;
            while (mm-- > 0) {
                const dsp_real cr = *tr++, ci = *ti++;
                const dsp_real xr = *br, xi = *bi;
                const dsp_real vr = xr * cr - xi * ci;
                const dsp_real vi = xr * ci + xi * cr;
                const dsp_real ur = *ar, ui = *ai;
                *br++ = ur - vr;
                *bi++ = ui - vi;
                *ar++ = ur + vr;
                *ai++ = ui + vi;
            }
        }
        base += half;
    }
}

/* DSP_FS_BLOCK interleaved in-place radix-2 transforms of length `len`, element i of lane
 * c at s[i*DSP_FS_BLOCK + c]. The lane count is the macro rather than an argument so the
 * innermost loop unrolls: it is DSP_FS_BLOCK independent butterflies, which is what keeps
 * the three-stage FPU pipeline fed, and a runtime bound there left the compiler nothing to
 * work with. */
static void fft_block(dsp_real *DSP_RESTRICT sr, dsp_real *DSP_RESTRICT si, const int len,
                      const int *DSP_RESTRICT swa, const int *DSP_RESTRICT swb, const int nsw,
                      const dsp_real *DSP_RESTRICT twr, const dsp_real *DSP_RESTRICT twi) {
    int s, i, j, c, l2, half, base;
    for (s = 0; s < nsw; s++) {
        dsp_real *ar = sr + (size_t)swa[s] * DSP_FS_BLOCK;
        dsp_real *br = sr + (size_t)swb[s] * DSP_FS_BLOCK;
        dsp_real *ai = si + (size_t)swa[s] * DSP_FS_BLOCK;
        dsp_real *bi = si + (size_t)swb[s] * DSP_FS_BLOCK;
        for (c = 0; c < DSP_FS_BLOCK; c++) {
            dsp_real t = ar[c];
            ar[c] = br[c];
            br[c] = t;
            t = ai[c];
            ai[c] = bi[c];
            bi[c] = t;
        }
    }

    for (i = 0; i < len; i += 2) {
        dsp_real *ar = sr + (size_t)i * DSP_FS_BLOCK, *br = ar + DSP_FS_BLOCK;
        dsp_real *ai = si + (size_t)i * DSP_FS_BLOCK, *bi = ai + DSP_FS_BLOCK;
        for (c = 0; c < DSP_FS_BLOCK; c++) {
            dsp_real ur = ar[c], vr = br[c], ui = ai[c], vi = bi[c];
            ar[c] = ur + vr;
            br[c] = ur - vr;
            ai[c] = ui + vi;
            bi[c] = ui - vi;
        }
    }

    base = 0;
    for (l2 = 4; l2 <= len; l2 *= 2) {
        half = dsp_half(l2);
        for (i = 0; i < len; i += l2) {
            for (j = 0; j < half; j++) {
                const dsp_real cr = twr[base + j], ci = twi[base + j];
                dsp_real *ar = sr + (size_t)(i + j) * DSP_FS_BLOCK;
                dsp_real *br = ar + (size_t)half * DSP_FS_BLOCK;
                dsp_real *ai = si + (size_t)(i + j) * DSP_FS_BLOCK;
                dsp_real *bi = ai + (size_t)half * DSP_FS_BLOCK;
                for (c = 0; c < DSP_FS_BLOCK; c++) {
                    const dsp_real xr = br[c], xi = bi[c];
                    dsp_real vr = xr * cr - xi * ci;
                    dsp_real vi = xr * ci + xi * cr;
                    dsp_real ur = ar[c], ui = ai[c];
                    br[c] = ur - vr;
                    bi[c] = ui - vi;
                    ar[c] = ur + vr;
                    ai[c] = ui + vi;
                }
            }
        }
        base += half;
    }
}

/* Four-step. With m = m1*m2, j = j1*m2 + j2 and k = k1 + k2*m1,
 *   X[k1 + k2 m1] = sum_j2 W_m^{j2 k1} W_m2^{j2 k2} [ sum_j1 x[j1 m2 + j2] W_m1^{j1 k1} ]
 * so the transform becomes m2 sub-transforms of length m1, a twiddle, m1 sub-transforms of
 * length m2, and a transpose. Each sub-transform is a few kB and runs entirely in cache,
 * which turns thirteen streaming passes over the data into three.
 *
 * The gather takes DSP_FS_BLOCK columns at a time so every byte of each 32-byte block it
 * fetches is used. One column at a time would read each block eight times, and the stride
 * maps the m1 streams onto four sets of an eight-way cache. */
static void fft_fourstep(dsp_plan *p) {
    const int m1 = p->m1, m2 = p->m2;
    const int h = dsp_half(p->m);
    dsp_real *DSP_RESTRICT re = p->re;
    dsp_real *DSP_RESTRICT im = p->im;
    dsp_real *DSP_RESTRICT wkr = p->wkr;
    dsp_real *DSP_RESTRICT wki = p->wki;
    dsp_real *DSP_RESTRICT blkr = p->blkr;
    dsp_real *DSP_RESTRICT blki = p->blki;
    const dsp_real *twr = p->twr, *twi = p->twi;
    int log2h = 0, twbase, jb, k1, k2, kb, t;

    for (t = h; t > 1; t = dsp_half(t))
        log2h++;
    /* W_m^idx for idx in [0,m) from the last stage's m/2 entries: the upper half is the lower
     * half negated, since W_m^{idx + m/2} = -W_m^{idx}. */
    twbase = h - 2;

    /* m2 is a power of two and at least DSP_FS_BLOCK for every m above DSP_FS_MIN, so every
     * block is full and the loops below need no partial case. */
    for (jb = 0; jb < m2; jb += DSP_FS_BLOCK) {
        int j1, c;

        for (j1 = 0; j1 < m1; j1++) {
            const dsp_real *gr = re + (size_t)j1 * (size_t)m2 + (size_t)jb;
            const dsp_real *gi = im + (size_t)j1 * (size_t)m2 + (size_t)jb;
            dsp_real *dr = blkr + (size_t)j1 * DSP_FS_BLOCK;
            dsp_real *di = blki + (size_t)j1 * DSP_FS_BLOCK;
            for (c = 0; c < DSP_FS_BLOCK; c++) {
                dr[c] = gr[c];
                di[c] = gi[c];
            }
        }

        fft_block(blkr, blki, m1, p->sw1_a, p->sw1_b, p->nsw1, twr, twi);
        /* One gather, one block of sub-transforms, one twiddle-and-scatter: the longest
         * stretch the caller waits through. */
        dsp_do_yield(p);

        /* Twiddle by W_m^{j2 k1} and scatter so the next pass reads each row contiguously. The
         * index advances by k1 a column, so it is an add rather than the multiply the algebra
         * writes. */
        for (k1 = 0; k1 < m1; k1++) {
            const dsp_real *ar = blkr + (size_t)k1 * DSP_FS_BLOCK;
            const dsp_real *ai = blki + (size_t)k1 * DSP_FS_BLOCK;
            dsp_real *o_r = wkr + (size_t)k1 * (size_t)m2 + (size_t)jb;
            dsp_real *o_i = wki + (size_t)k1 * (size_t)m2 + (size_t)jb;
            int idx = jb * k1;
            for (c = 0; c < DSP_FS_BLOCK; c++) {
                /* idx is a product of counts and never negative, so the masking and the
                 * shift are done unsigned: a signed shift past the sign bit is
                 * implementation-defined, and h is a power of two. */
                const unsigned u   = (unsigned)idx;
                const int      off = (int)(u & ((unsigned)h - 1U));
                const int      neg = (int)(u >> (unsigned)log2h);
                const dsp_real sgn = (dsp_real)(1 - 2 * neg);
                const dsp_real cr = sgn * twr[twbase + off];
                const dsp_real ci = sgn * twi[twbase + off];
                const dsp_real xr = ar[c], xi = ai[c];
                o_r[c] = xr * cr - xi * ci;
                o_i[c] = xr * ci + xi * cr;
                idx += k1;
            }
        }
    }

    /* Each row is m2 contiguous complex points, a few kB, so the whole sub-transform runs
     * without leaving the cache. The in-place kernel is reused rather than a one-lane version
     * of fft_block: a lane loop with a trip count of one is pure overhead. */
    for (k1 = 0; k1 < m1; k1++) {
        fft_radix2(wkr + (size_t)k1 * (size_t)m2, wki + (size_t)k1 * (size_t)m2, m2, p->sw2_a,
                   p->sw2_b, p->nsw2, twr, twi);
        dsp_do_yield(p);
    }

    /* X[k1 + k2 m1] = wk[k1 m2 + k2]: a transpose, blocked so each tile stays resident. */
    for (kb = 0; kb < m2; kb += DSP_FS_BLOCK) {
        int khi = kb + DSP_FS_BLOCK;
        int jbb;
        if (khi > m2)
            khi = m2;
        for (jbb = 0; jbb < m1; jbb += DSP_FS_BLOCK) {
            int jhi = jbb + DSP_FS_BLOCK;
            if (jhi > m1)
                jhi = m1;
            for (k2 = kb; k2 < khi; k2++) {
                dsp_real *o_r = re + (size_t)k2 * (size_t)m1;
                dsp_real *o_i = im + (size_t)k2 * (size_t)m1;
                for (k1 = jbb; k1 < jhi; k1++) {
                    o_r[k1] = wkr[(size_t)k1 * (size_t)m2 + (size_t)k2];
                    o_i[k1] = wki[(size_t)k1 * (size_t)m2 + (size_t)k2];
                }
            }
        }
    }
}

void dsp_rfft(dsp_plan *p) {
    int method;
    if (p == NULL || p->m < 2)
        return;
    /* Read off the arena rather than out of p->method. Now that the arena is sized for one
     * decomposition, the arrays present identify it uniquely, and a p->method overwritten by
     * hand would otherwise reach a kernel whose buffers are NULL. dsp_plan_init records the
     * same answer in p->method; this is the one that cannot be made to disagree with what
     * was allocated. */
    method = dsp_method_built(p);
    if (method == DSP_FFT_FOURSTEP)
        fft_fourstep(p);
    else
        fft_radix2(p->re, p->im, p->m, p->swp_a, p->swp_b, p->nswp, p->twr, p->twi);
}

/* ------------------------------------------------------------------------- */
/* power                                                                     */
/* ------------------------------------------------------------------------- */

void dsp_power(const dsp_real *DSP_RESTRICT re, const dsp_real *DSP_RESTRICT im, const int m,
               const dsp_real *DSP_RESTRICT utr, const dsp_real *DSP_RESTRICT uti,
               dsp_real *DSP_RESTRICT pwr, const double scale) {
    int half = dsp_half(m), j;
    /* Bin 0: X = Re Z[0] + Im Z[0], real. */
    {
        const double s = 2.0 * ((double)re[0] + (double)im[0]);
        pwr[0] = (dsp_real)(s * s * scale);
    }
    /* Bin m/2: its own mirror with twiddle -i, X = Re Z - i Im Z. Skipped at m < 2, where
     * m/2 is bin 0 and writing it again would overwrite the only bin there is with the
     * wrong formula. No plan reaches that -- dsp_plan_init refuses n below 4 -- but this is
     * published, so it answers for one bin rather than answering wrongly. */
    if (half > 0) {
        double a  = (double)re[half], b = (double)im[half];
        pwr[half] = (dsp_real)(4.0 * (a * a + b * b) * scale);
    }
    /* The untangle runs in dsp_real so the multiply-adds are the native width; only the final
     * scale is double, which keeps 1/wsum^2 exact for one multiply a bin. Mirror pairs share
     * four loads, so the pass walks inwards from both ends. */
    {
        const dsp_real *ar = re + 1, *ai = im + 1;
        const dsp_real *cr = re + m - 1, *ci = im + m - 1;
        const dsp_real *wr = utr + 1, *wi = uti + 1;
        dsp_real *lo = pwr + 1, *hi = pwr + m - 1;
        for (j = 1; j < half; j++) {
            dsp_real a  = *ar++, b = *ai++, c = *cr--, d = *ci--;
            const dsp_real s1 = a + c, s2 = b + d, d1 = a - c, d2 = b - d;
            const dsp_real u  = *wr++, v = *wi++;
            const dsp_real t1 = u * s2 + v * d1;
            const dsp_real t2 = v * s2 - u * d1;
            const dsp_real xr = s1 + t1, xi = d2 + t2;
            const dsp_real yr = s1 - t1, yi = t2 - d2;
            *lo++ = (dsp_real)(((double)xr * (double)xr + (double)xi * (double)xi) * scale);
            *hi-- = (dsp_real)(((double)yr * (double)yr + (double)yi * (double)yi) * scale);
        }
    }
}

/* ------------------------------------------------------------------------- */
/* FIR                                                                       */
/* ------------------------------------------------------------------------- */

/* Smallest passband gain a design may normalise by. The gain is near 1 for any band the
 * arguments admit, so this only catches a degenerate kernel; what it exists to stop is a
 * divisor near zero multiplying every tap by an arbitrary factor. */
#define DSP_FIR_GAIN_MIN 1e-6

/* Decimating by D folds the spectrum into D zones of fs/(2D). A band survives only inside one
 * zone: a boundary within the band folds the band onto itself, which no tap count repairs. An
 * upper edge exactly on a boundary belongs to the zone BELOW it, which is where the fold puts
 * it, so a full-span low-pass is not a straddle; the adjustment is below. */
static int dsp_zone_single(const double fs, const double flo, const double fhi, const int decim, int *zone) {
    int zlo, zhi;
    if (!(fs > 0.0) || !dsp_finite(fs) || !dsp_finite(flo) || !dsp_finite(fhi))
        return DSP_EARG;
    if (!(flo >= 0.0) || !(fhi > flo) || !(fhi <= 0.5 * fs))
        return DSP_EARG;
    if (decim < 1 || decim > DSP_DECIM_MAX)
        return DSP_EARG;
#if !DSP_BANDPASS
    if (flo != 0.0)
        return DSP_EUNSUPPORTED;
#endif
    {
        const double k = 2.0 * (double)decim / fs; /* one divide for both edges */
        const double uhi = k * fhi;
        zlo = dsp_ifloor(k * flo);
        zhi = dsp_ifloor(uhi);
        /* An upper edge exactly on a boundary belongs to the zone below it, which is where the
         * fold puts it: zone k covers [k, k+1) going up and the reflection makes it closed at
         * the top. Taking floor alone would read it as the zone above and call an ordinary
         * full-span low-pass a straddle. Written as a positive so a NaN cannot reach here. */
        if (zhi > 0 && !(uhi > (double)zhi))
            zhi--;
    }
    if (zlo != zhi)
        return DSP_EZONE;
    *zone = zlo;
    return DSP_OK;
}

int dsp_band_map(const double fs, const double flo, const double fhi, const int n, const int decim, dsp_bandmap *out) {
    double zw, bw;
    int zone = 0, rc;
    if (out == NULL)
        return DSP_EARG;
    memset(out, 0, sizeof(*out));
    if (n < 1)
        return DSP_EARG;
    rc = dsp_zone_single(fs, flo, fhi, decim, &zone);
    if (rc != DSP_OK)
        return rc;
    bw = dsp_binwidth(fs, n, decim);
    if (!(bw > 0.0) || !dsp_storable(bw))
        return DSP_EARG;
    zw = fs / (2.0 * (double)decim);
    /* An even zone arrives offset by its lower edge, ascending; an odd zone arrives reversed,
     * so bin 0 is the upper edge and frequency falls with the index. */
    out->zone  = zone;
    out->binhz = bw;
    if (!dsp_is_odd(zone)) {
        out->sense = 1;
        out->f0    = (double)zone * zw;
    } else {
        out->sense = -1;
        out->f0    = (double)(zone + 1) * zw;
    }
    if (!dsp_storable(out->f0)) {
        memset(out, 0, sizeof(*out));
        return DSP_EARG;
    }
    return DSP_OK;
}

double dsp_bin_hz(const dsp_bandmap *m, const int k) {
    if (m == NULL)
        return 0.0;
    return m->f0 + (double)m->sense * (double)k * m->binhz;
}

int dsp_band_bins(const dsp_bandmap *m, const double flo, const double fhi, const int nbins, int *k0_out,
                  int *k1_out) {
    double lo, hi;
    int k0, k1;
    /* Zeroed before every refusal that can be, which is the convention dsp_band_map and
     * dsp_thd_noise follow: a caller that ignores the code then reads bin 0 twice rather
     * than whatever it happened to pass in. */
    if (k0_out == NULL || k1_out == NULL)
        return DSP_EARG;
    *k0_out = 0;
    *k1_out = 0;
#if DSP_CHECK_OVERLAP
    /* One object for both edges is refused rather than left undefined: the window would
     * otherwise come back as k1 twice, which reads as a legal one-bin span. Equality is the
     * whole of overlap for two single ints, so this needs no extents. */
    if (k0_out == k1_out)
        return DSP_EARG;
#endif
    if (m == NULL)
        return DSP_EARG;
    if (nbins < 1 || !(m->binhz > 0.0) || !(fhi > flo))
        return DSP_EARG;
    if (!dsp_storable(flo) || !dsp_storable(fhi))
        return DSP_EARG;
    /* Indices of the two edges. An odd zone arrives reversed, so the HIGH frequency is the
     * low index: the edges swap but the ceil/floor do not, both following their own edge. */
    /* Divided, not scaled by a reciprocal. Both quotients go straight into ceil() and
     * floor(), so an edge that lands on an integer -- which the shipped spans do, binhz
     * dividing flo exactly -- turns one ulp into one whole bin. Measured: scaling here put
     * k0 at 4 where the divide gives 5. */
    if (m->sense >= 0) {
        lo = (flo - m->f0) / m->binhz;
        hi = (fhi - m->f0) / m->binhz;
    } else {
        lo = (m->f0 - fhi) / m->binhz;
        hi = (m->f0 - flo) / m->binhz;
    }
    /* Both edges are rounded inward, which is what makes the window the bins whose centre
     * frequency lies inside it. Rounding the low edge down would pull in the bin below --
     * at zone 0 that is DC, and a start under one bin width would report the mean as a
     * tone. */
    lo = ceil(lo);
    hi = floor(hi);
    /* Outside anything storable the clamps below are the answer, and converting first is
     * undefined where it does not fit an int. */
    if (!(lo > -1.0e9))
        lo = -1.0e9;
    if (!(hi < 1.0e9))
        hi = 1.0e9;
    k0 = (int)lo;
    k1 = (int)hi;
    if (k0 < 0)
        k0 = 0;
    if (k0 > nbins - 1)
        k0 = nbins - 1;
    if (k1 > nbins - 1)
        k1 = nbins - 1;
    /* Never empty: one bin is what a span narrower than a bin can honestly report, and the
     * callers that take k0..k1 all read at least one. */
    if (k1 < k0)
        k1 = k0;
    *k0_out = k0;
    *k1_out = k1;
    return DSP_OK;
}

double dsp_fir_transition(const double fs, const double flo, const double fhi, const int decim) {
    double zw, ghi, glo, inv_fs;
    int zone = 0;
    /* Zero means no usable transition: a refusal, a straddle and a band on a zone edge all
     * read the same, and every caller treats them the same. */
    if (dsp_zone_single(fs, flo, fhi, decim, &zone) != DSP_OK)
        return 0.0;
    zw = fs / (2.0 * (double)decim);
    inv_fs = 1.0 / fs;
    ghi = ((double)(zone + 1) * zw - fhi) * inv_fs;
    /* Nothing folds across DC, so zone 0 has no lower transition to keep; with flo of 0 that
     * is the low-pass case, where ghi is 1/(2*decim) - fhi/fs. */
    if (zone == 0)
        return ghi;
    glo = (flo - (double)zone * zw) * inv_fs;
    return (glo < ghi) ? glo : ghi;
}

int dsp_fir_taps_for(const double fs, const double flo, const double fhi, const int decim, const int maxtaps) {
    const double wtr = dsp_fir_transition(fs, flo, fhi, decim);
    int l;
    if (maxtaps < 3)
        return 0;
    if (!(wtr > 0.0))
        return 0;
    /* Bounded in double before the truncation. A stop frequency just under the decimated
     * Nyquist leaves a transition of order 1e-15, and the quotient is then 3.3e15, which no
     * ceiling admits and which is undefined to convert to int in the first place. */
    {
        /* One divide, tested and then used. */
        const double want = DSP_FIR_TAPK / wtr;
        if (!(want <= (double)maxtaps))
            return 0;
        l = dsp_iceil(want);
    }
    if (!dsp_is_odd(l))
        l++;
    if (l > maxtaps)
        return 0;
    if (l < 3)
        l = 3;
    return l;
}

int dsp_fir_pick_decim(const double fs, const double flo, const double fhi, const int n, const int maxtaps) {
    int dmax, d, zone = 0;
    if (!(fs > 0.0) || !(fhi > 0.0) || n < 2 || maxtaps < 3)
        return 1;
    dmax = dsp_ifloor((double)(DSP_FIR_MAXM - maxtaps) / (double)(n - 1));
    if (dmax > DSP_DECIM_MAX)
        dmax = DSP_DECIM_MAX;
    /* Downward from the read budget's ceiling, taking the first decimation that holds the
     * band in one zone with a realisable filter. A decimation derived from fhi alone cannot
     * express the zone condition, which depends on where the band sits. Plan time only,
     * bounded by DSP_DECIM_MAX. */
    for (d = dmax; d > 1; d--) {
        if (dsp_zone_single(fs, flo, fhi, d, &zone) != DSP_OK)
            continue;
        if (dsp_fir_taps_for(fs, flo, fhi, d, maxtaps) == 0)
            continue;
        return d;
    }
    return 1;
}

const char *dsp_strerror(const int code) {
    switch (code) {
    case DSP_OK:
        return "ok";
    case DSP_EARG:
        return "bad argument";
    case DSP_EPOW2:
        return "samples not a power of two";
    case DSP_ENOMEM:
        return "arena too small";
    case DSP_EUNSUPPORTED:
        return "setting not supported";
    case DSP_ESHORT:
        return "capture too short";
    case DSP_EBETA:
        return "beta out of range";
    case DSP_EDECLINE:
        return "no sub-bin estimate";
    case DSP_EALIGN:
        return "arena misaligned";
    case DSP_EZONE:
        return "band spans a Nyquist zone";
    case DSP_ESEG:
        return "array larger than one segment";
    case DSP_EDIRTY:
        return "settings moved, commit again";
    default:
        return "unknown error";
    }
}

int dsp_fir_srclength(const int n, const int decim, const int ntaps) {
    if (n < 2 || decim < 1 || ntaps < 0 || ntaps > DSP_FIR_MAXTAPS)
        return 0;
    if (decim < 2)
        return n;
    /* Divide the bound rather than form the product: `(n-1)*decim` overflows int for
     * arguments nothing else refuses, and `long long` would pull in a 64-bit division, which
     * on a 32-bit target is a compiler runtime call (__divdi3) nothing else here needs. */
    if (decim > (DSP_SRC_MAX - ntaps) / (n - 1))
        return 0;
    return (n - 1) * decim + ntaps;
}

double dsp_binwidth(const double fs, const int n, const int decim) {
    /* A rate that is not positive and finite has no bin width, and 0 is what this reports for
     * arguments it refuses. dsp_reduce then refuses the 0 rather than plotting against a
     * negative or infinite frequency axis. */
    if (n < 1 || decim < 1 || !(fs > 0.0) || !dsp_finite(fs))
        return 0.0;
    return fs / ((double)decim * (double)n);
}

int dsp_fir_design(dsp_real *DSP_RESTRICT h, const int maxtaps, const double fs, const double flo, const double fhi,
                   const int decim, const int order) {
    double fc_hi, fc_lo, zw, c, divisor, inv_fs;
    int l, i, zone = 0, rc;
    if (h == NULL || maxtaps < 3)
        return DSP_EARG;
    if (!(fs > 0.0) || !(fhi > 0.0) || decim < 1)
        return DSP_EARG;
    /* A low-pass at decim 1 is a no-op: the record goes through untouched. A band-pass at
     * decim 1 is a real filter, because there the selectivity is the point and not the
     * anti-aliasing. */
    if (decim < 2 && flo == 0.0)
        return 0;
    /* Validates the rates, refuses a band that spans a zone boundary, and in a low-pass build
     * refuses a non-zero flo. */
    rc = dsp_zone_single(fs, flo, fhi, decim, &zone);
    if (rc != DSP_OK)
        return rc;
    inv_fs = 1.0 / fs; /* every frequency below is a fraction of fs */

    if (order > 0) {
        l = order;
        /* Odd, so the group delay is a whole sample. Up by one, except at the ceiling, where
         * up by one would be refused: order == maxtaps is the ordinary way to ask for the
         * longest filter the buffer holds, and rounding it up rejected it. */
        if (!dsp_is_odd(l))
            l = (l < maxtaps) ? l + 1 : l - 1;
    } else {
        /* A transition needing more than the caller's buffer gets the ceiling, which is the
         * Lua's behaviour: too few taps for the transition, but the best the budget allows. */
        l = dsp_fir_taps_for(fs, flo, fhi, decim, maxtaps);
        if (l == 0)
            l = maxtaps;
        if (!dsp_is_odd(l))
            l--;
    }
    if (l < 3)
        l = 3;
    if (l > maxtaps)
        return DSP_EARG;

    /* Each cutoff half a transition outside its band edge, so the edge sits in the flat part
     * and not in the roll-off: a cutoff on the edge reads 3.5 dB low at 16.6 kHz of a 20 kHz
     * span, measured on the instrument. The transition is the one the tap count delivers,
     * bounded by the room the zone leaves. For a derived count the two coincide and this is
     * half-way to the zone edge, where a low-pass cutoff sits; a forced longer filter hugs the
     * band edge instead of widening the passband to a zone edge that may be far away. */
    zw = 0.5 / (double)decim; /* zone width, in cycles a sample */
    {
        const double tw  = DSP_FIR_TAPK / (double)l;
        const double ghi = (double)(zone + 1) * zw - fhi * inv_fs;
        const double glo = flo * inv_fs - (double)zone * zw;
        const double phi = 0.5 * ((ghi < tw) ? ghi : tw);
        const double plo = 0.5 * ((glo < tw) ? glo : tw);
        fc_hi = fhi * inv_fs + ((phi > 0.0) ? phi : 0.0);
        fc_lo = flo * inv_fs - ((plo > 0.0) ? plo : 0.0);
    }
    if (fc_hi > 0.5)
        fc_hi = 0.5;
    if (fc_lo < 0.0)
        fc_lo = 0.0;
    if (!(fc_hi > fc_lo))
        return DSP_EARG;

    /* A difference of sincs: at fc_lo zero the lower term vanishes, giving the low-pass. */
    c = (double)(l - 1) * 0.5;
    {
        /* The window's 1/(l-1) is hoisted: one divide, not one a tap. */
        const double wstep = 2.0 * M_PI / (double)(l - 1);
        const double whi = 2.0 * M_PI * fc_hi, wlo = 2.0 * M_PI * fc_lo;
        /* One exact double i serves the sinc's offset and the window's angle, so neither
         * converts and the tap loop holds no int-to-double at all. */
        double di;
        for (i = 0, di = 0.0; i < l; i++, di += 1.0) {
            const double mm = di - c;
            double v;
            if (mm == 0.0)
                v = 2.0 * (fc_hi - fc_lo);
            else
                v = (DSP_SIN(whi * mm) - DSP_SIN(wlo * mm)) * INV_M_PI / mm;
            /* Hamming, which holds the first sidelobe near -43 dB at a tap count this small. */
            v *= 0.54 - 0.46 * DSP_COS(wstep * di);
            h[i] = (dsp_real)v;
        }
    }

    if (flo == 0.0) {
        /* DC is in the passband, so its gain is the passband gain: the sum of the taps. Unit
         * DC gain keeps the filter from changing a reading's amplitude. */
        double sum = 0.0;
        for (i = 0; i < l; i++)
            sum += (double)h[i];
        divisor = sum;
    } else {
#if DSP_BANDPASS
        /* DC is a stopband here, so its gain nears zero with a data-dependent sign and
         * dividing by it is unbounded. Unit gain is taken at the passband centre, where a
         * symmetric kernel responds h[c] + 2*sum_{i<c} h[i]*cos(w0*(c-i)). */
        const double w0 = M_PI * (flo + fhi) * inv_fs;
        const int    ci = dsp_half(l - 1);
        double g  = (double)h[ci];
        /* dci counts ci - i down exactly, so the distance from the centre is never
         * converted. */
        double dci;
        for (i = 0, dci = (double)ci; i < ci; i++, dci -= 1.0)
            g += 2.0 * (double)h[i] * DSP_COS(w0 * dci);
        divisor = g;
#else
        return DSP_EUNSUPPORTED;
#endif
    }
    /* Positive, not just non-zero: the centre response is positive for any band admitted
     * here, and a negative divisor would invert every tap. */
    if (!(divisor > DSP_FIR_GAIN_MIN))
        return DSP_EARG;
    {
        const double inv = 1.0 / divisor; /* one divide, not one a tap */
        for (i = 0; i < l; i++)
            h[i] = (dsp_real)((double)h[i] * inv);
    }
    return l;
}

int dsp_fir_run(const double *DSP_RESTRICT x, const int nx, const dsp_real *DSP_RESTRICT h, const int ntaps,
                const int decim, double *DSP_RESTRICT y) {
    int ny, j, t;
    if (x == NULL || h == NULL || y == NULL)
        return DSP_EARG;
    if (ntaps < 1 || decim < 1 || nx < ntaps)
        return DSP_EARG;
    ny = (nx - ntaps) / decim + 1;
#if DSP_CHECK_OVERLAP
    /* The output against both inputs, by extent and not just by base: output j reads inputs
     * j*decim through j*decim+ntaps-1, so a y starting anywhere inside x destroys readings
     * the later outputs still need. In place is the case a caller reaches for first. */
    if (dsp_overlaps(y, (size_t)ny * sizeof(*y), x, (size_t)nx * sizeof(*x))
        || dsp_overlaps(y, (size_t)ny * sizeof(*y), h, (size_t)ntaps * sizeof(*h)))
        return DSP_EARG;
#endif
    /* Four chains, because one would stall the three-stage pipeline every third instruction.
     * The accumulation stays in double: the source is the instrument's double readings and
     * the output feeds the same loader as an unfiltered capture. csrc/README.md records what
     * a single-precision chain would buy on the target and why it is not taken here. */
    for (j = 0; j < ny; j++) {
        const double *xp = x + (size_t)j * (size_t)decim;
        const dsp_real *hp = h;
        double a0 = 0.0, a1 = 0.0, a2 = 0.0, a3 = 0.0;
        for (t = 0; t + 3 < ntaps; t += 4) {
            a0 = a0 + xp[0] * (double)hp[0];
            a1 = a1 + xp[1] * (double)hp[1];
            a2 = a2 + xp[2] * (double)hp[2];
            a3 = a3 + xp[3] * (double)hp[3];
            xp += 4;
            hp += 4;
        }
        for (; t < ntaps; t++) {
            a0 = a0 + *xp * (double)*hp;
            xp++;
            hp++;
        }
        y[j] = (a0 + a2) + (a1 + a3);
    }
    return ny;
}

/* ------------------------------------------------------------------------- */
/* reduction and peak search                                                 */
/* ------------------------------------------------------------------------- */

int dsp_reduce(const dsp_real *DSP_RESTRICT pwr, const int nbins, const int k0, int k1, const int nseg,
               const dsp_bandmap *map, const double dbmin, const double dbmax, const double vfloor,
               dsp_real *DSP_RESTRICT db, dsp_real *DSP_RESTRICT hz) {
    double vfl = vfloor * vfloor; /* squared: the bins are power */
    double fstep, f0, binhz, dc;
    int npts, c, qstep, rstep, q0, q1, r1;
    if (pwr == NULL || db == NULL || hz == NULL || map == NULL)
        return DSP_EARG;
    if (nbins < 1 || k0 < 0 || k0 >= nbins || nseg < 1 || nseg > DSP_NSEG_MAX)
        return DSP_EARG;
#if DSP_CHECK_OVERLAP
    /* The two traces against each other and against the bins they are reduced from. Both are
     * nseg long and written point by point, so sharing bytes with pwr would have a segment
     * reduce bins an earlier segment had already overwritten. */
    if (dsp_overlaps(db, (size_t)nseg * sizeof(*db), hz, (size_t)nseg * sizeof(*hz))
        || dsp_overlaps(db, (size_t)nseg * sizeof(*db), pwr, (size_t)nbins * sizeof(*pwr))
        || dsp_overlaps(hz, (size_t)nseg * sizeof(*hz), pwr, (size_t)nbins * sizeof(*pwr)))
        return DSP_EARG;
#endif
    /* k1 clamped rather than refused, which is what dsp_peaks does over the same array: a
     * caller passing the bin count instead of the last index is the ordinary off-by-one, and
     * this runs every frame. nbins is the only thing that bounds it. */
    if (k1 > nbins - 1)
        k1 = nbins - 1;
    if (k1 < k0)
        return DSP_EARG;
    binhz = map->binhz;
    /* No usable frequency scale yet, which is the state before the first plan. */
    if (!(binhz > 0.0) || !dsp_finite(binhz) || !dsp_finite(map->f0))
        return DSP_EARG;
    if (map->sense != 1 && map->sense != -1)
        return DSP_EARG;
    /* The dB window. Every segment that does not clear the floor is written as dbmin and
     * every one over the ceiling as dbmax, so a limit that is not storable is a trace that is
     * not storable whatever the bins hold, and an inverted window describes no segment. */
    if (!dsp_storable(dbmin) || !dsp_storable(dbmax) || !(dbmin < dbmax))
        return DSP_EARG;
    /* Squared below, so a negative floor would silently become a positive one. */
    if (!dsp_finite(vfloor) || !(vfloor >= 0.0))
        return DSP_EARG;
    npts = k1 - k0 + 1;
    /* Hoisted: the step is one divide for the whole trace instead of one a point, leaving a
     * multiply and an add per point. Not accumulated -- c * fstep is formed each time, so
     * the rounding does not walk along the axis. The series starts at whichever end of the
     * window is the lowest frequency -- k0 ascending, k1 descending -- and climbs from
     * there. That one substitution is the whole reversal, because sense*sense is 1. */
    f0 = dsp_bin_hz(map, (map->sense > 0) ? k0 : k1);
    fstep = ((double)npts / (double)nseg) * binhz;
    /* The frequencies are an affine series in binhz, so a width that is finite but large
     * enough to overflow the series puts an infinity in hz -- or, at segment 0 where the
     * multiplier is zero, the product 0 * inf, which is a NaN. The endpoints bound every
     * value between them, and fstep is checked for the ones that are not endpoints. */
    if (!dsp_storable(f0) || !dsp_storable(fstep) ||
        !dsp_storable(f0 + (double)(nseg - 1) * fstep))
        return DSP_EARG;

    /* Segmentation by addition, not `c * npts / nseg`: that product needs more than 32 bits
     * at the argument limits, and widening it pulls in a 64-bit division. Carrying the
     * quotient and remainder gives the same floor exactly, in int, with no division in the
     * loop. q0 is segment c's first offset, q1 segment c+1's, so q1-1 is this one's last. */
    qstep = npts / nseg;
    rstep = npts % nseg;
    q0 = 0;
    q1 = qstep;
    r1 = rstep;

    /* dc holds c exactly, so the product below is the one a conversion would have given and
     * the segment loop converts nothing. */
    for (c = 0, dc = 0.0; c < nseg; c++, dc += 1.0) {
        /* Offsets, then bins. Descending maps offset o to bin k1 - o, mirroring the range
         * while the frequency still rises with c. */
        int oa = q0, ob = q1 - 1;
        int a, b;
        const dsp_real *qp;
        dsp_real top;
        double d;
        int run;
        if (ob < oa)
            ob = oa;
        if (ob > npts - 1)
            ob = npts - 1;
        if (map->sense > 0) {
            a = k0 + oa;
            b = k0 + ob;
        } else {
            a = k1 - ob;
            b = k1 - oa;
        }
        /* A ternary rather than an if with a branch body, so a floating select can take it.
         * A NaN loses the comparison either way, so every NaN bin is dropped and the
         * segment reports the largest bin that is not one. Seeded below the floor rather
         * than from the first bin: seeding from it made a NaN THERE stick, since nothing
         * compares greater than a NaN, and one bin then suppressed a whole segment -- 32
         * bins at 16,384 samples, hiding a tone 4 bins away. Power is never negative, so
         * -1 cannot win against a real bin, and an all-NaN segment keeps it and plots at
         * the floor. */
        qp = pwr + a;
        top = (dsp_real)-1;
        for (run = b - a + 1; run > 0; run--) {
            const dsp_real v = *qp++;
            top = (v > top) ? v : top;
        }
        /* Anything at or below the floor plots at the floor, so the logarithm never sees zero.
         * The range tests are positives because every comparison with a NaN is false: written
         * the other way round a NaN would pass straight through to the trace buffer. */
        d = dbmin;
        if ((double)top > vfl) {
            d = 10.0 * DSP_LOG10((double)top);
            if (!(d > dbmin))
                d = dbmin;
            else if (!(d < dbmax))
                d = dbmax;
        }
        db[c] = (dsp_real)d;
        hz[c] = (dsp_real)(f0 + dc * fstep);

        /* Advance both offsets by npts/nseg, carrying the remainder. */
        q0 = q1;
        q1 += qstep;
        r1 += rstep;
        if (r1 >= nseg) {
            r1 -= nseg;
            q1++;
        }
    }
    return nseg;
}

int dsp_peaks(const dsp_real *DSP_RESTRICT pwr, const int nbins, int k0, int k1, int kdc, const int want,
              const dsp_interp *ip, int *DSP_RESTRICT bin, dsp_real *DSP_RESTRICT frac,
              dsp_real *DSP_RESTRICT amp) {
    int kfloor, k, s, found = 0;
    double bv[DSP_PEAKS_MAX];
    if (pwr == NULL || bin == NULL || want < 1)
        return DSP_EARG;
    if (want > DSP_PEAKS_MAX)
        return DSP_EARG;
    /* nbins first, as dsp_reduce does over the same array: without it `nbins - 1` below
     * overflows at INT_MIN, and the kdc clamp has nothing to bound it with. */
    if (nbins < 1)
        return DSP_EARG;
#if DSP_CHECK_OVERLAP
    /* The three result arrays against each other and against the bins. bin is seeded before
     * the search and frac and amp are filled after it, so an overlap would have the seed
     * wipe a result or a result wipe the bins still being searched. frac and amp are
     * optional, and dsp_overlaps answers 0 for a NULL side. */
    {
        const size_t zb = (size_t)want * sizeof(*bin);
        const size_t zf = (size_t)want * sizeof(*frac);
        const size_t zp = (size_t)nbins * sizeof(*pwr);
        if (dsp_overlaps(bin, zb, frac, zf) || dsp_overlaps(bin, zb, amp, zf)
            || dsp_overlaps(frac, zf, amp, zf) || dsp_overlaps(bin, zb, pwr, zp)
            || dsp_overlaps(frac, zf, pwr, zp) || dsp_overlaps(amp, zf, pwr, zp))
            return DSP_EARG;
    }
#endif

    for (s = 0; s < want; s++) {
        bin[s] = -1;
        bv[s] = -1.0;
    }
    /* Clamped, not trusted: kdc is reachable in the struct, and `1 + kdc` overflows at
     * INT_MAX. Inside the array it can only narrow the search. */
    if (kdc < 0)
        kdc = 0;
    if (kdc > nbins - 1)
        kdc = nbins - 1;
    kfloor = 1 + kdc;
    if (k0 < kfloor)
        k0 = kfloor;
    if (k1 > nbins - 1)
        k1 = nbins - 1;

    for (k = k0; k <= k1; k++) {
        double v = (double)pwr[k];
        /* A missing neighbour is the end of the spectrum and counts as lower. Inside a zoom
         * window the neighbours are real bins even when off-screen, so the flank of an
         * out-of-window tone does not read as a peak. Branching comparisons on purpose: a NaN
         * fails both, which keeps a NaN bin and its neighbours out of the table, and a
         * floating select would have to reproduce that by hand. */
        const double vl = (k > 0) ? (double)pwr[k - 1] : -1.0;
        const double vr = (k + 1 < nbins) ? (double)pwr[k + 1] : -1.0;
        if (!(v > vl) || !(v >= vr))
            continue;
        if (k == kfloor && ip != NULL) {
            /* A tone inside the DC region leaks enough into the first reportable bin to make it a
             * local maximum, which then reports the tone a whole bin and 16 dB out. The estimator
             * saturates at -0.5 there, so a peak estimating a quarter bin or more below the lowest
             * reportable bin is refused. */
            double d = 0.0;
            if (dsp_peak_interp(ip, pwr, k, nbins, &d, NULL) != DSP_OK)
                d = 0.0;
            if ((double)k + d < (double)kfloor - 0.25)
                continue;
        }
        if (v > bv[want - 1]) {
            s = want - 1;
            while (s > 0 && v > bv[s - 1]) {
                bv[s] = bv[s - 1];
                bin[s] = bin[s - 1];
                s--;
            }
            bv[s] = v;
            bin[s] = k;
        }
    }

    for (s = 0; s < want; s++) {
        if (bin[s] < 0)
            break;
        found++;
        if (frac != NULL || amp != NULL) {
            double d = 0.0, v;
            if (ip != NULL && dsp_peak_interp(ip, pwr, bin[s], nbins, &d, &v) == DSP_OK) {
                if (frac != NULL)
                    frac[s] = (dsp_real)d;
                if (amp != NULL)
                    amp[s] = (dsp_real)v;
            } else {
                const double pk = (double)pwr[bin[s]];
                if (frac != NULL)
                    frac[s] = (dsp_real)0;
                if (amp != NULL)
                    amp[s] = (dsp_real)(pk > 0.0 ? DSP_SQRT(pk) : 0.0);
            }
        }
    }
    for (s = found; s < want; s++) {
        if (frac != NULL)
            frac[s] = (dsp_real)0;
        if (amp != NULL)
            amp[s] = (dsp_real)0;
    }
    return found;
}

/* ------------------------------------------------------------------------- */
/* one frame                                                                 */
/* ------------------------------------------------------------------------- */

int dsp_spectrum_run(dsp_plan *p, const double *DSP_RESTRICT src, const int nsrc, double *mean_out) {
    const double *load_from;
    int need, rc;
    if (p == NULL || src == NULL)
        return DSP_EARG;
    if (p->n < 4)
        return DSP_EARG;
    /* ntaps is reachable in the struct, so it is checked here rather than trusted: h holds
     * DSP_FIR_MAXTAPS entries and is last in the layout at decim == 1, so a larger count
     * reads outside the arena entirely. dsp_plan_set_fir refuses the same range. */
    if (p->ntaps < 0 || p->ntaps > DSP_FIR_MAXTAPS)
        return DSP_EARG;
    /* A decimating plan with no filter is refused, not run unfiltered: dsp_binwidth reports
     * the decimated width either way, so an unfiltered run would put every frequency out by
     * the decimation factor with nothing in the return value to say so. */
    if (p->decim > 1 && (p->ntaps == 0 || p->fir_out == NULL))
        return DSP_EARG;
    need = dsp_fir_srclength(p->n, p->decim, p->ntaps);
    /* 0 is dsp_fir_srclength refusing the configuration, and `nsrc < 0` would not catch it. */
    if (need <= 0)
        return DSP_EARG;
    if (nsrc < need)
        return DSP_ESHORT;

    if (p->decim > 1) {
        /* `need`, not nsrc: a longer capture produces outputs nothing reads, and fir_out holds
         * exactly p->n of them. */
        const int ny = dsp_fir_run(src, need, p->h, p->ntaps, p->decim, p->fir_out);
        if (ny < p->n)
            return (ny < 0) ? ny : DSP_ESHORT;
        load_from = p->fir_out;
        /* The filter is the longest single stretch in a decimating frame: 384 taps over
         * 16,384 outputs is 6.3 M multiply-accumulates. */
        dsp_do_yield(p);
    } else {
        load_from = src;
    }
    rc = dsp_load(load_from, p->n, p->w, p->wsum, p->re, p->im, mean_out);
    if (rc != DSP_OK)
        return rc;
    dsp_do_yield(p);
    dsp_rfft(p);
    dsp_do_yield(p);
    dsp_power(p->re, p->im, p->m, p->utr, p->uti, p->pwr, p->ksq);
    return p->m;
}

/* ------------------------------------------------------------------------- */

/* The amplitude of the line at bin k, interpolated where the tables allow it: a bin
 * maximum alone reads up to 3.9 dB low on a tone sitting between bins. */
static double dsp_line_amp(const dsp_interp *ip, const dsp_real *DSP_RESTRICT pwr, const int k,
                           const int nbins, const double p, double *d_out) {
    double amp = DSP_SQRT(p);
    if (d_out != NULL)
        *d_out = 0.0;
    if (ip != NULL) {
        double d = 0.0, a = 0.0;
        if (dsp_peak_interp(ip, pwr, k, nbins, &d, &a) == DSP_OK && a > 0.0) {
            amp = a;
            if (d_out != NULL)
                *d_out = d;
        }
    }
    return amp;
}

/* Sum and count the bins that are neither a line nor a skirt and do not exceed ceil_v.
 * The line list is ascending, so it is walked alongside the bins: one comparison a bin,
 * not one a line a bin. */
static void dsp_noise_pass(const dsp_real *DSP_RESTRICT pwr, const int k0, const int k1,
                           const int *DSP_RESTRICT line, const int nline, const int skirt, const double ceil_v,
                           const int stride, double *DSP_RESTRICT sum_out,
                           int *DSP_RESTRICT cnt_out) {
    double sum = 0.0;
    int cnt = 0, e = 0, k;
    for (k = k0; k <= k1; k += stride) {
        double v;
        while (e < nline && line[e] + skirt < k)
            e++;
        if (e < nline && k >= line[e] - skirt)
            continue;
        v = (double)pwr[k];
        /* Positive tests, so a NaN bin is skipped instead of poisoning the sum. */
        if (!(v >= 0.0) || !(v <= ceil_v))
            continue;
        sum += v;
        cnt++;
    }
    *sum_out = sum;
    *cnt_out = cnt;
}

/* Is this candidate mains pickup rather than the signal? Level first: it is the cheap test
 * and the common answer. Called only where a candidate beats the running maximum, which is
 * a handful of times over a spectrum rather than once a bin. */
static int dsp_is_mains(const double fhz, const double p, const double binhz, const int mains) {
    double tol = binhz;
    int i;
    if (mains == 0 || !(binhz > 0.0) || !(p <= DSP_THD_MAINS_PWR)
        || !(fhz < DSP_THD_MAINS_FMAX))
        return 0;
    if (!(tol > 2.0))
        tol = 2.0;
    for (i = 0; i < 2; i++) {
        const int fi = (i == 0) ? DSP_THD_MAINS_A : DSP_THD_MAINS_B;
        const double f = (double)fi;
        double n, d;
        /* One frequency or both. Selecting one gives back every multiple of the other:
         * at 50 Hz the rule covers 50 to 950, which is most of the band under
         * DSP_THD_MAINS_FMAX. Compared as ints, so no float compares an equality. */
        if (mains != DSP_THD_MAINS_BOTH && mains != fi)
            continue;
        n = floor(fhz / f + 0.5);
        if (!(n >= 1.0))
            continue;
        d = fhz - n * f;
        if (d < 0.0)
            d = -d;
        if (d <= tol)
            return 1;
    }
    return 0;
}

int dsp_thd_noise(const dsp_real *DSP_RESTRICT pwr, const int nbins, int k0, int k1, int kdc,
                  const double binhz, const int mains, const dsp_interp *ip,
                  dsp_thdn *DSP_RESTRICT out) {
    int line[DSP_THD_HMAX + 1];
    int nline, kfloor, k, h, kf = -1, cnt = 0, skirt, nh = 0, stride;
    double pf = 0.0, vf, d0 = 0.0, fb = 0.0, hsum = 0.0, sum = 0.0;

    if (pwr == NULL || out == NULL)
        return DSP_EARG;
    /* Before every refusal below, so that `out` is zeroed on all of them and not only on
     * the late ones. A caller that reads the struct after an EARG sees zeros, never the
     * previous frame's figures. */
    memset(out, 0, sizeof(*out));
#if DSP_CHECK_OVERLAP
    /* The figures against the bins they are taken from: the zeroing above would otherwise
     * blank part of the spectrum before it is read. */
    if (dsp_overlaps(out, sizeof(*out), pwr, (size_t)nbins * sizeof(*pwr)))
        return DSP_EARG;
#endif
    if (nbins < 8)
        return DSP_EARG;
    /* Refused rather than ignored: a frequency that is neither mains would discount a band
     * nothing picks up, and the caller would see plausible figures over a hole. */
    if (mains != DSP_THD_MAINS_BOTH && mains != 0 && mains != DSP_THD_MAINS_A
        && mains != DSP_THD_MAINS_B)
        return DSP_EARG;
    /* Clamped for the same reason as in dsp_peaks: `1 + kdc` overflows at INT_MAX. */
    if (kdc < 0)
        kdc = 0;
    if (kdc > nbins - 1)
        kdc = nbins - 1;
    kfloor = 1 + kdc;
    if (k0 < kfloor)
        k0 = kfloor;
    if (k1 > nbins - 1)
        k1 = nbins - 1;
    if (k1 - k0 < 4)
        return DSP_EARG;
    /* Inside the window's main lobe the bins hold signal, not noise, so the skirt follows
     * the window rather than a constant: a fixed three capped S/N at 38.5 dB on Kaiser 18
     * against the 102 dB the window allows. One bin of guard past the null. */
    skirt = (ip != NULL && ip->lobe > 0) ? ip->lobe + 1 : DSP_THD_SKIRT;

    /* The fundamental, which must be a LOCAL MAXIMUM. Otherwise the shoulder of a louder
     * line qualifies: measured on the instrument with its inputs floating, the 60 Hz line
     * was discounted as mains but the bin one along -- its own skirt, 8 dB down and a hertz
     * outside the mains tolerance -- became the fundamental and reported 21.4% distortion
     * on no signal. A monotonic skirt has no local maximum; a real tone is one.
     *
     * Comparisons written as positives, so a NaN bin can never win and neither can its
     * neighbours. A missing neighbour is the end of the spectrum and counts as lower. */
    for (k = k0; k <= k1; k++) {
        const double v = (double)pwr[k];
        double l, r;
        if (!(v > pf))
            continue;
        l = (k > 0) ? (double)pwr[k - 1] : -1.0;
        r = (k + 1 < nbins) ? (double)pwr[k + 1] : -1.0;
        if (!(v > l) || !(v >= r))
            continue;
        if (dsp_is_mains((double)k * binhz, v, binhz, mains))
            continue;
        pf = v;
        kf = k;
    }
    /* No fundamental is not an error and does not end it: the floor is the useful number
     * with the inputs disconnected, and a flat spectrum has no local maximum at all. The
     * noise passes below run either way, with nothing excluded when there is no line. */
    nline = 0;
    vf = 0.0;
    if (kf >= 0) {
        const double amp = dsp_line_amp(ip, pwr, kf, nbins, pf, &d0);
        if (amp > 0.0) {
            vf = amp;
            fb = (double)kf + d0;
            out->f0 = fb;
            out->f0_hz = (binhz > 0.0) ? fb * binhz : 0.0;
            out->amp0 = vf;
            line[0] = kf;
            nline = 1;
        }
    }
    for (h = 2; nline > 0 && h <= DSP_THD_HMAX; h++) {
        const double c = fb * (double)h;
        double bp = -1.0;
        int a, b, bk = -1;
        /* Positive again: a NaN fb ends the search rather than running it on garbage. */
        if (!(c + (double)DSP_THD_HALFW <= (double)k1))
            break;
        a = dsp_ifloor(c - (double)DSP_THD_HALFW + 0.5);
        b = dsp_ifloor(c + (double)DSP_THD_HALFW + 0.5);
        /* Only the lower bound needs clamping. The break above has already established
         * c + HALFW <= k1, and k1 is an integer, so b = floor(c + HALFW + 0.5) <= k1. */
        if (a < k0)
            a = k0;
        for (k = a; k <= b; k++) {
            double v = (double)pwr[k];
            if (v > bp) {
                bp = v;
                bk = k;
            }
        }
        if (bk < 0 || !(bp > 0.0))
            continue;
        /* Inside the previous line's skirt the two are not resolvable and counting both
         * counts one twice. Skipping also keeps the list ascending, which the noise pass
         * below relies on. */
        if (bk <= line[nline - 1] + skirt)
            continue;
        {
            const double hv = dsp_line_amp(ip, pwr, bk, nbins, bp, NULL);
            hsum += hv * hv;
        }
        line[nline] = bk;
        nline++;
        nh++;
    }

    /* One in every stride bins; see ::DSP_THD_NSAMPLE for why the figures sample. */
    stride = (k1 - k0 + 1) / DSP_THD_NSAMPLE;
    if (stride < 1)
        stride = 1;
    dsp_noise_pass(pwr, k0, k1, line, nline, skirt, DBL_MAX, stride, &sum, &cnt);
    /* Again with the outliers clipped: see ::DSP_THD_CLIP for why the plain mean is not
     * the floor. One extra pass, no transcendentals. */
    for (h = 0; h < DSP_THD_CLIPS && cnt > 0 && sum > 0.0; h++) {
        double csum = 0.0;
        int ccnt = 0;
        dsp_noise_pass(pwr, k0, k1, line, nline, skirt,
                       (sum / (double)cnt) * DSP_THD_CLIP, stride, &csum, &ccnt);
        /* Converged: the clip removed nothing, so another pass would remove nothing. */
        if (ccnt == cnt || ccnt < 1 || !(csum > 0.0))
            break;
        sum = csum;
        cnt = ccnt;
    }

    out->stride = stride;
    if (cnt > 0 && sum > 0.0 && dsp_finite(sum)) {
        const double mean = sum / (double)cnt;
        out->nnoise = cnt;
        out->noise_db = 10.0 * DSP_LOG10(mean);
        /* NO FUNDAMENTAL, NO RATIOS. The strongest bin of a spectrum with nothing in it is
         * a noise peak, and both ratios taken against it are arithmetic about nothing. The
         * floor above still stands: shorted, it is the instrument's own. */
        if (vf > 0.0 && vf * vf > mean * DSP_THD_MINRATIO) {
            out->signal = 1;
            /* The halves of the two mean squares cancel, leaving the power ratio.
             * sum * stride is the integrated noise: the sampled sum scaled back up. */
            out->snr_db = 10.0 * DSP_LOG10((vf * vf) / (sum * (double)stride));
        }
    }
    if (out->signal != 0) {
        out->nharm = nh;
        if (nh > 0)
            out->thd = DSP_SQRT(hsum) / vf;
    }
    /* Nothing non-finite leaves here, which is what dsp_reduce enforces for the trace and
     * what these figures reach the front panel through. Bins near DBL_MAX overflow the
     * harmonic sum and the noise sum, and an infinity formatted into a display string is a
     * refused parameter and a modal dialog. A figure that cannot be computed is reported as
     * absent -- its flag cleared -- rather than as a number no test could predict. */
    if (!dsp_finite(out->thd) || !dsp_finite(out->snr_db)) {
        out->thd = 0.0;
        out->snr_db = 0.0;
        out->signal = 0;
        out->nharm = 0;
    }
    /* noise_db needs no guard of its own: the sum is tested for finiteness where the mean is
     * formed, and a positive finite mean over a positive count has a finite logarithm. An
     * overflowed sum leaves nnoise at 0, which is the flag saying there is no floor. */
    if (!dsp_finite(out->f0) || !dsp_finite(out->f0_hz) || !dsp_finite(out->amp0)) {
        out->f0 = 0.0;
        out->f0_hz = 0.0;
        out->amp0 = 0.0;
    }
    return DSP_OK;
}
