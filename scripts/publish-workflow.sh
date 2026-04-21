#!/bin/bash
#
# Publish a local workflow directory to the workflow hub on the
# workflowUI server.
#
# Usage:
#   publish-workflow.sh <workflow-dir>
#       [--name <name>]
#       [--description <desc>]
#       [--dry-run]
#
# The directory must contain:
#   workflow.json              (required)  — stages/transitions config
#   readme.md                  (optional)  — rendered on the hub detail page
#   <stage>.md (one per stage) (optional)  — per-stage instructions
#
# Any other files in the directory are ignored. `name` defaults to the
# directory's basename and must be a bare slug. `description` is
# auto-derived from readme.md's first non-heading line when omitted.
# `--dry-run` prints what would be uploaded without touching the server.
#
# After a successful publish, the workflow can be pulled by the plugin via:
#   /meta-workflow:start --workflow <name> <task>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

print_help() {
  cat <<'EOF'
Usage: publish-workflow.sh <workflow-dir> [options]

Arguments:
  <workflow-dir>           Path to a directory containing workflow.json and
                           (optionally) readme.md + one <stage>.md per stage.

Options:
  --name <name>            Hub name (default: dir basename).
                           Must match [A-Za-z0-9][A-Za-z0-9._-]*.
  --description <desc>     One-line description for the hub list. If omitted,
                           auto-derived from readme.md's first non-heading line.
  --dry-run                Print the PUT body + target URL without sending.
  -h, --help               Show this message.

Environment:
  META_WORKFLOW_SERVER      Hub server URL (default: baked-in plugin default).

Example:
  publish-workflow.sh ./my-workflow --name bugfix-fast --description "Quick bugfix pipeline"
EOF
}

