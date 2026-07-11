#!/usr/bin/env bash
#
# hdf5/mayhem/test.sh — RUN the self-contained golden oracle built by mayhem/build.sh and emit a
# CTRF summary. exit 0 iff the oracle passes.
#
# PATCH-grade oracle: mayhem/h5_golden creates a known .h5 (dataset "dsetname" + attribute
# "theattr"), reopens it and asserts the read-back values byte-for-byte, then asserts a file with a
# corrupted superblock is REJECTED by H5Fopen. This is the exact open/read path the fuzzers drive,
# so a no-op / exit(0) patch (or any change that breaks encode/decode round-trip or the reject
# path) cannot pass. This script only RUNS the pre-built binary; it never compiles. Fast (< 1s).
#
# HDF5's own ctest suite is huge and slow (minutes, hundreds of MB of fixtures), so we use the
# focused golden oracle instead of `ctest`.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "${SRC:-/mayhem}"

GOLDEN="${SRC:-/mayhem}/mayhem-build/h5_golden"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-${SRC:-/mayhem}/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

if [ ! -x "$GOLDEN" ]; then
  echo "missing $GOLDEN — run mayhem/build.sh first" >&2
  emit_ctrf "h5-golden" 0 1 0; exit 2
fi

echo "=== running HDF5 golden oracle ==="
out="$("$GOLDEN" 2>&1)"; rc=$?
echo "$out"

# Assert behavior (output), not just exit code — a no-op/exit(0) neuter produces no output and
# fails the grep, so the sabotage check cannot slip through. The oracle prints exactly this string
# when the round-trip dataset+attribute pass and the corrupt-superblock rejection works.
if [ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -qF "GOLDEN PASS: round-trip dataset+attribute OK; corrupted superblock rejected"; then
  emit_ctrf "h5-golden" 1 0 0
else
  echo "ORACLE FAIL: expected 'GOLDEN PASS' output not found (rc=$rc)" >&2
  emit_ctrf "h5-golden" 0 1 0
fi
