# Agent Screen Detection Fixture Corpus

This directory contains sanitized, capture-derived inputs for the production screen
classifier. It is a regression suite, not a transcript archive and not a replacement for
focused inline predicate tests.

## Layout

Normal fixture:

```text
<runtime>/<cli-version>/<expected-state>/<scenario>.txt
<runtime>/<cli-version>/<expected-state>/<scenario>.metadata.json
```

Known current misdetection:

```text
<runtime>/<cli-version>/known-misdetection/<expected-state>/<current-state>/<issue>-<scenario>.txt
<runtime>/<cli-version>/known-misdetection/<expected-state>/<current-state>/<issue>-<scenario>.metadata.json
```

The harness accepts every `DetectedAgent`; the corpus currently contains `claude`, `codex`,
and `pi`. States are `working`, `blocked`, `idle`, or `unknown`; `done` is display state
derived from `idle + unseen` and is never a fixture state.

## Capture and promotion

1. Run a current Debug build of Prowl and the matching bundled `prowl` CLI.
2. Capture the exact production input with `prowl read --source detection --json`.
3. Require `.data.source == "detection"`; never substitute a viewport read.
4. Keep the raw response under the ignored `.local/agent-screen-captures/` directory.
5. Record exact CLI version, capture timestamp, terminal rows/columns, and the redaction
   summary in a same-basename metadata file.
6. Reduce the capture to the exact production detector input for the agent
   (`DetectedAgent.detectionScreenText(from:)`):
   - `claude` consumes the full active screen. Commit the capture as read, without
     trimming; it must not exceed the terminal rows recorded in metadata. Trimming a
     Claude capture can delete the very row above the window that reproduces a bug.
   - `pi` consumes a 32-line tail, so the pi-subagents widget keeps its header and
     its live job row in one slice.
   - Every other agent consumes the 24-line tail produced by the production
     `agentDetectionRecentText` helper.

   A tail starts at the budget-th non-empty line from the bottom when that many
   exist; otherwise it retains the whole screen. Keep blank lines and trailing
   screen rows inside that window.
7. Redact paths, repositories, account identifiers, all real-session prompts/model output,
   and the counters a custom status line reports for the session — cost, token totals,
   quota percentages, elapsed time — without changing runtime chrome, line ordering,
   markers, wrapping, or blank-line boundaries. The generator masks dollar amounts only;
   the other counters are yours to replace. Deliberately scripted probe interactions from
   disposable workspaces may remain verbatim and are preferred for conversational fixtures.
8. Run `AgentScreenFixtureCorpusTests` before committing.

Steps 3, 6, and 7 are mechanical, and doing them by hand is where fixtures go wrong: a
redaction that changes a line's visible width moves a wrap point and produces a screen the
agent CLI would never render. `scripts/make-detection-fixture.py` performs those three
steps and refuses a substitution it cannot fit:

```bash
scripts/make-detection-fixture.py .local/agent-screen-captures/capture.json \
  --agent claude \
  --redact "/Users/me=/Users/usr" \
  --redact "Acme Inc=<ORG_0000>" \
  > claude/2.1.226/idle/composer.txt
```

`--agent` is required and selects the step 6 reduction: `claude` keeps the full active
screen, `pi` takes the bounded 32-line tail, and every other agent value takes the bounded
24-line tail. The flag mirrors `DetectedAgent.detectionScreenText(from:)` rather than
reading the agent from the capture, because the capture does not record which detector will
consume it. A capture reduced under the wrong budget cannot be caught later: applying a
wider tail to an already narrower fixture leaves the fixture unchanged.

Each replacement is padded or trimmed in the spaces immediately following it, so every
later column on the row — a closing box border, a second column of chrome — keeps its
captured position. A replacement too long for the space after it fails with the maximum
length that would fit. The script writes the redaction summary step 5 asks for to stderr,
leaving stdout to be redirected into the fixture. That summary names each replacement and
the number of lines it touched, never the text it replaced — it is copied into a committed
metadata file, and the original is what the redaction existed to keep out of the
repository, so describe it there yourself. The script still does not choose *what* to
redact: step 7 governs that.

Width is counted in terminal cells, not code points: an ideograph occupies two columns and
a combining mark none, so replacing `東京` with `Tokyo` is a one-column widening rather
than the three-column one `len()` would report. A replacement whose width no terminal
agrees on — a ZWJ sequence, or a variation selector that flips a character between text
and emoji presentation — is refused rather than guessed at. Dollar amounts are masked
digit for digit (`$123.45` becomes `$XXX.XX`), so the mask is the width of the amount at
any magnitude; grouped amounts keep their separator (`$1,234.56` becomes `$X,XXX.XX`), and
`--keep-money` retains them. The digit count survives, and therefore so does the order of
magnitude: a mask that hid it would occupy different columns, and holding the columns is
what the fixture is for. A dollar-shaped token this does not recognise fails the run, so
the documented default never silently skips one; a bare `$1` is a shell positional and is
left alone.

`make test-scripts` exercises these guarantees. The corpus tests validate committed
fixtures and never run the generator, so without it nothing holds the script to the
promise it exists to make.

The loader resolves this tree through `#filePath`, so tests intentionally run from a
source checkout rather than relying on test-bundle resource flattening.

Required metadata shape:

```json
{
  "schema_version": 1,
  "captured_at": "2026-08-06T12:34:56Z",
  "cli_version": "0.146.1",
  "capture_source": "prowl-read-detection",
  "terminal": {
    "columns": 120,
    "rows": 40
  },
  "redactions": [
    "working directory replaced with <WORKSPACE>",
    "user prompt replaced with <USER_PROMPT>"
  ],
  "issue": null
}
```

`issue` is required and non-null only in `known-misdetection`.

## Quarantine

A fresh capture that the current detector misclassifies must not be omitted or made into a
failing infrastructure PR. Put it under `known-misdetection`, encode both intended and
current states in the path, and link the tracking issue in metadata. The corpus test
asserts the current behavior, so a later detector fix makes the quarantine fail until the
fixture is promoted to the normal expected-state path.

## Retention and privacy

- Keep the newest verified fixture for each scenario/UI shape.
- Retain an older CLI version only when its distinct shape remains intentionally supported.
- Remove byte-equivalent history.
- Never commit raw captures, credentials, real-session user prompts/model output, account
  names, home paths, or repository names. Purpose-built scripted probes are allowed as
  described above; replace any output that exposes private configuration or persona text.
- Reconstructed and synthetic screens stay inline in `ScreenHeuristicsTests.swift`; they
  must not be version-stamped as captured evidence here.
