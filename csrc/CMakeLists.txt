cmake_minimum_required(VERSION 3.14)
project(dmm6500_dsp C CXX)

set(CMAKE_C_STANDARD 99)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS OFF)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE RelWithDebInfo CACHE STRING "" FORCE)
endif()

include(FetchContent)
FetchContent_Declare(
  googletest
  GIT_REPOSITORY https://github.com/google/googletest.git
  GIT_TAG v1.15.2
  GIT_SHALLOW TRUE)
set(gtest_force_shared_crt ON CACHE BOOL "" FORCE)
set(INSTALL_GTEST OFF CACHE BOOL "" FORCE)
FetchContent_MakeAvailable(googletest)

enable_testing()

# The library is strict C99 under -pedantic -Werror. Everything clang has that this code can
# be clean under is on, which was established by trying them one at a time rather than by
# taste: of the flags probed, only -Wpadded fires, and it asks for the public struct to be
# reordered for packing, which would undo the field grouping the header documents.
# -Weverything is clean apart from that, -Wbad-function-cast (see dsp_ifloor),
# -Wdeclaration-after-statement, -Wunsafe-buffer-usage, -Wpre-c11-compat, -Wc99-compat and
# -Wcovered-switch-default; set DSP_WEVERYTHING=ON to check that claim.
#
# The ones that earn their place here rather than being inherited from -Wall: -Wconversion for
# silent narrowing in the mixed float/double arithmetic, -Wdouble-promotion for a promotion
# that would hide a precision decision, -Wbad-function-cast because an out-of-range
# double-to-int conversion is undefined and traps at -O1, -Wdocumentation because the
# interface is Doxygen and a stale @param is how a header starts lying, and
# -Wshift-sign-overflow and -Wconditional-uninitialized for the bit and branch arithmetic in
# the four-step. -Wbad-function-cast is why every float-to-int conversion goes through
# dsp_ifloor.
set(DSP_C_FLAGS
    -std=c99
    -pedantic
    -pedantic-errors
    -Wall
    -Wextra
    -Werror
    -Wconversion
    -Wdouble-promotion
    -Wshadow
    -Wstrict-prototypes
    -Wmissing-prototypes
    -Wmissing-declarations
    -Wmissing-variable-declarations
    -Wcast-qual
    -Wcast-align
    -Wpointer-arith
    -Wwrite-strings
    -Wundef
    -Wvla
    -Wbad-function-cast
    -Wfloat-equal
    -Wswitch-enum
    -Wswitch-default
    -Wformat=2
    -Wimplicit-fallthrough
    -Wredundant-decls
    -Wnested-externs
    -Wold-style-definition
    -Winit-self
    -Wunused-macros
    -Wtautological-compare
    -Wnewline-eof)

# clang-only additions, all verified clean. Kept apart so a gcc build does not fail on an
# unknown flag.
if(CMAKE_C_COMPILER_ID MATCHES "Clang")
  list(APPEND DSP_C_FLAGS
       -Wdocumentation
       -Wshift-sign-overflow
       -Wconditional-uninitialized
       -Wcomma
       -Wassign-enum
       -Wextra-semi
       -Wunreachable-code-aggressive
       -Wduplicate-enum
       -Wover-aligned
       -Wloop-analysis
       -Wreserved-identifier
       -Wdisabled-macro-expansion)
endif()

# The buffer-overlap checks are compiled in by default, and the header's #ifndef is what makes
# that the default. This exists so the other setting is one documented flag rather than a
# hand-written -D: it is the path nobody takes, so it is the one that rots. Both the library and
# the suite see it, since five cases only mean anything with the checks present.
option(DSP_CHECK_OVERLAP "Compile the buffer-overlap checks into dsp.c" ON)
if(NOT DSP_CHECK_OVERLAP)
  add_compile_definitions(DSP_CHECK_OVERLAP=0)
endif()

