# FFT Spectrum Analyser

Runs entirely on the instrument: the digitizer captures, the instrument computes the transform, the
firmware's own graph object draws the trace. DMM6500, DAQ6510 and DMM7510.

Install `FFT_Spectrum.tspa` from a USB key under **MENU > Manage Apps**. **End App** frees every
screen and buffer the app made.

## The spectrum screen

![The spectrum screen: a 12.5 kHz 1.0014 V tone reading 0.0 dBV as a single 195 Hz-wide lump, over a 10 Hz to 50 kHz span at 512 samples with the Hann window. The vertical axis is labelled +020.0dB down to -120.0dB and the horizontal axis +00.00kHz to +40.00kHz, both by the firmware. The noise floor sits near -100 dB. A padlock button, open, and a cog button sit to the right of the peak table](manual-spectrum.png)

+20 to −120 dBV against frequency. By default, 512 samples a frame, 256 bins, 10 frames a second.
Options offers larger records for finer bin spacing, at a slower update rate.

**Both axes are labelled in the units you want: kHz across, dB down.** That is worth a note only
because it was not always so, and the two mechanisms are worth knowing if you read the source. The
graph object's X axis is labelled in seconds whenever it is bound to a reading's timestamp, with a
suffix that cannot be switched off; binding it to the reading's *extra* field instead makes it the
firmware's numeric plot, which labels the real frequency and picks the SI prefix itself. The Y values
are decibels held in a buffer whose unit is a two-character custom one, `dB`, for the same reason: a
volt-unit buffer labelled them `V`.

The `+` signs are the firmware's doing — it signs its numeric axes. The tick numbers are round
because the axis is pinned from DC whenever the Start frequency is under one pixel of the span, which
it is at every default: a 10 Hz Start on a 50 kHz span would otherwise put the ticks at 10, 10010 and
20010 Hz and label them `+00.01kHz`. Zoom into a narrow band and the axis keeps that band's own
limits, so the trace still fills the plot.

Six peaks, strongest first, in two columns:

```
1  21.100 kHz   4.5122 V   13.1 dBV
```

In the capture, peaks 2 and 3 are the tone's second and third harmonics, 81 and 82 dB down; peaks 4
to 6 are noise, 84 dB down. At 195 Hz bins the harmonics sit close enough to the floor that their
frequencies read tens of hertz out — 24.927 kHz for one that is really 25.000. The 16,384-sample
capture further down resolves them exactly.

Two buttons sit to the right of the peak table: a **padlock**, which locks the view, and a **cog**,
which opens Options.

## Locking the view

The firmware's graph pans and zooms on touch, and offers no way to decline — `display.setstate`
refuses both `STATE_DISABLE` and `STATE_READONLY` on a graph. So a brushed screen slides the trace
sideways and the axis labels no longer describe the span.

**The lock is on when the app starts**, and the padlock shows closed. Pan or zoom the trace and the
view is restored within about a second — the check runs once a second, not once a frame, so at 16384
samples it lands on the next frame instead, about two seconds. Press the padlock and it opens,
leaving the view wherever your finger left it; the next Apply, or a zoom, re-pins it. Press it again
and it closes, restoring the window at once rather than waiting for the next check.

**An untouched lock makes no graph call at all.** Writing an axis limit takes 60 ms and repaints the
whole graph, which at 512 samples is most of an 81 ms frame — doing it every frame collapses the
update rate and visibly flickers the trace, which is what it did. So the lock is told when to look:
the graph reports its own pan and zoom, and a check that has had no report does nothing. One that has
reads the limits back at 0.0094 ms each, and writes only a limit that has really moved. Nothing moved means nothing written, and the axis that
did not move is left alone.

**Very narrow spans high up the range have a dead zone.** A pan smaller than about a millionth of
the stop frequency is taken for rounding and left alone. On ordinary spans that is a thousandth of a
pixel, but on a 10 Hz window at 499 kHz it is some thirty pixels — the trace can be nudged visibly
without the lock putting it back, while the padlock still reads closed. Such a window holds no bins
at all, so the trace is empty before this matters, but it is the lock's limit rather than a fault.

