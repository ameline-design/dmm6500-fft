/* What does the filter's source-record length actually cost?
 *
 * DSP_FIR_MAXM caps the decimation dsp_fir_pick_decim will offer, through
 * (DSP_FIR_MAXM - maxtaps)/(n-1), and its stated reason is a 22 us-per-reading buffer cost.
 * That is the Lua's marshalling cost across the TSP boundary; on this side the readings are
 * doubles already in memory. So: measure what M costs here. */
#include "dsp.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

static double now_s(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (double)t.tv_sec + 1e-9 * (double)t.tv_nsec;
}

int main(void) {
    static const int counts[] = {512, 1024, 2048, 4096, 8192, 16384};
    static const int decims[] = {2, 4, 8, 16, 32, 64, 128};
    const double fs = 1e6;
    int ci, di;
    printf("%7s %6s %8s %8s %7s %10s %12s %10s %9s\n",
           "n", "decim", "M", "taps", "ny", "MAC", "host ms", "ns/out", "src kB");
    for (ci = 0; ci < (int)(sizeof counts / sizeof *counts); ci++) {
        const int n = counts[ci];
        for (di = 0; di < (int)(sizeof decims / sizeof *decims); di++) {
            const int d = decims[di];
            dsp_real h[DSP_FIR_MAXTAPS];
            double *x, *y, t0, el;
            long M = (long)(n - 1) * d;
            int taps, ny, reps, r;
            double fhi = fs / (2.0 * (double)d) * 0.7;
            taps = dsp_fir_design(h, DSP_FIR_MAXTAPS, fs, 0.0, fhi, d, 0);
            if (taps <= 0)
                continue;
            M += taps;
            if (M > DSP_SRC_MAX)
                continue;
            x = (double *)malloc((size_t)M * sizeof *x);
            y = (double *)malloc((size_t)n * sizeof *y + 64);
            if (x == NULL || y == NULL) { free(x); free(y); continue; }
            for (r = 0; r < M; r++)
                x[r] = sin(2.0 * 3.14159265358979 * 1000.0 * (double)r / fs);
            ny = dsp_fir_run(x, (int)M, h, taps, d, y);
            if (ny <= 0) { free(x); free(y); continue; }
            reps = (int)(2e8 / ((double)ny * (double)taps));
            if (reps < 3) reps = 3;
            if (reps > 2000) reps = 2000;
            t0 = now_s();
            for (r = 0; r < reps; r++)
                dsp_fir_run(x, (int)M, h, taps, d, y);
            el = (now_s() - t0) / (double)reps;
            printf("%7d %6d %8ld %8d %7d %10.3g %12.4f %10.2f %9.1f\n",
                   n, d, M, taps, ny, (double)ny * (double)taps, el * 1e3,
                   el * 1e9 / (double)ny, (double)M * 8.0 / 1024.0);
            free(x);
            free(y);
        }
        printf("\n");
    }
    return 0;
}
