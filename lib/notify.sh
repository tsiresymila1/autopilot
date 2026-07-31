#!/usr/bin/env bash
# ap_notify: the plain title/body notifier kept for back-compat. Sourced, never
# executed. The real machinery lives in channels.sh (sourced right after this in
# common.sh); ap_notify now fans out to EVERY configured channel instead of
# picking one. Best-effort — never fails the run; each backend echoes what it used.

set -uo pipefail

# ap_notify <title> <body> — fan a milestone message out to all channels.
ap_notify() {
  local title="${1:-autopilot}" body="${2:-}"
  ap_channels_send "notify" "$title" "$body" "" "" "$(date '+%Y-%m-%d %H:%M:%S')"
}
