//! Sandboxed WebAssembly filter plugins for LensWorks.
//!
//! A plugin is one WebAssembly module that filters straight-alpha linear float RGBA pixels one tile at a time. It
//! runs in the wasmi interpreter with nothing but the declared filter interface to call: no WASI, no filesystem,
//! network, clock, randomness or threads. Every resource it can use is bounded by [`LIMITS`], and every way it can
//! fail (an endless loop, unbounded recursion, a memory bomb, a trap, a write outside its memory, a malformed
//! module, an unusable result) ends in an [`Err`] that says what happened. docs/PLUGINS.md is the public contract.

use std::fmt;
use wasmi::{
    Caller, CompilationMode, Config, EnforcedLimits, Engine, ExternType, Linker, Memory, Module,
    Store, StoreLimits, StoreLimitsBuilder, TrapCode, TypedFunc, ValType,
};

pub mod ffi;

/// The filter interface version this host implements. A plugin's manifest names the version it was built for.
pub const INTERFACE_VERSION: u32 = 1;
/// The one import module a plugin may name.
pub const IMPORT_MODULE: &str = "lensworks_filter_v1";
/// The one import a plugin may name in [`IMPORT_MODULE`]: `param(index: i32) -> f64`.
pub const IMPORT_PARAM: &str = "param";
pub const EXPORT_MEMORY: &str = "memory";
pub const EXPORT_TILE_BUFFER: &str = "lw_tile_buffer";
pub const EXPORT_FILTER_TILE: &str = "lw_filter_tile";
const PAGE: u64 = 65_536;

/// Every bound a plugin runs under. The app shows these and docs/PLUGINS.md states them; this is the one definition.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Limits {
    /// The largest module, in bytes.
    pub module_bytes: u64,
    /// The most linear memory an instance may hold, in bytes. Growing past it traps.
    pub memory_bytes: u64,
    /// The most elements a plugin's one table may hold.
    pub table_elements: u64,
    /// The interpreter's value stack, in bytes.
    pub stack_bytes: u64,
    /// The deepest chain of calls.
    pub recursion_depth: u64,
    /// The most pixels one tile carries.
    pub tile_pixels: u64,
    /// Fuel for a `lw_tile_buffer` call.
    pub fuel_buffer_call: u64,
    /// Fuel for instantiation and for a `lw_filter_tile` call before its per-pixel share.
    pub fuel_filter_base: u64,
    /// Fuel a `lw_filter_tile` call gains per pixel of its tile.
    pub fuel_per_pixel: u64,
    /// The most parameters a plugin may declare.
    pub parameters: u64,
    pub interface_version: u32,
}

pub const LIMITS: Limits = Limits {
    module_bytes: 4 * 1024 * 1024,
    memory_bytes: 256 * PAGE,
    table_elements: 4_096,
    stack_bytes: 1024 * 1024,
    recursion_depth: 1_024,
    tile_pixels: 65_536,
    fuel_buffer_call: 1_000_000,
    fuel_filter_base: 10_000_000,
    fuel_per_pixel: 4_000,
    parameters: 16,
    interface_version: INTERFACE_VERSION,
};

/// Why a plugin was refused or stopped. The message is for the person: it never carries plugin-supplied text other
/// than an import or export name, which is quoted and bounded.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PluginError(pub String);

impl fmt::Display for PluginError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}
impl std::error::Error for PluginError {}

fn refuse<T>(message: impl Into<String>) -> Result<T, PluginError> {
    Err(PluginError(message.into()))
}

/// Text from the module or the runtime, made safe to show: printable ASCII only, at most 160 characters.
fn shown(name: &str) -> String {
    let mut text: String = name
        .chars()
        .take(160)
        .map(|c| {
            if c.is_ascii_graphic() || c == ' ' {
                c
            } else {
                '?'
            }
        })
        .collect();
    if name.chars().count() > 160 {
        text.push_str("...");
    }
    text
}

