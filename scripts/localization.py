#!/usr/bin/env python3
"""Maintain the app string catalog. Nothing here blocks everyday work; the release sync is strict.

  check    Everyday check (`make check`, CI). Fails only when the catalog is broken: a
           translation whose placeholders do not match the source string. A missing
           translation is not a failure, because translations are synced at release time.
  audit    Release check. Reports everything the `sync-l10n` skill must resolve:
             broken        translations whose placeholders do not match the source
             missing       strings the code uses but the catalog does not have
             unused        catalog entries that no code uses
             untranslated  entries without a finished translation
             suspects      string literals that look like UI copy, are not localized, and
                           have not been triaged into the baseline
             obsolete      baseline entries that are done: the literal left the code, or
                           every place of it is localized now
           It also prints the size of the known debt. Needs a Debug build. The exit
           status is 1 while any list is not empty; that is a finding, not a failure.
  apply    Add or update translations from a JSON file, validated and in Xcode's format.
  prune    Remove unused catalog entries and obsolete baseline entries.
  triage   Record decisions about suspects in the baseline (exempt or debt).
  debt     List the debt by file, optionally only in files changed since a git ref;
           --blocked lists the copy that must stay in English for now, with the reason.
  format   Rewrite the catalog in the format Xcode writes.

The coverage data comes from the `.stringsdata` files that the Swift compiler writes during a
build. They list every localizable string the compiler found, so `missing` and `unused` are
exact. An entry for a key that is built at run time must have the extraction state "manual".

`suspects` is a heuristic, because a plain `String` that reaches the UI looks the same as a
log line. The baseline (`scripts/localization_baseline.json`) holds the human decisions:
rules and literals that are exempt, and `debt`, the UI copy that is known but not localized
yet. See docs-ai/070-app-localization/.
"""

from dataclasses import dataclass, field
from fnmatch import fnmatch
from pathlib import Path
import argparse
import json
import os
import re
import subprocess
import sys


ROOT = Path(__file__).resolve().parent.parent
CATALOG = ROOT / "supacode" / "Localizable.xcstrings"
BASELINE = ROOT / "scripts" / "localization_baseline.json"
SOURCES = "supacode"
TARGET = "supacode"
TABLE = "Localizable"
EXEMPT_CATEGORIES = ("identifier", "product-name", "log", "agent-prompt", "protocol", "developer", "other")

PLACEHOLDER = re.compile(r"%(?:(\d+)\$)?[-+ #0]*\d*(?:\.\d+)?(hh|h|ll|l|q|z|t|j)?([@dDiuUxXoOfFeEgGaAcCsS])")
WORD = re.compile(r"[A-Za-z]{2,}")
SENTENCE_START = re.compile(r"[A-Z“\"'(%]")
CONTINUATION = "\x00"
SINGLE_WORD = re.compile(r"[A-Z][a-z]{2,}(?:…|\.\.\.)?")


# MARK: - Catalog


def serialize(catalog: dict) -> str:
    """The exact format that Xcode and `xcstringstool` write, so both can edit the file."""
    return json.dumps(catalog, ensure_ascii=False, indent=2, separators=(",", " : "), sort_keys=True)


def placeholders(text: str) -> list[str] | None:
    """Return the placeholder types in argument order, or None when positions are mixed."""
    found = PLACEHOLDER.findall(text.replace("%%", ""))
    types = [(length or "") + conversion for _, length, conversion in found]
    positions = [int(position) for position, _, _ in found if position]
    if not positions:
        return types
    if len(positions) != len(found):
        return None
    ordered: dict[int, str] = {}
    for position, kind in zip(positions, types):
        ordered[position] = kind
    return [ordered[position] for position in sorted(ordered)]


def string_units(localization: dict) -> list[dict]:
    units = []
    if "stringUnit" in localization:
        units.append(localization["stringUnit"])
    for variation in localization.get("variations", {}).values():
        for case in variation.values():
            units.extend(string_units(case))
    return units


def describe(types: list[str] | None) -> str:
    return "mixed positions" if types is None else "[" + ", ".join(types) + "]"


def target_languages(catalog: dict) -> list[str]:
    """Every language the catalog uses, so a new language is enforced from its first entry."""
    languages = {language for entry in catalog["strings"].values() for language in entry.get("localizations", {})}
    return sorted(languages - {catalog.get("sourceLanguage", "en")})


