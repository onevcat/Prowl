# Workflow Actions

Use an action for deterministic file, repository, or tool work. Use an agent role for tasks
that need judgment. Actions await a result; they cannot declare `expect` or call
`prowl workflow done`. They are separate from the app's shell-command Custom Actions.

## Package layout

```text
report.pwlworkflow/
  workflow.yaml
  actions/
    summarize/
      action.yaml
      main.py
      helpers.py
```

Use `action: local:summarize` for that package or `action: builtin:git.context` for Prowl's
repository collector. Local IDs are slugs. There is no global script registry. Helpers,
schemas, and assets must live inside the workflow bundle. Symlinks and special files are
rejected. Pass the bundle directory to `prowl workflow validate`, not `workflow.yaml`.

A script declaration:

```yaml
schema: prowl.action/v1
name: Summarize files
input_schema:
  type: object
  properties:
    paths: {type: array, items: {type: string}}
  required: [paths]
  additionalProperties: false
output_schema:
  type: object
  properties:
    count: {type: integer}
  required: [count]
  additionalProperties: false
backend:
  type: script
  interpreter: python3
  entrypoint: main.py
  arguments: []
  environment: []
timeout: 30s
```

The interpreter is a literal executable name resolved through Prowl's PATH, or an absolute
executable path. The entrypoint is relative to its action directory and cannot escape it.
Arguments are literal strings. Schema defaults do not insert missing inputs. Input and
output roots must be objects, validated with JSON Schema Draft 2020-12, without network
schema fetching.

## Request and result

The script receives one JSON object on stdin:

```json
{
  "protocol": "prowl.action/v1",
  "input": {"paths": ["README.md"]},
  "context": {
    "execution": {
      "id": "<execution UUID>",
      "step_id": "summarize",
      "attempt": 1,
      "cwd": "/repo",
      "artifact_dir": "/repo/.prowl/workflow-runs/<run>/actions/summarize/<execution>/artifacts"
    }
  }
}
```

`context` also contains the workflow's step snapshot; see [authoring](authoring.md).
The working directory is the selected worktree. Write exactly one schema-conforming JSON
object to stdout; put diagnostics on stderr. Exit zero is necessary for success.

```python
import json
import sys

request = json.load(sys.stdin)
json.dump({"count": len(request["input"]["paths"])}, sys.stdout)
```

The workflow supplies typed values:

```yaml
- id: summarize
  action: local:summarize
  with:
    paths: [README.md, CHANGELOG.md]
- id: report
  notify: "Found {{ actions.summarize.output.count }} files"
```

A complete `{{ expression }}` retains its JSON type in `with`; interpolation in larger
text accepts scalars only. Results appear at `actions.<step>.output` and the invocation's
JSON file at `actions.<step>.result_path`. Retain results in typed state before leaving a
branch or loop iteration if later steps need them.

## Approval and testing

Scripts run with the local user's permissions. Review their code, helpers, and assets in
**Settings > Agents > Workflows > Review Bundle…**, then approve that exact version.
Approval covers the canonical source location and every file's content. Moving the bundle
or editing any file requires review again. Approval does not start a run. CLI commands do
not grant approval. Start-time inputs and changing repository contents do not alter the grant.

Prowl copies the approved definition into each run and checks its integrity before actions.
Editing the source affects future runs; editing the run copy invalidates the current run.
Cancel an invalidated run and start a newly reviewed version.

After validation and approval, test one action through the normal runner:

```bash
prowl workflow test-action report local:summarize --input-json '{"paths":["README.md"]}' --json
prowl workflow status <run-id> --json
```

The first argument is a discovered workflow ID/name. An optional source selects the target
worktree as for `workflow run`. Tests create real runs and have real side effects. Then run
the whole workflow to verify expressions, result scopes, and agent handoffs together.

Each attempt uses a new UUID under `actions/<step>/<execution>/`, with `request.json`,
`result.json` on success, `execution.json`, `stderr.log`, and `artifacts/`. Inspect these
records after failures. Manual retry can repeat side effects; no automatic retry or rollback
is promised. Cancel/timeout terminates the owned script process group. It does not undo work
already done or stop independent agent tasks.

Default timeout: 30 seconds. Stdout and stderr: 1 MiB each. Request: 1 MiB. JSON depth: 64.
Bundle: 16 MiB and 2048 files. Interpreter environment starts with PATH, HOME, TMPDIR, LANG,
and LC_ALL when present. `backend.environment` names extra inherited variables; `PROWL_*`
control variables are always stripped. Environment values are not recorded in the request.

## Built-in repository context

`builtin:git.context` takes optional `root`, restricted to the selected worktree, and returns
`output.path` plus `output.branch`. It writes the Markdown repository summary into this
invocation's `artifacts/context.md`. It does not write shared handoff files. Workflow
`handoff.transition` and `handoff.checkpoint` were removed; the separate `prowl handoff` CLI
remains available for its existing purpose.

`prowl workflow schema --action` exports the manifest schema. Schema references can use
local JSON or YAML files in the same bundle. Network references and `$id` overrides are
rejected; use local `$ref` paths and anchors. `--input-json` supplies literal JSON data,
so strings containing `{{` are not evaluated as workflow expressions.
