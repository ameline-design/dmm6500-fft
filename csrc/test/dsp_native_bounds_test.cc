// Test the native address gates on the host without issuing invalid reads or writes to the meter.

#include <gtest/gtest.h>

extern "C" {
#include "dsp_native_bounds.h"

#include "dsp.h"
}

namespace {

// Use named addresses to identify failures by memory region.
constexpr uint32_t kVectors   = 0x00000000U;
constexpr uint32_t kText      = 0x00004000U;
constexpr uint32_t kTextEnd   = 0x0052567CU;
constexpr uint32_t kRodata    = 0x005256C0U;
constexpr uint32_t kData      = 0x006E4F70U;
constexpr uint32_t kBss       = 0x009C6A40U;
constexpr uint32_t kBssEnd    = 0x00FE5548U;
constexpr uint32_t kIoBuffers = 0x01000000U;  // between .bss and .heap: live I/O
constexpr uint32_t kHeapLo    = 0x01036000U;
constexpr uint32_t kHeapMid   = 0x03562AE8U;  // a real chunk payload from a capture
constexpr uint32_t kHeapHi    = 0x0D836000U;
constexpr uint32_t kStack     = 0x0D836000U;
constexpr uint32_t kStackEnd  = 0x0D84A000U;
constexpr uint32_t kRamEnd    = 0x0D84A000U;
constexpr uint32_t kPageTable = 0x0FC00000U;
constexpr uint32_t kUnmapped  = 0x20000000U;
constexpr uint32_t kMmio1     = 0x80000000U;
constexpr uint32_t kMmio2     = 0x90000000U;
constexpr uint32_t kMmio3     = 0xA0000000U;
constexpr uint32_t kFlash     = 0xFE000000U;

// Use a broad declared window when the compiled bound is the gate under test.
constexpr uint32_t kWinLo = kHeapLo;
constexpr uint32_t kWinHi = kHeapHi;

int WriteOk(uint32_t a, uint32_t n) { return dspn_write_ok(a, n, kWinLo, kWinHi); }
int ReadOk(uint32_t a, uint32_t n) { return dspn_read_ok(a, n, 0U, 0xFFFFFFFFU); }

}  // namespace

TEST(RangeOk, InteriorAccepted) {
  EXPECT_TRUE(dspn_range_ok(100, 10, 0, 1000));
}

TEST(RangeOk, ExactFitAccepted) {
  EXPECT_TRUE(dspn_range_ok(0, 1000, 0, 1000));
  EXPECT_TRUE(dspn_range_ok(990, 10, 0, 1000));
}

TEST(RangeOk, OnePastTheEndRefused) {
  EXPECT_FALSE(dspn_range_ok(991, 10, 0, 1000));
  EXPECT_FALSE(dspn_range_ok(1000, 1, 0, 1000));
}

TEST(RangeOk, OneBelowTheStartRefused) {
  EXPECT_FALSE(dspn_range_ok(99, 10, 100, 1000));
}

TEST(RangeOk, ZeroLengthAcceptedAnywhere) {
  // A zero-length range touches nothing, even outside a window.
  EXPECT_TRUE(dspn_range_ok(0, 0, 100, 1000));
  EXPECT_TRUE(dspn_range_ok(kMmio1, 0, 100, 1000));
  EXPECT_TRUE(WriteOk(kFlash, 0));
}

TEST(RangeOk, WrapRefused) {
  EXPECT_FALSE(dspn_range_ok(0xFFFFFFF0U, 0x20U, 0U, 0xFFFFFFFFU));
  EXPECT_FALSE(dspn_range_ok(0x80000000U, 0x80000000U, 0U, 0xFFFFFFFFU));
}

TEST(RangeOk, EmptyWindowRefusesEverythingNonZero) {
  EXPECT_FALSE(dspn_range_ok(500, 1, 500, 500));
}

TEST(WriteGate, HeapAccepted) {
  EXPECT_TRUE(WriteOk(kHeapLo, 4));
  EXPECT_TRUE(WriteOk(kHeapMid, 32768));
  EXPECT_TRUE(WriteOk(kHeapHi - 4, 4));
}

TEST(WriteGate, HeapBoundariesExact) {
  EXPECT_FALSE(WriteOk(kHeapLo - 1, 4));
  EXPECT_TRUE(WriteOk(kHeapLo, 1));
  EXPECT_TRUE(WriteOk(kHeapHi - 1, 1));
  EXPECT_FALSE(WriteOk(kHeapHi, 1));
  // Reject rather than clip a range that straddles either bound.
  EXPECT_FALSE(WriteOk(kHeapLo - 2, 8));
  EXPECT_FALSE(WriteOk(kHeapHi - 2, 8));
}

