# Filter plugins

A LensWorks filter plugin is a WebAssembly module that changes the pixels of one layer. The person installs it in
Settings › Plugins; from then on it is a command — an item in Filter › Plugins, and a command AI agents can list and
run — that applies to the selected layer as one Undo step.

A plugin is third-party code, so it runs in a sandbox and LensWorks treats everything about it as untrusted: the
module, the manifest, and every string in the manifest. This document is the contract: the interface a plugin
implements, the package it ships in, the limits it runs under, and how to build one.

Source: `adapters/plugins` (the sandbox, in Rust), `native/Compositor/Plugins` (packages, the installed store, the
tile runner, the UI), `adapters/plugins/samples` (sample plugins, with sources).

## What a plugin can and cannot do

A plugin can read the float pixels of the tile it is handed, read its own declared parameters, compute, and write
pixels back into that tile. That is all.

It cannot read or write files, open a network connection, read a clock, obtain randomness, start threads, or call
anything in the app or the operating system: there is no WASI, and the only import the host provides is the one
function of the filter interface below. It cannot see any pixel outside the layer it was run on — LensWorks copies
that layer's tiles into the plugin's own memory, and nothing else ever enters it — so it sees no other layer, no
other document, and nothing of the catalog. Each run gets a fresh instance, so nothing a plugin stored during one
run is there in the next. Because it has no clock and no randomness, and floating-point results are canonicalised,
the same pixels and parameters always give the same result.

## The runtime

