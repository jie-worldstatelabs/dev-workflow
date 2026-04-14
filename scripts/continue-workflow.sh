#!/bin/bash

# Dev Workflow Continue Script
# Resumes an interrupted workflow by restoring the saved resume_status.
# Only works when status is "interrupted" — use /dev-workflow:dev for a fresh start.
#
# Session-keyed model: each run lives under .dev-workflow/<session_id>/.
# If the user resumes from a NEW Claude session (e.g. reopened terminal),
# the interrupted run's dir is renamed to this session's id so the stop hook
# and other session-scoped machinery resolve correctly.
#
# Usage: continue-workflow.sh [--topic <name>] [--session <id>]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

TOPIC_ARG=""
SESSION_ARG=""
FORCE_MISMATCH=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --topic=*)               TOPIC_ARG="${1#--topic=}";     shift ;;
    --topic)                 TOPIC_ARG="$2";                shift 2 ;;
    --session=*)             SESSION_ARG="${1#--session=}"; shift ;;
    --session)               SESSION_ARG="$2";              shift 2 ;;
    --force-project-mismatch) FORCE_MISMATCH="yes";         shift ;;
    *)                       shift ;;
  esac
done

[[ -n "$TOPIC_ARG" ]] && DESIRED_TOPIC="$TOPIC_ARG"
[[ -n "$SESSION_ARG" ]] && DESIRED_SESSION="$SESSION_ARG"

# Cross-machine takeover: if --session <id> refers to a cloud session
# that has never been seen on this machine, pull it down from the server
# and register both the server session_id and this machine's local
# session_id as aliases pointing at the same scratch dir. After this
# block, resolve_state will find the shadow via either key.
if [[ -n "${DESIRED_SESSION:-}" ]] && ! is_cloud_session "$DESIRED_SESSION"; then
  echo "▶️  Attempting cross-machine takeover of cloud session ${DESIRED_SESSION}..." >&2
  scratch_path="$(cloud_pull_shadow "$DESIRED_SESSION")" || {
    echo "❌ could not pull session ${DESIRED_SESSION} from server" >&2
    exit 1
  }
  # Primary alias — matches the server-side session_id and the scratch
  # dir basename, so cloud_post_* helpers POST to the right row.
  cloud_register_session "$DESIRED_SESSION" "${DEV_WORKFLOW_SERVER}" "" "$scratch_path"
  # Local alias — the current Claude session's id, so resolve_state from
  # hooks/CLI on this machine (which keys on read_cached_session_id)
  # finds the same scratch dir.
  LOCAL_SID="$(read_cached_session_id)"
  if [[ -n "$LOCAL_SID" ]] && [[ "$LOCAL_SID" != "$DESIRED_SESSION" ]]; then
    cloud_register_session "$LOCAL_SID" "${DEV_WORKFLOW_SERVER}" "" "$scratch_path"
  fi
  echo "   Shadow restored at: $scratch_path" >&2
fi

# Resolve the workflow to resume. Strategy:
#   1. If DESIRED_TOPIC or DESIRED_SESSION was set, use resolve_state (scoped).
#   2. Otherwise, scan all .dev-workflow/*/ for a single interrupted run
#      (cross-session takeover — the common case when the user reopened
#      Claude Code in a fresh session).
if [[ -n "${DESIRED_TOPIC:-}" ]] || [[ -n "${DESIRED_SESSION:-}" ]]; then
  if ! resolve_state; then
    echo "No dev workflow matching the given --topic/--session." >&2
    exit 1
  fi
else
  rc=0
  resolve_interrupted_state || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    if [[ "$rc" -eq 2 ]]; then
      # Multiple matches already printed by resolve_interrupted_state
      exit 1
    fi
    echo "No interrupted dev workflow found." >&2
    if workflows=$(list_all_workflows); [[ -n "$workflows" ]]; then
      echo "   Available workflows:" >&2
      echo "$workflows" >&2
    else
      echo "   Start a new workflow with: /dev-workflow:dev <task>" >&2
    fi
    exit 1
  fi
fi

STATUS=$(_read_fm_field "$STATE_FILE" status)
RESUME_STATUS=$(_read_fm_field "$STATE_FILE" resume_status)
IS_CLOUD="false"
if is_cloud_session "$RUN_DIR_NAME"; then
  IS_CLOUD="true"
fi

# ──────────────────────────────────────────────────────────────
# Project identity check
# ──────────────────────────────────────────────────────────────
# Before touching state, verify the current CWD is in the same git
# project the workflow was started in (root commit fingerprint).
# Allows different HEADs but catches "wrong repo entirely".
verify_rc=0
verify_project_match "$STATE_FILE" "$(pwd)" || verify_rc=$?
case $verify_rc in
  0)
    CURRENT_DIR="$(pwd)"
    STORED_PR="$(_read_fm_field "$STATE_FILE" project_root)"
    if [[ -n "$CURRENT_DIR" ]] && [[ "$CURRENT_DIR" != "$STORED_PR" ]]; then
      # Same project, different local path (cross-machine clone or the
      # user cd'd from a subdir). Update project_root so cloud_post_diff
      # and any other downstream git ops use the right working copy.
      set_fm_field "$STATE_FILE" project_root "$CURRENT_DIR"
      PROJECT_ROOT="$CURRENT_DIR"
      if [[ "$IS_CLOUD" == "true" ]]; then
        CUR_EPOCH=$(_read_fm_field "$STATE_FILE" epoch)
        CUR_STATUS=$(_read_fm_field "$STATE_FILE" status)
        cloud_post_state "$RUN_DIR_NAME" "$CUR_STATUS" "${CUR_EPOCH:-1}" "" "true" "$CURRENT_DIR" || true
      fi
      echo "   project_root updated: ${STORED_PR:-<unset>} → $CURRENT_DIR" >&2
    fi
    ;;
  1)
    EXPECTED=$(_read_fm_field "$STATE_FILE" project_fingerprint)
    ACTUAL=$(git_project_fingerprint "$(pwd)")
    echo "❌ Project mismatch: current git repo doesn't match the workflow's project." >&2
    echo "   Current root commits:  $ACTUAL" >&2
    echo "   Workflow root commits: $EXPECTED" >&2
    echo "   cd to the right project and retry, or pass --force-project-mismatch to override." >&2
    [[ "$FORCE_MISMATCH" != "yes" ]] && exit 1
    echo "⚠️  --force-project-mismatch set; continuing anyway." >&2
    ;;
  2)
    EXPECTED=$(_read_fm_field "$STATE_FILE" project_fingerprint)
    echo "❌ Current directory has no git repo, but the workflow was started in one." >&2
    echo "   Workflow root commits: $EXPECTED" >&2
    echo "   cd into the workflow's project dir and retry, or pass --force-project-mismatch." >&2
    [[ "$FORCE_MISMATCH" != "yes" ]] && exit 1
    echo "⚠️  --force-project-mismatch set; continuing anyway." >&2
    ;;
