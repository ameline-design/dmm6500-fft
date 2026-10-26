# Where the frame time goes, and what is left to win

Every figure here was **measured on the instrument** (DMM6500, firmware 1.7.17a) on 2026-10-23,
except where it says otherwise. The cost model came out of a separate reverse-engineering pass over
the firmware image; the reasoning that depends on the firmware's internals is marked as such, and
the write-up of that pass lives in the serial-decode repo at `docs/FIRMWARE_API.md`.

The short version: **precision is not what this app pays for, and neither is the FFT's arithmetic.**
It pays for interpreter dispatch and for marshalled calls across the TSP API. Every lever below is
about doing fewer operations, not cheaper ones.

## The displayed frame rate is quantised, and the app chooses which tick it lands on

The app offers 512 through 16,384 samples in Options, retaining 512 as the default. Every size was
measured on the instrument on 2026-10-24 -- see **Every selectable sample count, measured** below --
so the caveat that once stood here about needing hardware validation is discharged. The Options
acquisition-duration readout is `N / fs` only; it does not include processing or display.

The rate the app achieves is not the rate the frame can sustain, and the gap is not small.

Two measured facts set it. **The display task shares the application CPU with the Lua interpreter and
is scheduled only when Lua blocks** -- so a frame that never blocks runs fast in Lua while the glass
falls further behind every frame. Measured: a 5 ms yield gave 35.6 Hz in Lua, 194 dropped-message
events (1706), and a trace updating about three times a second. And **a timer tick landing while a
frame is still running is dropped, not queued**, with the shortest period the firmware accepts being
0.05 s -- `arm(0.045)` is refused with event 1131, *"Parameter, period, expected value from 0.05 to
120"*. So

```
displayed = 1 / (0.05 * ceil(frame / 0.05))
```

which admits 20, 10, 6.67, 5 fps and nothing between. **Shaving a frame from 81 ms to 55 ms buys
nothing; getting it from 51 to 49 doubles the rate.** Optimising this app means crossing a boundary,
not reducing a number.

That formula describes a period left at the 0.05 s floor, which is what the app used to do, and the
idle it leaves is then an accident of rounding -- 44 % at 512 samples and 2 % at 4096. The second
figure is why the Options button was unreachable at the larger counts: `delay()` lets the display task
paint, but dispatching a touch needs the Lua interpreter, and during a frame the interpreter is busy,
so the only time a press can be handled is the gap between a frame ending and the next tick.

The app now arms the timer deliberately, at the smallest tick count leaving about a fifth of the
period idle, from the peak work over eight real frames (`fftsa.tick_period`). The quantisation is
unchanged -- it is the firmware's -- but which tick a size lands on is now a decision with a reason
rather than a remainder.

### Measured, N=512, 256 bins, graph 784x272, timer frozen, frames back to back

The graph is **312** tall as shipped (`sg_gh`, raised after these were taken), so the `sg_update` row
and the total below are for 7.4 % less paint area than the app now does. It does not cross a
frame-rate bucket -- 81.8 ms and anything up to 100 ms both display at 10 fps -- and no row other
than `sg_update` depends on the geometry.

| phase | ms |
|---|---|
| `digitize.read` | 6.4 |
| `fft_load` | 14.3 |
| `fft_run` | 14.4 |
| `fft_power` | 2.0 |
| `find_peaks` | 1.9 |
| `sg_update` | 42.6 |
| peak text | 0.2 |
| **total** | **81.8 -- 12.3 fps capability, 10 fps displayed** |

Confirmed from the other end: 3.20 fps displayed at the old 0.3 s period and 8.55 fps at 0.1 s with
no host traffic, both consistent with the formula.

The paint inside `sg_update` is proportional to graph **area**, not point count: 784x272 costs
14.4 ms, 784x200 11.6, 784x136 8.7, 392x136 7.3. Point count does not move it -- 16 and 710 points
measured the same. The shipped 784x312 is above the top of that series and has not been measured;
on the area fit it is about 15.5 ms.

### The N trade, and why 512 stays the default

Modelled from the per-unit costs, since halving N halves acquisition, buffer read-out, transform,
fill and peak search at once:

