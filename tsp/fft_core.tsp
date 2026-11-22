-- Window definitions shared by the UI and the FFT implementations.

-- Rectangular is excluded: its first null makes the three-bin peak fit ill-conditioned.
fftsa = fftsa or {}

fftsa.win_names = {"Hann", "Blackman", "Blk-Harris", "Kaiser"}
-- Cosine-sum coefficients: a0 - a1*cos + a2*cos2 - a3*cos3. No entry for Kaiser.
fftsa.win_cos = {
  {0.5, 0.5},
  {0.42, 0.5, 0.08},
  {0.35875, 0.48829, 0.14128, 0.01168},
}
fftsa.win_i = 1

-- Kaiser betas keep the first null outside 1.5 bins for main-lobe peak interpolation.
fftsa.kbetas       = {4, 6, 9, 12, 15, 18}
fftsa.kbeta_labels = {"4  -30dB", "6  -44dB", "9  -66dB",
                      "12  -90dB", "15  -114dB", "18  -139dB"}
fftsa.kbeta_i      = 4

function fftsa.kbeta(bi)
  local b = fftsa.kbetas[bi or fftsa.kbeta_i]
  if b == nil then b = fftsa.kbetas[1] end
  return b
end

function fftsa.win_name(wi)
  wi = wi or fftsa.win_i
  return fftsa.win_names[wi] or fftsa.win_names[1]
end

-- Defaults to the applied window. Options passes the pending window and beta.
function fftsa.win_label(wi, bi)
  wi = wi or fftsa.win_i
  if fftsa.win_cos[wi] ~= nil then return fftsa.win_name(wi) end
  return fftsa.win_name(wi) .. " b=" .. tostring(fftsa.kbeta(bi))
end