**A restore costs a visible pause.** The write lands inside a frame, so that frame takes 202 ms
instead of 81 and the app re-arms its timer from the slowest frame it has seen — 3.3 frames a second,
held for about two and a half seconds while that peak decays. Restoring one axis rather than two is
5 fps for about a second and a half. So a drag costs a brief stutter and then recovers; holding a
finger down and dragging continuously keeps paying it.

Both buttons lose their icon for a moment when they take the yellow focus highlight, because the
firmware paints the highlight over everything inside the button. The app redraws the icons once a
second, so a blank button fills itself back in — while frames are running, since the repair rides on
the same tick as the peak table. A halted app keeps whatever the last touch left, and the button
works either way.

## Options

![The options form: Start Freq, Stop Freq and Input Range in the left column, Window, Kaiser Beta and FFT Samples in the right, with the preview line beneath and About, Apply and Cancel along the bottom. Start Freq reads 10.0000 Hz, Stop Freq 50.0000 kHz, Input Range 10 V, Window Hann, Kaiser Beta 12 -90dB and FFT Samples 512](manual-options.png)

| Field | |
|---|---|
| Start Freq | Low edge of the display. Floor 10 Hz, because bin 1 is DC. The peak table has its own floor two or three bins up — see *The lowest frequency the table reports*. |
| Stop Freq | Top of the display, 2 kHz to 500 kHz. Zooming in does not change the sample rate; widening past 50 kHz raises it. |
| Input Range | 0.1, 1 or 10 V full scale. |
| Window | Hann, Blackman, Blk-Harris or Kaiser. |
| Kaiser Beta | Sidelobe level, −30 to −139 dB. Inert for the other three windows. |
| FFT Samples | 512 (default), 1024, 2048, 4096, 8192 or 16384. More samples give finer bins but take more time and memory. |

The centered line under the fields previews **sampling rate** (using kS/s or MS/s as appropriate),
**bin spacing** (`fs / N`) and **acquisition
duration** (`N / fs`, in milliseconds). It refreshes as you edit the stop frequency or sample count,
without changing acquisition until you press Apply. Cancel discards the edits. On reopening Options,
the readout uses the rate measured from the active capture's timestamps. For an unapplied change to
the sampling rate, it uses the rate the app will request: 100, 200, 500 or 1000 kS/s.

At 100 kS/s (stop frequency up to 50 kHz):

| FFT samples | Bin spacing | Acquisition duration |
|---:|---:|---:|
| 512 | 195.31 Hz | 5.12 ms |
| 1024 | 97.66 Hz | 10.24 ms |
| 2048 | 48.83 Hz | 20.48 ms |
| 4096 | 24.41 Hz | 40.96 ms |
| 8192 | 12.21 Hz | 81.92 ms |
| 16384 | 6.10 Hz | 163.84 ms |

Acquisition duration is the record length, not the complete frame time or the timestamp difference
between the first and last samples (which is `(N - 1) / fs`). Processing and display add overhead.
Windowing spreads each tone across several bins, so bin spacing is not a guarantee of tone separation.

Apply rebuilds the window and its tables behind the loading screen, and resizes the acquisition
buffer if needed. The graph buffer is one fixed size for every sample count and stays attached
throughout, because the trace is capped at the graph's width (see **How many points the trace
carries** below).

**Apply costs roughly 0.2 ms per sample**, measured on 2026-10-24 and linear in the count:

| FFT Samples | 512 | 1024 | 2048 | 4096 | 8192 | 16384 |
|---|---|---|---|---|---|---|
| Apply | 0.11 s | 0.22 s | 0.38 s | 0.74 s | 1.46 s | **2.89 s** |

Most of it is the gain table and the window: both are rebuilt for the new size, and both are
proportional to it. The loading screen is up for all of it.

If Apply fails, the message appears beneath the spectrum. Frames stop only when the **sample count
changed**, because a half-finished resize is the one case where the transform and the buffers can
disagree; a failure at an unchanged count leaves the previous tables intact and the trace running.
Reopen Options and apply again to retry.

## Windows

A window tapers the selected record to zero at each end. Without one, the ends of the record form a step
that smears every tone across the whole spectrum. The shape of the taper sets what you can see, and
every shape trades the same two things: a **narrow main lobe** resolves two close tones, **low
sidelobes** reveal a weak tone beside a strong one. None gives both.

