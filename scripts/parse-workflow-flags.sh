#!/bin/bash
#
# parse-workflow-flags.sh — shared flag parser for stagent skill bash blocks.
#
# Usage:
#   eval "$("$P/scripts/parse-workflow-flags.sh" "$ARGS")"
#
# Input:
#   $1  — raw $ARGUMENTS string from the skill (the full user input line)
#
# On success (exit 0), prints sourciable variable assignments to stdout:
#   WORKFLOW_FLAG='...'   value of --flow (empty if omitted)
#   MODE='...'            cloud|local  (default: STAGENT_DEFAULT_MODE or cloud)
#   WF_TYPE='...'         local|cloud  (empty when WORKFLOW_FLAG is empty)
#   DESCRIPTION='...'     remaining text after stripping --flow and --mode flags
#
# On error (exit 1), prints ❌ lines to stderr. Nothing is printed to stdout.
#
# Validation performed:
#   - --flow value must be a local dir with workflow.json, or cloud://author/name
#   - cloud://... is forbidden when --mode=local
#   - local path must exist and contain workflow.json

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

ARGS="${1:-}"
WORKFLOW_FLAG=""
MODE="${STAGENT_DEFAULT_MODE:-cloud}"
WF_TYPE=""
DESCRIPTION="$ARGS"

# ── Flag parsing ──────────────────────────────────────────────────────────────

# --flow=<value>  or  --flow <value>  (space-separated, legacy)
if [[ "$ARGS" =~ (^|[[:space:]])--flow=([^[:space:]]+) ]]; then
  WORKFLOW_FLAG="${BASH_REMATCH[2]}"
  DESCRIPTION="${DESCRIPTION/--flow=${WORKFLOW_FLAG}/}"
elif [[ "$ARGS" =~ (^|[[:space:]])--flow[[:space:]]+([^-][^[:space:]]*) ]]; then
  WORKFLOW_FLAG="${BASH_REMATCH[2]}"
  DESCRIPTION="${DESCRIPTION/--flow ${WORKFLOW_FLAG}/}"
fi

# --mode=cloud|local
if [[ "$ARGS" =~ (^|[[:space:]])--mode=(cloud|local) ]]; then
  MODE="${BASH_REMATCH[2]}"
  DESCRIPTION="${DESCRIPTION/--mode=${MODE}/}"
fi

# Trim whitespace from DESCRIPTION
DESCRIPTION="${DESCRIPTION#"${DESCRIPTION%%[![:space:]]*}"}"
DESCRIPTION="${DESCRIPTION%"${DESCRIPTION##*[![:space:]]}"}"

# ── Validation ────────────────────────────────────────────────────────────────

ERRS=0

if [[ -n "$WORKFLOW_FLAG" ]]; then
  RESOLVED="${WORKFLOW_FLAG/#\~/$HOME}"
  # Also expand literal $HOME / ${HOME} anywhere in the path — agents
  # often single-quote args which defeats shell expansion.
  RESOLVED="${RESOLVED//\$\{HOME\}/$HOME}"
  RESOLVED="${RESOLVED//\$HOME/$HOME}"

  if [[ -f "${RESOLVED}/workflow.json" ]]; then
    WF_TYPE="local"
  elif [[ -d "$RESOLVED" ]]; then
    echo "❌ No workflow.json found in: ${WORKFLOW_FLAG}" >&2
    ERRS=1
  elif [[ "$WORKFLOW_FLAG" =~ ^cloud://[A-Za-z0-9][A-Za-z0-9._-]*(/[A-Za-z0-9][A-Za-z0-9._-]*)?$ ]]; then
    WF_TYPE="cloud"
  elif [[ "$WORKFLOW_FLAG" =~ ^(/|\.\.?/|~) ]]; then
    echo "❌ Workflow path not found: ${WORKFLOW_FLAG}" >&2
    ERRS=1
  else
    echo "❌ '${WORKFLOW_FLAG}' is not a local workflow directory and does not look like a cloud://name or cloud://author/name reference." >&2
    ERRS=1
  fi

  # Cloud reference forbidden in local mode
  if [[ $ERRS -eq 0 && "$WF_TYPE" == "cloud" && "$MODE" == "local" ]]; then
    echo "❌ --flow '${WORKFLOW_FLAG}' is a cloud reference — cannot be used with --mode=local." >&2
    echo "   Remove --mode=local (cloud is the default) or pass a local directory path." >&2
    ERRS=1
  fi

fi

[[ $ERRS -eq 0 ]] || exit 1

# ── Output sourciable assignments ─────────────────────────────────────────────

printf "WORKFLOW_FLAG=%q\n" "$WORKFLOW_FLAG"
printf "MODE=%q\n"          "$MODE"
printf "WF_TYPE=%q\n"       "$WF_TYPE"
printf "DESCRIPTION=%q\n"   "$DESCRIPTION"
