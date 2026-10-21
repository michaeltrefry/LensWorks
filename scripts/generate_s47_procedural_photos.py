#!/usr/bin/env python3
"""Create deterministic, license-free S47 photo fixtures without external assets."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import struct
import zlib

WIDTH, HEIGHT, PANORAMA_OVERLAP_PIXELS = 160, 120, 48
FRAME_SCHEMA = "lensworks.s47.procedural-photo-fixtures.v2"
SUBJECT_HALF_WIDTH = 9
SUBJECT_TOP, SUBJECT_BOTTOM = 46, 93


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


def _write(output: Path, path: str, data: bytes, record: dict) -> None:
    destination = output / path
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(data)
    record.update({"path": path, "sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data), "width": WIDTH, "height": HEIGHT})


# The S47 tours both display one working-version folder path, so the default prepares that one folder; the
# fixture owner moves it aside after the first tour and recreates it empty before the second.
DEFAULT_WORKING_FOLDERS = ("WorkingVersions",)


def _working_folder_names(names: tuple[str, ...]) -> tuple[str, ...]:
    if not names or len(set(names)) != len(names):
        raise ValueError("working folders must be distinct and at least one")
    for name in names:
        if not name or name in (".", "..") or "/" in name or "\\" in name or "\0" in name:
            raise ValueError("each working folder must be one plain path component")
    return names


def generate(output: Path, seed: int, catalog_directory: Path | None = None, working_folders: tuple[str, ...] = DEFAULT_WORKING_FOLDERS) -> dict:
    if not 0 <= seed <= 0xFFFFFFFF:
        raise ValueError("seed must be an unsigned 32-bit integer")
    working_folders = _working_folder_names(tuple(working_folders))
    if output.exists():
        raise ValueError("output must be a new directory")
    output.mkdir(parents=True)
    for name in working_folders:
        folder = output / name
        folder.mkdir(mode=0o700)
        folder.chmod(0o700)  # exact private mode whatever the umask
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
    (output / "fixture-manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    return manifest


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--seed", type=int, required=True)
    parser.add_argument("--catalog-directory", type=Path)
    parser.add_argument("--working-folder", action="append", dest="working_folders",
                        help="empty private (0700) working folder to prepare under --output; repeatable (default: WorkingVersions)")
    args = parser.parse_args()
    manifest = generate(args.output.absolute(), args.seed, args.catalog_directory, tuple(args.working_folders or DEFAULT_WORKING_FOLDERS))
    print(json.dumps({"schema": manifest["schema"], "photo_count": len(manifest["photos"]), "manifest": str(args.output.absolute() / "fixture-manifest.json")}, sort_keys=True))


if __name__ == "__main__":
    main()
