# FFT Spectrum Analyser performance

The app runs a native FFT and draws on the instrument. Options offers **1,024 to 32,768 samples**,
with **2,048** as the default. At 100 kS/s the DMM6500 screen captures show **20 fps at 2,048
samples** and **2.3 fps at 32,768**, both with the `F` indicator active. At the maximum size, the
record alone spans 327.68 ms; drawing faster cannot remove that acquisition time.

## Resolution and measured update rates

Bin spacing is `fs / N`; the acquisition duration shown in Options is `N / fs`. These columns
are calculated at 100 kS/s. They do not include the time the instrument takes to store the
readings, run the FFT and draw the trace.

| FFT samples | Bin spacing | Record duration | Fast path, v9.33 bench (fps) | Fast path, screen captures (fps) |
|---:|---:|---:|---:|---:|
| 1,024 | 97.66 Hz | 10.24 ms | 20 | — |
| **2,048** | **48.83 Hz** | **20.48 ms** | 20 | **20** |
| 4,096 | 24.41 Hz | 40.96 ms | 15 | — |
| 8,192 | 12.21 Hz | 81.92 ms | 8.7 | — |
| 16,384 | 6.10 Hz | 163.84 ms | 4.8 | — |
| **32,768** | **3.05 Hz** | **327.68 ms** | 2.4 | **2.3** |

The all-size FPS sweep was recorded on a DMM6500 on 2026-11-15 with v9.33's native ring writer
and on-demand trace decoding enabled. The two
screen captures are separate observations at [2,048 samples](manual-spectrum-current.png) on
the 10 V range and [32,768 samples](manual-spectrum-harmonics.png) on the 1 V range. The figures
are examples, not guaranteed rates or a before/after benchmark of the compiler changes in
v9.57. The optimized image was run on a DMM6500, but there is no matched timing sweep for it
or comparable timings here for the DAQ6510 or DMM7510.

