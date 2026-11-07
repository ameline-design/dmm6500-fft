# csrc — C translation of the TSP spectrum analyser's arithmetic

The library behind the "The Proposed C Side" section of `docs/NATIVE-DSP-PROPOSAL.md`, with a
GoogleTest suite ported from the Lua suite's numerical cases, a C99 translation unit that
compiles the same interface with `restrict` live, and a benchmark that compares the two FFT
decompositions against a modelled cache.

`tsp/fft_core.tsp`, `tsp/spectrum_ui.tsp` and `tsp/spectrum_graph.tsp` are the working
original and remain the reference. This is a translation, not a reimplementation: where the
Lua does something that looks odd, the reason is in a comment next to it there and next to
the same code here.

## Build and run

From the repository root:

```sh
cmake -S csrc -B /tmp/dspbuild
cmake --build /tmp/dspbuild
ctest --test-dir /tmp/dspbuild
```

GoogleTest v1.15.2 comes from `FetchContent`, so the first configure needs network access.
`ctest` registers eight tests: `dsp_single` and `dsp_double` are the GoogleTest suite with
`dsp_real` as `float` and as `double`, 204 cases in each; `dsp_c99_single` and `dsp_c99_double`
are `test/dsp_c99_test.c`, 102 checks in each; and the four `*_lowpass_*` are those same two built
with `-DDSP_BANDPASS=0`. All eight pass.

Two more switches change what is compiled rather than what is tested. `-DDSP_BANDPASS=0`
drops the band-pass arithmetic, and `-DDSP_CHECK_OVERLAP=0` drops the buffer-overlap checks:
the pairs whose extents are both known from a function's own arguments are compared on entry and
refused with `DSP_EARG` rather than left undefined. Those checks cost **368 bytes of text**,
23,084 against 22,716 at `-O2` on x86-64, which is 1.6 % of the library; they add a handful of
integer comparisons at an entry point and nothing inside any loop. On is the default and the
setting to ship; `-DDSP_CHECK_OVERLAP=OFF` is the other one, and the suite then drops the five
cases that test them, 199 instead of 204, and still passes:

```sh
cmake -S csrc -B /tmp/dspnoov -DDSP_CHECK_OVERLAP=OFF && ctest --test-dir /tmp/dspnoov
```

The C99 unit exists because the gtest suite is C++, where `DSP_RESTRICT` expands to nothing. 26
parameters carry a non-aliasing promise that the C++ build erases before the compiler sees it, so
without a C99 translation unit the arithmetic is never compiled the way the target will compile
it, and a C++-only construct in the header would go unnoticed until someone built the firmware.

Run a binary directly to see the measured figures the suite prints:

```sh
/tmp/dspbuild/dsp_test_single
/tmp/dspbuild/dsp_bench_single     # not a ctest target; see "Choosing a decomposition"
```

### The gates

All five have to pass. They find different things, which is why there are five.

| gate | how | state |
|---|---|---|
| warnings as errors | ~45 flags including `-Wconversion`, `-Wdouble-promotion`, `-Wbad-function-cast`, `-Wshift-sign-overflow`, `-Wdocumentation` | clean |
| `-Weverything` | `-DDSP_WEVERYTHING=ON`, less `-Wpadded` and seven documented exceptions | clean |
| sanitizers | `-DDSP_SANITIZE=ON`: ASan, UBSan, `float-cast-overflow`, `float-divide-by-zero`, `-fno-sanitize-recover=all` | 8/8 pass |
| static analysis | `clang-tidy` with `clang-analyzer-*`, `cert-*`, `bugprone-*`, `misc-*`, `performance-*`, `portability-*`, `readability-*` as errors | 0 findings |
| coverage | `-DDSP_COVERAGE=ON` and `llvm-cov` over `dsp.c` | 97.8 % lines, 100 % functions, 91.5 % branches |

```sh
cmake -S csrc -B /tmp/dspsan  -DDSP_SANITIZE=ON   -DCMAKE_BUILD_TYPE=Debug
cmake -S csrc -B /tmp/dspcov  -DDSP_COVERAGE=ON   -DCMAKE_BUILD_TYPE=Debug
clang-tidy -p /tmp/dspbuild --extra-arg=-isysroot --extra-arg="$(xcrun --show-sdk-path)" dsp.c
```

**Both halves of that clang-tidy line are needed, and without either it passes by not
looking.** `-p` needs a build configured with `-DCMAKE_EXPORT_COMPILE_COMMANDS=ON`; pointed at
a build directory without `compile_commands.json` it prints "Running without flags", analyses
with no include paths or defines, and reports every finding suppressed as non-user code. With
the database but no `-isysroot`, homebrew's clang-tidy cannot find `math.h` and stops at a
compiler error. Neither failure looks like a failure in the output.

The coverage tools have to match the compiler, not the PATH: the build uses `/usr/bin/cc`,
whose profiles are raw format v10, where homebrew's `llvm-profdata` expects v11 and refuses to
merge. Use `xcrun llvm-profdata` and `xcrun llvm-cov`.

Leak detection is not part of the sanitizer gate: `detect_leaks` is unsupported on macOS/arm64,
which is the host this is measured on. The library allocates nothing, so a leak could only come
from the test harness.

The library is compiled as strict C99:

```
-std=c99 -pedantic -pedantic-errors -Wall -Wextra -Werror -Wconversion -Wdouble-promotion
-Wshadow -Wstrict-prototypes -Wmissing-prototypes -Wmissing-declarations -Wcast-qual
-Wcast-align -Wpointer-arith -Wwrite-strings -Wundef -Wvla
```

and is clean under all of it. No GNU extensions, no VLAs, no anonymous structs, no
`long long`. `restrict` is used where it is true, through a `DSP_RESTRICT` macro that
expands to nothing in C++ — the test file is C++17 and has no such keyword, and `dsp.h` is
wrapped in `extern "C"` so it works from both. `-ffp-contract=off` is set on every target:
it stops a host silently fusing a multiply and an add the source wrote separately, which
would make the single build more accurate than a plain C compiler and hide the thing the
two-variant build exists to measure. It does not stop the target's compiler contracting an
expression the source wrote *as* a multiply-add.