def placeholder_issue(key: str, language: str, value: str) -> str | None:
    expected, actual = placeholders(key), placeholders(value)
    if actual == expected:
        return None
    return f'"{key}": {language} placeholders {describe(actual)} do not match source {describe(expected)}'


def structure_issues(catalog: dict) -> list[str]:
    issues = []
    for key, entry in catalog["strings"].items():
        if entry.get("shouldTranslate") is False:
            continue
        for language in target_languages(catalog):
            for unit in string_units(entry.get("localizations", {}).get(language, {})):
                issue = placeholder_issue(key, language, unit.get("value", ""))
                if issue:
                    issues.append(issue)
    return issues


def translation_issues(catalog: dict) -> list[str]:
    issues = []
    for key, entry in catalog["strings"].items():
        if entry.get("shouldTranslate") is False:
            continue
        for language in target_languages(catalog):
            units = string_units(entry.get("localizations", {}).get(language, {}))
            if not units:
                issues.append(f'"{key}": no {language} translation')
            for unit in units:
                if unit.get("state") != "translated":
                    issues.append(f'"{key}": {language} state is {unit.get("state")}')
    return issues


def apply_translations(catalog: dict, translations: dict) -> list[str]:
    """Merge `{key: {language: value} | None}` into the catalog. None means "do not translate".

    `"manual": true` next to the languages marks a key that is built at run time, so the
    coverage check does not report it as unused.
    """
    errors = []
    for key, values in translations.items():
        if values is None:
            catalog["strings"][key] = {"shouldTranslate": False}
            continue
        values = dict(values)
        manual = values.pop("manual", False)
        problems = [placeholder_issue(key, language, value) for language, value in values.items()]
        problems = [problem for problem in problems if problem]
        if problems:
            errors.extend(problems)
            continue
        entry = catalog["strings"].setdefault(key, {})
        entry.pop("shouldTranslate", None)
        if entry.get("extractionState") == "stale":
            del entry["extractionState"]
        if manual:
            entry["extractionState"] = "manual"
        for language, value in values.items():
            entry.setdefault("localizations", {})[language] = {"stringUnit": {"state": "translated", "value": value}}
    return errors


def apply_summary(catalog: dict, translations: dict) -> str:
    """Describe what `apply_translations` is about to do. Call it before the merge."""
    added = sum(1 for key in translations if key not in catalog["strings"])
    manual = sum(1 for values in translations.values() if values and values.get("manual"))
    untranslatable = sum(1 for values in translations.values() if values is None)
    updated = len(translations) - added
    return f"Added {added}, updated {updated} ({manual} manual, {untranslatable} not translatable)."


# MARK: - Coverage


@dataclass
class ExtractionIssues:
    missing: dict[str, list[str]] = field(default_factory=dict)
    unused: list[str] = field(default_factory=list)


def extracted_keys(directory: Path, root: Path = ROOT) -> dict[str, set[str]]:
    """Map each key the compiler extracted to the places (`path:line`) that use it."""
    keys: dict[str, set[str]] = {}
    root = root.resolve()
    for path in sorted(Path(directory).rglob("*.stringsdata")):
        data = json.loads(path.read_text())
        source = Path(data.get("source", ""))
        # Incremental builds can leave the output of a deleted file behind.
        if not source.is_file():
            continue
        source = source.resolve()
        name = source.relative_to(root).as_posix() if source.is_relative_to(root) else source.name
        for item in data.get("tables", {}).get(TABLE, []):
            if item["key"]:
                line = item.get("location", {}).get("startingLine", 0)
                keys.setdefault(item["key"], set()).add(f"{name}:{line}")
    return keys


def place_path(place: str) -> str:
    return place.rsplit(":", 1)[0]


def extraction_issues(catalog: dict, extracted: dict[str, set[str]]) -> ExtractionIssues:
    strings = catalog["strings"]
    issues = ExtractionIssues()
    for key in sorted(extracted):
        if key not in strings:
            issues.missing[key] = sorted(extracted[key])
    for key, entry in strings.items():
        if key not in extracted and entry.get("extractionState") != "manual":
            issues.unused.append(key)
    return issues


def prune(catalog: dict, extracted: dict[str, set[str]]) -> list[str]:
    removed = extraction_issues(catalog, extracted).unused
    for key in removed:
        del catalog["strings"][key]
    return removed


