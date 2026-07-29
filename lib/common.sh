#!/usr/bin/env bash
# Shared helpers for the autopilot CLI. Sourced, never executed directly.
# No side effects on source — only function + readonly definitions.

set -uo pipefail

# --- paths -------------------------------------------------------------------

# Repo root = git toplevel if we are in a repo, else the current directory.
ap_root() { git rev-parse --show-toplevel 2>/dev/null || pwd; }

ap_state_dir()  { echo "$(ap_root)/.agent"; }
ap_status_file(){ echo "$(ap_state_dir)/run/status"; }
ap_task_state() { echo "$(ap_state_dir)/run/state"; }   # dir: one file per task id
ap_queue_dir()  { echo "$(ap_state_dir)/queue"; }
ap_lock_file()  { echo "$(ap_state_dir)/run/lock"; }

# --- logging -----------------------------------------------------------------

ap_log()  { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
ap_die()  { printf 'autopilot: %s\n' "$*" >&2; exit "${2:-1}"; }
ap_warn() { printf 'autopilot: %s\n' "$*" >&2; }

# --- notifications -----------------------------------------------------------

# Notify the user that an autonomous run reached a milestone. Best-effort — never
# fails the run. Backends, in priority order:
#   ntfy    → $AUTOPILOT_NTFY_TOPIC set → push to $AUTOPILOT_NTFY_SERVER (default
#             https://ntfy.sh), optional $AUTOPILOT_NTFY_TOKEN for auth. The main path.
#   custom  → $AUTOPILOT_NOTIFY run as a command; title/body in
#             $AUTOPILOT_NOTIFY_TITLE / $AUTOPILOT_NOTIFY_BODY
#   macOS   → osascript · linux → notify-send · else → no-op (still logged)
# Report the backend used on stdout so callers/tests can see it.
ap_notify() {
  local title="${1:-autopilot}" body="${2:-}"
  if [ -n "${AUTOPILOT_NTFY_TOPIC:-}" ] && command -v curl >/dev/null 2>&1; then
    local server="${AUTOPILOT_NTFY_SERVER:-https://ntfy.sh}"
    curl -fsS -m 10 -H "Title: $title" \
      ${AUTOPILOT_NTFY_TOKEN:+-H "Authorization: Bearer $AUTOPILOT_NTFY_TOKEN"} \
      -d "$body" "$server/$AUTOPILOT_NTFY_TOPIC" >/dev/null 2>&1 \
      && { echo "notified via ntfy ($AUTOPILOT_NTFY_TOPIC)"; return; }
    echo "ntfy push failed ($server/$AUTOPILOT_NTFY_TOPIC)"; return
  fi
  if [ -n "${AUTOPILOT_NOTIFY:-}" ]; then
    AUTOPILOT_NOTIFY_TITLE="$title" AUTOPILOT_NOTIFY_BODY="$body" \
      eval "$AUTOPILOT_NOTIFY" >/dev/null 2>&1 && { echo "notified via AUTOPILOT_NOTIFY"; return; }
    echo "notify hook failed (AUTOPILOT_NOTIFY)"; return
  fi
  if command -v osascript >/dev/null 2>&1; then
    osascript -e 'on run {t,b}' -e 'display notification b with title t' -e 'end run' \
      "$title" "$body" >/dev/null 2>&1 && { echo "notified via osascript"; return; }
  fi
  if command -v notify-send >/dev/null 2>&1; then
    notify-send "$title" "$body" >/dev/null 2>&1 && { echo "notified via notify-send"; return; }
  fi
  echo "no notifier available (set AUTOPILOT_NTFY_TOPIC or AUTOPILOT_NOTIFY)"
}

# --- project detection -------------------------------------------------------

# Emit the project type on stdout: node | python | rust | go | php | static | empty.
# "static" = files present but no recognised toolchain. "empty" = no files at all.
ap_project_type() {
  local r; r="$(ap_root)"
  [ -f "$r/package.json" ]                                   && { echo node;   return; }
  { [ -f "$r/pyproject.toml" ] || [ -f "$r/requirements.txt" ] || [ -f "$r/setup.py" ]; } \
                                                             && { echo python; return; }
  [ -f "$r/Cargo.toml" ]                                     && { echo rust;   return; }
  [ -f "$r/go.mod" ]                                         && { echo go;     return; }
  [ -f "$r/composer.json" ]                                  && { echo php;    return; }
  # Anything tracked/untracked besides the .agent workspace and git plumbing?
  if [ -n "$(ls -A "$r" 2>/dev/null | grep -vE '^(\.agent|\.git)$')" ]; then
    echo static; return
  fi
  echo empty
}

# Best-guess "prove it builds/tests" command for a project type. Empty string if
# none is inferable — the skill must then design a bespoke gate.
ap_default_gate() {
  case "${1:-$(ap_project_type)}" in
    node)   echo 'npm run build --if-present && npm test' ;;
    python) echo 'python -m pytest -q' ;;
    rust)   echo 'cargo build && cargo test' ;;
    go)     echo 'go build ./... && go test ./...' ;;
    php)    echo 'composer test' ;;
    *)      echo '' ;;
  esac
}

# --- git ---------------------------------------------------------------------

ap_in_git()      { git rev-parse --is-inside-work-tree >/dev/null 2>&1; }
ap_tree_clean()  { [ -z "$(git status --porcelain 2>/dev/null)" ]; }

# --- scope enforcement -------------------------------------------------------

# Print any changed file NOT covered by the allowed list — the objective,
# machine-checkable form of "## Allowed Files". Empty output = in scope.
#   ap_scope_violations <allowed-file> [<git-ref>]
# <allowed-file>: one repo-relative path or directory per line (comments/blank ok).
# <git-ref>: compare working tree against this ref (default: HEAD).
# A change is in scope if it equals an allowed path or sits under an allowed dir.
ap_scope_violations() {
  local allowed="$1" ref="${2:-HEAD}" f a covered
  local -a globs=()
  while IFS= read -r a; do
    a="${a%%#*}"; a="$(echo "$a" | xargs 2>/dev/null)"   # strip comment + trim
    [ -n "$a" ] && globs+=("${a%/}")
  done < "$allowed"
  git diff --name-only "$ref" 2>/dev/null | while IFS= read -r f; do
    [ -n "$f" ] || continue
    covered=0
    for a in "${globs[@]}"; do
      [ "$f" = "$a" ] && { covered=1; break; }
      case "$f" in "$a"/*) covered=1; break;; esac
    done
    [ "$covered" -eq 0 ] && echo "$f"
  done
}