## What is here

| file | |
|---|---|
| `dsp.h` | declarations with Doxygen, the error codes, the shipped constants, `dsp_plan` |
| `dsp.c` | the implementation: strict C99, no allocation, nothing from libc but `<math.h>`, `<string.h>` and `<stdint.h>` for `uintptr_t` |
| `test/dsp_test.cc` | the suite |
| `test/dsp_bench.c` | host timings and modelled cache traffic for both decompositions |
| `test/dsp_firbench.c` | the filter's cost against its source-record length, which is what `DSP_FIR_MAXM` bounds |

### What a source record costs

`DSP_FIR_MAXM` caps the record a decimating plan asks for, through
`(DSP_FIR_MAXM - maxtaps)/(n - 1)`. Two measurements say what that is buying.

`test/dsp_firbench.c`, on the host: **the filter's cost does not depend on the record length.**
Over `M` from 1,067 to 524,607 the cost an output does not move -- 0.23 ns a multiply-add, a
function of the tap count alone, because the output count is `n` whatever the decimation. 45
taps cost 9 ns an output and 383 cost 88. `DSP_FIR_MAXTAPS` is what bounds the arithmetic.

On a DMM6500, timing the app's own sequence (`digitize.count`, `clear`, `digitize.read`) at an
aperture of 1 us: the wall time of a capture is **`max(M/fs, M * 10.36 us)`**.

| M | wall s at 1 MS/s | `M/fs` s | us a reading |
|---:|---:|---:|---:|
| 8,192 | 0.0851 | 0.0082 | 10.39 |
| 16,384 | 0.1699 | 0.0164 | 10.37 |
| 65,536 | 0.6787 | 0.0655 | 10.36 |
| 262,144 | 2.7152 | 0.2621 | 10.36 |

The per-reading term is independent of the requested rate. At `M` of 65,536 the wall time is
0.679 s at 1 MS/s, 500 kS/s, 200 kS/s and 100 kS/s alike, with the buffer's timestamps
reporting the requested rate correctly in each case; only at 50 kS/s does it become `M/fs`,
1.3109 s against an ideal 1.3107. The terms cross near **96.5 kS/s**, which is the throughput
a capture actually sustains however fast the digitizer samples.

So 8192 is about 85 ms of capture. The value stands; the reason in the header did not, having
been carried over from a 22 us-a-reading figure for crossing the interpreter boundary. The one
place it bites: `n` of 4096 at decimation 2 wants `M` of 8235, **43 readings over the
ceiling**, so decimation falls to 1 at 4096 and above. Admitting it costs 85.3 ms rather than
84.9.
| `CMakeLists.txt` | fetches GoogleTest, builds both precisions, registers the tests |

Requirements, and how they are met:

- **No dynamic allocation.** The caller passes one arena. `dsp_plan_bytes(n, decim)` says
  how large, `dsp_plan_init` carves it, and the layout walk is a single function so the two
  cannot disagree. A size that cannot be met is refused at plan time with `DSP_ENOMEM`
  rather than mid-frame. `dsp_spectrum_run` allocates nothing.
- **No file-scope mutable state.** `dsp.c` has one file-scope object, `dsp_wincos`, which is
  `static const`. `Plan.TwoPlansSideBySideAgreeExactly` runs two plans interleaved and
  asserts bit-identical output.
- **32-byte alignment.** `DSP_ALIGN` is the e300c4's cache-block size, and `dsp_plan_init`
  refuses an arena off a block boundary — every one of the 31 possible offsets, not just an
  odd address. The four-step's eight-column gather depends on a block boundary to be one
  fill rather than two.
- **Double accumulators where it matters.** The window sum, the window-weighted mean, the
  gain-table cosine sums, the FIR and the final power scale accumulate in `double`; the
  arrays and the butterfly arithmetic are `dsp_real`. The interpolation tables are `double`
  in both builds — there are 102 of them and the inversion differences two nearly equal
  gains.

## Choosing a decomposition

Two are implemented behind `dsp_rfft`, chosen when the plan is built because the arena is sized
for the one that will run:

- `DSP_FFT_RADIX2` — textbook in-place radix-2, bit reversal from a precomputed swap list.
- `DSP_FFT_FOURSTEP` — `m = m1·m2`, `m1 ≤ m2`, both powers of two. `m2` sub-transforms of
  length `m1` gathered eight columns at a time, a twiddle fused into the scatter, `m1`
  contiguous sub-transforms of length `m2`, and a blocked transpose. A four-step request below
  `DSP_FS_MIN` (m = 64) builds a radix-2 plan instead, which `dsp_plan::method` reports.

`dsp_rfft` reads the decomposition off the arena rather than out of `dsp_plan::method`: the
arrays each one needs are disjoint, so the arena identifies its own method, and a field a caller
can reach cannot send a kernel at a buffer that is NULL.

A self-sorting Stockham is a third candidate and is **not** offered. The measurements below are
why: it is 1.4 to 1.5× the in-place form on traffic at every size, because each stage writes an
array it did not read and a write-allocate cache fetches those blocks first. It is kept in the
tables as the evidence for the decision, not in the code.

### Host timings, for what they are worth

`dsp_bench_single`, this machine, milliseconds per transform including the load:

| N | radix-2 | Stockham | four-step | live kB (radix-2) |
|---|---|---|---|---|
| 512 | 0.0006 | 0.0007 | 0.0011 | 4 — fits |
| 2048 | 0.0027 | 0.0030 | 0.0042 | 16 — fits |
| 8192 | 0.0121 | 0.0132 | 0.0175 | 64 |
| 16384 | 0.0256 | 0.0301 | 0.0366 | 128 |
| 32768 | 0.0563 | 0.0738 | 0.0769 | 256 |

