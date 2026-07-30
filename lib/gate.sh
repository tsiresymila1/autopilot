#!/usr/bin/env bash
# Gate + verify helpers: extract a task's gate and Allowed Files, reject weak
# gates, run gates reproducibly with provenance, and verify a task at two tiers.
# Sourced, never executed. Depends on paths.sh + project.sh.

set -uo pipefail

# Echo the task's gate command (from the `- **gate**: ...` line), backticks stripped.
ap_gate_of() {
  sed -n 's/^-[[:space:]]*\*\*gate\*\*:[[:space:]]*//p' "$1" | head -1 | tr -d '`'
}

# Echo the task's id (from `- **id**:`), falling back to the filename stem.
ap_id_of() {
  local id; id="$(sed -n 's/^-[[:space:]]*\*\*id\*\*:[[:space:]]*//p' "$1" | head -1)"
  [ -n "$id" ] && echo "$id" || basename "$1" .md
}

# Echo the paths under "## Allowed Files", one per line — backticks, inline `# comments`
# and surrounding whitespace stripped, so callers can use each line as a real path.
ap_allowed_paths() {
  awk '/^##[[:space:]]+Allowed Files/{f=1;next} /^##[[:space:]]/{f=0} f' "$1" \
    | sed -n 's/^[[:space:]]*[-*][[:space:]]*`\{0,1\}\([^`]*\)`\{0,1\}[[:space:]]*$/\1/p' \
    | sed -e 's/[[:space:]]*#.*$//' -e 's/[[:space:]]*$//' -e 's/^[[:space:]]*//' \
    | grep -v '^$'
}

# Echo the body of the task's "## Manual Verification" section verbatim (the lines
# a human must check when the automated gate cannot prove completion headless).
# Empty when the section is absent — which is what forbids a silent bypass.
ap_manual_steps() {
  awk '/^##[[:space:]]+Manual Verification/{f=1;next} /^##[[:space:]]/{f=0} f' "$1" \
    | sed -e 's/[[:space:]]*$//' | grep -v '^$'
}

# Return 0 if the gate is too weak to prove completion (cheatable / trivially true).
# A weak gate is the one failure mode the whole design must not allow.
ap_gate_weak() {
  local g; g="$(echo "$1" | xargs 2>/dev/null)"   # trim
  case "$g" in
    ''|true|:|'exit 0')                 return 0 ;;   # tautology
    echo*|printf*|ls|ls\ *|pwd|cat\ *)  return 0 ;;   # prints, proves nothing
  esac
  # `test -f X` / `[ -f X ]` pass on an empty file — demand a content/behaviour check.
  case "$g" in
    'test -f '*|'[ -f '*)
      case "$g" in *'&&'*|*';'*|*'|'*) return 1 ;; *) return 0 ;; esac ;;
  esac
  return 1
}

# Run a gate command reproducibly: from the repo root, output captured to a log,
# provenance appended to the journal. Echoes nothing; returns the gate's exit code.
# ap_run_gate <label> <command>
ap_run_gate() {
  local label="$1" cmd="$2" root logf rc
  root="$(ap_root)"; mkdir -p "$(ap_logs_dir)"
  logf="$(ap_logs_dir)/gate-$label.log"
  ( cd "$root" && eval "$cmd" ) >"$logf" 2>&1; rc=$?
  { printf '[%s] gate %s: `%s` → exit %d (log: %s)\n' \
      "$(date '+%H:%M:%S')" "$label" "$cmd" "$rc" "$logf"; } >> "$(ap_journal)" 2>/dev/null || true
  return $rc
}