Plugins run in [wasmi](https://github.com/wasmi-labs/wasmi) 2.0.0, a WebAssembly interpreter written in Rust,
pinned by exact version and crate checksum (`DEPENDENCIES.json`, `wasmi`). It was chosen because:

- **Licence.** MIT or Apache-2.0; LensWorks takes MIT, which matches the app's own distribution. Its dependencies
  (wasmparser, spin, libm, bitflags) are MIT or Apache-2.0 too. All are in the shipped notices
  (`scripts/collect-native-notices.py` fails if one is missing).
- **An interpreter, not a compiler.** It never generates machine code, so the app needs no just-in-time
  entitlement under the hardened runtime and has no writable-and-executable memory for a plugin to aim at. Running
  a filter this way is slower than compiled code, and fast enough: a 256 × 256 tile of a simple filter takes a few
  milliseconds on Apple silicon.
- **Deterministic interruption.** It meters execution in *fuel* and stops a call when its fuel is spent, wherever
  it is — an endless loop ends at a known instruction count rather than at a timer. It bounds memory and table
  growth through a resource limiter, bounds its own value stack and call depth, and has compile-time limits meant
  for hostile modules.
- **Maintained and small.** It is actively developed, embeds as a library on Apple silicon with no native
  dependencies, and adds seven crates to the app.

The runtime is unmodified. It is built with the features `std`, `validate`, `auto-dispatch` and `deterministic`;
memory64, SIMD, threads, multi-memory, tail calls, custom page sizes and wide arithmetic are off, and a module
using them does not validate. A module with a start function is refused.

## The filter interface (version 1)

### Pixel format

A tile is `width × height` pixels in row order, top row first. Each pixel is four little-endian 32-bit floats:
red, green, blue, alpha.

- Color is **linear light** with sRGB primaries (extended linear sRGB): 0 is black and 1 is display white, and
  values may lie outside 0–1 on a float layer.
- Alpha is **straight** (not premultiplied), from 0 through 1.

A plugin must return finite values and an alpha from 0 through 1; anything else fails the run.

LensWorks keeps a layer in the storage it already has. A float layer (a developed RAW, for instance) is read and
written as float and keeps values outside 0–1. An 8-bit layer is converted to this format a tile at a time and
converted back; color outside 0–1 is clipped on the way back, and a pixel the plugin left untouched keeps its bytes
exactly.

### Tiles

LensWorks never hands a plugin a whole layer. It cuts the layer into tiles of at most 256 × 256 pixels (65,536
pixels) and calls the plugin once per tile, in row order. A plugin is told where each tile sits — its top-left
pixel's `x` and `y` in the layer, and the layer's `frame_width` and `frame_height` — so a filter that depends on
position computes the same result however the layer is cut. Only the tile's own pixels are available: a filter that
needs neighbouring pixels (a blur) cannot see across a tile edge in this version of the interface.

For a pointwise filter the tiled result is identical to one whole-frame pass; the tests check this for the sample
plugins at several tile sizes.

Memory cost: the float copy of the pixels is one tile at a time — 1 MiB for a full 256 × 256 tile (16 bytes a
pixel), three of them resident while a tile is in flight (as read, as the plugin's working copy, as handed to
storage) — whatever the size of the layer, plus the plugin's own memory (at most 16 MiB). It is charged to the
512 MiB float working set like every other float operation. The result of a float layer is written to tile files on
disk, 16 MB per megapixel, as every float layer is. An 8-bit layer costs what a built-in filter costs: 4 MB per
megapixel for its decoded pixels and 4 MB per megapixel for the result. A selection adds 1 byte per pixel for its
coverage mask.

### What a module must export

| Export | Type | Meaning |
| --- | --- | --- |
| `memory` | memory | The module's one linear memory. |
| `lw_tile_buffer` | `(bytes: i32) -> i32` | Returns the address of a buffer of at least `bytes` bytes inside `memory` for the next tile, or 0 if it cannot provide one. `bytes` is `width × height × 16`, at most 1,048,576. |
| `lw_filter_tile` | `(pointer: i32, width: i32, height: i32, x: i32, y: i32, frame_width: i32, frame_height: i32) -> i32` | Filters the tile at `pointer` in place. Returns 0 on success; any other value fails the run. |

For each tile LensWorks calls `lw_tile_buffer`, copies the tile into the buffer, calls `lw_filter_tile`, checks the
buffer still lies inside the module's memory, checks every value, and copies the tile out. Nothing but that buffer
is read back, so a plugin's output is exactly one tile.

### What a module may import

| Import | Type | Meaning |
| --- | --- | --- |
| `lensworks_filter_v1.param` | `(index: i32) -> f64` | The value of the declared parameter at `index` (in manifest order): the number itself, 0 or 1 for a boolean, or a choice's position in its list. An index the plugin did not declare answers 0. |

That is the whole list. A module that imports anything else — a function, memory, table or global, from any module
name — is refused when it is installed and again when it is run, with the import named:

> The module imports “wasi_snapshot_preview1.fd_write”, which the filter interface does not provide. A plugin may
> import only lensworks_filter_v1.param.

## The package

A plugin package is a folder (by convention named `something.lwplugin`) holding two files. Other files in it are
ignored and not installed.

- `filter.wasm` — the module.
- `plugin.json` — the manifest:

```json
{
  "interface": 1,
  "id": "com.example.brightness",
  "name": "Example Brightness",
  "version": "1.0.0",
  "parameters": [
    { "name": "amount", "label": "Amount", "type": "number", "minimum": -1, "maximum": 1, "default": 0.25 },
    { "name": "channel", "label": "Channel", "type": "choice", "choices": ["all", "red", "green", "blue"], "default": "all" },
    { "name": "clamp", "label": "Clamp to 0-1", "type": "boolean", "default": false },
    { "name": "repeat", "label": "Repeat", "type": "integer", "minimum": 1, "maximum": 4, "default": 1 }
  ]
}
```

| Key | Rule |
| --- | --- |
| `interface` | The filter interface version the plugin was built for. This LensWorks provides 1; any other is refused. |
| `id` | The plugin's identity. Lowercase ASCII letters and digits in parts joined by `.` or `-`, with at least one dot, 3 to 64 bytes. Use a reverse domain name you control. |
| `name` | What the person sees. 1 to 40 characters: ASCII letters, digits, spaces and `- _ . & + '`, no space at either end, no doubled space. Not the name of any built-in LensWorks command, and not the name of another installed plugin. |
| `version` | 1 to 32 ASCII letters, digits, `.`, `+` or `-`. Shown to the person; LensWorks does not interpret it. |
| `parameters` | At most 16. Each has `name` (1 to 32 ASCII letters and digits starting with a lowercase letter, unique, not `layer` or `plugin`), `label` (the same rule as `name` above), `type`, and `default`. A `number` or `integer` also has `minimum` < `maximum`, both finite and within ±1e9, with the default between them (whole numbers for an integer). A `choice` has `choices`: 2 to 32 different strings under the label rule, with the default one of them. A `boolean`'s default is `true` or `false`. |

A manifest is at most 64 KiB. A key the format does not define is refused, so a misspelled key never silently does
nothing.

**Plugin strings are untrusted.** The name and labels are limited to plain ASCII so they cannot carry look-alike
letters, control or direction-changing characters, the “ — ” that precedes a disabled menu item's reason, a dialog's
ellipsis, or an “(Agent)” label. A plugin's name is never shown alone: its menu item is in the Filter › Plugins
submenu (never among the built-in filters) as `Name (id)`, its history entry is `Plugin: Name`, and the settings
pane, parameter sheet, progress panel and failure alert carry LensWorks's own titles with the name and id beneath.
No plugin string appears in the title of anything the person is asked to confirm.

## Installing, reloading, removing

**Install** (Settings › Plugins › Install Plugin…, or Filter › Plugins › Install Plugin…): the person picks the
package folder. LensWorks checks the manifest, checks the module against everything in this document (size,
validity, imports, exports, limits) without running it, and only then copies the two files into its own
Application Support folder (`Plugins/<id>/`) and records the SHA-256 of each. A refused package leaves nothing
behind. Settings lists each installed plugin with its name, id, version and module hash.

**Every run** reads LensWorks's own copy, checks both files still hash to what was installed, and validates the
module again as it is instantiated. If the installed files were changed behind LensWorks's back the plugin does not
run and is listed as damaged, with only Remove offered.

**Reload** reads the package again from the folder it was installed from. If the bytes are the same it says so; if
either file changed, the new package is checked exactly as at install and replaces the old one, and the pane states
the old and new hash. The next run uses the new code. A package that is refused, or that now carries a different
id, leaves the installed plugin as it was. Installing a package whose id is already installed is the same
replacement.

**Remove** deletes LensWorks's copy. The plugin's menu item and its agent command are gone at once.

Installing, reloading and removing are the person's alone. Installing executable code is a decision to trust it, so
no agent command reaches them: `plugin.install`, `plugin.remove` and `plugin.reload` are registered commands that
agents are refused with that reason.

## Running a plugin

A plugin runs on the selected layer when that layer has pixels and nothing else is in progress — the conditions of
a built-in filter, and additionally no pending transform or gradient (those would be applied on the way in, and a
plugin that then failed could not leave history untouched). With a selection, only the selected pixels change, and
soft selection edges blend. A plugin with parameters first shows a sheet with a control for each; one without runs
at once. When its item is disabled the menu states why, and an agent is refused with the same words.

The run happens off the main thread, so the window stays live. If it lasts more than a moment a panel shows its
progress with a Cancel button (a registered command, `plugin.cancel`, also on Escape). Cancelling stops the run
between tiles — at most one tile's fuel later.

The result replaces the layer's pixels as one history entry, `Plugin: Name`, which one Undo reverts. As with the
built-in filters, the layer keeps its name, placement, opacity, blend mode, mask and effects; live text, a shape or
a live RAW source becomes pixels. A saved project holds the resulting pixels and no reference to the plugin, so it
opens the same whether or not the plugin is still installed.

**A run either completes or changes nothing.** If the plugin is missing or damaged, loops, recurses without end,
asks for too much memory, traps, reads or writes outside its memory, returns a value that is not finite or an alpha
outside 0–1, reports failure, or is cancelled, the document and its history are exactly as they were, and the person
(or the agent) is told which plugin failed and why.

### For agents

Each installed plugin is its own command, `plugin.run.<id>`, listed by `list_commands` with a JSON schema generated
from the manifest: every declared parameter with its type, range and choices, plus `layer`. It is admitted like
every other command: an argument the manifest does not declare is refused by name, as is a value of the wrong type,
a number that is not finite or lies outside its declared range, and a choice not in the list. The command `plugin.run`
takes a `plugin` id and runs that plugin with its default parameter values. Both can be members of a document
batch. A run by an agent is one history entry labeled `Plugin: Name (Agent)`. No plugin command takes a file path.

In the command registry every plugin command belongs to one built-in family, `plugin.run`, whose classification
(runnable by agents, acts on the document, reversed by Undo, needs no confirmation) it shares — so a plugin can
never be a kind of command the registry did not classify.

## Limits

These are compiled into the sandbox (`adapters/plugins/src/lib.rs`, `LIMITS`) and shown in Settings › Plugins.

| Bound | Value | What happens past it |
| --- | --- | --- |
| Module size | 4 MiB (4,194,304 bytes) | Refused at install. |
| Manifest size | 64 KiB | Refused at install. |
| Linear memory | 16 MiB (256 pages), one memory | A module that starts larger is refused at install; growing past it traps. |
| Table | one table, 4,096 elements | Growing past it traps. |
| Value stack | 1 MiB | The call traps. |
| Call depth | 1,024 calls | The call traps. |
| Tile | 65,536 pixels (256 × 256), a 1 MiB buffer | LensWorks never sends more. |
| Fuel for `lw_tile_buffer` | 1,000,000 | The call is stopped. |
| Fuel to instantiate | 10,000,000 | The plugin is not started. |
| Fuel for `lw_filter_tile` | 10,000,000 + 4,000 per pixel of the tile (272,144,000 for a full tile) | The call is stopped. |
| Output | exactly the tile buffer: `width × height × 16` bytes | Nothing else is read back. |
| Compile limits | 10,000 functions, 1,000 globals, 1,000 data and 1,000 element segments, 32 parameters and 32 results per function, at least 40 bytes per function on average | Refused at install. |
| Parameters | 16 | Refused at install. |
| Installed plugins | 64 | Install is refused. |

Fuel is roughly one unit per executed instruction, plus a charge per byte for bulk memory operations. A full tile's
budget of 272 million units is about four thousand instructions per pixel; the interpreter spends it in roughly a
tenth of a second on Apple silicon, which is how long an endless loop runs before it is stopped. There is no
wall-clock limit: a plugin that uses its whole budget on every tile and still succeeds is slow rather than stuck,
and the person can cancel it.

## Building a plugin

Any toolchain that produces a freestanding WebAssembly module (target `wasm32-unknown-unknown` or equivalent, no
WASI, no JavaScript glue) works, provided the result has the three exports, imports nothing but
`lensworks_filter_v1.param`, and stays inside the limits.

The simplest plugin, in WebAssembly text — this is the sample `invert`, complete:

```wat
(module
  ;; 17 pages: the 1 MiB tile buffer starts at 65536, above a page left for the module's own use.
  (memory (export "memory") 17)
  (func (export "lw_tile_buffer") (param $bytes i32) (result i32)
    (if (result i32) (i32.gt_u (local.get $bytes) (i32.const 1048576))
      (then (i32.const 0))
      (else (i32.const 65536))))
  (func (export "lw_filter_tile") (param $ptr i32) (param $w i32) (param $h i32) (param $x i32) (param $y i32) (param $fw i32) (param $fh i32) (result i32)
    (local $end i32)
    (local.set $end (i32.add (local.get $ptr) (i32.shl (i32.mul (local.get $w) (local.get $h)) (i32.const 4))))
    (block $done
      (loop $next
        (br_if $done (i32.ge_u (local.get $ptr) (local.get $end)))
        (f32.store offset=0 (local.get $ptr) (f32.sub (f32.const 1) (f32.load offset=0 (local.get $ptr))))
        (f32.store offset=4 (local.get $ptr) (f32.sub (f32.const 1) (f32.load offset=4 (local.get $ptr))))
        (f32.store offset=8 (local.get $ptr) (f32.sub (f32.const 1) (f32.load offset=8 (local.get $ptr))))
        (local.set $ptr (i32.add (local.get $ptr) (i32.const 16)))
        (br $next)))
    (i32.const 0)))
```

In Rust the same shape is a `#![no_std]` `cdylib` built with `--target wasm32-unknown-unknown`: declare
`extern "C" { fn param(index: i32) -> f64; }` under `#[link(wasm_import_module = "lensworks_filter_v1")]`, keep a
static 1 MiB buffer and return its address from `#[no_mangle] extern "C" fn lw_tile_buffer`, and filter it in
`#[no_mangle] extern "C" fn lw_filter_tile`. Do not link the standard library's WASI support or anything that
imports from `env` or `wasi_snapshot_preview1`; the install message names any import that slipped in.

Put `filter.wasm` beside a `plugin.json`, install the folder, and use Reload after each rebuild.

### The sample plugins

`adapters/plugins/samples` holds ten packages, each with its `filter.wat` source, its `plugin.json`, and the built
`filter.wasm`:

| Sample | What it is for |
| --- | --- |
| `invert` | A filter with no parameters. |
| `brightness` | Every parameter type: a ranged number, a choice, a boolean, a ranged integer. |
| `gradient` | Depends on each pixel's position in the layer: shows that tiling agrees with one whole frame. |
| `loop`, `recursion`, `memory-bomb`, `trap`, `oob-write`, `not-a-number` | Hostile: each conforms to the interface, installs, and is stopped and reported when run. |
| `forbidden-import` | Hostile: asks for a WASI file write and is refused at install. |

They are built from source by a pinned, reproducible step:

```sh
scripts/build-sample-plugins.sh
```

The toolchain is the `wat` assembler crate, version 1.261.0, pinned with its checksum in
`adapters/plugins/Cargo.toml`, `Cargo.lock` and `DEPENDENCIES.json`, and built by the rustc pinned in
`rust-toolchain.toml`. Assembling WebAssembly text is a pure function of the source, so the output is byte-for-byte
reproducible. The built modules are committed with their SHA-256 hashes (`adapters/plugins/samples/SHA256SUMS`),
and `cargo test --manifest-path adapters/plugins/Cargo.toml --locked` — which CI runs — reassembles every source
and fails if a committed module is not exactly what its source produces.

## Tests

- `adapters/plugins/tests/sandbox.rs` — the sandbox itself: forbidden imports refused by name, each limit, each way
  of failing, tiles against whole frames, the C interface.
- `adapters/plugins/tests/samples.rs` — the committed samples match their sources.
- `native/CompositorTests/LensWorksPluginTests.swift` — the app: install, the menu command, pixels and Undo;
  agents listing and running a plugin with typed parameters; every argument outside its declaration refused; every
  hostile sample stopped with the document unchanged; refusal at install and again at load; manifests and
  untrusted strings; remove and reload; float layers, selections and tiling; liveness and Cancel.
