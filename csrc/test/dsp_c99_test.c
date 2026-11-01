/* dsp_c99_test.c -- the library through a C99 translation unit.
 *
 * The gtest suite is C++, where DSP_RESTRICT expands to nothing: 23 parameters carry a
 * non-aliasing promise that the C++ build erases before the compiler sees it, so the suite
 * cannot compile the arithmetic the way the target will. This file is compiled as strict C99
 * with the library's own warning set, which makes `restrict` live and lets the optimiser act
 * on it, and it proves the header is includable from C99 at all -- a C++-only construct in
 * dsp.h would otherwise go unnoticed until someone built the firmware.
 *
 * It is not an aliasing detector: breaking a restrict promise is undefined, not diagnosed.
 * What it checks is that every call the header documents gives the same answer when the
 * promise is kept, that the ABI guard agrees with the header the caller compiled against,
 * and that the refusals refuse.
 *
 * Deliberately no framework. Printing the first failure and returning 1 is all ctest needs,
 * and a C99 TU that pulled in a C++ test framework would defeat its own purpose.
 */

#include "dsp.h"

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define PI 3.14159265358979323846

static int failures = 0;
static int checks = 0;

static void check(int ok, const char *what) {
    checks++;
    if (!ok) {
        failures++;
        printf("FAIL: %s\n", what);
    }
}

static void check_near(double got, double want, double tol, const char *what) {
    checks++;
    /* Written as a positive, so a NaN fails rather than passing a negated comparison. */
    if (!(fabs(got - want) <= tol)) {
        failures++;
        printf("FAIL: %s: got %.17g, want %.17g, tolerance %.3g\n", what, got, want, tol);
    }
}

/* An undecimated bin-to-hertz map: bin k is k*binhz. */
static int ReduceFlat(const dsp_real *pwr, int nbins, int k0, int k1, int nseg, double binhz,
                      double dbmin, double dbmax, double vfloor, dsp_real *db, dsp_real *hz) {
    dsp_bandmap m;
    m.f0 = 0.0;
    m.binhz = binhz;
    m.sense = 1;
    m.zone = 0;
    return dsp_reduce(pwr, nbins, k0, k1, nseg, &m, dbmin, dbmax, vfloor, db, hz);
}

/* Over-allocate and round up, which is the idiom DSP_ALIGN documents. */
static unsigned char *align_up(unsigned char *p) {
    while (((uintptr_t)p & (uintptr_t)(DSP_ALIGN - 1)) != 0)
        p++;
    return p;
}

/* ------------------------------------------------------------------------- */

/* The ABI guard. A header compiled without DSP_DOUBLE against a library built with it links
 * cleanly and misreads every stride, so there has to be something to compare. */
static void test_abi(void) {
    check(dsp_real_size == (int)sizeof(dsp_real), "dsp_real_size agrees with the header");
    check(dsp_real_size == 4 || dsp_real_size == 8, "dsp_real is float or double");
}

/* One tone through the whole frame, with every buffer separately allocated so no restrict
 * promise is broken and the optimiser is free to act on all of them. */
