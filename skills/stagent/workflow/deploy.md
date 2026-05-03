# Stage: deploy

_Runtime config (canonical): `workflow.json` → `stages.deploy`_

**Purpose:** deploy the webapp to Vercel via the Vercel CLI and record the production URL.
**Output artifact:** write to the absolute path provided in your prompt
**Valid results this stage writes:** `pending` (deploy in progress / awaiting user action), `deployed` (production deploy succeeded and smoke-checked)

This is an interruptible stage — natural pauses are allowed for first-time `vercel login`, project linking, env-var input, or inspecting failed deploys.

## Inputs

- **Required:**
  - `planning` report — read for: Vercel project name, scope, production env vars (names), build command override, deployment notes
  - `qa-ing` report — confirms QA passed (the state machine only routes here on `qa-ing.PASS`)

## Step 1 — Prerequisite checks

In the project root:

```bash
which vercel || npm i -g vercel
vercel whoami
```

If `vercel whoami` reports not logged in:

> "You're not logged into Vercel. Run `vercel login` in another terminal, then tell me to continue."

Stop and wait for the user. Re-run `vercel whoami` after they confirm. Keep `result: pending` while waiting.

## Step 2 — Project linking

Check whether `.vercel/project.json` exists.

- **Exists** → already linked. Continue.
- **Missing** → first deploy in this workdir. Link the project:
  ```bash
  vercel link --yes
  ```
  Use the project name + scope from the plan if available. If `vercel link` needs interactive answers, surface the prompt to the user and pause (interruptible).

## Step 3 — Sync production env vars

Read the plan for the list of required production env vars (names only — values supplied by the user or already configured).

For each name in the plan that isn't already in `vercel env ls production`, ask the user for the value (one var per message), then set it:

```bash
echo -n "<value>" | vercel env add <NAME> production
```

If the plan listed env vars but the user can't provide values yet, keep `result: pending` and wait.

## Step 4 — Production deploy

Run the production deploy:

```bash
vercel --prod --yes 2>&1 | tee /tmp/vercel-deploy.log
```

Extract the deployment URL from the output (matches `https://<project>-...vercel.app` or the configured alias).

If the deploy fails (build error, Vercel API error, missing env vars caught at build time), surface the relevant tail of `/tmp/vercel-deploy.log` to the user, keep `result: pending`, and ask whether to:
- Re-run deploy (the user fixed something out-of-band)
- Loop back through the workflow (escalate manually — the user can `/stagent:cancel` and restart)

## Step 5 — Smoke check

```bash
curl -sS -o /dev/null -w "%{http_code}" "<DEPLOY_URL>"
```

- `2xx` → deploy is reachable, mark deployed.
- `401` (auth-protected app) → ask the user whether to treat as success.
- Anything else → surface the status to the user; keep `pending` and ask whether to re-deploy or accept.

## Step 6 — Write the deploy report

```markdown
---
epoch: <epoch>
result: deployed
---
# Deploy Report

## Deployment URL
<https://...>

## Vercel Project
- name: <...>
- scope: <...>

## Environment Variables Set
- <NAME> (production)
- ...

## Smoke Check
- HTTP status: <200 / ...>

## Deploy Log Tail
<last 30 lines of `vercel --prod` output>
```

## Finalize

Once the deploy is live and smoke-checked, set `result: deployed`. The main loop reads `result:` and calls `update-status.sh` to advance to `complete` — do NOT call it yourself from this stage file.

## Rules

- Treat `result: deployed` as the final commit. Don't write it speculatively — only after a successful production deploy whose URL returns an acceptable HTTP status.
- Keep secrets out of the report — record env-var **names**, never values.
- If the user wants to abort partway, they use `/stagent:cancel`. Don't try to "auto-rollback" from this stage.
