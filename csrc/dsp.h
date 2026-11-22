/**
 * @file dsp.h
 * @brief Allocation-free DSP primitives for the DMM6500 family.
 * Bin indices are zero-based. Pointer arguments must not overlap unless explicitly allowed.
 * Public kernels use caller-owned storage.
 */
#ifndef DSP_H
#define DSP_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Element type for signal arrays, window samples and twiddles.
 * Single by default; define DSP_DOUBLE consistently in the library and its callers.
 */
#ifdef DSP_DOUBLE
typedef double dsp_real;
#else
typedef float dsp_real;
#endif

/**
 * @brief C99 restrict; empty in C++.
 * A restrict-qualified object must not also be accessed through another pointer in the call.
 */
#ifdef __cplusplus
#define DSP_RESTRICT
#elif defined(__STDC_VERSION__) && __STDC_VERSION__ >= 199901L
#define DSP_RESTRICT restrict
#else
#define DSP_RESTRICT
#endif

/** @brief Size of the library's dsp_real, in bytes, for caller ABI checks. */
extern const int dsp_real_size;

/**
 * @brief Required array and arena alignment in bytes.
 * Align to the target's cache-block width. Overallocate by DSP_ALIGN - 1 bytes if needed
 * when rounding an allocation up to that boundary.
 */
#define DSP_ALIGN 32

/** @brief Maximum slices one array may occupy in a segmented arena. */
#define DSP_MAX_SLICES 32

/**
 * @brief Array stored in power-of-two slices; only the last may be partial.
 * A contiguous array has one slice. Multislice indexing uses a shift and a mask.
 */
typedef struct {
    dsp_real *tab[DSP_MAX_SLICES];
    int       nslice;  /**< Slices in use; 1 when the array is contiguous. */
    int       sh;      /**< log2 of @c per. */
    int       mask;    /**< @c per less one. */
    int       per;     /**< Elements a slice holds. */
    int       len;     /**< Elements in the whole array. */
} dsp_vec;

/** @brief Maximum blocks in a strided source record. */
#define DSP_MAX_SRC_BLOCKS 32

/**
 * @brief Doubles in equal-sized, independently allocated blocks.
 * The reading starts at offset zero of each element. Supply a stride of at least
 * sizeof(double) and a multiple of four. The first block may start inside its payload;
 * the supplied pointer addresses its first sample. Each base is four-byte aligned, and
 * `nblock * per` must cover `len`.
 */
typedef struct {
    const unsigned char *blk[DSP_MAX_SRC_BLOCKS];
    int nblock;
    int per;    /**< Elements in each block; only the last may hold fewer. */
    int stride; /**< Bytes between elements, >= sizeof(double) and a multiple of 4. */
    int len;    /**< Elements in the record. */
} dsp_src;

/** @brief Element @p i of @p v. @p v is a `dsp_vec *`. */
#define DSP_AT(v, i)  ((v)->tab[(i) >> (v)->sh][(i) & (v)->mask])

/**
 * @brief Address of element @p i. At most `per - (i & mask)` elements are contiguous.
 */
#define DSP_ROW(v, i) (&DSP_AT(v, i))

/**
 * @brief Window kinds.
 * Rectangular is available in C but excluded from the app's peak picker because its
 * first null makes the three-bin estimate ill-conditioned.
 */
enum {
    DSP_WINDOW_RECT            = 0, /**< Flat. Present, not recommended; see above. */
    DSP_WINDOW_HANN            = 1, /**< 0.5 - 0.5 cos. */
    DSP_WINDOW_BLACKMAN        = 2, /**< 0.42, 0.5, 0.08. */
    DSP_WINDOW_BLACKMAN_HARRIS = 3, /**< Four-term. */
    DSP_WINDOW_KAISER          = 4, /**< Beta trades main-lobe width against sidelobes. */
    DSP_WINDOW_COUNT           = 5,
};

/**
 * @brief FFT decomposition, fixed by the plan's workspace.
 * Small transforms may fall back from four-step to radix-2; the bin order is unchanged.
 */
enum {
    /** Textbook in-place radix-2, bit-reversal from a precomputed swap list. */
    DSP_FFT_RADIX2   = 0,
    /** Four-step: sub-transforms that fit the cache, a blocked gather and a blocked transpose. */
    DSP_FFT_FOURSTEP = 1,
    DSP_FFT_COUNT    = 2,
};

/** @brief Decomposition to ask ::dsp_plan_init for; override with `-DDSP_FFT_DEFAULT=...`. */
#ifndef DSP_FFT_DEFAULT
#define DSP_FFT_DEFAULT DSP_FFT_FOURSTEP
#endif

