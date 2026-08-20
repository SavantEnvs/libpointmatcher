#!/usr/bin/env bash
#
# mayhem/test.sh — RUN libpointmatcher's gtest unit-test suite (`utest`), already built by
# mayhem/build.sh with the project's normal flags. Asserts BEHAVIOR (gtest EXPECT/ASSERT over the
# IO/CSV/VTK parsers, data filters, matchers, ICP, etc.) — a no-op/exit(0) PATCH fails it.
# Emits a CTRF (https://ctrf.io) summary and exits non-zero iff a test failed.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"
cd "$SRC"

emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
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

UTEST="$SRC/build-tests/utest/utest"
[ -x "$UTEST" ] || { echo "FATAL: $UTEST missing — mayhem/build.sh did not build the test suite" >&2; emit_ctrf "gtest" 0 1 0; exit 1; }

# utest takes the example-data path (its IO tests load real point clouds from examples/data/).
# NB: no `set -e` here (matching the template) — a grep that finds no match returns non-zero,
# which under pipefail would otherwise abort the script before we emit the CTRF report.
LOG=/tmp/utest.log
"$UTEST" --path "$SRC/examples/data/" 2>&1 | tee "$LOG"

# Parse gtest's summary lines:
#   [==========] N tests from M test suites ran.
#   [  PASSED  ] P tests.
#   [  FAILED  ] F tests, listed below:   (absent when F==0)
total=$(grep -oE '\[==========\] [0-9]+ tests? from' "$LOG"  | tail -1 | grep -oE '[0-9]+' | head -1 || true)
passed=$(grep -oE '\[  PASSED  \] [0-9]+ tests?' "$LOG"      | tail -1 | grep -oE '[0-9]+' | head -1 || true)
failed=$(grep -oE '\[  FAILED  \] [0-9]+ tests?' "$LOG"      | tail -1 | grep -oE '[0-9]+' | head -1 || true)
: "${total:=0}" "${passed:=0}" "${failed:=0}"

# If gtest printed no PASSED line at all, the runner crashed/aborted — treat as a hard failure.
if ! grep -q '\[==========\].*ran\.' "$LOG"; then
  echo "FATAL: utest did not complete a run (crash/abort?)" >&2
  emit_ctrf "gtest" "$passed" "$(( failed > 0 ? failed : 1 ))"
  exit 1
fi

emit_ctrf "gtest" "$passed" "$failed"
