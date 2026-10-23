-- spectrum.tsp -- spectrum-analyser render path for the DMM6500
--
-- Companion to fft_core.tsp. Owns the pixel canvas and the per-frame draw.
--
-- Split of responsibilities, per the "documented API for chrome, pixels for the
-- fast-changing trace" principle:
--   * documented display API  -> screen, title, axis labels, peak readouts
--   * undocumented setpixel   -> the trace itself, redrawn every frame
--
-- The canvas is an OBJ_IMAGE created with explicit WIDTH/HEIGHT (the 7-argument
-- form), which is what allocates an addressable pixel buffer. Without those two
-- trailing arguments every write fails with
--   1130 Parameter x, expected value from 0 to -1
--
-- Redraw is differential: we remember the column height drawn last frame and
-- only erase the delta, so a frame costs O(W) writes rather than O(W*H).

SP_W      = 750      -- canvas width in pixels (leaves room for a y axis legend)
SP_H      = 360      -- canvas height
SP_X      = 45       -- canvas origin on screen
SP_Y      = 60
SP_BG     = 0x000008 -- near black; mid greys wash the trace out
SP_FG     = 0x00FF00 -- full-brightness green, 2 px thick
SP_GRID   = 0x203040
SP_PEAK   = 0xFF3030

sp_img    = nil      -- image object id
sp_scr    = nil      -- host screen id
sp_prev   = nil      -- previous bar height per column (differential redraw)
sp_col2bin = nil     -- column -> bin map, precomputed
sp_dbmin  = -100     -- dB floor of the plot
sp_dbmax  = 20       -- dB ceiling (20 dBV ~ 10 Vpk)

-- Map each display column to a spectrum bin once, at setup.
-- With 256 bins over 750 columns each bin is ~3 columns wide, so this is a
-- cheap nearest-neighbour stretch (off-by-one is invisible at this scale).
function sp_map_columns(nbins)
  sp_col2bin = {}
  local w = SP_W
  for x = 0, w-1 do
    local b = math.floor(x * nbins / w) + 1
    if b > nbins then b = nbins end
    sp_col2bin[x] = b
  end
end

-- Create the host screen and the pixel canvas. `imgname` must already have been
-- uploaded with the loadimage shell directive.
function sp_setup(imgname, nbins, title)
  sp_scr = display.create(display.ROOT, display.OBJ_SCREEN, title)
  display.changescreen(sp_scr)
  -- NOTE the trailing SP_W, SP_H: without them setpixel cannot address anything.
  sp_img = display.create(sp_scr, display.OBJ_IMAGE, SP_X, SP_Y, imgname, SP_W, SP_H)
  -- -1 means "nothing drawn yet in this column", so the first frame draws
  -- without trying to erase a stale pixel.
  sp_prev = {}
  for x = 0, SP_W-1 do sp_prev[x] = -1 end
  sp_map_columns(nbins)
  return sp_img
end

-- Convert a magnitude in volts-peak to a plot row (0 = top).
-- Uses dB so the noise floor and the fundamental are visible at once.
function sp_v_to_row(v)
  local db
  if v <= 1e-9 then
    db = sp_dbmin
  else
    db = 20 * math.log10(v)
  end
  if db < sp_dbmin then db = sp_dbmin end
  if db > sp_dbmax then db = sp_dbmax end
  local frac = (db - sp_dbmin) / (sp_dbmax - sp_dbmin)   -- 0 at floor, 1 at top
  return math.floor((1 - frac) * (SP_H - 1))
end

-- Draw one frame as a single-pixel-wide TRACE (not filled bars).
--
-- A filled bar graph costs O(sum of bar heights) writes, which for a noisy
-- spectrum is most of the canvas every frame (measured: 210 ms). A trace costs
-- exactly 2 writes per column for the erase + 2 for the draw, i.e. O(W), which
-- is what makes an interactive frame rate possible.
--
-- The trace is 2 px thick because the panel's physical pixels are tiny.
function sp_draw_trace(nbins)
  local sp    = display.setpixel
  local img   = sp_img
  local prev  = sp_prev
  local c2b   = sp_col2bin
  local mag   = fft_mag
  local W     = SP_W
  local bg    = SP_BG
  local fg    = SP_FG
  local floor = math.floor
  local log10 = math.log10
  local dbmin = sp_dbmin
  local dbspan = sp_dbmax - sp_dbmin
  local hm1   = SP_H - 1

  for x = 0, W-1 do
    local v = mag[c2b[x]]
    local db
    if v <= 1e-9 then db = dbmin else db = 20*log10(v) end
    if db < dbmin then db = dbmin end
    if db > sp_dbmax then db = sp_dbmax end
    -- row 0 is the top of the canvas, so invert
    local y = floor((1 - (db - dbmin)/dbspan) * hm1)
    if y < 0 then y = 0 end
    if y >= hm1 then y = hm1 - 1 end

    local p = prev[x]
    if p ~= y then
      if p >= 0 then
        sp(img, x, p, bg)
        sp(img, x, p+1, bg)
      end
      sp(img, x, y, fg)
      sp(img, x, y+1, fg)
      prev[x] = y
    end
  end
  display.flush(img)
end

-- Draw one frame of the spectrum as a filled bar graph, differentially.
-- Bars grow from the bottom; only the changed part of each column is touched.
-- Kept for comparison: correct, but ~210 ms/frame on a noisy spectrum.
function sp_draw(nbins)
  local sp     = display.setpixel
  local img    = sp_img
  local prev   = sp_prev
  local c2b    = sp_col2bin
  local mag    = fft_mag
  local H      = SP_H
  local W      = SP_W
  local bg     = SP_BG
  local fg     = SP_FG
  local floor  = math.floor
  local log10  = math.log10
  local dbmin  = sp_dbmin
  local dbspan = sp_dbmax - sp_dbmin
  local hm1    = H - 1

  for x = 0, W-1 do
    local v = mag[c2b[x]]
    -- inline of sp_v_to_row: this is the hot loop, a call per column costs real
    -- time on a 5.0.2 interpreter
    local db
    if v <= 1e-9 then db = dbmin else db = 20*log10(v) end
    if db < dbmin then db = dbmin end
    local h = floor((db - dbmin) / dbspan * hm1)
    if h < 0 then h = 0 end
    if h > hm1 then h = hm1 end

    local p = prev[x]
    if h > p then
      -- bar grew: paint the new segment only
      for y = hm1 - h, hm1 - p - 1 do sp(img, x, y, fg) end
    elseif h < p then
      -- bar shrank: erase the vacated segment only
      for y = hm1 - p, hm1 - h - 1 do sp(img, x, y, bg) end
    end
    prev[x] = h
  end
  display.flush(img)
end

-- Clear the canvas completely (used on setup and on span changes).
-- Expensive (W*H writes) so it must not happen per frame.
function sp_clear()
  local sp  = display.setpixel
  local img = sp_img
  local bg  = SP_BG
  for y = 0, SP_H-1 do
    for x = 0, SP_W-1 do sp(img, x, y, bg) end
  end
  for x = 0, SP_W-1 do sp_prev[x] = -1 end
  display.flush(img)
end
