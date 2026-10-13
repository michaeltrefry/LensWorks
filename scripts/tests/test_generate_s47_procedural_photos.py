import hashlib
import importlib.util
import json
import math
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
            for run in (1, 2):
                working = output / f"WorkingVersions-{run}"
                self.assertTrue(working.is_dir())
                self.assertFalse(working.is_symlink())
                self.assertEqual(working.stat().st_mode & 0o7777, 0o700)
                self.assertEqual(list(working.iterdir()), [])
            originals = file_hashes(output)
            manifest_bytes = (output / "fixture-manifest.json").read_bytes()
            with self.assertRaisesRegex(ValueError, "output must be a new directory"):
                s47.generate(output, 8, catalog)
            self.assertEqual(file_hashes(output), originals)
            self.assertEqual((output / "fixture-manifest.json").read_bytes(), manifest_bytes)

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


class RotationPanoramaFixtureTests(unittest.TestCase):
    """The S44 rotated-camera set: opt-in, deterministic, and true to its declared camera."""

    def test_the_default_output_is_unchanged_and_the_set_is_only_written_on_request(self):
        with tempfile.TemporaryDirectory() as parent:
            plain, extended = Path(parent) / "plain", Path(parent) / "extended"
            without, with_set = s47.generate(plain, 25322), s47.generate(extended, 25322, rotation_panorama=True)
            self.assertNotIn("rotation_panorama", without)
            self.assertFalse((plain / "rotation-panorama").exists())
            self.assertEqual(without, {key: value for key, value in with_set.items() if key != "rotation_panorama"})
            self.assertEqual(file_hashes(plain), {name: digest for name, digest in file_hashes(extended).items() if name.startswith("photos/")})
            self.assertEqual(json.loads((extended / "fixture-manifest.json").read_text()), with_set)
            section = with_set["rotation_panorama"]
            self.assertEqual(section["schema"], "lensworks.s44.rotation-panorama-fixtures.v1")
            self.assertEqual([(entry["series"], entry["index"]) for entry in section["photos"]], [(series, index) for series in ("plain", "exposure") for index in range(3)])
            self.assertEqual([entry["exposure_stops"] for entry in section["photos"]], [0.0, 0.0, 0.0, -0.6, 0.0, 0.5])
            self.assertEqual([entry["vignetting"] for entry in section["photos"]], [0.0, 0.0, 0.0, 0.3, 0.3, 0.3])
            for entry in section["photos"]:
                data = (extended / entry["path"]).read_bytes()
                self.assertEqual((entry["width"], entry["height"], entry["bytes"]), (320, 240, len(data)))
                self.assertEqual(entry["sha256"], hashlib.sha256(data).hexdigest())
            again = Path(parent) / "again"
            s47.generate(again, 25322, rotation_panorama=True)
            self.assertEqual(file_hashes(extended), file_hashes(again))

    def test_each_declared_rotation_is_a_rotation_built_from_its_angles(self):
        for name, yaw, pitch, roll in s47.ROTATION_VIEWS:
            matrix = s47.rotation_matrix(yaw, pitch, roll)
            for i in range(3):
                for j in range(3):
                    dot = sum(matrix[k][i] * matrix[k][j] for k in range(3))
                    self.assertAlmostEqual(dot, 1.0 if i == j else 0.0, places=12, msg=name)
            forward = [row[2] for row in matrix]
            self.assertAlmostEqual(math.degrees(math.atan2(forward[0], forward[2])), yaw, places=9)
            # Positive pitch turns the camera up: world y points down.
            self.assertAlmostEqual(math.degrees(math.asin(-forward[1])), pitch, places=9)
        self.assertEqual(s47.rotation_matrix(0, 0, 0), [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]])

    def test_actual_frames_show_one_scene_through_the_declared_cameras(self):
        """A world direction seen by two frames has the scene's colour in both, at the pixel the pinhole model gives."""
        with tempfile.TemporaryDirectory() as parent:
            root = Path(parent) / "fixtures"
            section = s47.generate(root, 25322, rotation_panorama=True)["rotation_panorama"]
            focal, (centre_x, centre_y) = section["parameters"]["focal_pixels"], section["parameters"]["principal_point"]
            plain = [entry for entry in section["photos"] if entry["series"] == "plain"]
            decoded = [rgb8_png(root / entry["path"])[2] for entry in plain]

            def direction(entry, x, y):
                m = entry["camera_to_world"]
                u, v = (x - centre_x) / focal, (y - centre_y) / focal
                return tuple(m[i * 3] * u + m[i * 3 + 1] * v + m[i * 3 + 2] for i in range(3))

            def project(entry, d):
                m = entry["camera_to_world"]
                camera = [m[i] * d[0] + m[3 + i] * d[1] + m[6 + i] * d[2] for i in range(3)]
                return focal * camera[0] / camera[2] + centre_x, focal * camera[1] / camera[2] + centre_y

            # Every pixel is the scene along its own ray, sRGB-encoded.
            for entry, rows in zip(plain, decoded, strict=True):
                for y in range(0, 240, 7):
                    for x in range(0, 320, 7):
                        expected = tuple(s47._srgb8(channel) for channel in s47.scene_radiance(25322, direction(entry, x, y)))
                        self.assertEqual(pixel(rows, x, y), expected)
            # Neighbouring frames overlap by about half, and agree where a pixel of one lands on a pixel centre of the other.
            for first, second in ((0, 1), (1, 2)):
                shared = compared = 0
                for y in range(240):
                    for x in range(320):
                        other_x, other_y = project(plain[second], direction(plain[first], x, y))
                        if not (0 <= other_x <= 319 and 0 <= other_y <= 239):
                            continue
                        shared += 1
                        nearest_x, nearest_y = round(other_x), round(other_y)
                        if abs(other_x - nearest_x) < 0.02 and abs(other_y - nearest_y) < 0.02:
                            compared += 1
                            here, there = pixel(decoded[first], x, y), pixel(decoded[second], nearest_x, nearest_y)
                            self.assertLessEqual(max(abs(a - b) for a, b in zip(here, there)), 8, (first, x, y))
                self.assertGreater(shared, 0.4 * 320 * 240)
                self.assertLess(shared, 0.6 * 320 * 240)
                self.assertGreater(compared, 20)

    def test_the_exposure_series_is_the_plain_series_with_declared_gain_and_falloff(self):
        with tempfile.TemporaryDirectory() as parent:
            root = Path(parent) / "fixtures"
            section = s47.generate(root, 25322, rotation_panorama=True)["rotation_panorama"]
            (centre_x, centre_y), focal = section["parameters"]["principal_point"], section["parameters"]["focal_pixels"]
            low, high = section["parameters"]["scene_radiance_range"]
            corner = centre_x ** 2 + centre_y ** 2
            for entry in (photo for photo in section["photos"] if photo["series"] == "exposure"):
                rows, m = rgb8_png(root / entry["path"])[2], entry["camera_to_world"]
                brightest = 0
                for y in range(0, 240, 5):
                    for x in range(0, 320, 5):
                        u, v = (x - centre_x) / focal, (y - centre_y) / focal
                        scene = s47.scene_radiance(25322, tuple(m[i * 3] * u + m[i * 3 + 1] * v + m[i * 3 + 2] for i in range(3)))
                        self.assertTrue(all(low <= channel <= high for channel in scene))
                        falloff = 1 - entry["vignetting"] * ((x - centre_x) ** 2 + (y - centre_y) ** 2) / corner
                        expected = tuple(s47._srgb8(channel * 2 ** entry["exposure_stops"] * falloff) for channel in scene)
                        self.assertEqual(pixel(rows, x, y), expected)
                        brightest = max(brightest, *pixel(rows, x, y))
                # Nothing clips, so the frames differ by exposure alone.
                self.assertLess(brightest, 250)


if __name__ == "__main__":
    unittest.main()