| | frame | capability | displayed |
|---|---|---|---|
| N=512, 256 bins | 81.6 ms | 12.3 fps | **10 fps** |
| N=256, 128 bins | 47.9 ms | 20.9 fps | **20 fps** |
| N=256, graph 784x136 | 40.7 ms | 24.6 fps | 20 fps |
| N=128, 64 bins | 31.4 ms | 31.8 fps | 20 fps |

No combination of the smaller levers crosses 50 ms from 81.6: radix-4 ~3 ms, graph height ~4, the
fill's arithmetic ~3. Halving N is the only cut large enough, and it is one constant. Note that
`acq 6.4 + load 14.3` is irreducible at N=512, so even with radix-4, power, peaks and a 14 ms floor
on the paint, N=512 reaches ~48 ms *with zero fill* -- it cannot comfortably cross.

**The operator chose 512 on 2026-10-23: 10 fps is fast enough, and resolution is not for trading.**
What follows is therefore the record of an option, not a plan.

It costs **resolution, not accuracy.** Bin width goes 195.3 -> 390.6 Hz, so tones closer than ~391 Hz
merge. An isolated peak does not move at all, because the three-bin interpolation absorbs the coarser
grid entirely -- measured offline under Lua 5.0.2 on a 12345 Hz 0.5 V tone:

| N | bin width | interpolated | error | amplitude error |
|---|---|---|---|---|
| 512 | 195.3 Hz | 12345.0000 Hz | 0.0000 Hz | 0.0073 % |
| 256 | 390.6 Hz | 12345.0000 Hz | 0.0000 Hz | 0.0040 % |
| 128 | 781.3 Hz | 12345.0005 Hz | 0.0005 Hz | 0.0028 % |

(Those figures were 0.11, 0.81 and 1.65 Hz while the estimator used Hann's closed-form kernel against
a symmetric window. The kernel is now read from the window's own transform, which removed the
systematic part; the amplitude residual that is left comes from DC removal, not the estimator.)

**If it is ever revisited, the margin is thin and the cliff is binary.** 47.9 ms leaves about 2 ms
before 50, and crossing back costs half the rate rather than a few per cent. The cheapest headroom is
`fftsa.sg_yield` -- it need only cover the display task's work, which halves with the bin count --
then the graph height. Note that **radix-4 does not help at N=256**: it needs M a power of four and M
would be 128, so it falls back to radix-2. It applies at N=512 and N=2048, and at N=512 it saves
~5 ms, which crosses no boundary and so changes nothing the operator sees.

**The other route past the quantisation, unmeasured:** at the 0.05 s floor, a *count-bounded* second
frame per tick (never a time loop) gives 13.3 fps displayed for a frame at or under 75 ms, and three
frames gives 15 at or under 66 ms. That recovers some of the dropped-tick loss without needing the
frame under 50 at all, and it keeps 195 Hz bins. It wants measuring before it is trusted: holding the
interpreter away from its event loop is what the firmware is least forgiving of.

### What a window change costs, and where

Nothing per frame. Selecting a window moves work into `fft_init()`, which runs on Apply and at
startup, never inside a frame:

| | cost at N = 512, modelled from the table above |
|---|---|
| window samples, cosine windows | 256 `cos` calls (symmetry halves it) |
| window samples, Kaiser | 256 x `I0`, each ~30 series terms -- about 45 ms |
| gain table, every window | 61 x 256 `cos` calls -- about 120 ms |
| ratio table and its inverse | arithmetic only, 61 nodes |

So about 130 ms for a cosine window and 180 ms for Kaiser, on top of the capture `apply()` already
takes. That is why Apply raises the loading cover: the panel is frozen for the duration either way,
and a cover is the difference between "working" and "wedged".

The frame itself got slightly *cheaper*. `peak_interp` used to call `math.sin` once per peak (a C
call, ~4 µs); it now does two table lookups and a multiply instead, six times a frame.

### Not yet verified on hardware

The 47.9 ms for N=256 is modelled, not measured, and so is the 10 fps at the 0.05 s floor for the
shipped N=512. The check for either is one count of completed frames against the wall clock with the
event log read afterwards; if 1706 appears, `sg_yield` is short of the display task's work.

## Every selectable sample count, measured

