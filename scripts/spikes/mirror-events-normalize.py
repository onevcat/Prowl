#!/usr/bin/env python3
"""Spike: normalize Claude Code and Codex transcripts into Prowl Mirror conversation events.

Usage:
  normalize.py claude <session.jsonl> [--render] [--limit N]
  normalize.py codex  <rollout.jsonl> [--render] [--limit N]

Emits one JSON object per line (the normalized event) or, with --render, one readable
line per event. This is a boundary probe, not production code: it shows which event
kinds each file source can produce, and what each kind can carry.
"""
from __future__ import annotations

import json
import sys
from collections import Counter
from datetime import datetime, timezone

TRUNCATE = 400


def trunc(text: str | None, limit: int = TRUNCATE) -> dict:
    if text is None:
        return {"text": None, "truncated": False}
    if len(text) <= limit:
        return {"text": text, "truncated": False}
    return {"text": text[:limit], "truncated": True, "totalChars": len(text)}


def iso_ms(ms: int | float | None) -> str | None:
    if ms is None:
        return None
    return datetime.fromtimestamp(ms / 1000, timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


class Emitter:
    def __init__(self, agent: str):
        self.agent = agent
        self.seq = 0
        self.events: list[dict] = []

    def emit(self, kind_: str, ts: str | None, source_: str, **data):
        self.seq += 1
        self.events.append({"seq": self.seq, "ts": ts, "agent": self.agent, "kind": kind_, "source": source_, "data": data})


# ---------------------------------------------------------------- Claude Code

CLAUDE_TOOL_KINDS = {
    "Bash": "shell", "Read": "read", "Write": "edit", "Edit": "edit", "MultiEdit": "edit", "NotebookEdit": "edit",
    "Grep": "search", "Glob": "search", "WebFetch": "web", "WebSearch": "web", "Agent": "agent", "Task": "agent",
    "AskUserQuestion": "question", "ExitPlanMode": "plan", "EnterPlanMode": "plan", "Skill": "skill",
}


def claude_tool_title(name: str, inp: dict) -> str:
    if name == "Bash":
        return (inp.get("description") or inp.get("command") or "")[:120]
    for key in ("file_path", "path", "pattern", "url", "query", "prompt", "description", "skill"):
        if isinstance(inp.get(key), str):
            return inp[key][:120]
    return ""


def normalize_claude(path: str) -> Emitter:
    em = Emitter("claude")
    session_announced = False
    pending_tools: dict[str, dict] = {}
    for line in open(path, encoding="utf-8"):
        line = line.strip()
        if not line:
            continue
        try:
            r = json.loads(line)
        except json.JSONDecodeError:
            em.emit("notice", None, "transcript", level="warning", text="unparseable transcript line")
            continue
        t = r.get("type")
        ts = r.get("timestamp")
        if not session_announced and r.get("sessionId") and t in ("user", "assistant", "system"):
            session_announced = True
            em.emit("session.started", ts, "transcript", sessionID=r.get("sessionId"), cwd=r.get("cwd"),
                    version=r.get("version"), gitBranch=r.get("gitBranch"), permissionMode=r.get("permissionMode"))
        if t == "ai-title":
            em.emit("session.titled", None, "transcript", title=r.get("aiTitle"))
        elif t == "queue-operation":
            op = r.get("operation")
            kind = {"enqueue": "user.queued", "remove": "user.unqueued", "popAll": "user.unqueued", "dequeue": "user.unqueued"}.get(op, "notice")
            em.emit(kind, ts, "transcript", operation=op, reason=r.get("reason"), **trunc(r.get("content"), 200))
        elif t == "user":
            m = r.get("message") or {}
            content = m.get("content")
            if r.get("isMeta"):
                continue
            if isinstance(content, str):
                origin = (r.get("origin") or {}).get("kind") if isinstance(r.get("origin"), dict) else r.get("turnOrigin")
                em.emit("turn.started", ts, "transcript", promptID=r.get("promptId"), origin=origin,
                        promptSource=r.get("promptSource"))
                em.emit("user.message", ts, "transcript", origin=origin, **trunc(content))
            elif isinstance(content, list):
                texts = [b.get("text") for b in content if isinstance(b, dict) and b.get("type") == "text"]
                images = sum(1 for b in content if isinstance(b, dict) and b.get("type") == "image")
                results = [b for b in content if isinstance(b, dict) and b.get("type") == "tool_result"]
                if texts or images:
                    em.emit("turn.started", ts, "transcript", promptID=r.get("promptId"), origin=r.get("turnOrigin"))
                    em.emit("user.message", ts, "transcript", origin=r.get("turnOrigin"), images=images, **trunc("\n".join(x for x in texts if x)))
                for b in results:
                    tool = pending_tools.pop(b.get("tool_use_id"), {})
                    rc = b.get("content")
                    if isinstance(rc, list):
                        rc = "\n".join(x.get("text", "") for x in rc if isinstance(x, dict))
                    tur = r.get("toolUseResult") if isinstance(r.get("toolUseResult"), dict) else {}
                    em.emit("tool.completed", ts, "transcript", toolID=b.get("tool_use_id"), name=tool.get("name"),
                            status="error" if b.get("is_error") else ("interrupted" if tur.get("interrupted") else "ok"),
                            output=trunc(rc if isinstance(rc, str) else None), isImage=bool(tur.get("isImage")))
            decision = r.get("permissionDecision")
            if isinstance(decision, dict) and decision.get("source") not in (None, "config"):
                em.emit("prompt.resolved", ts, "transcript", outcome=decision.get("decision"), decidedBy=decision.get("source"),
                        reasonType=decision.get("reasonType"))
        elif t == "assistant":
            m = r.get("message") or {}
            for b in m.get("content") or []:
                if not isinstance(b, dict):
                    continue
                bt = b.get("type")
                if bt == "text":
                    em.emit("assistant.message", ts, "transcript", model=m.get("model"), **trunc(b.get("text")))
                elif bt == "thinking":
                    em.emit("assistant.reasoning", ts, "transcript", summary=None, durationMs=r.get("thinkingDurationMs"))
                elif bt == "tool_use":
                    name = b.get("name") or ""
                    inp = b.get("input") if isinstance(b.get("input"), dict) else {}
                    pending_tools[b.get("id")] = {"name": name}
                    kind = CLAUDE_TOOL_KINDS.get(name, "mcp" if name.startswith("mcp__") else "other")
                    em.emit("tool.started", ts, "transcript", toolID=b.get("id"), name=name, kind=kind,
                            title=claude_tool_title(name, inp), command=inp.get("command"), path=inp.get("file_path"),
                            background=bool(inp.get("run_in_background")))
                    if name == "AskUserQuestion":
                        qs = inp.get("questions") or []
                        em.emit("prompt.opened", ts, "transcript", promptID=b.get("id"), kind="question",
                                questions=[{"header": q.get("header"), "question": q.get("question"),
                                            "multiSelect": q.get("multiSelect"),
                                            "options": [{"label": o.get("label"), "description": (o.get("description") or "")[:120]} for o in q.get("options") or []]}
                                           for q in qs if isinstance(q, dict)])
                    elif name == "ExitPlanMode":
                        em.emit("prompt.opened", ts, "transcript", promptID=b.get("id"), kind="plan-approval",
                                choices=[{"id": "approve", "label": "Approve plan"}, {"id": "reject", "label": "Keep planning"}])
        elif t == "system":
            sub = r.get("subtype")
            if sub == "turn_duration":
                em.emit("turn.completed", ts, "transcript", durationMs=r.get("durationMs"))
            elif sub == "compact_boundary":
                em.emit("context.compacted", ts, "transcript")
            elif sub == "stop_hook_summary":
                if r.get("hookErrors"):
                    em.emit("notice", ts, "transcript", level="warning", text=f"hook errors: {len(r['hookErrors'])}")
            elif sub in ("informational", "local_command", "away_summary"):
                em.emit("notice", ts, "transcript", level=r.get("level") or "info", subtype=sub, **trunc(str(r.get("content") or ""), 200))
        elif t == "cost-state":
            em.emit("session.cost", None, "transcript", totalCostUSD=r.get("totalCostUSD"), linesAdded=r.get("totalLinesAdded"), linesRemoved=r.get("totalLinesRemoved"))
    return em


# ---------------------------------------------------------------- Codex

CODEX_ITEM_KINDS = {"CommandExecution": "shell", "FileChange": "edit", "McpToolCall": "mcp", "Extension": "web",
                    "ImageView": "read", "DynamicToolCall": "other", "CollabAgentToolCall": "agent",
                    "SubAgentActivity": "agent"}


def codex_text(content) -> str:
    if isinstance(content, list):
        parts = []
        for c in content:
            if isinstance(c, dict):
                parts.append(c.get("text") or c.get("input_text") or "")
        return "\n".join(p for p in parts if p)
    return content if isinstance(content, str) else ""


def normalize_codex(path: str) -> Emitter:
    em = Emitter("codex")
    for line in open(path, encoding="utf-8"):
        line = line.strip()
        if not line:
            continue
        try:
            r = json.loads(line)
        except json.JSONDecodeError:
            em.emit("notice", None, "rollout", level="warning", text="unparseable rollout line")
            continue
        t = r.get("type")
        ts = r.get("timestamp")
        p = r.get("payload") if isinstance(r.get("payload"), dict) else {}
        pt = p.get("type")
        if t == "session_meta":
            em.emit("session.started", ts, "rollout", sessionID=p.get("id"), cwd=p.get("cwd"), version=p.get("cli_version"),
                    source=p.get("source"), threadSource=p.get("thread_source"))
        elif t == "turn_context":
            em.emit("session.settings", ts, "rollout", model=p.get("model"), approvalPolicy=p.get("approval_policy"),
                    sandbox=(p.get("sandbox_policy") or {}).get("mode") if isinstance(p.get("sandbox_policy"), dict) else p.get("sandbox_policy"),
                    effort=p.get("effort"), turnID=p.get("turn_id"))
        elif t == "compacted":
            em.emit("context.compacted", ts, "rollout")
        elif t == "event_msg":
            if pt == "task_started":
                em.emit("turn.started", ts, "rollout", turnID=p.get("turn_id"), origin=None)
            elif pt == "task_complete":
                em.emit("turn.completed", ts, "rollout", turnID=p.get("turn_id"), durationMs=p.get("duration_ms"),
                        lastMessage=trunc(p.get("last_agent_message"), 200))
            elif pt == "turn_aborted":
                em.emit("turn.completed", ts, "rollout", turnID=p.get("turn_id"), status="aborted", reason=p.get("reason"))
            elif pt == "item_completed":
                it = p.get("item") if isinstance(p.get("item"), dict) else {}
                itype = it.get("type")
                started = iso_ms(p.get("started_at_ms"))
                if itype == "UserMessage":
                    em.emit("user.message", started or ts, "rollout", origin="human", itemID=it.get("id"), **trunc(codex_text(it.get("content"))))
                elif itype == "AgentMessage":
                    em.emit("assistant.message", ts, "rollout", phase=it.get("phase"), itemID=it.get("id"), **trunc(codex_text(it.get("content"))))
                elif itype == "Reasoning":
                    summary = it.get("summary_text")
                    if isinstance(summary, list):
                        summary = "\n".join(str(s) for s in summary)
                    em.emit("assistant.reasoning", ts, "rollout", summary=trunc(summary or None, 200))
                elif itype == "ContextCompaction":
                    em.emit("context.compacted", ts, "rollout")
                elif itype in CODEX_ITEM_KINDS:
                    kind = CODEX_ITEM_KINDS[itype]
                    cmd = it.get("command")
                    if isinstance(cmd, list):
                        cmd = " ".join(str(c) for c in cmd)
                    title = cmd or it.get("tool") or it.get("query") or it.get("path") or ""
                    if itype == "FileChange":
                        title = ", ".join(list((it.get("changes") or {}).keys())[:3])
                    em.emit("tool.started", started or ts, "rollout", toolID=it.get("id"), name=itype, kind=kind, title=str(title)[:120],
                            command=cmd, cwd=it.get("cwd"), server=it.get("server"))
                    output = it.get("aggregated_output") or it.get("stdout") or (json.dumps(it.get("result"))[:TRUNCATE] if it.get("result") is not None else None)
                    em.emit("tool.completed", ts, "rollout", toolID=it.get("id"), name=itype, status=it.get("status") or "completed",
                            exitCode=it.get("exit_code"), output=trunc(output if isinstance(output, str) else None),
                            durationMs=(p.get("completed_at_ms") or 0) - (p.get("started_at_ms") or 0) if p.get("started_at_ms") else None)
                else:
                    em.emit("notice", ts, "rollout", level="debug", text=f"unmapped item {itype}")
        elif t == "response_item":
            if pt == "message" and p.get("role") == "developer":
                em.emit("notice", ts, "rollout", level="debug", text="developer message (instructions) omitted")
    return em


# ---------------------------------------------------------------- Render

def render(ev: dict) -> str:
    d = ev["data"]
    ts = (ev.get("ts") or "")[11:23]
    k = ev["kind"]
    if k in ("user.message", "assistant.message", "user.queued", "user.unqueued"):
        body = (d.get("text") or "").replace("\n", "⏎")[:90]
        extra = f" [{d.get('origin') or d.get('phase') or d.get('operation')}]"
        return f"{ts} {k:<20}{extra} {body}"
    if k == "tool.started":
        return f"{ts} {k:<20} {d.get('kind')}/{d.get('name')}: {(d.get('title') or '')[:80]}"
    if k == "tool.completed":
        out = (d.get('output') or {}).get('text') or ''
        return f"{ts} {k:<20} {d.get('name')} status={d.get('status')} exit={d.get('exitCode')} out={out.replace(chr(10), '⏎')[:60]!r}"
    if k == "prompt.opened":
        return f"{ts} {k:<20} kind={d.get('kind')} {json.dumps(d.get('questions') or d.get('choices'), ensure_ascii=False)[:120]}"
    return f"{ts} {k:<20} {json.dumps({x: y for x, y in d.items() if y not in (None, '', False)}, ensure_ascii=False)[:110]}"


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(2)
    agent, path = sys.argv[1], sys.argv[2]
    do_render = "--render" in sys.argv
    limit = None
    if "--limit" in sys.argv:
        limit = int(sys.argv[sys.argv.index("--limit") + 1])
    em = normalize_claude(path) if agent == "claude" else normalize_codex(path)
    events = em.events[:limit] if limit else em.events
    if do_render:
        for ev in events:
            print(render(ev))
        print("--- kinds:", dict(Counter(e["kind"] for e in em.events)))
    else:
        for ev in events:
            print(json.dumps(ev, ensure_ascii=False))


if __name__ == "__main__":
    main()
