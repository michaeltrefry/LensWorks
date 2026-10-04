# LensWorks

Native Apple-silicon macOS photo catalog and layered editor. The approved product
requirements and implementation plan live in Shortcut epic
[24655](https://app.shortcut.com/trefry/epic/24655). Delivery remains in progress;
source reuse and a compiling application do not establish product acceptance.

The Swift editor adapts the exact MIT-licensed Compositor baseline in
[DEPENDENCIES.json](DEPENDENCIES.json). LensWorks owns its Swift/Rust boundary;
PhotoCatalog catalog, metadata and migration services remain pinned and unchanged.
The read-only source baselines are Git submodules.

## Build the development application

Requires Apple silicon, Xcode 26.5, Rust 1.97.1, Python 3.11+, pkg-config and the exact
native library versions recorded in DEPENDENCIES.json. This local build uses ad hoc
signing. Signed/notarized distribution and LensWorks updates have separate story
acceptance; Compositor's upstream update feed is not used.

```sh
git submodule update --init --recursive
scripts/build-native.sh
python3 scripts/audit-capabilities.py
```

The script verifies frozen source/native library pins, acquires the checksum-pinned
Adobe DNG SDK in `.build`, builds the owned Rust static library and audits every
native object's deployment floor before compiling the app. Generated builds,
fixtures and SDKs remain outside Git. The native app is in
`.build/xcode/Build/Products/Debug/LensWorks.app`.

For local installed acceptance, `scripts/install-development-app.py` relocates the
native dependency closure into a new app copy, carries the verified native/Rust
notice manifest from `scripts/collect-native-notices.py`, ad hoc signs it, and verifies its
architecture, deployment floor and bundle closure. This is not a release package.

The first execution slice is a raster catalog → working version → editable layer →
save/reopen journey with unchanged source bytes. The complete live RAW, precision,
catalog, history, recovery, layered interchange and real-weight AI requirements
remain tracked in the epic. See [the execution ledger](docs/EXECUTION_LEDGER.md),
[capability inventory](docs/CAPABILITY_INVENTORY.md) and
[native project format](docs/NATIVE_PROJECT_FORMAT.md) for scope and evidence.
