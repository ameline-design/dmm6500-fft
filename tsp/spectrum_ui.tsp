-- spectrum_ui.tsp -- peak finder used by the spectrum app.

fftsa = fftsa or {}   -- the single global this app exposes

-- Top `count` local maxima of fftsa.fft_pwr, strongest first, as two 1..count
-- arrays: bin indices and power (volts-squared). kmin/kmax (default 2..nbins)
-- restrict the search to the bins the graph shows, so the table never reports a
-- tone that is absent from the trace. Bin 1 is DC and is never a candidate.
function fftsa.find_peaks(nbins, count, kmin, kmax)
  local pwr = fftsa.fft_pwr
  local bi, bv = {}, {}
  for s = 1, count do bi[s] = 0; bv[s] = -1 end
  if kmin == nil or kmin < 2 then kmin = 2 end
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
