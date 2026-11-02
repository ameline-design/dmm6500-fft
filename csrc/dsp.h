/**
 * @file dsp.h
 * @brief Native signal-processing primitives for the DMM6500 family.
 *
 * A C translation of the TSP spectrum analyser's arithmetic: analysis windows and their
 * sub-bin interpolation tables, a decimating windowed-sinc FIR, a real-input FFT by the
 * half-length complex method, a power spectrum, a segment reduction for a graph trace and
 * a peak search. `tsp/fft_core.tsp`, `tsp/spectrum_ui.tsp` and `tsp/spectrum_graph.tsp`
 * are the working original; `csrc/README.md` records what differs and why.
 *
 * Strict C99. No allocation, no file-scope mutable state, and no libc beyond
 * `<float.h>`, `<limits.h>`, `<math.h>`, `<stdint.h>` and `<string.h>` -- the last four of
 * which freestanding C99 provides. The caller owns one ::dsp_plan and one arena; everything
 * loop-invariant is built into the arena once by ::dsp_plan_init, and nothing below it
 * allocates, so a frame cannot fail on memory.
 *
 * Bin indices are 0-based here and 1-based in the Lua: bin @e k is the frequency
 * `k * binwidth`.
 *
 * No two pointer arguments to any function here may overlap, whether or not the parameter
 * carries ::DSP_RESTRICT; overlap is undefined behaviour. A function that permits it has to
 * say so in its own `@pre`, and none does. Stated once so that a function without an
 * aliasing line is refusing overlap rather than allowing it.
 */
#ifndef DSP_H
#define DSP_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Element type for the signal arrays, the window and the twiddles.
 *
 * Single by default. The e300c4's FPU holds a single-precision multiply-add array that
 * issues and completes one multiply-add a cycle, so single is the arithmetic fast path as
 * well as the bandwidth one. Define `DSP_DOUBLE` to build the same code in double; the
 * test suite passes in both, so the precision question can be answered by measurement. The
 * interpolation tables are `double` either way -- there are 102 of them and the inversion
 * differences two nearly equal gains.
 */
#ifdef DSP_DOUBLE
typedef double dsp_real;
#else
typedef float dsp_real;
#endif

/**
 * @brief `restrict` where the compiler has it; nothing in C++, which has no such keyword.
 *
 * Every parameter carrying it is a promise by the caller that the object it points at is
 * reached through no other pointer for the duration of the call, and breaking that promise
 * is undefined behaviour whether or not the keyword survived preprocessing. The C++ build
 * erases it, so a suite written only in C++ cannot compile the arithmetic the way the target
 * will; `test/dsp_c99_test.c` is compiled as C99 for that reason. The file-level no-overlap
 * rule binds every pointer parameter; this marks the ones the compiler is told about too.
 */
#ifdef __cplusplus
#define DSP_RESTRICT
#elif defined(__STDC_VERSION__) && __STDC_VERSION__ >= 199901L
#define DSP_RESTRICT restrict
#else
#define DSP_RESTRICT
#endif

/**
 * @brief `sizeof(dsp_real)` as the library was compiled, for an ABI check at link time.
 *
 * ::DSP_DOUBLE changes the element type of every array in the interface, so a caller that
 * includes this header without it and links a library built with it gets a clean link and
 * misreads every stride. Compare this against `sizeof(dsp_real)` once at start-up.
 */
extern const int dsp_real_size;

/**
 * @brief Alignment every caller-provided array and the arena must satisfy, in bytes.
 *
 * The e300c4's data cache has 32-byte blocks. A misaligned array splits the eight-column
 * gather block the four-step transform relies on across two cache blocks and doubles its
 * fills, so ::dsp_plan_init refuses an arena off a block boundary rather than running
 * slowly and silently.
 *
 * C99 has no `alignas`, and ::dsp_plan_bytes returns the layout exactly, with no slack for a
 * caller to round into. So over-allocate by one block and round up:
 * @code
 * size_t want = dsp_plan_bytes(n, decim, method);
 * unsigned char *raw = malloc(want + DSP_ALIGN - 1);
 * unsigned char *arena = raw + ((DSP_ALIGN - ((uintptr_t)raw & (DSP_ALIGN - 1))) & (DSP_ALIGN - 1));
 * dsp_plan_init(&p, arena, want, n, kind, beta, decim, method);
 * @endcode
 * A static arena needs the same treatment unless the toolchain offers an alignment
 * attribute; `malloc` guarantees 16 bytes on the hosts this is tested on, not 32.
 */
#define DSP_ALIGN 32

/**
 * @brief Slices one array may be cut into when no segment will hold it whole.
 *
 * Thirty-two is what `n = 16,384` needs in double precision against the instrument's
 * 32,736-byte segment: the window is `n` entries and the slice holds 512, so it is exactly
 * at this bound and `n = 32,768` is refused with ::DSP_ESEG rather than silently truncated.
 */
#define DSP_MAX_SLICES 32

/**
 * @brief An array the arena may have had to split across segments.
 *
 * A contiguous array is one slice, and ::DSP_AT is then `tab[0][i]` -- the indexing it
 * always was, which is why the contiguous suite covers this type. An array longer than a
 * segment is cut into slices of @c per elements, each whole inside one segment, so an index
 * splits with a shift and a mask rather than a divide.
 *
 * @c per is a power of two and a multiple of every row length the transform addresses.
 * `m1`, `m2` and ::DSP_FS_BLOCK are all powers of two, so @c per being at least the largest
 * of them is enough, and that is what lets the kernels go on taking a row base pointer and
 * a contiguous run: no inner loop learns about slices.
 *
 * @c per is a capacity, not a length. An array whose length is not a power of two -- the
 * twiddle tables at `m-2` -- rounds @c per up, so the unused tail of the last slice is
 * never addressed.
 */
typedef struct {
    dsp_real *tab[DSP_MAX_SLICES];
    int       nslice;  /**< Slices in use; 1 when the array is contiguous. */
    int       sh;      /**< log2 of @c per. */
    int       mask;    /**< @c per less one. */
    int       per;     /**< Elements a slice holds. */
    int       len;     /**< Elements in the whole array. */
} dsp_vec;

/**
 * @brief Blocks a strided source record may be spread over.
 *
 * Thirty-two covers `n = 16,384` from a reading buffer of 24-byte elements, which holds 1365
 * to a 32,768-byte chunk and so needs thirteen.
 */
#define DSP_MAX_SRC_BLOCKS 32

/**
 * @brief A record of doubles the caller holds as strided elements in equal-sized blocks.
 *
 * The instrument's capture is a reading buffer: fixed-size elements with the reading at
 * offset zero, packed into chunks of a fixed payload, so a record longer than one chunk is
 * this rather than an array. Reading it in place is what removes the de-strided copy -- @c n
 * doubles, 131 kB at 16,384 samples and longer than any segment -- from the frame entirely.
 *
 * @c nblock 1 with @c stride `sizeof(double)` is a plain array, which is what the entry
 * points taking one build. @c stride must be a multiple of 8: the elements are then as
 * aligned as the block base and a `double` load is safe, which a 4-aligned stride would not
 * make it.
 */
typedef struct {
    const unsigned char *blk[DSP_MAX_SRC_BLOCKS];
    int nblock;
    int per;    /**< Elements in each block; only the last may hold fewer. */
    int stride; /**< Bytes between elements, a multiple of 8. */
    int len;    /**< Elements in the record. */
} dsp_src;

/** @brief Element @p i of @p v. @p v is a `dsp_vec *`. */
#define DSP_AT(v, i)  ((v)->tab[(i) >> (v)->sh][(i) & (v)->mask])

/**
 * @brief Address of element @p i, for a run that stays inside one slice.
 *
 * Valid for @c per elements less the offset within the slice. Every caller here passes a
 * row base whose length divides @c per.
 */
#define DSP_ROW(v, i) (&DSP_AT(v, i))

