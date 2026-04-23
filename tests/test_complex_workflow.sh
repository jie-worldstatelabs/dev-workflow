#!/bin/bash
# T12 — complex workflow.json: conditional transitions, cycles, required_inputs
#        Validated via setup-workflow.sh --validate-only and lib.sh config functions.

set -euo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "${TESTS_DIR}/.." && pwd)"
source "${TESTS_DIR}/helpers.sh"
source "${PLUGIN_ROOT}/scripts/lib.sh"

echo "T12 — complex workflow.json structures"

VALIDATE="${PLUGIN_ROOT}/scripts/setup-workflow.sh"

TMP="$(make_tmpdir)"
trap 'rm -rf "$TMP"' EXIT

# ── T12-1: Conditional transitions (fan-out) — valid ─────────────────────────
# stage A has two outgoing transitions: one to B, one to C (conditional paths)
mkdir -p "$TMP/cond"
cat > "$TMP/cond/workflow.json" <<'EOF'
{
  "initial_stage": "triage",
  "terminal_stages": ["resolved", "escalated"],
  "stages": {
    "triage": {
      "execution": { "type": "inline" },
      "transitions": { "simple": "patch", "complex": "design" }
    },
    "patch": {
      "execution": { "type": "inline" },
      "transitions": { "done": "resolved" }
    },
    "design": {
      "execution": { "type": "inline" },
      "transitions": { "done": "resolved", "blocked": "escalated" }
    }
  }
}
EOF
touch "$TMP/cond/triage.md" "$TMP/cond/patch.md" "$TMP/cond/design.md"
"$VALIDATE" --validate-only --flow="$TMP/cond" 2>/dev/null
check "conditional fan-out transitions → valid" $?

# ── T12-2: Cycle (A → B → A) — valid (cycles are allowed state machine loops) ─
mkdir -p "$TMP/cycle"
cat > "$TMP/cycle/workflow.json" <<'EOF'
{
  "initial_stage": "plan",
  "terminal_stages": ["done"],
  "stages": {
    "plan": {
      "execution": { "type": "inline" },
      "transitions": { "approved": "review", "done": "done" }
    },
    "review": {
      "execution": { "type": "inline" },
      "transitions": { "pass": "done", "fail": "plan" }
    }
  }
}
EOF
touch "$TMP/cycle/plan.md" "$TMP/cycle/review.md"
"$VALIDATE" --validate-only --flow="$TMP/cycle" 2>/dev/null
check "cycle (plan→review→plan) → valid" $?

# ── T12-3: Transition to undefined stage → validation fails ──────────────────
mkdir -p "$TMP/bad_trans"
cat > "$TMP/bad_trans/workflow.json" <<'EOF'
{
  "initial_stage": "plan",
  "terminal_stages": ["done"],
  "stages": {
    "plan": {
      "execution": { "type": "inline" },
      "transitions": { "go": "nonexistent_stage" }
    }
  }
}
EOF
touch "$TMP/bad_trans/plan.md"
rc=0; "$VALIDATE" --validate-only --flow="$TMP/bad_trans" 2>/dev/null || rc=$?
[[ $rc -ne 0 ]]
check "transition to undefined stage → validation fails" $?

# ── T12-4: initial_stage not in stages → validation fails ────────────────────
mkdir -p "$TMP/bad_init"
cat > "$TMP/bad_init/workflow.json" <<'EOF'
{
  "initial_stage": "missing",
  "terminal_stages": ["done"],
  "stages": {
    "plan": {
      "execution": { "type": "inline" },
      "transitions": { "done": "done" }
    }
  }
}
EOF
touch "$TMP/bad_init/plan.md"
rc=0; "$VALIDATE" --validate-only --flow="$TMP/bad_init" 2>/dev/null || rc=$?
[[ $rc -ne 0 ]]
check "initial_stage not in stages → validation fails" $?