def build_settings_command(environment: dict[str, str]) -> list[str]:
    command = ["xcodebuild", "-project", str(ROOT / "supacode.xcodeproj"), "-scheme", TARGET]
    command += ["-configuration", "Debug", "-showBuildSettings", "-json"]
    # `make test-app` builds into this directory when the variable is set (CI does that).
    derived_data = environment.get("PROWL_DERIVED_DATA_PATH")
    if derived_data:
        command += ["-derivedDataPath", derived_data]
    return command


def build_objects_directory() -> Path:
    """Ask Xcode where the Debug build of the app target writes its per-file output."""
    command = build_settings_command(dict(os.environ))
    output = subprocess.run(command, check=True, capture_output=True, text=True).stdout
    for target in json.loads(output):
        if target["target"] == TARGET:
            return Path(target["buildSettings"]["OBJECT_FILE_DIR_normal"])
    raise SystemExit(f"error: no build settings for target {TARGET}")


# MARK: - Literals that look like UI copy


def is_view_file(path: str) -> bool:
    return "/Views/" in path or path.endswith("View.swift")


def skip_interpolation(text: str, index: int) -> int:
    """Return the index after the `)` that closes an interpolation. `index` is after its `(`."""
    depth = 1
    while index < len(text) and depth:
        character = text[index]
        if character == '"':
            index = read_literal(text, index)[1]
            continue
        depth += {"(": 1, ")": -1}.get(character, 0)
        index += 1
    return index


def read_literal(text: str, start: int) -> tuple[str, int]:
    """Read the string literal that opens at `start`. Return its value and the index after it.

    An interpolation becomes `%@`, as it does in a catalog key. A multi-line literal is joined
    the way the compiler joins it, without the indentation of its closing delimiter.
    """
    multiline = text.startswith('"""', start)
    index = start + (3 if multiline else 1)
    parts = []
    while index < len(text):
        if multiline and text.startswith('"""', index):
            index += 3
            break
        character = text[index]
        if not multiline and character in '"\n':
            index += 1
            break
        if character == "\\" and index + 1 < len(text):
            following = text[index + 1]
            if following == "(":
                parts.append("%@")
                index = skip_interpolation(text, index + 2)
                continue
            if following == "\n":  # line continuation: joined after the indentation is removed
                parts.append(CONTINUATION + "\n")
                index += 2
                continue
            parts.append({"n": "\n", "t": "\t"}.get(following, following))
            index += 2
            continue
        parts.append(character)
        index += 1
    value = "".join(parts)
    if multiline:
        lines = value.split("\n")[1:]
        indent = len(lines[-1]) if lines and not lines[-1].strip() else 0
        value = "\n".join(line[indent:] for line in lines[:-1]).replace(CONTINUATION + "\n", "")
    return value, index


def string_literals(text: str) -> list[tuple[int, str]]:
    """Every string literal outside comments, with the line where it starts."""
    literals = []
    index = 0
    while index < len(text):
        if text.startswith("//", index):
            index = text.find("\n", index) if "\n" in text[index:] else len(text)
        elif text.startswith("/*", index):
            end = text.find("*/", index)
            index = len(text) if end < 0 else end + 2
        elif text[index] == '"':
            value, end = read_literal(text, index)
            literals.append((text.count("\n", 0, index) + 1, value))
            index = end
        else:
            index += 1
    return literals


def candidate_literals(path: str, text: str) -> list[tuple[int, str]]:
    """Literals that read like UI copy: a sentence anywhere, or one capitalized word in a view file."""
    candidates = []
    for number, literal in string_literals(text):
        words = WORD.findall(literal.replace("%@", ""))
        # A sentence has a space between words; a file name or an identifier does not.
        sentence = len(words) >= 2 and SENTENCE_START.match(literal) and re.search(r"[A-Za-z@] +[A-Za-z%“\"'(]", literal)
        word = is_view_file(path) and SINGLE_WORD.fullmatch(literal)
        # "Automatic (%@)": one capitalized word that frames a value.
        labelled_value = "%@" in literal and SINGLE_WORD.fullmatch(re.sub(r"%@|[\s():·—–-]", "", literal))
        if sentence or word or labelled_value:
            candidates.append((number, literal))
    return candidates


def loosen(key: str) -> str:
    """Compare a scanned literal with a catalog key: the scan cannot know the placeholder types."""
    return PLACEHOLDER.sub("%@", key)


