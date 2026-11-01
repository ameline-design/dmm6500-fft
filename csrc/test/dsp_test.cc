// dsp_test.cc -- numerical tests for csrc/dsp.c, ported from tools/test_tsp.lua.
//
// The bounds here are the Lua suite's bounds, not bounds fitted to this code. Where a
// bound is precision-dependent it is derived from the floating-point error, scaled off
// sizeof(dsp_real), and the derivation is in a comment next to it; everything else is
// identical in the single- and double-precision builds. Tests that assert an identity --
// coherent gain, window symmetry, G(0) == 1, a decimating run against a non-decimating
// one -- hold exactly in both.
//
// Several tests carry their own negative control, because the Lua suite's experience is
// that a numerical bound nothing can fail is worth nothing: the DFT comparison perturbs a
// bin, the pedestal test re-runs with an arithmetic mean, the segment reduction re-runs as
// a mean, the filter re-runs with its cutoff on the stop and the window sweep runs one
// window's data through another window's tables.

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

// A NaN and an infinity, from <limits> rather than from 0.0/0.0: the division is what
// -fsanitize=float-divide-by-zero flags, and the sanitizer build is a gate this suite runs
// under. Hostile.TheTestValuesAreWhatTheyClaimToBe checks the bit patterns of the quiet and
// signalling NaNs used by the hostile-input tests.
const double kNaN = std::numeric_limits<double>::quiet_NaN();
const double kInf = std::numeric_limits<double>::infinity();

// ---------------------------------------------------------------------------
// precision-dependent bounds
// ---------------------------------------------------------------------------
//
// A radix-2 FFT of M points accumulates an error of order eps*log2(M)*||x|| on each bin's
// complex value, where eps is the unit roundoff: 1.19e-7 for float, 2.2e-16 for double.
// That bound does not shrink for a small bin, so a bin in the noise floor cannot be
// compared relatively at all -- which is why every bin-for-bin comparison below uses a
// mixed allowance,
//
//     allow = rel * reference + absfs * (the largest bin in the spectrum)
//
// and asserts the error as a fraction of it. The absolute half is a spur-free-range
// statement, which is the physically meaningful one here and is directly comparable with
// the instrument's own figure: the 10 V range at 1 MS/s is specified at 95, 80 and 70 dB
// spur-free at 1, 10 and 50 kHz. Both halves are reported as measured figures by the
// tests, so a reviewer sees the margin rather than the bound.
// The absolute half is set from the worst floor measured across the stimulus family the
// suite uses -- one, two and three tones, with and without a pedestal, at n from 64 to
// 32768 -- with about 10 dB of margin, not from any single case. Single reaches -103.0 dB
// of full scale at its worst (two tones on a pedestal at n = 64) against the -93 dB bound;
// double reaches -184.9 dB against -170. The figure comes from the family rather than from
// one measurement: a bound fitted to the single-tone case alone sits at 3e-11, and a
// two-tone record walks straight through it. Every test using these prints both halves.
constexpr double kDftRel = kSingle ? 1e-5 : 1e-9;
constexpr double kDftAbsFs = kSingle ? 5e-10 : 1e-17;
constexpr double kPinnedRel = kSingle ? 3e-6 : 1e-9;
constexpr double kPinnedAbsFs = kSingle ? 5e-12 : 1e-18;

// Coherent gain and the power scale both come from the sum of the stored window, so
// neither is exact. In the single build the dominant term is the rounding of the n window
// samples themselves, a random walk of sqrt(n)*eps*w/2 on the sum, which is 5e-10 on cg at
// n = 4096 against a measured 3.7e-10; in double the samples are stored as computed and
// the term is the accumulation, 3.4e-15 predicted against a measured 1.2e-15. The cost on
// a reported amplitude in single is 2e-8 relative, or 1.7e-7 dB.
constexpr double kCgAbs = kSingle ? 1e-8 : 1e-14;
constexpr double kKsqRel = kSingle ? 2e-8 : 6.6e-15;

// What is left in bin 0 after the window-weighted mean removes a 1.0 V pedestal. In double
// the cancellation is exact and only rounding survives (the Lua measures 1.03e-31 and
// gates at 1e-20). In single each windowed difference rounds with an error of about
// eps/2 * 0.5, and 512 of them accumulate to 4e-7 on the bin's complex value, so the power
// lands near 4*ksq*(4e-7)^2 = 9e-18; the measurement is 1.4e-17. Both gates sit far below
// the 6.5e-07 an arithmetic mean leaves, which the test measures rather than quotes.
constexpr double kPedestal = kSingle ? 1e-15 : 1e-20;

// ---------------------------------------------------------------------------
// fixtures and helpers
// ---------------------------------------------------------------------------

// Round a pointer up to DSP_ALIGN. The default allocator guarantees 16 bytes on this host
// and the plan wants 32, so every arena here is over-allocated and rounded.
unsigned char *AlignUp(unsigned char *p) {
    while ((reinterpret_cast<uintptr_t>(p) & (DSP_ALIGN - 1)) != 0)
        p++;
    return p;
}

// A plan plus the arena it was carved from. The arena is sized for one decomposition, so the
// method is a construction parameter rather than something set afterwards.
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

// An undecimated spectrum's bin-to-hertz map: bin k is k*binhz. Most tests use this, so they
// call through the wrapper and read as they did before dsp_reduce took a map.
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

// The nine window configurations the Lua suite sweeps: three cosine windows and Kaiser at
// each of the six betas on its list.
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

// One frame against a plain array: load, transform, power. Returns the bin count.
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

// A unit-amplitude tone at a fractional bin position, the stimulus the Lua sweep uses.
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

// ---------------------------------------------------------------------------
// windows
// ---------------------------------------------------------------------------

TEST(Window, HannCoherentGainIsTheExactWindowMean) {
    // sum(0.5 - 0.5*cos(2*pi*i/(n-1))) over i = 0..n-1 is (n-1)/2 exactly: the first n-1
    // cosines are a whole period and sum to zero, and the last one is 1. So cg is
    // (n-1)/(2n) for every n, which is 511/1024 at n = 512 -- the value the Lua suite pins.
    double worst = 0.0;
    for (int n : {64, 128, 512, 1024, 4096}) {
        Plan p(n, DSP_WINDOW_HANN);
        ASSERT_EQ(DSP_OK, p.rc()) << "n=" << n;
        EXPECT_NEAR(p->cg, (double)(n - 1) / (2.0 * n), kCgAbs) << "n=" << n;
        worst = std::max(worst, std::fabs(p->cg - (double)(n - 1) / (2.0 * n)));
    }
    Plan p512(512, DSP_WINDOW_HANN);
    // Not bit-exact even in double: cg is a sum of 512 window samples divided by n, so the
    // last bit is accumulation error. The Lua measures 0.4990234374999999 and allows 1e-15,
    // which is kept here for the double build; in single this bin is 1.03e-9 out.
    EXPECT_NEAR(p512->cg, 511.0 / 1024.0, kSingle ? kCgAbs : 1e-15) << "cg = " << p512->cg;
    std::printf("[window] coherent gain: worst departure from (n-1)/2n is %.3e (bound %.0e)\n",
                worst, kCgAbs);
}

TEST(Window, PowerScaleConstantIsUnchanged) {
    // Pins the one constant a silent change to would shift every bin by the same factor,
    // and so be invisible to any self-consistent comparison. ksq is 1/wsum^2, so its
    // relative error is twice the window sum's.
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
    // The first null sits at sqrt(1 + (beta/pi)^2) bins and has to stay outside 1.5 bins or
    // the three-bin ratio reads a sidelobe. That puts the floor at 3.5124; the Lua ships a
    // list whose lowest entry is 4 for the same reason.
    std::vector<dsp_real> w(512);
    EXPECT_EQ(DSP_EBETA, dsp_window(w.data(), 512, DSP_WINDOW_KAISER, 3.0));
    EXPECT_EQ(DSP_EBETA, dsp_window(w.data(), 512, DSP_WINDOW_KAISER, 0.0));
    EXPECT_EQ(DSP_EBETA, dsp_window(w.data(), 512, DSP_WINDOW_KAISER, 3.5));
    EXPECT_EQ(DSP_OK, dsp_window(w.data(), 512, DSP_WINDOW_KAISER, 4.0));
    Plan bad(512, DSP_WINDOW_KAISER, 2.0);
    EXPECT_EQ(DSP_EBETA, bad.rc());
    EXPECT_EQ(0, bad->n) << "a refused plan must not look half-built";
}

// I0 by its integral representation, I0(x) = (1/pi) * integral of exp(x*cos t) over
// 0..pi, by Simpson. Independent of the power series dsp.c uses, which is the point: a
// wrong term ratio or a wrong early-exit in that series would agree with itself.
double BesselI0Quadrature(double x) {
    const int n = 200000; // even
    double h = M_PI / n, s = std::exp(x) + std::exp(-x);
    for (int i = 1; i < n; i++)
        s += (i & 1 ? 4.0 : 2.0) * std::exp(x * std::cos(i * h));
    return s * h / 3.0 / M_PI;
}

TEST(Window, BesselSeriesMatchesAnIndependentQuadrature) {
    // I0 is not exported, so it is measured through the window it builds: with n odd the
    // centre sample is I0(beta)/I0(beta) = 1 exactly, and the end samples are
    // I0(0)/I0(beta) = 1/I0(beta).
    for (double beta : {4.0, 6.0, 9.0, 12.0, 15.0, 18.0}) {
        std::vector<dsp_real> w(1025);
        ASSERT_EQ(DSP_OK, dsp_window(w.data(), 1025, DSP_WINDOW_KAISER, beta)) << beta;
        double want = 1.0 / BesselI0Quadrature(beta);
        EXPECT_NEAR((double)w[512], 1.0, 1e-7) << "beta=" << beta;
        // Single precision holds 1/I0(18) = 1.6e-7 to seven figures, so the bound is the
        // array's rounding and not the series'.
        EXPECT_NEAR((double)w[0] / want, 1.0, kSingle ? 2e-6 : 1e-9)
            << "beta=" << beta << ": 1/I0 = " << (double)w[0] << ", quadrature " << want;
    }
}

TEST(Window, GainIsEvenAndUnityAtZero) {
    for (const WinCfg &c : ShippedWindows()) {
        Plan p(512, c.kind, c.beta);
        ASSERT_EQ(DSP_OK, p.rc()) << c.label();
        // A tone exactly on a bin needs no amplitude correction.
        EXPECT_NEAR(dsp_win_gain(&p->ip, 0.0), 1.0, 1e-12) << c.label();
        for (double d : {0.01, 0.1, 0.25, 0.4999, 0.9, 1.4}) {
            EXPECT_EQ(dsp_win_gain(&p->ip, d), dsp_win_gain(&p->ip, -d)) << c.label() << " d=" << d;
        }
        // Monotonically decreasing across the main lobe, and below 1 off a bin centre.
        EXPECT_LT(dsp_win_gain(&p->ip, 0.5), 1.0) << c.label();
        EXPECT_LT(dsp_win_gain(&p->ip, 0.5), dsp_win_gain(&p->ip, 0.25)) << c.label();
    }
}

