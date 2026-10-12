# Inference adapter

LensWorks owns this C/JSON boundary over the SceneWorks inference macOS runtime,
which is retained unmodified (E2). The runtime is pinned by revision in
`Cargo.toml`, `Cargo.lock` and `DEPENDENCIES.json` (`inference`); 
`scripts/verify-dependencies.py` rejects drift. The pin is the revision SceneWorks
main uses for its macOS worker (`runtime-macos`) at qualification time:
`25bd55cdb6a56c78b07584a12150c9f5d46be439`, with the MLX fork at
`48ff5e78a49e0a513f1976b0b1af70f9a5305f00`. Only the bundle's `media` feature is
composed; the Candle audio lane is not part of this product. Changes needed inside
inference are tracked there and arrive here only as a tested repin.

## Packaging

The crate builds `liblensworks_inference.dylib`. The app never links MLX: the Swift
boundary (`native/Compositor/LensWorks/LensWorksInference.swift`) `dlopen`s the
library from `Contents/Helpers` (or, in Debug builds only, `LW_INFERENCE_LIBRARY`), checks
`lw_inference_abi_version`, and resolves the symbols in `include/LensWorksInference.h`.
`scripts/build-native.sh` embeds the dylib in `Contents/Helpers` and `mlx.metallib` in
`Contents/Resources`, where the app's own signature seals it as a resource. The library is
never unloaded (Rust/MLX thread-local destructors make `dlclose` unsafe).

The pinned MLX fork would otherwise prefer the absolute build-directory metallib compiled
into the library (and `~/.cache/pmetal`) over the bundled copy. When the loaded library sits
in an app bundle's `Contents/Helpers` and `Contents/Resources/mlx.metallib` exists (or, in a
flat layout, a `mlx.metallib` sits next to the library), the adapter pins that file before
any Metal work (and before the catalog is built) through upstream
MLX's strict `set_metallib_path` (a small C++ shim, `shim/metallib.cpp`): MLX loads exactly
that file or fails device creation, never falling back. Capabilities (`execution.metallib`)
and every result's provenance report the pinned path, or `mlx_search_order` for unbundled
development builds. `tests/metallib.rs` proves both halves in child processes.