| | peak sidelobe | scalloping loss | peak width | skirt swing |
|---|---|---|---|---|
| **Hann** (default) | −31.5 dB | −1.42 dB | 3–4 bins | 49.8 dB |
| **Blackman** | −58.1 | −1.09 | 3–4 | 10.8 |
| **Blk-Harris** | −92.0 | −0.82 | 4–5 | 7.2 |
| **Kaiser** β=4 | −30.0 | −2.06 | 2–3 | 3.9 |
| β=6 | −43.8 | −1.50 | 3–4 | 21.9 |
| β=9 | −66.3 | −1.06 | 4–5 | 10.1 |
| β=12 | −90.0 | −0.82 | 4–5 | 7.2 |
| β=15 | −114.0 | −0.67 | 5–6 | 5.6 |
| β=18 | −138.6 | −0.56 | 5–6 | 4.7 |

**Hann** for general work: it resolves well and its peaks are narrow. **Blackman** or **Blk-Harris**
to find a weak tone near a strong one. **Kaiser** to choose the sidelobe floor directly — β buys
about 7 dB per unit. β=6 matches Hann's resolution with 12 dB lower sidelobes; β=18 buries sidelobes
at −139 dB and makes every peak six bins wide.

Kaiser β=4 has the narrowest main lobe here and the worst sidelobes. A tone 40 dB down and five bins
from a strong one vanishes under them.

## Why a peak narrows at some frequencies

Tune a generator slowly and the peak changes width. At some frequencies it stands up as a clean
spike; a few hundred hertz away it grows skirts. The signal has not changed.

The bins are what moved. The DFT samples the window's transform at whole-bin offsets from the tone,
and the Hann transform is **zero at every whole-bin offset past the first**. A tone sitting exactly
on a bin centre therefore puts all its neighbours in those zeros: three bins carry the tone and the
rest carry nothing. Move the tone half a bin and the neighbours land on the sidelobe envelope
instead, which is far from zero, and the skirts appear.

With Hann the second bin from the peak swings **49.8 dB** between the two cases. At 100 kS/s and
N=512 the bins are 195.3 Hz apart, so 25.000 kHz is bin 128 exactly and draws the spike; 24.9 kHz is
not and draws the skirts.

**The narrow peak is the truthful one.** The skirts are leakage, not signal. The amplitude in the
peak table is right in both cases.

How large the swing gets depends on where the window's main lobe ends, and not in the direction you
would guess from the peak-width column. It is the rise between 2.0 and 1.5 bins out, so it is biggest
when 2 bins lands in a null or on the steep edge of the lobe — Hann nulls there exactly (49.8 dB),
and Kaiser β=6's lobe ends at 2.16 bins (21.9 dB). It is smallest when 2 bins is still well inside a
wide lobe (β=18, 4.7 dB) or already out on the sidelobe shelf of a narrow one (β=4, 3.9 dB).

So if the changing width distracts, use **Kaiser at β=15 or β=18**: 5 dB of swing instead of 50, for
a peak about twice as wide. β=4 is quiet for the opposite reason and buys −30 dB sidelobes with it,
which is usually the worse trade.

## Aliasing: a peak can be real and still be at the wrong frequency

There is no anti-alias filter in front of the digitizer. Anything above half the sample rate folds
back into the display, at full amplitude, looking exactly like a tone that is there.

Measured: a pure 21.1 kHz sine, with the sample rate chosen from a 0 to 7 kHz span, drew one 4.5135 V
peak at **1.100 kHz** — 21100 reduced mod 20000. The amplitude was right to four digits. Nothing on
the screen said the frequency was not.

That is why zooming in no longer lowers the sample rate. The span selects which bins are drawn and
leaves acquisition alone, so a tone outside the view is excluded rather than folded into it.

**Band-Pass is the one thing that reaches this**, and only partly: it filters digitally, so it can
remove what the digitizer has sampled honestly but not what the ADC already folded. See the next
section.

**Folding above 50 kHz remains** with Band-Pass off, because it is the missing filter rather than the
rate. At the
default span a 63 kHz tone appears at 37 kHz and an 84 kHz tone at 16 kHz. Two ways to tell an alias
from a tone: widen the span, and a real tone stays put while an alias moves; or change the signal and
watch which peak follows.

## Band-Pass

