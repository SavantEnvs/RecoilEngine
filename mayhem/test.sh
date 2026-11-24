#!/usr/bin/env bash
#
# mayhem/test.sh — RUN the functional suite mayhem/build.sh built: upstream's Catch2 unit tests
# for the fuzzed code (test_LoadSave: creg serializer save/load round trip; test_QuadField: ray
# traversal vs a brute-force reference) plus our known-answer test (test_GameDataUri: GameData
# pack/unpack and spring:// / rapid:// parsing). exit 0 = pass.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
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

BIN="$SRC/mayhem/build/bin"
passed=0; failed=0
for name in LoadSave QuadField GameDataUri; do
  exe="$BIN/test_$name"
  if [ ! -x "$exe" ]; then
    echo "test.sh: $exe missing — run mayhem/build.sh first" >&2
    failed=$((failed + 1)); continue
  fi
  out="$("$exe" --reporter junit 2>&1)"; rc=$?
  cases=$(grep -c '<testcase ' <<<"$out")
  fails=$(grep -c '<failure\|<error' <<<"$out")
  if [ "$rc" -ne 0 ] || [ "$cases" -eq 0 ]; then
    echo "test.sh: test_$name FAILED (rc=$rc, $cases test cases, $fails failures)"
    printf '%s\n' "$out" | tail -40
    failed=$((failed + (fails > 0 ? fails : 1)))
    passed=$((passed + (cases > fails ? cases - fails : 0)))
  else
    echo "test.sh: test_$name passed ($cases test cases)"
    passed=$((passed + cases))
  fi
done
emit_ctrf "catch2" "$passed" "$failed" 0
