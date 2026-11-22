/* Scalar DSP kernels and plan layout. The caller owns all storage; frame processing allocates nothing. */

#include "dsp.h"

#include <float.h>  /* FLT_MAX, DBL_MAX; freestanding C99 provides it */
#include <limits.h> /* INT_MAX, INT_MIN; freestanding C99 provides it */
#include <math.h>
#include <stdint.h> /* uintptr_t only; freestanding C99 provides it */
#include <string.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

#define INV_M_PI    (1.0 / M_PI)
#define INV_DSP_GHX (1.0 / DSP_GHX)
#define INV_DSP_DN  (1.0 / (double)DSP_DN)

/*
 * Use element-width math where available. The freestanding image uses the
 * firmware's double-precision entry points for transcendentals.
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

/* Check range before converting a double to dsp_real. */
#ifdef DSP_DOUBLE
#define DSP_REAL_MAX DBL_MAX
#else
#define DSP_REAL_MAX FLT_MAX
#endif

/* Reject non-finite limits and scales before they reach the trace. */
static int dsp_finite(const double v) {
    return isfinite(v) != 0;
}

static int dsp_storable(const double v) {

    return isfinite(v) != 0 && v <= (double)DSP_REAL_MAX && v >= -(double)DSP_REAL_MAX;
}

/* Halve a nonnegative length without signed division or a signed right shift. */
static int dsp_half(const int v) {
    return (int)((unsigned)v >> 1U);
}

static int dsp_is_odd(const int v) {
    return ((unsigned)v & 1U) != 0U;
}

#if DSP_CHECK_OVERLAP
/* Compare byte ranges by address difference so computing the end cannot overflow. */

static void dsp_vec_flat(dsp_vec *v, dsp_real *p, int len);
static void dsp_vec_flat_ro(dsp_vec *v, const dsp_real *p, int len);

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

/* The final slice holds only the remaining elements, not a full slice. */
static size_t dsp_slice_bytes(const dsp_vec *v, const int s) {
    const int rest = v->len - s * v->per;
    const int take = (rest < v->per) ? rest : v->per;
    return (take > 0) ? (size_t)take * sizeof(dsp_real) : 0U;
}

/* Check every slice; a segmented array need not be physically contiguous. */
static int dsp_vec_hits(const dsp_vec *v, const void *q, const size_t qz) {
    int s;
    if (v == NULL || q == NULL || qz == 0U)
        return 0;
    for (s = 0; s < v->nslice; s++) {
        if (dsp_overlaps(v->tab[s], dsp_slice_bytes(v, s), q, qz))
            return 1;
    }
    return 0;
}

static int dsp_vec_hits_vec(const dsp_vec *a, const dsp_vec *b) {
    int s;
    if (a == NULL || b == NULL)
        return 0;
    for (s = 0; s < a->nslice; s++) {
        if (dsp_vec_hits(b, a->tab[s], dsp_slice_bytes(a, s)))
            return 1;
    }
    return 0;
}
#endif /* DSP_CHECK_OVERLAP */

