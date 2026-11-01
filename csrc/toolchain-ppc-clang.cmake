# toolchain-ppc-clang.cmake -- clang/llvm cross-compilation to PowerPC e300.
#
# Requires Homebrew LLVM (not Apple clang, which has no PPC backend):
#   brew install llvm
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
# The e300c4 is derived from the 603e: 32-bit, big-endian, EABI ABI,
# hardware single and double-precision FPU, no AltiVec/VMX.
#
# LLVM has no e300 family entries.  The correct value is -mcpu=603e, which
# is what the e300c4 derives from and what LLVM generates correct code for.
# Do NOT use e300c2/c3/c4 -- those are not in LLVM's CPU table.
# Do NOT use e500/8548 -- those are SPE cores without a classic double FPU.
#
# ABI: System V PPC EABI.  GCC and clang agree on the calling convention.

set(CMAKE_SYSTEM_NAME Generic)
set(CMAKE_SYSTEM_PROCESSOR powerpc)

# Homebrew LLVM clang; Apple's clang has no PPC backend.
find_program(LLVM_CLANG clang
    HINTS /opt/homebrew/opt/llvm/bin /usr/local/opt/llvm/bin
    REQUIRED)
set(CMAKE_C_COMPILER   "${LLVM_CLANG}")
set(CMAKE_CXX_COMPILER "${LLVM_CLANG}++")
set(CMAKE_ASM_COMPILER "${LLVM_CLANG}")

set(CLANG_TARGET "powerpc-unknown-elf")
set(COMMON_FLAGS
    "--target=${CLANG_TARGET} -mcpu=603e -mhard-float -mbig-endian \
     -mabi=sysv -ffreestanding -fno-PIC")

set(CMAKE_C_FLAGS_INIT   "${COMMON_FLAGS}")
set(CMAKE_CXX_FLAGS_INIT "${COMMON_FLAGS}")
set(CMAKE_ASM_FLAGS_INIT "${COMMON_FLAGS}")
set(CMAKE_EXE_LINKER_FLAGS_INIT "")

# llvm-objcopy and ld.lld from the same brew prefix.
find_program(LLVM_OBJCOPY llvm-objcopy
    HINTS /opt/homebrew/opt/llvm/bin /usr/local/opt/llvm/bin
    REQUIRED)
set(CMAKE_OBJCOPY "${LLVM_OBJCOPY}")

find_program(LLVM_LD ld.lld
    HINTS /opt/homebrew/opt/lld/bin /opt/homebrew/opt/llvm/bin
          /usr/local/opt/lld/bin
    REQUIRED)
set(CMAKE_LINKER "${LLVM_LD}")
set(CMAKE_EXE_LINKER_FLAGS_INIT "${CMAKE_EXE_LINKER_FLAGS_INIT} -fuse-ld=${LLVM_LD}")

set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)