/** @brief Return codes. Negative; everything else is a non-negative count. */
enum {
    DSP_OK           = 0,
    DSP_EARG         = -1, /**< Null pointer or a scalar out of range. */
    DSP_EPOW2        = -2, /**< Sample count is not a power of two, or is outside 4..::DSP_N_MAX. */
    DSP_ENOMEM       = -3, /**< The arena is smaller than ::dsp_plan_bytes asked for. */
    DSP_EUNSUPPORTED = -4, /**< The build does not support this setting. */
    DSP_ESHORT       = -5, /**< The source record is shorter than ::dsp_fir_srclength. */
    DSP_EBETA        = -6, /**< Kaiser beta outside ::DSP_KAISER_BETA_MIN..::DSP_KAISER_BETA_MAX. */
    DSP_EDECLINE     = -7, /**< No sub-bin estimate here; the caller reads the raw bin. */
    DSP_EALIGN       = -8, /**< The arena is not on a ::DSP_ALIGN boundary. */
    DSP_EZONE        = -9, /**< The band straddles a Nyquist zone of the decimated rate. */
    /** Plan invalidated by a settings change; reserved for the caller's lifecycle. */
    DSP_EDIRTY       = -10,
    /** A required workspace allocation cannot fit the arena segment layout. */
    DSP_ESEG         = -11,
};

/** @brief Set to 0 for low-pass only: nonzero low edges are refused. */
#ifndef DSP_BANDPASS
#define DSP_BANDPASS 1
#endif

/** @brief Set to 0 to omit overlap checks; non-overlap remains required. */
#ifndef DSP_CHECK_OVERLAP
#define DSP_CHECK_OVERLAP 1
#endif

/** @brief Maximum number of trace points ::dsp_reduce writes. */
#define DSP_NSEG_MAX 65536

/** @brief Maximum accepted sample count; bounds arena layout arithmetic on 32-bit targets. */
#define DSP_N_MAX 65536

/**
 * @name Interpolation grid
 * The gain grid must cover offsets through 1.5 bins.
 * @{
 */
#define DSP_GHX 0.025 /**< Gain table step, in bins. */
#define DSP_GN  60     /**< Gain table spans 0 to `DSP_GN * DSP_GHX` = 1.5 bins. */
#define DSP_DN  40     /**< Offset table nodes, spaced uniformly in the three-bin ratio. */
/** @} */

/**
 * @name DC exclusion
 * Withhold bins where weighted mean removal can change tone amplitude by more than 5%.
 * @{
 */
#define DSP_DCTOL 0.05
#define DSP_KDCN  6
/** @} */

/**
 * @brief Minimum Kaiser beta for sub-bin interpolation.
 * The first null must be beyond 1.5 bins; it lies at sqrt(1 + (beta/pi)^2).
 */
#define DSP_KAISER_BETA_MIN 3.5124

/** @brief Maximum Kaiser beta supported by the bounded I0 series. */
#define DSP_KAISER_BETA_MAX 200.0

/** @brief Maximum FIR tap count reserved by a plan. */
#define DSP_FIR_MAXTAPS 384

/** @brief Maximum readings the FIR planner requests, independent of tap count. */
#define DSP_FIR_MAXM 8192

/** @brief Maximum decimation accepted by a plan. */
#define DSP_DECIM_MAX 4096

/**
 * @brief Maximum record length ::dsp_fir_srclength can return.
 * The product is checked before it is formed in int arithmetic.
 */
#define DSP_SRC_MAX 1048576

/** @brief Hamming's transition constant: about `3.3/transition` taps for its stopband. */
#define DSP_FIR_TAPK 3.3

/** @brief Maximum peaks ranked in one pass; bounds stack scratch. */
#define DSP_PEAKS_MAX 64

/** @brief Columns gathered at once by four-step; eight floats fill one 32-byte cache block. */
#define DSP_FS_BLOCK 8

/**
 * @brief Minimum complex size for four-step.
 * Below this size the plan uses radix-2; both gather and scatter require full column blocks.
 */
#define DSP_FS_MIN 64

/**
 * @brief Map decimated bins into hertz as f0 + sense * k * binhz.
 * Odd Nyquist zones reverse the sense; an undecimated spectrum starts at zero.
 */
typedef struct {
    double f0;    /**< Hertz at bin 0. */
    double binhz; /**< Bin width in hertz, after decimation. */
    int    sense; /**< +1 if frequency rises with the bin index, -1 if it falls. */
    int    zone;  /**< Nyquist zone of the decimated rate; 0 means no fold. */
} dsp_bandmap;

/**
 * @brief Work out the bin-to-hertz map for a band at a decimation.
 *
 * @param      fs    Sample rate before decimation, Hz.
 * @param      flo   Band start, Hz; 0 for a low-pass.
 * @param      fhi   Band end, Hz. Above @p flo and not above `fs/2`.
 * @param      n     Sample count the transform runs on.
 * @param      decim Decimation, `1..DSP_DECIM_MAX`.
 * @param[out] out   Filled on ::DSP_OK, zeroed otherwise.
 * @return ::DSP_OK, ::DSP_EARG, ::DSP_EZONE when the band spans a zone boundary -- at
 * which point the decimation folds the band onto itself and no tap count helps --
 * or ::DSP_EUNSUPPORTED for a non-zero @p flo in a `DSP_BANDPASS=0` build.
 * ::dsp_fir_pick_decim only returns decimations for which this succeeds.
 */
int dsp_band_map(double fs, double flo, double fhi, int n, int decim, dsp_bandmap *out);

/**
 * @brief Hertz at bin @p k of a mapped spectrum.
 * @return The frequency, or 0 if @p m is NULL.
 */
double dsp_bin_hz(const dsp_bandmap *m, int k);

