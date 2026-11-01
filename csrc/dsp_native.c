/*
 * dsp_native.c  --  lua_CFunction glue between native_link and dsp.c.
 *
 * Compiled for PowerPC e300 and loaded into the instrument's heap via the trampoline
 * mechanism in tsp/native_link.tsp.  The entry point dsp_native_run replaces one frame
 * of dsp.spectrum (Keithley's service call) without the internal buffer.clear() that
 * causes flicker.
 *
 * Binary layout
 * -------------
 * The flat binary produced by objcopy begins with a 4-byte slot for the params address,
 * followed immediately by dsp_native_run at offset 4.  The Lua startup code writes the
 * params address to (CODE_BASE + 0) via ki.poke32, then redirects ki.peek8 to
 * (CODE_BASE + 4).
 *
 * The binary is linked with a linker script that places .native_header before .text.
 *
 *   [0x00]  dsp_native_params_addr  (uint32_t, zero until Lua writes it)
 *   [0x04]  dsp_native_run entry point
 *   [...]   rest of .text and .rodata from dsp.c
 *
 * Params struct  (matches tsp/native_link.tsp nl.pack_params)
 * -----------------------------------------------------------
 *   +0   uint32  lua_pushnumber_addr  -- lua_pushnumber(L, v); 1.7.17a: 0x0021EF40
 *   +4   uint32  cap_chunk1           -- capture chunk 1 payload address
 *   +8   uint32  cap_chunk2           -- chunk 2, or 0
 *   +12  uint32  cap_n                -- N, power of two
 *   +16  uint32  out_chunk1           -- graph buffer chunk 1 payload address
 *   +20  uint32  out_chunk2           -- chunk 2, or 0
 *   +24  uint32  out_desc_cursor      -- column descriptor +0x4C address (write cursor)
 *   +28  uint32  out_desc_n_0         -- column descriptor +0x50 (n, first copy)
 *   +32  uint32  out_desc_n_1         -- column descriptor +0x60 (n, second copy)
 *   +36  uint32  plan_addr            -- dsp_plan in heap, init'd at startup
 *
 * Calling convention for dsp_native_run
 * ---------------------------------------
 * Standard PPC EABI / Lua CFunction: r3 = lua_State *L on entry; return count in r3.
 * The function pushes one number (bin count) and returns 1.
 * lua_pushnumber is called via an indirect call through the resolved address in params.
 *
 * Build
 * -----
 *   powerpc-eabi-gcc -mcpu=e300c2 -mhard-float -Os -fno-common -fPIE \
 *       -DSP_DOUBLE -DDSP_CHECK_OVERLAP=0 -I csrc \
 *       -c csrc/dsp_native.c csrc/dsp.c
 *   powerpc-eabi-ld -T csrc/dsp_native.ld -r dsp_native.o dsp.o \
 *       -o dsp_native_linked.o
 *   powerpc-eabi-objcopy -O binary dsp_native_linked.o dsp_native.bin
 *
 *   # Find the offset of dsp_native_params_addr in the flat binary:
 *   powerpc-eabi-nm dsp_native_linked.o | grep dsp_native_params_addr
 *   # Subtract the link address to get the file offset; that is CODE_BASE + offset.
 */

#include <stdint.h>
#include "dsp.h"

/* -------------------------------------------------------------------------
 * Type used for Lua function pointers.  The only signature needed here is
 * lua_pushnumber, which takes (lua_State*, double) and returns void.
 * -------------------------------------------------------------------------*/
typedef void (*lua_pushnumber_fn)(void *L, double v);

/* -------------------------------------------------------------------------
 * Params struct (layout matches tsp/native_link.tsp nl.pack_params).
 * -------------------------------------------------------------------------*/
typedef struct {
    uint32_t lua_pushnumber_addr;
    uint32_t cap_chunk1;
    uint32_t cap_chunk2;
    uint32_t cap_n;
    uint32_t out_chunk1;
    uint32_t out_chunk2;
    uint32_t out_desc_cursor;
    uint32_t out_desc_n_0;
    uint32_t out_desc_n_1;
    uint32_t plan_addr;
} dsp_native_params;

/* -------------------------------------------------------------------------
 * The 4-byte params-address slot placed before dsp_native_run by the linker
 * script.  Initialised to zero; the Lua side writes the actual params address
 * via ki.poke32(CODE_BASE, params_addr_hex) before the first call.
 * -------------------------------------------------------------------------*/
/* Placed at offset 0 in the flat binary by the ELF linker script dsp_native.ld.
 * The section attribute is silenced on non-ELF hosts; the host build is only used
 * to check that the source compiles, not to run it.                                 */
#ifdef __ELF__
uint32_t dsp_native_params_addr __attribute__((section(".native_header"))) = 0;
#else
uint32_t dsp_native_params_addr = 0;
#endif

