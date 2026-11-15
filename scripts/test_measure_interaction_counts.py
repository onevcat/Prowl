import importlib.util
import os
from pathlib import Path
import sys
import time
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


class CompareTableTests(unittest.TestCase):
  def test_reports_relative_change_per_step_and_counter(self):
    base = {
      "label": "base",
      "os": "26.6",
      "language": "zh-Hans",
      "summary": module.summarize([sample("switch_same_repo", 132, 132), sample("activate", 0, 4)]),
    }
    head = {
      "label": "head",
      "os": "26.6",
      "language": "zh-Hans",
      "summary": module.summarize([sample("switch_same_repo", 0, 66), sample("activate", 0, 0)]),
    }

    table = module.compare_table(base, head)

    self.assertIn("| switch_same_repo | resource_to_string | 132 | 66 | -50% |\n", table)
    self.assertIn("| switch_same_repo | strings_table_parse | 132 | 0 | -100% |\n", table)
    self.assertIn("| activate | strings_table_parse | 0 | 0 | ±0 |\n", table)
    self.assertIn("| activate | resource_to_string | 4 | 0 | -100% |\n", table)


class ProcessCPUTests(unittest.TestCase):
  def test_counts_cpu_time_that_this_process_spends(self):
    before = module.process_cpu_ns(os.getpid())
    deadline = time.process_time() + 0.05
    while time.process_time() < deadline:
      pass

    spent = module.process_cpu_ns(os.getpid()) - before

    self.assertGreaterEqual(spent, 40_000_000)
    self.assertLess(spent, 5_000_000_000)


class MergeReportsTests(unittest.TestCase):
  def test_combines_samples_and_recomputes_the_summary(self):
    def report(waits):
      samples = [{"step": "activate", "counts": {"main_thread_wait_ms": w}, "seconds_with_lldb": 0} for w in waits]
      return {"label": "head", "os": "26.6", "samples": samples, "summary": {}}

    merged = module.merge_reports([report([100, 300]), report([200])])

    self.assertEqual(len(merged["samples"]), 3)
    self.assertEqual(merged["summary"]["activate"]["median"], {"main_thread_wait_ms": 200})
    self.assertEqual(merged["label"], "head")


if __name__ == "__main__":
  unittest.main()