/**
 * @brief Bins of a mapped spectrum whose frequency lies inside `[flo, fhi]`.
 *
 * @param[in]  m      A map from ::dsp_band_map.
 * @param      flo    Low edge in hertz.
 * @param      fhi    High edge in hertz; must exceed @p flo.
 * @param      nbins  Bins available, usually ::dsp_plan::m.
 * @param[out] k0_out First bin, `0..nbins-1`.
 * @param[out] k1_out Last bin, `k0_out..nbins-1`.
 * @return ::DSP_OK, or ::DSP_EARG for a NULL argument, @p k0_out and @p k1_out being one
 * object, @p nbins below 1, a map with no bin width, a non-ascending band or a
 * non-finite edge. Both outputs are 0 on a refusal.
 * @note The window is never empty: a band narrower than one bin reports the single bin it
 * falls in, which is what every call taking `k0..k1` expects.
 */
int dsp_band_bins(const dsp_bandmap *m, double flo, double fhi, int nbins, int *k0_out,
                  int *k1_out);

/**
 * @brief Window response and its inverse three-bin offset table.
 * At offset d, the bins around the peak have gains G(d), G(1+d) and G(1-d).
 * Their ratio is inverted onto a uniform grid for constant-time interpolation.
 */
typedef struct {
    double  gtab[DSP_GN + 1]; /**< `G(j * DSP_GHX)`. */
    double  dtab[DSP_DN + 1]; /**< `d` at `r = m * dhr`. */
    double  dhr;              /**< `dtab` step in r; 0 means there is no usable table. */
    double  inv_dhr;          /**< `1/dhr`, so a lookup multiplies; 0 alongside `dhr` 0. */
    int     mono;             /**< `r(d)` rose all the way to half a bin. */
    int     lobe;             /**< Rounded main-lobe half-width; noise estimation excludes one extra bin on either side. */
} dsp_interp;

/** @brief Optional callback at frame phase boundaries, not inside an inner loop. */
typedef void (*dsp_yield_fn)(void *ctx);

/**
 * @brief Precomputed window, FFT and filter state backed by the caller's arena.
 * Modify it only through the plan API; workspace determines the effective FFT method.
 */
typedef struct {
    int        n;       /**< Samples: a power of two, at least 4. */
    int        m;       /**< `n/2`, the complex transform size and the number of bins. */
    int        kind;    /**< One of the `DSP_WINDOW_*` values. */
    int        decim;   /**< Decimation the FIR scratch was sized for; 1 means no filter. */
    int        method;  /**< Effective decomposition selected when the workspace is built. */
    double     beta;    /**< Kaiser only. */
    dsp_real  *w;       /**< Window, @c n entries. */
    double     wsum;    /**< Sum of the window; ::dsp_load weights the mean by it. */
    double     cg;      /**< Coherent gain, `wsum/n`. A window identity, not read per frame. */
    double     ksq;     /**< Power scale, `1/wsum^2`, applied to the untangled `|2X|^2`. */
    /* Workspaces used by only one decomposition are NULL for the other. */
    int       *swp_a;   /**< Bit-reversal swap pairs over `0..m-1`; ::DSP_FFT_RADIX2 only. */
    int       *swp_b;
    int        nswp;
    int       *sw1_a;   /**< Swap pairs over `0..m1-1`, for the four-step's column transforms. */
    int       *sw1_b;
    int        nsw1;
    int       *sw2_a;   /**< Swap pairs over `0..m2-1`, for its row transforms. */
    int       *sw2_b;
    int        nsw2;
    dsp_real  *twr;     /**< Butterfly twiddles, stage-major, `m-2` entries. */
    dsp_real  *twi;
    dsp_real  *utr;     /**< Untangle twiddles `exp(-2 pi i k / n)`, `k = 0..m-1`. */
    dsp_real  *uti;
    dsp_real  *re;      /**< Packed complex working array, @c m entries. */
    dsp_real  *im;
    dsp_real  *wkr;     /**< The four-step's intermediate matrix, `m` entries; NULL under
                             ::DSP_FFT_RADIX2, which is in place. */
    dsp_real  *wki;
    dsp_real  *blkr;    /**< Four-step gather block, `DSP_FS_BLOCK * m1` entries; else NULL. */
    dsp_real  *blki;
    dsp_real  *pwr;     /**< Power output, @c m entries, volts-squared peak. */
    dsp_real  *h;       /**< FIR taps, up to ::DSP_FIR_MAXTAPS; written by ::dsp_plan_set_fir. */
    int       ntaps;    /**< Taps in @c h; 0 when the filter is not in the path. */
    double    *fir_out; /**< @c n decimated samples; NULL when @c decim is 1. */
    int        m1;      /**< Four-step factors, `m1 * m2 == m`, `m1 <= m2`. */
    int        m2;
    /* Sliced views address the full arrays even when one segment cannot hold them. */
    dsp_vec    w_v;
    dsp_vec    twr_v;
    dsp_vec    twi_v;
    dsp_vec    utr_v;
    dsp_vec    uti_v;
    dsp_vec    re_v;
    dsp_vec    im_v;
    dsp_vec    wkr_v;
    dsp_vec    wki_v;
    dsp_vec    pwr_v;
    dsp_interp ip;
    int        kdc;     /**< Bins above DC the mean removal makes unreportable. */
    int        mono;    /**< Copy of `ip.mono`: the window has an invertible offset table. */
    dsp_yield_fn yield; /**< Called at the points ::dsp_plan_set_yield documents; NULL for
                             none. Set after ::dsp_plan_init, which zeroes the plan. */
    void      *yield_ctx;
} dsp_plan;

