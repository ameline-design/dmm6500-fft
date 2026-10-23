-- spectrum_ui.tsp -- peak finder used by the spectrum app.

fftsa = fftsa or {}   -- the single global this app exposes

-- Top `count` local maxima of fftsa.fft_pwr, strongest first. O(nbins), negligible cost.
-- Returns two 1..count arrays: bin indices (bi) and their POWER (bv, volts-squared).
-- Power orders bins exactly as magnitude would, so the search needs no square
-- roots; fftsa.sg_show_peaks takes them for the few bins it reports.
--
-- kmin/kmax (optional, default 2..nbins) restrict the search to the bins the
-- graph is actually DISPLAYING. Without them a strong tone outside the zoom
-- window is reported in the table while being absent from the trace, so the
-- numbers describe something other than the picture. fftsa.frame_body() passes
-- the same window fftsa.sg_update() plots.
--
-- Bin 1 is DC (removed before the transform) and is never a candidate, so the
-- search starts at bin 2 -- the first real frequency bin, and reportable.
function fftsa.find_peaks(nbins, count, kmin, kmax)
  local pwr = fftsa.fft_pwr
  local bi, bv = {}, {}
  for s = 1, count do bi[s] = 0; bv[s] = -1 end
  if kmin == nil or kmin < 2 then kmin = 2 end
  if kmax == nil or kmax > nbins then kmax = nbins end
  for k = kmin, kmax do
    local m = pwr[k]
    -- nil-safe: a partial fftsa.fft_pwr (e.g. after a short read) may hold nils,
    -- and comparing nils raises a runtime error -- guard against it.
    if m ~= nil then
      local ml = pwr[k-1]
      local mr = pwr[k+1]
      -- A missing neighbour means we are at the end of the spectrum, so treat it
      -- as lower than anything: that lets the final bin qualify. Inside a zoom
      -- window the neighbours are real bins even when they are off-screen, which
      -- is what stops the flank of an out-of-window tone reading as a peak.
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
