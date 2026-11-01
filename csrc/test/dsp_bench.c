/* dsp_bench.c -- host timings and modelled cache traffic for the three FFT decompositions.
 *
 * Not a ctest target: a benchmark under ctest makes the suite slow and its timings flaky.
 *
 * The host timing is the less useful half and says so when it prints. This machine has
 * megabytes of cache; the target has 32 kB with 32-byte blocks, and at 16,384 samples the
 * transform's working set is nine times that. Everything the four-step is for is invisible
 * here, so the model is what decides and the timing only shows the arithmetic and
 * bookkeeping cost.
 */

#include "dsp.h"

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

/* e300c4 data cache: 32 kB, eight-way, 32-byte blocks. */
#define CACHE_BYTES 32768
#define LINE_BYTES 32

static const char *method_name(int method) {
    switch (method) {
    case DSP_FFT_RADIX2:
        return "radix-2 in place";
    case DSP_FFT_FOURSTEP:
        return "four-step";
    default:
        return "?";
    }
}

static int ilog2(int v) {
    int b = 0;
    while (v > 1) {
        v >>= 1;
        b++;
    }
    return b;
}

/* Modelled traffic on the two signal arrays for one transform, in cache-block fills and
 * writebacks. Only the signal arrays are counted: both decompositions read the same
 * twiddle table in the same order, so it cannot separate them, and counting it would bury
 * the difference under a common term. Stated rather than hidden.
 *
 * A pass is one sweep in which every block of re and im is touched. An in-place pass reads
 * a block, modifies it and writes it back: one fill, one writeback. An out-of-place pass
 * reads the source and writes a different block, and a write-allocate cache fetches the
 * destination before merging: two fills, one writeback.
 *
 *   radix-2   log2(m) butterfly stages plus one bit-reversal pass, all in place.
 *   four-step gather and scatter (out of place), the row transforms (in place), and the
 *             output transpose (out of place). Three passes whatever m is, because each
 *             sub-transform is a few kB and completes without leaving the cache.
 */
static void model(int m, int method, double *fills, double *wbacks, int *working) {
    double lines = (double)(2 * m * (int)sizeof(dsp_real)) / (double)LINE_BYTES;
    int stages = ilog2(m);
    int twiddle_bytes = 2 * (m - 2) * (int)sizeof(dsp_real);
    int data_bytes = 2 * m * (int)sizeof(dsp_real);
    int m1 = 1 << (stages / 2);

    /* What each decomposition has to keep live. The in-place form needs the signal arrays and
     * the twiddles; the four-step needs a second signal array and a gather block as well. That
     * second array is what pushes it over the line first, and the step in the counts below is
     * that boundary rather than a modelling artefact. */
    if (method == DSP_FFT_RADIX2)
        *working = data_bytes + twiddle_bytes;
    else
        *working = 2 * data_bytes + twiddle_bytes + 2 * DSP_FS_BLOCK * m1 * (int)sizeof(dsp_real);

    /* Resident: the compulsory traffic only. An in-place pass reads a block, modifies it and
   * writes it back; an out-of-place pass also has to fetch the destination before merging,
   * which a write-allocate cache does. */
    if (*working <= CACHE_BYTES) {
        *fills = (method == DSP_FFT_RADIX2) ? lines : 2.0 * lines;
        *wbacks = lines;
        return;
    }

    switch (method) {
    case DSP_FFT_FOURSTEP:
        /* Three passes whatever m is, because each sub-transform is a few kB and completes
       * without leaving the cache: gather and scatter (out of place), the row transforms
       * (in place), and the output transpose (out of place). */
        *fills = 5.0 * lines;
        *wbacks = 3.0 * lines;
        break;
    default:
        *fills = (double)(stages + 1) * lines; /* stages plus the bit-reversal pass */
        *wbacks = (double)(stages + 1) * lines;
        break;
    }
}

