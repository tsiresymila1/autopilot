#!/usr/bin/env bash
# The durable-doc quad: the committed source of truth every run maintains.
#
#   docs.sh status        report which quad docs exist and are non-empty (exit 3 if not)
#   docs.sh init          scaffold any missing quad doc with its ownership header
#
# Content is written by the skill (Claude); this only checks presence and scaffolds
# headers so each doc states what facts it owns.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/common.sh"

DOCS=(REQUIREMENTS ARCHITECTURE TASK_BACKLOG TEST_STRATEGY)

ap_doc_owns() { case "$1" in
  REQUIREMENTS)  echo "product behaviour, user-visible requirements, API contracts, security/data rules, roles, permissions, external contracts" ;;
  ARCHITECTURE)  echo "stable module layout, runtime ownership, provider wiring, service boundaries, data-flow shape, top-level file/folder responsibility" ;;
  TASK_BACKLOG)  echo "sequencing, exact implementation tasks, per-task mechanics, remaining gaps, future task intent" ;;
  TEST_STRATEGY) echo "coverage classes, risk scenarios, expected checks, verification gaps" ;;
esac; }

cmd="${1:-status}"; root="$(ap_root)"; dir="$root/docs"

case "$cmd" in
  init)
    mkdir -p "$dir"
    for d in "${DOCS[@]}"; do
      f="$dir/$d.md"
      if [ -s "$f" ]; then echo "  • $d.md exists — kept"; continue; fi
      title="$(echo "$d" | tr '_' ' ')"
      { echo "# $title"; echo; echo "> Owns: $(ap_doc_owns "$d")."; echo
        echo "<!-- autopilot maintains this durable doc. Replace stale claims with concise"
        echo "     current truth. Do not put another doc's facts here. -->"; } > "$f"
      echo "  ✓ scaffolded $d.md"
    done
    # Optional cross-run memory — not part of the status gate.
    mem="$dir/AI_MEMORY.md"
    if [ ! -s "$mem" ]; then
      { echo "# AI Memory"; echo; echo "> Short workflow lessons autopilot carries between runs."
        echo "> Read in Phase 1, appended in Phase 4. Keep entries one line: what happened → what to do."; echo; } > "$mem"
      echo "  ✓ scaffolded AI_MEMORY.md (optional)"
    fi ;;

  status)
    missing=0
    for d in "${DOCS[@]}"; do
      f="$dir/$d.md"
      if [ -s "$f" ]; then echo "  ✓ docs/$d.md"
      else echo "  ✗ docs/$d.md missing or empty"; missing=$((missing+1)); fi
    done
    [ "$missing" -eq 0 ] || { echo "quad incomplete — run 'autopilot docs init' then fill them"; exit 3; }
    echo "quad complete" ;;

  *) ap_die "usage: autopilot docs [status|init]" ;;
esac
