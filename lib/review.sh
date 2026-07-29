#!/usr/bin/env bash
# Independent review of a task's diff by a DIFFERENT model than the builder.
#
#   review.sh <task-file.md> [git-ref]
#
# Backend is chosen by $AUTOPILOT_REVIEWER (default: subagent):
#   subagent  → no external model available; exit 10 so the skill reviews in-session
#   codex     → pipe the review prompt to the codex CLI, expect JSON on stdout
#   <other>   → $AUTOPILOT_REVIEWER_CMD is run as the backend (reads prompt on stdin,
#               writes the JSON verdict on stdout) — used for custom models and tests
#
# On a real external review it prints the validated JSON verdict and exits 0.
# Exit 10 = "no external reviewer, fall back to the subagent". Other non-zero = error.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/common.sh"

TASK="${1:?usage: review.sh <task-file.md> [git-ref]}"; REF="${2:-HEAD}"
[ -f "$TASK" ] || ap_die "no such task file: $TASK"

backend="${AUTOPILOT_REVIEWER:-subagent}"
[ "$backend" = subagent ] && exit 10        # nothing external — skill uses the subagent

root="$(ap_root)"
# ponytail: full diff; if it overflows the reviewer's context, split the task instead.
diff="$(git -C "$root" diff "$REF" 2>/dev/null)"
[ -z "$diff" ] && ap_die "no changes to review against $REF" 2

# Build the prompt in a temp file. Plain heredocs only — no $(cat <<EOF) wrapping,
# which macOS bash mis-parses; and file/diff content is written, never shell-parsed.
prompt_file="$(mktemp)"; trap 'rm -f "$prompt_file"' EXIT
cat > "$prompt_file" <<'EOF'
You are an INDEPENDENT reviewer. You did NOT write this code. Judge it against the task.
Be adversarial: assume it is wrong until the diff proves otherwise.

Return ONLY JSON, no prose, matching exactly:
{"status":"APPROVED|CHANGES_REQUESTED|RISKY|SCOPE_EXPANSION_REQUIRED",
 "required_checks_passed":true|false,
 "findings":[{"file":"","line":1,"issue":"","required_correction":""}],
 "summary":""}

Rules:
- APPROVED only if every acceptance criterion is met and the diff stays within ## Allowed Files.
- CHANGES_REQUESTED for defects, missing tests, out-of-scope edits, weakened security boundaries.
- RISKY if the change is unsafe to keep (hidden regression, data loss, security hole) — the runner reverts it.
- SCOPE_EXPANSION_REQUIRED only if the task genuinely cannot be done inside ## Allowed Files;
  list each needed repo-relative path in a finding.
- Enforce ## Docs Impact: a full-durable task must update every durable doc it names and
  keep them internally consistent; a no-doc task must not touch durable docs; broad docs
  must not carry another doc's facts or implementation narration.
- The gate already proved completion. You catch what a green gate cannot: security, design, regressions, scope.
EOF
{ printf '\n===== TASK =====\n'; cat "$TASK"
  printf '\n===== DIFF (git diff %s) =====\n%s\n' "$REF" "$diff"; } >> "$prompt_file"

run_backend() {
  case "$backend" in
    codex)
      command -v codex >/dev/null 2>&1 || { ap_warn "codex not on PATH — falling back to subagent"; return 10; }
      codex exec -C "$root" -s read-only \
        ${AUTOPILOT_REVIEWER_MODEL:+-m "$AUTOPILOT_REVIEWER_MODEL"} - < "$prompt_file" 2>/dev/null ;;
    *)
      [ -n "${AUTOPILOT_REVIEWER_CMD:-}" ] || { ap_die "unknown reviewer '$backend' and no AUTOPILOT_REVIEWER_CMD"; }
      eval "$AUTOPILOT_REVIEWER_CMD" < "$prompt_file" ;;
  esac
}

out="$(run_backend)"; rc=$?
[ "$rc" -eq 10 ] && exit 10
[ "$rc" -eq 0 ] || ap_die "reviewer backend '$backend' failed (rc=$rc)" "$rc"

# Validate a known status is present, then pass the backend's JSON through verbatim
# (no reformatting — reflowing risks truncating the findings array).
status="$(printf '%s' "$out" | sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([A-Z_]*\)".*/\1/p' | head -1)"
case "$status" in
  APPROVED|CHANGES_REQUESTED|RISKY|SCOPE_EXPANSION_REQUIRED) ;;
  *) ap_die "reviewer returned no valid status. Raw:
$out" 2 ;;
esac
printf '%s\n' "$out"