option(DSP_WEVERYTHING "Compile dsp.c under -Weverything, less the documented exceptions" OFF)
if(DSP_WEVERYTHING AND CMAKE_C_COMPILER_ID MATCHES "Clang")
  list(APPEND DSP_C_FLAGS
       -Weverything
       -Wno-padded
       -Wno-declaration-after-statement
       -Wno-unsafe-buffer-usage
       -Wno-pre-c11-compat
       -Wno-c99-compat
       -Wno-covered-switch-default
       # Fires on /usr/local/include, which CMake puts in the implicit include list on
       # macOS. It is about cross-compilation, not this code: an empty .c file trips it
       # identically. Without it the -Weverything gate cannot run on a host build here.
       -Wno-poison-system-directories)
endif()

# The test translation units get a warning set too. Without it the suite was the one part of
# the build nothing checked, and a test is as able to narrow a double silently as the library
# is. The C-only flags do not apply, and gtest's own headers trip -Wundef and -Wswitch-enum.
#
# -Wno-sign-conversion is the one deliberate hole, and only here. -Wconversion implies it, and
# in C++ it fires on every `std::vector<T>[int]` -- about 200 sites across this file, and a
# negative index is an immediate ASan abort, which is a gate this suite already runs under.
# Rewriting every loop index as size_t would make the arithmetic against
# the library's int counts worse to read for no finding. dsp.c itself is clean under the full
# -Wconversion, including the signedness half.
set(DSP_CXX_FLAGS
    -Wall
    -Wextra
    -Werror
    -Wconversion
    -Wno-sign-conversion
    -Wdouble-promotion
    -Wshadow
    -Wcast-qual
    -Wcast-align
    -Wpointer-arith
    -Wwrite-strings
    -Wvla
    -Wnon-virtual-dtor
    -Woverloaded-virtual
    -Wimplicit-fallthrough
    -Winit-self)
# Not -Wfloat-equal here: several tests assert bit-identity of two dsp_real spectra on purpose
# -- that a decomposition is repeatable, that a substituted plan is the kernel it substituted
# -- and an exact comparison is the assertion, not an accident.

# -ffp-contract=off everywhere. An FMA in the butterfly or in the gain-table sum makes the
# single build more accurate than a plain C compiler would, hiding the thing the two-variant
# build exists to measure, and it keeps the arithmetic identical on every host. It does not
# stop the target's compiler emitting a multiply-add for an expression written as one; it
# stops a host fusing a multiply and an add the source wrote separately.
set(DSP_FP_FLAGS -ffp-contract=off)

# -DDSP_SANITIZE=ON builds everything under ASan and UBSan. Separate from the warning set
# because the two find different things: the warnings are compile-time narrowing and shadowing,
# the sanitizers are the out-of-range double-to-int conversions and the arena overruns that a
# clean compile said nothing about. Both gates have to pass.
option(DSP_SANITIZE "Build with AddressSanitizer and UndefinedBehaviorSanitizer" OFF)
if(DSP_SANITIZE)
  # float-cast-overflow is not in the default UBSan set and is the check this code most
  # needs: an out-of-range double converted to int is reported by nothing else.
  set(DSP_SAN_FLAGS
      -fsanitize=address,undefined,float-divide-by-zero,float-cast-overflow
      -fno-omit-frame-pointer
      -fno-sanitize-recover=all
      -g)
  add_compile_options(${DSP_SAN_FLAGS})
  add_link_options(${DSP_SAN_FLAGS})
endif()

# -DDSP_COVERAGE=ON instruments the library for llvm-cov, so the claim about which lines the
# suite reaches is measured rather than asserted. Only dsp.c is instrumented; coverage of the
# test file itself is not a number that means anything.
option(DSP_COVERAGE "Instrument dsp.c for llvm-cov" OFF)
if(DSP_COVERAGE)
  set(DSP_COV_FLAGS -fprofile-instr-generate -fcoverage-mapping)
  add_link_options(-fprofile-instr-generate)
else()
  set(DSP_COV_FLAGS "")