/**
 * @brief Analysis windows.
 *
 * ::DSP_WINDOW_RECT is here because the proposal's enum lists it; the shipped Lua refuses
 * it. Its transform is exactly zero one bin from the peak, so the three-bin ratio leaves
 * the origin as `d^2` rather than as `d` and recovers an offset five orders worse than
 * Hann. Hamming is absent: it exits the app on the instrument, and Kaiser at beta 6 covers
 * it to within a dB of sidelobe level.
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
 * @brief FFT decomposition. Both produce the same bins to rounding.
 *
 * Chosen when the plan is built, because the arena is sized for the one that will run rather
 * than for both: the extras are disjoint -- radix-2 wants a bit-reversal swap list over `m`,
 * the four-step an `m`-point intermediate matrix plus a gather block and two smaller swap
 * lists -- so sizing for the union carried whichever was not going to be used. Benchmark them
 * by building a plan each. `csrc/README.md` gives the host timings and the modelled cache
 * traffic that decide between them.
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
    DSP_EUNSUPPORTED = -4, /**< A setting the reference implementation does not define. */
    DSP_ESHORT       = -5, /**< The source record is shorter than ::dsp_fir_srclength. */
    DSP_EBETA        = -6, /**< Kaiser beta outside ::DSP_KAISER_BETA_MIN..::DSP_KAISER_BETA_MAX. */
    DSP_EDECLINE     = -7, /**< No sub-bin estimate here; the caller reads the raw bin. */
    DSP_EALIGN       = -8, /**< The arena is not on a ::DSP_ALIGN boundary. */
    DSP_EZONE        = -9, /**< The band straddles a Nyquist zone of the decimated rate. */
    /** A setting moved since the plan was built; rebuild it. Returned by no function here:
     the plan is a struct this library never sees change, so the dirty state belongs to the
     layer that owns the attributes -- the TSP surface in `docs/NATIVE-DSP-PROPOSAL.md`,
     whose `spectrum` refuses with it. Defined here so both sides name one code. */
    DSP_EDIRTY       = -10,
    /** No segment can hold one of the arrays. Only ::dsp_plan_init_segs returns it: the
     arrays are each laid out whole, so the largest of them -- the window, @c n entries --
     has to fit a single segment. See ::dsp_plan_segs for the resulting bound on @c n. */
    DSP_ESEG         = -11,
};

/**
 * @brief Whether the band-pass arithmetic is compiled in. Define as 0 for a low-pass build.
 *
 * A low-pass build refuses a non-zero `flo` with ::DSP_EUNSUPPORTED and drops the
 * passband-centre normalisation, which is the only arithmetic it removes: the
 * difference-of-sincs kernel and the Nyquist-zone search are compiled either way, since at
 * `flo` of 0 the lower sinc term is zero and the zone is always 0. The
 * interface is the same either way, so a caller compiles against one header; `csrc/README.md`
 * records what the band-pass costs in bytes on the target.
 */
#ifndef DSP_BANDPASS
#define DSP_BANDPASS 1
#endif

/**
 * @brief Whether the buffer-overlap checks are compiled in. Define as 0 to drop them.
 *
 * The file-level rule refusing overlap holds either way: with this at 0 a caller that breaks
 * it gets undefined behaviour, and with it at 1 the pairs whose extents are both known from
 * the arguments get ::DSP_EARG instead. The cost is a few integer comparisons at an entry
 * point and nothing inside any loop, so a frame does not notice it; what it costs is code,
 * which is why it is a switch. `csrc/README.md` records the bytes on the target.
 *
 * The ::dsp_power overlap cannot be reported whatever this is set to, since that function
 * returns void.
 */
#ifndef DSP_CHECK_OVERLAP
#define DSP_CHECK_OVERLAP 1
#endif

/**
 * @brief Most trace points ::dsp_reduce will write.
 *
 * A trace with more points than the display has pixels is not a picture of anything, and the
 * bound is what lets the segment arithmetic stay in `int`: the running remainder is below
 * `nseg`, so a ceiling here is what keeps `remainder + npts % nseg` from overflowing.
 */
#define DSP_NSEG_MAX 65536

/**
 * @brief Largest sample count a plan will accept.
 *
 * A ceiling is necessary, not tidiness: the layout walk accumulates in `size_t`, which is 32
 * bits on the target. At @c n of 2^30 a single-precision four-step plan's arrays total
 * 23,623,566,976 bytes; that wraps, and ::dsp_plan_bytes reports 2,148,730,496 -- an
 * under-report of 21.5 GB, for a plan that would write every byte of it. 65,536 gives 32,768
 * bins -- twice the count the application uses -- for 1,453,184 bytes in single and twice
 * that in double, and leaves the walk four orders inside the wrap.
 */
#define DSP_N_MAX 65536

/** @name Interpolation grid
 * The shipped values. ::dsp_plan_init refuses a combination whose gain table cannot reach
 * 1.5 bins, because the inversion would read past its end.
 * @{ */
#define DSP_GHX 0.025 /**< Gain table step, in bins. */
#define DSP_GN  60     /**< Gain table spans 0 to `DSP_GN * DSP_GHX` = 1.5 bins. */
#define DSP_DN  40     /**< Offset table nodes, spaced uniformly in the three-bin ratio. */
/** @} */

/** @name DC region
 * How far above DC the mean removal in ::dsp_load makes a bin unreportable: 5 % of
 * amplitude, 0.45 dB. The scan reaches 6 bins, which covers Kaiser beta 18's 5.82-bin main
 * lobe.
 * @{ */
#define DSP_DCTOL 0.05
#define DSP_KDCN  6
/** @} */

/**
 * @brief Lowest Kaiser beta the sub-bin interpolation can use.
 *
 * Kaiser's first null sits at `sqrt(1 + (beta/pi)^2)` bins and has to stay outside 1.5 bins
 * for the three-bin ratio to read main lobe rather than sidelobe, which puts the floor at
 * `pi*sqrt(1.25)`. The Lua ships a fixed list whose lowest entry is 4 for the same reason.
 */
#define DSP_KAISER_BETA_MIN 3.5124

/**
 * @brief Highest Kaiser beta the Bessel series is accurate over.
 *
 * The I0 power series has term ratio `(beta/2)^2/k^2`, so it rises until `k` passes `beta/2`
 * and only then converges; a term cap below that truncates it mid-rise. Against a 400-term
 * long-double reference the 200-term cap is exact through beta 200, where the convergence
 * test stops it at 166 terms. The ceiling is needed because truncation is silent: the
 * amplitudes self-correct from the stored window sum, so the only symptom is sidelobes unlike
 * the ones beta promised. A 40-term cap is 3.6e-15 off at beta 30, 2.0e-05 at beta 50 and
 * wrong by 0.43 at the window centre at beta 80.
 */
#define DSP_KAISER_BETA_MAX 200.0

/**
 * @brief The Kaiser betas that are tested and supported.
 *
 * `4, 6, 9, 12, 15, 18`. The range above is what the Bessel series and the interpolation
 * tables can carry; this list is what is exercised, on both sides of the API. The TSP
 * implementation holds window tables for exactly these and refuses ::DSP_EBETA for anything
 * else, so a beta outside the list is accepted here and rejected there -- the conformance
 * harness keeps a case for that difference rather than letting it be rediscovered.
 *
 * A caller wanting another beta is asking for an untested configuration, not a refused one.
 */
#define DSP_KAISER_BETA_SUPPORTED "4, 6, 9, 12, 15, 18"

/**
 * @brief Longest filter a plan reserves room for, and the proposal's order ceiling.
 *
 * The Lua's own ceiling is 65, because `n*taps` multiply-accumulates land in an interpreted
 * frame. That does not apply here: 384 taps at 32,768 outputs is 12.6 M multiply-adds, or
 * 31 ms at 400 MHz. The ceiling governing a *design* is passed in rather than taken from
 * here, so a caller reproducing the Lua's choices passes 65 and gets the Lua's answers.
 */
#define DSP_FIR_MAXTAPS 384

/**
 * @brief Ceiling on the record the filter consumes, in readings.
 *
 * It bounds acquisition, not arithmetic. ::dsp_fir_pick_decim offers at most
 * `(DSP_FIR_MAXM - maxtaps)/(n - 1)`, so this decides how long a record a decimating plan
 * asks the digitizer for: `M/fs` seconds, 8.2 ms at 1 MS/s here.
 *
 * It does not bound the filter's cost, and `test/dsp_firbench.c` is why that is measured
 * rather than assumed. Over M from 1,067 to 524,607 the cost an output does not move: 0.23 ns
 * a multiply-add on the host, a function of the tap count alone, because the output count is
 * `n` whatever the decimation. 45 taps cost 9 ns an output and 383 cost 88. ::DSP_FIR_MAXTAPS
 * is what bounds the arithmetic, and a decimation reaches that through the transition width
 * rather than through the record length.
 *
 * What a record costs is measured, on a DMM6500 at an aperture of 1 us: the wall time of a
 * capture is `max(M/fs, M * 10.36 us)`. The second term is fixed per reading and independent
 * of the requested rate -- 65,536 readings take 0.679 s at every rate from 1 MS/s down to
 * 100 kS/s, with the timestamps tracking the request exactly, and only at 50 kS/s does the
 * wall time become `M/fs`. The two cross near 96.5 kS/s, so above that the instrument's
 * sustained throughput, not the digitizer's rate, is what a long record costs.
 *
 * 8192 is therefore about 85 ms of capture, which is why the value stands. Its original
 * reason did not: it was carried over from a 22 us-a-reading figure for crossing the
 * interpreter boundary, which is neither the measured cost nor one a native implementation
 * would pay.
 *
 * It bites at one place. `n` of 4096 at decimation 2 wants `M` of 8235, 43 readings over this
 * ceiling, so the offered decimation falls to 1 there and at every count above it. Admitting
 * it costs 85.3 ms instead of 84.9; a ceiling of 8640, or 90 ms, would cover it.
 */
