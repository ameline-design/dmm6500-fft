// Bounds tests for the native DSP entry point.
//
// These run on the host because the instrument cannot be used to test them: asking the
// DMM whether a write to a device register is refused means performing that write if the
// answer is no. The arithmetic is pure, so it is proved here instead, and the hardware
// experiments only exercise the guard at a boundary inside a buffer we own, where a
// failure writes into our own chunk storage and is harmless.
//
// Addresses are the 1.7.17a section table from fwmem-SAFETY.md.

#include <gtest/gtest.h>

extern "C" {
#include "dsp_native_bounds.h"
// For DSP_MAX_SRC_BLOCKS: the record's bound, against the vector's one here.
#include "dsp.h"
}

namespace {

// Named points in the address map, so a failure says which region leaked.
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

// A declared window wide enough not to be the thing doing the refusing.
constexpr uint32_t kWinLo = kHeapLo;
constexpr uint32_t kWinHi = kHeapHi;

int WriteOk(uint32_t a, uint32_t n) { return dspn_write_ok(a, n, kWinLo, kWinHi); }
int ReadOk(uint32_t a, uint32_t n) { return dspn_read_ok(a, n, 0U, 0xFFFFFFFFU); }

}  // namespace

// ---------------------------------------------------------------------------
// range_ok, the primitive the rest are built from.
// ---------------------------------------------------------------------------

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
  // A zero-length range touches nothing, so refusing it would only turn a no-op into
  // a spurious failure. This holds even for addresses that are otherwise forbidden.
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

// ---------------------------------------------------------------------------
// The write gate: heap only.
// ---------------------------------------------------------------------------

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
  // Straddling either edge is refused, not clipped.
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
  // The gap between .bss and .heap holds the splash, flash, ethernet and debug buffers.
  // A lower bound of 0x01000000 admits 216 KB of it, so the guard starts at the heap.
  EXPECT_FALSE(WriteOk(kIoBuffers, 4));
  EXPECT_FALSE(WriteOk(kBssEnd, 4));
  EXPECT_FALSE(WriteOk(kHeapLo - 0x1000U, 4));
}

TEST(WriteGate, CallStacksRefused) {
  // An upper bound of 0x0E000000 admits all four stacks plus 7.7 MB beyond them, so the
  // guard ends at the top of the heap and not at a round number near it.
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
  // Inside the heap but outside the declared window: refused by the window.
  EXPECT_FALSE(dspn_write_ok(kHeapMid, 4, kHeapLo, kHeapLo + 0x1000U));
  // The data sections and the call stacks are the window's job alone -- those addresses
  // differ per model, so the backstop names none of them.
  EXPECT_FALSE(dspn_write_ok(kBss, 4, kHeapLo, kHeapHi));
  EXPECT_FALSE(dspn_write_ok(kStack, 4, kHeapLo, kHeapHi));
  EXPECT_TRUE(dspn_write_ok(kBss, 4, kBss, kBss + 0x1000U));
  EXPECT_TRUE(dspn_write_ok(kStack, 4, kStack, kStack + 0x1000U));
}

TEST(WriteGate, BackstopHoldsAgainstAnyDeclaredWindow) {
  // What the backstop refuses however wide the window: .text, the exception vectors,
  // MMIO, flash and the unmapped gap above DRAM. A params struct cannot reach any of
  // them by declaring a bigger window, and nor can a window drawn tightly around one.
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
  // The gap between the vectors and .text, the word above .text, and the top of DRAM,
  // which it permits: on every measured build the heap floor is above TEXT_HI.
  EXPECT_TRUE(dspn_write_ok(DSPN_DRAM_LO, 4, 0U, 0xFFFFFFFFU));
  EXPECT_TRUE(dspn_write_ok(DSPN_TEXT_HI, 4, 0U, 0xFFFFFFFFU));
  EXPECT_TRUE(dspn_write_ok(DSPN_DRAM_END - 4U, 4, 0U, 0xFFFFFFFFU));
  EXPECT_TRUE(dspn_write_ok(kHeapLo, 4, 0U, 0xFFFFFFFFU));
}

// ---------------------------------------------------------------------------
// The read gate: all DRAM, nothing above it.
// ---------------------------------------------------------------------------

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
  // A load from a device register is not a read: it can pop a FIFO, clear an interrupt
  // status bit or start a transaction. Reads are refused, not just writes.
  EXPECT_FALSE(ReadOk(kMmio1, 4));
  EXPECT_FALSE(ReadOk(kMmio2, 4));
  EXPECT_FALSE(ReadOk(kMmio3, 4));
}