fn engine() -> Engine {
    let mut config = Config::default();
    config
        .consume_fuel(true)
        .compilation_mode(CompilationMode::Eager)
        .enforced_limits(EnforcedLimits::strict())
        .allow_start_fn(false)
        .ignore_custom_sections(true)
        .wasm_multi_memory(false)
        .wasm_tail_call(false)
        .wasm_custom_page_sizes(false)
        .wasm_wide_arithmetic(false);
    // The minimum is lowered first: the maximum may never be below it.
    config.set_min_stack_height(16 * 1024);
    config.set_max_stack_height(LIMITS.stack_bytes as usize);
    config.set_max_recursion_depth(LIMITS.recursion_depth as usize);
    config.set_max_cached_stacks(1);
    Engine::new(&config)
}

fn is(types: &[ValType], expected: &[ValType]) -> bool {
    types.len() == expected.len() && types.iter().zip(expected).all(|(a, b)| a == b)
}

/// Checks a module against the filter interface without running any of it: its size, that it is well-formed and
/// within the compile limits, that every import is the declared filter interface (anything else is named in the
/// refusal), and that it exports the interface's memory and two functions with the right types.
pub fn validate(wasm: &[u8]) -> Result<(), PluginError> {
    compile(&engine(), wasm).map(|_| ())
}

fn compile(engine: &Engine, wasm: &[u8]) -> Result<Module, PluginError> {
    if wasm.len() as u64 > LIMITS.module_bytes {
        return refuse(format!(
            "The module is {} bytes, over the {}-byte limit.",
            wasm.len(),
            LIMITS.module_bytes
        ));
    }
    if wasm.len() < 8 || &wasm[..4] != b"\0asm" {
        return refuse("The file is not a WebAssembly module.");
    }
    let module = Module::new(engine, wasm).map_err(|error| {
        PluginError(format!(
            "The module is not valid WebAssembly for this host: {}.",
            shown(&error.to_string())
        ))
    })?;
    for import in module.imports() {
        let name = format!("{}.{}", shown(import.module()), shown(import.name()));
        if import.module() != IMPORT_MODULE || import.name() != IMPORT_PARAM {
            return refuse(format!(
                "The module imports \u{201c}{name}\u{201d}, which the filter interface does not provide. A plugin may import only {IMPORT_MODULE}.{IMPORT_PARAM}."
            ));
        }
        match import.ty() {
            ExternType::Func(ty)
                if is(ty.params(), &[ValType::I32]) && is(ty.results(), &[ValType::F64]) => {}
            _ => {
                return refuse(format!(
                    "The module imports \u{201c}{name}\u{201d} with the wrong type: it is a function (i32) -> f64."
                ));
            }
        }
    }
    match module.get_export(EXPORT_MEMORY) {
        Some(ExternType::Memory(memory)) => {
            if memory.is_64() || memory.minimum().saturating_mul(PAGE) > LIMITS.memory_bytes {
                return refuse(format!(
                    "The module\u{2019}s memory starts over the {}-byte limit.",
                    LIMITS.memory_bytes
                ));
            }
        }
        _ => {
            return refuse(format!(
                "The module does not export its memory as \u{201c}{EXPORT_MEMORY}\u{201d}."
            ));
        }
    }
    let i32s = [ValType::I32; 7];
    for (name, params) in [
        (EXPORT_TILE_BUFFER, &i32s[..1]),
        (EXPORT_FILTER_TILE, &i32s[..]),
    ] {
        match module.get_export(name) {
            Some(ExternType::Func(ty))
                if is(ty.params(), params) && is(ty.results(), &[ValType::I32]) => {}
            Some(_) => {
                return refuse(format!(
                    "The module exports \u{201c}{name}\u{201d} with the wrong type: it takes {} i32 and returns i32.",
                    params.len()
                ));
            }
            None => {
                return refuse(format!(
                    "The module does not export the function \u{201c}{name}\u{201d}."
                ));
            }
        }
    }
    Ok(module)
}

struct Host {
    limits: StoreLimits,
    parameters: Vec<f64>,
}

/// `lw_filter_tile(pointer, width, height, x, y, frame_width, frame_height)`.
type TileArguments = (i32, i32, i32, i32, i32, i32, i32);

