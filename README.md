# A spectrum analyser that runs on the DMM6500

A real-time FFT spectrum analyser for the Keithley DMM6500, running **entirely on the instrument** as
a TSP app. No host, no PC software: the digitizer captures, the instrument computes the transform in
Lua, and the firmware's own graph object draws the trace. Touch the front panel to change the span.

![the app running](docs/spectrum-working.png)

The DMM6500 is a bench multimeter, not a spectrum analyser. It does have a 1 MS/s digitizer, a
400 MHz processor and a touchscreen, and that turns out to be enough for a usable instrument at
around 12 frames a second.

## What it does

- **Digitizes** up to 1 MS/s into a reading buffer, 512 samples a frame.
- **Transforms** with a real-input radix-2 FFT in Lua 5.0.2, with the Hann window, the bit-reversal
  permutation and every twiddle factor precomputed once. 256 bins.
- **Plots** through the instrument's own `display.OBJ_GRAPH`, which costs one call per frame rather
  than one per point, and brings axes, grid, labels and auto-scaling with it.
- **Finds peaks** to sub-bin accuracy. A tone almost never lands on a bin centre, and a single-bin
  reading pays for it twice -- the frequency is quantised to the bin grid and the amplitude suffers
  scalloping loss, up to -1.42 dB for a Hann window. Both are recoverable in closed form from the
  peak bin and its two neighbours. Verified on hardware: a 12.000 kHz 1.000 V tone at 195.3 Hz bin
  width reads 11.914 kHz / 0.883 V from the peak bin alone, and 11999.8 Hz / 1.0016 V from the
  three-bin estimate.

The options form sets the span like a real analyser would: the **stop** frequency chooses the sample
rate (`fs` = the smallest exact rate at or above twice it, so a narrower span also gives finer
resolution), and the **start** frequency restricts what is displayed.

## Layout

```
FFT_Spectrum.tspa        the packaged app, installable from a USB key
tsp/fft_core.tsp         the transform: window, bit reversal, twiddles, butterflies, magnitude
tsp/spectrum_app.tsp     the options form and the run loop
tsp/spectrum_graph.tsp   the graph, its scaling, and the frequency axis
tsp/spectrum_ui.tsp      peak finding
tools/                   host-side helpers -- packaging, linting, screen capture, test harness
docs/PERFORMANCE.md      where the frame time goes, measured, and what is left to win
docs/pixel-drawing.pdf   the three render paths that were benchmarked, and why the graph won
```

## Building and installing

```sh
python3 tools/package_tspa.py          # -> FFT_Spectrum.tspa
lua tools/test_tsp.lua                 # the offline suite
python3 tools/lint_tsp.py tsp/*.tsp    # Lua 5.0.2 syntax gate
```

Copy `FFT_Spectrum.tspa` to a USB key, plug it into the instrument, and install it from
**MENU > Manage Apps**.

## Notes on the instrument

Two things shaped the whole design, and both are measured rather than assumed.

**Display calls are asynchronous messages to a second processor.** The CPU board carries two 400 MHz
PowerPC chips; the one with its own memory is the raster graphics engine. So what costs time is the
*number* of display messages per frame, not the amount of Lua work. Three render paths were
benchmarked -- the built-in graph object, N line objects, and the undocumented `display.setpixel` --
and the graph won by an order of magnitude. `docs/pixel-drawing.pdf` has the numbers.

**The arithmetic is not the bottleneck; the interpreter is.** A Lua table read costs about 1.4 µs and
an arithmetic operation about 1.2 µs, which at 400 MHz is some 480 cycles for one multiply whose
floating-point part is 3 to 5 cycles. Everything in `fft_core.tsp` that looks like premature
optimisation -- the precomputed tables, the aggressive local caching, the specialised first stage --
is there because the inner loop is table-access bound. `docs/PERFORMANCE.md` has the full cost model
and the remaining levers.

## Licence

MIT. See `LICENSE`.

Keithley's manuals and the processor reference manuals this work was done against are **not** in the
repository -- they are vendor copyright. Everything measured from them is quoted with its source
named.