class Baseline:
    def __init__(self, data: dict):
        self.data = data
        self.exempt_paths: dict[str, str] = data.setdefault("exemptPaths", {})
        self.exempt_line_patterns: dict[str, str] = data.setdefault("exemptLinePatterns", {})
        self.runtime_key_paths: dict[str, str] = data.setdefault("runtimeKeyPaths", {})
        self.exempt_literals: dict[str, str] = data.setdefault("exemptLiterals", {})
        # UI copy whose value also goes to a CLI response, a log, a file, or another machine.
        # Not debt: it needs a design change (separate UI copy) before it can be localized.
        self.blocked: dict[str, str] = data.setdefault("blocked", {})
        self.debt: list[str] = data.setdefault("debt", [])
        self._line_patterns = [re.compile(pattern) for pattern in self.exempt_line_patterns]

    def exempts_path(self, path: str) -> bool:
        return any(fnmatch(path, glob) for glob in self.exempt_paths)

    def looks_up_at_run_time(self, path: str) -> bool:
        """A file whose titles reach the catalog through a run-time lookup, not through a literal."""
        return any(fnmatch(path, glob) for glob in self.runtime_key_paths)

    def exempts_line(self, line: str) -> bool:
        return any(pattern.search(line) for pattern in self._line_patterns)

    def knows(self, literal: str) -> bool:
        return literal in self.exempt_literals or literal in self.blocked or literal in self.debt

    def obsolete(self, still_open: set[str]) -> list[str]:
        """Entries with no open place: the literal left the code, or every place is localized now.

        They must go, so the baseline only shrinks.
        """
        known = [*self.exempt_literals, *self.blocked, *self.debt]
        return [literal for literal in known if literal not in still_open]

    def remove(self, literals: list[str]) -> None:
        for literal in literals:
            self.exempt_literals.pop(literal, None)
            self.blocked.pop(literal, None)
        self.debt[:] = [literal for literal in self.debt if literal not in literals]

    def serialize(self) -> str:
        self.data["exemptLiterals"] = dict(sorted(self.exempt_literals.items()))
        self.data["blocked"] = dict(sorted(self.blocked.items()))
        self.data["debt"] = sorted(set(self.debt))
        return json.dumps(self.data, ensure_ascii=False, indent=2) + "\n"


def scan_sources(root: Path, baseline: Baseline) -> dict[str, list[str]]:
    """Map each candidate literal to where it occurs, after the baseline's path and line rules."""
    found: dict[str, list[str]] = {}
    for file in sorted((root / SOURCES).rglob("*.swift")):
        path = file.relative_to(root).as_posix()
        if baseline.exempts_path(path):
            continue
        lines = file.read_text().split("\n")
        for number, literal in candidate_literals(path, "\n".join(lines)):
            line = lines[number - 1]
            # A call such as `logger.warning(` often puts the literal on the next line.
            context = lines[number - 2] + line if line.lstrip().startswith('"') and number > 1 else line
            if not baseline.exempts_line(context):
                found.setdefault(literal, []).append(f"{path}:{number}")
    return found


def runtime_keys(catalog: dict) -> set[str]:
    """Keys that the code looks up at run time. Their literals are localized, but not extracted."""
    return {key for key, entry in catalog["strings"].items() if entry.get("extractionState") == "manual"}


def open_places(
    found: dict[str, list[str]],
    baseline: Baseline,
    extracted: dict[str, set[str]],
    runtime_keys: set[str] = frozenset(),
) -> dict[str, list[str]]:
    """The places where each candidate is still not localized.

    The comparison is per place (`path:line`): the same words can be localized in a label and
    verbatim in a tooltip of the same file. The compiler and the lexer report the same line for
    a literal. In a file that looks titles up at run time, a catalog key is localized.
    """
    localized: dict[str, set[str]] = {}
    for key, places in extracted.items():
        localized.setdefault(loosen(key), set()).update(places)
    still_open = {}
    for literal, places in found.items():
        extracted_places = localized.get(loosen(literal))
        in_catalog = extracted_places is not None or literal in runtime_keys
        remaining = []
        for place in places:
            if place in (extracted_places or ()):
                continue
            if in_catalog and baseline.looks_up_at_run_time(place_path(place)):
                continue
            remaining.append(place)
        if remaining:
            still_open[literal] = remaining
    return still_open


