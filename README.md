# A spectrum analyser that runs on the DMM6500

A real-time FFT spectrum analyser for the Keithley DMM6500, DAQ6510 and DMM7510, running **entirely
on the instrument** as a TSP app. The digitizer captures, the instrument computes the transform in
Lua, and the firmware's own graph object draws the trace. No host, no PC software.

![The spectrum screen: two tones at 21.1 and 42.2 kHz, 4.5 and 4.0 V, over a 0 to 50 kHz span with the Hann window](docs/manual-spectrum.png)

A bench multimeter is not a spectrum analyser. This one has a 1 MS/s digitizer, a 400 MHz processor
and a touchscreen, which is enough for 195 Hz resolution at 10 frames a second.

`docs/MANUAL.md` is the user manual. Start there to operate it; read on for how it works.

## What it does

- **Digitizes** up to 1 MS/s, 512 samples a frame, into a reading buffer.
- **Transforms** with a real-input radix-2 FFT in Lua 5.0.2. The window, the bit-reversal permutation
  and every twiddle factor are precomputed once. 256 bins.
- **Plots** through `display.OBJ_GRAPH`, one call a frame rather than one a point, which brings axes,
  grid, labels and auto-scaling with it.
- **Finds six peaks** to sub-bin accuracy, correcting both the frequency and the scalloping loss.
- **Offers four windows**, Kaiser with six betas, and reads peaks exactly for each.

The span windows the display and may only *raise* the sample rate, never lower it: zooming in leaves
acquisition at 100 kS/s and 195.3 Hz bins, while widening past 50 kHz steps the rate up to 1 MS/s and
coarsens the bins with it. There is no anti-alias filter, so a rate chosen below the signal's own
content folds it into view — a pure 21.1 kHz sine, sampled for a 7 kHz span, drew a 4.51 V peak at
1.100 kHz. Raising the rate can only remove aliases; lowering it is what creates them.

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

`tools/window_check.lua` measures every figure from the window the instrument builds. **Skirt swing**
is the one that is not a textbook number: the level at the second bin from the peak, on a bin centre
against half a bin off. On a centre that bin sits 2.0 bins from the tone; half a bin off, the nearer
of the two sits 1.5 bins away — so the figure is how far the window's transform rises between those
two offsets, and it is what makes a tone at exactly 25 kHz look sharper than the same tone at
24 kHz. Hann swings 50 dB, because its transform nulls at 2 bins exactly. Kaiser at β=15 or 18 cuts
that to 5 dB and doubles the peak width; β=6 is the other extreme at 22 dB, its main lobe ending at
2.16 bins. `docs/MANUAL.md` explains the effect for an operator.

**The peak estimate is exact for every window, in the middle of the spectrum.** `fft_init` samples
the window's own transform into a 61-point table, inverts the offset-to-ratio curve from it, and reads
the scalloping correction from the same table, so the estimator is derived from the window in use
rather than fitted to one and approximated for the rest. Worst case over 83 sub-bin offsets and all
nine settings: **4.0e-6 bins of frequency error and 0.0035 dB of amplitude error**, both at Kaiser
β=4. `tools/test_tsp.lua` pins them at 1e-5 bins and 0.008 dB, and proves the sweep failable by
feeding one window's data to another's tables.

Both ends of the spectrum are four to six orders worse, and the suite now bounds them separately.

| | frequency | amplitude |
|---|---|---|
| middle of the span | 4.0e-6 bins | 0.0035 dB |
| lowest bin the table reports | 0.102 bins | 0.15 dB |
| top bin of the span | 0.494 bins | 2.3 to 7.1 dB low |

The top bin has no neighbour above it, so `peak_interp` declines and the caller reads the raw bin. At
the low end the DC removal owns the first bin or two: the weighted mean of a record with a tone inside
the window's main lobe of DC *is partly the tone*, so removing it takes `2·G(b)²` out of the tone's
own bin — a 1.000 V tone on bin 1 reads 0.589 V under Hann and moves with the capture phase. No mean
rule does better; the arithmetic mean instead leaves a −27 dBc line at bin 1 for any off-centre tone
anywhere in the spectrum. `fft_init` measures how far the damage reaches (`fft_kdc`, one bin for Hann
and two for Blackman-Harris) and `find_peaks` will not report those bins. The trace still draws them.
`docs/MANUAL.md` states the resulting lowest reported frequency.