Firmware 1.7.17a, 100 kS/s, 10 V range, 10 Hz to 50 kHz span, a 12.5 kHz 1.000 V tone, graph
784x292, 255 trace points at every count. Twelve frames a size, called synchronously with the timer
parked, so the period each size settles on has been re-armed from real frames before it is read.
Taken 2026-10-25, event log clean throughout. `tools/../../fftmeas/docmeas5.py` is the run.

| N | Apply | frame | worst frame | period | displayed | occupancy | bin width | record |
|---|---|---|---|---|---|---|---|---|
| 512 | 0.106 s | 0.079 s | 0.081 s | 0.10 s | **10.0 fps** | 81 % | 195.31 Hz | 5.1 ms |
| 1024 | 0.219 s | 0.122 s | 0.125 s | 0.20 s | 5.0 fps | 62 % | 97.66 Hz | 10.2 ms |
| 2048 | 0.376 s | 0.212 s | 0.215 s | 0.30 s | 3.33 fps | 72 % | 48.83 Hz | 20.5 ms |
| 4096 | 0.737 s | 0.460 s | 0.526 s | 0.60 s | 1.67 fps | 88 % | 24.41 Hz | 41.0 ms |
| 8192 | 1.455 s | 0.860 s | 0.883 s | 1.10 s | 0.91 fps | 80 % | 12.21 Hz | 81.9 ms |
| 16384 | 2.893 s | 1.686 s | 1.730 s | 2.15 s | 0.47 fps | 80 % | 6.10 Hz | 163.8 ms |

**The worst frame is not the mean plus noise.** At 4096 the slowest of twelve is 0.526 s against a
0.460 s mean, a 14 % outlier, and it is what puts that row on 0.60 s rather than 0.55 -- the period
covers the slowest frame by design, so one slow frame in a window costs a tick until the window
turns over. Every other count holds within 2 % of its mean. The occupancy column is `worst / period`,
so 4096's 88 % is that outlier arriving after the period had been armed from a lower peak.

**The displayed rate is now a figure the app chooses, not one the quantisation leaves.** The period
is re-armed from the peak work over eight real frames, through `fftsa.tick_period()`, which asks for
the work to be about 80 % of the period and rounds up to the firmware's 0.05 s tick. So `period` is
what the operator sees and `worst frame` is what it was sized to cover -- the mean is only there to
show the spread is small, under 2 % at every count.

4096 and 8192 are **slower than an earlier revision of this table** recorded -- 1.67 fps against 2.0,
0.91 against 1.1 -- and that is the rule working rather than a regression. Those figures came from a
period left at the 0.05 s floor with ticks dropped, which gave the interpreter 2 % idle at 4096 and
made the Options button unreachable there. A fifth of each frame is now idle by construction, and the
button answers at 16384.

Two sources of error this table had before, both now gone: the frame times were taken without the
display task's paint and so ran a tick or two optimistic, and the trace point count grew with N
(255 at 512 up to 502 at 16384) which moved the fill cost between rows. The trace is a fixed 255
points at every count.

### Where a frame goes, per sample and per bin

Each measured on its own, so the frame can be built from them for any count:

| term | cost | scaling |
|---|---|---|
| `dmm.digitize.read` | **10.9 us a sample** | N; at 100 kS/s, 10 of those are the sampling itself |
| `fftsa.fft_load` | **32.0 us a sample** | N; about 22 of it is `buf.readings[i]`, one C call per sample |
| `fft_run` + `fft_power` | **3.59e-6 s per N*log2(N)** | 0.017 s at 512, 0.826 at 16384, 1.766 at 32768 |
| `buffer.write.reading` | **51.6 us a point** | per trace point written |
| max-scan over `fft_pwr` | **2.5 us a bin** | per bin examined by the column reduction |

`fftsa.frame_estimate(n)` in `spectrum_app.tsp` is these numbers, and predicts 0.080 s at 512
against 0.079 measured and 1.63 s at 16384 against 1.686. `busy_max` is three times it.