TEST(Window, TheGainTableIsNonNegativeForEveryWindowKind) {
    // G is a magnitude, so the gain table holds the absolute value of the window's
    // transform. For the shipped windows that absolute value is a no-op -- the main lobe
    // reaches past 1.5 bins for all of them -- so the only window it is observable through
    // is RECT, whose first null sits at one bin and whose transform is negative from there
    // to two bins. A negative table entry would make dsp_win_gain return a negative
    // scalloping factor and dsp_peak_interp divide an amplitude by it.
    double most_negative_without_abs = 0.0;
    for (int kind = 0; kind < DSP_WINDOW_COUNT; kind++) {
        Plan p(512, kind, 12.0);
        ASSERT_EQ(DSP_OK, p.rc()) << WindowName(kind);
        for (int j = 0; j <= DSP_GN; j++)
            ASSERT_GE(p->ip.gtab[j], 0.0) << WindowName(kind) << " at " << (j * DSP_GHX) << " bins";
        // The same sum without the absolute value, to show the test is not vacuous: rebuilt
        // here from the window because dsp.c does not expose the signed form.
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
    // Past the end of the table the three bins are not one tone, so the offset saturates.
    ASSERT_EQ(DSP_OK, dsp_win_offset(&p->ip, 10.0, &d));
    EXPECT_DOUBLE_EQ(0.5, d);
    ASSERT_EQ(DSP_OK, dsp_win_offset(&p->ip, -10.0, &d));
    EXPECT_DOUBLE_EQ(-0.5, d);
}

TEST(Window, EveryShippedWindowHasAnInvertibleOffsetTable) {
    // r(d) must rise all the way to half a bin, or the offset is not invertible and the
    // window has no business being on the list.
    for (const WinCfg &c : ShippedWindows()) {
        Plan p(512, c.kind, c.beta);
        ASSERT_EQ(DSP_OK, p.rc()) << c.label();
        EXPECT_EQ(1, p->mono) << c.label() << ": r(d) is not monotonic to half a bin";
        EXPECT_GT(p->ip.dhr, 0.0) << c.label();
    }
}

TEST(Window, NoSelectableWindowFailsTheMonotonicityCheck) {
    // Swept rather than spot-checked, because the result decides whether the `mono == 0`
    // branch in dsp.c is ever taken: every window kind, every Kaiser beta above the floor in
    // fine steps, every count from 8 to 4096. Nothing reachable fails it, so that branch and
    // dsp_win_offset's DSP_EDECLINE are a guard against a window nobody can select -- the
    // test below drives the guard directly instead.
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
    // The guard the sweep above shows nothing reaches. Driven directly, because a branch
    // that no input takes is still a branch a future window would take.
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
    // And a peak search with no table still reports the bin, falling back to the raw value.
    int bin[2];
    dsp_real frac[2], a[2];
    int found = dsp_peaks(pwr.data(), 64, 1, 62, 1, 2, &ip, bin, frac, a);
    ASSERT_GE(found, 1);
    EXPECT_EQ(20, bin[0]);
    EXPECT_EQ((dsp_real)0, frac[0]);
    EXPECT_NEAR((double)a[0], std::sqrt(0.5), 1e-6);
}

TEST(Window, MonotonicityIsNotEnoughToQualifyAWindow) {
    // RECT passes the monotonicity check -- r(d) does rise to half a bin -- and is still
    // five orders worse at recovering an offset, because its gain reaches exactly zero one
    // bin from the peak and so r(d) leaves the origin as d^2 rather than as d. Asserted
    // because `mono` reads like a sufficient condition and is not one.
    Plan rect(512, DSP_WINDOW_RECT);
    ASSERT_EQ(DSP_OK, rect.rc());
    EXPECT_EQ(1, rect->mono);
    const int one = (int)(1.0 / DSP_GHX + 0.5);
    EXPECT_NEAR(rect->ip.gtab[one], 0.0, 1e-6) << "RECT's first null must sit at one bin";
    // No shipped window may have a null inside 1.5 bins, which is the whole of the range the
    // three-bin ratio reads. Kaiser beta 4 is the closest: its first null sits at
    // sqrt(1 + (4/pi)^2) = 1.62 bins, which is what puts the beta floor at 3.5124.
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
    // And the DC region is empty for RECT, since for a flat window the weighted mean is the
    // arithmetic mean and spreads nothing.
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

// ---------------------------------------------------------------------------
// the plan and its arena
// ---------------------------------------------------------------------------

TEST(Plan, BytesMatchesWhatInitNeeds) {
    for (int n : {4, 64, 512, 16384}) {
        for (int decim : {1, 4}) {
            for (int method = 0; method < DSP_FFT_COUNT; method++) {
                size_t want = dsp_plan_bytes(n, decim, method);
                ASSERT_GT(want, 0u) << "n=" << n;
                std::vector<unsigned char> raw(want + DSP_ALIGN, 0);
                unsigned char *arena = AlignUp(raw.data());
                dsp_plan p{};
                // Exactly what it asked for is enough.
                EXPECT_EQ(DSP_OK,
                          dsp_plan_init(&p, arena, want, n, DSP_WINDOW_HANN, 0, decim, method))
                    << "n=" << n << " decim=" << decim << " " << MethodName(method);
                // One byte less is not.
                EXPECT_EQ(DSP_ENOMEM,
                          dsp_plan_init(&p, arena, want - 1, n, DSP_WINDOW_HANN, 0, decim, method))
                    << "n=" << n << " decim=" << decim << " " << MethodName(method);
            }
        }
    }
    // The figures the proposal quotes, printed so a reviewer has them without a build.
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
    // The arena holds what its own method reads. The two extras are disjoint -- radix-2 a swap
    // list over m, the four-step an m-point intermediate matrix plus a gather block and two
    // smaller swap lists -- so the saving is real rather than a rounding artefact, and it is
    // the premise behind the footprint the proposal quotes.
    const int n = 16384;
    const int m = n / 2;
    size_t r2 = dsp_plan_bytes(n, 1, DSP_FFT_RADIX2);
    size_t fs = dsp_plan_bytes(n, 1, DSP_FFT_FOURSTEP);
    ASSERT_GT(r2, 0u);
    EXPECT_LT(r2, fs) << "radix-2 is in place, so it carries no second complex array";
    // The swap list radix-2 carries and the four-step does not, exactly.
    size_t swap = 2u * (size_t)(m / 2) * sizeof(int);
    EXPECT_EQ(swap, 32768u) << "16 kB each at n=16384, which is what sizing for both cost";
    // The figures the proposal quotes are the four-step arena, so the union would be 32 kB
    // above them. Asserted rather than described, because the document's 358 kB at n=16384
    // and 715 kB at n=32768 are only reproducible from a one-decomposition walk.
    std::printf("[ plan ] n=16384 %s: radix-2 %zu, four-step %zu (%.1f kB), union would be %zu\n",
                kSingle ? "single" : "double", r2, fs, (double)fs / 1024.0, fs + swap);
    // Pinned, because these are the numbers a reader outside this repository is quoted and
    // there is no other way to notice one drifting. The swap list is `int` either way, so the
    // 32 kB is the same figure in both precisions.
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
    // A NULL here is an array the plan did not pay for, and dsp_rfft reads the method off
    // these pointers, so which ones are set is the dispatch and not just bookkeeping.
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

    // Every plan has the arrays every decomposition needs.
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
    // The field is reachable, and a kernel must never be handed a buffer that is NULL. The
    // transform is read off the arena, so every value of the field gives the same bins.
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
    // Without the ceiling the layout walk wrapped a 32-bit size_t: at n = 2^30 the arrays
    // total 25,771,050,624 bytes and dsp_plan_bytes reported 1,246,848, so a 1.2 MB arena was
    // accepted for a plan that writes 25 GB. Powers of two only, so this is the ceiling doing
    // the refusing and not the power-of-two test.
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
    // And the ceiling itself is accepted, so the bound is not one size too tight.
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
    // Every offset inside a cache block is refused, not just an odd address: the four-step's
    // gather block has to start on a block boundary for its eight columns to be one fill.
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
    // The arena is large enough here, so these are the window refusals and not size ones.
    EXPECT_EQ(DSP_EBETA,
              dsp_plan_init(&p, arena, bytes, 64, DSP_WINDOW_KAISER, 1.0, 1, DSP_FFT_DEFAULT));
    EXPECT_EQ(DSP_EBETA, dsp_plan_init(&p, arena, bytes, 64, DSP_WINDOW_KAISER,
                                       DSP_KAISER_BETA_MAX + 1.0, 1, DSP_FFT_DEFAULT))
        << "past the beta the Bessel series is accurate over";
    EXPECT_EQ(DSP_EBETA, dsp_plan_init(&p, arena, bytes, 64, DSP_WINDOW_KAISER, kNaN, 1,
                                       DSP_FFT_DEFAULT))
        << "a NaN beta, which fails both bounds because they are written as positives";
    // dsp_plan_bytes refuses the same configurations, so a caller sizing an arena first gets
    // the refusal there rather than after allocating.
    EXPECT_EQ(0u, dsp_plan_bytes(64, 0, DSP_FFT_DEFAULT));
    EXPECT_EQ(0u, dsp_plan_bytes(64, DSP_DECIM_MAX + 1, DSP_FFT_DEFAULT));
    EXPECT_EQ(0u, dsp_plan_bytes(64, 1, DSP_FFT_COUNT));
    EXPECT_EQ(0u, dsp_plan_bytes(64, 1, -1));
}

TEST(Plan, EveryRefusalLeavesThePlanZeroed) {
    // The header promises p->n == 0 on refusal, on every path. That is what stops a caller
    // which ignores the return code from running a frame on a plan whose arena it has already
    // released, so the state after a refusal is what this pins -- not just the return code.
    std::vector<unsigned char> raw((1u << 19) + DSP_ALIGN, 0);
    unsigned char *arena = AlignUp(raw.data());
    const size_t bytes = 1u << 19;
    dsp_plan p{};

    // A good plan first, so every refusal below has something stale it could leave behind.
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
        // The consequence that matters: a frame on a refused plan must refuse too.
        std::vector<double> x(16384, 1.0);
        EXPECT_EQ(DSP_EARG, dsp_spectrum_run(&p, x.data(), (int)x.size(), nullptr))
            << c.what << ": a refused plan must not run a frame";
        // And dsp_rfft on one must do nothing rather than walk a released arena.
        dsp_rfft(&p);
    }
    // A misaligned arena is the fifth path, and it needs its own offset pointer.
    ASSERT_EQ(DSP_OK,
              dsp_plan_init(&p, arena, bytes, 512, DSP_WINDOW_HANN, 0, 1, DSP_FFT_DEFAULT));
    EXPECT_EQ(DSP_EALIGN, dsp_plan_init(&p, arena + 1, bytes - DSP_ALIGN, 512, DSP_WINDOW_HANN, 0,
                                        1, DSP_FFT_DEFAULT));
    EXPECT_EQ(0, p.n);
    EXPECT_EQ(nullptr, p.re);
    // A null plan pointer cannot be zeroed, so it is the one refusal with nothing to check
    // beyond the code.
    EXPECT_EQ(DSP_EARG,
              dsp_plan_init(nullptr, arena, bytes, 512, DSP_WINDOW_HANN, 0, 1, DSP_FFT_DEFAULT));
}

TEST(Plan, TwoPlansSideBySideAgreeExactly) {
    // Requirement 3: no file-scope mutable state. Two plans of different sizes and windows
    // interleaved must not disturb each other.
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
    // The bit-reversal is stored as the pairs that move. Replaying it must be an involution
    // and must agree with the index arithmetic computed independently here. Radix-2 plans,
    // because the swap list over m is the array only radix-2 pays for.
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

// ---------------------------------------------------------------------------
// the transform against a direct DFT
// ---------------------------------------------------------------------------

TEST(Fft, EveryBinMatchesADirectDft) {
    // The gate for replacing the transform. Every other check here looks at the peak bin of
    // a single tone, which a transform can get right while being wrong everywhere else -- a
    // bin-ordering or scaling error in the untangle would pass all of them. This compares
    // all bins against the textbook sum.
    const int n = 64;
    Plan p(n, DSP_WINDOW_HANN);
    ASSERT_EQ(DSP_OK, p.rc());
    std::vector<double> x(n);
    for (int i = 0; i < n; i++)
        x[i] = 2.5 + 0.7 * std::sin(2.0 * M_PI * 11000.0 * i / 100000.0);

    double mean = 0.0;
    ASSERT_EQ(p->m, RunSpectrum(p, x, &mean));

    // The reference runs on exactly the values the transform consumed, rounded to dsp_real
    // the same way dsp_load rounds them, so the comparison isolates the transform's own
    // error from the load's.
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

    // Reported as two separate figures, because one number conflates them: the relative
    // error on the bins carrying energy, and the absolute error on the bins that should hold
    // nothing. The second is the transform's own noise floor, which is the figure that
    // decides whether single precision is enough.
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

    // And that the comparison could fail. The Lua suite's own negative control: perturb one
    // bin by 1 % and re-measure it. Bin 8 is on the tone's main lobe, so 1 % of it is far
    // above the absolute half of the allowance -- the control measures the relative half.
    double keep = (double)p->pwr[8];
    p->pwr[8] = (dsp_real)(keep * 1.01);
    double perturbed = std::fabs((double)p->pwr[8] - want[8]) / allow(want[8]);
    EXPECT_GT(perturbed, 100.0) << "perturbed bin 8 by 1%, " << perturbed << " of budget";
    p->pwr[8] = (dsp_real)keep;
}

TEST(Fft, EveryDecompositionMatchesADirectDft) {
    // The four-step reorders the adds relative to the textbook radix-2, so each decomposition
    // is measured against the same direct DFT separately rather than against radix-2. The
    // same budget as the test above, and the figure each one reaches is printed: a
    // decomposition that is materially less accurate belongs in the decision on which to
    // ship, not hidden behind a shared tolerance.
    //
    // n = 512, not the 64 the single-decomposition test uses: at m = 32 the four-step is
    // below DSP_FS_MIN and falls back, so a comparison there would measure radix-2 three
    // times and report it as agreement.
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
    // Not bit-exact -- the summation orders differ -- so the bound is the same mixed
    // allowance the direct-DFT comparison uses, with radix-2 as the reference because its
    // accuracy is the one already measured against the Lua's pinned values.
    //
    // Each arm states which decomposition it actually compared. Below DSP_FS_MIN a four-step
    // request builds a radix-2 plan, so an arm at such a size would compare radix-2 with
    // itself and report a difference of exactly zero -- the strongest-looking agreement in the
    // table, measuring nothing. A substituted arm is asserted bit-identical instead, which is
    // the true claim about a substitution, and the count of arms that genuinely ran the
    // four-step is asserted at the end so the test cannot become all substitution.
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
                // The substitution. Identical arithmetic, so identical bits, and anything
                // else means the fallback is not running what it says.
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
            // A genuinely different decomposition cannot agree bit for bit at these sizes.
            // Without this the arm would pass if the dispatch silently ran radix-2 again.
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
    // m1 is the smaller factor on purpose: the gather's strided footprint is m1 cache blocks
    // per array, so making it the larger one would push that out of a 32 kB cache.
    for (int n : {64, 128, 512, 2048, 8192, 16384, 32768, 65536}) {
        Plan p(n, DSP_WINDOW_HANN);
        ASSERT_EQ(DSP_OK, p.rc()) << "n=" << n;
        EXPECT_EQ(p->m, p->m1 * p->m2) << "n=" << n;
        EXPECT_LE(p->m1, p->m2) << "n=" << n;
        EXPECT_EQ(0, p->m1 & (p->m1 - 1)) << "n=" << n << ": m1 must be a power of two";
        EXPECT_EQ(0, p->m2 & (p->m2 - 1)) << "n=" << n << ": m2 must be a power of two";
        // The gather block is DSP_FS_BLOCK * m1 complex points and has to stay a small part of
        // a 32 kB cache, or the pass it exists to make cache-resident is not.
        size_t blk = 2u * DSP_FS_BLOCK * (size_t)p->m1 * sizeof(dsp_real);
        EXPECT_LE(blk, 16384u) << "n=" << n << ": gather block is " << blk << " bytes";
    }
    Plan small(32, DSP_WINDOW_HANN);
    ASSERT_EQ(DSP_OK, small.rc());
    EXPECT_LT(small->m, DSP_FS_MIN) << "m=16 must fall back, which the agreement test covers";
}

TEST(Fft, EachDecompositionIsRepeatableAndDistinct) {
    // The arena is sized for one decomposition, so a benchmark builds a plan each rather
    // than switching a field. Two things are asserted: a plan re-run on the same input is
    // bit-identical, so no state survives a frame; and each of the other two differs from
    // radix-2 somewhere, because without that both decompositions could be the same one
    // running twice and every agreement test would still pass. The claim is only that the
    // bit patterns differ, which they must -- the summation orders do. How closely they
    // agree is BothDecompositionsAgreeBinForBin's business.
    const int n = 4096;
    auto x = ToneAtBin(n, 300.27);
    std::vector<std::vector<dsp_real>> out;
    for (int method = 0; method < DSP_FFT_COUNT; method++) {
        Plan p(n, DSP_WINDOW_HANN, 0, 1, method);
        ASSERT_EQ(DSP_OK, p.rc());
        ASSERT_EQ(method, p->method) << "n=4096 is above every substitution threshold";
        ASSERT_EQ(p->m, RunSpectrum(p, x));
        std::vector<dsp_real> first(p->pwr, p->pwr + p->m);
        // Again, on the same plan: a frame that left state behind would move a bin.
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
    // The substitution is at build time, so it is visible: p->method reports what was built
    // rather than what was asked for. A caller timing decompositions against each other
    // needs that, and the arena is sized for the answer.
    for (int n : {4, 8, 16, 32, 64, 128}) {
        Plan p(n, DSP_WINDOW_HANN, 0, 1, DSP_FFT_FOURSTEP);
        ASSERT_EQ(DSP_OK, p.rc()) << "n=" << n;
        bool usable = p->m2 >= DSP_FS_BLOCK && p->m >= DSP_FS_MIN;
        EXPECT_EQ(usable ? DSP_FFT_FOURSTEP : DSP_FFT_RADIX2, p->method) << "n=" << n;
        // And the arena matches what was built, both ways round.
        EXPECT_EQ(usable, p->blkr != nullptr) << "n=" << n;
        EXPECT_EQ(!usable, p->swp_a != nullptr) << "n=" << n;
        EXPECT_EQ(dsp_plan_bytes(n, 1, p->method), p.bytes()) << "n=" << n;
        // It still transforms correctly, which is what makes the substitution safe.
        auto x = ToneAtBin(n, n / 8.0);
        ASSERT_EQ(p->m, RunSpectrum(p, x));
    }
    // m = 32 is the smallest size the four-step's own precondition admits, and it is below
    // DSP_FS_MIN, so the header's two reasons are genuinely separate: m2 is exactly one block
    // here, not under one.
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
    // EARG, not EPOW2: the sample count is fine and the window sum is what cannot be
    // divided by. Naming the power-of-two code here named the one argument that was right.
    EXPECT_EQ(DSP_EARG, dsp_load(x.data(), 64, p->w, 0.0, p->re, p->im, nullptr));
    EXPECT_EQ(DSP_EARG, dsp_load(nullptr, 64, p->w, p->wsum, p->re, p->im, nullptr));
}

TEST(Fft, PinnedReferenceValues) {
    // The DFT check above recomputes the truth in this file, which catches a wrong
    // transform but not a changed input: if the stimulus drifts, both sides move together
    // and the check still passes. These literals come from tools/make_refs.lua, which has
    // its own window, its own weighted-mean removal and its own O(N^2) DFT -- so they are
    // not this code pinned against itself.
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
    // 1-based in the Lua, so each index is one lower here.
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
    // A half-bin offset, which is what exercises the square roots in dsp_peak_interp and
    // the untangle away from a bin centre.
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
    // What the window-weighted mean buys. The arithmetic mean zeroes the true DC and leaves
    // the window's own DC response spread over the first bins; the weighted mean makes
    // sum(w*(x-mean)) vanish, which is the quantity the transform sees.
    const int n = 512, fs = 100000;
    Plan p(n, DSP_WINDOW_HANN);
    ASSERT_EQ(DSP_OK, p.rc());
    std::vector<double> x(n);
    for (int i = 0; i < n; i++)
        x[i] = 1.0 + 0.5 * std::sin(2.0 * M_PI * 12345.0 * i / fs);
    ASSERT_EQ(256, RunSpectrum(p, x));
    double weighted = (double)p->pwr[0];

    // The negative control, and the reason the bound can be tight: the same record with an
    // arithmetic mean removed instead. The Lua measures 6.5e-07 here.
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
    // G(0) == 1, so a tone on a bin centre needs no correction and must not be nudged.
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
    // A zero peak bin has no ratio to take.
    dsp_real keep = p->pwr[100];
    p->pwr[100] = 0;
    EXPECT_EQ(DSP_EDECLINE, dsp_peak_interp(&p->ip, p->pwr, 100, p->m, &d, &amp));
    p->pwr[100] = keep;
}

// ---------------------------------------------------------------------------
// sub-bin recovery, every window
// ---------------------------------------------------------------------------

struct SweepResult {
    double worst_f = 0.0; // bins
    double worst_a = 0.0; // dB
    int misses = 0;       // offsets where the peak finder did not report the tone
    int fallbacks = 0;    // offsets where dsp_peak_interp declined
};

// The Lua's win_sweep. Offsets at j/83 of a bin, coprime with the 40-node interpolation
// grid: on the nodes every window reads zero error, which would measure the grid rather
// than the code. Routed through dsp_peaks, the way a frame reaches the interpolation, not
// through a local argmax -- an argmax always lands on the tone, so it cannot see a tone
// present in the spectrum and absent from the table.
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

// Bounds from tools/window_check.lua, loosened by about 2x in the Lua so a harmless
// last-bit change does not fail: its measured worst cases are 4.0e-6 bins and 0.0035 dB,
// both at Kaiser b=4 and both at mid-spectrum.
constexpr double kWinDf = 1e-5, kWinDa = 0.008;
// The first bin the table may report. The Lua's measured worst over every window at and
// above that bin centre is 0.102 bins and 0.15 dB, at Kaiser b=9.
constexpr double kLowDf = 0.15, kLowDa = 0.3;
// The top bin has no right-hand neighbour, so the interpolation declines for every window
// and the raw bin is read: half a bin of frequency and 2.3 to 7.1 dB of scalloping.
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
    // Offsets below the centre are not swept: the tone is then under the app's own
    // low-frequency limit, and the masked bin beside it vetoes the one above, so the table
    // is legitimately empty there.
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
    // Those bins carry dsp_load's own error, so a number printed from them is wrong by up to
    // 11.6 dB and moves with the capture phase. The whole region must stay empty.
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
    // Such a tone leaks into the lowest reportable bin and makes it a local maximum, and it
    // was then reported a whole bin and 16 dB out under Blackman and Kaiser b=9.
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
            // Rows at the mask edge only. The other five legitimately carry whatever
            // noise-level maxima exist further up the spectrum.
            for (int s = 0; s < found; s++)
                if (bin[s] >= 0 && bin[s] <= 1 + p->kdc)
                    rows++;
        }
    }
    EXPECT_EQ(0, rows) << GetParam().label() << ": " << rows << " rows at the mask edge over "
                       << positions << " positions";
}

