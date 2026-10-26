# A spectrum analyser that runs on the Keithley DMM6500, DMM7510, and DAQ6510

A real-time FFT spectrum analyser for the Keithley DMM6500, DAQ6510 and DMM7510, running **entirely
on the instrument** as a TSP app. The digitizer captures, the instrument computes the transform in
Lua, and the firmware's own graph object draws the trace. No host, no PC software.

![The spectrum screen at 16,384 samples: a 12.5 kHz 1.0014 V tone reading 0.0 dBV as a narrow spike, its 
second and third harmonics resolved as separate lines at 25.000 and 37.500 kHz, 81 and 83 dB down, over a 10 Hz 
to 50 kHz span with 6.1 Hz bins. The firmware labels the axes itself, +020.0dB down to -120.0dB and 
+00.00kHz across to +40.00kHz](docs/manual-spectrum-16384.png)

A bench multimeter is not a spectrum analyser. This one has a 1 MS/s digitizer, a 400 MHz processor
and a touchscreen, which is enough to resolve the second and third harmonics of a 12.5 kHz tone at
−83.5 and −84.1 dBV — 6.1 Hz bins at 16,384 samples, or 195 Hz bins at 10 frames a second.

`docs/MANUAL.md` is the user manual. Start there to operate it; read on for how it works.

## What it does

- **Digitizes** up to 1 MS/s, with selectable 512 to 16,384 samples per frame (default 512).
- **Transforms** with a real-input radix-2 FFT in Lua 5.0.2. The window, the bit-reversal permutation
  and every twiddle factor are precomputed when settings are applied. 256 to 8,192 bins.
- **Plots** through `display.OBJ_GRAPH`, one buffer refill a frame and no graph call in a frame
  nobody has touched, which brings axes, grid, labels and auto-scaling with it. The firmware labels both axes in real units --
  kHz across, from binding X to the reading's extra field rather than its timestamp, and dB down,
  from a two-character custom buffer unit. The trace is a fixed **255 columns** at every
  sample count, each carrying the **maximum of the bins it covers**, so a narrow tone always reaches
  it however many bins the span holds.
- **Finds six peaks** to sub-bin accuracy, correcting both the frequency and the scalloping loss.
- **Offers four windows**, Kaiser with six betas, and reads peaks exactly for each.
- **Locks the view.** The firmware's graph pans and zooms on touch and will not be told not to, so a
  brushed screen slides the trace off its axes. On by default, and free until you touch it: the graph
  reports its own pan, and a once-a-second check does nothing without a report. One that has a report
  reads the limits back at 0.0094 ms and rewrites only an axis that really moved — a write costs
  60 ms, so doing it per frame collapsed the update rate. The padlock toggles it: press once to pan
  freely, press again to lock and snap the window back at once. The cog beside it opens Options.

The span windows the display and may only *raise* the sample rate, never lower it: zooming in leaves
acquisition at 100 kS/s and, with the default 512 samples, 195.3 Hz bins. Widening past 50 kHz steps 
the rate up to 1 MS/s and coarsens the bins with it. There is no anti-alias filter, so a rate chosen 
below the signal's own content folds it into view.

More samples give finer bins without reducing bandwidth: 16,384 samples at 100 kS/s give
6.10 Hz spacing. Larger sizes cost update rate. `docs/PERFORMANCE.md` has every size measured.

![The same tone at the default 512 samples: one 195 Hz-wide lump, the harmonics lost in the noise 
floor, at 10 frames a second](docs/manual-spectrum.png)

The same signal at the default 512 samples, for comparison: 195 Hz bins at 10 frames a second, where
the harmonics are in the floor. 

## Choosing a window

| | peak sidelobe | scalloping loss | -20 dB peak width | skirt swing |
|---|---|---|---|---|
| **Hann** (default) | -31.5 dB | -1.42 dB | 3-4 bins | 49.8 dB |
| **Blackman** | -58.1 | -1.09 | 3-4 | 10.8 |
| **Blk-Harris** | -92.0 | -0.82 | 4-5 | 7.2 |
| **Kaiser** β=4 | -30.0 | -2.06 | 2-3 | 3.9 |
| β=6 | -43.8 | -1.50 | 3-4 | 21.9 |
| β=9 | -66.3 | -1.06 | 4-5 | 10.1 |
| β=12 | -90.0 | -0.82 | 4-5 | 7.2 |
| β=15 | -114.0 | -0.67 | 5-6 | 5.6 |
| β=18 | -138.6 | -0.56 | 5-6 | 4.7 |

**Skirt swing** is the one that is not a textbook number: the level at the second bin from the peak, 
on a bin centre against half a bin off. On a centre that bin sits 2.0 bins from the tone; half a bin off, 
the nearer of the two sits 1.5 bins away — so the figure is how far the window's transform rises between 
those two offsets, and it is what makes a tone at exactly 25 kHz look sharper than the same tone at
24 kHz. Hann swings 50 dB, because its transform nulls at 2 bins exactly. Kaiser at β=15 or 18 cuts
that to 5 dB and doubles the peak width; β=6 is the other extreme at 22 dB, its main lobe ending at
2.16 bins. `docs/MANUAL.md` explains the effect for an operator.

**The peak estimate is exact for every window, in the middle of the spectrum.** `fft_init` samples
the window's own transform into a 61-point table, inverts the offset-to-ratio curve from it, and reads
the scalloping correction from the same table, so the estimator is derived from the window in use
rather than fitted to one and approximated for the rest. Worst case over 83 sub-bin offsets and all
nine settings: **4.0e-6 bins of frequency error and 0.0035 dB of amplitude error**, both at Kaiser
β=4. 

## Licence

MIT. See `LICENSE`.

