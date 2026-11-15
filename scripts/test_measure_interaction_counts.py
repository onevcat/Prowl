import importlib.util
from pathlib import Path
import sys
import unittest


spec = importlib.util.spec_from_file_location(
  "measure_interaction_counts", Path(__file__).with_name("measure-interaction-counts.py")
)
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)


def sample(step, parse, resource, seconds=1.0):
  return module.StepSample(step, {"strings_table_parse": parse, "resource_to_string": resource}, seconds)


class SummarizeTests(unittest.TestCase):
  def test_reports_median_min_and_max_per_step_in_step_order(self):
    samples = [
      sample("activate", 3, 90),
      sample("switch_same_repo", 10, 110),
      sample("switch_same_repo", 12, 110),
      sample("switch_same_repo", 50, 111),
    ]

    summary = module.summarize(samples)

    self.assertEqual(list(summary), ["switch_same_repo", "activate"])
    self.assertEqual(summary["switch_same_repo"]["rounds"], 3)
    self.assertEqual(summary["switch_same_repo"]["median"], {"strings_table_parse": 12, "resource_to_string": 110})
    self.assertEqual(summary["switch_same_repo"]["min"]["strings_table_parse"], 10)
    self.assertEqual(summary["switch_same_repo"]["max"]["strings_table_parse"], 50)

  def test_skips_steps_without_samples(self):
    summary = module.summarize([sample("deactivate", 0, 4)])

    self.assertEqual(list(summary), ["deactivate"])


class MarkdownTableTests(unittest.TestCase):
  def test_renders_one_row_per_step_with_sorted_counter_columns(self):
    report = {
      "os": "26.6",
      "language": "zh-Hans",
      "worktrees": 16,
      "label": "macos-26",
      "summary": module.summarize([sample("switch_cross_repo", 132, 132), sample("activate", 102, 102)]),
    }

    table = module.markdown_table(report)

    self.assertEqual(
      table,
      "### macOS 26.6 · zh-Hans · 16 worktrees · macos-26\n"
      "\n"
      "| Step | resource_to_string | strings_table_parse |\n"
      "| --- | ---: | ---: |\n"
      "| switch_cross_repo | 132 | 132 |\n"
      "| activate | 102 | 102 |\n"
      "\n",
    )


if __name__ == "__main__":
  unittest.main()