TEST_P(WindowSweep, ADistantOffCentreToneLeavesTheDcRegionClean) {
    // Why dsp_load weights the mean: the arithmetic mean leaves the window's own DC response
    // behind as a line at bin 0 following G(k), 100 dB above the floor the low-sidelobe
    // windows are chosen for. Eight phases, not one: the residue is A*G_rect(b)*cos(phase)
    // about the window centre, and at one phase the arithmetic mean reads -60 dBc and passes.
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
    // The sweep must be able to fail, or the bounds above mean nothing.
    Plan hann(512, DSP_WINDOW_HANN);
    Plan bh(512, DSP_WINDOW_BLACKMAN_HARRIS);
    ASSERT_EQ(DSP_OK, hann.rc());
    ASSERT_EQ(DSP_OK, bh.rc());
    // Blackman-Harris tables fed Hann data: swap the window the loader uses.
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
    // The proposal's enum lists RECT. Its transform has a null exactly one bin from the
    // peak, so near d = 0 the three-bin ratio goes as d^2 rather than as d: the sign of the
    // offset is unrecoverable and the magnitude is ill-conditioned. Measured against Hann
    // through the same sweep, which is the evidence for leaving it off the list.
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

// ---------------------------------------------------------------------------
// peak search
// ---------------------------------------------------------------------------

TEST(Peaks, FindsTheStrongestPeaksInOrder) {
    const int m = 256;
    std::vector<dsp_real> pwr(m, (dsp_real)1e-12);
    // Isolated maxima, so each is a local maximum of its own.
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
    // The first bin past the region is reportable.
    pwr[p->kdc + 1] = (dsp_real)0.25;
    int found = dsp_peaks(pwr.data(), m, 0, m - 1, p->kdc, 6, &p->ip, bin, nullptr, nullptr);
    ASSERT_GE(found, 1);
    EXPECT_EQ(p->kdc + 1, bin[0]) << "want bin " << (p->kdc + 1);
    // The region itself never is, even at full scale.
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
        // A plateau is not a maximum except at the right-hand end, where the missing
        // neighbour counts as lower.
        EXPECT_GE(found, 0);
        EXPECT_LE(found, 6);
        for (int s = 0; s < found; s++)
            EXPECT_TRUE(bin[s] >= 0 && bin[s] < m) << bin[s];
    }
}

TEST(Peaks, APlateauReportsItsLeftBin) {
    // The test is `m > left && m >= right`, so two equal bins report the left one. Asserted
    // because a symmetric test would report both and a strictly-greater test neither.
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
    // Every comparison with a NaN is false, so a NaN bin fails both halves of the local
    // maximum test and so does each of its neighbours. Asserted rather than assumed: a
    // reported NaN frequency reaches the panel, and a refused parameter on the way is a
    // modal dialog.
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
    // And a NaN in the input does not become a reported peak either.
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

// ---------------------------------------------------------------------------
// FIR
// ---------------------------------------------------------------------------

// The Lua's tap ceiling, which is what an interpreted frame affords. Passed explicitly
// wherever a test reproduces one of the Lua's answers; DSP_FIR_MAXTAPS is this one's.
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
    // With order 0 the design takes its ceiling from maxtaps, not from DSP_FIR_MAXTAPS. The
    // /4 transition at a 10 kHz stop needs 133 taps: at the Lua's 65 the design falls back to
    // the ceiling, odd, and at 384 it gets what it asked for.
    EXPECT_EQ(65, dsp_fir_design(h, kLuaMaxTaps, 100000.0, 0.0, 10000.0, 4, 0));
    EXPECT_EQ(133, dsp_fir_design(h, DSP_FIR_MAXTAPS, 100000.0, 0.0, 10000.0, 4, 0));
    EXPECT_EQ(31, dsp_fir_design(h, 32, 100000.0, 0.0, 10000.0, 4, 0))
        << "an even ceiling must come back odd, not over the caller's buffer";
}

TEST(Fir, ANonDecimatingLowPassIsNoFilterButABandPassIs) {
    dsp_real h[DSP_FIR_MAXTAPS];
    // A low-pass at the full Nyquist does nothing, so there are no taps and that is not an
    // error. A band-pass at the same decimation is a real filter: there the selectivity is
    // the point rather than the anti-aliasing.
    EXPECT_EQ(0, dsp_fir_design(h, DSP_FIR_MAXTAPS, 100000.0, 0.0, 20000.0, 1, 0));
#if DSP_BANDPASS
    EXPECT_GT(dsp_fir_design(h, DSP_FIR_MAXTAPS, 100000.0, 2000.0, 20000.0, 1, 101), 0);
    // /2 gives 25 kHz zones, which an 18 kHz band fits. /4 gives 12.5 kHz zones, which it
    // cannot: a band wider than a zone has nowhere to land, whatever the tap count.
    EXPECT_GT(dsp_fir_design(h, DSP_FIR_MAXTAPS, 100000.0, 2000.0, 20000.0, 2, 101), 0);
    EXPECT_EQ(DSP_EZONE, dsp_fir_design(h, DSP_FIR_MAXTAPS, 100000.0, 2000.0, 20000.0, 4, 101));
#else
    // A low-pass-only build refuses a low cutoff outright, before it looks at the zones, so
    // the band-pass cases above become DSP_EUNSUPPORTED rather than a design or a straddle.
    EXPECT_EQ(DSP_EUNSUPPORTED,
              dsp_fir_design(h, DSP_FIR_MAXTAPS, 100000.0, 2000.0, 20000.0, 1, 101));
    EXPECT_EQ(DSP_EUNSUPPORTED,
              dsp_fir_design(h, DSP_FIR_MAXTAPS, 100000.0, 2000.0, 20000.0, 4, 101));
#endif
    EXPECT_EQ(DSP_EARG, dsp_fir_design(h, DSP_FIR_MAXTAPS, 0.0, 0.0, 20000.0, 4, 0));
    EXPECT_EQ(DSP_EARG, dsp_fir_design(nullptr, DSP_FIR_MAXTAPS, 100000.0, 0.0, 2e4, 4, 0));
    // An inverted or empty band has no passband to normalise at.
    EXPECT_EQ(DSP_EARG, dsp_fir_design(h, DSP_FIR_MAXTAPS, 100000.0, 20000.0, 2000.0, 4, 0));
    EXPECT_EQ(DSP_EARG, dsp_fir_design(h, DSP_FIR_MAXTAPS, 100000.0, 20000.0, 20000.0, 4, 0));
    EXPECT_EQ(DSP_EARG, dsp_fir_design(h, DSP_FIR_MAXTAPS, 100000.0, -1000.0, 20000.0, 4, 0));
    // Above the undecimated Nyquist there is nothing to filter.
    EXPECT_EQ(DSP_EARG, dsp_fir_design(h, DSP_FIR_MAXTAPS, 100000.0, 2000.0, 60000.0, 4, 0));
}