TEST(ReadGate, FlashRefusedForReads) {
  EXPECT_FALSE(ReadOk(kFlash, 4));
}

// ---------------------------------------------------------------------------
// Library addresses.
// ---------------------------------------------------------------------------

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
  // An unresolved FNF lookup leaves zero in the struct, which must not call anything.
  EXPECT_FALSE(dspn_text_ok(0U));
}

// ---------------------------------------------------------------------------
// Strided element ranges, where the multiply is the hazard.
// ---------------------------------------------------------------------------

TEST(StrideOk, ChunkOfElementsAccepted) {
  EXPECT_TRUE(dspn_stride_ok(kHeapMid, 1024, 32, kHeapMid,
                             kHeapMid + 32768, 1));
}

TEST(StrideOk, OneElementPastTheChunkRefused) {
  EXPECT_FALSE(dspn_stride_ok(kHeapMid, 1025, 32, kHeapMid,
                              kHeapMid + 32768, 1));
}

TEST(StrideOk, ZeroCountAccepted) {
  // The second chunk is absent when the capture fits one, and its count is zero.
  EXPECT_TRUE(dspn_stride_ok(0, 0, 32, kHeapMid, kHeapMid + 32768, 1));
}

TEST(StrideOk, MultiplyOverflowRefused) {
  // k * stride must not wrap into a small number and pass the range test.
  EXPECT_FALSE(dspn_stride_ok(kHeapMid, 0x08000000U, 32, kHeapLo, kHeapHi, 1));
  EXPECT_FALSE(dspn_stride_ok(kHeapMid, 0xFFFFFFFFU, 32, kHeapLo, kHeapHi, 1));
  EXPECT_FALSE(dspn_stride_ok(kHeapMid, 0x80000000U, 2, kHeapLo, kHeapHi, 1));
}

TEST(StrideOk, ZeroStrideRefused) {
  EXPECT_FALSE(dspn_stride_ok(kHeapMid, 10, 0, kHeapLo, kHeapHi, 1));
}

TEST(StrideOk, ReadSideUsesTheReadGate) {
  // Capture storage is read, so all of DRAM is fine for it -- including the exception
  // vectors, where a load is inert and a store is not.
  EXPECT_TRUE(dspn_stride_ok(kText, 4, 32, 0U, DSPN_DRAM_END, 0));
  EXPECT_TRUE(dspn_stride_ok(kVectors, 4, 32, 0U, DSPN_DRAM_END, 0));
  // But not for the write side.
  EXPECT_FALSE(dspn_stride_ok(kText, 4, 32, 0U, DSPN_DRAM_END, 1));
  EXPECT_FALSE(dspn_stride_ok(kVectors, 4, 32, 0U, DSPN_DRAM_END, 1));
  // Past DRAM, neither side goes.
  EXPECT_FALSE(dspn_stride_ok(kMmio1, 4, 32, 0U, 0xFFFFFFFFU, 0));
  EXPECT_FALSE(dspn_stride_ok(kMmio1, 4, 32, 0U, 0xFFFFFFFFU, 1));
}

// ---------------------------------------------------------------------------
// Per-chunk containment. The declared window has to cover every chunk of a buffer and the
// payloads are scattered -- 0x8010 is the allocator's block size, not a pitch -- so the
// window is necessarily wider than the payloads it describes. The addresses here are the
// real pair from E4c, where the second payload sits BELOW the first.
// ---------------------------------------------------------------------------

namespace {
constexpr uint32_t kChunk1 = 0x0360D600U;   // measured on the instrument
constexpr uint32_t kChunk2 = 0x036055F0U;   // measured, 32784 bytes BELOW kChunk1
constexpr uint32_t kSpanLo = kChunk2;
constexpr uint32_t kSpanHi = kChunk1 + 32768U;
}  // namespace

TEST(ChunkStride, BothMeasuredChunksAcceptedWholeAndFull) {
  EXPECT_TRUE(dspn_chunk_stride_ok(kChunk1, 1024, 32, kSpanLo, kSpanHi, 1));
  EXPECT_TRUE(dspn_chunk_stride_ok(kChunk2, 1024, 32, kSpanLo, kSpanHi, 1));
}

TEST(ChunkStride, OneElementPastEitherChunkRefused) {
  // The window alone would permit this: kChunk2 + 32768 is still well below kSpanHi, so
  // only the per-chunk bound refuses it. That gap is the reason the helper exists.
  EXPECT_TRUE(dspn_range_ok(kChunk2, 1025 * 32, kSpanLo, kSpanHi));
  EXPECT_FALSE(dspn_chunk_stride_ok(kChunk2, 1025, 32, kSpanLo, kSpanHi, 1));
  EXPECT_FALSE(dspn_chunk_stride_ok(kChunk1, 1025, 32, kSpanLo, kSpanHi, 1));
}

