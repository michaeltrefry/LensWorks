import hashlib
import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest
import zlib

MODULE = Path(__file__).parents[1] / "generate_s47_procedural_photos.py"
spec = importlib.util.spec_from_file_location("s47", MODULE)
s47 = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(s47)


def file_hashes(root):
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(root.rglob("*.png"))}


def rgb8_png(path):
    data = Path(path).read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise AssertionError("not PNG")
    position, chunks = 8, {}
    while position < len(data):
        length = struct.unpack(">I", data[position:position + 4])[0]
        kind = data[position + 4:position + 8]
        payload = data[position + 8:position + 8 + length]
        chunks.setdefault(kind, []).append(payload)
        position += 12 + length
    width, height, depth, color, compression, filtering, interlace = struct.unpack(">IIBBBBB", chunks[b"IHDR"][0])
    if (depth, color, compression, filtering, interlace) != (8, 2, 0, 0, 0):
        raise AssertionError("expected non-interlaced RGB8 PNG")
    raw = zlib.decompress(b"".join(chunks[b"IDAT"]))
    rows, stride = [], width * 3
    for row in range(height):
        start = row * (stride + 1)
        if raw[start] != 0:
            raise AssertionError("expected filter-none rows")
        rows.append(raw[start + 1:start + 1 + stride])
    return width, height, rows


def pixel(rows, x, y):
    start = x * 3
    return tuple(rows[y][start:start + 3])