TEST(WriteGate, FirmwareSectionsRefused) {
  EXPECT_FALSE(WriteOk(kVectors, 4));
  EXPECT_FALSE(WriteOk(kText, 4));
  EXPECT_FALSE(WriteOk(kTextEnd - 4, 4));
  EXPECT_FALSE(WriteOk(kRodata, 4));
  EXPECT_FALSE(WriteOk(kData, 4));
  EXPECT_FALSE(WriteOk(kBss, 4));
  EXPECT_FALSE(WriteOk(kBssEnd - 4, 4));
}

TEST(WriteGate, IoBuffersBelowHeapRefused) {
  // Start at the heap, not the firmware buffers between BSS and heap.
  EXPECT_FALSE(WriteOk(kIoBuffers, 4));
  EXPECT_FALSE(WriteOk(kBssEnd, 4));
  EXPECT_FALSE(WriteOk(kHeapLo - 0x1000U, 4));
}

TEST(WriteGate, CallStacksRefused) {

  EXPECT_FALSE(WriteOk(kStack, 4));
  EXPECT_FALSE(WriteOk(kStack + 0x1000U, 4));
  EXPECT_FALSE(WriteOk(kStackEnd - 4, 4));
}

TEST(WriteGate, AboveRamEndRefused) {
  EXPECT_FALSE(WriteOk(kRamEnd, 4));
  EXPECT_FALSE(WriteOk(kPageTable, 4));
  EXPECT_FALSE(WriteOk(0x0FFFFFFCU, 4));
}

TEST(WriteGate, MmioRefused) {
  EXPECT_FALSE(WriteOk(kMmio1, 4));
  EXPECT_FALSE(WriteOk(kMmio2, 4));
  EXPECT_FALSE(WriteOk(kMmio3, 4));
  EXPECT_FALSE(WriteOk(kMmio1 + 0xFFFFCU, 4));
}

TEST(WriteGate, FlashRefused) {
  EXPECT_FALSE(WriteOk(kFlash, 4));
  EXPECT_FALSE(WriteOk(0xFFFFFFFCU, 4));
}

TEST(WriteGate, UnmappedRefused) {
  EXPECT_FALSE(WriteOk(kUnmapped, 4));
}

TEST(WriteGate, BothSidesMustAgree) {
  // The declared window can exclude otherwise valid DRAM.
  EXPECT_FALSE(dspn_write_ok(kHeapMid, 4, kHeapLo, kHeapLo + 0x1000U));

  EXPECT_FALSE(dspn_write_ok(kBss, 4, kHeapLo, kHeapHi));
  EXPECT_FALSE(dspn_write_ok(kStack, 4, kHeapLo, kHeapHi));
  EXPECT_TRUE(dspn_write_ok(kBss, 4, kBss, kBss + 0x1000U));
  EXPECT_TRUE(dspn_write_ok(kStack, 4, kStack, kStack + 0x1000U));
}

TEST(WriteGate, BackstopHoldsAgainstAnyDeclaredWindow) {
  // An overbroad declared window must not admit text, vectors, MMIO or flash for writes.
  EXPECT_FALSE(dspn_write_ok(kText, 4, 0U, 0xFFFFFFFFU));
  EXPECT_FALSE(dspn_write_ok(kText, 4, kText, kText + 0x1000U));
  EXPECT_FALSE(dspn_write_ok(kTextEnd - 4, 4, 0U, 0xFFFFFFFFU));
  EXPECT_FALSE(dspn_write_ok(DSPN_TEXT_HI - 1, 1, 0U, 0xFFFFFFFFU));
  EXPECT_FALSE(dspn_write_ok(DSPN_TEXT_LO - 2, 8, 0U, 0xFFFFFFFFU));  // straddling
  EXPECT_FALSE(dspn_write_ok(DSPN_TEXT_HI - 2, 8, 0U, 0xFFFFFFFFU));
  EXPECT_FALSE(dspn_write_ok(kVectors, 4, 0U, 0xFFFFFFFFU));
  EXPECT_FALSE(dspn_write_ok(DSPN_DRAM_LO - 4U, 8, 0U, 0xFFFFFFFFU));
  EXPECT_FALSE(dspn_write_ok(kMmio1, 4, 0U, 0xFFFFFFFFU));
  EXPECT_FALSE(dspn_write_ok(kMmio2, 4, 0U, 0xFFFFFFFFU));
  EXPECT_FALSE(dspn_write_ok(kMmio3, 4, 0U, 0xFFFFFFFFU));
  EXPECT_FALSE(dspn_write_ok(kFlash, 4, 0U, 0xFFFFFFFFU));
  EXPECT_FALSE(dspn_write_ok(kUnmapped, 4, 0U, 0xFFFFFFFFU));
  EXPECT_FALSE(dspn_write_ok(DSPN_DRAM_END, 4, 0U, 0xFFFFFFFFU));
  EXPECT_FALSE(dspn_write_ok(DSPN_DRAM_END - 2U, 8, 0U, 0xFFFFFFFFU));

  EXPECT_TRUE(dspn_write_ok(DSPN_DRAM_LO, 4, 0U, 0xFFFFFFFFU));
  EXPECT_TRUE(dspn_write_ok(DSPN_TEXT_HI, 4, 0U, 0xFFFFFFFFU));
  EXPECT_TRUE(dspn_write_ok(DSPN_DRAM_END - 4U, 4, 0U, 0xFFFFFFFFU));
  EXPECT_TRUE(dspn_write_ok(kHeapLo, 4, 0U, 0xFFFFFFFFU));
}