**The model no longer sets the frame rate**, and it should not be made to. It is a fit at one point
count and one draw path, and it errs both ways: 80.4 ms at 512 against 79, and 216 ms at 2048 against
212. Divided by the occupancy target those errors land either side of a tick boundary, which is a
50 % swing in displayed rate. `frame_estimate` is now used only for the first arm, before any frame
has been timed, and for `busy_max`; `fftsa.frame()` re-arms from measurement thereafter.

**The fixed column count is why the larger counts are usable.** Writing every bin at 16384 would be
8191 points at 51.6 us, about 0.42 s a frame -- a quarter of the whole frame -- for points the
firmware then discards, 784 pixels being all it has. 255 columns costs a 2.5 us scan per bin plus 255
writes: about 0.035 s at any count, which is also what makes the frame time linear in N.

### The refill, and the window it opens

The trace buffer is bound to the graph for the life of the app and refilled in place, so it is at
n = 0 from `clear()` until the last write and a paint landing there draws a blank or partial trace.
That window is the flicker, and it cannot be removed: the firmware needs the clear before a
`FILL_ONCE` buffer can be rewritten.

So the window is made narrow instead. Every value is computed into two preallocated arrays *before*
the clear, while the buffer still holds the previous complete trace, leaving only
`buffer.write.reading` inside it. Measured at 255 points:

| | time |
|---|---|
| staging, outside the window | 7.6 ms |
| clear and 255 writes, the window | **20.3 ms** |
| the same refill interleaved | 30 ms, all of it the window |

A point costs about 109 us to produce and 51.6 of that is the write, so this is the better half of
the work moved out. There is no bulk route into a reading buffer (`FIRMWARE_API.md`), so one write a
point is the floor, and caching the function in a local -- 65 us against 72 through the table -- is
the only other lever.

### Apply, and why it is the figure an operator notices

Apply is `fft_init`, and `fft_init` is linear at **0.163 ms a sample** -- 2.667 s at 16384 measured
directly, 5.333 s at 32768. The gain table is 61 cosines per N/2 and the Kaiser window is an `I0`
series per N/2, and both are rebuilt whenever anything on the form changes. There is no `delay()`
anywhere in it, so the loading screen is the only thing that keeps it from looking like a wedge.

### Heap

`gcinfo()` after a collect, with only `fft_core` loaded, so these are the transform's own tables:

| N | 512 | 2048 | 8192 | 16384 | 32768 |
|---|---|---|---|---|---|
| heap in use | 565 KB | 657 KB | 1002 KB | 1459 KB | **2359 KB** |
| its tables | ~60 KB | ~152 KB | ~497 KB | ~954 KB | ~1854 KB |

Baseline is about 505 KB. **32768 completes and allocates 2.36 MB**, which is well inside what this
instrument has been seen to give -- so heap is not what limits the sample count. Time is: a 3.3 s
frame and a 5.3 s Apply are the reasons 32768 is not on the Options list.

## The cost model

| operation | cost | how measured |
|---|---|---|
| Lua table read | **1.4 µs** | 20,000-iteration loop, overhead subtracted |
| Lua arithmetic op | **~1.2 µs** | same |
| `i - math.floor(i/256)*256` | 2.7 µs | per iteration, loop overhead subtracted |
| `math.mod(i, 256)` | 3.5 µs | same |
| `bit.bitand(a, b)` | **4.1 µs** | same -- a Lua-to-C call, see below |
| reading-buffer element read, `rd[i]` with `rd` cached | **22 µs** | 512 reads |
| same, `buf.readings[i]` indexed fresh each time | 25 µs | 512 reads |
| `buffer.write.reading(b, v)` | **65 µs** | 256 writes, function cached in a local |
| same, function not cached | 72 µs | 256 writes |
| `buffer.write.reading` with 3 arguments | 67 µs | no cheaper than 2 |
| `bufferVar.clear()` | 0.2 ms | effectively free |
| `display.graph.add(graph, buffer)` | **4 ms** | one call, any number of points |
| `display.graph.scalex(g, m, t, lo, hi)` -- a write | **59.3 ms** | 50 calls, frame loop parked |
| `display.graph.scaley(g, m, t, lo, hi)` -- a write | **60.8 ms** | same; the pair is 121.1 ms |
| `display.graph.scalex(g)` -- a read | **0.0094 ms** | 50 calls; nil unless events are on |
| `display.setstate(image, state)` | 0.020 ms | 50 calls, state unchanged |
| same, `STATE_INVISIBLE` then `STATE_ENABLE` | 0.034 ms a pair | what forces an icon to redraw |
| `display.setpixel(...)` | 10.8 - 14.6 µs | 2,500 and 60,000 call runs |
| `display.flush(obj)` | **0.203 s** for an 800x480 surface | see the surface note below |