**On this host radix-2 wins everywhere.** That is the expected answer and not the useful
one: this is an Apple Silicon machine with megabytes of cache, so the four-step's extra
gather, twiddle and transpose are pure cost and the traffic it saves is free anyway.

The host does show one thing worth having, though. Plotting the four-step against radix-2
by *working set* rather than by N, across both precision builds:

| live kB | build | four-step / radix-2 |
|---|---|---|
| 64 | single, N=8192 | 1.45 |
| 128 | single, N=16384 | 1.43 |
| 128 | double, N=8192 | 1.33 |
| 256 | single, N=32768 | 1.37 |
| 256 | double, N=16384 | 1.25 |
| 512 | double, N=32768 | **0.89** |

The ratio falls monotonically with working set and crosses 1.0 between 256 and 512 kB,
which is this machine's L2. The two builds agree where they overlap, at 128 kB and at
256 kB, so this is a property of the working set and not of the precision. **The four-step
overtakes the in-place form exactly when the data stops fitting in cache** — the mechanism
the model describes, measured here at a cache 16 times the target's.

### Modelled traffic for a 32 kB cache

The decision rests on this, because the host cannot show it. The model counts cache-block
fills and writebacks on the two signal arrays for one transform, 32-byte blocks, 32 kB
eight-way. Only the signal arrays: both read the same twiddle table in the same order,
so counting it cannot separate them and would bury the difference under a common term.

A pass is one sweep touching every block of `re` and `im`. An in-place pass reads a block,
modifies it and writes it back: one fill, one writeback. An out-of-place pass reads the
source and writes a different block, and a write-allocate cache fetches the destination
before merging: two fills, one writeback.

- **radix-2**: `log2(m)` butterfly stages plus one bit-reversal pass, all in place.
- **Stockham**: `log2(m)` out-of-place stages, plus a copy back when `log2(m)` is odd.
- **four-step**: three passes whatever `m` is, because each sub-transform is a few kB and
  completes without leaving the cache — the gather and scatter (out of place), the row
  transforms (in place), and the output transpose (out of place).

Single precision, fills + writebacks per transform:

| N | radix-2 | Stockham | four-step | four-step vs radix-2 |
|---|---|---|---|---|
| 8192 | 26,624 | 36,864 | 8,192 | 0.31 |
| 16384 | 57,344 | 86,016 | 16,384 | 0.29 |
| 32768 | 122,880 | 172,032 | 32,768 | 0.27 |

Two results:

1. **Stockham is worse than the in-place form on traffic, not better** — 1.4 to 1.5× — and
   the host agrees, placing it 5 to 30 % slower at every N. In-place reads and writes the
   same block; out-of-place writes a block it did not read, and a write-allocate cache
   fetches that first. Stockham buys the loss of one bit-reversal pass out of fourteen and
   pays half again on every stage. It also needs a second complex array, so its working set
   is 1.5× and it leaves the cache at a smaller N.
2. **The four-step moves 3.4 to 3.7× less data.**

### The decision, and the arithmetic behind it

**Ship the four-step.** `DSP_FFT_DEFAULT` is `DSP_FFT_FOURSTEP`.

The four-step costs about 36 % more non-memory work — that is the host figure at N = 32768
in single, where memory is free — and saves 90,112 block transactions out of 122,880. For
it to lose, those 90,112 transactions would have to cost less than the extra arithmetic.
The proposal estimates 4–10 ms for a 16,384-point transform, so roughly 1.7–4.0 M cycles;
scaling by `N log N` puts 32,768 at about 2.2× that, say 4 M cycles for radix-2.
Thirty-six per cent of that is 1.4 M cycles, so the break-even is **1.4 M / 90,112 ≈ 16
cycles per cache-block transaction**. A 32-byte fill from external memory on a 200–400 MHz
part is well above that, and the host measurement above shows the crossover happening as
soon as the working set exceeds the cache — which on 32 kB is `m = 2048`, or **N = 4096**.
Every count the proposal cares about is eight to sixteen times past that.

So: the host says radix-2, the model says four-step, and they are not in conflict — they
are measuring two machines. Written down rather than resolved silently, as asked. The
losing decompositions stay in the tree behind the `method` field so the choice can be
re-made on real hardware without touching a caller; `AMethodSwitchBetweenFramesIsHonoured`
asserts the field is honoured, because a plan that cached the method at build time would
make the benchmark time one decomposition three times.

### Accuracy, which does not decide it

All three reorder the adds relative to each other, so each is measured against the same
direct DFT separately rather than against radix-2. At N = 512, worst departure as a
fraction of the mixed allowance, and the relative error on the bins carrying energy:

| | single, of budget | single, relative | double, of budget | double, relative |
|---|---|---|---|---|
| radix-2 | 0.085 | 1.32e-05 | 0.013 | 3.20e-12 |
| Stockham | 0.124 | 7.73e-06 | 0.013 | 3.24e-12 |
| four-step | 0.061 | 1.32e-05 | 0.013 | 3.20e-12 |

**No material difference.** Stockham is slightly better on the relative measure here and
slightly worse at N = 64 (3.3e-05 against 1.5e-05); the four-step is indistinguishable from
radix-2. Nothing in the accuracy column argues for or against any of them, so the traffic
model decides alone. `BothDecompositionsAgreeBinForBin` holds both to the same
allowance at every N from 8 to 32,768.

### What it does to the scratch

The proposal tells Keithley 288 kB in single at 16,384 samples, counting two complex
arrays, the per-stage twiddles, the untangle twiddles, the window and the power array. That
count is right for those items — they come to 289.5 kB — but the arena is larger, and
**the proposal is wrong until it is updated**:

| at N = 16,384, single | kB | needed by |
|---|---|---|
| window | 64.0 | all |
| stage twiddles | 64.0 | all |
| untangle twiddles | 64.0 | all |
| `re` + `im` | 64.0 | all |
| power | 32.0 | all |
| FIR taps (384) | 1.5 | all |
| bit-reversal swap list | 32.0 | radix-2 only |
| second complex array | 64.0 | Stockham and four-step |
| gather block + sub-swap lists | 4.9 | four-step only |
| **total** | **390.4** | |