static void test_frame(int method) {
    const int n = 1024;
    const double fs = 100000.0;
    const double bin = 100.37;
    size_t bytes = dsp_plan_bytes(n, 1, method);
    unsigned char *raw = (unsigned char *)malloc(bytes + DSP_ALIGN);
    double *src = (double *)malloc((size_t)n * sizeof(double));
    dsp_plan p;
    int i, k, best = 0, rc;
    double d = 0.0, amp = 0.0;

    if (raw == NULL || src == NULL) {
        printf("FAIL: out of memory\n");
        failures++;
        free(raw);
        free(src);
        return;
    }
    for (i = 0; i < n; i++)
        src[i] = 1.0 * cos(2.0 * PI * bin * (double)i / (double)n + 0.3);

    rc = dsp_plan_init(&p, align_up(raw), bytes, n, DSP_WINDOW_HANN, 0.0, 1, method);
    check(rc == DSP_OK, "dsp_plan_init accepts an aligned arena of the size it asked for");
    if (rc != DSP_OK) {
        free(raw);
        free(src);
        return;
    }
    check(p.n == n, "the plan records n");
    check(p.m == n / 2, "m is n/2");
    check(p.method == method, "n=1024 is above every substitution threshold");

    rc = dsp_spectrum_run(&p, src, n, NULL);
    check(rc == p.m, "a frame returns the bin count");

    for (k = 0; k < p.m; k++)
        if (p.pwr[k] > p.pwr[best])
            best = k;
    check(best == 100, "the tone lands in bin 100");

    /* The sub-bin estimate, which is the reason the interpolation tables exist. */
    rc = dsp_peak_interp(&p.ip, p.pwr, best, p.m, &d, &amp);
    check(rc == DSP_OK, "the peak interpolation accepts a mid-spectrum peak");
    check_near((double)best + d, bin, 0.01, "the recovered bin position");
    check_near(amp, 1.0, 0.01, "the recovered amplitude");

    /* The peak search and the segment reduction over the same spectrum, into their own
     * buffers. dsp_peaks writes three arrays that must not alias each other or pwr. */
    {
        int binsout[6];
        dsp_real frac[6], amps[6];
        int found = dsp_peaks(p.pwr, p.m, 0, p.m - 1, p.kdc, 6, &p.ip, binsout, frac, amps);
        check(found >= 1, "the peak search finds the tone");
        if (found >= 1) {
            check(binsout[0] == 100, "and ranks it first");
            check_near((double)binsout[0] + (double)frac[0], bin, 0.01, "its ranked position");
            check_near((double)amps[0], 1.0, 0.01, "its ranked amplitude");
        }
    }
    {
        const int nseg = 255;
        dsp_real *db = (dsp_real *)malloc((size_t)nseg * sizeof(dsp_real));
        dsp_real *hz = (dsp_real *)malloc((size_t)nseg * sizeof(dsp_real));
        double binhz = dsp_binwidth(fs, n, 1);
        if (db == NULL || hz == NULL) {
            printf("FAIL: out of memory\n");
            failures++;
        } else {
            int c, at = 0;
            rc = ReduceFlat(p.pwr, p.m, 0, p.m - 1, nseg, binhz, -120.0, 20.0, 1e-9, db, hz);
            check(rc == nseg, "the reduction writes every segment");
            for (c = 0; c < nseg; c++)
                if (db[c] > db[at])
                    at = c;
            check_near((double)db[at], 0.0, 1.5, "a 1 V tone reaches the trace near 0 dBV");
            check_near((double)hz[at], bin * binhz, 2.0 * binhz * (double)p.m / (double)nseg,
                       "at its own segment's frequency");
            for (c = 1; c < nseg; c++)
                if (!(hz[c] > hz[c - 1])) {
                    check(0, "the segment frequencies are strictly increasing");
                    break;
                }
        }
        free(db);
        free(hz);
    }
    free(raw);
    free(src);
}

/* The decimating path, which is the one with a filter in it. Source, taps and output are
 * three separate allocations. */
