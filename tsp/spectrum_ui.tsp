-- spectrum_ui.tsp -- the loading cover and the peak finder.

fftsa = fftsa or {}   -- the single global this app exposes

-- ---------- loading cover ----------
-- A screen holding nothing but a line of text, kept in front while the real screens are
-- built and while Apply rebuilds the window tables. Creating a screen makes it active, so
-- every screen build raises this again before its first child, or the operator watches a
-- screen assemble itself one create at a time. Made once, deleted once by stop(); raising
-- it is a changescreen and nothing else, since a create/delete per raise would churn the
-- 463-object pool.
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
  display.setevent(fftsa.loadscr, display.EVENT_ENDAPP,
                   "if fftsa ~= nil then fftsa.cleanup() end")
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
  display.changescreen(showscr)
  if fftsa.loadscr == nil then return false end
  fftsa.del_obj(fftsa.loadtxt)
  fftsa.del_obj(fftsa.loadscr)
  fftsa.loadtxt, fftsa.loadscr = nil, nil
  return true
end

-- ---------- peak finder ----------

-- Top `count` local maxima of fftsa.fft_pwr, strongest first, as bin indices and power.
-- kmin/kmax restrict the search to the bins the graph shows, so the table never reports a
-- tone absent from the trace. Index 1 and the fftsa.fft_kdc bins above it carry the mean
-- removal's own error rather than signal, so neither is a candidate whatever kmin says.
function fftsa.find_peaks(nbins, count, kmin, kmax)
  local pwr = fftsa.fft_pwr
  -- Reused, not rebuilt: two tables a frame was the only allocation left in the frame
  -- path, and the house rule is to allocate once. Callers read them immediately.
  if fftsa.pk_bi == nil then fftsa.pk_bi, fftsa.pk_bv = {}, {} end
  local bi, bv = fftsa.pk_bi, fftsa.pk_bv
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
        -- A tone inside the DC region leaks enough into the first reportable bin to
        -- make it a local maximum, which then reports the tone a whole bin and 16 dB
        -- out. The estimator saturates at -0.5 there, saying the three bins are not one
        -- tone centred here -- so refuse a peak estimating a quarter bin or more below
        -- the lowest reportable bin. A genuine tone there estimates within 0.017 bins,
        -- against the leak's 0.500, so the margin sits in the middle of the gap.
        local keep = true
        if k == k0 then
          local d = fftsa.peak_interp(k, nbins)
          if (k - 1) + d < (k0 - 1) - 0.25 then keep = false end
        end
        if keep and m > bv[count] then
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
