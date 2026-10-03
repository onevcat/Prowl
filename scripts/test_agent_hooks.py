"""Behavioral tests for the bundled managed-hook extensions in App/Resources/agent-hooks.

The extensions are TypeScript relays loaded in-process by Pi, Oh My Pi, and OpenCode. Node runs
them here with the same handler contract those runtimes use, against a capture script standing
in for the bundled `prowl` CLI, so the forwarding decisions (which events, which session id,
sub-agent filtering) are pinned without launching an agent.
"""

import json
import os
import pathlib
import shutil
import subprocess
import tempfile
import textwrap
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
HOOKS = ROOT / "App" / "Resources" / "agent-hooks"
NODE = shutil.which("node")

CAPTURE = textwrap.dedent(
    """\
    #!/bin/sh
    payload=$(cat)
    printf '%s\\t%s\\n' "$*" "$payload" >> "$PROWL_TEST_CAPTURE"
    """
)

PI_FAMILY_HARNESS = textwrap.dedent(
    """\
    import { pathToFileURL } from "node:url";
    import { promises as fs } from "node:fs";
    const capturePath = process.env.PROWL_TEST_CAPTURE;
    async function captureCount() {
      try { return (await fs.readFile(capturePath, "utf8")).split("\\n").filter(Boolean).length; } catch { return 0; }
    }
    // Handlers are fired back to back, the way a runtime emits adjacent lifecycle events; the
    // relay must serialize its own deliveries, so the capture order is asserted strictly.
    async function quiesce() {
      let last = -1;
      let stableSince = Date.now();
      const deadline = Date.now() + 8000;
      while (Date.now() < deadline) {
        await new Promise((resolve) => setTimeout(resolve, 25));
        const count = await captureCount();
        if (count !== last) { last = count; stableSince = Date.now(); }
        else if (Date.now() - stableSince > 500) return;
      }
    }
    const [extensionPath, scriptPath] = process.argv.slice(2);
    const steps = JSON.parse(await import("node:fs").then((fs) => fs.promises.readFile(scriptPath, "utf8")));
    // A step may name an `instance`: the runtime loads a fresh module instance on `/reload` and
    // for every sub-agent session, which a cache-busting query reproduces here.
    const instances = new Map();
    async function handlersFor(instance) {
      const key = instance ?? 0;
      if (!instances.has(key)) {
        const url = pathToFileURL(extensionPath);
        url.searchParams.set("instance", String(key));
        const module = await import(url.href);
        const handlers = new Map();
        module.default({ on(name, handler) { handlers.set(name, handler); } });
        instances.set(key, handlers);
      }
      return instances.get(key);
    }
    for (const step of steps) {
      const handler = (await handlersFor(step.instance)).get(step.event);
      if (!handler) continue;
      const ctx = {
        hasUI: step.hasUI,
        mode: step.hasUI ? "tui" : "print",
        cwd: step.cwd ?? "/tmp/project",
        sessionManager: {
          getSessionId: () => step.session,
          getSessionFile: () => step.file,
        },
      };
      await handler(step.payload ?? { type: step.event }, ctx);
    }
    await quiesce();
    """
)

OPENCODE_HARNESS = textwrap.dedent(
    """\
    import { pathToFileURL } from "node:url";
    import { promises as fs } from "node:fs";
    const capturePath = process.env.PROWL_TEST_CAPTURE;
    async function captureCount() {
      try { return (await fs.readFile(capturePath, "utf8")).split("\\n").filter(Boolean).length; } catch { return 0; }
    }
    // Handlers are fired back to back, the way a runtime emits adjacent lifecycle events; the
    // relay must serialize its own deliveries, so the capture order is asserted strictly.
    async function quiesce() {
      let last = -1;
      let stableSince = Date.now();
      const deadline = Date.now() + 8000;
      while (Date.now() < deadline) {
        await new Promise((resolve) => setTimeout(resolve, 25));
        const count = await captureCount();
        if (count !== last) { last = count; stableSince = Date.now(); }
        else if (Date.now() - stableSince > 500) return;
      }
    }
    const [pluginPath, scriptPath] = process.argv.slice(2);
    const module = await import(pathToFileURL(pluginPath));
    const hooks = await module.ProwlHooks({ directory: "/tmp/project", worktree: "/tmp/project", project: {}, client: {}, $: null });
    const events = JSON.parse(await import("node:fs").then((fs) => fs.promises.readFile(scriptPath, "utf8")));
    for (const event of events) {
      await hooks.event({ event });
    }
    await quiesce();
    """
)