`lw_inference_self_test` is a weights-free GPU check: on the executor thread it runs a steel
GEMM and a Q4 `quantized_matmul` against a CPU reference and reports the metallib MLX loaded
(MLX's own record of the strict path). CI runs it against the signed app bundle.

## Execution model

* One dedicated executor thread runs every load and job, FIFO. MLX Metal work is
  effectively single-threaded per process and inference providers are `!Send`.
* At most one model is resident. `load.residency` is `unload_after` (default: drop
  the model and return MLX cached buffers when the job ends) or `keep_loaded`
  (reuse it for the next job with the same task/provider/weights/quantization).
  A load/execution failure or a panic always drops it; a cancelled job, or a request
  refused by validation (unknown provider, unsupported control, a value outside the
  advertised floor), keeps a healthy `keep_loaded` model. `lw_inference_release_models`
  drops it explicitly.
* Requests are validated against the provider's weights-free capability floor
  (`Capabilities::validate_request` for generators, `CaptionCapabilities::validate_request`
  for captioners, the adapter's capability checks for every route) before any weights load.
* If runtime initialisation fails, the next job after a backoff (1 s, doubling to 60 s)
  retries it; jobs inside the backoff window fail with `runtime_unavailable` and
  `retry_after_ms`.
* Cancellation is cooperative: a queued job cancels immediately; a running provider
  stops at its next step boundary (registry providers check the request
  `CancelFlag`; bespoke SAM utilities are checked before load and before/after their
  forward pass). A cancelled job never delivers output, even if the provider finished.
* Panics in request processing are caught; the job fails with kind `panic`, resident
  models are dropped, and the executor keeps serving.

## Ownership and callbacks

* `lw_inference_job_start` copies every input buffer (once, converting premultiplied
  alpha) before returning, so its cost scales with the input size: the Swift boundary
  calls it, and the capability enumeration and self-test, off the caller's thread
  (`async` APIs). An input edge above 16384 pixels fails with kind `input_too_large`. On
  rejection it returns NULL and an owned error JSON (`lw_inference_string_free`).
* The callback runs on the executor thread, never concurrently for one job. Event
  JSON and pixels are borrowed for the callback only.
* Every job not released first gets exactly one terminal event (`COMPLETED`,
  `FAILED`, `CANCELLED`); the adapter drops its callback slot after it.
* `lw_inference_job_release` cancels, then returns only when no callback for the job
  is running or can start, so the caller may free `context` immediately. It may be
  called from inside the job's own callback.

## Buffers and colour

All 8-bit buffers are sRGB (`color_space = 1`); callers colour-manage other spaces
first (the Swift boundary renders any `CGImage` into sRGB). Inputs carry 1 (gray or
mask), 3 (RGB) or 4 (RGBA) channels with an explicit row stride; 4-channel inputs
declare straight or premultiplied alpha and are converted to straight alpha. RGB-only
routes receive RGBA composited over white, which is inference's own flattening rule
(`RgbaImage::to_rgb_over_white`); each conversion is recorded in the result's
`input_conversions`. Image outputs are tightly packed RGB, or RGBA with straight
alpha when `alpha_output` is requested from a model that supports it. Masks are one
channel, 0 or 255, on the source pixel grid.

## Request contract (version 1)

```json
{"version":1,"task":"generate","provider":"sana_sprint_1600m",
 "weights":{"dir":"/abs/Sana_Sprint/q4"},"load":{"residency":"keep_loaded"},
 "params":{"prompt":"…","width":512,"height":512,"steps":2,"seed":7,
           "conditioning":[{"kind":"mask","input":0}]}}
```

Tasks: `generate`, `transform`, `caption`, `embed_image`, `embed_text` (registry
providers by id) and `segment_sam2_box`, `segment_sam3_concept`, `segment_sam3_box`
(bespoke utilities; provider `sam2`/`sam3`, `weights.file`, SAM3 also `tokenizer`).
Unknown fields are rejected; paths are absolute; every input must be referenced.

## Capabilities and unsupported controls

`lw_inference_capabilities` returns a weights-free document listing every provider
the bundle registers with a route (`supported`, or `unsupported` with a reason: video
and audio generators are not still-image routes), each exposed control as supported
with constraints or unsupported with a reason, conditioning kinds, quantization
choices, output channels, and the runtime surfaces the adapter does not route
(trainers, text LLMs, bespoke depth/face/InstantID/PiD/SAM video and point
utilities). Requests are gated by the same rules on the executor before any weights
load: a control the model cannot honour fails with kind `unsupported` and an
`unsupported` list instead of being dropped. Engine features the adapter does not yet
carry (LoRA, previews, HDR, prompt enhancement) are reported unsupported per model.

## Model licences and measured memory

The capability document carries `model_licenses`: the pinned runtime's own checkpoint licence
table (`gen_core::LICENSE_FAMILIES` and `MEDIA_COMPONENT_LICENSES`, schema 3 without provider
mappings, which the bundle does not re-export). Every `COMPLETED` result carries
`memory.peak_bytes` and `memory.active_bytes`, MLX's high-water mark and resident bytes for the
job (the load is included unless the model was reused). The native model store
(`native/Compositor/LensWorks/LensWorksModelStore.swift`) validates each model's licence rows
and route against this document and admits models only when their measured peak (the values in
`LensWorksModels.json`, measured by `measure_reference_memory` in `tests/real_weights.rs`, or a
larger measurement recorded on the Mac itself) fits the GPU's recommended working set.

## Events

`STARTED` (`model_reused`), `PROGRESS` (`phase`: `load_model`, `loading`, `step`
with `current`/`total`, `decoding`), `IMAGE`/`MASK` (pixels plus index, score and box
for masks), `COMPLETED` (provenance: task, provider, inference revision, weights,
quantization, reuse, input conversions, measured memory; plus caption text or embeddings with their
space and dimension), `FAILED` (`kind`: `invalid_request`, `unsupported`,
`unknown_provider`, `load`, `engine`, `geometry_refused`, `unsupported_output`,
`no_result`, `panic`, `runtime_unavailable`), `CANCELLED`.

## Tests

`cargo test --locked` runs the weights-free suites (pixels, request parsing,
capability/gating consistency for every registered generator, lifecycle and teardown
with a scripted provider, and the exported C ABI). Real-weight runs use existing
SceneWorks model files from the Hugging Face cache:

```sh
LW_INFERENCE_REQUIRE_WEIGHTS=1 cargo test --locked --test real_weights -- --ignored --test-threads=1
```
