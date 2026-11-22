// Numerical and API conformance in single and double precision.
// Negative controls check that the tolerances reject meaningful defects.

#include "dsp.h"

#include <gtest/gtest.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <limits>
#include <string>
#include <vector>

namespace {

constexpr bool kSingle = sizeof(dsp_real) == 4;

// Use library NaN and infinity constants rather than zero-division expressions.
const double kNaN = std::numeric_limits<double>::quiet_NaN();
const double kInf = std::numeric_limits<double>::infinity();

// Compare bin power with mixed tolerance: rel*reference + absfs*largest_bin.
// The absolute term covers noise-floor bins where relative error is not meaningful.
constexpr double kDftRel = kSingle ? 1e-5 : 1e-9;
constexpr double kDftAbsFs = kSingle ? 5e-10 : 1e-17;
constexpr double kPinnedRel = kSingle ? 3e-6 : 1e-9;
constexpr double kPinnedAbsFs = kSingle ? 5e-12 : 1e-18;

// Coherent gain depends on rounded window samples in float and sum rounding in double.
constexpr double kCgAbs = kSingle ? 1e-8 : 1e-14;
constexpr double kKsqRel = kSingle ? 2e-8 : 6.6e-15;

// The pedestal bound limits residual DC after subtracting the window-weighted mean.
constexpr double kPedestal = kSingle ? 1e-15 : 1e-20;

// Fixtures and reference helpers

// Overallocate and round every arena base to DSP_ALIGN.
unsigned char *AlignUp(unsigned char *p) {
    while ((reinterpret_cast<uintptr_t>(p) & (DSP_ALIGN - 1)) != 0)
        p++;
    return p;
}

// Allocate the workspace for the selected FFT decomposition.
class Plan {
  public:
    Plan(int n, int kind, double beta = 12.0, int decim = 1, int method = DSP_FFT_DEFAULT) {
        bytes_ = dsp_plan_bytes(n, decim, method);
        arena_.assign((bytes_ ? bytes_ : 8u) + DSP_ALIGN, 0);
        rc_ = dsp_plan_init(&p_, AlignUp(arena_.data()), arena_.size() - DSP_ALIGN, n, kind, beta,
                            decim, method);
    }
    int rc() const {
        return rc_;
    }
    size_t bytes() const {
        return bytes_;
    }
    dsp_plan *operator->() {
        return &p_;
    }
    const dsp_plan *operator->() const {
        return &p_;
    }
    dsp_plan &get() {
        return p_;
    }

