# Telegram Bridge MVP

> A lightweight daemon that maps Telegram forum topics to Prowl worktrees and
> drives panes through the existing `prowl` CLI. This is an MVP script, not an
> in-app integration.

**Keywords:** telegram, bot, topic, forum, bridge, remote control, prowl cli, agents, long polling

**Related:** [cli](cli.md) · [active-agents](active-agents.md) · [agent-detection](agent-detection.md)

## What it does

`scripts/prowl-telegram-bridge.py` runs on the Mac where Prowl is running. It
uses Telegram Bot API long polling for incoming messages and calls the local
`prowl` CLI for all Prowl operations.

The intended model is:

```text
Telegram forum group
  topic A -> Prowl worktree A
  topic B -> Prowl worktree B
  topic C -> Prowl worktree C

prowl-telegram-bridge.py
  -> prowl list / agents / read / send / key / focus
  -> Prowl app CLI socket
```

It does not expose a local HTTP server and it does not require an inbound tunnel.
The daemon only makes outbound HTTPS requests to Telegram.

## Safety model

The bridge can read terminal output and, when enabled, send text or keys to a
terminal pane. Treat it like a remote-control surface.

Defaults and safeguards:

- `allowed_user_ids` is required. Messages from other Telegram users are ignored.
- `chat_id` is optional but strongly recommended; when set, messages from other
  chats are ignored.
- `/send` is disabled unless `allow_send` or `PROWL_TG_ALLOW_SEND=1` is set.
- `/key` is disabled unless `allow_key` or `PROWL_TG_ALLOW_KEY=1` is set.
- Output redaction is enabled by default for common credential-looking strings.
- Plain non-command messages are ignored in this MVP.

Terminal output still goes through Telegram. Do not use this bridge for panes
that routinely print private keys, customer data, or other sensitive output.

## Setup

Create a Telegram bot with BotFather and add it to a Telegram supergroup. If you
want the bridge to create topics automatically, the group must have forum topics
enabled and the bot must have permission to manage topics.

Install the Prowl CLI from Prowl: **Settings → Advanced → Install Command Line
Tool**, then confirm this works on the Mac:

```bash
prowl list --json
```

Create a config file from the example:

```bash
cp scripts/prowl-telegram-bridge.config.example.json prowl-telegram-bridge.config.json
vim prowl-telegram-bridge.config.json
```

Minimum config:

```json
{
  "bot_key": "123456:replace-with-the-value-from-BotFather",
  "chat_id": -1001234567890,
  "allowed_user_ids": [93520829],
  "allow_send": true,
  "allow_key": true
}
```

You can also use environment variables:

```bash
export PROWL_TG_BOT_KEY='123456:replace-with-the-value-from-BotFather'  # PROWL_TG_BOT_TOKEN also works
export PROWL_TG_CHAT_ID='-1001234567890'
export PROWL_TG_ALLOWED_USERS='93520829'
export PROWL_TG_ALLOW_SEND=1
export PROWL_TG_ALLOW_KEY=1
```

Run it:

```bash
scripts/prowl-telegram-bridge.py --config prowl-telegram-bridge.config.json
```

Use `--verbose` for debug logs.

## Finding IDs

Send `/whoami` to the bot in the target group/topic. It replies with:

```text
chat_id=-1001234567890
message_thread_id=42
user_id=93520829
```

Copy `chat_id` and your `user_id` into the config. `message_thread_id` is only
needed if you want status-change notifications to fall back to a specific
overview topic via `overview_thread_id`.

## Commands

Topic setup:

```text
/sync
/bind <number|id|name|path>
/unbind
/create_topics
/whoami
```

Inspect:

```text
/status
/agents
/panes
/use <number|pane-id>
/read [lines] [@pane]
```

Control:

```text
/send [@pane] <text>
/key [@pane] <key>
/focus [@pane]
```

Examples:

```text
/sync
/bind 2
/status
/panes
/use 1
/read 160
/send npm test
/send @2 continue with the failing test
/key ctrl-c
/focus
```

## Topic mapping

Bindings are stored in a local JSON state file. By default:

```text
~/Library/Application Support/com.onevcat.prowl/telegram-bridge-state.json
```

A binding records:

```json
{
  "worktree_id": "...",
  "worktree_name": "main",
  "pane_id": "..."
}
```

When a topic is bound, `/status`, `/agents`, `/panes`, `/read`, `/send`, `/key`,
and `/focus` act on that worktree. `/use <pane>` changes the default pane for the
topic.

## Automatic status notifications

When `notify_status_changes` is true, the bridge periodically runs
`prowl agents --json`, compares each agent's status with the last snapshot, and
posts status changes into the bound worktree topic.

If a worktree has no bound topic, the bridge posts to `overview_thread_id` when
that value is configured. Otherwise it skips the notification.

## Launching as a daemon

A simple macOS LaunchAgent can keep it running. Adjust paths as needed:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.onevcat.prowl.telegram-bridge</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/python3</string>
    <string>/path/to/Prowl/scripts/prowl-telegram-bridge.py</string>
    <string>--config</string>
    <string>/path/to/prowl-telegram-bridge.config.json</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>/tmp/prowl-telegram-bridge.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/prowl-telegram-bridge.err.log</string>
</dict>
</plist>
```

## MVP limitations

- It is a standalone script, not a Settings panel or in-app service.
- It uses long polling, not webhooks.
- It reads snapshots; it does not stream a full terminal UI.
- It calls `prowl` as a subprocess instead of linking directly to
  `CLICommandRouter`.
- It does not support attachments, file transfer, PR actions, or worktree
  creation.
