#!/usr/bin/env python3
"""Create deterministic, license-free S47 photo fixtures without external assets."""
from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
import struct
import zlib

WIDTH, HEIGHT, PANORAMA_OVERLAP_PIXELS = 160, 120, 48
FRAME_SCHEMA = "lensworks.s47.procedural-photo-fixtures.v2"
SUBJECT_HALF_WIDTH = 9
SUBJECT_TOP, SUBJECT_BOTTOM = 46, 93


# The rotated-camera panorama set (S44): one procedural scene on the sphere of directions, seen by
# a pinhole camera that only rotates between frames, so every frame's rotation is ground truth.
ROTATION_WIDTH, ROTATION_HEIGHT, ROTATION_FOCAL_PIXELS = 320, 240, 300.0
# name, yaw, pitch and roll in degrees: a hand-held sweep, about half of each frame overlapping the next.
ROTATION_VIEWS = (("left", -27.0, 1.5, 0.8), ("center", 0.0, 0.0, 0.0), ("right", 28.0, -1.0, -0.6))
# The exposure series: each frame's exposure in stops, and the lens falloff 1 - k * (r / half diagonal)^2.
ROTATION_EXPOSURE_STOPS = (-0.6, 0.0, 0.5)
ROTATION_VIGNETTING = 0.3
ROTATION_SCHEMA = "lensworks.s44.rotation-panorama-fixtures.v1"


def _chunk(kind: bytes, data: bytes) -> bytes:
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)


def _png(width: int, height: int, rows: list[bytes]) -> bytes:
    if len(rows) != height or any(len(row) != width * 3 for row in rows):
        raise ValueError("invalid RGB dimensions")
    raw = b"".join(b"\0" + row for row in rows)
    return b"\x89PNG\r\n\x1a\n" + _chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)) + _chunk(b"IDAT", zlib.compress(raw, 9)) + _chunk(b"IEND", b"")


def _mix(seed: int, x: int, y: int) -> int:
    value = (seed ^ (x * 0x9E3779B1) ^ (y * 0x85EBCA77)) & 0xFFFFFFFF
    value ^= value >> 16
    value = (value * 0x7FEB352D) & 0xFFFFFFFF
    value ^= value >> 15
    value = (value * 0x846CA68B) & 0xFFFFFFFF
    return (value ^ (value >> 16)) & 0xFFFFFFFF


def _even(value: int) -> int:
    return value & ~1


