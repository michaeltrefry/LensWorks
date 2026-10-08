#!/usr/bin/env python3
"""Generate small source fixtures and independent orientation oracles for S04."""
import argparse
import ctypes
import hashlib
import json
from pathlib import Path
import struct
import zlib

SRGB_PROFILE = Path('/System/Library/ColorSync/Profiles/sRGB Profile.icc')


def linear_profile(library_path):
    """Build D65/sRGB-primary gamma-1 ICC; expected conversion uses independent math."""
    class Point(ctypes.Structure):
        _fields_ = [('x', ctypes.c_double), ('y', ctypes.c_double), ('Y', ctypes.c_double)]
    class Primaries(ctypes.Structure):
        _fields_ = [('Red', Point), ('Green', Point), ('Blue', Point)]
    library = ctypes.CDLL(str(library_path))
    library.cmsBuildGamma.argtypes = [ctypes.c_void_p, ctypes.c_double]
    library.cmsBuildGamma.restype = ctypes.c_void_p
    library.cmsFreeToneCurve.argtypes = [ctypes.c_void_p]
    library.cmsCreateRGBProfile.argtypes = [ctypes.POINTER(Point), ctypes.POINTER(Primaries),
                                           ctypes.POINTER(ctypes.c_void_p)]
    library.cmsCreateRGBProfile.restype = ctypes.c_void_p
    library.cmsCloseProfile.argtypes = [ctypes.c_void_p]
    library.cmsSaveProfileToMem.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint32)]
    library.cmsSaveProfileToMem.restype = ctypes.c_int
    curve = library.cmsBuildGamma(None, 1.0)
    if not curve:
        raise RuntimeError('Could not create linear ICC curve')
    profile = None
    try:
        white = Point(0.3127, 0.3290, 1.0)
        primaries = Primaries(Point(0.64, 0.33, 1.0), Point(0.30, 0.60, 1.0), Point(0.15, 0.06, 1.0))
        curves = (ctypes.c_void_p * 3)(curve, curve, curve)
        profile = library.cmsCreateRGBProfile(ctypes.byref(white), ctypes.byref(primaries), curves)
        if not profile:
            raise RuntimeError('Could not create linear RGB ICC profile')
        length = ctypes.c_uint32()
        if not library.cmsSaveProfileToMem(profile, None, ctypes.byref(length)):
            raise RuntimeError('Could not size ICC profile')
        data = ctypes.create_string_buffer(length.value)
        if not library.cmsSaveProfileToMem(profile, data, ctypes.byref(length)):
            raise RuntimeError('Could not serialize ICC profile')
        return data.raw[:length.value]
    finally:
        if profile:
            library.cmsCloseProfile(profile)
        library.cmsFreeToneCurve(curve)


def chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))


