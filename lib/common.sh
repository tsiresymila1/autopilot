#!/usr/bin/env bash
# Aggregator: sources the focused helper modules so callers keep one stable
# `. common.sh` line. Each module owns one concern (paths, project, notify).
set -uo pipefail
_ap_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/paths.sh
. "$_ap_lib/paths.sh"
# shellcheck source=lib/project.sh
. "$_ap_lib/project.sh"
# shellcheck source=lib/notify.sh
. "$_ap_lib/notify.sh"
# shellcheck source=lib/gate.sh
. "$_ap_lib/gate.sh"
# shellcheck source=lib/engine.sh
. "$_ap_lib/engine.sh"