Measured, not derived: `dsp_plan_bytes` returns 399,744 bytes at N = 16,384 and 797,312 at
N = 32,768 in single; 765,824 and 1,527,936 in double. **Deleting the two losing
decompositions brings the single figure to 358.4 kB at N = 16,384 and 714.6 kB at
N = 32,768** — the swap list goes, the second array stays, because the four-step needs it.
Both are far below the 954 kB the Lua tables measure at 16,384, so the claim that a native
implementation replaces a larger allocation than it makes holds either way.

The figures for the proposal, if only the four-step ships: **358 kB single and 684 kB
double at 16,384; 715 kB single and 1,370 kB double at 32,768.**

## Shaped for the e300c4

Structural, in portable C. No inline assembly, no intrinsics, nothing that only pays off
under vectorisation — the core has no AltiVec — and the suite builds and passes unchanged.

- **Explicit multiply-accumulate.** Every inner loop is written as `acc = acc + a*b` or
  `a*b + c` rather than as separate multiplies and adds, so the compiler can contract to a
  single-precision multiply-add. The butterfly is four multiply-adds plus two adds.
- **Independent chains.** The FPU is a three-stage pipeline that stalls for a cycle when
  full, so one dependent chain stalls every third instruction. `dsp_load`'s weighted mean
  runs two chains split over the even and odd samples — which is also the pairing the
  packing loop wants, so the record is walked the same way twice. `dsp_fir_run` runs four.
  The four-step's column pass transforms `DSP_FS_BLOCK` interleaved sub-transforms with the
  lane loop innermost, which is eight independent butterflies; the lane count is the macro
  rather than an argument so that loop unrolls, and leaving it a runtime bound cost 2.5× on
  the host before it was fixed.
- **Pointer increments.** Integer multiply is multi-cycle, so no inner loop recomputes
  `base + i*stride`. The four-step's twiddle index advances by `k1` per column rather than
  being multiplied out, and `dsp_power` walks mirror pairs inwards from both ends.
- **Branchless max.** `dsp_reduce`'s segment maximum is a ternary on a float comparison
  rather than an `if` with a branch body, so a floating select can take it. The NaN
  behaviour is the same either way — PowerPC's `fsel` returns the else-operand for a NaN
  condition, which is what the branch does — and that is the property the test asserts
  rather than the instruction.
- **Cache blocking.** As above. `DSP_FS_BLOCK` is 8 because eight single-precision values
  fill one 32-byte block, so the gather uses every byte of each block it fetches. One column
  at a time would read each block eight times, and its stride maps the `m1` streams onto
  four sets of an eight-way cache and thrashes. `m1` is the *smaller* factor on purpose, so
  the strided footprint is `m1` blocks per array and the gather block stays a small part of
  32 kB; `TheFourStepFactorsCoverTheWholeTransform` asserts both.

**One loop is not in the single-precision path, and should be.** `dsp_fir_run` accumulates
in `double`, because its input is the instrument's double readings and its output feeds the
same loader as an unfiltered capture. A single-precision FIR would be the one-cycle
multiply-add instead, and 384 taps accumulated in single lose about 1.2e-06 relative — far
under a 13-bit converter. The change is a typedef away but needs a second loader for
`dsp_real` input, which is a decision rather than a translation, so it is flagged here
rather than taken.

## Signature changes

The proposal's signatures are a draft and several cannot express what the Lua needs. Each
change below is the smallest one that does.

| proposal | here | why |
|---|---|---|
| `void dsp_window(float *w, int n, int kind, float beta)` | returns `int` | a Kaiser beta below the interpolation floor has to be refusable |
| `int dsp_fir_design(float *h, int maxtaps, float fs, float flo, float fhi, int order)` | `+ int decim` | each cutoff is placed relative to the edge of the Nyquist zone the band lands in, so the decimation is an input to the design. Without it neither cutoff can be placed. `flo` is a real band start: the kernel is a difference of sincs and the normalisation moves to the passband centre |
| `int dsp_fir_run(const float *x, ...)` | `const double *x`, `double *y` | the source is the reading buffer, which holds doubles, and the output feeds the same loader as an unfiltered capture |
| `void dsp_rfft(float *re, float *im, int m, const float *twr, const float *twi)` | `void dsp_rfft(dsp_plan *p)` | the decompositions need the swap lists, the work array and the gather block. Passing six more arrays would make callers aware of the decomposition, which is what the signature was protecting against; taking the plan keeps it an implementation detail, as asked |
| `void dsp_power(..., float *pwr, float scale)` | `+ const dsp_real *utr, *uti`, `scale` is `double` | the untangle twiddles have nowhere else to come from. `scale` is `1/wsum^2`, down to 9e-10 at n = 65536, and keeping it double costs one multiply a bin |
| `int dsp_reduce(const float *pwr, int k0, int k1, int nseg, float *db, float *hz)` | `+ double binhz, dbmin, dbmax, vfloor` | `hz[]` cannot be filled without the bin width, and the dB clamps are module state in the Lua |
| `int dsp_peaks(const float *pwr, int k0, int k1, int want, int *bin, float *frac)` | `+ int nbins, int kdc, const dsp_interp *ip, dsp_real *amp` | the DC-region floor and the quarter-bin leak refusal both need `kdc`, and the refusal needs the interpolation tables. `amp` is computed on the way, so returning it saves recomputing it; it may be NULL |
| `fftsa.bp_taps_for(fs, fhi, d)`, `bp_pick_d(fs, fhi, n)` | `+ int maxtaps` | both answers depend on the tap ceiling and the two that matter are far apart — 65 is what an interpreted frame affords, 384 what the proposal asks for. Hard-coding either would make the C disagree with the document it ships with; passing it makes the Lua's answers reproducible by passing 65 |