Rectangular and Hamming are absent. Rectangular's transform nulls one bin from the peak, which leaves
the three-bin estimate ill-conditioned; Kaiser β=6 covers Hamming to within a dB.

Mixed signals are where the choice earns its keep. A weak tone 40 dB down and 5 bins from a strong
one reads -38.5 dBV under Hann, whose own sidelobes add in, and -39.8 under Blackman-Harris. Kaiser
β=4 misses it entirely: -30 dB sidelobes bury a -40 dB tone.

## Layout

```
FFT_Spectrum.tspa        the packaged app, installable from a USB key
tsp/fft_core.tsp         the transform: windows, bit reversal, twiddles, butterflies, peak estimate
tsp/spectrum_app.tsp     the options form and the run loop
tsp/spectrum_graph.tsp   the graph, its scaling, and the frequency axis
tsp/spectrum_ui.tsp      the loading cover and peak finding
tools/window_check.lua   what the peak estimator achieves, per window, against known tones
tools/                   packaging, linting, screen capture, test harness
docs/MANUAL.md           the user manual
docs/PERFORMANCE.md      where the frame time goes, and what is left to win
docs/pixel-drawing.pdf   why the graph object beat line objects and setpixel
```

## Building and installing

```sh
python3 tools/package_tspa.py                           # -> FFT_Spectrum.tspa, gated
~/tmp/base/out/lua502/bin/lua tools/test_tsp.lua        # the offline suite
~/tmp/base/out/lua502/bin/lua tools/window_check.lua    # per-window accuracy
python3 tools/lint_tsp.py tsp/*.tsp                     # Lua 5.0.2 syntax gate
```

Copy `FFT_Spectrum.tspa` to a USB key and install it from **MENU > Manage Apps**.

**Run the suite under Lua 5.0.2, never the `lua` on `$PATH`.** The instrument is 5.0.2; later
versions accept hex literals, `#`, string methods and `string.match`, none of which it takes. A parse
error anywhere in the archive leaves `fftsa` nil, so every call raises `-286` on the panel.
`package_tspa.py` gates itself against that: it runs the linter, then compiles the *assembled* script
with 5.0.2's own compiler, before writing anything. A missing 5.0.2 compiler is a refusal, not a skip.

## Notes on the instrument

Two measured facts shape the whole design.

**The display runs in another task on the same core, and only while Lua is blocked.** A separate GUI
task draws, not the second PowerPC: the start-up code creates it locally and the channel the display
API talks over is in-process. Sharing the one core with the interpreter, it is scheduled only when
the Lua task blocks — so a Lua frame rate means nothing by itself. A frame loop with a 5 ms yield
measures 35.6 Hz in Lua while dropping display messages and updating the glass three times a second.
Every frame therefore blocks once, deliberately, for the paint.

That also fixes the frame rate. A timer tick arriving mid-frame is dropped rather than queued, and
the shortest period the firmware accepts is 0.05 s, so the displayed rate is quantised to
`1/(0.05 × ceil(frame/0.05))` — 20, 10, 6.67 fps and nothing between. Getting a frame under 50 ms
doubles the rate; shaving it from 81 ms to 55 ms buys nothing.

**The interpreter is the bottleneck, not the arithmetic.** A Lua table read costs about 1.4 µs and an
arithmetic operation about 1.2 µs — some 480 cycles at 400 MHz for one multiply whose floating-point
part is 3 to 5 cycles. Everything in `fft_core.tsp` that looks like premature optimisation is there
because the inner loop is table-access bound. `docs/PERFORMANCE.md` has the cost model.

## Licence

MIT. See `LICENSE`.

Keithley's manuals and the processor reference manuals this work was done against are **not** in the
repository — they are vendor copyright. Everything measured from them is quoted with its source
named.