/// One instantiated plugin, good for the tiles of one run. After any failure it refuses every later call.
pub struct Instance {
    store: Store<Host>,
    memory: Memory,
    buffer: TypedFunc<i32, i32>,
    filter: TypedFunc<TileArguments, i32>,
    failed: bool,
}

/// What stopped a call, in the person's terms.
fn stopped(error: &wasmi::Error, fuel: u64) -> PluginError {
    PluginError(match error.as_trap_code() {
        Some(TrapCode::OutOfFuel) => format!(
            "It ran past its execution budget of {fuel} fuel for this call (an endless loop?) and was stopped."
        ),
        Some(TrapCode::StackOverflow) => format!(
            "It exceeded the stack limit of {} calls deep or {} bytes (unbounded recursion?) and was stopped.",
            LIMITS.recursion_depth, LIMITS.stack_bytes
        ),
        Some(TrapCode::MemoryOutOfBounds) => {
            "It read or wrote outside its own memory and was stopped.".into()
        }
        Some(TrapCode::UnreachableCodeReached) => {
            "It trapped (reached unreachable code) and was stopped.".into()
        }
        Some(TrapCode::GrowthOperationLimited) => format!(
            "It asked for more than its limit of {} bytes of memory or {} table elements and was stopped.",
            LIMITS.memory_bytes, LIMITS.table_elements
        ),
        _ => format!("It trapped and was stopped: {}.", shown(&error.to_string())),
    })
}

