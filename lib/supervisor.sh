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

wait_for_reset() {
  local out="$1" secs="$RETRY_WAIT" hhmm now target
  hhmm=$(grep -oiE '(resets?|réinitialis[^ ]*|réessayez?)[^0-9]{0,20}([0-9]{1,2})[:h]([0-9]{2})' "$out" 2>/dev/null \
         | grep -oE '([0-9]{1,2})[:h]([0-9]{2})' | head -1 | tr 'h' ':')
  if [ -n "$hhmm" ]; then
    now=$(date +%s); target=$(date -j -f "%H:%M" "$hhmm" +%s 2>/dev/null || echo "")
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

for i in $(seq 1 "$MAX_RELAUNCH"); do
  OUT="$LOGDIR/session-$(date +%Y%m%d-%H%M%S).log"
  log "session $i/$MAX_RELAUNCH → $OUT"
  ap_engine_exec "$PROMPTFILE" >"$OUT" 2>&1
  code=$?
  status=$(cat "$STATUS" 2>/dev/null || echo "RUNNING")
  log "session ended (code $code) · status=$status"

  case "$status" in
    DONE)    log "✅ done — nothing left"; ap_notify "autopilot: DONE" "$GOAL — nothing left to do"; tail -40 "$OUT"; exit 0 ;;
    BLOCKED) log "⛔ blocked — human needed (see .autopilot/inbox.md)"; ap_notify "autopilot: BLOCKED" "$GOAL — human needed (.autopilot/inbox.md)"; tail -40 "$OUT"; exit 2 ;;
  esac

  if grep -qiE 'usage limit|rate limit|quota|too many requests|limite.*atteinte|429' "$OUT"; then
    wait_for_reset "$OUT"
  elif [ "$code" -ne 0 ]; then
    log "⚠️  unexpected failure (code $code) — retry in 60 s"; tail -15 "$OUT"; sleep 60
  else
    log "session closed without finishing — resuming immediately"
  fi
done

log "⚠️  hit the $MAX_RELAUNCH relaunch cap — stopping"
ap_notify "autopilot: STOPPED" "$GOAL — hit the $MAX_RELAUNCH relaunch cap, still not done"
exit 3