/* Clamp before converting to int and handle NaN explicitly. */
static int dsp_ifloor(const double v) {
    const double f = floor(v);

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

/* The exported element size lets callers check that their header matches the linked library. */
const int dsp_real_size = (int)sizeof(dsp_real);

/* Windows */

/* Index-parallel cosine sums: a0 - a1*cos + a2*cos2 - a3*cos3. Kaiser has no coefficients here. */
static const double dsp_wincos[DSP_WINDOW_COUNT][4] = {
    {1.0, 0.0, 0.0, 0.0},                 /* RECT */
    {0.5, 0.5, 0.0, 0.0},                 /* HANN */
    {0.42, 0.5, 0.08, 0.0},               /* BLACKMAN */
    {0.35875, 0.48829, 0.14128, 0.01168}, /* BLACKMAN_HARRIS */
    {0.0, 0.0, 0.0, 0.0},                 /* KAISER: unused */
};

/* I0(x) = sum ((x/2)^k/k!)^2. The next term multiplies by (x/2)^2/k^2. */
#define DSP_I0_TERMS 200

/* Increment an exact double index instead of converting it twice per term. */
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

static int dsp_window_vec(dsp_vec *w, const int n, const int kind, const double beta) {
    double di;
    int half, i;
    if (w == NULL || w->nslice < 1 || n < 2)
        return DSP_EARG;
    if (kind < 0 || kind >= DSP_WINDOW_COUNT)
        return DSP_EARG;
    half = dsp_half(n + 1);

    if (kind == DSP_WINDOW_KAISER) {
        double i0b, inv_i0b, ustep;
        /* Ordered bounds reject NaN beta before it reaches the series. */
        if (!(beta >= DSP_KAISER_BETA_MIN) || !(beta <= DSP_KAISER_BETA_MAX))
            return DSP_EBETA;
        i0b = dsp_bessel_i0(beta);
        if (!(i0b > 0.0))
            return DSP_EBETA;
        inv_i0b = 1.0 / i0b;
        /* Hoist both the window step and the I0 normalization out of the loop. */
        ustep = 2.0 / (double)(n - 1);
        /* Compute u from an exact index so rounding does not accumulate as it would with u += ustep. */
        for (i = 0, di = 0.0; i < half; i++, di += 1.0) {
            double u = ustep * di - 1.0;
            double s = 1.0 - u * u;
            double v;
            if (s < 0.0)
                s = 0.0;
            v = dsp_bessel_i0(beta * DSP_SQRT(s)) * inv_i0b;
            DSP_AT(w, i) = (dsp_real)v;
            DSP_AT(w, n - 1 - i) = (dsp_real)v;
        }
    } else {
        const double *c = dsp_wincos[kind];
        const double step = 2.0 * M_PI / (double)(n - 1);
        for (i = 0, di = 0.0; i < half; i++, di += 1.0) {
            const double t = step * di;
            double v = c[0] - c[1] * DSP_COS(t) + c[2] * DSP_COS(2.0 * t) -
                       c[3] * DSP_COS(3.0 * t);
            DSP_AT(w, i) = (dsp_real)v;
            DSP_AT(w, n - 1 - i) = (dsp_real)v;
        }
    }
    return DSP_OK;
}

int dsp_window(dsp_real *DSP_RESTRICT w, const int n, const int kind, const double beta) {
    dsp_vec v;
    if (w == NULL)
        return DSP_EARG;
    dsp_vec_flat(&v, w, n);
    return dsp_window_vec(&v, n, kind, beta);
}

/* Interpolation tables */

/* Evaluate the symmetric window's transform with twice the half-sum plus any center sample. */

static double dsp_gain_at(const dsp_vec *w, const int n, const double x, const double inv_wsum) {
    const double ctr = 0.5 * (double)(n - 1);
    const double a = 2.0 * M_PI * x / (double)n;
    double s = 0.0, d;
    int half = dsp_half(n), i;
    /* The centered index is an exact integer or half-integer; incrementing it adds no rounding. */
    for (i = 0, d = -ctr; i < half; i++, d += 1.0)
        s += (double)DSP_AT(w, i) * DSP_COS(a * d);
    s = 2.0 * s * inv_wsum;
    return s < 0.0 ? -s : s;
}

/* The first null depends on the window shape, not the FFT length. */
int dsp_window_lobe(const int kind, const double beta) {
    switch (kind) {

    case DSP_WINDOW_RECT:
    case DSP_WINDOW_HANN:
        return 2;
    case DSP_WINDOW_BLACKMAN:
        return 3;
    case DSP_WINDOW_BLACKMAN_HARRIS:
        return 4;
    case DSP_WINDOW_KAISER: {
        /* Kaiser's first null is at sqrt(1 + (beta/pi)^2) bins. */
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

static int dsp_win_tables(const dsp_vec *w, const int n, dsp_interp *ip, int *kdc_out) {
    double rt[DSP_DN + 1];
    double wsum = 0.0, inv_wsum;
    int one, nd, mono, j, jd, b, kdc;
    const int half = dsp_half(n);

    for (j = 0; j < half; j++)
        wsum += (double)DSP_AT(w, j);
    wsum = 2.0 * wsum;
    if (!(wsum > 0.0))
        return DSP_EARG;

    inv_wsum = 1.0 / wsum;
    for (j = 0; j <= DSP_GN; j++)
        ip->gtab[j] = dsp_gain_at(w, n, (double)j * DSP_GHX, inv_wsum);

    one = dsp_ifloor(INV_DSP_GHX + 0.5);
    nd = dsp_ifloor(0.5 * INV_DSP_GHX + 0.5);
    /* The gain grid must reach 1.5 bins to cover the far neighbor at a half-bin offset. */
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
        /* Invert onto a uniform ratio grid so sub-bin lookup needs no search. */
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

    /* Mean removal changes near-DC amplitude by up to 2*G(b)^2; withhold affected bins. */
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
    /* Bound the index while retaining the fractional part for interpolation. */
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
    /* A zero ratio step means the window has no usable inverse table. */
    if (!(ip->dhr > 0.0))
        return DSP_EDECLINE;
    if (r < 0.0) {
        r = -r;
        neg = 1;
    }
    t = r * ip->inv_dhr;

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

int dsp_peak_interp_vec(const dsp_interp *ip, const dsp_vec *pwr, const int k, const int nbins,
                        double *d_out, double *amp_out) {
    double pc, pl, pr, cc, ll, rr, den, d, g;
    if (ip == NULL || pwr == NULL || pwr->nslice < 1)
        return DSP_EARG;
#if DSP_CHECK_OVERLAP
    /* Refuse output aliasing before clearing estimates; neither result may overwrite bins. */
    if (dsp_overlaps(d_out, sizeof(*d_out), amp_out, sizeof(*amp_out)))
        return DSP_EARG;
#endif
    /* Reject short spectra before subtracting from a potentially invalid bin count. */
    if (nbins < 3)
        return DSP_EDECLINE;
    if (k < 1 || k >= nbins - 1)
        return DSP_EDECLINE;
    pc = (double)DSP_AT(pwr, k);
    pl = (double)DSP_AT(pwr, k - 1);
    pr = (double)DSP_AT(pwr, k + 1);
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

int dsp_peak_interp(const dsp_interp *ip, const dsp_real *DSP_RESTRICT pwr, const int k,
                    const int nbins, double *d_out, double *amp_out) {
    dsp_vec v;
    dsp_vec_flat_ro(&v, pwr, nbins);
    return dsp_peak_interp_vec(ip, &v, k, nbins, d_out, amp_out);
}

/* Arena layout */

/* A zero slice count marks an array the chosen method does not allocate. */
typedef struct {
    size_t off[DSP_MAX_SLICES];
    int    nslice, per, sh, len;
} dsp_vlay;

typedef struct {
    size_t swp_a, swp_b, sw1_a, sw1_b, sw2_a, sw2_b, blkr, blki, h, fir_out, total;
    dsp_vlay w, twr, twi, utr, uti, re, im, wkr, wki, pwr;
} dsp_layout;

/* The layout walk uses flat offsets or virtual offsets across fixed-size segments. */
typedef struct {
    size_t at;
    size_t seg;
    int    fail; /* no slicing of some array fits the segments */
} dsp_walk;

static size_t dsp_bump(dsp_walk *wk, const size_t bytes) {
    const size_t need = (bytes + (DSP_ALIGN - 1U)) & ~(size_t)(DSP_ALIGN - 1U);
    size_t off = wk->at;
    if (wk->seg != 0U && need != 0U) {
        size_t within;
        /* Each allocation must fit one segment; large arrays use multiple allocations through slices. */
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

static int dsp_log2_of(const int v) {
    int s = 0;
    while ((1 << s) < v)
        s++;
    return s;
}

/*
 * Split a source index into block and in-block element. A single block needs no division.
 * Assemble four-byte-aligned doubles from two word loads to avoid page-straddling faults.
 */
static double dsp_src_at(const dsp_src *s, const int i) {
    const unsigned char *q;
    if (s->nblock == 1)
        q = s->blk[0] + (size_t)i * (size_t)s->stride;
    else
        q = s->blk[i / s->per] + (size_t)(i % s->per) * (size_t)s->stride;
    if (((uintptr_t)q & 7U) != 0U) {
        union { double d; uint32_t w[2]; } u;
        const uint32_t *p = (const uint32_t *)(const void *)q;
        u.w[0] = p[0];
        u.w[1] = p[1];
        return u.d;
    }
    return *(const double *)(const void *)q;
}

static void dsp_src_flat(dsp_src *s, const double *x, const int len) {
    int b;
    for (b = 0; b < DSP_MAX_SRC_BLOCKS; b++)
        s->blk[b] = NULL;
    s->blk[0]  = (const unsigned char *)(const void *)x;
    s->nblock  = (x != NULL) ? 1 : 0;
    s->per     = (len > 0) ? len : 1;
    s->stride  = (int)sizeof(double);
    s->len     = len;
}

/* The read-only view shares the mutable vector type; callers must not store through it. */
static void dsp_vec_flat_ro(dsp_vec *v, const dsp_real *p, const int len) {
    union { const dsp_real *c; dsp_real *m; } u;
    u.c = p;
    dsp_vec_flat(v, u.m, len);
}

static void dsp_vec_flat(dsp_vec *v, dsp_real *p, const int len) {
    int s, per = 1;
    while (per < len && per < (1 << 30))
        per <<= 1;
    for (s = 0; s < DSP_MAX_SLICES; s++)
        v->tab[s] = NULL;
    v->tab[0]  = p;
    /* Decide whether a vector is present from its pointer, not its unvalidated length. */
    v->nslice  = (p != NULL) ? 1 : 0;
    v->per     = per;
    v->sh      = dsp_log2_of(per);
    v->mask    = per - 1;
    v->len     = len;
}

/* A slice uses a power-of-two element count for shift/mask indexing and must hold one contiguous kernel run. */
static int dsp_slice_of(const size_t len, const size_t r, const size_t seg_bytes,
                        const int rowmin) {
    int per = 1, cap = 1, want = 1;
    if (len == 0U)
        return 1;
    if (seg_bytes == 0U || len * r <= seg_bytes) {
        while ((size_t)per < len)
            per <<= 1;
        return per;
    }
    while ((size_t)(cap * 2) * r <= seg_bytes)
        cap <<= 1;
    while ((size_t)(want * 2) * r * 4U <= seg_bytes)
        want <<= 1;
    per = (want > rowmin) ? want : rowmin;
    if ((size_t)per * r > seg_bytes || per > cap)
        return 0;
    return per;
}

/* Only the last slice may be partial; allocate just its actual elements. */
static void dsp_bump_vec(dsp_walk *wk, dsp_vlay *v, const size_t len, const size_t r,
                         const int per) {
    size_t left = len;
    int s;
    v->len = (int)len;
    v->per = (per > 0) ? per : 1;
    v->sh = dsp_log2_of(v->per);
    v->nslice = 0;
    if (len == 0U)
        return;
    if (per <= 0) {
        wk->fail = 1;
        return;
    }
    v->nslice = (int)((len + (size_t)per - 1U) / (size_t)per);
    if (v->nslice > DSP_MAX_SLICES) {
        wk->fail = 1;
        v->nslice = 0;
        return;
    }
    for (s = 0; s < v->nslice; s++) {
        const size_t take = (left < (size_t)per) ? left : (size_t)per;
        v->off[s] = dsp_bump(wk, take * r);
        left -= take;
    }
}

/* Bound n before accumulating layout sizes in a potentially 32-bit size_t. */
static int dsp_is_pow2(const int n) {
    return n >= 4 && n <= DSP_N_MAX && ((unsigned)n & ((unsigned)n - 1U)) == 0U;
}

/* Keep m1 the smaller factor to limit the strided gather's working set. */
static void dsp_fs_factors(const int m, int *m1, int *m2) {
    unsigned bits = 0, t;

    for (t = (unsigned)m; t > 1U; t >>= 1U)
        bits++;
    *m1 = (int)(1U << (bits / 2U));
    *m2 = m / *m1;
}

/* Keep only disjoint bit-reversal pairs that actually move. */
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

/* Four-step requires complete gather blocks; smaller transforms use radix-2. */
static int dsp_fs_usable(const int m, const int m2) {
    return m2 >= DSP_FS_BLOCK && m >= DSP_FS_MIN;
}

/* Resolve the effective method before both sizing and initializing the plan. */
static int dsp_method_of(const int m, const int m2, const int method) {
    if (method == DSP_FFT_FOURSTEP && !dsp_fs_usable(m, m2))
        return DSP_FFT_RADIX2;
    return method;
}

/* Dispatch by the allocated workspace, not a mutable method field. */
static int dsp_method_built(const dsp_plan *p) {
    if (p->wkr != NULL && p->blkr != NULL && p->sw1_a != NULL)
        return DSP_FFT_FOURSTEP;
    return DSP_FFT_RADIX2;
}

/* Sizing and initialization share one layout walk and allocate only the chosen method's workspace. */
static int dsp_layout_of(int n, const int decim, const int method, const size_t seg_bytes,
                         dsp_layout *lay) {
    dsp_walk wk;
    size_t r = sizeof(dsp_real);
    int m, ntw, m1, m2, meth, rowmin, per_m, per_n, per_tw;
    if (decim < 1 || decim > DSP_DECIM_MAX)
        return DSP_EARG;
    if (method < 0 || method >= DSP_FFT_COUNT)
        return DSP_EARG;
    if (!dsp_is_pow2(n))
        return DSP_EPOW2;
    /* Each segment must preserve DSP_ALIGN for the allocations it contains. */
    if (seg_bytes != 0U && (seg_bytes < DSP_ALIGN || (seg_bytes & (DSP_ALIGN - 1U)) != 0U))
        return DSP_EARG;
    wk.at = 0;
    wk.seg = seg_bytes;
    wk.fail = 0;
    m = dsp_half(n);
    ntw = (m >= 4) ? m - 2 : 1; /* stages len=4..m contribute len/2 each: m-2 in total */
    dsp_fs_factors(m, &m1, &m2);
    meth = dsp_method_of(m, m2, method);
    /* Slices must fit the longest contiguous run: a four-step row or a radix-2 kernel run. */
    rowmin = (m1 > m2) ? m1 : m2;
    if (rowmin < DSP_FS_BLOCK)
        rowmin = DSP_FS_BLOCK;
    per_m  = dsp_slice_of((size_t)m, r, seg_bytes, rowmin);
    per_n  = dsp_slice_of((size_t)n, r, seg_bytes, rowmin);
    per_tw = dsp_slice_of((size_t)ntw, r, seg_bytes, rowmin);
    dsp_bump_vec(&wk, &lay->w, (size_t)n, r, per_n);

    if (meth == DSP_FFT_RADIX2) {
        lay->swp_a = dsp_bump(&wk, (size_t)dsp_half(m) * sizeof(int));
        lay->swp_b = dsp_bump(&wk, (size_t)dsp_half(m) * sizeof(int));
    } else {
        lay->swp_a = 0;
        lay->swp_b = 0;
    }

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
    dsp_bump_vec(&wk, &lay->twr, (size_t)ntw, r, per_tw);
    dsp_bump_vec(&wk, &lay->twi, (size_t)ntw, r, per_tw);
    dsp_bump_vec(&wk, &lay->utr, (size_t)m, r, per_m);
    dsp_bump_vec(&wk, &lay->uti, (size_t)m, r, per_m);
    dsp_bump_vec(&wk, &lay->re, (size_t)m, r, per_m);
    dsp_bump_vec(&wk, &lay->im, (size_t)m, r, per_m);

    if (meth == DSP_FFT_FOURSTEP) {
        dsp_bump_vec(&wk, &lay->wkr, (size_t)m, r, per_m);
        dsp_bump_vec(&wk, &lay->wki, (size_t)m, r, per_m);
        lay->blkr = dsp_bump(&wk, (size_t)(DSP_FS_BLOCK * m1) * r);
        lay->blki = dsp_bump(&wk, (size_t)(DSP_FS_BLOCK * m1) * r);
    } else {
        dsp_bump_vec(&wk, &lay->wkr, 0U, r, 1);
        dsp_bump_vec(&wk, &lay->wki, 0U, r, 1);
        lay->blkr = 0;
        lay->blki = 0;
    }
    dsp_bump_vec(&wk, &lay->pwr, (size_t)m, r, per_m);
    lay->h     = dsp_bump(&wk, (size_t)DSP_FIR_MAXTAPS * r);
    /* Reserve FIR scratch only for a decimating plan. */
    lay->fir_out = (decim > 1) ? dsp_bump(&wk, (size_t)n * sizeof(double)) : 0;

    if (wk.fail)
        return DSP_ESEG;
    /* Radix-2 requires whole working arrays; four-step can address slices at row boundaries. */
    if (meth != DSP_FFT_FOURSTEP &&
        (lay->re.nslice > 1 || lay->im.nslice > 1 ||
         lay->twr.nslice > 1 || lay->twi.nslice > 1))
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
    /* Round the final virtual extent up to count all occupied segments. */
    segs = (lay.total + seg_bytes - 1U) / seg_bytes;
    if (segs > (size_t)DSP_N_MAX)
        return 0;
    return (int)segs;
}

/* Translate virtual offsets to their segment base and in-segment offset. */
static void *dsp_seg_at(void *const *segs, const size_t seg_bytes, const size_t off) {
    if (seg_bytes == 0U)
        return (void *)((unsigned char *)segs[0] + off);
    return (void *)((unsigned char *)segs[off / seg_bytes] + (off % seg_bytes));
}

static void dsp_bind_vec(dsp_vec *v, const dsp_vlay *lay, void *const *segs,
                         const size_t seg_bytes) {
    int s;
    v->nslice = lay->nslice;
    v->per    = lay->per;
    v->sh     = lay->sh;
    v->mask   = lay->per - 1;
    v->len    = lay->len;
    for (s = 0; s < DSP_MAX_SLICES; s++)
        v->tab[s] = NULL;
    for (s = 0; s < lay->nslice; s++)
        v->tab[s] = (dsp_real *)dsp_seg_at(segs, seg_bytes, lay->off[s]);
}

/* A zero segment size selects the contiguous arena case. */
static int dsp_plan_build(dsp_plan *p, void *const *segs, const int nsegs, const size_t seg_bytes,
                          const size_t flat_bytes, int n, const int kind, const double beta,
                          const int decim, const int method) {
    dsp_layout lay;
    int m, rc, i, idx, len, half, kdc, meth, si;
    double wsum, di;

    if (p == NULL)
        return DSP_EARG;
    /* Clear the plan on entry so any rejected configuration leaves it unusable. */
    memset(p, 0, sizeof(*p));
    if (segs == NULL || nsegs < 1)
        return DSP_EARG;
    for (si = 0; si < nsegs; si++) {
        if (segs[si] == NULL)
            return DSP_EARG;
    }
#if DSP_CHECK_OVERLAP
    /* Reject overlap before acquiring pointers into the caller's arena. */
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
    /* Each base must be aligned; aligned offsets cannot fix an unaligned base. */
    for (si = 0; si < nsegs; si++) {
        if (((uintptr_t)segs[si] & (uintptr_t)(DSP_ALIGN - 1)) != 0)
            return DSP_EALIGN;
    }

    m = dsp_half(n);
    dsp_fs_factors(m, &p->m1, &p->m2);

    meth = dsp_method_of(m, p->m2, method);
    p->n      = n;
    p->m      = m;
    p->kind   = kind;
    p->beta   = beta;
    p->decim  = decim;
    p->method = meth;
    dsp_bind_vec(&p->w_v, &lay.w, segs, seg_bytes);
    dsp_bind_vec(&p->twr_v, &lay.twr, segs, seg_bytes);
    dsp_bind_vec(&p->twi_v, &lay.twi, segs, seg_bytes);
    dsp_bind_vec(&p->utr_v, &lay.utr, segs, seg_bytes);
    dsp_bind_vec(&p->uti_v, &lay.uti, segs, seg_bytes);
    dsp_bind_vec(&p->re_v, &lay.re, segs, seg_bytes);
    dsp_bind_vec(&p->im_v, &lay.im, segs, seg_bytes);
    dsp_bind_vec(&p->pwr_v, &lay.pwr, segs, seg_bytes);
    /* The plain pointers alias slice zero for callers using contiguous storage. */
    p->w     = p->w_v.tab[0];
    p->twr   = p->twr_v.tab[0];
    p->twi   = p->twi_v.tab[0];
    p->utr   = p->utr_v.tab[0];
    p->uti   = p->uti_v.tab[0];
    p->re    = p->re_v.tab[0];
    p->im    = p->im_v.tab[0];
    p->pwr   = p->pwr_v.tab[0];
    p->h     = (dsp_real *)dsp_seg_at(segs, seg_bytes, lay.h);

    if (meth == DSP_FFT_RADIX2) {
        p->swp_a = (int *)dsp_seg_at(segs, seg_bytes, lay.swp_a);
        p->swp_b = (int *)dsp_seg_at(segs, seg_bytes, lay.swp_b);
    }
    if (meth == DSP_FFT_FOURSTEP) {
        p->sw1_a = (int *)dsp_seg_at(segs, seg_bytes, lay.sw1_a);
        p->sw1_b = (int *)dsp_seg_at(segs, seg_bytes, lay.sw1_b);
        p->sw2_a = (int *)dsp_seg_at(segs, seg_bytes, lay.sw2_a);
        p->sw2_b = (int *)dsp_seg_at(segs, seg_bytes, lay.sw2_b);
        dsp_bind_vec(&p->wkr_v, &lay.wkr, segs, seg_bytes);
        dsp_bind_vec(&p->wki_v, &lay.wki, segs, seg_bytes);
        p->wkr   = p->wkr_v.tab[0];
        p->wki   = p->wki_v.tab[0];
        p->blkr  = (dsp_real *)dsp_seg_at(segs, seg_bytes, lay.blkr);
        p->blki  = (dsp_real *)dsp_seg_at(segs, seg_bytes, lay.blki);
    }
    p->fir_out = (decim > 1) ? (double *)dsp_seg_at(segs, seg_bytes, lay.fir_out) : NULL;

    rc = dsp_window_vec(&p->w_v, n, kind, beta);
    if (rc != DSP_OK) {
        memset(p, 0, sizeof(*p));
        return rc;
    }

    /* Sum the actual window: the ideal coherent gain is not exact for a finite record. */
    wsum = 0.0;
    for (i = 0; i < n; i++)
        wsum += (double)DSP_AT(&p->w_v, i);
    if (!(wsum > 0.0)) {
        memset(p, 0, sizeof(*p));
        return DSP_EARG;
    }
    p->wsum = wsum;
    p->cg = wsum / (double)n;
    /* Untangling yields 2X; square 1/wsum to scale it to peak voltage squared. */
    {
        const double iw = 1.0 / wsum; /* one divide, squared */
        p->ksq = iw * iw;
    }

    rc = dsp_win_tables(&p->w_v, n, &p->ip, &kdc);
    if (rc != DSP_OK) {
        memset(p, 0, sizeof(*p));
        return rc;
    }
    p->kdc = kdc;
    p->mono = p->ip.mono;
    p->ip.lobe = dsp_window_lobe(kind, beta);

    if (p->swp_a != NULL)
        p->nswp = dsp_build_swaps(m, p->swp_a, p->swp_b);
    if (p->sw1_a != NULL) {
        p->nsw1 = dsp_build_swaps(p->m1, p->sw1_a, p->sw1_b);
        p->nsw2 = dsp_build_swaps(p->m2, p->sw2_a, p->sw2_b);
    }

    /* Flatten butterfly twiddles stage-major. The length-2 stage uses unity and stores nothing. */
    idx = 0;
    for (len = 4; len <= m; len *= 2) {
        const double ang = -2.0 * M_PI / (double)len;
        half = dsp_half(len);

        for (i = 0, di = 0.0; i < half; i++, di += 1.0) {
            const double t = ang * di;
            DSP_AT(&p->twr_v, idx) = (dsp_real)DSP_COS(t);
            DSP_AT(&p->twi_v, idx) = (dsp_real)DSP_SIN(t);
            idx++;
        }
    }

    {
        const double ang = -2.0 * M_PI / (double)n;
        for (i = 0, di = 0.0; i < m; i++, di += 1.0) {
            const double t = ang * di;
            DSP_AT(&p->utr_v, i) = (dsp_real)DSP_COS(t);
            DSP_AT(&p->uti_v, i) = (dsp_real)DSP_SIN(t);
        }
    }
    return DSP_OK;
}

int dsp_plan_init(dsp_plan *p, void *arena, const size_t bytes, int n, const int kind, const double beta,
                  const int decim, const int method) {

    void *one = arena;
    return dsp_plan_build(p, &one, 1, 0U, bytes, n, kind, beta, decim, method);
}

int dsp_plan_init_segs(dsp_plan *p, void *const *segs, const int nsegs, const size_t seg_bytes, int n,
                       const int kind, const double beta, const int decim, const int method) {
    /* Zero segment size is reserved for the flat layout, which supplies a separate byte count. */
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
    /* Reject taps for a plan that cannot decimate rather than ignoring the filter in each frame. */
    if (ntaps > 0 && p->decim < 2)
        return DSP_EARG;
    /* Copy taps into the plan arena so the caller can release its design buffer. */
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

/* Yield at phase boundaries, never in an inner loop. */
static void dsp_do_yield(const dsp_plan *p) {
    if (p->yield != NULL)
        p->yield(p->yield_ctx);
}

/* Windowed load */

static int dsp_load_vec(const dsp_src *x, const int n, const dsp_vec *w,
                        const double wsum, dsp_vec *re, dsp_vec *im, double *mean_out) {
    double s0 = 0.0, s1 = 0.0, mean;
    int i, k, m;
    if (x == NULL || w == NULL || re == NULL || im == NULL)
        return DSP_EARG;
    if (x->nblock < 1 || x->nblock > DSP_MAX_SRC_BLOCKS || x->per < 1 || x->len < n)
        return DSP_EARG;
    /* The block vector must cover every source index the loader can address. */
    if ((long)x->nblock * (long)x->per < (long)x->len)
        return DSP_EARG;
    /*
     * The stride must hold a double and preserve the firmware's four-byte alignment.
     * The loader handles a four-byte-aligned double with two word loads.
     */
    if (x->stride < (int)sizeof(double) || (x->stride & 3) != 0)
        return DSP_EARG;
    if (w->nslice < 1 || re->nslice < 1 || im->nslice < 1)
        return DSP_EARG;
    if (!dsp_is_pow2(n))
        return DSP_EPOW2;

    if (!(wsum > 0.0))
        return DSP_EARG;
    m = dsp_half(n);
#if DSP_CHECK_OVERLAP
    /* Check both writable halves against each other and every input extent. */
    {
        int b;
        if (dsp_vec_hits_vec(re, im) || dsp_vec_hits_vec(re, w) || dsp_vec_hits_vec(im, w)
            || dsp_vec_hits(re, mean_out, sizeof(*mean_out))
            || dsp_vec_hits(im, mean_out, sizeof(*mean_out))
            || dsp_vec_hits(w, mean_out, sizeof(*mean_out)))
            return DSP_EARG;

        for (b = 0; b < x->nblock; b++) {
            const int rest = x->len - b * x->per;
            const int take = (rest < x->per) ? rest : x->per;
            const size_t zb = (take > 0) ? (size_t)take * (size_t)x->stride : 0U;
            if (dsp_vec_hits(re, x->blk[b], zb) || dsp_vec_hits(im, x->blk[b], zb)
                || dsp_vec_hits(w, x->blk[b], zb)
                || dsp_overlaps(mean_out, sizeof(*mean_out), x->blk[b], zb))
                return DSP_EARG;
        }
    }
#endif
    /* Use independent even and odd accumulation chains, which also match the packed output. */
    for (i = 0; i < n; i += 2) {
        s0 = s0 + dsp_src_at(x, i) * (double)DSP_AT(w, i);
        s1 = s1 + dsp_src_at(x, i + 1) * (double)DSP_AT(w, i + 1);
    }
    mean = (s0 + s1) / wsum;
    /* Subtract the mean in double before rounding into the complex arrays. */
    for (k = 0, i = 0; k < m; k++, i += 2) {
        DSP_AT(re, k) = (dsp_real)((dsp_src_at(x, i) - mean) * (double)DSP_AT(w, i));
        DSP_AT(im, k) = (dsp_real)((dsp_src_at(x, i + 1) - mean) * (double)DSP_AT(w, i + 1));
    }
    if (mean_out != NULL)
        *mean_out = mean;
    return DSP_OK;
}

int dsp_load(const double *DSP_RESTRICT x, const int n, const dsp_real *DSP_RESTRICT w,
             const double wsum, dsp_real *DSP_RESTRICT re, dsp_real *DSP_RESTRICT im,
             double *mean_out) {
    dsp_vec wv, rv, iv;
    dsp_src xs;
    if (x == NULL || w == NULL || re == NULL || im == NULL)
        return DSP_EARG;
    if (!dsp_is_pow2(n))
        return DSP_EPOW2;
    dsp_vec_flat_ro(&wv, w, n);
    dsp_vec_flat(&rv, re, dsp_half(n));
    dsp_vec_flat(&iv, im, dsp_half(n));
    dsp_src_flat(&xs, x, n);
    return dsp_load_vec(&xs, n, &wv, wsum, &rv, &iv, mean_out);
}

/* FFT decompositions */

/* In-place decimation-in-time radix-2 with precomputed bit-reversal swaps. */
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

/* Transform interleaved gather lanes; element i of lane c is at i*DSP_FS_BLOCK + c. */
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

/*
 * Four-step for m = m1*m2: run m2 length-m1 column FFTs, apply W_m^{j2*k1},
 * run m1 length-m2 row FFTs, then transpose to k = k1 + k2*m1.
 */
static void fft_fourstep(dsp_plan *p) {
    const int m1 = p->m1, m2 = p->m2;
    const int h = dsp_half(p->m);
    /* Index the intermediate and working matrices by slice; a segment can be smaller than a matrix. */
    dsp_vec *re = &p->re_v;
    dsp_vec *im = &p->im_v;
    dsp_vec *wkr = &p->wkr_v;
    dsp_vec *wki = &p->wki_v;
    dsp_real *DSP_RESTRICT blkr = p->blkr;
    dsp_real *DSP_RESTRICT blki = p->blki;
    /* Each sub-transform's twiddles are a prefix of the full table and fit the contiguous run. */
    const dsp_real *twr = p->twr, *twi = p->twi;
    const dsp_vec *twr_v = &p->twr_v, *twi_v = &p->twi_v;
    int log2h = 0, twbase, jb, k1, k2, kb, t;

    for (t = h; t > 1; t = dsp_half(t))
        log2h++;
    /* Use the last stage for W_m^idx; the upper half is the lower half negated. */
    twbase = h - 2;

    /* Powers of two and the lower size limit give full gather blocks. */
    for (jb = 0; jb < m2; jb += DSP_FS_BLOCK) {
        int j1, c;

        for (j1 = 0; j1 < m1; j1++) {
            const dsp_real *gr = DSP_ROW(re, j1 * m2 + jb);
            const dsp_real *gi = DSP_ROW(im, j1 * m2 + jb);
            dsp_real *dr = blkr + (size_t)j1 * DSP_FS_BLOCK;
            dsp_real *di = blki + (size_t)j1 * DSP_FS_BLOCK;
            for (c = 0; c < DSP_FS_BLOCK; c++) {
                dr[c] = gr[c];
                di[c] = gi[c];
            }
        }

        fft_block(blkr, blki, m1, p->sw1_a, p->sw1_b, p->nsw1, twr, twi);

        dsp_do_yield(p);

        /* Apply W_m^{j2*k1} while scattering into the next pass's contiguous rows. */
        for (k1 = 0; k1 < m1; k1++) {
            const dsp_real *ar = blkr + (size_t)k1 * DSP_FS_BLOCK;
            const dsp_real *ai = blki + (size_t)k1 * DSP_FS_BLOCK;
            dsp_real *o_r = DSP_ROW(wkr, k1 * m2 + jb);
            dsp_real *o_i = DSP_ROW(wki, k1 * m2 + jb);
            int idx = jb * k1;
            for (c = 0; c < DSP_FS_BLOCK; c++) {

                const unsigned u   = (unsigned)idx;
                const int      off = (int)(u & ((unsigned)h - 1U));
                const int      neg = (int)(u >> (unsigned)log2h);
                const dsp_real sgn = (dsp_real)(1 - 2 * neg);
                const dsp_real cr = sgn * DSP_AT(twr_v, twbase + off);
                const dsp_real ci = sgn * DSP_AT(twi_v, twbase + off);
                const dsp_real xr = ar[c], xi = ai[c];
                o_r[c] = xr * cr - xi * ci;
                o_i[c] = xr * ci + xi * cr;
                idx += k1;
            }
        }
    }

    for (k1 = 0; k1 < m1; k1++) {
        fft_radix2(DSP_ROW(wkr, k1 * m2), DSP_ROW(wki, k1 * m2), m2, p->sw2_a,
                   p->sw2_b, p->nsw2, twr, twi);
        dsp_do_yield(p);
    }

    /* X[k1 + k2*m1] = wk[k1*m2 + k2]; transpose in cache-sized tiles. */
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
                dsp_real *o_r = DSP_ROW(re, k2 * m1);
                dsp_real *o_i = DSP_ROW(im, k2 * m1);
                for (k1 = jbb; k1 < jhi; k1++) {
                    o_r[k1] = DSP_AT(wkr, k1 * m2 + k2);
                    o_i[k1] = DSP_AT(wki, k1 * m2 + k2);
                }
            }
        }
    }
}

void dsp_rfft(dsp_plan *p) {
    int method;
    if (p == NULL || p->m < 2)
        return;
    /* The workspace determines which kernel is safe to run. */
    method = dsp_method_built(p);
    if (method == DSP_FFT_FOURSTEP)
        fft_fourstep(p);
    else
        fft_radix2(p->re, p->im, p->m, p->swp_a, p->swp_b, p->nswp, p->twr, p->twi);
}

/* Power */

/* Use indices so mirrored pairs remain valid across non-contiguous slices. */
static void dsp_power_vec(const dsp_vec *re, const dsp_vec *im, const int m,
                          const dsp_vec *utr, const dsp_vec *uti, dsp_vec *pwr,
                          const double scale) {
    int half = dsp_half(m), j;
    /* Bin 0 is real: X = Re Z[0] + Im Z[0]. */
    {
        const double s = 2.0 * ((double)DSP_AT(re, 0) + (double)DSP_AT(im, 0));
        DSP_AT(pwr, 0) = (dsp_real)(s * s * scale);
    }
    /* Bin m/2 is its own mirror with twiddle -i. At m < 2 it is already bin 0. */
    if (half > 0) {
        double a  = (double)DSP_AT(re, half), b = (double)DSP_AT(im, half);
        DSP_AT(pwr, half) = (dsp_real)(4.0 * (a * a + b * b) * scale);
    }
    /* Untangle at element precision; keep the final power scale in double. */
    for (j = 1; j < half; j++) {
        const int jh = m - j;
        const dsp_real a = DSP_AT(re, j), b = DSP_AT(im, j);
        const dsp_real c = DSP_AT(re, jh), d = DSP_AT(im, jh);
        const dsp_real s1 = a + c, s2 = b + d, d1 = a - c, d2 = b - d;
        const dsp_real u  = DSP_AT(utr, j), v = DSP_AT(uti, j);
        const dsp_real t1 = u * s2 + v * d1;
        const dsp_real t2 = v * s2 - u * d1;
        const dsp_real xr = s1 + t1, xi = d2 + t2;
        const dsp_real yr = s1 - t1, yi = t2 - d2;
        DSP_AT(pwr, j) =
            (dsp_real)(((double)xr * (double)xr + (double)xi * (double)xi) * scale);
        DSP_AT(pwr, jh) =
            (dsp_real)(((double)yr * (double)yr + (double)yi * (double)yi) * scale);
    }
}

void dsp_power(const dsp_real *DSP_RESTRICT re, const dsp_real *DSP_RESTRICT im, const int m,
               const dsp_real *DSP_RESTRICT utr, const dsp_real *DSP_RESTRICT uti,
               dsp_real *DSP_RESTRICT pwr, const double scale) {
    dsp_vec rv, iv, ur, ui, pv;
    dsp_vec_flat_ro(&rv, re, m);
    dsp_vec_flat_ro(&iv, im, m);
    dsp_vec_flat_ro(&ur, utr, m);
    dsp_vec_flat_ro(&ui, uti, m);
    dsp_vec_flat(&pv, pwr, m);
    dsp_power_vec(&rv, &iv, m, &ur, &ui, &pv, scale);
}

/* FIR */

#define DSP_FIR_GAIN_MIN 1e-6

/* Decimating by D folds the input into D zones of width fs/(2D); a passband must fit one zone. */
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
        /* Assign an exact upper edge to the zone below the boundary. */
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
    /* Even zones map upward from the lower edge; odd zones reverse from the upper edge. */
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

    if (k0_out == NULL || k1_out == NULL)
        return DSP_EARG;
    *k0_out = 0;
    *k1_out = 0;
#if DSP_CHECK_OVERLAP
    /* A single output object cannot hold both ends of the selected bin range. */
    if (k0_out == k1_out)
        return DSP_EARG;
#endif
    if (m == NULL)
        return DSP_EARG;
    if (nbins < 1 || !(m->binhz > 0.0) || !(fhi > flo))
        return DSP_EARG;
    if (!dsp_storable(flo) || !dsp_storable(fhi))
        return DSP_EARG;
    /* In an odd zone the high-frequency edge has the lower bin index. */
    /* Divide directly before ceil/floor so an exact bin boundary is not perturbed by a reciprocal. */
    if (m->sense >= 0) {
        lo = (flo - m->f0) / m->binhz;
        hi = (fhi - m->f0) / m->binhz;
    } else {
        lo = (m->f0 - fhi) / m->binhz;
        hi = (m->f0 - flo) / m->binhz;
    }
    /* Round inward to include only bins whose centers lie inside the band. */
    lo = ceil(lo);
    hi = floor(hi);
    /* Clamp before integer conversion so out-of-range quotients cannot overflow it. */
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
    /* A narrow span still supplies one plottable bin. */
    if (k1 < k0)
        k1 = k0;
    *k0_out = k0;
    *k1_out = k1;
    return DSP_OK;
}

double dsp_fir_transition(const double fs, const double flo, const double fhi, const int decim) {
    double zw, ghi, glo, inv_fs;
    int zone = 0;

    if (dsp_zone_single(fs, flo, fhi, decim, &zone) != DSP_OK)
        return 0.0;
    zw = fs / (2.0 * (double)decim);
    inv_fs = 1.0 / fs;
    ghi = ((double)(zone + 1) * zw - fhi) * inv_fs;
    /* Zone zero has no lower alias transition across DC. */
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
    /* Bound the tap estimate before converting to an integer. */
    {

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
    /* Search down from the source-read ceiling for the highest feasible decimation. */
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
        return "no slice layout fits the segments";
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
    /* Compare against a divided bound before forming (n-1)*decim. */
    if (decim > (DSP_SRC_MAX - ntaps) / (n - 1))
        return 0;
    return (n - 1) * decim + ntaps;
}

double dsp_binwidth(const double fs, const int n, const int decim) {

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
    /* A low-pass at decimation one is a no-op; a band-pass can still require filtering. */
    if (decim < 2 && flo == 0.0)
        return 0;

    rc = dsp_zone_single(fs, flo, fhi, decim, &zone);
    if (rc != DSP_OK)
        return rc;
    inv_fs = 1.0 / fs; /* every frequency below is a fraction of fs */

    if (order > 0) {
        l = order;
        /* Use odd taps for an integral group delay; do not round past capacity. */
        if (!dsp_is_odd(l))
            l = (l < maxtaps) ? l + 1 : l - 1;
    } else {

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

    /* Place each cutoff half a transition outside the passband, within its Nyquist zone. */
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

    /* Subtract two sinc kernels; at fc_lo == 0 the lower term vanishes. */
    c = (double)(l - 1) * 0.5;
    {

        const double wstep = 2.0 * M_PI / (double)(l - 1);
        const double whi = 2.0 * M_PI * fc_hi, wlo = 2.0 * M_PI * fc_lo;

        double di;
        for (i = 0, di = 0.0; i < l; i++, di += 1.0) {
            const double mm = di - c;
            double v;
            if (mm == 0.0)
                v = 2.0 * (fc_hi - fc_lo);
            else
                v = (DSP_SIN(whi * mm) - DSP_SIN(wlo * mm)) * INV_M_PI / mm;
            /* Hamming window keeps the first sidelobe near -43 dB. */
            v *= 0.54 - 0.46 * DSP_COS(wstep * di);
            h[i] = (dsp_real)v;
        }
    }

    if (flo == 0.0) {
        /* Normalize low-pass taps by their DC gain, the sum of all taps. */
        double sum = 0.0;
        for (i = 0; i < l; i++)
            sum += (double)h[i];
        divisor = sum;
    } else {
#if DSP_BANDPASS
        /* For band-pass, normalize at the band center; DC lies in the stopband. */
        const double w0 = M_PI * (flo + fhi) * inv_fs;
        const int    ci = dsp_half(l - 1);
        double g  = (double)h[ci];

        double dci;
        for (i = 0, dci = (double)ci; i < ci; i++, dci -= 1.0)
            g += 2.0 * (double)h[i] * DSP_COS(w0 * dci);
        divisor = g;
#else
        return DSP_EUNSUPPORTED;
#endif
    }

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
    /* Refuse overlap with source or taps before writing the output convolution. */
    if (dsp_overlaps(y, (size_t)ny * sizeof(*y), x, (size_t)nx * sizeof(*x))
        || dsp_overlaps(y, (size_t)ny * sizeof(*y), h, (size_t)ntaps * sizeof(*h)))
        return DSP_EARG;
#endif
    /* Use four independent multiply-accumulate chains and accumulate in double. */
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

/* Reduction and peak search */

int dsp_reduce_vec(const dsp_vec *pwr, const int nbins, const int k0, int k1, const int nseg,
                   const dsp_bandmap *map, const double dbmin, const double dbmax,
                   const double vfloor, dsp_real *DSP_RESTRICT db, dsp_real *DSP_RESTRICT hz) {
    double vfl = vfloor * vfloor; /* squared: the bins are power */
    double fstep, f0, binhz, dc;
    int npts, c, qstep, rstep, q0, q1, r1;
    if (pwr == NULL || pwr->nslice < 1 || db == NULL || hz == NULL || map == NULL)
        return DSP_EARG;
    if (nbins < 1 || k0 < 0 || k0 >= nbins || nseg < 1 || nseg > DSP_NSEG_MAX)
        return DSP_EARG;
#if DSP_CHECK_OVERLAP
    /* The two reduction arrays must not overlap each other or their source bins. */
    if (dsp_overlaps(db, (size_t)nseg * sizeof(*db), hz, (size_t)nseg * sizeof(*hz))
        || dsp_vec_hits(pwr, db, (size_t)nseg * sizeof(*db))
        || dsp_vec_hits(pwr, hz, (size_t)nseg * sizeof(*hz)))
        return DSP_EARG;
#endif

    if (k1 > nbins - 1)
        k1 = nbins - 1;
    if (k1 < k0)
        return DSP_EARG;
    binhz = map->binhz;
    /* Reject a missing or invalid frequency scale before forming the axis. */
    if (!(binhz > 0.0) || !dsp_finite(binhz) || !dsp_finite(map->f0))
        return DSP_EARG;
    if (map->sense != 1 && map->sense != -1)
        return DSP_EARG;

    if (!dsp_storable(dbmin) || !dsp_storable(dbmax) || !(dbmin < dbmax))
        return DSP_EARG;
    /* Require a nonnegative voltage floor before squaring it. */
    if (!dsp_finite(vfloor) || !(vfloor >= 0.0))
        return DSP_EARG;
    npts = k1 - k0 + 1;
    /* Reuse one frequency step per trace; native Lua reconstruction uses the same series. */
    f0 = dsp_bin_hz(map, (map->sense > 0) ? k0 : k1);
    fstep = ((double)npts / (double)nseg) * binhz;
    /* Check the endpoint so even a finite bin width cannot overflow the generated series. */
    if (!dsp_storable(f0) || !dsp_storable(fstep) ||
        !dsp_storable(f0 + (double)(nseg - 1) * fstep))
        return DSP_EARG;

    /* Carry the division remainder instead of multiplying two potentially wide indices. */
    qstep = npts / nseg;
    rstep = npts % nseg;
    q0 = 0;
    q1 = qstep;
    r1 = rstep;

    for (c = 0, dc = 0.0; c < nseg; c++, dc += 1.0) {
        /* Mirror descending bin maps so plotted frequencies still rise from left to right. */
        int oa = q0, ob = q1 - 1;
        int a, b;
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
        /* A ternary allows floating select; NaN still loses against the current maximum. */
        /* Index each element so a segment may cross non-contiguous slices. */
        top = (dsp_real)-1;
        for (run = a; run <= b; run++) {
            const dsp_real v = DSP_AT(pwr, run);
            top = (v > top) ? v : top;
        }
        /* Clamp power before log10 so zero and non-finite bins do not reach the display. */
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

int dsp_reduce(const dsp_real *DSP_RESTRICT pwr, const int nbins, const int k0, int k1,
               const int nseg, const dsp_bandmap *map, const double dbmin, const double dbmax,
               const double vfloor, dsp_real *DSP_RESTRICT db, dsp_real *DSP_RESTRICT hz) {
    dsp_vec v;
    dsp_vec_flat_ro(&v, pwr, nbins);
    return dsp_reduce_vec(&v, nbins, k0, k1, nseg, map, dbmin, dbmax, vfloor, db, hz);
}

int dsp_peaks_vec(const dsp_vec *pwr, const int nbins, int k0, int k1, int kdc, const int want,
                  const dsp_interp *ip, int *DSP_RESTRICT bin, dsp_real *DSP_RESTRICT frac,
                  dsp_real *DSP_RESTRICT amp) {
    int kfloor, k, s, found = 0;
    double bv[DSP_PEAKS_MAX];
    if (pwr == NULL || pwr->nslice < 1 || bin == NULL || want < 1)
        return DSP_EARG;
    if (want > DSP_PEAKS_MAX)
        return DSP_EARG;
    /* Validate nbins before deriving the highest index or clamping the DC region. */
    if (nbins < 1)
        return DSP_EARG;
#if DSP_CHECK_OVERLAP
    /* Clear the result buffers only after checking that they do not alias the input or each other. */
    {
        const size_t zb = (size_t)want * sizeof(*bin);
        const size_t zf = (size_t)want * sizeof(*frac);

        if (dsp_overlaps(bin, zb, frac, zf) || dsp_overlaps(bin, zb, amp, zf)
            || dsp_overlaps(frac, zf, amp, zf) || dsp_vec_hits(pwr, bin, zb)
            || dsp_vec_hits(pwr, frac, zf) || dsp_vec_hits(pwr, amp, zf))
            return DSP_EARG;
    }
#endif

    for (s = 0; s < want; s++) {
        bin[s] = -1;
        bv[s] = -1.0;
    }
    /* Clamp the DC exclusion before adding one to avoid signed overflow. */
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
        double v = (double)DSP_AT(pwr, k);
        /* A display span edge is not a spectrum edge: compare its real neighboring bins. */
        const double vl = (k > 0) ? (double)DSP_AT(pwr, k - 1) : -1.0;
        const double vr = (k + 1 < nbins) ? (double)DSP_AT(pwr, k + 1) : -1.0;
        if (!(v > vl) || !(v >= vr))
            continue;
        if (k == kfloor && ip != NULL) {
            /* Reject a first reportable peak whose fitted offset puts it in the DC leakage region. */
            double d = 0.0;
            if (dsp_peak_interp_vec(ip, pwr, k, nbins, &d, NULL) != DSP_OK)
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
            if (ip != NULL && dsp_peak_interp_vec(ip, pwr, bin[s], nbins, &d, &v) == DSP_OK) {
                if (frac != NULL)
                    frac[s] = (dsp_real)d;
                if (amp != NULL)
                    amp[s] = (dsp_real)v;
            } else {
                const double pk = (double)DSP_AT(pwr, bin[s]);
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

int dsp_peaks(const dsp_real *DSP_RESTRICT pwr, const int nbins, int k0, int k1, int kdc,
              const int want, const dsp_interp *ip, int *DSP_RESTRICT bin,
              dsp_real *DSP_RESTRICT frac, dsp_real *DSP_RESTRICT amp) {
    dsp_vec v;
    dsp_vec_flat_ro(&v, pwr, nbins);
    return dsp_peaks_vec(&v, nbins, k0, k1, kdc, want, ip, bin, frac, amp);
}

/* Frame processing */

int dsp_spectrum_run_src(dsp_plan *p, const dsp_src *src, const int nsrc, double *mean_out) {
    /* Pass the source record by pointer so the freestanding build need not copy its block vector. */
    const dsp_src *from = src;
    dsp_src filtered;
    int need, rc;
    if (p == NULL || src == NULL || src->nblock < 1)
        return DSP_EARG;
    if (p->n < 4)
        return DSP_EARG;
    /* Bound the mutable tap count before indexing the plan's allocated filter storage. */
    if (p->ntaps < 0 || p->ntaps > DSP_FIR_MAXTAPS)
        return DSP_EARG;
    /* Refuse decimation without a filter rather than labeling unfiltered samples at a decimated rate. */
    if (p->decim > 1 && (p->ntaps == 0 || p->fir_out == NULL))
        return DSP_EARG;
    need = dsp_fir_srclength(p->n, p->decim, p->ntaps);

    if (need <= 0)
        return DSP_EARG;
    if (nsrc < need)
        return DSP_ESHORT;

    if (p->decim > 1) {
        /* A decimating plan requires contiguous source data for the FIR kernel. */
        const int ny = (src->nblock == 1 && src->stride == (int)sizeof(double))
                           ? dsp_fir_run((const double *)(const void *)src->blk[0], need, p->h,
                                         p->ntaps, p->decim, p->fir_out)
                           : DSP_EUNSUPPORTED;
        if (ny < p->n)
            return (ny < 0) ? ny : DSP_ESHORT;
        dsp_src_flat(&filtered, p->fir_out, p->n);
        from = &filtered;
        /* Yield after filtering, the longest individual phase for a decimating plan. */
        dsp_do_yield(p);
    }
    rc = dsp_load_vec(from, p->n, &p->w_v, p->wsum, &p->re_v, &p->im_v, mean_out);
    if (rc != DSP_OK)
        return rc;
    dsp_do_yield(p);
    dsp_rfft(p);
    dsp_do_yield(p);
    dsp_power_vec(&p->re_v, &p->im_v, p->m, &p->utr_v, &p->uti_v, &p->pwr_v, p->ksq);
    return p->m;
}

int dsp_spectrum_run(dsp_plan *p, const double *DSP_RESTRICT src, const int nsrc,
                     double *mean_out) {
    dsp_src s;
    if (src == NULL)
        return DSP_EARG;
    dsp_src_flat(&s, src, (nsrc > 0) ? nsrc : 0);
    return dsp_spectrum_run_src(p, &s, nsrc, mean_out);
}

/* Interpolated amplitude corrects the scalloping loss in a raw peak bin. */
static double dsp_line_amp(const dsp_interp *ip, const dsp_vec *pwr, const int k,
                           const int nbins, const double p, double *d_out) {
    double amp = DSP_SQRT(p);
    if (d_out != NULL)
        *d_out = 0.0;
    if (ip != NULL) {
        double d = 0.0, a = 0.0;
        if (dsp_peak_interp_vec(ip, pwr, k, nbins, &d, &a) == DSP_OK && a > 0.0) {
            amp = a;
            if (d_out != NULL)
                *d_out = d;
        }
    }
    return amp;
}

/* Walk ascending line exclusions while summing bins below the noise clip. */
static void dsp_noise_pass(const dsp_vec *pwr, const int k0, const int k1,
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
        v = (double)DSP_AT(pwr, k);

        if (!(v >= 0.0) || !(v <= ceil_v))
            continue;
        sum += v;
        cnt++;
    }
    *sum_out = sum;
    *cnt_out = cnt;
}

/* Check level before testing whether a candidate is a mains harmonic. */
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
        /* Selecting one mains frequency leaves harmonics of the other eligible. */
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

int dsp_thd_noise_vec(const dsp_vec *pwr, const int nbins, int k0, int k1, int kdc,
                      const double binhz, const int mains, const dsp_interp *ip,
                      dsp_thdn *DSP_RESTRICT out) {
    int line[DSP_THD_HMAX + 1];
    int nline, kfloor, k, h, kf = -1, cnt = 0, skirt, nh = 0, stride;
    double pf = 0.0, vf, d0 = 0.0, fb = 0.0, hsum = 0.0, sum = 0.0;

    if (pwr == NULL || pwr->nslice < 1 || out == NULL)
        return DSP_EARG;
    /* Clear the outputs before validation so a refusal cannot leave stale figures. */
    memset(out, 0, sizeof(*out));
#if DSP_CHECK_OVERLAP
    /* Refuse aliasing between the results and input bins. */
    if (dsp_vec_hits(pwr, out, sizeof(*out)))
        return DSP_EARG;
#endif
    if (nbins < 8)
        return DSP_EARG;
    /* Reject unsupported mains settings rather than discounting the wrong bands. */
    if (mains != DSP_THD_MAINS_BOTH && mains != 0 && mains != DSP_THD_MAINS_A
        && mains != DSP_THD_MAINS_B)
        return DSP_EARG;

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
    /* Exclude each line's window-dependent main lobe from noise estimation. */
    skirt = (ip != NULL && ip->lobe > 0) ? ip->lobe + 1 : DSP_THD_SKIRT;

    /* Require a local maximum so a louder tone's shoulder cannot become the fundamental. */
    for (k = k0; k <= k1; k++) {
        const double v = (double)DSP_AT(pwr, k);
        double l, r;
        if (!(v > pf))
            continue;
        l = (k > 0) ? (double)DSP_AT(pwr, k - 1) : -1.0;
        r = (k + 1 < nbins) ? (double)DSP_AT(pwr, k + 1) : -1.0;
        if (!(v > l) || !(v >= r))
            continue;
        if (dsp_is_mains((double)k * binhz, v, binhz, mains))
            continue;
        pf = v;
        kf = k;
    }
    /* Without a fundamental only the noise floor is meaningful. */
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

        if (!(c + (double)DSP_THD_HALFW <= (double)k1))
            break;
        a = dsp_ifloor(c - (double)DSP_THD_HALFW + 0.5);
        b = dsp_ifloor(c + (double)DSP_THD_HALFW + 0.5);
        /* Clamp the candidate harmonic interval to valid bin indices before reading it. */
        if (a < k0)
            a = k0;
        if (b > k1)
            b = k1;
        for (k = a; k <= b; k++) {
            double v = (double)DSP_AT(pwr, k);
            if (v > bp) {
                bp = v;
                bk = k;
            }
        }
        if (bk < 0 || !(bp > 0.0))
            continue;
        /* Skip harmonics inside the prior line's skirt; they cannot be resolved as separate tones. */
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

    stride = (k1 - k0 + 1) / DSP_THD_NSAMPLE;
    if (stride < 1)
        stride = 1;
    dsp_noise_pass(pwr, k0, k1, line, nline, skirt, DBL_MAX, stride, &sum, &cnt);
    /* Re-estimate noise after clipping outliers. */
    for (h = 0; h < DSP_THD_CLIPS && cnt > 0 && sum > 0.0; h++) {
        double csum = 0.0;
        int ccnt = 0;
        dsp_noise_pass(pwr, k0, k1, line, nline, skirt,
                       (sum / (double)cnt) * DSP_THD_CLIP, stride, &csum, &ccnt);

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

        if (vf > 0.0 && vf * vf > mean * DSP_THD_MINRATIO) {
            out->signal = 1;
            /* Scale sampled noise by the stride to estimate integrated power; mean-square halves cancel in the ratio. */
            out->snr_db = 10.0 * DSP_LOG10((vf * vf) / (sum * (double)stride));
        }
    }
    if (out->signal != 0) {
        out->nharm = nh;
        if (nh > 0)
            out->thd = DSP_SQRT(hsum) / vf;
    }
    /* Publish ratios only when they are finite. */
    if (!dsp_finite(out->thd) || !dsp_finite(out->snr_db)) {
        out->thd = 0.0;
        out->snr_db = 0.0;
        out->signal = 0;
        out->nharm = 0;
    }

    if (!dsp_finite(out->f0) || !dsp_finite(out->f0_hz) || !dsp_finite(out->amp0)) {
        out->f0 = 0.0;
        out->f0_hz = 0.0;
        out->amp0 = 0.0;
    }
    return DSP_OK;
}

int dsp_thd_noise(const dsp_real *DSP_RESTRICT pwr, const int nbins, int k0, int k1, int kdc,
                  const double binhz, const int mains, const dsp_interp *ip,
                  dsp_thdn *DSP_RESTRICT out) {
    dsp_vec v;
    dsp_vec_flat_ro(&v, pwr, nbins);
    return dsp_thd_noise_vec(&v, nbins, k0, k1, kdc, binhz, mains, ip, out);
}
