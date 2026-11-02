cmake_minimum_required(VERSION 3.14)
project(dmm6500_dsp C CXX)

set(CMAKE_C_STANDARD 99)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS OFF)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE MinSizeRel CACHE STRING "" FORCE)
endif()

# googletest only in a host tree. The PPC tree has no hosted C++ runtime to link it against,
# and a gtest binary built for powerpc-unknown-elf could not be run anyway.
if(NOT CMAKE_CROSSCOMPILING)
  include(FetchContent)
  FetchContent_Declare(
    googletest
    GIT_REPOSITORY https://github.com/google/googletest.git
    GIT_TAG v1.15.2
    GIT_SHALLOW TRUE)
  set(gtest_force_shared_crt ON CACHE BOOL "" FORCE)
  set(INSTALL_GTEST OFF CACHE BOOL "" FORCE)
  FetchContent_MakeAvailable(googletest)
endif()

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

# Everything from here to the PPC section is host-only: it is compiled to be run, and a
# cross tree cannot run it. Registering it there put nine permanent failures in the cross
# tree's ctest output, which is how a red gate stops being read.
if(NOT CMAKE_CROSSCOMPILING)

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

# The address bounds the native entry point guards every write with. A host test,
# deliberately: the instrument cannot be asked whether a write to a device register is
# refused without performing it when the answer is no. Built for the host even when the
# PPC target is not configured, because this is the gate that runs before instrument time.
add_executable(dsp_native_bounds_test test/dsp_native_bounds_test.cc)
target_include_directories(dsp_native_bounds_test PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
target_link_libraries(dsp_native_bounds_test PRIVATE GTest::gtest_main)
target_compile_options(dsp_native_bounds_test PRIVATE ${DSP_CXX_FLAGS})
add_test(NAME dsp_native_bounds COMMAND dsp_native_bounds_test)

endif()  # NOT CMAKE_CROSSCOMPILING

# The relocation applier runs on the instrument under Lua 5.0.2, where a wrong patch is a
# silently wrong address rather than a failure. Its checks run against hand-computed
# answers, including the ADDR16_HA carry boundary. Not gated on the PPC target: it tests
# Lua, and it is a gate that should run on every build.
find_program(LUA502 lua HINTS $ENV{HOME}/tmp/lua502/lua-5.0.2/bin NO_DEFAULT_PATH)
if(LUA502)
  add_test(NAME relocate_applier
           COMMAND ${LUA502} ${CMAKE_CURRENT_SOURCE_DIR}/tools/test_relocate.lua)

  # The app's own suite, which loads the REAL tsp/*.tsp against a mock of the instrument
  # API -- 456 assertions including the object-lifetime invariant and a direct DFT against
  # the shipped transform. It was runnable by hand and in no gate, so a change to
  # spectrum_app.tsp could pass everything this file knew about. It needs the repo root as
  # its working directory, because it loads the modules by relative path.
  add_test(NAME app_tsp
           COMMAND ${LUA502} tools/test_tsp.lua
           WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}/..)
else()
  message(STATUS "Lua 5.0.2 not found; the relocate_applier and app_tsp gates will not run")
endif()

