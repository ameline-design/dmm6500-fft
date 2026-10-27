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

-- A harmonic is h times an INTERPOLATED fundamental, so it misses the bin centre and the
-- window spreads it: halfw is the search radius, skirt what stays out of the noise mean.
fftsa.thd_halfw = 2
fftsa.thd_skirt = 3
fftsa.thd_hmax  = 20      -- ceiling on harmonics; the window top usually stops it first

-- THD and the noise floor over the plotted bins, as a percentage and dBV.
--
-- Amplitudes come from fftsa.peak_interp, not bin maxima, which read up to 3.9 dB low on a
-- tone between bins. The noise floor is the MEAN POWER of every bin that is not a line or
-- its skirt: averaging decibels instead lets one deep null drag it down several dB.
--
-- Both nil with nothing to measure. THD alone is nil when no harmonic fits in the window,
-- which is not a clean signal and must not read as 0.00%.
function fftsa.thd_noise(nb, binhz)
  local pwr = fftsa.fft_pwr
  if pwr == nil or nb == nil or nb < 8 then return nil, nil, 0 end
  if binhz == nil or not (binhz > 0) then return nil, nil, 0 end
  local sqrt, floor, log10 = math.sqrt, math.floor, math.log10
  local k0 = 2 + (fftsa.fft_kdc or 0)
  local kmin, kmax = fftsa.sg_window_bins(nb, binhz)
  if kmin < k0 then kmin = k0 end
  if kmax > nb then kmax = nb end
  if kmax - kmin < 4 then return nil, nil, 0 end

  local k, kf, pf = nil, nil, 0
  for k = kmin, kmax do
    local p = pwr[k]
    -- A partial fftsa.fft_pwr after a short read holds nils, and comparing one raises.
    if p ~= nil and p > pf then kf, pf = k, p end
  end
  if kf == nil or not (pf > 0) then return nil, nil, 0 end
  local df, vf = fftsa.peak_interp(kf, nb)
  if vf == nil then df, vf = 0, sqrt(pf) end
  if not (vf > 0) then return nil, nil, 0 end

  -- Line centres, ascending by construction. Reused: the house rule is to allocate once.
  local ex = fftsa.thd_ex
  if ex == nil then ex = {}; fftsa.thd_ex = ex end
  ex[1] = kf
  local nex, hsum, nh = 1, 0, 0
  local halfw, skirt = fftsa.thd_halfw, fftsa.thd_skirt
  local fb = kf - 1 + df                  -- the fundamental, in bins from DC
  local h
  for h = 2, fftsa.thd_hmax do
    local c = fb * h + 1                  -- the h'th harmonic's predicted 1-based bin
    if c + halfw > kmax then break end
    local a, b = floor(c - halfw + 0.5), floor(c + halfw + 0.5)
    if a < kmin then a = kmin end
    local bk, bp = nil, -1
    for k = a, b do
      local p = pwr[k]
      if p ~= nil and p > bp then bk, bp = k, p end
    end
    if bk ~= nil and bp > 0 and bk > ex[nex] + skirt then
      local hd, hv = fftsa.peak_interp(bk, nb)
      if hv == nil then hv = sqrt(bp) end
      hsum = hsum + hv * hv
      nh, nex = nh + 1, nex + 1
      ex[nex] = bk
    end
  end

  -- The exclusion list is walked alongside the bins: one comparison a bin, not one a
  -- line a bin, which at 8192 bins and twenty harmonics is what keeps this free.
  local sum, cnt, e = 0, 0, 1
  for k = kmin, kmax do
    while e <= nex and ex[e] + skirt < k do e = e + 1 end
    if e > nex or k < ex[e] - skirt then
      local p = pwr[k]
      if p ~= nil then sum = sum + p; cnt = cnt + 1 end
    end
  end

  local thd = nil
  if nh > 0 then thd = 100 * sqrt(hsum) / vf end
  local ndb, snr = nil, nil
  if cnt > 0 and sum > 0 then
    ndb = 10 * log10(sum / cnt)
    -- Floored at the plot's floor, like the peak column: 1e-26 reads -260 dBV.
    if not (ndb > fftsa.sg_dbmin) then ndb = fftsa.sg_dbmin end
    -- S/N is the fundamental against the INTEGRATED noise, not against the per-bin mean,
    -- so it does not move when the sample count does -- narrower bins, more of them, the
    -- same total. Harmonics are excluded from the sum, which is what makes this the ratio
    -- THD is not already reporting. The halves of both mean squares cancel in the ratio.
    snr = 10 * log10(vf * vf / sum)
  end
  return thd, ndb, nh, snr
end