/**
 * @brief Bytes the arena needs for a configuration.
 *
 * @param n      Sample count; a power of two in `4..DSP_N_MAX`.
 * @param decim  Decimation the FIR output scratch must hold, `1..DSP_DECIM_MAX`; 1 for none.
 * @param method One of the `DSP_FFT_*` values.
 * @return Bytes required, or 0 for a configuration that would be refused.
 * @note The return value is the layout exactly, with no slack for a caller to align into;
 * see ::DSP_ALIGN for the idiom.
 */
size_t dsp_plan_bytes(int n, int decim, int method);

/**
 * @brief Build the window, the interpolation tables, the swap list and the twiddles.
 *
 * @param[out] p      Plan to fill; zeroed on refusal.
 * @param[in]  arena  Caller-owned scratch, retained by @p p for its lifetime.
 * @param      bytes  Size of @p arena.
 * @param      n      Sample count.
 * @param      kind   One of the `DSP_WINDOW_*` values.
 * @param      beta   Kaiser only; ignored otherwise.
 * @param      decim  Decimation to size the FIR output scratch for; 1 for none.
 * @param      method Requested `DSP_FFT_*` decomposition; read the effective one in @p p.
 * @return ::DSP_OK, ::DSP_EARG, ::DSP_EPOW2, ::DSP_ENOMEM, ::DSP_EALIGN or ::DSP_EBETA.
 *         With ::DSP_CHECK_OVERLAP, overlap between @p p and @p arena is ::DSP_EARG.
 * @pre @p n is a power of two in `4..DSP_N_MAX`, @p decim is in `1..DSP_DECIM_MAX`.
 * @pre @p arena is aligned to ::DSP_ALIGN and holds at least ::dsp_plan_bytes bytes.
 * @pre @p arena is reached through no other live pointer; the plan writes all of it.
 */
int dsp_plan_init(dsp_plan *p, void *arena, size_t bytes, int n, int kind, double beta, int decim,
                  int method);

/**
 * @brief Segments of @p seg_bytes the plan needs, including unused tails.
 *
 * @param n         Sample count; a power of two in `4..DSP_N_MAX`.
 * @param decim     Decimation the FIR output scratch must hold; 1 for none.
 * @param method    One of the `DSP_FFT_*` values.
 * @param seg_bytes Size of one segment; a multiple of ::DSP_ALIGN.
 * @return Segments required, or 0 if the configuration cannot fit, including radix-2
 *         with working arrays too large for one segment.
 */
int dsp_plan_segs(int n, int decim, int method, size_t seg_bytes);

/**
 * @brief ::dsp_plan_init over segments that are not adjacent.
 *
 * @param[out] p         Plan to fill; zeroed on refusal.
 * @param[in]  segs      @p nsegs aligned segment bases, each holding @p seg_bytes.
 *                       Keep the segment storage live for the plan's lifetime.
 * @param      nsegs     Segments available; at least ::dsp_plan_segs.
 * @param      seg_bytes Size of one segment; a multiple of ::DSP_ALIGN.
 * @param      n         Sample count.
 * @param      kind      One of the `DSP_WINDOW_*` values.
 * @param      beta      Kaiser only; ignored otherwise.
 * @param      decim     Decimation to size the FIR output scratch for; 1 for none.
 * @param      method    Decomposition to build for.
 * @return The codes from ::dsp_plan_init, or ::DSP_ESEG if the layout cannot fit the
 *         segment size. ::DSP_ENOMEM means there are too few segments.
 * @pre Segments are non-NULL, ::DSP_ALIGN-aligned and disjoint. Order and adjacency don't matter.
 */
int dsp_plan_init_segs(dsp_plan *p, void *const *segs, int nsegs, size_t seg_bytes, int n, int kind,
                       double beta, int decim, int method);

/**
 * @brief Install the filter taps, or clear the filter.
 *
 * @param[in,out] p     Plan from ::dsp_plan_init.
 * @param[in]     h     Taps from ::dsp_fir_design; may be NULL only if @p ntaps is zero.
 * @param         ntaps Tap count, `0..DSP_FIR_MAXTAPS`; 0 clears the filter.
 * @return @p ntaps installed, or ::DSP_EARG.
 * @pre Nonzero taps require a decimating plan, which has FIR output scratch.
 * @pre @p h does not point into @p p's arena.
 */
int dsp_plan_set_fir(dsp_plan *p, const dsp_real *h, int ntaps);

/**
 * @brief Install a yield callback, or clear it.
 *
 * @param[in,out] p   Plan from ::dsp_plan_init, which zeroes this, so install it afterwards.
 * @param         fn  Callback, or NULL to clear.
 * @param[in]     ctx Passed through untouched.
 * @return ::DSP_OK, or ::DSP_EARG for a null or unbuilt plan.
 * @warning The callback must not access the plan or reenter a frame: it runs between
 *          processing phases while the working arrays contain intermediate state.
 */
int dsp_plan_set_yield(dsp_plan *p, dsp_yield_fn fn, void *ctx);