# The picker index and DSP_WINDOW_* are different numbers that currently coincide, and
# native_link.tsp carries a hand-maintained map between them. A hand-maintained map is
# worth only what checks it: a renumbered enumerator would select the wrong window with
# nothing on the glass to say so, every amplitude out by a scalloping factor. Not gated on
# the PPC target, and not on the host either -- it compares two text files.
find_package(Python3 COMPONENTS Interpreter QUIET)
if(Python3_Interpreter_FOUND)
  add_test(NAME window_enum
           COMMAND ${Python3_EXECUTABLE} -I
                   ${CMAKE_CURRENT_SOURCE_DIR}/tools/check_window_enum.py
                   --root ${CMAKE_CURRENT_SOURCE_DIR}/..)

  # dsp_native_params is a wire format: Lua writes a flat sequence of big-endian words and
  # dsp_native_run reads a struct. A field added, removed or moved on one side only shifts
  # every word after it, so the entry point reads one heap address where another was meant
  # -- which passes the bounds test and is simply wrong. Field for field, by name.
  add_test(NAME params_layout
           COMMAND ${Python3_EXECUTABLE} -I
                   ${CMAKE_CURRENT_SOURCE_DIR}/tools/check_params_layout.py)
  add_test(NAME params_layout_selftest
           COMMAND ${Python3_EXECUTABLE} -I
                   ${CMAKE_CURRENT_SOURCE_DIR}/tools/check_params_layout.py --self-test)

  # Every double that crosses to the native side -- the bin width, the decibel window, the
  # voltage floor -- goes as the word pair the Lua packer builds, and comes back through the
  # reader nl.results() decodes the peaks with. A fault in either is a plausible wrong
  # number rather than a refusal. Needs Lua 5.0.2, whose math.frexp is the instrument's.
  if(LUA502)
    add_test(NAME f64_pack
             COMMAND ${Python3_EXECUTABLE} -I
                     ${CMAKE_CURRENT_SOURCE_DIR}/tools/check_f64.py)

    # The archive carries the image as base64, so there is a decoder between the compiler
    # and the CPU. A wrong byte there is not a failure to load: it is one instruction or
    # one float constant quietly different, which relocation then places perfectly.
    add_test(NAME b64_blob
             COMMAND ${Python3_EXECUTABLE} -I
                     ${CMAKE_CURRENT_SOURCE_DIR}/tools/check_b64.py)
    add_test(NAME b64_blob_selftest
             COMMAND ${Python3_EXECUTABLE} -I
                     ${CMAKE_CURRENT_SOURCE_DIR}/tools/check_b64.py --self-test)
    # Every point on the spectrum crosses to the graph through nl.reduce: the compiled path
    # fills two arrays in the arena and the frame writes them with buffer.write.reading.
    # A value decoded wrong there is a plausible wrong trace, and a nil reaching that call
    # is a posted event per point.
    add_test(NAME reduce
             COMMAND ${Python3_EXECUTABLE} -I
                     ${CMAKE_CURRENT_SOURCE_DIR}/tools/check_reduce.py)
    add_test(NAME reduce_selftest
             COMMAND ${Python3_EXECUTABLE} -I
                     ${CMAKE_CURRENT_SOURCE_DIR}/tools/check_reduce.py --self-test)
    # The cache-flush routine is the one firmware address the native path cannot be handed
    # and cannot do without, so it is found by what it does -- dcbst over the range, icbi
    # over the same range, isync before returning. Pinning it to one build makes a firmware
    # upgrade a branch into whatever occupies that address now, which bluescreens.
    add_test(NAME find_flush
             COMMAND ${Python3_EXECUTABLE} -I
                     ${CMAKE_CURRENT_SOURCE_DIR}/tools/check_findflush.py)
    add_test(NAME find_flush_selftest
             COMMAND ${Python3_EXECUTABLE} -I
                     ${CMAKE_CURRENT_SOURCE_DIR}/tools/check_findflush.py --self-test)
    set_tests_properties(f64_pack b64_blob b64_blob_selftest reduce reduce_selftest
                         find_flush find_flush_selftest
                         PROPERTIES ENVIRONMENT "LUA502=${LUA502}")
  endif()
endif()

