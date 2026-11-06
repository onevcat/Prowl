# Conversation fixtures

Real agent transcripts, sanitized, with the `conversation-v1` events the Host derives from
them (docs-ai 087). Both the Mac app tests and the iOS client use them: the Mac test
`MirrorConversationFixtureTests` runs the adapters over each `<name>.jsonl` and compares
the result with `<name>.events.jsonl`; the iOS app renders `<name>.events.jsonl` in its
DEBUG fixture mode without a Host.

| Fixture | Source |
| --- | --- |
| `claude-review-1038` | Claude Code 2.1.317 reviewing PR #1038 read-only (2026-11-04), including one AskUserQuestion |
| `codex-review-1038` | Codex 0.166.0 reviewing PR #1038 read-only (2026-11-04) |

`scripts/mirror-fixture-sanitize.py <claude|codex> <in> <out>` produced the raw files: it drops
bulky and private records (API request blobs, attachments, developer instructions, token
counts), truncates long text at 3,000 characters, and replaces the home directory. Claude Code
2.1.317 wrote its thinking blocks empty; one block in `claude-review-1038.jsonl` has a short
thought added by hand, with a minimal narration signature (field 2 → 1 → 8 = `narration`), as
Claude Code 2.1.319 writes visible thinking, so the client shows one.

Regenerate the event files after an adapter change:

```bash
TEST_RUNNER_PROWL_UPDATE_FIXTURES=1 xcodebuild test -workspace Prowl.xcworkspace -scheme Prowl -destination "platform=macOS" \
  -only-testing:ProwlTests/MirrorConversationFixtureTests \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" -skipMacroValidation
```
