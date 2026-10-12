#!/usr/bin/env python3
"""Run the inference adapter's weights-free GPU self-test from a built app bundle.

Loads Contents/Helpers/liblensworks_inference.dylib exactly as the app ships it, runs
lw_inference_self_test (a steel GEMM and a Q4 quantized_matmul on the adapter's executor
thread) and requires both kernels to pass on the metallib sealed in Contents/Resources.
"""
import ctypes
import json
import pathlib
import subprocess
import sys

app = pathlib.Path(sys.argv[1]).resolve()
library = app / 'Contents/Helpers/liblensworks_inference.dylib'
metallib = app / 'Contents/Resources/mlx.metallib'
if not library.is_file() or not metallib.is_file():
    raise SystemExit(f'missing {library} or {metallib}')
if (library.parent / 'mlx.metallib').exists():
    raise SystemExit('mlx.metallib must be a sealed resource, not a file in Contents/Helpers')
subprocess.run(['codesign', '--verify', '--strict', '--deep', str(app)], check=True)
lib = ctypes.CDLL(str(library))
lib.lw_inference_self_test.restype = ctypes.c_void_p
lib.lw_inference_string_free.argtypes = [ctypes.c_void_p]
raw = lib.lw_inference_self_test()
if not raw:
    raise SystemExit('lw_inference_self_test returned NULL')
document = json.loads(ctypes.string_at(raw).decode())
lib.lw_inference_string_free(raw)
print(json.dumps(document, indent=2))
result = document.get('result') or {}
if not document.get('ok') or result.get('metallib') != str(metallib):
    raise SystemExit(f'self-test failed or loaded {result.get("metallib")!r} instead of {metallib}')
if [op.get('op') for op in result.get('ops', [])] != ['steel_gemm_f32', 'quantized_matmul_q4']:
    raise SystemExit('self-test did not run both kernels')
print(f'PASS: GPU self-test on the executor thread with {metallib}')