TEST(Fir, TapsForRefusesATransitionThatDoesNotFit) {
    // At decim exactly fs/(2*fhi) the transition has zero width, and past it the stop is
    // outside the decimated Nyquist altogether. Neither depends on the ceiling.
    for (int cap : {kLuaMaxTaps, DSP_FIR_MAXTAPS}) {
        EXPECT_EQ(0, dsp_fir_taps_for(100000.0, 0.0, 50000.0, 1, cap)) << "zero width at /1";
        EXPECT_EQ(0, dsp_fir_taps_for(100000.0, 0.0, 10000.0, 5, cap)) << "zero width at /5";
        EXPECT_EQ(0, dsp_fir_taps_for(100000.0, 0.0, 10000.0, 6, cap)) << "stop past the Nyquist";
    }
    // /3 at a 10 kHz stop leaves a transition of 1/6 - 1/10 = 0.0667 of the rate, so
    // 3.3/0.0667 = 50 taps, rounded up to the next odd. This is the proposal's 51-tap
    // filter, and it fits either ceiling.
    EXPECT_EQ(51, dsp_fir_taps_for(100000.0, 0.0, 10000.0, 3, kLuaMaxTaps));
    EXPECT_EQ(51, dsp_fir_taps_for(100000.0, 0.0, 10000.0, 3, DSP_FIR_MAXTAPS));
    // /4 leaves 0.025 and needs 133. That is why the Lua stops at /3, and why this ceiling
    // does not have to: the whole point of the tap ceiling moving.
    EXPECT_EQ(0, dsp_fir_taps_for(100000.0, 0.0, 10000.0, 4, kLuaMaxTaps));
    EXPECT_EQ(133, dsp_fir_taps_for(100000.0, 0.0, 10000.0, 4, DSP_FIR_MAXTAPS));
    // 0.001 of the rate needs 3301 taps, which neither ceiling allows.
    EXPECT_EQ(0, dsp_fir_taps_for(100000.0, 0.0, 12400.0, 4, kLuaMaxTaps));
    EXPECT_EQ(0, dsp_fir_taps_for(100000.0, 0.0, 12400.0, 4, DSP_FIR_MAXTAPS));
    // The widest transition any argument can produce is just under 0.5 of the rate, at
    // decim 1 and a stop near DC, and 3.3/0.5 rounds up to 7. So the three-tap floor inside
    // dsp_fir_taps_for -- which the Lua has too -- is unreachable from here; it is reachable
    // only through dsp_fir_design's explicit order, which the test above covers.
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

// The Lua's gain(hz): drive a tone through the real taps and take the peak of the
// steady-state output, which starts after the group delay.
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
    // The two numbers that were wrong on the instrument. The filter has to be flat across
    // the displayed span and down by the time the decimated Nyquist arrives. The old design
    // was neither: its cutoff sat on the span top so the band was inside the roll-off, and
    // 13 taps where 51 were needed left the near stopband barely attenuated. Measured
    // against the same stimulus, that read 3.5 dB low at 16.6 kHz of a 20 kHz span.
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
    // The negative control for the line above. The same tap count with the cutoff placed on
    // the stop instead of midway, measured at the span edge: that is the fault being
    // controlled for, and it has to be visible through this measurement or the measurement
    // proves nothing.
    const double fs = 200000.0, fhi = 20000.0;
    const int n = 512;
    int d = dsp_fir_pick_decim(fs, 0.0, fhi, n, DSP_FIR_MAXTAPS);
    ASSERT_GE(d, 2);
    dsp_real h[DSP_FIR_MAXTAPS];
    int l = dsp_fir_design(h, DSP_FIR_MAXTAPS, fs, 0.0, fhi, d, 0);
    ASSERT_GT(l, 0);
    // Rebuild the same taps with fc on the stop by asking for the design whose midway
    // cutoff lands there: fc_mid(fhi') = fhi/fs needs fhi'/fs = 2*fhi/fs - 0.5/d.
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
    // Decimating by 4 at 100 kS/s leaves a 12.5 kHz Nyquist, so a 20 kHz tone -- which the
    // hardware samples perfectly well -- folds to 5 kHz if the record is simply thinned.
    // The in-band tone is the control: a filter that killed everything would pass the alias
    // test and fail this.
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
    // Bit-identical: the same taps in the same order over the same inputs.
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
// Filtering in place is the overlap a caller is most likely to reach for, and the loop cannot
// survive it: output j reads inputs j*decim .. j*decim+ntaps-1, so writing y[0] destroys
// inputs the next outputs still need. Detected rather than left to produce a plausible trace.
TEST(Fir, RunRefusesToFilterInPlace) {
    dsp_real h[DSP_FIR_MAXTAPS];
    const int l = dsp_fir_design(h, DSP_FIR_MAXTAPS, 100000.0, 0.0, 10000.0, 4, 0);
    ASSERT_GT(l, 0);
    // The premise: separate buffers filter this record, so the refusal is the aliasing.
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
// Extent, not just base. An output one element into the input shares no address with it and
// would pass any comparison of pointers, while still destroying readings the later outputs
// read. Both lengths are arguments, so this is knowable rather than the caller's problem.
TEST(Fir, RunRefusesAnOutputOverlappingTheInputWithoutSharingItsBase) {
    dsp_real h[DSP_FIR_MAXTAPS];
    const int l = dsp_fir_design(h, DSP_FIR_MAXTAPS, 100000.0, 0.0, 10000.0, 4, 0);
    ASSERT_GT(l, 0);
    std::vector<double> x((size_t)l * 4);
    for (size_t i = 0; i < x.size(); i++)
        x[i] = std::sin(2.0 * M_PI * 500.0 * (double)i / 100000.0);
    const int nx = (int)x.size() - 1;
    const std::vector<double> before = x;
    // The premise: these two really do differ, so a base comparison would let it through.
    ASSERT_NE(x.data(), x.data() + 1);
    EXPECT_EQ(DSP_EARG, dsp_fir_run(x.data(), nx, h, l, 4, x.data() + 1));
    EXPECT_EQ(before, x);
    // And the reverse direction: an input starting inside the output region.
    EXPECT_EQ(DSP_EARG, dsp_fir_run(x.data() + 1, nx, h, l, 4, x.data()));
    EXPECT_EQ(before, x);
    // A genuinely separate output of the same size is still accepted, so the test is about
    // overlap and not about the sizes.
    std::vector<double> y(x.size());
    EXPECT_GT(dsp_fir_run(x.data(), nx, h, l, 4, y.data()), 0);
}
#endif

#if DSP_CHECK_OVERLAP
// A plan sitting inside the arena it is about to carve up is the worst overlap in the library:
// the carve-up writes table pointers into the plan while the tables are built in the arena, so
// the plan's own pointers get overwritten by window samples. Both extents are arguments.
TEST(PlanInit, RefusesAPlanInsideItsOwnArena) {
    const int n = 256;
    const size_t bytes = dsp_plan_bytes(n, 1, DSP_FFT_DEFAULT);
    ASSERT_GT(bytes, 0u);
    std::vector<unsigned char> blob(bytes + sizeof(dsp_plan) + 2 * DSP_ALIGN, 0);
    dsp_plan *inside = reinterpret_cast<dsp_plan *>(AlignUp(blob.data()));
    unsigned char *arena = AlignUp(reinterpret_cast<unsigned char *>(inside) + sizeof(dsp_plan));
    // The premise: laid out end to end like this the two do not overlap, and the plan builds.
    ASSERT_EQ(DSP_OK, dsp_plan_init(inside, arena, bytes, n, DSP_WINDOW_HANN, 12.0, 1,
                                    DSP_FFT_DEFAULT));
    // Now an arena that starts at the plan itself.
    EXPECT_EQ(DSP_EARG, dsp_plan_init(inside, inside, bytes + sizeof(dsp_plan), n,
                                      DSP_WINDOW_HANN, 12.0, 1, DSP_FFT_DEFAULT));
    EXPECT_EQ(0, inside->n) << "zeroed on the refusal, like every other plan refusal";
    // And an arena that merely contains the plan part-way in.
    dsp_plan *midway = reinterpret_cast<dsp_plan *>(arena);
    EXPECT_EQ(DSP_EARG, dsp_plan_init(midway, arena, bytes, n, DSP_WINDOW_HANN, 12.0, 1,
                                      DSP_FFT_DEFAULT));
}
#endif

TEST(Fir, TheDecimationIsCappedByTheFilterLengthAsWellAsTheReadCost) {
    // Two caps, and which one binds depends on the tap ceiling. At the Lua's 65 the filter is
    // the tighter: a decimation leaves a transition from the stop to the decimated Nyquist,
    // and the taps it needs grow fast as that narrows. At 384 the read budget binds instead,
    // which is the whole effect of raising the ceiling and is asserted here rather than
    // assumed.
    int read65 = (int)std::floor((double)(DSP_FIR_MAXM - kLuaMaxTaps) / 511.0);
    int read384 = (int)std::floor((double)(DSP_FIR_MAXM - DSP_FIR_MAXTAPS) / 511.0);
    // The Lua's answers, reproduced by passing the Lua's ceiling.
    EXPECT_EQ(1, dsp_fir_pick_decim(100000.0, 0.0, 50000.0, 512, kLuaMaxTaps))
        << "a 50 kHz stop at 100 kS/s has no room";
    EXPECT_EQ(3, dsp_fir_pick_decim(100000.0, 0.0, 10000.0, 512, kLuaMaxTaps));
    int narrow65 = dsp_fir_pick_decim(100000.0, 0.0, 2000.0, 512, kLuaMaxTaps);
    EXPECT_EQ(7, narrow65);
    EXPECT_LT(narrow65, read65) << "at 65 taps the filter is the tighter cap";
    EXPECT_EQ(1, dsp_fir_pick_decim(100000.0, 0.0, 2000.0, 16384, kLuaMaxTaps))
        << "16384 samples leaves no read budget whatever the span";
    // At 384 taps the 2 kHz span reaches the read budget instead.
    int narrow384 = dsp_fir_pick_decim(100000.0, 0.0, 2000.0, 512, DSP_FIR_MAXTAPS);
    EXPECT_EQ(read384, narrow384) << "at 384 taps the read budget is the binding cap";
    EXPECT_GT(narrow384, narrow65);
    // Wider spans are capped by what the tap ceiling can realise, not by a fixed margin over
    // Nyquist. A 10 kHz span at /4 needs 133 taps: 384 affords them and 65 does not, so the
    // two ceilings give different answers for the same span, which is the point of passing it.
    EXPECT_EQ(4, dsp_fir_pick_decim(100000.0, 0.0, 10000.0, 512, DSP_FIR_MAXTAPS));
    EXPECT_EQ(133, dsp_fir_taps_for(100000.0, 0.0, 10000.0, 4, DSP_FIR_MAXTAPS));
    EXPECT_EQ(0, dsp_fir_taps_for(100000.0, 0.0, 10000.0, 4, kLuaMaxTaps));
    EXPECT_EQ(1, dsp_fir_pick_decim(100000.0, 0.0, 50000.0, 512, DSP_FIR_MAXTAPS));
    // The read budget is DSP_FIR_MAXM minus the taps, so the ceiling moves the budget too.
    // At n = 256 and a 100 Hz stop the span allows /390 and the budget is what binds: 30 at
    // a 384-tap ceiling against 31 at 65, and both records fit the 8192-reading cap, so this
    // asserts the arithmetic rather than the cap.
    EXPECT_EQ(30, dsp_fir_pick_decim(100000.0, 0.0, 100.0, 256, DSP_FIR_MAXTAPS));
    EXPECT_LE(dsp_fir_srclength(256, 30, dsp_fir_taps_for(100000.0, 0.0, 100.0, 30, DSP_FIR_MAXTAPS)),
              DSP_FIR_MAXM);
    // Every chosen decimation must have a filter that fits whatever ceiling was passed.
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
    // The figure the proposal states: 16,384 samples decimating by 4 with 51 taps needs
    // 65,583 readings, not 16,384, and that is what has to go into dmm.digitize.count.
    EXPECT_EQ(65583, dsp_fir_srclength(16384, 4, 51));
    EXPECT_EQ(512, dsp_fir_srclength(512, 1, 0)) << "no decimation: the count is the count";
    EXPECT_EQ((512 - 1) * 3 + 25, dsp_fir_srclength(512, 3, 25));
    EXPECT_DOUBLE_EQ(100000.0 / 4 / 512, dsp_binwidth(100000.0, 512, 4));
    EXPECT_DOUBLE_EQ(100000.0 / 512, dsp_binwidth(100000.0, 512, 1));
}

TEST(Fir, AShortSourceRecordIsRefusedNotZeroPadded) {
    // Zero-padding the tail gives a convincing and false broadband spectrum, and a trigger
    // timeout is the ordinary way a capture comes up short. The previous spectrum must be
    // left alone.
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
    // What the filter buys is bin width: acquire more samples at the hardware rate, filter,
    // keep every Dth, and the bin is fs/srclength rather than fs/n.
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
    // The filter is normalised to unit DC gain, so it cannot change the amplitude.
    EXPECT_NEAR((double)amp[0], 0.8, 0.005 * 0.8);
}

// ---------------------------------------------------------------------------
// segment reduction
// ---------------------------------------------------------------------------

TEST(Reduce, ASingleBinSpikeSurvivesASegmentSpanningThirtyTwoBins) {
    // The whole reason the rule is a maximum. At 16,384 samples and 255 segments each
    // segment spans 32 bins; a decimating or averaging reduction loses a narrow tone, and a
    // spectrum analyser that drops single-bin tones at high resolution is worse than one
    // with fewer bins.
    const int m = 8192, nseg = 255;
    const double binhz = 100000.0 / 16384.0;
    std::vector<dsp_real> pwr(m, (dsp_real)1e-18);
    std::vector<dsp_real> db(nseg), hz(nseg);
    // 8192 bins over 255 segments is 32.1 bins a segment, so every segment spans 32 or 33.
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
        // Within one segment: the trace carries each segment's own frequency, so a tone is
        // drawn at its segment rather than its bin. What must survive is the level.
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

        // The control: the same segmentation reduced by the mean instead of the maximum. A
        // 1 V^2 spike spread over the 32 bins of its own segment averages to 1/32, which is
        // 15 dB down -- below the -10 dB the test above accepts, so taking the maximum is
        // what makes the spike survive.
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
    // Segments can be narrower than a bin and several would then share one, so only the
    // segment's own frequency is strictly increasing.
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
    // The frequency axis still spans the window: the last segment starts within one segment
    // width of the top bin.
    double step = ((double)m / nseg) * binhz;
    EXPECT_NEAR((double)hz[nseg - 1], (nseg - 1) * step, 1e-3 * binhz);
}

TEST(Reduce, EveryBinInTheWindowIsCoveredBySomeSegment) {
    // No bin may be skipped: a skipped bin is a tone that cannot reach the trace at all.
    //
    // Driven through dsp_reduce with a one-hot power array, one bin at a time, and asked
    // whether any segment saw it. Reimplementing the segmentation in the test body instead
    // proves only that the test agrees with itself -- it would pass with dsp_reduce deleted,
    // and it let a one-character change to the carry (`r1 >= nseg` to `r1 > nseg`) drop the
    // top bin of the window in 48 % of configurations while every test still passed.
    //
    // The pairs include nseg not dividing npts, nseg above npts, and nseg of 1, because the
    // carry only does anything when the division is inexact.
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
    // The carry replaces `k0 + c*npts/nseg`, which needs more than 32 bits at the argument
    // limits. This checks the *algorithm* against that quotient over every pair up to 420.
    //
    // It does not test dsp.c: the carry is written out again below, so a mutation in the
    // library cannot fail it. EveryBinInTheWindowIsCoveredBySomeSegment is what exercises the
    // implementation, by driving dsp_reduce. Keeping the two apart is deliberate -- one pins
    // the arithmetic, the other pins the code -- and saying so is the point, because a test
    // that reimplements what it claims to check reads exactly like one that does not.
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
            // After nseg steps the running offset must land exactly on npts, or the last
            // segment is short and the top bin of the window is never read.
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
    // Two independent guards stand between a NaN bin and the trace buffer, where a refused
    // parameter is a modal dialog, and the test has to reach both. `v > hi` in the maximum
    // loop drops a NaN that is not the segment's first bin; `hi > vfl` catches one that is,
    // because the first bin seeds hi unconditionally; and the dB range tests are written as
    // positives so that anything still NaN lands on dbmin rather than passing through.
    // Every bin of the segmentation below is tried as the NaN, so each guard is exercised.
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
    // An infinity must clamp rather than reach the buffer either.
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
    // No usable frequency scale yet, which is the state before the first plan.
    EXPECT_EQ(DSP_EARG,
              ReduceFlat(pwr.data(), 64, 0, 63, 8, 0.0, -120, 20, 1e-9, db.data(), hz.data()));
    // The bound nbins exists for. A zero or negative bin count is refused, and so is a k0
    // at or past the end -- there is no segmentation of an empty range to produce.
    EXPECT_EQ(DSP_EARG,
              ReduceFlat(pwr.data(), 0, 0, 63, 8, 100.0, -120, 20, 1e-9, db.data(), hz.data()));
    EXPECT_EQ(DSP_EARG,
              ReduceFlat(pwr.data(), -1, 0, 63, 8, 100.0, -120, 20, 1e-9, db.data(), hz.data()));
    EXPECT_EQ(DSP_EARG,
              ReduceFlat(pwr.data(), 64, 64, 70, 8, 100.0, -120, 20, 1e-9, db.data(), hz.data()));
    // A NaN or infinite bin width is not a frequency scale either; the test is a positive, so
    // a NaN fails it rather than reaching the per-segment multiply.
    EXPECT_EQ(DSP_EARG, ReduceFlat(pwr.data(), 64, 0, 63, 8, kNaN, -120, 20, 1e-9, db.data(),
                                   hz.data()));
    EXPECT_EQ(DSP_EARG,
              ReduceFlat(pwr.data(), 64, 0, 63, 8, -1.0, -120, 20, 1e-9, db.data(), hz.data()));
    EXPECT_EQ(DSP_EARG, ReduceFlat(pwr.data(), 64, 0, 63, 8, kInf, -120, 20, 1e-9, db.data(),
                                   hz.data()))
        << "an infinite width passes a bare `> 0` test, and makes k0 * binhz the product 0*inf";
    // An inverted dB window describes no segment, so it is refused rather than producing a
    // trace clamped the wrong way round.
    EXPECT_EQ(DSP_EARG,
              ReduceFlat(pwr.data(), 64, 0, 63, 8, 100.0, 20, -120, 1e-9, db.data(), hz.data()))
        << "dbmin above dbmax";
    EXPECT_EQ(DSP_EARG,
              ReduceFlat(pwr.data(), 64, 0, 63, 8, 100.0, 0, 0, 1e-9, db.data(), hz.data()))
        << "a dB window of zero width";
    // A negative voltage floor would square to a positive one and silently raise the floor.
    EXPECT_EQ(DSP_EARG,
              ReduceFlat(pwr.data(), 64, 0, 63, 8, 100.0, -120, 20, -1e-9, db.data(), hz.data()))
        << "a negative voltage floor";
    // Zero is allowed: it means nothing is below the floor on that account, and the dbmin
    // clamp is what keeps log10 of a zero bin off the trace.
    EXPECT_EQ(8, ReduceFlat(pwr.data(), 64, 0, 63, 8, 100.0, -120, 20, 0.0, db.data(), hz.data()));
    for (int c = 0; c < 8; c++)
        EXPECT_TRUE(std::isfinite((double)db[c])) << "vfloor 0, segment " << c;
}

TEST(Reduce, PastTheEndClampsInsteadOfReadingThere) {
    // k1 is a last index, and a caller passing the bin count instead is the ordinary
    // off-by-one, and nbins is the only thing that bounds it -- this runs every frame, and a
    // one-bin overread is something ASan reports and a release build does not. Clamped rather
    // than refused, matching dsp_peaks over the same array.
    const int m = 64, nseg = 8;
    std::vector<dsp_real> pwr(m, (dsp_real)1e-12), db(nseg), hz(nseg);
    pwr[m - 1] = (dsp_real)1.0;
    std::vector<dsp_real> want_db(nseg), want_hz(nseg);
    ASSERT_EQ(nseg, ReduceFlat(pwr.data(), m, 0, m - 1, nseg, 100.0, -120.0, 20.0, 1e-9,
                               want_db.data(), want_hz.data()));
    // Off by one, off by a lot, and INT_MAX: each must give the clamped answer exactly.
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
    // And the premise: the top bin is inside the clamped window, so the clamp is not hiding
    // the tone the comparison relies on.
    EXPECT_GT((double)want_db[nseg - 1], -10.0) << "the 1 V^2 bin must reach the last segment";
}

TEST(Reduce, AToneAnywhereInARealSpectrumReachesTheTrace) {
    // The same guarantee through the real transform rather than a synthetic power array, at
    // the count where a segment is widest.
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
        // A 1 V peak tone is 0 dBV; the trace must show it within the window's own scalloping.
        EXPECT_GT(top, -1.5) << "bin " << bin << " read " << top << " dB";
        double tol = 1.5 * binhz * p->m / nseg;
        EXPECT_LT(std::fabs((double)hz[at] - bin * binhz), tol) << "bin " << bin;
    }
}

// ---------------------------------------------------------------------------
// the whole frame
// ---------------------------------------------------------------------------

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
    // 32,768 and 65,536 are the counts the Lua declines because the frame is seconds long.
    // The arithmetic has to be right at those sizes before the offer is worth making.
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

// ---------------------------------------------------------------------------
// hostile floating-point input
// ---------------------------------------------------------------------------
//
// The instrument supplies these. A digitize read of an open input, a range change mid-capture
// or a reading at overflow arrives as a non-finite double, and a reading of exactly zero
// through a sign-preserving scale arrives as -0.0. What the library must do with them is
// survive and report something finite: a non-finite value reaching a graph parameter or a
// reading posts event 1131 and a modal dialog on the front panel, which is unrecoverable
// without touching the instrument.
//
// Both NaN flavours are built by bit pattern. A quiet NaN has the mantissa MSB set, a
// signalling NaN has it clear with a non-zero mantissa; the distinction matters because an
// operation on a signalling NaN raises the invalid-operation flag, and on a target where that
// flag is enabled as a trap the two behave differently.

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
    // The premise. A quiet NaN that is not a NaN, or a signalling NaN the compiler has
    // quietened at compile time, would make every test below vacuous.
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
    // Every double a caller passes that is not sample data. None may be accepted silently in
    // a way that puts a non-finite value in an output.
    Plan p(256, DSP_WINDOW_HANN);
    ASSERT_EQ(DSP_OK, p.rc());
    std::vector<dsp_real> db(16), hz(16), pwr(64, (dsp_real)1e-12);
    dsp_real taps[DSP_FIR_MAXTAPS];

    for (const Hostile &h : HostileValues()) {
        SCOPED_TRACE(h.name);
        // A window's Kaiser beta: outside the bounds either way, so refused.
        std::vector<dsp_real> w(64);
        int rc = dsp_window(w.data(), 64, DSP_WINDOW_KAISER, h.v);
        EXPECT_EQ(DSP_EBETA, rc) << "beta " << h.name << " returned " << rc;

        // Each of the four scalars that reaches an output array, one at a time. Whatever the
        // return code, no output may end up non-finite or outside the dB window: these are
        // written into the trace buffer, where a refused parameter is a modal dialog. A
        // helper rather than four copies, so the check cannot drift between them.
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
        // And a non-finite one is refused rather than clamped, for all four: there is no
        // defensible value to substitute for a floor nobody specified.
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

        // The sub-bin tables. A gain is always finite, and an accepted offset is always
        // inside half a bin.
        double g = dsp_win_gain(&p->ip, h.v);
        EXPECT_FALSE(std::isnan(g)) << "gain at offset " << h.name;
        EXPECT_GE(g, 0.0) << "gain at offset " << h.name;
        double d = 1e9;
        if (dsp_win_offset(&p->ip, h.v, &d) == DSP_OK) {
            EXPECT_FALSE(std::isnan(d)) << "offset from ratio " << h.name;
            EXPECT_LE(std::fabs(d), 0.5) << "offset from ratio " << h.name << " gave " << d;
        }

        // The filter's rates. Nothing may come back as a tap count with non-finite taps.
        int l = dsp_fir_design(taps, DSP_FIR_MAXTAPS, h.v, 0.0, 20000.0, 4, 0);
        if (l > 0)
            for (int i = 0; i < l; i++)
                ASSERT_TRUE(std::isfinite((double)taps[i])) << "fs " << h.name << " tap " << i;
        l = dsp_fir_design(taps, DSP_FIR_MAXTAPS, 1e6, 0.0, h.v, 4, 0);
        if (l > 0)
            for (int i = 0; i < l; i++)
                ASSERT_TRUE(std::isfinite((double)taps[i])) << "fhi " << h.name << " tap " << i;
        // -0.0 compares equal to zero, so it is a low-pass at DC like +0.0 and must give the
        // identical design. Everything else here is outside 0 < flo < fhi, so it is refused;
        // a legitimate band-pass flo is covered by the BandPass suite.
        if (h.v == 0.0) {
            int lz = dsp_fir_design(taps, DSP_FIR_MAXTAPS, 1e6, h.v, 2e4, 4, 0);
            dsp_real plus[DSP_FIR_MAXTAPS];
            int lp = dsp_fir_design(plus, DSP_FIR_MAXTAPS, 1e6, 0.0, 2e4, 4, 0);
            EXPECT_EQ(lp, lz) << "flo " << h.name << " must design like +0.0";
            for (int i = 0; i < lz && i < lp; i++)
                ASSERT_EQ(plus[i], taps[i]) << "flo " << h.name << " tap " << i;
        } else if (std::isfinite(h.v) && h.v > 0.0 && h.v < 2e4) {
            // A positive finite low cutoff inside the band is an ordinary band-pass, however
            // small: the taps have to be finite, which is the requirement here.
            int rc2 = dsp_fir_design(taps, DSP_FIR_MAXTAPS, 1e6, h.v, 2e4, 4, 0);
            if (rc2 > 0)
                for (int i = 0; i < rc2; i++)
                    ASSERT_TRUE(std::isfinite((double)taps[i]))
                        << "flo " << h.name << " tap " << i;
        } else {
            EXPECT_LT(dsp_fir_design(taps, DSP_FIR_MAXTAPS, 1e6, h.v, 2e4, 4, 0), 0)
                << "flo " << h.name << " is outside 0 < flo < fhi and must be refused";
        }

        // The planning helpers return a count or a width, never a trap and never a negative.
        EXPECT_GE(dsp_fir_pick_decim(h.v, 0.0, 20000.0, 512, DSP_FIR_MAXTAPS), 1) << "fs " << h.name;
        EXPECT_GE(dsp_fir_pick_decim(1e6, 0.0, h.v, 512, DSP_FIR_MAXTAPS), 1) << "fhi " << h.name;
        EXPECT_GE(dsp_fir_taps_for(h.v, 0.0, 20000.0, 4, DSP_FIR_MAXTAPS), 0) << "fs " << h.name;
        EXPECT_GE(dsp_fir_taps_for(1e6, 0.0, h.v, 4, DSP_FIR_MAXTAPS), 0) << "fhi " << h.name;
        // The transition's sign is its whole answer -- positive fits, zero or negative does
        // not -- so a NaN is the one result it may never give, whatever the rates are. A
        // subnormal rate legitimately gives -inf, which is negative and so reads as "does
        // not fit".
        EXPECT_FALSE(std::isnan(dsp_fir_transition(h.v, 0.0, 20000.0, 4))) << "fs " << h.name;
        EXPECT_FALSE(std::isnan(dsp_fir_transition(1e6, 0.0, h.v, 4))) << "fhi " << h.name;
        // A tap count is 0 or an odd value the buffer holds. Nothing else, for any rate: a
        // huge rate legitimately gives a wide transition and so a short filter.
        for (int nt : {dsp_fir_taps_for(h.v, 0.0, 20000.0, 4, DSP_FIR_MAXTAPS),
                       dsp_fir_taps_for(1e6, 0.0, h.v, 4, DSP_FIR_MAXTAPS)}) {
            ASSERT_GE(nt, 0) << "fs/fhi " << h.name;
            if (nt != 0) {
                ASSERT_GE(nt, 3) << "fs/fhi " << h.name;
                ASSERT_LE(nt, DSP_FIR_MAXTAPS) << "fs/fhi " << h.name;
                ASSERT_EQ(1, nt & 1) << "fs/fhi " << h.name << ": the group delay must be whole";
            }
        }
        // A bin width is positive and finite or it is zero, which is this function refusing.
        double bw = dsp_binwidth(h.v, 512, 1);
        EXPECT_TRUE(bw == 0.0 || (bw > 0.0 && std::isfinite(bw)))
            << "bin width from fs " << h.name << " is " << bw;

        // A plan's beta, through the whole build.
        Plan bad(256, DSP_WINDOW_KAISER, h.v);
        EXPECT_EQ(DSP_EBETA, bad.rc()) << "plan beta " << h.name;
        EXPECT_EQ(0, bad->n) << "plan beta " << h.name << ": a refused plan must be zeroed";
    }
}

