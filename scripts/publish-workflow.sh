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
#   /dev-workflow:dev --workflow <name> <task>

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
  DEV_WORKFLOW_SERVER      Hub server URL (default: baked-in plugin default).

Example:
  publish-workflow.sh ./my-workflow --name bugfix-fast --description "Quick bugfix pipeline"
EOF
}

DIR=""
NAME=""
DESCRIPTION=""
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

# ── Resolve name (default: author/basename) + validate slug ──
if [[ -z "$NAME" ]]; then
  _author="$(jq -r '.author // "anonymous"' "${HOME}/.dev-workflow/auth.json" 2>/dev/null || echo "anonymous")"
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

PAYLOAD="$(jq -n --argjson files "$FILES_JSON" --arg desc "$DESCRIPTION" \
  '{files: $files} + (if $desc == "" then {} else {description: $desc} end)')"

# Server URL is always populated via lib.sh's default; require_env
# validates it didn't get unset out from under us.
cloud_require_env || exit 1
URL="${DEV_WORKFLOW_SERVER}/api/workflows/${NAME}"

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

http_code=$(curl -sS -o "$tmp_body" -w "%{http_code}" \
    -X PUT "$URL" \
    -H "$(_cloud_auth_header)" \
    -H "Content-Type: application/json" \
    --data "$PAYLOAD" || echo "000")

if [[ "$http_code" != "200" ]]; then
  echo "❌ PUT failed with HTTP ${http_code}" >&2
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
echo "   Hub URL:     ${DEV_WORKFLOW_SERVER}/hub/${NAME}"
echo ""
echo "   Pull with:"
echo "     /dev-workflow:dev --workflow ${NAME} <task>"
