-- spectrum_ui.tsp -- the loading cover and the peak finder.

fftsa = fftsa or {}   -- the single global this app exposes

-- ---------- loading cover ----------
-- A screen with nothing on it but a line of text, held in front while the real
-- screens are built and while Apply rebuilds the window tables. Creating a screen
-- makes it active, so every screen build raises this again before its first child or
-- the operator watches the screen assemble itself, one 12 ms create at a time.
--
-- Created once by fftsa.loading_build() and deleted once by fftsa.stop(), so it
-- outlives the build and is there for the Apply that rebuilds the window tables.
-- Raising it is a changescreen and nothing else: creating and deleting a cover per
-- raise would put two objects of the 463-object pool through a create/delete cycle
-- every time, and a refused delete raises nothing.
if fftsa.load_handles_inited == nil then
  fftsa.loadscr = nil
  fftsa.loadtxt = nil
  fftsa.load_handles_inited = true
end
-- x for the string below on FONT_MEDIUM, measured on the panel.
fftsa.load_x = 261
fftsa.load_y = 214

function fftsa.loading_build()
  if fftsa.loadscr ~= nil then return fftsa.loadscr end
  fftsa.loadscr = display.create(display.ROOT, display.OBJ_SCREEN, "FFT SPECTRUM ANALYSER")
  if fftsa.loadscr == nil then return nil end     -- pool exhausted; a visible build is the cost
  fftsa.loadtxt = display.create(fftsa.loadscr, display.OBJ_TEXT, fftsa.load_x, fftsa.load_y,
                                 "Loading, please wait...", 16777215, display.FONT_MEDIUM)
  -- End App is hooked here too: the firmware may deliver EVENT_ENDAPP only to the
  -- visible screen, and this is the visible one while Apply rebuilds the tables.
  pcall(function()
    display.setevent(fftsa.loadscr, display.EVENT_ENDAPP,
                     "if fftsa ~= nil then fftsa.cleanup() end")
  end)
  return fftsa.loadscr
end

function fftsa.loading_front()
  if fftsa.loadscr == nil then return false end
  display.changescreen(fftsa.loadscr)
  return true
end

-- Put a real screen in front, then take the cover away. Switch first, delete
-- second: deleting the screen on show leaves the panel black.
function fftsa.loading_destroy(showscr)
  if showscr == nil then showscr = display.SCREEN_HOME end
  pcall(function() display.changescreen(showscr) end)
  if fftsa.loadscr == nil then return false end
  fftsa.del_obj(fftsa.loadtxt)
  fftsa.del_obj(fftsa.loadscr)
  fftsa.loadtxt, fftsa.loadscr = nil, nil
  return true
end

-- ---------- peak finder ----------

-- Top `count` local maxima of fftsa.fft_pwr, strongest first, as two 1..count
-- arrays: bin indices and power (volts-squared). kmin/kmax restrict the search to
-- the bins the graph shows, so the table never reports a tone that is absent from
-- the trace.
--
-- The DC region is never reported, whatever kmin says. Index 1 is DC, and the
-- fftsa.fft_kdc bins above it hold the mean removal's own error rather than the
-- signal: a 1.000 V tone at bin 1 reads 0.589 V under Hann and dances to 1.110 V
-- with the capture phase, and no mean rule does better (fft_core.tsp). Printing a
-- confident wrong number is worse than printing none, so the floor is here; the
-- trace still draws those bins, which is where a low-frequency tone shows up.
function fftsa.find_peaks(nbins, count, kmin, kmax)
  local pwr = fftsa.fft_pwr
  local bi, bv = {}, {}
  for s = 1, count do bi[s] = 0; bv[s] = -1 end
  local k0 = 2 + (fftsa.fft_kdc or 0)
  if kmin == nil or kmin < k0 then kmin = k0 end
  if kmax == nil or kmax > nbins then kmax = nbins end
  for k = kmin, kmax do
    local m = pwr[k]
    -- A partial fftsa.fft_pwr (after a short read) can hold nils, and comparing
    -- a nil raises.
    if m ~= nil then
      local ml = pwr[k-1]
      local mr = pwr[k+1]
      -- A missing neighbour is the end of the spectrum and counts as lower. Inside
      -- a zoom window the neighbours are real bins even when off-screen, so the
      -- flank of an out-of-window tone does not read as a peak.
      if ml == nil then ml = -1 end
      if mr == nil then mr = -1 end
      if m > ml and m >= mr then
        if m > bv[count] then
          local s = count
          while s > 1 and m > bv[s-1] do
            bv[s] = bv[s-1]; bi[s] = bi[s-1]; s = s - 1
          end
          bv[s] = m; bi[s] = k
        end
      end
    end
  end
  return bi, bv
end
