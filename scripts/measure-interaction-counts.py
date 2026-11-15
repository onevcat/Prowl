#!/usr/bin/env python3
"""Count main-thread work on interaction call paths in a running Prowl Debug app.

The script seeds a temporary set of repositories and worktrees, launches the given
Prowl app against an isolated home, data directory, and CLI socket, attaches LLDB,
and counts breakpoint hits for each interaction:

- worktree switches inside one repository and across repositories (`prowl focus`),
- app deactivation and activation (`open -b com.apple.finder`, then `open -a <app>`).

Hit counts do not depend on machine speed, so they compare across CI runners and
local machines. Wall time is recorded only as context.

The counters (see `PROBES`):

- `strings_table_parse`: CoreFoundation parses a strings table. On macOS 26 this
  happens on every `String(localized: LocalizedStringResource)` call (#1074).
- `resource_to_string`: `String(localized: LocalizedStringResource)` calls.
- `help_text`: `AppShortcuts.helpText(title:commandID:in:)` calls, a proxy for how
  much of the sidebar and the menu bar SwiftUI evaluates again.
- `body`: (with `--count-bodies`) `body` getters of views in the Prowl module.

Run `make measure-interaction-counts` (it builds the Debug app first) or call this
script with `--app <path to Prowl Debug.app>`.
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import shutil
import statistics
import subprocess
import sys
import tempfile
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path


def import_lldb():
  lldb_python = subprocess.run(
    ["xcrun", "lldb", "-P"], check=True, capture_output=True, text=True
  ).stdout.strip()
  sys.path.insert(0, lldb_python)
  import lldb  # noqa: PLC0415

  return lldb


@dataclass(frozen=True)
class Probe:
  key: str
  # Exactly one of `name` (a symbol, demangled or mangled) or `regex` is set.
  name: str | None = None
  regex: str | None = None
  module: str | None = None
  optional: bool = False


PROBES = [
  Probe("strings_table_parse", name="__CFBundleCreateStringsFromPlistData", module="CoreFoundation"),
  Probe(
    "resource_to_string",
    # (extension in Foundation):Swift.String.init(localized: Foundation.LocalizedStringResource)
    name="$sSS10FoundationE9localizedSSAA23LocalizedStringResourceV_tcfC",
  ),
  Probe("help_text", regex=r"^static Prowl\.AppShortcuts\.helpText\(title:", optional=True),
]

BODY_PROBE = Probe("body", regex=r"^Prowl\..*\.body\.getter :", optional=True)

STEPS = ["switch_same_repo", "switch_cross_repo", "deactivate", "activate"]


@dataclass
class StepSample:
  step: str
  counts: dict[str, int]
  seconds: float
  body_top: list[tuple[str, int]] = field(default_factory=list)


def run(cmd: list[str], **kwargs) -> subprocess.CompletedProcess:
  return subprocess.run(cmd, check=True, capture_output=True, text=True, **kwargs)


def git(*args: str, cwd: Path) -> None:
  run(["git", *args], cwd=cwd)


def seed_repositories(root: Path, repo_count: int, extra_worktrees: int) -> list[list[Path]]:
  """Create `repo_count` repositories, each with `extra_worktrees` linked worktrees."""
  env = dict(os.environ, GIT_AUTHOR_NAME="perf", GIT_AUTHOR_EMAIL="perf@example.invalid")
  env.update(GIT_COMMITTER_NAME="perf", GIT_COMMITTER_EMAIL="perf@example.invalid")
  groups: list[list[Path]] = []
  for index in range(repo_count):
    repo = root / f"repo-{chr(ord('a') + index)}"
    repo.mkdir(parents=True)
    run(["git", "init", "-q", "-b", "main"], cwd=repo, env=env)
    (repo / "README.md").write_text(f"perf fixture {index}\n")
    run(["git", "add", "README.md"], cwd=repo, env=env)
    run(["git", "commit", "-q", "-m", "init"], cwd=repo, env=env)
    paths = [repo]
    for worktree in range(extra_worktrees):
      path = root / f"{repo.name}-wt{worktree + 1}"
      run(["git", "worktree", "add", "-q", "-b", f"wt{worktree + 1}", str(path)], cwd=repo, env=env)
      paths.append(path)
    groups.append(paths)
  return groups


class ProwlInstance:
  def __init__(self, app: Path, workdir: Path, language: str):
    self.app = app
    self.workdir = workdir
    self.language = language
    self.home = workdir / "home"
    self.data = workdir / "data"
    self.socket = workdir / "cli.sock"
    self.cli = app / "Contents/Resources/prowl-cli/prowl"
    self.pid: int | None = None

  def launch(self) -> int:
    self.home.mkdir(parents=True, exist_ok=True)
    self.data.mkdir(parents=True, exist_ok=True)
    executable_dir = self.app / "Contents/MacOS/ProwlApp"
    before = set(self._pids(executable_dir))
    env = {k: v for k, v in os.environ.items() if k != "CLAUDE_CODE_CHILD_SESSION"}
    run(
      [
        "open", "-n", "-g",
        "--env", f"CFFIXED_USER_HOME={self.home}",
        "--env", f"PROWL_DEBUG_DATA_DIRECTORY={self.data}",
        "--env", f"PROWL_CLI_SOCKET={self.socket}",
        str(self.app),
        "--args", "-AppleLanguages", f"({self.language})",
      ],
      env=env,
    )
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
      new = set(self._pids(executable_dir)) - before
      if new and self.socket.exists():
        self.pid = max(new)
        return self.pid
      time.sleep(0.25)
    raise RuntimeError("Prowl did not start or did not open its CLI socket within 60 s")

  @staticmethod
  def _pids(executable_dir: Path) -> list[int]:
    result = subprocess.run(["pgrep", "-f", str(executable_dir)], capture_output=True, text=True)
    return [int(line) for line in result.stdout.split()]

  def cli_json(self, *args: str, timeout: float = 60) -> dict:
    env = dict(os.environ, PROWL_CLI_SOCKET=str(self.socket))
    result = subprocess.run(
      [str(self.cli), *args, "--json"], capture_output=True, text=True, env=env, timeout=timeout
    )
    try:
      payload = json.loads(result.stdout)
    except json.JSONDecodeError as error:
      raise RuntimeError(f"prowl {' '.join(args)} returned no JSON: {result.stdout}{result.stderr}") from error
    if not payload.get("ok", False):
      raise RuntimeError(f"prowl {' '.join(args)} failed: {json.dumps(payload)}")
    return payload

  def terminate(self) -> None:
    if self.pid is None:
      return
    subprocess.run(["kill", str(self.pid)], capture_output=True)
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline and subprocess.run(["kill", "-0", str(self.pid)], capture_output=True).returncode == 0:
      time.sleep(0.2)
    subprocess.run(["kill", "-9", str(self.pid)], capture_output=True)


class Counter:
  def __init__(self, lldb, pid: int, count_bodies: bool):
    self.lldb = lldb
    self.debugger = lldb.SBDebugger.Create()
    self.debugger.SetAsync(True)
    self.target = self.debugger.CreateTarget("")
    error = lldb.SBError()
    listener = self.debugger.GetListener()
    self.process = self.target.AttachToProcessWithID(listener, pid, error)
    if not error.Success():
      raise RuntimeError(f"LLDB could not attach to {pid}: {error.GetCString()}")
    self._wait_for_state(lldb.eStateStopped)
    self.breakpoints: dict[str, object] = {}
    probes = PROBES + ([BODY_PROBE] if count_bodies else [])
    for probe in probes:
      if probe.regex:
        breakpoint = self.target.BreakpointCreateByRegex(probe.regex)
      else:
        breakpoint = self.target.BreakpointCreateByName(probe.name, probe.module) if probe.module else self.target.BreakpointCreateByName(probe.name)
      if breakpoint.GetNumLocations() == 0:
        if not probe.optional:
          raise RuntimeError(f"probe {probe.key} resolved to no locations")
        print(f"note: probe {probe.key} has no locations; it reports 0", file=sys.stderr)
      breakpoint.SetAutoContinue(True)
      self.breakpoints[probe.key] = breakpoint
    # Terminal panes deliver signals that LLDB stops on by default; pass them through.
    result = lldb.SBCommandReturnObject()
    self.debugger.GetCommandInterpreter().HandleCommand(
      "process handle SIGPIPE SIGCHLD SIGWINCH SIGUSR1 SIGUSR2 SIGALRM SIGURG SIGIO SIGVTALRM SIGPROF SIGINT SIGHUP "
      "SIGTERM SIGCONT SIGTSTP SIGTTIN SIGTTOU -s false -n false -p true",
      result,
    )
    self.unexpected_stops = 0
    self._stop = threading.Event()
    self.process.Continue()
    self._wait_for_state(lldb.eStateRunning)
    self._pump = threading.Thread(target=self._pump_events, daemon=True)
    self._pump.start()

  def _wait_for_state(self, state, timeout: float = 30) -> None:
    listener = self.debugger.GetListener()
    event = self.lldb.SBEvent()
    deadline = time.monotonic() + timeout
    while self.process.GetState() != state:
      if time.monotonic() > deadline:
        raise RuntimeError(f"LLDB: process did not reach state {state}")
      listener.WaitForEvent(1, event)

  def _pump_events(self) -> None:
    """Drain process events and resume any stop that is not an auto-continued breakpoint."""
    lldb = self.lldb
    listener = self.debugger.GetListener()
    event = lldb.SBEvent()
    while not self._stop.is_set():
      if not listener.WaitForEvent(1, event):
        continue
      if not lldb.SBProcess.EventIsProcessEvent(event):
        continue
      state = lldb.SBProcess.GetStateFromEvent(event)
      if state == lldb.eStateStopped and not lldb.SBProcess.GetRestartedFromEvent(event):
        self.unexpected_stops += 1
        if self.unexpected_stops <= 5:
          thread = self.process.GetSelectedThread()
          print(f"note: unexpected stop ({thread.GetStopDescription(200)}); resuming", file=sys.stderr)
        self.process.Continue()
      elif state in (lldb.eStateExited, lldb.eStateCrashed, lldb.eStateDetached):
        return

  def snapshot(self) -> dict[str, int]:
    if self.process.GetState() not in (self.lldb.eStateRunning, self.lldb.eStateStopped, self.lldb.eStateStepping):
      raise RuntimeError(f"the app is no longer running (state {self.process.GetState()})")
    return {key: bp.GetHitCount() for key, bp in self.breakpoints.items()}

  def body_locations(self) -> dict[str, int]:
    breakpoint = self.breakpoints.get("body")
    if breakpoint is None:
      return {}
    result: dict[str, int] = {}
    for index in range(breakpoint.GetNumLocations()):
      location = breakpoint.GetLocationAtIndex(index)
      hits = location.GetHitCount()
      if hits:
        name = location.GetAddress().GetFunction().GetName() or location.GetAddress().GetSymbol().GetName()
        result[name] = result.get(name, 0) + hits
    return result

  def detach(self) -> None:
    self._stop.set()
    self._pump.join(timeout=5)
    try:
      if self.process.GetState() == self.lldb.eStateRunning:
        self.process.Stop()
        self._wait_for_state(self.lldb.eStateStopped, timeout=10)
      self.process.Detach()
    finally:
      self.lldb.SBDebugger.Destroy(self.debugger)


def settle(counter: Counter, quiet: float, minimum: float, maximum: float) -> dict[str, int]:
  """Wait until no counter changes for `quiet` seconds, after at least `minimum` seconds."""
  start = time.monotonic()
  last = counter.snapshot()
  last_change = start
  while True:
    time.sleep(0.25)
    now = time.monotonic()
    current = counter.snapshot()
    if current != last:
      last = current
      last_change = now
    if now - start >= minimum and now - last_change >= quiet:
      return current
    if now - start >= maximum:
      print("warning: counters did not settle; using the current values", file=sys.stderr)
      return current


def measure_step(counter: Counter, step: str, action, args) -> StepSample:
  before = settle(counter, args.quiet, 0, args.max_settle)
  bodies_before = counter.body_locations()
  start = time.monotonic()
  action()
  after = settle(counter, args.quiet, args.min_settle, args.max_settle)
  seconds = time.monotonic() - start - args.quiet
  bodies_after = counter.body_locations()
  delta = {key: after[key] - before[key] for key in after}
  body_delta = {name: hits - bodies_before.get(name, 0) for name, hits in bodies_after.items()}
  top = sorted(((n, h) for n, h in body_delta.items() if h > 0), key=lambda item: -item[1])[:15]
  return StepSample(step, delta, max(seconds, 0), top)


def summarize(samples: list[StepSample]) -> dict:
  summary: dict[str, dict] = {}
  for step in STEPS:
    rows = [s for s in samples if s.step == step]
    if not rows:
      continue
    keys = rows[0].counts.keys()
    summary[step] = {
      "rounds": len(rows),
      "median": {key: statistics.median(r.counts[key] for r in rows) for key in keys},
      "min": {key: min(r.counts[key] for r in rows) for key in keys},
      "max": {key: max(r.counts[key] for r in rows) for key in keys},
      "median_seconds_with_lldb": round(statistics.median(r.seconds for r in rows), 3),
    }
  return summary


def print_table(summary: dict) -> None:
  keys = sorted({key for step in summary.values() for key in step["median"]})
  header = f"{'step':<20}" + "".join(f"{key:>22}" for key in keys)
  print(header)
  for step, values in summary.items():
    cells = "".join(
      f"{values['median'][key]:>12g} [{values['min'][key]:g}-{values['max'][key]:g}]".rjust(22) for key in keys
    )
    print(f"{step:<20}{cells}")


def markdown_table(report: dict) -> str:
  """Render the medians of a report as a Markdown table (for the CI job summary)."""
  summary = report["summary"]
  keys = sorted({key for step in summary.values() for key in step["median"]})
  title = f"macOS {report['os']} · {report['language']} · {report['worktrees']} worktrees"
  if report.get("label"):
    title += f" · {report['label']}"
  lines = [f"### {title}", "", "| Step | " + " | ".join(keys) + " |", "| --- |" + " ---: |" * len(keys)]
  for step, values in summary.items():
    lines.append(f"| {step} | " + " | ".join(f"{values['median'][key]:g}" for key in keys) + " |")
  return "\n".join(lines) + "\n\n"


def main() -> int:
  parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
  parser.add_argument("--app", required=True, type=Path, help="Path to Prowl Debug.app")
  parser.add_argument("--language", default="zh-Hans")
  parser.add_argument("--repos", type=int, default=4)
  parser.add_argument("--worktrees-per-repo", type=int, default=3, help="Linked worktrees per repository")
  parser.add_argument("--rounds", type=int, default=5)
  parser.add_argument("--count-bodies", action="store_true", help="Also count Prowl view body evaluations")
  parser.add_argument("--quiet", type=float, default=1.5, help="Seconds without counter changes that end a step")
  parser.add_argument("--min-settle", type=float, default=2.0)
  parser.add_argument("--max-settle", type=float, default=30.0)
  parser.add_argument("--output", type=Path, help="Write the JSON report here")
  parser.add_argument("--markdown", type=Path, help="Append a Markdown table of the medians here")
  parser.add_argument("--label", default="", help="Free-form label stored in the report")
  parser.add_argument("--keep-workdir", action="store_true")
  args = parser.parse_args()

  app = args.app.resolve()
  if not (app / "Contents/Resources/prowl-cli/prowl").exists():
    parser.error(f"{app} has no bundled prowl CLI")
  lldb = import_lldb()

  # Unix socket paths are limited to 104 bytes, so the work directory stays short.
  workdir = Path(tempfile.mkdtemp(prefix="prowl-perf-", dir="/tmp")).resolve()
  defaults_domain = run(["defaults", "read", str(app / "Contents/Info.plist"), "CFBundleIdentifier"]).stdout.strip()
  defaults_backup = workdir / "defaults-backup.plist"
  had_defaults = subprocess.run(["defaults", "export", defaults_domain, str(defaults_backup)], capture_output=True).returncode == 0

  instance = ProwlInstance(app, workdir, args.language)
  counter: Counter | None = None
  samples: list[StepSample] = []
  try:
    groups = seed_repositories(workdir / "repos", args.repos, args.worktrees_per_repo)
    instance.launch()
    panes: list[list[str]] = []
    for group in groups:
      group_panes = []
      for path in group:
        opened = instance.cli_json("open", str(path))
        group_panes.append(opened["data"]["target"]["pane"]["id"])
      panes.append(group_panes)

    counter = Counter(lldb, instance.pid, args.count_bodies)
    # Visit every worktree once so each keeps a terminal state, as in a long-running session.
    for group_panes in panes:
      for pane in group_panes:
        instance.cli_json("focus", "--pane", pane)
    settle(counter, args.quiet, args.min_settle, args.max_settle)

    for round_index in range(args.rounds):
      group = panes[round_index % len(panes)]
      other = panes[(round_index + 1) % len(panes)]
      steps = [
        ("switch_same_repo", lambda g=group: instance.cli_json("focus", "--pane", g[1 + round_index % (len(g) - 1)])),
        ("switch_cross_repo", lambda o=other: instance.cli_json("focus", "--pane", o[0])),
        ("deactivate", lambda: run(["open", "-b", "com.apple.finder"])),
        ("activate", lambda: run(["open", "-a", str(app)])),
      ]
      for step, action in steps:
        sample = measure_step(counter, step, action, args)
        samples.append(sample)
        print(f"round {round_index + 1} {step:<18} {sample.counts} {sample.seconds:.2f}s", file=sys.stderr)
  finally:
    if counter is not None:
      counter.detach()
    instance.terminate()
    if had_defaults:
      subprocess.run(["defaults", "delete", defaults_domain], capture_output=True)
      subprocess.run(["defaults", "import", defaults_domain, str(defaults_backup)], capture_output=True)
    else:
      subprocess.run(["defaults", "delete", defaults_domain], capture_output=True)
    if not args.keep_workdir:
      shutil.rmtree(workdir, ignore_errors=True)

  summary = summarize(samples)
  report = {
    "schema": "prowl.interaction-counts/v1",
    "label": args.label,
    "os": platform.mac_ver()[0],
    "arch": platform.machine(),
    "language": args.language,
    "app_commit": subprocess.run(
      ["git", "rev-parse", "--short", "HEAD"], capture_output=True, text=True, cwd=Path(__file__).parent
    ).stdout.strip(),
    "worktrees": args.repos * (args.worktrees_per_repo + 1),
    "summary": summary,
    "samples": [
      {"step": s.step, "counts": s.counts, "seconds_with_lldb": round(s.seconds, 3), "body_top": s.body_top}
      for s in samples
    ],
  }
  print_table(summary)
  if args.output:
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(f"report: {args.output}")
  if args.markdown:
    with args.markdown.open("a") as handle:
      handle.write(markdown_table(report))
  return 0


if __name__ == "__main__":
  sys.exit(main())
