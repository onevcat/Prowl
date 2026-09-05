#!/usr/bin/env python3
"""Compare the installed tier-A agent CLIs with the managed-hook version attestation.

Prowl's launch-scoped hooks (docs-ai 064, S3 wave 1) are a contract with eight external
binaries, and that contract moves with them. The version each runtime last passed a live
sweep against is recorded in `docs-ai/064-agent-completion-signals/agent-attestation.json`;
this script is the cheap half of #726 (T0). For every attested runtime it locates the binary,
runs its version command with a timeout, parses the semantic version out of whatever banner
the CLI prints, and reports one of:

    attested     the installed build is the one the contract was verified against
    newer        the contract has not been verified against this build (warning)
    older        an older build than the attested one is installed (warning)
    missing      no binary on PATH, nor on the login shell's PATH (warning, not a failure)
    unparseable  the binary ran but printed no recognizable version, failed, or timed out

Binaries are looked up on this process's PATH first. When one is missing there, the user's
shell (`$SHELL -lic`, login and interactive, because Homebrew and `mise activate` usually live in
`.zshrc`) is asked for its PATH once and the lookup is retried on it, so a `mise`-managed tool or
a PATH extended only in shell rc files is still found when the script runs from `make` under an
editor or agent harness. A version command runs with the PATH it was found on, so shims can
resolve their own toolchain. `--no-login-shell` disables the fallback.

The research matrix keeps a generated "Tier-A attestation" line whose versions must equal the
record; `--check-matrix` verifies that (and `make test-scripts` runs it), `--write-matrix`
regenerates the line.

Usage:

    scripts/agent_versions.py [--json] [--strict] [--timeout SECONDS] [--no-login-shell]
    scripts/agent_versions.py --check-matrix
    scripts/agent_versions.py --write-matrix

The exit code is 0 unless `--strict` is given, in which case any status other than
`attested` exits 1. `--check-matrix` exits 1 on drift.
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass
from typing import Callable, Optional, Sequence

ROOT = pathlib.Path(__file__).resolve().parents[1]
ENTRY_DIR = ROOT / "docs-ai" / "064-agent-completion-signals"
ATTESTATION_PATH = ENTRY_DIR / "agent-attestation.json"
MATRIX_PATH = ENTRY_DIR / "research-agent-completion-signals.md"

ATTESTATION_SCHEMA = 1
TIER_A_RUNTIMES = ("claude", "codex", "copilot", "droid", "qodercli", "pi", "omp", "opencode")
ENTRY_KEYS = frozenset(
    {"runtime", "name", "binary", "version_command", "attested_version", "attested_on", "record"}
)
STATUSES = ("attested", "newer", "older", "missing", "unparseable")
DEFAULT_TIMEOUT = 20.0

MATRIX_LINE_PREFIX = "**Tier-A attestation**"
MATRIX_LINE_INTRO = (
    " (generated from [agent-attestation.json](agent-attestation.json) by"
    " `scripts/agent_versions.py --write-matrix`; `make test-scripts` fails when this line drifts): "
)

ANSI_ESCAPE = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]")
# Three dotted integers not preceded by a digit or dot ("v1.2.3", "omp/18.0.6", "codex-cli 0.149.1")
# and not followed by a word character or hyphen ("1.0.80." keeps its sentence period out; a
# fourth component such as "2026.05.09.1" is not a semantic version and does not match at all).
VERSION_PATTERN = re.compile(r"(?<![\d.])(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z][0-9A-Za-z.-]*))?(?![\w-])(?!\.\d)")


class AttestationError(ValueError):
    """The attestation record is malformed."""


@dataclass(frozen=True)
class Version:
    core: tuple
    prerelease: Optional[str]
    text: str

    def sort_key(self):
        # A prerelease sorts below the release it precedes; two prereleases compare as strings.
        return (self.core, self.prerelease is None, self.prerelease or "")


@dataclass(frozen=True)
class AttestedRuntime:
    runtime: str
    name: str
    binary: str
    version_command: tuple
    attested_version: str
    attested_on: str
    record: str

    @classmethod
    def from_json(cls, fields) -> "AttestedRuntime":
        if not isinstance(fields, dict):
            raise AttestationError("each runtime entry must be an object")
        keys = set(fields)
        if keys != ENTRY_KEYS:
            unexpected = sorted(keys - ENTRY_KEYS)
            missing = sorted(ENTRY_KEYS - keys)
            raise AttestationError(f"runtime entry keys: unexpected {unexpected}, missing {missing}")
        command = fields["version_command"]
        if not isinstance(command, list) or not command or not all(isinstance(part, str) for part in command):
            raise AttestationError(f"{fields['runtime']}: version_command must be a non-empty list of strings")
        for key in ("runtime", "name", "binary", "attested_version", "attested_on", "record"):
            if not isinstance(fields[key], str) or not fields[key]:
                raise AttestationError(f"{fields['runtime']}: {key} must be a non-empty string")
        if parse_version(fields["attested_version"]) is None:
            raise AttestationError(f"{fields['runtime']}: attested_version {fields['attested_version']!r} is not a version")
        try:
            datetime.date.fromisoformat(fields["attested_on"])
        except ValueError as error:
            raise AttestationError(f"{fields['runtime']}: attested_on must be an ISO date: {error}") from None
        return cls(
            runtime=fields["runtime"],
            name=fields["name"],
            binary=fields["binary"],
            version_command=tuple(command),
            attested_version=fields["attested_version"],
            attested_on=fields["attested_on"],
            record=fields["record"],
        )


@dataclass(frozen=True)
class ResolvedBinary:
    path: str
    resolution: str  # "path" or "login-shell"
    search_path: str


@dataclass(frozen=True)
class CommandResult:
    stdout: str
    stderr: str
    returncode: Optional[int]
    timed_out: bool


@dataclass
class RuntimeReport:
    entry: AttestedRuntime
    status: str
    detail: str = ""
    path: Optional[str] = None
    resolution: Optional[str] = None
    installed: Optional[Version] = None
    raw_output: str = ""


def load_attestation(path: pathlib.Path) -> list:
    try:
        document = json.loads(path.read_text())
    except (OSError, ValueError) as error:
        raise AttestationError(f"cannot read {path}: {error}") from None
    if not isinstance(document, dict) or document.get("schema") != ATTESTATION_SCHEMA:
        raise AttestationError(f"{path}: expected an object with schema {ATTESTATION_SCHEMA}")
    runtimes = document.get("runtimes")
    if not isinstance(runtimes, list) or not runtimes:
        raise AttestationError(f"{path}: runtimes must be a non-empty list")
    entries = [AttestedRuntime.from_json(fields) for fields in runtimes]
    seen = set()
    for item in entries:
        if item.runtime in seen:
            raise AttestationError(f"{path}: runtime {item.runtime!r} is listed twice")
        seen.add(item.runtime)
        if not (path.parent / item.record).is_file():
            raise AttestationError(f"{path}: {item.runtime}: record {item.record!r} does not exist next to the attestation")
    return entries


def parse_version(text: str) -> Optional[Version]:
    match = VERSION_PATTERN.search(ANSI_ESCAPE.sub("", text))
    if match is None:
        return None
    core = (int(match.group(1)), int(match.group(2)), int(match.group(3)))
    prerelease = match.group(4)
    if prerelease:
        prerelease = prerelease.rstrip(".")
    rendered = ".".join(str(part) for part in core)
    if prerelease:
        rendered += f"-{prerelease}"
    return Version(core=core, prerelease=prerelease or None, text=rendered)


def compare_versions(installed: Version, attested: Version) -> str:
    if installed.sort_key() == attested.sort_key():
        return "attested"
    return "newer" if installed.sort_key() > attested.sort_key() else "older"


def login_shell_path(shell: Optional[str] = None, timeout: float = 10.0) -> Optional[str]:
    """The PATH of a fresh login + interactive shell, or None when it cannot be obtained.

    Interactive matters: on a stock macOS setup Homebrew's `shellenv` and `mise activate` are
    sourced from `.zshrc`, which a login-only shell skips. The PATH is fenced with markers so
    banners printed by the rc files do not leak into it.
    """
    shell = shell or os.environ.get("SHELL") or "/bin/zsh"
    marker = "__PROWL_PATH__"
    try:
        result = subprocess.run(
            [shell, "-lic", f'printf "\\n{marker}%s{marker}\\n" "$PATH"'],
            capture_output=True,
            text=True,
            errors="replace",
            stdin=subprocess.DEVNULL,
            timeout=timeout,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    match = re.search(f"{marker}(.*?){marker}", result.stdout, re.DOTALL)
    if match is None or not match.group(1).strip():
        return None
    return match.group(1).strip()


class BinaryResolver:
    """Looks a binary up on this process's PATH, then on the login shell's PATH (once, lazily)."""

    def __init__(self, use_login_shell: bool = True):
        self.use_login_shell = use_login_shell
        self._login_path: Optional[str] = None
        self._login_path_queried = False

    def _login_shell_path(self) -> Optional[str]:
        if not self._login_path_queried:
            self._login_path_queried = True
            self._login_path = login_shell_path()
        return self._login_path

    def __call__(self, binary: str) -> Optional[ResolvedBinary]:
        current = os.environ.get("PATH", "")
        found = shutil.which(binary, path=current)
        if found:
            return ResolvedBinary(path=found, resolution="path", search_path=current)
        if not self.use_login_shell:
            return None
        login = self._login_shell_path()
        if not login:
            return None
        found = shutil.which(binary, path=login)
        if found:
            return ResolvedBinary(path=found, resolution="login-shell", search_path=login)
        return None


def run_version_command(command: Sequence[str], search_path: str, timeout: float) -> CommandResult:
    env = {**os.environ, "PATH": search_path, "NO_COLOR": "1"}
    try:
        result = subprocess.run(
            list(command),
            capture_output=True,
            text=True,
            errors="replace",
            stdin=subprocess.DEVNULL,
            env=env,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as expired:
        return CommandResult(
            stdout=_decode(expired.stdout),
            stderr=_decode(expired.stderr),
            returncode=None,
            timed_out=True,
        )
    except OSError as error:
        return CommandResult(stdout="", stderr=str(error), returncode=None, timed_out=False)
    return CommandResult(stdout=result.stdout, stderr=result.stderr, returncode=result.returncode, timed_out=False)


def _decode(data) -> str:
    if data is None:
        return ""
    if isinstance(data, bytes):
        return data.decode("utf-8", errors="replace")
    return str(data)


def assess(
    entries: Sequence[AttestedRuntime],
    resolve: Callable[[str], Optional[ResolvedBinary]],
    run: Callable[[Sequence[str], str, float], CommandResult],
    timeout: float,
) -> list:
    reports = []
    for item in entries:
        resolved = resolve(item.binary)
        if resolved is None:
            reports.append(
                RuntimeReport(
                    entry=item,
                    status="missing",
                    detail=f"{item.binary} not found on PATH (nor on the login shell PATH)",
                )
            )
            continue
        command = (resolved.path, *item.version_command[1:])
        result = run(command, resolved.search_path, timeout)
        raw_output = result.stdout if result.stdout.strip() else result.stderr
        report = RuntimeReport(
            entry=item,
            status="unparseable",
            path=resolved.path,
            resolution=resolved.resolution,
            raw_output=result.stdout + result.stderr,
        )
        shown = " ".join(item.version_command)
        if result.timed_out:
            report.detail = f"`{shown}` timed out after {timeout:g}s"
            reports.append(report)
            continue
        installed = parse_version(raw_output)
        if installed is None:
            first_line = next((line for line in (result.stdout + result.stderr).splitlines() if line.strip()), "")
            exit_text = "did not start" if result.returncode is None else f"exited {result.returncode}"
            report.detail = f"`{shown}` {exit_text} without a recognizable version: {first_line.strip()!r}"
            reports.append(report)
            continue
        report.installed = installed
        report.status = compare_versions(installed, parse_version(item.attested_version))
        reports.append(report)
    return reports


def warnings_for(reports: Sequence[RuntimeReport]) -> list:
    warnings = []
    for report in reports:
        item = report.entry
        provenance = f"{item.record}, {item.attested_on}"
        if report.status == "newer":
            warnings.append(
                f"warning: {item.binary} {report.installed.text} is newer than the attested"
                f" {item.attested_version} ({provenance}); the managed-hook contract is unverified"
                f" against it — run `make test-agent-contracts AGENT_CONTRACT_ARGS=\"--mode verify\"` (#726 T1),"
                f" then publish its report as documented in agent-contracts-runbook.md"
            )
        elif report.status == "older":
            warnings.append(
                f"warning: {item.binary} {report.installed.text} is older than the attested"
                f" {item.attested_version} ({provenance}); upgrade, or re-run"
                f" `make test-agent-contracts AGENT_CONTRACT_ARGS=\"--mode verify\"` (#726 T1) against this build"
            )
        elif report.status == "missing":
            warnings.append(f"warning: {report.detail}; its managed-hook contract cannot be checked on this machine")
        elif report.status == "unparseable":
            warnings.append(f"warning: {item.binary}: {report.detail}")
    return warnings


def render_table(reports: Sequence[RuntimeReport]) -> str:
    rows = [("runtime", "attested", "installed", "status")]
    for report in reports:
        installed = report.installed.text if report.installed else "-"
        rows.append((report.entry.binary, report.entry.attested_version, installed, report.status))
    widths = [max(len(row[column]) for row in rows) for column in range(4)]
    lines = []
    for row in rows:
        cells = [cell.ljust(width) for cell, width in zip(row, widths)]
        lines.append("  ".join(cells).rstrip())
    return "\n".join(lines)


def json_document(reports: Sequence[RuntimeReport], attestation_path: pathlib.Path) -> dict:
    runtimes = []
    for report in reports:
        item = report.entry
        runtimes.append(
            {
                "runtime": item.runtime,
                "name": item.name,
                "binary": item.binary,
                "version_command": list(item.version_command),
                "attested_version": item.attested_version,
                "attested_on": item.attested_on,
                "record": item.record,
                "path": report.path,
                "resolution": report.resolution,
                "installed_version": report.installed.text if report.installed else None,
                "raw_output": report.raw_output,
                "status": report.status,
                "detail": report.detail,
            }
        )
    summary = {status: sum(1 for report in reports if report.status == status) for status in STATUSES}
    return {"attestation": str(attestation_path), "runtimes": runtimes, "summary": summary}


def exit_code(reports: Sequence[RuntimeReport], strict: bool) -> int:
    if strict and any(report.status != "attested" for report in reports):
        return 1
    return 0


def render_matrix_line(entries: Sequence[AttestedRuntime]) -> str:
    versions = " · ".join(f"{item.binary} {item.attested_version}" for item in entries)
    sweeps = {}
    for item in entries:
        sweeps.setdefault((item.attested_on, item.record), []).append(item.binary)
    if len(sweeps) == 1:
        (date, record), _ = next(iter(sweeps.items()))
        provenance = f"last live sweep {date} ([{record}]({record}))"
    else:
        parts = [
            f"{date} ([{record}]({record})): {', '.join(binaries)}"
            for (date, record), binaries in sorted(sweeps.items())
        ]
        provenance = "last live sweeps: " + "; ".join(parts)
    return f"{MATRIX_LINE_PREFIX}{MATRIX_LINE_INTRO}{versions} — {provenance}."


def _matrix_versions(line: str) -> dict:
    body = line.split("): ", 1)[1] if "): " in line else line
    body = body.split(" — ", 1)[0]
    versions = {}
    for token in body.split(" · "):
        parts = token.strip().split(" ")
        if len(parts) == 2:
            versions[parts[0]] = parts[1]
    return versions


def check_matrix(entries: Sequence[AttestedRuntime], matrix_text: str) -> list:
    """Problems with the matrix's generated line; empty when it matches the attestation."""
    lines = [line for line in matrix_text.splitlines() if line.startswith(MATRIX_LINE_PREFIX)]
    if not lines:
        return [f"no line starting with {MATRIX_LINE_PREFIX!r} in the research matrix"]
    if len(lines) > 1:
        return [f"{len(lines)} lines start with {MATRIX_LINE_PREFIX!r}; expected exactly one"]
    expected = render_matrix_line(entries)
    actual = lines[0]
    if actual == expected:
        return []
    problems = []
    found = _matrix_versions(actual)
    for item in entries:
        version = found.get(item.binary)
        if version is None:
            problems.append(f"{item.binary}: matrix lists no version, attestation {item.attested_version}")
        elif version != item.attested_version:
            problems.append(f"{item.binary}: matrix {version}, attestation {item.attested_version}")
    for binary in found:
        if binary not in {item.binary for item in entries}:
            problems.append(f"{binary}: listed in the matrix but not in the attestation")
    if not problems:
        problems.append("the generated line's wording or provenance differs from the attestation")
    problems.append(f"expected line:\n{expected}\nactual line:\n{actual}")
    return problems


