import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from scripts.ci.export_s47_tour_capture import DOMAIN_SCHEMA, TOUR_SCHEMA, publish, select_capture

PNG = b"\x89PNG\r\n\x1a\n" + b"capture"


class S47TourCaptureExportTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def exported(self, files):
        directory = self.root / "exported"
        directory.mkdir()
        attachments = []
        for index, data in enumerate(files):
            name = f"{index}.bin"
            (directory / name).write_bytes(data)
            attachments.append({"exportedFileName": name, "suggestedHumanReadableName": name, "isAssociatedWithFailure": False})
        (directory / "manifest.json").write_text(json.dumps([{"testIdentifier": "CompositorUITests/tour()", "attachments": attachments}]))
        return directory

    @staticmethod
    def domain(run, png=PNG):
        return json.dumps({"schema": DOMAIN_SCHEMA, "run": run, "pngSHA256": hashlib.sha256(png).hexdigest()}).encode()

    @staticmethod
    def tour(run):
        return json.dumps({"schema": TOUR_SCHEMA, "run": run, "originalHashes": {}}).encode()

    def test_selects_the_runs_records_and_the_png_by_its_declared_digest(self):
        other = b"\x89PNG\r\n\x1a\n" + b"other"
        exported = self.exported([other, self.domain(1), self.tour(1), PNG, b"not json"])
        self.assertEqual(select_capture(exported, 1), (PNG, self.domain(1), self.tour(1)))

    def test_missing_ambiguous_or_mismatched_attachments_fail(self):
        cases = [
            [self.tour(1), PNG],
            [self.domain(1), PNG],
            [self.domain(1), self.domain(1), self.tour(1), PNG],
            [self.domain(1), self.tour(1), self.tour(1), PNG],
            [self.domain(2), self.tour(2), PNG],
            [self.domain(1), self.tour(1)],
            [self.domain(1), self.tour(1), PNG, PNG],
            [self.domain(1, b"capture"), self.tour(1), b"capture"],
        ]
        for files in cases:
            with self.subTest(files=files):
                exported = self.exported(files)
                with self.assertRaises(ValueError):
                    select_capture(exported, 1)
                for path in exported.iterdir():
                    path.unlink()
                exported.rmdir()

    def test_publish_writes_exclusively_into_a_real_owner_directory(self):
        captures = self.root / "captures"
        captures.mkdir(mode=0o700)
        publish(captures, 2, PNG, self.domain(2), self.tour(2))
        self.assertEqual((captures / "run-2.png").read_bytes(), PNG)
        self.assertEqual((captures / "run-2-domain.json").read_bytes(), self.domain(2))
        self.assertEqual((captures / "run-2-tour.json").read_bytes(), self.tour(2))
        with self.assertRaises(FileExistsError):
            publish(captures, 2, PNG, self.domain(2), self.tour(2))
        link = self.root / "link"
        link.symlink_to(captures)
        with self.assertRaises(ValueError):
            publish(link, 1, PNG, self.domain(1), self.tour(1))


if __name__ == "__main__":
    unittest.main()