/**
 * @brief Build a symmetric analysis window.
 *
 * @param[out] w    Window, @p n entries.
 * @param      n    Length, at least 2.
 * @param      kind One of the `DSP_WINDOW_*` values.
 * @param      beta Kaiser only.
 * @return ::DSP_OK, ::DSP_EARG for a null pointer or an unknown @p kind, or ::DSP_EBETA for
 * a Kaiser beta outside ::DSP_KAISER_BETA_MIN to ::DSP_KAISER_BETA_MAX. A NaN beta
 * is ::DSP_EBETA: the test is written as a positive, so a NaN fails it.
 * @pre @p w is reached through no other pointer during the call.
 */
int dsp_window(dsp_real *DSP_RESTRICT w, int n, int kind, double beta);

/**
 * @brief Design a decimating windowed-sinc band-pass or low-pass, Hamming-windowed.
 *
 * @param[out] h       Taps, up to @p maxtaps entries.
 * @param      maxtaps Ceiling, which is both @p h's length and the design's limit.
 * @param      fs      Sample rate before decimation, Hz.
 * @param      flo     Band start, Hz; 0 for low-pass. Nonzero requires ::DSP_BANDPASS.
 * @param      fhi     Band end, Hz. Above @p flo, not above `fs/2`.
 * @param      decim   Decimation; low-pass at 1 needs no filter, while band-pass still does.
 * @param      order   Requested taps, or 0 to derive from the transition. Round even counts
 *                     up to odd unless that exceeds @p maxtaps, then round down.
 * @return Tap count, 0 when no filter is needed, or ::DSP_EARG, ::DSP_EUNSUPPORTED or
 * ::DSP_EZONE.
 * @pre @p h is reached through no other pointer during the call.
 * @note Automatic taps size the alias transitions. Zone 0 has no lower alias edge;
 *       force @p order if the lower skirt needs more taps.
 */
int dsp_fir_design(dsp_real *DSP_RESTRICT h, int maxtaps, double fs, double flo, double fhi,
                   int decim, int order);

/**
 * @brief Run a decimating convolution.
 *
 * @param[in]  x     Source readings, @p nx of them.
 * @param      nx    Source length.
 * @param[in]  h     Taps from ::dsp_fir_design.
 * @param      ntaps Tap count.
 * @param      decim Decimation, at least 1.
 * @param[out] y     Outputs; needs `(nx - ntaps)/decim + 1` entries.
 * @return Outputs written, or ::DSP_EARG -- including for @p y and @p x being one pointer,
 * the in-place case, which is detected rather than left undefined.
 * @pre `nx >= ntaps`, and @p h holds @p ntaps entries.
 * @pre @p x, @p h and @p y do not overlap. In place is not supported: each output reads
 * @p ntaps inputs, which overlap the inputs of the outputs around it.
 */
int dsp_fir_run(const double *DSP_RESTRICT x, int nx, const dsp_real *DSP_RESTRICT h, int ntaps,
                int decim, double *DSP_RESTRICT y);

/**
 * @brief Window @p n samples, remove the window-weighted mean, pack into `n/2` complex.
 *
 * @param[in]  x        Source readings, @p n of them.
 * @param      n        Sample count; a power of two.
 * @param[in]  w        Window, @p n entries.
 * @param      wsum     Sum of @p w, from ::dsp_plan::wsum.
 * @param[out] re       Real parts, `n/2` entries.
 * @param[out] im       Imaginary parts, `n/2` entries.
 * @param[out] mean_out Weighted mean removed; may be NULL.
 * @return ::DSP_OK, ::DSP_EPOW2 for a sample count that is not a power of two in range, or
 * ::DSP_EARG for a null pointer, a @p wsum that is not positive, or -- under
 * ::DSP_CHECK_OVERLAP -- any two of these buffers sharing bytes.
 * @pre @p x, @p w, @p re and @p im do not overlap.
 */
int dsp_load(const double *DSP_RESTRICT x, int n, const dsp_real *DSP_RESTRICT w, double wsum,
             dsp_real *DSP_RESTRICT re, dsp_real *DSP_RESTRICT im, double *mean_out);

/**
 * @brief In-place complex FFT of `p->m` points on `p->re` and `p->im`.
 *
 * @param[in,out] p Plan whose `re`/`im` hold the packed input and receive the transform.
 * @pre @p p was built by ::dsp_plan_init. A plan it refused has `p->m == 0` and is ignored.
 */
void dsp_rfft(dsp_plan *p);

/**
 * @brief Untangle the half-size transform into @p m real-input bins and write their power.
 *
 * @param[in]  re    Real parts from ::dsp_rfft.
 * @param[in]  im    Imaginary parts.
 * @param      m     Complex transform size.
 * @param[in]  utr   Untangle twiddles, real part, from ::dsp_plan::utr.
 * @param[in]  uti   Imaginary part.
 * @param[out] pwr   Power, @p m entries, volts-squared peak.
 * @param      scale ::dsp_plan::ksq.
 * @pre @p m is a power of two and at least 2; @p utr and @p uti hold @p m entries each.
 * @pre @p pwr overlaps none of @p re, @p im, @p utr or @p uti. It is the same length as
 * @p re and the pass walks mirror pairs, so an in-place call would consume bins it has
 * already overwritten.
 */
