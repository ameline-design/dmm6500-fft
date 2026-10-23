# Where the frame time goes, and what is left to win

Every figure here was **measured on the instrument** (DMM6500, firmware 1.7.17a) on 2026-10-23,
except where it says otherwise. The cost model came out of a separate reverse-engineering pass over
the firmware image; the reasoning that depends on the firmware's internals is marked as such, and
the write-up of that pass lives in the serial-decode repo at `docs/FIRMWARE_API.md`.

The short version: **precision is not what this app pays for, and neither is the FFT's arithmetic.**
It pays for interpreter dispatch and for marshalled calls across the TSP API. Every lever below is
about doing fewer operations, not cheaper ones.

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
| `display.setpixel(...)` | 10.8 - 14.6 µs | 2,500 and 60,000 call runs |
| `display.flush(obj)` | **0.203 s** for an 800x480 surface | see the surface note below |

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

### 1. Real-input packing: about 15 ms, and it is exact

This is the biggest single lever and it is not yet taken. `fft_run` exploits real input in exactly two
places -- the bit-reversal permutes `re[]` alone, and stage 1 is add/sub with no `im[]` writes -- but
**stages 2 through 9 are full complex butterflies over all N points.**

The standard trick: pack the N real samples as N/2 complex points, `z[k] = x[2k] + i*x[2k+1]`, run an
**N/2-point** complex FFT, then untangle with one O(N/2) pass.

Counting the actual loops: inner iterations per stage are `(N/len)*(len/2) = N/2 = 256`, over
`log2(N)-1 = 8` stages.

| | full complex butterflies | cheap stage-1 | untangle |
|---|---|---|---|
| now | 2048 | 256 | -- |
| packed, M = 256 | **896** | 128 | 128 points |

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

### 3. Drop the sqrt from the magnitude pass: free

If the display is dB, then `20*log10(sqrt(a*a + b*b))` is `10*log10(a*a + b*b)` -- the sqrt
disappears entirely. That is 256 C calls at ~4 µs gone, about 1 ms, for one edit and **no loss of
accuracy at all**.

### 4. Cache `buffer.write.reading` in a local: 1.8 ms

Measured: 72 µs a call through the table, 65 µs through a local. At 256 points that is 1.8 ms a frame
for one line.

### 5. Plot fewer points: 65 µs each

Every point not plotted is 65 µs. The graph object is at most 799 px wide, so above about 780 visible
bins the detail cannot be seen anyway. Halving 256 to 128 is ~8 ms, at half the plotted resolution.

Taken together, 1 + 3 + 4 is about **18 ms off 80**, with no resolution cost: roughly **16 fps**.

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
cheaper than the read. And a 256x256 binary table is ~65,536 TValues, about **1 MB** of Lua heap plus
~0.2 s to build, for a 32 % saving over `bit.bitand`: a poor trade unless the operation is hot.

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

It is still the wrong path -- the graph object plots 200 points end to end in ~32 ms, against a flush
alone at 0.203 s -- but the reasons are worth recording, because neither is obvious.

**The image's surface is owned by its *name*, not by the object.**
`display.create(parent, display.OBJ_IMAGE, x, y, name, w, h)` takes a string as its 5th argument, and
that string names the surface. A 400x200 object created with a name already bound to an 800x480
surface displays and flushes that 800x480 surface -- the `w`/`h` arguments do not resize it. A name
with no surface renders a small blue "?" placeholder, and `setpixel` into it writes nothing and posts
**no event at all** (measured with 60,000 calls). On a freshly booted instrument the first fresh name
allocated a surface and worked; later fresh names got the placeholder, which suggests the surface is
not released when the object is deleted.

**`flush` is a chunked bulk copy, so its cost is proportional to surface area.** It pushes the entire
pixel block to the display processor over channel 9 in 240-byte chunks under a per-channel lock: an
800x480 32-bit surface is 1,536,000 bytes, 6,400 chunks. Measuring 0.203 s for both a 400x200 and an
800x480 object looks like a fixed cost and is not -- both were flushing the same surface, per the
name rule above.

`OBJ_IMAGE` (type 5) is the **only** object type with a pixel surface. `OBJ_RECT` posts event 1717,
"Attribute pixel, does not apply to an object of type Rectangle", once per call.

## The frequency axis

The existing `sg_pick_fscale()` steps `s` by ten while `fhi/s >= 59`, so a 500 kHz span lands on
`s = 10000` and the reader has to multiply the label by ten.

**Fixing `s = 1e6` removes that.** The whole 0-500 kHz span then maps to 0-0.5 label-seconds, so it
never reaches a minute and base 60 cannot appear, and the graph's own SI prefixes line up with the
units: `s` is MHz, `ms` is kHz, `us` is Hz. 12.5 kHz labels itself `12.5ms`. One constant instead of a
multiplier the reader has to apply.

Unverified: whether the graph prefixes sub-second timestamps as `ms`/`us` or prints `0.0125s`. Both
are decimal and unambiguous; only the first reads directly as kHz. One screenshot settles it.

Related, from the firmware: units are `buffer.UNIT_*`, with `UNIT_HERTZ = 9` and `UNIT_SECOND = 10`.
`UNIT_SECOND` is the only horizontal-axis unit the firmware demonstrably exercises, and two of the
three unit symbol tables in the image have Hertz pointing at an **empty string** -- which is a
plausible shape for the frequency-units crash, though the failing call was never captured so the
mechanism is unproven. Treat every unit other than `UNIT_SECOND` as unvalidated.

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