Bin indices are 0-based throughout, where the Lua's are 1-based: bin *k* is the frequency
`k · binwidth`. This removes the `(k-1)` that appears at every use site in the Lua.

### Functions the proposal's list leaves out

- **`dsp_load`** — the two-pass window-weighted mean removal and the packing into the
  half-length complex array. The proposal has no function that windows a record, and the
  weighted mean is the single most consequential line in the whole thing; see the pedestal
  measurement below. Kept pure, with no plan argument, so it is testable on its own.
- **`dsp_win_gain`, `dsp_win_offset`, `dsp_peak_interp`** — the proposal folds the sub-bin
  estimate into `dsp_peaks`' `frac` output, but `dsp_peak(i, &hz, &amp, &db)` cannot produce
  `amp` without `G(d)`, because the amplitude correction *is* the window's own transform at
  the offset. These are `fftsa.win_gain`, `win_offset` and `peak_interp`.
- **`dsp_fir_transition`, `dsp_fir_taps_for`, `dsp_fir_pick_decim`, `dsp_fir_srclength`,
  `dsp_binwidth`** — the filter planning the proposal describes in prose. `srclength` is
  the one it calls out as necessary: at 16,384 samples decimating by 4 with 51 taps the
  record is 65,583 readings, which `Fir.SourceLengthIsTheRecordTheFilterMustConsume` pins.
- **`dsp_plan_bytes`, `dsp_plan_init`, `dsp_spectrum_run`** — the commit-time build and one
  frame. The proposal's four entry points (`dsp_commit`, `dsp_spectrum`, `dsp_peak`,
  `dsp_release`) are TSP glue over buffer handles and attribute state; those belong with the
  firmware's registration layer, and `dsp_spectrum_run` is what `dsp_spectrum` would call
  once it has unpacked the handles. `dsp_release` has nothing to do: the arena is the
  caller's.

### Two settings the reference does not define

- **`dsp.filter.lowcutoff`.** `fftsa.bp_build` is a low-pass; the `bp_` prefix is a
  misnomer. A band-pass ahead of a decimation is a down-mix, so it moves the bin-to-hertz
  mapping the whole display rests on, and the Lua's unit-DC-gain normalisation (divide by
  the tap sum) divides by approximately zero for a band-pass. `dsp_fir_design` returns
  `DSP_EUNSUPPORTED` for a non-zero `flo` rather than ignoring it, so the gap is explicit.

  **This needs a decision.** The proposal's opening now names "a band-pass with decimation"
  as part of the ask, and its first line calls it the only way to get a bin finer than the
  sample rate. That second claim is true of the low-pass-and-decimate the reference
  implements; a genuine two-sided band-pass is a different feature and the reference has no
  behaviour to port. Either the proposal means the low-pass — in which case `lowcutoff`
  should go, or be documented as reserved — or it means the band-pass, in which case there
  is design work here that is not translation.
- **`dsp.fft.unit`.** `dsp_reduce` emits `10·log10(power)`, which is dBV against a 1 V peak,
  exactly as `fftsa.sg_update` does. `UNIT_VOLT` and `UNIT_VRMS` are a scale on the way out
  and are not implemented, because no reference behaviour exists for them.

`dsp.fft.beta` is handled differently rather than left out. The Lua ships a fixed list,
`{4, 6, 9, 12, 15, 18}`, because every value on it is verified and a typed beta would admit
unmeasured shapes. In C the constraint is stated instead of enumerated: Kaiser's first null
sits at `sqrt(1 + (beta/pi)^2)` bins and has to stay outside 1.5 bins for the three-bin
ratio to read main lobe rather than sidelobe, which puts the floor at `pi·sqrt(1.25)` =
3.5124. `dsp_window` returns `DSP_EBETA` below it, and
`NoSelectableWindowFailsTheMonotonicityCheck` sweeps beta from 3.52 to 24 in 0.01 steps at
every count from 8 to 4096 to confirm the floor is enough.

## Comment style

Doxygen on every public declaration in `dsp.h`: `@brief`, `@param` marked in or out,
`@return` with the codes enumerated, `@pre` for the real preconditions — power-of-two `n`,
32-byte alignment, the source record length when the filter is on. Elsewhere a comment
states a current fact and earns its line: the why, not the what, and only where a reader
would otherwise assume a mistake. Where a decision is ported from the Lua the comment
carries the Lua's measured figure for it rather than its history.

## The statements no test reaches

`llvm-cov` over `dsp.c` with both binaries merged: 98.0 % of statements, 100 % of functions,
92.9 % of branches. The 27 statements left are reachable by no caller either. Each is a backstop
behind a condition something upstream already guarantees, and the argument for each is here
rather than left as a gap — an unreached refusal would be a hole in the suite, an unreachable
backstop is a decision.