TEST(Hostile, SampleDataSurvivesAndNeverReachesAnOutput) {
    // The sample record itself. One hostile reading is placed at every position that matters
    // -- first, last, in the middle, and the two either side of the packing boundary -- and
    // the whole frame then has to complete with a finite spectrum, finite peaks and a finite
    // trace. The bins near a non-finite reading are worthless, which is expected; what is not
    // allowed is a NaN leaving the library.
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
    // -0.0 is the one hostile value that is a perfectly good number, so the requirement is
    // stronger than survival: a record of negative zeros must give the same answer as a record
    // of positive zeros, bit for bit. A sign-preserving scale on the instrument produces it
    // for a reading of exactly zero, so it arrives in ordinary use rather than at a fault.
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

    // And mixed in with real data, at every position, against the same record with +0.0.
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

    // A power bin of -0.0 must plot at the floor, not produce log10 of a negative zero.
    std::vector<dsp_real> pwr(64, (dsp_real)1e-12), db(8), hz(8);
    pwr[10] = (dsp_real)NegativeZero();
    ASSERT_EQ(8, ReduceFlat(pwr.data(), 64, 0, 63, 8, 100.0, -120.0, 20.0, 1e-9, db.data(),
                            hz.data()));
    for (int c = 0; c < 8; c++) {
        ASSERT_FALSE(std::isnan((double)db[c])) << "segment " << c;
        ASSERT_FALSE(std::isinf((double)db[c])) << "segment " << c;
        ASSERT_GE((double)db[c], -120.0) << "segment " << c;
    }
    // And a -0.0 peak bin declines rather than reporting an infinite amplitude.
    double d = 0.0, aout = 0.0;
    pwr[20] = (dsp_real)NegativeZero();
    EXPECT_EQ(DSP_EDECLINE, dsp_peak_interp(&a->ip, pwr.data(), 20, 64, &d, &aout))
        << "a non-positive peak bin has no sub-bin estimate";
}

TEST(Hostile, AWholeRecordOfOneHostileValueCompletes) {
    // The degenerate case: every reading identical and non-finite. The window-weighted mean is
    // then non-finite too, so the subtraction is inf-inf or NaN at every sample. The frame must
    // still return a bin count and the trace must still be finite, because a timeout or an
    // open input produces exactly this.
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
    // The filter is the one kernel the caller can hand both data and coefficients. A
    // non-finite tap or sample contaminates the outputs it touches, which is unavoidable; the
    // requirement is that the run completes and reports the right count.
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

// ---------------------------------------------------------------------------
// refusal paths
// ---------------------------------------------------------------------------
//
// Every documented error return, driven from the API. Measured with llvm-cov: with these, the
// only statements in dsp.c no test reaches are ones no caller can reach either, and those are
// listed in csrc/README.md with the argument for each. The two classes are worth keeping
// apart -- an unreached refusal is a hole in the suite, an unreachable backstop is a decision.

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

    // The accepting cases, including the ceiling and the two that clear the filter.
    EXPECT_EQ(21, dsp_plan_set_fir(&p.get(), taps, 21));
    EXPECT_EQ(21, p->ntaps);
    EXPECT_EQ(DSP_FIR_MAXTAPS, dsp_plan_set_fir(&p.get(), taps, DSP_FIR_MAXTAPS))
        << "exactly as many taps as h holds";
    EXPECT_EQ(0, dsp_plan_set_fir(&p.get(), nullptr, 0)) << "a null with a zero count clears it";
    EXPECT_EQ(0, p->ntaps);
    EXPECT_EQ(0, dsp_plan_set_fir(&p.get(), taps, 0)) << "and so does a zero count alone";

    // The taps are copied into the arena, not aliased, so the caller's buffer can be a local.
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

    // A decimating plan with no taps: refused, not run unfiltered.
    ASSERT_EQ(0, p->ntaps);
    EXPECT_EQ(DSP_EARG, dsp_spectrum_run(&p.get(), src.data(), (int)src.size(), nullptr))
        << "decim > 1 with no filter";

    // A tap count outside what h holds, reached by writing the field, which is why the run
    // checks it rather than trusting it.
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

    // A source record the arithmetic cannot express. dsp_fir_srclength reports 0, and 0 is not
    // a length an `nsrc < need` test would catch.
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
    // A transition needing exactly maxtaps, where maxtaps is even: the count is raised to stay
    // odd and then no longer fits, so there is no filter to offer.
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
    // The read budget normally binds first. At the smallest count with the shortest filter it
    // does not, and DSP_DECIM_MAX is what stops the answer running away.
    int d = dsp_fir_pick_decim(1e9, 0.0, 1.0, 2, 3);
    EXPECT_LE(d, DSP_DECIM_MAX) << "a ratio of 1e9 must still clamp";
    EXPECT_GE(d, 1);
    // The refusals return 1 rather than an error: no decimation is not a fault.
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
    // k0 below the DC floor is raised, so a tall bin inside the region is never a candidate.
    pwr[1] = (dsp_real)4.0;
    int found = dsp_peaks(pwr.data(), m, 0, m - 1, 3, 4, nullptr, bins, nullptr, nullptr);
    ASSERT_GE(found, 1);
    EXPECT_EQ(30, bins[0]) << "the bin at 1 is inside a three-bin DC region";
    // A window that is entirely inside the DC region reports nothing.
    EXPECT_EQ(0, dsp_peaks(pwr.data(), m, 0, 2, 8, 4, nullptr, bins, nullptr, nullptr));

    // The leak refusal at the lowest reportable bin, on the branch where the interpolation
    // itself declines. A negative left neighbour is what makes it decline -- a zero one is
    // still a valid three-bin set -- and the offset then falls back to zero, which keeps the
    // peak rather than refusing it.
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
    // Neither output is written on a decline, which the header promises.
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
    // Both bounds are inclusive, so the endpoints are usable.
    EXPECT_EQ(DSP_OK, dsp_window(w, 64, DSP_WINDOW_KAISER, DSP_KAISER_BETA_MIN));
    EXPECT_EQ(DSP_OK, dsp_window(w, 64, DSP_WINDOW_KAISER, DSP_KAISER_BETA_MAX));
    // An odd length, where the mirror writes the centre sample twice, and the shortest.
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
    // Nothing to assert but survival: a plan with no transform size must not walk an arena.
    dsp_plan empty{};
    dsp_rfft(nullptr);
    dsp_rfft(&empty);
    // And the smallest real plan, where m is 2 and the first butterfly loop runs once.
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

// ---------------------------------------------------------------------------
// the band-pass
// ---------------------------------------------------------------------------
//
// Three things have to hold and none follows from the low-pass tests. The kernel is a
// difference of sincs, so the passband has to be flat between the cutoffs and the stopbands
// down on *both* sides. The normalisation is taken at the passband centre, because for a
// band-pass DC is a stopband -- normalising there divides by a number near zero with a
// data-dependent sign. And the decimation only works inside one Nyquist zone, with an odd
// zone arriving frequency-reversed.

#if DSP_BANDPASS

// Magnitude response of a symmetric FIR at a normalised frequency, in dB.
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
    // The whole reason the normalisation had to change. A band-pass's DC gain is its
    // *stopband* gain, so dividing the taps by their sum divides by something near zero with
    // an arbitrary sign. Both facts are measured here: the sum is tiny next to the centre
    // response, and the centre response after normalisation is 1.
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
    // Unit gain where it was asked for.
    EXPECT_NEAR(at_centre, 1.0, 0.02) << "the passband centre must have unit gain";
    // And the control: normalising at DC instead would have divided by this.
    EXPECT_LT(std::fabs(sum), 0.05)
        << "sum(h) is " << sum << ", so a DC normalisation divides by nearly nothing";
    EXPECT_LT(FirResponseDb(h, l, 0.0), -40.0) << "DC must be in the stopband";
}

