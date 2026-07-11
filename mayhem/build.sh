#!/usr/bin/env bash
#
# hdf5/mayhem/build.sh — build the HDF5 file-format parser as sanitized libFuzzer targets
# (+ standalone reproducers) and a small self-contained golden oracle for mayhem/test.sh.
#
# Fuzzed surface = the HDF5 binary file-format reader. Both OSS-Fuzz harnesses write the input
# bytes to a temp file and call H5Fopen() (+ the extended one then H5Dopen2/H5Aopen_name), which
# drives the entire superblock/object-header/btree/heap/datatype decode path on attacker bytes.
#   h5_read_fuzzer     — strips a leading "decider" byte, then H5Fopen() + traverse.
#   h5_extended_fuzzer — raw input -> H5Fopen() -> H5Dopen2("dsetname") -> H5Aopen_name("theattr").
#
# We compile libhdf5 ITSELF with $SANITIZER_FLAGS so the parser (not just the harness) is
# instrumented. The build is kept light: static lib only, no HL/Fortran/C++/tools/examples/tests,
# threadsafe off, only the core C library + zlib filter.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# `=` (not `:=`) for SANITIZER_FLAGS so an explicit empty --build-arg builds with NO sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -g}"
# DEBUG_FLAGS: -gdwarf-3 keeps DWARF < 4 (§6.2 item 10); clang-19 plain -g emits DWARF-5.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${STANDALONE_FUZZ_MAIN:=$SRC/mayhem/harnesses/standalone_main.c}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS

cd "$SRC"

HARNESS_DIR="$SRC/mayhem/harnesses"
# -fsanitize=fuzzer-no-link gives the parser coverage instrumentation without pulling in the
# libFuzzer main (the harness/standalone driver supplies main / LLVMFuzzerTestOneInput).
FUZZ_COV="-fsanitize=fuzzer-no-link"

# ── 1) Build libhdf5.a WITH sanitizers + coverage (the fuzzed parser is instrumented) ──────────
BUILD="$SRC/mayhem-build"
mkdir -p "$BUILD"
# HDF5's CMake honors CMAKE_C_FLAGS for the library compile; pass our sanitizer+coverage flags there.
cmake -G "Unix Makefiles" -S "$SRC" -B "$BUILD" \
    -DCMAKE_BUILD_TYPE:STRING=RelWithDebInfo \
    -DCMAKE_C_COMPILER="$CC" \
    -DCMAKE_C_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS $FUZZ_COV" \
    -DBUILD_SHARED_LIBS:BOOL=OFF \
    -DBUILD_STATIC_LIBS:BOOL=ON \
    -DBUILD_TESTING:BOOL=OFF \
    -DHDF5_BUILD_EXAMPLES:BOOL=OFF \
    -DHDF5_BUILD_TOOLS:BOOL=OFF \
    -DHDF5_BUILD_UTILS:BOOL=OFF \
    -DHDF5_BUILD_HL_LIB:BOOL=OFF \
    -DHDF5_BUILD_CPP_LIB:BOOL=OFF \
    -DHDF5_BUILD_FORTRAN:BOOL=OFF \
    -DHDF5_BUILD_JAVA:BOOL=OFF \
    -DHDF5_ENABLE_THREADSAFE:BOOL=OFF \
    -DHDF5_ENABLE_PARALLEL:BOOL=OFF \
    -DHDF5_ENABLE_SZIP_SUPPORT:BOOL=OFF \
    -DHDF5_ENABLE_Z_LIB_SUPPORT:BOOL=ON \
    -DCMAKE_VERBOSE_MAKEFILE:BOOL=ON

cmake --build "$BUILD" --target hdf5-static -j"$MAYHEM_JOBS"

# Locate the freshly built static lib + the generated header dir (H5pubconf.h lands in build tree).
LIBHDF5="$(find "$BUILD" -name 'libhdf5.a' | head -1)"
[ -n "$LIBHDF5" ] || { echo "ERROR: libhdf5.a not found under $BUILD" >&2; exit 1; }
GEN_INC="$(dirname "$(find "$BUILD" -name 'H5pubconf.h' | head -1)")"
# hdf5.h pulls in H5FDsubfiling.h (the subfiling VFD public header lives in its own subdir).
INC="-I$SRC/src -I$GEN_INC -I$SRC/src/H5FDsubfiling"
echo "libhdf5.a = $LIBHDF5 ; generated headers = $GEN_INC"

# ── 2) Standalone run-once driver object (no libFuzzer runtime; reads one input file) ──────────
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$BUILD/standalone_main.o"

# ── 3) Build each OSS-Fuzz harness twice: libFuzzer (-> /mayhem/<name>) + standalone reproducer ─
mkdir -p /mayhem
for harness in h5_read_fuzzer h5_extended_fuzzer; do
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS $INC -std=c99 -c "$HARNESS_DIR/$harness.c" -o "$BUILD/$harness.o"

  # libFuzzer target -> /mayhem/<name>   (link with C++ driver since LIB_FUZZING_ENGINE is C++)
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE "$BUILD/$harness.o" "$LIBHDF5" -lz -ldl -lm \
      -o "/mayhem/$harness"

  # standalone reproducer (no libFuzzer runtime) -> /mayhem/<name>-standalone
  # $FUZZ_COV provides the sancov runtime stubs that the coverage-instrumented libhdf5.a references.
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS $FUZZ_COV "$BUILD/$harness.o" "$BUILD/standalone_main.o" "$LIBHDF5" \
      -lz -ldl -lm -o "/mayhem/$harness-standalone"

  echo "built $harness (+ standalone)"
done

# ── 4) Build the self-contained golden oracle for mayhem/test.sh (normal flags, separate obj) ──
# h5_golden.c creates a known .h5 (dataset "dsetname" + attribute "theattr"), reads them back and
# asserts the values, then asserts a corrupted file is rejected by H5Fopen. Links libhdf5.a.
# libhdf5.a is built with $SANITIZER_FLAGS + $FUZZ_COV, so the oracle must link the same runtimes
# (ASan/UBSan + the sancov stubs) to resolve __asan_*/__sanitizer_cov_* references in the library.
env -u CFLAGS -u CXXFLAGS \
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS $FUZZ_COV -O1 $INC -std=c99 "$HARNESS_DIR/../h5_golden.c" "$LIBHDF5" \
  -lz -ldl -lm -o "$BUILD/h5_golden"
echo "built golden oracle -> $BUILD/h5_golden"

echo "build.sh complete:"
ls -la /mayhem/h5_read_fuzzer /mayhem/h5_extended_fuzzer \
       /mayhem/h5_read_fuzzer-standalone /mayhem/h5_extended_fuzzer-standalone 2>&1 || true