def write_matrix(entries: Sequence[AttestedRuntime], matrix_path: pathlib.Path) -> bool:
    """Regenerate the matrix line in place; returns whether the file changed."""
    text = matrix_path.read_text()
    expected = render_matrix_line(entries)
    lines = text.split("\n")
    indexes = [index for index, line in enumerate(lines) if line.startswith(MATRIX_LINE_PREFIX)]
    if len(indexes) != 1:
        raise SystemExit(
            f"{matrix_path}: expected exactly one line starting with {MATRIX_LINE_PREFIX!r}, found {len(indexes)}"
        )
    if lines[indexes[0]] == expected:
        return False
    lines[indexes[0]] = expected
    matrix_path.write_text("\n".join(lines))
    return True


def parse_args(argv: Optional[Sequence[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--attestation", type=pathlib.Path, default=ATTESTATION_PATH, help="attestation record to check against")
    parser.add_argument("--matrix", type=pathlib.Path, default=MATRIX_PATH, help="research matrix for --check-matrix / --write-matrix")
    parser.add_argument("--json", action="store_true", help="print the report as JSON instead of a table")
    parser.add_argument("--strict", action="store_true", help="exit 1 unless every runtime is attested")
    parser.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT, help=f"seconds per version command (default {DEFAULT_TIMEOUT:g})")
    parser.add_argument("--no-login-shell", action="store_true", help="do not consult the login shell's PATH for missing binaries")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--check-matrix", action="store_true", help="verify the research matrix's generated line matches the attestation")
    mode.add_argument("--write-matrix", action="store_true", help="regenerate the research matrix's generated line from the attestation")
    return parser.parse_args(argv)


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = parse_args(argv)
    try:
        entries = load_attestation(args.attestation)
    except AttestationError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2

    if args.check_matrix:
        problems = check_matrix(entries, args.matrix.read_text())
        if problems:
            print(f"error: {args.matrix.relative_to(ROOT) if args.matrix.is_relative_to(ROOT) else args.matrix} drifts from {args.attestation.name}:", file=sys.stderr)
            for problem in problems:
                print(f"  {problem}", file=sys.stderr)
            print("  run `scripts/agent_versions.py --write-matrix` to regenerate the line", file=sys.stderr)
            return 1
        print(f"{args.matrix.name} matches {args.attestation.name}")
        return 0

    if args.write_matrix:
        changed = write_matrix(entries, args.matrix)
        print(f"{args.matrix.name}: {'updated' if changed else 'already current'}")
        return 0

    resolver = BinaryResolver(use_login_shell=not args.no_login_shell)
    reports = assess(entries, resolve=resolver, run=run_version_command, timeout=args.timeout)
    if args.json:
        print(json.dumps(json_document(reports, args.attestation), indent=2))
    else:
        print(render_table(reports))
    # Keep the report ahead of the warnings when stdout is a pipe.
    sys.stdout.flush()
    for warning in warnings_for(reports):
        print(warning, file=sys.stderr)
    return exit_code(reports, strict=args.strict)


if __name__ == "__main__":
    sys.exit(main())
