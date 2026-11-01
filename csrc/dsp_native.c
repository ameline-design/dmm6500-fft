/*
 * dsp_native.c  --  lua_CFunction glue between native_link and dsp.c.
 *
 * Compiled for PowerPC e300c4 (big-endian) and loaded into the instrument's heap via
 * the trampoline mechanism in tsp/native_link.tsp.
 *
 * Position independence
 * --------------------
 * The binary is loaded at a heap address chosen at startup (CODE_BASE).  Traditional
 * -fPIC uses a GOT with relocation entries that a dynamic linker must apply; there is
 * no dynamic linker here, so -fPIC cannot be used.
 *
 * Instead the binary is made position-independent by construction:
 *   - Internal calls use `bl offset` (PC-relative) and work wherever the binary lands.
 *   - Calls to firmware functions use absolute addresses in the firmware's own .text,
 *     which is always at the same addresses regardless of where our binary is.
 *   - No global variables -- there is nothing in .data or .bss, so no absolute
 *     references to our own binary.
 *
 * The params address is passed as arg 1 on the Lua stack (a hex string), and parsed
 * using lua_tostring + hexparse at their known 1.7.17a addresses.  These are firmware
 * addresses, not binary-relative, so they remain correct at any load address.
 *
 * Binary layout (from dsp_native.ld)
 * ------------------------------------
 * No header slot is needed since we no longer use a global.  The flat binary is purely
 * .text followed by .rodata; dsp_native_run is at offset 0.
 *
 *   [0x00]  dsp_native_run entry point
 *   [...]   rest of .text from dsp.c, then .rodata
 *
 * The Lua side redirects ki.peek8 directly to CODE_BASE.
 *
 * Params struct  (matches tsp/native_link.tsp nl.pack_params)
 * -----------------------------------------------------------
 *   +0   uint32  lua_pushnumber_addr  -- lua_pushnumber(L, f1) on 1.7.17a: 0x0021EF24
 *   +4   uint32  cap_chunk1           -- capture chunk 1 payload address
 *   +8   uint32  cap_chunk2           -- chunk 2, or 0
 *   +12  uint32  cap_n                -- N, power of two
 *   +16  uint32  out_chunk1           -- graph buffer chunk 1 payload address
 *   +20  uint32  out_chunk2           -- chunk 2, or 0
 *   +24  uint32  out_desc_cursor      -- column descriptor +0x4C (write cursor)
 *   +28  uint32  out_desc_n_0         -- column descriptor +0x50 (n, first copy)
 *   +32  uint32  out_desc_n_1         -- column descriptor +0x60 (n, second copy)
 *   +36  uint32  plan_addr            -- dsp_plan in heap, initialised at startup
 *
 * Firmware addresses (1.7.17a -- rebuild dsp_native.bin for other firmware)
 * ---------------------------------------------------------------------------
 * LUA_TOSTRING  0x0021E868   lua_tostring(L, n) -> const char* in r3
 * HEXPARSE      0x004BFE9C   hexparse(str, &err) -> uint32 in r3
 * LUA_PUSHNUMBER resolved from params->lua_pushnumber_addr (written by FNF at startup)
 *
 * Build (requires clang with PPC backend + ld.lld)
 * ------------------------------------------------
 *   cmake -B build-ppc -DCMAKE_TOOLCHAIN_FILE=csrc/toolchain-ppc-clang.cmake \
 *         -DDSP_DST_NATIVE=ON
 *   cmake --build build-ppc --target dsp_native_bin
 *
 * Then set fftsa.nl._DSP_CODE in native_link.tsp to the contents of
 * build-ppc/dsp_native.bin.
 */

#include <stdint.h>
#include "dsp.h"

/* -------------------------------------------------------------------------
 * Library function strategy
 * -------------------------
 * Two classes of external function:
 *
 * 1. Firmware math functions (sin, cos, tan, asin, acos, atan, atan2, sqrt,
 *    exp, log, log10, floor, ceil): resolved at app startup via FNF scanning
 *    the Lua math wrappers.  Any firmware that runs Lua's math.* exposes them
 *    at discoverable, firmware-version-independent addresses.  Their addresses
 *    arrive in the params struct.
 *
 * 2. memcpy, memset, fabs: not exposed through Lua wrappers, so no reliable
 *    runtime discovery path exists.  Implemented directly below instead.
 *    These trivial implementations are fast enough for DSP init and setup;
 *    the hot loops in dsp.c use only math operations and array accesses.
 *
 * lua_tostring and hexparse are firmware addresses hardcoded below; they are
 * needed to parse the params address off the Lua stack, before the params
 * struct (which would carry discovered addresses) can be read.  For new
 * firmware builds, update them here and rebuild.
 * -------------------------------------------------------------------------*/

/* lua_tostring(lua_State *L, int n) -> const char *  1.7.17a */
#define LUA_TOSTRING_ADDR  0x0021E868u

/* hexparse(const char *str, int *err) -> uint32_t    1.7.17a */
#define HEXPARSE_ADDR      0x004BFE9Cu

typedef const char *(*lua_tostring_fn)(void *, int);
typedef uint32_t    (*hexparse_fn)(const char *, int *);
typedef void        (*lua_pushnumber_fn)(void *, double);