class ProceduralS47FixtureTests(unittest.TestCase):
    def test_same_seed_and_parameters_produce_byte_identical_photos_and_manifest(self):
        with tempfile.TemporaryDirectory() as parent:
            first, second = Path(parent) / "first", Path(parent) / "second"
            one, two = s47.generate(first, 25317), s47.generate(second, 25317)
            self.assertEqual(file_hashes(first), file_hashes(second))
            self.assertEqual(one["parameters"], two["parameters"])
            self.assertEqual(len(one["photos"]), 8)

    def test_different_seed_changes_every_photo_without_changing_the_contract_shape(self):
        with tempfile.TemporaryDirectory() as parent:
            first, second = Path(parent) / "first", Path(parent) / "second"
            one, two = s47.generate(first, 25317), s47.generate(second, 25318)
            a, b = file_hashes(first), file_hashes(second)
            self.assertEqual(a.keys(), b.keys())
            self.assertEqual(len(a), 8)
            for name in a:
                self.assertNotEqual(a[name], b[name], name)
            self.assertEqual([entry["kind"] for entry in one["photos"]], [entry["kind"] for entry in two["photos"]])

    def test_manifest_declares_license_free_bracket_panorama_and_optional_catalog_launch_target(self):
        with tempfile.TemporaryDirectory() as parent:
            output, catalog = Path(parent) / "fixtures", Path(parent) / "Demo.catalog"
            manifest = s47.generate(output, 7, catalog)
            parsed = json.loads((output / "fixture-manifest.json").read_text())
            self.assertEqual(manifest, parsed)
            self.assertEqual(parsed["license"]["spdx"], "CC0-1.0")
            self.assertEqual(sum(entry["kind"] == "exposure-bracket" for entry in parsed["photos"]), 3)
            self.assertEqual(sum(entry["kind"] == "panorama" for entry in parsed["photos"]), 3)
            self.assertEqual(parsed["demo_catalog"]["catalog_directory"], str(catalog.absolute()))
            # Both S47 tours use this one folder path; the fixture owner recreates it empty between them.
            working = output / "WorkingVersions"
            self.assertTrue(working.is_dir())
            self.assertFalse(working.is_symlink())
            self.assertEqual(working.stat().st_mode & 0o7777, 0o700)
            self.assertEqual(list(working.iterdir()), [])
            self.assertEqual(sorted(path.name for path in output.iterdir() if path.name.startswith("WorkingVersions")), ["WorkingVersions"])
            originals = file_hashes(output)
            manifest_bytes = (output / "fixture-manifest.json").read_bytes()
            with self.assertRaisesRegex(ValueError, "output must be a new directory"):
                s47.generate(output, 8, catalog)
            self.assertEqual(file_hashes(output), originals)
            self.assertEqual((output / "fixture-manifest.json").read_bytes(), manifest_bytes)

    def test_requested_working_folders_are_real_empty_private_and_validated_before_any_write(self):
        with tempfile.TemporaryDirectory() as parent:
            output = Path(parent) / "fixtures"
            names = ("WorkingVersions-1", "WorkingVersions-2", "WorkingVersions-3", "WorkingVersions-4")
            s47.generate(output, 25316, working_folders=names)
            self.assertEqual(sorted(path.name for path in output.iterdir() if path.name.startswith("WorkingVersions")), list(names))
            for name in names:
                working = output / name
                self.assertTrue(working.is_dir())
                self.assertFalse(working.is_symlink())
                self.assertEqual(working.stat().st_mode & 0o7777, 0o700)
                self.assertEqual(list(working.iterdir()), [])
            for invalid in [(), ("a", "a"), ("",), (".",), ("..",), ("a/b",), ("a\\b",), ("a\0",)]:
                fresh = Path(parent) / "refused"
                with self.assertRaises(ValueError, msg=repr(invalid)):
                    s47.generate(fresh, 25316, working_folders=invalid)
                self.assertFalse(fresh.exists(), repr(invalid))

    def test_actual_png_layout_and_panorama_overlap_are_validated_from_generated_bytes(self):
        with tempfile.TemporaryDirectory() as parent:
            root = Path(parent) / "fixtures"
            s47.generate(root, 25317)
            left = rgb8_png(root / "photos/panorama-left.png")
            center = rgb8_png(root / "photos/panorama-center.png")
            right = rgb8_png(root / "photos/panorama-right.png")
            self.assertEqual(left[:2], (160, 120))
            self.assertEqual(left[:2], center[:2])
            self.assertEqual(center[:2], right[:2])
            for y in range(120):
                for offset in range(48):
                    self.assertEqual(pixel(left[2], 112 + offset, y), pixel(center[2], offset, y))
                    self.assertEqual(pixel(center[2], 112 + offset, y), pixel(right[2], offset, y))

    def test_actual_bracket_uses_shared_world_with_true_ev_and_subject_only_motion(self):
        with tempfile.TemporaryDirectory() as parent:
            root = Path(parent) / "fixtures"
            manifest = s47.generate(root, 25317)
            bracket = [entry for entry in manifest["photos"] if entry["kind"] == "exposure-bracket"]
            self.assertEqual([entry["exposure_scale"] for entry in bracket], [0.5, 1, 2])
            decoded = [rgb8_png(root / entry["path"])[2] for entry in bracket]
            for y in range(120):
                for x in range(160):
                    inside_subject = any(entry["subject_bounds"][0] <= x <= entry["subject_bounds"][2] and entry["subject_bounds"][1] <= y <= entry["subject_bounds"][3] for entry in bracket)
                    if inside_subject:
                        continue
                    under, middle, over = (pixel(rows, x, y) for rows in decoded)
                    self.assertEqual(tuple(channel * 2 for channel in under), middle)
                    self.assertEqual(tuple(channel * 2 for channel in middle), over)
            for entry, rows in zip(bracket, decoded, strict=True):
                for y in range(120):
                    for x in range(160):
                        actual = pixel(rows, x, y)
                        inside = entry["subject_bounds"][0] <= x <= entry["subject_bounds"][2] and entry["subject_bounds"][1] <= y <= entry["subject_bounds"][3]
                        if inside:
                            source = s47._subject_pixel(x, y, entry["subject_x"])
                            self.assertIsNotNone(source)
                            expected = tuple(s47._quantized_exposure(value, entry["exposure_stops"]) for value in source)
                        else:
                            source = s47._background_pixel(25317, x, y)
                            expected = tuple(s47._quantized_exposure(value, entry["exposure_stops"]) for value in source)
                        self.assertEqual(actual, expected)
                        self.assertTrue(all(isinstance(channel, int) and 0 <= channel <= 255 for channel in actual))
                if entry["exposure_stops"] == 1:
                    self.assertEqual(pixel(rows, entry["subject_x"], s47.SUBJECT_TOP)[0], 255, "foreground +1 EV red must saturate as declared")


if __name__ == "__main__":
    unittest.main()