  private:
    std::vector<unsigned char> arena_;
    size_t bytes_ = 0;
    dsp_plan p_{};
    int rc_ = DSP_EARG;
};

// Undecimated bin map: bin k lies at k*binhz.
dsp_bandmap FlatMap(double binhz) {
    dsp_bandmap m{};
    m.f0 = 0.0;
    m.binhz = binhz;
    m.sense = 1;
    m.zone = 0;
    return m;
}

int ReduceFlat(const dsp_real *pwr, int nbins, int k0, int k1, int nseg, double binhz,
               double dbmin, double dbmax, double vfloor, dsp_real *db, dsp_real *hz) {
    dsp_bandmap m = FlatMap(binhz);
    return dsp_reduce(pwr, nbins, k0, k1, nseg, &m, dbmin, dbmax, vfloor, db, hz);
}

const char *MethodName(int method) {
    switch (method) {
    case DSP_FFT_RADIX2:
        return "radix-2";
    case DSP_FFT_FOURSTEP:
        return "four-step";
    default:
        return "?";
    }
}

const char *WindowName(int kind) {
    switch (kind) {
    case DSP_WINDOW_RECT:
        return "Rect";
    case DSP_WINDOW_HANN:
        return "Hann";
    case DSP_WINDOW_BLACKMAN:
        return "Blackman";
    case DSP_WINDOW_BLACKMAN_HARRIS:
        return "Blk-Harris";
    case DSP_WINDOW_KAISER:
        return "Kaiser";
    default:
        return "?";
    }
}

// Cover every window and Kaiser beta offered by the picker.
struct WinCfg {
    int kind;
    double beta;
    std::string label() const {
        std::string s = WindowName(kind);
        if (kind == DSP_WINDOW_KAISER)
            s += " b=" + std::to_string((int)beta);
        return s;
    }
};

std::vector<WinCfg> ShippedWindows() {
    std::vector<WinCfg> v = {
        {DSP_WINDOW_HANN, 0.0}, {DSP_WINDOW_BLACKMAN, 0.0}, {DSP_WINDOW_BLACKMAN_HARRIS, 0.0}};
    for (double b : {4.0, 6.0, 9.0, 12.0, 15.0, 18.0})
        v.push_back({DSP_WINDOW_KAISER, b});
    return v;
}

int RunSpectrum(Plan &p, const std::vector<double> &x, double *mean = nullptr) {
    double m = 0.0;
    int rc = dsp_load(x.data(), p->n, p->w, p->wsum, p->re, p->im, &m);
    if (rc != DSP_OK)
        return rc;
    dsp_rfft(&p.get());
    dsp_power(p->re, p->im, p->m, p->utr, p->uti, p->pwr, p->ksq);
    if (mean)
        *mean = m;
    return p->m;
}

std::vector<double> ToneAtBin(int n, double bin, double phase = 0.3) {
    std::vector<double> x(n);
    for (int i = 0; i < n; i++)
        x[i] = std::cos(2.0 * M_PI * bin * i / n + phase);
    return x;
}

int ArgMaxBin(const dsp_plan &p, int from = 0) {
    int best = from;
    for (int k = from; k < p.m; k++)
        if (p.pwr[k] > p.pwr[best])
            best = k;
    return best;
}

// Windows

TEST(Window, HannCoherentGainIsTheExactWindowMean) {

    double worst = 0.0;
    for (int n : {64, 128, 512, 1024, 4096}) {
        Plan p(n, DSP_WINDOW_HANN);
        ASSERT_EQ(DSP_OK, p.rc()) << "n=" << n;
        EXPECT_NEAR(p->cg, (double)(n - 1) / (2.0 * n), kCgAbs) << "n=" << n;
        worst = std::max(worst, std::fabs(p->cg - (double)(n - 1) / (2.0 * n)));
    }
    Plan p512(512, DSP_WINDOW_HANN);

    EXPECT_NEAR(p512->cg, 511.0 / 1024.0, kSingle ? kCgAbs : 1e-15) << "cg = " << p512->cg;
    std::printf("[window] coherent gain: worst departure from (n-1)/2n is %.3e (bound %.0e)\n",
                worst, kCgAbs);
}

TEST(Window, PowerScaleConstantIsUnchanged) {

    const double want = 1.53185687861183e-05;
    Plan p(512, DSP_WINDOW_HANN);
    ASSERT_EQ(DSP_OK, p.rc());
    EXPECT_NEAR(p->ksq, want, want * kKsqRel)
        << p->ksq << ", off by " << (p->ksq / want - 1.0) << " relative";
}

TEST(Window, EveryWindowIsSymmetric) {
    for (int kind = 0; kind < DSP_WINDOW_COUNT; kind++) {
        std::vector<dsp_real> w(1024);
        ASSERT_EQ(DSP_OK, dsp_window(w.data(), 1024, kind, 12.0)) << WindowName(kind);
        for (int i = 0; i < 512; i++)
            ASSERT_EQ(w[i], w[1023 - i]) << WindowName(kind) << " at " << i;
    }
}

TEST(Window, RectIsUnity) {
    std::vector<dsp_real> w(64);
    ASSERT_EQ(DSP_OK, dsp_window(w.data(), 64, DSP_WINDOW_RECT, 0.0));
    for (int i = 0; i < 64; i++)
        ASSERT_EQ(w[i], (dsp_real)1) << i;
}

TEST(Window, KaiserBelowTheInterpolationFloorIsRefused) {

    std::vector<dsp_real> w(512);
    EXPECT_EQ(DSP_EBETA, dsp_window(w.data(), 512, DSP_WINDOW_KAISER, 3.0));
    EXPECT_EQ(DSP_EBETA, dsp_window(w.data(), 512, DSP_WINDOW_KAISER, 0.0));
    EXPECT_EQ(DSP_EBETA, dsp_window(w.data(), 512, DSP_WINDOW_KAISER, 3.5));
    EXPECT_EQ(DSP_OK, dsp_window(w.data(), 512, DSP_WINDOW_KAISER, 4.0));
    Plan bad(512, DSP_WINDOW_KAISER, 2.0);
    EXPECT_EQ(DSP_EBETA, bad.rc());
    EXPECT_EQ(0, bad->n) << "a refused plan must not look half-built";
}

// Integrate exp(x*cos(t))/pi by Simpson's rule as an independent I0 oracle.
double BesselI0Quadrature(double x) {
    const int n = 200000; // even
    double h = M_PI / n, s = std::exp(x) + std::exp(-x);
    for (int i = 1; i < n; i++)
        s += (i & 1 ? 4.0 : 2.0) * std::exp(x * std::cos(i * h));
    return s * h / 3.0 / M_PI;
}

TEST(Window, BesselSeriesMatchesAnIndependentQuadrature) {

    for (double beta : {4.0, 6.0, 9.0, 12.0, 15.0, 18.0}) {
        std::vector<dsp_real> w(1025);
        ASSERT_EQ(DSP_OK, dsp_window(w.data(), 1025, DSP_WINDOW_KAISER, beta)) << beta;
        double want = 1.0 / BesselI0Quadrature(beta);
        EXPECT_NEAR((double)w[512], 1.0, 1e-7) << "beta=" << beta;

        EXPECT_NEAR((double)w[0] / want, 1.0, kSingle ? 2e-6 : 1e-9)
            << "beta=" << beta << ": 1/I0 = " << (double)w[0] << ", quadrature " << want;
    }
}

TEST(Window, GainIsEvenAndUnityAtZero) {
    for (const WinCfg &c : ShippedWindows()) {
        Plan p(512, c.kind, c.beta);
        ASSERT_EQ(DSP_OK, p.rc()) << c.label();

        EXPECT_NEAR(dsp_win_gain(&p->ip, 0.0), 1.0, 1e-12) << c.label();
        for (double d : {0.01, 0.1, 0.25, 0.4999, 0.9, 1.4}) {
            EXPECT_EQ(dsp_win_gain(&p->ip, d), dsp_win_gain(&p->ip, -d)) << c.label() << " d=" << d;
        }

        EXPECT_LT(dsp_win_gain(&p->ip, 0.5), 1.0) << c.label();
        EXPECT_LT(dsp_win_gain(&p->ip, 0.5), dsp_win_gain(&p->ip, 0.25)) << c.label();
    }
}

TEST(Window, TheGainTableIsNonNegativeForEveryWindowKind) {

    double most_negative_without_abs = 0.0;
    for (int kind = 0; kind < DSP_WINDOW_COUNT; kind++) {
        Plan p(512, kind, 12.0);
        ASSERT_EQ(DSP_OK, p.rc()) << WindowName(kind);
        for (int j = 0; j <= DSP_GN; j++)
            ASSERT_GE(p->ip.gtab[j], 0.0) << WindowName(kind) << " at " << (j * DSP_GHX) << " bins";

        double wsum = 0.0;
        for (int i = 0; i < p->n; i++)
            wsum += (double)p->w[i];
        for (int j = 0; j <= DSP_GN; j++) {
            double x = j * DSP_GHX, a = 2.0 * M_PI * x / p->n, s = 0.0;
            double ctr = 0.5 * (p->n - 1);
            for (int i = 0; i < p->n / 2; i++)
                s += (double)p->w[i] * std::cos(a * (i - ctr));
            most_negative_without_abs = std::min(most_negative_without_abs, 2.0 * s / wsum);
        }
    }
    EXPECT_LT(most_negative_without_abs, -0.1)
        << "some window's transform must go negative inside 1.5 bins, or the absolute value "
           "in the gain table is untested";
}

TEST(Window, OffsetTableIsOddAndSaturatesAtHalfABin) {
    Plan p(512, DSP_WINDOW_HANN);
    ASSERT_EQ(DSP_OK, p.rc());
    double d = 0.0, dn = 0.0;
    ASSERT_EQ(DSP_OK, dsp_win_offset(&p->ip, 0.0, &d));
    EXPECT_EQ(0.0, d);
    for (double r : {0.01, 0.05, 0.12}) {
        ASSERT_EQ(DSP_OK, dsp_win_offset(&p->ip, r, &d));
        ASSERT_EQ(DSP_OK, dsp_win_offset(&p->ip, -r, &dn));
        EXPECT_EQ(d, -dn) << "r=" << r;
        EXPECT_GT(d, 0.0) << "r=" << r;
    }

    ASSERT_EQ(DSP_OK, dsp_win_offset(&p->ip, 10.0, &d));
    EXPECT_DOUBLE_EQ(0.5, d);
    ASSERT_EQ(DSP_OK, dsp_win_offset(&p->ip, -10.0, &d));
    EXPECT_DOUBLE_EQ(-0.5, d);
}

TEST(Window, EveryShippedWindowHasAnInvertibleOffsetTable) {

    for (const WinCfg &c : ShippedWindows()) {
        Plan p(512, c.kind, c.beta);
        ASSERT_EQ(DSP_OK, p.rc()) << c.label();
        EXPECT_EQ(1, p->mono) << c.label() << ": r(d) is not monotonic to half a bin";
        EXPECT_GT(p->ip.dhr, 0.0) << c.label();
    }
}

TEST(Window, NoSelectableWindowFailsTheMonotonicityCheck) {

    int checked = 0;
    for (int n = 8; n <= 4096; n *= 2) {
        for (int kind = 0; kind < DSP_WINDOW_COUNT; kind++) {
            for (double beta = 3.52; beta <= 24.0; beta += (beta < 6.0 ? 0.01 : 1.0)) {
                Plan p(n, kind, beta);
                if (p.rc() != DSP_OK)
                    continue;
                checked++;
                ASSERT_EQ(1, p->mono) << WindowName(kind) << " beta=" << beta << " n=" << n;
                ASSERT_GT(p->ip.dhr, 0.0) << WindowName(kind) << " beta=" << beta << " n=" << n;
                if (kind != DSP_WINDOW_KAISER)
                    break; // beta is Kaiser's alone
            }
        }
    }
    std::printf("[window] r(d) is monotonic to half a bin in all %d configurations swept\n",
                checked);
    EXPECT_GT(checked, 1000) << "the sweep must actually cover something";
}

TEST(Window, WithNoUsableTableTheOffsetAndTheInterpolationBothDecline) {

    dsp_interp ip{};
    ip.dhr = 0.0;
    ip.mono = 0;
    double d = 1.0;
    EXPECT_EQ(DSP_EDECLINE, dsp_win_offset(&ip, 0.1, &d));
    EXPECT_EQ(1.0, d) << "a declined call must not write an offset";
    std::vector<dsp_real> pwr(64, (dsp_real)1e-9);
    pwr[20] = (dsp_real)0.5;
    double amp = -1.0;
    EXPECT_EQ(DSP_EDECLINE, dsp_peak_interp(&ip, pwr.data(), 20, 64, &d, &amp));
    EXPECT_EQ(-1.0, amp);

    int bin[2];
    dsp_real frac[2], a[2];
    int found = dsp_peaks(pwr.data(), 64, 1, 62, 1, 2, &ip, bin, frac, a);
    ASSERT_GE(found, 1);
    EXPECT_EQ(20, bin[0]);
    EXPECT_EQ((dsp_real)0, frac[0]);
    EXPECT_NEAR((double)a[0], std::sqrt(0.5), 1e-6);
}

TEST(Window, MonotonicityIsNotEnoughToQualifyAWindow) {

    Plan rect(512, DSP_WINDOW_RECT);
    ASSERT_EQ(DSP_OK, rect.rc());
    EXPECT_EQ(1, rect->mono);
    const int one = (int)(1.0 / DSP_GHX + 0.5);
    EXPECT_NEAR(rect->ip.gtab[one], 0.0, 1e-6) << "RECT's first null must sit at one bin";

    double tightest = 1.0;
    for (const WinCfg &c : ShippedWindows()) {
        Plan p(512, c.kind, c.beta);
        ASSERT_EQ(DSP_OK, p.rc());
        for (int j = 0; j <= DSP_GN; j++)
            ASSERT_GT(p->ip.gtab[j], 0.0)
                << c.label() << ": a null at " << (j * DSP_GHX) << " bins";
        tightest = std::min(tightest, p->ip.gtab[DSP_GN]);
    }
    std::printf("[window] smallest gain at 1.5 bins over the shipped windows: %.4f; RECT at "
                "one bin: %.2e\n",
                tightest, rect->ip.gtab[one]);
    EXPECT_GT(tightest, 0.0);

    EXPECT_EQ(0, rect->kdc);
}

TEST(Window, DcRegionIsOneOrTwoBinsWide) {
    for (const WinCfg &c : ShippedWindows()) {
        Plan p(512, c.kind, c.beta);
        ASSERT_EQ(DSP_OK, p.rc()) << c.label();
        EXPECT_TRUE(p->kdc == 1 || p->kdc == 2) << c.label() << ": kdc=" << p->kdc;
    }
    Plan hann(512, DSP_WINDOW_HANN);
    EXPECT_EQ(1, hann->kdc) << "Hann puts one bin above DC inside the region";
}

// Plan and arena

TEST(Plan, BytesMatchesWhatInitNeeds) {
    for (int n : {4, 64, 512, 16384}) {
        for (int decim : {1, 4}) {
            for (int method = 0; method < DSP_FFT_COUNT; method++) {
                size_t want = dsp_plan_bytes(n, decim, method);
                ASSERT_GT(want, 0u) << "n=" << n;
                std::vector<unsigned char> raw(want + DSP_ALIGN, 0);
                unsigned char *arena = AlignUp(raw.data());
                dsp_plan p{};

                EXPECT_EQ(DSP_OK,
                          dsp_plan_init(&p, arena, want, n, DSP_WINDOW_HANN, 0, decim, method))
                    << "n=" << n << " decim=" << decim << " " << MethodName(method);

                EXPECT_EQ(DSP_ENOMEM,
                          dsp_plan_init(&p, arena, want - 1, n, DSP_WINDOW_HANN, 0, decim, method))
                    << "n=" << n << " decim=" << decim << " " << MethodName(method);
            }
        }
    }

    for (int method = 0; method < DSP_FFT_COUNT; method++)
        std::printf("[ plan ] arena bytes, %s, %-10s: n=512 %zu, n=4096 %zu, n=16384 %zu, "
                    "n=32768 %zu, n=65536 %zu\n",
                    kSingle ? "single" : "double", MethodName(method),
                    dsp_plan_bytes(512, 1, method), dsp_plan_bytes(4096, 1, method),
                    dsp_plan_bytes(16384, 1, method), dsp_plan_bytes(32768, 1, method),
                    dsp_plan_bytes(65536, 1, method));
    std::printf("[ plan ] arena bytes, %s, four-step with decim 4: n=16384 %zu, n=32768 %zu\n",
                kSingle ? "single" : "double", dsp_plan_bytes(16384, 4, DSP_FFT_FOURSTEP),
                dsp_plan_bytes(32768, 4, DSP_FFT_FOURSTEP));
}

TEST(Plan, SizingForOneDecompositionIsSmallerThanForBoth) {

    const int n = 16384;
    const int m = n / 2;
    size_t r2 = dsp_plan_bytes(n, 1, DSP_FFT_RADIX2);
    size_t fs = dsp_plan_bytes(n, 1, DSP_FFT_FOURSTEP);
    ASSERT_GT(r2, 0u);
    EXPECT_LT(r2, fs) << "radix-2 is in place, so it carries no second complex array";

    size_t swap = 2u * (size_t)(m / 2) * sizeof(int);
    EXPECT_EQ(swap, 32768u) << "16 kB each at n=16384, which is what sizing for both cost";

    std::printf("[ plan ] n=16384 %s: radix-2 %zu, four-step %zu (%.1f kB), union would be %zu\n",
                kSingle ? "single" : "double", r2, fs, (double)fs / 1024.0, fs + swap);

    if (kSingle) {
        EXPECT_NEAR((double)fs / 1024.0, 358.4, 0.1) << "the proposal's n=16384 single figure";
        EXPECT_NEAR((double)dsp_plan_bytes(32768, 1, DSP_FFT_FOURSTEP) / 1024.0, 714.6, 0.1)
            << "the proposal's n=32768 single figure";
        EXPECT_NEAR((double)dsp_plan_bytes(32768, 4, DSP_FFT_FOURSTEP) / 1024.0, 970.6, 0.1)
            << "n=32768 with decim 4, which has to include the FIR output scratch";
    } else {
        EXPECT_NEAR((double)fs / 1024.0, 715.9, 0.1) << "n=16384 double";
    }
}

TEST(Plan, OnlyTheArraysItsOwnMethodReadsArePresent) {

    Plan r2(4096, DSP_WINDOW_HANN, 0, 1, DSP_FFT_RADIX2);
    Plan fs(4096, DSP_WINDOW_HANN, 0, 1, DSP_FFT_FOURSTEP);
    ASSERT_EQ(DSP_OK, r2.rc());
    ASSERT_EQ(DSP_OK, fs.rc());

    EXPECT_NE(nullptr, r2->swp_a);
    EXPECT_EQ(nullptr, r2->wkr) << "radix-2 is in place";
    EXPECT_EQ(nullptr, r2->blkr);
    EXPECT_EQ(nullptr, r2->sw1_a);
    EXPECT_EQ(nullptr, r2->sw2_a);

    EXPECT_EQ(nullptr, fs->swp_a) << "the four-step bit-reverses its factors instead";
    EXPECT_NE(nullptr, fs->wkr);
    EXPECT_NE(nullptr, fs->blkr);
    EXPECT_NE(nullptr, fs->sw1_a);
    EXPECT_NE(nullptr, fs->sw2_a);

    for (Plan *p : {&r2, &fs}) {
        EXPECT_NE(nullptr, (*p)->w);
        EXPECT_NE(nullptr, (*p)->twr);
        EXPECT_NE(nullptr, (*p)->utr);
        EXPECT_NE(nullptr, (*p)->re);
        EXPECT_NE(nullptr, (*p)->im);
        EXPECT_NE(nullptr, (*p)->pwr);
        EXPECT_NE(nullptr, (*p)->h);
    }
}

TEST(Plan, OverwritingTheMethodFieldChangesNothing) {

    const int n = 4096;
    auto x = ToneAtBin(n, 300.27);
    for (int built = 0; built < DSP_FFT_COUNT; built++) {
        Plan ref(n, DSP_WINDOW_HANN, 0, 1, built);
        ASSERT_EQ(DSP_OK, ref.rc());
        ASSERT_EQ(ref->m, RunSpectrum(ref, x));
        std::vector<dsp_real> want(ref->pwr, ref->pwr + ref->m);
        for (int lie = -3; lie < DSP_FFT_COUNT + 3; lie++) {
            Plan p(n, DSP_WINDOW_HANN, 0, 1, built);
            ASSERT_EQ(DSP_OK, p.rc());
            p.get().method = lie;
            ASSERT_EQ(p->m, RunSpectrum(p, x));
            for (int k = 0; k < p->m; k++)
                ASSERT_EQ(want[k], p->pwr[k]) << "built " << MethodName(built) << ", method field "
                                              << lie << ", bin " << k;
        }
    }
}

TEST(Plan, RefusesACountThatIsNotAPowerOfTwo) {
    for (int n : {0, 1, 2, 3, 5, 6, 100, 513, 1000, -8}) {
        EXPECT_EQ(0u, dsp_plan_bytes(n, 1, DSP_FFT_DEFAULT)) << "n=" << n;
        std::vector<unsigned char> raw((1u << 19) + DSP_ALIGN, 0);
        unsigned char *arena = AlignUp(raw.data());
        dsp_plan p{};
        EXPECT_EQ(DSP_EPOW2,
                  dsp_plan_init(&p, arena, 1u << 19, n, DSP_WINDOW_HANN, 0, 1, DSP_FFT_DEFAULT))
            << "n=" << n;
    }
}

TEST(Plan, RefusesACountPastTheCeiling) {

    std::vector<unsigned char> raw((1u << 19) + DSP_ALIGN, 0);
    unsigned char *arena = AlignUp(raw.data());
    dsp_plan p{};
    for (int n : {DSP_N_MAX * 2, 1 << 24, 1 << 30}) {
        ASSERT_EQ(0, n & (n - 1)) << "n=" << n << " must be a power of two for this to mean "
                                              "anything";
        EXPECT_EQ(0u, dsp_plan_bytes(n, 1, DSP_FFT_DEFAULT)) << "n=" << n;
        EXPECT_EQ(DSP_EPOW2,
                  dsp_plan_init(&p, arena, 1u << 19, n, DSP_WINDOW_HANN, 0, 1, DSP_FFT_DEFAULT))
            << "n=" << n;
        EXPECT_EQ(0, p.n) << "n=" << n << ": a refused plan must be left zeroed";
    }

    EXPECT_GT(dsp_plan_bytes(DSP_N_MAX, 1, DSP_FFT_DEFAULT), 0u);
}

TEST(Plan, RefusesNullArgumentsAndAMisalignedArena) {
    std::vector<unsigned char> raw((1u << 17) + DSP_ALIGN, 0);
    unsigned char *arena = AlignUp(raw.data());
    const size_t bytes = 1u << 17;
    dsp_plan p{};
    EXPECT_EQ(DSP_EARG,
              dsp_plan_init(nullptr, arena, bytes, 64, DSP_WINDOW_HANN, 0, 1, DSP_FFT_DEFAULT));
    EXPECT_EQ(DSP_EARG,
              dsp_plan_init(&p, nullptr, bytes, 64, DSP_WINDOW_HANN, 0, 1, DSP_FFT_DEFAULT));

    for (int off = 1; off < DSP_ALIGN; off++)
        EXPECT_EQ(DSP_EALIGN, dsp_plan_init(&p, arena + off, bytes - DSP_ALIGN, 64,
                                            DSP_WINDOW_HANN, 0, 1, DSP_FFT_DEFAULT))
            << "offset " << off;
    EXPECT_EQ(DSP_EARG, dsp_plan_init(&p, arena, bytes, 64, 99, 0, 1, DSP_FFT_DEFAULT))
        << "an unknown window kind";
    EXPECT_EQ(DSP_EARG, dsp_plan_init(&p, arena, bytes, 64, -1, 0, 1, DSP_FFT_DEFAULT))
        << "a negative window kind";
    EXPECT_EQ(DSP_EARG,
              dsp_plan_init(&p, arena, bytes, 64, DSP_WINDOW_COUNT, 0, 1, DSP_FFT_DEFAULT))
        << "the enum's own count is not a window";
    EXPECT_EQ(DSP_EARG, dsp_plan_init(&p, arena, bytes, 64, DSP_WINDOW_HANN, 0, 0, DSP_FFT_DEFAULT))
        << "a decimation below one";
    EXPECT_EQ(DSP_EARG,
              dsp_plan_init(&p, arena, bytes, 64, DSP_WINDOW_HANN, 0, -4, DSP_FFT_DEFAULT))
        << "a negative decimation";
    EXPECT_EQ(DSP_EARG, dsp_plan_init(&p, arena, bytes, 64, DSP_WINDOW_HANN, 0, DSP_DECIM_MAX + 1,
                                      DSP_FFT_DEFAULT))
        << "a decimation past the ceiling, which multiplies the source length";
    EXPECT_EQ(DSP_EARG, dsp_plan_init(&p, arena, bytes, 64, DSP_WINDOW_HANN, 0, 1, -1))
        << "a negative decomposition";
    EXPECT_EQ(DSP_EARG, dsp_plan_init(&p, arena, bytes, 64, DSP_WINDOW_HANN, 0, 1, DSP_FFT_COUNT))
        << "the enum's own count is not a decomposition";

    EXPECT_EQ(DSP_EBETA,
              dsp_plan_init(&p, arena, bytes, 64, DSP_WINDOW_KAISER, 1.0, 1, DSP_FFT_DEFAULT));
    EXPECT_EQ(DSP_EBETA, dsp_plan_init(&p, arena, bytes, 64, DSP_WINDOW_KAISER,
                                       DSP_KAISER_BETA_MAX + 1.0, 1, DSP_FFT_DEFAULT))
        << "past the beta the Bessel series is accurate over";
    EXPECT_EQ(DSP_EBETA, dsp_plan_init(&p, arena, bytes, 64, DSP_WINDOW_KAISER, kNaN, 1,
                                       DSP_FFT_DEFAULT))
        << "a NaN beta, which fails both bounds because they are written as positives";

    EXPECT_EQ(0u, dsp_plan_bytes(64, 0, DSP_FFT_DEFAULT));
    EXPECT_EQ(0u, dsp_plan_bytes(64, DSP_DECIM_MAX + 1, DSP_FFT_DEFAULT));
    EXPECT_EQ(0u, dsp_plan_bytes(64, 1, DSP_FFT_COUNT));
    EXPECT_EQ(0u, dsp_plan_bytes(64, 1, -1));
}

TEST(Plan, EveryRefusalLeavesThePlanZeroed) {

    std::vector<unsigned char> raw((1u << 19) + DSP_ALIGN, 0);
    unsigned char *arena = AlignUp(raw.data());
    const size_t bytes = 1u << 19;
    dsp_plan p{};

    ASSERT_EQ(DSP_OK,
              dsp_plan_init(&p, arena, bytes, 512, DSP_WINDOW_HANN, 0, 1, DSP_FFT_DEFAULT));
    ASSERT_EQ(512, p.n);
    ASSERT_NE(nullptr, p.re);

    struct Case {
        const char *what;
        int n, kind, decim, method;
        double beta;
        size_t bytes;
        int want;
    };
    const size_t tiny = 64;
    const Case cases[] = {
        {"not a power of two", 513, DSP_WINDOW_HANN, 1, DSP_FFT_DEFAULT, 0.0, bytes, DSP_EPOW2},
        {"past DSP_N_MAX", DSP_N_MAX * 2, DSP_WINDOW_HANN, 1, DSP_FFT_DEFAULT, 0.0, bytes,
         DSP_EPOW2},
        {"arena too small", 16384, DSP_WINDOW_HANN, 1, DSP_FFT_DEFAULT, 0.0, tiny, DSP_ENOMEM},
        {"unknown window", 512, 99, 1, DSP_FFT_DEFAULT, 0.0, bytes, DSP_EARG},
        {"decimation below one", 512, DSP_WINDOW_HANN, 0, DSP_FFT_DEFAULT, 0.0, bytes, DSP_EARG},
        {"unknown decomposition", 512, DSP_WINDOW_HANN, 1, DSP_FFT_COUNT, 0.0, bytes, DSP_EARG},
        {"beta below the floor", 512, DSP_WINDOW_KAISER, 1, DSP_FFT_DEFAULT, 1.0, bytes, DSP_EBETA},
        {"beta past the ceiling", 512, DSP_WINDOW_KAISER, 1, DSP_FFT_DEFAULT,
         DSP_KAISER_BETA_MAX + 1.0, bytes, DSP_EBETA},
    };
    for (const Case &c : cases) {
        ASSERT_EQ(DSP_OK,
                  dsp_plan_init(&p, arena, bytes, 512, DSP_WINDOW_HANN, 0, 1, DSP_FFT_DEFAULT))
            << c.what << ": the plan this refusal has to overwrite must build";
        EXPECT_EQ(c.want,
                  dsp_plan_init(&p, arena, c.bytes, c.n, c.kind, c.beta, c.decim, c.method))
            << c.what;
        EXPECT_EQ(0, p.n) << c.what << ": n must be zero after a refusal";
        EXPECT_EQ(0, p.m) << c.what << ": m must be zero too, or dsp_rfft would run";
        EXPECT_EQ(nullptr, p.re) << c.what << ": a pointer into the old arena must not survive";
        EXPECT_EQ(nullptr, p.pwr) << c.what;
        EXPECT_EQ(0, p.ntaps) << c.what;

        std::vector<double> x(16384, 1.0);
        EXPECT_EQ(DSP_EARG, dsp_spectrum_run(&p, x.data(), (int)x.size(), nullptr))
            << c.what << ": a refused plan must not run a frame";

        dsp_rfft(&p);
    }

    ASSERT_EQ(DSP_OK,
              dsp_plan_init(&p, arena, bytes, 512, DSP_WINDOW_HANN, 0, 1, DSP_FFT_DEFAULT));
    EXPECT_EQ(DSP_EALIGN, dsp_plan_init(&p, arena + 1, bytes - DSP_ALIGN, 512, DSP_WINDOW_HANN, 0,
                                        1, DSP_FFT_DEFAULT));
    EXPECT_EQ(0, p.n);
    EXPECT_EQ(nullptr, p.re);

    EXPECT_EQ(DSP_EARG,
              dsp_plan_init(nullptr, arena, bytes, 512, DSP_WINDOW_HANN, 0, 1, DSP_FFT_DEFAULT));
}

TEST(Plan, TwoPlansSideBySideAgreeExactly) {

    Plan a(512, DSP_WINDOW_HANN);
    Plan b(256, DSP_WINDOW_KAISER, 12.0);
    Plan c(512, DSP_WINDOW_HANN);
    ASSERT_EQ(DSP_OK, a.rc());
    ASSERT_EQ(DSP_OK, b.rc());
    ASSERT_EQ(DSP_OK, c.rc());
    auto x512 = ToneAtBin(512, 100.37);
    auto x256 = ToneAtBin(256, 50.1);
    ASSERT_GT(RunSpectrum(a, x512), 0);
    ASSERT_GT(RunSpectrum(b, x256), 0); // between the two halves of a's frame
    ASSERT_GT(RunSpectrum(c, x512), 0);
    for (int k = 0; k < a->m; k++)
        ASSERT_EQ(a->pwr[k], c->pwr[k]) << "bin " << k;
}

TEST(Plan, SwapListHoldsEveryPairThatMoves) {

    for (int n : {64, 512, 4096}) {
        Plan p(n, DSP_WINDOW_HANN, 0, 1, DSP_FFT_RADIX2);
        ASSERT_EQ(DSP_OK, p.rc());
        ASSERT_NE(nullptr, p->swp_a);
        int m = p->m, bits = 0;
        while ((1 << bits) < m)
            bits++;
        std::vector<int> perm(m);
        for (int i = 0; i < m; i++)
            perm[i] = i;
        for (int s = 0; s < p->nswp; s++)
            std::swap(perm[p->swp_a[s]], perm[p->swp_b[s]]);
        for (int i = 0; i < m; i++) {
            int rev = 0;
            for (int b = 0; b < bits; b++)
                if (i & (1 << b))
                    rev |= 1 << (bits - 1 - b);
            ASSERT_EQ(rev, perm[i]) << "n=" << n << " i=" << i;
        }
    }
}

// FFT against a direct DFT

TEST(Fft, EveryBinMatchesADirectDft) {

    const int n = 64;
    Plan p(n, DSP_WINDOW_HANN);
    ASSERT_EQ(DSP_OK, p.rc());
    std::vector<double> x(n);
    for (int i = 0; i < n; i++)
        x[i] = 2.5 + 0.7 * std::sin(2.0 * M_PI * 11000.0 * i / 100000.0);

    double mean = 0.0;
    ASSERT_EQ(p->m, RunSpectrum(p, x, &mean));

    std::vector<double> v(n);
    for (int i = 0; i < n; i++)
        v[i] = (double)(dsp_real)((x[i] - mean) * (double)p->w[i]);
    double wsum = 0.0;
    for (int i = 0; i < n; i++)
        wsum += (double)p->w[i];

    std::vector<double> want(p->m);
    double peak = 0.0;
    for (int b = 0; b < p->m; b++) {
        double sr = 0.0, si = 0.0;
        for (int i = 0; i < n; i++) {
            double ang = -2.0 * M_PI * b * i / n;
            sr += v[i] * std::cos(ang);
            si += v[i] * std::sin(ang);
        }
        want[b] = 4.0 * (sr * sr + si * si) / (wsum * wsum);
        peak = std::max(peak, want[b]);
    }
    auto allow = [peak](double ref) { return kDftRel * ref + kDftAbsFs * peak; };

    double worst = 0.0, worst_rel = 0.0, worst_floor = 0.0;
    int worstk = 0;
    for (int b = 0; b < p->m; b++) {
        double d = std::fabs((double)p->pwr[b] - want[b]);
        if (want[b] > 1e-6 * peak)
            worst_rel = std::max(worst_rel, d / want[b]);
        else
            worst_floor = std::max(worst_floor, d);
        if (d / allow(want[b]) > worst) {
            worst = d / allow(want[b]);
            worstk = b;
        }
    }
    std::printf("[  fft ] DFT at n=%d: worst %.3f of budget at bin %d; relative %.2e on the "
                "bins with energy, floor %.1f dB below the peak bin\n",
                n, worst, worstk, worst_rel, 10.0 * std::log10(worst_floor / peak));
    EXPECT_LE(worst, 1.0) << "worst " << worst << " of budget at bin " << worstk;

    double keep = (double)p->pwr[8];
    p->pwr[8] = (dsp_real)(keep * 1.01);
    double perturbed = std::fabs((double)p->pwr[8] - want[8]) / allow(want[8]);
    EXPECT_GT(perturbed, 100.0) << "perturbed bin 8 by 1%, " << perturbed << " of budget";
    p->pwr[8] = (dsp_real)keep;
}

TEST(Fft, EveryDecompositionMatchesADirectDft) {

    const int n = 512;
    std::vector<double> x(n);
    for (int i = 0; i < n; i++)
        x[i] = 2.5 + 0.7 * std::sin(2.0 * M_PI * 11000.0 * i / 100000.0) +
               0.3 * std::cos(2.0 * M_PI * 27000.0 * i / 100000.0);

    for (int method = 0; method < DSP_FFT_COUNT; method++) {
        Plan p(n, DSP_WINDOW_HANN, 0, 1, method);
        ASSERT_EQ(DSP_OK, p.rc());
        ASSERT_EQ(method, p->method) << "the plan must have been built for what was asked";
        ASSERT_GE(p->m, DSP_FS_MIN) << "the four-step must actually run at this size";
        double mean = 0.0;
        ASSERT_EQ(p->m, RunSpectrum(p, x, &mean));

        std::vector<double> v(n);
        for (int i = 0; i < n; i++)
            v[i] = (double)(dsp_real)((x[i] - mean) * (double)p->w[i]);
        double wsum = 0.0;
        for (int i = 0; i < n; i++)
            wsum += (double)p->w[i];

        double peak = 0.0;
        std::vector<double> want(p->m);
        for (int b = 0; b < p->m; b++) {
            double sr = 0.0, si = 0.0;
            for (int i = 0; i < n; i++) {
                double ang = -2.0 * M_PI * b * i / n;
                sr += v[i] * std::cos(ang);
                si += v[i] * std::sin(ang);
            }
            want[b] = 4.0 * (sr * sr + si * si) / (wsum * wsum);
            peak = std::max(peak, want[b]);
        }
        double worst = 0.0, worst_rel = 0.0, worst_floor = 0.0;
        for (int b = 0; b < p->m; b++) {
            double d = std::fabs((double)p->pwr[b] - want[b]);
            if (want[b] > 1e-6 * peak)
                worst_rel = std::max(worst_rel, d / want[b]);
            else
                worst_floor = std::max(worst_floor, d);
            worst = std::max(worst, d / (kDftRel * want[b] + kDftAbsFs * peak));
        }
        std::printf("[  fft ] %-10s n=%d: %.3f of budget; relative %.2e, floor %.1f dB below "
                    "the peak\n",
                    MethodName(method), n, worst, worst_rel, 10.0 * std::log10(worst_floor / peak));
        EXPECT_LE(worst, 1.0) << MethodName(method) << ": " << worst << " of budget";
    }
}

TEST(Fft, BothDecompositionsAgreeBinForBin) {

    int real_fs = 0, substituted = 0;
    for (int n : {8, 64, 128, 512, 2048, 16384, 32768}) {
        Plan ref(n, DSP_WINDOW_BLACKMAN_HARRIS, 0, 1, DSP_FFT_RADIX2);
        ASSERT_EQ(DSP_OK, ref.rc()) << "n=" << n;
        ASSERT_EQ(DSP_FFT_RADIX2, ref->method);
        auto x = ToneAtBin(n, n / 8.0 + 0.31);
        ASSERT_EQ(ref->m, RunSpectrum(ref, x));
        std::vector<dsp_real> want(ref->pwr, ref->pwr + ref->m);
        double peak = 0.0;
        for (int k = 0; k < ref->m; k++)
            peak = std::max(peak, (double)want[k]);

        for (int method = 1; method < DSP_FFT_COUNT; method++) {
            Plan p(n, DSP_WINDOW_BLACKMAN_HARRIS, 0, 1, method);
            ASSERT_EQ(DSP_OK, p.rc());
            ASSERT_EQ(p->m, RunSpectrum(p, x));
            if (p->method != method) {

                ASSERT_EQ(DSP_FFT_RADIX2, p->method) << "n=" << n;
                ASSERT_EQ(DSP_FFT_FOURSTEP, method) << "only the four-step substitutes";
                for (int k = 0; k < p->m; k++)
                    ASSERT_EQ(want[k], p->pwr[k])
                        << "n=" << n << " bin " << k << ": a substituted plan is radix-2 and "
                                                        "must be bit-identical to it";
                substituted++;
                continue;
            }
            if (method == DSP_FFT_FOURSTEP)
                real_fs++;
            double worst = 0.0;
            int worstk = 0;
            for (int k = 0; k < p->m; k++) {
                double d = std::fabs((double)p->pwr[k] - (double)want[k]);
                double allow = kDftRel * (double)want[k] + kDftAbsFs * peak;
                if (d / allow > worst) {
                    worst = d / allow;
                    worstk = k;
                }
            }
            EXPECT_LE(worst, 1.0) << MethodName(method) << " at n=" << n << ": " << worst
                                  << " of budget at bin " << worstk;

            int differing = 0;
            for (int k = 0; k < p->m; k++)
                if (p->pwr[k] != want[k])
                    differing++;
            if (p->m >= 64)
                EXPECT_GT(differing, 0) << MethodName(method) << " at n=" << n
                                        << " is bit-identical to radix-2 in all " << p->m
                                        << " bins, so it is probably not running at all";
        }
    }
    std::printf("[  fft ] agreement: %d arms ran the four-step, %d were substituted\n", real_fs,
                substituted);
    EXPECT_GE(real_fs, 4) << "the four-step was never actually compared";
    EXPECT_GE(substituted, 1) << "the substitution path was never exercised";
}

TEST(Fft, TheFourStepFactorsCoverTheWholeTransform) {

    for (int n : {64, 128, 512, 2048, 8192, 16384, 32768, 65536}) {
        Plan p(n, DSP_WINDOW_HANN);
        ASSERT_EQ(DSP_OK, p.rc()) << "n=" << n;
        EXPECT_EQ(p->m, p->m1 * p->m2) << "n=" << n;
        EXPECT_LE(p->m1, p->m2) << "n=" << n;
        EXPECT_EQ(0, p->m1 & (p->m1 - 1)) << "n=" << n << ": m1 must be a power of two";
        EXPECT_EQ(0, p->m2 & (p->m2 - 1)) << "n=" << n << ": m2 must be a power of two";

        size_t blk = 2u * DSP_FS_BLOCK * (size_t)p->m1 * sizeof(dsp_real);
        EXPECT_LE(blk, 16384u) << "n=" << n << ": gather block is " << blk << " bytes";
    }
    Plan small(32, DSP_WINDOW_HANN);
    ASSERT_EQ(DSP_OK, small.rc());
    EXPECT_LT(small->m, DSP_FS_MIN) << "m=16 must fall back, which the agreement test covers";
}

TEST(Fft, EachDecompositionIsRepeatableAndDistinct) {

    const int n = 4096;
    auto x = ToneAtBin(n, 300.27);
    std::vector<std::vector<dsp_real>> out;
    for (int method = 0; method < DSP_FFT_COUNT; method++) {
        Plan p(n, DSP_WINDOW_HANN, 0, 1, method);
        ASSERT_EQ(DSP_OK, p.rc());
        ASSERT_EQ(method, p->method) << "n=4096 is above every substitution threshold";
        ASSERT_EQ(p->m, RunSpectrum(p, x));
        std::vector<dsp_real> first(p->pwr, p->pwr + p->m);

        ASSERT_EQ(p->m, RunSpectrum(p, x));
        for (int k = 0; k < p->m; k++)
            ASSERT_EQ(first[k], p->pwr[k])
                << MethodName(method) << " bin " << k << " moved on the second pass";
        out.push_back(first);
    }
    for (int method = 1; method < DSP_FFT_COUNT; method++) {
        int differing = 0;
        for (size_t k = 0; k < out[method].size(); k++)
            if (out[method][k] != out[DSP_FFT_RADIX2][k])
                differing++;
        EXPECT_GT(differing, 0) << MethodName(method) << " is bit-identical to radix-2 in all "
                                << out[method].size()
                                << " bins, so it is probably not running at all";
    }
}

TEST(Fft, AskingForTheFourStepBelowItsFloorBuildsRadixTwo) {

    for (int n : {4, 8, 16, 32, 64, 128}) {
        Plan p(n, DSP_WINDOW_HANN, 0, 1, DSP_FFT_FOURSTEP);
        ASSERT_EQ(DSP_OK, p.rc()) << "n=" << n;
        bool usable = p->m2 >= DSP_FS_BLOCK && p->m >= DSP_FS_MIN;
        EXPECT_EQ(usable ? DSP_FFT_FOURSTEP : DSP_FFT_RADIX2, p->method) << "n=" << n;

        EXPECT_EQ(usable, p->blkr != nullptr) << "n=" << n;
        EXPECT_EQ(!usable, p->swp_a != nullptr) << "n=" << n;
        EXPECT_EQ(dsp_plan_bytes(n, 1, p->method), p.bytes()) << "n=" << n;

        auto x = ToneAtBin(n, n / 8.0);
        ASSERT_EQ(p->m, RunSpectrum(p, x));
    }

    Plan m32(64, DSP_WINDOW_HANN, 0, 1, DSP_FFT_FOURSTEP);
    ASSERT_EQ(DSP_OK, m32.rc());
    EXPECT_EQ(32, m32->m);
    EXPECT_EQ(4, m32->m1);
    EXPECT_EQ(8, m32->m2) << "m2 reaches one block at m=32, so the precondition holds there";
    EXPECT_LT(m32->m, DSP_FS_MIN) << "and DSP_FS_MIN is still above it, for the cache reason";
    EXPECT_EQ(DSP_FFT_RADIX2, m32->method);
}

TEST(Fft, PowerReturnsNOverTwoBins) {
    for (int n : {4, 8, 64, 512, 1024}) {
        Plan p(n, DSP_WINDOW_HANN);
        ASSERT_EQ(DSP_OK, p.rc()) << "n=" << n;
        EXPECT_EQ(n / 2, p->m) << "n=" << n;
        auto x = ToneAtBin(n, n / 8.0);
        EXPECT_EQ(n / 2, RunSpectrum(p, x)) << "n=" << n;
    }
}

TEST(Fft, LoadRefusesABadCountOrAZeroWindowSum) {
    Plan p(64, DSP_WINDOW_HANN);
    ASSERT_EQ(DSP_OK, p.rc());
    std::vector<double> x(64, 1.0);
    EXPECT_EQ(DSP_EPOW2, dsp_load(x.data(), 0, p->w, p->wsum, p->re, p->im, nullptr));
    EXPECT_EQ(DSP_EPOW2, dsp_load(x.data(), 63, p->w, p->wsum, p->re, p->im, nullptr));

    EXPECT_EQ(DSP_EARG, dsp_load(x.data(), 64, p->w, 0.0, p->re, p->im, nullptr));
    EXPECT_EQ(DSP_EARG, dsp_load(nullptr, 64, p->w, p->wsum, p->re, p->im, nullptr));
}

TEST(Fft, PinnedReferenceValues) {

    const int n = 512;
    const double fs = 100000.0;
    Plan p(n, DSP_WINDOW_HANN);
    ASSERT_EQ(DSP_OK, p.rc());
    std::vector<double> x(n);
    for (int i = 0; i < n; i++) {
        double t = i / fs;
        x[i] = 2.5 + 0.7 * std::sin(2.0 * M_PI * 12345.0 * t) +
               0.3 * std::sin(2.0 * M_PI * 4000.0 * t + 0.5) +
               0.1 * std::cos(2.0 * M_PI * 27777.0 * t);
    }
    ASSERT_EQ(256, RunSpectrum(p, x));

    struct Ref {
        int k;
        double v;
    };

    const Ref refs[] = {
        {0, 1.300361262791e-29},   {1, 1.021704940227e-09},   {2, 5.016625104977e-10},
        {19, 2.976886198854e-03},  {20, 6.663924261446e-02},  {21, 6.319270653668e-02},
        {22, 2.332826285037e-03},  {62, 6.055496038219e-02},  {63, 4.638311684332e-01},
        {64, 2.105245146147e-01},  {65, 1.196709648263e-03},  {127, 2.275997790175e-11},
        {141, 1.179005939318e-03}, {142, 9.404683131771e-03}, {143, 4.410196683798e-03},
        {199, 4.112308028054e-14}, {254, 2.881897498689e-15}, {255, 2.871653489567e-15},
    };
    double peak = 0.0;
    for (const Ref &r : refs)
        peak = std::max(peak, r.v);
    double worst = 0.0, worst_rel = 0.0, worst_floor = 0.0;
    int worstk = 0;
    for (const Ref &r : refs) {
        double d = std::fabs((double)p->pwr[r.k] - r.v);
        double allow = kPinnedRel * r.v + kPinnedAbsFs * peak;
        if (r.v > 1e-6 * peak)
            worst_rel = std::max(worst_rel, d / r.v);
        else
            worst_floor = std::max(worst_floor, d);
        if (d / allow > worst) {
            worst = d / allow;
            worstk = r.k;
        }
    }
    std::printf("[  fft ] pinned bins: worst %.3f of budget at bin %d; relative %.2e on the "
                "bins with energy, floor %.1f dB below the peak; bin 0 = %.3e\n",
                worst, worstk, worst_rel, 10.0 * std::log10(worst_floor / peak), (double)p->pwr[0]);
    EXPECT_LE(worst, 1.0) << "worst " << worst << " of budget at bin " << worstk;

    double tot = 0.0;
    for (int k = 0; k < 256; k++)
        tot += (double)p->pwr[k];
    EXPECT_NEAR(tot, 8.867318993681e-01, kPinnedRel * 8.867318993681e-01) << tot;
}

TEST(Fft, TheOffsetTonePinnedCase) {

    const int n = 512, fs = 100000;
    const double binhz = (double)fs / n;
    Plan p(n, DSP_WINDOW_HANN);
    ASSERT_EQ(DSP_OK, p.rc());
    std::vector<double> x(n);
    for (int i = 0; i < n; i++)
        x[i] = 1.0 + 0.5 * std::sin(2.0 * M_PI * 12345.0 * i / fs);
    ASSERT_EQ(256, RunSpectrum(p, x));

    int pk = ArgMaxBin(p.get(), 1);
    EXPECT_EQ(63, pk) << "the offset tone must peak in bin 63 (64 one-based)";
    double raw = std::sqrt((double)p->pwr[pk]);
    EXPECT_NEAR(raw, 0.486465471, kSingle ? 1e-5 : 1e-6)
        << "the raw scalloped read is 0.4865 V, not 0.5";

    double d = 0.0, amp = 0.0;
    ASSERT_EQ(DSP_OK, dsp_peak_interp(&p->ip, p->pwr, pk, p->m, &d, &amp));
    double hz = (pk + d) * binhz;
    EXPECT_NEAR(hz, 12345.0, 0.5) << hz << " Hz (d=" << d << ")";
    EXPECT_NEAR(amp, 0.5, 0.005 * 0.5) << amp << " V";
    std::printf("[  fft ] 12345 Hz 0.5 V: raw bin %.6f V at %.1f Hz, interpolated %.9f V at "
                "%.6f Hz\n",
                raw, pk * binhz, amp, hz);
}

TEST(Fft, ThePedestalIsRemovedToRoundingNotMerelyToSmall) {

    const int n = 512, fs = 100000;
    Plan p(n, DSP_WINDOW_HANN);
    ASSERT_EQ(DSP_OK, p.rc());
    std::vector<double> x(n);
    for (int i = 0; i < n; i++)
        x[i] = 1.0 + 0.5 * std::sin(2.0 * M_PI * 12345.0 * i / fs);
    ASSERT_EQ(256, RunSpectrum(p, x));
    double weighted = (double)p->pwr[0];

    double amean = 0.0;
    for (int i = 0; i < n; i++)
        amean += x[i];
    amean /= n;
    for (int k = 0, i = 0; k < p->m; k++, i += 2) {
        p->re[k] = (dsp_real)((x[i] - amean) * (double)p->w[i]);
        p->im[k] = (dsp_real)((x[i + 1] - amean) * (double)p->w[i + 1]);
    }
    dsp_rfft(&p.get());
    dsp_power(p->re, p->im, p->m, p->utr, p->uti, p->pwr, p->ksq);
    double arithmetic = (double)p->pwr[0];

    std::printf("[  fft ] pedestal residue in bin 0: weighted mean %.4e, arithmetic mean "
                "%.4e (gate %.0e)\n",
                weighted, arithmetic, kPedestal);
    EXPECT_LT(weighted, kPedestal) << weighted;
    EXPECT_GT(arithmetic, 1e-8) << "the control must leave something, or the gate is vacuous";
    EXPECT_GT(arithmetic / weighted, 1e4)
        << "weighted " << weighted << " vs arithmetic " << arithmetic;
}

TEST(Fft, AnOnBinToneIsLeftAlone) {

    const int n = 512;
    for (const WinCfg &c : ShippedWindows()) {
        Plan p(n, c.kind, c.beta);
        ASSERT_EQ(DSP_OK, p.rc()) << c.label();
        auto x = ToneAtBin(n, 26.0, 0.0);
        ASSERT_EQ(n / 2, RunSpectrum(p, x));
        double d = 0.0, amp = 0.0;
        ASSERT_EQ(DSP_OK, dsp_peak_interp(&p->ip, p->pwr, 26, p->m, &d, &amp)) << c.label();
        EXPECT_LT(std::fabs(d), 1e-4) << c.label() << ": d=" << d;
        EXPECT_NEAR(amp, 1.0, 0.005) << c.label() << ": " << amp << " V";
    }
}

TEST(Fft, PeakInterpDeclinesAtTheSpectrumEdges) {
    Plan p(512, DSP_WINDOW_HANN);
    ASSERT_EQ(DSP_OK, p.rc());
    auto x = ToneAtBin(512, 100.4);
    ASSERT_EQ(256, RunSpectrum(p, x));
    double d = 0.0, amp = 0.0;
    EXPECT_EQ(DSP_EDECLINE, dsp_peak_interp(&p->ip, p->pwr, 0, p->m, &d, &amp));
    EXPECT_EQ(DSP_EDECLINE, dsp_peak_interp(&p->ip, p->pwr, p->m - 1, p->m, &d, &amp));
    EXPECT_EQ(DSP_EARG, dsp_peak_interp(nullptr, p->pwr, 100, p->m, &d, &amp));

    dsp_real keep = p->pwr[100];
    p->pwr[100] = 0;
    EXPECT_EQ(DSP_EDECLINE, dsp_peak_interp(&p->ip, p->pwr, 100, p->m, &d, &amp));
    p->pwr[100] = keep;
}

// Sub-bin accuracy for every window

struct SweepResult {
    double worst_f = 0.0; // bins
    double worst_a = 0.0; // dB
    int misses = 0;       // offsets where the peak finder did not report the tone
    int fallbacks = 0;    // offsets where dsp_peak_interp declined
};

// Sample fractional offsets away from table nodes. Use dsp_peaks so missed peaks
// fail the test even when a local argmax would find the tone.
SweepResult WinSweep(Plan &p, double centre, int from_j = -41) {
    SweepResult r;
    const int n = p->n;
    for (int j = from_j; j <= 41; j++) {
        double bn = centre + (double)j / 83.0;
        auto x = ToneAtBin(n, bn);
        if (RunSpectrum(p, x) != p->m) {
            r.misses++;
            continue;
        }
        int bin[6];
        int found = dsp_peaks(p->pwr, p->m, 1, p->m - 1, p->kdc, 6, &p->ip, bin, nullptr, nullptr);
        if (found < 1 || std::fabs((double)bin[0] - bn) > 1.5) {
            r.misses++;
            continue;
        }
        double d = 0.0, v = 0.0;
        if (dsp_peak_interp(&p->ip, p->pwr, bin[0], p->m, &d, &v) != DSP_OK) {
            r.fallbacks++;
            d = 0.0;
            v = std::sqrt((double)p->pwr[bin[0]]);
        }
        double ef = std::fabs((double)bin[0] + d - bn);
        double ea = std::fabs(20.0 * std::log10(v)); // the tone is 1.0 V, so dB against 0
        r.worst_f = std::max(r.worst_f, ef);
        r.worst_a = std::max(r.worst_a, ea);
    }
    return r;
}

class WindowSweep : public testing::TestWithParam<WinCfg> {};

constexpr double kWinDf = 1e-5, kWinDa = 0.008;

constexpr double kLowDf = 0.15, kLowDa = 0.3;
// At the top bin there is no right neighbor, so interpolation must decline.
constexpr double kTopDf = 0.5, kTopDa = 8.0;

TEST_P(WindowSweep, MidSpectrumRecoveryIsWithinBounds) {
    Plan p(512, GetParam().kind, GetParam().beta);
    ASSERT_EQ(DSP_OK, p.rc());
    SweepResult r = WinSweep(p, 128.0);
    std::printf("[ sweep] %-12s mid: %.2e bins, %.1e dB, %d missed, %d fell back\n",
                GetParam().label().c_str(), r.worst_f, r.worst_a, r.misses, r.fallbacks);
    EXPECT_EQ(0, r.misses) << GetParam().label() << ": " << r.misses << " of 83 offsets missed";
    EXPECT_LE(r.worst_f, kWinDf) << GetParam().label() << ": " << r.worst_f << " bins";
    EXPECT_LE(r.worst_a, kWinDa) << GetParam().label() << ": " << r.worst_a << " dB";
}

TEST_P(WindowSweep, TheLowestReportableBinIsFoundAtEveryOffset) {
    Plan p(512, GetParam().kind, GetParam().beta);
    ASSERT_EQ(DSP_OK, p.rc());

    SweepResult r = WinSweep(p, (double)(p->kdc + 1), 0);
    std::printf("[ sweep] %-12s low: %.4f bins, %.2f dB, %d missed (bin %d)\n",
                GetParam().label().c_str(), r.worst_f, r.worst_a, r.misses, p->kdc + 1);
    EXPECT_EQ(0, r.misses) << GetParam().label() << ": bin " << (p->kdc + 1) << ", " << r.misses
                           << " of 42 missed";
    EXPECT_LT(r.worst_f, kLowDf) << GetParam().label();
    EXPECT_LT(r.worst_a, kLowDa) << GetParam().label();
}

TEST_P(WindowSweep, TheTopBinFallsBackToTheRawBin) {
    Plan p(512, GetParam().kind, GetParam().beta);
    ASSERT_EQ(DSP_OK, p.rc());
    SweepResult r = WinSweep(p, (double)(p->m - 1));
    std::printf("[ sweep] %-12s top: %.3f bins, %.2f dB, %d of 83 fell back\n",
                GetParam().label().c_str(), r.worst_f, r.worst_a, r.fallbacks);
    EXPECT_EQ(0, r.misses) << GetParam().label();
    EXPECT_GT(r.fallbacks, 0) << GetParam().label() << ": the top bin must decline";
    EXPECT_LT(r.worst_f, kTopDf) << GetParam().label();
    EXPECT_LT(r.worst_a, kTopDa) << GetParam().label();
}

TEST_P(WindowSweep, ATonePastTheDcRegionIsNeverReportedInsideIt) {

    Plan p(512, GetParam().kind, GetParam().beta);
    ASSERT_EQ(DSP_OK, p.rc());
    for (double centre : {1.0, 0.5}) {
        int rows = 0;
        for (int j = -41; j <= 41; j++) {
            auto x = ToneAtBin(p->n, centre + (double)j / 83.0);
            ASSERT_EQ(p->m, RunSpectrum(p, x));
            int bin[6];
            int found =
                dsp_peaks(p->pwr, p->m, 1, p->m - 1, p->kdc, 6, &p->ip, bin, nullptr, nullptr);
            for (int s = 0; s < found; s++)
                if (bin[s] >= 0 && bin[s] <= p->kdc)
                    rows++;
        }
        EXPECT_EQ(0, rows) << GetParam().label() << ": bin " << centre << " put " << rows
                           << " rows inside the DC region";
    }
}

TEST_P(WindowSweep, ATonebBelowTheLimitPutsNoRowInTheTableAtAll) {

    Plan p(512, GetParam().kind, GetParam().beta);
    ASSERT_EQ(DSP_OK, p.rc());
    int rows = 0, positions = 0;
    for (double bn = 0.3; bn <= 0.99 + 1e-9; bn += 0.01) {
        for (int ph = 0; ph < 4; ph++) {
            auto x = ToneAtBin(p->n, bn, ph * M_PI / 4.0);
            ASSERT_EQ(p->m, RunSpectrum(p, x));
            int bin[6];
            int found =
                dsp_peaks(p->pwr, p->m, 1, p->m - 1, p->kdc, 6, &p->ip, bin, nullptr, nullptr);
            positions++;

            for (int s = 0; s < found; s++)
                if (bin[s] >= 0 && bin[s] <= 1 + p->kdc)
                    rows++;
        }
    }
    EXPECT_EQ(0, rows) << GetParam().label() << ": " << rows << " rows at the mask edge over "
                       << positions << " positions";
}

TEST_P(WindowSweep, ADistantOffCentreToneLeavesTheDcRegionClean) {

    Plan p(512, GetParam().kind, GetParam().beta);
    ASSERT_EQ(DSP_OK, p.rc());
    double worst = 0.0;
    for (int ph = 0; ph < 8; ph++) {
        auto x = ToneAtBin(p->n, 64.5, ph * M_PI / 8.0);
        ASSERT_EQ(p->m, RunSpectrum(p, x));
        for (int k = 0; k <= p->kdc + 1; k++)
            worst = std::max(worst, (double)p->pwr[k]);
    }
    double dbc = worst > 0.0 ? 10.0 * std::log10(worst) : -300.0;
    std::printf("[ sweep] %-12s DC region with a distant tone: %.1f dBc\n",
                GetParam().label().c_str(), dbc);
    EXPECT_LT(dbc, -50.0) << GetParam().label();
}

INSTANTIATE_TEST_SUITE_P(Shipped, WindowSweep, testing::ValuesIn(ShippedWindows()),
                         [](const testing::TestParamInfo<WinCfg> &i) {
                             std::string s = WindowName(i.param.kind);
                             for (char &c : s)
                                 if (!std::isalnum((unsigned char)c))
                                     c = '_';
                             if (i.param.kind == DSP_WINDOW_KAISER)
                                 s += "_b" + std::to_string((int)i.param.beta);
                             return s;
                         });

TEST(WindowSweepControl, OneWindowsDataThroughAnothersTablesIsCaught) {

    Plan hann(512, DSP_WINDOW_HANN);
    Plan bh(512, DSP_WINDOW_BLACKMAN_HARRIS);
    ASSERT_EQ(DSP_OK, hann.rc());
    ASSERT_EQ(DSP_OK, bh.rc());

    dsp_real *keep = bh->w;
    bh.get().w = hann->w;
    bh.get().wsum = hann->wsum;
    bh.get().ksq = hann->ksq;
    SweepResult r = WinSweep(bh, 128.0);
    bh.get().w = keep;
    EXPECT_GT(r.worst_f, kWinDf) << r.worst_f << " bins";
    EXPECT_GT(r.worst_a, kWinDa) << r.worst_a << " dB";
}

TEST(WindowSweepControl, RectIsIllConditionedWhichIsWhyTheLuaRefusesIt) {

    Plan rect(512, DSP_WINDOW_RECT);
    Plan hann(512, DSP_WINDOW_HANN);
    ASSERT_EQ(DSP_OK, rect.rc());
    ASSERT_EQ(DSP_OK, hann.rc());
    SweepResult rr = WinSweep(rect, 128.0);
    SweepResult rh = WinSweep(hann, 128.0);
    std::printf("[ sweep] Rect vs Hann: %.3e bins / %.3f dB against %.3e bins / %.1e dB\n",
                rr.worst_f, rr.worst_a, rh.worst_f, rh.worst_a);
    EXPECT_GT(rr.worst_f, kWinDf * 100.0) << "Rect would have to be much worse than the list";
    EXPECT_GT(rr.worst_f / std::max(rh.worst_f, 1e-12), 100.0);
}

// Peak search

TEST(Peaks, FindsTheStrongestPeaksInOrder) {
    const int m = 256;
    std::vector<dsp_real> pwr(m, (dsp_real)1e-12);

    const int at[] = {40, 80, 120, 160, 200};
    const double amp[] = {0.04, 1.0, 0.25, 0.5, 0.09};
    for (int i = 0; i < 5; i++)
        pwr[at[i]] = (dsp_real)amp[i];
    int bin[6];
    dsp_real frac[6], a[6];
    Plan p(512, DSP_WINDOW_HANN);
    ASSERT_EQ(DSP_OK, p.rc());
    int found = dsp_peaks(pwr.data(), m, 0, m - 1, p->kdc, 6, &p->ip, bin, frac, a);
    ASSERT_EQ(5, found);
    EXPECT_EQ(80, bin[0]);
    EXPECT_EQ(160, bin[1]);
    EXPECT_EQ(120, bin[2]);
    EXPECT_EQ(200, bin[3]);
    EXPECT_EQ(40, bin[4]);
    EXPECT_EQ(-1, bin[5]) << "an unfilled slot must read as empty";
    for (int s = 0; s + 1 < found; s++)
        EXPECT_GE((double)pwr[bin[s]], (double)pwr[bin[s + 1]]) << "slot " << s;
}

TEST(Peaks, RefusesAPeakInsideTheDcRegionHoweverTallItStands) {
    Plan p(512, DSP_WINDOW_HANN);
    ASSERT_EQ(DSP_OK, p.rc());
    const int m = p->m;
    std::vector<dsp_real> pwr(m, (dsp_real)1e-12);
    int bin[6];

    pwr[p->kdc + 1] = (dsp_real)0.25;
    int found = dsp_peaks(pwr.data(), m, 0, m - 1, p->kdc, 6, &p->ip, bin, nullptr, nullptr);
    ASSERT_GE(found, 1);
    EXPECT_EQ(p->kdc + 1, bin[0]) << "want bin " << (p->kdc + 1);

    pwr[p->kdc + 1] = (dsp_real)1e-12;
    pwr[1] = (dsp_real)1.0;
    found = dsp_peaks(pwr.data(), m, 0, m - 1, p->kdc, 6, &p->ip, bin, nullptr, nullptr);
    EXPECT_EQ(0, found) << "reported bin " << bin[0];
}

TEST(Peaks, AWindowedSearchIgnoresTheOffScreenTone) {
    Plan p(512, DSP_WINDOW_HANN);
    ASSERT_EQ(DSP_OK, p.rc());
    const int m = p->m;
    std::vector<dsp_real> pwr(m, (dsp_real)1e-12);
    pwr[61] = (dsp_real)0.04; // inside the window
    pwr[204] = (dsp_real)1.0; // outside it, and much taller
    int bin[6];
    int found = dsp_peaks(pwr.data(), m, 40, 81, p->kdc, 6, &p->ip, bin, nullptr, nullptr);
    ASSERT_GE(found, 1);
    EXPECT_EQ(61, bin[0]);
    for (int s = 0; s < found; s++)
        EXPECT_TRUE(bin[s] >= 40 && bin[s] <= 81) << bin[s];
}

TEST(Peaks, AFlatSpectrumIsHandledWithoutCrashing) {
    Plan p(512, DSP_WINDOW_HANN);
    ASSERT_EQ(DSP_OK, p.rc());
    const int m = p->m;
    int bin[6];
    dsp_real frac[6], amp[6];
    for (double level : {0.0, 1e-30, 1.0}) {
        std::vector<dsp_real> pwr(m, (dsp_real)level);
        int found = dsp_peaks(pwr.data(), m, 0, m - 1, p->kdc, 6, &p->ip, bin, frac, amp);

        EXPECT_GE(found, 0);
        EXPECT_LE(found, 6);
        for (int s = 0; s < found; s++)
            EXPECT_TRUE(bin[s] >= 0 && bin[s] < m) << bin[s];
    }
}

TEST(Peaks, APlateauReportsItsLeftBin) {

    Plan p(512, DSP_WINDOW_HANN);
    ASSERT_EQ(DSP_OK, p.rc());
    const int m = p->m;
    std::vector<dsp_real> pwr(m, (dsp_real)1e-12);
    pwr[100] = pwr[101] = (dsp_real)0.5;
    int bin[6];
    int found = dsp_peaks(pwr.data(), m, 0, m - 1, p->kdc, 6, &p->ip, bin, nullptr, nullptr);
    ASSERT_GE(found, 1);
    EXPECT_EQ(100, bin[0]);
    for (int s = 1; s < found; s++)
        EXPECT_NE(101, bin[s]) << "the right half must not also report";
}

TEST(Peaks, ANanDoesNotReachAReportedPeak) {

    Plan p(512, DSP_WINDOW_HANN);
    ASSERT_EQ(DSP_OK, p.rc());
    const int m = p->m;
    std::vector<dsp_real> pwr(m, (dsp_real)1e-12);
    pwr[100] = (dsp_real)0.5;
    pwr[150] = (dsp_real)kNaN;
    ASSERT_TRUE(std::isnan((double)pwr[150])) << "this host does not produce a NaN from 0/0";
    int bin[6];
    dsp_real frac[6], amp[6];
    int found = dsp_peaks(pwr.data(), m, 0, m - 1, p->kdc, 6, &p->ip, bin, frac, amp);
    ASSERT_GE(found, 1);
    EXPECT_EQ(100, bin[0]);
    for (int s = 0; s < found; s++) {
        EXPECT_NE(150, bin[s]) << "the NaN bin was reported";
        EXPECT_FALSE(std::isnan((double)frac[s])) << "slot " << s;
        EXPECT_FALSE(std::isnan((double)amp[s])) << "slot " << s;
    }

    const int n = 512;
    Plan q(n, DSP_WINDOW_HANN);
    auto x = ToneAtBin(n, 100.4);
    x[7] = kNaN;
    ASSERT_EQ(q->m, RunSpectrum(q, x));
    found = dsp_peaks(q->pwr, q->m, 1, q->m - 1, q->kdc, 6, &q->ip, bin, frac, amp);
    for (int s = 0; s < found; s++) {
        EXPECT_FALSE(std::isnan((double)q->pwr[bin[s]])) << "bin " << bin[s];
        EXPECT_FALSE(std::isnan((double)amp[s])) << "slot " << s;
    }
}

TEST(Peaks, RefusesBadArguments) {
    Plan p(512, DSP_WINDOW_HANN);
    ASSERT_EQ(DSP_OK, p.rc());
    std::vector<dsp_real> pwr(p->m, (dsp_real)1e-12);
    int bin[6];
    EXPECT_EQ(DSP_EARG,
              dsp_peaks(nullptr, p->m, 0, p->m - 1, p->kdc, 6, &p->ip, bin, nullptr, nullptr));
    EXPECT_EQ(DSP_EARG, dsp_peaks(pwr.data(), p->m, 0, p->m - 1, p->kdc, 6, &p->ip, nullptr,
                                  nullptr, nullptr));
    EXPECT_EQ(DSP_EARG,
              dsp_peaks(pwr.data(), p->m, 0, p->m - 1, p->kdc, 0, &p->ip, bin, nullptr, nullptr));
    EXPECT_EQ(DSP_EARG, dsp_peaks(pwr.data(), p->m, 0, p->m - 1, p->kdc, DSP_PEAKS_MAX + 1, &p->ip,
                                  bin, nullptr, nullptr));
}

// FIR

// Use the interpreted path's tap limit for its conformance cases, not the native limit.
constexpr int kLuaMaxTaps = 65;

TEST(Fir, TapsAreOddSymmetricAndSumToOne) {
    dsp_real h[DSP_FIR_MAXTAPS];
    int l = dsp_fir_design(h, DSP_FIR_MAXTAPS, 100000.0, 0.0, 10000.0, 4, 0);
    ASSERT_GT(l, 0) << "no taps built";
    EXPECT_EQ(1, l & 1) << l << " taps";
    double sum = 0.0, worst = 0.0;
    for (int i = 0; i < l; i++)
        sum += (double)h[i];
    for (int i = 0; i < l; i++)
        worst = std::max(worst, std::fabs((double)h[i] - (double)h[l - 1 - i]));
    EXPECT_NEAR(sum, 1.0, kSingle ? 1e-6 : 1e-12) << "sum " << sum;
    EXPECT_LT(worst, kSingle ? 1e-7 : 1e-15) << "worst asymmetry " << worst;
    std::printf("[  fir ] %d taps at /4, sum %.15f, worst asymmetry %g\n", l, sum, worst);
}

TEST(Fir, OrderIsHonouredAndForcedOdd) {
    dsp_real h[DSP_FIR_MAXTAPS];
    EXPECT_EQ(51, dsp_fir_design(h, DSP_FIR_MAXTAPS, 100000.0, 0.0, 10000.0, 4, 51));
    EXPECT_EQ(51, dsp_fir_design(h, DSP_FIR_MAXTAPS, 100000.0, 0.0, 10000.0, 4, 50));
    EXPECT_EQ(3, dsp_fir_design(h, DSP_FIR_MAXTAPS, 100000.0, 0.0, 10000.0, 4, 1));
    EXPECT_EQ(DSP_EARG, dsp_fir_design(h, DSP_FIR_MAXTAPS, 100000.0, 0.0, 10000.0, 4, 1001));
    EXPECT_EQ(DSP_EARG, dsp_fir_design(h, 11, 100000.0, 0.0, 10000.0, 4, 51))
        << "maxtaps is the caller's buffer and must bound the design";

    EXPECT_EQ(65, dsp_fir_design(h, kLuaMaxTaps, 100000.0, 0.0, 10000.0, 4, 0));
    EXPECT_EQ(133, dsp_fir_design(h, DSP_FIR_MAXTAPS, 100000.0, 0.0, 10000.0, 4, 0));
    EXPECT_EQ(31, dsp_fir_design(h, 32, 100000.0, 0.0, 10000.0, 4, 0))
        << "an even ceiling must come back odd, not over the caller's buffer";
}

TEST(Fir, ANonDecimatingLowPassIsNoFilterButABandPassIs) {
    dsp_real h[DSP_FIR_MAXTAPS];

    EXPECT_EQ(0, dsp_fir_design(h, DSP_FIR_MAXTAPS, 100000.0, 0.0, 20000.0, 1, 0));
#if DSP_BANDPASS
    EXPECT_GT(dsp_fir_design(h, DSP_FIR_MAXTAPS, 100000.0, 2000.0, 20000.0, 1, 101), 0);

    EXPECT_GT(dsp_fir_design(h, DSP_FIR_MAXTAPS, 100000.0, 2000.0, 20000.0, 2, 101), 0);
    EXPECT_EQ(DSP_EZONE, dsp_fir_design(h, DSP_FIR_MAXTAPS, 100000.0, 2000.0, 20000.0, 4, 101));
#else

    EXPECT_EQ(DSP_EUNSUPPORTED,
              dsp_fir_design(h, DSP_FIR_MAXTAPS, 100000.0, 2000.0, 20000.0, 1, 101));
    EXPECT_EQ(DSP_EUNSUPPORTED,
              dsp_fir_design(h, DSP_FIR_MAXTAPS, 100000.0, 2000.0, 20000.0, 4, 101));
#endif
    EXPECT_EQ(DSP_EARG, dsp_fir_design(h, DSP_FIR_MAXTAPS, 0.0, 0.0, 20000.0, 4, 0));
    EXPECT_EQ(DSP_EARG, dsp_fir_design(nullptr, DSP_FIR_MAXTAPS, 100000.0, 0.0, 2e4, 4, 0));

    EXPECT_EQ(DSP_EARG, dsp_fir_design(h, DSP_FIR_MAXTAPS, 100000.0, 20000.0, 2000.0, 4, 0));
    EXPECT_EQ(DSP_EARG, dsp_fir_design(h, DSP_FIR_MAXTAPS, 100000.0, 20000.0, 20000.0, 4, 0));
    EXPECT_EQ(DSP_EARG, dsp_fir_design(h, DSP_FIR_MAXTAPS, 100000.0, -1000.0, 20000.0, 4, 0));

    EXPECT_EQ(DSP_EARG, dsp_fir_design(h, DSP_FIR_MAXTAPS, 100000.0, 2000.0, 60000.0, 4, 0));
}

TEST(Fir, TapsForRefusesATransitionThatDoesNotFit) {

    for (int cap : {kLuaMaxTaps, DSP_FIR_MAXTAPS}) {
        EXPECT_EQ(0, dsp_fir_taps_for(100000.0, 0.0, 50000.0, 1, cap)) << "zero width at /1";
        EXPECT_EQ(0, dsp_fir_taps_for(100000.0, 0.0, 10000.0, 5, cap)) << "zero width at /5";
        EXPECT_EQ(0, dsp_fir_taps_for(100000.0, 0.0, 10000.0, 6, cap)) << "stop past the Nyquist";
    }

    EXPECT_EQ(51, dsp_fir_taps_for(100000.0, 0.0, 10000.0, 3, kLuaMaxTaps));
    EXPECT_EQ(51, dsp_fir_taps_for(100000.0, 0.0, 10000.0, 3, DSP_FIR_MAXTAPS));

    EXPECT_EQ(0, dsp_fir_taps_for(100000.0, 0.0, 10000.0, 4, kLuaMaxTaps));
    EXPECT_EQ(133, dsp_fir_taps_for(100000.0, 0.0, 10000.0, 4, DSP_FIR_MAXTAPS));

    EXPECT_EQ(0, dsp_fir_taps_for(100000.0, 0.0, 12400.0, 4, kLuaMaxTaps));
    EXPECT_EQ(0, dsp_fir_taps_for(100000.0, 0.0, 12400.0, 4, DSP_FIR_MAXTAPS));

    EXPECT_EQ(7, dsp_fir_taps_for(100000.0, 0.0, 1.0, 1, DSP_FIR_MAXTAPS));
    EXPECT_EQ(7, dsp_fir_taps_for(100000.0, 0.0, 1000.0, 1, DSP_FIR_MAXTAPS));
    EXPECT_EQ(0, dsp_fir_taps_for(100000.0, 0.0, 1000.0, 1, 2)) << "a ceiling under three taps";
    for (int cap : {kLuaMaxTaps, DSP_FIR_MAXTAPS}) {
        for (int d = 1; d <= 16; d++) {
            int l = dsp_fir_taps_for(100000.0, 0.0, 2000.0, d, cap);
            ASSERT_TRUE(l == 0 || (l >= 3 && l <= cap && (l & 1)))
                << "cap " << cap << " /" << d << " -> " << l;
        }
    }
}

// Drive a tone through the real taps and measure the steady state after the group delay.
double FirGainAt(double fs, double fhi, int n, int decim, int ntaps, const dsp_real *h, double hz) {
    int nx = dsp_fir_srclength(n, decim, ntaps);
    std::vector<double> x(nx), y(n + 1);
    for (int i = 0; i < nx; i++)
        x[i] = std::sin(2.0 * M_PI * hz * i / fs);
    int ny = dsp_fir_run(x.data(), nx, h, ntaps, decim, y.data());
    if (ny < n)
        return -1.0;
    double mx = 0.0;
    for (int i = (int)std::ceil((double)ntaps / decim); i < n; i++)
        mx = std::max(mx, std::fabs(y[i]));
    (void)fhi;
    return mx;
}

TEST(Fir, FlatAcrossTheSpanAndDownPastTheNyquist) {

    const double fs = 200000.0, fhi = 20000.0;
    const int n = 512;
    int d = dsp_fir_pick_decim(fs, 0.0, fhi, n, DSP_FIR_MAXTAPS);
    ASSERT_GE(d, 2) << "no decimation to test at /1";
    dsp_real h[DSP_FIR_MAXTAPS];
    int l = dsp_fir_design(h, DSP_FIR_MAXTAPS, fs, 0.0, fhi, d, 0);
    ASSERT_GT(l, 0);
    double nyq = fs / (2.0 * d);
    double dc = FirGainAt(fs, fhi, n, d, l, h, 100.0);
    ASSERT_GT(dc, 0.0);
    auto db = [dc](double x) { return 20.0 * std::log10(x / dc); };
    double mid = db(FirGainAt(fs, fhi, n, d, l, h, fhi / 2));
    double edge = db(FirGainAt(fs, fhi, n, d, l, h, fhi * 0.98));
    double above = db(FirGainAt(fs, fhi, n, d, l, h, nyq * 1.15));
    std::printf("[  fir ] %d taps at /%d: mid %.2f dB, span edge %.2f dB, %.0f Hz %.1f dB\n", l, d,
                mid, edge, nyq * 1.15, above);
    EXPECT_LT(std::fabs(mid), 0.5);
    EXPECT_LT(std::fabs(edge), 0.5);
    EXPECT_LT(above, -30.0);
}

TEST(Fir, TheCutoffMustSitMidwayAndNotOnTheStop) {

    const double fs = 200000.0, fhi = 20000.0;
    const int n = 512;
    int d = dsp_fir_pick_decim(fs, 0.0, fhi, n, DSP_FIR_MAXTAPS);
    ASSERT_GE(d, 2);
    dsp_real h[DSP_FIR_MAXTAPS];
    int l = dsp_fir_design(h, DSP_FIR_MAXTAPS, fs, 0.0, fhi, d, 0);
    ASSERT_GT(l, 0);

    double fhi_bad = 2.0 * fhi - fs * 0.5 / d;
    ASSERT_GT(fhi_bad, 0.0);
    dsp_real hbad[DSP_FIR_MAXTAPS];
    int lbad = dsp_fir_design(hbad, DSP_FIR_MAXTAPS, fs, 0.0, fhi_bad, d, l);
    ASSERT_EQ(l, lbad) << "the control must differ only in the cutoff";

    double dc_ok = FirGainAt(fs, fhi, n, d, l, h, 100.0);
    double dc_bad = FirGainAt(fs, fhi, n, d, lbad, hbad, 100.0);
    double edge_ok = 20.0 * std::log10(FirGainAt(fs, fhi, n, d, l, h, fhi * 0.98) / dc_ok);
    double edge_bad = 20.0 * std::log10(FirGainAt(fs, fhi, n, d, lbad, hbad, fhi * 0.98) / dc_bad);
    std::printf("[  fir ] span edge: cutoff midway %.2f dB, cutoff on the stop %.2f dB\n", edge_ok,
                edge_bad);
    EXPECT_LT(edge_bad, -2.0) << "a cutoff on the stop must read the span edge low";
    EXPECT_GT(std::fabs(edge_bad), std::fabs(edge_ok) * 5.0);
}

TEST(Fir, AnOutOfBandToneIsStoppedBeforeItCanFold) {

    const double fs = 100000.0, fhi = 10000.0;
    const int n = 512, d = 4;
    dsp_real h[DSP_FIR_MAXTAPS];
    int l = dsp_fir_design(h, DSP_FIR_MAXTAPS, fs, 0.0, fhi, d, 0);
    ASSERT_GT(l, 0);
    double inband = FirGainAt(fs, fhi, n, d, l, h, 2000.0);
    double alias = FirGainAt(fs, fhi, n, d, l, h, 20000.0);
    std::printf("[  fir ] 2 kHz through at %.3f, 20 kHz down to %.4f (%.1f dB)\n", inband, alias,
                20.0 * std::log10(alias / inband));
    EXPECT_GT(inband, 0.9);
    EXPECT_LT(alias, 0.05);
}

TEST(Fir, ADecimatingRunMatchesANonDecimatingOneAtTheSamePoints) {
    const int n = 512, d = 4;
    dsp_real h[DSP_FIR_MAXTAPS];
    int l = dsp_fir_design(h, DSP_FIR_MAXTAPS, 100000.0, 0.0, 10000.0, d, 0);
    ASSERT_GT(l, 0);
    int nx = dsp_fir_srclength(n, d, l);
    std::vector<double> x(nx);
    for (int i = 0; i < nx; i++)
        x[i] = std::sin(2.0 * M_PI * 3100.0 * i / 100000.0) +
               0.3 * std::sin(2.0 * M_PI * 311.0 * i / 100000.0 + 1.1);
    std::vector<double> y1(nx), yd(nx);
    int ny1 = dsp_fir_run(x.data(), nx, h, l, 1, y1.data());
    int nyd = dsp_fir_run(x.data(), nx, h, l, d, yd.data());
    ASSERT_EQ(nx - l + 1, ny1);
    ASSERT_EQ(n, nyd);

    for (int j = 0; j < nyd; j++)
        ASSERT_EQ(y1[j * d], yd[j]) << "output " << j;
}

TEST(Fir, RunRefusesARecordShorterThanTheTaps) {
    dsp_real h[DSP_FIR_MAXTAPS];
    int l = dsp_fir_design(h, DSP_FIR_MAXTAPS, 100000.0, 0.0, 10000.0, 4, 0);
    ASSERT_GT(l, 0);
    std::vector<double> x(l), y(l);
    EXPECT_EQ(1, dsp_fir_run(x.data(), l, h, l, 4, y.data()));
    EXPECT_EQ(DSP_EARG, dsp_fir_run(x.data(), l - 1, h, l, 4, y.data()));
    EXPECT_EQ(DSP_EARG, dsp_fir_run(x.data(), l, h, l, 0, y.data()));
    EXPECT_EQ(DSP_EARG, dsp_fir_run(nullptr, l, h, l, 4, y.data()));
}

#if DSP_CHECK_OVERLAP
// In-place convolution would overwrite source samples still needed by later outputs.
TEST(Fir, RunRefusesToFilterInPlace) {
    dsp_real h[DSP_FIR_MAXTAPS];
    const int l = dsp_fir_design(h, DSP_FIR_MAXTAPS, 100000.0, 0.0, 10000.0, 4, 0);
    ASSERT_GT(l, 0);

    std::vector<double> x((size_t)l * 4), y((size_t)l * 4);
    for (size_t i = 0; i < x.size(); i++)
        x[i] = std::sin(2.0 * M_PI * 500.0 * (double)i / 100000.0);
    const std::vector<double> before = x;
    ASSERT_GT(dsp_fir_run(x.data(), (int)x.size(), h, l, 4, y.data()), 0);
    EXPECT_EQ(DSP_EARG, dsp_fir_run(x.data(), (int)x.size(), h, l, 4, x.data()));
    EXPECT_EQ(before, x) << "refused before a single output was written over the input";
}
#endif

#if DSP_CHECK_OVERLAP
// Partial overlap must be detected even when buffer bases differ.
TEST(Fir, RunRefusesAnOutputOverlappingTheInputWithoutSharingItsBase) {
    dsp_real h[DSP_FIR_MAXTAPS];
    const int l = dsp_fir_design(h, DSP_FIR_MAXTAPS, 100000.0, 0.0, 10000.0, 4, 0);
    ASSERT_GT(l, 0);
    std::vector<double> x((size_t)l * 4);
    for (size_t i = 0; i < x.size(); i++)
        x[i] = std::sin(2.0 * M_PI * 500.0 * (double)i / 100000.0);
    const int nx = (int)x.size() - 1;
    const std::vector<double> before = x;

    ASSERT_NE(x.data(), x.data() + 1);
    EXPECT_EQ(DSP_EARG, dsp_fir_run(x.data(), nx, h, l, 4, x.data() + 1));
    EXPECT_EQ(before, x);

    EXPECT_EQ(DSP_EARG, dsp_fir_run(x.data() + 1, nx, h, l, 4, x.data()));
    EXPECT_EQ(before, x);

    std::vector<double> y(x.size());
    EXPECT_GT(dsp_fir_run(x.data(), nx, h, l, 4, y.data()), 0);
}
#endif

#if DSP_CHECK_OVERLAP
// The plan struct must not overlap the arrays it initializes inside the arena.
TEST(PlanInit, RefusesAPlanInsideItsOwnArena) {
    const int n = 256;
    const size_t bytes = dsp_plan_bytes(n, 1, DSP_FFT_DEFAULT);
    ASSERT_GT(bytes, 0u);
    std::vector<unsigned char> blob(bytes + sizeof(dsp_plan) + 2 * DSP_ALIGN, 0);
    dsp_plan *inside = reinterpret_cast<dsp_plan *>(AlignUp(blob.data()));
    unsigned char *arena = AlignUp(reinterpret_cast<unsigned char *>(inside) + sizeof(dsp_plan));

    ASSERT_EQ(DSP_OK, dsp_plan_init(inside, arena, bytes, n, DSP_WINDOW_HANN, 12.0, 1,
                                    DSP_FFT_DEFAULT));

    EXPECT_EQ(DSP_EARG, dsp_plan_init(inside, inside, bytes + sizeof(dsp_plan), n,
                                      DSP_WINDOW_HANN, 12.0, 1, DSP_FFT_DEFAULT));
    EXPECT_EQ(0, inside->n) << "zeroed on the refusal, like every other plan refusal";

    dsp_plan *midway = reinterpret_cast<dsp_plan *>(arena);
    EXPECT_EQ(DSP_EARG, dsp_plan_init(midway, arena, bytes, n, DSP_WINDOW_HANN, 12.0, 1,
                                      DSP_FFT_DEFAULT));
}
#endif

TEST(Fir, TheDecimationIsCappedByTheFilterLengthAsWellAsTheReadCost) {

    int read65 = (int)std::floor((double)(DSP_FIR_MAXM - kLuaMaxTaps) / 511.0);
    int read384 = (int)std::floor((double)(DSP_FIR_MAXM - DSP_FIR_MAXTAPS) / 511.0);

    EXPECT_EQ(1, dsp_fir_pick_decim(100000.0, 0.0, 50000.0, 512, kLuaMaxTaps))
        << "a 50 kHz stop at 100 kS/s has no room";
    EXPECT_EQ(3, dsp_fir_pick_decim(100000.0, 0.0, 10000.0, 512, kLuaMaxTaps));
    int narrow65 = dsp_fir_pick_decim(100000.0, 0.0, 2000.0, 512, kLuaMaxTaps);
    EXPECT_EQ(7, narrow65);
    EXPECT_LT(narrow65, read65) << "at 65 taps the filter is the tighter cap";
    EXPECT_EQ(1, dsp_fir_pick_decim(100000.0, 0.0, 2000.0, 16384, kLuaMaxTaps))
        << "16384 samples leaves no read budget whatever the span";

    int narrow384 = dsp_fir_pick_decim(100000.0, 0.0, 2000.0, 512, DSP_FIR_MAXTAPS);
    EXPECT_EQ(read384, narrow384) << "at 384 taps the read budget is the binding cap";
    EXPECT_GT(narrow384, narrow65);

    EXPECT_EQ(4, dsp_fir_pick_decim(100000.0, 0.0, 10000.0, 512, DSP_FIR_MAXTAPS));
    EXPECT_EQ(133, dsp_fir_taps_for(100000.0, 0.0, 10000.0, 4, DSP_FIR_MAXTAPS));
    EXPECT_EQ(0, dsp_fir_taps_for(100000.0, 0.0, 10000.0, 4, kLuaMaxTaps));
    EXPECT_EQ(1, dsp_fir_pick_decim(100000.0, 0.0, 50000.0, 512, DSP_FIR_MAXTAPS));

    EXPECT_EQ(30, dsp_fir_pick_decim(100000.0, 0.0, 100.0, 256, DSP_FIR_MAXTAPS));
    EXPECT_LE(dsp_fir_srclength(256, 30, dsp_fir_taps_for(100000.0, 0.0, 100.0, 30, DSP_FIR_MAXTAPS)),
              DSP_FIR_MAXM);

    for (int cap : {kLuaMaxTaps, DSP_FIR_MAXTAPS}) {
        for (int hi = 2000; hi <= 50000; hi += 500) {
            int d = dsp_fir_pick_decim(100000.0, 0.0, (double)hi, 512, cap);
            if (d > 1)
                ASSERT_GT(dsp_fir_taps_for(100000.0, 0.0, (double)hi, d, cap), 0)
                    << "stop " << hi << " Hz chose /" << d << ", which needs more than " << cap
                    << " taps";
        }
    }
    EXPECT_EQ(1, dsp_fir_pick_decim(0.0, 0.0, 10000.0, 512, DSP_FIR_MAXTAPS));
    EXPECT_EQ(1, dsp_fir_pick_decim(100000.0, 0.0, 10000.0, 1, DSP_FIR_MAXTAPS));
}

TEST(Fir, NoChosenDecimationPutsTheStopPastItsOwnNyquist) {
    const double fs = 100000.0;
    for (int cap : {kLuaMaxTaps, DSP_FIR_MAXTAPS}) {
        for (int hi = 2000; hi <= 50000; hi += 500) {
            int d = dsp_fir_pick_decim(fs, 0.0, (double)hi, 512, cap);
            ASSERT_GE((fs / d) / 2.0, (double)hi) << "cap " << cap << ": stop " << hi << " Hz at /"
                                                  << d << " leaves Nyquist " << (fs / d) / 2.0;
        }
    }
}

TEST(Fir, SourceLengthIsTheRecordTheFilterMustConsume) {

    EXPECT_EQ(65583, dsp_fir_srclength(16384, 4, 51));
    EXPECT_EQ(512, dsp_fir_srclength(512, 1, 0)) << "no decimation: the count is the count";
    EXPECT_EQ((512 - 1) * 3 + 25, dsp_fir_srclength(512, 3, 25));
    EXPECT_DOUBLE_EQ(100000.0 / 4 / 512, dsp_binwidth(100000.0, 512, 4));
    EXPECT_DOUBLE_EQ(100000.0 / 512, dsp_binwidth(100000.0, 512, 1));
}

TEST(Fir, AShortSourceRecordIsRefusedNotZeroPadded) {

    const int n = 512, d = 4;
    Plan p(n, DSP_WINDOW_HANN, 0.0, d);
    ASSERT_EQ(DSP_OK, p.rc());
    int l = dsp_fir_design(p->h, DSP_FIR_MAXTAPS, 100000.0, 0.0, 10000.0, d, 0);
    ASSERT_GT(l, 0);
    p.get().ntaps = l;
    int need = dsp_fir_srclength(n, d, l);
    std::vector<double> x(need);
    for (int i = 0; i < need; i++)
        x[i] = std::sin(2.0 * M_PI * 3000.0 * i / 100000.0);
    ASSERT_EQ(p->m, dsp_spectrum_run(&p.get(), x.data(), need, nullptr));
    std::vector<dsp_real> keep(p->pwr, p->pwr + p->m);
    EXPECT_EQ(DSP_ESHORT, dsp_spectrum_run(&p.get(), x.data(), need - 1, nullptr));
    EXPECT_EQ(DSP_ESHORT, dsp_spectrum_run(&p.get(), x.data(), need / 2, nullptr));
    for (int k = 0; k < p->m; k++)
        ASSERT_EQ(keep[k], p->pwr[k]) << "bin " << k << " moved";
}

TEST(Fir, TheWholePathNarrowsTheBinByTheDecimation) {

    const double fs = 100000.0, fhi = 2000.0;
    const int n = 512;
    int d = dsp_fir_pick_decim(fs, 0.0, fhi, n, DSP_FIR_MAXTAPS);
    ASSERT_GE(d, 2);
    Plan p(n, DSP_WINDOW_HANN, 0.0, d);
    ASSERT_EQ(DSP_OK, p.rc());
    int l = dsp_fir_design(p->h, DSP_FIR_MAXTAPS, fs, 0.0, fhi, d, 0);
    ASSERT_GT(l, 0);
    p.get().ntaps = l;
    int need = dsp_fir_srclength(n, d, l);
    double binhz = dsp_binwidth(fs, n, d);
    EXPECT_NEAR(binhz, fs / d / n, 1e-9);
    EXPECT_LT(binhz, fs / n / 2.0) << "the bin must be finer than the undecimated one";

    const double tone = 1234.0;
    std::vector<double> x(need);
    for (int i = 0; i < need; i++)
        x[i] = 0.8 * std::sin(2.0 * M_PI * tone * i / fs);
    ASSERT_EQ(p->m, dsp_spectrum_run(&p.get(), x.data(), need, nullptr));
    int bin[1];
    dsp_real frac[1], amp[1];
    int found = dsp_peaks(p->pwr, p->m, 1, p->m - 1, p->kdc, 1, &p->ip, bin, frac, amp);
    ASSERT_EQ(1, found);
    double hz = (bin[0] + (double)frac[0]) * binhz;
    std::printf("[  fir ] /%d, %d taps, bin %.3f Hz: %.0f Hz tone read %.4f Hz at %.4f V\n", d, l,
                binhz, tone, hz, (double)amp[0]);
    EXPECT_NEAR(hz, tone, 0.1 * binhz);

    EXPECT_NEAR((double)amp[0], 0.8, 0.005 * 0.8);
}

// Segment reduction

TEST(Reduce, ASingleBinSpikeSurvivesASegmentSpanningThirtyTwoBins) {

    const int m = 8192, nseg = 255;
    const double binhz = 100000.0 / 16384.0;
    std::vector<dsp_real> pwr(m, (dsp_real)1e-18);
    std::vector<dsp_real> db(nseg), hz(nseg);

    {
        int narrow = 1 << 30, wide = 0;
        for (int c = 0; c < nseg; c++) {
            int a = (int)(((long)c * m) / nseg);
            int b = (int)((((long)c + 1) * m) / nseg) - 1;
            narrow = std::min(narrow, b - a + 1);
            wide = std::max(wide, b - a + 1);
        }
        EXPECT_EQ(32, narrow);
        EXPECT_EQ(33, wide);
    }

    int tried = 0, found = 0, first_miss = -1;
    double worst_mean = -1e9;
    for (int k = 97; k < 97 + 72; k++) {
        pwr[k] = (dsp_real)1.0; // a lone 1 V^2 tone
        ASSERT_EQ(nseg, ReduceFlat(pwr.data(), m, 0, m - 1, nseg, binhz, -120.0, 20.0, 1e-9,
                                   db.data(), hz.data()));
        pwr[k] = (dsp_real)1e-18;
        double want = k * binhz;

        double tol = std::max(1.5 * binhz * m / nseg, 1.5 * binhz);
        bool hit = false;
        for (int q = 0; q < nseg; q++)
            if ((double)db[q] > -10.0 && std::fabs((double)hz[q] - want) < tol)
                hit = true;
        tried++;
        if (hit)
            found++;
        else if (first_miss < 0)
            first_miss = k;

        for (int c = 0; c < nseg; c++) {
            int a = (int)(((long)c * m) / nseg);
            int b = (int)((((long)c + 1) * m) / nseg) - 1;
            if (b < a)
                b = a;
            if (a <= k && k <= b) {
                double sum = 1.0 + (double)(b - a) * 1e-18;
                worst_mean = std::max(worst_mean, 10.0 * std::log10(sum / (double)(b - a + 1)));
            }
        }
    }
    std::printf("[reduce] %d of %d single-bin positions reached the trace; a mean reduction "
                "would read %.1f dB\n",
                found, tried, worst_mean);
    EXPECT_GT(tried, 0);
    EXPECT_EQ(tried, found) << "first miss at bin " << first_miss;
    EXPECT_LT(worst_mean, -14.0) << "the control must be below the -10 dB gate above";
}

TEST(Reduce, ReportsTheSegmentFrequencyNotTheWinningBin) {

    const int m = 64, nseg = 255;
    const double binhz = 195.3125;
    std::vector<dsp_real> pwr(m, (dsp_real)1e-12);
    pwr[40] = (dsp_real)1.0;
    std::vector<dsp_real> db(nseg), hz(nseg);
    ASSERT_EQ(nseg, ReduceFlat(pwr.data(), m, 0, m - 1, nseg, binhz, -120.0, 20.0, 1e-9, db.data(),
                               hz.data()));
    for (int c = 1; c < nseg; c++)
        ASSERT_GT((double)hz[c], (double)hz[c - 1]) << "segment " << c << " did not advance";
    EXPECT_NEAR((double)hz[0], 0.0, 1e-6);

    double step = ((double)m / nseg) * binhz;
    EXPECT_NEAR((double)hz[nseg - 1], (nseg - 1) * step, 1e-3 * binhz);
}

TEST(Reduce, EveryBinInTheWindowIsCoveredBySomeSegment) {

    const double kHot = 1.0, kCold = 1e-18;
    for (int m : {3, 5, 64, 100, 256}) {
        for (int nseg : {1, 2, 7, 17, 63, 64, 65, 255}) {
            for (int k0 : {0, 1, 2}) {
                if (k0 >= m)
                    continue;
                const int k1 = m - 1;
                std::vector<dsp_real> db(nseg), hz(nseg);
                std::vector<bool> seen((size_t)m, false);
                for (int hot = k0; hot <= k1; hot++) {
                    std::vector<dsp_real> pwr((size_t)m, (dsp_real)kCold);
                    pwr[hot] = (dsp_real)kHot;
                    dsp_bandmap map = FlatMap(1.0);
                    ASSERT_EQ(nseg, dsp_reduce(pwr.data(), m, k0, k1, nseg, &map, -200.0, 20.0,
                                               0.0, db.data(), hz.data()))
                        << "m=" << m << " nseg=" << nseg << " k0=" << k0;
                    for (int c = 0; c < nseg; c++)
                        if ((double)db[c] > -50.0) {
                            seen[(size_t)hot] = true;
                            break;
                        }
                }
                int missing = 0;
                int first = -1;
                for (int k = k0; k <= k1; k++)
                    if (!seen[(size_t)k]) {
                        missing++;
                        if (first < 0)
                            first = k;
                    }
                ASSERT_EQ(0, missing) << "m=" << m << " nseg=" << nseg << " k0=" << k0 << ": "
                                      << missing << " bins reach no segment, first at " << first;
            }
        }
    }
}

TEST(Reduce, TheSegmentationMatchesTheDirectQuotientExactly) {

    int pairs = 0;
    for (int npts = 1; npts <= 420; npts++) {
        const int qstep = npts;
        (void)qstep;
        for (int nseg = 1; nseg <= 420; nseg++) {
            int q0 = 0, q1 = npts / nseg, r1 = npts % nseg;
            const int step_q = npts / nseg, step_r = npts % nseg;
            for (int c = 0; c < nseg; c++) {
                const int want_a = (int)(((long long)c * npts) / nseg);
                const int want_b = (int)((((long long)c + 1) * npts) / nseg) - 1;
                ASSERT_EQ(want_a, q0) << "npts=" << npts << " nseg=" << nseg << " seg " << c;
                ASSERT_EQ(want_b, q1 - 1) << "npts=" << npts << " nseg=" << nseg << " seg " << c;
                q0 = q1;
                q1 += step_q;
                r1 += step_r;
                if (r1 >= nseg) {
                    r1 -= nseg;
                    q1++;
                }
            }

            ASSERT_EQ(npts, q0) << "npts=" << npts << " nseg=" << nseg << ": the carry did not "
                                                                          "close the window";
            pairs++;
        }
    }
    std::printf("[reduce] segmentation agreed with the direct quotient over %d pairs\n", pairs);
    EXPECT_EQ(420 * 420, pairs);
}

TEST(Reduce, ClampsToTheDbRangeAndPlotsTheFloorAtTheFloor) {
    const int m = 64, nseg = 32;
    std::vector<dsp_real> pwr(m, (dsp_real)0.0);
    pwr[10] = (dsp_real)1e6;   // +60 dB, above dbmax
    pwr[20] = (dsp_real)1e-30; // below the voltage floor
    std::vector<dsp_real> db(nseg), hz(nseg);
    ASSERT_EQ(nseg, ReduceFlat(pwr.data(), m, 0, m - 1, nseg, 100.0, -120.0, 20.0, 1e-9, db.data(),
                               hz.data()));
    for (int c = 0; c < nseg; c++) {
        ASSERT_GE((double)db[c], -120.0) << "segment " << c;
        ASSERT_LE((double)db[c], 20.0) << "segment " << c;
    }
    EXPECT_DOUBLE_EQ(20.0, (double)db[5]) << "the +60 dB bin must clamp at dbmax";
    EXPECT_DOUBLE_EQ(-120.0, (double)db[10]) << "a bin under the floor plots at dbmin";
    EXPECT_DOUBLE_EQ(-120.0, (double)db[0]) << "an exactly-zero bin must not reach log10";
}

TEST(Reduce, ANanBinPlotsAtTheFloorRatherThanPassingThrough) {

    const int m = 64, nseg = 16;
    std::vector<dsp_real> db(nseg), hz(nseg);
    for (int bad = 0; bad < m; bad++) {
        std::vector<dsp_real> pwr(m, (dsp_real)1e-12);
        pwr[bad] = (dsp_real)kNaN;
        ASSERT_TRUE(std::isnan((double)pwr[bad])) << "this host does not produce a NaN from 0/0";
        ASSERT_EQ(nseg, ReduceFlat(pwr.data(), m, 0, m - 1, nseg, 100.0, -120.0, 20.0, 1e-9,
                                   db.data(), hz.data()));
        for (int c = 0; c < nseg; c++) {
            ASSERT_FALSE(std::isnan((double)db[c])) << "NaN at bin " << bad << ", segment " << c;
            ASSERT_FALSE(std::isnan((double)hz[c])) << "NaN at bin " << bad << ", segment " << c;
            ASSERT_GE((double)db[c], -120.0) << "NaN at bin " << bad << ", segment " << c;
            ASSERT_LE((double)db[c], 20.0) << "NaN at bin " << bad << ", segment " << c;
        }
    }

    std::vector<dsp_real> pwr(m, (dsp_real)1e-12);
    pwr[0] = (dsp_real)kInf;
    ASSERT_EQ(nseg, ReduceFlat(pwr.data(), m, 0, m - 1, nseg, 100.0, -120.0, 20.0, 1e-9, db.data(),
                               hz.data()));
    EXPECT_DOUBLE_EQ(20.0, (double)db[0]);
}

TEST(Reduce, RefusesBadArguments) {
    std::vector<dsp_real> pwr(64, (dsp_real)1e-12), db(8), hz(8);
    EXPECT_EQ(DSP_EARG,
              ReduceFlat(nullptr, 64, 0, 63, 8, 100.0, -120, 20, 1e-9, db.data(), hz.data()));
    EXPECT_EQ(DSP_EARG,
              ReduceFlat(pwr.data(), 64, 0, 63, 8, 100.0, -120, 20, 1e-9, nullptr, hz.data()));
    EXPECT_EQ(DSP_EARG,
              ReduceFlat(pwr.data(), 64, 0, 63, 8, 100.0, -120, 20, 1e-9, db.data(), nullptr));
    EXPECT_EQ(DSP_EARG,
              ReduceFlat(pwr.data(), 64, 0, 63, 0, 100.0, -120, 20, 1e-9, db.data(), hz.data()));
    EXPECT_EQ(DSP_EARG,
              ReduceFlat(pwr.data(), 64, 10, 9, 8, 100.0, -120, 20, 1e-9, db.data(), hz.data()));
    EXPECT_EQ(DSP_EARG,
              ReduceFlat(pwr.data(), 64, -1, 63, 8, 100.0, -120, 20, 1e-9, db.data(), hz.data()));

    EXPECT_EQ(DSP_EARG,
              ReduceFlat(pwr.data(), 64, 0, 63, 8, 0.0, -120, 20, 1e-9, db.data(), hz.data()));

    EXPECT_EQ(DSP_EARG,
              ReduceFlat(pwr.data(), 0, 0, 63, 8, 100.0, -120, 20, 1e-9, db.data(), hz.data()));
    EXPECT_EQ(DSP_EARG,
              ReduceFlat(pwr.data(), -1, 0, 63, 8, 100.0, -120, 20, 1e-9, db.data(), hz.data()));
    EXPECT_EQ(DSP_EARG,
              ReduceFlat(pwr.data(), 64, 64, 70, 8, 100.0, -120, 20, 1e-9, db.data(), hz.data()));

    EXPECT_EQ(DSP_EARG, ReduceFlat(pwr.data(), 64, 0, 63, 8, kNaN, -120, 20, 1e-9, db.data(),
                                   hz.data()));
    EXPECT_EQ(DSP_EARG,
              ReduceFlat(pwr.data(), 64, 0, 63, 8, -1.0, -120, 20, 1e-9, db.data(), hz.data()));
    EXPECT_EQ(DSP_EARG, ReduceFlat(pwr.data(), 64, 0, 63, 8, kInf, -120, 20, 1e-9, db.data(),
                                   hz.data()))
        << "an infinite width passes a bare `> 0` test, and makes k0 * binhz the product 0*inf";

    EXPECT_EQ(DSP_EARG,
              ReduceFlat(pwr.data(), 64, 0, 63, 8, 100.0, 20, -120, 1e-9, db.data(), hz.data()))
        << "dbmin above dbmax";
    EXPECT_EQ(DSP_EARG,
              ReduceFlat(pwr.data(), 64, 0, 63, 8, 100.0, 0, 0, 1e-9, db.data(), hz.data()))
        << "a dB window of zero width";

    EXPECT_EQ(DSP_EARG,
              ReduceFlat(pwr.data(), 64, 0, 63, 8, 100.0, -120, 20, -1e-9, db.data(), hz.data()))
        << "a negative voltage floor";

    EXPECT_EQ(8, ReduceFlat(pwr.data(), 64, 0, 63, 8, 100.0, -120, 20, 0.0, db.data(), hz.data()));
    for (int c = 0; c < 8; c++)
        EXPECT_TRUE(std::isfinite((double)db[c])) << "vfloor 0, segment " << c;
}

TEST(Reduce, PastTheEndClampsInsteadOfReadingThere) {

    const int m = 64, nseg = 8;
    std::vector<dsp_real> pwr(m, (dsp_real)1e-12), db(nseg), hz(nseg);
    pwr[m - 1] = (dsp_real)1.0;
    std::vector<dsp_real> want_db(nseg), want_hz(nseg);
    ASSERT_EQ(nseg, ReduceFlat(pwr.data(), m, 0, m - 1, nseg, 100.0, -120.0, 20.0, 1e-9,
                               want_db.data(), want_hz.data()));

    for (int k1 : {m, m + 1, m * 4, 2147483647}) {
        std::vector<dsp_real> got_db(nseg, (dsp_real)-1), got_hz(nseg, (dsp_real)-1);
        ASSERT_EQ(nseg, ReduceFlat(pwr.data(), m, 0, k1, nseg, 100.0, -120.0, 20.0, 1e-9,
                                   got_db.data(), got_hz.data()))
            << "k1=" << k1;
        for (int c = 0; c < nseg; c++) {
            ASSERT_EQ(want_db[c], got_db[c]) << "k1=" << k1 << " segment " << c;
            ASSERT_EQ(want_hz[c], got_hz[c]) << "k1=" << k1 << " segment " << c;
        }
    }

    EXPECT_GT((double)want_db[nseg - 1], -10.0) << "the 1 V^2 bin must reach the last segment";
}

TEST(Reduce, AToneAnywhereInARealSpectrumReachesTheTrace) {

    const int n = 16384, nseg = 255;
    Plan p(n, DSP_WINDOW_HANN);
    ASSERT_EQ(DSP_OK, p.rc());
    const double binhz = dsp_binwidth(1000000.0, n, 1);
    std::vector<dsp_real> db(nseg), hz(nseg);
    for (double bin : {1000.3, 4095.0, 4096.5, 8000.0}) {
        auto x = ToneAtBin(n, bin);
        ASSERT_EQ(p->m, RunSpectrum(p, x));
        ASSERT_EQ(nseg, ReduceFlat(p->pwr, p->m, 0, p->m - 1, nseg, binhz, -120.0, 20.0, 1e-9,
                                   db.data(), hz.data()));
        double top = -1e9;
        int at = 0;
        for (int c = 0; c < nseg; c++)
            if ((double)db[c] > top) {
                top = (double)db[c];
                at = c;
            }

        EXPECT_GT(top, -1.5) << "bin " << bin << " read " << top << " dB";
        double tol = 1.5 * binhz * p->m / nseg;
        EXPECT_LT(std::fabs((double)hz[at] - bin * binhz), tol) << "bin " << bin;
    }
}

// Complete frames

TEST(Frame, SpectrumRunMatchesTheKernelsCalledByHand) {
    const int n = 1024;
    Plan a(n, DSP_WINDOW_BLACKMAN_HARRIS);
    Plan b(n, DSP_WINDOW_BLACKMAN_HARRIS);
    ASSERT_EQ(DSP_OK, a.rc());
    ASSERT_EQ(DSP_OK, b.rc());
    auto x = ToneAtBin(n, 200.37);
    double m1 = 0.0, m2 = 0.0;
    ASSERT_EQ(a->m, dsp_spectrum_run(&a.get(), x.data(), n, &m1));
    ASSERT_EQ(b->m, RunSpectrum(b, x, &m2));
    EXPECT_EQ(m1, m2);
    for (int k = 0; k < a->m; k++)
        ASSERT_EQ(a->pwr[k], b->pwr[k]) << "bin " << k;
}

TEST(Frame, RefusesBadArguments) {
    Plan p(64, DSP_WINDOW_HANN);
    ASSERT_EQ(DSP_OK, p.rc());
    std::vector<double> x(64, 1.0);
    EXPECT_EQ(DSP_EARG, dsp_spectrum_run(nullptr, x.data(), 64, nullptr));
    EXPECT_EQ(DSP_EARG, dsp_spectrum_run(&p.get(), nullptr, 64, nullptr));
    EXPECT_EQ(DSP_ESHORT, dsp_spectrum_run(&p.get(), x.data(), 0, nullptr));
    EXPECT_EQ(DSP_ESHORT, dsp_spectrum_run(&p.get(), x.data(), 63, nullptr));
    dsp_plan empty{};
    EXPECT_EQ(DSP_EARG, dsp_spectrum_run(&empty, x.data(), 64, nullptr));
}

TEST(Frame, TheLargeCountsTheProposalWantsToOfferWork) {

    for (int n : {16384, 32768, 65536}) {
        Plan p(n, DSP_WINDOW_KAISER, 12.0);
        ASSERT_EQ(DSP_OK, p.rc()) << "n=" << n;
        const double bin = n / 4.0 + 0.37;
        auto x = ToneAtBin(n, bin);
        ASSERT_EQ(p->m, dsp_spectrum_run(&p.get(), x.data(), n, nullptr)) << "n=" << n;
        int b[1];
        dsp_real frac[1], amp[1];
        ASSERT_EQ(1, dsp_peaks(p->pwr, p->m, 1, p->m - 1, p->kdc, 1, &p->ip, b, frac, amp))
            << "n=" << n;
        double got = b[0] + (double)frac[0];
        EXPECT_NEAR(got, bin, kWinDf) << "n=" << n << ": " << got;
        EXPECT_NEAR(20.0 * std::log10((double)amp[0]), 0.0, kWinDa) << "n=" << n;
    }
}

// Non-finite inputs
// Construct quiet and signaling NaN payloads independently. Non-finite readings
// must not propagate into graph parameters or valid results.

double QuietNaN() {
    uint64_t bits = 0x7FF8000000000001ull;
    double d;
    std::memcpy(&d, &bits, sizeof d);
    return d;
}

double SignallingNaN() {
    uint64_t bits = 0x7FF0000000000001ull; // exponent all ones, mantissa MSB clear, non-zero
    double d;
    std::memcpy(&d, &bits, sizeof d);
    return d;
}

double NegativeZero() {
    uint64_t bits = 0x8000000000000000ull;
    double d;
    std::memcpy(&d, &bits, sizeof d);
    return d;
}

struct Hostile {
    double v;
    const char *name;
};

std::vector<Hostile> HostileValues() {
    return {{QuietNaN(), "quiet NaN"},
            {SignallingNaN(), "signalling NaN"},
            {std::numeric_limits<double>::infinity(), "+inf"},
            {-std::numeric_limits<double>::infinity(), "-inf"},
            {NegativeZero(), "-0.0"},
            {std::numeric_limits<double>::max(), "DBL_MAX"},
            {-std::numeric_limits<double>::max(), "-DBL_MAX"},
            {std::numeric_limits<double>::denorm_min(), "smallest subnormal"}};
}

TEST(Hostile, TheTestValuesAreWhatTheyClaimToBe) {

    EXPECT_TRUE(std::isnan(QuietNaN()));
    EXPECT_TRUE(std::isnan(SignallingNaN()));
    uint64_t q = 0, s = 0, z = 0;
    double qn = QuietNaN(), sn = SignallingNaN(), nz = NegativeZero();
    std::memcpy(&q, &qn, sizeof q);
    std::memcpy(&s, &sn, sizeof s);
    std::memcpy(&z, &nz, sizeof z);
    EXPECT_NE(0u, q & 0x0008000000000000ull) << "the quiet NaN must have its mantissa MSB set";
    EXPECT_EQ(0u, s & 0x0008000000000000ull) << "the signalling NaN must have it clear";
    EXPECT_NE(0u, s & 0x0007FFFFFFFFFFFFull) << "and a non-zero mantissa, or it is an infinity";
    EXPECT_EQ(0x8000000000000000ull, z) << "negative zero must be the sign bit alone";
    EXPECT_EQ(0.0, nz) << "and must still compare equal to zero";
    EXPECT_TRUE(std::signbit(nz)) << "while carrying its sign";
}

TEST(Hostile, ScalarParametersAreRefusedOrClamped) {

    Plan p(256, DSP_WINDOW_HANN);
    ASSERT_EQ(DSP_OK, p.rc());
    std::vector<dsp_real> db(16), hz(16), pwr(64, (dsp_real)1e-12);
    dsp_real taps[DSP_FIR_MAXTAPS];

    for (const Hostile &h : HostileValues()) {
        SCOPED_TRACE(h.name);

        std::vector<dsp_real> w(64);
        int rc = dsp_window(w.data(), 64, DSP_WINDOW_KAISER, h.v);
        EXPECT_EQ(DSP_EBETA, rc) << "beta " << h.name << " returned " << rc;

        auto reduce_is_safe = [&](int code, const char *which) {
            if (code == DSP_EARG)
                return; // refused, which is the answer for a limit that is not a number
            ASSERT_EQ(16, code) << which << " " << h.name << ": unexpected return";
            for (int c = 0; c < 16; c++) {
                ASSERT_TRUE(std::isfinite((double)db[c]))
                    << which << " " << h.name << ": db[" << c << "]";
                ASSERT_TRUE(std::isfinite((double)hz[c]))
                    << which << " " << h.name << ": hz[" << c << "]";
                ASSERT_GE((double)db[c], -120.0) << which << " " << h.name << " segment " << c;
                ASSERT_LE((double)db[c], 20.0) << which << " " << h.name << " segment " << c;
            }
        };
        reduce_is_safe(
            ReduceFlat(pwr.data(), 64, 0, 63, 16, h.v, -120.0, 20.0, 1e-9, db.data(), hz.data()),
            "binhz");
        reduce_is_safe(
            ReduceFlat(pwr.data(), 64, 0, 63, 16, 100.0, h.v, 20.0, 1e-9, db.data(), hz.data()),
            "dbmin");
        reduce_is_safe(
            ReduceFlat(pwr.data(), 64, 0, 63, 16, 100.0, -120.0, h.v, 1e-9, db.data(), hz.data()),
            "dbmax");
        reduce_is_safe(
            ReduceFlat(pwr.data(), 64, 0, 63, 16, 100.0, -120.0, 20.0, h.v, db.data(), hz.data()),
            "vfloor");

        if (!std::isfinite(h.v)) {
            EXPECT_EQ(DSP_EARG, ReduceFlat(pwr.data(), 64, 0, 63, 16, h.v, -120.0, 20.0, 1e-9,
                                           db.data(), hz.data()))
                << "binhz " << h.name;
            EXPECT_EQ(DSP_EARG, ReduceFlat(pwr.data(), 64, 0, 63, 16, 100.0, h.v, 20.0, 1e-9,
                                           db.data(), hz.data()))
                << "dbmin " << h.name;
            EXPECT_EQ(DSP_EARG, ReduceFlat(pwr.data(), 64, 0, 63, 16, 100.0, -120.0, h.v, 1e-9,
                                           db.data(), hz.data()))
                << "dbmax " << h.name;
            EXPECT_EQ(DSP_EARG, ReduceFlat(pwr.data(), 64, 0, 63, 16, 100.0, -120.0, 20.0, h.v,
                                           db.data(), hz.data()))
                << "vfloor " << h.name;
        }

        double g = dsp_win_gain(&p->ip, h.v);
        EXPECT_FALSE(std::isnan(g)) << "gain at offset " << h.name;
        EXPECT_GE(g, 0.0) << "gain at offset " << h.name;
        double d = 1e9;
        if (dsp_win_offset(&p->ip, h.v, &d) == DSP_OK) {
            EXPECT_FALSE(std::isnan(d)) << "offset from ratio " << h.name;
            EXPECT_LE(std::fabs(d), 0.5) << "offset from ratio " << h.name << " gave " << d;
        }

        int l = dsp_fir_design(taps, DSP_FIR_MAXTAPS, h.v, 0.0, 20000.0, 4, 0);
        if (l > 0)
            for (int i = 0; i < l; i++)
                ASSERT_TRUE(std::isfinite((double)taps[i])) << "fs " << h.name << " tap " << i;
        l = dsp_fir_design(taps, DSP_FIR_MAXTAPS, 1e6, 0.0, h.v, 4, 0);
        if (l > 0)
            for (int i = 0; i < l; i++)
                ASSERT_TRUE(std::isfinite((double)taps[i])) << "fhi " << h.name << " tap " << i;

        if (h.v == 0.0) {
            int lz = dsp_fir_design(taps, DSP_FIR_MAXTAPS, 1e6, h.v, 2e4, 4, 0);
            dsp_real plus[DSP_FIR_MAXTAPS];
            int lp = dsp_fir_design(plus, DSP_FIR_MAXTAPS, 1e6, 0.0, 2e4, 4, 0);
            EXPECT_EQ(lp, lz) << "flo " << h.name << " must design like +0.0";
            for (int i = 0; i < lz && i < lp; i++)
                ASSERT_EQ(plus[i], taps[i]) << "flo " << h.name << " tap " << i;
        } else if (std::isfinite(h.v) && h.v > 0.0 && h.v < 2e4) {

            int rc2 = dsp_fir_design(taps, DSP_FIR_MAXTAPS, 1e6, h.v, 2e4, 4, 0);
            if (rc2 > 0)
                for (int i = 0; i < rc2; i++)
                    ASSERT_TRUE(std::isfinite((double)taps[i]))
                        << "flo " << h.name << " tap " << i;
        } else {
            EXPECT_LT(dsp_fir_design(taps, DSP_FIR_MAXTAPS, 1e6, h.v, 2e4, 4, 0), 0)
                << "flo " << h.name << " is outside 0 < flo < fhi and must be refused";
        }

        EXPECT_GE(dsp_fir_pick_decim(h.v, 0.0, 20000.0, 512, DSP_FIR_MAXTAPS), 1) << "fs " << h.name;
        EXPECT_GE(dsp_fir_pick_decim(1e6, 0.0, h.v, 512, DSP_FIR_MAXTAPS), 1) << "fhi " << h.name;
        EXPECT_GE(dsp_fir_taps_for(h.v, 0.0, 20000.0, 4, DSP_FIR_MAXTAPS), 0) << "fs " << h.name;
        EXPECT_GE(dsp_fir_taps_for(1e6, 0.0, h.v, 4, DSP_FIR_MAXTAPS), 0) << "fhi " << h.name;

        EXPECT_FALSE(std::isnan(dsp_fir_transition(h.v, 0.0, 20000.0, 4))) << "fs " << h.name;
        EXPECT_FALSE(std::isnan(dsp_fir_transition(1e6, 0.0, h.v, 4))) << "fhi " << h.name;

        for (int nt : {dsp_fir_taps_for(h.v, 0.0, 20000.0, 4, DSP_FIR_MAXTAPS),
                       dsp_fir_taps_for(1e6, 0.0, h.v, 4, DSP_FIR_MAXTAPS)}) {
            ASSERT_GE(nt, 0) << "fs/fhi " << h.name;
            if (nt != 0) {
                ASSERT_GE(nt, 3) << "fs/fhi " << h.name;
                ASSERT_LE(nt, DSP_FIR_MAXTAPS) << "fs/fhi " << h.name;
                ASSERT_EQ(1, nt & 1) << "fs/fhi " << h.name << ": the group delay must be whole";
            }
        }

        double bw = dsp_binwidth(h.v, 512, 1);
        EXPECT_TRUE(bw == 0.0 || (bw > 0.0 && std::isfinite(bw)))
            << "bin width from fs " << h.name << " is " << bw;

        Plan bad(256, DSP_WINDOW_KAISER, h.v);
        EXPECT_EQ(DSP_EBETA, bad.rc()) << "plan beta " << h.name;
        EXPECT_EQ(0, bad->n) << "plan beta " << h.name << ": a refused plan must be zeroed";
    }
}

TEST(Hostile, SampleDataSurvivesAndNeverReachesAnOutput) {

    const int n = 256;
    const int nseg = 32;
    for (const Hostile &h : HostileValues()) {
        SCOPED_TRACE(h.name);
        for (int at : {0, 1, n / 2 - 1, n / 2, n / 2 + 1, n - 2, n - 1}) {
            Plan p(n, DSP_WINDOW_HANN);
            ASSERT_EQ(DSP_OK, p.rc());
            auto x = ToneAtBin(n, 40.3);
            x[at] = h.v;
            double mean = 0.0;
            ASSERT_EQ(p->m, dsp_spectrum_run(&p.get(), x.data(), n, &mean))
                << h.name << " at sample " << at;

            int bins[6];
            dsp_real frac[6], amp[6];
            int found = dsp_peaks(p->pwr, p->m, 0, p->m - 1, p->kdc, 6, &p->ip, bins, frac, amp);
            ASSERT_GE(found, 0) << h.name << " at sample " << at;
            for (int s = 0; s < 6; s++) {
                ASSERT_LT(bins[s], p->m) << h.name << " at " << at << ": peak " << s
                                         << " is outside the spectrum";
                ASSERT_GE(bins[s], -1) << h.name << " at " << at;
                ASSERT_FALSE(std::isnan((double)frac[s]))
                    << h.name << " at " << at << ": peak " << s << " offset";
                ASSERT_FALSE(std::isnan((double)amp[s]))
                    << h.name << " at " << at << ": peak " << s << " amplitude";
                ASSERT_LE(std::fabs((double)frac[s]), 0.5) << h.name << " at " << at;
            }

            std::vector<dsp_real> db(nseg), hz(nseg);
            ASSERT_EQ(nseg, ReduceFlat(p->pwr, p->m, 0, p->m - 1, nseg, 390.625, -120.0, 20.0,
                                       1e-9, db.data(), hz.data()))
                << h.name << " at sample " << at;
            for (int c = 0; c < nseg; c++) {
                ASSERT_FALSE(std::isnan((double)db[c]))
                    << h.name << " at " << at << ": segment " << c;
                ASSERT_FALSE(std::isnan((double)hz[c]))
                    << h.name << " at " << at << ": segment " << c;
                ASSERT_GE((double)db[c], -120.0) << h.name << " at " << at << ": segment " << c;
                ASSERT_LE((double)db[c], 20.0) << h.name << " at " << at << ": segment " << c;
            }
        }
    }
}

TEST(Hostile, NegativeZeroBehavesAsZeroThroughout) {

    const int n = 256;
    Plan a(n, DSP_WINDOW_HANN);
    Plan b(n, DSP_WINDOW_HANN);
    ASSERT_EQ(DSP_OK, a.rc());
    ASSERT_EQ(DSP_OK, b.rc());
    std::vector<double> zp(n, 0.0), zn(n, NegativeZero());
    ASSERT_EQ(a->m, dsp_spectrum_run(&a.get(), zp.data(), n, nullptr));
    ASSERT_EQ(b->m, dsp_spectrum_run(&b.get(), zn.data(), n, nullptr));
    for (int k = 0; k < a->m; k++)
        ASSERT_EQ(a->pwr[k], b->pwr[k]) << "bin " << k << " differs between +0.0 and -0.0";

    for (int at : {0, 1, n / 2, n - 1}) {
        auto xp = ToneAtBin(n, 40.3);
        auto xn = xp;
        xp[at] = 0.0;
        xn[at] = NegativeZero();
        ASSERT_EQ(a->m, dsp_spectrum_run(&a.get(), xp.data(), n, nullptr));
        std::vector<dsp_real> want(a->pwr, a->pwr + a->m);
        ASSERT_EQ(b->m, dsp_spectrum_run(&b.get(), xn.data(), n, nullptr));
        for (int k = 0; k < b->m; k++)
            ASSERT_EQ(want[k], b->pwr[k]) << "sample " << at << ", bin " << k;
    }

    std::vector<dsp_real> pwr(64, (dsp_real)1e-12), db(8), hz(8);
    pwr[10] = (dsp_real)NegativeZero();
    ASSERT_EQ(8, ReduceFlat(pwr.data(), 64, 0, 63, 8, 100.0, -120.0, 20.0, 1e-9, db.data(),
                            hz.data()));
    for (int c = 0; c < 8; c++) {
        ASSERT_FALSE(std::isnan((double)db[c])) << "segment " << c;
        ASSERT_FALSE(std::isinf((double)db[c])) << "segment " << c;
        ASSERT_GE((double)db[c], -120.0) << "segment " << c;
    }

    double d = 0.0, aout = 0.0;
    pwr[20] = (dsp_real)NegativeZero();
    EXPECT_EQ(DSP_EDECLINE, dsp_peak_interp(&a->ip, pwr.data(), 20, 64, &d, &aout))
        << "a non-positive peak bin has no sub-bin estimate";
}

TEST(Hostile, AWholeRecordOfOneHostileValueCompletes) {

    const int n = 128;
    for (const Hostile &h : HostileValues()) {
        SCOPED_TRACE(h.name);
        Plan p(n, DSP_WINDOW_HANN);
        ASSERT_EQ(DSP_OK, p.rc());
        std::vector<double> x(n, h.v);
        double mean = 0.0;
        ASSERT_EQ(p->m, dsp_spectrum_run(&p.get(), x.data(), n, &mean)) << h.name;
        int bins[4];
        dsp_real frac[4], amp[4];
        ASSERT_GE(dsp_peaks(p->pwr, p->m, 0, p->m - 1, p->kdc, 4, &p->ip, bins, frac, amp), 0);
        for (int s = 0; s < 4; s++) {
            ASSERT_FALSE(std::isnan((double)frac[s])) << h.name << " peak " << s;
            ASSERT_FALSE(std::isnan((double)amp[s])) << h.name << " peak " << s;
        }
        std::vector<dsp_real> db(16), hz(16);
        ASSERT_EQ(16, ReduceFlat(p->pwr, p->m, 0, p->m - 1, 16, 100.0, -120.0, 20.0, 1e-9,
                                 db.data(), hz.data()))
            << h.name;
        for (int c = 0; c < 16; c++) {
            ASSERT_FALSE(std::isnan((double)db[c])) << h.name << " segment " << c;
            ASSERT_GE((double)db[c], -120.0) << h.name << " segment " << c;
            ASSERT_LE((double)db[c], 20.0) << h.name << " segment " << c;
        }
    }
}

TEST(Hostile, AHostileTapOrFilterInputDoesNotEscape) {

    const int ntaps = 21, decim = 4, nout = 32;
    const int nx = (nout - 1) * decim + ntaps;
    std::vector<double> x(nx), y(nout);
    std::vector<dsp_real> h(ntaps, (dsp_real)(1.0 / ntaps));
    for (const Hostile &bad : HostileValues()) {
        SCOPED_TRACE(bad.name);
        for (int i = 0; i < nx; i++)
            x[i] = 0.5;
        x[nx / 2] = bad.v;
        EXPECT_EQ(nout, dsp_fir_run(x.data(), nx, h.data(), ntaps, decim, y.data()))
            << "a hostile sample " << bad.name;
        for (int i = 0; i < nx; i++)
            x[i] = 0.5;
        std::vector<dsp_real> hb = h;
        hb[ntaps / 2] = (dsp_real)bad.v;
        EXPECT_EQ(nout, dsp_fir_run(x.data(), nx, hb.data(), ntaps, decim, y.data()))
            << "a hostile tap " << bad.name;
    }
}

// API refusals

TEST(Refusals, PlanSetFirValidatesBothTapsAndCount) {
    Plan p(512, DSP_WINDOW_HANN, 0, 4);
    ASSERT_EQ(DSP_OK, p.rc());
    dsp_real taps[DSP_FIR_MAXTAPS];
    for (int i = 0; i < DSP_FIR_MAXTAPS; i++)
        taps[i] = (dsp_real)(1.0 / DSP_FIR_MAXTAPS);

    EXPECT_EQ(DSP_EARG, dsp_plan_set_fir(nullptr, taps, 21)) << "a null plan";
    dsp_plan empty{};
    EXPECT_EQ(DSP_EARG, dsp_plan_set_fir(&empty, taps, 21)) << "a plan that was never built";
    EXPECT_EQ(DSP_EARG, dsp_plan_set_fir(&p.get(), taps, -1)) << "a negative count";
    EXPECT_EQ(DSP_EARG, dsp_plan_set_fir(&p.get(), taps, DSP_FIR_MAXTAPS + 1))
        << "a count past what h holds";
    EXPECT_EQ(DSP_EARG, dsp_plan_set_fir(&p.get(), nullptr, 21)) << "taps promised but absent";

    EXPECT_EQ(21, dsp_plan_set_fir(&p.get(), taps, 21));
    EXPECT_EQ(21, p->ntaps);
    EXPECT_EQ(DSP_FIR_MAXTAPS, dsp_plan_set_fir(&p.get(), taps, DSP_FIR_MAXTAPS))
        << "exactly as many taps as h holds";
    EXPECT_EQ(0, dsp_plan_set_fir(&p.get(), nullptr, 0)) << "a null with a zero count clears it";
    EXPECT_EQ(0, p->ntaps);
    EXPECT_EQ(0, dsp_plan_set_fir(&p.get(), taps, 0)) << "and so does a zero count alone";

    dsp_real local[5] = {(dsp_real)0.2, (dsp_real)0.2, (dsp_real)0.2, (dsp_real)0.2,
                         (dsp_real)0.2};
    ASSERT_EQ(5, dsp_plan_set_fir(&p.get(), local, 5));
    for (int i = 0; i < 5; i++)
        local[i] = (dsp_real)-99.0;
    for (int i = 0; i < 5; i++)
        EXPECT_EQ((dsp_real)0.2, p->h[i]) << "tap " << i << " must have been copied";
}

TEST(Refusals, SpectrumRunValidatesThePlansFilter) {
    const int n = 512, decim = 4;
    Plan p(n, DSP_WINDOW_HANN, 0, decim);
    ASSERT_EQ(DSP_OK, p.rc());
    std::vector<double> src(8192, 0.5);

    ASSERT_EQ(0, p->ntaps);
    EXPECT_EQ(DSP_EARG, dsp_spectrum_run(&p.get(), src.data(), (int)src.size(), nullptr))
        << "decim > 1 with no filter";

    dsp_real taps[DSP_FIR_MAXTAPS];
    int l = dsp_fir_design(taps, DSP_FIR_MAXTAPS, 1e6, 0.0, 20000.0, decim, 0);
    ASSERT_GT(l, 0);
    ASSERT_EQ(l, dsp_plan_set_fir(&p.get(), taps, l));
    for (int bad : {-1, DSP_FIR_MAXTAPS + 1, 4096}) {
        p.get().ntaps = bad;
        EXPECT_EQ(DSP_EARG, dsp_spectrum_run(&p.get(), src.data(), (int)src.size(), nullptr))
            << "ntaps " << bad;
    }
    p.get().ntaps = l;
    EXPECT_EQ(p->m, dsp_spectrum_run(&p.get(), src.data(), (int)src.size(), nullptr))
        << "and the valid count still runs";

    p.get().decim = DSP_DECIM_MAX;
    EXPECT_EQ(0, dsp_fir_srclength(n, DSP_DECIM_MAX, l)) << "the premise: this record is refused";
    EXPECT_EQ(DSP_EARG, dsp_spectrum_run(&p.get(), src.data(), (int)src.size(), nullptr))
        << "a configuration whose source record is past DSP_SRC_MAX";
    p.get().decim = decim;
}

TEST(Refusals, SourceLengthValidatesEveryArgument) {
    EXPECT_EQ(0, dsp_fir_srclength(1, 1, 0)) << "a count below two";
    EXPECT_EQ(0, dsp_fir_srclength(-4, 1, 0)) << "a negative count";
    EXPECT_EQ(0, dsp_fir_srclength(512, 0, 21)) << "a decimation below one";
    EXPECT_EQ(0, dsp_fir_srclength(512, 4, -1)) << "a negative tap count";
    EXPECT_EQ(0, dsp_fir_srclength(512, 4, DSP_FIR_MAXTAPS + 1)) << "a tap count past the ceiling";
    EXPECT_EQ(0, dsp_fir_srclength(32768, 100000, 101)) << "a product that overflows an int";
    EXPECT_EQ(0, dsp_fir_srclength(32768, DSP_DECIM_MAX, 101)) << "a product past DSP_SRC_MAX";
    EXPECT_EQ(512, dsp_fir_srclength(512, 1, 0)) << "no decimation is just n";
    EXPECT_EQ(512, dsp_fir_srclength(512, 1, DSP_FIR_MAXTAPS))
        << "which ignores the taps, though it still range-checks them";
    EXPECT_EQ((512 - 1) * 4 + 21, dsp_fir_srclength(512, 4, 21));
}

TEST(Refusals, TapsForRefusesACountItCannotMakeOdd) {

    const double fs = 1e6, fhi = 5000.0;
    const int decim = 4;
    double wtr = dsp_fir_transition(fs, 0.0, fhi, decim);
    ASSERT_NEAR(0.12, wtr, 1e-12) << "the premise: a 0.12 transition";
    ASSERT_EQ(28, (int)std::ceil(DSP_FIR_TAPK / wtr))
        << "which needs ceil(3.3/0.12) = 28 taps";
    EXPECT_EQ(0, dsp_fir_taps_for(fs, 0.0, fhi, decim, 28))
        << "28 is even, so the odd count is 29 and does not fit";
    EXPECT_EQ(29, dsp_fir_taps_for(fs, 0.0, fhi, decim, 29)) << "one more and it does";
    EXPECT_EQ(0, dsp_fir_taps_for(fs, 0.0, fhi, decim, 2)) << "a ceiling below three taps";
    EXPECT_EQ(0, dsp_fir_taps_for(1e6, 0.0, 125000.0 - 1e-9, 4, DSP_FIR_MAXTAPS))
        << "a stop just under the decimated Nyquist needs 3.3/1e-15 taps";
    EXPECT_EQ(0, dsp_fir_taps_for(1e6, 0.0, 500000.0, 4, DSP_FIR_MAXTAPS))
        << "a stop above the decimated Nyquist has no transition at all";
}

TEST(Refusals, PickDecimIsBoundedByTheDecimationCeiling) {

    int d = dsp_fir_pick_decim(1e9, 0.0, 1.0, 2, 3);
    EXPECT_LE(d, DSP_DECIM_MAX) << "a ratio of 1e9 must still clamp";
    EXPECT_GE(d, 1);

    EXPECT_EQ(1, dsp_fir_pick_decim(0.0, 0.0, 20000.0, 512, DSP_FIR_MAXTAPS)) << "no sample rate";
    EXPECT_EQ(1, dsp_fir_pick_decim(1e6, 0.0, 0.0, 512, DSP_FIR_MAXTAPS)) << "no stop frequency";
    EXPECT_EQ(1, dsp_fir_pick_decim(1e6, 0.0, 20000.0, 1, DSP_FIR_MAXTAPS)) << "a count below two";
    EXPECT_EQ(1, dsp_fir_pick_decim(1e6, 0.0, 20000.0, 512, 2)) << "a ceiling below three taps";
}

TEST(Refusals, PeaksClampsAWindowPastTheEnd) {
    const int m = 64;
    std::vector<dsp_real> pwr(m, (dsp_real)1e-12);
    pwr[30] = (dsp_real)1.0;
    int bins[4];
    for (int k1 : {m - 1, m, m + 1, m * 8, 2147483647}) {
        for (int i = 0; i < 4; i++)
            bins[i] = -2;
        int found = dsp_peaks(pwr.data(), m, 0, k1, 0, 4, nullptr, bins, nullptr, nullptr);
        ASSERT_GE(found, 1) << "k1=" << k1;
        EXPECT_EQ(30, bins[0]) << "k1=" << k1;
        for (int i = 0; i < 4; i++)
            ASSERT_LT(bins[i], m) << "k1=" << k1 << " peak " << i << " is outside the spectrum";
    }

    pwr[1] = (dsp_real)4.0;
    int found = dsp_peaks(pwr.data(), m, 0, m - 1, 3, 4, nullptr, bins, nullptr, nullptr);
    ASSERT_GE(found, 1);
    EXPECT_EQ(30, bins[0]) << "the bin at 1 is inside a three-bin DC region";

    EXPECT_EQ(0, dsp_peaks(pwr.data(), m, 0, 2, 8, 4, nullptr, bins, nullptr, nullptr));

    Plan p(256, DSP_WINDOW_HANN);
    ASSERT_EQ(DSP_OK, p.rc());
    const int kf = 1 + p->kdc;
    ASSERT_GE(kf, 2) << "the left neighbour has to be a real bin";
    std::vector<dsp_real> q((size_t)p->m, (dsp_real)0.0);
    q[kf - 1] = (dsp_real)-1.0;
    q[kf] = (dsp_real)1.0;
    q[kf + 1] = (dsp_real)0.25;
    double dd = 0.0;
    ASSERT_EQ(DSP_EDECLINE, dsp_peak_interp(&p->ip, q.data(), kf, p->m, &dd, nullptr))
        << "the premise: the interpolation must decline here";
    found = dsp_peaks(q.data(), p->m, 0, p->m - 1, p->kdc, 4, &p->ip, bins, nullptr, nullptr);
    ASSERT_GE(found, 1) << "a declined estimate must not lose the peak";
    EXPECT_EQ(kf, bins[0]) << "the offset falls back to zero, which keeps the bin";
}

TEST(Refusals, PeakInterpDeclinesOnEveryDocumentedCondition) {
    Plan p(256, DSP_WINDOW_HANN);
    ASSERT_EQ(DSP_OK, p.rc());
    std::vector<dsp_real> pwr(64, (dsp_real)1e-6);
    double d = 0.0, a = 0.0;
    EXPECT_EQ(DSP_EARG, dsp_peak_interp(nullptr, pwr.data(), 10, 64, &d, &a)) << "a null table";
    EXPECT_EQ(DSP_EARG, dsp_peak_interp(&p->ip, nullptr, 10, 64, &d, &a)) << "a null spectrum";
    EXPECT_EQ(DSP_EDECLINE, dsp_peak_interp(&p->ip, pwr.data(), 0, 64, &d, &a)) << "bin 0";
    EXPECT_EQ(DSP_EDECLINE, dsp_peak_interp(&p->ip, pwr.data(), 63, 64, &d, &a)) << "the last bin";
    EXPECT_EQ(DSP_EDECLINE, dsp_peak_interp(&p->ip, pwr.data(), -1, 64, &d, &a)) << "below zero";
    pwr[10] = (dsp_real)0.0;
    EXPECT_EQ(DSP_EDECLINE, dsp_peak_interp(&p->ip, pwr.data(), 10, 64, &d, &a)) << "a zero peak";
    pwr[10] = (dsp_real)-1.0;
    EXPECT_EQ(DSP_EDECLINE, dsp_peak_interp(&p->ip, pwr.data(), 10, 64, &d, &a))
        << "a negative peak";
    pwr[10] = (dsp_real)1.0;
    pwr[9] = (dsp_real)-1.0;
    EXPECT_EQ(DSP_EDECLINE, dsp_peak_interp(&p->ip, pwr.data(), 10, 64, &d, &a))
        << "a negative neighbour";

    d = 1234.0;
    a = 5678.0;
    EXPECT_EQ(DSP_EDECLINE, dsp_peak_interp(&p->ip, pwr.data(), 10, 64, &d, &a));
    EXPECT_DOUBLE_EQ(1234.0, d);
    EXPECT_DOUBLE_EQ(5678.0, a);
}

TEST(Refusals, WindowRefusesEveryBadArgument) {
    dsp_real w[65];
    EXPECT_EQ(DSP_EARG, dsp_window(nullptr, 64, DSP_WINDOW_HANN, 0.0));
    EXPECT_EQ(DSP_EARG, dsp_window(w, 1, DSP_WINDOW_HANN, 0.0)) << "a length below two";
    EXPECT_EQ(DSP_EARG, dsp_window(w, 0, DSP_WINDOW_HANN, 0.0));
    EXPECT_EQ(DSP_EARG, dsp_window(w, -8, DSP_WINDOW_HANN, 0.0));
    EXPECT_EQ(DSP_EARG, dsp_window(w, 64, -1, 0.0));
    EXPECT_EQ(DSP_EARG, dsp_window(w, 64, DSP_WINDOW_COUNT, 0.0));
    EXPECT_EQ(DSP_EBETA, dsp_window(w, 64, DSP_WINDOW_KAISER, DSP_KAISER_BETA_MIN - 0.001));
    EXPECT_EQ(DSP_EBETA, dsp_window(w, 64, DSP_WINDOW_KAISER, DSP_KAISER_BETA_MAX + 0.001));

    EXPECT_EQ(DSP_OK, dsp_window(w, 64, DSP_WINDOW_KAISER, DSP_KAISER_BETA_MIN));
    EXPECT_EQ(DSP_OK, dsp_window(w, 64, DSP_WINDOW_KAISER, DSP_KAISER_BETA_MAX));

    EXPECT_EQ(DSP_OK, dsp_window(w, 65, DSP_WINDOW_HANN, 0.0));
    EXPECT_EQ(DSP_OK, dsp_window(w, 2, DSP_WINDOW_HANN, 0.0));
}

TEST(Refusals, FirDesignAndRunRefuseEveryBadArgument) {
    dsp_real h[DSP_FIR_MAXTAPS];
    std::vector<double> x(1024, 0.5), y(1024);
    EXPECT_EQ(DSP_EARG, dsp_fir_design(nullptr, DSP_FIR_MAXTAPS, 1e6, 0.0, 2e4, 4, 0));
    EXPECT_EQ(DSP_EARG, dsp_fir_design(h, 2, 1e6, 0.0, 2e4, 4, 0)) << "a ceiling below three";
    EXPECT_EQ(DSP_EARG, dsp_fir_design(h, DSP_FIR_MAXTAPS, 0.0, 0.0, 2e4, 4, 0)) << "no rate";
    EXPECT_EQ(DSP_EARG, dsp_fir_design(h, DSP_FIR_MAXTAPS, -1e6, 0.0, 2e4, 4, 0))
        << "a negative rate";
    EXPECT_EQ(DSP_EARG, dsp_fir_design(h, DSP_FIR_MAXTAPS, 1e6, 0.0, 0.0, 4, 0)) << "no stop";
    EXPECT_EQ(DSP_EARG, dsp_fir_design(h, DSP_FIR_MAXTAPS, 1e6, 0.0, 2e4, 0, 0))
        << "a decimation below one";
    EXPECT_EQ(0, dsp_fir_design(h, DSP_FIR_MAXTAPS, 1e6, 0.0, 2e4, 1, 0))
        << "no decimation and no low cutoff means no filter is needed";
    EXPECT_EQ(DSP_EARG, dsp_fir_design(h, DSP_FIR_MAXTAPS, 1e6, 2e4, 2e4, 4, 0))
        << "an empty band";
    EXPECT_EQ(DSP_EARG, dsp_fir_design(h, 64, 1e6, 0.0, 2e4, 4, 65))
        << "an odd order past the ceiling";
    EXPECT_EQ(3, dsp_fir_design(h, DSP_FIR_MAXTAPS, 1e6, 0.0, 2e4, 4, 1))
        << "an order of one is raised to the three-tap floor";

    EXPECT_EQ(DSP_EARG, dsp_fir_run(nullptr, 1024, h, 21, 4, y.data()));
    EXPECT_EQ(DSP_EARG, dsp_fir_run(x.data(), 1024, nullptr, 21, 4, y.data()));
    EXPECT_EQ(DSP_EARG, dsp_fir_run(x.data(), 1024, h, 21, 4, nullptr));
    EXPECT_EQ(DSP_EARG, dsp_fir_run(x.data(), 1024, h, 0, 4, y.data())) << "no taps";
    EXPECT_EQ(DSP_EARG, dsp_fir_run(x.data(), 1024, h, -1, 4, y.data())) << "a negative count";
    EXPECT_EQ(DSP_EARG, dsp_fir_run(x.data(), 1024, h, 21, 0, y.data())) << "decim below one";
    EXPECT_EQ(DSP_EARG, dsp_fir_run(x.data(), 20, h, 21, 1, y.data())) << "fewer samples than taps";
    EXPECT_EQ(1, dsp_fir_run(x.data(), 21, h, 21, 1, y.data()))
        << "exactly as many samples as taps gives one output";
}

TEST(Refusals, LoadRefusesEveryBadArgument) {
    Plan p(64, DSP_WINDOW_HANN);
    ASSERT_EQ(DSP_OK, p.rc());
    std::vector<double> x(64, 1.0);
    EXPECT_EQ(DSP_EARG, dsp_load(nullptr, 64, p->w, p->wsum, p->re, p->im, nullptr));
    EXPECT_EQ(DSP_EARG, dsp_load(x.data(), 64, nullptr, p->wsum, p->re, p->im, nullptr));
    EXPECT_EQ(DSP_EARG, dsp_load(x.data(), 64, p->w, p->wsum, nullptr, p->im, nullptr));
    EXPECT_EQ(DSP_EARG, dsp_load(x.data(), 64, p->w, p->wsum, p->re, nullptr, nullptr));
    EXPECT_EQ(DSP_EPOW2, dsp_load(x.data(), 2, p->w, p->wsum, p->re, p->im, nullptr))
        << "below the four-sample floor";
    EXPECT_EQ(DSP_EPOW2, dsp_load(x.data(), DSP_N_MAX * 2, p->w, p->wsum, p->re, p->im, nullptr))
        << "past DSP_N_MAX";
    EXPECT_EQ(DSP_EARG, dsp_load(x.data(), 64, p->w, -1.0, p->re, p->im, nullptr))
        << "a negative window sum is an argument error, not a count error";
}

TEST(Refusals, RfftIgnoresAPlanItCannotRun) {

    dsp_plan empty{};
    dsp_rfft(nullptr);
    dsp_rfft(&empty);

    Plan tiny(4, DSP_WINDOW_HANN);
    ASSERT_EQ(DSP_OK, tiny.rc());
    EXPECT_EQ(2, tiny->m);
    std::vector<double> x = {1.0, 2.0, 3.0, 4.0};
    EXPECT_EQ(2, dsp_spectrum_run(&tiny.get(), x.data(), 4, nullptr));
}

TEST(Refusals, TheAbiGuardAgreesWithTheHeader) {
    EXPECT_EQ((int)sizeof(dsp_real), dsp_real_size)
        << "a header compiled without DSP_DOUBLE against a library built with it links cleanly "
           "and misreads every stride, so this is the only thing that catches it";
    EXPECT_TRUE(dsp_real_size == 4 || dsp_real_size == 8);
    EXPECT_EQ(kSingle ? 4 : 8, dsp_real_size);
}

#if DSP_BANDPASS

double FirResponseDb(const dsp_real *h, int ntaps, double f_over_fs) {
    double re = 0.0, im = 0.0;
    for (int i = 0; i < ntaps; i++) {
        double ang = -2.0 * M_PI * f_over_fs * (double)i;
        re += (double)h[i] * std::cos(ang);
        im += (double)h[i] * std::sin(ang);
    }
    double mag = std::sqrt(re * re + im * im);
    return 20.0 * std::log10(mag > 1e-300 ? mag : 1e-300);
}

TEST(BandPass, UnitGainIsTakenAtThePassbandCentreNotAtDc) {

    const double fs = 1e6, flo = 200000.0, fhi = 240000.0;
    dsp_real h[DSP_FIR_MAXTAPS];
    int l = dsp_fir_design(h, DSP_FIR_MAXTAPS, fs, flo, fhi, 1, 201);
    ASSERT_GT(l, 0);

    double sum = 0.0;
    for (int i = 0; i < l; i++)
        sum += (double)h[i];
    const double centre = 0.5 * (flo + fhi);
    double at_centre = std::pow(10.0, FirResponseDb(h, l, centre / fs) / 20.0);
    std::printf("[   bp ] %d taps, %.0f-%.0f Hz: sum(h) = %.3e, gain at centre = %.6f, "
                "DC = %.1f dB\n",
                l, flo, fhi, sum, at_centre, FirResponseDb(h, l, 0.0));

    EXPECT_NEAR(at_centre, 1.0, 0.02) << "the passband centre must have unit gain";

    EXPECT_LT(std::fabs(sum), 0.05)
        << "sum(h) is " << sum << ", so a DC normalisation divides by nearly nothing";
    EXPECT_LT(FirResponseDb(h, l, 0.0), -40.0) << "DC must be in the stopband";
}

TEST(BandPass, TheDcGainCrossesZeroWhichIsWhyItCannotBeTheDivisor) {

    const double fs = 1e6;
    int sign_changes = 0;
    double prev = 0.0;
    double worst_centre_err = 0.0;
    for (double flo = 20000.0; flo <= 400000.0; flo += 10000.0) {
        const double fhi = flo + 40000.0;
        dsp_real h[DSP_FIR_MAXTAPS];
        int l = dsp_fir_design(h, DSP_FIR_MAXTAPS, fs, flo, fhi, 1, 201);
        ASSERT_GT(l, 0) << "flo " << flo;
        double sum = 0.0;
        for (int i = 0; i < l; i++)
            sum += (double)h[i];
        if (prev != 0.0 && ((prev < 0.0) != (sum < 0.0)))
            sign_changes++;
        prev = sum;
        double g = std::pow(10.0, FirResponseDb(h, l, 0.5 * (flo + fhi) / fs) / 20.0);
        worst_centre_err = std::max(worst_centre_err, std::fabs(g - 1.0));
    }
    std::printf("[   bp ] sweeping the band: sum(h) changed sign %d times; worst centre-gain "
                "error %.4f\n",
                sign_changes, worst_centre_err);
    EXPECT_GT(sign_changes, 0) << "if sum(h) never changed sign, this test proves nothing about "
                                  "why a DC normalisation is unusable";
    EXPECT_LT(worst_centre_err, 0.02) << "the centre normalisation must hold across the sweep";
}

TEST(BandPass, FlatInsideTheBandAndDownOnBothSides) {

    const double fs = 1e6, flo = 150000.0, fhi = 200000.0;
    dsp_real h[DSP_FIR_MAXTAPS];
    int l = dsp_fir_design(h, DSP_FIR_MAXTAPS, fs, flo, fhi, 1, 301);
    ASSERT_GT(l, 0);
    double worst_ripple = 0.0;
    for (double f = flo; f <= fhi; f += 1000.0)
        worst_ripple = std::max(worst_ripple, std::fabs(FirResponseDb(h, l, f / fs)));

    const double tw = DSP_FIR_TAPK / (double)l * fs;
    double lo_stop = FirResponseDb(h, l, (flo - 1.5 * tw) / fs);
    double hi_stop = FirResponseDb(h, l, (fhi + 1.5 * tw) / fs);
    std::printf("[   bp ] %d taps, %.0f-%.0f Hz: ripple %.2f dB, lower stop %.1f dB, upper "
                "stop %.1f dB\n",
                l, flo, fhi, worst_ripple, lo_stop, hi_stop);
    EXPECT_LT(worst_ripple, 1.0) << "the passband must be flat to a dB";
    EXPECT_LT(lo_stop, -30.0) << "the lower stopband is the one a low-pass never has";
    EXPECT_LT(hi_stop, -30.0) << "and the upper one must still be there";
}

TEST(BandPass, ARealToneInTheBandSurvivesAndOneOutsideDoesNot) {

    const double fs = 1e6, flo = 150000.0, fhi = 200000.0;
    const int ntaps = 301, nout = 512;
    dsp_real h[DSP_FIR_MAXTAPS];
    ASSERT_EQ(ntaps, dsp_fir_design(h, DSP_FIR_MAXTAPS, fs, flo, fhi, 1, ntaps));
    const int nx = nout + ntaps - 1;
    std::vector<double> x(nx), y(nout);
    struct Case {
        double hz;
        bool pass;
        const char *what;
    };
    const Case cases[] = {{175000.0, true, "mid-band"},
                          {155000.0, true, "just inside the lower edge"},
                          {195000.0, true, "just inside the upper edge"},
                          {50000.0, false, "well below"},
                          {5000.0, false, "near DC"},
                          {400000.0, false, "well above"}};
    for (const Case &c : cases) {
        for (int i = 0; i < nx; i++)
            x[i] = std::cos(2.0 * M_PI * c.hz * (double)i / fs + 0.2);
        ASSERT_EQ(nout, dsp_fir_run(x.data(), nx, h, ntaps, 1, y.data()));
        double peak = 0.0;
        for (int j = 0; j < nout; j++)
            peak = std::max(peak, std::fabs(y[j]));
        double db = 20.0 * std::log10(peak > 1e-300 ? peak : 1e-300);
        std::printf("[   bp ] %-28s %7.0f Hz -> %6.1f dB\n", c.what, c.hz, db);
        if (c.pass)
            EXPECT_GT(db, -1.5) << c.what << " must pass";
        else
            EXPECT_LT(db, -30.0) << c.what << " must be rejected";
    }
}

TEST(BandPass, ADecimatedBandLandsWhereTheMapSays) {

    const double fs = 1e6;
    const int n = 4096;
    struct Case {
        double flo, fhi;
        int decim;
        int want_zone, want_sense;
    };

    const Case cases[] = {{380000.0, 400000.0, 2, 1, -1}, {30000.0, 50000.0, 4, 0, 1}};
    for (const Case &c : cases) {
        dsp_bandmap map{};
        ASSERT_EQ(DSP_OK, dsp_band_map(fs, c.flo, c.fhi, n, c.decim, &map))
            << c.flo << "-" << c.fhi << " /" << c.decim;
        EXPECT_EQ(c.want_zone, map.zone);
        EXPECT_EQ(c.want_sense, map.sense);
        EXPECT_DOUBLE_EQ(fs / c.decim / n, map.binhz);

        EXPECT_DOUBLE_EQ(dsp_binwidth(fs, n, 1) / c.decim, map.binhz);

        dsp_real h[DSP_FIR_MAXTAPS];
        int l = dsp_fir_design(h, DSP_FIR_MAXTAPS, fs, c.flo, c.fhi, c.decim, 0);
        ASSERT_GT(l, 0) << "no filter for " << c.flo << "-" << c.fhi << " /" << c.decim;

        Plan p(n, DSP_WINDOW_HANN, 0, c.decim);
        ASSERT_EQ(DSP_OK, p.rc());
        ASSERT_EQ(l, dsp_plan_set_fir(&p.get(), h, l));
        const int need = dsp_fir_srclength(n, c.decim, l);
        ASSERT_GT(need, 0);

        for (double tone : {c.flo + 0.25 * (c.fhi - c.flo), 0.5 * (c.flo + c.fhi),
                            c.flo + 0.75 * (c.fhi - c.flo)}) {
            std::vector<double> src(need);
            for (int i = 0; i < need; i++)
                src[i] = std::cos(2.0 * M_PI * tone * (double)i / fs + 0.3);
            ASSERT_EQ(p->m, dsp_spectrum_run(&p.get(), src.data(), need, nullptr));
            int best = ArgMaxBin(p.get(), 1);
            double got = dsp_bin_hz(&map, best);
            std::printf("[   bp ] zone %d sense %+d: %.0f Hz -> bin %d -> %.0f Hz (%.2f Hz "
                        "bins)\n",
                        map.zone, map.sense, tone, best, got, map.binhz);
            EXPECT_NEAR(got, tone, 2.0 * map.binhz)
                << "zone " << map.zone << ", tone " << tone << " landed at bin " << best;
        }
    }
}

TEST(BandPass, AnOddZoneIsReversedAndTheReductionStillAscends) {

    const double fs = 1e6;
    const int n = 2048, nseg = 64;
    dsp_bandmap map{};
    ASSERT_EQ(DSP_OK, dsp_band_map(fs, 380000.0, 400000.0, n, 2, &map));
    ASSERT_EQ(-1, map.sense) << "the premise: zone 1 is reversed";

    EXPECT_GT(dsp_bin_hz(&map, 0), dsp_bin_hz(&map, n / 2 - 1));

    std::vector<dsp_real> pwr((size_t)(n / 2), (dsp_real)1e-12);

    const int lo_bin = n / 2 - 5;  // lowest frequency, because the map is reversed
    const int hi_bin = 5;          // highest frequency
    pwr[lo_bin] = (dsp_real)1.0;
    pwr[hi_bin] = (dsp_real)0.25;
    std::vector<dsp_real> db(nseg), hz(nseg);
    ASSERT_EQ(nseg, dsp_reduce(pwr.data(), n / 2, 0, n / 2 - 1, nseg, &map, -120.0, 20.0, 1e-9,
                               db.data(), hz.data()));
    for (int c = 1; c < nseg; c++)
        ASSERT_GT((double)hz[c], (double)hz[c - 1]) << "the trace must ascend at segment " << c;

    int at_strong = 0, at_weak = 0;
    for (int c = 0; c < nseg; c++) {
        if (db[c] > db[at_strong])
            at_strong = c;
        if ((double)db[c] > -10.0 && c > at_weak)
            at_weak = c;
    }
    EXPECT_LT(at_strong, nseg / 2) << "the lowest-frequency marker belongs in an early segment";
    EXPECT_GT(at_weak, nseg / 2) << "and the highest-frequency one in a late segment";

    EXPECT_NEAR((double)hz[0], dsp_bin_hz(&map, n / 2 - 1), 0.5 * map.binhz);
    EXPECT_LT((double)hz[nseg - 1], dsp_bin_hz(&map, 0));
}

TEST(BandPass, AReversedReductionCoversTheSameBinsAsAForwardOne) {

    const int m = 256, nseg = 17; // deliberately not a divisor of m
    std::vector<dsp_real> pwr((size_t)m);
    for (int k = 0; k < m; k++)
        pwr[k] = (dsp_real)(1e-9 + (double)k);
    dsp_bandmap up{}, down{};
    up.f0 = 0.0;
    up.binhz = 10.0;
    up.sense = 1;
    down.f0 = (double)(m - 1) * 10.0;
    down.binhz = 10.0;
    down.sense = -1;
    std::vector<dsp_real> dbu(nseg), hzu(nseg), dbd(nseg), hzd(nseg);
    ASSERT_EQ(nseg, dsp_reduce(pwr.data(), m, 0, m - 1, nseg, &up, -400.0, 400.0, 0.0,
                               dbu.data(), hzu.data()));
    ASSERT_EQ(nseg, dsp_reduce(pwr.data(), m, 0, m - 1, nseg, &down, -400.0, 400.0, 0.0,
                               dbd.data(), hzd.data()));

    for (int c = 1; c < nseg; c++) {
        ASSERT_GE((double)dbu[c], (double)dbu[c - 1]) << "ascending segment " << c;
        ASSERT_LE((double)dbd[c], (double)dbd[c - 1]) << "descending segment " << c;
        ASSERT_GT((double)hzu[c], (double)hzu[c - 1]);
        ASSERT_GT((double)hzd[c], (double)hzd[c - 1]) << "both traces ascend in frequency";
    }

    std::vector<int> seen((size_t)m, 0);
    int qstep = m / nseg, rstep = m % nseg, q0 = 0, q1 = qstep, r1 = rstep;
    for (int c = 0; c < nseg; c++) {
        int oa = q0, ob = q1 - 1;
        if (ob < oa)
            ob = oa;
        if (ob > m - 1)
            ob = m - 1;
        for (int o = oa; o <= ob; o++)
            seen[(size_t)(m - 1 - o)]++;
        q0 = q1;
        q1 += qstep;
        r1 += rstep;
        if (r1 >= nseg) {
            r1 -= nseg;
            q1++;
        }
    }
    for (int k = 0; k < m; k++)
        ASSERT_EQ(1, seen[(size_t)k]) << "bin " << k << " covered " << seen[(size_t)k] << " times";
}

TEST(BandPass, ABandThatStraddlesAZoneIsRefusedNotFiltered) {

    const double fs = 1e6;

    dsp_bandmap map{};
    EXPECT_EQ(DSP_EZONE, dsp_band_map(fs, 100000.0, 150000.0, 1024, 4, &map));
    EXPECT_EQ(0, map.zone) << "a refused map must be left zeroed";
    EXPECT_EQ(0, map.sense);
    dsp_real h[DSP_FIR_MAXTAPS];
    EXPECT_EQ(DSP_EZONE, dsp_fir_design(h, DSP_FIR_MAXTAPS, fs, 100000.0, 150000.0, 4, 101));
    EXPECT_EQ(0.0, dsp_fir_transition(fs, 100000.0, 150000.0, 4));
    EXPECT_EQ(0, dsp_fir_taps_for(fs, 100000.0, 150000.0, 4, DSP_FIR_MAXTAPS));

    EXPECT_EQ(DSP_OK, dsp_band_map(fs, 100000.0, 150000.0, 1024, 2, &map));
    EXPECT_EQ(0, map.zone);
    EXPECT_EQ(1, map.sense);

    EXPECT_EQ(DSP_OK, dsp_band_map(fs, 100000.0, 125000.0, 1024, 4, &map));
    EXPECT_EQ(0, map.zone);
    EXPECT_EQ(1, map.sense);
    EXPECT_EQ(0.0, dsp_fir_transition(fs, 100000.0, 125000.0, 4));
    EXPECT_EQ(0, dsp_fir_taps_for(fs, 100000.0, 125000.0, 4, DSP_FIR_MAXTAPS));

    EXPECT_EQ(DSP_OK, dsp_band_map(200000.0, 0.0, 100000.0, 512, 1, &map));
    EXPECT_EQ(0, map.zone);
    EXPECT_EQ(1, map.sense);
    EXPECT_DOUBLE_EQ(0.0, map.f0);
    EXPECT_DOUBLE_EQ(dsp_binwidth(200000.0, 512, 1), map.binhz);

    for (int d = 1; d <= 16; d++) {
        dsp_bandmap full{};
        const double nyq = 1e6 / (2.0 * (double)d);
        EXPECT_EQ(DSP_OK, dsp_band_map(1e6, 0.0, nyq, 1024, d, &full))
            << "/" << d << ": a span reaching its own decimated Nyquist must map";
        EXPECT_EQ(0, full.zone) << "/" << d;
        EXPECT_EQ(1, full.sense) << "/" << d;
    }

    EXPECT_EQ(DSP_EZONE, dsp_band_map(fs, 100000.0, 125001.0, 1024, 4, &map));
}

TEST(BandPass, PickDecimSkipsTheStraddlingDecimations) {

    const double fs = 1e6;
    int taken = 0, straddled = 0;
    for (double flo = 10000.0; flo <= 400000.0; flo += 10000.0) {
        for (double width : {5000.0, 20000.0, 50000.0}) {
            const double fhi = flo + width;
            if (fhi > 0.5 * fs)
                continue;
            int d = dsp_fir_pick_decim(fs, flo, fhi, 512, DSP_FIR_MAXTAPS);
            ASSERT_GE(d, 1);
            if (d > 1) {
                dsp_bandmap map{};
                ASSERT_EQ(DSP_OK, dsp_band_map(fs, flo, fhi, 512, d, &map))
                    << flo << "-" << fhi << " chose /" << d << ", which straddles a zone";
                ASSERT_GT(dsp_fir_taps_for(fs, flo, fhi, d, DSP_FIR_MAXTAPS), 0)
                    << flo << "-" << fhi << " chose /" << d << ", whose filter does not fit";
                ASSERT_LE(dsp_fir_srclength(512, d, dsp_fir_taps_for(fs, flo, fhi, d,
                                                                     DSP_FIR_MAXTAPS)),
                          DSP_FIR_MAXM)
                    << flo << "-" << fhi << " chose /" << d << ", which blows the read budget";
                taken++;
            }

            for (int probe = 2; probe <= 16; probe++) {
                dsp_bandmap m2{};
                if (dsp_band_map(fs, flo, fhi, 512, probe, &m2) == DSP_EZONE) {
                    straddled++;
                    break;
                }
            }
        }
    }
    std::printf("[   bp ] pick_decim: %d bands decimated, %d had a straddling candidate\n",
                taken, straddled);
    EXPECT_GT(taken, 10) << "the sweep must actually decimate something";
    EXPECT_GT(straddled, 5) << "if nothing straddles, the skip is never exercised";
}

TEST(BandPass, TapsComeFromTheNarrowerOfTheTwoTransitions) {

    const double fs = 1e6;
    const int decim = 2; // 250 kHz zones
    // Zone 1 runs 250-500 kHz. This band sits 25 kHz above its lower edge and 150 kHz below
    // the upper one, so the lower transition decides and the tap ceiling can still meet it.
    const double flo = 275000.0, fhi = 350000.0;
    dsp_bandmap map{};
    ASSERT_EQ(DSP_OK, dsp_band_map(fs, flo, fhi, 1024, decim, &map));
    ASSERT_EQ(1, map.zone);
    double wtr = dsp_fir_transition(fs, flo, fhi, decim);
    EXPECT_NEAR(wtr, 25000.0 / fs, 1e-12) << "the lower guard is the narrow one";

    double upper_only = (500000.0 - fhi) / fs;
    EXPECT_GT(upper_only, 5.0 * wtr) << "the upper guard is much wider, so using it alone "
                                        "would ask for far too few taps";
    int l = dsp_fir_taps_for(fs, flo, fhi, decim, DSP_FIR_MAXTAPS);
    ASSERT_GT(l, 0);
    int want = (int)std::ceil(DSP_FIR_TAPK / wtr);
    if ((want % 2) == 0)
        want++;
    EXPECT_EQ(want, l) << "the count follows the narrow guard";

    dsp_real h[DSP_FIR_MAXTAPS];
    ASSERT_EQ(l, dsp_fir_design(h, DSP_FIR_MAXTAPS, fs, flo, fhi, decim, 0));
    double at_edge = FirResponseDb(h, l, 250000.0 / fs);
    std::printf("[   bp ] zone-1 band %.0f-%.0f /%d: %d taps, zone edge %.1f dB\n", flo, fhi,
                decim, l, at_edge);
    EXPECT_LT(at_edge, -20.0) << "the zone edge must be in the stopband or the band folds";
}

TEST(BandPass, ZoneZeroHasNoLowerAliasingTransition) {

    const double fs = 1e6;
    EXPECT_DOUBLE_EQ(dsp_fir_transition(fs, 0.0, 20000.0, 4),
                     dsp_fir_transition(fs, 2000.0, 20000.0, 4))
        << "in zone 0 the lower edge does not change the transition";

    EXPECT_NEAR(dsp_fir_transition(fs, 0.0, 20000.0, 4), 1.0 / 8.0 - 0.02, 1e-15);

    dsp_real h[DSP_FIR_MAXTAPS];
    int l = dsp_fir_design(h, DSP_FIR_MAXTAPS, fs, 50000.0, 100000.0, 4, 0);
    ASSERT_GT(l, 0);
    double dc = FirResponseDb(h, l, 0.0);
    double mid = FirResponseDb(h, l, 75000.0 / fs);
    std::printf("[   bp ] zone-0 band 50k-100k /4: %d taps, DC %.1f dB, mid-band %.2f dB\n", l,
                dc, mid);
    EXPECT_NEAR(mid, 0.0, 1.0) << "the passband is flat";
    EXPECT_LT(dc, -40.0) << "and DC is rejected";

    int lnear = dsp_fir_design(h, DSP_FIR_MAXTAPS, fs, 2000.0, 20000.0, 4, 0);
    ASSERT_GT(lnear, 0);
    double dc_near = FirResponseDb(h, lnear, 0.0);
    std::printf("[   bp ] zone-0 band 2k-20k /4: %d taps, DC %.2f dB -- the lower skirt needs "
                "~%.0f taps\n",
                lnear, dc_near, DSP_FIR_TAPK / (2000.0 / fs));
    EXPECT_GT(dc_near, -3.0) << "with a derived count a band this close to DC is a low-pass; "
                                "an explicit order is the only way to buy the skirt";
    EXPECT_GT(DSP_FIR_TAPK / (2000.0 / fs), (double)DSP_FIR_MAXTAPS)
        << "and the taps it would need are past the ceiling, which is why";
}

TEST(BandPass, TheResolutionClaimTheProposalMakes) {

    dsp_bandmap map{};
    ASSERT_EQ(DSP_OK, dsp_band_map(1e6, 30000.0, 90000.0, 32768, 4, &map));
    EXPECT_NEAR(map.binhz, 7.63, 0.01);
    EXPECT_NEAR(dsp_binwidth(1e6, 32768, 1), 30.52, 0.01);
    EXPECT_EQ(0, map.zone);
    EXPECT_EQ(1, map.sense);
}

TEST(BandPass, TheMapRefusesEveryBadArgument) {
    dsp_bandmap m{};
    EXPECT_EQ(DSP_EARG, dsp_band_map(1e6, 0.0, 2e4, 1024, 4, nullptr)) << "a null output";
    EXPECT_EQ(DSP_EARG, dsp_band_map(1e6, 0.0, 2e4, 0, 4, &m)) << "a sample count below one";
    EXPECT_EQ(DSP_EARG, dsp_band_map(1e6, 0.0, 2e4, -8, 4, &m)) << "a negative count";
    EXPECT_EQ(DSP_EARG, dsp_band_map(1e6, 0.0, 2e4, 1024, 0, &m)) << "a decimation below one";
    EXPECT_EQ(DSP_EARG, dsp_band_map(1e6, 0.0, 2e4, 1024, DSP_DECIM_MAX + 1, &m))
        << "a decimation past the ceiling";
    EXPECT_EQ(DSP_EARG, dsp_band_map(0.0, 0.0, 2e4, 1024, 4, &m)) << "no sample rate";
    EXPECT_EQ(DSP_EARG, dsp_band_map(-1e6, 0.0, 2e4, 1024, 4, &m)) << "a negative rate";
    EXPECT_EQ(DSP_EARG, dsp_band_map(kNaN, 0.0, 2e4, 1024, 4, &m)) << "a NaN rate";
    EXPECT_EQ(DSP_EARG, dsp_band_map(kInf, 0.0, 2e4, 1024, 4, &m)) << "an infinite rate";
    EXPECT_EQ(DSP_EARG, dsp_band_map(1e6, kNaN, 2e4, 1024, 4, &m)) << "a NaN band start";
    EXPECT_EQ(DSP_EARG, dsp_band_map(1e6, 0.0, kNaN, 1024, 4, &m)) << "a NaN band end";
    EXPECT_EQ(DSP_EARG, dsp_band_map(1e6, -1.0, 2e4, 1024, 4, &m)) << "a negative band start";
    EXPECT_EQ(DSP_EARG, dsp_band_map(1e6, 2e4, 2e4, 1024, 4, &m)) << "an empty band";
    EXPECT_EQ(DSP_EARG, dsp_band_map(1e6, 3e4, 2e4, 1024, 4, &m)) << "an inverted band";
    EXPECT_EQ(DSP_EARG, dsp_band_map(1e6, 0.0, 6e5, 1024, 4, &m)) << "a band past Nyquist";

    EXPECT_EQ(DSP_EARG, dsp_band_map(1e-316, 0.0, 5e-317, 65536, 4096, &m))
        << "a bin width that underflows";
    EXPECT_DOUBLE_EQ(0.0, dsp_binwidth(1e-316, 65536, 4096)) << "the premise";

    if (kSingle) {
        EXPECT_EQ(DSP_EARG, dsp_band_map(1e42, 3e41, 4e41, 65536, 2, &m))
            << "a zone offset past FLT_MAX";
        EXPECT_GT(dsp_binwidth(1e42, 65536, 2), 0.0) << "while the bin width itself is storable";
    }

    EXPECT_EQ(0.0, m.f0);
    EXPECT_EQ(0.0, m.binhz);
    EXPECT_EQ(0, m.sense);
    EXPECT_EQ(0, m.zone);

    ASSERT_EQ(DSP_OK, dsp_band_map(1e6, 0.0, 2e4, 1024, 4, &m));
    EXPECT_EQ(0, m.zone);
    EXPECT_EQ(1, m.sense);
    EXPECT_DOUBLE_EQ(0.0, dsp_bin_hz(&m, 0));
    EXPECT_DOUBLE_EQ(m.binhz, dsp_bin_hz(&m, 1));
    EXPECT_DOUBLE_EQ(0.0, dsp_bin_hz(nullptr, 5)) << "a null map has no frequency";
}

TEST(BandPass, ReduceRefusesAMapItCannotPlotAgainst) {
    const int m = 64, nseg = 8;
    std::vector<dsp_real> pwr((size_t)m, (dsp_real)1e-12), db(nseg), hz(nseg);
    dsp_bandmap ok = FlatMap(100.0);
    EXPECT_EQ(nseg, dsp_reduce(pwr.data(), m, 0, m - 1, nseg, &ok, -120.0, 20.0, 1e-9,
                               db.data(), hz.data()));
    EXPECT_EQ(DSP_EARG, dsp_reduce(pwr.data(), m, 0, m - 1, nseg, nullptr, -120.0, 20.0, 1e-9,
                                   db.data(), hz.data()))
        << "a null map";

    for (int bad : {0, 2, -2, 99}) {
        dsp_bandmap m2 = ok;
        m2.sense = bad;
        EXPECT_EQ(DSP_EARG, dsp_reduce(pwr.data(), m, 0, m - 1, nseg, &m2, -120.0, 20.0, 1e-9,
                                       db.data(), hz.data()))
            << "sense " << bad;
    }

    for (double bad : {kNaN, kInf, -kInf}) {
        dsp_bandmap m2 = ok;
        m2.f0 = bad;
        EXPECT_EQ(DSP_EARG, dsp_reduce(pwr.data(), m, 0, m - 1, nseg, &m2, -120.0, 20.0, 1e-9,
                                       db.data(), hz.data()));
    }

    EXPECT_EQ(DSP_EARG, dsp_reduce(pwr.data(), m, 0, m - 1, DSP_NSEG_MAX + 1, &ok, -120.0, 20.0,
                                   1e-9, db.data(), hz.data()))
        << "past DSP_NSEG_MAX";
}

#endif /* DSP_BANDPASS */

TEST(ThdNoise, TheFiguresAreTheRatioAndTheMeanPutIn) {
    std::vector<dsp_real> pwr(256, (dsp_real)1e-10);
    pwr[60] = (dsp_real)1.0;
    pwr[120] = (dsp_real)0.0025;
    dsp_thdn r{};
    ASSERT_EQ(DSP_OK, dsp_thd_noise(pwr.data(), 256, 1, 130, 0, 0.0, DSP_THD_MAINS_BOTH, nullptr, &r));
    EXPECT_EQ(1, r.nharm);
    EXPECT_EQ(116, r.nnoise);
    EXPECT_NEAR(0.05, r.thd, 1e-4) << "thd is a fraction, not a percentage";
    EXPECT_NEAR(-100.0, r.noise_db, 0.01);
    EXPECT_NEAR(79.355, r.snr_db, 0.05);
    EXPECT_NEAR(60.0, r.f0, 1e-6);
    EXPECT_NEAR(1.0, r.amp0, 1e-5);
}

TEST(ThdNoise, TheThreeFiguresSatisfyTheirIdentity) {
    std::vector<dsp_real> pwr(512, (dsp_real)4e-9);
    pwr[80] = (dsp_real)2.25;   // 1.5 V
    pwr[160] = (dsp_real)0.01;  // 0.1 V
    pwr[240] = (dsp_real)0.0004;
    dsp_thdn r{};
    ASSERT_EQ(DSP_OK, dsp_thd_noise(pwr.data(), 512, 1, 400, 0, 0.0, DSP_THD_MAINS_BOTH, nullptr, &r));
    ASSERT_GT(r.nnoise, 0);
    const double lhs = 20.0 * std::log10(r.amp0) - r.snr_db - r.noise_db;
    EXPECT_NEAR(10.0 * std::log10((double)r.nnoise), lhs, 0.02)
        << "nnoise=" << r.nnoise << " amp0=" << r.amp0 << " snr=" << r.snr_db
        << " floor=" << r.noise_db;
}

TEST(ThdNoise, TheLinesAndTheirSkirtsStayOutOfTheMean) {
    std::vector<dsp_real> flat(256, (dsp_real)1e-10);
    dsp_thdn bare{};
    ASSERT_EQ(DSP_OK, dsp_thd_noise(flat.data(), 256, 1, 130, 0, 0.0, DSP_THD_MAINS_BOTH, nullptr, &bare));
    std::vector<dsp_real> loud = flat;
    loud[60] = (dsp_real)1.0;
    dsp_thdn with{};
    ASSERT_EQ(DSP_OK, dsp_thd_noise(loud.data(), 256, 1, 130, 0, 0.0, DSP_THD_MAINS_BOTH, nullptr, &with));
    EXPECT_NEAR(-100.0, bare.noise_db, 0.01);
    EXPECT_NEAR(-100.0, with.noise_db, 0.05) << "a 1 V line reached the noise mean";
}

TEST(ThdNoise, NoHarmonicInTheWindowLeavesNharmZero) {
    std::vector<dsp_real> pwr(256, (dsp_real)1e-10);
    pwr[100] = (dsp_real)1.0;
    dsp_thdn r{};
    ASSERT_EQ(DSP_OK, dsp_thd_noise(pwr.data(), 256, 1, 130, 0, 0.0, DSP_THD_MAINS_BOTH, nullptr, &r));
    EXPECT_EQ(0, r.nharm);
    EXPECT_EQ(0.0, r.thd);
    EXPECT_GT(r.nnoise, 0) << "the noise figures stand on their own";
}

TEST(ThdNoise, TheDcRegionCannotBecomeTheFundamental) {
    std::vector<dsp_real> pwr(256, (dsp_real)1e-10);
    pwr[0] = (dsp_real)1e6;
    pwr[2] = (dsp_real)1e6;
    pwr[60] = (dsp_real)1.0;
    dsp_thdn r{};
    ASSERT_EQ(DSP_OK, dsp_thd_noise(pwr.data(), 256, 0, 130, 3, 0.0, DSP_THD_MAINS_BOTH, nullptr, &r));
    EXPECT_NEAR(60.0, r.f0, 1e-6) << "the DC region won the fundamental";
}

TEST(ThdNoise, AMeasuredSpectrumGivesTheSynthesisedDistortion) {
    for (const WinCfg &c : ShippedWindows()) {
        Plan p(1024, c.kind, c.beta);
        ASSERT_EQ(DSP_OK, p.rc()) << c.label();
        std::vector<double> x(1024);
        for (int i = 0; i < 1024; i++)
            x[i] = std::cos(2.0 * M_PI * 100.0 * i / 1024.0) +
                   0.05 * std::cos(2.0 * M_PI * 200.0 * i / 1024.0 + 0.7);
        ASSERT_EQ(p->m, RunSpectrum(p, x)) << c.label();
        dsp_thdn r{};
        ASSERT_EQ(DSP_OK, dsp_thd_noise(p->pwr, p->m, 1, p->m - 1, p->kdc, 0.0, DSP_THD_MAINS_BOTH, &p->ip, &r))
            << c.label();
        EXPECT_GE(r.nharm, 1) << c.label();
        EXPECT_NEAR(0.05, r.thd, 0.004) << c.label() << " thd=" << r.thd;
        EXPECT_NEAR(1.0, r.amp0, 0.01) << c.label();
        EXPECT_NEAR(100.0, r.f0, 0.05) << c.label();

        EXPECT_GT(r.snr_db, 30.0) << c.label() << " snr=" << r.snr_db;
        EXPECT_NE(0, r.signal) << c.label() << " a 1 V tone is a signal";
    }
}

TEST(ThdNoise, NullInterpolationFallsBackToTheBinRoot) {
    std::vector<dsp_real> pwr(256, (dsp_real)1e-10);
    pwr[60] = (dsp_real)0.25;
    dsp_thdn r{};
    ASSERT_EQ(DSP_OK, dsp_thd_noise(pwr.data(), 256, 1, 130, 0, 0.0, DSP_THD_MAINS_BOTH, nullptr, &r));
    EXPECT_NEAR(0.5, r.amp0, 1e-5);
}

TEST(ThdNoise, EveryBadArgumentIsRefused) {
    std::vector<dsp_real> pwr(256, (dsp_real)1e-10);
    dsp_thdn r{};
    EXPECT_EQ(DSP_EARG, dsp_thd_noise(nullptr, 256, 1, 130, 0, 0.0, DSP_THD_MAINS_BOTH, nullptr, &r));
    EXPECT_EQ(DSP_EARG, dsp_thd_noise(pwr.data(), 256, 1, 130, 0, 0.0, DSP_THD_MAINS_BOTH, nullptr, nullptr));
    EXPECT_EQ(DSP_EARG, dsp_thd_noise(pwr.data(), 4, 1, 3, 0, 0.0, DSP_THD_MAINS_BOTH, nullptr, &r));
    EXPECT_EQ(DSP_EARG, dsp_thd_noise(pwr.data(), 256, 1, 4, 0, 0.0, DSP_THD_MAINS_BOTH, nullptr, &r))
        << "a window under five bins wide";

    std::vector<dsp_real> zero(256, (dsp_real)0.0);
    EXPECT_EQ(DSP_OK, dsp_thd_noise(zero.data(), 256, 1, 130, 0, 0.0, DSP_THD_MAINS_BOTH, nullptr, &r));
    EXPECT_EQ(0, r.nharm);
    EXPECT_EQ(0, r.nnoise);
}

TEST(ThdNoise, HostileBinsDoNotReachTheResult) {
    const double bad[] = {QuietNaN(), SignallingNaN(), kInf, -kInf, NegativeZero(),
                          1e30};
    for (double v : bad) {
        for (int at : {1, 60, 61, 120, 129}) {
            std::vector<dsp_real> pwr(256, (dsp_real)1e-10);
            pwr[60] = (dsp_real)1.0;
            pwr[120] = (dsp_real)0.0025;
            pwr[at] = (dsp_real)v;
            dsp_thdn r{};
            ASSERT_EQ(DSP_OK, dsp_thd_noise(pwr.data(), 256, 1, 130, 0, 0.0, DSP_THD_MAINS_BOTH, nullptr, &r))
                << "v=" << v << " at=" << at;
            EXPECT_FALSE(std::isnan(r.thd)) << "v=" << v << " at=" << at;
            EXPECT_FALSE(std::isnan(r.noise_db)) << "v=" << v << " at=" << at;
            EXPECT_FALSE(std::isnan(r.snr_db)) << "v=" << v << " at=" << at;
            EXPECT_FALSE(std::isnan(r.f0)) << "v=" << v << " at=" << at;
            EXPECT_FALSE(std::isnan(r.amp0)) << "v=" << v << " at=" << at;
        }
    }
}

TEST(ThdNoise, AHarmonicInsideThePreviousSkirtIsNotCounted) {
    std::vector<dsp_real> pwr(256, (dsp_real)1e-10);
    pwr[2] = (dsp_real)1.0;
    pwr[4] = (dsp_real)0.25;
    dsp_thdn r{};
    ASSERT_EQ(DSP_OK, dsp_thd_noise(pwr.data(), 256, 1, 130, 0, 0.0, DSP_THD_MAINS_BOTH, nullptr, &r));
    EXPECT_NEAR(2.0, r.f0, 1e-6);

    EXPECT_LT(r.thd, 0.01) << "a line inside the skirt was counted as a harmonic";
}

TEST(ThdNoise, TheWindowSetsACeilingOnReportableSnr) {
    struct Want {
        int kind;
        double beta;
        double floor_db;
    };

    const Want want[] = {
        {DSP_WINDOW_HANN, 0.0, 100.0},          {DSP_WINDOW_BLACKMAN, 0.0, 112.0},
        {DSP_WINDOW_BLACKMAN_HARRIS, 0.0, 131.0}, {DSP_WINDOW_KAISER, 4.0, 34.0},
        {DSP_WINDOW_KAISER, 6.0, 45.0},         {DSP_WINDOW_KAISER, 9.0, 67.0},
        {DSP_WINDOW_KAISER, 12.0, 90.0},        {DSP_WINDOW_KAISER, 15.0, 115.0},
        {DSP_WINDOW_KAISER, 18.0, 122.0},
    };
    for (const Want &w : want) {
        Plan p(16384, w.kind, w.beta);
        ASSERT_EQ(DSP_OK, p.rc());
        ASSERT_EQ(p->m, RunSpectrum(p, ToneAtBin(16384, 2048.0, 0.0)));
        dsp_thdn r{};
        ASSERT_EQ(DSP_OK, dsp_thd_noise(p->pwr, p->m, 1, p->m - 1, p->kdc, 0.0, DSP_THD_MAINS_BOTH, &p->ip, &r));
        WinCfg c{w.kind, w.beta};
        EXPECT_NE(0, r.signal) << c.label();
        EXPECT_GT(r.snr_db, w.floor_db) << c.label() << " ceiling fell: " << r.snr_db;
    }
}

TEST(WindowLobe, TheHalfWidthBracketsTheMeasuredFirstNull) {
    for (const WinCfg &c : ShippedWindows()) {
        Plan p(1024, c.kind, c.beta);
        ASSERT_EQ(DSP_OK, p.rc());
        double wsum = 0.0;
        for (int i = 0; i < 1024; i++)
            wsum += (double)p->w[i];
        const double cc = (1024 - 1) / 2.0;
        double prev = 1.0, nullx = -1.0;
        for (double x = 0.25; x <= 12.0; x += 0.01) {
            double s = 0.0;
            for (int i = 0; i < 1024; i++)
                s += (double)p->w[i] * std::cos(2.0 * M_PI * x * ((double)i - cc) / 1024.0);
            const double g = std::fabs(s) / wsum;
            if (g > prev && prev < 1e-3) {   // climbing out of a null
                nullx = x;
                break;
            }
            prev = g;
        }
        ASSERT_GT(nullx, 0.0) << c.label() << " no null found to compare against";
        const int lobe = dsp_window_lobe(c.kind, c.beta);
        EXPECT_GE(lobe, (int)std::floor(nullx))
            << c.label() << " lobe=" << lobe << " null at " << nullx;
        EXPECT_LE(lobe, (int)std::ceil(nullx) + 1)
            << c.label() << " lobe=" << lobe << " null at " << nullx;
    }
}

TEST(WindowLobe, EveryKindAnswersAndAnUnknownOneDoesNot) {
    EXPECT_EQ(2, dsp_window_lobe(DSP_WINDOW_HANN, 0.0));
    EXPECT_EQ(3, dsp_window_lobe(DSP_WINDOW_BLACKMAN, 0.0));
    EXPECT_EQ(4, dsp_window_lobe(DSP_WINDOW_BLACKMAN_HARRIS, 0.0));
    EXPECT_EQ(6, dsp_window_lobe(DSP_WINDOW_KAISER, 18.0));
    EXPECT_EQ(2, dsp_window_lobe(DSP_WINDOW_KAISER, 0.0)) << "the contract's minimum";
    EXPECT_EQ(0, dsp_window_lobe(DSP_WINDOW_COUNT, 0.0)) << "an unknown kind";
    EXPECT_EQ(0, dsp_window_lobe(-1, 0.0));

    EXPECT_EQ(2, dsp_window_lobe(DSP_WINDOW_KAISER, kNaN));
    EXPECT_EQ(2, dsp_window_lobe(DSP_WINDOW_KAISER, -1.0));
    EXPECT_GE(dsp_window_lobe(DSP_WINDOW_KAISER, kInf), 2);
    EXPECT_GE(dsp_window_lobe(DSP_WINDOW_KAISER, 1e300), 2);
}

TEST(WindowLobe, APlanRecordsItsOwnLobe) {
    for (const WinCfg &c : ShippedWindows()) {
        Plan p(1024, c.kind, c.beta);
        ASSERT_EQ(DSP_OK, p.rc()) << c.label();
        EXPECT_EQ(dsp_window_lobe(c.kind, c.beta), p->ip.lobe) << c.label();
        EXPECT_GE(p->ip.lobe, 2) << c.label();
    }
}

TEST(ThdNoise, ANoisePeakIsNotASignal) {
    for (double over_db : {0.0, 10.0, 17.0, 25.0, 38.8, 44.0}) {
        std::vector<dsp_real> pwr(2048, (dsp_real)1e-10);
        pwr[700] = (dsp_real)(1e-10 * std::pow(10.0, over_db / 10.0));
        dsp_thdn r{};
        ASSERT_EQ(DSP_OK, dsp_thd_noise(pwr.data(), 2048, 1, 2000, 0, 0.0, DSP_THD_MAINS_BOTH, nullptr, &r));
        EXPECT_EQ(0, r.signal) << over_db << " dB over the mean read as a signal";
        EXPECT_EQ(0, r.nharm) << over_db;
        EXPECT_EQ(0.0, r.thd) << over_db;
        EXPECT_EQ(0.0, r.snr_db) << over_db;

        EXPECT_GT(r.nnoise, 0) << over_db;
        EXPECT_NEAR(-100.0, r.noise_db, 0.3) << over_db;
    }
    for (double over_db : {46.0, 92.0, 117.9}) {
        std::vector<dsp_real> pwr(2048, (dsp_real)1e-10);
        pwr[700] = (dsp_real)(1e-10 * std::pow(10.0, over_db / 10.0));
        dsp_thdn r{};
        ASSERT_EQ(DSP_OK, dsp_thd_noise(pwr.data(), 2048, 1, 2000, 0, 0.0, DSP_THD_MAINS_BOTH, nullptr, &r));
        EXPECT_NE(0, r.signal) << over_db << " dB over the mean is a tone";
    }
}

TEST(ThdNoise, AToneDoesNotLiftTheMeasuredNoiseFloor) {
    for (const WinCfg &c : ShippedWindows()) {
        Plan p(16384, c.kind, c.beta);
        ASSERT_EQ(DSP_OK, p.rc());

        unsigned state = 2024u;
        std::vector<double> noise(16384);
        for (int i = 0; i < 16384; i++) {
            state = state * 1103515245u + 12345u;
            noise[(size_t)i] = 1e-3 * ((double)((state >> 8) & 0xFFFFu) / 32768.0 - 1.0);
        }
        ASSERT_EQ(p->m, RunSpectrum(p, noise));
        dsp_thdn bare{};
        ASSERT_EQ(DSP_OK, dsp_thd_noise(p->pwr, p->m, 1, p->m - 1, p->kdc, 0.0, DSP_THD_MAINS_BOTH, &p->ip, &bare));
        ASSERT_GT(bare.nnoise, 0) << c.label();
        for (double frac : {0.0, 0.25, 0.5, 0.75}) {
            std::vector<double> x = noise;
            for (int i = 0; i < 16384; i++)
                x[(size_t)i] += std::cos(2.0 * M_PI * (2048.0 + frac) * i / 16384.0);
            ASSERT_EQ(p->m, RunSpectrum(p, x));
            dsp_thdn r{};
            ASSERT_EQ(DSP_OK, dsp_thd_noise(p->pwr, p->m, 1, p->m - 1, p->kdc, 0.0, DSP_THD_MAINS_BOTH, &p->ip, &r));
            ASSERT_NE(0, r.signal) << c.label() << " frac=" << frac;

            const double bound = (c.kind == DSP_WINDOW_KAISER && c.beta <= 6.0) ? 12.0 : 2.0;
            EXPECT_NEAR(bare.noise_db, r.noise_db, bound)
                << c.label() << " frac=" << frac << ": a 1 V tone moved the floor from "
                << bare.noise_db << " to " << r.noise_db;
        }
    }
}

TEST(ThdNoise, TheClipDoesNotEatRealNoise) {
    for (int nb : {512, 4096}) {
        unsigned state = 12345u;
        std::vector<dsp_real> pwr((size_t)nb);
        const double mean_in = 1e-10;
        double raw = 0.0;
        for (int k = 0; k < nb; k++) {
            state = state * 1103515245u + 12345u;
            const double u = ((double)((state >> 8) & 0xFFFFFFu) + 1.0) / 16777216.0;
            const double v = -mean_in * std::log(u);     // exponential, mean mean_in
            pwr[(size_t)k] = (dsp_real)v;
            raw += v;
        }
        dsp_thdn r{};
        ASSERT_EQ(DSP_OK, dsp_thd_noise(pwr.data(), nb, 1, nb - 1, 0, 0.0, DSP_THD_MAINS_BOTH, nullptr, &r));
        const double raw_db = 10.0 * std::log10(raw / (double)nb);

        EXPECT_NEAR(raw_db, r.noise_db, 1.5)
            << "nb=" << nb << " bias " << (r.noise_db - raw_db) << " dB, kept " << r.nnoise;

        int stride = (nb - 1) / DSP_THD_NSAMPLE;
        if (stride < 1)
            stride = 1;
        const int sampled = ((nb - 1) - 1) / stride + 1;
        EXPECT_GT(r.nnoise, (sampled * 9) / 10)
            << "nb=" << nb << " stride=" << stride << " kept " << r.nnoise << " of "
            << sampled << " sampled";
        EXPECT_EQ(0, r.signal) << "noise alone is not a signal";
    }
}

TEST(ThdNoise, TheWindowClampsHoldAtTheEdges) {
    std::vector<dsp_real> pwr(256, (dsp_real)1e-10);
    pwr[60] = (dsp_real)1.0;
    pwr[120] = (dsp_real)0.0025;
    dsp_thdn r{};

    ASSERT_EQ(DSP_OK, dsp_thd_noise(pwr.data(), 256, 1, 100000, 0, 0.0, DSP_THD_MAINS_BOTH, nullptr, &r));
    EXPECT_GE(r.nharm, 1);
    EXPECT_NEAR(0.05, r.thd, 1e-4) << "floor bins at 3f and 4f moved the figure";

    std::vector<dsp_real> low(256, (dsp_real)1e-10);
    low[1] = (dsp_real)1.0;
    dsp_thdn q{};
    ASSERT_EQ(DSP_OK, dsp_thd_noise(low.data(), 256, 1, 130, 0, 0.0, DSP_THD_MAINS_BOTH, nullptr, &q));
    EXPECT_NEAR(1.0, q.f0, 1e-6);

    EXPECT_GE(q.nharm, 1);
    EXPECT_LT(q.thd, 1e-3) << "floor bins at the harmonics moved the figure";
}

TEST(ThdNoise, AHarmonicSearchOverZerosFindsNothing) {
    std::vector<dsp_real> pwr(256, (dsp_real)1e-10);
    pwr[60] = (dsp_real)1.0;
    for (int k = 117; k <= 123; k++)
        pwr[(size_t)k] = (dsp_real)0.0;
    dsp_thdn r{};
    ASSERT_EQ(DSP_OK, dsp_thd_noise(pwr.data(), 256, 1, 130, 0, 0.0, DSP_THD_MAINS_BOTH, nullptr, &r));
    EXPECT_EQ(0, r.nharm) << "a window of zeros produced a harmonic";
    EXPECT_EQ(0.0, r.thd);
    EXPECT_NE(0, r.signal) << "the fundamental is still a signal";
    EXPECT_GT(r.nnoise, 0);
}

TEST(ThdNoise, MainsPickupIsPassedOver) {
    const double binhz = 10.0;
    auto spectrum = [](const std::vector<std::pair<int, double>> &lines) {
        std::vector<dsp_real> p(256, (dsp_real)1e-12);
        for (const auto &l : lines)
            p[(size_t)l.first] = (dsp_real)l.second;
        return p;
    };

    {
        auto p = spectrum({{6, 1e-3}, {12, 1e-5}, {18, 1e-6}, {54, 1e-7}});
        dsp_thdn r{};
        ASSERT_EQ(DSP_OK, dsp_thd_noise(p.data(), 256, 1, 254, 0, binhz, DSP_THD_MAINS_BOTH, nullptr, &r));
        EXPECT_EQ(0, r.signal) << "60 Hz hum read as a signal, f0=" << r.f0_hz;
        EXPECT_GT(r.nnoise, 0) << "the floor is still the useful number";
    }

    {
        auto p = spectrum({{5, 1e-3}, {10, 1e-5}, {15, 1e-6}});
        dsp_thdn r{};
        ASSERT_EQ(DSP_OK, dsp_thd_noise(p.data(), 256, 1, 254, 0, binhz, DSP_THD_MAINS_BOTH, nullptr, &r));
        EXPECT_EQ(0, r.signal) << "50 Hz hum read as a signal, f0=" << r.f0_hz;
    }

    {
        auto p = spectrum({{6, 1e-3}, {12, 1e-5}, {123, 1e-4}});
        dsp_thdn r{};
        ASSERT_EQ(DSP_OK, dsp_thd_noise(p.data(), 256, 1, 254, 0, binhz, DSP_THD_MAINS_BOTH, nullptr, &r));
        EXPECT_NE(0, r.signal);
        EXPECT_NEAR(1230.0, r.f0_hz, 1.0) << "the hum outranked a real tone";
    }

    {
        auto p = spectrum({{6, 1.0}});
        dsp_thdn r{};
        ASSERT_EQ(DSP_OK, dsp_thd_noise(p.data(), 256, 1, 254, 0, binhz, DSP_THD_MAINS_BOTH, nullptr, &r));
        EXPECT_NE(0, r.signal) << "a 0 dBV 60 Hz tone was discounted as hum";
        EXPECT_NEAR(60.0, r.f0_hz, 1.0);
    }

    {
        auto p = spectrum({{120, 1e-4}});
        dsp_thdn r{};
        ASSERT_EQ(DSP_OK, dsp_thd_noise(p.data(), 256, 1, 254, 0, binhz, DSP_THD_MAINS_BOTH, nullptr, &r));
        EXPECT_NE(0, r.signal) << "1200 Hz was discounted as a mains multiple";
        EXPECT_NEAR(1200.0, r.f0_hz, 1.0);
    }

    {
        auto p = spectrum({{6, 1e-3}});
        dsp_thdn r{};
        ASSERT_EQ(DSP_OK, dsp_thd_noise(p.data(), 256, 1, 254, 0, 0.0, DSP_THD_MAINS_BOTH, nullptr, &r));
        EXPECT_NE(0, r.signal) << "the rule fired without a bin width to place 60 Hz with";
        EXPECT_EQ(0.0, r.f0_hz);
    }

    {
        auto p = spectrum({{62, 1e-3}, {7, 1e-4}});
        dsp_thdn r{};
        ASSERT_EQ(DSP_OK, dsp_thd_noise(p.data(), 256, 1, 254, 0, 1.0, DSP_THD_MAINS_BOTH, nullptr, &r));
        EXPECT_NEAR(7.0, r.f0_hz, 0.5) << "62 Hz of hum outranked a line at 7";
    }
}

// Select one mains frequency without excluding the other; the fixture keeps their bins distinct.
TEST(ThdNoise, SelectingOneMainsFrequencyGivesBackTheOther) {
    std::vector<dsp_real> p(256, (dsp_real)1e-12);
    p[25] = (dsp_real)1e-3;              // 50 Hz
    p[30] = (dsp_real)2e-3;              // 60 Hz, the louder of the two
    const double binhz = 2.0;
    struct {
        int mains;
        int signal;
        double f0;
        const char *what;
    } cases[] = {
        {DSP_THD_MAINS_BOTH, 0, 0.0, "both discounted"},
        {(int)DSP_THD_MAINS_A, 1, 60.0, "50 selected, so 60 is a tone"},
        {(int)DSP_THD_MAINS_B, 1, 50.0, "60 selected, so 50 is a tone"},
        {0, 1, 60.0, "the rule off, so the louder line is the tone"},
    };
    for (const auto &c : cases) {
        dsp_thdn r{};
        ASSERT_EQ(DSP_OK, dsp_thd_noise(p.data(), 256, 1, 254, 0, binhz, c.mains,
                                        nullptr, &r)) << c.what;
        EXPECT_EQ(c.signal, r.signal) << c.what;
        if (c.signal != 0)
            EXPECT_NEAR(c.f0, r.f0_hz, 0.5) << c.what;
    }

    for (const auto &c : cases) {
        dsp_thdn r{};
        ASSERT_EQ(DSP_OK, dsp_thd_noise(p.data(), 256, 1, 254, 0, binhz, c.mains,
                                        nullptr, &r));
        EXPECT_GT(r.nnoise, 0) << c.what;
    }
}

TEST(ThdNoise, AnUnknownMainsSelectionIsRefused) {
    std::vector<dsp_real> p(256, (dsp_real)1e-12);
    p[30] = (dsp_real)2e-3;
    dsp_thdn r{};
    EXPECT_EQ(DSP_EARG, dsp_thd_noise(p.data(), 256, 1, 254, 0, 2.0, 55, nullptr, &r));
    EXPECT_EQ(DSP_EARG, dsp_thd_noise(p.data(), 256, 1, 254, 0, 2.0, -2, nullptr, &r));

    EXPECT_EQ(DSP_OK, dsp_thd_noise(p.data(), 256, 1, 254, 0, 2.0, 50, nullptr, &r));
    EXPECT_EQ(DSP_OK, dsp_thd_noise(p.data(), 256, 1, 254, 0, 2.0, 60, nullptr, &r));
    EXPECT_EQ(DSP_OK, dsp_thd_noise(p.data(), 256, 1, 254, 0, 2.0, 0, nullptr, &r));
}

// Check the integrated-noise identity above the sampling threshold, including stride.
TEST(ThdNoise, TheIdentityHoldsAcrossTheSamplingThreshold) {
    std::vector<dsp_real> pwr(8192, (dsp_real)4e-9);
    pwr[80] = (dsp_real)2.25;
    for (int k1 : {400, 1024, 2048, 4096, 8000}) {
        dsp_thdn r{};
        ASSERT_EQ(DSP_OK, dsp_thd_noise(pwr.data(), 8192, 1, k1, 0, 0.0, DSP_THD_MAINS_BOTH,
                                        nullptr, &r)) << "k1=" << k1;
        ASSERT_GT(r.nnoise, 0) << "k1=" << k1;
        int want = k1 / DSP_THD_NSAMPLE;
        if (want < 1)
            want = 1;
        EXPECT_EQ(want, r.stride) << "k1=" << k1;
        const double lhs = 20.0 * std::log10(r.amp0) - r.snr_db - r.noise_db;
        const double rhs = 10.0 * std::log10((double)r.nnoise * (double)r.stride);
        EXPECT_NEAR(rhs, lhs, 0.02)
            << "k1=" << k1 << " stride=" << r.stride << " nnoise=" << r.nnoise;
    }
}

// Overflowing sums must clear result validity rather than return infinite figures.
TEST(ThdNoise, NoFigureLeavesNonFinite) {
    std::vector<dsp_real> pwr(512, (dsp_real)1e-30);
    const dsp_real huge = std::numeric_limits<dsp_real>::max();
    pwr[20] = huge;
    pwr[40] = huge;
    pwr[60] = huge;
    pwr[80] = huge;
    dsp_thdn r{};
    ASSERT_EQ(DSP_OK, dsp_thd_noise(pwr.data(), 512, 1, 500, 0, 0.0, DSP_THD_MAINS_BOTH,
                                    nullptr, &r));
    EXPECT_TRUE(std::isfinite(r.thd)) << "thd=" << r.thd;
    EXPECT_TRUE(std::isfinite(r.snr_db)) << "snr=" << r.snr_db;
    EXPECT_TRUE(std::isfinite(r.noise_db)) << "floor=" << r.noise_db;
    EXPECT_TRUE(std::isfinite(r.amp0));
    EXPECT_TRUE(std::isfinite(r.f0));
    EXPECT_TRUE(std::isfinite(r.f0_hz));

    std::fill(pwr.begin(), pwr.end(), huge);
    ASSERT_EQ(DSP_OK, dsp_thd_noise(pwr.data(), 512, 1, 500, 0, 0.0, DSP_THD_MAINS_BOTH,
                                    nullptr, &r));
    EXPECT_TRUE(std::isfinite(r.noise_db)) << "floor=" << r.noise_db;
    EXPECT_TRUE(std::isfinite(r.snr_db));
    EXPECT_TRUE(std::isfinite(r.thd));
}

// Refusals clear the result struct so stale figures cannot reach the caller.
TEST(ThdNoise, OutIsZeroedOnEveryRefusal) {
    std::vector<dsp_real> pwr(512, (dsp_real)1e-9);
    pwr[80] = (dsp_real)1.0;
    dsp_thdn seed{};
    ASSERT_EQ(DSP_OK, dsp_thd_noise(pwr.data(), 512, 1, 500, 0, 10.0, DSP_THD_MAINS_BOTH,
                                    nullptr, &seed));
    ASSERT_NE(0, seed.signal) << "the seed has to carry real figures";
    struct Bad {
        int nbins, k1, mains;
        const char *what;
    };
    const Bad bad[] = {
        {4, 3, DSP_THD_MAINS_BOTH, "fewer than eight bins"},
        {512, 3, DSP_THD_MAINS_BOTH, "a window under five"},
        {512, 500, 55, "a frequency that is neither mains"},
    };
    for (const Bad &b : bad) {
        dsp_thdn r = seed;
        EXPECT_EQ(DSP_EARG, dsp_thd_noise(pwr.data(), b.nbins, 1, b.k1, 0, 10.0, b.mains,
                                          nullptr, &r)) << b.what;
        EXPECT_EQ(0, r.signal) << b.what;
        EXPECT_EQ(0.0, r.noise_db) << b.what;
        EXPECT_EQ(0, r.nnoise) << b.what;
        EXPECT_EQ(0.0, r.amp0) << b.what;
    }
}

// NaNs must not suppress a segment's valid maximum, regardless of their position.
TEST(Reduce, ANanBinDoesNotSuppressItsSegment) {
    dsp_bandmap m{};
    ASSERT_EQ(DSP_OK, dsp_band_map(100000.0, 0.0, 50000.0, 64, 1, &m));
    const double nan = std::numeric_limits<double>::quiet_NaN();

    for (int where : {8, 9, 15}) {
        std::vector<dsp_real> pwr(64, (dsp_real)1e-12), db(8), hz(8);
        pwr[(size_t)where] = (dsp_real)nan;
        pwr[12] = (dsp_real)1.0;             // 0 dBV, same segment
        ASSERT_EQ(8, dsp_reduce(pwr.data(), 64, 0, 63, 8, &m, -120.0, 20.0, 1e-9, db.data(),
                                hz.data()));
        EXPECT_NEAR(0.0, (double)db[1], 1e-5)
            << "a NaN at bin " << where << " hid the tone at bin 12";
    }

    {
        std::vector<dsp_real> pwr(64, (dsp_real)1e-12), db(8), hz(8);
        for (int k = 8; k <= 15; k++)
            pwr[(size_t)k] = (dsp_real)nan;
        ASSERT_EQ(8, dsp_reduce(pwr.data(), 64, 0, 63, 8, &m, -120.0, 20.0, 1e-9, db.data(),
                                hz.data()));
        EXPECT_EQ((dsp_real)-120.0, db[1]);
    }
}

// In a one-bin spectrum, the self-mirrored bin is already bin zero.
TEST(Power, OneBinAnswersForThatBinRatherThanWrongly) {
    const dsp_real re[2] = {(dsp_real)3.0, (dsp_real)0.0};
    const dsp_real im[2] = {(dsp_real)4.0, (dsp_real)0.0};

    const dsp_real utr[2] = {(dsp_real)1.0, (dsp_real)0.0};
    const dsp_real uti[2] = {(dsp_real)1.0, (dsp_real)0.0};
    dsp_real out[2] = {(dsp_real)-1.0, (dsp_real)-1.0};
    dsp_power(re, im, 1, utr, uti, out, 1.0);

    EXPECT_NEAR(196.0, (double)out[0], 1e-3);
}

// A nondecimating plan has no FIR output scratch and must reject taps.
TEST(Refusals, TapsOnANonDecimatingPlanAreRefused) {
    dsp_real h[DSP_FIR_MAXTAPS];
    int l = 21;
    for (int i = 0; i < l; i++)
        h[i] = (dsp_real)(1.0 / (double)l);
#if DSP_BANDPASS

    l = dsp_fir_design(h, DSP_FIR_MAXTAPS, 100000.0, 2000.0, 20000.0, 1, 0);
    ASSERT_GT(l, 0) << "the design side admits a decim-1 band-pass";
#endif
    Plan flat(1024, DSP_WINDOW_HANN, 0, 1);
    ASSERT_EQ(DSP_OK, flat.rc());
    EXPECT_EQ(DSP_EARG, dsp_plan_set_fir(&flat.get(), h, l))
        << "a filter this plan could never apply";
    EXPECT_EQ(0, flat.get().ntaps) << "and nothing was installed";
    EXPECT_EQ(0, dsp_plan_set_fir(&flat.get(), nullptr, 0)) << "clearing is still fine";

    Plan dec(1024, DSP_WINDOW_HANN, 0, 4);
    ASSERT_EQ(DSP_OK, dec.rc());
    EXPECT_EQ(l, dsp_plan_set_fir(&dec.get(), h, l));
}

// Extreme counts must not overflow when computing bin indices.
TEST(Refusals, HostileIntegerParametersDoNotOverflow) {
    std::vector<dsp_real> pwr(4096, (dsp_real)1e-12);
    pwr[100] = (dsp_real)1.0;
    int bin[6];
    dsp_real frac[6], amp[6];
    EXPECT_GE(dsp_peaks(pwr.data(), 4096, 1, 4000, INT_MAX, 6, nullptr, bin, frac, amp), 0)
        << "kdc at INT_MAX";
    EXPECT_GE(dsp_peaks(pwr.data(), 4096, 1, 4000, INT_MIN, 6, nullptr, bin, frac, amp), 0)
        << "kdc at INT_MIN";
    EXPECT_EQ(DSP_EARG, dsp_peaks(pwr.data(), 0, 1, 10, 0, 6, nullptr, bin, frac, amp))
        << "no bins at all";
    EXPECT_EQ(DSP_EARG, dsp_peaks(pwr.data(), INT_MIN, 1, 10, 0, 6, nullptr, bin, frac, amp))
        << "nbins at INT_MIN";
    dsp_thdn r{};

    EXPECT_EQ(DSP_EARG, dsp_thd_noise(pwr.data(), 4096, 1, 4000, INT_MAX, 10.0,
                                      DSP_THD_MAINS_BOTH, nullptr, &r)) << "kdc at INT_MAX";
    EXPECT_EQ(DSP_OK, dsp_thd_noise(pwr.data(), 4096, 1, 4000, INT_MIN, 10.0,
                                    DSP_THD_MAINS_BOTH, nullptr, &r)) << "kdc at INT_MIN";

    Plan ip(64, DSP_WINDOW_HANN);
    ASSERT_EQ(DSP_OK, ip.rc());
    double d = 0.0, a = 0.0;
    EXPECT_EQ(DSP_EDECLINE, dsp_peak_interp(&ip->ip, pwr.data(), 5, INT_MIN, &d, &a))
        << "nbins at INT_MIN";
    EXPECT_EQ(DSP_EDECLINE, dsp_peak_interp(&ip->ip, pwr.data(), 1, 2, &d, &a))
        << "a two-bin spectrum has no interior bin";
}

TEST(StrError, EveryCodeHasAShortMessage) {
    const int codes[] = {DSP_OK, DSP_EARG, DSP_EPOW2, DSP_ENOMEM, DSP_EUNSUPPORTED,
                         DSP_ESHORT, DSP_EBETA, DSP_EDECLINE, DSP_EALIGN, DSP_EZONE,
                         DSP_EDIRTY};
    for (int c : codes) {
        const char *s = dsp_strerror(c);
        ASSERT_NE(nullptr, s) << "code " << c;
        EXPECT_GT(std::strlen(s), 1u) << "code " << c;
        EXPECT_LE(std::strlen(s), 31u) << "code " << c << " = " << s;
    }

    for (size_t i = 0; i < sizeof codes / sizeof codes[0]; i++)
        for (size_t j = i + 1; j < sizeof codes / sizeof codes[0]; j++)
            EXPECT_STRNE(dsp_strerror(codes[i]), dsp_strerror(codes[j]))
                << codes[i] << " and " << codes[j];
    EXPECT_STREQ("unknown error", dsp_strerror(-999));
    EXPECT_STREQ("unknown error", dsp_strerror(12345));
}

namespace {
int g_yields = 0;
void CountYield(void *ctx) {
    g_yields++;
    if (ctx != nullptr)
        *(int *)ctx += 1;
}
} // namespace

// Yields occur at a bounded number of phase boundaries, not per sample.
TEST(Yield, IsCalledABoundedNumberOfTimesPerFrame) {
    for (int method = 0; method < DSP_FFT_COUNT; method++) {
        Plan p(1024, DSP_WINDOW_HANN, 0, 1, method);
        ASSERT_EQ(DSP_OK, p.rc());
        std::vector<double> x(1024);
        for (size_t i = 0; i < x.size(); i++)
            x[i] = std::sin(2.0 * M_PI * 50.0 * (double)i / 1024.0);
        int mine = 0;
        ASSERT_EQ(DSP_OK, dsp_plan_set_yield(&p.get(), CountYield, &mine));
        g_yields = 0;
        ASSERT_EQ(p->m, dsp_spectrum_run(&p.get(), x.data(), 1024, nullptr));
        EXPECT_GE(mine, 2) << "method " << method << ": at least the load and the transform";
        EXPECT_LE(mine, 4 * p->m1 + 8)
            << "method " << method << ": bounded by the decomposition, not by the samples";
        EXPECT_EQ(g_yields, mine) << "the context reached the callback";

        ASSERT_EQ(DSP_OK, dsp_plan_set_yield(&p.get(), nullptr, nullptr));
        mine = 0;
        ASSERT_EQ(p->m, dsp_spectrum_run(&p.get(), x.data(), 1024, nullptr));
        EXPECT_EQ(0, mine) << "method " << method << ": a cleared yield is not called";
    }
}

TEST(Yield, RefusesAnUnbuiltPlan) {
    dsp_plan empty;
    std::memset(&empty, 0, sizeof empty);
    EXPECT_EQ(DSP_EARG, dsp_plan_set_yield(nullptr, CountYield, nullptr));
    EXPECT_EQ(DSP_EARG, dsp_plan_set_yield(&empty, CountYield, nullptr));
}

// Installing a yield callback must leave the spectrum unchanged.
TEST(Yield, DoesNotChangeTheSpectrum) {
    Plan a(1024, DSP_WINDOW_HANN), b(1024, DSP_WINDOW_HANN);
    ASSERT_EQ(DSP_OK, a.rc());
    ASSERT_EQ(DSP_OK, b.rc());
    std::vector<double> x(1024);
    for (size_t i = 0; i < x.size(); i++)
        x[i] = 0.7 * std::sin(2.0 * M_PI * 123.0 * (double)i / 1024.0) + 0.01;
    int mine = 0;
    ASSERT_EQ(DSP_OK, dsp_plan_set_yield(&b.get(), CountYield, &mine));
    ASSERT_EQ(a->m, dsp_spectrum_run(&a.get(), x.data(), 1024, nullptr));
    ASSERT_EQ(b->m, dsp_spectrum_run(&b.get(), x.data(), 1024, nullptr));
    ASSERT_GT(mine, 0);
    for (int k = 0; k < a->m; k++)
        ASSERT_EQ(a->pwr[k], b->pwr[k]) << "bin " << k;
}

// Frequency spans and bin indices

// Check both edges by inversion: chosen centers are inside and adjacent centers are outside.
TEST(BandBins, EveryBinInTheWindowIsInTheBandAndTheNeighboursAreNot) {
    const double fs = 1e6;
    const int n = 2048, nbins = n / 2;
    const struct {
        double flo, fhi;
    } cases[] = {
        {10.0, 400000.0},     {1000.0, 50000.0},     {50000.0, 400000.0},
        {0.0, 1000.0},        {123456.0, 123999.0},  {380000.0, 400000.0},
    };
    dsp_bandmap map{};
    ASSERT_EQ(DSP_OK, dsp_band_map(fs, 0.0, fs / 2.0, n, 1, &map));
    for (const auto &c : cases) {
        int k0 = -1, k1 = -1;
        ASSERT_EQ(DSP_OK, dsp_band_bins(&map, c.flo, c.fhi, nbins, &k0, &k1))
            << c.flo << ".." << c.fhi;
        ASSERT_GE(k0, 0);
        ASSERT_LE(k1, nbins - 1);
        ASSERT_LE(k0, k1);
        for (int k = k0; k <= k1; k++) {
            const double hz = dsp_bin_hz(&map, k);
            EXPECT_GE(hz, c.flo) << "bin " << k << " of " << c.flo << ".." << c.fhi;
            EXPECT_LE(hz, c.fhi) << "bin " << k << " of " << c.flo << ".." << c.fhi;
        }
        if (k0 > 0)
            EXPECT_LT(dsp_bin_hz(&map, k0 - 1), c.flo) << "the bin below k0 is inside";
        if (k1 < nbins - 1)
            EXPECT_GT(dsp_bin_hz(&map, k1 + 1), c.fhi) << "the bin above k1 is inside";
    }
}

// A positive start below one bin must not round down to DC.
TEST(BandBins, AStartUnderOneBinWidthDoesNotReachDc) {
    const double fs = 1e5;
    const int n = 512, nbins = n / 2;
    dsp_bandmap map{};
    ASSERT_EQ(DSP_OK, dsp_band_map(fs, 0.0, fs / 2.0, n, 1, &map));
    ASSERT_NEAR(map.binhz, 195.3125, 1e-9) << "the premise: a bin is 195 Hz here";
    int k0 = -1, k1 = -1;
    ASSERT_EQ(DSP_OK, dsp_band_bins(&map, 10.0, 49000.0, nbins, &k0, &k1));
    EXPECT_EQ(1, k0) << "a 10 Hz start belongs in bin 1, not the DC bin";
    EXPECT_EQ(0, (int)floor(10.0 / map.binhz)) << "the control: rounding down gives DC";

    ASSERT_EQ(DSP_OK, dsp_band_bins(&map, map.binhz * 3.0, 49000.0, nbins, &k0, &k1));
    EXPECT_EQ(3, k0) << "a start exactly on bin 3 keeps bin 3";
}

// Match the Lua span convention after accounting for zero- versus one-based indexing.
TEST(BandBins, ItAgreesWithTheShippedLuaRuleAcrossASweep) {
    const double fs = 1e6;
    const int n = 4096, nbins = n / 2;
    dsp_bandmap map{};
    ASSERT_EQ(DSP_OK, dsp_band_map(fs, 0.0, fs / 2.0, n, 1, &map));
    int tried = 0;
    for (int i = 0; i < 400; i++) {
        const double flo = (double)i * 37.0;
        const double fhi = flo + 1000.0 + (double)i * 211.0;
        if (!(fhi < fs / 2.0))
            break;
        int k0 = -1, k1 = -1;
        ASSERT_EQ(DSP_OK, dsp_band_bins(&map, flo, fhi, nbins, &k0, &k1));
        int want0 = (int)ceil(flo / map.binhz);
        int want1 = (int)floor(fhi / map.binhz);
        if (want0 < 0)
            want0 = 0;
        if (want0 > nbins - 1)
            want0 = nbins - 1;
        if (want1 > nbins - 1)
            want1 = nbins - 1;
        if (want1 < want0)
            want1 = want0;
        ASSERT_EQ(want0, k0) << "k0 at " << flo << ".." << fhi;
        ASSERT_EQ(want1, k1) << "k1 at " << flo << ".." << fhi;
        tried++;
    }
    EXPECT_GT(tried, 50) << "the sweep has to actually run, or it asserts nothing";
}

// Odd Nyquist zones reverse the order of the edge indices.
#if DSP_BANDPASS
TEST(BandBins, AnOddZoneSwapsTheEdges) {
    const double fs = 1e6;
    const int n = 2048, nbins = n / 2;
    dsp_bandmap map{};
    ASSERT_EQ(DSP_OK, dsp_band_map(fs, 380000.0, 400000.0, n, 2, &map));
    ASSERT_EQ(-1, map.sense) << "the premise: zone 1 is reversed";
    int k0 = -1, k1 = -1;
    ASSERT_EQ(DSP_OK, dsp_band_bins(&map, 380000.0, 400000.0, nbins, &k0, &k1));
    ASSERT_LT(k0, k1) << "a 20 kHz band is many bins wide, so this is not the clamp";
    EXPECT_GT(dsp_bin_hz(&map, k0), dsp_bin_hz(&map, k1)) << "frequency falls with the index";
    for (int k = k0; k <= k1; k++) {
        const double hz = dsp_bin_hz(&map, k);
        EXPECT_GE(hz, 380000.0) << "bin " << k;
        EXPECT_LE(hz, 400000.0) << "bin " << k;
    }
}
#endif /* DSP_BANDPASS */

TEST(BandBins, ABandNarrowerThanOneBinReportsTheOneBinItFallsIn) {
    const double fs = 1e5;
    const int n = 512, nbins = n / 2;
    dsp_bandmap map{};
    ASSERT_EQ(DSP_OK, dsp_band_map(fs, 0.0, fs / 2.0, n, 1, &map));
    int k0 = -1, k1 = -1;
    const double mid = map.binhz * 10.0;
    ASSERT_EQ(DSP_OK, dsp_band_bins(&map, mid - 1.0, mid + 1.0, nbins, &k0, &k1));
    EXPECT_EQ(10, k0);
    EXPECT_EQ(10, k1) << "never empty, and never wider than it has to be";
}

// A span strictly between bins exercises the never-empty repair.
TEST(BandBins, ABandBetweenTwoBinCentresStillReportsOneBin) {
    const double fs = 1e5;
    const int n = 512, nbins = n / 2;
    dsp_bandmap map{};
    ASSERT_EQ(DSP_OK, dsp_band_map(fs, 0.0, fs / 2.0, n, 1, &map));

    const double lo_hz = map.binhz * 10.2, hi_hz = map.binhz * 10.8;
    ASSERT_GT(std::ceil(lo_hz / map.binhz), std::floor(hi_hz / map.binhz));
    int k0 = -1, k1 = -1;
    ASSERT_EQ(DSP_OK, dsp_band_bins(&map, lo_hz, hi_hz, nbins, &k0, &k1));
    EXPECT_EQ(11, k0);
    EXPECT_EQ(11, k1) << "repaired to one bin, not left as 11..10";
    EXPECT_GE(k1, k0) << "the window a caller reads is never empty";
}

TEST(BandBins, HostileArgumentsAreRefusedAndTheOutputsZeroed) {
    const double fs = 1e5;
    const int n = 512, nbins = n / 2;
    dsp_bandmap map{};
    ASSERT_EQ(DSP_OK, dsp_band_map(fs, 0.0, fs / 2.0, n, 1, &map));
    int k0 = 7, k1 = 9;
    EXPECT_EQ(DSP_EARG, dsp_band_bins(NULL, 10.0, 1000.0, nbins, &k0, &k1));
    EXPECT_EQ(0, k0) << "zeroed on a refusal, so a caller ignoring the code reads bin 0";
    EXPECT_EQ(0, k1);
    EXPECT_EQ(DSP_EARG, dsp_band_bins(&map, 10.0, 1000.0, nbins, NULL, &k1));
    EXPECT_EQ(DSP_EARG, dsp_band_bins(&map, 10.0, 1000.0, nbins, &k0, NULL));
    EXPECT_EQ(DSP_EARG, dsp_band_bins(&map, 10.0, 1000.0, 0, &k0, &k1)) << "no bins";
    EXPECT_EQ(DSP_EARG, dsp_band_bins(&map, 1000.0, 1000.0, nbins, &k0, &k1)) << "not ascending";
    EXPECT_EQ(DSP_EARG, dsp_band_bins(&map, 2000.0, 1000.0, nbins, &k0, &k1)) << "descending";
    const double qnan = std::numeric_limits<double>::quiet_NaN();
    const double pinf = std::numeric_limits<double>::infinity();
    EXPECT_EQ(DSP_EARG, dsp_band_bins(&map, qnan, 1000.0, nbins, &k0, &k1));
    EXPECT_EQ(DSP_EARG, dsp_band_bins(&map, 10.0, qnan, nbins, &k0, &k1));
    EXPECT_EQ(DSP_EARG, dsp_band_bins(&map, 10.0, pinf, nbins, &k0, &k1));

    k0 = -1;
    k1 = -1;
    EXPECT_EQ(DSP_OK, dsp_band_bins(&map, 1e9, 2e9, nbins, &k0, &k1));
    EXPECT_EQ(nbins - 1, k0);
    EXPECT_EQ(nbins - 1, k1);
}

#if DSP_CHECK_OVERLAP
// Check overlap by shared byte extents, with disjoint-buffer controls.
TEST(Overlap, EveryFramePrimitiveRefusesSlicesOfOneBuffer) {
    const int n = 256, nbins = n / 2, nseg = 16, want = 4;
    std::vector<dsp_real> pool((size_t)nbins * 4, (dsp_real)1e-9);
    for (int k = 8; k < nbins; k += 11)
        pool[(size_t)k] = (dsp_real)1.0;
    dsp_real *pwr = pool.data();
    dsp_real *sep1 = pool.data() + nbins;
    dsp_real *sep2 = pool.data() + nbins * 2;
    const dsp_bandmap m = FlatMap(1e5 / (double)n);

    EXPECT_EQ(nseg, dsp_reduce(pwr, nbins, 0, nbins - 1, nseg, &m, -120.0, 20.0, 1e-9,
                               sep1, sep2));
    EXPECT_EQ(DSP_EARG, dsp_reduce(pwr, nbins, 0, nbins - 1, nseg, &m, -120.0, 20.0, 1e-9,
                                   sep1, sep1)) << "db and hz in one buffer";
    EXPECT_EQ(DSP_EARG, dsp_reduce(pwr, nbins, 0, nbins - 1, nseg, &m, -120.0, 20.0, 1e-9,
                                   sep1, sep1 + nseg / 2)) << "db and hz as overlapping slices";
    EXPECT_EQ(DSP_EARG, dsp_reduce(pwr, nbins, 0, nbins - 1, nseg, &m, -120.0, 20.0, 1e-9,
                                   pwr, sep2)) << "db inside the bins it reduces";

    std::vector<int> bins((size_t)want * 2, 0);
    EXPECT_GE(dsp_peaks(pwr, nbins, 0, nbins - 1, 0, want, nullptr, bins.data(), sep1, sep2), 1);
    EXPECT_EQ(DSP_EARG, dsp_peaks(pwr, nbins, 0, nbins - 1, 0, want, nullptr, bins.data(),
                                  sep1, sep1)) << "frac and amp in one buffer";
    EXPECT_EQ(DSP_EARG, dsp_peaks(pwr, nbins, 0, nbins - 1, 0, want, nullptr, bins.data(),
                                  pwr, sep2)) << "frac inside the bins";
    EXPECT_EQ(DSP_EARG, dsp_peaks(pwr, nbins, 0, nbins - 1, 0, want,
                                  nullptr, reinterpret_cast<int *>(sep1), sep1, sep2))
        << "bin and frac sharing bytes across types";

    dsp_thdn r{};
    EXPECT_EQ(DSP_OK, dsp_thd_noise(pwr, nbins, 1, nbins - 1, 0, 100.0, DSP_THD_MAINS_BOTH,
                                    nullptr, &r));
    EXPECT_EQ(DSP_EARG, dsp_thd_noise(pwr, nbins, 1, nbins - 1, 0, 100.0, DSP_THD_MAINS_BOTH,
                                      nullptr, reinterpret_cast<dsp_thdn *>(pwr)))
        << "the figures written over the spectrum they describe";

    std::vector<double> src((size_t)n, 0.0), win_d((size_t)n, 0.0);
    std::vector<dsp_real> win((size_t)n, (dsp_real)1.0);
    for (int i = 0; i < n; i++)
        src[(size_t)i] = std::sin(2.0 * M_PI * 7.0 * (double)i / (double)n);
    EXPECT_EQ(DSP_OK, dsp_load(src.data(), n, win.data(), (double)n, sep1, sep2, nullptr));
    EXPECT_EQ(DSP_EARG, dsp_load(src.data(), n, win.data(), (double)n, sep1, sep1, nullptr))
        << "re and im in one buffer";
    EXPECT_EQ(DSP_EARG, dsp_load(src.data(), n, win.data(), (double)n, sep1,
                                 sep1 + n / 4, nullptr)) << "re and im as overlapping slices";
    EXPECT_EQ(DSP_EARG, dsp_load(src.data(), n, win.data(), (double)n, win.data(), sep2,
                                 nullptr)) << "re written over the window it reads";
    EXPECT_EQ(DSP_EARG, dsp_load(src.data(), n, win.data(), (double)n, sep1, sep2,
                                 src.data())) << "the mean written into the source";
}
#endif

#if DSP_CHECK_OVERLAP

TEST(BandBins, OneObjectForBothEdgesIsRefused) {
    const double fs = 1e5;
    const int n = 512, nbins = n / 2;
    dsp_bandmap map{};
    ASSERT_EQ(DSP_OK, dsp_band_map(fs, 0.0, fs / 2.0, n, 1, &map));

    int k0 = -1, k1 = -1;
    ASSERT_EQ(DSP_OK, dsp_band_bins(&map, 1000.0, 20000.0, nbins, &k0, &k1));
    ASSERT_LT(k0, k1) << "the band has to span more than one bin for this to mean anything";
    int both = 7;
    EXPECT_EQ(DSP_EARG, dsp_band_bins(&map, 1000.0, 20000.0, nbins, &both, &both));
    EXPECT_EQ(0, both) << "zeroed on a refusal, like every other refusal that can be";
}
#endif

// Both outputs may be NULL; that is not an aliasing error.
TEST(PeakInterp, OneObjectForBothOutputsIsRefusedAndTwoNullsAreNot) {
    Plan p(512, DSP_WINDOW_HANN);
    auto x = ToneAtBin(512, 64.37);
    ASSERT_EQ(p->m, dsp_spectrum_run(&p.get(), x.data(), 512, nullptr));
    int bin[6];
    const int found = dsp_peaks(p->pwr, p->m, 1, p->m - 1, p->kdc, 6, &p->ip, bin,
                                nullptr, nullptr);
    ASSERT_GE(found, 1);

    double d = -99.0, amp = -99.0;
    ASSERT_EQ(DSP_OK, dsp_peak_interp(&p->ip, p->pwr, bin[0], p->m, &d, &amp));
    ASSERT_NE(d, amp) << "one value in both would make the overwrite invisible";
#if DSP_CHECK_OVERLAP
    double one = -99.0;
    EXPECT_EQ(DSP_EARG, dsp_peak_interp(&p->ip, p->pwr, bin[0], p->m, &one, &one));
    EXPECT_EQ(-99.0, one) << "refused before anything is written";
#endif

    EXPECT_EQ(DSP_OK, dsp_peak_interp(&p->ip, p->pwr, bin[0], p->m, nullptr, nullptr));

    double only = -99.0;
    EXPECT_EQ(DSP_OK, dsp_peak_interp(&p->ip, p->pwr, bin[0], p->m, &only, nullptr));
    EXPECT_NE(-99.0, only);
    only = -99.0;
    EXPECT_EQ(DSP_OK, dsp_peak_interp(&p->ip, p->pwr, bin[0], p->m, nullptr, &only));
    EXPECT_NE(-99.0, only);
}

// Segmented arenas and source records

// Use independent segments in non-address order to catch adjacency assumptions.
class SegPlan {
  public:
    SegPlan(int n, int kind, size_t seg_bytes, int nsegs, double beta = 12.0, int decim = 1,
            int method = DSP_FFT_DEFAULT) {
        for (int i = 0; i < nsegs; i++) {
            blocks_.push_back(std::vector<unsigned char>(seg_bytes + DSP_ALIGN, 0));
        }

        for (int i = nsegs - 1; i >= 0; i--) {
            bases_.push_back(AlignUp(blocks_[static_cast<size_t>(i)].data()));
        }
        rc_ = dsp_plan_init_segs(&p_, reinterpret_cast<void *const *>(bases_.data()), nsegs,
                                 seg_bytes, n, kind, beta, decim, method);
        seg_bytes_ = seg_bytes;
    }
    int rc() const { return rc_; }
    dsp_plan *operator->() { return &p_; }
    dsp_plan &get() { return p_; }

