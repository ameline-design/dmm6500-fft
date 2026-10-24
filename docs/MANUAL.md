# FFT Spectrum Analyser

A spectrum analyser that runs on the instrument. The digitizer captures, the instrument computes the
transform, and the firmware's own graph object draws the trace. Nothing runs on a host.

Supported: DMM6500, DAQ6510, DMM7510.

## Install

1. Copy `FFT_Spectrum.tspa` to a USB key.
2. Plug the key into the front panel.
3. **MENU > Manage Apps**, select FFT Spectrum Analyser, install.
4. Run it from the same screen.

Leave with **End App**. That frees every screen and buffer the app made.

## The spectrum screen

![The spectrum screen: a 12 kHz tone at 1 V, 0 to 50 kHz span, Hann window](manual-spectrum.png)

The trace runs 0 to −120 dBV against frequency. Tick labels below the plot read in Hz or kHz. The
firmware's own numbers along the left edge are the dB values; ignore the `V` it suffixes them with.

Six peaks sit below the trace in two columns, strongest first, each as frequency, amplitude and level:

```
1  12.000 kHz   1.0016 V   0.0 dBV
```

**Options** opens the settings form. **End App** exits.

## Options

![The options form: five fields in two columns](manual-options.png)

Touch a field, set it, then **Apply**. **Cancel** discards.

| Field | What it does |
|---|---|
| Start Freq | Low edge of the display. Floor 10 Hz, because bin 1 is DC. |
| Stop Freq | Chooses the sample rate — the smallest exact rate at or above twice it. A narrower span therefore also gives finer resolution. |
| Input Range | Digitizer full scale: 0.1 V, 1 V or 10 V. |
| Window | Hann, Blackman, Blk-Harris or Kaiser. |
| Kaiser Beta | Sidelobe level, 4 to 18. Applies only when the window is Kaiser. |

The line below the fields reads back what the instrument settled on: the span, the sample rate, the
bin width, the range and the window. The sample rate snaps to one the hardware can produce, so it is
rarely the number you asked for.

Apply rebuilds the window and its tables, which takes about a third of a second. The panel shows the
loading screen while it works.

## Windows

A window tapers the 512 samples to zero at each end. Without one, the ends of the record form a step
that smears every tone across the whole spectrum. The taper buys that back, and the shape of the
taper sets what you can see.

Every window trades the same two things. A **narrow main lobe** resolves two close tones. **Low
sidelobes** reveal a weak tone beside a strong one. No window gives both.

| | Peak sidelobe | Scalloping loss | Peak width | Skirt swing |
|---|---|---|---|---|
| **Hann** (default) | −31.5 dB | −1.42 dB | 3–4 bins | 32.8 dB |
| **Blackman** | −58.1 | −1.09 | 3–4 | 15.3 |
| **Blk-Harris** | −92.0 | −0.82 | 4–5 | 8.2 |
| **Kaiser** β=4 | −30.0 | −2.06 | 2–3 | 7.6 |
| β=6 | −43.8 | −1.50 | 3–4 | 7.6 |
| β=9 | −66.3 | −1.06 | 4–5 | 13.3 |
| β=12 | −90.0 | −0.82 | 4–5 | 8.1 |
| β=15 | −114.0 | −0.67 | 5–6 | 6.1 |
| β=18 | −138.6 | −0.56 | 5–6 | 4.9 |

Which to use:

- **Hann** for general work. It resolves well and its peaks are narrow.
- **Blackman** or **Blk-Harris** to find a weak tone near a strong one.
- **Kaiser** when you want to choose the sidelobe floor. β sets it directly: about −7 dB per unit.
  β=6 matches Hann's resolution with 12 dB lower sidelobes; β=18 buries sidelobes at −139 dB and
  makes every peak six bins wide.

Kaiser β=4 has the narrowest main lobe here and the worst sidelobes. A tone 40 dB down and five bins
from a strong one disappears under them.

## Why a peak narrows at some frequencies

Sweep a generator slowly and the peak changes width. At some frequencies it stands up as a clean
spike; a few hundred hertz away it grows skirts. The signal has not changed.

The cause is where the bins fall. The DFT samples the window's transform at whole-bin offsets from
the tone. The Hann transform is **zero at every whole-bin offset past the first**. So a tone sitting
exactly on a bin centre puts all its neighbours in those zeros: three bins carry the tone and the
rest carry nothing. Move the tone half a bin and the neighbours land on the sidelobe envelope
instead, which is far from zero, and the skirts appear.

With Hann the level two bins out swings **32.8 dB** between those two cases. At 100 kS/s and N=512 the
bins are 195.3 Hz apart, so 25.000 kHz is bin 128 exactly and draws the spike, while 24.9 kHz does
not and draws the skirts.

**The narrow peak is the truthful one.** The skirts are leakage, not signal. Nothing is wrong with
either reading, and the amplitude in the peak table is right in both.

If the changing width is distracting, use **Kaiser at β=15 or β=18**. Their transforms do not null at
whole-bin offsets, so the skirt stays put as the tone moves — 5 to 6 dB of swing instead of 33. The
peak is about twice as wide in exchange.

## The peak table is more accurate than the trace

A tone almost never lands on a bin centre, and reading the tallest bin pays for that twice. The
frequency is quantised to the bin grid — up to half a bin out, 98 Hz at 195.3 Hz bins. The amplitude
reads low by the scalloping loss, up to 1.42 dB with Hann.

The peak table recovers both from the tallest bin and its two neighbours. On hardware, a 12.000 kHz
1.000 V tone reads 11.914 kHz / 0.883 V from the tallest bin alone, and 11999.8 Hz / 1.0016 V in the
table.

So the apex of the trace can sit 1.4 dB below the number printed under it. The number is right.

Accuracy of the estimate, over 83 sub-bin offsets and every window: **4.0e-6 bins of frequency error
and 0.0035 dB of amplitude error**, worst case. The estimator reads the window's own transform, so it
carries no per-window approximation.

## Limits

- **512 samples a frame, 256 bins.** Bin width is the sample rate over 512: 195.3 Hz at 100 kS/s.
- **About 10 frames a second.** The firmware's shortest timer period is 0.05 s and a tick arriving
  mid-frame is dropped, so the displayed rate is quantised to 20, 10, 6.67 and 5 fps.
- **Sample rates are a fixed set**: 1 k, 10 k, 20 k, 50 k, 100 k, 200 k, 500 k and 1 MS/s. Stop
  frequency picks from it.
- **1 MS/s ceiling**, so 500 kHz is the highest tone the instrument can show.
- **Two tones closer than one bin width merge.** Narrow the span to separate them: it lowers the
  sample rate, which narrows the bins.
- **Rectangular and flat-top windows are not offered.** Rectangular nulls one bin from the peak,
  which makes the three-bin estimate unusable. Flat-top is seven bins wide.
- **No averaging and no peak hold.** Each frame is one capture.

## Troubleshooting

| Symptom | Cause |
|---|---|
| Trace pinned at the bottom | Input range too high, or no signal. Try 0.1 V. |
| Peak flat-topped at +20 dBV | Signal over range. Raise the range. |
| Trace frozen, peaks static | A capture is returning short. The app holds the last good frame rather than show a false spectrum. |
| Text on the axis legend line | A failure message. It replaces `X: kHz  Y: dBV` and clears at the next span change. |
| Peak width changes as you tune | Expected. See above. |
