-- legacy/line_renderer.tsp -- SUPERSEDED standalone OBJ_LINE spectrum renderer.
--
-- NOT part of the app or the .tspa build -- kept for reference only. The live app
-- renders through the instrument's built-in graph (tsp/spectrum_graph.tsp). This
-- was an earlier approach that drew the trace as short OBJ_LINE marks moved with
-- display.setposition(). The one function still in use, ui_find_peaks(), lives in
-- tsp/spectrum_ui.tsp; this file depends on it (and on fft_core.tsp's fft_mag).
--
-- Line-renderer notes: display.setposition() cost scales with the pixel area the
-- display processor repaints, so full-height bars "crawl" visibly; each bin is
-- drawn as one short 3x2 px mark instead. Static objects are created once (object
-- creation is ~12 ms each); the frame loop only calls setposition() and settext().
--
-- Usage: ui_build(title, nbins) once; per frame ui_draw(nbins) and
-- ui_show_peaks(bi, bv, count, fs, nbins); ui_set_span(fs, nbins) on setup.

-- ---------------------------------------------------------------- layout ----
-- Panel is 800x480; the app title bar takes roughly the top 45 px.
-- X is limited to 1..798 ("1130 Parameter X, expected value from 1 to 798").
UI_X0      = 14      -- left edge of the plot
UI_TOP     = 50      -- tight under the title bar
UI_BOT     = 300     -- bottom of the plot area (baseline)
UI_STEP    = 3       -- px per bin -> 14 + 255*3 = 779, inside the limit
UI_MARK_H  = 2       -- mark height in px: keep tiny, this drives the frame rate
UI_THICK   = 2       -- mark thickness (vertical extent of the drawn segment)

UI_C_BAR   = 0x00FF00   -- full-brightness green trace
UI_C_PEAK  = 0xFF0000   -- full-brightness red peak markers
UI_C_AXIS  = 0x909090
UI_C_LABEL = 0x00DCFF
UI_C_VALUE = 0xE0E0E0

UI_DBMIN   = -100
UI_DBMAX   = 20

ui_scr     = nil
ui_bars    = nil     -- one short mark per bin
ui_peaks   = nil     -- peak markers
ui_ptext   = nil     -- peak readout texts
ui_ftext   = nil     -- frequency axis labels
ui_stat    = nil
ui_prev    = nil     -- previous y per bin, so unchanged marks are skipped

function ui_build(title, nbins)
  local create, setcolor = display.create, display.setcolor
  local small = display.FONT_SMALL
  ui_scr = create(display.ROOT, display.OBJ_SCREEN, title)
  display.changescreen(ui_scr)

  -- Trace marks. Short segments, parked on the baseline.
  ui_bars = {}
  ui_prev = {}
  for i = 1, nbins do
    local x = UI_X0 + (i - 1) * UI_STEP
    if x > 798 then x = 798 end
    if x < 1 then x = 1 end
    local ln = create(ui_scr, display.OBJ_LINE, x, UI_BOT, x + 2, UI_BOT)
    setcolor(ln, UI_C_BAR)
    display.setthickness(ln, UI_THICK)
    ui_bars[i] = ln
    ui_prev[i] = UI_BOT
  end

  -- Frequency axis labels. Text objects appear to be anchored so that they
  -- extend UPWARD from the given y, so these sit well below the plot baseline to
  -- avoid overlapping the trace.
  ui_ftext = {}
  for k = 0, 5 do
    local x = UI_X0 + math.floor(k * (nbins - 1) * UI_STEP / 5) - 14
    if x < 2 then x = 2 end
    if x > 750 then x = 750 end
    local t = create(ui_scr, display.OBJ_TEXT, x, UI_BOT + 26, "----", UI_C_AXIS, small)
    ui_ftext[k] = t
  end

  -- Peak readout, small font, two columns to fit under the plot.
  ui_ptext = {}
  ui_peaks = {}
  for p = 1, 5 do
    local col = 0
    local row = p - 1
    if p > 3 then col = 1; row = p - 4 end
    local x = UI_X0 + col * 400
    local y = UI_BOT + 52 + row * 20
    local t = create(ui_scr, display.OBJ_TEXT, x, y,
                     string.format("%d  ---", p), UI_C_VALUE, small)
    ui_ptext[p] = t
    -- Peak marker: a short thick red segment sitting just above the trace.
    local m = create(ui_scr, display.OBJ_LINE, 1, UI_TOP, 3, UI_TOP)
    setcolor(m, UI_C_PEAK)
    display.setthickness(m, 4)
    ui_peaks[p] = m
  end

  ui_stat = create(ui_scr, display.OBJ_TEXT, UI_X0 + 400, UI_BOT + 112, "",
                   UI_C_LABEL, small)
  return ui_scr
end

function ui_set_span(fs_actual, nbins)
  local nyq = fs_actual / 2
  for k = 0, 5 do
    local f = nyq * k / 5
    local s
    if f >= 1000 then s = string.format("%.0fk", f / 1000)
    else s = string.format("%.0f", f) end
    display.settext(ui_ftext[k], s)
  end
end

-- Move each bin's mark to its amplitude. Only marks that actually moved are
-- touched: display.setposition() is the dominant per-frame cost.
function ui_draw(nbins)
  local setpos = display.setposition
  local bars   = ui_bars
  local prev   = ui_prev
  local mag    = fft_mag
  local floor  = math.floor
  local log10  = math.log10
  local x0     = UI_X0
  local step   = UI_STEP
  local top    = UI_TOP
  local bot    = UI_BOT
  local dbmin  = UI_DBMIN
  local dbmax  = UI_DBMAX
  local span   = dbmax - dbmin
  local hpx    = bot - top

  for i = 1, nbins do
    local v = mag[i]
    local db
    if v <= 1e-9 then db = dbmin else db = 20 * log10(v) end
    if db < dbmin then db = dbmin end
    if db > dbmax then db = dbmax end
    local y = bot - floor((db - dbmin) / span * hpx)
    if y < top then y = top end
    if y > bot then y = bot end
    if y ~= prev[i] then
      local x = x0 + (i - 1) * step
      if x > 796 then x = 796 end
      setpos(bars[i], x, y, x + 2, y)
      prev[i] = y
    end
  end
end

function ui_show_peaks(bi, bv, count, fs_actual, nbins)
  local binhz = fs_actual / (nbins * 2)
  local floor, log10 = math.floor, math.log10
  for p = 1, count do
    local k = bi[p]
    if k > 0 and bv[p] > 0 then
      local f = (k - 1) * binhz
      local v = bv[p]
      local ftxt
      if f >= 1000 then ftxt = string.format("%7.2fk", f / 1000)
      else ftxt = string.format("%7.1f ", f) end
      local vtxt
      if v >= 1 then vtxt = string.format("%6.3fV", v)
      elseif v >= 1e-3 then vtxt = string.format("%6.1fmV", v * 1e3)
      else vtxt = string.format("%6.0fuV", v * 1e6) end
      local db = -200
      if v > 1e-9 then db = 20 * log10(v) end
      display.settext(ui_ptext[p],
        string.format("%d %sHz %s %5.0fdB", p, ftxt, vtxt, db))
      local x = UI_X0 + (k - 1) * UI_STEP
      if x > 796 then x = 796 end
      local dbc = db
      if dbc < UI_DBMIN then dbc = UI_DBMIN end
      if dbc > UI_DBMAX then dbc = UI_DBMAX end
      local y = UI_BOT - floor((dbc - UI_DBMIN) / (UI_DBMAX - UI_DBMIN) * (UI_BOT - UI_TOP)) - 7
      if y < UI_TOP then y = UI_TOP end
      display.setposition(ui_peaks[p], x, y, x + 2, y)
    else
      display.settext(ui_ptext[p], string.format("%d  ---", p))
      display.setposition(ui_peaks[p], 1, UI_TOP, 3, UI_TOP)
    end
  end
end

function ui_status(txt)
  display.settext(ui_stat, txt)
end
