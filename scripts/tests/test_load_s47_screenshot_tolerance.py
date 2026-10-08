import copy
import json
from pathlib import Path
import tempfile
import unittest

from scripts.ci.load_s47_screenshot_tolerance import load_declared_environment, publish_github_environment


class S47DeclaredToleranceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.record = {"schema": "lensworks.s47.same-host-screenshot-tolerance.v4", "status": "MEASURED_DECLARED_PENDING_FRESH_ACCEPTANCE", "result": {"maximumChannelDelta": 191, "maximumChangedPixelFraction": 665 / 1729728}}

    def write_record(self, record):
        path = self.root / "tolerance.json"
        path.write_text(json.dumps(record), encoding="utf-8")
        return path

    def test_declared_values_preserve_exact_double_and_xcode_transport(self):
        values = load_declared_environment(self.write_record(self.record))
        self.assertEqual(set(values), {"TEST_RUNNER_LW_S47_MAX_CHANNEL_DELTA", "TEST_RUNNER_LW_S47_MAX_CHANGED_PIXEL_FRACTION"})
        self.assertEqual(int(values["TEST_RUNNER_LW_S47_MAX_CHANNEL_DELTA"]), self.record["result"]["maximumChannelDelta"])
        self.assertEqual(float(values["TEST_RUNNER_LW_S47_MAX_CHANGED_PIXEL_FRACTION"]), self.record["result"]["maximumChangedPixelFraction"])

    def test_unmeasured_missing_and_malformed_limits_are_refused(self):
        invalid = []
        for status in ["UNMEASURED_SOURCE_PROPOSAL", None]:
            record = copy.deepcopy(self.record)
            record["status"] = status
            invalid.append(record)
        record = copy.deepcopy(self.record)
        record["result"] = None
        invalid.append(record)
        for field, values in [("maximumChannelDelta", [True, "191", -1, 256, 191.5]), ("maximumChangedPixelFraction", [True, "0.1", -0.1, 1.1, float("nan"), float("inf")])]:
            for value in values:
                record = copy.deepcopy(self.record)
                record["result"][field] = value
                invalid.append(record)
        for record in invalid:
            with self.subTest(record=record), self.assertRaises(ValueError):
                load_declared_environment(self.write_record(record))

    def test_invalid_input_never_publishes_and_malformed_json_is_refused(self):
        record = copy.deepcopy(self.record)
        record["result"]["maximumChannelDelta"] = 256
        output = self.root / "github.env"
        with self.assertRaises(ValueError):
            publish_github_environment(self.write_record(record), output)
        self.assertFalse(output.exists())
        source = self.root / "malformed.json"
        source.write_text("{", encoding="utf-8")
        with self.assertRaises(json.JSONDecodeError):
            load_declared_environment(source)

    def test_github_environment_append_preserves_prior_records(self):
        output = self.root / "github.env"
        output.write_text("PRESERVED=existing\n", encoding="utf-8")
        publish_github_environment(self.write_record(self.record), output)
        lines = output.read_text(encoding="utf-8").splitlines()
        self.assertEqual(lines[0], "PRESERVED=existing")
        self.assertEqual(lines[1:], [f"{key}={value}" for key, value in load_declared_environment(self.root / "tolerance.json").items()])