| statement | why no caller reaches it |
|---|---|
| `dsp_ifloor` and `dsp_iceil` clamping to `INT_MIN` / `INT_MAX` | Every caller bounds its quotient first, so the conversion is in range before it happens. The clamp is what makes the conversion defined if a future caller does not. |
| `dsp_bessel_i0` returning after its term cap | The convergence test stops it at 166 terms at `DSP_KAISER_BETA_MAX`, against a cap of 200, and `dsp_window` refuses a larger beta. |
| `dsp_window`'s non-positive I0 guard | I0 of a non-negative argument is at least 1: the series starts at 1 and every term is a square. |
| Kaiser's `s = 1 - u*u` clamped at zero | `u` runs over `[-1, 1]`, so `s` is never negative. |
| `dsp_win_tables` refusing a non-positive window sum | `dsp_plan_init` sums the window and refuses a non-positive total before calling it. |
| `dsp_win_tables` refusing a grid that cannot reach 1.5 bins | `one + nd` is 60 and `DSP_GN` is 60: the test is on compile-time constants and needs the interpolation grid changed to fire. |
| the non-monotonic window path, and the `dhr = 0` branch | No window `dsp_window` builds has a three-bin ratio that fails to rise to half a bin, which `NoSelectableWindowFailsTheMonotonicityCheck` asserts directly. A hand-built window reaches it; the library cannot produce one. |
| `dsp_peak_interp` refusing a non-positive denominator | `den` is `ll + 2*cc + rr` and the guard above already requires `pwr[k] > 0`, so `cc` is positive. |
| `dsp_plan_init` refusing a non-positive window sum, and a failed table build | Unreachable after a `dsp_window` that returned `DSP_OK`; `dsp_win_tables` only fails on the two conditions above, both unreachable from here. |
| the four-step's partial-tile clamps | `m1` and `m2` are both powers of two and at least `DSP_FS_BLOCK` for every size the four-step is dispatched at, so no tile is partial. |
| `dsp_fir_taps_for`'s three-tap floor | The transition is at most `1/(2*decim)`, so the count is at least `ceil(3.3/0.5)` = 7. |
| `dsp_fir_design`'s `fc_hi > 0.5` and `fc_lo < 0` clamps | Each cutoff moves outward by at most half the room the zone leaves, so `fc_hi <= (fhi/fs + (zone+1)/(2*decim))/2 <= 0.5` and `fc_lo >= 0`. Confirmed over 23,028 designs: `fc_hi` reaches exactly 0.5 and `fc_lo` exactly 0, never past. |
| `dsp_fir_design`'s `fc_hi > fc_lo` check | `fc_hi >= fhi/fs` and `fc_lo <= flo/fs`, and `fhi > flo` is required, so they cannot cross. |
| `dsp_fir_design`'s passband-gain floor | The response at the passband centre is near 1 for every band the arguments admit; forced tap counts from 3 to 11 over five bands, and 23,028 designs across 12 forced orders, never drove it below `DSP_FIR_GAIN_MIN`. |
| `dsp_reduce`'s `ob > npts - 1` clamp | `ob` is `floor((c+1)*npts/nseg) - 1`, at most `npts - 1` for `c < nseg`. |
| `dsp_spectrum_run` refusing a short filter run | It passes exactly `dsp_fir_srclength` samples, which yields exactly `p->n` outputs by construction. |
| `dsp_spectrum_run` propagating a `dsp_load` failure | Every precondition `dsp_load` checks is already guaranteed by a built plan. |

No line numbers here on purpose: they go stale within a day of any edit to dsp.c, and a
stale pointer into source still reads as a measurement.

Two of these are worth keeping rather than deleting even though nothing reaches them: the
`dsp_iceil` clamps and the four-step's tile clamps are what make the code correct under a change
of constants, and `DSP_FS_BLOCK`, `DSP_GN` and `DSP_FIR_MAXTAPS` are all things a port might move.

## What the suite verifies

Figures are from the two binaries' own output, single then double where they differ. The
bounds are the Lua suite's; only the precision-dependent ones are derived here, each with
its derivation in a comment next to the constant.

**Transform against a direct DFT.** Every bin at N = 64 against the textbook sum computed in
double over exactly the values the transform consumed, then each of the three
decompositions separately at N = 512. With the Lua's negative control: bin 8 perturbed by
1 % reads more than 100× the allowance.

**Pinned reference values.** The 18 bins `tools/make_refs.lua` produced with its own window,
its own weighted-mean removal and its own O(N²) DFT, plus the total power and the `ksq`
scale constant. Worst 0.128 / 0.064 of the allowance.

**Known answers.** Hann's coherent gain is `(n-1)/(2n)` for every n, which is 511/1024 at
n = 512 — the brief says n = 1024, where the identity gives 1023/2048; 511/1024 is the
n = 512 value the Lua pins, and that is what is asserted. `G(0) == 1` to 1e-12 for every
window, so a tone on a bin centre takes no correction. `G` is bit-exactly even in d. The
offset table is bit-exactly odd in r and saturates at exactly half a bin.

**Sub-bin recovery, 83 offsets at j/83 of a bin, every window and every beta.** Routed
through `dsp_peaks` rather than a local argmax, so a tone present in the spectrum and absent
from the table counts as a miss.

| | worst frequency | worst amplitude | bound |
|---|---|---|---|
| mid-spectrum, all 9 configs | 3.79e-06 / 3.81e-06 bins (Kaiser b=4) | 3.6e-03 dB (Kaiser b=4) | 1e-05 bins, 0.008 dB |
| lowest reportable bin | 0.102 bins (Kaiser b=9) | 0.15 dB (Kaiser b=9) | 0.15 bins, 0.3 dB |
| top bin, which declines | 0.494 bins | 2.33 to 7.08 dB | 0.5 bins, 8 dB |

These are the Lua's own measured worst cases — 4.0e-6 bins and 0.0035 dB at Kaiser b=4
mid-spectrum, 0.102 bins and 0.15 dB at Kaiser b=9 at the low bin, 2.3 to 7.1 dB at the top
— reproduced to the figures quoted. The sweep's negative control runs Hann data through
Blackman-Harris tables and demands both bounds fail.

**The pedestal.** A 0.5 V tone on a 1.0 V offset leaves bin 0 at 1.3932e-17 in single and
1.0340e-31 in double; the Lua measures 1.03e-31. The control removes an arithmetic mean
from the same record and leaves 6.4596e-07, which the Lua also measures. Both halves are
asserted — the weighted figure under its gate and the arithmetic figure above 1e-8 — so the
gate cannot pass vacuously. The same tone recovers as 12345.000002 Hz / 0.500037 V in single
and 12344.999997 Hz / 0.500037 V in double, against a raw scalloped read of 0.486465 V; the
proposal quotes 12,344.999997 Hz and 0.4865 V.

**FIR.** At a 20 kHz span and 200 kS/s, `dsp_fir_pick_decim` chooses /3 with 51 taps, flat
to −0.02 dB at mid-span and at 98 % of the span, and 61.2 dB down at 1.15× the decimated
Nyquist. The Lua measures 0.02 dB and 61 dB. Four controls:

