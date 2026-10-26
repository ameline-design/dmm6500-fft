# Native DSP primitives for the DMM6500 family

A proposal for four signal-processing primitives callable from TSP, implemented in C on the
instrument. Filter, transform, peak search, and the reduction that fills a graph's trace buffer.

The case for them is measured, not assumed. We have a working spectrum analyser written entirely in
TSP (Lua 5.0.2) running as an installed app on a DMM6500 at firmware 1.7.17a, with every phase cost
measured on the instrument. It works, and it is slow for exactly one reason: the arithmetic is
interpreted and every sample crosses the Lua-to-C boundary one call at a time.

## What it costs today

Measured on the instrument, per frame, at 16,384 samples:

| phase | cost | what it is |
|---|---|---|
| `dmm.digitize.read` | 179 ms | 164 ms of it is the acquisition itself at 100 kS/s |
| sample load and window | 524 ms | 32.0 µs a sample, 22 µs of that one `buf.readings[i]` call |
| transform and power spectrum | 823 ms | 3.59 µs per N·log2(N) |
| peak search over the bins | 20 ms | 2.5 µs a bin |
| writing 255 trace points | 13 ms | 51.6 µs a point |
| **frame** | **1.686 s** | 0.47 frames a second |

Separately, `fft_init` builds the window, its interpolation tables and the twiddles at 0.163 ms a
sample: 83 ms at 512 samples, a measured 2.667 s at 16,384. That runs on every settings change.

So 1.52 s of the 1.686 s frame is software, and 164 ms is the sample time, which no implementation
can remove. Two consequences:

- **The band-pass filter is unusable above 2,048 samples.** Our FIR costs one multiply-accumulate
  per tap per output in interpreted Lua, and the app refuses it at 4,096 samples and up. A 51-tap
  filter at 16,384 samples with decimation by 4 models at about 5.4 s a frame on top of the
  transform. (That figure is derived from measured per-operation costs, not measured on the loop —
  the configuration is refused, so it has never run.)
- **A 32,768-point transform completes and is not offered**, because the frame is 3.3 s and the
  settings change 5.3 s. Heap is not the limit: it allocates 2.36 MB and the instrument gives it.

## What it would cost in C

The e300 core in this part is dual-issue with a double-precision FPU at 200 to 400 MHz. At 16,384
samples the transform is 53,248 radix-2 butterflies plus the real-input untangle, windowing and the
power spectrum — on the order of 650,000 floating-point operations, 1.7 to 2.0 M cycles with
ordinary scheduling. That is **4 to 10 ms**. A 51-tap FIR over 16,384 outputs is another 835,000
multiply-accumulates, 5 to 13 ms.

| | Lua today | C | ratio |
|---|---|---|---|
| 16,384 transform, no filter | 1.52 s of software | 4–10 ms | 150× to 380× |
| 16,384 with a 51-tap band-pass | ~7 s (modelled; refused today) | 9–23 ms | 300× to 790× |

The filter is where the gap is widest, because an interpreted multiply-accumulate loop is the worst
case for Lua and the best case for a compiled one.

**The frame rate improves by about 10×, not 150×**, because once the arithmetic is free the 164 ms
acquisition at 100 kS/s sets the floor. The ceiling moves instead: 16,384 samples at 1 MS/s becomes
a 16 ms acquisition and a ~20 ms frame, so the instrument could hold 50 frames a second at a
resolution it currently manages half a frame a second at. 32,768 and 65,536 become ordinary.

Memory goes *down*. The Lua tables at 16,384 samples measure about 954 kB; the same work in C needs
two complex arrays, a power array, a window and the twiddles — about 230 kB in single precision,
460 kB in double. A native implementation replaces a larger allocation than it makes.

## The Lua interface

Attributes to configure, one call to run, in the style of `dmm.digitize`. Nothing crosses the
boundary per sample: the call takes the acquisition buffer in and writes a reading buffer out.

```lua
-- Capability. On firmware without it, dsp is nil and the caller falls back.
if dsp ~= nil and dsp.version >= 1 then ... end

-- Transform
dsp.fft.samples = 16384                 -- power of two
dsp.fft.window  = dsp.WINDOW_KAISER     -- HANN, BLACKMAN, BLACKMAN_HARRIS, KAISER, RECT
dsp.fft.beta    = 12                    -- Kaiser only
dsp.fft.unit    = dsp.UNIT_DBV          -- UNIT_DBV, UNIT_VOLT, UNIT_VRMS

-- Filter, ahead of the transform. Off by default.
dsp.filter.state      = dsp.ON
dsp.filter.lowcutoff  = 2000            -- Hz; 0 for a plain low-pass
dsp.filter.highcutoff = 20000           -- Hz
dsp.filter.order      = 64              -- taps; or dsp.ORDER_AUTO from the transition width
dsp.filter.decimate   = dsp.DECIMATE_AUTO   -- or an integer, or 1 for none

-- Output reduction
dsp.out.segments = 255                  -- trace points, independent of the bin count
dsp.out.lowfreq  = 10                   -- the window actually plotted
dsp.out.highfreq = 50000

dsp.peaks.count = 6

dsp.commit()        -- build taps, window, interpolation tables, twiddles. The slow call, once.

-- Per frame
local nseg = dsp.spectrum(cap, trace, marks)
local hz, volts, db = dsp.peak(1)
```