esac

# Terminal workflows (including user-cancelled ones) can't be resumed.
if is_terminal_status "$STATUS" 2>/dev/null; then
  case "$STATUS" in
    cancelled)
      echo "⚠️  Workflow '$TOPIC' was cancelled — resume unavailable." >&2
      echo "    Start a new workflow with /dev-workflow:dev if you want to retry." >&2
      ;;
    *)
      echo "⚠️  Workflow '$TOPIC' is already $STATUS — nothing to resume." >&2
      ;;
  esac
  exit 1
fi

# Decide the phase we're resuming into:
#   - interrupted → restore resume_status (normal /interrupt + /continue flow)
#   - active stage + local mode → must have been interrupted first
#   - active stage + cloud mode → cross-machine takeover; keep the current
#     status as the display phase, stop-hook will drive the stage from there
DISPLAY_PHASE=""
if [[ "$STATUS" == "interrupted" ]]; then
  # If resume_status is empty (corrupt state.md or a legacy run), fall
  # back to the workflow's own initial_stage. No hardcoded stage names.
  if [[ -z "$RESUME_STATUS" ]]; then
    RESUME_STATUS="$(config_initial_stage 2>/dev/null || true)"
  fi
  if [[ -z "$RESUME_STATUS" ]]; then
    echo "⚠️  Workflow '$TOPIC' has no resume_status and no initial_stage — cannot resume safely." >&2
    echo "   Inspect $STATE_FILE and set resume_status manually, or start over with /dev-workflow:dev." >&2
    exit 1
  fi
  DISPLAY_PHASE="$RESUME_STATUS"
elif [[ "$IS_CLOUD" == "true" ]]; then
  DISPLAY_PHASE="$STATUS"
else
  echo "⚠️  Workflow '$TOPIC' is not interrupted (status: $STATUS)." >&2
  echo "   Only interrupted workflows can be continued in local mode." >&2
  exit 1
fi

# ──────────────────────────────────────────────────────────────
# Cross-session takeover (LOCAL MODE ONLY): rename the run dir to this
# session's id so hooks resolve to it from this session onward. In
# cloud mode the shadow dir is keyed by the server session_id and
# resolve_state uses registry aliases, so no rename is needed.
# ──────────────────────────────────────────────────────────────
if [[ "$IS_CLOUD" != "true" ]]; then
  NEW_SESSION="$(read_cached_session_id)"
  OLD_SESSION="$RUN_DIR_NAME"
  if [[ -n "$NEW_SESSION" ]] && [[ "$NEW_SESSION" != "$OLD_SESSION" ]]; then
    NEW_DIR="${PROJECT_ROOT}/.dev-workflow/${NEW_SESSION}"
    if [[ -e "$NEW_DIR" ]]; then
      echo "⚠️  This session already has a workflow dir at $NEW_DIR — refusing to overwrite." >&2
      echo "   Cancel or resolve that run first, then retry continue." >&2
      exit 1
    fi
    mv "$TOPIC_DIR" "$NEW_DIR"
    TOPIC_DIR="$NEW_DIR"
    STATE_FILE="$NEW_DIR/state.md"
    RUN_DIR_NAME="$NEW_SESSION"
    set_fm_field "$STATE_FILE" session_id "$NEW_SESSION"
  fi
fi

# Restore active status. On an interrupted-style resume this flips
# back to the saved resume_status; on a cloud cross-machine takeover
# of an already-active stage we leave the status alone (DISPLAY_PHASE
# equals $STATUS).
if [[ "$STATUS" == "interrupted" ]]; then
  set_fm_field "$STATE_FILE" status "$RESUME_STATUS"
  set_fm_field "$STATE_FILE" resume_status ""
fi

if [[ "$IS_CLOUD" == "true" ]]; then
  CUR_EPOCH=$(_read_fm_field "$STATE_FILE" epoch)
  cloud_post_state "$RUN_DIR_NAME" "$DISPLAY_PHASE" "${CUR_EPOCH:-1}" "" "true" || {
    echo "⚠️  cloud resume sync failed" >&2
  }
fi

echo "▶️  Dev workflow resumed."
echo ""
echo "   Topic:  $TOPIC"
echo "   Phase:  $DISPLAY_PHASE"
echo "   Session: $RUN_DIR_NAME"
echo "   State dir: $TOPIC_DIR"
echo ""
echo "   The stop hook is now active again."
echo "   To interrupt again: /dev-workflow:interrupt"
echo "   To cancel: /dev-workflow:cancel"