    bool InOneSegment(const void *q, size_t bytes) const {
        const unsigned char *lo = static_cast<const unsigned char *>(q);
        for (size_t i = 0; i < bases_.size(); i++) {
            if (lo >= bases_[i] && lo + bytes <= bases_[i] + seg_bytes_)
                return true;
        }
        return false;
    }

  private:
    std::vector<std::vector<unsigned char>> blocks_;
    std::vector<unsigned char *> bases_;
    size_t seg_bytes_ = 0;
    dsp_plan p_{};
    int rc_ = DSP_EARG;
};

constexpr size_t kSeg = 32768;

// Find a size requiring multiple segments in the tested precision.
int NForSegs(int want, int method = DSP_FFT_DEFAULT) {
    const int nmax = static_cast<int>(kSeg / sizeof(dsp_real));
    for (int n = 64; n <= nmax; n *= 2) {
        const int segs = dsp_plan_segs(n, 1, method, kSeg);
        if (segs >= want)
            return n;
    }
    return 0;
}

TEST(Segments, CountIsPositiveAndSufficient) {
    for (int n : {64, 256, 512, 1024}) {
        int segs = dsp_plan_segs(n, 1, DSP_FFT_DEFAULT, kSeg);
        ASSERT_GT(segs, 0) << "n=" << n;

        SegPlan p(n, DSP_WINDOW_HANN, kSeg, segs);
        EXPECT_EQ(DSP_OK, p.rc()) << "n=" << n << " segs=" << segs;

        size_t flat = dsp_plan_bytes(n, 1, DSP_FFT_DEFAULT);
        EXPECT_GE(static_cast<size_t>(segs) * kSeg, flat) << "n=" << n;
    }
}

TEST(Segments, OneShortIsEnomem) {
    const int n = NForSegs(2);
    ASSERT_GT(n, 0) << "no n needs two segments at this precision; the bound is too tight";
    int segs = dsp_plan_segs(n, 1, DSP_FFT_DEFAULT, kSeg);
    ASSERT_GT(segs, 1);
    SegPlan p(n, DSP_WINDOW_HANN, kSeg, segs - 1);
    EXPECT_EQ(DSP_ENOMEM, p.rc());
    EXPECT_EQ(0, p->n) << "a refused plan must be left zeroed";
}

dsp_real VecAt(const dsp_vec &v, int i) {
    return v.tab[i >> v.sh][i & v.mask];
}

size_t SliceBytes(const dsp_vec &v, int s) {
    const int rest = v.len - s * v.per;
    const int take = (rest < v.per) ? rest : v.per;
    return take > 0 ? static_cast<size_t>(take) * sizeof(dsp_real) : 0u;
}

TEST(Segments, TheInstrumentsGeometryServesEveryCountTheApplicationOffers) {

    const size_t seg = 32768u - 32u;
    const int maxsegs = 32;
    const int counts[] = {512, 1024, 2048, 4096, 8192, 16384};
    for (size_t i = 0; i < sizeof(counts) / sizeof(counts[0]); i++) {
        const int n = counts[i];
        const int segs = dsp_plan_segs(n, 1, DSP_FFT_DEFAULT, seg);
        EXPECT_GT(segs, 0) << "n=" << n << " lays out in no number of segments";
        EXPECT_LE(segs, maxsegs) << "n=" << n << " needs " << segs
                                 << " segments against DSPN_MAX_SEGS " << maxsegs;
    }
}

// Compare strided and flat source records for each alignment produced by a 20-byte stride.
void ExpectStridedRecordMatchesArray(const int n, const int stride, const int per,
                                     const size_t base_off) {
    const int nblk = (n + per - 1) / per;
    ASSERT_LE(nblk, DSP_MAX_SRC_BLOCKS);

    std::vector<double> x(static_cast<size_t>(n));
    for (int i = 0; i < n; i++) {
        const double t = static_cast<double>(i);
        x[static_cast<size_t>(i)] = 0.8 * std::sin(2.0 * M_PI * 53.0 * t / n) +
                                   0.03 * std::sin(2.0 * M_PI * 211.0 * t / n) - 0.02;
    }

    std::vector<std::vector<unsigned char>> blocks;
    for (int b = 0; b < nblk; b++) {
        blocks.push_back(std::vector<unsigned char>(base_off + static_cast<size_t>(per) *
                                                                   static_cast<size_t>(stride),
                                                    0));
    }
    dsp_src src{};
    for (int b = 0; b < nblk; b++)
        src.blk[b] = blocks[static_cast<size_t>(b)].data() + base_off;
    src.nblock = nblk;
    src.per = per;
    src.stride = stride;
    src.len = n;
    for (int i = 0; i < n; i++) {
        unsigned char *q = blocks[static_cast<size_t>(i / per)].data() + base_off +
                           static_cast<size_t>(i % per) * static_cast<size_t>(stride);
        std::memcpy(q, &x[static_cast<size_t>(i)], sizeof(double));
    }

    Plan flat(n, DSP_WINDOW_HANN);
    ASSERT_EQ(DSP_OK, flat.rc());
    Plan strided(n, DSP_WINDOW_HANN);
    ASSERT_EQ(DSP_OK, strided.rc());
    double mean_a = 0.0, mean_b = 0.0;
    ASSERT_GT(dsp_spectrum_run(&flat.get(), x.data(), n, &mean_a), 0);
    ASSERT_GT(dsp_spectrum_run_src(&strided.get(), &src, n, &mean_b), 0);
    EXPECT_EQ(mean_a, mean_b);
    for (int k = 0; k < flat->m; k++)
        ASSERT_EQ(flat->pwr[k], strided->pwr[k]) << "bin " << k;
}

TEST(Source, AStridedMultiBlockRecordMatchesTheSameSamplesAsAnArray) {

    ExpectStridedRecordMatchesArray(1024, 24, 65, 0u);
}

TEST(Source, AFourAlignedElementIsReadAsTwoWordsAndStillMatches) {

    ExpectStridedRecordMatchesArray(1024, 20, 65, 0u);
    ExpectStridedRecordMatchesArray(1024, 20, 65, 4u);

    ExpectStridedRecordMatchesArray(512, 12, 33, 0u);
    ExpectStridedRecordMatchesArray(512, 28, 33, 4u);
}

TEST(Source, AStrideShorterThanADoubleIsRefused) {

    const int n = 512;
    const unsigned short_strides[] = {4u};
    for (size_t s = 0; s < sizeof(short_strides) / sizeof(short_strides[0]); s++) {
        std::vector<unsigned char> raw(static_cast<size_t>(n) * short_strides[s], 0);
        dsp_src src{};
        src.blk[0] = raw.data();
        src.nblock = 1;
        src.per = n;
        src.stride = static_cast<int>(short_strides[s]);
        src.len = n;
        Plan p(n, DSP_WINDOW_HANN);
        ASSERT_EQ(DSP_OK, p.rc());
        double mean = 0.0;
        EXPECT_EQ(DSP_EARG, dsp_spectrum_run_src(&p.get(), &src, n, &mean))
            << "stride " << short_strides[s];
    }
}

TEST(Source, ANegativeStrideIsRefused) {

    const int n = 64;
    std::vector<unsigned char> raw(static_cast<size_t>(n) * 8u, 0);
    dsp_src src{};
    src.blk[0] = raw.data();
    src.nblock = 1;
    src.per = n;
    src.stride = -4;
    src.len = n;
    Plan p(n, DSP_WINDOW_HANN);
    ASSERT_EQ(DSP_OK, p.rc());
    double mean = 0.0;
    EXPECT_EQ(DSP_EARG, dsp_spectrum_run_src(&p.get(), &src, n, &mean));
}

TEST(Source, BlocksThatDoNotReachTheRecordLengthAreRefused) {

    const int n = 1024;
    std::vector<unsigned char> raw(4096u, 0);
    dsp_src src{};
    src.blk[0] = raw.data();
    src.blk[1] = raw.data();
    src.nblock = 2;
    src.per = 10;
    src.stride = 8;
    src.len = n;
    Plan p(n, DSP_WINDOW_HANN);
    ASSERT_EQ(DSP_OK, p.rc());
    double mean = 0.0;
    EXPECT_EQ(DSP_EARG, dsp_spectrum_run_src(&p.get(), &src, n, &mean));
}

TEST(Source, AStrideFinerThanAWordIsRefused) {

    const int n = 64;
    const unsigned strides[] = {9u, 10u, 14u};
    for (size_t s = 0; s < sizeof(strides) / sizeof(strides[0]); s++) {
        std::vector<unsigned char> raw(static_cast<size_t>(n) * strides[s] + 8u, 0);
        dsp_src src{};
        src.blk[0] = raw.data();
        src.nblock = 1;
        src.per = n;
        src.stride = static_cast<int>(strides[s]);
        src.len = n;
        Plan p(n, DSP_WINDOW_HANN);
        ASSERT_EQ(DSP_OK, p.rc());
        double mean = 0.0;
        EXPECT_EQ(DSP_EARG, dsp_spectrum_run_src(&p.get(), &src, n, &mean))
            << "stride " << strides[s];
    }
}

TEST(Segments, AnArrayLongerThanASegmentIsSplitRatherThanRefused) {

    const int at_limit = static_cast<int>(kSeg / sizeof(dsp_real));
    const int over = at_limit * 2;

    EXPECT_GT(dsp_plan_segs(at_limit, 1, DSP_FFT_DEFAULT, kSeg), 0)
        << "n = seg_bytes/sizeof(dsp_real) must still lay out";
    const int segs = dsp_plan_segs(over, 1, DSP_FFT_DEFAULT, kSeg);
    ASSERT_GT(segs, 0) << "an array longer than a segment is sliced, not refused";

    SegPlan p(over, DSP_WINDOW_HANN, kSeg, segs);
    ASSERT_EQ(DSP_OK, p.rc());
    EXPECT_GT(p->w_v.nslice, 1) << "the window is the array that had to split";
    EXPECT_EQ(over, p->w_v.len);

    EXPECT_EQ(0, p->w_v.per & (p->w_v.per - 1)) << "per must be a power of two";
    EXPECT_GE(p->re_v.per, p->m2) << "a row of m2 has to lie inside one slice";
    EXPECT_GE(p->re_v.per, p->m1) << "a row of m1 has to lie inside one slice";
    EXPECT_GE(p->re_v.per, DSP_FS_BLOCK);
    EXPECT_EQ(p->w_v.per - 1, p->w_v.mask);
    EXPECT_EQ(1 << p->w_v.sh, p->w_v.per);
}

TEST(Segments, EverySliceOfASplitArrayLiesWhollyInOneSegment) {
    const int over = static_cast<int>(kSeg / sizeof(dsp_real)) * 2;
    const int segs = dsp_plan_segs(over, 1, DSP_FFT_DEFAULT, kSeg);
    ASSERT_GT(segs, 0);
    SegPlan p(over, DSP_WINDOW_HANN, kSeg, segs);
    ASSERT_EQ(DSP_OK, p.rc());
    const dsp_vec *all[] = {&p->w_v,  &p->twr_v, &p->twi_v, &p->utr_v, &p->uti_v,
                            &p->re_v, &p->im_v,  &p->wkr_v, &p->wki_v, &p->pwr_v};
    const char *names[] = {"w", "twr", "twi", "utr", "uti", "re", "im", "wkr", "wki", "pwr"};
    for (size_t a = 0; a < sizeof(all) / sizeof(all[0]); a++) {
        for (int sl = 0; sl < all[a]->nslice; sl++) {
            EXPECT_TRUE(p.InOneSegment(all[a]->tab[sl], SliceBytes(*all[a], sl)))
                << names[a] << " slice " << sl;
        }
        for (int sl = all[a]->nslice; sl < DSP_MAX_SLICES; sl++) {
            EXPECT_EQ(nullptr, all[a]->tab[sl]) << names[a] << " slice " << sl;
        }
    }
}

TEST(Segments, RadixTwoIsRefusedAnArenaThatSplitsItsWorkingArrays) {

    const int n = static_cast<int>(kSeg / sizeof(dsp_real)) * 4;
    if (n > DSP_N_MAX)
        GTEST_SKIP() << "the precision's m-array fits a segment at every legal n";
    SegPlan p(n, DSP_WINDOW_HANN, kSeg, 64, 12.0, 1, DSP_FFT_RADIX2);
    EXPECT_EQ(DSP_ESEG, p.rc());
    EXPECT_EQ(0, p->n) << "a refused plan must be left zeroed";
}

TEST(Segments, ASplitArenaGivesBitIdenticalResultsToAContiguousOne) {

    const int n = static_cast<int>(kSeg / sizeof(dsp_real)) * 2;
    const int segs = dsp_plan_segs(n, 1, DSP_FFT_DEFAULT, kSeg);
    ASSERT_GT(segs, 0);
    Plan flat(n, DSP_WINDOW_HANN);
    ASSERT_EQ(DSP_OK, flat.rc()) << "the contiguous reference must build";
    SegPlan split(n, DSP_WINDOW_HANN, kSeg, segs);
    ASSERT_EQ(DSP_OK, split.rc());
    ASSERT_GT(split->w_v.nslice, 1) << "nothing split, so this proves nothing";

    std::vector<double> x(static_cast<size_t>(n));
    for (int i = 0; i < n; i++) {
        const double t = static_cast<double>(i);
        x[static_cast<size_t>(i)] = 0.9 * std::sin(2.0 * M_PI * 37.0 * t / n) +
                                   0.05 * std::sin(2.0 * M_PI * 311.0 * t / n) + 0.01;
    }
    double mean_a = 0.0, mean_b = 0.0;
    ASSERT_GT(dsp_spectrum_run(&flat.get(), x.data(), n, &mean_a), 0);
    ASSERT_GT(dsp_spectrum_run(&split.get(), x.data(), n, &mean_b), 0);
    EXPECT_EQ(mean_a, mean_b);

    const int m = flat->m;
    ASSERT_EQ(m, split->m);
    int differing = 0, first = -1;
    for (int k = 0; k < m; k++) {
        if (VecAt(split->pwr_v, k) != flat->pwr[k]) {
            if (first < 0)
                first = k;
            differing++;
        }
    }
    EXPECT_EQ(0, differing) << differing << " bins differ, first at " << first;

    for (int i = 0; i < n; i++) {
        ASSERT_EQ(flat->w[i], VecAt(split->w_v, i)) << "window entry " << i;
    }
}

TEST(Segments, EveryArrayLiesWhollyInOneSegment) {
    const int n = 512;
    int segs = dsp_plan_segs(n, 1, DSP_FFT_RADIX2, kSeg);
    ASSERT_GT(segs, 0);
    SegPlan p(n, DSP_WINDOW_HANN, kSeg, segs, 12.0, 1, DSP_FFT_RADIX2);
    ASSERT_EQ(DSP_OK, p.rc());
    const int m = p->m;

    EXPECT_TRUE(p.InOneSegment(p->w, static_cast<size_t>(n) * sizeof(dsp_real))) << "w";
    EXPECT_TRUE(p.InOneSegment(p->twr, static_cast<size_t>(m - 2) * sizeof(dsp_real))) << "twr";
    EXPECT_TRUE(p.InOneSegment(p->twi, static_cast<size_t>(m - 2) * sizeof(dsp_real))) << "twi";
    EXPECT_TRUE(p.InOneSegment(p->utr, static_cast<size_t>(m) * sizeof(dsp_real))) << "utr";
    EXPECT_TRUE(p.InOneSegment(p->uti, static_cast<size_t>(m) * sizeof(dsp_real))) << "uti";
    EXPECT_TRUE(p.InOneSegment(p->re, static_cast<size_t>(m) * sizeof(dsp_real))) << "re";
    EXPECT_TRUE(p.InOneSegment(p->im, static_cast<size_t>(m) * sizeof(dsp_real))) << "im";
    EXPECT_TRUE(p.InOneSegment(p->pwr, static_cast<size_t>(m) * sizeof(dsp_real))) << "pwr";
    EXPECT_TRUE(p.InOneSegment(p->h, DSP_FIR_MAXTAPS * sizeof(dsp_real))) << "h";
    EXPECT_TRUE(p.InOneSegment(p->swp_a, static_cast<size_t>(m / 2) * sizeof(int))) << "swp_a";
    EXPECT_TRUE(p.InOneSegment(p->swp_b, static_cast<size_t>(m / 2) * sizeof(int))) << "swp_b";
}

TEST(Segments, EveryArrayIsAligned) {
    const int n = 512;
    int segs = dsp_plan_segs(n, 1, DSP_FFT_DEFAULT, kSeg);
    ASSERT_GT(segs, 0);
    SegPlan p(n, DSP_WINDOW_HANN, kSeg, segs);
    ASSERT_EQ(DSP_OK, p.rc());
    const void *arrays[] = {p->w, p->twr, p->twi, p->utr, p->uti, p->re, p->im, p->pwr, p->h};
    for (const void *q : arrays) {
        EXPECT_EQ(0u, reinterpret_cast<uintptr_t>(q) & (DSP_ALIGN - 1));
    }
}

// Changing arena placement must not change the spectrum bit for bit.
TEST(Segments, SpectrumIsBitIdenticalToAFlatArena) {
    for (int method : {DSP_FFT_RADIX2, DSP_FFT_FOURSTEP}) {
        for (int n : {64, 256, 512}) {
            const int segs = dsp_plan_segs(n, 1, method, kSeg);
            ASSERT_GT(segs, 0) << "n=" << n;

            Plan flat(n, DSP_WINDOW_BLACKMAN_HARRIS, 12.0, 1, method);
            ASSERT_EQ(DSP_OK, flat.rc());
            SegPlan seg(n, DSP_WINDOW_BLACKMAN_HARRIS, kSeg, segs, 12.0, 1, method);
            ASSERT_EQ(DSP_OK, seg.rc());
            ASSERT_EQ(flat->method, seg->method) << "both must resolve the same decomposition";

            std::vector<double> x(static_cast<size_t>(n));
            for (int i = 0; i < n; i++) {
                const double t = static_cast<double>(i);
                x[static_cast<size_t>(i)] = 0.75 + std::sin(2.0 * M_PI * 5.25 * t / n) +
                                            0.3 * std::sin(2.0 * M_PI * 19.0 * t / n + 0.4);
            }

            double mean_flat = 0.0, mean_seg = 0.0;
            ASSERT_EQ(flat->m, dsp_spectrum_run(&flat.get(), x.data(), n, &mean_flat));
            ASSERT_EQ(seg->m, dsp_spectrum_run(&seg.get(), x.data(), n, &mean_seg));

            EXPECT_EQ(mean_flat, mean_seg) << "n=" << n << " method=" << method;
            for (int k = 0; k < flat->m; k++) {
                ASSERT_EQ(flat->pwr[k], seg->pwr[k])
                    << "bin " << k << " differs, n=" << n << " method=" << method;
            }

            for (int i = 0; i < n; i++) {
                ASSERT_EQ(flat->w[i], seg->w[i]) << "window " << i << " differs, n=" << n;
            }
        }
    }
}

TEST(Segments, RefusesTheArgumentsItShould) {
    const int n = 256;
    const int segs = dsp_plan_segs(n, 1, DSP_FFT_DEFAULT, kSeg);
    ASSERT_GT(segs, 0);
    std::vector<unsigned char> block(kSeg + DSP_ALIGN, 0);
    unsigned char *base = AlignUp(block.data());
    void *one[2] = {base, base};
    dsp_plan p{};

    EXPECT_EQ(DSP_EARG, dsp_plan_init_segs(&p, one, 1, 0u, n, DSP_WINDOW_HANN, 12.0, 1,
                                           DSP_FFT_DEFAULT));
    EXPECT_EQ(0, p.n) << "and the plan is still zeroed on that path";

    EXPECT_EQ(DSP_EARG, dsp_plan_init_segs(&p, one, 1, kSeg + 1, n, DSP_WINDOW_HANN, 12.0, 1,
                                           DSP_FFT_DEFAULT));
    EXPECT_EQ(DSP_EARG, dsp_plan_init_segs(&p, one, 1, DSP_ALIGN / 2, n, DSP_WINDOW_HANN, 12.0,
                                           1, DSP_FFT_DEFAULT));

    EXPECT_EQ(DSP_EARG,
              dsp_plan_init_segs(&p, one, 0, kSeg, n, DSP_WINDOW_HANN, 12.0, 1, DSP_FFT_DEFAULT));
    EXPECT_EQ(DSP_EARG, dsp_plan_init_segs(&p, nullptr, 1, kSeg, n, DSP_WINDOW_HANN, 12.0, 1,
                                           DSP_FFT_DEFAULT));
    void *with_null[2] = {base, nullptr};
    EXPECT_EQ(DSP_EARG, dsp_plan_init_segs(&p, with_null, 2, kSeg, n, DSP_WINDOW_HANN, 12.0, 1,
                                           DSP_FFT_DEFAULT));

    EXPECT_EQ(DSP_EARG, dsp_plan_init_segs(nullptr, one, 1, kSeg, n, DSP_WINDOW_HANN, 12.0, 1,
                                           DSP_FFT_DEFAULT));

    EXPECT_EQ(0, dsp_plan_segs(n, 1, DSP_FFT_DEFAULT, 0u));
    EXPECT_EQ(0, dsp_plan_segs(n, 1, DSP_FFT_DEFAULT, kSeg + 1));
    EXPECT_EQ(0, dsp_plan_segs(n + 1, 1, DSP_FFT_DEFAULT, kSeg)) << "n not a power of two";
}

TEST(Segments, MisalignedSegmentIsEalign) {
    const int n = 256;
    const int segs = dsp_plan_segs(n, 1, DSP_FFT_DEFAULT, kSeg);
    ASSERT_GT(segs, 0);

    std::vector<unsigned char> block(kSeg * static_cast<size_t>(segs) + 2 * DSP_ALIGN, 0);
    unsigned char *base = AlignUp(block.data());
    std::vector<void *> bases;
    for (int i = 0; i < segs; i++)
        bases.push_back(base + static_cast<size_t>(i) * kSeg);
    dsp_plan p{};
    ASSERT_EQ(DSP_OK, dsp_plan_init_segs(&p, bases.data(), segs, kSeg, n, DSP_WINDOW_HANN, 12.0,
                                         1, DSP_FFT_DEFAULT));

    bases[static_cast<size_t>(segs - 1)] =
        static_cast<unsigned char *>(bases[static_cast<size_t>(segs - 1)]) + 1;
    EXPECT_EQ(DSP_EALIGN, dsp_plan_init_segs(&p, bases.data(), segs, kSeg, n, DSP_WINDOW_HANN,
                                             12.0, 1, DSP_FFT_DEFAULT));
}

#if DSP_CHECK_OVERLAP
TEST(Segments, PlanInsideAnySegmentIsRefused) {
    const int n = NForSegs(2);
    ASSERT_GT(n, 0) << "no n needs two segments at this precision";
    const int segs = dsp_plan_segs(n, 1, DSP_FFT_DEFAULT, kSeg);
    ASSERT_GT(segs, 1);
    std::vector<std::vector<unsigned char>> blocks;
    for (int i = 0; i < segs; i++)
        blocks.push_back(std::vector<unsigned char>(kSeg + DSP_ALIGN, 0));
    std::vector<void *> bases;
    for (int i = 0; i < segs; i++)
        bases.push_back(AlignUp(blocks[static_cast<size_t>(i)].data()));

    void *last = bases[static_cast<size_t>(segs - 1)];
    dsp_plan *inside = static_cast<dsp_plan *>(last);
    EXPECT_EQ(DSP_EARG, dsp_plan_init_segs(inside, bases.data(), segs, kSeg, n, DSP_WINDOW_HANN,
                                           12.0, 1, DSP_FFT_DEFAULT));
}
#endif

TEST(Segments, PaddingIsTheOnlyCost) {

    for (int n : {64, 256, 512, 1024}) {
        const size_t flat = dsp_plan_bytes(n, 1, DSP_FFT_DEFAULT);
        const int segs = dsp_plan_segs(n, 1, DSP_FFT_DEFAULT, kSeg);
        ASSERT_GT(segs, 0) << "n=" << n;
        const size_t given = static_cast<size_t>(segs) * kSeg;
        ASSERT_GE(given, flat) << "n=" << n;

        EXPECT_LT(given - flat, kSeg + flat) << "n=" << n << ": padding is out of proportion";
    }
}

} // namespace