TEST(BandPass, TheDcGainCrossesZeroWhichIsWhyItCannotBeTheDivisor) {
    // Sweeping the band upward, sum(h) changes sign. A DC normalisation is therefore not
    // merely inaccurate for a band-pass: at the crossing it is a divide by zero, and either
    // side of it the taps come out scaled by an arbitrary factor with an arbitrary sign.
    // Every design below still has unit gain at its own centre, which is the point.
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
    // A low-pass is only ever measured on one side. Here both stopbands matter, and the
    // lower one is the one a low-pass formula never looks at.
    const double fs = 1e6, flo = 150000.0, fhi = 200000.0;
    dsp_real h[DSP_FIR_MAXTAPS];
    int l = dsp_fir_design(h, DSP_FIR_MAXTAPS, fs, flo, fhi, 1, 301);
    ASSERT_GT(l, 0);
    double worst_ripple = 0.0;
    for (double f = flo; f <= fhi; f += 1000.0)
        worst_ripple = std::max(worst_ripple, std::fabs(FirResponseDb(h, l, f / fs)));
    // Measured a full transition outside each cutoff, which is where the stopband starts. At
    // the cutoff itself a windowed sinc is -6 dB by construction, so measuring there would
    // say nothing about rejection.
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
    // Through dsp_fir_run rather than through the response formula, so the taps, the
    // convolution and the normalisation are all in the measurement.
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
    // The claim the whole feature rests on: a band high in frequency, decimated, gives bins
    // finer than the sample rate over the sample count -- and the tone comes back at its own
    // frequency through dsp_bin_hz, in a zone that may be reversed.
    const double fs = 1e6;
    const int n = 4096;
    struct Case {
        double flo, fhi;
        int decim;
        int want_zone, want_sense;
    };
    // /2 puts 380-400 kHz in zone 1, which is odd and so arrives reversed. /4 puts
    // 30-50 kHz in zone 0, which is not. Both are checked the same way.
    const Case cases[] = {{380000.0, 400000.0, 2, 1, -1}, {30000.0, 50000.0, 4, 0, 1}};
    for (const Case &c : cases) {
        dsp_bandmap map{};
        ASSERT_EQ(DSP_OK, dsp_band_map(fs, c.flo, c.fhi, n, c.decim, &map))
            << c.flo << "-" << c.fhi << " /" << c.decim;
        EXPECT_EQ(c.want_zone, map.zone);
        EXPECT_EQ(c.want_sense, map.sense);
        EXPECT_DOUBLE_EQ(fs / c.decim / n, map.binhz);
        // The resolution claim: the decimated bin is decim times finer.
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
    // A graph trace has to ascend in x. An odd zone arrives reversed, so the reduction walks
    // the window from the top down; the control is that doing it the naive way would give a
    // descending trace, which is asserted against the map directly.
    const double fs = 1e6;
    const int n = 2048, nseg = 64;
    dsp_bandmap map{};
    ASSERT_EQ(DSP_OK, dsp_band_map(fs, 380000.0, 400000.0, n, 2, &map));
    ASSERT_EQ(-1, map.sense) << "the premise: zone 1 is reversed";

    // Bin 0 is the top of the zone and the last bin the bottom, so the raw map descends.
    EXPECT_GT(dsp_bin_hz(&map, 0), dsp_bin_hz(&map, n / 2 - 1));

    std::vector<dsp_real> pwr((size_t)(n / 2), (dsp_real)1e-12);
    // A marker near each end of the window, so the ordering is observable.
    const int lo_bin = n / 2 - 5;  // lowest frequency, because the map is reversed
    const int hi_bin = 5;          // highest frequency
    pwr[lo_bin] = (dsp_real)1.0;
    pwr[hi_bin] = (dsp_real)0.25;
    std::vector<dsp_real> db(nseg), hz(nseg);
    ASSERT_EQ(nseg, dsp_reduce(pwr.data(), n / 2, 0, n / 2 - 1, nseg, &map, -120.0, 20.0, 1e-9,
                               db.data(), hz.data()));
    for (int c = 1; c < nseg; c++)
        ASSERT_GT((double)hz[c], (double)hz[c - 1]) << "the trace must ascend at segment " << c;
    // The 1 V marker is the low-frequency one, so it must appear in an early segment and the
    // 0.25 V marker in a late one. Reversed, that ordering would swap.
    int at_strong = 0, at_weak = 0;
    for (int c = 0; c < nseg; c++) {
        if (db[c] > db[at_strong])
            at_strong = c;
        if ((double)db[c] > -10.0 && c > at_weak)
            at_weak = c;
    }
    EXPECT_LT(at_strong, nseg / 2) << "the lowest-frequency marker belongs in an early segment";
    EXPECT_GT(at_weak, nseg / 2) << "and the highest-frequency one in a late segment";
    // The endpoints agree with the map, both ways round.
    EXPECT_NEAR((double)hz[0], dsp_bin_hz(&map, n / 2 - 1), 0.5 * map.binhz);
    EXPECT_LT((double)hz[nseg - 1], dsp_bin_hz(&map, 0));
}

TEST(BandPass, AReversedReductionCoversTheSameBinsAsAForwardOne) {
    // The mirroring must not drop or duplicate a bin. The same power array reduced under an
    // ascending map and a descending one has to produce the same multiset of segment maxima,
    // just in the opposite order.
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
    // pwr rises with k, so the ascending reduction's maxima rise and the descending one's
    // fall. Segment c of one is segment nseg-1-c of the other over the mirrored bins.
    for (int c = 1; c < nseg; c++) {
        ASSERT_GE((double)dbu[c], (double)dbu[c - 1]) << "ascending segment " << c;
        ASSERT_LE((double)dbd[c], (double)dbd[c - 1]) << "descending segment " << c;
        ASSERT_GT((double)hzu[c], (double)hzu[c - 1]);
        ASSERT_GT((double)hzd[c], (double)hzd[c - 1]) << "both traces ascend in frequency";
    }
    // Every bin is covered exactly once by the descending segmentation too.
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
    // The failure no tap count repairs: a zone boundary inside the band folds the band onto
    // itself, so part of the spectrum lands on top of another part.
    const double fs = 1e6;
    // /4 gives 125 kHz zones. 100-150 kHz crosses the 125 kHz boundary.
    dsp_bandmap map{};
    EXPECT_EQ(DSP_EZONE, dsp_band_map(fs, 100000.0, 150000.0, 1024, 4, &map));
    EXPECT_EQ(0, map.zone) << "a refused map must be left zeroed";
    EXPECT_EQ(0, map.sense);
    dsp_real h[DSP_FIR_MAXTAPS];
    EXPECT_EQ(DSP_EZONE, dsp_fir_design(h, DSP_FIR_MAXTAPS, fs, 100000.0, 150000.0, 4, 101));
    EXPECT_EQ(0.0, dsp_fir_transition(fs, 100000.0, 150000.0, 4));
    EXPECT_EQ(0, dsp_fir_taps_for(fs, 100000.0, 150000.0, 4, DSP_FIR_MAXTAPS));
    // The same band at /2 has 250 kHz zones and fits inside zone 0.
    EXPECT_EQ(DSP_OK, dsp_band_map(fs, 100000.0, 150000.0, 1024, 2, &map));
    EXPECT_EQ(0, map.zone);
    EXPECT_EQ(1, map.sense);
    // A band ending exactly on a boundary belongs to the zone below it, which is where the
    // fold puts it, so the map is fine. What it has no room for is a filter: the transition
    // there is zero wide, which dsp_fir_taps_for reports rather than dsp_band_map refusing.
    EXPECT_EQ(DSP_OK, dsp_band_map(fs, 100000.0, 125000.0, 1024, 4, &map));
    EXPECT_EQ(0, map.zone);
    EXPECT_EQ(1, map.sense);
    EXPECT_EQ(0.0, dsp_fir_transition(fs, 100000.0, 125000.0, 4));
    EXPECT_EQ(0, dsp_fir_taps_for(fs, 100000.0, 125000.0, 4, DSP_FIR_MAXTAPS));

    // The case that matters most for the low-pass: an undecimated full span. At decim 1 there
    // is one zone and nothing folds, so the ordinary 0..fs/2 request must map, and the plain
    // k*binwidth relation must come out of it. Reading fhi's zone as the one above would call
    // this a straddle and leave the commonest configuration with no map at all.
    EXPECT_EQ(DSP_OK, dsp_band_map(200000.0, 0.0, 100000.0, 512, 1, &map));
    EXPECT_EQ(0, map.zone);
    EXPECT_EQ(1, map.sense);
    EXPECT_DOUBLE_EQ(0.0, map.f0);
    EXPECT_DOUBLE_EQ(dsp_binwidth(200000.0, 512, 1), map.binhz);
    // And the same at every decimation, for the span that reaches that decimation's Nyquist:
    // the span a user asks for by default is the one the zone test must not reject.
    for (int d = 1; d <= 16; d++) {
        dsp_bandmap full{};
        const double nyq = 1e6 / (2.0 * (double)d);
        EXPECT_EQ(DSP_OK, dsp_band_map(1e6, 0.0, nyq, 1024, d, &full))
            << "/" << d << ": a span reaching its own decimated Nyquist must map";
        EXPECT_EQ(0, full.zone) << "/" << d;
        EXPECT_EQ(1, full.sense) << "/" << d;
    }
    // A genuine straddle is still refused, which is what keeps the relaxation honest: 100 kHz
    // past the edge is inside the next zone, not on its boundary.
    EXPECT_EQ(DSP_EZONE, dsp_band_map(fs, 100000.0, 125001.0, 1024, 4, &map));
}

TEST(BandPass, PickDecimSkipsTheStraddlingDecimations) {
    // A decimation chosen from fhi alone would land on one of these. Every decimation this
    // returns has to give a single zone and a realisable filter, which is asserted over a
    // sweep of bands rather than at one point.
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
            // The control: some decimation below the one chosen does straddle, so the search
            // is skipping candidates rather than never meeting one.
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
    // A low-pass has one transition and a band-pass two. For a band near the bottom of a
    // zone the lower one is narrower, and it is the edge a low-pass formula never looks at,
    // so a tap count taken from fhi alone is too small.
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
    // What a low-pass formula would have said, which is 30 times wider.
    double upper_only = (500000.0 - fhi) / fs;
    EXPECT_GT(upper_only, 5.0 * wtr) << "the upper guard is much wider, so using it alone "
                                        "would ask for far too few taps";
    int l = dsp_fir_taps_for(fs, flo, fhi, decim, DSP_FIR_MAXTAPS);
    ASSERT_GT(l, 0);
    int want = (int)std::ceil(DSP_FIR_TAPK / wtr);
    if ((want % 2) == 0)
        want++;
    EXPECT_EQ(want, l) << "the count follows the narrow guard";
    // And the resulting filter really does reject below the zone edge, which is what the
    // lower guard is for: energy there folds into the band.
    dsp_real h[DSP_FIR_MAXTAPS];
    ASSERT_EQ(l, dsp_fir_design(h, DSP_FIR_MAXTAPS, fs, flo, fhi, decim, 0));
    double at_edge = FirResponseDb(h, l, 250000.0 / fs);
    std::printf("[   bp ] zone-1 band %.0f-%.0f /%d: %d taps, zone edge %.1f dB\n", flo, fhi,
                decim, l, at_edge);
    EXPECT_LT(at_edge, -20.0) << "the zone edge must be in the stopband or the band folds";
}

TEST(BandPass, ZoneZeroHasNoLowerAliasingTransition) {
    // Nothing folds across DC, so a band in zone 0 has only the upper transition and the
    // derived tap count comes from it alone. Asserted because the alternative -- treating DC
    // as a guard -- would demand thousands of taps for an ordinary low band.
    const double fs = 1e6;
    EXPECT_DOUBLE_EQ(dsp_fir_transition(fs, 0.0, 20000.0, 4),
                     dsp_fir_transition(fs, 2000.0, 20000.0, 4))
        << "in zone 0 the lower edge does not change the transition";
    // Which is the low-pass formula exactly.
    EXPECT_NEAR(dsp_fir_transition(fs, 0.0, 20000.0, 4), 1.0 / 8.0 - 0.02, 1e-15);
    // A band-pass in zone 0 still gets a lower skirt, and with the band far enough from DC
    // the derived tap count rejects DC properly.
    dsp_real h[DSP_FIR_MAXTAPS];
    int l = dsp_fir_design(h, DSP_FIR_MAXTAPS, fs, 50000.0, 100000.0, 4, 0);
    ASSERT_GT(l, 0);
    double dc = FirResponseDb(h, l, 0.0);
    double mid = FirResponseDb(h, l, 75000.0 / fs);
    std::printf("[   bp ] zone-0 band 50k-100k /4: %d taps, DC %.1f dB, mid-band %.2f dB\n", l,
                dc, mid);
    EXPECT_NEAR(mid, 0.0, 1.0) << "the passband is flat";
    EXPECT_LT(dc, -40.0) << "and DC is rejected";

    // The documented limitation, pinned rather than left to be discovered. A band close to DC
    // has a lower transition far narrower than the upper one, and in zone 0 the upper one is
    // what sets the derived count -- so the skirt it affords does nothing at the lower edge.
    // Rejecting 2 kHz at 1 MS/s needs about 3.3/0.002 taps, four times the ceiling.
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
    // The figure in the document: 32,768 samples at 1 MS/s decimating by four gives 7.6 Hz a
    // bin against 30.5 undecimated. Pinned here because it is quoted outside this repository.
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
    // A rate so small the bin width underflows to zero is not a frequency scale either.
    EXPECT_EQ(DSP_EARG, dsp_band_map(1e-316, 0.0, 5e-317, 65536, 4096, &m))
        << "a bin width that underflows";
    EXPECT_DOUBLE_EQ(0.0, dsp_binwidth(1e-316, 65536, 4096)) << "the premise";
    // And a zone offset too large to store in dsp_real, which is reachable only where
    // dsp_real is narrower than double.
    if (kSingle) {
        EXPECT_EQ(DSP_EARG, dsp_band_map(1e42, 3e41, 4e41, 65536, 2, &m))
            << "a zone offset past FLT_MAX";
        EXPECT_GT(dsp_binwidth(1e42, 65536, 2), 0.0) << "while the bin width itself is storable";
    }
    // Every refusal leaves the map zeroed, so a caller ignoring the code cannot plot against
    // a half-built scale.
    EXPECT_EQ(0.0, m.f0);
    EXPECT_EQ(0.0, m.binhz);
    EXPECT_EQ(0, m.sense);
    EXPECT_EQ(0, m.zone);
    // The accepting case, and bin_hz on a null map.
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
    // A sense that is neither direction is not a map: the reduction would mirror the window
    // by a factor of zero and collapse every segment onto one bin.
    for (int bad : {0, 2, -2, 99}) {
        dsp_bandmap m2 = ok;
        m2.sense = bad;
        EXPECT_EQ(DSP_EARG, dsp_reduce(pwr.data(), m, 0, m - 1, nseg, &m2, -120.0, 20.0, 1e-9,
                                       db.data(), hz.data()))
            << "sense " << bad;
    }
    // A non-finite zone offset reaches hz directly.
    for (double bad : {kNaN, kInf, -kInf}) {
        dsp_bandmap m2 = ok;
        m2.f0 = bad;
        EXPECT_EQ(DSP_EARG, dsp_reduce(pwr.data(), m, 0, m - 1, nseg, &m2, -120.0, 20.0, 1e-9,
                                       db.data(), hz.data()));
    }
    // And more trace points than the segment arithmetic is bounded for.
    EXPECT_EQ(DSP_EARG, dsp_reduce(pwr.data(), m, 0, m - 1, DSP_NSEG_MAX + 1, &ok, -120.0, 20.0,
                                   1e-9, db.data(), hz.data()))
        << "past DSP_NSEG_MAX";
}

#endif /* DSP_BANDPASS */

// ---------------------------------------------------------------------------
// distortion and noise
// ---------------------------------------------------------------------------

// A spectrum built here rather than measured, so every answer is arithmetic. All bins are
// the floor except two lines: 1.0 V at bin 60 and 0.05 V at bin 120, which is 0.05 by
// definition. The floor is 1e-10 in power, exactly -100.0 dBV. The window stops at bin 130
// so the third harmonic does not fit, which holds the harmonic set to one line. 130 window
// bins less two skirts of seven leaves 116, so the integrated noise is 1.16e-8 and the
// ratio against a 1.0 V fundamental is 79.355 dB.
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

// The three figures are not independent: the fundamental, the per-bin mean and the bin
// count fix the ratio. Asserted as the identity, which is what caught nothing being
// double-counted when a skirt overlapped a line.
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

// A fundamental twelve orders of magnitude over the floor would drag a mean that included
// it up by 20 dB. The skirt is what makes the figure mean anything.
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

// A fundamental above half the window has no harmonic inside it, so there is no distortion
// figure. nharm is the flag; thd stays at the zeroed value and must not be read as clean.
TEST(ThdNoise, NoHarmonicInTheWindowLeavesNharmZero) {
    std::vector<dsp_real> pwr(256, (dsp_real)1e-10);
    pwr[100] = (dsp_real)1.0;
    dsp_thdn r{};
    ASSERT_EQ(DSP_OK, dsp_thd_noise(pwr.data(), 256, 1, 130, 0, 0.0, DSP_THD_MAINS_BOTH, nullptr, &r));
    EXPECT_EQ(0, r.nharm);
    EXPECT_EQ(0.0, r.thd);
    EXPECT_GT(r.nnoise, 0) << "the noise figures stand on their own";
}

// Bin 0 and the kdc bins above it carry the mean-removal error, so a large value there is
// not a candidate however low k0 is.
TEST(ThdNoise, TheDcRegionCannotBecomeTheFundamental) {
    std::vector<dsp_real> pwr(256, (dsp_real)1e-10);
    pwr[0] = (dsp_real)1e6;
    pwr[2] = (dsp_real)1e6;
    pwr[60] = (dsp_real)1.0;
    dsp_thdn r{};
    ASSERT_EQ(DSP_OK, dsp_thd_noise(pwr.data(), 256, 0, 130, 3, 0.0, DSP_THD_MAINS_BOTH, nullptr, &r));
    EXPECT_NEAR(60.0, r.f0, 1e-6) << "the DC region won the fundamental";
}

// Through the real pipeline, not a hand-built array: a 1 V tone with a 0.05 V second
// harmonic, both on bin centres so leakage cannot be blamed for the answer.
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
        // 30, not a tighter number: on a synthesis with no noise in it at all the figure
        // is the WINDOW's integrated leakage, and Kaiser 4's sidelobes are 30 dB down,
        // which caps it at 36.7 dB however wide the skirt gets. See the ceiling test.
        EXPECT_GT(r.snr_db, 30.0) << c.label() << " snr=" << r.snr_db;
        EXPECT_NE(0, r.signal) << c.label() << " a 1 V tone is a signal";
    }
}