**Writing an axis limit is the most expensive call in this table** -- 60 ms, fifteen times
`graph.add`, and it repaints the whole widget including its axis label text. Both figures were taken
with the frame loop parked; an earlier run that left frames running measured the same 60-67 ms and
would have been contaminated either way, so the park is what makes them comparable. Cross-checked
from the host at 139.9 ms for the pair against a 7.3 ms bare round trip.

That number is why the view lock is driven by `display.EVENT_SCALE` rather than by re-asserting the
limits each frame. **At 512 samples the margin is about 1 ms.** The frame is 81.0 ms and
`tick_period()`'s 10 fps bucket ends at 82.0 ms, so 121 ms of pinning per frame does not shave the
rate, it collapses it -- and on the glass it read as a flickering trace, which is what the operator
reported. One pin per gesture is 121 ms once; an untouched locked frame makes no graph call at all.

The read-back is affordable at 0.0094 ms and is what the lock tests with -- **but its return values
"are only valid when the objects event generation is set to ALL"**, and non-button objects have no
events enabled by default. On a graph nobody had registered an event on, `scalex(g)` and `scaley(g)`
answered nil and posted no event, so a lock that skipped its pin on nil did nothing whatsoever and
every offline test passed, because the mock answered unconditionally. Registering `EVENT_SCALE`
supplies the precondition, so the registration is not an optimisation: without it the read-back does
not work. It costs nothing per frame -- frame work measured 74.7 ms minimum with it on and with it
off, at 512 samples -- and it reports the gesture as well, which lets a tick that saw no report skip
even the reads.

A reading-buffer element costs **16x a plain Lua table element**. That is the single most important
number in this file: it is why the load phase is what it is, and why copying a buffer into a plain
table first does not help (the copy costs the same 22 µs per element).

## Why double precision is not the lever

Lua 5.0.2's number type is fixed at build time by `LUA_NUMBER`, and on this firmware it is `double`.
There is no float subtype and no way to request one. The firmware's own marshaller has *distinct*
type codes for single (1) and double (2), so its C side knows the difference, but everything crossing
into Lua arrives as a double. The TValue is 16 bytes with an 8-byte value slot, which is consistent.

It would not help anyway. One Lua arithmetic op measures ~1.2 µs, which at 400 MHz is about **480
cycles**. The e300 core's FPU does `fmul` in 3-5 cycles and `fmuls` (single) in the same -- on this
core single and double multiply-add have identical latency, and only divide differs materially, which
a butterfly does not use. So the floating-point work is roughly **1 %** of what is being paid. The
other 99 % is opcode decode, TValue fetch, type check and result store.

Halving the mantissa would therefore change nothing measurable. Fewer VM operations is the only axis.

## The per-frame budget, N = 512

From `notes/HANDOFF.md`, on-instrument timers, 12.53 fps sustained:

```
acquire    5.5 ms     digitize 512 samples at 100 kS/s
load      15.5 ms     buffer -> Lua table, DC removal, Hann window
FFT       30.6 ms     real-input radix-2, precomputed tables
magnitude  1.6 ms
peaks      0.5 ms
graph    ~20   ms     refill WRITABLE buffer, one repaint
```

Cross-checking against the cost model: 512 buffer reads at 22 µs is **11.3 ms** of the 15.5 ms load,
and 256 buffer writes at 65 µs is **16.6 ms** of the ~20 ms graph phase. So about **28 ms of the
80 ms frame is marshalled API calls**, and it is a hard floor -- there is no bulk route into or out of
a reading buffer from Lua (established three ways, see the dead ends).

## What is left to win

Items 1, 3 and 4 are **taken** -- they shipped on 2026-10-23 and the measured phase table above is
the result. They are kept here because the reasoning is the record of why the transform has the shape
it does.

