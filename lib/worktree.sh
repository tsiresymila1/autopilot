#!/usr/bin/env bash
# Parallel execution mechanics — the deterministic, fail-safe core that makes
# `--parallel N` safe regardless of how the engine schedules it. Sourced, never
# executed. Depends on paths.sh (ap_*), gate.sh (ap_id_of, ap_allowed_paths),
# channels.sh (ap_event). Sourced from common.sh after those.
#
# The model: each concurrent task runs in its OWN git worktree on branch ap/<id>,
# so its build/gate/commit can't collide with another task's. Merging back is the
# only serial step, and `ap_wt_merge` REFUSES any worktree whose diff escapes the
# task's ## Allowed Files or would conflict — so a mis-scheduled parallel run can
# never corrupt the main branch.

set -uo pipefail

# --- task fields -------------------------------------------------------------

# ap_deps_of <task.md> — ids from `- **depends**: a, b` (comma/space separated), one per line.
ap_deps_of() {
  sed -n 's/^-[[:space:]]*\*\*depends\*\*:[[:space:]]*//p' "$1" | head -1 \
    | tr ',' ' ' | tr -s ' ' '\n' | sed '/^$/d'
}

# ap_state_of <id> — the recorded state (done|blocked|…) or empty. Mirrors the
# key-resolution the `status` verb uses (id, then filename stem, then NNN prefix).
ap_state_of() {
  local id="$1" sd; sd="$(ap_task_state)"
  [ -f "$sd/$id" ] && { cat "$sd/$id"; return; }
  echo ""
}

# --- disjointness ------------------------------------------------------------

