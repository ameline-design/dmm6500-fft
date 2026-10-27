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
      -- m == m and mr == mr ARE THE NaN TESTS. This firmware implements a >= b as
      -- not (a < b), so m >= mr is TRUE when mr is a NaN and a bin beside one would be
      -- reported as a peak. Strict > needs no guard; >= does.
      if m == m and mr == mr and m > ml and m >= mr then
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
-- window spreads it: halfw is the search radius.
fftsa.thd_halfw = 2

-- Bins either side of a line that hold the WINDOW's main lobe rather than noise. Counting
-- them as noise puts a floor under every figure: a fixed 3 capped reportable S/N at 38.5 dB
-- on Kaiser 18, against the 124.9 dB the window itself allows, measured on a pure tone at
-- 16384 samples. The first null in bins is 2 for Hann, 3 for Blackman, 4 for Blk-Harris
-- and sqrt(1 + (beta/pi)^2) for Kaiser -- 5.82 at beta 18 -- plus one bin of guard.
--
-- Sidelobes are NOT covered and cannot be: Kaiser 4's are 30 dB down and integrate to a
-- 36.7 dB ceiling whatever the skirt does. That is the window, not a measurement error.
fftsa.thd_lobes = {2, 3, 4}      -- Hann, Blackman, Blk-Harris

function fftsa.thd_skirt()
  local wi = fftsa.win_i
  local l = fftsa.thd_lobes[wi]
  if l == nil then
    -- Kaiser, the one window whose lobe moves with a setting.
    local b = fftsa.kbetas[fftsa.kbeta_i]
    if b == nil then b = 0 end
    l = math.ceil(math.sqrt(1 + (b / math.pi) * (b / math.pi)))
    if l < 2 then l = 2 end
  end
  return l + 1
end
fftsa.thd_hmax  = 20      -- ceiling on harmonics; the window top usually stops it first

-- The fundamental must clear the per-bin noise mean by this ratio before THD and S/N mean
-- anything: 45 dB. Measured at 16384 samples -- a shorted input's strongest bin stood
-- 17.1 dB over the mean, a FLOATING input's best surviving candidate stood 38.8 (a mains
-- harmonic at 1019 Hz, past the cutoff below), and an 8 Vp-p tone stood 117.9. The margin
-- goes between the floating case and the tone, which is where the useful gap is.
--
-- The cost is that a tone under 45 dB over the per-bin floor reads NoSig -- about 0.9 mV at
-- 16384 samples -- and its distortion would have been noise anyway. Raising the mains
-- cutoff instead has no natural stopping point, the harmonic series being endless, and
-- would discount legitimate quiet tones landing on multiples of 50.
fftsa.thd_minratio = 31623

-- A noise bin above this multiple of the running mean is an outlier, not noise. The plain
-- mean of a windowed spectrum is set by whichever few bins carry a line's leakage skirt:
-- measured at 16384 samples with the tone off a bin centre, Hann's skirt put the reported
-- floor at -80.2 dBV over a trace sitting at -100, and swung it 62 dB purely on where the
-- tone fell between bins. Widening the skirt cannot reach it -- Hann is still 45 dB down
-- four bins out -- but clipping can, since those bins are orders of magnitude up.
--
-- Each pass tightens the threshold and the loop stops when one removes nothing. On noise
-- with no outliers the clip trims the top few per cent and costs 0.5 dB.
-- Mains pickup is not the signal under test. A floating input reads 60 Hz at -25.4 dBV
-- with harmonics out to 540, which made the hum the fundamental and reported its own
-- distortion as the instrument's: 11.04% measured, over a -105.2 dBV floor. A candidate at
-- a multiple of 50 or 60 Hz, below thd_mains_fmax and at or under -22 dBV, is passed over
-- so the search moves on -- and with nothing else there the margin then answers NoSig.
--
-- The harmonics have to go too, or discounting 60 Hz alone promotes 120 at -46.3 dBV,
-- which still clears the margin by 59 dB.
fftsa.thd_mains      = {50, 60}
fftsa.thd_mains_pwr  = 0.0063096   -- -22 dBV expressed as power
fftsa.thd_mains_fmax = 1000        -- above this a tone on a mains multiple is a tone

-- Bins the noise figures sample. They do not need all of them: the standard error of a
-- mean over 2048 bins is 0.1 dB, well inside the 0.5 dB the clip already costs, and the
-- clip wants several passes. Measured on the instrument, all 8192 bins at 16384 samples
-- cost 0.498 s a call and took the frame from 1.67 s to 2.17 s -- 30% of it, for a figure
-- that updates once a second. Striding holds it to a few per cent.
fftsa.thd_nsample = 2048

fftsa.thd_clip  = 4
fftsa.thd_clips = 6

-- Is this candidate mains pickup rather than the signal? Level first, because it is the
-- cheap test and the common answer. Called only when a candidate beats the running
-- maximum, which happens a handful of times over a spectrum, not once a bin.
function fftsa.thd_is_mains(fhz, p, binhz)
  if not (p <= fftsa.thd_mains_pwr) then return false end
  if not (fhz < fftsa.thd_mains_fmax) then return false end
  local tol = binhz
  if not (tol > 2) then tol = 2 end
  local i
  for i = 1, 2 do
    local f = fftsa.thd_mains[i]
    local n = math.floor(fhz / f + 0.5)
    if n >= 1 then
      local d = fhz - n * f
      if d < 0 then d = -d end
      if d <= tol then return true end
    end
  end
  return false
end