- the same tap count with the cutoff on the stop instead of midway reads the span edge
  5.16 dB low, which is the defect the midway placement exists for and close to the 3.5 dB
  measured on the instrument;
- a 20 kHz tone that would fold to 5 kHz under /4 comes out 73.1 dB below an in-band tone,
  with the in-band tone as the control against a filter that killed everything;
- a decimating run is bit-identical to a non-decimating run read at the same points;
- every decimation `dsp_fir_pick_decim` chooses from a 2 kHz to a 50 kHz stop has a filter
  that fits the ceiling it was given and leaves the stop inside its own Nyquist, at both 65
  and 384 taps.

**The tap ceiling.** `DSP_FIR_MAXTAPS` is 384, the proposal's `dsp.filter.order` ceiling,
where the Lua's `bp_lmax` is 65 — explicitly an interpreted-frame cost, so it does not apply
here. The effect is asserted rather than assumed: at 65 taps the filter is the cap that
binds a decimation and a 2 kHz span at 512 samples gets /7, and at 384 the read budget binds
instead and the same span gets /15 with 249 taps, taking the bin from 27.9 Hz to 13.0 Hz. A
/4 decimation at a 10 kHz stop needs 133 taps and is refused at 65. Both regimes are pinned.

**Segment reduction.** A lone 1 V² bin, swept over 72 consecutive positions of an 8192-bin
spectrum reduced to 255 segments — 32 or 33 bins a segment — reaches the trace from every
one of them. The control computes what a mean over the same segment would give: −15.1 dB,
below the −10 dB the test accepts, so taking the maximum is what makes it pass. Separately
the reduction runs on the real transform at N = 16,384 for four tone positions. The
frequency reported is the segment's: `hz[]` is strictly increasing even with 255 segments
over 64 bins, where four segments share a bin.

**Peak search.** Ranks five planted peaks in order; refuses a full-scale peak inside the DC
region while reporting the first bin past it; the quarter-bin refusal keeps a tone below the
lowest reportable bin out of the table at all 280 position-and-phase combinations, for every
window; a windowed search ignores a taller tone outside the window; a plateau of two equal
bins reports the left one; a flat spectrum at 0, 1e-30 and 1.0 does not crash.

**NaN and refusals.** A NaN bin is never reported as a peak and never produces a NaN
frequency or amplitude, including a NaN in the time-domain input. A NaN bin plots at the
floor — swept over all 64 bins of the segmentation, so each of the two guards is reached, and
an infinity is checked too. `n` not a power of two, zero length, a null pointer, every
misaligned arena offset, an arena one byte short, a decimation below one, an unknown window
kind, a Kaiser beta under the floor, a peak count over the ceiling and a source record one
reading short are all refused with the documented code, and a short record leaves `pwr[]`
byte-for-byte untouched.

**Large counts.** 16,384, 32,768 and 65,536 all transform and recover a tone at n/4 + 0.37
to within 1e-05 bins and 0.008 dB. These are the counts the Lua declines on frame time
alone.

## Mutation check

A numerical bound nothing can fail is worth nothing, so the suite is checked against named
single-change mutations of `dsp.c` — 46 in all, ten of them aimed at the two new
decompositions. **44 are caught by a test; the other two are not gaps.** The script is not
in the tree; it is reproducible with `perl -0pi -e` on a copy.

Seven mutants in the first pass were rejected by `-Werror` instead of failing a test:
removing the use of a variable makes `-Wunused` fire, and a mutation the compiler refuses
proves nothing about test coverage. Each was rewritten to compile — the loop kept but the
maximum removed, `kdc` still read but compared against an unreachable value, and so on —
and all seven then failed a test. The counts above are the rewritten versions.

The sweep has three times found tests asserting less than they appeared to, and in each
case the test was strengthened rather than the mutant dropped:

- the segment reduction's control was initialised to 0 and `max`-ed with negative dB, so it
  always read 0;
- the gain table's absolute value was unobservable, because `G` is positive out to 1.5 bins
  for every shipped window — it is observable only through RECT;
- the reduction's NaN test put its NaN where neither guard was reached;
- the decomposition accuracy comparison ran at N = 64, where the four-step falls back
  to radix-2, so it measured radix-2 three times and reported it as agreement. It now runs
  at N = 512 and asserts `m >= DSP_FS_MIN` so it cannot regress to that;
- **nothing asserted that the decompositions were actually different.** Making `dsp_rfft`
  ignore `plan::method` and always run radix-2 passed the entire suite: every agreement test
  still agreed, and the switch test only checked that the same method twice gives the same
  answer. `AMethodSwitchBetweenFramesIsHonoured` now also requires each of the other two to
  differ from radix-2 bit-for-bit in at least one bin — they must, since the summation
  orders differ — which is the premise the rest of the comparison rests on.

Two mutants are not caught, and neither is a gap:

- **`xi = t2 - d2` changed to `d2 - t2` in the untangle.** `xi` is only ever squared, so the
  sign is immaterial. The same is true in the Lua.
- **The `mono` monotonicity check forced true.** Nothing reachable fails it: every window
  kind, every Kaiser beta from 3.52 to 24 in 0.01 steps, every count from 8 to 4096 — 2,710
  configurations — has `r(d)` monotonic to half a bin. So that branch and
  `dsp_win_offset`'s `DSP_EDECLINE` guard against a window nobody can select. The suite
  asserts the invariant across that sweep and drives the guard separately with a hand-made
  zeroed table, which is the most that can be asserted about an unreachable branch.

Three caught mutants are worth naming because the Lua's comments say they were real
defects: the arithmetic mean fails 20 tests, the cutoff on the stop fails 2, and the
reduction by mean rather than maximum fails 2.

## Five findings about the Lua