**Not offered on the form.** It works, and it is measured flat to 0.02 dB across the span with 61 dB
of rejection above the Nyquist, but it is not worth the frame time: the filter is one
multiply-accumulate per tap per output, 51 taps over 512 outputs, and the frame goes from 0.08 s to
around a quarter of a second for nothing an operator can see. At 4096 samples and up the read budget
leaves no room for it at any span. It remains settable over the socket as `fftsa.bp_on`, and the rest
of this section describes what it does when it is on.

On, the capture is low-pass filtered and then decimated to the span, so the transform
sees only the band on screen. Two things come of that, and which one you get depends on the span.

**A narrow span buys bin width.** The bin becomes the acquisition rate divided by the number of
samples actually taken, so a span the filter can decimate hard reaches a resolution that would
otherwise need a much longer transform. At 512 samples:

| Stop | rate | decimation | taps | bin | bin with it off |
|---|---|---|---|---|---|
| 50 kHz | 100 kS/s | — | — | 195.31 Hz | 195.31 Hz |
| 20 kHz | 200 kS/s | /3 | 51 | 130.21 Hz | 195.31 Hz |
| 10 kHz | 100 kS/s | /3 | 51 | 65.10 Hz | 195.31 Hz |
| 2 kHz | 100 kS/s | /7 | 65 | 27.90 Hz | 195.31 Hz |

**A wide span gets nothing**, and that is deliberate. The rate goes up by one step at most, and at a
50 kHz span neither 100 nor 200 kS/s leaves room to decimate, so the filter is left out and the line
reads `BP:On (span too wide)`. Going further up the rate list would make it possible — 500 kS/s at
/3 — but 51 taps over 512 outputs costs about 135 ms of arithmetic, which takes the frame from 0.08 s
to a quarter of a second to produce a bin *coarser* than the unfiltered one.

The readback line says which regime you are in. `BP:On /3` means the filter is in the path at a
decimation of three. `BP:On` with a reason in brackets means it is not:

| | |
|---|---|
| span too wide | No rate the hardware has leaves room to decimate this span. |
| too many samples | The record needed is past the read budget — 4096 samples and up, whatever the span. |
| filter will not fit | The transition that decimation leaves would need more taps than the ceiling. |

**`fs` on the readback line is always the digitizer's rate**, never the decimated one. At `BP:On /3`
and 200 kS/s the transform is seeing 66.667 kS/s, but the hardware is not running below its 100 kS/s
floor and never does. The bin width and the record length are the decimated figures.

It costs frame time: the filter reads several times as many samples and does one multiply-accumulate
per tap per output. At a 2 kHz span and 512 samples that is an estimated 0.4 s a frame against 0.08 s.

The filter is a Hamming-windowed sinc, cut off halfway between the span top and the decimated
Nyquist, with taps sized from that transition. Measured through the real taps at a 20 kHz span: flat
to **0.02 dB** across the span and **61 dB** down above the Nyquist.

## About

**About**, bottom left of the Options form, names the author and carries the MIT licence over two
pages with **PgUp** and **PgDn**. **Back** returns to the form.

## How many points the trace carries

The plotted area is 680 pixels wide, measured off a panel capture, so a sample count above 512 gives
more bins than there are columns to draw them in -- 8192 bins at 16384 samples. The app therefore
draws a fixed **255 columns** at every sample count, and the reduction is not a stride: each column
reports the **maximum** of the bins that fall in it.

Three consequences, and the first is the point of it:

- **A narrow tone always reaches the trace.** Taking every nth bin would miss a tone that lands in a
  skipped one. Measured over 72 consecutive bin positions at 16384 samples, max-per-column draws all
  72; taking each column's first bin draws 2.
- **The noise floor reads as a band, not a line**, because the minimum is drawn as well as the
  maximum. Maximum alone would lift the apparent floor by about 6 dB at 64 bins a column, since the
  largest of 64 noise samples sits well above their average.
- **Below 256 points nothing is reduced.** The default 512 samples puts about 255 bins in a 10 Hz to
  50 kHz span, so the default trace is every bin, exactly as it has always been.

| FFT Samples | 512 | 1024 | 2048 | 4096 | 8192 | 16384 |
|---|---|---|---|---|---|---|
| bins in a 50 kHz span | 255 | 511 | 1023 | 2047 | 4095 | 8191 |
| points drawn | 255 | 380 | 441 | 475 | 496 | 502 |