def _background_pixel(seed: int, world_x: int, y: int) -> tuple[int, int, int]:
    """Stable world-space scenery. Every channel is even and <= 126 for exact ±1 EV checks."""
    noise = _mix(seed, world_x, y)
    horizon = 38 + ((noise >> 27) & 14)
    if y < horizon:
        return (
            _even(28 + (world_x * 48 // 384) + ((noise >> 3) & 6)),
            _even(50 + (y * 32 // max(1, horizon)) + ((noise >> 11) & 6)),
            _even(84 + (world_x * 36 // 384) + ((noise >> 19) & 6)),
        )
    return (
        _even(18 + ((noise >> 2) & 18)),
        _even(30 + ((noise >> 10) & 22)),
        _even(20 + ((noise >> 18) & 14)),
    )


def _subject_pixel(world_x: int, y: int, subject_x: int) -> tuple[int, int, int] | None:
    if abs(world_x - subject_x) <= SUBJECT_HALF_WIDTH and SUBJECT_TOP <= y <= SUBJECT_BOTTOM:
        return (220, 68 + (y % 22), 36)
    return None


def _quantized_exposure(channel: int, stops: int) -> int:
    if not 0 <= channel <= 255:
        raise ValueError("RGB8 channel is outside its declared range")
    if stops == -1:
        return channel // 2
    if stops == 0:
        return channel
    if stops == 1:
        return min(255, channel * 2)
    raise ValueError("S47 only declares -1, 0, and +1 EV bracket frames")


def _pixel(seed: int, x: int, y: int, *, stops: int, subject_x: int, panorama_x: int) -> tuple[int, int, int]:
    world_x = x + panorama_x
    base = _subject_pixel(world_x, y, subject_x) or _background_pixel(seed, world_x, y)
    return tuple(_quantized_exposure(channel, stops) for channel in base)


def _frame(seed: int, *, stops: int = 0, subject_x: int = 80, panorama_x: int = 0) -> bytes:
    rows = []
    for y in range(HEIGHT):
        row = bytearray()
        for x in range(WIDTH):
            row.extend(_pixel(seed, x, y, stops=stops, subject_x=subject_x, panorama_x=panorama_x))
        rows.append(bytes(row))
    return _png(WIDTH, HEIGHT, rows)


def _write(output: Path, path: str, data: bytes, record: dict, width: int = WIDTH, height: int = HEIGHT) -> None:
    destination = output / path
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(data)
    record.update({"path": path, "sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data), "width": width, "height": height})


def rotation_matrix(yaw: float, pitch: float, roll: float) -> list[list[float]]:
    """Camera-to-world rotation for angles in degrees: yaw about y (down), then pitch about x (right), then roll about z (forward)."""
    cy, sy = math.cos(math.radians(yaw)), math.sin(math.radians(yaw))
    cp, sp = math.cos(math.radians(pitch)), math.sin(math.radians(pitch))
    cr, sr = math.cos(math.radians(roll)), math.sin(math.radians(roll))
    yaw_m = [[cy, 0.0, sy], [0.0, 1.0, 0.0], [-sy, 0.0, cy]]
    pitch_m = [[1.0, 0.0, 0.0], [0.0, cp, -sp], [0.0, sp, cp]]
    roll_m = [[cr, -sr, 0.0], [sr, cr, 0.0], [0.0, 0.0, 1.0]]

    def mul(a, b):
        return [[sum(a[i][k] * b[k][j] for k in range(3)) for j in range(3)] for i in range(3)]

    return mul(mul(yaw_m, pitch_m), roll_m)


def _smooth(edge_low: float, edge_high: float, value: float) -> float:
    t = min(1.0, max(0.0, (value - edge_low) / (edge_high - edge_low)))
    return t * t * (3.0 - 2.0 * t)


def _shape_layer(seed: int, longitude: float, latitude: float, cell: float, softness: float) -> tuple[float, int]:
    """Coverage in [0, 1] of the one soft-edged shape (disc or turned square) owned by this cell, and the cell's hash."""
    column, row = math.floor(longitude / cell), math.floor(latitude / cell)
    noise = _mix(seed, column, row)
    centre_x = (column + 0.32 + 0.36 * ((noise & 0xFF) / 255.0)) * cell
    centre_y = (row + 0.32 + 0.36 * (((noise >> 8) & 0xFF) / 255.0)) * cell
    radius = cell * (0.14 + 0.14 * (((noise >> 16) & 0xFF) / 255.0))
    dx, dy = longitude - centre_x, latitude - centre_y
    if noise & 0x1000000:
        angle = ((noise >> 25) & 0x3F) / 63.0 * math.pi / 2
        c, s = math.cos(angle), math.sin(angle)
        distance = max(abs(c * dx + s * dy), abs(c * dy - s * dx))
    else:
        distance = math.hypot(dx, dy)
    return 1.0 - _smooth(radius - softness, radius + softness, distance), noise


def scene_radiance(seed: int, direction: tuple[float, float, float]) -> tuple[float, float, float]:
    """Linear scene-referred sRGB radiance, within [0.06, 0.6], seen along a world direction (x right, y down, z forward)."""
    x, y, z = direction
    longitude = math.degrees(math.atan2(x, z))
    latitude = math.degrees(math.atan2(y, math.hypot(x, z)))
    ground = _smooth(-6.0, 6.0, latitude + 3.0 * math.sin(math.radians(longitude * 3.0)))
    wave = 0.5 + 0.5 * math.sin(math.radians(longitude * 2.3 + latitude * 1.1))
    red = 0.16 + 0.10 * ground + 0.05 * wave
    green = 0.22 + 0.04 * ground + 0.04 * (1.0 - wave)
    blue = 0.34 - 0.20 * ground + 0.04 * wave
    large, noise = _shape_layer(seed, longitude, latitude, 4.0, 0.3)
    if large > 0.0:
        tint = (0.08 + 0.50 * ((noise >> 3) & 0x1F) / 31.0, 0.08 + 0.50 * ((noise >> 11) & 0x1F) / 31.0, 0.08 + 0.50 * ((noise >> 19) & 0x1F) / 31.0)
        red, green, blue = red + (tint[0] - red) * large, green + (tint[1] - green) * large, blue + (tint[2] - blue) * large
    small, noise = _shape_layer(seed ^ 0x5A17C3D1, longitude, latitude, 2.2, 0.3)
    if small > 0.0:
        level = 0.07 if noise & 0x20000000 else 0.58
        red, green, blue = red + (level - red) * small * 0.8, green + (level - green) * small * 0.8, blue + (level - blue) * small * 0.8
    return (min(0.6, max(0.06, red)), min(0.6, max(0.06, green)), min(0.6, max(0.06, blue)))


def _srgb8(linear: float) -> int:
    value = min(1.0, max(0.0, linear))
    encoded = value * 12.92 if value <= 0.0031308 else 1.055 * value ** (1 / 2.4) - 0.055
    return int(round(encoded * 255.0))


def _rotation_frame(seed: int, rotation: list[list[float]], stops: float, vignetting: float) -> bytes:
    """One pinhole view of the scene: principal point at the frame centre, sRGB-encoded RGB8."""
    width, height, focal = ROTATION_WIDTH, ROTATION_HEIGHT, ROTATION_FOCAL_PIXELS
    centre_x, centre_y = (width - 1) / 2.0, (height - 1) / 2.0
    corner = centre_x * centre_x + centre_y * centre_y
    gain = 2.0 ** stops
    rows = []
    for y in range(height):
        row = bytearray()
        v = (y - centre_y) / focal
        for x in range(width):
            u = (x - centre_x) / focal
            direction = tuple(rotation[i][0] * u + rotation[i][1] * v + rotation[i][2] for i in range(3))
            falloff = 1.0 - vignetting * ((x - centre_x) ** 2 + (y - centre_y) ** 2) / corner
            row.extend(_srgb8(channel * gain * falloff) for channel in scene_radiance(seed, direction))
        rows.append(bytes(row))
    return _png(width, height, rows)


def generate_rotation_panorama(output: Path, seed: int) -> dict:
    """Write the two three-frame rotated-camera series under `rotation-panorama/` and return their manifest section."""
    records = []
    for series, exposures, vignetting in (("plain", (0.0, 0.0, 0.0), 0.0), ("exposure", ROTATION_EXPOSURE_STOPS, ROTATION_VIGNETTING)):
        for index, ((name, yaw, pitch, roll), stops) in enumerate(zip(ROTATION_VIEWS, exposures, strict=True)):
            rotation = rotation_matrix(yaw, pitch, roll)
            record = {
                "kind": "rotation-panorama", "series": series, "index": index, "scene_seed": seed,
                "yaw_degrees": yaw, "pitch_degrees": pitch, "roll_degrees": roll,
                "camera_to_world": [value for row in rotation for value in row],
                "exposure_stops": stops, "vignetting": vignetting,
            }
            _write(output, f"rotation-panorama/{series}-{name}.png", _rotation_frame(seed, rotation, stops, vignetting), record, ROTATION_WIDTH, ROTATION_HEIGHT)
            records.append(record)
    return {
        "schema": ROTATION_SCHEMA,
        "parameters": {
            "width": ROTATION_WIDTH, "height": ROTATION_HEIGHT, "focal_pixels": ROTATION_FOCAL_PIXELS,
            "principal_point": [(ROTATION_WIDTH - 1) / 2.0, (ROTATION_HEIGHT - 1) / 2.0],
            "camera": "pinhole; world direction = camera_to_world (row-major) x ((x - cx) / f, (y - cy) / f, 1), with x right, y down, z forward",
            "encoding": "PNG RGB8 filter-none zlib9, sRGB transfer of linear scene radiance x 2^exposure_stops x falloff",
            "falloff": "1 - vignetting x (distance from the principal point / distance to the corner)^2",
            "scene_radiance_range": [0.06, 0.6],
        },
        "photos": records,
    }


def generate(output: Path, seed: int, catalog_directory: Path | None = None, rotation_panorama: bool = False) -> dict:
    if not 0 <= seed <= 0xFFFFFFFF:
        raise ValueError("seed must be an unsigned 32-bit integer")
    if output.exists():
        raise ValueError("output must be a new directory")
    output.mkdir(parents=True)
    for run in (1, 2):
        (output / f"WorkingVersions-{run}").mkdir(mode=0o700)
    records: list[dict] = []
    for index, name in enumerate(("single-harbor.png", "single-garden.png")):
        record = {"kind": "single", "seed": seed, "scene_seed": seed, "index": index, "subject_x": 53 + index * 38}
        _write(output, f"photos/{name}", _frame(seed, subject_x=record["subject_x"]), record)
        records.append(record)
    bracket_subjects = (55, 79, 103)
    for index, (stops, subject_x) in enumerate(zip((-1, 0, 1), bracket_subjects, strict=True)):
        record = {
            "kind": "exposure-bracket", "series": "moving-subject", "index": index,
            "exposure_stops": stops, "exposure_scale": 2 ** stops,
            "subject_x": subject_x, "subject_bounds": [subject_x - SUBJECT_HALF_WIDTH, SUBJECT_TOP, subject_x + SUBJECT_HALF_WIDTH, SUBJECT_BOTTOM],
            "scene_seed": seed, "motion": "only the subject position differs across the series",
        }
        _write(output, f"photos/bracket-moving-{index + 1}.png", _frame(seed, stops=stops, subject_x=subject_x), record)
        records.append(record)
    for index, name in enumerate(("left", "center", "right")):
        panorama_x = index * (WIDTH - PANORAMA_OVERLAP_PIXELS)
        record = {
            "kind": "panorama", "series": "overlap", "index": index, "panorama_x": panorama_x,
            "overlap_pixels": PANORAMA_OVERLAP_PIXELS, "scene_seed": seed,
            "camera": "world-space crop; scene pixels are shared by overlapping crops",
        }
        _write(output, f"photos/panorama-{name}.png", _frame(seed, subject_x=352, panorama_x=panorama_x), record)
        records.append(record)
    manifest = {
        "schema": FRAME_SCHEMA,
        "license": {"spdx": "CC0-1.0", "statement": "Pixels are generated from this checked-in algorithm; no external image, model, or download is used."},
        "seed": seed,
        "parameters": {
            "width": WIDTH, "height": HEIGHT, "panorama_overlap_pixels": PANORAMA_OVERLAP_PIXELS,
            "encoding": "PNG RGB8 filter-none zlib9", "bracket_exposure_encoding": "linear_scale=2^exposure_stops; RGB8 uses floor(channel/2) at -1 EV and saturating channel*2 at +1 EV",
            "subject_bounds_encoding": "[min_x,min_y,max_x,max_y] inclusive",
        },
        "photos": records,
        "demo_catalog": None if catalog_directory is None else {"catalog_directory": str(catalog_directory.absolute()), "creation": "LensWorks UI tour passes --lensworks-create-catalog; the generator does not create a catalog database."},
        "acceptance_state": "SOURCE_ONLY_NOT_GENERATED_OR_UI_VALIDATED",
    }
    if rotation_panorama:
        manifest["rotation_panorama"] = generate_rotation_panorama(output, seed)
    (output / "fixture-manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    return manifest


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--seed", type=int, required=True)
    parser.add_argument("--catalog-directory", type=Path)
    parser.add_argument("--rotation-panorama", action="store_true", help="also write the rotated-camera panorama series (S44) under rotation-panorama/")
    args = parser.parse_args()
    manifest = generate(args.output.absolute(), args.seed, args.catalog_directory, args.rotation_panorama)
    print(json.dumps({"schema": manifest["schema"], "photo_count": len(manifest["photos"]), "manifest": str(args.output.absolute() / "fixture-manifest.json")}, sort_keys=True))


if __name__ == "__main__":
    main()