# ---------------------------------------------------------------------------
# PPC cross-compilation target for the DMM6500 instrument.
#
# Prerequisites. Two separate Homebrew formulae: llvm supplies the PPC backend Apple clang
# does not have, and lld supplies ld.lld, which the toolchain file invokes directly.
#   brew install llvm lld
#
# Build the flat binary. CMAKE_TOOLCHAIN_FILE has to be absolute -- CMake resolves a
# relative one against the build directory rather than the source directory.
#   cmake -B build-ppc -S csrc \
#         -DCMAKE_TOOLCHAIN_FILE=$PWD/csrc/toolchain-ppc-clang.cmake \
#         -DDSP_DST_NATIVE=ON
#   cmake --build build-ppc
#
# The output is build-ppc/dsp_native.bin (flat binary, entry at offset 0), plus
# dsp_native_reloc.lua. tools/embed_native.py turns both into tsp/native_code.tsp.
# ---------------------------------------------------------------------------
option(DSP_DST_NATIVE "Build dsp_native.c for the DMM6500 instrument" OFF)
if(DSP_DST_NATIVE)
  add_executable(dsp_native_elf
      dsp_native.c
      dsp.c)
  # freestanding/ first: the bare powerpc-unknown-elf triple ships no C library headers,
  # so <math.h> and <string.h> come from there. They declare only what dsp.c calls, and
  # dsp_native.c defines every one of them.
  target_include_directories(dsp_native_elf PUBLIC
      ${CMAKE_CURRENT_SOURCE_DIR}/freestanding
      ${CMAKE_CURRENT_SOURCE_DIR})
  # Single precision, which is dsp_real's default. The e300c4 issues and completes a
  # single-precision multiply-add every cycle where a double takes several, and every array
  # the transform sweeps halves, so single is the arithmetic fast path and the bandwidth one
  # at once. Add DSP_DOUBLE back to build the same code in double; the host suite runs both
  # variants, and nl.SIZEOF_REAL comes out of the image, so the Lua read-back follows
  # whichever is built without being told.
  #
  # DSP_NO_SINGLE_MATH because the transcendentals have to stay on the double entry points:
  # the six firmware addresses are discovered by FNF from Lua's own math wrappers, and there
  # is no math.sinf to discover, so sinf/cosf/sqrtf/log10f could only come from addresses
  # typed in here. It costs nothing that matters -- sin and cos run once a plan building the
  # window and the twiddles, and log10 runs once a trace point either way -- and computing
  # the window in double before storing it to float is the accurate direction.
  target_compile_definitions(dsp_native_elf PUBLIC
      DSP_NO_SINGLE_MATH
      DSP_CHECK_OVERLAP=1   # keep the overlap checks; they catch aliasing bugs
      )
  target_compile_options(dsp_native_elf PRIVATE
      -Os -fno-common -Wno-int-to-pointer-cast
      -ffunction-sections  # lets the linker script place dsp_native_run first
      -Wall -Wextra -Wconversion -Wdouble-promotion
      -ffp-contract=off
      -fno-builtin)
  # --unresolved-symbols=report-all so a libm call dsp.c makes that dsp_native.c does not
  # define is a build error rather than a branch to address zero.
  #
  # --emit-relocs keeps the .rela sections in the linked image. They are what
  # emit_reloc.py turns into the table the Lua loader applies: the image carries 355
  # absolute data references, and without the table every float constant, the error
  # string table and dsp_wincos read from the link-time address instead of the load
  # address. Do not strip, and do not drop this flag.
  # Plain ld.lld flags: the toolchain file links with ld.lld directly, not through the
  # clang driver, so there is no -Wl, wrapping here and no -nostdlib to ask for.
  target_link_options(dsp_native_elf PRIVATE
      -T ${CMAKE_CURRENT_SOURCE_DIR}/dsp_native.ld
      -e dsp_native_run
      --no-dynamic-linker
      --unresolved-symbols=report-all
      --emit-relocs)

  find_package(Python3 COMPONENTS Interpreter REQUIRED)
  add_custom_command(
      OUTPUT dsp_native.bin dsp_native_reloc.lua
      COMMAND ${Python3_EXECUTABLE}
              ${CMAKE_CURRENT_SOURCE_DIR}/tools/emit_reloc.py
              $<TARGET_FILE:dsp_native_elf>
              --stem ${CMAKE_CURRENT_BINARY_DIR}/dsp_native
      DEPENDS dsp_native_elf ${CMAKE_CURRENT_SOURCE_DIR}/tools/emit_reloc.py
      COMMENT "Emitting dsp_native.bin and its relocation table")
  add_custom_target(dsp_native_bin ALL DEPENDS dsp_native.bin dsp_native_reloc.lua)

  # The relocation applier against the linker as an independent oracle: link the same
  # objects at the load address and require the applier's output to be byte-identical.
  # This is not redundant with the Lua unit checks -- those compared the applier against
  # hand-computed expectations that shared its own wrong idea of where an ADDR16 field
  # sits, so they passed while the emitted table was off by two bytes on every one of 427
  # entries. The oracle caught it on the first run.
  add_test(NAME reloc_vs_linker
           COMMAND ${Python3_EXECUTABLE}
                   ${CMAKE_CURRENT_SOURCE_DIR}/tools/check_reloc.py
                   --build ${CMAKE_CURRENT_BINARY_DIR}
                   --objdir ${CMAKE_CURRENT_BINARY_DIR}/CMakeFiles/dsp_native_elf.dir)
endif()