endif()

# dsp.c compiled twice: dsp_real is float by default and double under DSP_DOUBLE. Both
# variants run the same test source, which scales its precision-dependent bounds off
# sizeof(dsp_real), so the suite measures what single precision costs rather than assuming
# it. The physics bounds -- sub-bin recovery, filter flatness, stopband -- are identical.
foreach(variant IN ITEMS single double)
  if(variant STREQUAL double)
    set(variant_def DSP_DOUBLE)
  else()
    set(variant_def DSP_SINGLE)
  endif()

  add_library(dsp_${variant} STATIC dsp.c)
  target_include_directories(dsp_${variant} PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
  target_compile_definitions(dsp_${variant} PUBLIC ${variant_def})
  target_compile_options(dsp_${variant} PRIVATE ${DSP_C_FLAGS} ${DSP_FP_FLAGS} ${DSP_COV_FLAGS})
  if(NOT MSVC)
    target_link_libraries(dsp_${variant} PUBLIC m)
  endif()

  add_executable(dsp_test_${variant} test/dsp_test.cc)
  target_link_libraries(dsp_test_${variant} PRIVATE dsp_${variant} GTest::gtest_main)
  target_compile_options(dsp_test_${variant} PRIVATE ${DSP_CXX_FLAGS} ${DSP_FP_FLAGS})
  add_test(NAME dsp_${variant} COMMAND dsp_test_${variant})

  # The same library through a C99 translation unit. DSP_RESTRICT expands to `restrict` here
  # and to nothing in C++, so without this the non-aliasing the interface promises is never
  # compiled the way the target will compile it, and 25 parameters carry a qualifier no test
  # exercises. It also proves the header is includable from C99 at all, which the C++ suite
  # cannot: a C++-only construct in the header would go unnoticed.
  add_executable(dsp_c99_${variant} test/dsp_c99_test.c)
  target_link_libraries(dsp_c99_${variant} PRIVATE dsp_${variant})
  target_compile_options(dsp_c99_${variant} PRIVATE ${DSP_C_FLAGS} ${DSP_FP_FLAGS})
  add_test(NAME dsp_c99_${variant} COMMAND dsp_c99_${variant})

  # The conformance driver: one case in, the figures the proposed TSP API would hand a
  # caller out. Deliberately not an add_test -- it proves nothing on its own, the comparison
  # against the Lua implementation is the test, and that lives in
  # notes/dsp-private/conform/run.py because it needs a Lua 5.0.2 and the tsp/ tree.
  # The FIR's cost against its source-record length, which is what DSP_FIR_MAXM bounds.
  # Not an add_test: it measures, it does not assert.
  add_executable(dsp_firbench_${variant} test/dsp_firbench.c)
  target_link_libraries(dsp_firbench_${variant} PRIVATE dsp_${variant})
  target_compile_options(dsp_firbench_${variant} PRIVATE ${DSP_C_FLAGS} ${DSP_FP_FLAGS})

  add_executable(dsp_conform_${variant} test/conform_driver.c)
  target_link_libraries(dsp_conform_${variant} PRIVATE dsp_${variant})
  target_compile_options(dsp_conform_${variant} PRIVATE ${DSP_C_FLAGS} ${DSP_FP_FLAGS})

  # The same sources with the band-pass compiled out. A build option nothing runs is a build
  # option that does not work: this one asserted band-pass behaviour in a build that has none
  # until it was given a gate of its own.
  add_library(dsp_${variant}_lp STATIC dsp.c)
  target_include_directories(dsp_${variant}_lp PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
  target_compile_definitions(dsp_${variant}_lp PUBLIC ${variant_def} DSP_BANDPASS=0)
  target_compile_options(dsp_${variant}_lp PRIVATE ${DSP_C_FLAGS} ${DSP_FP_FLAGS}
                                                   ${DSP_COV_FLAGS})
  if(NOT MSVC)
    target_link_libraries(dsp_${variant}_lp PUBLIC m)
  endif()

  add_executable(dsp_test_${variant}_lp test/dsp_test.cc)
  target_link_libraries(dsp_test_${variant}_lp PRIVATE dsp_${variant}_lp GTest::gtest_main)
  target_compile_options(dsp_test_${variant}_lp PRIVATE ${DSP_CXX_FLAGS} ${DSP_FP_FLAGS})
  add_test(NAME dsp_lowpass_${variant} COMMAND dsp_test_${variant}_lp)

  add_executable(dsp_c99_${variant}_lp test/dsp_c99_test.c)
  target_link_libraries(dsp_c99_${variant}_lp PRIVATE dsp_${variant}_lp)
  target_compile_options(dsp_c99_${variant}_lp PRIVATE ${DSP_C_FLAGS} ${DSP_FP_FLAGS})
  add_test(NAME dsp_c99_lowpass_${variant} COMMAND dsp_c99_${variant}_lp)

  # Deliberately not an add_test: a benchmark under ctest makes the suite slow and its
  # timings flaky. Build and run it by hand.
  add_executable(dsp_bench_${variant} test/dsp_bench.c)
  target_link_libraries(dsp_bench_${variant} PRIVATE dsp_${variant})
  target_compile_options(dsp_bench_${variant} PRIVATE ${DSP_C_FLAGS} ${DSP_FP_FLAGS})
endforeach()

# ---------------------------------------------------------------------------
# PPC cross-compilation target for the DMM6500 instrument.
#
# Prerequisites:
#   brew install powerpc-elf-binutils   # or crosstool-ng for a full toolchain
#
# Build the flat binary:
#   cmake -B build-ppc \
#         -DCMAKE_TOOLCHAIN_FILE=csrc/toolchain-ppc.cmake \
#         -DDSP_DST_NATIVE=ON
#   cmake --build build-ppc --target dsp_native_bin
#
# The output is build-ppc/dsp_native.bin (flat binary, entry at offset 0).
# ---------------------------------------------------------------------------
option(DSP_DST_NATIVE "Build dsp_native.c for the DMM6500 instrument" OFF)
if(DSP_DST_NATIVE)
  add_executable(dsp_native_elf
      dsp_native.c
      dsp.c)
  target_include_directories(dsp_native_elf PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
  target_compile_definitions(dsp_native_elf PUBLIC
      DSP_DOUBLE
      DSP_CHECK_OVERLAP=1   # keep the overlap checks; they catch aliasing bugs
      )
  target_compile_options(dsp_native_elf PRIVATE
      -Os -fno-common -Wno-int-to-pointer-cast
      -ffunction-sections  # lets the linker script place dsp_native_run first
      -Wall -Wextra -Wconversion -Wdouble-promotion
      -ffp-contract=off
      -fno-builtin)
  # Final link: -r retains relocations and cannot produce a working flat binary.
  # Use a final link with -nostdlib and --unresolved-symbols=report-all so any
  # unresolved external (e.g. libm functions in dsp.c) is a build error, not
  # a silent wrong-address branch.
  target_link_options(dsp_native_elf PRIVATE
      -T ${CMAKE_CURRENT_SOURCE_DIR}/dsp_native.ld
      -nostdlib
      -e dsp_native_run
      --no-dynamic-linker
      -Wl,--unresolved-symbols=report-all)
  # No -lm: dsp.c's math calls (floor, ceil, sqrt, sin, cos, log10) must be
  # satisfied by implementations in dsp_native.c itself, not from the host.
  # See csrc/README.md for the function-pointer-table approach.

  add_custom_command(
      OUTPUT dsp_native.bin
      COMMAND ${CMAKE_OBJCOPY} -O binary dsp_native_elf dsp_native.bin
      DEPENDS dsp_native_elf
      COMMENT "Producing flat binary dsp_native.bin")
  add_custom_target(dsp_native_bin ALL DEPENDS dsp_native.bin)
endif()
