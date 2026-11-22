// Exercise the real pixel writer and slot-map validation on the host.

#include <gtest/gtest.h>

#include <cstdint>
#include <cstring>
#include <limits>
#include <vector>

extern "C" {
#include "dsp_native_px.h"
}

namespace {

// Use the DMM6500 record stride and Y offset for the baseline.
constexpr uint32_t kStride = 56U;
constexpr uint32_t kYoff = 12U;
constexpr uint32_t kYmax = 479U;   // what Lua sends: the panel is 480 rows
constexpr uint8_t kGuard = 0xA5U;

// Surround the ring with guard records so an off-by-one write is visible.
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

  // Check all bytes except the mapped Y triples against the guard value.
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

std::vector<uint32_t> Identity(uint32_t n) {
  std::vector<uint32_t> idx(n);
  for (uint32_t i = 0; i < n; i++) { idx[i] = i + 1U; }
  return idx;
}

}  // namespace

TEST(NativePx, WritesEveryTripleAndNothingElse) {
  const uint32_t n = 17U;
  Ring ring(n);
  std::vector<dsp_real> db(n);
  for (uint32_t i = 0; i < n; i++) { db[i] = static_cast<dsp_real>(-100.0 + i); }
  const std::vector<uint32_t> idx = Identity(n);

  dspn_px_fill(ring.base(), kStride, kYoff, n, kYmax, -2.0, 94.0, idx.data(), db.data());

  EXPECT_TRUE(ring.OnlyTriplesTouched());
  for (uint32_t s = 0; s < n; s++) {

    const uint32_t want = static_cast<uint32_t>(-2.0 * (-100.0 + s) + 94.0);
    EXPECT_EQ(ring.word(s, 0), want) << "record " << s;
    EXPECT_EQ(ring.word(s, 1), want) << "record " << s << " second copy";
    EXPECT_EQ(ring.word(s, 2), want) << "record " << s << " third copy";
  }
}

// Check a permuted map rather than assuming slot order is column order.
TEST(NativePx, HonoursThePermutedSlotMap) {
  const uint32_t n = 8U;
  Ring ring(n);
  const dsp_real db[n] = {-10, -20, -30, -40, -50, -60, -70, -80};

  const uint32_t idx[n] = {4, 3, 2, 1, 8, 7, 6, 5};

  dspn_px_fill(ring.base(), kStride, kYoff, n, kYmax, -1.0, 100.0, idx, db);

  for (uint32_t s = 0; s < n; s++) {
    const uint32_t want =
        static_cast<uint32_t>(-1.0 * static_cast<double>(db[idx[s] - 1U]) + 100.0);
    EXPECT_EQ(ring.word(s, 0), want) << "slot " << s << " should draw column " << idx[s];
  }
}

// Exercise a different valid stride and Y offset to expose fixed-layout assumptions.
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

// Clamp infinities to the panel and keep NaN out of integer conversion.
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

// The native row must equal Lua's separate multiply and add; a fused result differs here.
// Keep the expected row independent of the expression under test.
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

// Check the half-up rounding boundary in both directions.
TEST(NativePx, RowIsTheFloorOfTheHalfUpSum) {
  EXPECT_EQ(dspn_px_row(0.0, 1.0, 100.49, kYmax), 100U);
  EXPECT_EQ(dspn_px_row(0.0, 1.0, 100.5, kYmax), 101U);
  EXPECT_EQ(dspn_px_row(0.0, 1.0, 100.51, kYmax), 101U);

  EXPECT_EQ(dspn_px_row(-20.0, -2.0, 94.0, kYmax), 134U);
}

// An invalid map, even at the last slot, must be rejected before any store.
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

// Exercise a full folded pass of 510 records for 255 columns.
TEST(NativePx, AFullPassAndTheLongestMap) {
  const uint32_t n = 510U;
  Ring ring(n);
  std::vector<dsp_real> db(255U);
  for (uint32_t i = 0; i < 255U; i++) {
    db[i] = static_cast<dsp_real>(-110.0 + 0.3 * static_cast<double>(i));
  }

  std::vector<uint32_t> idx(n);
  for (uint32_t i = 0; i < 255U; i++) {
    idx[i] = i + 1U;
    idx[255U + i] = 255U - i;
  }

  ASSERT_TRUE(dspn_px_map_ok(idx.data(), n, 255U));
  dspn_px_fill(ring.base(), kStride, kYoff, n, kYmax, -2.0, 94.0, idx.data(), db.data());

  EXPECT_TRUE(ring.OnlyTriplesTouched());
  // Both halves of the fold must draw each column at the same row.
  for (uint32_t i = 0; i < 255U; i++) {
    EXPECT_EQ(ring.word(i, 0), ring.word(509U - i, 0)) << "column " << (i + 1);
  }
}