`cap` is the buffer `dmm.digitize.read` filled. `trace` is a `WRITABLE_FULL` buffer bound to a
graph, and receives `nseg` points: the reading is the magnitude in the requested unit and the extra
value is the segment's frequency in hertz, which is what lets `display.graph.add(g, trace,
ELEMENT_DATA, trace, ELEMENT_EXTRA)` label the axis in real units. `marks` is optional and receives
one point per peak in the same form, so a second trace draws the peak markers with no further work.

Five points that matter more than the syntax:

1. **The sample rate comes from the source buffer's timestamps**, not from an attribute and not from
   `dmm.digitize.samplerate`. We measure a rate that differs from the one requested, and the bin
   width has to follow the rate actually delivered. An explicit `dsp.fft.samplerate` should exist as
   an override for a buffer without timestamps.
2. **The reduction to segments must take the maximum of the bins each segment covers**, not a
   decimation or a mean. At 16,384 samples and 255 segments each segment spans 32 bins; anything but
   a maximum loses a narrow tone entirely, and a spectrum analyser that drops single-bin tones at
   high resolution is worse than one with fewer bins. The segment's own frequency should be
   reported, not the winning bin's, so the series stays monotonic when segments are narrower than a
   bin.
3. **`commit()` is separate from `spectrum()`** so the caller chooses when to pay for the tables. We
   put a cover screen up for ours; something has to, because there is no yield inside it. An
   implementation that rebuilt lazily inside `spectrum()` would put that cost in a frame.
4. **`spectrum()` must be callable from a timer callback**, which is where a live display loop runs.
   It should also state its worst-case duration, since the display task on this firmware is
   scheduled only while Lua blocks and a long call starves the panel.
5. **Errors post an event and return nil**, as `display.*` and `buffer.*` do. A raise inside a timer
   or button callback on this firmware posts -286 and leaves the app on screen and dead.

## The C side

Seven internal functions and four entry points. The entry points fit the existing TSP registration:
scalar arguments and returns, plus internal reading-buffer handles.

```c
int  dsp_commit(void);                      /* 0, or a negative code the caller posts */
int  dsp_spectrum(bufhandle src, bufhandle dst, bufhandle marks, int *nseg);
int  dsp_peak(int i, double *hz, double *amp, double *db);
void dsp_release(void);                     /* free scratch: attribute change, teardown */
```

```c
/* Analysis windows, symmetric, built half and mirrored. Kaiser via a Bessel I0 series. */
void dsp_window(float *w, int n, int kind, float beta);

/* Windowed-sinc FIR. Cutoff sits midway between highcutoff and the decimated Nyquist, not
   on highcutoff: a cutoff at the band edge puts the whole displayed band inside the
   roll-off and reads every peak low. Returns the tap count. */
int  dsp_fir_design(float *h, int maxtaps, float fs, float flo, float fhi, int order);

/* Decimating convolution: one output per `decim` inputs, taps applied only where an output
   is produced. */
int  dsp_fir_run(const float *x, int nx, const float *h, int ntaps, int decim, float *y);

/* Real-input FFT as a half-length complex transform plus an untangle. */
void dsp_rfft(float *re, float *im, int m, const float *twr, const float *twi);
void dsp_power(const float *re, const float *im, int m, float *pwr, float scale);

/* Segment reduction and peak search, both over the bin window [k0,k1]. */
int  dsp_reduce(const float *pwr, int k0, int k1, int nseg, float *db, float *hz);
int  dsp_peaks(const float *pwr, int k0, int k1, int want, int *bin, float *frac);
```

Ownership and lifetime: `dsp_commit` allocates all scratch and holds it until an attribute changes or
`dsp_release` is called. `dsp_spectrum` allocates nothing, so a frame cannot fail on memory. The
scratch is a function of `samples` alone, so its size is known at commit time and can be refused
there rather than mid-frame.

## Sub-bin accuracy, which is the part worth having

A tone between bins reads low and at the wrong frequency. Taking the three bins around a peak, the
ratio `(R − L) / (L + 2C + R)` is a fixed odd function of the offset for a given window, and the
amplitude error is the window's own transform at that offset. Tabulating both at commit time turns
the correction into two lookups and a multiply. Measured on our implementation: a 12,345 Hz tone
recovered to 12,344.999997 Hz and 0.5 V to within 0.01 %, against a raw scalloped read of 0.4865 V.

This is why the peak table is more accurate than the trace, and it is the part a customer cannot
easily write themselves.

## What we would supply

- The reference implementation, working on an instrument: four TSP modules, an installed-app
  archive, and a manual documenting the measured behaviour.
- 398 offline tests, including pinned reference values from a direct DFT, per-window peak-recovery
  bounds, and a mutation harness that demands each test fail for a named change.
- The measured per-phase costs above, and the derivations behind the window constants, the filter
  cutoff placement and the interpolation tables.
- C translations of the six internal functions.

## Open questions

1. Single or double precision internally? Single halves the scratch and roughly halves the cycle
   count; the readings arrive as doubles and the output is a display trace, so single is likely
   enough, but the FFT's accumulated error over 14 stages is worth a decision rather than a guess.
2. May a registered C function read and write a `WRITABLE_FULL` buffer's reading, extra and
   timestamp fields directly?
3. Where does ~250 kB of scratch come from, and should the caller instead pass a buffer to be used
   as scratch so the budget stays visible in TSP?
4. How long may a synchronous call block before the display task suffers? That sets the largest
   transform worth offering.
5. Is `dsp == nil` a safe capability test on firmware that predates this, so one script can run on
   both?
6. DMM6500 and DAQ6510 share boards; the DMM7510 has a better digitizer and front end. Our app
   installs and runs on all three through `dmm.digitize` alone. Would this follow the same line?
