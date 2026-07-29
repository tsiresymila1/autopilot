#!/usr/bin/env bash
# Project detection and the default-gate matrix. Sourced, never executed.
# Depends on ap_root from paths.sh.

set -uo pipefail

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
  # Anything besides the autopilot workspace and git plumbing?
  if [ -n "$(ls -A "$r" 2>/dev/null | grep -vE '^(\.autopilot|\.git)$')" ]; then
    echo static; return
  fi
  echo empty
}

# Best-guess "prove it builds/tests" command for a project type — also the repo-wide
# gate (`autopilot gate --repo`). Empty string if none is inferable; the skill must
# then design a bespoke gate per task.
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
