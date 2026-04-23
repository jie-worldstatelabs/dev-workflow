---
description: "Publish a local workflow directory to the cloud workflow hub"
argument-hint: "<workflow-dir> [--name <name>] [--description <desc>] [--dry-run]"
allowed-tools: Bash, Read, Glob
---

Publish a local workflow directory to the workflow hub served by
`$STAGENT_SERVER` (default: the baked-in plugin server).

The directory must contain `workflow.json`; `readme.md` and one
`<stage>.md` per stage declared in `workflow.json` are optional but
recommended. `name` defaults to the directory's basename; `description`
is auto-derived from `readme.md`'s first non-heading line when omitted.

Arguments from the user: `$ARGUMENTS`

## Step 1: Upload the bundle

```!
bash "${CLAUDE_PLUGIN_ROOT}/scripts/publish-workflow.sh" $ARGUMENTS
```

The script prints the resulting Hub URL on success, plus the one-line
pull command a teammate can use from their own plugin:

```
/stagent:start --flow=cloud://<name> <task>
```

## Step 2 (optional): confirm in the browser

Open the Hub URL printed above to verify the README renders, the
state-machine graph looks right, and each stage's markdown shows up
when you click its node.
