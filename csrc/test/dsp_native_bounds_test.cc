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
  // The gap between .bss and .heap holds the splash, flash, ethernet and debug
  // buffers. An earlier version of the guard used 0x01000000 as its lower bound and
  // admitted 216 KB of this.
  EXPECT_FALSE(WriteOk(kIoBuffers, 4));
  EXPECT_FALSE(WriteOk(kBssEnd, 4));
  EXPECT_FALSE(WriteOk(kHeapLo - 0x1000U, 4));
}

TEST(WriteGate, CallStacksRefused) {
  // An earlier version used 0x0E000000 as its upper bound, which admitted all four
  // stacks plus 7.7 MB beyond, while its comment claimed the opposite.
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
  // Inside a declared window that reaches past the heap: refused by the backstop, so a
  // params struct cannot widen the gate by declaring a bigger window.
  EXPECT_FALSE(dspn_write_ok(kStack, 4, kHeapLo, 0x0FFFFFFFU));
  EXPECT_FALSE(dspn_write_ok(kMmio1, 4, 0U, 0xFFFFFFFFU));
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
  // Capture storage is read, so DRAM outside the heap is fine for it.
  EXPECT_TRUE(dspn_stride_ok(kText, 4, 32, 0U, DSPN_DRAM_END, 0));
  // But not for the write side.
  EXPECT_FALSE(dspn_stride_ok(kText, 4, 32, 0U, DSPN_DRAM_END, 1));
}
