// The graph ring fill, on the host.
//
// This is the loop the instrument runs to draw a frame: it writes three copies of a row
// number into each record of the display task's own ring. It cannot be tested on the
// instrument -- the ring is in the display task's heap and an error in the destination
// arithmetic lands in the free list, which reaches PegRect::operator& on a freed widget and
// bluescreens with no recovery but a power cycle. The arithmetic is pure, so it is proved
// here, against a ring in ordinary host memory with guard bytes around and between the
// records.
//
// WHAT THESE COVER THAT THE LUA GATES CANNOT. tools/test_nl_reattach.lua stubs the native
// call, so it proves the block Lua packs and which writer a frame picks, and nothing about
// the loop. A destination of `(s + 1) * stride` would put the last triple one record past the
// window dsp_native_run validated and every one of those gates would still pass.
//
// Byte order is deliberately not asserted: the stores are plain uint32 and the instrument is
// big-endian, so the bytes are the big-endian encoding the Lua writer packs by hand, while
// this host is little-endian. What is asserted is the VALUE of each word, which is the claim
// the loop makes, and that all three copies carry it.

#include <gtest/gtest.h>

#include <cstdint>
#include <cstring>
#include <limits>
#include <vector>

extern "C" {
#include "dsp_native_px.h"
}

namespace {

// The geometry measured on a DMM6500: 56-byte records with the y triple at +12. The x pixel
// triple is at +0 and the value and x float are past the y triple, so a fill that overran
// either way would land on a field the firmware owns.
constexpr uint32_t kStride = 56U;
constexpr uint32_t kYoff = 12U;
constexpr uint32_t kYmax = 479U;   // what Lua sends: the panel is 480 rows
constexpr uint8_t kGuard = 0xA5U;

// A ring, with a whole record of guard either side so an off-by-one record is caught rather
// than clipped by the allocation.
class Ring {
 public:
  explicit Ring(uint32_t nrec) : nrec_(nrec), buf_((nrec + 2) * kStride, kGuard) {}

  uintptr_t base() const {
    return reinterpret_cast<uintptr_t>(buf_.data()) + kStride;
  }

  uint32_t word(uint32_t rec, uint32_t copy) const {
    uint32_t v = 0;
    std::memcpy(&v, &buf_[(rec + 1) * kStride + kYoff + copy * 4U], 4U);
    return v;
  }

  // Is every byte outside the nrec y triples still the guard value? That is the whole of the
  // destination claim: the leading and trailing guard records, the record prefix holding the
  // x pixel, and the suffix holding the value and the x float.
  bool OnlyTriplesTouched() const {
    for (size_t i = 0; i < buf_.size(); i++) {
      const bool inside = i >= kStride && i < (nrec_ + 1) * kStride &&
                          (i - kStride) % kStride >= kYoff &&
                          (i - kStride) % kStride < kYoff + 12U;
      if (!inside && buf_[i] != kGuard) { return false; }
    }
    return true;
  }

 private:
  uint32_t nrec_;
  std::vector<uint8_t> buf_;
};

// A plain identity map, one slot per column.
std::vector<uint32_t> Identity(uint32_t n) {
  std::vector<uint32_t> idx(n);
  for (uint32_t i = 0; i < n; i++) { idx[i] = i + 1U; }
  return idx;
}

}  // namespace

// Every store lands on its own record's y triple and nowhere else. The case that matters is
// the last record: a destination off by one record writes past the range dsp_native_run
// bounded, which on the instrument is somebody else's allocation.
TEST(NativePx, WritesEveryTripleAndNothingElse) {
  const uint32_t n = 17U;
  Ring ring(n);
  std::vector<dsp_real> db(n);
  for (uint32_t i = 0; i < n; i++) { db[i] = static_cast<dsp_real>(-100.0 + i); }
  const std::vector<uint32_t> idx = Identity(n);

  dspn_px_fill(ring.base(), kStride, kYoff, n, kYmax, -2.0, 94.0, idx.data(), db.data());

  EXPECT_TRUE(ring.OnlyTriplesTouched());
  for (uint32_t s = 0; s < n; s++) {
    // row = floor(-2*db + 94 + 0.5), and every db here is a whole number so there is no
    // rounding to argue about in this case.
    const uint32_t want = static_cast<uint32_t>(-2.0 * (-100.0 + s) + 94.0);
    EXPECT_EQ(ring.word(s, 0), want) << "record " << s;
    EXPECT_EQ(ring.word(s, 1), want) << "record " << s << " second copy";
    EXPECT_EQ(ring.word(s, 2), want) << "record " << s << " third copy";
  }
}