![The spectrum screen at 16384 samples: the 12.5 kHz tone as a narrow spike at 0.0 dBV, its second
and third harmonics resolved as separate spikes at 25.000 and 37.500 kHz, and the noise floor drawn
as a single line near -100 dB, with the padlock and cog buttons right of the peak table. The axes are the firmware's own, +020.0dB to -120.0dB and +00.00kHz to
+40.00kHz](manual-spectrum-16384.png)

Compare the 512-sample shot at the top of this manual, where the same tone is a single 195 Hz-wide
lump and the harmonics are down in the noise of the trace — the table still finds them, a few tens
of hertz out.

Because each column reports its maximum, the noise floor reads about 6 dB high and as an upper
envelope rather than a band. Writing the minimum as well was tried and withdrawn: it doubled the
point count and made every second segment span the whole noise band, about 45 px, where a
single-valued trace moves a few pixels between neighbours -- and the firmware's cost of drawing a
trace is per segment length.

Reducing the trace does not reduce the **table**: `find_peaks` reads every bin at full resolution, so
a reported frequency is never a column edge. It is also what makes the larger counts usable at all --
writing 8191 points costs 51.6 us each, about 0.42 s a frame, against 0.035 s for 255.

## The peak table is more accurate than the trace

A tone almost never lands on a bin centre, and reading the tallest bin pays for that twice: the
frequency is quantised to the bin grid, up to 98 Hz out at 195.3 Hz bins, and the amplitude reads low
by the scalloping loss, up to 1.42 dB with Hann.

The table recovers both from the tallest bin and its two neighbours. On hardware, a 12.000 kHz
1.000 V tone reads 11.914 kHz / 0.883 V from the tallest bin alone and 11999.8 Hz / 1.0016 V in the
table.

So the apex of the trace can sit 1.4 dB below the number printed under it. The number is right. Over
83 sub-bin offsets and every window the worst case **in the middle of the spectrum** is 4.0e-6 bins
and 0.0035 dB; the estimator reads the window's own transform, so it carries no per-window
approximation. Both ends of the spectrum are worse, and by a long way:

| where | frequency | amplitude |
|---|---|---|
| middle of the span | 4.0e-6 bins | 0.0035 dB |
| three bins up from DC and above | 0.07 bins | 0.11 dB |
| lowest bin the table reports | 0.11 bins | 0.19 dB |
| below that bin, where it reports at all | 0.28 bins | 1.7 dB |
| top bin of the span | 0.494 bins | 2.3 to 7.1 dB low |

The top bin has no neighbour above it, so there is nothing to interpolate against and the table falls
back to the bin itself: 49.805 kHz at the default span, read up to 98 Hz low with the full scalloping
loss. Widen the span by one step if a tone sits in it.

## The lowest frequency the table reports

The transform removes the DC level before it runs, or a 2.5 V offset would stand 2.5 V tall at the
left edge and bury everything near it. The estimate of that level is the window-weighted mean, and
for a tone within one main lobe of DC **the estimate is partly the tone**: removing it takes
`2·G(b)²` of the tone out of the tone's own bin. Measured on bin 1, a 1.000 V tone at 195.3 Hz reads
0.589 V under Hann and swings to 1.110 V as the capture phase drifts.

Nothing fixes that. A record 512 samples long cannot tell a steady offset from a tone one bin away
from it — they are the same resolution cell. Removing the plain arithmetic mean instead puts a
spurious line of up to −27 dBc at bin 1 for any off-centre tone **anywhere** in the spectrum, which
is 110 dB above the floor Kaiser β=18 is chosen for. Both were measured over every window and nine
tone positions.

So the app declines to put a number on those bins. The trace still draws them, which is where a tone
below the limit shows up:

| window | bins not reported | lowest frequency the table reports, at 195.3 Hz bins |
|---|---|---|
| Hann, Blackman, Kaiser β=4, β=6, β=9 | DC and 1 | **390.6 Hz** |
| Blk-Harris, Kaiser β=12, β=15, β=18 | DC, 1 and 2 | **585.9 Hz** |

The limit is in **bins**, so it moves with both the sample rate and the sample count: at a 500 kHz
span and 512 samples the bins are 1953 Hz and two of them is 3.9 kHz, while at 16384 samples and a
50 kHz span they are 6.10 Hz and two of them is 12.2 Hz. A narrower window main lobe reaches closer
to DC, which is the one thing Kaiser β=4 is better at than β=18.

