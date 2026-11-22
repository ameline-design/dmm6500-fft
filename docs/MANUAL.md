# FFT Spectrum Analyser

Runs entirely on the DMM6500, DAQ6510 or DMM7510: the digitizer captures, the native DSP computes
the FFT, and the firmware's graph draws the trace. Choose **1,024 to 32,768 samples** per frame
in Options; the default is **2,048**.

Install `FFT_Spectrum.tspa` from a USB key under **MENU > Manage Apps**. **End App** frees the app's
screens and graph buffers. Selecting a different measurement or digitize function with the
front-panel **FUNCTION** key also exits the analyser and leaves that function selected. From the
live spectrum, the physical **EXIT** key exits the analyser too.

## The spectrum screen

![DMM6500 spectrum screen showing a 6.000 kHz tone at 708.06 mVrms and 0.0 dBV. THD is 0.01%, S/N is 70.8 dB, and the noise floor is -100.4 dBV. The fast-path F indicator is on, and padlock and Options buttons sit to the right of the peak table.](manual-spectrum-current.png)

The graph spans +20 to −120 dBV by default and extends to −140 dBV in the low-range settings
described below. At the default 2,048 samples and 100 kS/s, bins are 48.83 Hz wide. The screenshot
shows the fast path at 20 fps. At the same rate, the **32,768-sample** setting gives **3.05 Hz** bins
and the harmonic screenshot below shows **2.3 fps**. More samples improve bin spacing without
changing bandwidth, but each frame takes longer.

### The `F` at the start of the bottom line

The bottom line reads `F  2048 pts  …` once the app is drawing by its **fast path**. Instead of
appending 510 readings one at a time for the firmware's display task to copy, it writes the
pixel records straight into the task's own ring in a single operation, and asks for one repaint.
This makes the most difference at short records, where drawing is a larger share of the frame.

At default settings, it usually appears within a few seconds. A number after it, such as `F2`,
reports restarts since the previous settings-line refresh. Changing the span or sample count can
make the indicator disappear for a few frames while the app keeps drawing with appends.

**If no `F` appears within about five seconds at default settings**, the app is drawing through
the append path. It shows the same spectrum and peak readings, but may update more slowly.
Allow more time after changing settings or selecting a long capture.

