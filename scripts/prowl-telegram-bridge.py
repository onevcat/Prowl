#!/usr/bin/env python3
"""Telegram topic bridge MVP for Prowl.

Runs outside the app, listens to Telegram updates with long polling, and calls
Prowl through the existing `prowl` CLI.  It is intentionally dependency-free so
it can run on a Mac with only Python 3 available.
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import re
import shlex
import subprocess
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

LOG = logging.getLogger("prowl-telegram-bridge")
DEFAULT_STATE_PATH = (
    Path.home()
    / "Library"
    / "Application Support"
    / "com.onevcat.prowl"
    / "telegram-bridge-state.json"
)


class BridgeError(RuntimeError):
    pass


@dataclass
class BridgeConfig:
    bot_key: str
    chat_id: int | None = None
    allowed_user_ids: set[int] = field(default_factory=set)
    prowl_bin: str = "prowl"
    state_path: Path = DEFAULT_STATE_PATH
    default_read_lines: int = 120
    max_message_chars: int = 3800
    poll_timeout_seconds: int = 10
    sync_interval_seconds: int = 5
    prowl_timeout_seconds: int = 45
    send_timeout_seconds: int = 60
    allow_send: bool = False
    allow_key: bool = False
    allow_focus: bool = True
    allow_create_topics: bool = False
    notify_status_changes: bool = True
    overview_thread_id: int | None = None
    redact_output: bool = True


@dataclass
class TopicBinding:
    worktree_id: str
    worktree_name: str
    pane_id: str | None = None

    @classmethod
    def from_json(cls, value: dict[str, Any]) -> "TopicBinding":
        return cls(
            worktree_id=str(value.get("worktree_id", "")),
            worktree_name=str(value.get("worktree_name", "")),
            pane_id=value.get("pane_id"),
        )

    def to_json(self) -> dict[str, Any]:
        return {
            "worktree_id": self.worktree_id,
            "worktree_name": self.worktree_name,
            "pane_id": self.pane_id,
        }


class JsonState:
    def __init__(self, path: Path):
        self.path = path
        self.data: dict[str, Any] = {"offset": None, "topics": {}, "last_agent_status": {}}
        self.load()

    def load(self) -> None:
        if not self.path.exists():
            return
        try:
            loaded = json.loads(self.path.read_text(encoding="utf-8"))
        except Exception as error:
            raise BridgeError(f"failed to read state file {self.path}: {error}") from error
        if isinstance(loaded, dict):
            self.data.update(loaded)

    def save(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.path.with_suffix(self.path.suffix + ".tmp")
        tmp.write_text(json.dumps(self.data, ensure_ascii=False, indent=2, sort_keys=True), encoding="utf-8")
        tmp.replace(self.path)

    @property
    def offset(self) -> int | None:
        value = self.data.get("offset")
        return int(value) if value is not None else None

    @offset.setter
    def offset(self, value: int | None) -> None:
        self.data["offset"] = value

    def binding(self, chat_id: int, thread_id: int | None) -> TopicBinding | None:
        raw = self.data.get("topics", {}).get(topic_key(chat_id, thread_id))
        if not isinstance(raw, dict):
            return None
        binding = TopicBinding.from_json(raw)
        return binding if binding.worktree_id else None

    def set_binding(self, chat_id: int, thread_id: int | None, binding: TopicBinding) -> None:
        self.data.setdefault("topics", {})[topic_key(chat_id, thread_id)] = binding.to_json()

    def remove_binding(self, chat_id: int, thread_id: int | None) -> None:
        self.data.setdefault("topics", {}).pop(topic_key(chat_id, thread_id), None)

    def bound_thread_for_worktree(self, chat_id: int, worktree_id: str) -> int | None:
        prefix = f"{chat_id}:"
        for key, value in self.data.get("topics", {}).items():
            if not key.startswith(prefix) or not isinstance(value, dict):
                continue
            if value.get("worktree_id") != worktree_id:
                continue
            raw_thread_id = key.split(":", 1)[1]
            thread_id = int(raw_thread_id)
            return thread_id if thread_id != 0 else None
        return None


def topic_key(chat_id: int, thread_id: int | None) -> str:
    return f"{chat_id}:{thread_id or 0}"


def parse_bool(value: Any, default: bool = False) -> bool:
    if value is None:
        return default
    if isinstance(value, bool):
        return value
    return str(value).strip().lower() in {"1", "true", "yes", "y", "on"}


def parse_int(value: Any, default: int | None = None) -> int | None:
    if value is None or value == "":
        return default
    return int(value)


def parse_int_set(value: Any) -> set[int]:
    if value is None or value == "":
        return set()
    if isinstance(value, str):
        values = [part.strip() for part in value.split(",")]
    elif isinstance(value, list):
        values = value
    else:
        values = [value]
    return {int(part) for part in values if str(part).strip()}


def load_config(config_path: Path | None) -> BridgeConfig:
    raw: dict[str, Any] = {}
    if config_path:
        try:
            raw = json.loads(config_path.read_text(encoding="utf-8"))
        except FileNotFoundError as error:
            raise BridgeError(f"config file not found: {config_path}") from error
        except json.JSONDecodeError as error:
            raise BridgeError(f"invalid JSON config {config_path}: {error}") from error

    def get(name: str, env_name: str | None = None, default: Any = None) -> Any:
        if env_name and os.getenv(env_name) not in (None, ""):
            return os.getenv(env_name)
        return raw.get(name, default)

    bot_key = get("bot_key", "PROWL_TG_BOT_KEY") or get("bot_token", "PROWL_TG_BOT_TOKEN")
    if not bot_key:
        raise BridgeError("bot_key is required: set PROWL_TG_BOT_KEY/PROWL_TG_BOT_TOKEN or config.bot_key")

    allowed_user_ids = parse_int_set(get("allowed_user_ids", "PROWL_TG_ALLOWED_USERS"))
    if not allowed_user_ids:
        raise BridgeError("allowed_user_ids is required for safety; set PROWL_TG_ALLOWED_USERS")

    state_path = Path(str(get("state_path", "PROWL_TG_STATE_PATH", DEFAULT_STATE_PATH))).expanduser()
    return BridgeConfig(
        bot_key=str(bot_key),
        chat_id=parse_int(get("chat_id", "PROWL_TG_CHAT_ID")),
        allowed_user_ids=allowed_user_ids,
        prowl_bin=str(get("prowl_bin", "PROWL_TG_PROWL_BIN", "prowl")),
        state_path=state_path,
        default_read_lines=int(get("default_read_lines", None, 120)),
        max_message_chars=int(get("max_message_chars", None, 3800)),
        poll_timeout_seconds=int(get("poll_timeout_seconds", None, 10)),
        sync_interval_seconds=int(get("sync_interval_seconds", None, 5)),
        prowl_timeout_seconds=int(get("prowl_timeout_seconds", None, 45)),
        send_timeout_seconds=int(get("send_timeout_seconds", None, 60)),
        allow_send=parse_bool(get("allow_send", "PROWL_TG_ALLOW_SEND"), False),
        allow_key=parse_bool(get("allow_key", "PROWL_TG_ALLOW_KEY"), False),
        allow_focus=parse_bool(get("allow_focus", "PROWL_TG_ALLOW_FOCUS"), True),
        allow_create_topics=parse_bool(get("allow_create_topics", "PROWL_TG_ALLOW_CREATE_TOPICS"), False),
        notify_status_changes=parse_bool(get("notify_status_changes", None), True),
        overview_thread_id=parse_int(get("overview_thread_id", "PROWL_TG_OVERVIEW_THREAD_ID")),
        redact_output=parse_bool(get("redact_output", None), True),
    )


class TelegramClient:
    def __init__(self, config: BridgeConfig):
        self.config = config
        self.base_url = f"https://api.telegram.org/bot{config.bot_key}/"

    def api(self, method: str, payload: dict[str, Any], timeout: int = 30) -> Any:
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        request = urllib.request.Request(
            self.base_url + method,
            data=data,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                body = response.read()
        except urllib.error.HTTPError as error:
            details = error.read().decode("utf-8", errors="replace")
            raise BridgeError(f"Telegram {method} failed: HTTP {error.code}: {details}") from error
        except urllib.error.URLError as error:
            raise BridgeError(f"Telegram {method} failed: {error}") from error
        decoded = json.loads(body.decode("utf-8"))
        if not decoded.get("ok"):
            raise BridgeError(f"Telegram {method} failed: {decoded.get('description', decoded)}")
        return decoded.get("result")

    def get_updates(self, offset: int | None) -> list[dict[str, Any]]:
        payload: dict[str, Any] = {"timeout": self.config.poll_timeout_seconds, "allowed_updates": ["message"]}
        if offset is not None:
            payload["offset"] = offset
        result = self.api("getUpdates", payload, timeout=self.config.poll_timeout_seconds + 10)
        return result if isinstance(result, list) else []

    def send_message(self, chat_id: int, text: str, thread_id: int | None = None) -> None:
        for chunk in split_message(text, self.config.max_message_chars):
            payload: dict[str, Any] = {"chat_id": chat_id, "text": chunk, "disable_web_page_preview": True}
            if thread_id:
                payload["message_thread_id"] = thread_id
            self.api("sendMessage", payload)

    def create_forum_topic(self, chat_id: int, name: str) -> dict[str, Any]:
        result = self.api("createForumTopic", {"chat_id": chat_id, "name": name[:128]})
        return result if isinstance(result, dict) else {}


class ProwlClient:
    def __init__(self, config: BridgeConfig):
        self.config = config

    def list(self) -> dict[str, Any]:
        return self._run_json(["list"], timeout=self.config.prowl_timeout_seconds)

    def agents(self) -> dict[str, Any]:
        return self._run_json(["agents"], timeout=self.config.prowl_timeout_seconds)

    def read(self, pane_id: str, lines: int, wait_stable: bool = True) -> dict[str, Any]:
        args = ["read", "--pane", pane_id, "--last", str(lines)]
        if wait_stable:
            args.append("--wait-stable")
        return self._run_json(args, timeout=self.config.prowl_timeout_seconds)

    def send(self, pane_id: str, text: str) -> dict[str, Any]:
        args = ["send", "--pane", pane_id, "--capture", "--timeout", str(self.config.send_timeout_seconds)]
        return self._run_json(args, stdin=text, timeout=self.config.send_timeout_seconds + 10)

    def key(self, pane_id: str, key_name: str) -> dict[str, Any]:
        return self._run_json(["key", "--pane", pane_id, key_name], timeout=self.config.prowl_timeout_seconds)

    def focus(self, pane_id: str) -> dict[str, Any]:
        return self._run_json(["focus", "--pane", pane_id], timeout=self.config.prowl_timeout_seconds)

    def _run_json(self, args: list[str], stdin: str | None = None, timeout: int = 30) -> dict[str, Any]:
        cmd = [self.config.prowl_bin, *args, "--json"]
        LOG.debug("running: %s", shlex.join(cmd))
        try:
            completed = subprocess.run(
                cmd,
                input=stdin,
                text=True,
                capture_output=True,
                timeout=timeout,
                check=False,
            )
        except FileNotFoundError as error:
            raise BridgeError(f"prowl CLI not found: {self.config.prowl_bin}") from error
        except subprocess.TimeoutExpired as error:
            raise BridgeError(f"prowl command timed out: {shlex.join(cmd)}") from error
        stdout = completed.stdout.strip()
        stderr = completed.stderr.strip()
        if completed.returncode != 0:
            raise BridgeError(f"prowl command failed: {stderr or stdout or completed.returncode}")
        try:
            decoded = json.loads(stdout)
        except json.JSONDecodeError as error:
            raise BridgeError(f"prowl returned invalid JSON: {stdout[:500]}") from error
        if not decoded.get("ok"):
            detail = decoded.get("error") or {}
            raise BridgeError(str(detail.get("message") or detail or "prowl command failed"))
        data = decoded.get("data")
        return data if isinstance(data, dict) else {}


class Redactor:
    PATTERNS = [
        (re.compile(r"(?i)((?:api[_-]?key|credential|password)\s*[:=]\s*)[^\s'\"]+"), r"\1[REDACTED]"),
        (re.compile(r"sk-[A-Za-z0-9_-]{20,}"), "sk-[REDACTED]"),
        (re.compile(r"gh[pousr]_[A-Za-z0-9_]{20,}"), "gh_[REDACTED]"),
        (re.compile(r"AKIA[0-9A-Z]{16}"), "AKIA[REDACTED]"),
    ]

    @classmethod
    def apply(cls, text: str) -> str:
        redacted = text
        for pattern, replacement in cls.PATTERNS:
            redacted = pattern.sub(replacement, redacted)
        return redacted


class Bridge:
    def __init__(self, config: BridgeConfig):
        self.config = config
        self.state = JsonState(config.state_path)
        self.telegram = TelegramClient(config)
        self.prowl = ProwlClient(config)
        self.last_sync_at = 0.0

    def run_forever(self) -> None:
        LOG.info("starting bridge; state=%s", self.config.state_path)
        while True:
            try:
                updates = self.telegram.get_updates(self.state.offset)
                for update in updates:
                    self.state.offset = int(update["update_id"]) + 1
                    self.handle_update(update)
                self.maybe_sync_agent_status()
                self.state.save()
            except KeyboardInterrupt:
                LOG.info("stopping")
                self.state.save()
                return
            except Exception as error:
                LOG.exception("bridge loop failed: %s", error)
                time.sleep(3)

    def run_once(self) -> None:
        self.maybe_sync_agent_status(force=True)
        self.state.save()

    def handle_update(self, update: dict[str, Any]) -> None:
        message = update.get("message")
        if not isinstance(message, dict):
            return
        text = message.get("text")
        if not isinstance(text, str) or not text.strip():
            return
        chat = message.get("chat") or {}
        user = message.get("from") or {}
        chat_id = int(chat.get("id"))
        thread_raw = message.get("message_thread_id")
        thread_id = int(thread_raw) if thread_raw else None
        user_id = int(user.get("id", 0))

        if self.config.chat_id is not None and chat_id != self.config.chat_id:
            LOG.warning("ignoring message from unexpected chat_id=%s", chat_id)
            return
        if user_id not in self.config.allowed_user_ids:
            LOG.warning("ignoring message from unauthorized user_id=%s", user_id)
            return

        try:
            response = self.handle_text(chat_id, thread_id, text.strip(), user_id)
        except BridgeError as error:
            response = f"❌ {error}"
        except Exception as error:
            LOG.exception("message handling failed")
            response = f"❌ Bridge error: {error}"
        if response:
            self.reply(chat_id, response, thread_id)

    def handle_text(self, chat_id: int, thread_id: int | None, text: str, user_id: int) -> str | None:
        if not text.startswith("/"):
            return "Use /help, /status, /read, or /send <text>. Plain messages are ignored by this MVP."
        command, rest = parse_command(text)
        if command in {"help", "start"}:
            return help_text(self.config)
        if command == "whoami":
            return f"chat_id={chat_id}\nmessage_thread_id={thread_id or 0}\nuser_id={user_id}"
        if command == "sync":
            return self.format_overview()
        if command == "create_topics":
            return self.create_topics(chat_id)
        if command == "bind":
            return self.bind_topic(chat_id, thread_id, rest)
        if command == "unbind":
            self.state.remove_binding(chat_id, thread_id)
            return "Unbound this topic."
        if command == "status":
            return self.status(chat_id, thread_id)
        if command == "agents":
            return self.agents(chat_id, thread_id)
        if command == "panes":
            binding = self.require_binding(chat_id, thread_id)
            _, panes = self.panes_for_binding(binding)
            return format_panes(binding, panes)
        if command == "use":
            return self.use_pane(chat_id, thread_id, rest)
        if command == "read":
            return self.read_pane(chat_id, thread_id, rest)
        if command == "send":
            return self.send_text(chat_id, thread_id, rest)
        if command == "key":
            return self.send_key(chat_id, thread_id, rest)
        if command == "focus":
            return self.focus(chat_id, thread_id, rest)
        return f"Unknown command: /{command}\n\n{help_text(self.config)}"

    def reply(self, chat_id: int, text: str, thread_id: int | None) -> None:
        if self.config.redact_output:
            text = Redactor.apply(text)
        self.telegram.send_message(chat_id, text, thread_id=thread_id)

    def require_binding(self, chat_id: int, thread_id: int | None) -> TopicBinding:
        binding = self.state.binding(chat_id, thread_id)
        if not binding:
            raise BridgeError("this topic is not bound yet. Use /bind <worktree-id|name|path> or /sync first.")
        return binding

    def bind_topic(self, chat_id: int, thread_id: int | None, query: str) -> str:
        snapshot = self.prowl.list()
        worktrees = worktrees_from_snapshot(snapshot)
        if not query:
            return "Choose a worktree to bind:\n" + format_worktree_choices(worktrees)
        worktree = resolve_worktree(worktrees, query)
        if not worktree:
            return "Could not find a matching worktree. Available:\n" + format_worktree_choices(worktrees)
        panes = panes_for_worktree(snapshot, worktree["id"])
        default_pane = choose_default_pane(panes, None)
        binding = TopicBinding(
            worktree_id=worktree["id"],
            worktree_name=worktree["name"],
            pane_id=default_pane.get("id") if default_pane else None,
        )
        self.state.set_binding(chat_id, thread_id, binding)
        self.state.save()
        pane_line = f"\nDefault pane: {short_id(binding.pane_id)}" if binding.pane_id else ""
        return f"Bound this topic to {worktree['name']} ({short_id(worktree['id'])}).{pane_line}"

    def status(self, chat_id: int, thread_id: int | None) -> str:
        binding = self.state.binding(chat_id, thread_id)
        if not binding:
            return self.format_overview()
        _, panes = self.panes_for_binding(binding)
        return format_worktree_status(binding, panes)

    def agents(self, chat_id: int, thread_id: int | None) -> str:
        binding = self.state.binding(chat_id, thread_id)
        data = self.prowl.agents()
        agents = data.get("agents", [])
        if binding:
            agents = [agent for agent in agents if agent.get("worktree", {}).get("id") == binding.worktree_id]
        return format_agents(agents, binding)

    def panes_for_binding(self, binding: TopicBinding) -> tuple[dict[str, Any], list[dict[str, Any]]]:
        snapshot = self.prowl.list()
        panes = panes_for_worktree(snapshot, binding.worktree_id)
        if not panes:
            raise BridgeError(f"no live panes found for {binding.worktree_name}")
        return snapshot, panes

    def use_pane(self, chat_id: int, thread_id: int | None, query: str) -> str:
        binding = self.require_binding(chat_id, thread_id)
        _, panes = self.panes_for_binding(binding)
        pane = resolve_pane(panes, query)
        if not pane:
            return "Could not find that pane.\n" + format_panes(binding, panes)
        binding.pane_id = pane["id"]
        self.state.set_binding(chat_id, thread_id, binding)
        self.state.save()
        return f"Default pane set to #{pane['index']} {pane['title']} ({short_id(pane['id'])})."

    def read_pane(self, chat_id: int, thread_id: int | None, args: str) -> str:
        binding = self.require_binding(chat_id, thread_id)
        _, panes = self.panes_for_binding(binding)
        lines, pane_query = parse_read_args(args, self.config.default_read_lines)
        pane = resolve_pane(panes, pane_query) or choose_default_pane(panes, binding.pane_id)
        if not pane:
            raise BridgeError("could not resolve a pane to read")
        data = self.prowl.read(pane["id"], lines)
        terminal_text = data.get("text", "")
        header = f"📖 {binding.worktree_name} / #{pane['index']} {pane['title']}\nlines={data.get('line_count', '?')} source={data.get('source', '?')}"
        if data.get("truncated"):
            header += " truncated=true"
        return f"{header}\n\n{terminal_text or '(empty)'}"

    def send_text(self, chat_id: int, thread_id: int | None, args: str) -> str:
        if not self.config.allow_send:
            raise BridgeError("/send is disabled. Set allow_send=true or PROWL_TG_ALLOW_SEND=1.")
        binding = self.require_binding(chat_id, thread_id)
        pane_query, text = parse_target_prefixed_text(args)
        if not text:
            return "Usage: /send [@pane-index|pane-id] <text>"
        _, panes = self.panes_for_binding(binding)
        pane = resolve_pane(panes, pane_query) or choose_default_pane(panes, binding.pane_id)
        if not pane:
            raise BridgeError("could not resolve a pane to send to")
        data = self.prowl.send(pane["id"], text)
        wait = data.get("wait") or {}
        capture = data.get("capture") or {}
        captured_text = capture.get("text") or ""
        header = f"📨 Sent to {binding.worktree_name} / #{pane['index']} {pane['title']}\nexit={wait.get('exit_code')} duration_ms={wait.get('duration_ms')}"
        return f"{header}\n\n{captured_text}" if captured_text else header

    def send_key(self, chat_id: int, thread_id: int | None, args: str) -> str:
        if not self.config.allow_key:
            raise BridgeError("/key is disabled. Set allow_key=true or PROWL_TG_ALLOW_KEY=1.")
        binding = self.require_binding(chat_id, thread_id)
        pane_query, key_text = parse_target_prefixed_text(args)
        if not key_text:
            return "Usage: /key [@pane-index|pane-id] <key>, for example /key ctrl-c"
        _, panes = self.panes_for_binding(binding)
        pane = resolve_pane(panes, pane_query) or choose_default_pane(panes, binding.pane_id)
        if not pane:
            raise BridgeError("could not resolve a pane to send key to")
        key_name = key_text.split()[0]
        self.prowl.key(pane["id"], key_name)
        return f"⌨️ Sent {key_name} to #{pane['index']} {pane['title']}"

    def focus(self, chat_id: int, thread_id: int | None, args: str) -> str:
        if not self.config.allow_focus:
            raise BridgeError("/focus is disabled.")
        binding = self.require_binding(chat_id, thread_id)
        _, panes = self.panes_for_binding(binding)
        pane = resolve_pane(panes, args.strip()) or choose_default_pane(panes, binding.pane_id)
        if not pane:
            raise BridgeError("could not resolve a pane to focus")
        self.prowl.focus(pane["id"])
        return f"Focused {binding.worktree_name} / #{pane['index']} {pane['title']}"

    def format_overview(self) -> str:
        snapshot = self.prowl.list()
        worktrees = worktrees_from_snapshot(snapshot)
        if not worktrees:
            return "No live Prowl worktrees found. Open a worktree/tab in Prowl first."
        lines = ["Prowl worktrees:"]
        for index, worktree in enumerate(worktrees, 1):
            panes = panes_for_worktree(snapshot, worktree["id"])
            task = first_task_status(panes)
            lines.append(f"{index}. {status_icon(task)} {worktree['name']} ({short_id(worktree['id'])}) panes={len(panes)} path={worktree['path']}")
        lines.append("\nBind this topic with /bind <number|id|name|path>.")
        return "\n".join(lines)

    def create_topics(self, chat_id: int) -> str:
        if not self.config.allow_create_topics:
            raise BridgeError("/create_topics is disabled. Set allow_create_topics=true first.")
        snapshot = self.prowl.list()
        worktrees = worktrees_from_snapshot(snapshot)
        if not worktrees:
            return "No live worktrees found."
        created: list[str] = []
        for worktree in worktrees:
            topic_name = safe_topic_name(worktree["name"])
            result = self.telegram.create_forum_topic(chat_id, topic_name)
            thread_id = int(result.get("message_thread_id"))
            panes = panes_for_worktree(snapshot, worktree["id"])
            default_pane = choose_default_pane(panes, None)
            self.state.set_binding(
                chat_id,
                thread_id,
                TopicBinding(
                    worktree_id=worktree["id"],
                    worktree_name=worktree["name"],
                    pane_id=default_pane.get("id") if default_pane else None,
                ),
            )
            created.append(f"{topic_name} -> thread {thread_id}")
        self.state.save()
        return "Created and bound topics:\n" + "\n".join(created)

    def maybe_sync_agent_status(self, force: bool = False) -> None:
        if not self.config.notify_status_changes or self.config.chat_id is None:
            return
        now = time.monotonic()
        if not force and now - self.last_sync_at < self.config.sync_interval_seconds:
            return
        self.last_sync_at = now
        data = self.prowl.agents()
        current: dict[str, dict[str, Any]] = {}
        for agent in data.get("agents", []):
            agent_id = str(agent.get("id"))
            current[agent_id] = {
                "status": agent.get("status"),
                "name": agent.get("name"),
                "type": agent.get("type"),
                "worktree_id": agent.get("worktree", {}).get("id"),
                "worktree_name": agent.get("worktree", {}).get("name"),
                "pane_title": agent.get("pane", {}).get("title"),
            }
        previous = self.state.data.get("last_agent_status", {})
        if not isinstance(previous, dict) or force:
            previous = {}
        for agent_id, info in current.items():
            old = previous.get(agent_id)
            if old and old.get("status") != info.get("status"):
                self.notify_agent_status_change(info, old.get("status"), info.get("status"))
        self.state.data["last_agent_status"] = current

    def notify_agent_status_change(self, info: dict[str, Any], old: Any, new: Any) -> None:
        chat_id = self.config.chat_id
        if chat_id is None:
            return
        worktree_id = str(info.get("worktree_id") or "")
        thread_id = self.state.bound_thread_for_worktree(chat_id, worktree_id) or self.config.overview_thread_id
        if thread_id is None:
            return
        text = (
            f"{agent_status_icon(str(new))} Agent status changed: {old} -> {new}\n"
            f"Worktree: {info.get('worktree_name')}\n"
            f"Agent: {info.get('name')} ({info.get('type')})\n"
            f"Pane: {info.get('pane_title')}\n\nUse /read to inspect the pane."
        )
        self.reply(chat_id, text, thread_id)


def parse_command(text: str) -> tuple[str, str]:
    head, _, rest = text.partition(" ")
    command = head.lstrip("/").split("@", 1)[0].strip().lower().replace("-", "_")
    return command, rest.strip()


def parse_read_args(args: str, default_lines: int) -> tuple[int, str | None]:
    lines = default_lines
    pane_query: str | None = None
    for item in args.split():
        if item.isdigit():
            lines = max(1, min(1000, int(item)))
        else:
            pane_query = item[1:] if item.startswith("@") else item
    return lines, pane_query


def parse_target_prefixed_text(args: str) -> tuple[str | None, str]:
    stripped = args.strip()
    if not stripped:
        return None, ""
    if stripped.startswith("@"):
        target, _, rest = stripped.partition(" ")
        return target[1:].strip(), rest.strip()
    return None, stripped


def worktrees_from_snapshot(snapshot: dict[str, Any]) -> list[dict[str, Any]]:
    seen: set[str] = set()
    worktrees: list[dict[str, Any]] = []
    for item in snapshot.get("items", []):
        worktree = item.get("worktree") or {}
        worktree_id = str(worktree.get("id", ""))
        if worktree_id and worktree_id not in seen:
            seen.add(worktree_id)
            worktrees.append(worktree)
    return worktrees


def panes_for_worktree(snapshot: dict[str, Any], worktree_id: str) -> list[dict[str, Any]]:
    panes: list[dict[str, Any]] = []
    for item in snapshot.get("items", []):
        worktree = item.get("worktree") or {}
        if worktree.get("id") != worktree_id:
            continue
        pane = dict(item.get("pane") or {})
        tab = item.get("tab") or {}
        task = item.get("task") or {}
        pane["index"] = len(panes) + 1
        pane["tab_id"] = tab.get("id")
        pane["tab_title"] = tab.get("title")
        pane["tab_selected"] = bool(tab.get("selected"))
        pane["task_status"] = task.get("status")
        panes.append(pane)
    return panes


def resolve_worktree(worktrees: list[dict[str, Any]], query: str) -> dict[str, Any] | None:
    needle = query.strip()
    if needle.isdigit():
        index = int(needle)
        if 1 <= index <= len(worktrees):
            return worktrees[index - 1]
    lower = needle.lower()
    exact = [
        worktree
        for worktree in worktrees
        if lower
        in {
            str(worktree.get("id", "")).lower(),
            str(worktree.get("name", "")).lower(),
            str(worktree.get("path", "")).lower(),
            str(worktree.get("root_path", "")).lower(),
        }
    ]
    if len(exact) == 1:
        return exact[0]
    partial = [
        worktree
        for worktree in worktrees
        if lower in str(worktree.get("name", "")).lower()
        or lower in str(worktree.get("path", "")).lower()
        or str(worktree.get("id", "")).lower().startswith(lower)
    ]
    return partial[0] if len(partial) == 1 else None


def resolve_pane(panes: list[dict[str, Any]], query: str | None) -> dict[str, Any] | None:
    if not query:
        return None
    needle = query.strip()
    if needle.startswith("@"):
        needle = needle[1:]
    if needle.isdigit():
        index = int(needle)
        if 1 <= index <= len(panes):
            return panes[index - 1]
    lower = needle.lower()
    for pane in panes:
        pane_id = str(pane.get("id", ""))
        if pane_id == needle or pane_id.lower().startswith(lower):
            return pane
    matches = [pane for pane in panes if lower in str(pane.get("title", "")).lower()]
    return matches[0] if len(matches) == 1 else None


def choose_default_pane(panes: list[dict[str, Any]], preferred_id: str | None) -> dict[str, Any] | None:
    if preferred_id:
        for pane in panes:
            if pane.get("id") == preferred_id:
                return pane
    for pane in panes:
        if pane.get("focused"):
            return pane
    for pane in panes:
        if pane.get("tab_selected"):
            return pane
    return panes[0] if panes else None


def format_worktree_choices(worktrees: list[dict[str, Any]]) -> str:
    if not worktrees:
        return "No live worktrees."
    return "\n".join(
        f"{index}. {worktree.get('name')} ({short_id(worktree.get('id'))}) path={worktree.get('path')}"
        for index, worktree in enumerate(worktrees, 1)
    )


def format_worktree_status(binding: TopicBinding, panes: list[dict[str, Any]]) -> str:
    lines = [f"Worktree: {binding.worktree_name} ({short_id(binding.worktree_id)})"]
    if panes:
        lines.append(f"Task: {first_task_status(panes) or 'unknown'}")
        lines.append(f"Default pane: {short_id(binding.pane_id) if binding.pane_id else '(auto)'}")
        lines.append("")
        lines.append(format_panes(binding, panes))
    return "\n".join(lines)


def format_panes(binding: TopicBinding, panes: list[dict[str, Any]]) -> str:
    lines = [f"Panes for {binding.worktree_name}:"]
    for pane in panes:
        marker = "*" if pane.get("id") == binding.pane_id else " "
        focus = "focused" if pane.get("focused") else ""
        selected = "selected-tab" if pane.get("tab_selected") else ""
        flags = " ".join(part for part in [focus, selected] if part)
        flags = f" [{flags}]" if flags else ""
        lines.append(
            f"{marker}{pane['index']}. {pane.get('title') or '(untitled)'} "
            f"({short_id(pane.get('id'))}) tab={pane.get('tab_title')}{flags}"
        )
    lines.append("\nUse /use <number> to set the default pane.")
    return "\n".join(lines)


def format_agents(agents: list[dict[str, Any]], binding: TopicBinding | None) -> str:
    label = f" for {binding.worktree_name}" if binding else ""
    if not agents:
        return f"No agents found{label}."
    order = {"blocked": 0, "working": 1, "done": 2, "idle": 3}
    agents = sorted(agents, key=lambda item: order.get(str(item.get("status")), 99))
    lines = [f"Agents{label}:"]
    for agent in agents:
        pane = agent.get("pane") or {}
        worktree = agent.get("worktree") or {}
        lines.append(
            f"{agent_status_icon(str(agent.get('status')))} {agent.get('status')} "
            f"{agent.get('name')} pane=#{pane.get('index')} {pane.get('title')} "
            f"worktree={worktree.get('name')} changed={agent.get('last_changed_at')}"
        )
    return "\n".join(lines)


def first_task_status(panes: list[dict[str, Any]]) -> str | None:
    for pane in panes:
        if pane.get("task_status"):
            return str(pane.get("task_status"))
    return None


def status_icon(status: str | None) -> str:
    return "🔄" if status == "running" else "⚪"


def agent_status_icon(status: str) -> str:
    return {"blocked": "⚠️", "working": "🔄", "done": "✅", "idle": "⚪"}.get(status, "•")


def short_id(value: Any) -> str:
    text = str(value or "")
    return text[:8] if len(text) > 8 else text


def safe_topic_name(value: str) -> str:
    cleaned = re.sub(r"\s+", " ", value).strip()
    return cleaned[:120] or "Prowl Worktree"


def split_message(text: str, limit: int) -> list[str]:
    if len(text) <= limit:
        return [text]
    chunks: list[str] = []
    remaining = text
    while len(remaining) > limit:
        split_at = remaining.rfind("\n", 0, limit)
        if split_at < limit // 2:
            split_at = limit
        chunks.append(remaining[:split_at].rstrip())
        remaining = remaining[split_at:].lstrip()
    if remaining:
        chunks.append(remaining)
    return chunks


def help_text(config: BridgeConfig) -> str:
    send_state = "enabled" if config.allow_send else "disabled"
    key_state = "enabled" if config.allow_key else "disabled"
    topic_state = "enabled" if config.allow_create_topics else "disabled"
    return f"""Prowl Telegram Bridge MVP

Topic setup:
/sync - list live Prowl worktrees
/bind <number|id|name|path> - bind this topic to a worktree
/unbind - remove this topic binding
/create_topics - create one Telegram topic per live worktree ({topic_state})
/whoami - show chat/thread/user ids

Inspect:
/status - status for this topic, or global overview when unbound
/agents - list detected agents
/panes - list panes in the bound worktree
/use <number|pane-id> - set default pane
/read [lines] [@pane] - read the default or selected pane

Control:
/send [@pane] <text> - send text and capture output ({send_state})
/key [@pane] <key> - send a key like ctrl-c or enter ({key_state})
/focus [@pane] - focus the pane in Prowl
""".strip()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Telegram topic bridge for Prowl CLI")
    parser.add_argument("--config", type=Path, help="Path to JSON config file")
    parser.add_argument("--once", action="store_true", help="Run one status-sync pass and exit")
    parser.add_argument("--verbose", action="store_true", help="Enable debug logging")
    args = parser.parse_args(argv)

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )

    try:
        config = load_config(args.config)
        bridge = Bridge(config)
        if args.once:
            bridge.run_once()
        else:
            bridge.run_forever()
    except BridgeError as error:
        LOG.error("%s", error)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