#define DSP_FIR_MAXM 8192

/**
 * @brief Largest decimation a plan accepts, and the ceiling ::dsp_fir_pick_decim clamps to.
 *
 * The read budget binds long before this does: `(DSP_FIR_MAXM - maxtaps)/(n-1)` is 2602 at
 * the smallest plan size with a 384-tap ceiling and 1 from `n` of 3906 up, so a decimation
 * arrived at by asking is always one a plan accepts. What this bounds is a caller setting
 * @c decim by hand, because it multiplies the source length.
 */
#define DSP_DECIM_MAX 4096

/**
 * @brief Largest source record ::dsp_fir_srclength will admit, in readings.
 *
 * `(n-1)*decim + ntaps` exceeds a 32-bit `int` for arguments nothing else refuses --
 * `(32768, 100000, 101)` is 3.3e9 -- and a wrapped negative length passes the `nsrc < need`
 * test in ::dsp_spectrum_run, which then reads a record that is not there. The product is
 * compared against this by dividing it, never by forming the product. A million readings is
 * 22 s of reads at 22 us each,
 * far past ::DSP_FIR_MAXM and past any configuration offered here, so the ceiling catches
 * only arithmetic that would wrap.
 */
#define DSP_SRC_MAX 1048576

/** @brief Hamming's transition constant: about `3.3/transition` taps for its stopband. */
#define DSP_FIR_TAPK 3.3

/**
 * @brief Peaks ::dsp_peaks will rank in one pass.
 *
 * Its insertion sort keeps the running top list on the stack, so this bounds that frame.
 * The app asks for 6.
 */
#define DSP_PEAKS_MAX 64

/**
 * @brief Columns the four-step gathers at once.
 *
 * Eight single-precision values fill one 32-byte cache block, so a block of eight columns
 * uses every byte of each block it fetches. Without it the gather's stride maps 128 streams
 * onto 4 cache sets and thrashes an eight-way cache.
 */
#define DSP_FS_BLOCK 8

/**
 * @brief Smallest complex transform length the four-step is used for.
 *
 * Two reasons, and only the first is about correctness. The gather and the scatter step a
 * whole ::DSP_FS_BLOCK of columns with no partial case, so the four-step requires `m2` to be
 * at least ::DSP_FS_BLOCK; forced past that, `m` of 4, 8 and 16 read outside the array and
 * return bins wrong by up to 12.5. The condition is tested directly rather than inferred
 * from this number, at plan time: ::dsp_plan_init substitutes radix-2 where the four-step
 * cannot run, and ::dsp_rfft then dispatches on the arrays the arena actually holds. The smallest `m` that satisfies it is 32, where `m1` is 4
 * and `m2` is 8. Separately, below 64 the whole array is a few hundred bytes and resident
 * whatever the decomposition does, so the blocking can only cost: this is the size the
 * four-step starts paying off at, not the size it starts working at.
 */
#define DSP_FS_MIN 64

/* ------------------------------------------------------------------------- */

/**
 * @brief How the decimated spectrum's bins map back to hertz.
 *
 * Bin @e k is at `f0 + sense * k * binhz`. Without decimation that is `k * binhz` with
 * @c f0 zero and @c sense 1, which is the relation the rest of this interface assumes; a
 * decimated band-pass breaks it both ways. Decimating by @e D folds the spectrum into zones
 * `D` of them, each `fs/(2D)` wide, and the band lands in zone `floor(2*D*flo/fs)`. An
 * even zone arrives offset by the zone's lower edge; an **odd zone arrives
 * frequency-reversed**, because the fold runs the other way, so the highest input frequency
 * is at the lowest bin.
 *
 * Which is why this exists rather than a second `binwidth` read-back: `(fs, n, decim)` no
 * longer determines a bin's frequency, and getting the sense wrong mirrors the whole
 * spectrum without changing anything a plausibility check would notice.
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
 *         which point the decimation folds the band onto itself and no tap count helps --
 *         or ::DSP_EUNSUPPORTED for a non-zero @p flo in a `DSP_BANDPASS=0` build.
 *         ::dsp_fir_pick_decim only returns decimations for which this succeeds.
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
 * The inverse of ::dsp_bin_hz, and the `k0`/`k1` every windowed call takes: ::dsp_reduce,
 * ::dsp_peaks and ::dsp_thd_noise. It is here so that a caller does not have to invent it:
 * the trace and all three distortion figures are computed over this window, so two
 * callers rounding the edges differently disagree about every one of them -- by an amount
 * too small to look like a defect and large enough to matter. Stated once, in code.
 *
 * Both edges round inward: `ceil` on the low index, `floor` on the high. That is what makes
 * the window the bins whose centre frequency is inside the band. Rounding the low edge down
 * instead pulls in the bin below, and at zone 0 that bin is DC -- so a start frequency under
 * one bin width would report the removed mean as a tone.
 *
 * An odd Nyquist zone arrives reversed (::dsp_bandmap::sense is -1), so @p fhi is the low
 * index there: the edges swap and each keeps its own rounding.
 *
 * @param[in]  m      A map from ::dsp_band_map.
 * @param      flo    Low edge in hertz.
 * @param      fhi    High edge in hertz; must exceed @p flo.
 * @param      nbins  Bins available, usually ::dsp_plan::m.
 * @param[out] k0_out First bin, `0..nbins-1`.
 * @param[out] k1_out Last bin, `k0_out..nbins-1`.
 * @return ::DSP_OK, or ::DSP_EARG for a NULL argument, @p k0_out and @p k1_out being one
 *         object, @p nbins below 1, a map with no bin width, a non-ascending band or a
 *         non-finite edge. Both outputs are 0 on a refusal.
 * @note The window is never empty: a band narrower than one bin reports the single bin it
 *       falls in, which is what every call taking `k0..k1` expects.
 */
int dsp_band_bins(const dsp_bandmap *m, double flo, double fhi, int nbins, int *k0_out,
                  int *k1_out);

/**
 * @brief Tabulated main lobe of the window in use, and its inversion.
 *
 * A tone at bin `k+d` puts the three bins around the peak at `-d`, `1-d` and `1+d` on
 * `G(x) = |sum w[i] cos(2 pi x (i-c) / n)| / sum w[i]`, `c = (n-1)/2`, so the ratio
 * `r = (R-L)/(L+2C+R)` is a fixed odd function of `d` and the amplitude is low by exactly
 * `G(d)`. Both tables come from the window samples in use, so a window change needs no new
 * constants.
 */
typedef struct {
    double  gtab[DSP_GN + 1]; /**< `G(j * DSP_GHX)`. */
    double  dtab[DSP_DN + 1]; /**< `d` at `r = m * dhr`. */
    double  dhr;              /**< `dtab` step in r; 0 means there is no usable table. */
    double  inv_dhr;          /**< `1/dhr`, so a lookup multiplies; 0 alongside `dhr` 0. */
    int     mono;             /**< `r(d)` rose all the way to half a bin. */
    int     lobe;             /**< Main-lobe half-width in bins, from ::dsp_window_lobe.
                                   ::dsp_thd_noise withholds this many bins PLUS ONE
                                   either side of a line from its noise figures: inside the
                                   lobe the bins hold the window rather than noise, and the
                                   extra bin is guard past the null. */
} dsp_interp;

/**
 * @brief Everything loop-invariant, built once into the caller's arena.
 *
 * Read-only to the caller except @c method. The filter goes in through ::dsp_plan_set_fir,
 * which is the only way to leave @c h and @c ntaps agreeing; ::dsp_spectrum_run revalidates
 * @c ntaps regardless, because the field is reachable and @c h holds at most
 * ::DSP_FIR_MAXTAPS entries.
 */

/**
 * @brief Called from inside a frame so the caller can let other tasks run.
 *
 * The display task on this instrument is scheduled only while the interpreter blocks, so a
 * primitive that runs to completion without yielding leaves the panel dead for its whole
 * duration. See ::dsp_plan_set_yield for where it is called and what it may not do.
 */
typedef void (*dsp_yield_fn)(void *ctx);