TEST(ReadGate, AllDramAccepted) {
  EXPECT_TRUE(ReadOk(kVectors, 4));
  EXPECT_TRUE(ReadOk(kText, 4));
  EXPECT_TRUE(ReadOk(kHeapMid, 4));
  EXPECT_TRUE(ReadOk(kStack, 4));
  EXPECT_TRUE(ReadOk(kPageTable, 4));
  EXPECT_TRUE(ReadOk(DSPN_DRAM_END - 4, 4));
}

TEST(ReadGate, PastDramRefused) {
  EXPECT_FALSE(ReadOk(DSPN_DRAM_END, 4));
  EXPECT_FALSE(ReadOk(DSPN_DRAM_END - 2, 8));
  EXPECT_FALSE(ReadOk(kUnmapped, 4));
}

TEST(ReadGate, MmioRefusedForReadsToo) {
  // Memory-mapped I/O must not be read as ordinary memory.
  EXPECT_FALSE(ReadOk(kMmio1, 4));
  EXPECT_FALSE(ReadOk(kMmio2, 4));
  EXPECT_FALSE(ReadOk(kMmio3, 4));
}

TEST(ReadGate, FlashRefusedForReads) {
  EXPECT_FALSE(ReadOk(kFlash, 4));
}

TEST(TextOk, FirmwareTextAccepted) {
  EXPECT_TRUE(dspn_text_ok(0x0046F83CU));  // GHS sin on 1.7.17a
  EXPECT_TRUE(dspn_text_ok(0x0021EF24U));  // lua_pushnumber
  EXPECT_TRUE(dspn_text_ok(DSPN_TEXT_LO));
  EXPECT_TRUE(dspn_text_ok(DSPN_TEXT_HI - 1));
}

TEST(TextOk, OutsideTextRefused) {
  EXPECT_FALSE(dspn_text_ok(0));
  EXPECT_FALSE(dspn_text_ok(DSPN_TEXT_LO - 1));
  EXPECT_FALSE(dspn_text_ok(DSPN_TEXT_HI));
  EXPECT_FALSE(dspn_text_ok(kHeapMid));
  EXPECT_FALSE(dspn_text_ok(kMmio1));
  // An unresolved math address is zero and must fail the text check.
  EXPECT_FALSE(dspn_text_ok(0U));
}

// Reject multiplication overflow in strided ranges.

TEST(StrideOk, ChunkOfElementsAccepted) {
  EXPECT_TRUE(dspn_stride_ok(kHeapMid, 1024, 32, kHeapMid,
                             kHeapMid + 32768, 1));
}

TEST(StrideOk, OneElementPastTheChunkRefused) {
  EXPECT_FALSE(dspn_stride_ok(kHeapMid, 1025, 32, kHeapMid,
                              kHeapMid + 32768, 1));
}

TEST(StrideOk, ZeroCountAccepted) {

  EXPECT_TRUE(dspn_stride_ok(0, 0, 32, kHeapMid, kHeapMid + 32768, 1));
}

TEST(StrideOk, MultiplyOverflowRefused) {

  EXPECT_FALSE(dspn_stride_ok(kHeapMid, 0x08000000U, 32, kHeapLo, kHeapHi, 1));
  EXPECT_FALSE(dspn_stride_ok(kHeapMid, 0xFFFFFFFFU, 32, kHeapLo, kHeapHi, 1));
  EXPECT_FALSE(dspn_stride_ok(kHeapMid, 0x80000000U, 2, kHeapLo, kHeapHi, 1));
}