### 1. Real-input packing: about 15 ms, and it is exact -- TAKEN

The biggest single lever. Before it, `fft_run` exploited real input in exactly two places -- the
bit-reversal permuted `re[]` alone, and stage 1 was add/sub with no `im[]` writes -- while
**stages 2 through 9 were full complex butterflies over all N points.**

The trick: pack the N real samples as N/2 complex points, `z[k] = x[2k] + i*x[2k+1]`, run an
**N/2-point** complex FFT, then untangle with one O(N/2) pass.

Counting the actual loops: inner iterations per stage are `(N/len)*(len/2) = N/2 = 256`, over
`log2(N)-1 = 8` stages.

| | full complex butterflies | cheap stage-1 | untangle |
|---|---|---|---|
| before | 2048 | 256 | -- |
| packed, M = 256, shipped | **896** | 128 | 128 points |

2.3x fewer full butterflies. Scaling the measured 30.6 ms gives ~13.6 ms for the transform plus
~1.8 ms for the untangle, so **about 15 ms back**, which is 12.5 -> ~15.5 fps on its own.

Two caveats so the estimate is not rosier than it should be. Stage 1 can no longer skip `im[]`
writes, because after packing the input genuinely is complex -- that is the 128 cheap butterflies
above, not zero. And the untangle needs `conj(Z[M-k])`, so it walks the array from both ends and pays
two index computations per point rather than one.

### 2. Radix-4: a further 20-25 %

Worth doing *after* packing, and for a reason that is not the usual one. The win here is not the ~25 %
fewer multiplies; it is that a radix-4 butterfly loads four points and does more arithmetic per load
before storing them back. On a loop where table reads and writes dominate the arithmetic 1.4 µs to
1.2 µs, reducing the number of stages is reducing table traffic. N = 512 is not a power of four, so
this is one radix-2 stage plus four radix-4 stages.

### 3. Drop the sqrt from the magnitude pass: free -- TAKEN

`fft_power` outputs power, and `fft_magnitude` is gone. If the display is dB, then `20*log10(sqrt(a*a + b*b))` is `10*log10(a*a + b*b)` -- the sqrt
disappears entirely. That is 256 C calls at ~4 µs gone, about 1 ms, for one edit and **no loss of
accuracy at all**.

### 4. Cache `buffer.write.reading` in a local: 1.8 ms -- TAKEN

Measured: 72 µs a call through the table, 65 µs through a local. At 256 points that is 1.8 ms a frame
for one line.

### 5. Plot fewer points: 65 µs each

Every point not plotted is 65 µs. The graph object is at most 799 px wide, so above about 780 visible
bins the detail cannot be seen anyway. Halving 256 to 128 is ~8 ms, at half the plotted resolution.

Together 1 + 3 + 4 were worth about **18 ms off 80**, with no resolution cost. The frame is now
81.8 ms measured against a pre-packing 80 ms estimate that was itself low; what the three bought is
visible in the phase table, and the displayed rate went 3.2 -> 10 fps because the timer period came
down with them. What is left is 2 and 5, and neither crosses the 50 ms boundary that would matter.

## Dead ends, measured -- do not retry these

- **`bit.*` is slower than arithmetic for masking.** The firmware has an undocumented global `bit`
  table, but a call is 4.1 µs against 2.7 µs for `i - math.floor(i/256)*256`. It wins only where the
  pure-Lua alternative is a loop, and always for XOR, which has no cheap arithmetic equivalent.
- **A plain Lua table cannot be graphed.** `display.graph.add(g, {...})` is refused with event 1138,
  "Parameter 2, expected type 'reading buffer', but found type 'table'", for both the 2- and
  4-argument forms. The buffer refill is unavoidable.
- **A buffer element cannot be assigned.** `b.readings[i] = v` raises "Cannot modify this read only
  table". `buffer.write.reading` is the only way in.
- **A standard-style buffer refuses writes** with event 4926, "must be of a 'writable' style to use
  this function". `buffer.make(n, buffer.STYLE_WRITABLE)` is required, and
  `buffer.write.format(b, unit, digits)` before the first write.
- **There is no bulk read or write.** Copying a buffer into a plain table costs the same 22 µs per
  element as reading it in place, so there is nothing to amortise.
