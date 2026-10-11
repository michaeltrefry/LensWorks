"""Deliver the checked-in S47 screenshot limits through Xcode's host environment."""
import json
import math
import os
from pathlib import Path


def load_declared_environment(path):
    with Path(path).open(encoding="utf-8") as source:
        record = json.load(source)
    if record.get("schema") != "lensworks.s47.same-host-screenshot-tolerance.v4" or record.get("status") != "MEASURED_DECLARED_PENDING_FRESH_ACCEPTANCE":
        raise ValueError("S47 requires a source-declared measured tolerance")
    result = record.get("result")
    if not isinstance(result, dict):
        raise ValueError("S47 declared limits are missing")
    delta = result.get("maximumChannelDelta")
    fraction = result.get("maximumChangedPixelFraction")
    if type(delta) is not int or not 0 <= delta <= 255:
        raise ValueError("S47 channel limit must be an integer byte")
    if type(fraction) not in (int, float) or not math.isfinite(fraction) or not 0 <= fraction <= 1:
        raise ValueError("S47 changed-pixel fraction must be finite and within zero to one")
    return {
        "TEST_RUNNER_LW_S47_MAX_CHANNEL_DELTA": str(delta),
        "TEST_RUNNER_LW_S47_MAX_CHANGED_PIXEL_FRACTION": repr(float(fraction)),
    }


def publish_github_environment(tolerance_path, environment_path):
    values = load_declared_environment(tolerance_path)
    with Path(environment_path).open("a", encoding="utf-8") as target:
        target.write("".join(f"{name}={value}\n" for name, value in values.items()))


if __name__ == "__main__":
    repository = Path(__file__).resolve().parents[2]
    publish_github_environment(repository / "S47_SCREENSHOT_TOLERANCE.json", os.environ["GITHUB_ENV"])