typedef struct {
    int        n;       /**< Samples: a power of two, at least 4. */
    int        m;       /**< `n/2`, the complex transform size and the number of bins. */
    int        kind;    /**< One of the `DSP_WINDOW_*` values. */
    int        decim;   /**< Decimation the FIR scratch was sized for; 1 means no filter. */
    int        method;  /**< The `DSP_FFT_*` value the arena was built for, after the
                             substitution ::DSP_FS_MIN describes. Asking for the four-step
                             below that size records ::DSP_FFT_RADIX2 here. */
    double     beta;    /**< Kaiser only. */
    dsp_real  *w;       /**< Window, @c n entries. */
    double     wsum;    /**< Sum of the window; ::dsp_load weights the mean by it. */
    double     cg;      /**< Coherent gain, `wsum/n`. A window identity, not read per frame. */
    double     ksq;     /**< Power scale, `1/wsum^2`, applied to the untangled `|2X|^2`. */
    /* The arrays below marked for one decomposition are NULL in a plan built for another:
     * the arena holds what its own method reads and nothing else. */
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
    /* The arrays above that a segment may be too small to hold whole, as the slice tables
     * the kernels address them through. The raw pointer beside each one is the whole array
     * only while its @c nslice is 1; past that it is the first slice and nothing else, and
     * ::dsp_plan_segs is what decides which. The small arrays -- the swap lists, the gather
     * block, the FIR taps -- are never split and have no table here. */
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
 * Sized for @p method alone. Derived from the same layout walk as ::dsp_plan_init, so the two
 * cannot disagree.
 *
 * @param n      Sample count; a power of two in `4..DSP_N_MAX`.
 * @param decim  Decimation the FIR output scratch must hold, `1..DSP_DECIM_MAX`; 1 for none.
 * @param method One of the `DSP_FFT_*` values.
 * @return Bytes required, or 0 for a configuration that would be refused.
 * @note The return value is the layout exactly, with no slack for a caller to align into;
 *       see ::DSP_ALIGN for the idiom.
 */
size_t dsp_plan_bytes(int n, int decim, int method);

/**
 * @brief Build the window, the interpolation tables, the swap list and the twiddles.
 *
 * The slow call, once per change of @p n, @p kind, @p beta, @p decim or @p method: the
 * `O(n * DSP_GN)` cosines for the interpolation tables dominate. Leaves
 * ::dsp_plan::ntaps at 0, so a decimating plan needs a ::dsp_plan_set_fir before a frame.
 *
 * @param[out] p      Plan to fill. Zeroed before anything else is checked, so every refusal
 *                    leaves `p->n == 0` and a rejected plan cannot be mistaken for the plan
 *                    that was there before. A caller that retries larger, is refused for
 *                    memory and runs a frame anyway is refused there too.
 * @param[in]  arena  Caller-owned scratch, retained by @p p for its lifetime.
 * @param      bytes  Size of @p arena.
 * @param      n      Sample count.
 * @param      kind   One of the `DSP_WINDOW_*` values.
 * @param      beta   Kaiser only; ignored otherwise.
 * @param      decim  Decimation to size the FIR output scratch for; 1 for none.
 * @param      method Decomposition to build for, one of the `DSP_FFT_*` values. Recorded in
 *                    ::dsp_plan::method, which is where to read what it resolved to.
 * @return ::DSP_OK, ::DSP_EARG, ::DSP_EPOW2, ::DSP_ENOMEM, ::DSP_EALIGN or ::DSP_EBETA.
 *         Under ::DSP_CHECK_OVERLAP a @p p that lies inside @p arena is ::DSP_EARG; without
 *         it the carve-up overwrites the plan's own pointers with window samples.
 * @pre @p n is a power of two in `4..DSP_N_MAX`, @p decim is in `1..DSP_DECIM_MAX`.
 * @pre @p arena is aligned to ::DSP_ALIGN and holds at least
 *      `dsp_plan_bytes(n, decim, method)`.
 * @pre @p arena is reached through no other live pointer; the plan writes all of it.
 */
int dsp_plan_init(dsp_plan *p, void *arena, size_t bytes, int n, int kind, double beta, int decim,
                  int method);

/**
 * @brief Segments of @p seg_bytes the plan needs, when no one block is big enough.
 *
 * For a caller whose memory comes in fixed-size pieces that are not adjacent. On the
 * DMM6500 a reading buffer's chunk payloads are 32,768 bytes each and are placed
 * independently by the allocator, so a multi-chunk arena is not one region; see
 * `notes/firmware/fwmem-BUFFER.md`.
 *
 * The layout walk then places each array wholly inside one segment, skipping to the next
 * when the remainder of the current one is too small. Every array stays flat and
 * contiguous, so nothing in the transform changes -- only where the arrays sit. The cost
 * is the skipped tail of each segment, which ::dsp_plan_segs accounts for.
 *
 * Because an array is never split, **the largest one has to fit a single segment**. That
 * is the window at `n * sizeof(dsp_real)`, so `n <= seg_bytes / sizeof(dsp_real)`: with
 * 32,768-byte segments, 4096 in a double build and 8192 in a single one. A larger @p n
 * is ::DSP_ESEG from ::dsp_plan_init_segs and 0 here.
 *
 * @param n         Sample count; a power of two in `4..DSP_N_MAX`.
 * @param decim     Decimation the FIR output scratch must hold; 1 for none.
 * @param method    One of the `DSP_FFT_*` values.
 * @param seg_bytes Size of one segment; a multiple of ::DSP_ALIGN.
 * @return Segments required, or 0 for a configuration that would be refused.
 */
int dsp_plan_segs(int n, int decim, int method, size_t seg_bytes);

/**
 * @brief ::dsp_plan_init over segments that are not adjacent.
 *
 * Identical to ::dsp_plan_init in what it builds and what the plan then does; the only
 * difference is where the arrays live. See ::dsp_plan_segs for the layout rule and the
 * bound it puts on @p n.
 *
 * @param[out] p         Plan to fill. Zeroed before anything else is checked, as in
 *                       ::dsp_plan_init.
 * @param[in]  segs      @p nsegs segment base addresses, each aligned to ::DSP_ALIGN and
 *                       each holding @p seg_bytes. Retained by @p p for its lifetime.
 * @param      nsegs     Segments available; at least ::dsp_plan_segs.
 * @param      seg_bytes Size of one segment; a multiple of ::DSP_ALIGN.
 * @param      n         Sample count.
 * @param      kind      One of the `DSP_WINDOW_*` values.
 * @param      beta      Kaiser only; ignored otherwise.
 * @param      decim     Decimation to size the FIR output scratch for; 1 for none.
 * @param      method    Decomposition to build for.
 * @return ::DSP_OK, ::DSP_EARG, ::DSP_EPOW2, ::DSP_ENOMEM, ::DSP_EALIGN, ::DSP_EBETA or
 *         ::DSP_ESEG. ::DSP_ENOMEM means @p nsegs is short of ::dsp_plan_segs; ::DSP_ESEG
 *         means no segment could hold one array whatever @p nsegs is.
 * @pre Every entry of @p segs is non-NULL, aligned, holds @p seg_bytes, and is reached
 *      through no other live pointer; the plan writes all of them.
 * @note The segments need not be in address order, and need not be adjacent. Overlapping
 *       segments are not detected and would corrupt the plan.
 */
int dsp_plan_init_segs(dsp_plan *p, void *const *segs, int nsegs, size_t seg_bytes, int n, int kind,
                       double beta, int decim, int method);

/**
 * @brief Install the filter taps, or clear the filter.
 *
 * The only supported way to change @c h and @c ntaps. Set either by hand and they can
 * disagree, which ::dsp_spectrum_run then refuses with ::DSP_EARG rather than running a
 * configuration it cannot honour.
 *
 * @param[in,out] p     Plan from ::dsp_plan_init.
 * @param[in]     h     Taps from ::dsp_fir_design. May be NULL only with @p ntaps of 0;
 *                      NULL with a non-zero count is ::DSP_EARG, not a clear.
 * @param         ntaps Tap count, `0..DSP_FIR_MAXTAPS`; 0 clears the filter, and is the
 *                      only thing that clears it.
 * @return @p ntaps installed, or ::DSP_EARG.
 * @pre @p p decimates. Taps on a plan with `decim` of 1 are ::DSP_EARG: ::dsp_spectrum_run
 *      filters only where the decimation makes it necessary and ::dsp_plan_init gives such
 *      a plan no buffer to filter into, so they could never be applied.
 * @pre @p h does not point into @p p's arena.
 */
int dsp_plan_set_fir(dsp_plan *p, const dsp_real *h, int ntaps);

/**
 * @brief Install a yield callback, or clear it.
 *
 * Called at a fixed, small number of points per frame, never inside an inner loop: after the
 * filter, after the load, after the transform, and once per four-step gather block and row
 * group. The longest stretch between two calls is one sub-transform -- a few kB, resident in
 * cache -- so the cost is a null test per boundary and nothing per sample.
 *
 * @param[in,out] p   Plan from ::dsp_plan_init, which zeroes this, so install it afterwards.
 * @param         fn  Callback, or NULL to clear.
 * @param[in]     ctx Passed through untouched.
 * @return ::DSP_OK, or ::DSP_EARG for a null or unbuilt plan.
 * @warning The callback MUST NOT touch @p p, read `p->pwr` or start another frame. It is
 *          called with the working arrays holding intermediate state -- between the
 *          four-step's passes `re` and `im` are neither the input nor the spectrum -- so a
 *          reader would see values that are not a spectrum at any scale.
 * @note It may run for as long as the caller likes. Nothing here holds a lock and no state
 *       spans the call other than the arrays, which only this plan's frame touches.
 */
int dsp_plan_set_yield(dsp_plan *p, dsp_yield_fn fn, void *ctx);

/* ------------------------------------------------------------------------- */

/**
 * @brief Build a symmetric analysis window.
 *
 * Computed over half the span and mirrored; Kaiser from a Bessel I0 power series.
 *
 * @param[out] w    Window, @p n entries.
 * @param      n    Length, at least 2.
 * @param      kind One of the `DSP_WINDOW_*` values.
 * @param      beta Kaiser only.
 * @return ::DSP_OK, ::DSP_EARG for a null pointer or an unknown @p kind, or ::DSP_EBETA for
 *         a Kaiser beta outside ::DSP_KAISER_BETA_MIN to ::DSP_KAISER_BETA_MAX. A NaN beta
 *         is ::DSP_EBETA: the test is written as a positive, so a NaN fails it.
 * @pre @p w is reached through no other pointer during the call.
 */
int dsp_window(dsp_real *DSP_RESTRICT w, int n, int kind, double beta);

/**
 * @brief Design a decimating windowed-sinc band-pass or low-pass, Hamming-windowed.
 *
 * A difference of sincs, so `flo` of 0 gives the low-pass kernel exactly. Each cutoff sits
 * half a transition outside its band edge rather than on it: a filter's roll-off starts before
 * its cutoff, so a cutoff at the band edge puts the whole displayed band inside the roll-off,
 * which read 3.5 dB low at 16.6 kHz of a 20 kHz span when measured on the instrument. The
 * transition used is the one the tap count delivers, bounded by the room the zone leaves,
 * which keeps a forced longer filter hugging the band edge instead of widening the passband
 * out to a zone edge that may be far away. Stated as a consequence rather than a position,
 * because the position is not a simple one: over 2,564 realisable low-pass designs the worst
 * response error at the span edge is 0.119 dB.
 *
 * **The normalisation differs between the two, and has to.** For a low-pass DC is in the
 * passband, so the DC gain is the passband gain and the taps are divided by their sum. For a
 * band-pass DC is a *stopband*: the sum approaches zero with a data-dependent sign, and
 * dividing by it is unbounded rather than merely inaccurate. Unit gain is taken at the
 * passband centre instead, from one cosine sum over the taps at design time.
 *
 * @param[out] h       Taps, up to @p maxtaps entries.
 * @param      maxtaps Ceiling, which is both @p h's length and the design's limit.
 * @param      fs      Sample rate before decimation, Hz.
 * @param      flo     Band start, Hz. 0 for a low-pass. A non-zero value needs
 *                     ::DSP_BANDPASS; a low-pass build returns ::DSP_EUNSUPPORTED.
 * @param      fhi     Band end, Hz. Above @p flo, not above `fs/2`.
 * @param      decim   Decimation the design is for. With `flo` of 0 a @p decim of 1 needs no
 *                     filter and returns 0; a band-pass at @p decim 1 is a real filter,
 *                     because the selectivity is the point rather than the anti-aliasing.
 * @param      order   Taps to force, or 0 to take them from the transition width. An even
 *                     @p order becomes the next odd value, or the previous one when that
 *                     would pass @p maxtaps, so `order == maxtaps` is a design rather than a
 *                     refusal; the proposal's own example asks for exactly that.
 * @return Tap count, 0 when no filter is needed, or ::DSP_EARG, ::DSP_EUNSUPPORTED or
 *         ::DSP_EZONE.
 * @pre @p h is reached through no other pointer during the call.
 * @note A derived tap count comes from the transitions that prevent *aliasing*, which
 *       ::dsp_fir_transition defines. In zone 0 the lower band edge has no aliasing
 *       transition -- nothing folds across DC -- so the sharpness of the lower skirt there is
 *       whatever that tap count affords. Pass an explicit @p order to buy more of it.
 */
int dsp_fir_design(dsp_real *DSP_RESTRICT h, int maxtaps, double fs, double flo, double fhi,
                   int decim, int order);

/**
 * @brief Run a decimating convolution.
 *
 * Output @e j spans inputs `j*decim .. j*decim + ntaps - 1`, so it is centred on
 * `j*decim + (ntaps-1)/2` and the taps are applied only where an output is produced. An odd
 * tap count makes that group delay a whole sample, which is why ::dsp_fir_design forces
 * one. Four independent accumulator chains, because the e300c4's FPU is a
 * three-stage pipeline and one dependent chain stalls every third instruction.
 *
 * @param[in]  x     Source readings, @p nx of them.
 * @param      nx    Source length.
 * @param[in]  h     Taps from ::dsp_fir_design.
 * @param      ntaps Tap count.
 * @param      decim Decimation, at least 1.
 * @param[out] y     Outputs; needs `(nx - ntaps)/decim + 1` entries.
 * @return Outputs written, or ::DSP_EARG -- including for @p y and @p x being one pointer,
 *         the in-place case, which is detected rather than left undefined.
 * @pre `nx >= ntaps`, and @p h holds @p ntaps entries.
 * @pre @p x, @p h and @p y do not overlap. In place is not supported: each output reads
 *      @p ntaps inputs, which overlap the inputs of the outputs around it.
 */
int dsp_fir_run(const double *DSP_RESTRICT x, int nx, const dsp_real *DSP_RESTRICT h, int ntaps,
                int decim, double *DSP_RESTRICT y);

/**
 * @brief Window @p n samples, remove the window-weighted mean, pack into `n/2` complex.
 *
 * Two passes, because the mean must be known before it is subtracted. The mean is
 * window-weighted, `sum(w*x)/sum(w)`, not arithmetic: what has to vanish is the DC of the
 * sequence the transform sees, `sum(w*(x-mean))`, and only the weighted mean makes it. The
 * arithmetic mean leaves the window's own DC response spread over the first bins, which
 * puts a -27 dBc line at bin 1 for a 1.000 V tone at bin 10.5. The price is that near DC
 * the estimate is the tone, which is what ::dsp_plan::kdc measures.
 *
 * @param[in]  x        Source readings, @p n of them.
 * @param      n        Sample count; a power of two.
 * @param[in]  w        Window, @p n entries.
 * @param      wsum     Sum of @p w, from ::dsp_plan::wsum.
 * @param[out] re       Real parts, `n/2` entries.
 * @param[out] im       Imaginary parts, `n/2` entries.
 * @param[out] mean_out Weighted mean removed; may be NULL.
 * @return ::DSP_OK, ::DSP_EPOW2 for a sample count that is not a power of two in range, or
 *         ::DSP_EARG for a null pointer, a @p wsum that is not positive, or -- under
 *         ::DSP_CHECK_OVERLAP -- any two of these buffers sharing bytes.
 * @pre @p x, @p w, @p re and @p im do not overlap.
 */
int dsp_load(const double *DSP_RESTRICT x, int n, const dsp_real *DSP_RESTRICT w, double wsum,
             dsp_real *DSP_RESTRICT re, dsp_real *DSP_RESTRICT im, double *mean_out);

/**
 * @brief In-place complex FFT of `p->m` points on `p->re` and `p->im`.
 *
 * Runs the decomposition the plan was built for. Both leave the same bins in natural order
 * to rounding; they differ in memory traffic, which `csrc/README.md` models. The
 * method is read off the arena rather than out of ::dsp_plan::method, so overwriting that
 * field changes nothing: the arrays a decomposition reads are the arrays its own plan paid
 * for, and a kernel is never handed a buffer that is NULL.
 *
 * Asking ::dsp_plan_init for ::DSP_FFT_FOURSTEP below the size ::DSP_FS_MIN describes builds
 * a ::DSP_FFT_RADIX2 plan instead, which ::dsp_plan::method reports. The substitution is at
 * build time, so a caller timing decompositions against each other can see it.
 *
 * @param[in,out] p Plan whose `re`/`im` hold the packed input and receive the transform.
 * @pre @p p was built by ::dsp_plan_init. A plan it refused has `p->m == 0` and is ignored.
 */
void dsp_rfft(dsp_plan *p);

/**
 * @brief Untangle the half-size transform into @p m real-input bins and write their power.
 *
 * With `Z` the @p m-point transform of the packed input and `Zc` its conjugate at the mirror
 * index, `X[k] = (Z + Zc)/2 + exp(-2 pi i k/n) (Z - Zc)/(2i)`. Bins @e k and `m-k` share the
 * same four loads, so the pass walks mirror pairs; bin 0 and bin `m/2` are their own
 * mirrors. The untangle leaves every bin doubled, so @p scale is `1/wsum^2` rather than
 * `4/wsum^2` and a bin's square root is the window-corrected peak amplitude of a tone
 * sitting on it.
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
 *      @p re and the pass walks mirror pairs, so an in-place call would consume bins it has
 *      already overwritten.
 */
void dsp_power(const dsp_real *DSP_RESTRICT re, const dsp_real *DSP_RESTRICT im, int m,
               const dsp_real *DSP_RESTRICT utr, const dsp_real *DSP_RESTRICT uti,
               dsp_real *DSP_RESTRICT pwr, double scale);

/**
 * @brief Reduce bins `k0..k1` to @p nseg trace points in dB and hertz.
 *
 * Each segment reports the *maximum* of the bins it covers, not a decimation or a mean: at
 * 16,384 samples and 255 segments a segment spans 32 bins, and anything but a maximum loses
 * a narrow tone entirely. The frequency reported is the *segment's*, not the winning bin's,
 * so the series stays strictly increasing when segments are narrower than a bin.
 *
 * **The output is always ascending in frequency, whatever the map says.** A band down-mixed
 * into an odd Nyquist zone arrives frequency-reversed, so for `sense` of -1 the segments walk
 * the bin window from its top down. A graph trace has to be ascending in x, and reversing it
 * here is one subtraction rather than something every caller has to remember.
 *
 * @param[in]  pwr    Power bins.
 * @param      nbins  Total bins in @p pwr. Present because this runs every frame and had no
 *                    way to bound @p k1: `k1 = m` reads one bin past the end, which
 *                    ::dsp_peaks catches over the same array and this could not.
 * @param      k0     First bin, inclusive.
 * @param      k1     Last bin, inclusive; clamped to `nbins - 1`.
 * @param      nseg   Trace points to write, `1..DSP_NSEG_MAX`.
 * @param[in]  map    Bin-to-hertz map from ::dsp_band_map. For an undecimated spectrum that
 *                    is `{0, dsp_binwidth(...), 1, 0}`, which is the plain `k * binwidth`.
 * @param      dbmin  Floor; a bin at or below `vfloor^2` plots here. Finite, below @p dbmax.
 * @param      dbmax  Ceiling. Finite.
 * @param      vfloor Floor in volts, squared internally so the logarithm never sees zero.
 *                    Finite and not negative.
 * @param[out] db     dB values, @p nseg entries.
 * @param[out] hz     Segment frequencies, @p nseg entries, ascending.
 * @return @p nseg, or ::DSP_EARG -- which under ::DSP_CHECK_OVERLAP includes @p db, @p hz
 *         and @p pwr sharing bytes with one another.
 * @pre `nbins >= 1`, `0 <= k0 < nbins`, `k0 <= k1`, `map->binhz > 0` and `map->sense` is
 *      either 1 or -1.
 * @pre `map->f0`, `map->binhz`, @p dbmin, @p dbmax and @p vfloor are finite, and every
 *      frequency the map produces over the window is representable in `dsp_real`. Each of
 *      them is written into @p db or @p hz on some path, so an argument that is not is a
 *      trace that is not, and that is a refused graph parameter on the instrument. The tests
 *      are for finiteness rather than for a NaN because an infinity passes `> 0` and then
 *      makes `0 * binhz` a NaN.
 * @pre @p db and @p hz overlap neither each other nor @p pwr.
 * @note A NaN bin plots at @p dbmin. The comparisons are written as positives for that
 *       reason: written the other way round a NaN would reach the trace buffer, where a
 *       refused parameter is a modal dialog.
 */
int dsp_reduce(const dsp_real *DSP_RESTRICT pwr, int nbins, int k0, int k1, int nseg,
               const dsp_bandmap *map, double dbmin, double dbmax, double vfloor,
               dsp_real *DSP_RESTRICT db, dsp_real *DSP_RESTRICT hz);

/**
 * @brief Find the strongest local maxima of @p pwr over bins `k0..k1`, strongest first.
 *
 * Bin 0 and the @p kdc bins above it carry ::dsp_load's mean-removal error rather than
 * signal, so none of them is a candidate whatever @p k0 says. A tone inside that region
 * leaks enough into the first reportable bin to make it a local maximum, which then reports
 * the tone a whole bin and 16 dB out; the estimator saturates at -0.5 there, so a peak at
 * the region's edge estimating a quarter bin or more below it is refused. A genuine tone
 * there estimates within 0.017 bins against the leak's 0.500.
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
 *                   where the estimate declined. May be NULL.
 * @return Peaks found, or ::DSP_EARG -- which under ::DSP_CHECK_OVERLAP includes @p bin,
 *         @p frac, @p amp and @p pwr sharing bytes with one another.
 * @pre @p pwr holds @p nbins entries; @p bin, @p frac and @p amp hold @p want each.
 * @pre @p bin, @p frac and @p amp overlap neither each other nor @p pwr.
 * @note A NaN bin is never reported: every comparison with a NaN is false, so it fails both
 *       halves of the local-maximum test and so does each of its neighbours.
 */
int dsp_peaks(const dsp_real *DSP_RESTRICT pwr, int nbins, int k0, int k1, int kdc, int want,
              const dsp_interp *ip, int *DSP_RESTRICT bin, dsp_real *DSP_RESTRICT frac,
              dsp_real *DSP_RESTRICT amp);

/* ------------------------------------------------------------------------- */

/**
 * @brief Scalloping loss at sub-bin offset @p d: the factor an amplitude reads low by.
 * @param[in] ip Interpolation tables.
 * @param     d  Offset in bins. Even in @p d; `G(0)` is 1; clamped past 1.5 bins.
 * @return The factor, or 1 if @p ip is NULL.
 * @note The range test is in `double` and written as a positive, so a NaN or a huge @p d
 *       clamps to the end of the table. Testing the truncated index instead converted an
 *       out-of-range `double` to `int` first, which is undefined: at `-O1` clang emitted a
 *       trap for `d = 1e30` while every other level returned the clamp.
 */
double dsp_win_gain(const dsp_interp *ip, double d);

/**
 * @brief Invert the three-bin ratio to a sub-bin offset.
 *
 * Past the end of the table the three bins are not one tone and the offset saturates at
 * half a bin.
 *
 * @param[in]  ip    Interpolation tables.
 * @param      r     `(R-L)/(L+2C+R)`.
 * @param[out] d_out Offset in `-0.5..0.5`; untouched unless ::DSP_OK is returned.
 * @return ::DSP_OK, ::DSP_EARG, or ::DSP_EDECLINE when the window has no invertible table.
 * @note A NaN @p r saturates like any ratio past the end of the table, for the reason in
 *       ::dsp_win_gain, so @p d_out is always finite on ::DSP_OK. A NaN there would reach an
 *       amplitude, and a non-finite reading is a modal dialog on the instrument.
 */
int dsp_win_offset(const dsp_interp *ip, double r, double *d_out);

/**
 * @brief Sub-bin peak estimate from bin @p k and its two neighbours.
 *
 * From the peak bin alone a tone between centres is off by up to half a bin and low by the
 * scalloping loss, 1.42 dB with Hann; both come back from the window's own main lobe.
 *
 * @param[in]  ip      Interpolation tables.
 * @param[in]  pwr     Power bins.
 * @param      k       Peak bin.
 * @param      nbins   Total bins in @p pwr.
 * @param[out] d_out   Offset in `-0.5..0.5`; may be NULL.
 * @param[out] amp_out Amplitude in volts; may be NULL.
 * @return ::DSP_OK, ::DSP_EARG for a NULL @p ip or @p pwr or for @p d_out and @p amp_out
 *         being one object, or ::DSP_EDECLINE at a spectrum edge, on a non-positive peak
 *         bin, or with no usable table. Neither output is written on a decline.
 * @pre @p pwr holds @p nbins entries, and @p ip was built for the window that produced them.
 */
int dsp_peak_interp(const dsp_interp *ip, const dsp_real *DSP_RESTRICT pwr, int k, int nbins,
                    double *d_out, double *amp_out);

/* ------------------------------------------------------------------------- */

/**
 * @brief Narrowest transition the decimation leaves, as a fraction of the sample rate.
 *
 * The transitions that matter are the ones that prevent aliasing, so they are measured from
 * the band edges to the edges of the Nyquist zone the band lands in. A band-pass has two of
 * them and the tap count is set by the narrower, which for a band near the bottom of a zone
 * is the lower one -- the edge a low-pass formula never looks at.
 *
 * Zone 0's lower edge is DC and nothing folds across it, so a band in zone 0 has only the
 * upper transition. With `flo` of 0 that reduces to `1/(2*decim) - fhi/fs`.
 *
 * @return The fraction; zero means there is no usable transition -- the band does not fit
 *         inside one zone, touches a zone edge, or the arguments are refused.
 */
double dsp_fir_transition(double fs, double flo, double fhi, int decim);

/**
 * @brief Taps a decimation's transition needs, odd so the group delay is a whole sample.
 *
 * Too few taps is not a subtle fault: 13 where the transition needs 50 reads 3.5 dB low at
 * the top of the span. @p maxtaps is the caller's because the answer depends on it, and the
 * two ceilings that matter are far apart: 65 is what an interpreted frame affords, 384 what
 * this one does.
 *
 * @return The tap count, or 0 when the transition needs more than @p maxtaps or does not
 *         exist.
 */
int dsp_fir_taps_for(double fs, double flo, double fhi, int decim, int maxtaps);

/**
 * @brief Largest decimation that keeps the band in one zone with a filter short enough.
 *
 * Three conditions, and the second is the one a low-pass formula cannot express: the read
 * budget must allow the source record (::DSP_FIR_MAXM), the whole band must land inside a
 * single Nyquist zone of the decimated rate, and the transitions that leaves must need no
 * more than @p maxtaps. Searched downwards from the read budget's ceiling, so the answer is
 * the finest bin width the band admits.
 *
 * The band's *position* decides this, not just its top. A decimation chosen from `fhi` alone
 * can put a zone boundary inside the band, which folds the band onto itself; no tap count
 * repairs that, so such a decimation is skipped rather than filtered harder.
 *
 * @return The decimation, or 1 when there is no room, which is not an error.
 */
int dsp_fir_pick_decim(double fs, double flo, double fhi, int n, int maxtaps);

/**
 * @brief A short, fixed message for a return code.
 *
 * For a caller that has to put a refusal in front of an operator. The reference application
 * writes one to its status line on a failed settings change and 60 characters of it behind a
 * halted banner, and a bare `-2` on the glass tells nobody anything.
 *
 * @param code Any ::DSP_OK or `DSP_E*` value.
 * @return A string literal, never NULL, never longer than 31 characters. Unknown codes give
 *         "unknown error", so the caller needs no range test of its own.
 */
const char *dsp_strerror(int code);

/**
 * @brief Readings the capture must hold for one record.
 *
 * @p n when the filter is not decimating, `(n-1)*decim + ntaps` when it is. A shorter
 * capture is refused rather than zero-padded: padding the tail gives a convincing and false
 * broadband spectrum, and a trigger timeout is the ordinary way a capture comes up short.
 *
 * The bound is DIVIDED rather than the product formed: `(n-1)*decim` overflows int for
 * arguments nothing else refuses, and widening it would pull in a 64-bit division. So every
 * length returned is one the arithmetic represents exactly.
 *
 * @return The length, or 0 for bad arguments or a record past ::DSP_SRC_MAX.
 */
int dsp_fir_srclength(int n, int decim, int ntaps);

/** @brief Bin width in Hz after decimation, from the rate actually delivered. */
double dsp_binwidth(double fs, int n, int decim);

/* ------------------------------------------------------------------------- */

/**
 * @brief One frame: filter if the plan has taps, then load, transform and power.
 *
 * Allocates nothing.
 *
 * @param[in,out] p        Plan; receives the spectrum in `p->pwr`.
 * @param[in]     src      Capture readings.
 * @param         nsrc     Readings available.
 * @param[out]    mean_out Weighted mean removed; may be NULL.
 * @return Bins written (`p->m`), or ::DSP_EARG, or ::DSP_ESHORT when @p nsrc is below
 *         ::dsp_fir_srclength, in which case `p->pwr` is untouched so the previous spectrum
 *         stays on screen.
 * @pre @p src overlaps nothing in @p p's arena.
 * @note ::DSP_EARG covers a plan whose filter cannot run the configuration it describes: a
 *       @c ntaps outside `0..DSP_FIR_MAXTAPS`, or a `decim > 1` with no taps. Running the
 *       second unfiltered would leave every frequency wrong by the decimation factor, since
 *       ::dsp_binwidth still reports the decimated width, so it is refused.
 */
int dsp_spectrum_run(dsp_plan *p, const double *DSP_RESTRICT src, int nsrc, double *mean_out);

/**
 * @brief ::dsp_spectrum_run over a record the caller holds as strided blocks.
 *
 * The form the instrument uses: the capture is read in place out of the reading buffer's
 * chunks, so no de-strided copy exists. ::dsp_spectrum_run is this over a one-block record.
 * A decimating plan still needs a contiguous one, the filter reading it as an array.
 */
int dsp_spectrum_run_src(dsp_plan *p, const dsp_src *src, int nsrc, double *mean_out);

/* ------------------------------------------------------------------------- */

#define DSP_THD_HMAX  20 /**< Harmonics ::dsp_thd_noise considers at most. */
#define DSP_THD_HALFW 2  /**< Bins either side of a predicted harmonic searched for it. */
#define DSP_THD_SKIRT 3  /**< Fallback skirt where ::dsp_interp::lobe is unavailable. */
/**
 * @brief Ratio the fundamental must clear the per-bin noise mean by to count as a signal.
 *
 * 45 dB. Below it there is no tone, only the largest noise bin, and every ratio taken
 * against it is arithmetic about nothing: measured on the instrument at 16384 samples, a
 * shorted input reported 31.8% distortion and -22.0 dB S/N, and a floating one 21.4% on
 * mains pickup. The shorted peak stood 17.1 dB over the per-bin mean, the best candidate a
 * floating input left stood 38.8, and an 8 Vp-p tone stood 117.9 -- so the margin goes
 * between the floating case and the tone.
 */
#define DSP_THD_MINRATIO 31623.0

/**
 * @brief Multiple of the running mean above which a noise bin is an outlier, not noise.
 *
 * The plain mean of a windowed spectrum is set by whichever few bins carry a line's leakage
 * skirt rather than by the broadband floor. Measured at 16384 samples with a tone half a
 * bin off centre, Hann's skirt put the mean 62 dB over the floor the trace showed -- and
 * swung the figure 62 dB purely on where the tone landed between bins. Widening the skirt
 * cannot reach it: Hann is still 45 dB down four bins out, so the skirt would have to be
 * about a hundred bins wide.
 *
 * Clipping at four times the first mean removes them, since leakage bins sit orders of
 * magnitude up rather than a factor of four. For noise with no outliers at all the clip
 * trims and biases the answer low, which is the price of the robustness. One pass over
 * exponential bins trims the top 1.8% and costs 0.34 dB; ::DSP_THD_CLIPS passes tighten the
 * threshold each time and converge at 0.46 dB, which is the figure that ships -- measured
 * over 2047 bins and 40 trials, and matching the analytic iteration to 0.002 dB.
 */
#define DSP_THD_CLIP 4.0

/**
 * @brief Mains frequencies whose multiples ::dsp_thd_noise passes over.
 *
 * Integers, because they are also the values the @p mains selector takes: a double-typed
 * constant passed to an int parameter works by silent conversion, which is the kind of
 * agreement that stops being true the moment someone writes 50.5 here.
 */
#define DSP_THD_MAINS_A 50
#define DSP_THD_MAINS_B 60
/**
 * @brief Pass over multiples of BOTH mains frequencies; the @p mains argument's default.
 *
 * Negative, because every real selection is a frequency and so positive. Both is the right
 * default for an instrument sold in either region, and the wrong thing to hard-wire: at
 * 50 Hz every multiple to 950 is discounted, which is most of the band the rule covers, so
 * a 60 Hz user who knows it gives those back by selecting ::DSP_THD_MAINS_B.
 */
#define DSP_THD_MAINS_BOTH (-1)
/** Power at which a mains multiple stops being pickup and counts as a tone: -22 dBV. */
#define DSP_THD_MAINS_PWR 0.0063096
/** Above this frequency a tone on a mains multiple is taken at face value. */
#define DSP_THD_MAINS_FMAX 1000.0

/**
 * @brief Bins the noise figures sample, rather than sweeping the whole window.
 *
 * The clip wants several passes and each walks the window, so the cost is passes times
 * bins. Measured in the Lua the primitives replace, all 8192 bins at 16384 samples cost
 * 0.498 s a call and took the frame from 1.67 s to 2.17 s -- thirty per cent of it, for a
 * figure that updates once a second.
 *
 * The standard error of a mean over 1024 bins is 0.14 dB, under a third of the 0.46 dB the
 * clip itself costs, so sampling is free in any sense that shows. 2048 held the Lua frame at
 * 1.81 s against 1.67 s; 1024 is the same trade again. @c snr_db scales the sampled
 * sum back up by the stride, which is unbiased; @c noise_db needs no scaling because the
 * stride cancels in `sum / cnt`.
 */
#define DSP_THD_NSAMPLE 1024
/** Clip passes at most; each tightens the threshold, and it stops when one removes
 *  nothing. A graded skirt needs more than one: Hann took three to settle. */
#define DSP_THD_CLIPS 6

/**
 * @brief Distortion and noise over one spectrum, from ::dsp_thd_noise.
 *
 * @c signal and the two counts say which figures mean anything; every other field is
 * zeroed, so an unread one is 0 rather than indeterminate. There is no in-band sentinel:
 * 0 dB and 0% are both values a real spectrum can produce, so the flags are the only
 * honest answer.
 */
typedef struct {
    double thd;      /**< Harmonic distortion as a FRACTION of the fundamental, not a
                          percentage: multiply by 100 for the figure a panel shows.
                          Meaningful only where @c signal is set AND @c nharm is above
                          zero -- no harmonic inside the window is not a clean signal. */
    double snr_db;   /**< Fundamental over the INTEGRATED non-harmonic power, in dB. Holds
                          still when @c nbins changes, where @c noise_db FALLS about 3 dB a
                          doubling: the floor is per bin and the bins narrow, while this is
                          against the integrated noise and the bandwidth does not move. Meaningful only where @c signal is set. */
    double noise_db; /**< Mean non-line bin power, in dB against a 1 V amplitude -- the
                          reference ::dsp_reduce uses, so the two compare directly.
                          Meaningful wherever @c nnoise is above zero, @c signal or not:
                          with the inputs shorted this is the instrument's own floor. */
    double f0;       /**< Strongest bin's position in bins, fractional, @c signal or not. */
    double f0_hz;    /**< The same in hertz, or 0 where @p binhz was not supplied. */
    double amp0;     /**< Strongest bin's amplitude in volts, @c signal or not. */
    int    signal;   /**< Nonzero where the strongest bin cleared ::DSP_THD_MINRATIO times
                          the per-bin noise mean, so it is a tone and not a noise peak. */
    int    nharm;    /**< Harmonics found inside the window; 0 unless @c signal is set. */
    int    nnoise;   /**< Bins that went into the noise figures: SAMPLED bins, so the
                          bandwidth @c snr_db is referenced to is `nnoise * stride`. */
    int    stride;   /**< One bin in this many was sampled; 1 below ::DSP_THD_NSAMPLE bins.
                          Reported because the three figures satisfy
                          `20*log10(amp0) - snr_db - noise_db == 10*log10(nnoise * stride)`,
                          which is the only cross-check on them, and without this the
                          caller cannot form it: at 8192 bins the stride is 8 and the
                          identity is out by 9 dB. */
} dsp_thdn;

/**
 * @brief Measure harmonic distortion and noise over bins `k0..k1` of @p pwr.
 *
 * The fundamental is the strongest bin in the window that is also a LOCAL MAXIMUM and clears
 * ::DSP_THD_MINRATIO. Strongest alone is not enough: on a monotonic skirt it picks the
 * shoulder of a louder line, which measured 21.4% distortion on no signal. Harmonics are sought at `h * f0` for
 * rising @c h, each taken as the largest bin within ::DSP_THD_HALFW of the prediction, and
 * only while that lands inside the window and clear of the previous line's skirt: two
 * lines closer than ::dsp_interp::lobe plus one are not resolvable and counting both would
 * count one of them twice. That is 3 bins for Hann and 7 at Kaiser 18, so it follows the
 * window; ::DSP_THD_SKIRT is only the fallback where @p ip is NULL. Amplitudes come from ::dsp_peak_interp, because a bin maximum alone reads
 * up to 3.9 dB low on a tone sitting between bins.
 *
 * The noise figures use the MEAN POWER of every bin that is neither a line nor a skirt.
 * A mean of powers and not of decibels: averaging logarithms lets one deep null drag the
 * result down by several dB, where power is the quantity that adds.
 *
 * MAINS PICKUP IS PASSED OVER. A floating input carries 50 or 60 Hz and its harmonics --
 * measured on the instrument, 60 Hz at -25.4 dBV with harmonics out to 540 -- and taking
 * the hum as the fundamental reports the hum's own distortion, 11.04% over a -105.2 dBV
 * floor. A candidate at a multiple of the selected mains frequency, under
 * ::DSP_THD_MAINS_FMAX and at or below ::DSP_THD_MAINS_PWR, is skipped so the search moves
 * on; with nothing else present @c signal then comes back clear. Needs @p binhz to place
 * the multiples, and does nothing without it.
 *
 * @param[in]  pwr   Power bins, as ::dsp_plan::pwr holds them.
 * @param      nbins Total bins in @p pwr.
 * @param      k0    First bin, raised to `1 + kdc` if lower.
 * @param      k1    Last bin, clamped to `nbins - 1`.
 * @param      kdc   ::dsp_plan::kdc.
 * @param      binhz Bin width in hertz, from ::dsp_binwidth. Only the mains rule needs it;
 *                   a caller measuring in bins rather than hertz passes 0, which switches
 *                   the rule off whatever @p mains asks for.
 * @param      mains ::DSP_THD_MAINS_BOTH, ::DSP_THD_MAINS_A, ::DSP_THD_MAINS_B, or 0 to
 *                   take hum at face value. Anything else is ::DSP_EARG: a frequency that
 *                   is neither mains would discount a band nothing picks up, and silently
 *                   ignoring it would hide the typo.
 * @param[in]  ip    Interpolation tables; NULL falls back to `sqrt(pwr[k])` per line.
 * @param[out] out   Zeroed, then filled. See ::dsp_thdn for which fields are valid.
 * @return ::DSP_OK, or ::DSP_EARG for a null argument, fewer than eight bins in @p pwr,
 *         a window narrower than five bins, an unknown @p mains, or -- under
 *         ::DSP_CHECK_OVERLAP -- an @p out that shares bytes with @p pwr.
 * @pre @p pwr holds @p nbins entries and does not overlap @p out.
 * @note One pass over the window for the fundamental and one for the noise, plus a short
 *       search per harmonic. No allocation: the line list is at most
 *       `DSP_THD_HMAX + 1` bins and lives on the stack.
 * @note A NaN bin cannot become the fundamental -- every comparison with it is false -- and
 *       is excluded from the noise sum by the same test, written as a positive.
 */
int dsp_thd_noise(const dsp_real *DSP_RESTRICT pwr, int nbins, int k0, int k1, int kdc,
                  double binhz, int mains, const dsp_interp *ip,
                  dsp_thdn *DSP_RESTRICT out);

/**
 * @brief Half-width of the window's main lobe, in bins, rounded up.
 *
 * The first null of the window's transform: 2 for Hann, 3 for Blackman, 4 for
 * Blackman-Harris, and `sqrt(1 + (beta/pi)^2)` for Kaiser -- 5.82 bins at `beta` 18.
 * ::dsp_thd_noise keeps this many bins plus one either side of every line out of its noise
 * figures, since inside the lobe the bins hold signal.
 *
 * A fixed three bins instead caps the reportable S/N at 38.5 dB on Kaiser 18 against the
 * 102 dB the window itself allows, measured on a pure tone at 16384 samples: nearly three
 * bins of main lobe each side were counted as noise.
 *
 * @param kind One of the `DSP_WINDOW_*` values.
 * @param beta Kaiser only; ignored otherwise.
 * @return The half-width in bins, at least 2, or 0 for an unknown @p kind.
 * @note Sidelobe energy is NOT covered and cannot be: Kaiser 4's sidelobes are 30 dB down
 *       and integrate to a 36.7 dB ceiling whatever the skirt does. That is the window's
 *       property, not a measurement error.
 */
int dsp_window_lobe(int kind, double beta);

/**
 * @name The power-spectrum readers, over a split array
 *
 * The same functions as the four above, taking the power spectrum as the ::dsp_vec the
 * arena may have had to cut it into. Each of those is this one over a one-slice vector, so
 * a caller with a contiguous array has nothing to change; a caller holding a plan reads
 * @c pwr_v, which is the whole spectrum however the segments fell.
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