@unittest.skipUnless(NODE, "node is required to run the bundled extensions")
class AgentHookExtensionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp(prefix="prowl-agent-hooks-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        cli_dir = self.tmp / "prowl-cli"
        cli_dir.mkdir()
        cli = cli_dir / "prowl"
        cli.write_text(CAPTURE)
        cli.chmod(0o755)
        self.capture = self.tmp / "capture.log"
        self.capture.write_text("")
        for runtime in ("pi", "omp", "opencode"):
            target = self.tmp / "agent-hooks" / runtime
            target.mkdir(parents=True)
            shutil.copy(HOOKS / runtime / "prowl-hooks.ts", target / "prowl-hooks.ts")

    def run_harness(self, harness, extension, steps, token="token-1"):
        harness_path = self.tmp / "harness.mjs"
        harness_path.write_text(harness)
        script_path = self.tmp / "steps.json"
        script_path.write_text(json.dumps(steps))
        env = dict(os.environ)
        env["PROWL_TEST_CAPTURE"] = str(self.capture)
        env.pop("PROWL_AGENT_HOOK_TOKEN", None)
        if token is not None:
            env["PROWL_AGENT_HOOK_TOKEN"] = token
        completed = subprocess.run(
            [NODE, "--experimental-strip-types", "--no-warnings", str(harness_path), str(extension), str(script_path)],
            env=env,
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        forwarded = []
        for line in self.capture.read_text().splitlines():
            argv, payload = line.split("\t", 1)
            forwarded.append((argv.split(" "), json.loads(payload)))
        return forwarded

    def pi_family(self, runtime, steps, token="token-1"):
        return self.run_harness(PI_FAMILY_HARNESS, self.tmp / "agent-hooks" / runtime / "prowl-hooks.ts", steps, token)

    # Pi

    MAIN_1 = "/Users/me/.pi/agent/sessions/--tmp-project--/2026-08-26T10-00-00-000Z_main-1.jsonl"
    MAIN_2 = "/Users/me/.pi/agent/sessions/--tmp-project--/2026-08-26T10-05-00-000Z_main-2.jsonl"
    SUB_1 = "/Users/me/.pi/agent/sessions/--tmp-project--/2026-08-26T10-00-00-000Z_main-1/Worker.jsonl"
    SUB_NESTED = "/Users/me/.pi/agent/sessions/--tmp-project--/2026-08-26T10-00-00-000Z_main-1/Worker/Worker.Inner.jsonl"

    def test_pi_forwards_its_lifecycle_with_native_names_and_a_custom_session_id(self):
        session = "prowlcustom"
        file = "/Users/me/.pi/agent/sessions/--tmp-project--/2026-08-26T12-01-30-384Z_prowlcustom.jsonl"
        forwarded = self.pi_family(
            "pi",
            [
                {"event": "session_start", "hasUI": True, "session": session, "file": file, "payload": {"type": "session_start", "reason": "startup"}},
                {"event": "agent_settled", "hasUI": True, "session": session, "file": file},
                {"event": "agent_end", "hasUI": True, "session": session, "file": file},
                {"event": "session_shutdown", "hasUI": True, "session": session, "file": file, "payload": {"type": "session_shutdown", "reason": "quit"}},
            ],
        )
        self.assertEqual(
            [(argv, payload["hook_event_name"], payload["session_id"], payload.get("reason")) for argv, payload in forwarded],
            [
                (["agents", "_hook", "pi", "session_start"], "session_start", session, "startup"),
                (["agents", "_hook", "pi", "agent_settled"], "agent_settled", session, None),
                (["agents", "_hook", "pi", "session_shutdown"], "session_shutdown", session, "quit"),
            ],
        )
        self.assertTrue(all(payload["cwd"] == "/tmp/project" for _, payload in forwarded))

    def test_pi_sub_agent_sessions_are_recognised_by_their_nested_file_without_shared_state(self):
        # The runtime loads a fresh extension instance per sub-agent session, so every step here
        # is classified on its own: a headless main (no UI) still counts, a nested file never does.
        forwarded = self.pi_family(
            "pi",
            [
                {"event": "session_start", "hasUI": False, "session": "main-1", "file": self.MAIN_1},
                {"event": "session_start", "hasUI": False, "session": "sub-1", "file": self.SUB_1},
                {"event": "agent_settled", "hasUI": False, "session": "sub-1", "file": self.SUB_1},
                {"event": "session_shutdown", "hasUI": False, "session": "sub-2", "file": self.SUB_NESTED},
                {"event": "agent_settled", "hasUI": False, "session": "main-1", "file": self.MAIN_1},
                {"event": "agent_settled", "hasUI": True, "session": "ephemeral", "file": None},
            ],
        )
        self.assertEqual(
            [(payload["hook_event_name"], payload["session_id"]) for _, payload in forwarded],
            [("session_start", "main-1"), ("agent_settled", "main-1"), ("agent_settled", "ephemeral")],
        )

    def test_pi_new_session_in_the_tui_rotates_the_main_session(self):
        forwarded = self.pi_family(
            "pi",
            [
                {"event": "session_start", "hasUI": True, "session": "main-1", "file": self.MAIN_1},
                {"event": "session_shutdown", "hasUI": True, "session": "main-1", "file": self.MAIN_1, "payload": {"type": "session_shutdown", "reason": "new"}},
                {"event": "session_start", "hasUI": True, "session": "main-2", "file": self.MAIN_2, "payload": {"type": "session_start", "reason": "new"}},
                {"event": "agent_settled", "hasUI": True, "session": "main-2", "file": self.MAIN_2},
            ],
        )
        self.assertEqual(
            [(payload["hook_event_name"], payload["session_id"]) for _, payload in forwarded],
            [("session_start", "main-1"), ("session_shutdown", "main-1"), ("session_start", "main-2"), ("agent_settled", "main-2")],
        )

    def test_pi_keeps_lifecycle_order_across_a_burst_of_adjacent_events(self):
        # Pi emits `agent_settled` and `session_shutdown` milliseconds apart at exit, and a
        # `/new` rotation is a `session_shutdown` immediately followed by a `session_start`.
        steps = []
        for index in range(12):
            session = f"main-{index}"
            file = f"/s/2026-08-26T10-00-00-{index:03d}Z_{session}.jsonl"
            steps.append({"event": "session_start", "hasUI": True, "session": session, "file": file})
            steps.append({"event": "agent_settled", "hasUI": True, "session": session, "file": file})
            steps.append({"event": "session_shutdown", "hasUI": True, "session": session, "file": file})
        forwarded = self.pi_family("pi", steps)
        self.assertEqual(
            [(payload["hook_event_name"], payload["session_id"]) for _, payload in forwarded],
            [(step["event"], step["session"]) for step in steps],
        )

    def test_pi_reload_swaps_instances_without_ending_or_reannouncing_the_session(self):
        # `/reload` fires `session_shutdown{reload}` on the old instance and, milliseconds later,
        # `session_start{reload}` on a fresh instance with the same id; the session continues.
        forwarded = self.pi_family(
            "pi",
            [
                {"event": "session_start", "hasUI": True, "session": "main-1", "file": self.MAIN_1, "instance": 1},
                {"event": "agent_settled", "hasUI": True, "session": "main-1", "file": self.MAIN_1, "instance": 1},
                {"event": "session_shutdown", "hasUI": True, "session": "main-1", "file": self.MAIN_1, "instance": 1, "payload": {"type": "session_shutdown", "reason": "reload"}},
                {"event": "session_start", "hasUI": True, "session": "main-1", "file": self.MAIN_1, "instance": 2, "payload": {"type": "session_start", "reason": "reload"}},
                {"event": "agent_settled", "hasUI": True, "session": "main-1", "file": self.MAIN_1, "instance": 2},
                {"event": "session_shutdown", "hasUI": True, "session": "main-1", "file": self.MAIN_1, "instance": 2, "payload": {"type": "session_shutdown", "reason": "quit"}},
            ],
        )
        self.assertEqual(
            [(payload["hook_event_name"], payload["session_id"], payload.get("reason")) for _, payload in forwarded],
            [("session_start", "main-1", None), ("agent_settled", "main-1", None), ("agent_settled", "main-1", None), ("session_shutdown", "main-1", "quit")],
        )

    def test_deliveries_stay_ordered_across_extension_instances(self):
        # Instances loaded for sub-agent sessions (and by `/reload`) share one delivery order.
        steps = []
        for index in range(10):
            main = f"main-{index}"
            main_file = f"/s/2026-08-26T10-00-00-{index:03d}Z_{main}.jsonl"
            sub_file = f"/s/2026-08-26T10-00-00-{index:03d}Z_{main}/Worker.jsonl"
            steps.append({"event": "session_start", "hasUI": True, "session": main, "file": main_file, "instance": 1})
            steps.append({"event": "tool_approval_requested", "hasUI": False, "session": f"sub-{index}", "file": sub_file, "instance": 2, "payload": {"type": "tool_approval_requested", "toolName": "write"}})
            steps.append({"event": "session_stop", "hasUI": True, "session": main, "file": main_file, "instance": 1})
        forwarded = self.pi_family("omp", steps)
        expected = []
        for index in range(10):
            expected += [("session_start", f"main-{index}"), ("tool_approval_requested", f"main-{index}"), ("session_stop", f"main-{index}")]
        self.assertEqual([(payload["hook_event_name"], payload["session_id"]) for _, payload in forwarded], expected)

    def test_pi_without_a_launch_token_spawns_nothing(self):
        forwarded = self.pi_family("pi", [{"event": "session_start", "hasUI": True, "session": "main-1", "file": self.MAIN_1}], token=None)
        self.assertEqual(forwarded, [])

    # Oh My Pi

    def test_omp_forwards_session_switch_and_sub_agent_approvals_under_the_parent_session(self):
        forwarded = self.pi_family(
            "omp",
            [
                {"event": "session_start", "hasUI": True, "session": "main-1", "file": self.MAIN_1},
                {"event": "tool_approval_requested", "hasUI": True, "session": "main-1", "file": self.MAIN_1, "payload": {"type": "tool_approval_requested", "toolName": "task", "sessionId": "main-1"}},
                {"event": "session_start", "hasUI": False, "session": "sub-1", "file": self.SUB_1},
                {"event": "tool_approval_requested", "hasUI": False, "session": "sub-1", "file": self.SUB_1, "payload": {"type": "tool_approval_requested", "toolName": "write", "sessionId": "sub-1"}},
                {"event": "tool_approval_requested", "hasUI": False, "session": "sub-2", "file": self.SUB_NESTED, "payload": {"type": "tool_approval_requested", "toolName": "bash", "sessionId": "sub-2"}},
                {"event": "agent_end", "hasUI": False, "session": "sub-1", "file": self.SUB_1},
                {"event": "session_shutdown", "hasUI": False, "session": "sub-1", "file": self.SUB_1},
                {"event": "session_stop", "hasUI": True, "session": "main-1", "file": self.MAIN_1, "payload": {"type": "session_stop", "session_id": "main-1", "last_assistant_message": "secret"}},
                {"event": "session_switch", "hasUI": True, "session": "main-2", "file": self.MAIN_2},
                {"event": "session_stop", "hasUI": True, "session": "main-2", "file": self.MAIN_2, "payload": {"type": "session_stop", "session_id": "main-2"}},
                {"event": "session_shutdown", "hasUI": True, "session": "main-2", "file": self.MAIN_2},
            ],
        )
        self.assertEqual(
            [(payload["hook_event_name"], payload["session_id"], payload.get("reason")) for _, payload in forwarded],
            [
                ("session_start", "main-1", None),
                ("tool_approval_requested", "main-1", "task"),
                ("tool_approval_requested", "main-1", "write"),
                ("tool_approval_requested", "main-1", "bash"),
                ("session_stop", "main-1", None),
                ("session_switch", "main-2", None),
                ("session_stop", "main-2", None),
                ("session_shutdown", "main-2", None),
            ],
        )
        self.assertTrue(all(argv[:3] == ["agents", "_hook", "omp"] for argv, _ in forwarded))
        self.assertFalse(any("secret" in json.dumps(payload) for _, payload in forwarded))

    # OpenCode

    def test_opencode_forwards_top_level_session_events_and_drops_sub_agent_sessions(self):
        forwarded = self.run_harness(
            OPENCODE_HARNESS,
            self.tmp / "agent-hooks" / "opencode" / "prowl-hooks.ts",
            [
                {"type": "session.created", "properties": {"sessionID": "ses_main", "info": {"id": "ses_main"}}},
                {"type": "session.status", "properties": {"sessionID": "ses_main", "status": {"type": "busy"}}},
                {"type": "session.created", "properties": {"sessionID": "ses_child", "info": {"id": "ses_child", "parentID": "ses_main"}}},
                {"type": "session.idle", "properties": {"sessionID": "ses_child"}},
                {"type": "permission.asked", "properties": {"sessionID": "ses_child", "permission": "edit"}},
                {"type": "permission.asked", "properties": {"sessionID": "ses_main", "permission": "edit"}},
                {"type": "permission.replied", "properties": {"sessionID": "ses_main", "reply": "once"}},
                {"type": "question.asked", "properties": {"sessionID": "ses_main"}},
                {"type": "session.error", "properties": {"sessionID": "ses_main"}},
                {"type": "session.idle", "properties": {"sessionID": "ses_main"}},
            ],
        )
        self.assertEqual(
            [(argv, payload["hook_event_name"], payload["session_id"], payload.get("reason")) for argv, payload in forwarded],
            [
                (["agents", "_hook", "opencode", "permission.asked"], "permission.asked", "ses_main", "edit"),
                (["agents", "_hook", "opencode", "question.asked"], "question.asked", "ses_main", None),
                (["agents", "_hook", "opencode", "session.idle"], "session.idle", "ses_main", None),
            ],
        )
        self.assertTrue(all(payload["cwd"] == "/tmp/project" for _, payload in forwarded))


if __name__ == "__main__":
    unittest.main()
