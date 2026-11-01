/*
 * conform_driver.c -- drive the C library over one conformance case and print the results.
 *
 *   dsp_conform_double <case> <out> [radix2|fourstep]
 *
 * The other half of notes/dsp-private/conform: the Lua driver runs the same case through
 * dsp.* and a comparator diffs the two. Everything printed here is something the proposed
 * TSP API hands a caller -- the trace, the peaks, the three distortion figures and the
 * window they were computed over -- because that is all the switch can change.
 *
 * The map is taken over the whole spectrum and the window comes from dsp_band_bins, which
 * is how a native TSP binding would do it: dsp.out.lowfreq/highfreq are hertz and the
 * primitive owns the conversion.
 */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "dsp.h"

#define MAXSEG 4096
#define MAXPK 64

struct spec {
    int n, window, segments, peaks, thd_harmonics, thd_bins, thd_mains;
    double fs, beta, flo, fhi, dbfloor, dbceil, vfloor;
    int nsamples;
    double *samples;
};

static int readspec(const char *path, struct spec *s) {
    char line[256], key[64];
    FILE *f = fopen(path, "r");
    int cap = 1024;
    if (f == NULL)
        return -1;
    memset(s, 0, sizeof(*s));
    s->samples = (double *)malloc((size_t)cap * sizeof(double));
    if (s->samples == NULL) {
        fclose(f);
        return -1;
    }
    while (fgets(line, (int)sizeof(line), f) != NULL) {
        double v = 0.0;
        if (sscanf(line, "%63s", key) != 1)
            continue;
        if (strcmp(key, "samples") == 0) {
            /* Everything after this key is one sample a line. */
            while (fgets(line, (int)sizeof(line), f) != NULL) {
                if (sscanf(line, "%lf", &v) != 1)
                    continue;
                if (s->nsamples == cap) {
                    double *bigger;
                    cap *= 2;
                    bigger = (double *)realloc(s->samples, (size_t)cap * sizeof(double));
                    if (bigger == NULL) {
                        fclose(f);
                        return -1;
                    }
                    s->samples = bigger;
                }
                s->samples[s->nsamples++] = v;
            }
            break;
        }
        if (sscanf(line + strlen(key), "%lf", &v) != 1)
            continue;
        if (strcmp(key, "n") == 0)
            s->n = (int)v;
        else if (strcmp(key, "fs") == 0)
            s->fs = v;
        else if (strcmp(key, "window") == 0)
            s->window = (int)v;
        else if (strcmp(key, "beta") == 0)
            s->beta = v;
        else if (strcmp(key, "flo") == 0)
            s->flo = v;
        else if (strcmp(key, "fhi") == 0)
            s->fhi = v;
        else if (strcmp(key, "segments") == 0)
            s->segments = (int)v;
        else if (strcmp(key, "peaks") == 0)
            s->peaks = (int)v;
        else if (strcmp(key, "dbfloor") == 0)
            s->dbfloor = v;
        else if (strcmp(key, "dbceil") == 0)
            s->dbceil = v;
        else if (strcmp(key, "vfloor") == 0)
            s->vfloor = v;
        else if (strcmp(key, "thd_harmonics") == 0)
            s->thd_harmonics = (int)v;
        else if (strcmp(key, "thd_bins") == 0)
            s->thd_bins = (int)v;
        else if (strcmp(key, "thd_mains") == 0)
            s->thd_mains = (int)v;
    }
    fclose(f);
    return 0;
}

static void emitnum(FILE *o, const char *k, double v) {
    if (v != v)
        fprintf(o, "%s nan\n", k);
    else
        fprintf(o, "%s %.17g\n", k, v);
}

