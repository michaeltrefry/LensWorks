# Third-party notices

The native editor adapts Compositor at the exact revision in DEPENDENCIES.json. Its MIT license and copyright notice follow. Source provenance remains in the read-only submodule.

MIT License

Copyright (c) 2026 Wonder Assembly LLC

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.


LensWorks owns the copied catalog sources in engines/catalog and has no build or runtime dependency on the PhotoCatalog repository. The upstream revision in DEPENDENCIES.json records the original copy's provenance. The copied catalog and its transitive native/Rust dependency licenses remain with their sources. The Adobe DNG SDK license is included by the dependency acquisition script. Sparkle is recorded as a frozen baseline reference and is not linked; LensWorks distribution and updates require sc-24690 acceptance.

The inference adapter (adapters/inference) links the SceneWorks inference macOS runtime (Apache-2.0) at the exact revision in DEPENDENCIES.json, unmodified, together with its MLX fork and transitive Rust crates; their licenses remain with their sources. Model weights are not distributed: LensWorks reads model files the user already has, under each model's own license.

Filter plugins run in the wasmi WebAssembly interpreter (adapters/plugins), at the exact crate versions and checksums in DEPENDENCIES.json (`wasmi`): wasmi, wasmi_core, wasmi_ir and wasmi_collections 2.0.0 (MIT or Apache-2.0; LensWorks takes MIT), wasmparser 0.228.0 (Apache-2.0 with LLVM exception, Apache-2.0 or MIT), spin 0.9.9 (MIT) and libm 0.2.16 (MIT). The runtime is unmodified and linked into the app through the catalog adapter's static library; scripts/collect-native-notices.py inventories it from the shipped lock files and fails if any of these crates is missing. wasmi's MIT notice follows; the others' notices are collected with it.

MIT License

Copyright (c) 2018-2024 Robin Freyler

Permission is hereby granted, free of charge, to any
person obtaining a copy of this software and associated
documentation files (the "Software"), to deal in the
Software without restriction, including without
limitation the rights to use, copy, modify, merge,
publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software
is furnished to do so, subject to the following
conditions:

The above copyright notice and this permission notice
shall be included in all copies or substantial portions
of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF
ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED
TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT
SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR
IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
DEALINGS IN THE SOFTWARE.