def unknown_candidates(
    found: dict[str, list[str]],
    baseline: Baseline,
    extracted: dict[str, set[str]],
    runtime_keys: set[str] = frozenset(),
) -> dict[str, list[str]]:
    """Open places of the candidates that nobody has triaged into the baseline yet."""
    still_open = open_places(found, baseline, extracted, runtime_keys)
    return {literal: places for literal, places in still_open.items() if not baseline.knows(literal)}


def places_elsewhere(still_open: dict[str, list[str]], literal: str, changed: set[str]) -> list[str]:
    """Open places of a literal outside the changed files. The debt is paid only when they go too."""
    return [place for place in still_open.get(literal, []) if place_path(place) not in changed]


def debt_places(
    still_open: dict[str, list[str]], baseline: Baseline, changed: set[str] | None
) -> dict[str, list[tuple[int, str]]]:
    """Group the open places of the debt by file. `changed` limits the result to those files."""
    by_file: dict[str, list[tuple[int, str]]] = {}
    for literal in baseline.debt:
        for place in still_open.get(literal, []):
            path, line = place.rsplit(":", 1)
            if changed is None or path in changed:
                by_file.setdefault(path, []).append((int(line), literal))
    return {path: sorted(items) for path, items in sorted(by_file.items())}


# MARK: - Commands


def load_json(path: Path) -> dict:
    return json.loads(path.read_text())


def print_issues(title: str, issues: list[str]) -> None:
    if issues:
        print(f"\n## {title} ({len(issues)})")
        for issue in issues:
            print("  " + issue.replace("\n", "\\n"))


def stringsdata_directory(arguments) -> Path:
    directory = arguments.stringsdata or build_objects_directory()
    if not any(Path(directory).rglob("*.stringsdata")):
        raise SystemExit(f"error: no .stringsdata files in {directory}; run `make build-app` first")
    return directory


def command_check(arguments) -> int:
    issues = structure_issues(load_json(arguments.catalog))
    print_issues("Broken translations", issues)
    return 1 if issues else 0


def command_audit(arguments) -> int:
    catalog = load_json(arguments.catalog)
    baseline = Baseline(load_json(arguments.baseline))
    extracted = extracted_keys(stringsdata_directory(arguments))
    coverage = extraction_issues(catalog, extracted)
    found = scan_sources(ROOT, baseline)
    report = {
        "broken": structure_issues(catalog),
        "missing": coverage.missing,
        "unused": coverage.unused,
        "untranslated": translation_issues(catalog),
        "suspects": unknown_candidates(found, baseline, extracted, runtime_keys(catalog)),
        "obsolete": baseline.obsolete(set(open_places(found, baseline, extracted, runtime_keys(catalog)))),
    }
    debt = len(baseline.debt)
    if arguments.json:
        print(json.dumps({**report, "debt": debt, "blocked": len(baseline.blocked)}, ensure_ascii=False, indent=2))
    else:
        print_issues("Broken translations", report["broken"])
        print_issues("Missing from the catalog", [f'"{k}" ({", ".join(v)})' for k, v in report["missing"].items()])
        print_issues("Unused catalog entries", [f'"{key}"' for key in report["unused"]])
        print_issues("Untranslated", report["untranslated"])
        print_issues("Suspects to triage", [f'"{k}" ({v[0]})' for k, v in report["suspects"].items()])
        print_issues("Obsolete baseline entries", [f'"{literal}"' for literal in report["obsolete"]])
        print(f"\nKnown debt: {debt} literal(s) of UI copy that are not localized yet.")
        print(f"Blocked: {len(baseline.blocked)} literal(s) that share their value with protocol text (`debt --blocked`).")
    return 1 if any(report.values()) else 0


def command_apply(arguments) -> int:
    catalog = load_json(arguments.catalog)
    translations = load_json(arguments.translations)
    summary = apply_summary(catalog, translations)
    errors = apply_translations(catalog, translations)
    print(summary)
    print_issues("Rejected", errors)
    arguments.catalog.write_text(serialize(catalog))
    return 1 if errors else 0


