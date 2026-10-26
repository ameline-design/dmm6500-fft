# Panel icons

The images `tools/package_tspa.py` embeds in `FFT_Spectrum.tspa`, one `loadimage` block each.

| file | size | where it appears |
|---|---|---|
| `fftlockc.png` | 28x34 | closed padlock — the Lock button while the view is locked |
| `fftlocko.png` | 28x34 | open padlock — the Lock button while the view is free |
| `fftcog.png` | 34x34 | cog — the Options button |

**Which files get embedded is decided by the script, not by this directory.** The packager reads the
`fftsa.img_* = "name"` declarations out of `tsp/` and requires `assets/<name>.png` for each. A
declared name with no file is a packaging failure, and so is a file nothing declares — because a
missing image draws nothing and reports nothing, which on the glass is a blank button.

`loadimage` wants "standard PNG format (compressed 24 bit with Alpha)". These are 8-bit RGBA with
IHDR, IDAT and IEND and nothing else; `png_size()` in the packager rejects anything but 8-bit RGB or
RGBA. A button face is light grey, so the glyphs are near-black on transparency.

The App icon, `fft_icon`, is not here: `png_icon()` in the packager draws it.

All three arrived with the contributed view-lock change, in v2.2.