static void test_decimating_frame(void) {
    const int n = 512;
    const double fs = 1000000.0;
    const double fhi = 20000.0;
    const int decim = 4;
    size_t bytes = dsp_plan_bytes(n, decim, DSP_FFT_DEFAULT);
    unsigned char *raw = (unsigned char *)malloc(bytes + DSP_ALIGN);
    dsp_real *taps = (dsp_real *)malloc((size_t)DSP_FIR_MAXTAPS * sizeof(dsp_real));
    dsp_plan p;
    int ntaps, need, rc, i, k, best = 0;
    double *src = NULL;
    double tonehz = 5000.0;

    if (raw == NULL || taps == NULL) {
        printf("FAIL: out of memory\n");
        failures++;
        free(raw);
        free(taps);
        return;
    }
    rc = dsp_plan_init(&p, align_up(raw), bytes, n, DSP_WINDOW_HANN, 0.0, decim, DSP_FFT_DEFAULT);
    check(rc == DSP_OK, "a decimating plan builds");
    if (rc != DSP_OK) {
        free(raw);
        free(taps);
        return;
    }
    check(p.fir_out != NULL, "a decimating plan has the FIR output scratch");
    check(p.ntaps == 0, "and no filter until one is installed");

    /* Without the taps the frame must refuse rather than run unfiltered. */
    need = dsp_fir_srclength(n, decim, 101);
    src = (double *)malloc((size_t)need * sizeof(double));
    if (src == NULL) {
        printf("FAIL: out of memory\n");
        failures++;
        free(raw);
        free(taps);
        return;
    }
    for (i = 0; i < need; i++)
        src[i] = cos(2.0 * PI * tonehz * (double)i / fs + 0.1);
    check(dsp_spectrum_run(&p, src, need, NULL) == DSP_EARG,
          "a decimating plan with no taps refuses the frame");

    ntaps = dsp_fir_design(taps, DSP_FIR_MAXTAPS, fs, 0.0, fhi, decim, 0);
    check(ntaps > 0, "the filter designs");
    check(dsp_plan_set_fir(&p, taps, ntaps) == ntaps, "and installs");
    check(p.ntaps == ntaps, "which is what the plan reports");

    need = dsp_fir_srclength(n, decim, ntaps);
    check(need == (n - 1) * decim + ntaps, "the source length is the record the filter eats");
    free(src);
    src = (double *)malloc((size_t)need * sizeof(double));
    if (src == NULL) {
        printf("FAIL: out of memory\n");
        failures++;
        free(raw);
        free(taps);
        return;
    }
    for (i = 0; i < need; i++)
        src[i] = cos(2.0 * PI * tonehz * (double)i / fs + 0.1);

    check(dsp_spectrum_run(&p, src, need - 1, NULL) == DSP_ESHORT,
          "one reading short is refused, not zero-padded");
    rc = dsp_spectrum_run(&p, src, need, NULL);
    check(rc == p.m, "the decimating frame runs");
    for (k = 0; k < p.m; k++)
        if (p.pwr[k] > p.pwr[best])
            best = k;
    /* The decimated bin width, which is the whole point of decimating. */
    check_near((double)best * dsp_binwidth(fs, n, decim), tonehz, 2.0 * dsp_binwidth(fs, n, decim),
               "the tone is at its own frequency after decimation");

    free(src);
    free(raw);
    free(taps);
}

/* The refusals, which are the paths a C++ suite can reach too but which have to be reachable
 * from C99 with the same answers -- a different return code here would mean the two builds
 * disagree about the interface. */
static void test_refusals(void) {
    dsp_real w[64];
    dsp_real h[64];
    dsp_plan p;
    double d = 0.0;

    check(dsp_window(NULL, 64, DSP_WINDOW_HANN, 0.0) == DSP_EARG, "a null window buffer");
    check(dsp_window(w, 1, DSP_WINDOW_HANN, 0.0) == DSP_EARG, "a window of one sample");
    check(dsp_window(w, 64, 99, 0.0) == DSP_EARG, "an unknown window kind");
    check(dsp_window(w, 64, DSP_WINDOW_KAISER, 1.0) == DSP_EBETA, "beta below the floor");
    check(dsp_window(w, 64, DSP_WINDOW_KAISER, DSP_KAISER_BETA_MAX + 1.0) == DSP_EBETA,
          "beta past the ceiling");
    check(dsp_window(w, 64, DSP_WINDOW_HANN, 0.0) == DSP_OK, "and a good one is accepted");

    check(dsp_plan_init(NULL, w, sizeof w, 64, DSP_WINDOW_HANN, 0.0, 1, DSP_FFT_DEFAULT) ==
              DSP_EARG,
          "a null plan");
    check(dsp_plan_init(&p, NULL, 1024, 64, DSP_WINDOW_HANN, 0.0, 1, DSP_FFT_DEFAULT) == DSP_EARG,
          "a null arena");
    check(dsp_plan_bytes(63, 1, DSP_FFT_DEFAULT) == 0, "a count that is not a power of two");
    check(dsp_plan_bytes(DSP_N_MAX * 2, 1, DSP_FFT_DEFAULT) == 0, "a count past the ceiling");
    check(dsp_plan_bytes(64, 0, DSP_FFT_DEFAULT) == 0, "a decimation below one");
    check(dsp_plan_bytes(64, 1, DSP_FFT_COUNT) == 0, "an unknown decomposition");

    check(dsp_fir_design(NULL, 64, 1e6, 0.0, 2e4, 4, 0) == DSP_EARG, "a null tap buffer");
#if DSP_BANDPASS
    check(dsp_fir_design(h, 64, 1e6, 2000.0, 20000.0, 2, 0) > 0, "a band-pass designs");
#else
    check(dsp_fir_design(h, 64, 1e6, 2000.0, 20000.0, 2, 0) == DSP_EUNSUPPORTED,
          "a low-pass-only build refuses a band-pass");
#endif
    check(dsp_fir_design(h, 64, 1e6, 2e4, 2e4, 4, 0) == DSP_EARG, "an empty band is refused");
    check(dsp_fir_design(h, 64, 1e6, 0.0, 2e4, 1, 0) == 0, "no decimation means no filter");
    check(dsp_fir_srclength(32768, 100000, 101) == 0,
          "a source record whose length would overflow an int");
    check(dsp_fir_run(NULL, 64, h, 3, 1, NULL) == DSP_EARG, "a null FIR source");

    check(dsp_win_offset(NULL, 0.0, &d) == DSP_EARG, "a null interpolation table");
    check_near(dsp_win_gain(NULL, 0.5), 1.0, 0.0, "a null table gives unit gain");
    check(dsp_peak_interp(NULL, NULL, 1, 64, NULL, NULL) == DSP_EARG, "a null peak interpolation");
    check(dsp_peaks(NULL, 64, 0, 63, 0, 6, NULL, NULL, NULL, NULL) == DSP_EARG, "a null peak search");
    check(ReduceFlat(NULL, 64, 0, 63, 8, 1.0, -120.0, 20.0, 1e-9, NULL, NULL) == DSP_EARG,
          "a null reduction");
    check(dsp_spectrum_run(NULL, NULL, 0, NULL) == DSP_EARG, "a null frame");
}