What you get either side of it, measured over a 1.000 V tone swept in 0.01-bin steps at four phases:

The two boundaries below are **in bins**, and the Hz are the default 512 samples at 100 kS/s. At
16384 samples the same 0.3 bins is 1.8 Hz rather than 58.6.

| tone sits | the table |
|---|---|
| at or above the lowest reported bin | always reports it, within **0.11 bins and 0.19 dB** |
| between 0.3 bins and that bin | usually empty; where it does report, within **0.28 bins and 1.7 dB** |
| below **0.3 bins** (58.6 Hz at 512 samples, 1.8 Hz at 16384) | never reports it |

A peak the app cannot place is refused rather than guessed: the estimator saturates when the three
bins around a candidate are not one tone centred there, and a candidate whose own estimate lands a
quarter bin below the lowest reported bin is dropped. Before that guard, Blackman and Kaiser β=9
reported a 100 Hz tone at 390.6 Hz and 16 dB low.

**A bump at the left edge of the trace with nothing in the table is a tone below this limit.**

## Limits

- **Bin width is the sample rate divided by the selected sample count**, and the sample rate is
  100 kS/s for any span up to 50 kHz. At the default 512 samples bins are 195.3 Hz; at 16384 they are
  6.10 Hz. **Zooming in alone does not make them finer**; increase FFT Samples instead.
- **A span wider than 50 kHz raises the rate** and coarsens the bins with it. At 512 samples:
  200 kS/s to 100 kHz (390.6 Hz bins), 500 kS/s to 250 kHz (976.6 Hz), 1 MS/s to 500 kHz (1953 Hz).
  Divide all three by 32 at 16384 samples. 500 kHz is the highest tone the instrument can show.
- **10 frames a second at 512 samples, and far slower above it.** The firmware's shortest timer
  period is 0.05 s and a tick arriving mid-frame is dropped, so the rate can only be `1 / (0.05 * k)`
  -- a ladder of 20, 10, 6.67, 5 fps and on down. The app times its own frames and picks the smallest
  period that leaves about a fifth of it idle, so the rate below is what it settles on rather than
  wherever the rounding fell:

  | FFT Samples | 512 | 1024 | 2048 | 4096 | 8192 | 16384 |
  |---|---|---|---|---|---|---|
  | frame | 0.079 s | 0.122 s | 0.212 s | 0.460 s | 0.860 s | 1.686 s |
  | displayed | 10 fps | 5 fps | 3.33 fps | 1.67 fps | 0.91 fps | **0.47 fps** |

  That reserved idle is what keeps the **padlock** and **cog** answering: `delay()` lets the display task
  paint, but dispatching a press needs the Lua interpreter, and during a frame the interpreter is
  busy. It costs 4096 and 8192 about a tick each against leaving the period at the floor, and in
  exchange every size stays operable -- at 16384 the trace repaints about every two seconds and the
  button still answers. **16384 is usable rather than comfortable**, and 32768 is not offered.

- **The trace flickers slightly.** The firmware requires a writable buffer to be cleared before it
  can be rewritten, so the trace buffer is empty for the 20 ms it takes to write 255 points, and a
  repaint landing in that window draws a partial trace. Everything the refill needs is computed
  before the clear to keep that window as short as the write calls themselves.
- **No rectangular or flat-top window.** Rectangular nulls one bin from the peak, which makes the
  three-bin estimate unusable; flat-top is seven bins wide.
- **The peak table starts two or three bins above DC** and the top bin of the span has no sub-bin
  estimate. See above for both.
- **No averaging and no peak hold.** Each frame is one capture.

## Troubleshooting

| Symptom | Cause |
|---|---|
| Trace pinned at the bottom | Range too high, or no signal. |
| Peak flat-topped at +20 dBV | Over range. |
| Peaks update but the trace is missing | A frame failed inside the refill, leaving the trace unbound. Fixed in this build; on an older one, change the span or the sample count to force a rebind. |
| Trace frozen, peaks static | A capture is returning short. The app holds the last good frame rather than show a false spectrum. |
| Text where `X: kHz  Y: dBV` belongs | A failure message. It clears at the next span change. |
| Peak width changes as you tune | Expected. See above. |
| A bump at the left edge, nothing in the table | A tone below the lowest reported bin. See above. |
