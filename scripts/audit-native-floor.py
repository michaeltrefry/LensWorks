#!/usr/bin/env python3
"""Fail if any Mach-O object in the linked Rust archive or the inference dylib exceeds macOS 26.2."""
import collections
import os
import pathlib
import re
import subprocess

root = pathlib.Path(__file__).resolve().parents[1]
archive = root / '.build/rust-catalog/release/liblensworks_catalog.a'
result = subprocess.run(['otool', '-l', str(archive)], text=True, capture_output=True, check=True)
versions = re.findall(r'\bminos\s+(\d+\.\d+(?:\.\d+)?)', result.stdout)
versions += re.findall(r'cmd LC_VERSION_MIN_MACOSX\s+cmdsize \d+\s+version (\d+\.\d+(?:\.\d+)?)', result.stdout)
if not versions:
    raise SystemExit('No native deployment targets found in Rust archive')
def version(value):
    return tuple(map(int, value.split('.'))) + (0,) * (3 - len(value.split('.')))
failures = {value for value in versions if version(value) > version('26.2')}
if failures:
    raise SystemExit('Native archive exceeds macOS 26.2: ' + ', '.join(sorted(failures)))
print('PASS: native archive deployment floors ' + str(dict(collections.Counter(versions))))

inference = pathlib.Path(os.environ.get('LW_INFERENCE_TARGET_DIR', root / '.build/rust-inference')) / 'release/liblensworks_inference.dylib'
if not inference.exists():
    raise SystemExit(f'Inference adapter library is missing: {inference}')
dylib = subprocess.run(['otool', '-l', str(inference)], text=True, capture_output=True, check=True).stdout
floors = re.findall(r'\bminos\s+(\d+\.\d+(?:\.\d+)?)', dylib)
if not floors or any(version(value) > version('26.2') for value in floors):
    raise SystemExit(f'Inference library deployment floors exceed macOS 26.2: {floors}')
print('PASS: inference library deployment floors ' + str(dict(collections.Counter(floors))))