TEST(StrideOk, ZeroStrideRefused) {
  EXPECT_FALSE(dspn_stride_ok(kHeapMid, 10, 0, kHeapLo, kHeapHi, 1));
}

TEST(StrideOk, ReadSideUsesTheReadGate) {

  EXPECT_TRUE(dspn_stride_ok(kText, 4, 32, 0U, DSPN_DRAM_END, 0));
  EXPECT_TRUE(dspn_stride_ok(kVectors, 4, 32, 0U, DSPN_DRAM_END, 0));

  EXPECT_FALSE(dspn_stride_ok(kText, 4, 32, 0U, DSPN_DRAM_END, 1));
  EXPECT_FALSE(dspn_stride_ok(kVectors, 4, 32, 0U, DSPN_DRAM_END, 1));

  EXPECT_FALSE(dspn_stride_ok(kMmio1, 4, 32, 0U, 0xFFFFFFFFU, 0));
  EXPECT_FALSE(dspn_stride_ok(kMmio1, 4, 32, 0U, 0xFFFFFFFFU, 1));
}

// The declared window may cover multiple chunks; each access must stay inside its own payload.

namespace {
constexpr uint32_t kChunk1 = 0x0360D600U;
constexpr uint32_t kChunk2 = 0x036055F0U;   // Lower address than chunk 1; vector order is not address order.
constexpr uint32_t kSpanLo = kChunk2;
constexpr uint32_t kSpanHi = kChunk1 + 32768U;
}  // namespace

TEST(ChunkStride, BothMeasuredChunksAcceptedWholeAndFull) {
  EXPECT_TRUE(dspn_chunk_stride_ok(kChunk1, 1024, 32, kSpanLo, kSpanHi, 1));
  EXPECT_TRUE(dspn_chunk_stride_ok(kChunk2, 1024, 32, kSpanLo, kSpanHi, 1));
}

TEST(ChunkStride, OneElementPastEitherChunkRefused) {

  EXPECT_TRUE(dspn_range_ok(kChunk2, 1025 * 32, kSpanLo, kSpanHi));
  EXPECT_FALSE(dspn_chunk_stride_ok(kChunk2, 1025, 32, kSpanLo, kSpanHi, 1));
  EXPECT_FALSE(dspn_chunk_stride_ok(kChunk1, 1025, 32, kSpanLo, kSpanHi, 1));
}

TEST(ChunkStride, AWalkCannotCrossFromOnePayloadIntoTheOther) {

  constexpr uint32_t kReach = 1026;
  static_assert(kChunk2 + kReach * 32 > kChunk1, "the walk must reach the other payload");
  EXPECT_TRUE(dspn_range_ok(kChunk2, kReach * 32, kSpanLo, kSpanHi));
  EXPECT_FALSE(dspn_chunk_stride_ok(kChunk2, kReach, 32, kSpanLo, kSpanHi, 1));
}

TEST(ChunkStride, BoundsTheExtentButDoesNotAuthenticateTheBase) {
  // Containment does not authenticate a payload base; the caller must prove ownership.
  const uint32_t header = kChunk2 + 32768U;
  EXPECT_TRUE(dspn_chunk_stride_ok(header, 1, 16, kSpanLo, kSpanHi, 1));

  EXPECT_FALSE(dspn_chunk_stride_ok(header, 1025, 32, kSpanLo, kSpanHi, 1));
  EXPECT_FALSE(dspn_chunk_stride_ok(header, 1, 16, kHeapLo, kChunk2, 1));
}

TEST(ChunkStride, AbsentSecondChunkIsZeroCountNotZeroBase) {

  EXPECT_TRUE(dspn_chunk_stride_ok(0, 0, 32, kSpanLo, kSpanHi, 1));
  EXPECT_FALSE(dspn_chunk_stride_ok(0, 1, 32, kSpanLo, kSpanHi, 1));
}

TEST(ChunkStride, StillRefusesEverythingTheBackstopRefuses) {

  EXPECT_FALSE(dspn_chunk_stride_ok(kText, 1024, 32, kText, kText + 32768, 1));
  EXPECT_FALSE(dspn_chunk_stride_ok(kRodata, 1024, 32, kRodata, kRodata + 32768, 1));
  EXPECT_FALSE(dspn_chunk_stride_ok(kVectors, 16, 32, kVectors, kVectors + 32768, 1));
  EXPECT_FALSE(dspn_chunk_stride_ok(kMmio1, 1024, 32, kMmio1, kMmio1 + 32768, 0));
  EXPECT_TRUE(dspn_chunk_stride_ok(kBss, 1024, 32, kBss, kBss + 32768, 1));
  EXPECT_TRUE(dspn_chunk_stride_ok(kStack, 1024, 32, kStack, kStack + 32768, 1));
}