void dsp_power(const dsp_real *DSP_RESTRICT re, const dsp_real *DSP_RESTRICT im, int m,
               const dsp_real *DSP_RESTRICT utr, const dsp_real *DSP_RESTRICT uti,
               dsp_real *DSP_RESTRICT pwr, double scale);

/**
 * @brief Reduce bins `k0..k1` to @p nseg trace points in dB and hertz.
 * Each segment keeps its maximum power but reports its own frequency, not the winning
 * bin's. Output frequencies always ascend, including when the map reverses the bins.
 *
 * @param[in]  pwr    Power bins.
 * @param      nbins  Total bins in @p pwr.
 * @param      k0     First bin, inclusive.
 * @param      k1     Last bin, inclusive; clamped to `nbins - 1`.
 * @param      nseg   Trace points to write, `1..DSP_NSEG_MAX`.
 * @param[in]  map    Bin-to-hertz map from ::dsp_band_map. For an undecimated spectrum that
 * is `{0, dsp_binwidth(...), 1, 0}`, which is the plain `k * binwidth`.
 * @param      dbmin  Floor; a bin at or below `vfloor^2` plots here. Finite, below @p dbmax.
 * @param      dbmax  Ceiling. Finite.
 * @param      vfloor Floor in volts, squared internally so the logarithm never sees zero.
 * Finite and not negative.
 * @param[out] db     dB values, @p nseg entries.
 * @param[out] hz     Segment frequencies, @p nseg entries, ascending.
 * @return @p nseg, or ::DSP_EARG -- which under ::DSP_CHECK_OVERLAP includes @p db, @p hz
 * and @p pwr sharing bytes with one another.
 * @pre `nbins >= 1`, `0 <= k0 < nbins`, `k0 <= k1`, `map->binhz > 0` and `map->sense` is
 * either 1 or -1.
 * @pre Map and dB limits are finite; every plotted frequency fits in dsp_real.
 * @pre @p db and @p hz overlap neither each other nor @p pwr.
 * @note NaN bins do not participate in the segment maximum.
 */
int dsp_reduce(const dsp_real *DSP_RESTRICT pwr, int nbins, int k0, int k1, int nseg,
               const dsp_bandmap *map, double dbmin, double dbmax, double vfloor,
               dsp_real *DSP_RESTRICT db, dsp_real *DSP_RESTRICT hz);

/**
 * @brief Find the strongest local maxima of @p pwr over bins `k0..k1`, strongest first.
 * Exclude DC and @p kdc bins above it. Reject a first eligible peak whose fitted offset
 * lies a quarter bin or more below its center, where DC leakage can mimic a peak.
 *
 * @param[in]  pwr   Power bins.
 * @param      nbins Total bins in @p pwr.
 * @param      k0    First bin to search, raised to `1 + kdc` if lower.
 * @param      k1    Last bin to search, clamped to `nbins - 1`.
 * @param      kdc   ::dsp_plan::kdc.
 * @param      want  Peaks to rank, at most ::DSP_PEAKS_MAX.
 * @param[in]  ip    Interpolation tables; may be NULL, which skips the leak refusal.
 * @param[out] bin   Bin indices, @p want entries; -1 beyond the count returned.
 * @param[out] frac  Sub-bin offsets, 0 where the estimate declined. May be NULL.
 * @param[out] amp   Interpolated amplitudes in volts, falling back to `sqrt(pwr[bin])`
 * where the estimate declined. May be NULL.
 * @return Peaks found, or ::DSP_EARG -- which under ::DSP_CHECK_OVERLAP includes @p bin,
 * @p frac, @p amp and @p pwr sharing bytes with one another.
 * @pre @p pwr holds @p nbins entries; @p bin, @p frac and @p amp hold @p want each.
 * @pre @p bin, @p frac and @p amp overlap neither each other nor @p pwr.
 * @note A NaN bin is never reported: every comparison with a NaN is false, so it fails both
 * halves of the local-maximum test and so does each of its neighbours.
 */
int dsp_peaks(const dsp_real *DSP_RESTRICT pwr, int nbins, int k0, int k1, int kdc, int want,
              const dsp_interp *ip, int *DSP_RESTRICT bin, dsp_real *DSP_RESTRICT frac,
              dsp_real *DSP_RESTRICT amp);

/**
 * @brief Scalloping loss at sub-bin offset @p d: the factor an amplitude reads low by.
 * @param[in] ip Interpolation tables.
 * @param     d  Offset in bins. Even in @p d; `G(0)` is 1; clamped past 1.5 bins.
 * @return The factor, or 1 if @p ip is NULL.
 * @note NaN and out-of-range offsets clamp before integer indexing.
 */
double dsp_win_gain(const dsp_interp *ip, double d);

/**
 * @brief Invert the three-bin ratio to a sub-bin offset.
 *
 * @param[in]  ip    Interpolation tables.
 * @param      r     `(R-L)/(L+2C+R)`.
 * @param[out] d_out Offset in `-0.5..0.5`; untouched unless ::DSP_OK is returned.
 * @return ::DSP_OK, ::DSP_EARG, or ::DSP_EDECLINE when the window has no invertible table.
 * @note A NaN @p r saturates like any ratio past the end of the table, for the reason in
 * ::dsp_win_gain, so @p d_out is always finite on ::DSP_OK. A NaN there would reach an
 * amplitude, and a non-finite reading is a modal dialog on the instrument.
 */
