/*
 * dsp_native_px.h -- the graph ring's y-pixel fill, and the slot map's validity.
 *
 * In a header of its own for the same reason dsp_native_bounds.h is: so the host suite
 * exercises the code that ships rather than a copy of it.  The instrument cannot be used to
 * test this -- an error in the destination arithmetic writes into the display task's heap,
 * and the first symptom is PegRect::operator& on a freed widget, a bluescreen ki.reboot
 * cannot recover.  The arithmetic is pure, so it is proved on the host instead; see
 * csrc/test/dsp_native_px_test.cc, which covers the destination of every store, the clamp at
 * both ends, NaN and both infinities, and the rounding against the Lua writer's.
 *
 * CONFINEMENT IS NOT HERE.  The addresses arrive from Lua in a block and are bounded in
 * dsp_native_run, where the params struct and the declared windows are.  What is handed to
 * dspn_px_fill is a destination already proved to be ours, and the only claim this file makes
 * about it is that no store lands outside [ring, ring + nrec*stride).
 */
#ifndef DSP_NATIVE_PX_H
#define DSP_NATIVE_PX_H

#include <stdint.h>
#include "dsp.h"

/* The row a decibel draws on.
 *
 * TWO ROUNDINGS AND NOT ONE, which is what the volatile is for.  The target has fmadd and
 * the compiler used it -- `fmadd 3, 31, 3, 30` in the image built before this -- so
 * `ay*db + by` was one fused operation with a single rounding, while the Lua writer rounds
 * the product and then adds.  Where the sum lands exactly on a half the two floors differ by
 * a whole row:
 *
 *     ay = -7.7603470944719,  db = 8.477140426635742,  by = 231.28555207927295
 *     Lua           (ay*db) rounded, then + by  ->  165.5              -> row 166
 *     fused         one rounding                ->  165.49999999999997 -> row 165
 *
 * The two writers are interchangeable frame by frame -- a frame that re-points the series
 * uses the Lua one and every other frame uses this -- so they have to agree.  A volatile
 * forces the store and load that rounds the product, which no -ffp-contract setting can take
 * away; a compile flag could be lost in a build change and nothing would notice.
 *
 * NaN goes to the bottom row and not the top: both comparisons below are false for it, so
 * without naming it the conversion to int32 would be undefined.  The floor is the answer
 * dsp_reduce already gives a bin it could not measure.  +inf clamps to the floor and -inf to
 * row zero, which is what the ordinary comparisons do with them.
 */
static uint32_t dspn_px_row(double db, double ay, double by, uint32_t ymax)
{
    volatile double prod = ay * db;
    const double ymaxd = (double)ymax;
    double y = prod + by + 0.5;
    if (y != y)       { y = ymaxd; }
    else if (y < 0.0) { y = 0.0; }
    if (y > ymaxd)    { y = ymaxd; }
    /* y is in 0..ymax and ymax is bounded by the caller, so the conversion is defined and
     * the truncation is the floor the clamp already landed on. */
    return (uint32_t)(int32_t)y;
}

/* Is every slot's column inside the reduction's array?
 *
 * ALL OF THEM BEFORE THE FIRST STORE.  A slot naming a column outside the array reads a
 * dsp_real from whatever follows it, and refusing half way through the ring would leave the
 * picture part this frame and part the last -- a tear nothing downstream could tell from a
 * real spectrum.  So the map is checked whole and the fill is all or nothing.
 *
 * One-based, as the Lua slot map is: column j of the spectrum is idx[s] == j.
 */
static int dspn_px_map_ok(const uint32_t *idx, uint32_t nrec, uint32_t nseg)
{
    uint32_t s;
    if (idx == NULL || nrec == 0U || nseg == 0U) { return 0; }
    for (s = 0U; s < nrec; s++) {
        if (idx[s] == 0U || idx[s] > nseg) { return 0; }
    }
    return 1;
}

/* Write nrec records' y triples, and nothing else.
 *
 * Every address touched is ring + s*stride + yoff for s in 0..nrec-1, twelve bytes each, so
 * the whole of it lies in [ring, ring + nrec*stride) exactly when yoff + 12 <= stride -- which
 * dsp_native_run requires along with 4-byte alignment of all three, so no store is misaligned.
 *
 * Three identical copies, which is how the firmware stores a pixel.  They are plain uint32
 * stores and the target is big-endian, so the bytes are the big-endian encoding the Lua
 * writer packs by hand.
 *
 * KEPT OUT OF LINE, which is the one thing here that is for a gate rather than for the
 * instrument.  It is called once a frame, so a call costs nothing measurable, and being a
 * symbol is what lets csrc/tools/check_fp_contract.py read its instructions and prove the
 * image holds no fused multiply-add in it -- the only place that question can be settled,
 * because the host does not fuse this expression at any flag while PowerPC does.
 *
 * ring is a uintptr_t and not a uint32_t so that the host suite can hand it a real buffer:
 * on the target the two are the same width and nothing about the arithmetic changes, while on
 * a 64-bit host a heap pointer does not fit a uint32 and the loop could only be tested
 * against addresses nothing owns.  The caller still bounds it as a uint32, which is what the
 * instrument's addresses are.
 */
#if defined(__GNUC__) || defined(__clang__)
__attribute__((noinline))
#endif
static void dspn_px_fill(uintptr_t ring, uint32_t stride, uint32_t yoff, uint32_t nrec,
                         uint32_t ymax, double ay, double by,
                         const uint32_t *idx, const dsp_real *db)
{
    uint32_t s;
    for (s = 0U; s < nrec; s++) {
        volatile uint32_t *q = (volatile uint32_t *)(ring + s * stride + yoff);
        const uint32_t yw = dspn_px_row((double)db[idx[s] - 1U], ay, by, ymax);
        q[0] = yw;
        q[1] = yw;
        q[2] = yw;
    }
}

#endif
