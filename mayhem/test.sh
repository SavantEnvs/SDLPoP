#!/usr/bin/env bash
#
# mayhem/test.sh — SDLPoP's own replay regression testcases (doc/replays-testcases/*.p1r), replayed
# headless with the oracle build (mayhem/out-test/prince, upstream's normal flags). exit 0 = pass. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
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

# Each upstream testcase replay is played with `prince validate <replay>` (no window, no sound;
# the game simulates every tick and prints where the replay started/ended, whether the kid is alive,
# the remaining time and the play duration). Those lines are compared exactly against
# mayhem/test-golden/<name>.txt — a known-answer test of the replay loader, savestate restore and the
# game logic (movement, collisions, guards, timers). A neutered binary prints nothing and fails.
export SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy
BIN="$SRC/mayhem/out-test/prince"
[ -x "$BIN" ] || { echo "missing $BIN (build.sh must build it)" >&2; emit_ctrf "sdlpop-replay-golden" 0 1; exit 1; }
passed=0; failed=0
for f in "$SRC"/doc/replays-testcases/*.p1r; do
  name=$(basename "$f" .p1r | tr -c 'A-Za-z0-9\n' '_')
  golden="$SRC/mayhem/test-golden/$name.txt"
  # timeout: an unreadable replay makes prince fall back to the interactive game loop forever.
  out=$(timeout 120 "$BIN" validate "$f" 2>/dev/null | grep -E '^(Replay started|Replay ended|Kid is|Remaining time|Play duration)')
  if [ -f "$golden" ] && [ "$out" = "$(cat "$golden")" ]; then
    passed=$((passed+1)); echo "PASS $name"
  else
    failed=$((failed+1)); echo "FAIL $name"; diff <(echo "$out") "$golden" || true
  fi
done
# Every golden must have been exercised (a vanished testcase is a failure, not a skip).
ngold=$(ls "$SRC"/mayhem/test-golden/*.txt | wc -l)
[ $((passed+failed)) -eq "$ngold" ] || { echo "ran $((passed+failed)) of $ngold golden testcases"; failed=$((failed+1)); }
emit_ctrf "sdlpop-replay-golden" "$passed" "$failed"