int main(void) {
    static const int counts[] = {512, 2048, 8192, 16384, 32768};
    const int ncounts = (int)(sizeof(counts) / sizeof(counts[0]));
    int ci, method;

    printf("dsp_bench: %s precision, dsp_real is %d bytes\n",
           sizeof(dsp_real) == 4 ? "single" : "double", (int)sizeof(dsp_real));
    printf("host timings are from this machine's cache hierarchy, not the target's; the\n"
           "modelled columns are for a %d-byte eight-way cache with %d-byte blocks.\n\n",
           CACHE_BYTES, LINE_BYTES);
    printf("%7s %5s %18s %10s %9s %9s %11s %11s %9s\n", "N", "m", "method", "ms", "reps", "live kB",
           "fills", "writebacks", "vs rdx2");

    for (ci = 0; ci < ncounts; ci++) {
        const int n = counts[ci];
        double *src = (double *)malloc((size_t)n * sizeof(double));
        double base_traffic = 0.0;
        int i;

        if (src == NULL) {
            printf("out of memory at N=%d\n", n);
            return 1;
        }
        for (i = 0; i < n; i++) {
            double t = (double)i / 100000.0;
            src[i] = 2.5 + 0.7 * sin(2.0 * 3.14159265358979323846 * 12345.0 * t) +
                     0.3 * sin(2.0 * 3.14159265358979323846 * 4000.0 * t + 0.5);
        }

        /* A plan each, because the arena is sized for one decomposition. That is also the
         * fairer measurement: each method gets exactly the footprint it would ship with. */
        for (method = 0; method < DSP_FFT_COUNT; method++) {
            size_t bytes = dsp_plan_bytes(n, 1, method);
            unsigned char *raw = NULL;
            void *arena;
            dsp_plan p;
            double fills, wbacks, traffic, ms;
            int reps = 1, working = 0;
            clock_t t0, t1;

            if (bytes == 0) {
                printf("N=%d %s refused\n", n, method_name(method));
                continue;
            }
            raw = (unsigned char *)malloc(bytes + DSP_ALIGN);
            if (raw == NULL) {
                printf("out of memory at N=%d\n", n);
                free(src);
                return 1;
            }
            /* Round up by hand: C99 has no aligned_alloc and the plan wants DSP_ALIGN. */
            {
                unsigned char *at = raw;
                while (((uintptr_t)at & (uintptr_t)(DSP_ALIGN - 1)) != 0)
                    at++;
                arena = at;
            }
            if (dsp_plan_init(&p, arena, bytes, n, DSP_WINDOW_HANN, 0.0, 1, method) != DSP_OK) {
                printf("plan refused at N=%d %s\n", n, method_name(method));
                free(raw);
                continue;
            }
            /* p.method, not the loop variable: below DSP_FS_MIN a four-step request builds a
             * radix-2 plan, and timing it as the four-step would report radix-2 twice. */
            model(p.m, p.method, &fills, &wbacks, &working);
            traffic = fills + wbacks;
            if (p.method == DSP_FFT_RADIX2 && method == DSP_FFT_RADIX2)
                base_traffic = traffic;

            /* Grow the repeat count until the measurement is worth reading: clock() has
             * microsecond granularity at best and measures CPU time. */
            for (;;) {
                t0 = clock();
                for (i = 0; i < reps; i++) {
                    dsp_load(src, p.n, p.w, p.wsum, p.re, p.im, NULL);
                    dsp_rfft(&p);
                }
                t1 = clock();
                ms = 1000.0 * (double)(t1 - t0) / (double)CLOCKS_PER_SEC;
                if (ms >= 200.0 || reps >= (1 << 22))
                    break;
                reps *= 4;
            }
            printf("%7d %5d %18s %10.4f %9d %9.1f %11.0f %11.0f %8.2fx%s%s\n", n, p.m,
                   method_name(p.method), ms / (double)reps, reps, (double)working / 1024.0, fills,
                   wbacks, base_traffic > 0.0 ? traffic / base_traffic : 0.0,
                   working <= CACHE_BYTES ? " fits" : "",
                   p.method != method ? " (substituted)" : "");
            free(raw);
        }
        printf("\n");
        free(src);
    }
    return 0;
}