int dsp_win_offset(const dsp_interp *ip, double r, double *d_out);

/**
 * @brief Sub-bin peak estimate from bin @p k and its two neighbours.
 *
 * @param[in]  ip      Interpolation tables.
 * @param[in]  pwr     Power bins.
 * @param      k       Peak bin.
 * @param      nbins   Total bins in @p pwr.
 * @param[out] d_out   Offset in `-0.5..0.5`; may be NULL.
 * @param[out] amp_out Amplitude in volts; may be NULL.
 * @return ::DSP_OK, ::DSP_EARG for a NULL @p ip or @p pwr or for @p d_out and @p amp_out
 * being one object, or ::DSP_EDECLINE at a spectrum edge, on a non-positive peak
 * bin, or with no usable table. Neither output is written on a decline.
 * @pre @p pwr holds @p nbins entries, and @p ip was built for the window that produced them.
 */
int dsp_peak_interp(const dsp_interp *ip, const dsp_real *DSP_RESTRICT pwr, int k, int nbins,
                    double *d_out, double *amp_out);

/**
 * @brief Narrowest transition the decimation leaves, as a fraction of the sample rate.
 *
 * @return The fraction; zero means there is no usable transition -- the band does not fit
 * inside one zone, touches a zone edge, or the arguments are refused.
 */
double dsp_fir_transition(double fs, double flo, double fhi, int decim);

/**
 * @brief Taps a decimation's transition needs, odd so the group delay is a whole sample.
 *
 * @return The tap count, or 0 when the transition needs more than @p maxtaps or does not
 * exist.
 */
int dsp_fir_taps_for(double fs, double flo, double fhi, int decim, int maxtaps);

/**
 * @brief Largest decimation fitting one Nyquist zone, tap capacity and source-read budget.
 *
 * @return The decimation, or 1 when there is no room, which is not an error.
 */
int dsp_fir_pick_decim(double fs, double flo, double fhi, int n, int maxtaps);

/**
 * @brief A short, fixed message for a return code.
 *
 * @param code Any ::DSP_OK or `DSP_E*` value.
 * @return A string literal, never NULL, never longer than 31 characters. Unknown codes give
 * "unknown error", so the caller needs no range test of its own.
 */
const char *dsp_strerror(int code);

/**
 * @brief Readings the capture must hold for one record.
 *
 * @p n when the filter is not decimating, `(n-1)*decim + ntaps` when it is. A shorter
 * capture is refused rather than zero-padded: padding the tail gives a convincing and false
 * broadband spectrum, and a trigger timeout is the ordinary way a capture comes up short.
 *
 * @return The length, or 0 for bad arguments or a record past ::DSP_SRC_MAX.
 */
int dsp_fir_srclength(int n, int decim, int ntaps);

/** @brief Bin width in Hz after decimation, from the rate actually delivered. */
double dsp_binwidth(double fs, int n, int decim);

/**
 * @brief One frame: filter if the plan has taps, then load, transform and power.
 *
 * @param[in,out] p        Plan; receives the spectrum in `p->pwr`.
 * @param[in]     src      Capture readings.
 * @param         nsrc     Readings available.
 * @param[out]    mean_out Weighted mean removed; may be NULL.
 * @return Bins written (`p->m`), or ::DSP_EARG, or ::DSP_ESHORT when @p nsrc is below
 * ::dsp_fir_srclength, in which case `p->pwr` is untouched so the previous spectrum
 * stays on screen.
 * @pre @p src overlaps nothing in @p p's arena.
 * @note ::DSP_EARG covers a plan whose filter cannot run the configuration it describes: a
 * @c ntaps outside `0..DSP_FIR_MAXTAPS`, or a `decim > 1` with no taps. Running the
 * second unfiltered would leave every frequency wrong by the decimation factor, since
 * ::dsp_binwidth still reports the decimated width, so it is refused.
 */
int dsp_spectrum_run(dsp_plan *p, const double *DSP_RESTRICT src, int nsrc, double *mean_out);

/**
 * @brief ::dsp_spectrum_run over a strided or multi-block record.
 * A decimating plan still requires a contiguous array of doubles for its FIR.
 */
int dsp_spectrum_run_src(dsp_plan *p, const dsp_src *src, int nsrc, double *mean_out);

#define DSP_THD_HMAX  20 /**< Harmonics ::dsp_thd_noise considers at most. */
#define DSP_THD_HALFW 2  /**< Bins either side of a predicted harmonic searched for it. */
#define DSP_THD_SKIRT 3  /**< Fallback skirt where ::dsp_interp::lobe is unavailable. */
/** @brief Minimum fundamental-to-per-bin-noise power ratio (45 dB). */
#define DSP_THD_MINRATIO 31623.0

/** @brief Reject noise bins above this multiple of the mean before recomputing it. */
#define DSP_THD_CLIP 4.0

