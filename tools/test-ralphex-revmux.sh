#!/usr/bin/env bash
# The ralphex -> revmux bridge, driven for real: tools/ralphex-revmux.sh runs with a stub
# `revmux` first on PATH and RALPHEX_REVMUX_DRY_RUN=1, which stops the script once the
# round is open and the scope written.
#
# That window is the whole subject. The bridge's trap prints <<<RALPHEX:CODEX_REVIEW_DONE>>>
# and exits 0 on every path, deliberately - ralphex would otherwise sit out its idle_timeout
# on a review that already finished. The cost is that a bridge which never opened a round
# looks exactly like a review that found nothing. So the failure paths are worth pinning:
# how many times a refused run name is retried, and whether revmux's explanation survives
# to stderr.
#
# The stub refuses in revmux's own words, taken from the binary. A refusal authored to
# satisfy whatever the bridge looks for is how a retry condition that matched nothing
# looked tested for a week in agwinterm.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
BRIDGE="$ROOT/tools/ralphex-revmux.sh"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP/bin"

# Verbatim revmux refusals for a run name it will not open. None of them contains
# "already exists", "duplicate" or "collision".
cat > "$TMP/bin/revmux" <<'FAKE_REVMUX'
#!/usr/bin/env bash
set -u
[ "${1:-}" = "new" ] || exit 0
RUN=""
while [ $# -gt 0 ]; do [ "$1" = "--run" ] && RUN="${2:-}"; shift; done
printf '%s\n' "$RUN" >> "$FAKE_ROOT/calls.log"
ATTEMPT="${RUN##*-}"
refuse() { printf '%s\n' "${1//%RUN%/$RUN}" >&2; exit 1; }
case "${STUB_MODE:-accept}" in
  collide) [ "$ATTEMPT" = 1 ] && refuse 'round %RUN% is being written by a run holding it: two runs sharing a round truncate each other'"'"'s artifacts, so open a new round instead' ;;
  taken)
    case "$ATTEMPT" in
      1) refuse 'round %RUN% has already run, report.md is in place: a round that went badly is exactly the one a later reflection agent reads, so it is never reused' ;;
      2) refuse 'round %RUN% is being written by a run holding it: two runs sharing a round truncate each other'"'"'s artifacts, so open a new round instead' ;;
      *) refuse 'round %RUN% was claimed by a run that never came back and still holds what it wrote (findings.json): re-using it would put two runs'"'"' artifacts under one round, so open a new round instead' ;;
    esac ;;
  fail) refuse 'profile "comprehensive", have expert' ;;
esac
# One key per line: the bridge's pluck is a greedy sed capture and cannot read a
# single-line object.
printf '{\n  "scope": "%s",\n  "profile": "%s"\n}\n' "$FAKE_ROOT/scope.md" "$FAKE_ROOT/profile.md"
FAKE_REVMUX
chmod +x "$TMP/bin/revmux"

printf 'Review docs/plans/20260826-example-plan.md against the diff.\n' > "$TMP/prompt.txt"

# Runs the bridge in mode $1. Bounded by coreutils timeout, which signals the whole MSYS
# process group - a bridge whose retry loop lost its bound must die here, not outlive
# the test.
run_bridge() {
  local mode="$1"
  rm -f -- "$TMP/calls.log" "$TMP/scope.md" "$TMP/profile.md"
  set +e
  STUB_MODE="$mode" FAKE_ROOT="$TMP" PATH="$TMP/bin:$PATH" RALPHEX_REVMUX_DRY_RUN=1 \
    timeout -s KILL 60 bash "$BRIDGE" "$TMP/prompt.txt" > "$TMP/$mode.out" 2> "$TMP/$mode.err"
  status=$?
  set -e
  [ "$status" -ne 137 ] || { echo "[$mode] the bridge did not terminate within 60s" >&2; exit 1; }
}
calls() { [ -f "$TMP/calls.log" ] && wc -l < "$TMP/calls.log" | tr -d ' ' || echo 0; }
distinct() { sort -u "$TMP/calls.log" | wc -l | tr -d ' '; }
fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { grep -Fq -- "$2" "$1" || fail "missing '$2' in $(basename "$1")"; }

# 1. A round opens, the scope is written, ralphex is released.
run_bridge accept
[ "$status" -eq 0 ] || fail "accept: exit $status"
assert_contains "$TMP/accept.out" '<<<RALPHEX:CODEX_REVIEW_DONE>>>'
[ "$(calls)" -eq 1 ] || fail "accept: $(calls) revmux new calls, want 1"
[ -f "$TMP/scope.md" ] || fail "accept: scope was not written"
assert_contains "$TMP/scope.md" '20260826-example-plan.md'

# 2. The run name is not just the second the review started in - that is the shape
#    that collided: two reviews of one plan in the same second ask for one name.
name="$(head -1 "$TMP/calls.log")"
case "$name" in
  [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]) fail "run name is a bare timestamp: $name" ;;
  [0-9]*-[0-9]*-[0-9]*-[0-9]*-1) ;;
  *) fail "unexpected run name shape: $name" ;;
esac

# 3. A taken name is retried under a fresh one, not reported as a clean review.
run_bridge collide
[ "$status" -eq 0 ] || fail "collide: exit $status"
[ "$(calls)" -eq 2 ] || fail "collide: $(calls) calls, want 2 (refused once, then retried)"
[ "$(distinct)" -eq 2 ] || fail "collide: the retry reused the refused name"
case "$(tail -1 "$TMP/calls.log")" in *-2) ;; *) fail "collide: retry did not carry attempt 2" ;; esac
[ -f "$TMP/scope.md" ] || fail "collide: the round did not open on the retry"

# 4. A name refused three times gives up bounded, with distinct names, and says why.
run_bridge taken
[ "$(calls)" -eq 3 ] || fail "taken: $(calls) calls, want 3 (the attempt cap)"
[ "$(distinct)" -eq 3 ] || fail "taken: an attempt reused a run name already refused"
[ ! -f "$TMP/scope.md" ] || fail "taken: a scope was written with no round open"
assert_contains "$TMP/taken.err" 'was claimed by a run that never came back'
assert_contains "$TMP/taken.err" 'revmux new failed after 3 attempts'
[ "$status" -eq 0 ] || fail "taken: exit $status, want 0 (the trap releases ralphex regardless)"
assert_contains "$TMP/taken.out" '<<<RALPHEX:CODEX_REVIEW_DONE>>>'

# 5. revmux's own explanation reaches stderr when the round cannot open. Without it the
#    progress log says "revmux new failed" and never which refusal, and a misconfigured
#    panel cannot be told from a transient collision without opening the round directory.
run_bridge fail
assert_contains "$TMP/fail.err" 'profile "comprehensive", have expert'
assert_contains "$TMP/fail.err" 'ralphex-revmux: revmux new failed'
[ "$status" -eq 0 ] || fail "fail: exit $status, want 0"
assert_contains "$TMP/fail.out" '<<<RALPHEX:CODEX_REVIEW_DONE>>>'

echo 'ralphex-revmux bridge tests passed'
