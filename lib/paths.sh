#!/usr/bin/env bash
# Workspace paths, logging, git, and scope helpers. Sourced, never executed.
# No side effects on source — only function definitions.

set -uo pipefail

# --- workspace layout --------------------------------------------------------
# The whole autopilot workspace lives under .autopilot/ (git-ignored, local).
# Flat and self-describing: one glance tells you what each entry is.

# Repo root = git toplevel if we are in a repo, else the current directory.
ap_root() { git rev-parse --show-toplevel 2>/dev/null || pwd; }

ap_state_dir()   { echo "$(ap_root)/.autopilot"; }
ap_status_file() { echo "$(ap_state_dir)/status"; }        # RUNNING | DONE | BLOCKED
ap_lock_file()   { echo "$(ap_state_dir)/lock"; }          # supervisor pid
ap_task_state()  { echo "$(ap_state_dir)/state"; }         # dir: one file per task id
ap_tasks_dir()   { echo "$(ap_state_dir)/tasks"; }         # dir: one spec per task
ap_logs_dir()    { echo "$(ap_state_dir)/logs"; }          # supervisor.log + session-*.log
ap_journal()     { echo "$(ap_state_dir)/journal.md"; }    # decisions, gate results
ap_inbox()       { echo "$(ap_state_dir)/inbox.md"; }      # awaiting a human
ap_plan()        { echo "$(ap_state_dir)/plan.md"; }       # the decomposition
ap_events_log()  { echo "$(ap_state_dir)/events.log"; }    # append-only per-step event feed

# The durable docs are COMMITTED (unlike .autopilot/): namespaced under docs/autopilot/
# so they never collide with a project's own docs. Override to merge them elsewhere.
ap_docs_dir()    { echo "$(ap_root)/${AUTOPILOT_DOCS_DIR:-docs/autopilot}"; }

# --- logging -----------------------------------------------------------------

ap_log()  { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
ap_die()  { printf 'autopilot: %s\n' "$*" >&2; exit "${2:-1}"; }
ap_warn() { printf 'autopilot: %s\n' "$*" >&2; }

# --- git ---------------------------------------------------------------------

ap_in_git()     { git rev-parse --is-inside-work-tree >/dev/null 2>&1; }
ap_tree_clean() { [ -z "$(git status --porcelain 2>/dev/null)" ]; }

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