// The slot map is a permutation of the spectrum, which is what the ring's cursor leaves
// behind: slot s carries column idx[s], one-based. A fill that ignored it would draw the
// right spectrum at the wrong columns -- correct-looking and wrong.
TEST(NativePx, HonoursThePermutedSlotMap) {
  const uint32_t n = 8U;
  Ring ring(n);
  const dsp_real db[n] = {-10, -20, -30, -40, -50, -60, -70, -80};
  // Reversed, then rotated by three: neither the identity nor a reversal alone.
  const uint32_t idx[n] = {4, 3, 2, 1, 8, 7, 6, 5};

  dspn_px_fill(ring.base(), kStride, kYoff, n, kYmax, -1.0, 100.0, idx, db);

  for (uint32_t s = 0; s < n; s++) {
    const uint32_t want =
        static_cast<uint32_t>(-1.0 * static_cast<double>(db[idx[s] - 1U]) + 100.0);
    EXPECT_EQ(ring.word(s, 0), want) << "slot " << s << " should draw column " << idx[s];
  }
}

// A stride and an offset that are not the ones this was measured on. The geometry is derived
// at runtime on the instrument, so a second layout has to work without a change here.
TEST(NativePx, AnyStrideAndOffsetTheCallerPermits) {
  const uint32_t n = 5U;
  const uint32_t stride = 28U, yoff = 16U;   // yoff + 12 == stride: the tight case
  std::vector<uint8_t> buf((n + 2) * stride, kGuard);
  const uintptr_t base = reinterpret_cast<uintptr_t>(buf.data()) + stride;
  const dsp_real db[n] = {-1, -2, -3, -4, -5};
  const std::vector<uint32_t> idx = Identity(n);

  dspn_px_fill(base, stride, yoff, n, kYmax, -1.0, 10.0, idx.data(), db);

  for (size_t i = 0; i < buf.size(); i++) {
    const bool inside = i >= stride && i < (n + 1) * stride &&
                        (i - stride) % stride >= yoff;
    if (!inside) { EXPECT_EQ(buf[i], kGuard) << "byte " << i; }
  }
  for (uint32_t s = 0; s < n; s++) {
    uint32_t v = 0;
    std::memcpy(&v, &buf[(s + 1) * stride + yoff], 4U);
    EXPECT_EQ(v, static_cast<uint32_t>(10.0 + 1.0 + s));
  }
}

// Both ends of the panel. A decibel off the top of the trace window would otherwise store a
// negative row, and the conversion of a negative double to uint32 is not the clamp anybody
// intended.
TEST(NativePx, ClampsBothEnds) {
  Ring ring(4U);
  const dsp_real db[4] = {1000, -1000, 0, -239};   // way above, way below, and two inside
  const std::vector<uint32_t> idx = Identity(4U);

  dspn_px_fill(ring.base(), kStride, kYoff, 4U, kYmax, -2.0, 94.0, idx.data(), db);

  EXPECT_EQ(ring.word(0, 0), 0U) << "a decibel above the window clamps to the top row";
  EXPECT_EQ(ring.word(1, 0), kYmax) << "a decibel below it clamps to the bottom row";
  EXPECT_EQ(ring.word(2, 0), 94U);
  EXPECT_EQ(ring.word(3, 0), 572U > kYmax ? kYmax : 572U);
}

// NaN and the infinities, which the comparisons alone do not catch: NaN fails both of them,
// so without being named it would reach the conversion and the result would be undefined.
TEST(NativePx, NanAndInfinitiesLandOnARealRow) {
  Ring ring(3U);
  dsp_real db[3];
  db[0] = std::numeric_limits<dsp_real>::quiet_NaN();
  db[1] = std::numeric_limits<dsp_real>::infinity();
  db[2] = -std::numeric_limits<dsp_real>::infinity();
  const std::vector<uint32_t> idx = Identity(3U);

  dspn_px_fill(ring.base(), kStride, kYoff, 3U, kYmax, -2.0, 94.0, idx.data(), db);

  EXPECT_EQ(ring.word(0, 0), kYmax) << "NaN draws at the axis floor";
  EXPECT_EQ(ring.word(1, 0), 0U) << "+inf through a negative slope is the top row";
  EXPECT_EQ(ring.word(2, 0), kYmax) << "-inf through a negative slope is the floor";
  EXPECT_TRUE(ring.OnlyTriplesTouched());
}

