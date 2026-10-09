#!/usr/bin/env python3
"""Tests for the fixture generator's width guarantee.

The corpus tests validate the fixtures that were committed; they never execute
the generator, so nothing held it to the one promise it makes — that a redacted
row occupies the same columns the terminal captured. These do.

Run with `make test-scripts`, or directly:

    python3 -m unittest discover -s scripts -p 'test_*.py'
"""

from __future__ import annotations

import importlib.util
import json
import pathlib
import re
import subprocess
import sys
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parent / "make-detection-fixture.py"
DETECTED_AGENT_SWIFT = (
    SCRIPT.parent.parent / "App/Sources/Domain/AgentDetection/DetectedAgent.swift"
)
SCREEN_HEURISTICS_SWIFT = (
    SCRIPT.parent.parent / "App/Sources/Infrastructure/AgentDetection/ScreenHeuristics.swift"
)


def swift_declaration_body(source: str, header: str) -> str:
    """The braced body of the declaration `header` opens, brace-matched.

    Splitting on a later member instead would stop the scan early, and a case
    declared after that member would go unread.
    """
    start = source.index(header)
    opening = source.index("{", start)
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[opening + 1 : index]
    raise AssertionError(f"unterminated declaration: {header}")


_spec = importlib.util.spec_from_file_location("make_detection_fixture", SCRIPT)
fixture = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(fixture)


class CellWidth(unittest.TestCase):
    def test_ascii_counts_one_cell_per_character(self):
        self.assertEqual(fixture.cell_width("claude"), 6)

    def test_ideographs_count_two_cells(self):
        # len() is 1 here, which is exactly the confusion this replaces.
        self.assertEqual(fixture.cell_width("猫"), 2)
        self.assertEqual(fixture.cell_width("メモ"), 4)

    def test_combining_marks_occupy_no_cell(self):
        self.assertEqual(fixture.cell_width("é"), 1)

    def test_joiner_is_refused_rather_than_guessed(self):
        with self.assertRaises(fixture.WidthError):
            fixture.cell_width("\U0001f469‍\U0001f4bb")

    def test_variation_selector_is_refused(self):
        with self.assertRaises(fixture.WidthError):
            fixture.cell_width("❤️")

    def test_emoji_modifier_is_refused_rather_than_summed(self):
        # Two wide code points, one two-cell grapheme: summing reports four.
        with self.assertRaises(fixture.WidthError):
            fixture.cell_width("\U0001f469\U0001f3fd")

    def test_tag_sequence_is_refused(self):
        with self.assertRaises(fixture.WidthError):
            fixture.cell_width("\U0001f3f4\U000e0067\U000e0062")


class Substitute(unittest.TestCase):
    def test_narrowing_replacement_pads_to_hold_the_border(self):
        line = "│ user  猫猫  │"
        out = fixture.substitute(line, "猫猫", "cat")
        self.assertEqual(fixture.cell_width(out), fixture.cell_width(line))
        self.assertTrue(out.endswith("│"))

    def test_widening_replacement_consumes_following_spaces(self):
        line = "│ me     │"
        out = fixture.substitute(line, "me", "user")
        self.assertEqual(fixture.cell_width(out), fixture.cell_width(line))

    def test_widening_beyond_the_slack_is_refused(self):
        with self.assertRaises(fixture.WidthError):
            fixture.substitute("│ me │", "me", "a much longer name")

    def test_ascii_replaced_by_ideograph_holds_the_width(self):
        line = "│ ab      │"
        out = fixture.substitute(line, "ab", "猫")
        self.assertEqual(fixture.cell_width(out), fixture.cell_width(line))