At the lowest rate, **12.5 kS/s**, a 32,768-sample record gives **0.38 Hz** bins and takes
**2.62 s before processing and display**. That is less than 0.39 frames/s even before overhead.
Use the [manual's rate table](MANUAL.md#dragging-and-zooming-the-trace) to choose a span. A lower
rate also lowers the folding frequency; use an appropriately band-limited input.

## Where a frame spends its time

### Acquisition and storage

Each frame takes a fresh, blocking digitizer capture. The acquisition duration in the UI is
the nominal record length, not the wall time for `dmm.digitize.read` to return. On the DMM6500,
the [blocking capture tests](../csrc/README.md#what-a-source-record-costs) fit approximately
`max(N / fs, N × 10.36 µs)` for the tested settings. At 100 kS/s that model gives about **339 ms**
for 32,768 samples; a DMM6500 frame trace on 2026-11-09 measured **338.5 ms** for its acquisition
phase. That leaves a capture-only ceiling near
**2.95 fps** at this size, before any FFT, plotting, timer slack or UI work. Raising the digitizer
rate widens the bandwidth but does not necessarily return the same number of samples sooner:
storing each reading was the limiting cost in the high-rate tests.

The app does not overlap successive captures. A [continuous-capture experiment](https://github.com/ameline-design/dmm6500-fft/blob/v9.57/docs/PERFORMANCE.md#continuous-digitizing-into-a-ring-measured-and-it-does-not-work)
did not provide a reliable replacement: delivery dropped samples under interpreter load, and
the trigger model could stop between display callbacks. Missing samples are unacceptable even if
the resulting graph still looks plausible.

### Native DSP and plotting

The native image reads digitizer samples in place, removes the window-weighted mean, applies
the window, runs a real-input four-step FFT, and computes power, trace, peaks and distortion.
It does not pull each sample across the Lua API. The shipped image uses single-precision working
arrays with double precision for selected calculations. The build uses Clang's 32-bit PowerPC
EABI target, `-mcpu=603e -mtune=e500mc -mhard-float -O2`, and disables
hardware square-root instructions. There is no interpreted FFT in the app archive.

The trace reducer assigns the selected FFT bins to **255 columns**, keeping the maximum of each
group. At 32,768 samples and a 10 Hz–50 kHz span at 100 kS/s, it examines **16,380 bins** without
increasing the number of plotted columns. Peak and distortion calculations use the FFT bins,
not the reduced trace; the noise estimator can sample those bins for its mean.

- **Append fallback:** the firmware receives 510 readings (255 ascending and 255 descending).
  The fold keeps each ring slot's frequency fixed and joins passes at the same frequency, so a
  partial repaint does not draw a line across the plot. A DMM6500 bench pass measured about
  **39 ms** for those appends. That is a draw-stage measurement, not the time for a frame.
- **Fast path (`F`):** the app validates the display ring before writing it. The native writer
  uses the reduction's dB array directly to update the Y pixels; a graph cursor command requests
  repaint without advancing the ring. If column frequencies need to be rewritten in place, the
  Lua writer can update the X fields too. The app keeps plotting with appends if it cannot use
  the ring. At short records drawing is a larger share of the frame, so avoiding appends helps
  most there.

In the same November bench series, at 2,048 samples the v9.32 ring writer showed 15–16 fps;
v9.33, with on-demand dB decoding, showed 20 fps. At 32,768 samples both builds showed 2.4 fps.

### Timer and front-panel response

The shortest frame-timer period is **50 ms**, for a ceiling of **20 fps**. The app schedules
periods in 10 ms steps on the DMM6500 and DAQ6510, and uses 50 ms steps on the DMM7510 to avoid
an off-grid timer dialog. It starts with an estimate, then adjusts the period from measured
frame work, targeting about 20 ms of idle time for input and enforcing at least 10 ms of planned
slack. It normally paces from frames without the periodic display updates. The displayed FPS
counts completed frames over elapsed time, rather than reporting `1 / timer period`.

The native DSP, the draw path and the `delay()` that lets the display task paint all contribute to
the frame budget. A paint yield is not an interval in which the interpreter can dispatch another
button callback. For records longer than one second the app polls pending button events before
starting the next capture. Close LAN or USB control sessions before comparing rates or judging the
panel's response.

An untouched graph does not need its axes rewritten. A DMM6500 bench test measured about **60 ms
per axis write**, so the app responds to reported gestures and only writes limits that change.
Changing the span without changing sample rate does not require a new capture for the retune;
crossing a rate step runs the Apply sequence between frames.

## Apply and workspace

The loading screen covers digitizer setup, an initial capture and a native plan rebuild. The
plan contains the window, interpolation tables, bit-reversal data and twiddles. Apply normally
reuses the native workspace and acquisition buffer, which are sized for the maximum FFT length
at startup. The Options `N / fs` readout is not an Apply benchmark, and the old interpreted
plan-build timings do not apply to the native image.

The table below is a **layout calculation**, not a heap or timing measurement. It uses the
shipped single-precision, no-decimation, four-step configuration with `dsp_plan_segs` and
32,736 usable bytes per segment (32 KiB payload less 32 bytes reserved for alignment).

| FFT samples | Arena segments required |
|---:|---:|
| 1,024 | 1 |
| 2,048 | 2 |
| 4,096 | 4 |
| 8,192 | 10 |
| 16,384 | 13 |
| **32,768** | **26** |

The instrument allocates the **26** arena chunks for the maximum size, plus a chunk for the plan
and a chunk for reduction, results and scratch. The resulting **896 KiB of plan-buffer payload**
does not include the code buffer, capture buffer or allocator overhead. Arrays can span
independently allocated chunks, but each four-step kernel's contiguous run stays inside a slice.
Capture chunks are separate: the native loader supports four-byte-aligned as well as
eight-byte-aligned readings, without copying the record into a Lua table.

## Comparing builds

For a useful comparison, record the app version, meter and firmware, span, measured sample
rate, FFT length, window and input range. Wait for the drawing path to settle and note whether
`F` is present. Use the front-panel FPS with no control connection, and repeat after any change
that makes the app reacquire the ring. For phase-level diagnostics, `fftsa.phases()` separates
acquisition (`acq`), DSP plus trace work (`spec`), markers, periodic UI work, display yield and
peak display. Those counters are not a standalone FFT benchmark.

Older interpreted-transform, display and firmware experiments are retained in the
[previous bench write-up](https://github.com/ameline-design/dmm6500-fft/blob/v9.57/docs/PERFORMANCE.md).
See the [manual](MANUAL.md) for choosing settings and reporting a missing fast path.
