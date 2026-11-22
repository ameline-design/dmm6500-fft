/*
 * Position-independent e300 cache flush. Lua writes address and length at offset 4;
 * no Lua arguments or results are used. Push D-cache lines before invalidating I-cache.
 * The loader must keep the requested lines disjoint from this executing trampoline.
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