class MoneyMasking(unittest.TestCase):
    def test_multi_digit_amount_keeps_its_columns(self):
        line = "│ spent $123.45 today │"
        out, applied = fixture.mask_money(line)
        self.assertEqual(fixture.cell_width(out), fixture.cell_width(line))
        self.assertIn("$XXX.XX", out)
        self.assertEqual(applied, [("$123.45", "$XXX.XX")])

    def test_single_unit_amount_still_masks(self):
        out, _ = fixture.mask_money("cost $1.23 |")
        self.assertEqual(out, "cost $X.XX |")

    def test_grouped_amount_is_masked_and_keeps_its_separator(self):
        line = "│ $1,234.56 spent │"
        out, applied = fixture.mask_money(line)
        self.assertEqual(out, "│ $X,XXX.XX spent │")
        self.assertEqual(fixture.cell_width(out), fixture.cell_width(line))
        self.assertEqual(applied, [("$1,234.56", "$X,XXX.XX")])

    def test_unrecognized_amount_shape_fails_rather_than_passing_through(self):
        with self.assertRaises(fixture.AmountError):
            fixture.mask_money("total $12,34.5 |")

    def test_shell_positional_is_not_treated_as_an_amount(self):
        # `echo "$1"` is ordinary capture content, not billing data.
        out, applied = fixture.mask_money('echo "$1" && shift')
        self.assertEqual(out, 'echo "$1" && shift')
        self.assertEqual(applied, [])

    def test_several_amounts_on_one_row(self):
        line = "$9.99 and $1234.56 |"
        out, applied = fixture.mask_money(line)
        self.assertEqual(fixture.cell_width(out), fixture.cell_width(line))
        self.assertEqual(out, "$X.XX and $XXXX.XX |")
        self.assertEqual(len(applied), 2)



class AgentVocabulary(unittest.TestCase):
    def test_agent_vocabulary_matches_the_swift_enum(self):
        # The generator mirrors the detector's dispatch, so its agent names have
        # to be the detector's. A hand-copied list drifts silently; this fails.
        source = DETECTED_AGENT_SWIFT.read_text(encoding="utf-8")
        body = swift_declaration_body(source, "enum DetectedAgent")
        # Two leading spaces pins a member of the enum itself. A `case .claude:`
        # inside one of its switch statements sits deeper and ends in a colon,
        # so it matches neither the indent nor the end-of-line anchor.
        cases = re.findall(r'^  case (\w+)(?:\s*=\s*"([^"]+)")?\s*$', body, re.M)
        self.assertTrue(cases, "no cases parsed from DetectedAgent.swift")
        self.assertEqual(list(fixture.DETECTED_AGENTS), [raw or name for name, raw in cases])

    def test_body_scan_reads_past_a_member_declared_before_a_case(self):
        # The scan used to stop at `var id:`. Swift permits a case after a
        # computed property, and that case has to be read.
        source = "enum Sample: String {\n  case first\n  var id: String { rawValue }\n  case last\n}\n"
        body = swift_declaration_body(source, "enum Sample")
        cases = re.findall(r'^  case (\w+)(?:\s*=\s*"([^"]+)")?\s*$', body, re.M)
        self.assertEqual([name for name, _ in cases], ["first", "last"])


class TailLimits(unittest.TestCase):
    def test_tail_limits_match_the_swift_constants(self):
        # The generator ports the detector's line budgets. A budget changed on
        # the Swift side and not here produces a fixture the detector never
        # reads, and the corpus round trip cannot see it: applying a wider tail
        # to an already narrower fixture leaves the fixture unchanged.
        source = SCREEN_HEURISTICS_SWIFT.read_text(encoding="utf-8")
        limits = dict(
            re.findall(r"^nonisolated let (\w*[Ll]ineLimit) = (\d+)$", source, re.M)
        )
        self.assertEqual(
            limits,
            {
                "agentDetectionRecentLineLimit": str(fixture.DETECTOR_TAIL_LIMIT),
                "piAgentDetectionRecentLineLimit": str(fixture.PI_DETECTOR_TAIL_LIMIT),
            },
        )