/** @brief Supported mains frequencies for the line-rejection rule. */
#define DSP_THD_MAINS_A 50
#define DSP_THD_MAINS_B 60
/** @brief Reject multiples of both supported mains frequencies. */
#define DSP_THD_MAINS_BOTH (-1)
/** Power at which a mains multiple stops being pickup and counts as a tone: -22 dBV. */
#define DSP_THD_MAINS_PWR 0.0063096
/** Above this frequency a tone on a mains multiple is taken at face value. */
#define DSP_THD_MAINS_FMAX 1000.0

/** @brief Target number of sampled noise bins; limits work per clip pass. */
#define DSP_THD_NSAMPLE 1024
/** @brief Maximum clip passes; stop earlier if no bins are removed. */
#define DSP_THD_CLIPS 6

/** @brief Distortion and noise results with separate signal and bin counts for validity. */
typedef struct {
    double thd;      /**< Harmonic distortion as a fraction, not a percent; valid when harmonics are present. */
    double snr_db;   /**< Fundamental over integrated non-harmonic power in dB; valid for a detected signal. */
    double noise_db; /**< Mean non-line bin power in dBV; valid when nnoise is nonzero. */
    double f0;       /**< Strongest bin's position in bins, fractional, @c signal or not. */
    double f0_hz;    /**< The same in hertz, or 0 where @p binhz was not supplied. */
    double amp0;     /**< Strongest bin's amplitude in volts, @c signal or not. */
    int    signal;   /**< Nonzero where the strongest bin cleared ::DSP_THD_MINRATIO times
                          the per-bin noise mean, so it is a tone and not a noise peak. */
    int    nharm;    /**< Harmonics found inside the window; 0 unless @c signal is set. */
    int    nnoise;   /**< Bins that went into the noise figures: SAMPLED bins, so the
                          bandwidth @c snr_db is referenced to is `nnoise * stride`. */
    int    stride;   /**< Sample every stride-th bin; integrated noise scales by nnoise * stride. */
} dsp_thdn;

/**
 * @brief Measure harmonic distortion and noise over bins `k0..k1` of @p pwr.
 * Use the strongest eligible local maximum as the fundamental. At each harmonic, keep
 * the largest bin near the prediction outside the preceding line's skirt. The noise
 * floor averages non-line bin power after clipping; S/N uses integrated noise.
 *
 * @param[in]  pwr   Power bins, as ::dsp_plan::pwr holds them.
 * @param      nbins Total bins in @p pwr.
 * @param      k0    First bin, raised to `1 + kdc` if lower.
 * @param      k1    Last bin, clamped to `nbins - 1`.
 * @param      kdc   ::dsp_plan::kdc.
 * @param      binhz Bin width in hertz; zero disables mains rejection.
 * @param      mains One of the `DSP_THD_MAINS_*` selections, or 0 to keep mains lines.
 *                   Reject only lines within the configured frequency and power limits.
 * @param[in]  ip    Interpolation tables; NULL falls back to `sqrt(pwr[k])` per line.
 * @param[out] out   Zeroed, then filled. See ::dsp_thdn for which fields are valid.
 * @return ::DSP_OK, or ::DSP_EARG for a null argument, fewer than eight bins in @p pwr,
 * a window narrower than five bins, an unknown @p mains, or -- under
 * ::DSP_CHECK_OVERLAP -- an @p out that shares bytes with @p pwr.
 * @pre @p pwr holds @p nbins entries and does not overlap @p out.
 * @note NaN bins are excluded from the fundamental and noise sum.
 */
int dsp_thd_noise(const dsp_real *DSP_RESTRICT pwr, int nbins, int k0, int k1, int kdc,
                  double binhz, int mains, const dsp_interp *ip,
                  dsp_thdn *DSP_RESTRICT out);

/**
 * @brief Half-width of the window's main lobe, in bins, rounded up to its first null.
 *
 * @param kind One of the `DSP_WINDOW_*` values.
 * @param beta Kaiser only; ignored otherwise.
 * @return The half-width in bins, at least 2, or 0 for an unknown @p kind.
 * @note The noise exclusion uses this width plus one bin. Sidelobe energy still counts.
 */
int dsp_window_lobe(int kind, double beta);

/**
 * @name Split-array power-spectrum readers
 * The *_vec variants read the same bins and contracts through a possibly sliced dsp_vec.
 * @{
 */
int dsp_reduce_vec(const dsp_vec *pwr, int nbins, int k0, int k1, int nseg,
                   const dsp_bandmap *map, double dbmin, double dbmax, double vfloor,
                   dsp_real *DSP_RESTRICT db, dsp_real *DSP_RESTRICT hz);
int dsp_peaks_vec(const dsp_vec *pwr, int nbins, int k0, int k1, int kdc, int want,
                  const dsp_interp *ip, int *DSP_RESTRICT bin, dsp_real *DSP_RESTRICT frac,
                  dsp_real *DSP_RESTRICT amp);
int dsp_thd_noise_vec(const dsp_vec *pwr, int nbins, int k0, int k1, int kdc, double binhz,
                      int mains, const dsp_interp *ip, dsp_thdn *DSP_RESTRICT out);
int dsp_peak_interp_vec(const dsp_interp *ip, const dsp_vec *pwr, int k, int nbins,
                        double *d_out, double *amp_out);
/** @} */

#ifdef __cplusplus
}
#endif

#endif /* DSP_H */
