#!/usr/bin/env bash
# The durable-doc quad: the committed source of truth every run maintains.
#
#   docs.sh status        report which quad docs exist and are non-empty (exit 3 if not)
#   docs.sh init          scaffold any missing quad doc with its ownership header
#
# Lives under docs/autopilot/ (override with AUTOPILOT_DOCS_DIR) — namespaced so it
# never collides with a project's own docs/, and lowercase-kebab so the filename says
# what it is. Committed, unlike the local .autopilot/ workspace.
#
# Content is written by the skill (Claude); this only checks presence and scaffolds
# headers so each doc states what facts it owns.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/common.sh"

DOCS=(requirements architecture backlog test-strategy)

ap_doc_owns() { case "$1" in
  requirements)  echo "product behaviour, user-visible requirements, API contracts, security/data rules, roles, permissions, external contracts" ;;
  architecture)  echo "stable module layout, runtime ownership, provider wiring, service boundaries, data-flow shape, top-level file/folder responsibility" ;;
  backlog)       echo "sequencing, exact implementation tasks, per-task mechanics, remaining gaps, future task intent" ;;
  test-strategy) echo "coverage classes, risk scenarios, expected checks, verification gaps" ;;
esac; }

cmd="${1:-status}"
dir="$(ap_docs_dir)"; rel="${dir#$(ap_root)/}"

case "$cmd" in
  init)
    mkdir -p "$dir"
    for d in "${DOCS[@]}"; do
      f="$dir/$d.md"
      if [ -s "$f" ]; then echo "  • $d.md exists — kept"; continue; fi
      title="$(echo "$d" | tr '-' ' ')"
      { echo "# $title"; echo; echo "> Owns: $(ap_doc_owns "$d")."; echo
        echo "<!-- autopilot maintains this durable doc. Replace stale claims with concise"
        echo "     current truth. Do not put another doc's facts here. -->"; } > "$f"
      echo "  ✓ scaffolded $d.md"
    done
    # Optional cross-run memory — not part of the status gate.
    mem="$dir/memory.md"
    if [ ! -s "$mem" ]; then
      { echo "# memory"; echo; echo "> Short workflow lessons autopilot carries between runs."
        echo "> Read in Phase 1, appended in Phase 4. Keep entries one line: what happened → what to do."; echo; } > "$mem"
      echo "  ✓ scaffolded memory.md (optional)"
    fi ;;

  status)
    missing=0
    for d in "${DOCS[@]}"; do
      if [ -s "$dir/$d.md" ]; then echo "  ✓ $rel/$d.md"
      else echo "  ✗ $rel/$d.md missing or empty"; missing=$((missing+1)); fi
    done
    [ "$missing" -eq 0 ] || { echo "quad incomplete — run 'autopilot docs init' then fill them"; exit 3; }
    echo "quad complete" ;;

  *) ap_die "usage: autopilot docs [status|init]" ;;
esac