def command_prune(arguments) -> int:
    catalog = load_json(arguments.catalog)
    baseline = Baseline(load_json(arguments.baseline))
    extracted = extracted_keys(stringsdata_directory(arguments))
    still_open = open_places(scan_sources(ROOT, baseline), baseline, extracted, runtime_keys(catalog))
    removed = prune(catalog, extracted)
    obsolete = baseline.obsolete(set(still_open))
    baseline.remove(obsolete)
    arguments.catalog.write_text(serialize(catalog))
    arguments.baseline.write_text(baseline.serialize())
    print_issues("Removed catalog entries", [f'"{key}"' for key in removed])
    print_issues("Removed baseline entries", [f'"{literal}"' for literal in obsolete])
    return 0


def record_decisions(baseline: Baseline, decisions: dict) -> None:
    """Record `{"exempt": {literal: category}, "blocked": {literal: reason}, "debt": [literal]}`.

    The latest decision wins. A blocked entry is UI copy that shares its value with text that
    must stay in English; the reason says what the value is also used for.
    """
    for literal, category in decisions.get("exempt", {}).items():
        if category not in EXEMPT_CATEGORIES:
            raise SystemExit(f'error: "{literal}": category must be one of {", ".join(EXEMPT_CATEGORIES)}')
        baseline.remove([literal])
        baseline.exempt_literals[literal] = category
    for literal, reason in decisions.get("blocked", {}).items():
        baseline.remove([literal])
        baseline.blocked[literal] = reason
    for literal in decisions.get("debt", []):
        baseline.remove([literal])
        baseline.debt.append(literal)


def command_triage(arguments) -> int:
    baseline = Baseline(load_json(arguments.baseline))
    record_decisions(baseline, load_json(arguments.decisions))
    arguments.baseline.write_text(baseline.serialize())
    return 0


def command_debt(arguments) -> int:
    catalog = load_json(arguments.catalog)
    baseline = Baseline(load_json(arguments.baseline))
    extracted = extracted_keys(stringsdata_directory(arguments))
    still_open = open_places(scan_sources(ROOT, baseline), baseline, extracted, runtime_keys(catalog))
    changed = None
    if arguments.since:
        command = ["git", "-C", str(ROOT), "diff", "--name-only", f"{arguments.since}..HEAD", "--", SOURCES]
        changed = set(subprocess.run(command, check=True, capture_output=True, text=True).stdout.split())
    if arguments.blocked:
        for literal, reason in sorted(baseline.blocked.items()):
            places = ", ".join(still_open.get(literal, []))
            print(f"{literal}\n    {reason}\n    {places}")
        print(f"\n{len(baseline.blocked)} blocked literal(s).")
        return 0
    by_file = debt_places(still_open, baseline, changed)
    for path, items in sorted(by_file.items(), key=lambda item: -len(item[1])):
        print(f"\n## {path} ({len(items)})")
        for line, literal in items:
            elsewhere = places_elsewhere(still_open, literal, changed) if changed is not None else []
            note = f"  (also at {', '.join(elsewhere)})" if elsewhere else ""
            print(f"  {line}: " + literal.replace("\n", "\\n") + note)
    print(f"\n{sum(len(items) for items in by_file.values())} debt place(s) in {len(by_file)} file(s).")
    return 0


def command_format(arguments) -> int:
    arguments.catalog.write_text(serialize(load_json(arguments.catalog)))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--catalog", type=Path, default=CATALOG)
    parser.add_argument("--baseline", type=Path, default=BASELINE)
    parser.add_argument("--stringsdata", type=Path, help="build directory with the .stringsdata files")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("check").set_defaults(run=command_check)
    audit = commands.add_parser("audit")
    audit.add_argument("--json", action="store_true", help="print the full report as JSON")
    audit.set_defaults(run=command_audit)
    apply = commands.add_parser("apply")
    apply.add_argument("translations", type=Path)
    apply.set_defaults(run=command_apply)
    commands.add_parser("prune").set_defaults(run=command_prune)
    triage = commands.add_parser("triage")
    triage.add_argument("decisions", type=Path)
    triage.set_defaults(run=command_triage)
    debt = commands.add_parser("debt")
    debt.add_argument("--since", help="only files changed since this git ref, for example the last release tag")
    debt.add_argument("--blocked", action="store_true", help="list the blocked copy with its reasons instead")
    debt.set_defaults(run=command_debt)
    commands.add_parser("format").set_defaults(run=command_format)
    arguments = parser.parse_args()
    return arguments.run(arguments)


if __name__ == "__main__":
    sys.exit(main())