// With no tables the amplitude is the root of the bin, which is what a caller with no plan
// gets. The figure is then low by the scalloping loss, so the test uses a bin centre.
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
    // An all-zero spectrum is not an error: there is simply nothing in it.
    std::vector<dsp_real> zero(256, (dsp_real)0.0);
    EXPECT_EQ(DSP_OK, dsp_thd_noise(zero.data(), 256, 1, 130, 0, 0.0, DSP_THD_MAINS_BOTH, nullptr, &r));
    EXPECT_EQ(0, r.nharm);
    EXPECT_EQ(0, r.nnoise);
}

// The hostile-value rule for this entry point: a NaN or an infinity in the spectrum must
// not put one in the result, and must not win the fundamental.
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

// Two lines closer than a skirt are one line as far as the window is concerned, and
// counting both would count one of them twice. The second harmonic of a fundamental in
// bin 2 lands in bin 4, inside the first line's skirt.
TEST(ThdNoise, AHarmonicInsideThePreviousSkirtIsNotCounted) {
    std::vector<dsp_real> pwr(256, (dsp_real)1e-10);
    pwr[2] = (dsp_real)1.0;
    pwr[4] = (dsp_real)0.25;
    dsp_thdn r{};
    ASSERT_EQ(DSP_OK, dsp_thd_noise(pwr.data(), 256, 1, 130, 0, 0.0, DSP_THD_MAINS_BOTH, nullptr, &r));
    EXPECT_NEAR(2.0, r.f0, 1e-6);
    // Bin 4 is inside bin 2's skirt, so it is not a harmonic; bin 6 and up are clear and
    // hold only the floor, so whatever harmonics are counted contribute almost nothing.
    EXPECT_LT(r.thd, 0.01) << "a line inside the skirt was counted as a harmonic";
}

// How much S/N a PURE tone can show: the window's own integrated leakage, with no noise in
// the signal at all. This is the ceiling every measured S/N sits under, so a reading near
// it is leakage-limited rather than noise-limited.
//
// The bounds are the measured values less two dB. They exist as a REGRESSION guard on the
// skirt: a fixed three bins instead of the window's own lobe read 38.5 dB on Kaiser 18 and
// 50.9 on Kaiser 15, against the 124.9 and 117.5 here.
TEST(ThdNoise, TheWindowSetsACeilingOnReportableSnr) {
    struct Want {
        int kind;
        double beta;
        double floor_db;
    };
    // Kaiser 4 and 6 are SIDELOBE-limited -- 30 and 40 dB down, integrated over the band --
    // so no skirt can lift them. That is the window's property, not a defect.
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

// The lobe half-width against the window's OWN transform, not against the formula twice
// over: G(x) is scanned for its first null and the answer has to bracket it. Without this
// the constants in dsp_window_lobe are only as good as the handbook they came from.
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
    // Reachable arguments a plan would refuse: none may convert a NaN to an int.
    EXPECT_EQ(2, dsp_window_lobe(DSP_WINDOW_KAISER, kNaN));
    EXPECT_EQ(2, dsp_window_lobe(DSP_WINDOW_KAISER, -1.0));
    EXPECT_GE(dsp_window_lobe(DSP_WINDOW_KAISER, kInf), 2);
    EXPECT_GE(dsp_window_lobe(DSP_WINDOW_KAISER, 1e300), 2);
}

// A plan records its window's lobe, which is what makes the skirt automatic.
TEST(WindowLobe, APlanRecordsItsOwnLobe) {
    for (const WinCfg &c : ShippedWindows()) {
        Plan p(1024, c.kind, c.beta);
        ASSERT_EQ(DSP_OK, p.rc()) << c.label();
        EXPECT_EQ(dsp_window_lobe(c.kind, c.beta), p->ip.lobe) << c.label();
        EXPECT_GE(p->ip.lobe, 2) << c.label();
    }
}

// The margin: a noise peak is not a fundamental. 17 dB over the mean is what a shorted
// input's peak stood 17.1 dB over the per-bin mean and a floating input's best
    // surviving candidate 38.8, where an 8 Vp-p tone stood 117.9.
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
        // The floor is still the one useful number there.
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

// Adding a tone must not move the measured noise floor, wherever it lands between bins.
// That is the property the clip exists for, and it is differential so it does not depend on
// the build's floating-point precision the way a noiseless synthesis does. Before the clip
// a half-bin Hann tone lifted the reported floor by 20 dB over the floor actually present.
TEST(ThdNoise, AToneDoesNotLiftTheMeasuredNoiseFloor) {
    for (const WinCfg &c : ShippedWindows()) {
        Plan p(16384, c.kind, c.beta);
        ASSERT_EQ(DSP_OK, p.rc());
        // Broadband noise well above the leakage the clip leaves, well below the tone.
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
            // Kaiser's sidelobes are near-flat where Hann's roll off at 18 dB an octave,
            // so at low beta their integrated energy genuinely RAISES the broadband floor.
            // That is not an outlier and no clip can remove it: beta 4 is labelled "-30dB"
            // on the panel for this reason, and measured 6 to 10 dB of lift here.
            const double bound = (c.kind == DSP_WINDOW_KAISER && c.beta <= 6.0) ? 12.0 : 2.0;
            EXPECT_NEAR(bare.noise_db, r.noise_db, bound)
                << c.label() << " frac=" << frac << ": a 1 V tone moved the floor from "
                << bare.noise_db << " to " << r.noise_db;
        }
    }
}

// What the clip costs on noise that has no outliers at all. A windowed FFT of Gaussian
// noise gives exponentially distributed bin powers, so this is the distribution the clip
// has to leave alone. Reported against the arithmetic mean of the same bins.
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
        // Measured -0.64 dB at 512 bins and -0.49 at 4096, keeping 95% of them: on a
        // distribution with no outliers the clip converges after a pass or two. 1.5 dB
        // is the bound; past that the clip would be eating the noise it is measuring.
        EXPECT_NEAR(raw_db, r.noise_db, 1.5)
            << "nb=" << nb << " bias " << (r.noise_db - raw_db) << " dB, kept " << r.nnoise;
        // Against the SAMPLED count, not nb: the figures stride the window, so nnoise is
        // how many of the sampled bins survived the clip rather than how many exist.
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

// The two clamps the window arithmetic needs, each reached on purpose.
TEST(ThdNoise, TheWindowClampsHoldAtTheEdges) {
    std::vector<dsp_real> pwr(256, (dsp_real)1e-10);
    pwr[60] = (dsp_real)1.0;
    pwr[120] = (dsp_real)0.0025;
    dsp_thdn r{};
    // k1 past the array: clamped to nbins - 1 rather than read off the end. Harmonics 3
    // and 4 fit in that wider window and hold only the floor, so they count but add
    // nothing -- which is itself the standard definition working.
    ASSERT_EQ(DSP_OK, dsp_thd_noise(pwr.data(), 256, 1, 100000, 0, 0.0, DSP_THD_MAINS_BOTH, nullptr, &r));
    EXPECT_GE(r.nharm, 1);
    EXPECT_NEAR(0.05, r.thd, 1e-4) << "floor bins at 3f and 4f moved the figure";

    // The lower bound of a harmonic's search window dipping under k0: a fundamental in
    // the first reportable bin puts 2f at bin 2, so the window starts below it.
    std::vector<dsp_real> low(256, (dsp_real)1e-10);
    low[1] = (dsp_real)1.0;
    dsp_thdn q{};
    ASSERT_EQ(DSP_OK, dsp_thd_noise(low.data(), 256, 1, 130, 0, 0.0, DSP_THD_MAINS_BOTH, nullptr, &q));
    EXPECT_NEAR(1.0, q.f0, 1e-6);
    // 2f, 3f and 4f are inside bin 1's skirt and not resolvable. 5f and up are clear of it
    // but hold only the floor, so they count and contribute nothing -- which is the
    // standard definition, and why the figure stays at zero rather than going missing.
    EXPECT_GE(q.nharm, 1);
    EXPECT_LT(q.thd, 1e-3) << "floor bins at the harmonics moved the figure";
}

// Nothing but zeros where a harmonic should be. Not an error and not a harmonic: the
// search finds no positive bin and moves on, which is the path a notched input takes.
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

// Mains pickup is not the signal. Bins at 10 Hz, so 50 and 60 and their multiples land on
// bin centres. Measured on the instrument, a floating input read 60 Hz at -25.4 dBV with
// harmonics out to 540, and taking that as the fundamental reported 11.04% distortion.
TEST(ThdNoise, MainsPickupIsPassedOver) {
    const double binhz = 10.0;
    auto spectrum = [](const std::vector<std::pair<int, double>> &lines) {
        std::vector<dsp_real> p(256, (dsp_real)1e-12);
        for (const auto &l : lines)
            p[(size_t)l.first] = (dsp_real)l.second;
        return p;
    };
    // 60 Hz with harmonics at 120, 180 and 540, every one under -22 dBV.
    {
        auto p = spectrum({{6, 1e-3}, {12, 1e-5}, {18, 1e-6}, {54, 1e-7}});
        dsp_thdn r{};
        ASSERT_EQ(DSP_OK, dsp_thd_noise(p.data(), 256, 1, 254, 0, binhz, DSP_THD_MAINS_BOTH, nullptr, &r));
        EXPECT_EQ(0, r.signal) << "60 Hz hum read as a signal, f0=" << r.f0_hz;
        EXPECT_GT(r.nnoise, 0) << "the floor is still the useful number";
    }
    // 50 Hz, for Europe, with its harmonics.
    {
        auto p = spectrum({{5, 1e-3}, {10, 1e-5}, {15, 1e-6}});
        dsp_thdn r{};
        ASSERT_EQ(DSP_OK, dsp_thd_noise(p.data(), 256, 1, 254, 0, binhz, DSP_THD_MAINS_BOTH, nullptr, &r));
        EXPECT_EQ(0, r.signal) << "50 Hz hum read as a signal, f0=" << r.f0_hz;
    }
    // A real tone WEAKER than the hum still wins, because the hum is passed over. 1230 Hz
    // is a multiple of neither 50 nor 60.
    {
        auto p = spectrum({{6, 1e-3}, {12, 1e-5}, {123, 1e-4}});
        dsp_thdn r{};
        ASSERT_EQ(DSP_OK, dsp_thd_noise(p.data(), 256, 1, 254, 0, binhz, DSP_THD_MAINS_BOTH, nullptr, &r));
        EXPECT_NE(0, r.signal);
        EXPECT_NEAR(1230.0, r.f0_hz, 1.0) << "the hum outranked a real tone";
    }
    // A LOUD mains-frequency tone is a tone: -22 dBV is the line and 0 dBV is over it.
    {
        auto p = spectrum({{6, 1.0}});
        dsp_thdn r{};
        ASSERT_EQ(DSP_OK, dsp_thd_noise(p.data(), 256, 1, 254, 0, binhz, DSP_THD_MAINS_BOTH, nullptr, &r));
        EXPECT_NE(0, r.signal) << "a 0 dBV 60 Hz tone was discounted as hum";
        EXPECT_NEAR(60.0, r.f0_hz, 1.0);
    }
    // And a quiet tone above the cutoff is a tone even on a mains multiple: 1200 = 20 x 60.
    {
        auto p = spectrum({{120, 1e-4}});
        dsp_thdn r{};
        ASSERT_EQ(DSP_OK, dsp_thd_noise(p.data(), 256, 1, 254, 0, binhz, DSP_THD_MAINS_BOTH, nullptr, &r));
        EXPECT_NE(0, r.signal) << "1200 Hz was discounted as a mains multiple";
        EXPECT_NEAR(1200.0, r.f0_hz, 1.0);
    }
    // binhz 0 switches the rule off, which is what a caller working in bins wants.
    {
        auto p = spectrum({{6, 1e-3}});
        dsp_thdn r{};
        ASSERT_EQ(DSP_OK, dsp_thd_noise(p.data(), 256, 1, 254, 0, 0.0, DSP_THD_MAINS_BOTH, nullptr, &r));
        EXPECT_NE(0, r.signal) << "the rule fired without a bin width to place 60 Hz with";
        EXPECT_EQ(0.0, r.f0_hz);
    }
    // Fine bins: the tolerance is the bin width or 2 Hz, whichever is wider, because a hum
    // line does not sit at exactly 60.000 Hz. 62 Hz is discounted here and would not be on
    // the bin width alone. 7 Hz is a multiple of neither 50 nor 60, so it stays eligible and
    // the weaker of the two lines is the one named.
    {
        auto p = spectrum({{62, 1e-3}, {7, 1e-4}});
        dsp_thdn r{};
        ASSERT_EQ(DSP_OK, dsp_thd_noise(p.data(), 256, 1, 254, 0, 1.0, DSP_THD_MAINS_BOTH, nullptr, &r));
        EXPECT_NEAR(7.0, r.f0_hz, 0.5) << "62 Hz of hum outranked a line at 7";
    }
}

// Selecting one mains frequency gives back every multiple of the other. Two quiet lines,
// 50 and 60 Hz, at 2 Hz bins so the 2 Hz tolerance cannot reach from one to the other.
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
    // The floor reports in every one of those, because it always does.
    for (const auto &c : cases) {
        dsp_thdn r{};
        ASSERT_EQ(DSP_OK, dsp_thd_noise(p.data(), 256, 1, 254, 0, binhz, c.mains,
                                        nullptr, &r));
        EXPECT_GT(r.nnoise, 0) << c.what;
    }
}

// A frequency that is neither mains is refused, not ignored: it would discount a band
// nothing picks up and the figures would look plausible over the hole.
TEST(ThdNoise, AnUnknownMainsSelectionIsRefused) {
    std::vector<dsp_real> p(256, (dsp_real)1e-12);
    p[30] = (dsp_real)2e-3;
    dsp_thdn r{};
    EXPECT_EQ(DSP_EARG, dsp_thd_noise(p.data(), 256, 1, 254, 0, 2.0, 55, nullptr, &r));
    EXPECT_EQ(DSP_EARG, dsp_thd_noise(p.data(), 256, 1, 254, 0, 2.0, -2, nullptr, &r));
    // And the three that are not refused.
    EXPECT_EQ(DSP_OK, dsp_thd_noise(p.data(), 256, 1, 254, 0, 2.0, 50, nullptr, &r));
    EXPECT_EQ(DSP_OK, dsp_thd_noise(p.data(), 256, 1, 254, 0, 2.0, 60, nullptr, &r));
    EXPECT_EQ(DSP_OK, dsp_thd_noise(p.data(), 256, 1, 254, 0, 2.0, 0, nullptr, &r));
}

// The three figures satisfy 20log10(amp0) - snr_db - noise_db == 10log10(nnoise * stride).
// Run PAST the sampling threshold on purpose: this is the only cross-check on these numbers,
// and against nnoise alone it is out by 10log10(stride) -- 9 dB at 8192 bins, which is the
// window at 16,384 samples.
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

// Every figure that leaves here is finite. Bins near the element ceiling overflow the
// harmonic sum and the noise sum, and an infinity formatted into a display string is a
// refused parameter and a modal dialog on the front panel. A figure that cannot be computed
// comes back absent -- its flag cleared -- rather than as a number no test could predict.
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
    // And with every bin at the ceiling, where the noise sum itself overflows.
    std::fill(pwr.begin(), pwr.end(), huge);
    ASSERT_EQ(DSP_OK, dsp_thd_noise(pwr.data(), 512, 1, 500, 0, 0.0, DSP_THD_MAINS_BOTH,
                                    nullptr, &r));
    EXPECT_TRUE(std::isfinite(r.noise_db)) << "floor=" << r.noise_db;
    EXPECT_TRUE(std::isfinite(r.snr_db));
    EXPECT_TRUE(std::isfinite(r.thd));
}

// `out` is zeroed on every refusal, not only the late ones: a caller that reads the struct
// after an EARG must not see the previous frame's figures.
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