TEST(ChunkStride, AWalkCannotCrossFromOnePayloadIntoTheOther) {
  // The span is 65,552 bytes to hold two 32,768-byte payloads, so between them sit 16
  // bytes of allocator block header that the window covers and we do not own. This is the
  // access the window cannot refuse: start at the lower payload and run long enough to
  // reach the higher one. 1026 elements of 32 bytes from kChunk2 covers the header and the
  // first 48 bytes of kChunk1.
  constexpr uint32_t kReach = 1026;
  static_assert(kChunk2 + kReach * 32 > kChunk1, "the walk must reach the other payload");
  EXPECT_TRUE(dspn_range_ok(kChunk2, kReach * 32, kSpanLo, kSpanHi));
  EXPECT_FALSE(dspn_chunk_stride_ok(kChunk2, kReach, 32, kSpanLo, kSpanHi, 1));
}

TEST(ChunkStride, BoundsTheExtentButDoesNotAuthenticateTheBase) {
  // A documented limitation, asserted so it cannot change silently. The helper confines a
  // walk to DSPN_CHUNK_BYTES from wherever it starts; it has no list of real payloads, so
  // a base in the inter-payload header looks like a chunk base to it and a short walk from
  // there is accepted. That is not a hole in practice -- dsp_native_run only ever passes
  // p->cap_chunk1/2 and p->out_chunk1/2, so a bad base means Lua declared a bad payload,
  // which is the same trust boundary as declaring a bad window -- but it is the reason
  // this check tightens the window rather than replacing it.
  const uint32_t header = kChunk2 + 32768U;
  EXPECT_TRUE(dspn_chunk_stride_ok(header, 1, 16, kSpanLo, kSpanHi, 1));
  // What it still guarantees from that base: the extent, and the declared window.
  EXPECT_FALSE(dspn_chunk_stride_ok(header, 1025, 32, kSpanLo, kSpanHi, 1));
  EXPECT_FALSE(dspn_chunk_stride_ok(header, 1, 16, kHeapLo, kChunk2, 1));
}

TEST(ChunkStride, AbsentSecondChunkIsZeroCountNotZeroBase) {
  // chunk2 == 0 means "one chunk holds it all", which is only consistent with a zero
  // count. A positive count from a null base is a caller bug, not an empty walk.
  EXPECT_TRUE(dspn_chunk_stride_ok(0, 0, 32, kSpanLo, kSpanHi, 1));
  EXPECT_FALSE(dspn_chunk_stride_ok(0, 1, 32, kSpanLo, kSpanHi, 1));
}

TEST(ChunkStride, StillRefusesEverythingTheBackstopRefuses) {
  // The per-chunk bound is an addition, never a replacement: a chunk-shaped access at an
  // address the backstop forbids stays refused even though it is internally
  // self-consistent, and even though the window here is drawn around it.
  //
  // What that covers is .text, the vectors, and everything outside DRAM. It does NOT
  // cover .data, .bss, the I/O buffers or the call stacks: those addresses differ per
  // model, so no figure compiled in here can name them without refusing good heap on a
  // model it was not measured on. A window drawn around one of them is accepted, and
  // what keeps a window from being drawn there is on the Lua side -- the descriptor is
  // authenticated by signature before its chunk vector is read, and the window is
  // derived from that vector rather than declared.
  EXPECT_FALSE(dspn_chunk_stride_ok(kText, 1024, 32, kText, kText + 32768, 1));
  EXPECT_FALSE(dspn_chunk_stride_ok(kRodata, 1024, 32, kRodata, kRodata + 32768, 1));
  EXPECT_FALSE(dspn_chunk_stride_ok(kVectors, 16, 32, kVectors, kVectors + 32768, 1));
  EXPECT_FALSE(dspn_chunk_stride_ok(kMmio1, 1024, 32, kMmio1, kMmio1 + 32768, 0));
  EXPECT_TRUE(dspn_chunk_stride_ok(kBss, 1024, 32, kBss, kBss + 32768, 1));
  EXPECT_TRUE(dspn_chunk_stride_ok(kStack, 1024, 32, kStack, kStack + 32768, 1));
}

