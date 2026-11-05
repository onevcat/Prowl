#!/usr/bin/env python3
"""Sanitize an agent transcript into a bounded fixture: drop private/bulky records, truncate
long text, and replace the home directory. Usage: sanitize.py claude|codex <in> <out>"""
import json, sys, os
LIMIT = 3000
HOME = os.path.expanduser("~")
def scrub(v):
    if isinstance(v, str):
        v = v.replace(HOME, "/Users/dev")
        return v if len(v) <= LIMIT else v[:LIMIT] + "…[truncated]"
    if isinstance(v, list): return [scrub(x) for x in v]
    if isinstance(v, dict): return {k: scrub(x) for k, x in v.items()}
    return v
agent, src, dst = sys.argv[1:4]
kept = 0; dropped = 0
with open(dst, "w", encoding="utf-8") as out:
    for line in open(src, encoding="utf-8"):
        line = line.strip()
        if not line: continue
        r = json.loads(line)
        t = r.get("type")
        if agent == "claude":
            if t not in ("user", "assistant", "system", "queue-operation", "ai-title", "cost-state"):
                dropped += 1; continue
            for k in ("wireIngestContext", "wireToolInputs", "requestRef", "advisorModel"):
                r.pop(k, None)
        else:
            p = r.get("payload") if isinstance(r.get("payload"), dict) else {}
            if t == "response_item" and p.get("role") == "developer": dropped += 1; continue
            if t == "response_item" and p.get("type") in ("reasoning", "additional_tools"): dropped += 1; continue
            if t in ("token_usage_record", "world_state"): dropped += 1; continue
            if t == "session_meta": p["base_instructions"] = "[omitted]"
            if t == "event_msg" and p.get("type") == "token_count": dropped += 1; continue
        out.write(json.dumps(scrub(r), ensure_ascii=False) + "\n"); kept += 1
print(f"{agent}: kept {kept}, dropped {dropped}, bytes {os.path.getsize(dst)}")
