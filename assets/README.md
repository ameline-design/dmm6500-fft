# Panel icons

The images `tools/package_tspa.py` embeds in `FFT_Spectrum.tspa`, one `loadimage` block each.

| file | size | where it appears |
|---|---|---|
| `fftlockc.png` | 28x34 | closed padlock — the Lock button while the view is locked |
| `fftlocko.png` | 28x34 | open padlock — the Lock button while the view is free |
| `fftcog.png` | 34x34 | cog — the Options button |

**Which files get embedded is decided by the script, not by this directory.** The packager reads the
`fftsa.img_* = "name"` declarations out of `tsp/` and requires `assets/<name>.png` for each. A
declared name with no file is a packaging failure, and so is a file nothing declares.

**A name the firmware has no image for is not a blank button and is not reported.**
`display.create(OBJ_IMAGE, ...)` returns a live handle either way, so the script's own "image
did not load" guard cannot fire and `lasterr` stays nil; what appears is the firmware's own
placeholder, a 46-pixel blue block with a red glyph, at the same size whatever the image was
declared to be. Measured on the panel: both buttons drew it at 46 px for a 28x34 and a 34x34
icon.

**8-bit RGB, colour type 2, filter 0 on every row, one IDAT, no ancillary chunks.** The
documentation for `loadimage` says "standard PNG format (compressed 24 bit with Alpha)", and
8-bit RGBA is what these were until the placeholder above was traced to them: the one image on
the instrument that does render, the App icon, is type 2, and `png_icon()` in the packager has
always written it that way. `png_size()` accepts either, so the packager will not catch a
regression here — the panel will. The button face is **(157,157,157)**, sampled off a capture,
and the alpha is composited onto it, so the glyphs read correctly without a decoder that
blends.

The App icon, `fft_icon`, is not here: `png_icon()` in the packager draws it.

All three arrived with the contributed view-lock change, in v2.2.