TEST(ChunkStride, BaseNearTheTopOfTheAddressSpaceRefused) {
  // base + DSPN_CHUNK_BYTES must not wrap when the per-chunk extent is formed.
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
  // The bug this was added alongside: describe() took hi from the second payload
  // unconditionally, so with the measured pair hi came out below lo. It fails closed --
  // every frame refused, native path dead, silent fallback to dsp.spectrum.
  constexpr uint32_t bad_lo = kChunk1;
  constexpr uint32_t bad_hi = kChunk2 + 32768U;   // 0x360D5F0, below bad_lo
  static_assert(bad_hi < bad_lo, "the measured pair must invert, or this tests nothing");
  EXPECT_FALSE(dspn_chunk_stride_ok(kChunk1, 1024, 32, bad_lo, bad_hi, 1));
  EXPECT_FALSE(dspn_chunk_stride_ok(kChunk2, 1024, 32, bad_lo, bad_hi, 1));
}

// A buffer's chunk VECTOR and the part of it a record SPANS are two different lengths, and
// they do not share a bound. Bounding the vector at DSP_MAX_SRC_BLOCKS refused a DMM6500's
// own capture outright -- 49 entries against 32 -- which reached the instrument as
// DSPN_ECAPTURE on every frame, with the app halting because this archive carries no
// interpreted transform to fall back to. DSPN_MAX_NCHUNKS is the vector's bound and exists
// only to stop `nchunks * 4` wrapping; DSP_MAX_SRC_BLOCKS is the record's and bounds
// dsp_src::blk.
TEST(ChunkVector, TheVectorIsLongerThanTheRecordSpansAtEveryCountTheAppOffers) {
  struct Geom { const char *model; int elemsize; };
  // Both measured: 24 on a DMM6500 1.7.17a, 20 on a DMM7510 1.7.16a. The element size is a
  // runtime sum of column widths, so it is per model and neither figure is compiled in.
  const Geom geoms[] = {{"DMM6500", 24}, {"DMM7510", 20}};
  const uint32_t capacity = 65536U;           // what the app asks buffer.make for
  const int counts[] = {512, 1024, 2048, 4096, 8192, 16384, 32768};

  for (const Geom &g : geoms) {
    const uint32_t perchunk = DSPN_CHUNK_BYTES / static_cast<uint32_t>(g.elemsize);
    // perchunk is how many elements fill one payload, and one more must not.
    EXPECT_LE(perchunk * static_cast<uint32_t>(g.elemsize), DSPN_CHUNK_BYTES) << g.model;
    EXPECT_GT((perchunk + 1U) * static_cast<uint32_t>(g.elemsize), DSPN_CHUNK_BYTES)
        << g.model;

    const uint32_t nchunks = (capacity + perchunk - 1U) / perchunk;
    EXPECT_LT(nchunks, DSPN_MAX_NCHUNKS) << g.model << " vector length must be admissible";
    // THE POINT: the vector is legitimately longer than a record can span, so the two
    // bounds cannot be the same number.
    EXPECT_GT(nchunks, static_cast<uint32_t>(DSP_MAX_SRC_BLOCKS))
        << g.model << " vector of " << nchunks
        << " entries must NOT be judged against DSP_MAX_SRC_BLOCKS";

    for (size_t i = 0; i < sizeof(counts) / sizeof(counts[0]); i++) {
      const uint32_t want =
          (static_cast<uint32_t>(counts[i]) + perchunk - 1U) / perchunk;
      EXPECT_LE(want, static_cast<uint32_t>(DSP_MAX_SRC_BLOCKS))
          << g.model << " n=" << counts[i] << " spans " << want << " blocks";
      EXPECT_LE(want, nchunks) << g.model << " n=" << counts[i];
      // Every element the record has must be addressable: blk[j / per] for j < n.
      EXPECT_GE(want * perchunk, static_cast<uint32_t>(counts[i]))
          << g.model << " n=" << counts[i];
    }
  }
}

// And the wrap the vector bound is actually for: a length that is a multiple of 2^30 makes
// `nchunks * 4` exactly zero, and a zero-length range is permitted at any address -- the
// device registers included. The bound is what keeps that unreachable.
TEST(ChunkVector, AVectorLengthThatWrapsItsByteCountIsOutsideTheBound) {
  for (uint32_t nch : {0x40000000U, 0x80000000U, 0xC0000000U}) {
    EXPECT_EQ(0U, nch * 4U) << "this nchunks must wrap to a zero byte length";
    EXPECT_GE(nch, DSPN_MAX_NCHUNKS) << "and must therefore be refused";
    // Proof the wrap would otherwise pass: a zero-length range is admitted at MMIO.
    EXPECT_TRUE(dspn_range_ok(0x80000000U, nch * 4U, 0U, DSPN_DRAM_END));
  }
}