# ── T12-5: required_inputs from_stage — config_required_inputs resolution ────
# Uses helpers from lib.sh directly to test input path resolution.
mkdir -p "$TMP/inputs"
cat > "$TMP/inputs/workflow.json" <<'EOF'
{
  "initial_stage": "plan",
  "terminal_stages": ["done"],
  "stages": {
    "plan": {
      "execution": { "type": "inline" },
      "transitions": { "approved": "verify" }
    },
    "verify": {
      "execution": { "type": "subagent" },
      "transitions": { "pass": "done" },
      "inputs": {
        "required": [
          { "from_stage": "plan", "description": "Plan report" }
        ],
        "optional": []
      }
    }
  }
}
EOF
touch "$TMP/inputs/plan.md" "$TMP/inputs/verify.md"
use_workflow "$TMP/inputs"
use_run_dir "$TMP/inputs/run"
mkdir -p "$TMP/inputs/run"
RUN_DIR_NAME="run"
PROJECT_ROOT="$TMP/inputs"

# config_required_inputs should yield a from_stage entry for "verify"
required="$(config_required_inputs "verify" 2>/dev/null)"
echo "$required" | grep -q "plan"
check "required_inputs from_stage: config_required_inputs yields from_stage=plan" $?

# ── T12-6: required_inputs from_run_file — path resolves to run dir ──────────
mkdir -p "$TMP/runfile"
cat > "$TMP/runfile/workflow.json" <<'EOF'
{
  "initial_stage": "build",
  "terminal_stages": ["done"],
  "run_files": {
    "snapshot": {
      "description": "Repo snapshot at start",
      "init": "echo snapshot"
    }
  },
  "stages": {
    "build": {
      "execution": { "type": "inline" },
      "transitions": { "done": "done" },
      "inputs": {
        "required": [
          { "from_run_file": "snapshot", "description": "Initial snapshot" }
        ]
      }
    }
  }
}
EOF
touch "$TMP/runfile/build.md"
use_workflow "$TMP/runfile"
use_run_dir "$TMP/runfile/run"
mkdir -p "$TMP/runfile/run"

path="$(config_run_file_path "snapshot" "" "$TMP/runfile" 2>/dev/null)"
[[ "$path" == "$TMP/runfile/run/snapshot" ]]
check "from_run_file: config_run_file_path resolves to run dir" $?

# ── T12-7: Multi-stage chain (4 stages) with required_inputs — valid ─────────
mkdir -p "$TMP/chain"
cat > "$TMP/chain/workflow.json" <<'EOF'
{
  "initial_stage": "research",
  "terminal_stages": ["shipped", "abandoned"],
  "stages": {
    "research": {
      "execution": { "type": "inline" },
      "transitions": { "proceed": "design", "abandon": "abandoned" }
    },
    "design": {
      "execution": { "type": "inline" },
      "transitions": { "proceed": "implement", "back": "research" },
      "inputs": {
        "required": [{ "from_stage": "research", "description": "Research output" }]
      }
    },
    "implement": {
      "execution": { "type": "subagent" },
      "transitions": { "done": "shipped", "back": "design" },
      "inputs": {
        "required": [{ "from_stage": "design", "description": "Design spec" }]
      }
    }
  }
}
EOF
touch "$TMP/chain/research.md" "$TMP/chain/design.md" "$TMP/chain/implement.md"
"$VALIDATE" --validate-only --flow="$TMP/chain" 2>/dev/null
check "4-stage chain with conditional back-edges + required_inputs → valid" $?

# ── T12-8: required_inputs from_stage refs undefined stage → validation fails ─
mkdir -p "$TMP/bad_input"
cat > "$TMP/bad_input/workflow.json" <<'EOF'
{
  "initial_stage": "build",
  "terminal_stages": ["done"],
  "stages": {
    "build": {
      "execution": { "type": "inline" },
      "transitions": { "done": "done" },
      "inputs": {
        "required": [
          { "from_stage": "nonexistent", "description": "Missing stage output" }
        ]
      }
    }
  }
}
EOF
touch "$TMP/bad_input/build.md"
rc=0; "$VALIDATE" --validate-only --flow="$TMP/bad_input" 2>/dev/null || rc=$?
[[ $rc -ne 0 ]]
check "required_inputs from_stage refs undefined stage → validation fails" $?

print_summary
