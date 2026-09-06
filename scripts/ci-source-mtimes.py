#!/usr/bin/env python3
"""Preserve SwiftPM input times only when cached content still matches checkout."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

INPUTS = [
    "Package.swift", "Package.resolved", "ProwlCLI", "ProwlCLITests",
    "ProwlCLIContracts", "supacode/CLIService/Shared",
]


def regular_input(root, name):
    path = Path(name)
    if path.is_absolute() or ".." in path.parts:
        return None
    current = root
    for part in path.parts:
        current = current / part
        if current.is_symlink():
            return None
    return current if current.is_file() else None


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def save(root, names, manifest):
    files = {}
    for name in names:
        path = regular_input(root, name)
        if path is not None:
            files[name] = {"sha256": digest(path), "mtime_ns": path.stat().st_mtime_ns}
    manifest.parent.mkdir(parents=True, exist_ok=True)
    manifest.write_text(json.dumps({"version": 1, "root": str(root), "files": files}))


def restore(root, names, manifest):
    try:
        data = json.loads(manifest.read_text())
    except (OSError, ValueError):
        return 0
    if not isinstance(data, dict) or data.get("version") != 1 or data.get("root") != str(root):
        return 0
    files = data.get("files")
    if not isinstance(files, dict):
        return 0
    restored = 0
    for name in names:
        entry = files.get(name)
        path = regular_input(root, name)
        if path is None or not isinstance(entry, dict):
            continue
        timestamp = entry.get("mtime_ns")
        if type(timestamp) is not int or not 0 <= timestamp < 2**63:
            continue
        if entry.get("sha256") != digest(path):
            continue
        os.utime(path, ns=(path.stat().st_atime_ns, timestamp))
        restored += 1
    return restored


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["save", "restore"])
    args = parser.parse_args()
    root = Path.cwd().resolve()
    names = subprocess.check_output(
        ["git", "ls-files", "-z", "--", *INPUTS], text=True
    ).split("\0")
    names = [name for name in names if name]
    manifest = root / ".build/prowl-ci-source-mtimes.json"
    if args.action == "save":
        save(root, names, manifest)
        print("Saved CLI source content and modification times.")
    else:
        count = restore(root, names, manifest)
        print(f"Restored modification times for {count} unchanged CLI inputs.")


if __name__ == "__main__":
    main()