/* The out-of-range double-to-int conversions, which at -O1 trapped rather than clamped. The
 * C99 build is where that matters: the trap was emitted from this exact source. */
static void test_range_clamps(void) {
    const int n = 256;
    size_t bytes = dsp_plan_bytes(n, 1, DSP_FFT_DEFAULT);
    unsigned char *raw = (unsigned char *)malloc(bytes + DSP_ALIGN);
    dsp_plan p;
    double d = 0.0, g;

    if (raw == NULL) {
        printf("FAIL: out of memory\n");
        failures++;
        return;
    }
    if (dsp_plan_init(&p, align_up(raw), bytes, n, DSP_WINDOW_HANN, 0.0, 1, DSP_FFT_DEFAULT) !=
        DSP_OK) {
        printf("FAIL: the plan for the clamp test did not build\n");
        failures++;
        free(raw);
        return;
    }
    /* check_near with a zero tolerance, not ==: the comparison wanted here is exact, and
     * -Wfloat-equal is on because everywhere else in this code an exact one is a mistake. */
    g = dsp_win_gain(&p.ip, 1e30);
    check_near(g, p.ip.gtab[DSP_GN], 0.0, "a huge offset clamps to the end of the gain table");
    g = dsp_win_gain(&p.ip, (double)NAN);
    check_near(g, p.ip.gtab[DSP_GN], 0.0, "and so does a NaN");
    check(!isnan(g), "the clamped gain is finite");

    check(dsp_win_offset(&p.ip, 0.0, NULL) == DSP_EARG, "a null offset output is refused");
    check(dsp_win_offset(&p.ip, 1e30, &d) == DSP_OK, "a huge ratio is accepted");
    check(!isnan(d) && d > 0.0 && d <= 0.5, "and saturates inside half a bin");
    d = 0.0;
    check(dsp_win_offset(&p.ip, (double)NAN, &d) == DSP_OK, "a NaN ratio is accepted");
    check(!isnan(d), "and does not put a NaN in the output");
    free(raw);
}

/* The new entry points through a C99 TU, where the restrict promises are live. Separate
 * allocations for the power array and the result, so no promise is broken. */
