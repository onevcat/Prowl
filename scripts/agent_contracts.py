#!/usr/bin/env python3
"""Inventory runtime contracts; opt in to config preflight or real headless hook checks.

Inventory is the default and requests no inference. Live mode uses the configured models.
Neither mode establishes interactive or release-wide readiness. See the contract runbook.
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
import pathlib
import re
import signal
import stat
import subprocess
import sys
import tempfile
import time
import urllib.parse
import uuid

import agent_versions as versions

ROOT = pathlib.Path(__file__).resolve().parents[1]
MAX_POLICY_BYTES = 64 * 1024
MAX_CAPTURE_BYTES = 1024 * 1024
CODEX_SCENARIOS = ("base", "absent", "profile", "override", "cleanup")
ROUTE_KEYS = {"provider", "model", "base_url", "wire_api", "api_key_env"}
SAFE_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:/+\[\]-]{0,199}\Z")
ENV_NAME = re.compile(r"[A-Z][A-Z0-9_]{0,99}\Z")


class PolicyError(ValueError):
    """Invalid local configuration; messages must not include its values."""


class EvidenceError(ValueError):
    """A successful process did not supply sufficient preflight evidence."""


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise PolicyError("Duplicate configuration field.")
        result[key] = value
    return result


def load_policy(path, required=True):
    try:
        with path.open("rb") as source:
            data = source.read(MAX_POLICY_BYTES + 1)
    except FileNotFoundError:
        if not required:
            return {}
        raise PolicyError("The explicitly selected configuration is missing.") from None
    except OSError:
        raise PolicyError("Cannot read the selected configuration.") from None
    if len(data) > MAX_POLICY_BYTES:
        raise PolicyError("Configuration exceeds 64 KiB.")
    try:
        document = json.loads(data, object_pairs_hook=unique_object)
    except (ValueError, UnicodeError):
        raise PolicyError("Configuration must be JSON with unique fields.") from None
    if not isinstance(document, dict) or set(document) != {"schema", "runtimes"}:
        raise PolicyError("Configuration requires exactly schema and runtimes.")
    if type(document["schema"]) is not int or document["schema"] != 1:
        raise PolicyError("Unsupported configuration schema; expected 1.")
    runtimes = document["runtimes"]
    if not isinstance(runtimes, dict) or set(runtimes) - set(versions.TIER_A_RUNTIMES):
        raise PolicyError("Configuration contains an unsupported runtime.")
    for runtime, route in runtimes.items():
        if not isinstance(route, dict) or set(route) != ROUTE_KEYS:
            raise PolicyError("Each route requires provider, model, base_url, wire_api, and api_key_env only.")
        for field in ("provider", "model"):
            value = route[field]
            if not isinstance(value, str) or not SAFE_NAME.fullmatch(value) or value in {"auto", "openrouter/free"}:
                raise PolicyError("Provider and model must be explicit identifiers, not automatic routing.")
        if route["wire_api"] == "runtime-managed":
            if runtime != "qodercli" or route["provider"] != "qoder" or route["base_url"] is not None or route["api_key_env"] is not None:
                raise PolicyError("Runtime-managed routes require Qoder with no URL or key reference.")
            continue
        if route["wire_api"] not in ("responses", "chat-completions", "anthropic-messages"):
            raise PolicyError("Unsupported wire_api.")
        key = route["api_key_env"]
        if key is not None and (not isinstance(key, str) or not ENV_NAME.fullmatch(key)):
            raise PolicyError("api_key_env must name an environment variable, or be null for a keyless route.")
        address = route["base_url"]
        if not isinstance(address, str) or len(address) > 512 or any(char.isspace() for char in address):
            raise PolicyError("Invalid provider base_url.")
        try:
            parsed = urllib.parse.urlsplit(address)
            allowed = parsed.scheme == "https" or (
                parsed.scheme == "http" and parsed.hostname in {"127.0.0.1", "localhost", "::1"}
            )
            _ = parsed.port
            if not allowed or not parsed.hostname or parsed.username or parsed.password or parsed.query or parsed.fragment:
                raise ValueError()
        except ValueError:
            raise PolicyError("base_url requires HTTPS (or loopback HTTP), without credentials, query, or fragment.") from None
    return runtimes


def load_credentials(path, environment, required=True):
    """Read a private, literal KEY=value file; never source shell configuration."""
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        if not required:
            return dict(environment)
        raise PolicyError("The selected credentials file is missing.") from None
    except OSError:
        raise PolicyError("Cannot safely open the credentials file.") from None
    with os.fdopen(descriptor, "rb") as source:
        info = os.fstat(source.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise PolicyError("Credentials require an owner-only regular file.")
        raw = source.read(MAX_POLICY_BYTES + 1)
    if len(raw) > MAX_POLICY_BYTES:
        raise PolicyError("Credentials file exceeds 64 KiB.")
    try:
        lines = raw.decode("utf-8").splitlines()
    except UnicodeError:
        raise PolicyError("Credentials file must be UTF-8.") from None
    values = {}
    for line in lines:
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        name, separator, value = line.partition("=")
        name, value = name.strip(), value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
            value = value[1:-1]
        if (not separator or not ENV_NAME.fullmatch(name) or name in values
                or not re.fullmatch(r"[A-Za-z0-9_./:+=@%-]+", value)):
            raise PolicyError("Credentials require unique names and literal, nonempty token values.")
        values[name] = value
    return {**values, **environment}


def route_status(route, environment):
    if route is None:
        return {"status": "not_configured", "credential_present": None}
    key = route["api_key_env"]
    present = bool(environment.get(key)) if key else None
    return {**route, "status": "credential_missing" if present is False else "configured", "credential_present": present}


def probe_environment(environment, search_path):
    # Preserve the real home for toolchain discovery, not arbitrary agent configuration,
    # credentials, workflow tokens, or TEST_RUNNER_ overrides from the hosting session.
    names = ("HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "LC_ALL", "DEVELOPER_DIR", "SDKROOT")
    clean = {name: environment[name] for name in names if name in environment}
    clean.update(PATH=search_path, NO_COLOR="1")
    return clean


def stop_group(process):
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait()


def run_process(command, search_path, timeout, environment=None):
    env = environment if environment is not None else probe_environment(os.environ, search_path)
    with tempfile.TemporaryFile() as stdout, tempfile.TemporaryFile() as stderr:
        try:
            process = subprocess.Popen(
                list(command), stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr,
                env=env, cwd=ROOT, start_new_session=True,
            )
        except OSError:
            return versions.CommandResult("", "", None, False)
        timed_out = False
        try:
            process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            stop_group(process)
        except BaseException:
            stop_group(process)
            raise
        stdout.seek(0)
        stderr.seek(0)
        return versions.CommandResult(
            stdout.read(MAX_CAPTURE_BYTES).decode("utf-8", errors="replace"),
            stderr.read(MAX_CAPTURE_BYTES).decode("utf-8", errors="replace"),
            None if timed_out else process.returncode, timed_out,
        )


def inventory(entries, policy, environment, resolve=None, run=run_process, timeout=20):
    resolve = resolve or versions.BinaryResolver()
    rows = []
    for entry in entries:
        binary = resolve(entry.binary)
        row = {
            "runtime": entry.runtime, "executable": binary.path if binary else None,
            "resolution": binary.resolution if binary else None,
            "installed_version": None, "attested_version": entry.attested_version,
            "version_status": "unknown", "route": route_status(policy.get(entry.runtime), environment),
            "preflight": {"status": "not_run"}, "live": {"status": "not_run", "reason": "not_requested"},
        }
        if binary is None:
            row["inventory"] = {"status": "blocked", "reason": "binary_missing"}
        else:
            result = run((binary.path, *entry.version_command[1:]), binary.search_path, timeout)
            version = versions.parse_version(result.stdout if result.stdout.strip() else result.stderr)
            if result.timed_out:
                row["inventory"] = {"status": "timed_out", "reason": "version_timeout"}
            elif result.returncode != 0:
                row["inventory"] = {"status": "blocked", "reason": "version_command_failed"}
            elif version is None:
                row["inventory"] = {"status": "blocked", "reason": "version_unparseable"}
            else:
                row["installed_version"] = version.text
                row["version_status"] = versions.compare_versions(version, versions.parse_version(entry.attested_version))
                row["inventory"] = {"status": "passed", "reason": "version_read"}
        rows.append(row)
    return rows


def validate_preflight(receipt, summary, nonce, executable):
    expected = {
        "schema": 1, "mode": "preflight", "runtime": "codex", "nonce": nonce,
        "executable": executable, "scenarios": list(CODEX_SCENARIOS),
    }
    if receipt != expected:
        raise EvidenceError("Missing, incomplete, or mismatched Codex receipt.")
    if not isinstance(summary, dict) or summary.get("result") != "Passed":
        raise EvidenceError("Xcode did not report a passed test result.")
    for field, expected_count in (("totalTestCount", 1), ("passedTests", 1), ("failedTests", 0), ("skippedTests", 0)):
        if type(summary.get(field)) is not int or summary[field] != expected_count:
            raise EvidenceError("Expected exactly one passed, executed test with zero failures or skips.")


def write_json(path, value):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w") as output:
        json.dump(value, output, indent=2, sort_keys=True)
        output.write("\n")


def run_preflight(row, directory, resolve, timeout):
    if row["runtime"] != "codex":
        return {"status": "not_run", "reason": "preflight_not_implemented_for_runtime"}
    if row["inventory"]["status"] != "passed":
        return {"status": "blocked", "reason": "binary_inventory_failed"}
    binary = resolve("codex")
    if binary is None or binary.path != row["executable"]:
        return {"status": "blocked", "reason": "binary_changed_since_inventory"}
    nonce = str(uuid.uuid4())
    env = probe_environment(os.environ, binary.search_path)
    env.update(
        PROWL_CONTRACT_CODEX_EXECUTABLE=binary.path,
        PROWL_CONTRACT_RECEIPT=str(directory / "codex-preflight.json"),
        PROWL_CONTRACT_NONCE=nonce,
        PROWL_CONTRACT_RESULT=str(directory / "codex-preflight.xcresult"),
    )
    if os.environ.get("PROWL_DEVELOPMENT_TEAM"):
        env["PROWL_DEVELOPMENT_TEAM"] = os.environ["PROWL_DEVELOPMENT_TEAM"]
    started = time.monotonic()
    result = run_process(["/usr/bin/make", "_test-agent-contract-codex"], binary.search_path, timeout, env)
    # Build output has already passed through xcsift; keep it separate from the machine report.
    log = directory / "codex-preflight-build.txt"
    with log.open("x") as output:
        output.write(result.stdout + result.stderr)
    log.chmod(0o600)
    evidence = {"elapsed_seconds": round(time.monotonic() - started, 3), "build_log": str(log)}
    if result.timed_out:
        return {**evidence, "status": "timed_out", "reason": "preflight_timeout"}
    if result.returncode != 0:
        return {**evidence, "status": "contract_failed", "reason": "preflight_build_or_test_failed"}
    summary = run_process(
        ["/usr/bin/xcrun", "xcresulttool", "get", "test-results", "summary", "--path", env["PROWL_CONTRACT_RESULT"], "--compact"],
        binary.search_path, 20,
    )
    try:
        if summary.returncode != 0:
            raise EvidenceError("Cannot read Xcode summary.")
        receipt = json.loads(pathlib.Path(env["PROWL_CONTRACT_RECEIPT"]).read_text())
        test_summary = json.loads(summary.stdout)
        validate_preflight(receipt, test_summary, nonce, binary.path)
    except (OSError, ValueError):
        return {**evidence, "status": "contract_failed", "reason": "preflight_evidence_invalid"}
    write_json(directory / "codex-test-summary.json", test_summary)
    return {
        **evidence, "status": "passed", "reason": "configuration_contract_verified",
        "executed_tests": 1, "scenarios": list(CODEX_SCENARIOS),
        "receipt": env["PROWL_CONTRACT_RECEIPT"], "xcresult": env["PROWL_CONTRACT_RESULT"],
    }


def source_fingerprint():
    paths = [ROOT / "Makefile", pathlib.Path(__file__), ROOT / "supacodeTests/CodexConfigReadLiveContractTests.swift",
             ROOT / "scripts/agent_contract_live.py", ROOT / "supacodeTests/AgentHookContractExportTests.swift"]
    paths += sorted((ROOT / "supacode/Domain/AgentRuntime").glob("*.swift"))
    paths += sorted((ROOT / "supacode/Domain/AgentProfile").glob("*.swift"))
    paths += sorted((ROOT / "supacode/CLIService/Shared").glob("*.swift"))
    paths += sorted((ROOT / "ProwlCLI").rglob("*.swift"))
    paths += sorted((ROOT / "Resources/agent-hooks").rglob("*"))
    digest = hashlib.sha256()
    for path in paths:
        if path.is_file():
            digest.update(str(path.relative_to(ROOT)).encode())
            digest.update(b"\0")
            digest.update(path.read_bytes())
    return digest.hexdigest()


def positive_timeout(value):
    try:
        number = float(value)
        if not 0 < number <= 1800:
            raise ValueError()
        return number
    except ValueError:
        raise argparse.ArgumentTypeError("Timeout must be greater than zero and at most 1800 seconds.") from None


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=("inventory", "preflight", "live"), default="inventory")
    parser.add_argument("--runtime", action="append", choices=versions.TIER_A_RUNTIMES, help="Repeat to select runtimes; default: all eight.")
    parser.add_argument("--config", type=pathlib.Path, help="Secret-free JSON policy; default: ~/.prowl/agent-contracts.json if present.")
    parser.add_argument("--credentials", type=pathlib.Path, help="Private literal env file; default: ~/.prowl/agent-contracts.env if present.")
    parser.add_argument("--output-dir", type=pathlib.Path, default=ROOT / "build/agent-contracts", help="Parent for unique private report directories.")
    parser.add_argument("--json", action="store_true", help="Print the report as JSON.")
    parser.add_argument("--strict", action="store_true", help="Fail inventory when binaries or credential references are not ready; version drift alone is not failure.")
    parser.add_argument("--no-login-shell", action="store_true")
    parser.add_argument("--timeout", type=positive_timeout, default=20, help="Per-version-command deadline in seconds.")
    parser.add_argument("--live-timeout", type=positive_timeout, default=90, help="Per-runtime inference deadline; no harness retries.")
    parser.add_argument("--preflight-timeout", type=positive_timeout, default=600, help="Build/test deadline in seconds, including a cold build.")
    args = parser.parse_args(argv)
    try:
        config = args.config or pathlib.Path.home() / ".prowl/agent-contracts.json"
        policy = load_policy(config, required=args.config is not None)
        credential_path = args.credentials or pathlib.Path.home() / ".prowl/agent-contracts.env"
        environment = load_credentials(credential_path, os.environ, required=args.credentials is not None)
        entries = versions.load_attestation(versions.ATTESTATION_PATH)
        if args.runtime:
            entries = [entry for entry in entries if entry.runtime in args.runtime]
        resolver = versions.BinaryResolver(use_login_shell=not args.no_login_shell)
        rows = inventory(entries, policy, environment, resolve=resolver, timeout=args.timeout)
        args.output_dir.mkdir(parents=True, exist_ok=True)
        directory = pathlib.Path(tempfile.mkdtemp(prefix="run-", dir=args.output_dir)).resolve()
        if args.mode == "preflight":
            for row in rows:
                row["preflight"] = run_preflight(row, directory, resolver, args.preflight_timeout)
        if args.mode == "live":
            from agent_contract_live import run_suite
            run_suite(rows, directory, resolver, environment, args.live_timeout, args.preflight_timeout)
        report = {
            "schema": 1, "mode": args.mode,
            "created_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "config_path": str(config), "report_path": str(directory / "report.json"),
            "source_fingerprint": source_fingerprint(), "release_ready": False,
            "bridge_sha256": hashlib.sha256((ROOT / "Resources/prowl-cli/prowl").read_bytes()).hexdigest() if args.mode == "live" and (ROOT / "Resources/prowl-cli/prowl").exists() else None,
            "inference_requested": args.mode == "live", "attestation_updated": False, "runtimes": rows,
        }
        write_json(directory / "report.json", report)
    except (PolicyError, versions.AttestationError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    except OSError:
        print("error: cannot create or write the contract report.", file=sys.stderr)
        return 2
    if args.json:
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        print("Runtime     Version       Drift       Inventory   Route                Preflight  Live")
        for row in rows:
            print(f"{row['runtime']:<11} {row['installed_version'] or '-':<13} {row['version_status']:<11} "
                  f"{row['inventory']['status']:<11} {row['route']['status']:<20} {row['preflight']['status']:<10} {row['live']['status']}")
        print(f"Report: {report['report_path']}")
        print("Headless live evidence only; release readiness not established." if args.mode == "live" else "No inference requested; release readiness not established.")
    if args.mode == "live":
        return int(any(row["live"]["status"] != "passed" for row in rows))
    if args.mode == "preflight":
        return int(any(row["preflight"]["status"] != "passed" for row in rows))
    return int(args.strict and any(row["inventory"]["status"] != "passed" or row["route"]["status"] != "configured" for row in rows))


if __name__ == "__main__":
    raise SystemExit(main())
