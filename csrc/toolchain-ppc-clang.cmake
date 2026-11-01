# toolchain-ppc-clang.cmake -- clang/llvm cross-compilation to PowerPC e300.
#
# clang has native PPC support without a separate cross-compiler; it uses the
# LLVM PPC backend and LLVM's integrated assembler.  Only the linker (lld or a
# system ld) and objcopy (llvm-objcopy) need to handle PPC ELF objects.
#
# Install on macOS:
#   brew install llvm lld
#   # lld includes llvm-objcopy; add the brew prefix to PATH.
#
# Usage:
#   cmake -B build-ppc \
#         -DCMAKE_TOOLCHAIN_FILE=csrc/toolchain-ppc-clang.cmake \
#         -DDSP_DST_NATIVE=ON
#   cmake --build build-ppc --target dsp_native_bin
#
# Processor notes
# ---------------
# The DMM6500 uses a Freescale MPC5200B (PowerPC e300c4, ~400 MHz).
# The e300c4 core is derived from the 603e: 32-bit, big-endian, EABI ABI,
# hardware single and double-precision FPU, no AltiVec/VMX.
#
# clang target: powerpc-unknown-elf
# -mcpu=e300c2   covers the e300c2/c3/c4 cores and generates correct code.
# -mhard-float   use the hardware FPU.
# -mbig-endian   the DMM6500 runs big-endian (confirmed by the element layout
#                and the BAT setup -- WIMG=0 PP=2, no endian-swap bit).
#
# ABI: System V PPC EABI.  GCC and clang agree on the calling convention.

set(CMAKE_SYSTEM_NAME Generic)
set(CMAKE_SYSTEM_PROCESSOR powerpc)

# clang triple for PPC big-endian ELF (no OS, bare-metal).
set(CLANG_TARGET "powerpc-unknown-elf")

set(CMAKE_C_COMPILER   "clang")
set(CMAKE_CXX_COMPILER "clang++")
set(CMAKE_ASM_COMPILER "clang")

# Flags that are part of the cross-compilation target and never change.
#
# -mcpu=e300c4: the Freescale MPC5200B uses an e300c4 core.  The e300c4 is
#   an enhancement of the e300c2/c3; clang's -mcpu=e300c4 targets it exactly.
#   The core is big-endian, 32-bit, EABI ABI, hardware single and double FPU,
#   no AltiVec.  Use -mcpu=603e if e300c4 is not recognised by an older clang.
#
# -mbig-endian: the DMM6500 runs in big-endian mode (confirmed by the buffer
#   element capture and the BAT setup in the boot code).
#
# -mhard-float: use the hardware FPU.  The e300c4 has an FPU; soft-float
#   would generate software-float calls that are not in the instrument's heap.
#
# -fno-PIC / -mrelocatable: the binary is loaded at a fixed heap address chosen
#   at startup.  Position-independent code is not needed; the linker script
#   places .native_header at offset 0 and the entry point at offset 4.
set(COMMON_FLAGS
    "--target=${CLANG_TARGET} -mcpu=e300c4 -mhard-float -mbig-endian \
     -mabi=sysv -ffreestanding -fno-PIC")

set(CMAKE_C_FLAGS_INIT   "${COMMON_FLAGS}")
set(CMAKE_CXX_FLAGS_INIT "${COMMON_FLAGS}")
set(CMAKE_ASM_FLAGS_INIT "${COMMON_FLAGS}")
set(CMAKE_EXE_LINKER_FLAGS_INIT "")

# llvm-objcopy understands ELF PPC objects; locate it via the brew prefix.
find_program(LLVM_OBJCOPY llvm-objcopy
    HINTS /opt/homebrew/opt/llvm/bin /usr/local/opt/llvm/bin)
if(LLVM_OBJCOPY)
  set(CMAKE_OBJCOPY "${LLVM_OBJCOPY}")
endif()

# ld.lld handles PPC ELF without a target-specific linker installed.
find_program(LLVM_LD ld.lld
    HINTS /opt/homebrew/opt/lld/bin /opt/homebrew/opt/llvm/bin
          /usr/local/opt/lld/bin)
if(LLVM_LD)
  set(CMAKE_LINKER "${LLVM_LD}")
  set(CMAKE_EXE_LINKER_FLAGS_INIT "${CMAKE_EXE_LINKER_FLAGS_INIT} -fuse-ld=${LLVM_LD}")
endif()

# Prevent CMake from testing the compiler by trying to link an executable
# (which would fail on the host due to PPC ABI mismatch).
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)