def png(orientation, profile):
    # Six distinct patches; independent expected orders are recorded below.
    # Large solid interiors permit JPEG center samples without boundary subsampling artifacts.
    patch = 32
    rows = b''.join(b'\0' + bytes(value for x in range(3 * patch)
                                for value in (((y // patch) * 3 + x // patch + 1) * 30, 0, 0))
                    for y in range(2 * patch))
    exif = b'II*\0\x08\0\0\0\x01\0\x12\x01\x03\0\x01\0\0\0'
    exif += struct.pack('<H', orientation) + bytes(6)
    return (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 3 * patch, 2 * patch, 8, 2, 0, 0, 0))
            + chunk(b'iCCP', b'Source sRGB\0\0' + zlib.compress(profile))
            + chunk(b'eXIf', exif) + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b''))


def generate(destination, profile_path, interruption_count=0, linear_library=None):
    if not 0 <= interruption_count <= 10000:
        raise ValueError('Interruption fixture count must be 0..10000')
    if destination.exists():
        raise ValueError('Fixture destination must be a new directory')
    profile = profile_path.read_bytes()
    if profile != SRGB_PROFILE.read_bytes():
        raise ValueError('The orientation oracle requires the verified system sRGB profile bytes')
    if len(profile) < 128 or profile[36:40] != b'acsp':
        raise ValueError('An actual ICC profile is required')
    destination.mkdir(parents=True)
    orders = ([1, 2, 3, 4, 5, 6], [3, 2, 1, 6, 5, 4], [6, 5, 4, 3, 2, 1],
              [4, 5, 6, 1, 2, 3], [1, 4, 2, 5, 3, 6], [4, 1, 5, 2, 6, 3],
              [6, 3, 5, 2, 4, 1], [3, 6, 2, 5, 1, 4])
    records = []
    for orientation, order in enumerate(orders, 1):
        folder = destination / ('Sources' if orientation <= 2 else
                                'Sources/Nested' if orientation <= 5 else 'Sources/Nested/Photos café')
        folder.mkdir(parents=True, exist_ok=True)
        path = folder / f'Orientation-{orientation}.png'
        data = png(orientation, profile)
        path.write_bytes(data)
        records.append({'relative_path': str(path.relative_to(destination)),
                        'sha256': hashlib.sha256(data).hexdigest(), 'source_width': 96, 'source_height': 64,
                        'exif_orientation': orientation, 'expected_width': 64 if orientation >= 5 else 96,
                        'expected_height': 96 if orientation >= 5 else 64,
                        'expected_srgb_rgb8': [[n * 30, 0, 0] for n in order],
                        'expected_sample_centers': [[x * 32 + 16, y * 32 + 16]
                                                    for y in range(3 if orientation >= 5 else 2)
                                                    for x in range(2 if orientation >= 5 else 3)]})
    linear_provenance = None
    if linear_library:
        icc = linear_profile(linear_library)
        path = destination / 'Sources/Linear-sRGB.png'
        data = png(1, icc)
        path.write_bytes(data)
        def encode(value):
            linear = value / 255
            return round(255 * (12.92 * linear if linear <= 0.0031308 else
                                1.055 * linear ** (1 / 2.4) - 0.055))
        records.append({'relative_path': str(path.relative_to(destination)),
                        'sha256': hashlib.sha256(data).hexdigest(), 'source_width': 96, 'source_height': 64,
                        'exif_orientation': 1, 'expected_width': 96, 'expected_height': 64,
                        'expected_srgb_rgb8': [[encode(n * 30), 0, 0] for n in range(1, 7)],
                        'expected_sample_centers': [[x * 32 + 16, y * 32 + 16] for y in range(2) for x in range(3)],
                        'color_oracle': 'Independent standard sRGB transfer of gamma-1 D65/sRGB-primary RGB'})
        linear_provenance = {'library': str(linear_library),
                             'library_sha256': hashlib.sha256(linear_library.read_bytes()).hexdigest(),
                             'profile_sha256': hashlib.sha256(icc).hexdigest()}
    interruption = []
    if interruption_count:
        folder = destination / 'InterruptionSources'
        folder.mkdir()
        data = png(1, profile)
        digest = hashlib.sha256(data).hexdigest()
        for index in range(interruption_count):
            path = folder / f'Interrupted-{index:05d}.png'
            path.write_bytes(data)
            interruption.append({'relative_path': str(path.relative_to(destination)), 'sha256': digest})
    manifest = {'fixture': 'generated-s04-nested-orientation-v2', 'original_count': len(records),
                'profile_path': str(profile_path), 'profile_sha256': hashlib.sha256(profile).hexdigest(),
                'direct_counts': {'Sources': 2 + bool(linear_library), 'Sources/Nested': 3, 'Sources/Nested/Photos café': 3},
                'recursive_counts': {'Sources': 8 + bool(linear_library), 'Sources/Nested': 6, 'Sources/Nested/Photos café': 3},
                'sources': records, 'interruption_sources': interruption,
                'linear_profile_provenance': linear_provenance,
                'limitations': 'Opaque sRGB raster orientation fixture; RAW, wide-gamut and alpha require separate fixtures.'}
    (destination / 'manifest.json').write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + '\n')
    return manifest


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--profile', type=Path, default=Path('/System/Library/ColorSync/Profiles/sRGB Profile.icc'))
    parser.add_argument('--interruption-count', type=int, default=0)
    parser.add_argument('--linear-library', type=Path, help='Installed LittleCMS2 library for a nonidentity linear ICC fixture')
    args = parser.parse_args()
    result = generate(args.output.absolute(), args.profile.absolute(), args.interruption_count, args.linear_library)
    print(f"Generated {result['original_count']} source fixtures and independent orientation oracles")
