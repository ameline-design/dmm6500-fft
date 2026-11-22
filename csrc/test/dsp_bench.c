/* Benchmark host FFT kernels and estimate e300c4 cache traffic on their signal arrays. */

#include "dsp.h"

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

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

/* Count data-cache fills and writebacks on signal arrays; shared twiddles are excluded. */
static void model(int m, int method, double *fills, double *wbacks, int *working) {
    double lines = (double)(2 * m * (int)sizeof(dsp_real)) / (double)LINE_BYTES;
    int stages = ilog2(m);
    int twiddle_bytes = 2 * (m - 2) * (int)sizeof(dsp_real);
    int data_bytes = 2 * m * (int)sizeof(dsp_real);
    int m1 = 1 << (stages / 2);

    /* Include each decomposition's live working arrays when determining cache residency. */
    if (method == DSP_FFT_RADIX2)
        *working = data_bytes + twiddle_bytes;
    else
        *working = 2 * data_bytes + twiddle_bytes + 2 * DSP_FS_BLOCK * m1 * (int)sizeof(dsp_real);

    /* Resident passes pay compulsory traffic only; out-of-place stores allocate destination lines. */
    if (*working <= CACHE_BYTES) {
        *fills = (method == DSP_FFT_RADIX2) ? lines : 2.0 * lines;
        *wbacks = lines;
        return;
    }

    switch (method) {
    case DSP_FFT_FOURSTEP:
        /* Four-step estimates one gather/scatter, row-transform and transpose pass. */
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

        /* Build one arena per decomposition so each uses its actual scratch layout. */
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
            /* Round the allocation to DSP_ALIGN; C99 has no aligned_alloc. */
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
            /* Report the effective method because small four-step requests use radix-2. */
            model(p.m, p.method, &fills, &wbacks, &working);
            traffic = fills + wbacks;
            if (p.method == DSP_FFT_RADIX2 && method == DSP_FFT_RADIX2)
                base_traffic = traffic;

            /* Repeat long enough that clock granularity does not dominate. */
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
