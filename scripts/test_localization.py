import json
import tempfile
import unittest
from pathlib import Path

from localization import (
    Baseline,
    apply_summary,
    apply_translations,
    build_settings_command,
    candidate_literals,
    debt_places,
    open_places,
    places_elsewhere,
    extracted_keys,
    extraction_issues,
    placeholders,
    prune,
    record_decisions,
    serialize,
    structure_issues,
    translation_issues,
    unknown_candidates,
)


def unit(value, state="translated"):
    return {"stringUnit": {"state": state, "value": value}}


def entry(zh_hans=None, **fields):
    localizations = {} if zh_hans is None else {"zh-Hans": unit(zh_hans)}
    return {"localizations": localizations, **fields}


def catalog(strings):
    return {"sourceLanguage": "en", "strings": strings, "version": "1.0"}


class PlaceholderTests(unittest.TestCase):
    def test_reads_types_in_argument_order(self):
        self.assertEqual(placeholders("%@ has %lld items"), ["@", "lld"])
        self.assertEqual(placeholders("%2$lld 项属于 %1$@"), ["@", "lld"])

    def test_ignores_escaped_percent(self):
        self.assertEqual(placeholders("%lld%% done"), ["lld"])

    def test_rejects_mixed_positional_and_sequential(self):
        self.assertIsNone(placeholders("%1$@ and %@"))


class SerializeTests(unittest.TestCase):
    def test_matches_the_format_that_xcode_writes(self):
        text = serialize(catalog({"b": entry("乙"), "A": {"shouldTranslate": False}}))
        self.assertTrue(text.startswith('{\n  "sourceLanguage" : "en",\n  "strings" : {\n    "A" : {'))
        self.assertLess(text.index('"A"'), text.index('"b"'))
        self.assertIn('"value" : "乙"', text)
        self.assertFalse(text.endswith("\n"))


class StructureIssueTests(unittest.TestCase):
    """The everyday check. It must not fail because a translation is still missing."""

    def test_accepts_entries_that_wait_for_the_release_sync(self):
        strings = {
            "Open": entry("打开"),
            "New copy": entry(),
            "From Xcode": {"extractionState": "stale", "localizations": {"zh-Hans": unit("旧", state="new")}},
        }
        self.assertEqual(structure_issues(catalog(strings)), [])

    def test_reports_placeholder_mismatch(self):
        strings = {"%@ has %lld items": entry("%@ 有 %@ 项")}
        self.assertEqual(
            structure_issues(catalog(strings)),
            ['"%@ has %lld items": zh-Hans placeholders [@, @] do not match source [@, lld]'],
        )

    def test_reports_reordered_placeholders_without_positions(self):
        strings = {"%@ has %lld items": entry("%lld 项属于 %@")}
        self.assertEqual(len(structure_issues(catalog(strings))), 1)

    def test_checks_every_variation(self):
        variations = {"variations": {"plural": {"one": unit("%lld 项"), "other": unit("很多项")}}}
        strings = {"%lld items": {"localizations": {"zh-Hans": variations}}}
        self.assertEqual(
            structure_issues(catalog(strings)),
            ['"%lld items": zh-Hans placeholders [] do not match source [lld]'],
        )


class TranslationIssueTests(unittest.TestCase):
    """The release check."""

    def test_accepts_complete_catalog(self):
        strings = {"Open": entry("打开"), "·": {"shouldTranslate": False}}
        self.assertEqual(translation_issues(catalog(strings)), [])

    def test_reports_missing_translation(self):
        strings = {"Open": entry("打开"), "Close": entry()}
        self.assertEqual(translation_issues(catalog(strings)), ['"Close": no zh-Hans translation'])

    def test_reports_unfinished_state(self):
        strings = {"Open": {"localizations": {"zh-Hans": unit("打开", state="needs_review")}}}
        self.assertEqual(translation_issues(catalog(strings)), ['"Open": zh-Hans state is needs_review'])

    def test_requires_every_language_the_catalog_uses(self):
        strings = {
            "Open": {"localizations": {"zh-Hans": unit("打开"), "ja": unit("開く")}},
            "Close": entry("关闭"),
        }
        self.assertEqual(translation_issues(catalog(strings)), ['"Close": no ja translation'])