# ap_allowed_disjoint <taskA.md> <taskB.md> — 0 (true) if their ## Allowed Files
# do not overlap. Two paths conflict if equal, or one is nested under the other —
# the same containment rule ap_scope_violations enforces.
ap_allowed_disjoint() {
  local a b pa pb
  local ta bt; ta="$(mktemp)"; bt="$(mktemp)"
  ap_allowed_paths "$1" > "$ta"; ap_allowed_paths "$2" > "$bt"
  local rc=0
  while IFS= read -r a; do
    [ -n "$a" ] || continue; a="${a%/}"
    while IFS= read -r b; do
      [ -n "$b" ] || continue; b="${b%/}"
      if [ "$a" = "$b" ]; then rc=1; break; fi
      case "$a" in "$b"/*) rc=1; break;; esac
      case "$b" in "$a"/*) rc=1; break;; esac
    done < "$bt"
    [ "$rc" -eq 1 ] && break
  done < "$ta"
  rm -f "$ta" "$bt"
  return $rc
}

# --- the ready wave ----------------------------------------------------------

# ap_wave <width> — print up to <width> task-file paths that can run concurrently:
# not done, all deps done, has a gate + Allowed Files, and pairwise-disjoint.
ap_wave() {
  local width="${1:-2}" qd f id st dep ok picked=0
  qd="$(ap_tasks_dir)"; [ -d "$qd" ] || return 0
  local -a chosen=()
  for f in "$qd"/*.md; do
    [ -e "$f" ] || continue
    [ "$picked" -ge "$width" ] && break
    id="$(ap_id_of "$f")"
    st="$(ap_state_of "$id")"
    # skip any task already settled (done or parked); only fresh/todo tasks join a wave
    case "$st" in done|blocked|needs-human|needs-verification) continue;; esac
    [ -n "$(ap_gate_of "$f")" ] || continue
    [ -n "$(ap_allowed_paths "$f")" ] || continue
    # every dependency must be done
    ok=1
    for dep in $(ap_deps_of "$f"); do
      [ "$(ap_state_of "$dep")" = done ] || { ok=0; break; }
    done
    [ "$ok" -eq 1 ] || continue
    # disjoint from everything already picked
    if [ "${#chosen[@]}" -gt 0 ]; then
      for p in "${chosen[@]}"; do
        ap_allowed_disjoint "$f" "$p" || { ok=0; break; }
      done
    fi
    [ "$ok" -eq 1 ] || continue
    chosen+=("$f"); picked=$((picked+1)); echo "$f"
  done
}

# --- worktree lifecycle ------------------------------------------------------

ap_wt_path()   { echo "$(ap_worktrees_dir)/$1"; }
ap_wt_branch() { echo "ap/$1"; }

# ap_wt_add <task.md> — create an isolated worktree on branch ap/<id> off HEAD.
ap_wt_add() {
  local task="$1" root id wt br
  root="$(ap_root)"; id="$(ap_id_of "$task")"; wt="$(ap_wt_path "$id")"; br="$(ap_wt_branch "$id")"
  [ -e "$wt" ] && { ap_warn "worktree already exists: $wt (drop it first)"; return 2; }
  mkdir -p "$(ap_worktrees_dir)"
  git -C "$root" worktree add -q -b "$br" "$wt" HEAD 2>/dev/null \
    || { ap_warn "git worktree add failed for $id"; return 1; }
  echo "$wt"
}

# ap_wt_merge <task.md> — the safety gate. Scope-check the worktree's commits, then
# cherry-pick them onto the current branch. Refuses anything unsafe.
ap_wt_merge() {
  local task="$1" root id wt br base tmp v
  root="$(ap_root)"; id="$(ap_id_of "$task")"; wt="$(ap_wt_path "$id")"; br="$(ap_wt_branch "$id")"
  [ -d "$wt" ] || { ap_warn "no worktree for $id"; return 2; }
  # must have advanced past the branch point
  base="$(git -C "$root" merge-base HEAD "$br" 2>/dev/null)"
  [ -n "$base" ] || { ap_warn "$id: cannot find branch point"; return 1; }
  if [ "$(git -C "$root" rev-parse "$br")" = "$base" ]; then
    ap_warn "$id: worktree has no commit — nothing built"; return 3
  fi
  # scope: the branch's committed diff must stay within ## Allowed Files
  tmp="$(mktemp)"; ap_allowed_paths "$task" > "$tmp"
  v="$(ap_scope_violations "$tmp" "$base..$br" 2>/dev/null)"; rm -f "$tmp"
  if [ -n "$v" ]; then
    ap_warn "$id: REFUSED merge — changes outside ## Allowed Files:"; echo "$v" | sed 's/^/    /' >&2
    echo blocked > "$(ap_task_state)/$id"
    ap_event blocked "$id — merge refused (out of scope)" "$v" "$task" blocked milestones
    return 4
  fi
  # cherry-pick the range onto the main branch; disjoint ⇒ conflict-free
  if ! git -C "$root" cherry-pick "$base..$br" >/dev/null 2>&1; then
    git -C "$root" cherry-pick --abort >/dev/null 2>&1 || true
    ap_warn "$id: REFUSED merge — cherry-pick conflicted (worktree kept for inspection)"
    echo blocked > "$(ap_task_state)/$id"
    ap_event blocked "$id — merge conflict" "cherry-pick $base..$br conflicted" "$task" blocked milestones
    return 5
  fi
  echo done > "$(ap_task_state)/$id"
  ap_event task-done "$id — merged (parallel)" "merged worktree $br onto $(git -C "$root" rev-parse --abbrev-ref HEAD)" "$task" done steps
  ap_wt_drop "$task" >/dev/null 2>&1 || true
  echo "merged $id"
}

# ap_wt_drop <task.md> — remove the worktree + its branch (cleanup / on failure).
ap_wt_drop() {
  local task="$1" root id wt br
  root="$(ap_root)"; id="$(ap_id_of "$task")"; wt="$(ap_wt_path "$id")"; br="$(ap_wt_branch "$id")"
  git -C "$root" worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt"
  git -C "$root" branch -D "$br" >/dev/null 2>&1 || true
  git -C "$root" worktree prune >/dev/null 2>&1 || true
  echo "dropped $id"
}

# ap_wt_list — the autopilot worktrees currently on disk.
ap_wt_list() {
  local root; root="$(ap_root)"
  git -C "$root" worktree list 2>/dev/null | grep -F "$(ap_worktrees_dir)/" || echo "no autopilot worktrees"
}