TEST(ChunkStride, BaseNearTheTopOfTheAddressSpaceRefused) {

  EXPECT_FALSE(dspn_chunk_stride_ok(0xFFFFF000U, 1, 32, 0U, DSPN_DRAM_END, 0));
  EXPECT_FALSE(dspn_chunk_stride_ok(0xFFFFFFFFU, 1, 1, 0U, DSPN_DRAM_END, 0));
}

TEST(ChunkStride, MultiplyOverflowStillRefused) {
  EXPECT_FALSE(dspn_chunk_stride_ok(kChunk1, 0xFFFFFFFFU, 32, kSpanLo, kSpanHi, 1));
  EXPECT_FALSE(dspn_chunk_stride_ok(kChunk1, 0x80000000U, 2, kSpanLo, kSpanHi, 1));
}

TEST(ChunkStride, ZeroStrideRefused) {
  EXPECT_FALSE(dspn_chunk_stride_ok(kChunk1, 10, 0, kSpanLo, kSpanHi, 1));
}

TEST(ChunkStride, InvertedWindowRefusesEverything) {

  constexpr uint32_t bad_lo = kChunk1;
  constexpr uint32_t bad_hi = kChunk2 + 32768U;   // 0x360D5F0, below bad_lo
  static_assert(bad_hi < bad_lo, "the measured pair must invert, or this tests nothing");
  EXPECT_FALSE(dspn_chunk_stride_ok(kChunk1, 1024, 32, bad_lo, bad_hi, 1));
  EXPECT_FALSE(dspn_chunk_stride_ok(kChunk2, 1024, 32, bad_lo, bad_hi, 1));
}

// Distinguish the descriptor's chunk-vector length from the chunks one record actually uses.
TEST(ChunkVector, TheVectorIsLongerThanTheRecordSpansAtEveryCountTheAppOffers) {
  struct Geom { const char *model; int elemsize; };
  // Exercise both supported capture strides.
  const Geom geoms[] = {{"DMM6500", 24}, {"DMM7510", 20}};
  const uint32_t capacity = 65536U;           // what the app asks buffer.make for
  const int counts[] = {512, 1024, 2048, 4096, 8192, 16384, 32768};

  for (const Geom &g : geoms) {
    const uint32_t perchunk = DSPN_CHUNK_BYTES / static_cast<uint32_t>(g.elemsize);

    EXPECT_LE(perchunk * static_cast<uint32_t>(g.elemsize), DSPN_CHUNK_BYTES) << g.model;
    EXPECT_GT((perchunk + 1U) * static_cast<uint32_t>(g.elemsize), DSPN_CHUNK_BYTES)
        << g.model;

    const uint32_t nchunks = (capacity + perchunk - 1U) / perchunk;
    EXPECT_LT(nchunks, DSPN_MAX_NCHUNKS) << g.model << " vector length must be admissible";

    EXPECT_GT(nchunks, static_cast<uint32_t>(DSP_MAX_SRC_BLOCKS))
        << g.model << " vector of " << nchunks
        << " entries must NOT be judged against DSP_MAX_SRC_BLOCKS";

    for (size_t i = 0; i < sizeof(counts) / sizeof(counts[0]); i++) {
      const uint32_t want =
          (static_cast<uint32_t>(counts[i]) + perchunk - 1U) / perchunk;
      EXPECT_LE(want, static_cast<uint32_t>(DSP_MAX_SRC_BLOCKS))
          << g.model << " n=" << counts[i] << " spans " << want << " blocks";
      EXPECT_LE(want, nchunks) << g.model << " n=" << counts[i];

      EXPECT_GE(want * perchunk, static_cast<uint32_t>(counts[i]))
          << g.model << " n=" << counts[i];
    }
  }
}

// Bound the vector length before its byte count can wrap to zero.
TEST(ChunkVector, AVectorLengthThatWrapsItsByteCountIsOutsideTheBound) {
  for (uint32_t nch : {0x40000000U, 0x80000000U, 0xC0000000U}) {
    EXPECT_EQ(0U, nch * 4U) << "this nchunks must wrap to a zero byte length";
    EXPECT_GE(nch, DSPN_MAX_NCHUNKS) << "and must therefore be refused";

    EXPECT_TRUE(dspn_range_ok(0x80000000U, nch * 4U, 0U, DSPN_DRAM_END));
  }
}