/* -------------------------------------------------------------------------
 * Reading buffer element access: elements are 32 bytes, reading double at +0.
 * A chunk holds 1024 elements (32 768-byte payload).
 * -------------------------------------------------------------------------*/
static inline double rb_read(uint32_t ch1, uint32_t ch2, int k)
{
    const double *base;
    if (k < 1024) {
        base = (const double *)(uintptr_t)ch1;
    } else {
        base = (const double *)(uintptr_t)ch2;
        k   -= 1024;
    }
    return base[(size_t)k * 4u];          /* stride 4 doubles = 32 bytes */
}

static inline void rb_write(uint32_t ch1, uint32_t ch2, int k, double v)
{
    double *base;
    if (k < 1024) {
        base = (double *)(uintptr_t)ch1;
    } else {
        base = (double *)(uintptr_t)ch2;
        k   -= 1024;
    }
    base[(size_t)k * 4u] = v;
}

/* -------------------------------------------------------------------------
 * Entry point.
 * -------------------------------------------------------------------------*/
int dsp_native_run(void *L)
{
    uint32_t paddr = dsp_native_params_addr;
    if (paddr == 0u) { return 0; }

    const dsp_native_params *p = (const dsp_native_params *)(uintptr_t)paddr;
    dsp_plan *plan = (dsp_plan *)(uintptr_t)p->plan_addr;
    if (plan == NULL || plan->n == 0) { return 0; }

    int n = (int)p->cap_n;
    int m = plan->m;                 /* N/2 bins */
    if (n != plan->n) { return 0; }

    /* ------------------------------------------------------------------
     * Build a flat double array from the strided capture chunk storage.
     * The plan's fir_out pointer is reused as scratch when decim == 1
     * (in which case dsp_plan_init leaves it NULL and we must not use it).
     * We place the scratch right after the plan struct, 32-byte aligned.
     * The plan and its scratch live in the same arena block; the Lua
     * startup must size it to include n doubles of extra space.
     * ------------------------------------------------------------------ */
    uintptr_t plan_end = (uintptr_t)plan + sizeof(dsp_plan);
    plan_end = (plan_end + (uintptr_t)(DSP_ALIGN - 1))
               & ~(uintptr_t)(DSP_ALIGN - 1);
    double *src_flat = (double *)plan_end;

    {
        int k;
        for (k = 0; k < n; k++) {
            src_flat[k] = rb_read(p->cap_chunk1, p->cap_chunk2, k);
        }
    }

    int nbins = dsp_spectrum_run(plan, src_flat, n, NULL);
    if (nbins <= 0) { return 0; }

    /* ------------------------------------------------------------------
     * Write the power spectrum (plan->pwr) to the graph buffer's chunk
     * storage, reading the double directly since DSP_DOUBLE is defined.
     * ------------------------------------------------------------------ */
    {
        int k;
        for (k = 0; k < m; k++) {
            rb_write(p->out_chunk1, p->out_chunk2, k, (double)plan->pwr[k]);
        }
    }

    /* ------------------------------------------------------------------
     * Cursor-rewind: put the column descriptor's write cursor and n back
     * to the start so the graph widget sees a buffer that was "just filled"
     * from element 0, without a buffer.clear().  The descriptor fields are
     * the two iterator copies (+0x4C and +0x5C per fwmem-BUFFER.md).
     * We update only the first n copy here; the Lua notify (scaletrace or
     * drawstyle) triggers the widget re-read.
     * ------------------------------------------------------------------ */
    if (p->out_desc_cursor != 0u) {
        /* Cursor points to the slot AFTER the last write.  m writes from
         * chunk1 land the cursor at chunk1 + m*32 bytes when m <= 1024,
         * or into chunk2 otherwise.                                        */
        uint32_t new_cur;
        if (m <= 1024) {
            new_cur = p->out_chunk1 + (uint32_t)m * 32u;
        } else {
            new_cur = p->out_chunk2 + (uint32_t)(m - 1024) * 32u;
        }
        *(volatile uint32_t *)(uintptr_t)p->out_desc_cursor = new_cur;
    }
    if (p->out_desc_n_0 != 0u) {
        *(volatile uint32_t *)(uintptr_t)p->out_desc_n_0 = (uint32_t)m;
    }
    if (p->out_desc_n_1 != 0u) {
        *(volatile uint32_t *)(uintptr_t)p->out_desc_n_1 = (uint32_t)m;
    }

    /* ------------------------------------------------------------------
     * Push the bin count onto the Lua stack and return 1.
     * lua_pushnumber address comes from params; on 1.7.17a it is 0x0021EF40.
     * ------------------------------------------------------------------ */
    if (p->lua_pushnumber_addr != 0u) {
        lua_pushnumber_fn push =
            (lua_pushnumber_fn)(uintptr_t)p->lua_pushnumber_addr;
        push(L, (double)nbins);
        return 1;
    }

    return 0;
}
