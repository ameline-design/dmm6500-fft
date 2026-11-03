/*
 * flush_tramp.S -- the cache-flush trampoline fftsa.nl installs in the instrument heap.
 *
 * What it is for
 * --------------
 * ki.memwrite puts the compiled image into the heap through the data side. The e300c4
 * does not snoop the D-cache on an I-cache line fill, so the bytes have to be pushed out
 * with dcbst and the stale instruction lines invalidated with icbi before anything in the
 * image is called. This is the code that does it, and it is called exactly the way the
 * image is: ki.peek8's closure f pointer is redirected to the trampoline's load address.
 *
 * Entered as a lua_CFunction, so r3 holds the lua_State and r3 holds the number of
 * results on return. It takes no Lua arguments and returns none. The range comes from the
 * two words at offset 4, which fftsa.nl.flush writes with ki.memwrite before the call;
 * reading them is a data load on the core that wrote them, so it needs no barrier.
 *
 * Why the range is not read off the Lua stack
 * -------------------------------------------
 * Reading a Lua argument means calling lua_tostring and a hex parser, which are firmware
 * addresses, and the operator's requirement is that nothing here is pinned to a build.
 * Two words of its own and a pc-relative load cost sixteen bytes and depend on nothing.
 *
 * Position independence
 * ---------------------
 * The load address is chosen at install time. The bl/mflr pair puts the trampoline's own
 * address in a register, which is how the range words are reached; everything else is
 * register arithmetic and relative branches. The assembled object carries no relocations,
 * which csrc/tools/emit_tramp.py refuses to proceed without.
 *
 * The trampoline cannot flush itself: icbi on a line the core is executing from forces a
 * re-fetch mid-function. fftsa.nl.flush refuses a range that overlaps it, and the IPC
 * barrier in nl.init is what makes the trampoline's own bytes reachable.
 *
 * Registers are the volatiles only -- r0 is untouched, r3 to r6, r9 and r11 are scratch,
 * and the caller's return address is held in r11 across the bl rather than spilled, so
 * there is no stack frame.
 */

    .text
    .globl  dspn_flush_tramp
    .globl  dspn_flush_range
dspn_flush_tramp:
    b       .Lcode                              /* the entry is offset 0 */
dspn_flush_range:
    .long   0                                   /* offset 4: first address */
    .long   0                                   /* offset 8: length in bytes */
.Lcode:
    mflr    11                                  /* the caller's return address */
    bl      .Lpc
.Lpc:
    mflr    9                                   /* r9 = address of .Lpc */
    lwz     3, (dspn_flush_range - .Lpc)(9)
    lwz     4, (dspn_flush_range - .Lpc + 4)(9)
    mtlr    11
    cmplwi  4, 0                                /* a zero length flushes nothing */
    beq     .Ldone
    add     5, 3, 4
    addi    5, 5, 31
    rlwinm  5, 5, 0, 0, 26                      /* end, rounded up to a 32-byte line */
    rlwinm  3, 3, 0, 0, 26                      /* start, rounded down */
    mr      6, 3
.Lpush:
    dcbst   0, 3
    addi    3, 3, 32
    cmplw   3, 5
    blt     .Lpush
    sync                                        /* the stores are in memory before icbi */
.Linval:
    icbi    0, 6
    addi    6, 6, 32
    cmplw   6, 5
    blt     .Linval
    sync
    isync                                       /* and the pipeline refetches */
.Ldone:
    li      3, 0                                /* no Lua results */
    blr
