#!/usr/bin/env bash
# Supervisor: relaunch the autopilot session until the work is finished.
#
# Nothing inside an engine session can restart it after a quota block. This lives
# outside: it relaunches, waits for the reset, resumes. State is on disk
# (.autopilot/status, journal.md, state/*), so each relaunch picks up where
# the last one stopped. The engine is claude by default, codex via AUTOPILOT_ENGINE.
#
#   supervisor.sh "<goal or file>" [extra autopilot args]
#   MAX_RELAUNCH=40 supervisor.sh "goal" --max-tasks 5

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/common.sh"

GOAL="${1:?usage: supervisor.sh \"<goal or file>\" [options]}"; shift || true
EXTRA="$*"

MAX_RELAUNCH="${MAX_RELAUNCH:-24}"
RETRY_WAIT="${RETRY_WAIT:-900}"                 # fallback wait if reset time unknown
TRANSIENT_WAIT="${TRANSIENT_WAIT:-10}"         # server 5xx / overloaded: clears in seconds
PERMISSION_MODE="${PERMISSION_MODE:-bypassPermissions}"

why="$(ap_engine_available)" || ap_die "$why"
cd "$(ap_root)" || exit 1

# --- single-run lock (stale locks from dead PIDs are reclaimed) ---------------
LOCK="$(ap_lock_file)"; mkdir -p "$(dirname "$LOCK")"
if [ -f "$LOCK" ] && kill -0 "$(cat "$LOCK" 2>/dev/null)" 2>/dev/null; then
  ap_die "another autopilot run holds the lock (pid $(cat "$LOCK")). Stop it first."
fi
echo $$ > "$LOCK"
trap 'rm -f "$LOCK"; ap_log "interrupted"; exit 130' INT TERM
trap 'rm -f "$LOCK"' EXIT

STATUS="$(ap_status_file)"; LOGDIR="$(ap_logs_dir)"; mkdir -p "$LOGDIR"
log() { ap_log "$1" | tee -a "$LOGDIR/supervisor.log"; }

# Scaffold the machine-readable workspace up front so the supervisor contract
# never depends on the model creating it. The engine may still keep its own
# human-readable notes (PROGRESS.md, a repo's native layout); this is the
# status file the supervisor reads and `autopilot status` reports. A fresh run
# starts RUNNING; a resume keeps whatever status is already on disk.
mkdir -p "$(ap_tasks_dir)" "$(ap_task_state)"
[ -f "$STATUS" ] || echo RUNNING > "$STATUS"

wait_for_reset() {
  local out="$1" secs="$RETRY_WAIT" hhmm now target
  hhmm=$(grep -oiE '(resets?|réinitialis[^ ]*|réessayez?)[^0-9]{0,20}([0-9]{1,2})[:h]([0-9]{2})' "$out" 2>/dev/null \
         | grep -oE '([0-9]{1,2})[:h]([0-9]{2})' | head -1 | tr 'h' ':')
  if [ -n "$hhmm" ]; then
    # Parse the reset time portably: BSD/macOS date (-j -f) or GNU/Linux date (-d).
    now=$(date +%s)
    target=$(date -j -f "%H:%M" "$hhmm" +%s 2>/dev/null \
             || date -d "$hhmm" +%s 2>/dev/null || echo "")
    if [ -n "$target" ]; then
      [ "$target" -le "$now" ] && target=$((target + 86400))
      secs=$((target - now + 60))
    fi
  fi
  log "quota hit — resuming in $((secs/60)) min"; sleep "$secs"
}

# The engine prompt is built once (claude: a skill call · codex: the inlined skill).
PROMPTFILE="$(mktemp)"; trap 'rm -f "$PROMPTFILE" "$LOCK"' EXIT
ap_engine_prompt "$GOAL $EXTRA

If .autopilot/ already holds tasks and a journal, this is a RESUME: read
.autopilot/journal.md, .autopilot/state/* and .autopilot/tasks/, then restart at the
first task not marked done. Do not start over. Do not re-litigate decisions already made." \
  "$PROMPTFILE"

log "start — engine: $(ap_engine) · goal: $GOAL ${EXTRA:+· options: $EXTRA}"

# A fingerprint of progress: HEAD + status + the task-state dir. If a clean
# session leaves all three unchanged, it did nothing — the engine keeps
# concluding the same thing (already done, or waiting on a human) without
# writing a terminal status. Stop after STALL_LIMIT such no-ops instead of
# relaunching an identical session to the cap.
STALL_LIMIT="${STALL_LIMIT:-2}"
progress_fingerprint() {
  printf '%s|%s|%s' \
    "$(git rev-parse HEAD 2>/dev/null || echo none)" \
    "$(cat "$STATUS" 2>/dev/null)" \
    "$(ls -1 "$(ap_task_state)" 2>/dev/null | sort | tr '\n' ',')"
}
stall=0; last_fp="$(progress_fingerprint)"

for i in $(seq 1 "$MAX_RELAUNCH"); do
  OUT="$LOGDIR/session-$(date +%Y%m%d-%H%M%S).log"
  log "session $i/$MAX_RELAUNCH → $OUT"
  ap_engine_exec "$PROMPTFILE" >"$OUT" 2>&1
  code=$?
  status=$(cat "$STATUS" 2>/dev/null || echo "RUNNING")
  log "session ended (code $code) · status=$status"

  case "$status" in
    DONE)    log "✅ done — nothing left"; ap_event run-done "autopilot: DONE" "$GOAL — nothing left to do" "" DONE milestones; tail -40 "$OUT"; exit 0 ;;
    BLOCKED) log "⛔ blocked — human needed (see .autopilot/inbox.md)"; ap_event run-blocked "autopilot: BLOCKED" "$GOAL — human needed (.autopilot/inbox.md)" "" BLOCKED milestones; tail -40 "$OUT"; exit 2 ;;
  esac

  if grep -qiE 'usage limit|rate limit|quota|too many requests|limite.*atteinte|429' "$OUT"; then
    wait_for_reset "$OUT"
  elif grep -qiE '5[0-9]{2} .*(internal server|server error)|overloaded|Execution error|API Error: 5[0-9]{2}' "$OUT"; then
    log "🔁 transient server error — retry in ${TRANSIENT_WAIT}s"; tail -3 "$OUT"; sleep "$TRANSIENT_WAIT"
  elif [ "$code" -ne 0 ]; then
    log "⚠️  unexpected failure (code $code) — retry in 60 s"; tail -15 "$OUT"; sleep 60
  else
    # Clean exit, still RUNNING: did it actually move? No change = a no-op.
    fp="$(progress_fingerprint)"
    if [ "$fp" = "$last_fp" ]; then
      stall=$((stall+1))
      log "session made no change ($stall/$STALL_LIMIT no-op sessions)"
      if [ "$stall" -ge "$STALL_LIMIT" ]; then
        log "🛑 stuck — $stall sessions changed nothing. The engine keeps concluding without a terminal status (already done, or a human decision is pending). Stopping. See the last session below and .autopilot/inbox.md."
        ap_event run-stuck "autopilot: STUCK" "$GOAL — no progress in $stall sessions; likely needs a human" "" STUCK milestones
        tail -40 "$OUT"; exit 4
      fi
    else
      stall=0; last_fp="$fp"
      log "session closed without finishing — resuming immediately"
    fi
  fi
done

log "⚠️  hit the $MAX_RELAUNCH relaunch cap — stopping"
ap_event run-stopped "autopilot: STOPPED" "$GOAL — hit the $MAX_RELAUNCH relaunch cap, still not done" "" STOPPED milestones
exit 3