- **Single precision is not available.** See above.
- **No C hook exists for user code.** A 1,376-name census of the firmware's Lua surface turned up no
  FFT, no dot product and no vector helper.
- **`buffer.math` will not help.** It does elementwise expressions in firmware, but getting data into
  a buffer costs 65 µs an element -- far more than the arithmetic it would save.

### On lookup tables

Worth stating because the arithmetic is counter-intuitive on an interpreted VM:

| operation | best method | cost |
|---|---|---|
| unary byte op -- reverse, popcount, nibble, **any fused sequence** | 256-entry LUT | **1.4 µs** |
| shift by a constant | multiply or divide by a power of two | **1.2 µs** |
| binary AND/OR/XOR of two bytes | 2D LUT, `T[a][b]` | **2.8 µs** |
| the same, flattened `T[a*256+b]` | multiply + add + read | ~3.8 µs |
| the same | `bit.bitand(a, b)` | 4.1 µs |

**Flattening is worse than 2D**: two table reads beat a multiply, an add and one read, because index
arithmetic costs more than the extra indirection. **Do not put a shift in a table** -- the multiply is
cheaper than the read. And a 256x256 binary table is ~65,536 TValues at 16 bytes each, **1 MiB**
(1.05 MB) of Lua heap plus ~0.2 s to build, for a 32 % saving over `bit.bitand`: a poor trade
unless the operation is hot.

Where LUTs win decisively is **fused unary sequences** -- one read replacing reverse-then-mask, or
scale-then-clamp-then-pack, at 1.4 µs against 4-8 µs for the steps. This app has no such step; the
serial-decode project used exactly this for its MSB bit reversal.

## Corrections to notes/FINDINGS.md

Both from reading the firmware, and both make the existing notes wrong as written:

- **`display.setpixel`'s colour argument is not ignored.** Argument 5's low byte is **alpha**, and it
  is not reliably defaulted, so pixels written with the 4-argument form are transparent -- which is
  what "everything renders black" was. The form is `setpixel(id, x, y, colour, 255)`, colour as
  `0x00RRGGBB`, and the top byte of argument 4 is discarded.
- **`display.flush(obj)` exists** and is the queue sync point that was missing when flooding the
  display queue panicked the firmware. Related: the firmware reports display-queue overflow as event
  2351 for only the **first ten** occurrences and then drops them silently.

## Two things about the pixel path, if it is ever revisited

It is still the wrong path -- a graph refill and repaint costs tens of milliseconds against a flush
alone at 0.203 s -- but the reasons are worth recording, because neither is obvious. (The "~32 ms for
200 points" this paragraph used to quote was wrong, and is superseded by the measured phase table
above.)

**The image's surface is owned by its *name*, not by the object.**
`display.create(parent, display.OBJ_IMAGE, x, y, name, w, h)` takes a string as its 5th argument, and
that string names the surface. A 400x200 object created with a name already bound to an 800x480
surface displays and flushes that 800x480 surface -- the `w`/`h` arguments do not resize it. A name
with no surface renders a small blue "?" placeholder, and `setpixel` into it writes nothing and posts
**no event at all** (measured with 60,000 calls). On a freshly booted instrument the first fresh name
allocated a surface and worked; later fresh names got the placeholder, which suggests the surface is
not released when the object is deleted.

**`flush` is a chunked bulk copy, so its cost is proportional to surface area.** It pushes the entire
pixel block over channel 9 in 240-byte chunks under a per-channel lock. Channel 9 is an in-process
channel to the GUI task on this same core, not a link to the second processor: an
800x480 32-bit surface is 1,536,000 bytes, 6,400 chunks. Measuring 0.203 s for both a 400x200 and an
800x480 object looks like a fixed cost and is not -- both were flushing the same surface, per the
name rule above.

`OBJ_IMAGE` (type 5) is the **only** object type with a pixel surface. `OBJ_RECT` posts event 1717,
"Attribute pixel, does not apply to an object of type Rectangle", once per call.

## The frequency axis