impl Instance {
    /// Validates `wasm` again and instantiates it with `parameters` as the values `param(index)` answers.
    pub fn new(wasm: &[u8], parameters: &[f64]) -> Result<Self, PluginError> {
        if parameters.len() as u64 > LIMITS.parameters {
            return refuse(format!(
                "A plugin takes at most {} parameters.",
                LIMITS.parameters
            ));
        }
        if parameters.iter().any(|value| !value.is_finite()) {
            return refuse("Every plugin parameter must be a finite number.");
        }
        let engine = engine();
        let module = compile(&engine, wasm)?;
        let limits = StoreLimitsBuilder::new()
            .memory_size(LIMITS.memory_bytes as usize)
            .table_elements(LIMITS.table_elements as usize)
            .instances(1)
            .memories(1)
            .tables(1)
            .trap_on_grow_failure(true)
            .build();
        let mut store = Store::new(
            &engine,
            Host {
                limits,
                parameters: parameters.to_vec(),
            },
        );
        store.limiter(|host| &mut host.limits);
        let mut linker = Linker::<Host>::new(&engine);
        linker
            .func_wrap(
                IMPORT_MODULE,
                IMPORT_PARAM,
                |caller: Caller<'_, Host>, index: i32| -> f64 {
                    usize::try_from(index)
                        .ok()
                        .and_then(|index| caller.data().parameters.get(index).copied())
                        .unwrap_or(0.0)
                },
            )
            .map_err(|error| {
                PluginError(format!(
                    "The filter interface could not be set up: {error}."
                ))
            })?;
        // Instantiation copies data and element segments, which is charged; a start function is refused at compile.
        store
            .set_fuel(LIMITS.fuel_filter_base)
            .map_err(|error| PluginError(error.to_string()))?;
        let instance = linker
            .instantiate_and_start(&mut store, &module)
            .map_err(|error| {
                let reason = stopped(&error, LIMITS.fuel_filter_base).0;
                PluginError(format!("The plugin could not be started. {reason}"))
            })?;
        let memory = instance
            .get_memory(&store, EXPORT_MEMORY)
            .ok_or_else(|| PluginError("The module does not export its memory.".into()))?;
        let buffer = instance
            .get_typed_func::<i32, i32>(&store, EXPORT_TILE_BUFFER)
            .map_err(|error| PluginError(shown(&error.to_string())))?;
        let filter = instance
            .get_typed_func::<TileArguments, i32>(&store, EXPORT_FILTER_TILE)
            .map_err(|error| PluginError(shown(&error.to_string())))?;
        Ok(Self {
            store,
            memory,
            buffer,
            filter,
            failed: false,
        })
    }

    /// The byte range `[pointer, pointer + bytes)` when it lies inside the plugin's memory as it is now.
    fn range(&self, pointer: i32, bytes: usize) -> Option<std::ops::Range<usize>> {
        let start = pointer as u32 as usize;
        let end = start.checked_add(bytes)?;
        (start != 0 && end <= self.memory.data_size(&self.store)).then_some(start..end)
    }

    /// Filters one tile in place. `pixels` holds `width × height` RGBA float32 values (straight alpha, linear); the
    /// tile's top-left pixel is (`x`, `y`) of a `frame_width × frame_height` layer. On any error the pixels are
    /// left exactly as they were given.
    #[allow(clippy::too_many_arguments)]
    pub fn filter_tile(
        &mut self,
        pixels: &mut [f32],
        width: u32,
        height: u32,
        x: u32,
        y: u32,
        frame_width: u32,
        frame_height: u32,
    ) -> Result<(), PluginError> {
        if self.failed {
            return refuse("The plugin already failed during this run.");
        }
        let count = u64::from(width) * u64::from(height);
        if width == 0
            || height == 0
            || count > LIMITS.tile_pixels
            || pixels.len() as u64 != count * 4
        {
            return refuse(format!(
                "A tile carries from 1 through {} pixels.",
                LIMITS.tile_pixels
            ));
        }
        let inside = u64::from(x) + u64::from(width) <= u64::from(frame_width)
            && u64::from(y) + u64::from(height) <= u64::from(frame_height);
        if !inside || frame_width > i32::MAX as u32 || frame_height > i32::MAX as u32 {
            return refuse("The tile does not lie inside its layer.");
        }
        let result = self.run(pixels, width, height, x, y, frame_width, frame_height);
        self.failed = result.is_err();
        result
    }

    #[allow(clippy::too_many_arguments)]
    fn run(
        &mut self,
        pixels: &mut [f32],
        width: u32,
        height: u32,
        x: u32,
        y: u32,
        frame_width: u32,
        frame_height: u32,
    ) -> Result<(), PluginError> {
        let bytes = pixels.len() * 4;
        let fuel_error = |error: wasmi::Error| PluginError(error.to_string());
        self.store
            .set_fuel(LIMITS.fuel_buffer_call)
            .map_err(fuel_error)?;
        let pointer = self
            .buffer
            .call(&mut self.store, bytes as i32)
            .map_err(|error| stopped(&error, LIMITS.fuel_buffer_call))?;
        let Some(range) = self.range(pointer, bytes) else {
            return refuse(format!(
                "It did not provide a {bytes}-byte tile buffer inside its own memory."
            ));
        };
        {
            let target = &mut self.memory.data_mut(&mut self.store)[range];
            for (chunk, value) in target.chunks_exact_mut(4).zip(pixels.iter()) {
                chunk.copy_from_slice(&value.to_le_bytes());
            }
        }
        let fuel =
            LIMITS.fuel_filter_base + LIMITS.fuel_per_pixel * u64::from(width) * u64::from(height);
        self.store.set_fuel(fuel).map_err(fuel_error)?;
        let arguments = (
            pointer,
            width as i32,
            height as i32,
            x as i32,
            y as i32,
            frame_width as i32,
            frame_height as i32,
        );
        let status = self
            .filter
            .call(&mut self.store, arguments)
            .map_err(|error| stopped(&error, fuel))?;
        if status != 0 {
            return refuse(format!("It reported failure (code {status})."));
        }
        // The plugin may have grown or otherwise changed its memory: the output range is checked again.
        let Some(range) = self.range(pointer, bytes) else {
            return refuse("Its tile buffer no longer lies inside its own memory.");
        };
        let source = &self.memory.data(&self.store)[range];
        // Checked whole before anything is copied out, so a refused tile leaves `pixels` untouched.
        for (index, chunk) in source.chunks_exact(4).enumerate() {
            let value = f32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]);
            if !value.is_finite() {
                return refuse("It returned a value that is not a finite number.");
            }
            if index % 4 == 3 && !(0.0..=1.0).contains(&value) {
                return refuse("It returned an alpha value outside 0 through 1.");
            }
        }
        for (chunk, value) in source.chunks_exact(4).zip(pixels.iter_mut()) {
            *value = f32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]);
        }
        Ok(())
    }
}
