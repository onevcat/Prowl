#!/usr/bin/env python3
"""Reject the legacy project name `supacode` outside the places that must keep it.

The project name is Prowl (docs-ai 074). The old name stays only where stored user data,
machine-local credentials, or the upstream project need it.
"""

from pathlib import Path
import re
import subprocess
import sys


# Each pattern is a legitimate use. A line passes when nothing is left after these are removed.
ALLOWED = (
    r"supabitapp/supacode",  # the upstream repository
    r"\bSupacode\b",  # the upstream product name in prose
    r"supacodeClassic",  # stored raw value of NotificationSound
    r"~?/?\.supacode\b",  # legacy data folder, read for migration
    r"supacode(?:\.onevcat)?\.json",  # legacy settings files, read for migration
    r"supacode-notary",  # keychain profile name on the release machine
    r"""(?:repo|baseRepo): "supacode\"""",  # test data that names the upstream repository
    r'"name":"supacode"',
    r"`supacode(?:/\.\.\.)?`",  # the bare old name in prose that explains this rule
)
# History and third-party content is not maintained text.
EXCLUDED_PREFIXES = ("docs-ai/", "ThirdParty/", ".claude/skills/check-upstream-changes/")
EXCLUDED_FILES = ("CHANGELOG.md", "scripts/check_legacy_naming.py", "scripts/test_legacy_naming.py")
TEXT_SUFFIXES = {
    ".swift", ".md", ".json", ".yaml", ".yml", ".py", ".sh", ".awk", ".toml", ".xcconfig", ".plist",
    ".entitlements", ".xcstrings", ".kt", ".kts", ".txt", ".ts", ".example", ".template", "",
}

_ALLOWED = re.compile("|".join(ALLOWED))
_LEGACY = re.compile(r"supa(?:code|logger)", re.IGNORECASE)


def violations(text: str) -> list[int]:
    """Return the 1-based numbers of the lines that use the legacy name."""
    return [
        number
        for number, line in enumerate(text.splitlines(), 1)
        if _LEGACY.search(_ALLOWED.sub("", line))
    ]


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    names = subprocess.check_output(["git", "ls-files", "--cached", "--others", "--exclude-standard"], cwd=root, text=True)
    errors = []
    for name in sorted(set(names.splitlines())):
        if name.startswith(EXCLUDED_PREFIXES) or name in EXCLUDED_FILES:
            continue
        if _LEGACY.search(_ALLOWED.sub("", name)):
            errors.append(f"{name}: the path uses the legacy project name")
        path = root / name
        if path.is_symlink() or not path.is_file() or path.suffix not in TEXT_SUFFIXES:
            continue
        try:
            text = path.read_text()
        except UnicodeDecodeError:
            continue
        errors.extend(f"{name}:{line}: use the Prowl name (see docs-ai 074)" for line in violations(text))
    for error in errors:
        print(error)
    if not errors:
        print("Legacy naming checks passed.")
    return bool(errors)


if __name__ == "__main__":
    sys.exit(main())