// A NaN bin is dropped wherever it sits, and does not take the segment's real maximum with
// it. Seeding the running maximum from the segment's first bin made a NaN THERE stick --
// nothing compares greater than a NaN -- so one bin suppressed a whole segment, which is 32
// bins at 16,384 samples. The two cases differ only in where the NaN is.
TEST(Reduce, ANanBinDoesNotSuppressItsSegment) {
    dsp_bandmap m{};
    ASSERT_EQ(DSP_OK, dsp_band_map(100000.0, 0.0, 50000.0, 64, 1, &m));
    const double nan = std::numeric_limits<double>::quiet_NaN();
    // 64 bins over 8 segments is 8 bins each, so bins 8..15 are segment 1.
    for (int where : {8, 9, 15}) {
        std::vector<dsp_real> pwr(64, (dsp_real)1e-12), db(8), hz(8);
        pwr[(size_t)where] = (dsp_real)nan;
        pwr[12] = (dsp_real)1.0;             // 0 dBV, same segment
        ASSERT_EQ(8, dsp_reduce(pwr.data(), 64, 0, 63, 8, &m, -120.0, 20.0, 1e-9, db.data(),
                                hz.data()));
        EXPECT_NEAR(0.0, (double)db[1], 1e-5)
            << "a NaN at bin " << where << " hid the tone at bin 12";
    }
    // An all-NaN segment has no maximum at all and plots at the floor.
    {
        std::vector<dsp_real> pwr(64, (dsp_real)1e-12), db(8), hz(8);
        for (int k = 8; k <= 15; k++)
            pwr[(size_t)k] = (dsp_real)nan;
        ASSERT_EQ(8, dsp_reduce(pwr.data(), 64, 0, 63, 8, &m, -120.0, 20.0, 1e-9, db.data(),
                                hz.data()));
        EXPECT_EQ((dsp_real)-120.0, db[1]);
    }
}

// Bin 0 is the only bin a one-bin spectrum has, and the bin-m/2 write is bin 0 again there.
// No plan reaches m of 1 -- dsp_plan_init refuses n below 4 -- but this is published.
TEST(Power, OneBinAnswersForThatBinRatherThanWrongly) {
    const dsp_real re[2] = {(dsp_real)3.0, (dsp_real)0.0};
    const dsp_real im[2] = {(dsp_real)4.0, (dsp_real)0.0};
    // utr and uti are separate arrays rather than one passed twice: the header refuses
    // overlap between any two pointer arguments, read-only or not.
    const dsp_real utr[2] = {(dsp_real)1.0, (dsp_real)0.0};
    const dsp_real uti[2] = {(dsp_real)1.0, (dsp_real)0.0};
    dsp_real out[2] = {(dsp_real)-1.0, (dsp_real)-1.0};
    dsp_power(re, im, 1, utr, uti, out, 1.0);
    // X[0] = 2*(Re + Im) = 14, so the power is 196. The mirror formula would give 100.
    EXPECT_NEAR(196.0, (double)out[0], 1e-3);
}

// Taps on a plan that does not decimate are refused at configure time. Accepting them
// promised a filter that could never run: dsp_spectrum_run filters only where the decimation
// makes it necessary, and a decim-1 plan has no output buffer to filter into, so a 500 Hz
// tone passed a 2-20 kHz band-pass at -0.08 dBV with nothing in any return value to say so.
TEST(Refusals, TapsOnANonDecimatingPlanAreRefused) {
    dsp_real h[DSP_FIR_MAXTAPS];
    int l = 21;
    for (int i = 0; i < l; i++)
        h[i] = (dsp_real)(1.0 / (double)l);
#if DSP_BANDPASS
    // The design side admits a decim-1 band-pass, which is how the configuration arises.
    // A low-pass build has no such design, so the hand-made taps above stand in for it.
    l = dsp_fir_design(h, DSP_FIR_MAXTAPS, 100000.0, 2000.0, 20000.0, 1, 0);
    ASSERT_GT(l, 0) << "the design side admits a decim-1 band-pass";
#endif
    Plan flat(1024, DSP_WINDOW_HANN, 0, 1);
    ASSERT_EQ(DSP_OK, flat.rc());
    EXPECT_EQ(DSP_EARG, dsp_plan_set_fir(&flat.get(), h, l))
        << "a filter this plan could never apply";
    EXPECT_EQ(0, flat.get().ntaps) << "and nothing was installed";
    EXPECT_EQ(0, dsp_plan_set_fir(&flat.get(), nullptr, 0)) << "clearing is still fine";
    // The same taps on a decimating plan are accepted.
    Plan dec(1024, DSP_WINDOW_HANN, 0, 4);
    ASSERT_EQ(DSP_OK, dec.rc());
    EXPECT_EQ(l, dsp_plan_set_fir(&dec.get(), h, l));
}

// Hostile integers. kdc and nbins are both in a caller's hands, and `1 + kdc` and
// `nbins - 1` are signed arithmetic that overflowed at INT_MAX and INT_MIN -- undefined, and
// trapped by the sanitiser build. Clamped now, so these return instead of trapping.
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
    // Clamped to nbins-1, which excludes the whole window, so the window check refuses it.
    // The point is that it returns at all: this trapped before.
    EXPECT_EQ(DSP_EARG, dsp_thd_noise(pwr.data(), 4096, 1, 4000, INT_MAX, 10.0,
                                      DSP_THD_MAINS_BOTH, nullptr, &r)) << "kdc at INT_MAX";
    EXPECT_EQ(DSP_OK, dsp_thd_noise(pwr.data(), 4096, 1, 4000, INT_MIN, 10.0,
                                    DSP_THD_MAINS_BOTH, nullptr, &r)) << "kdc at INT_MIN";
    // A real ip, because the null check comes first and would hide the nbins path.
    Plan ip(64, DSP_WINDOW_HANN);
    ASSERT_EQ(DSP_OK, ip.rc());
    double d = 0.0, a = 0.0;
    EXPECT_EQ(DSP_EDECLINE, dsp_peak_interp(&ip->ip, pwr.data(), 5, INT_MIN, &d, &a))
        << "nbins at INT_MIN";
    EXPECT_EQ(DSP_EDECLINE, dsp_peak_interp(&ip->ip, pwr.data(), 1, 2, &d, &a))
        << "a two-bin spectrum has no interior bin";
}

// Every code has a message, nothing returns NULL, and nothing is long enough to overrun a
// status line. A bare -2 on the glass tells an operator nothing.
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
    // Distinct messages, so a reader can tell two refusals apart.
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

// The yield is called, called a bounded number of times, and never per sample. A primitive
// that runs a whole frame without yielding leaves the panel dead for its duration.
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
        // Cleared, and then nothing is called.
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

// The spectrum is the same whether a yield is installed or not: the callback is a boundary
// marker, not part of the arithmetic.
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

// ---------- dsp_band_bins: hertz to the k0..k1 every windowed call takes ----------

// The defining property, asserted as an inverse rather than against expected numbers: every
// bin in the window is inside the band, and the bin outside each end is outside it. An
// off-by-one either way breaks one half of this and nothing else would notice.
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

// The fault the inward rounding exists to prevent. A start frequency under one bin width
// rounded DOWN gives bin 0, which is DC -- so the removed mean reads as a tone and the
// distortion figures can take it for the fundamental. The control is the floor() answer.
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
    // A start exactly on a bin keeps that bin, which is the boundary ceil must not move.
    ASSERT_EQ(DSP_OK, dsp_band_bins(&map, map.binhz * 3.0, 49000.0, nbins, &k0, &k1));
    EXPECT_EQ(3, k0) << "a start exactly on bin 3 keeps bin 3";
}

// One rule, two implementations. fftsa.sg_window_bins in tsp/spectrum_graph.tsp is the same
// arithmetic one-based: ceil(flo/binhz) + 1 and floor(fhi/binhz) + 1. Pinned here against
// the formula so the C and the Lua cannot drift apart silently -- the trace and all three
// distortion figures are computed over this window.
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

// An odd zone arrives reversed, so the high frequency is the LOW index. The edges swap and
// each keeps its own rounding; taking them unswapped gives k1 < k0, which the clamp would
// then hide as a one-bin window.
//
// Only a band-pass build reaches a zone above 0: a DSP_BANDPASS=0 library refuses a non-zero
// flo outright, so there is no reversed map to test against.
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

// The case above straddles bin 10's centre, so both edges round to 10 and the never-empty
// repair never runs. A band lying strictly between two centres is what inverts them: the low
// edge ceils up to 11 and the high edge floors down to 10, and without the repair the window
// would come back as 11..10, which every caller taking k0..k1 reads as no bins at all.
TEST(BandBins, ABandBetweenTwoBinCentresStillReportsOneBin) {
    const double fs = 1e5;
    const int n = 512, nbins = n / 2;
    dsp_bandmap map{};
    ASSERT_EQ(DSP_OK, dsp_band_map(fs, 0.0, fs / 2.0, n, 1, &map));
    // The premise, in the rule's own arithmetic: ceil of the low edge exceeds floor of the
    // high one, so the repair is the only thing standing between this and an empty window.
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
    // A band wholly above the spectrum clamps to the last bin rather than refusing: the
    // display can ask for one while a smaller rate is still in force.
    k0 = -1;
    k1 = -1;
    EXPECT_EQ(DSP_OK, dsp_band_bins(&map, 1e9, 2e9, nbins, &k0, &k1));
    EXPECT_EQ(nbins - 1, k0);
    EXPECT_EQ(nbins - 1, k1);
}

#if DSP_CHECK_OVERLAP
// The per-frame primitives all know both extents of every buffer they are given, so each
// refuses an output that shares bytes with another output or with the bins it reads. One
// buffer is carved into overlapping slices, which is the mistake a caller reusing scratch
// space would actually make, and each call is checked against the same call with its own
// buffers so a refusal cannot be mistaken for an unrelated failure.
TEST(Overlap, EveryFramePrimitiveRefusesSlicesOfOneBuffer) {
    const int n = 256, nbins = n / 2, nseg = 16, want = 4;
    std::vector<dsp_real> pool((size_t)nbins * 4, (dsp_real)1e-9);
    for (int k = 8; k < nbins; k += 11)
        pool[(size_t)k] = (dsp_real)1.0;
    dsp_real *pwr = pool.data();
    dsp_real *sep1 = pool.data() + nbins;
    dsp_real *sep2 = pool.data() + nbins * 2;
    const dsp_bandmap m = FlatMap(1e5 / (double)n);

    // dsp_reduce: the premise first, with two separate traces.
    EXPECT_EQ(nseg, dsp_reduce(pwr, nbins, 0, nbins - 1, nseg, &m, -120.0, 20.0, 1e-9,
                               sep1, sep2));
    EXPECT_EQ(DSP_EARG, dsp_reduce(pwr, nbins, 0, nbins - 1, nseg, &m, -120.0, 20.0, 1e-9,
                                   sep1, sep1)) << "db and hz in one buffer";
    EXPECT_EQ(DSP_EARG, dsp_reduce(pwr, nbins, 0, nbins - 1, nseg, &m, -120.0, 20.0, 1e-9,
                                   sep1, sep1 + nseg / 2)) << "db and hz as overlapping slices";
    EXPECT_EQ(DSP_EARG, dsp_reduce(pwr, nbins, 0, nbins - 1, nseg, &m, -120.0, 20.0, 1e-9,
                                   pwr, sep2)) << "db inside the bins it reduces";

    // dsp_peaks: bin is int, frac and amp are dsp_real, all three sized by want.
    std::vector<int> bins((size_t)want * 2, 0);
    EXPECT_GE(dsp_peaks(pwr, nbins, 0, nbins - 1, 0, want, nullptr, bins.data(), sep1, sep2), 1);
    EXPECT_EQ(DSP_EARG, dsp_peaks(pwr, nbins, 0, nbins - 1, 0, want, nullptr, bins.data(),
                                  sep1, sep1)) << "frac and amp in one buffer";
    EXPECT_EQ(DSP_EARG, dsp_peaks(pwr, nbins, 0, nbins - 1, 0, want, nullptr, bins.data(),
                                  pwr, sep2)) << "frac inside the bins";
    EXPECT_EQ(DSP_EARG, dsp_peaks(pwr, nbins, 0, nbins - 1, 0, want,
                                  nullptr, reinterpret_cast<int *>(sep1), sep1, sep2))
        << "bin and frac sharing bytes across types";

    // dsp_thd_noise writes a struct, and zeroes it before reading the bins.
    dsp_thdn r{};
    EXPECT_EQ(DSP_OK, dsp_thd_noise(pwr, nbins, 1, nbins - 1, 0, 100.0, DSP_THD_MAINS_BOTH,
                                    nullptr, &r));
    EXPECT_EQ(DSP_EARG, dsp_thd_noise(pwr, nbins, 1, nbins - 1, 0, 100.0, DSP_THD_MAINS_BOTH,
                                      nullptr, reinterpret_cast<dsp_thdn *>(pwr)))
        << "the figures written over the spectrum they describe";

    // dsp_load packs the record into two halves.
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
// One object for both edges is detected, not left to the caller. Unchecked it would return
// the window as k1 twice, which reads as a legal one-bin span rather than as a mistake.
TEST(BandBins, OneObjectForBothEdgesIsRefused) {
    const double fs = 1e5;
    const int n = 512, nbins = n / 2;
    dsp_bandmap map{};
    ASSERT_EQ(DSP_OK, dsp_band_map(fs, 0.0, fs / 2.0, n, 1, &map));
    // The premise: with two objects this very band succeeds and the edges differ, so the
    // refusal below is about the aliasing and not about the band.
    int k0 = -1, k1 = -1;
    ASSERT_EQ(DSP_OK, dsp_band_bins(&map, 1000.0, 20000.0, nbins, &k0, &k1));
    ASSERT_LT(k0, k1) << "the band has to span more than one bin for this to mean anything";
    int both = 7;
    EXPECT_EQ(DSP_EARG, dsp_band_bins(&map, 1000.0, 20000.0, nbins, &both, &both));
    EXPECT_EQ(0, both) << "zeroed on a refusal, like every other refusal that can be";
}
#endif

// d_out and amp_out are both documented nullable, so the check has to catch one object
// without catching the legal NULL/NULL call.
TEST(PeakInterp, OneObjectForBothOutputsIsRefusedAndTwoNullsAreNot) {
    Plan p(512, DSP_WINDOW_HANN);
    auto x = ToneAtBin(512, 64.37);
    ASSERT_EQ(p->m, dsp_spectrum_run(&p.get(), x.data(), 512, nullptr));
    int bin[6];
    const int found = dsp_peaks(p->pwr, p->m, 1, p->m - 1, p->kdc, 6, &p->ip, bin,
                                nullptr, nullptr);
    ASSERT_GE(found, 1);
    // The premise: two objects estimate this peak, so a refusal is the aliasing.
    double d = -99.0, amp = -99.0;
    ASSERT_EQ(DSP_OK, dsp_peak_interp(&p->ip, p->pwr, bin[0], p->m, &d, &amp));
    ASSERT_NE(d, amp) << "one value in both would make the overwrite invisible";
#if DSP_CHECK_OVERLAP
    double one = -99.0;
    EXPECT_EQ(DSP_EARG, dsp_peak_interp(&p->ip, p->pwr, bin[0], p->m, &one, &one));
    EXPECT_EQ(-99.0, one) << "refused before anything is written";
#endif
    // The nullable cases do not turn on the overlap switch: two NULLs is a legal call that
    // wants the estimate and keeps neither figure, and stays legal either way.
    EXPECT_EQ(DSP_OK, dsp_peak_interp(&p->ip, p->pwr, bin[0], p->m, nullptr, nullptr));
    // One wanted and the other not, both ways round.
    double only = -99.0;
    EXPECT_EQ(DSP_OK, dsp_peak_interp(&p->ip, p->pwr, bin[0], p->m, &only, nullptr));
    EXPECT_NE(-99.0, only);
    only = -99.0;
    EXPECT_EQ(DSP_OK, dsp_peak_interp(&p->ip, p->pwr, bin[0], p->m, nullptr, &only));
    EXPECT_NE(-99.0, only);
}

} // namespace