/* -------------------------------------------------------------------------
 * Self-contained implementations of the C runtime functions dsp.c needs
 * that are not discoverable through Lua wrappers.
 * -------------------------------------------------------------------------*/

void *memcpy(void *dst, const void *src, size_t n)
{
    unsigned char       *d = (unsigned char *)dst;
    const unsigned char *s = (const unsigned char *)src;
    while (n--) { *d++ = *s++; }
    return dst;
}

void *memset(void *s, int c, size_t n)
{
    unsigned char *p = (unsigned char *)s;
    while (n--) { *p++ = (unsigned char)c; }
    return s;
}

double fabs(double x) { return x < 0.0 ? -x : x; }

/* Params struct with math function addresses written by FNF at startup.    */
typedef struct {
    uint32_t lua_pushnumber_addr;   /* 0x0021EF24 on 1.7.17a                */
    /* math functions resolved by FNF(math.*) -- firmware .text addresses   */
    uint32_t sin_addr;
    uint32_t cos_addr;
    uint32_t tan_addr;
    uint32_t asin_addr;
    uint32_t acos_addr;
    uint32_t atan_addr;
    uint32_t atan2_addr;
    uint32_t sqrt_addr;
    uint32_t exp_addr;
    uint32_t log_addr;
    uint32_t log10_addr;
    uint32_t floor_addr;
    uint32_t ceil_addr;
    /* per-frame data                                                        */
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

/* (old params struct removed; see the full definition above) */

/* -------------------------------------------------------------------------
 * Reading buffer element access: 32-byte stride, reading double at offset 0.
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
    return base[(size_t)k * 4U];   /* stride 4 doubles = 32 bytes */
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
    base[(size_t)k * 4U] = v;
}

/* -------------------------------------------------------------------------
 * Entry point.
 *
 * Arg 1 on the Lua stack: params_addr (hex string).
 * Pushes one number (bin count) and returns 1.
 * -------------------------------------------------------------------------*/
int dsp_native_run(void *L)
{
    /* Parse the params address from arg 1 on the Lua stack.
     * lua_tostring and hexparse are called via function pointers built from
     * their known firmware addresses.  No globals in our binary.             */
    lua_tostring_fn  lts  = (lua_tostring_fn)(uintptr_t)LUA_TOSTRING_ADDR;
    hexparse_fn      hp   = (hexparse_fn)(uintptr_t)HEXPARSE_ADDR;

    const char *arg1 = lts(L, 1);
    if (arg1 == NULL) { return 0; }
    int parse_err = 0;
    uint32_t paddr = hp(arg1, &parse_err);
    if (parse_err) { return 0; }

    const dsp_native_params *p = (const dsp_native_params *)(uintptr_t)paddr;
    dsp_plan *plan = (dsp_plan *)(uintptr_t)p->plan_addr;
    if (plan == NULL || plan->n == 0) { return 0; }

    int n = (int)p->cap_n;
    int m = plan->m;
    if (n != plan->n) { return 0; }

    /* Place the flat source array immediately after the plan, 32-byte aligned.
     * The Lua startup must size the plan arena to include n doubles of scratch.  */
    uintptr_t plan_end = (uintptr_t)plan + sizeof(dsp_plan);
    plan_end = (plan_end + (uintptr_t)(DSP_ALIGN - 1))
               & ~(uintptr_t)(DSP_ALIGN - 1);
    double *src_flat = (double *)plan_end;

    /* Extract readings from strided chunk storage into the flat array.           */
    {
        int k;
        for (k = 0; k < n; k++) {
            src_flat[k] = rb_read(p->cap_chunk1, p->cap_chunk2, k);
        }
    }

    int nbins = dsp_spectrum_run(plan, src_flat, n, NULL);
    if (nbins <= 0) { return 0; }

    /* Write power spectrum to graph buffer chunk storage.                        */
    {
        int k;
        for (k = 0; k < m; k++) {
            rb_write(p->out_chunk1, p->out_chunk2, k, (double)plan->pwr[k]);
        }
    }

    /* Cursor-rewind: advance the write cursor to slot m so the firmware knows
     * m elements have been written, without issuing a buffer.clear().
     * Two n-copies are updated; fwmem-BUFFER.md confirms these are the fields
     * the graph widget tests.                                                    */
    if (p->out_desc_cursor != 0U) {
        uint32_t new_cur;
        if (m <= 1024) {
            new_cur = p->out_chunk1 + (uint32_t)m * 32U;
        } else {
            new_cur = p->out_chunk2 + (uint32_t)(m - 1024) * 32U;
        }
        *(volatile uint32_t *)(uintptr_t)p->out_desc_cursor = new_cur;
    }
    if (p->out_desc_n_0 != 0U) {
        *(volatile uint32_t *)(uintptr_t)p->out_desc_n_0 = (uint32_t)m;
    }
    if (p->out_desc_n_1 != 0U) {
        *(volatile uint32_t *)(uintptr_t)p->out_desc_n_1 = (uint32_t)m;
    }

    /* Push the bin count and return 1 value.                                     */
    if (p->lua_pushnumber_addr != 0U) {
        lua_pushnumber_fn push =
            (lua_pushnumber_fn)(uintptr_t)p->lua_pushnumber_addr;
        push(L, (double)nbins);
        return 1;
    }

    return 0;
}
