#!/usr/bin/env bash
#
# mayhem/test.sh — RUN wget2's own functional suites built by mayhem/build.sh (normal flags):
#   * unit-tests/*: known-answer programs that print "Summary: All N tests passed" — N is asserted.
#   * tests/test-*: end-to-end wget2 runs against a local libmicrohttpd server, comparing the
#     downloaded files / exit codes with expected ones (exit 77 = skipped).
# The HTTP/2 tests listed below cannot connect inside the build container (TLS connect error before any
# request is made, identical on a pristine upstream build), so they are not run.
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

B="$SRC/mayhem/build-test"
SKIP_HTTP2="test-limit-rate-http2 test-http2-multiplexing test-http2-stream-errors test-http2-connection-errors test-http2-settings"
# test-redirection/test-waitretry read their own stdout back from ../<name>.log (as automake captures it).
LOGDIR="$B/tests"
passed=0; failed=0; skipped=0

# unit-tests: need the per-program "Summary: All N tests passed" line with N > 0 (test-cond only has an exit status).
for t in test test-parse-html test-html-get-urls test-decompress test-http-parse; do
  prog="$B/unit-tests/$t"
  if [ ! -x "$prog" ]; then echo "FAIL $t: $prog missing (build.sh bug)"; failed=$((failed+1)); continue; fi
  out=$(cd "$B/unit-tests" && "$prog" 2>&1); rc=$?
  n=$(printf '%s\n' "$out" | sed -n 's/^Summary: All \([0-9][0-9]*\) tests passed$/\1/p' | tail -1)
  if [ "$rc" -eq 0 ] && [ -n "$n" ] && [ "$n" -gt 0 ]; then echo "PASS $t ($n assertions)"; passed=$((passed+1))
  else echo "FAIL $t (rc=$rc)"; printf '%s\n' "$out" | tail -5; failed=$((failed+1)); fi
done
prog="$B/unit-tests/test-cond"
if [ -x "$prog" ] && (cd "$B/unit-tests" && "$prog" >/dev/null 2>&1); then echo "PASS test-cond"; passed=$((passed+1))
else echo "FAIL test-cond"; failed=$((failed+1)); fi

# tests/: run every built test program in parallel; 0 = pass, 77 = skip.
tests=()
for p in "$B"/tests/test-*; do
  [ -f "$p" ] && [ -x "$p" ] || continue
  n=$(basename "$p"); case " $SKIP_HTTP2 " in *" $n "*) continue;; esac
  tests+=("$n")
done
if [ "${#tests[@]}" -lt 50 ]; then echo "FAIL: only ${#tests[@]} tests/ programs built (build.sh bug)"; failed=$((failed+1)); fi
printf '%s\n' "${tests[@]}" | xargs -P "$MAYHEM_JOBS" -I{} bash -c \
  'cd "$1/tests" && SRCDIR="$4/tests" BUILDDIR=.. timeout 300 "./$2" >"$3/$2.log" 2>&1; echo $? >"$3/$2.rc"' _ "$B" {} "$LOGDIR" "$SRC"
for n in "${tests[@]}"; do
  rc=$(cat "$LOGDIR/$n.rc" 2>/dev/null || echo 255)
  case "$rc" in
    0)  passed=$((passed+1));;
    77) skipped=$((skipped+1));;
    *)  echo "FAIL $n (rc=$rc)"; tail -5 "$LOGDIR/$n.log"; failed=$((failed+1));;
  esac
done
emit_ctrf wget2-tests "$passed" "$failed" "$skipped"