1. **`win_mono` is not a sufficient test for a usable window.** RECT passes it — `r(d)` does
   rise monotonically to half a bin. It is still 2.0e-02 bins out against Hann's 3.9e-08,
   five orders worse, because `G(1) = 0` makes `r(d)` leave the origin as `d²` rather than
   as `d`. Whatever admits a window to the list has to test the recovery, not the flag. This
   is the measured case for RECT's absence from `fftsa.win_names`, which `fft_core.tsp`
   currently argues in prose.
2. **The absolute value in the gain table is dead for every shipped window.** `G` is positive
   out to 1.5 bins for all of them; the smallest value at 1.5 bins is 0.0367. It is
   observable only through RECT, whose transform is exactly zero at one bin and negative from
   there to two. Asserted rather than removed, since RECT is in the proposal's enum.
3. **`bp_taps_for`'s three-tap floor is unreachable.** The widest transition any argument can
   produce is just under 0.5 of the rate, and `3.3/0.5` rounds up to 7. The floor is
   reachable only through an explicit order, which `dsp_fir_design` has and the Lua does not.
4. **The two NaN guards in the reduction are redundant.** Either alone suffices. Removing one
   is unobservable; removing both is caught. Worth knowing before anyone simplifies it.
5. **The bit-reversal swap list becomes dead weight once the four-step ships.** 32 kB at
   N = 16,384 for a decomposition that will not be used; the four-step needs only the two
   small sub-lists for its factors.

## Precision: the proposal's open question 1, measured

The same suite in both precisions. Single is enough for everything the instrument can
resolve, and the margin is not large in one place.

| | single | double |
|---|---|---|
| sub-bin frequency recovery, worst | 3.79e-06 bins | 3.81e-06 bins |
| sub-bin amplitude recovery, worst | 3.6e-03 dB | 3.6e-03 dB |
| DFT agreement, bins with energy | 1.32e-05 | 3.20e-12 |
| transform noise floor below full scale | 103 to 122 dB | 178 to 192 dB |
| pedestal residue in bin 0 | 1.39e-17 | 1.03e-31 |
| DC region with a distant tone, Kaiser b=18 | −145.9 dBc | −167.2 dBc |
| coherent gain departure from `(n-1)/2n` | 1.84e-09 | 1.17e-15 |
| `ksq` relative error | 4.1e-09 | 6.6e-15 |
| arena at N = 16,384 | 399,744 B | 765,824 B |
| arena at N = 65,536 | 1,584,256 B | 3,035,776 B |

**The answer is single, with one caveat.** The figures that reach the operator — frequency
and amplitude of a peak — are indistinguishable: 3.79e-06 against 3.81e-06 bins, and
identical to three figures in dB. Both are four orders inside the bound and far below the
converter's own error, which the proposal puts at 1 part in 10,000 at best. Single also
halves the arena and is the e300c4's one-cycle multiply-add path, so it wins twice.

The caveat is the **noise floor**. Single puts the transform's own floor 103 to 122 dB below
full scale depending on how much energy the record carries; the 10 V range at 1 MS/s is
specified spur-free at 95, 80 and 70 dB at 1, 10 and 50 kHz. So single clears the converter
by 8 dB at its worst measured point and by 30 dB or more elsewhere — enough, but not by the
margin one would want for a low-sidelobe window chosen *for* its floor. Kaiser b=18 buys
−139 dB of sidelobe level and single delivers −145.9 dBc in the DC region against double's
−167.2: the window's advantage is being partly spent on the arithmetic. Anyone selecting
beta 15 or 18 is asking for a floor single precision only just provides.

Two cheap mitigations, if that matters: keep the twiddles in double while the data stays
single, which costs 64 kB at N = 16,384 and recovers most of the gap; or keep only `pwr[]`
in double, which costs 32 kB and removes the squaring's contribution. Neither is
implemented — `DSP_DOUBLE` moves everything at once, which is the measurement, not the
recommendation.

One note on how those floors were arrived at, because it bears on reading any of the
numbers above. The absolute half of the bin-for-bin allowance was first set from a
single-tone measurement, at −105 dB of full scale. A two-tone record on the same pedestal
walked straight through it: more energy in the record means a larger absolute error, and the
floor moved to −103 dB. The bound now comes from the worst across the stimulus family the
suite uses — one, two and three tones, with and without a pedestal, N from 64 to 32,768 —
with about 10 dB of margin, and every test using it prints both halves so the margin is
visible rather than asserted.

## Not reproduced

- **Timing on the target.** Nothing here is a hardware measurement. The host benchmark says
  what the arithmetic and bookkeeping cost on an Apple Silicon machine; the proposal's
  4–10 ms estimate for a 16,384-point transform remains an estimate, and the decomposition
  decision rests on a model rather than on silicon. The structure is the one the estimate
  assumes — one pass per sub-transform, no allocation in a frame — but no e300 has run this.
- **The yield points.** `fftsa.fft_load`, `fft_run` and `bp_filter` call `delay()` every few
  thousand samples, because the display task on that firmware runs only while Lua is
  blocked. A native implementation is two orders faster and the cooperative yield belongs
  with whatever schedules it, not in the arithmetic. The proposal's question 4 — how long a
  synchronous call may block — is the same question and is still open.
- **Everything above the arithmetic.** Buffer handles, attribute validation, the event posts,
  the graph binding, the peak text, the memoisation key on `(n, window, beta)`, the cover
  screen during a commit. `fftsa.fft_built_n` and friends are a Lua-side cache with no
  counterpart here: `dsp_plan_init` is the commit, and the caller decides when to call it.
- **`dsp.out.lowfreq` / `highfreq` to bin indices.** `fftsa.sg_window_bins` maps a frequency
  window to `k0`/`k1`, including the detail that the low edge uses `ceil` so a start below
  one bin width does not fall back onto the DC bin. `dsp_reduce` and `dsp_peaks` take
  `k0`/`k1` directly, as the proposal's signatures do, so that mapping is the caller's. It is
  four lines and the comment in `spectrum_graph.tsp` explains the `ceil`.