DIR=""
NAME=""
DESCRIPTION=""
VISIBILITY=""
DRY_RUN=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name=*)
      NAME="${1#--name=}"
      shift
      ;;
    --name)
      [[ $# -ge 2 ]] || { echo "❌ --name needs a value" >&2; exit 1; }
      NAME="$2"
      shift 2
      ;;
    --description=*)
      DESCRIPTION="${1#--description=}"
      shift
      ;;
    --visibility=*)
      VISIBILITY="${1#--visibility=}"
      shift
      ;;
    --visibility)
      [[ $# -ge 2 ]] || { echo "❌ --visibility needs a value" >&2; exit 1; }
      VISIBILITY="$2"
      shift 2
      ;;
    --description)
      [[ $# -ge 2 ]] || { echo "❌ --description needs a value" >&2; exit 1; }
      DESCRIPTION="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN="yes"
      shift
      ;;
    -h|--help)
      print_help
      exit 0
      ;;
    --)
      shift
      while [[ $# -gt 0 ]]; do
        [[ -z "$DIR" ]] && DIR="$1" || { echo "❌ unexpected arg: $1" >&2; exit 1; }
        shift
      done
      ;;
    -*)
      echo "❌ unknown option: $1" >&2
      print_help
      exit 1
      ;;
    *)
      if [[ -z "$DIR" ]]; then
        DIR="$1"
      else
        echo "❌ unexpected positional arg: $1" >&2
        exit 1
      fi
      shift
      ;;
  esac
done

if [[ -z "$DIR" ]]; then
  echo "❌ workflow directory is required" >&2
  print_help
  exit 1
fi

# Resolve to absolute path so later cd/cat are unambiguous.
if [[ ! -d "$DIR" ]]; then
  echo "❌ not a directory: $DIR" >&2
  exit 1
fi
DIR="$(cd "$DIR" && pwd)"

# ── Gate on login early (before any schema validation) ──
if [[ -z "$DRY_RUN" ]] && ! cloud_is_logged_in; then
  echo "❌ Publishing requires a logged-in account." >&2
  echo "   Run /meta-workflow:login first, then retry." >&2
  exit 1
fi

# ── Validate workflow.json ──
WF_FILE="${DIR}/workflow.json"
if [[ ! -f "$WF_FILE" ]]; then
  echo "❌ ${WF_FILE} not found" >&2
  echo "   A workflow dir must contain workflow.json." >&2
  exit 1
fi
if ! jq empty "$WF_FILE" 2>/dev/null; then
  echo "❌ ${WF_FILE} is not valid JSON" >&2
  exit 1
fi

INITIAL_STAGE="$(jq -r '.initial_stage // ""' "$WF_FILE")"
if [[ -z "$INITIAL_STAGE" ]]; then
  echo "❌ workflow.json is missing \`initial_stage\`" >&2
  exit 1
fi
STAGE_KEYS=()
while IFS= read -r key; do
  [[ -n "$key" ]] && STAGE_KEYS+=("$key")
done < <(jq -r '.stages | keys[]?' "$WF_FILE")
if [[ ${#STAGE_KEYS[@]} -eq 0 ]]; then
  echo "❌ workflow.json has no \`stages\`" >&2
  exit 1
fi

# ── Full workflow validation (transitions, inputs, stage files) ──
_PLUGIN_ROOT="$(cat ~/.config/meta-workflow/plugin-root 2>/dev/null || true)"
[[ -d "${_PLUGIN_ROOT}/scripts" ]] || _PLUGIN_ROOT=~/.claude/plugins/meta-workflow
[[ -d "${_PLUGIN_ROOT}/scripts" ]] || _PLUGIN_ROOT="$(ls -d ~/.claude/plugins/cache/*/meta-workflow/*/ 2>/dev/null | head -1)"
if [[ -z "$DRY_RUN" ]]; then
  if ! "${_PLUGIN_ROOT}/scripts/setup-workflow.sh" --validate-only --workflow="$DIR"; then
    echo "❌ Workflow validation failed — fix the errors above before publishing." >&2
    exit 1
  fi
fi

# ── Resolve name (default: author/basename) + validate slug ──
if [[ -z "$NAME" ]]; then
  _author_raw="$(jq -r '.author // "anonymous"' "${HOME}/.config/meta-workflow/auth.json" 2>/dev/null || echo "anonymous")"
  # Slugify: lowercase, spaces→hyphens, strip non-slug chars
  _author="$(echo "$_author_raw" | tr '[:upper:]' '[:lower:]' | sed 's/[[:space:]][[:space:]]*/\-/g; s/[^a-z0-9._-]//g; s/^[^a-z0-9]*//')"
  _author="${_author:-anonymous}"
  _basename="$(basename "$DIR")"
  NAME="${_author}/${_basename}"
fi
# Allow either flat slug or username/workflow-name
if ! [[ "$NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$ ]] && \
   ! [[ "$NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  echo "❌ name '${NAME}' must be a slug or username/slug" >&2
  exit 1
fi

# ── Warn on missing optional files ──
MISSING_STAGES=()
for stage in "${STAGE_KEYS[@]}"; do
  [[ -f "${DIR}/${stage}.md" ]] || MISSING_STAGES+=("${stage}.md")
done
if [[ ${#MISSING_STAGES[@]} -gt 0 ]]; then
  echo "⚠️  Stage instructions missing: ${MISSING_STAGES[*]}" >&2
  echo "   These stages will be uploaded without a <stage>.md." >&2
fi
if [[ ! -f "${DIR}/readme.md" ]]; then
  echo "⚠️  No readme.md in ${DIR}" >&2
  echo "   The hub detail page will show a 'no readme' banner." >&2
fi

# ── Build the files map via jq merging ──
# Include workflow.json + every *.md file at the top level. Any other
# file (nested dirs, binaries, README.md with uppercase R, etc.) is
# skipped — the hub API only knows about markdown + json.
FILES_JSON="{}"
shopt -s nullglob
CANDIDATES=("$WF_FILE")
for f in "$DIR"/*.md; do
  [[ -f "$f" ]] && CANDIDATES+=("$f")
done
shopt -u nullglob

for f in "${CANDIDATES[@]}"; do
  fname="$(basename "$f")"
  content="$(cat "$f")"
  FILES_JSON="$(jq -n --argjson base "$FILES_JSON" --arg k "$fname" --arg v "$content" \
                '$base + {($k): $v}')"
done

PAYLOAD="$(jq -n --argjson files "$FILES_JSON" --arg desc "$DESCRIPTION" --arg vis "$VISIBILITY" \
  '{files: $files} + (if $desc == "" then {} else {description: $desc} end) + (if $vis == "" then {} else {visibility: $vis} end)')"

# Server URL is always populated via lib.sh's default; require_env
# validates it didn't get unset out from under us.
cloud_require_env || exit 1
URL="${META_WORKFLOW_SERVER}/api/workflows/${NAME}"

# ── Pre-check: does a workflow with this name already exist? ──
# GET the workflow before the PUT so we can give a clear error if the
# name is owned by a different user, instead of a raw HTTP error code.
if [[ -z "$DRY_RUN" ]]; then
  _pre_tmp="$(mktemp -t dw-precheck-XXXXXX)"
  _pre_rc=0
  _pre_code="$(curl -sS -o "$_pre_tmp" -w "%{http_code}" \
    -H "$(_cloud_auth_header)" \
    "$URL" 2>/dev/null)" || _pre_rc=$?
  if [[ $_pre_rc -ne 0 ]]; then
    cloud_explain_curl_exit "$_pre_rc" "$META_WORKFLOW_SERVER"
    rm -f "$_pre_tmp"
    exit 1
  fi
  if [[ "$_pre_code" == "200" ]]; then
    _remote_uid="$(jq -r '.user_id // .workflow.user_id // empty' "$_pre_tmp" 2>/dev/null || echo "")"
    _my_uid="$(jq -r '.user_id // empty' ~/.config/meta-workflow/auth.json 2>/dev/null || echo "")"
    if [[ -n "$_remote_uid" && -n "$_my_uid" && "$_remote_uid" != "$_my_uid" ]]; then
      echo "❌ Name '${NAME}' is already taken by another user." >&2
      rm -f "$_pre_tmp"
      exit 1
    fi
    echo "⚠️  Updating existing workflow '${NAME}' on the hub." >&2
  fi
  rm -f "$_pre_tmp"
fi

if [[ -n "$DRY_RUN" ]]; then
  echo "── dry run ──"
  echo "  PUT ${URL}"
  echo "  name:        ${NAME}"
  echo "  description: ${DESCRIPTION:-<auto-derived from readme.md>}"
  echo "  files:"
  printf '%s' "$FILES_JSON" | jq -r 'to_entries[] | "    - \(.key)  (\(.value | length) bytes)"'
  exit 0
fi

# ── PUT ──
tmp_body="$(mktemp -t dw-publish-XXXXXX)"
trap 'rm -f "$tmp_body"' EXIT

put_rc=0
http_code=$(curl -sS -o "$tmp_body" -w "%{http_code}" \
    -X PUT "$URL" \
    -H "$(_cloud_auth_header)" \
    -H "Content-Type: application/json" \
    --data "$PAYLOAD" 2>/dev/null) || put_rc=$?

if [[ $put_rc -ne 0 ]]; then
  cloud_explain_curl_exit "$put_rc" "$META_WORKFLOW_SERVER"
  exit 1
fi

if [[ "$http_code" != "200" ]]; then
  case "$http_code" in
    403) echo "❌ Permission denied — '${NAME}' may be owned by a different user." >&2 ;;
    409) echo "❌ Name '${NAME}' is already taken by another user." >&2 ;;
    *)   echo "❌ Publish failed (HTTP ${http_code})." >&2 ;;
  esac
  cat "$tmp_body" >&2
  echo "" >&2
  exit 1
fi

FINAL_DESC="$(jq -r '.description // ""' "$tmp_body" 2>/dev/null || echo "")"
FILE_LIST="$(jq -r '.files | join(", ")' "$tmp_body" 2>/dev/null || echo "")"

echo "✅ Published '${NAME}' to the hub"
echo ""
echo "   Files:       ${FILE_LIST}"
echo "   Description: ${FINAL_DESC:-<empty>}"
echo "   Hub URL:     ${META_WORKFLOW_SERVER}/hub/${NAME}"
echo ""
echo "   Pull with:"
echo "     /meta-workflow:start --workflow ${NAME} <task>"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📍 RELAY THIS TO THE USER VERBATIM BEFORE CONTINUING:"
echo ""
echo "   Workflow published — hub URL:"
echo "   ${META_WORKFLOW_SERVER}/hub/${NAME}"
echo ""
echo "   (The user needs this link to view / share their workflow."
echo "    Do not summarise it away — paste it as-is in your next message.)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
