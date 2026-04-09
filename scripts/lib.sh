#!/bin/bash
# Shared utilities for dev-workflow scripts.
# Finds the state file regardless of current working directory.

resolve_state() {
  local state_file=""

  # 1. Check CWD
  if [[ -f ".dev-workflow/state.md" ]]; then
    state_file="$(pwd)/.dev-workflow/state.md"
  fi

  # 2. Search upward from CWD
  if [[ -z "$state_file" ]]; then
    local dir
    dir="$(pwd)"
    while [[ "$dir" != "/" ]]; do
      if [[ -f "$dir/.dev-workflow/state.md" ]]; then
        state_file="$dir/.dev-workflow/state.md"
        break
      fi
      dir="$(dirname "$dir")"
    done
  fi

  # 3. Breadcrumb file (written by setup-workflow.sh)
  if [[ -z "$state_file" ]]; then
    if [[ -f "${HOME}/.dev-workflow-active" ]]; then
      local stored
      stored="$(cat "${HOME}/.dev-workflow-active")"
      if [[ -f "$stored" ]]; then
        state_file="$stored"
      fi
    fi
  fi

  if [[ -z "$state_file" ]]; then
    return 1
  fi

  # Export results
  STATE_FILE="$state_file"

  # Extract project_root from YAML frontmatter, fall back to path derivation
  PROJECT_ROOT=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$STATE_FILE" \
    | grep '^project_root:' \
    | sed 's/project_root: *//' \
    | sed 's/^"\(.*\)"$/\1/') || true
  if [[ -z "$PROJECT_ROOT" ]]; then
    PROJECT_ROOT="$(dirname "$(dirname "$STATE_FILE")")"
  fi

  return 0
}
