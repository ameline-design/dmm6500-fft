-- fft_core.tsp -- the window enums and the labels, and nothing that computes.
--
-- What every path needs whatever computes the spectrum: the window names, the Kaiser betas
-- and the two accessors. fftsa.kbeta() feeds nl.init and win_label() feeds the settings
-- line, so neither belongs with the math -- which is in tsp/fft_interp.tsp, loaded by
-- tools/test_tsp.lua and left out of the archive.

-- ============================ analysis windows ============================
-- Every entry is a generalised cosine sum except Kaiser, whose beta trades main-lobe width
-- against sidelobe level and so spans the named windows and goes past them.
--
-- Rectangular is absent: its transform has a null one bin from the peak, which leaves the
-- three-bin interpolation ill-conditioned, so peak readings are wrong in a way the trace
-- does not show. Hamming is absent because it exits the app on the instrument, and Kaiser at
-- beta 6 covers it to within a dB of sidelobe level.
fftsa = fftsa or {}   -- the single global this app exposes

fftsa.win_names = {"Hann", "Blackman", "Blk-Harris", "Kaiser"}
-- Index-parallel to fftsa.win_names, coefficients a0 - a1*cos + a2*cos2 - a3*cos3.
-- Kaiser has no entry, which is how fftsa.win_build() tells it apart.
fftsa.win_cos = {
  {0.5, 0.5},
  {0.42, 0.5, 0.08},
  {0.35875, 0.48829, 0.14128, 0.01168},
}
fftsa.win_i = 1             -- index into fftsa.win_names

-- A fixed list rather than a typed number: every value here is verified for peak frequency
-- and amplitude in the suite, where a typed beta would admit unmeasured shapes. The floor is
-- 4 because the first null sits at sqrt(1 + (beta/pi)^2) bins and has to stay outside 1.5
-- bins for the interpolation to read main lobe rather than sidelobe.
fftsa.kbetas       = {4, 6, 9, 12, 15, 18}
fftsa.kbeta_labels = {"4  -30dB", "6  -44dB", "9  -66dB",
                      "12  -90dB", "15  -114dB", "18  -139dB"}
fftsa.kbeta_i      = 4      -- index into fftsa.kbetas

function fftsa.kbeta(bi)
  local b = fftsa.kbetas[bi or fftsa.kbeta_i]
  if b == nil then b = fftsa.kbetas[1] end
  return b
end

function fftsa.win_name(wi)
  wi = wi or fftsa.win_i
  return fftsa.win_names[wi] or fftsa.win_names[1]
end

-- Window name for a readback line, with beta where beta applies. Defaults to the applied
-- window; the options preview passes its field values so the whole line describes one state.
function fftsa.win_label(wi, bi)
  wi = wi or fftsa.win_i
  if fftsa.win_cos[wi] ~= nil then return fftsa.win_name(wi) end
  return fftsa.win_name(wi) .. " b=" .. tostring(fftsa.kbeta(bi))
end
