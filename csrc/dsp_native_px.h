/* Native graph-ring Y writer. The caller validates memory ranges, then checks the full slot map. */
#ifndef DSP_NATIVE_PX_H
#define DSP_NATIVE_PX_H

#include <stdint.h>
#include "dsp.h"

/*
 * Match Lua's two rounding steps: volatile prevents fusing the multiply and add.
 * Clamp the row before converting to an integer; the caller bounds ymax.
 */
static uint32_t dspn_px_row(double db, double ay, double by, uint32_t ymax)
{
    volatile double prod = ay * db;
    const double ymaxd = (double)ymax;
    double y = prod + by + 0.5;
    if (y != y)       { y = ymaxd; }
    else if (y < 0.0) { y = 0.0; }
    if (y > ymaxd)    { y = ymaxd; }

    return (uint32_t)(int32_t)y;
}

/* Reject any out-of-range column before the first store so failure leaves the ring untouched. */
static int dspn_px_map_ok(const uint32_t *idx, uint32_t nrec, uint32_t nseg)
{
    uint32_t s;
    if (idx == NULL || nrec == 0U || nseg == 0U) { return 0; }
    for (s = 0U; s < nrec; s++) {
        if (idx[s] == 0U || idx[s] > nseg) { return 0; }
    }
    return 1;
}

/* Write only the repeated Y word at each mapped slot; leave X and all other record fields intact. */
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