class ExtractionIssueTests(unittest.TestCase):
    def test_reports_key_in_code_without_entry(self):
        extracted = {"Open": {"supacode/A.swift:3"}, "Close": {"supacode/B.swift:9", "supacode/B.swift:4"}}
        issues = extraction_issues(catalog({"Open": entry("打开")}), extracted)
        self.assertEqual(issues.missing, {"Close": ["supacode/B.swift:4", "supacode/B.swift:9"]})
        self.assertEqual(issues.unused, [])

    def test_reports_entry_without_use(self):
        issues = extraction_issues(catalog({"Open": entry("打开"), "Close": entry("关闭")}), {"Open": {"A.swift:1"}})
        self.assertEqual(issues.unused, ["Close"])

    def test_keeps_manual_entry_without_use(self):
        strings = {"Open": entry("打开", extractionState="manual")}
        self.assertEqual(extraction_issues(catalog(strings), {}).unused, [])


class ExtractedKeyTests(unittest.TestCase):
    def test_reads_localizable_table_of_existing_sources(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "View.swift"
            source.write_text("")
            data = {
                "source": str(source),
                "tables": {
                    "Localizable": [{"key": "Open", "location": {"startingLine": 7}}, {"key": ""}],
                    "Other": [{"key": "Ignored"}],
                },
            }
            (root / "View.stringsdata").write_text(json.dumps(data))
            removed = {"source": str(root / "Removed.swift"), "tables": {"Localizable": [{"key": "Gone"}]}}
            (root / "Removed.stringsdata").write_text(json.dumps(removed))
            self.assertEqual(extracted_keys(root, root=root), {"Open": {"View.swift:7"}})


class ApplyTests(unittest.TestCase):
    def test_adds_and_updates_translations(self):
        data = catalog({"Open": entry("开")})
        errors = apply_translations(data, {"Open": {"zh-Hans": "打开"}, "Close": {"zh-Hans": "关闭"}})
        self.assertEqual(errors, [])
        self.assertEqual(data["strings"]["Open"]["localizations"]["zh-Hans"], unit("打开"))
        self.assertEqual(data["strings"]["Close"]["localizations"]["zh-Hans"], unit("关闭"))

    def test_null_marks_a_key_as_not_translatable(self):
        data = catalog({})
        self.assertEqual(apply_translations(data, {"%@:%@": None}), [])
        self.assertEqual(data["strings"]["%@:%@"], {"shouldTranslate": False})

    def test_summarizes_what_apply_changed(self):
        data = catalog({"Open": entry("开")})
        translations = {"Open": {"zh-Hans": "打开"}, "Close": {"zh-Hans": "关闭"}, "Title": {"manual": True}, "·": None}
        self.assertEqual(apply_summary(data, translations), "Added 3, updated 1 (1 manual, 1 not translatable).")

    def test_marks_a_key_as_manual_without_a_new_translation(self):
        data = catalog({"Toggle Canvas": entry("切换画布")})
        self.assertEqual(apply_translations(data, {"Toggle Canvas": {"manual": True}}), [])
        self.assertEqual(data["strings"]["Toggle Canvas"]["extractionState"], "manual")
        self.assertEqual(data["strings"]["Toggle Canvas"]["localizations"]["zh-Hans"], unit("切换画布"))

    def test_marks_a_run_time_key_as_manual(self):
        data = catalog({})
        self.assertEqual(apply_translations(data, {"Toggle Canvas": {"zh-Hans": "切换画布", "manual": True}}), [])
        self.assertEqual(data["strings"]["Toggle Canvas"]["extractionState"], "manual")
        self.assertEqual(list(data["strings"]["Toggle Canvas"]["localizations"]), ["zh-Hans"])

    def test_rejects_a_translation_with_wrong_placeholders(self):
        data = catalog({})
        errors = apply_translations(data, {"%@ items": {"zh-Hans": "很多项"}})
        self.assertEqual(len(errors), 1)
        self.assertNotIn("%@ items", data["strings"])


class PruneTests(unittest.TestCase):
    def test_removes_unused_entries_and_keeps_manual_ones(self):
        strings = {
            "Open": entry("打开"),
            "Gone": entry("没了"),
            "Run time": entry("运行时", extractionState="manual"),
        }
        data = catalog(strings)
        self.assertEqual(prune(data, {"Open": {"A.swift:1"}}), ["Gone"])
        self.assertEqual(sorted(data["strings"]), ["Open", "Run time"])


class CandidateLiteralTests(unittest.TestCase):
    def scan(self, path, text):
        return [literal for _, literal in candidate_literals(path, text)]

    def test_finds_sentences_anywhere(self):
        text = 'let message = "Unable to create worktree"\nlet key = "defaultEditorID"\n'
        self.assertEqual(self.scan("supacode/Domain/Thing.swift", text), ["Unable to create worktree"])

    def test_finds_single_words_only_in_view_files(self):
        text = 'Text(flag ? "Ready" : label)\n'
        self.assertEqual(self.scan("supacode/Features/X/Views/Row.swift", text), ["Ready"])
        self.assertEqual(self.scan("supacode/Domain/Thing.swift", text), [])

    def test_describes_interpolation_as_a_placeholder(self):
        text = 'return "Cannot reach \\(endpoint). Check the network."\n'
        self.assertEqual(self.scan("supacode/Domain/Thing.swift", text), ["Cannot reach %@. Check the network."])

    def test_finds_one_word_with_a_value_anywhere(self):
        text = 'let label = "Automatic (\\(ref))"\nlet header = "Bearer \\(token)"\nlet key = "prefix-\\(id)"\n'
        self.assertEqual(self.scan("supacode/Domain/Thing.swift", text), ["Automatic (%@)", "Bearer %@"])

    def test_skips_file_names_and_identifiers(self):
        text = 'let a = "Cargo.toml"\nlet b = "PROWL_LAUNCH_HOOK_TOKEN"\nlet c = "\\(home)/.local/bin/gh"\n'
        self.assertEqual(self.scan("supacode/Domain/Thing.swift", text), [])

    def test_skips_comments(self):
        self.assertEqual(self.scan("supacode/Domain/Thing.swift", '// "Not real copy here"\n'), [])

    def test_reads_past_quotes_inside_an_interpolation(self):
        text = 'let text = "Launching role \\(redelivery ? "again" : "now") for you"\n'
        self.assertEqual(self.scan("supacode/Domain/Thing.swift", text), ["Launching role %@ for you"])

    def test_reads_a_multi_line_literal_as_one_string(self):
        text = 'let text = """\n    Host is off. \\\n    Start Host first.\n    """\nlet next = 1\n'
        self.assertEqual(self.scan("supacode/Domain/Thing.swift", text), ["Host is off. Start Host first."])

    def test_keeps_a_space_that_follows_a_line_continuation(self):
        text = 'Text(\n  """\n  They play sounds\\\n   according to your settings.\n  """\n)\n'
        self.assertEqual(
            self.scan("supacode/Domain/Thing.swift", text), ["They play sounds according to your settings."]
        )

    def test_reports_the_line_where_the_literal_starts(self):
        text = 'let a = 1\nlet text = "Unable to create worktree"\n'
        self.assertEqual(candidate_literals("supacode/Domain/Thing.swift", text), [(2, "Unable to create worktree")])


class BaselineTests(unittest.TestCase):
    def baseline(self, **fields):
        data = {"exemptPaths": {}, "exemptLinePatterns": {}, "exemptLiterals": {}, "blocked": {}, "debt": []}
        data.update(fields)
        return Baseline(data)

    def test_reports_only_candidates_that_nobody_has_triaged(self):
        baseline = self.baseline(exemptLiterals={"Claude Code": "product-name"}, debt=["Unable to create worktree"])
        found = {
            "Claude Code": ["supacode/Domain/A.swift:1"],
            "Unable to create worktree": ["supacode/Features/B.swift:2"],
            "Brand new copy": ["supacode/Features/C.swift:3"],
        }
        self.assertEqual(unknown_candidates(found, baseline, extracted={}), {"Brand new copy": found["Brand new copy"]})

    def test_ignores_what_the_compiler_extracted_from_the_same_file(self):
        found = {"Open %@": ["supacode/Features/C.swift:3"]}
        extracted = {"Open %lld": {"supacode/Features/C.swift:3"}}
        self.assertEqual(unknown_candidates(found, self.baseline(), extracted), {})

    def test_reports_a_verbatim_copy_in_the_same_file(self):
        found = {"Listening": ["supacode/Features/Status.swift:140", "supacode/Features/Status.swift:154"]}
        extracted = {"Listening": {"supacode/Features/Status.swift:140"}}
        self.assertEqual(
            unknown_candidates(found, self.baseline(), extracted),
            {"Listening": ["supacode/Features/Status.swift:154"]},
        )

    def test_does_not_confuse_two_files_with_the_same_name(self):
        found = {"Open %@": ["supacode/Features/A/Row.swift:3"]}
        extracted = {"Open %@": {"supacode/Features/B/Row.swift:3"}}
        self.assertEqual(list(unknown_candidates(found, self.baseline(), extracted)), ["Open %@"])

    def test_trusts_a_run_time_key_only_where_titles_are_looked_up(self):
        baseline = self.baseline(runtimeKeyPaths={"supacode/App/AppShortcuts.swift": "Binding.localizedTitle"})
        found = {"Toggle Canvas": ["supacode/App/AppShortcuts.swift:3", "supacode/Features/Tooltip.swift:8"]}
        self.assertEqual(
            unknown_candidates(found, baseline, {}, runtime_keys={"Toggle Canvas"}),
            {"Toggle Canvas": ["supacode/Features/Tooltip.swift:8"]},
        )

    def test_trusts_catalog_keys_in_a_file_that_looks_titles_up_at_run_time(self):
        baseline = self.baseline(runtimeKeyPaths={"supacode/App/AppShortcuts.swift": "Binding.localizedTitle"})
        found = {
            "Toggle Left Sidebar": ["supacode/App/AppShortcuts.swift:3"],
            "Not in the catalog": ["supacode/App/AppShortcuts.swift:4"],
        }
        unknown = unknown_candidates(found, baseline, {"Toggle Left Sidebar": {"supacode/Commands/SidebarCommands.swift:15"}})
        self.assertEqual(list(unknown), ["Not in the catalog"])

    def test_reports_a_literal_that_only_another_file_localizes(self):
        found = {"Toggle Canvas": ["supacode/App/Menu.swift:3", "supacode/Features/Palette.swift:9"]}
        extracted = {"Toggle Canvas": {"supacode/App/Menu.swift:3"}}
        self.assertEqual(
            unknown_candidates(found, self.baseline(), extracted),
            {"Toggle Canvas": ["supacode/Features/Palette.swift:9"]},
        )

    def test_exempts_by_path_and_by_line(self):
        baseline = self.baseline(
            exemptPaths={"supacode/CLIService/**": "protocol"},
            exemptLinePatterns={r"[Ll]ogger\.": "log"},
        )
        self.assertTrue(baseline.exempts_path("supacode/CLIService/Handler.swift"))
        self.assertFalse(baseline.exempts_path("supacode/Features/View.swift"))
        self.assertTrue(baseline.exempts_line('  logger.info("Something happened here")'))

    def test_latest_triage_decision_wins(self):
        baseline = self.baseline(exemptLiterals={"RUN SCRIPT": "identifier"}, debt=["Claude Code"])
        record_decisions(baseline, {"exempt": {"Claude Code": "product-name"}, "debt": ["RUN SCRIPT"]})
        self.assertEqual(baseline.exempt_literals, {"Claude Code": "product-name"})
        self.assertEqual(baseline.debt, ["RUN SCRIPT"])

    def test_blocked_copy_is_not_debt(self):
        baseline = self.baseline(debt=["Launching %@ failed: %@"])
        record_decisions(baseline, {"blocked": {"Launching %@ failed: %@": "also in log.md"}})
        self.assertEqual(baseline.debt, [])
        self.assertEqual(baseline.blocked, {"Launching %@ failed: %@": "also in log.md"})
        self.assertTrue(baseline.knows("Launching %@ failed: %@"))
        record_decisions(baseline, {"debt": ["Launching %@ failed: %@"]})
        self.assertEqual((baseline.debt, baseline.blocked), (["Launching %@ failed: %@"], {}))

    def test_drops_a_blocked_entry_that_is_gone(self):
        baseline = self.baseline(blocked={"Gone copy": "reason"})
        self.assertEqual(baseline.obsolete(set()), ["Gone copy"])
        baseline.remove(["Gone copy"])
        self.assertEqual(baseline.blocked, {})

    def test_reports_entries_that_left_the_code(self):
        baseline = self.baseline(exemptLiterals={"Gone Product": "product-name"}, debt=["Gone copy", "Still here"])
        self.assertEqual(baseline.obsolete({"Still here"}), ["Gone Product", "Gone copy"])

    def test_lists_debt_in_the_files_a_release_touched(self):
        baseline = self.baseline(debt=["Expand All", "Cancel Run"], exemptLiterals={"Claude Code": "product-name"})
        still_open = {
            "Expand All": ["supacode/Features/Sidebar.swift:3"],
            "Cancel Run": ["supacode/Features/Workflow.swift:9"],
            "Claude Code": ["supacode/Features/Sidebar.swift:5"],
        }
        self.assertEqual(
            debt_places(still_open, baseline, changed={"supacode/Features/Sidebar.swift"}),
            {"supacode/Features/Sidebar.swift": [(3, "Expand All")]},
        )
        self.assertEqual(len(debt_places(still_open, baseline, changed=None)), 2)

    def test_names_the_places_of_a_literal_outside_the_changed_files(self):
        baseline = self.baseline(debt=["Open on %@"])
        still_open = {"Open on %@": ["supacode/Commands/Menu.swift:3", "supacode/Features/Button.swift:9"]}
        self.assertEqual(
            places_elsewhere(still_open, "Open on %@", changed={"supacode/Commands/Menu.swift"}),
            ["supacode/Features/Button.swift:9"],
        )

    def test_debt_is_paid_when_every_place_is_localized(self):
        baseline = self.baseline(debt=["Expand All", "Collapse All"])
        found = {"Expand All": ["supacode/Features/Sidebar.swift:3"], "Collapse All": ["supacode/Features/Sidebar.swift:4"]}
        still_open = open_places(found, baseline, {"Expand All": {"supacode/Features/Sidebar.swift:3"}})
        self.assertEqual(baseline.obsolete(set(still_open)), ["Expand All"])


class BuildSettingsCommandTests(unittest.TestCase):
    def test_uses_the_default_derived_data(self):
        self.assertNotIn("-derivedDataPath", build_settings_command({}))

    def test_follows_the_derived_data_path_of_make_test(self):
        command = build_settings_command({"PROWL_DERIVED_DATA_PATH": "/tmp/dd"})
        index = command.index("-derivedDataPath")
        self.assertEqual(command[index + 1], "/tmp/dd")


if __name__ == "__main__":
    unittest.main()