-- Sum and count the bins that are neither a line nor a skirt and do not exceed ceil. The
-- exclusion list is walked alongside the bins: one comparison a bin, not one a line a bin,
-- which at 8192 bins and twenty harmonics is what keeps this affordable. Module level, not
-- a local closure, because the house rule is to allocate once.
function fftsa.thd_noise_pass(pwr, kmin, kmax, ex, nex, skirt, ceil, stride)
  local sum, cnt, e, k = 0, 0, 1, nil
  for k = kmin, kmax, stride do
    while e <= nex and ex[e] + skirt < k do e = e + 1 end
    if e > nex or k < ex[e] - skirt then
      local p = pwr[k]
      -- p == p IS THE NaN TEST. Measured on this firmware, nan >= 0 and nan <= 1/0 are
      -- both TRUE -- it implements a >= b as not (a < b), which inverts the unordered
      -- case -- so neither ordered guard rejects one. Strict > and < are correct, which
      -- is why the searches above can rely on them. Unguarded, one NaN bin makes the sum
      -- NaN and the whole readout degrades to NoSig; one infinity reads "inf dBV".
      if p ~= nil and p == p and p >= 0 and p <= ceil then
        sum = sum + p
        cnt = cnt + 1
      end
    end
  end
  return sum, cnt
end

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
    -- Strict > rejects a NaN correctly on this firmware where >= does not.
    if p ~= nil and p > pf then
      -- A LOCAL MAXIMUM, or the shoulder of a louder line qualifies. Measured with the
      -- inputs floating: the 60 Hz line sat in bin 11 and was discounted as mains, but
      -- bin 12 at 67.1 Hz -- its own skirt, 8 dB down -- missed the mains tolerance by
      -- 1 Hz and became the fundamental, giving 21.4% distortion on no signal at all.
      -- A monotonic skirt has no local maximum; a real tone is one.
      local l, r = pwr[k - 1], pwr[k + 1]
      if (l == nil or p > l) and (r == nil or (r == r and p >= r))
         and not fftsa.thd_is_mains((k - 1) * binhz, p, binhz) then
        kf, pf = k, p
      end
    end
  end
  -- No fundamental is NOT the end of it: the floor is the useful number with the inputs
  -- disconnected, and a flat spectrum has no local maximum at all. vf nil carries that
  -- through to the noise pass with nothing excluded.
  local df, vf = 0, nil
  if kf ~= nil and pf > 0 then
    df, vf = fftsa.peak_interp(kf, nb)
    if vf == nil then df, vf = 0, sqrt(pf) end
    if not (vf > 0) then vf = nil end
  end

  -- Line centres, ascending by construction. Reused: the house rule is to allocate once.
  local ex = fftsa.thd_ex
  if ex == nil then ex = {}; fftsa.thd_ex = ex end
  local nex, hsum, nh = 0, 0, 0
  if vf ~= nil then
    ex[1] = kf
    nex = 1
  end
  local halfw, skirt = fftsa.thd_halfw, fftsa.thd_skirt()
  local fb = 0
  if vf ~= nil then fb = kf - 1 + df end  -- the fundamental, in bins from DC
  local h
  for h = 2, fftsa.thd_hmax do
    if vf == nil then break end
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

  -- One in every stride bins, which is what keeps the clip affordable. See thd_nsample.
  local stride = math.floor((kmax - kmin + 1) / fftsa.thd_nsample)
  if stride < 1 then stride = 1 end
  -- A finite ceiling, not 1/0: inf <= 1/0 is true and inf <= 1e308 is not, so this is
  -- what keeps an infinite bin out of the first pass.
  local sum, cnt = fftsa.thd_noise_pass(pwr, kmin, kmax, ex, nex, skirt, 1e308, stride)
  -- Again with the outliers clipped. See fftsa.thd_clip for why the plain mean is not the
  -- floor the trace shows.
  for h = 1, fftsa.thd_clips do
    if not (cnt > 0 and sum > 0) then break end
    local csum, ccnt = fftsa.thd_noise_pass(pwr, kmin, kmax, ex, nex, skirt,
                                            (sum / cnt) * fftsa.thd_clip, stride)
    -- Converged: a pass that removed nothing means the next would too.
    if ccnt == cnt or ccnt < 1 or not (csum > 0) then break end
    sum, cnt = csum, ccnt
  end

  local ndb, snr = nil, nil
  if cnt > 0 and sum > 0 then
    local mean = sum / cnt
    ndb = 10 * log10(mean)
    -- Floored at the plot's floor, like the peak column: 1e-26 reads -260 dBV.
    if not (ndb > fftsa.sg_dbmin) then ndb = fftsa.sg_dbmin end
    -- NO FUNDAMENTAL, NO RATIOS. With the inputs shorted the strongest bin is a noise
    -- peak, and both ratios built on it are arithmetic about nothing -- 31.8% and -22 dB.
    -- The floor still reports: shorted, it is the instrument's own and the useful number.
    if vf ~= nil and vf * vf > mean * fftsa.thd_minratio then
      -- Against the INTEGRATED noise, not the per-bin mean, so it holds still when the
      -- sample count changes. Harmonics are out of the sum, so this is not THD restated.
      -- The halves of both mean squares cancel in the ratio.
      -- sum * stride is the integrated noise: the sampled sum scaled back up, which is
      -- unbiased. The mean is sum/cnt, where the stride cancels.
      snr = 10 * log10(vf * vf / (sum * stride))
    else
      nh = 0
    end
  end
  local thd = nil
  if nh > 0 then thd = 100 * sqrt(hsum) / vf end
  return thd, ndb, nh, snr
end