**Settled, and the whole problem went away.** X is bound to the reading's **extra** field, which makes
the graph the firmware's numeric x-y plot instead of a time plot: the axis takes its limits in real
hertz and the firmware labels and SI-prefixes them itself -- `+00.00kHz`, `+10.00kHz`. The Y axis
reads `dB` because the buffer's reading unit is the two-character custom unit `buffer.UNIT_CUSTOM1`,
registered with `buffer.unit`. Confirmed on the instrument, 2026-10-25.

**A log frequency axis is not available from the firmware, and was left alone.** `AXIS_LOG` is
accepted by `scalex` and ignored: there is one log flag and the widget reads it for Y only
(`graph+0x3A0`), and none of the eight X scale methods is logarithmic. The only route is to write
`log10(f)` into the extra field, which positions the trace correctly and makes the firmware label the
row in log units -- `+02.00` for 100 Hz -- so correct labels would mean reinstating the app's own
label row and the 20 px it costs. Worth knowing before trying it: the display is 255 columns, so at
512 samples the bottom decade gets about 106 of them over roughly 5 bins and draws as a staircase.
It only reads properly at the large sample counts, and the column reduction would have to become
log-spaced with it.

Everything below is what that replaced, kept because two of the three are hazards.

The time axis is labelled in seconds with a suffix that cannot be switched off, so each bin's
frequency went into the timestamp divided by a decade scale (`sg_pick_fscale`, stepping while
`fhi/s >= 59` to stay clear of the base-60 rollover) and the app drew its own label row below the
plot in real units. Two rows of numbers, one of them wrong.

- **Fixing `s = 1e6` was tried on hardware and reverted. Do not retry it.** The idea was that a whole
  0-500 kHz span maps to 0-0.5 label-seconds, so base 60 cannot appear. What it did was put the
  firmware's axis row into a regime where its own choice of label count oscillates: the row
  alternated between labelling every tick and labelling the ticks between, one frame at a time --
  "normally 00.01ms, 10.01ms, 20.01ms; when it flickers it draws 05.01ms, 15.01ms".
- **Masking the firmware's row cannot work.** A child object inside the graph's rectangle is painted
  over by its per-frame repaint whatever the creation order: a thick white line across the label row
  showed up only for the three pixels extending past the graph's right edge. `OBJ_RECT` is
  outline-only here and `display.setfill` is inert, so a filled bar is a thick `OBJ_LINE` anyway,
  capped at 10 px by `setthickness`.
- **`buffer.UNIT_DECIBEL` panics the instrument during build.** The custom-unit path does not, and a
  custom label is truncated to two characters with event 4933 -- which `dB` fits exactly.

Related, from the firmware: units are `buffer.UNIT_*`, with `UNIT_HERTZ = 9` and `UNIT_SECOND = 10`.
`UNIT_SECOND` is the only unit the firmware demonstrably exercises **on an axis**, and two of the
three unit symbol tables in the image have Hertz pointing at an **empty string** -- which is a
plausible shape for the frequency-units crash, though the failing call was never captured so the
mechanism is unproven. Treat every unit other than `UNIT_SECOND` as unvalidated *as an axis unit*.
That is not in tension with `sg_make_buffer` formatting the second column as `UNIT_HERTZ`: that
column is the `extra` value, which the graph never plots and the axis never reads.

## Reference: the undocumented bit library

Global `bit` table, ten functions, in no DMM6500 manual. The first three are confirmed on the
instrument; the rest are read from the firmware's own argument checks and match Keithley's documented
2600-series library one for one.

| function | signature | returns |
|---|---|---|
| `bit.bitand`, `bit.bitor`, `bit.bitxor` | (number, number) | number |
| `bit.test` | (value, index) | boolean |
| `bit.get`, `bit.set`, `bit.clear`, `bit.toggle` | (value, index) | number |
| `bit.getfield` | (value, index, width) | number |
| `bit.setfield` | (value, index, width, fieldValue) | number |

Two arguments only -- `bit.bitand(255, 60, 15)` returns 60, silently ignoring the third. Full 32-bit
range works and results come back unsigned: `bit.bitor(2147483648, 1)` is 2147483649. There is no
`bitnot`; complement is `bit.bitxor(x, 0xFFFFFFFF)`. A non-number raises `-104` "Data type error",
and a bad index or width raises `-222` "Parameter data out of range".