static void test_thd_noise(void) {
    const int nb = 256;
    dsp_real *pwr = (dsp_real *)malloc((size_t)nb * sizeof(dsp_real));
    dsp_thdn *out = (dsp_thdn *)malloc(sizeof(dsp_thdn));
    int i;
    if (pwr == NULL || out == NULL) {
        printf("FAIL: out of memory\n");
        failures++;
        free(pwr);
        free(out);
        return;
    }
    for (i = 0; i < nb; i++)
        pwr[i] = (dsp_real)1e-10;
    pwr[60] = (dsp_real)1.0;      /* 1 V */
    pwr[120] = (dsp_real)0.0025;  /* 0.05 V, so 5% by definition */

    check(dsp_thd_noise(pwr, nb, 1, 130, 0, 0.0, DSP_THD_MAINS_BOTH, NULL, out) == DSP_OK, "thd_noise accepts");
    check(out->nharm == 1, "one harmonic fits below the window top");
    check(out->nnoise == 116, "116 bins survive the two skirts");
    check_near(out->thd, 0.05, 1e-4, "thd is a fraction, not a percentage");
    check_near(out->noise_db, -100.0, 0.05, "the floor is the mean power put in");
    check_near(out->snr_db, 79.355, 0.1, "snr is against the integrated noise");
    check(out->signal != 0, "a 1 V line over a 1e-10 floor is a signal");

    /* The refusals, which must answer the same here as in the C++ build. */
    check(dsp_thd_noise(NULL, nb, 1, 130, 0, 0.0, DSP_THD_MAINS_BOTH, NULL, out) == DSP_EARG, "a null spectrum");
    check(dsp_thd_noise(pwr, nb, 1, 130, 0, 0.0, DSP_THD_MAINS_BOTH, NULL, NULL) == DSP_EARG, "a null result");
    check(dsp_thd_noise(pwr, 4, 1, 3, 0, 0.0, DSP_THD_MAINS_BOTH, NULL, out) == DSP_EARG, "too few bins");
    check(dsp_thd_noise(pwr, nb, 1, 4, 0, 0.0, DSP_THD_MAINS_BOTH, NULL, out) == DSP_EARG, "a window under five");

    /* Mains pickup, which needs a bin width to be placed at all. */
    for (i = 0; i < nb; i++)
        pwr[i] = (dsp_real)1e-12;
    pwr[6] = (dsp_real)1e-3;      /* 60 Hz at 10 Hz bins, under -22 dBV */
    check(dsp_thd_noise(pwr, nb, 1, 254, 0, 10.0, DSP_THD_MAINS_BOTH, NULL, out) == DSP_OK, "a hum spectrum runs");
    check(out->signal == 0, "60 Hz pickup is not a signal");
    check(dsp_thd_noise(pwr, nb, 1, 254, 0, 0.0, DSP_THD_MAINS_BOTH, NULL, out) == DSP_OK, "and without binhz");
    check(out->signal != 0, "binhz 0 switches the mains rule off");

    /* Selecting the other region gives the line back. 2 Hz bins, so the tolerance cannot
     * reach from 50 to 60. */
    for (i = 0; i < nb; i++)
        pwr[i] = (dsp_real)1e-12;
    pwr[30] = (dsp_real)2e-3;     /* 60 Hz at 2 Hz bins */
    check(dsp_thd_noise(pwr, nb, 1, 254, 0, 2.0, (int)DSP_THD_MAINS_B, NULL, out) == DSP_OK,
          "60 Hz selected");
    check(out->signal == 0, "and that line is pickup");
    check(dsp_thd_noise(pwr, nb, 1, 254, 0, 2.0, (int)DSP_THD_MAINS_A, NULL, out) == DSP_OK,
          "50 Hz selected");
    check(out->signal != 0, "and the same line is a tone");
    check(dsp_thd_noise(pwr, nb, 1, 254, 0, 2.0, 55, NULL, out) == DSP_EARG,
          "a frequency that is neither mains is refused");

    check(dsp_strerror(DSP_EZONE) != NULL, "every code has a message");
    check(dsp_strerror(-999)[0] == 'u', "and an unknown one says so");

    check(dsp_window_lobe(DSP_WINDOW_HANN, 0.0) == 2, "Hann's lobe is two bins");
    check(dsp_window_lobe(DSP_WINDOW_KAISER, 18.0) == 6, "Kaiser 18's is six");
    check(dsp_window_lobe(DSP_WINDOW_COUNT, 0.0) == 0, "an unknown window has none");

    free(pwr);
    free(out);
}

int main(void) {
    int method;
    printf("dsp_c99_test: %s precision, C99, DSP_RESTRICT is \"%s\"\n",
           sizeof(dsp_real) == 4 ? "single" : "double",
#if defined(__STDC_VERSION__) && __STDC_VERSION__ >= 199901L
           "restrict"
#else
           "(empty)"
#endif
    );
    test_abi();
    for (method = 0; method < DSP_FFT_COUNT; method++)
        test_frame(method);
    test_decimating_frame();
    test_refusals();
    test_range_clamps();
    test_thd_noise();
    printf("dsp_c99_test: %d checks, %d failures\n", checks, failures);
    return failures == 0 ? 0 : 1;
}
