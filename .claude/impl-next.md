# impl-next profile — Prowl

The repository profile for the `impl-next` workflow. `CLAUDE.md` still applies where this
file says nothing.

## Task sources

Check these in order:

1. **Half-done work.**
   - An open PR by onevcat with review comments or failing checks.
   - A branch with unmerged commits.
   - A docs-ai slice that has a PR but is not finished.
2. **The next slice of an active docs-ai entry.**
   - An entry in `docs-ai/README.md` is active when the `Status` of its `000-plan.md` is
     Planned or In progress and the plan has a slice table. Today that is
     `docs-ai/084-ssh-remote-folders`, with slices P0, A1–A7, B1–B3, C1–C5. 082 keeps L1f,
     L1g–L1h and L2.
   - A slice is done when its PR is merged and its `00N-<slice>.md` amendment exists.
   - Take slices in table order. Respect each plan's exposure gates (for example, 084 keeps
     `PROWL_REMOTE_FOLDERS` off until C5) and its "Behaviour change" column.
   - A slice marked "independent fix from `main`" can go before its neighbours.
3. **Candidates for the user to pick.**
   - Open PRs from contributors (review, or take over as a `takeover/pr-<n>` branch).
   - Open issues in `onevcat/Prowl`.
   - Issues in the Linear project "Prowl" (team CLAW).

## Branch and PR

- A new branch from the latest `origin/main`, named `<type>/<topic>-<slice>` (for example
  `feat/ssh-l1-a1-terminal-worktree`).
- A slice that depends on an unmerged slice branches from that slice's branch, opens its PR
  with `--base <predecessor branch>`, and joins the stack with
  `GH_REPO=onevcat/Prowl gh stack link <PRs in order>`.
- PRs target `onevcat/Prowl`. Do not open them as drafts.

## Checks

Run all of these before the PR. Look at the real exit status: `xcodebuild | xcsift` returns
the exit code of `xcsift`.

- `make check`. If `swift-format` is not found, prepend
  `$(dirname "$(xcrun --find swift-format)")` to `PATH`.
- `make build-app`.
- `make test`: the full suite, not a subset. Wait logic only fails under full-suite load.
- For changes under `CLI/`, `Shared/` or `Mirror/Relay/`, also run `make build-cli`,
  `make test-cli-smoke`, `make test-cli-unit` and `make test-cli-integration`.
- Swift Testing ids in `-only-testing` need a trailing `()`. Without it, xcodebuild runs
  zero tests and reports success.

## Design records

- A slice of a multi-PR entry ships its own `docs-ai/<entry>/00N-<slice>.md` amendment in
  its PR. Add the matching line to the plan's Amendments and add the PR to Primary PRs.
- Write `001-action.md` once, when the last slice lands. Follow the `write-ai-doc` skill.
- When user-facing behaviour changes, update `docs/` in the same PR.

## Review

- Run the review loop with the Pi Reviewer:

  ```bash
  prowl workflow run prowl.review-loop --role reviewer="Pi Reviewer" --input max_rounds=5 \
    --input focus="<PR, slice, worktree path, what to check>" --json
  ```

- The brief must say:
  - the reviewer works only in this worktree's path;
  - the reviewer runs at most one `xcodebuild` at a time;
  - main does not build while the reviewer works (a second `xcodebuild test` in one
    checkout hangs at 0 % CPU).
- Commit and push before you start the loop. Do not change files between a delivery and
  the next round.

## E2E

- Use the `self-verify-prowl` skill: an isolated Prowl Debug instance with its own
  `PROWL_CLI_SOCKET` and `CFFIXED_USER_HOME`, never the user's live app. For native UI
  (Settings, sheets, menus, sidebar), use `prowl-ui` after its preflight returns `READY`.
- Run `caffeinate -d -u` for the whole run. Display sleep breaks surface creation, and a
  locked screen removes panes from the AX tree.
- The app that `make build-app` builds lives in a different DerivedData folder than the one
  `xcodebuild test` uses. Take `BUILT_PRODUCTS_DIR` from `-showBuildSettings`, or the E2E
  run tests old code.
- SSH test hosts:
  - mini, `onevcatdemac-mini.local`. Run `TERM=xterm-256color ssh …`, because mini has no
    `xterm-ghostty` terminfo. Do not touch tmux session `0`.
  - the Debian container `prowl-sshd-test` (port 2222, user `dev`).
- Take window-scoped screenshots, then attach them with `gh pr comment <n> --attach`.

## Quirks

- Confirm the branch before every commit. A shared checkout can be switched to `main`
  under you.
- In unit tests, never use `Task.sleep`; use `TestClock`. Do not block the main thread
  inside a `Task` in tests: TCA's main serial executor stays on during the full suite.