int main(int argc, char **argv) {
    struct spec s;
    dsp_plan p;
    dsp_bandmap map;
    dsp_thdn thd;
    void *arena;
    size_t bytes;
    double mean = 0.0, binhz;
    int method = DSP_FFT_RADIX2, rc, k0 = 0, k1 = 0, nbins, nseg, npk, i;
    dsp_real *db, *hz, *amp, *frac;
    int *bin;
    FILE *o;

    if (argc < 3) {
        fprintf(stderr, "usage: %s <case> <out> [radix2|fourstep]\n", argv[0]);
        return 2;
    }
    if (argc > 3 && strcmp(argv[3], "fourstep") == 0)
        method = DSP_FFT_FOURSTEP;
    if (readspec(argv[1], &s) != 0) {
        fprintf(stderr, "cannot read %s\n", argv[1]);
        return 2;
    }
    o = fopen(argv[2], "w");
    if (o == NULL) {
        fprintf(stderr, "cannot write %s\n", argv[2]);
        return 2;
    }

    bytes = dsp_plan_bytes(s.n, 1, method);
    if (bytes == 0) {
        fprintf(o, "commit refused-bytes\n");
        fclose(o);
        return 0;
    }
    arena = malloc(bytes);
    if (arena == NULL) {
        fprintf(o, "commit nomem\n");
        fclose(o);
        return 0;
    }
    rc = dsp_plan_init(&p, arena, bytes, s.n, s.window, s.beta, 1, method);
    fprintf(o, "commit %d\n", rc);
    if (rc != DSP_OK) {
        fprintf(o, "commit_msg %s\n", dsp_strerror(rc));
        fclose(o);
        free(arena);
        return 0;
    }
    nbins = p.m;
    binhz = dsp_binwidth(s.fs, s.n, 1);
    emitnum(o, "binwidth", binhz);
    fprintf(o, "srclength %d\n", dsp_fir_srclength(s.n, 1, 0));

    rc = dsp_spectrum_run(&p, s.samples, s.nsamples, &mean);
    fprintf(o, "spectrum %d\n", rc);
    if (rc > 0) {
        /* Zone 0 over the whole spectrum, which is what an undecimated plan produces and
         * what the Lua assumes: f0 of 0 and frequency rising with the bin. */
        rc = dsp_band_map(s.fs, 0.0, s.fs / 2.0, s.n, 1, &map);
        if (rc != DSP_OK) {
            fprintf(o, "bandmap %d\n", rc);
            fclose(o);
            free(arena);
            return 0;
        }
        rc = dsp_band_bins(&map, s.flo, s.fhi, nbins, &k0, &k1);
        if (rc != DSP_OK) {
            fprintf(o, "bandbins %d\n", rc);
            fclose(o);
            free(arena);
            return 0;
        }
        fprintf(o, "k0 %d\nk1 %d\nnbins %d\n", k0, k1, nbins);
        emitnum(o, "binwidth_run", map.binhz);

        nseg = s.segments > MAXSEG ? MAXSEG : s.segments;
        db = (dsp_real *)malloc((size_t)nseg * sizeof(dsp_real));
        hz = (dsp_real *)malloc((size_t)nseg * sizeof(dsp_real));
        if (db == NULL || hz == NULL)
            return 2;
        rc = dsp_reduce(p.pwr, nbins, k0, k1, nseg, &map, s.dbfloor, s.dbceil, s.vfloor,
                        db, hz);
        fprintf(o, "nseg %d\n", rc);
        for (i = 0; i < rc; i++) {
            fprintf(o, "seg %d %.17g %.17g\n", i, (double)db[i], (double)hz[i]);
        }

        npk = s.peaks > MAXPK ? MAXPK : s.peaks;
        bin = (int *)malloc((size_t)npk * sizeof(int));
        frac = (dsp_real *)malloc((size_t)npk * sizeof(dsp_real));
        amp = (dsp_real *)malloc((size_t)npk * sizeof(dsp_real));
        if (bin == NULL || frac == NULL || amp == NULL)
            return 2;
        rc = dsp_peaks(p.pwr, nbins, k0, k1, p.kdc, npk, &p.ip, bin, frac, amp);
        for (i = 0; i < rc; i++) {
            /* The peak's frequency, from the map and the sub-bin offset -- the same
             * composition the Lua does, so a bin-versus-hertz mix-up cannot hide. */
            const double f = dsp_bin_hz(&map, bin[i]) +
                             (double)map.sense * (double)frac[i] * map.binhz;
            fprintf(o, "peak %d %.17g %.17g\n", i, f, (double)amp[i]);
        }
        fprintf(o, "npeak %d\n", rc);

        rc = dsp_thd_noise(p.pwr, nbins, k0, k1, p.kdc, binhz, s.thd_mains, &p.ip, &thd);
        fprintf(o, "thd_rc %d\n", rc);
        if (rc == DSP_OK) {
            /* nil where the Lua returns nil: both ratios are meaningless with no tone, and
             * the floor is a number regardless. */
            /* thd is meaningful only with a harmonic inside the window: 0 % on a panel
             * reads as a perfect signal where the harmonics are merely off-screen, so a
             * binding reports nothing. snr needs only a fundamental. */
            if (thd.signal && thd.nharm > 0)
                emitnum(o, "thd", thd.thd);
            else
                fprintf(o, "thd nil\n");
            if (thd.signal)
                emitnum(o, "snr", thd.snr_db);
            else
                fprintf(o, "snr nil\n");
            emitnum(o, "floor", thd.noise_db);
            if (thd.signal)
                emitnum(o, "f0hz", thd.f0_hz);
            else
                fprintf(o, "f0hz nil\n");
            fprintf(o, "nharm %d\nnnoise %d\nstride %d\n", thd.nharm, thd.nnoise,
                    thd.stride);
        }
        free(db);
        free(hz);
        free(bin);
        free(frac);
        free(amp);
    }
    fclose(o);
    free(arena);
    free(s.samples);
    return 0;
}