Go to **Options → About** and page through with **PgDn**. **Photograph every page** and post them to the
EEVblog thread [TSP and Lua scripts for modern Keithley DMMs, SMUs etc](https://www.eevblog.com/forum/testgear/tsp-and-lua-scripts-for-modern-keithley-dmms-smus-etc/),
saying which instrument and firmware version you have. The diagnostics include both, along with
the app version.

The diagnostic pages show where the fast path looked for the trace and why it could not use it.

**Both axes show their units: kHz across, dB down.** The app binds the graph's X axis to the
reading's *extra* field, so the firmware labels the frequency instead of the timestamp. The Y
values use a custom `dB` buffer unit.

The `+` signs are the firmware's doing — it signs its numeric axes. The tick numbers are round
because the axis is pinned from DC whenever the Start frequency is under one pixel of the span, which
it is at every default: a 10 Hz Start on a 50 kHz span would otherwise put the ticks at 10, 10010 and
20010 Hz and label them `+00.01kHz`. Zoom into a narrow band and the axis keeps that band's own
limits, so the trace still fills the plot.

Six peaks, strongest first, in two columns. The voltage is the RMS amplitude of each tone
(`Vpeak / √2`). The dBV column uses the graph's peak-amplitude reference,
`20 log10(Vpeak / 1 V)`, not the displayed RMS voltage.

```
1  6.000 kHz   708.06mVrms   0.0 dBV
```

The other rows show the next strongest peaks in the span. They can be harmonics or noise; rank
does not identify them. The 32,768-sample capture further down shows how finer bins can
separate low-level harmonics from the noise floor.

Two buttons sit to the right of the peak table: a **padlock**, which decides what a sideways drag
means, and a **cog**, which opens Options.

**Between the graph and the peak table** sits distortion and noise:

```
THD: 0.42%    S/N: 86.3 dB    Noise Floor: -102.3 dBV
```

**THD** is `100 × √(summed harmonic power / fundamental power)`. The fundamental is the
strongest eligible local peak in the plotted
span. Harmonics at 2f, 3f and so on are measured with the same sub-bin estimator as the peak table.
Harmonics outside the span or too close to the preceding line are not counted. With a detected
signal, `THD: ---` means no harmonic was measured, not that the signal is clean. Widen the span
if it excludes the harmonics of interest.

The display uses **two decimal places at 1,024–4,096 samples, three at 8,192, and four at both
16,384 and 32,768**. These are display precision, not an accuracy specification. At 100% THD
or above, it displays no decimals.

**S/N** compares the fundamental with **integrated** noise across the plotted span, excluding the
signal and its harmonics. At the same bandwidth, doubling the sample count ideally lowers
broadband noise per bin by about 3 dB without changing the total noise power. In practice, leakage,
the window and which bins the app excludes can affect the reading.

**Noise Floor** is the estimated mean power per bin after excluding the signal, harmonics, their
skirts and outliers, in the same dBV reference as the peak table. The native estimator can sample
the remaining bins rather than reading each one. It averages power before converting to decibels.

**`NoSig` replaces both numbers when there is no tone to take them against**, the labels staying put. With the inputs
shorted the strongest bin is just the largest noise bin, and both ratios built on it are arithmetic
about noise rather than a signal. The app checks for a tone before reporting either ratio. With
the inputs shorted, the noise floor still reports the instrument's own per-bin noise.

**The skirt follows the window.** Inside the window's main lobe the bins hold signal, not noise, so
the number of bins withheld either side of each line is the window's own first null plus one: 3 for
Hann, 4 for Blackman, 5 for Blackman-Harris, and up to 7 for Kaiser at beta 18, whose lobe reaches
5.8 bins. Excluding too few bins counts part of the signal as noise and raises the reported floor.

**Window leakage can limit the reported S/N** even for a noise-free tone. The limit depends
on the window, FFT length, span and how the tone falls between bins. Low-beta Kaiser windows
have higher sidelobes and are a poor choice for measuring very low noise beside a strong tone.

**To measure a low noise floor in the presence of a strong tone, try Kaiser β=18 at 32,768
samples.** Its low sidelobes help keep leakage out of the noise estimate, but its wide main lobe
can merge closely spaced tones. At 100 kS/s, 32,768 samples give half the bin spacing of 16,384;
use 16,384 when faster updates matter more. Start with Hann for general work and nearby tones
of similar amplitude.

**Outliers are clipped before reporting the floor.** Bins above four times the running mean
are dropped from the next estimate. The app repeats the calculation until no more bins are
dropped or the pass limit is reached.

**The distortion calculation skips likely mains pickup when choosing the fundamental.** A weak
peak near a multiple of 50 or 60 Hz, within the 1 kHz and −22 dBV limits, is not used as the
fundamental. It can still appear in the peak table. A detected signal must clear a 45 dB margin
over the per-bin noise estimate.

The peak table, THD, S/N and noise-floor readouts refresh about once a second when frames are
available. A capture that takes longer than a second limits how often they can update.

**The line along the bottom reads back what is applied** — sample count, digitizer rate, bin width,
acquisition duration, window, input range, measured frame rate when available, and terminal
selection. It describes the settings in force, not the fields being edited.

**`FRONT` or `REAR` at the end of that line is the terminal selection.** FRONT/REAR is a front-panel
button the app cannot refuse, and the pair that is not selected is an open input: a signal wired to
the front with the switch on REAR reads as a *dead signal* rather than as a wrong setting, which on
the trace alone is indistinguishable from a broken transform. The setting refreshes on the
periodic display update; there is no need to open Options to check it.

## Dragging and zooming the trace

The firmware's graph pans and zooms on touch, and offers no way to decline — `display.setstate`
refuses both `STATE_DISABLE` and `STATE_READONLY` on a graph. So every gesture is settled after the
fact. The app checks for changes at intervals of at least 150 ms, when a frame reaches the check.
Long records can make that interval longer, and an unlocked gesture must settle before it is adopted.

**A frequency gesture is adopted only once the axis stops moving.** A finger still on the glass is
reported on every check, and retuning to each reading would mean several captures during one drag,
so a pair that has changed since the last check is noted and left alone. One drag, one retune.

**The dB axis always snaps back**, whatever the padlock says. A drag does not change the vertical
scale or the data.

**The floor follows the instrument, input range, and sample count.** The top is +20 dBV and the
default floor is −120 dBV. On the 1 V and 0.1 V ranges, the floor reaches −140 dBV on the DMM7510
and at 16,384 or 32,768 samples on the DMM6500 and DAQ6510. The peak table uses the same dB floor.
Press Apply to commit the range and sample count.

**The padlock decides what a horizontal gesture means.** It is closed when the app starts.

- **Closed** — the frequency axis goes back to the span in force. Pan or zoom and the trace snaps
  back on the next check, without waiting for the gesture to stop.
- **Open** — the span follows the axis. Drag or pinch and the analyser **retunes** to the range you
  have brought into view: Start and Stop in Options change to match, the firmware relabels the axis,
  and the next frame measures that range.

Pressing the padlock closed settles the view at once rather than waiting for the next check, so a
drag that has not yet been adopted snaps back instead. Pressing it open settles nothing, and the
span already in force stays in force until something is dragged.

**What a retune costs depends on whether the sample rate has to change.** The digitizer runs at the
slowest rate whose declared stop frequency covers the span:

| Stop frequency | Sample rate | Bin spacing at 2,048 samples | Record duration at 2,048 samples |
|---|---|---|---|
| 500 Hz–5 kHz | 12.5 kS/s | 6.1 Hz | 164 ms |
| >5–12 kHz | 25 kS/s | 12.2 Hz | 82 ms |
| >12–25 kHz | 50 kS/s | 24.4 Hz | 41 ms |
| >25–50 kHz | 100 kS/s | 48.8 Hz | 20 ms |
| >50–100 kHz | 200 kS/s | 97.7 Hz | 10 ms |
| >100–250 kHz | 500 kS/s | 244.1 Hz | 4 ms |
| >250–500 kHz | 1 MS/s | 488.3 Hz | 2 ms |

The three slow rates are there for resolution: a 5 kHz stop at 12.5 kS/s gives a bin width that a
100 kS/s span would need eight times the samples to reach, and at 32,768 samples it is **0.38 Hz**.
The record alone takes **2.62 s** at that setting, before processing and display. Lower sample
rates also make aliasing more likely. See [Aliasing](#aliasing-a-peak-can-be-real-and-still-be-at-the-wrong-frequency).

These rates divide the DMM6500's 66 MHz digitizer clock. The app uses capture timestamps to measure
the actual rate rather than relying on the requested-rate readback.

- A pan or zoom within the same rate band reuses the existing FFT plan. It shows more detail
  from the bins already available, without changing bin spacing.
- Crossing a ceiling in the table re-plans the digitizer, in either direction, between frames. The
  settings line reads `retuning to ... Hz` while it reconfigures the digitizer and takes
  one capture. The app also reapplies the native plan. At 32,768 samples and 25 kS/s the record
  alone takes 1.31 s; the full retune also includes plan and display work.

Note that the **default stop of 50 kHz sits exactly on a rate step**, so the first drag to
the right from a fresh start re-plans: 55 kHz needs 200 kS/s, which doubles the bin width at the same
sample count. The settings line reports the new rate and bin spacing when it comes back. Dragging
back and forth across a step re-plans each way; staying on one side of it does not.

**A gesture cannot leave the allowed range.** Start clamps to 10 Hz … 499 kHz and Stop to
500 Hz … 500 kHz — the limits the Options fields themselves declare, enforced through one function so
the form cannot be handed a value its own field would refuse. A pan is not told apart from a pinch —
both are just two limits to be snapped into range — so a drag that runs off an end *narrows* the span:
that edge sticks at the limit while the other keeps coming in. Adopted limits are rounded to whole
hertz, so the Options fields can show and re-apply them unchanged.

**Axis checks run only when the graph reports a change.** Writing a limit repaints the whole graph,
so the app reads the limits after a pan or zoom report and writes only a limit that needs restoring.

**Very narrow spans high up the range can have a visible dead zone.** The app ignores tiny relative
changes in the axis limits so rounding does not trigger a retune. Zooming in cannot create new FFT
bins: the settings line flags spans with fewer than three bins available for plotting.

**An axis write can cause a brief stutter.** An earlier DMM6500 bench test measured about 60 ms per
axis write. The app writes only limits that need changing, rather than repainting the axes every
frame. See [Performance](PERFORMANCE.md) for the measurement context.

Both buttons lose their icon for a moment when they take the yellow focus highlight, because the
firmware paints the highlight over everything inside the button. The app redraws the icons once a
second, so a blank button fills itself back in — while frames are running, since the repair rides on
the same tick as the peak table. A halted app keeps whatever the last touch left, and the button
works either way.

## Options

![The Options form shows a 10 Hz to 50 kHz span, 10 V input range, Hann window and 2,048 FFT samples. The preview shows 100 kS/s and 48.83 Hz bins. About, Reset, Apply and Cancel sit along the bottom.](manual-options.png)

**If Options is slow, close any LAN or USB control session first.** A script or probe can delay
front-panel event dispatch. A long capture can also delay the press until the frame finishes;
at 32,768 samples and 12.5 kS/s, allow a few seconds before pressing again.

| Field | |
|---|---|
| Start Freq | Low edge of the display, at least 10 Hz. The peak table also excludes bins affected by DC removal; see [The lowest frequency the table reports](#the-lowest-frequency-the-table-reports). |
| Stop Freq | Top of the display, 500 Hz to 500 kHz. It sets the sample rate; see the rate table above. At 5 kHz and below the rate is already 12.5 kS/s, so a lower stop narrows the view without changing bin spacing. |
| Input Range | 0.1, 1 or 10 V full scale. |
| Window | Hann, Blackman, Blk-Harris or Kaiser. |
| Kaiser Beta | Sidelobe level, −30 to −139 dB. Inert for the other three windows. |
| FFT Samples | 1,024, 2,048 (default), 4,096, 8,192, 16,384 or **32,768**. More samples give finer bins and slower updates at the same sample rate. |

Start Freq and Stop Freq are also written by a drag or a pinch on the trace while the padlock is
open, so the form opens on whatever the last gesture asked for — see *Dragging and zooming the
trace*. Apply supersedes a gesture the app has not finished acting on.

The centered line under the fields previews **sampling rate** (using kS/s or MS/s as appropriate),
**bin spacing** (`fs / N`) and **acquisition duration** (`N / fs`, in milliseconds). It refreshes
as you edit the stop frequency or sample count. Apply changes acquisition; Cancel discards the edits.

**Reset** puts all six fields back to their shipped values — 10 Hz, 50 kHz, 10 V, Hann, beta 12 and
2,048 samples — and does nothing else. Acquisition is untouched until you press Apply, so Cancel after
Reset leaves the analyser exactly as it was and a mis-press costs a press.

On reopening Options, the readout uses the rate measured from the active capture's timestamps.
If an edit selects a different rate, the preview uses the requested rate until Apply.

At 100 kS/s (stop frequency above 25 kHz and up to 50 kHz):

| FFT samples | Bin spacing | Acquisition duration |
|---:|---:|---:|
| 1,024 | 97.66 Hz | 10.24 ms |
| 2,048 | 48.83 Hz | 20.48 ms |
| 4,096 | 24.41 Hz | 40.96 ms |
| 8,192 | 12.21 Hz | 81.92 ms |
| 16,384 | 6.10 Hz | 163.84 ms |
| **32,768** | **3.05 Hz** | **327.68 ms** |

Acquisition duration is the nominal record length, not the time for the instrument to return the
capture or to finish a frame. Buffer storage, processing and display all add work.
Windowing spreads each tone across several bins, so bin spacing is not a guarantee of tone separation.

Apply configures the digitizer, takes one capture, and rebuilds the native FFT plan behind the
loading screen. It normally reuses the acquisition buffer and native workspace, both allocated
to support 32,768-sample FFTs. Trace capacity is unchanged by FFT size. Apply takes longer with long records;
the duration shown on the form is for the record only, not Apply as a whole.

If Apply fails, the message appears beneath the spectrum. For a failed resize the app tries to
restore the previous sample count; `[kept … samples]` confirms it recovered. If it cannot restore
a working setup, frames may stop. Reopen Options and apply again to retry.

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

With Hann the second bin from the peak swings **49.8 dB** between the two cases, and the zeros being
at whole-bin offsets makes that independent of the count. At 100 kS/s and N=1024 the bins are
97.66 Hz apart, so 25.000 kHz is bin 256 exactly and draws the spike; 24.95 kHz is half a bin out
and draws the skirts.

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

The app does not apply an anti-alias filter before sampling. Input above half the sample rate
can fold into the displayed span and look like a real in-band tone. The display does not mark
aliased peaks.

**Watch for aliases when narrowing the span.** A stop of 10 kHz selects 25 kS/s, so a 21.1 kHz
tone appears at 3.9 kHz. A stop of 5 kHz selects 12.5 kS/s, so a 10 kHz tone appears at 2.5 kHz.

The app uses a 1 µs digitizer aperture, not an anti-alias filter. Even a 10 µs boxcar aperture
has its first null at 100 kHz, far above the 6.25 kHz folding frequency at 12.5 kS/s.

To check for aliasing, widen the span enough to change the sample rate: a real in-band tone
stays at its frequency, while a folded peak can move or disappear. At the default 50 kHz span,
a 63 kHz tone appears at 37 kHz and an 84 kHz tone at 16 kHz.

The app does not offer a band-pass or decimation control. If the input contains energy above
half the sample rate, widen the span to raise the sample rate or filter the signal externally.

## About

**About**, bottom left of the Options form, names the author and carries the MIT licence with
**PgUp** and **PgDn**. **Back** returns to the form.

**The last pages are a diagnostic, not licence text.** They carry the build, the model, the
firmware version and the state of the compiled path: which memory window found the reading
buffer's descriptor, whether its field offsets had to be derived rather than assumed, how much
of the sweep reached memory, and the six firmware maths entries by address. None of it means
anything to a measurement. It is there so that an instrument on which the app *works* can still
be reported on -- **page to the end and send a grab of that page** if you are asked how a
particular model behaved.

About refreshes the diagnostic data each time it opens, so it includes failures that occur
during a run as well as the startup state.

## If the app stops, or will not start

A red **FFT &lt;version&gt;** page replaces the analyser, with the model and the firmware version
beside the build. Everything below it is a diagnostic dump: addresses, window
ranges, counters and a dump of the memory words examined during binding.

**It is written to be read by whoever fixes the app, not by you.** Two things are worth doing
with it:

* If a **More** button is present there is more than one page, and the counter by the headline
  says how many. **Press More and capture every page** -- the fault is as likely to be on page
  two as on page one.
* Send the captures. There is nothing to act on at the instrument; the app has already cleaned
  up after itself, and **End App** exits.

**The same page appears if the analyser stops during a run.** If the compiled transform cannot
continue, the app displays the full diagnostic. The archive has no interpreted FFT fallback.

## How many points the trace carries

The app plots **255 columns** at every FFT size. Each column shows the **maximum** of the bins
assigned to it, not a minimum/maximum pair or every nth bin. A narrow tone therefore still reaches
the trace when many bins share a column. The display ring contains two copies of the trace, one in
each direction, so its **510 records** do not represent 510 independent points.

| FFT samples | 1,024 | 2,048 | 4,096 | 8,192 | 16,384 | 32,768 |
|---|---:|---:|---:|---:|---:|---:|
| Bins in the 10 Hz–50 kHz span at 100 kS/s | 511 | 1,023 | 2,047 | 4,095 | 8,190 | 16,380 |
| Plotted columns | 255 | 255 | 255 | 255 | 255 | 255 |

![At 32,768 samples and 100 kS/s, the fast path runs at 2.3 fps with 3.05 Hz bins. A 6.000 kHz fundamental at 707.86 mVrms and 0.0 dBV stands above harmonics at 12, 18, 30 and 36 kHz. THD is 0.0082%; the noise floor is −120.8 dBV.](manual-spectrum-harmonics.png)

Finer bins help separate low-level harmonics from the noise floor. The trace can make the floor
look higher than the numeric Noise Floor readout: each column highlights its highest bin rather
than estimating mean noise power.

The **peak table** still searches the available FFT bins in the span at full resolution. Its
sub-bin estimates are independent of the 255 plotted columns.

## The peak table is more accurate than the trace

A tone almost never lands on a bin centre, and reading the tallest bin pays for that twice: the
frequency is quantised to the bin grid (up to half a bin off), and the amplitude reads low by the
scalloping loss (up to 1.42 dB with Hann).

The table recovers both from the tallest bin and its two neighbours. On hardware, a 12.000 kHz
1.000 V tone reads 11.914 kHz / 0.883 V from the tallest bin alone and 11999.8 Hz / 1.0016 V in the
table.

The trace apex can therefore sit below the corrected level in the table. These estimator tests
use isolated tones; they are not accuracy specifications for an instrument or for overlapping tones.

| where | frequency | amplitude |
|---|---|---|
| middle of the FFT spectrum | 4.0e-6 bins | 0.0035 dB |
| three bins up from DC and above | 0.07 bins | 0.11 dB |
| lowest bin the table reports | 0.11 bins | 0.19 dB |
| below that bin, where it reports at all | 0.28 bins | 1.7 dB |
| highest available FFT bin | 0.494 bins | 2.3 to 7.1 dB low |

The highest available FFT bin has no neighbour above it, so the table falls back to the raw bin
frequency and amplitude there. At 100 kS/s that bin is 49.951 kHz at the default 2,048 samples, or
49.997 kHz at 32,768. If a tone is near the Nyquist edge, raise Stop Freq enough to select the
next sample rate; merely changing an axis limit without changing the rate does not add neighbours.

## The lowest frequency the table reports

The transform removes the DC level before it runs, or a 2.5 V offset would stand 2.5 V tall at the
left edge and bury everything near it. The estimate of that level is the window-weighted mean, and
for a tone within one main lobe of DC **the estimate is partly the tone**: removing it takes
`2·G(b)²` of the tone out of the tone's own bin. Measured on bin 1, a 1.000 V tone at 195.3 Hz reads
0.589 V under Hann and swings to 1.110 V as the capture phase drifts.

Nothing fixes that. A finite record cannot tell a steady offset from a tone one bin away
from it — they are the same resolution cell. Removing the plain arithmetic mean instead puts a
spurious line of up to −27 dBc at bin 1 for any off-centre tone **anywhere** in the spectrum, which
is 110 dB above the floor Kaiser β=18 is chosen for. The measurements cover every window and nine
tone positions.

So the app declines to put a number on those bins. The trace still draws them, which is where a tone
below the limit shows up:

| Window | Bins excluded | First bin eligible by window | At 2,048 samples, 100 kS/s | At 32,768 samples, 100 kS/s |
|---|---|---:|---:|---:|
| Hann, Blackman, Kaiser β=4, β=6, β=9 | DC and 1 | 2 | 97.66 Hz | 6.10 Hz |
| Blk-Harris, Kaiser β=12, β=15, β=18 | DC, 1 and 2 | 3 | 146.48 Hz | 9.16 Hz |

These are bin centres, not the app's minimum reportable frequencies. Only bins in the selected
span are searched, and **Start Freq cannot go below 10 Hz**. At 32,768 samples and 100 kS/s,
for example, a 10 Hz start makes bin 4 (12.21 Hz) the first candidate for either window group;
the interpolated peak can fall between bin centres.

These near-DC sweep results describe the estimator in **bins**, before imposing the display span.
For scale, 0.3 bins is 29.3 Hz at 1,024 samples or 0.92 Hz at 32,768 samples, both at 100 kS/s.

| tone sits | the table |
|---|---|
| at or above the lowest reported bin | always reports it, within **0.11 bins and 0.19 dB** |
| between 0.3 bins and that bin | usually empty; where it does report, within **0.28 bins and 1.7 dB** |
| below **0.3 bins** | never reports it |

A peak the app cannot place is refused rather than guessed: the estimator saturates when the three
bins around a candidate are not one tone centred there, and a candidate whose own estimate lands a
quarter bin below the lowest reported bin is dropped.

**A bump at the left edge with nothing in the table can be a tone below this limit.**

## Limits

- **Bin width is the sample rate divided by the sample count.** At 32,768 samples and
  12.5 kS/s it is **0.38 Hz**, the finest spacing the app offers. The record takes 2.62 s.
- **The span sets the rate**, so zooming in below 25 kHz, 12 kHz or 5 kHz does make the bins finer —
  see the rate table under [Dragging and zooming the trace](#dragging-and-zooming-the-trace).
  It costs capture time in proportion, and it brings the folding
  frequency down with it; read *Aliasing* before trusting a peak at one of the slow rates.
- **A stop above 50 kHz raises the rate** and coarsens the bins with it. The highest Stop Freq is
  500 kHz; the FFT's highest available bin is one bin below Nyquist.
- **Frame rate depends on acquisition time and the drawing path.** The DMM6500 screenshots show
  20 fps at 2,048 samples and 2.3 fps at 32,768 samples, both at 100 kS/s with the fast path active.
  The nominal record durations are 20.48 ms and 327.68 ms, respectively. The app adjusts the frame timer
  to leave time for front-panel input between frames. See [Performance](PERFORMANCE.md) for the
  measurement details.
- **The append path may update more slowly than the fast path.** The `F` indicator shows which
  path is active.
- **No rectangular or flat-top window.** Rectangular nulls one bin from the peak, which makes the
  three-bin estimate unusable; flat-top is seven bins wide.
- **The peak table skips bins affected by DC removal.** Its lowest candidate also depends on the
  span. The highest FFT bin has no sub-bin estimate.
- **No averaging and no peak hold.** Each frame is one capture.

## Troubleshooting

| Symptom | Cause |
|---|---|
| Trace pinned at the bottom | Range too high, or no signal. |
| Peak flat-topped at +20 dBV | Over range. |
| Peaks update but the trace is missing | Reapply the span or sample count. If the trace does not return, capture the About pages. |
| Trace frozen, peaks static | A capture is returning short. The app holds the last good frame rather than show a false spectrum. |
| No `F` at the start of the bottom line after a few frames | The trace may still be using the append path, which draws the same spectrum more slowly. If it persists at default settings, photograph all **About** pages. See [The `F` at the start of the bottom line](#the-f-at-the-start-of-the-bottom-line). |
| `F` keeps disappearing or showing a restart count | A few restarts are normal after a span or sample-count change. If they continue with the settings unchanged, capture the About pages. |
| Options, or any front-panel key, slow to respond | Close any LAN or USB control session. When using a long record, allow the current capture to finish. |
| An `APPLY FAILED` message replaces the settings line | Reopen Options and apply again. If the app stops, capture its diagnostic pages. |
| A red `FFT <version>` page instead of the analyser | The compiled path could not bind, or started and then gave up, and this archive has no interpreted fallback. See "If the app stops, or will not start" above: capture every page. |
| A help dialog sits over the app after pressing HELP | Press EXIT to dismiss the firmware's help dialog. |
| Peak width changes as you tune | Expected. See above. |
| A bump at the left edge, nothing in the table | It may be below the lowest reportable bin. See [The lowest frequency the table reports](#the-lowest-frequency-the-table-reports). |