// THE ROUNDING, AGAINST THE LUA WRITER'S. The two writers alternate frame by frame -- a frame
// that re-points the series uses the Lua one -- so a row they disagree on is a column that
// moves when nothing about the spectrum did.
//
// The figures are literal and not recomputed here, which is the point: `ay*db + by` fused
// into one rounding gives 165.49999999999997 and a row of 165, while the Lua writer rounds
// the product and then adds, giving exactly 165.5 and a row of 166. The shipped image used
// fmadd here until dspn_px_row was made to round the product.
TEST(NativePx, RoundsTheProductBeforeAddingTheIntercept) {
  const double ay = -7.7603470944719;
  const double by = 231.28555207927295;
  dsp_real db;
  const uint32_t bits = 0x4107A25EU;        // 8.477140426635742 as a float32
  std::memcpy(&db, &bits, sizeof(db));
  ASSERT_EQ(sizeof(dsp_real), 4U) << "the literal above is a float32 bit pattern";
  ASSERT_DOUBLE_EQ(static_cast<double>(db), 8.477140426635742);

  EXPECT_EQ(dspn_px_row(static_cast<double>(db), ay, by, kYmax), 166U)
      << "a fused multiply-add gives 165 here, which is a row the Lua writer never draws";
}

// The row is the floor of the half-up sum, which is what the Lua writer computes. Checked at
// the two edges of a row rather than in its middle, where any rounding rule agrees.
TEST(NativePx, RowIsTheFloorOfTheHalfUpSum) {
  EXPECT_EQ(dspn_px_row(0.0, 1.0, 100.49, kYmax), 100U);
  EXPECT_EQ(dspn_px_row(0.0, 1.0, 100.5, kYmax), 101U);
  EXPECT_EQ(dspn_px_row(0.0, 1.0, 100.51, kYmax), 101U);
  // Negative slope, which is the real one: rows grow downwards and decibels upwards.
  EXPECT_EQ(dspn_px_row(-20.0, -2.0, 94.0, kYmax), 134U);
}

// The map, checked whole before the first store. A slot naming a column outside the
// reduction's array reads a dsp_real from whatever follows it.
TEST(NativePx, MapIsRefusedWholeOrAcceptedWhole) {
  std::vector<uint32_t> idx = Identity(6U);
  EXPECT_TRUE(dspn_px_map_ok(idx.data(), 6U, 6U));
  EXPECT_TRUE(dspn_px_map_ok(idx.data(), 6U, 255U)) << "a map into a longer spectrum is fine";

  idx[5] = 7U;
  EXPECT_FALSE(dspn_px_map_ok(idx.data(), 6U, 6U)) << "the LAST slot is still checked";
  idx[5] = 6U;
  idx[0] = 0U;
  EXPECT_FALSE(dspn_px_map_ok(idx.data(), 6U, 6U)) << "zero is not a one-based column";

  idx = Identity(6U);
  EXPECT_FALSE(dspn_px_map_ok(idx.data(), 0U, 6U)) << "no records is not a fill";
  EXPECT_FALSE(dspn_px_map_ok(idx.data(), 6U, 0U)) << "no columns is not a spectrum";
  EXPECT_FALSE(dspn_px_map_ok(nullptr, 6U, 6U));
}

// A full pass at the sizes the instrument actually runs: 510 records of the measured ring, and
// the largest map the image carries room for.
TEST(NativePx, AFullPassAndTheLongestMap) {
  const uint32_t n = 510U;
  Ring ring(n);
  std::vector<dsp_real> db(255U);
  for (uint32_t i = 0; i < 255U; i++) {
    db[i] = static_cast<dsp_real>(-110.0 + 0.3 * static_cast<double>(i));
  }
  // The fold a pass writes: up the band and back down it, so the ring holds two slots per
  // column and the last slot is column 1 again.
  std::vector<uint32_t> idx(n);
  for (uint32_t i = 0; i < 255U; i++) {
    idx[i] = i + 1U;
    idx[255U + i] = 255U - i;
  }

  ASSERT_TRUE(dspn_px_map_ok(idx.data(), n, 255U));
  dspn_px_fill(ring.base(), kStride, kYoff, n, kYmax, -2.0, 94.0, idx.data(), db.data());

  EXPECT_TRUE(ring.OnlyTriplesTouched());
  // The fold's two halves draw the same column at the same row, which is what makes the
  // wrap seam a repeated point rather than a step across the plot.
  for (uint32_t i = 0; i < 255U; i++) {
    EXPECT_EQ(ring.word(i, 0), ring.word(509U - i, 0)) << "column " << (i + 1);
  }
}