class Reduction(unittest.TestCase):
    def test_claude_and_antigravity_keep_the_full_screen(self):
        # Mirrors `DetectedAgent.detectionScreenText(from:)`: trimming a Claude
        # capture can delete the very row that reproduces a bug, and trimming an
        # Antigravity capture can delete the composer box its detector anchors on.
        text = "\n".join(f"line {index}" for index in range(40))
        self.assertEqual(fixture.detection_screen_text(text, "claude"), text)
        self.assertEqual(fixture.detection_screen_text(text, "antigravity"), text)

    def test_pi_takes_the_wider_bounded_tail(self):
        # Mirrors the `.pi` branch: 32 non-blank lines, not the default 24.
        text = "\n".join(f"line {index}" for index in range(40))
        reduced = fixture.detection_screen_text(text, "pi")
        self.assertEqual(reduced.split("\n"), [f"line {index}" for index in range(8, 40)])

    def test_other_agents_take_the_bounded_tail(self):
        text = "\n".join(f"line {index}" for index in range(40))
        reduced = fixture.detection_screen_text(text, "codex")
        self.assertEqual(reduced.split("\n"), [f"line {index}" for index in range(16, 40)])

    def test_each_agent_takes_its_own_slice_of_one_screen(self):
        # The three reduction categories, read off the same capture.
        text = "\n".join(f"line {index}" for index in range(40))
        widths = {
            agent: len(fixture.detection_screen_text(text, agent).split("\n"))
            for agent in ("claude", "pi", "codex")
        }
        self.assertEqual(widths, {"claude": 40, "pi": 32, "codex": 24})

    def test_blank_lines_do_not_count_toward_the_tail_budget(self):
        rows = [f"line {index}" for index in range(30)]
        rows.insert(28, "")
        reduced = fixture.detection_screen_text("\n".join(rows), "codex")
        self.assertEqual(len(reduced.split("\n")), 25)
        self.assertIn("", reduced.split("\n"))

    def test_short_screens_pass_through_for_every_agent(self):
        text = "a\n\nb"
        self.assertEqual(fixture.detection_screen_text(text, "codex"), text)


class EndToEnd(unittest.TestCase):
    def run_script(self, text, *args, agent="claude"):
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as handle:
            json.dump({"data": {"source": "detection", "text": text}}, handle)
            path = handle.name
        try:
            return subprocess.run(
                [sys.executable, str(SCRIPT), path, "--agent", agent, *args],
                capture_output=True,
                text=True,
            )
        finally:
            pathlib.Path(path).unlink()

    def test_amount_masking_does_not_move_the_closing_border(self):
        line = "│ Opus 5 · $123.45 · 60m │"
        result = self.run_script(line)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(fixture.cell_width(result.stdout), fixture.cell_width(line))
        self.assertIn("$XXX.XX", result.stdout)

    def test_unicode_redaction_holds_the_row(self):
        line = "│ 東京都のユーザー          │"
        result = self.run_script(line, "--redact", "東京都のユーザー=<CITY_0000>")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(fixture.cell_width(result.stdout), fixture.cell_width(line))

    def test_summary_never_names_what_it_replaced(self):
        line = "│ /Users/realname/Code  │"
        result = self.run_script(line, "--redact", "/Users/realname=/Users/usr")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("realname", result.stderr)
        self.assertIn("/Users/usr", result.stderr)
        self.assertIn("1 line", result.stderr)

    def test_unknown_agent_is_rejected(self):
        # Before the flag was constrained, "Claude" was not "claude" and so took
        # the bounded-tail branch, silently dropping rows from a Claude capture.
        result = self.run_script("row", agent="Claude")
        self.assertEqual(result.returncode, 2)
        self.assertIn("invalid choice", result.stderr)

    def test_undecidable_replacement_fails_the_run(self):
        result = self.run_script("│ owner name │", "--redact", "owner=❤️")
        self.assertEqual(result.returncode, 1)
        self.assertIn("no width terminals agree on", result.stderr)

    def test_agent_selects_the_reduction(self):
        text = "\n".join(f"row {index}" for index in range(30))
        full = self.run_script(text)
        tail = self.run_script(text, agent="codex")
        self.assertEqual(full.stdout, text)
        self.assertEqual(tail.stdout, "\n".join(f"row {index}" for index in range(6, 30)))

    def test_viewport_capture_is_still_rejected(self):
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as handle:
            json.dump({"data": {"source": "screen", "text": "x"}}, handle)
            path = handle.name
        try:
            # `--agent` is passed so exit 2 comes from the source check, not
            # from argparse rejecting a missing required flag with the same code.
            result = subprocess.run(
                [sys.executable, str(SCRIPT), path, "--agent", "claude"],
                capture_output=True,
                text=True,
            )
        finally:
            pathlib.Path(path).unlink()
        self.assertEqual(result.returncode, 2)


if __name__ == "__main__":
    unittest.main()
