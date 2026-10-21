"""Retain one S47 tour's editor capture, outside its result bundle, for the two-tour comparison.

Each S47 tour runs in its own `xcodebuild` invocation so that both tours can use one working-version folder path
(the fixture owner moves the used folder aside and recreates it empty in between; the sandboxed UI runner cannot).
The tour attaches its capture PNG, its typed window-domain record and its tour record to its result bundle. This
script exports exactly those three attachments from that exact bundle and publishes them, each written exclusively,
as `run-<N>.png`, `run-<N>-domain.json` and `run-<N>-tour.json` under the capture root that the comparison test reads.

The PNG is selected by content, never by name: it must be the one attachment whose SHA-256 the run's domain record
names. Missing, ambiguous or mismatched attachments fail.

usage: export_s47_tour_capture.py <result-bundle> <run> <capture-root>
"""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

DOMAIN_SCHEMA = "lensworks.s47.editor-window-capture-domain.v1"
TOUR_SCHEMA = "lensworks.s47.tour-record.v1"


def _attachment_files(exported):
    manifest = json.loads((exported / "manifest.json").read_text(encoding="utf-8"))
    if not isinstance(manifest, list):
        raise ValueError("the attachment manifest must be a list of tests")
    files = []
    for test in manifest:
        for attachment in test.get("attachments", []):
            name = attachment.get("exportedFileName")
            if not isinstance(name, str) or not name or "/" in name or name in (".", ".."):
                raise ValueError(f"unexpected exported attachment name {name!r}")
            path = exported / name
            if path.is_symlink() or not path.is_file():
                raise ValueError(f"exported attachment {name} is not a regular file")
            files.append(path)
    return files


def _json_record(data):
    try:
        record = json.loads(data)
    except (UnicodeDecodeError, ValueError):
        return None
    return record if isinstance(record, dict) else None


def select_capture(exported, run):
    """Return (png, domain, tour) bytes for `run` from an exported attachments directory."""
    files = [(path, path.read_bytes()) for path in _attachment_files(Path(exported))]
    domains, tours = [], []
    for _, data in files:
        record = _json_record(data)
        if record is None or record.get("run") != run or type(record.get("run")) is not int:
            continue
        if record.get("schema") == DOMAIN_SCHEMA:
            domains.append((record, data))
        elif record.get("schema") == TOUR_SCHEMA:
            tours.append(data)
    if len(domains) != 1 or len(tours) != 1:
        raise ValueError(f"tour {run} must retain exactly one domain record and one tour record, found {len(domains)} and {len(tours)}")
    domain, domain_bytes = domains[0]
    digest = domain.get("pngSHA256")
    if not isinstance(digest, str) or len(digest) != 64:
        raise ValueError(f"tour {run} domain record names no capture digest")
    pngs = [data for _, data in files if hashlib.sha256(data).hexdigest() == digest]
    if len(pngs) != 1 or not pngs[0].startswith(b"\x89PNG\r\n\x1a\n"):
        raise ValueError(f"tour {run} must retain exactly one PNG capture whose SHA-256 is {digest}, found {len(pngs)}")
    return pngs[0], domain_bytes, tours[0]


def publish(capture_root, run, png, domain, tour):
    root = Path(capture_root)
    if root.is_symlink() or not root.is_dir():
        raise ValueError("the capture root must be a real directory prepared by the fixture owner")
    for name, data in ((f"run-{run}.png", png), (f"run-{run}-domain.json", domain), (f"run-{run}-tour.json", tour)):
        with (root / name).open("xb") as target:
            target.write(data)


def export(bundle, run, capture_root):
    with tempfile.TemporaryDirectory() as scratch:
        exported = Path(scratch) / "attachments"
        subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", str(bundle), "--output-path", str(exported)], check=True)
        publish(capture_root, run, *select_capture(exported, run))


if __name__ == "__main__":
    if len(sys.argv) != 4 or sys.argv[2] not in ("1", "2"):
        sys.exit("usage: export_s47_tour_capture.py <result-bundle> <1|2> <capture-root>")
    export(Path(sys.argv[1]), int(sys.argv[2]), Path(sys.argv[3]))
