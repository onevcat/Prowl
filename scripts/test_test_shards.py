import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("test_shards", Path(__file__).with_name("test-shards.py"))
module = importlib.util.module_from_spec(spec)


def enumeration(*identifiers):
    tests = [{"identifier": identifier} for identifier in identifiers]
    return {"errors": [], "values": [{"disabledTests": [], "enabledTests": tests}]}


class TestShardsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec.loader.exec_module(module)

    def test_groups_tests_by_suite_and_keeps_nested_suites(self):
        suites = module.suites_from(enumeration(
            "ProwlTests/A/one()", "ProwlTests/A/two()", "ProwlTests/Root/Nested/three()", "ProwlTests/Root/Nested/four()",
        ))
        self.assertEqual(suites, {"A": 2, "Root/Nested": 2})

    def test_excludes_whole_suites_and_single_tests(self):
        suites = module.suites_from(
            enumeration("ProwlTests/A/one()", "ProwlTests/A/two()", "ProwlTests/B/one()"),
            excluded=["ProwlTests/A/two()", "ProwlTests/B"],
        )
        self.assertEqual(suites, {"A": 1})

    def test_excluding_a_parent_suite_excludes_its_nested_suites(self):
        suites = module.suites_from(
            enumeration("ProwlTests/Root/Nested/one()", "ProwlTests/Other/two()"),
            excluded=["ProwlTests/Root"],
        )
        self.assertEqual(suites, {"Other": 1})

    def test_prefix_of_a_suite_name_excludes_nothing(self):
        suites = module.suites_from(enumeration("ProwlTests/AB/one()"), excluded=["ProwlTests/A"])
        self.assertEqual(suites, {"AB": 1})

    def test_every_suite_lands_in_exactly_one_shard(self):
        suites = {f"S{index}": index + 1 for index in range(23)}
        shards = module.partition(suites, {}, 4)
        assigned = [suite for shard in shards for suite in shard]
        self.assertEqual(sorted(assigned), sorted(suites))

    def test_balances_by_cost_not_by_test_count(self):
        shards = module.partition({"Slow": 1, "A": 100, "B": 100}, {"Slow": 30.0}, 2)
        self.assertIn(["Slow"], shards)

    def test_an_unknown_suite_costs_by_its_test_count(self):
        shards = module.partition({"New": 1000, "A": 1, "B": 1}, {}, 2)
        self.assertIn(["New"], shards)

    def test_partition_does_not_depend_on_input_order(self):
        forward = {"A": 1, "B": 1, "C": 1, "D": 1}
        backward = dict(reversed(list(forward.items())))
        self.assertEqual(module.partition(forward, {}, 2), module.partition(backward, {}, 2))

    def test_more_shards_than_suites_leaves_no_empty_shard(self):
        self.assertEqual(module.partition({"A": 1}, {}, 4), [["A"]])

    def test_rejects_an_enumeration_with_errors(self):
        with self.assertRaises(ValueError):
            module.suites_from({"errors": ["boom"], "values": []})

    def test_rejects_an_empty_enumeration(self):
        with self.assertRaises(ValueError):
            module.suites_from(enumeration())

    def test_writes_arguments_and_the_expected_count_of_each_shard(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "tests.json"
            source.write_text(json.dumps(enumeration("ProwlTests/A/one()", "ProwlTests/A/two()", "ProwlTests/B/one()")))
            costs = root / "costs.json"
            costs.write_text("{}")
            excluded = root / "excluded.txt"
            excluded.write_text("ProwlTests/A/two()\n")
            output = root / "out"
            count = module.main([
                "--enumeration", str(source), "--costs", str(costs), "--excluded", str(excluded),
                "--shards", "2", "--out", str(output),
            ])
            self.assertEqual(count, 2)
            lines = sorted((output / f"shard{index}.args").read_text() for index in range(2))
            self.assertEqual(lines, ["-only-testing:ProwlTests/A\n", "-only-testing:ProwlTests/B\n"])
            self.assertEqual(sorted((output / f"shard{index}.count").read_text() for index in range(2)), ["1\n", "1\n"])


if __name__ == "__main__":
    unittest.main()
