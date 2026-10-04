//! Isolated full-resolution retained decoder. No catalog handle/SQLite owner is
//! opened here. Source authority comes only from a retained prepared export plan.
use anyhow::{Context, Result, ensure};
use photocatalog::{
    application::exports::{DecodeLimits, Plan},
    media, metadata_export,
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    io::{Read, Seek, SeekFrom, Write},
    path::Path,
    process::{Child, Command, Stdio},
    sync::atomic::{AtomicBool, Ordering},
    time::{Duration, Instant},
};
const MAGIC: &[u8; 8] = b"LWFLT002";
const MAX_HEADER: usize = 1024 * 1024;
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Input {
    plan: Plan,
    limits: DecodeLimits,
    worker_bytes: u64,
    max_output_bytes: u64,
}
fn limits(i: &Input) -> Result<media::DecodeLimits> {
    let l = media::DecodeLimits {
        max_encoded_bytes: i.limits.max_encoded_bytes.0,
        max_intermediate_pixels: i.limits.max_intermediate_pixels.0,
        max_allocation_bytes: i.limits.max_allocation_bytes.0,
    };
    l.validate()?;
    ensure!(
        [
            l.max_encoded_bytes,
            l.max_intermediate_pixels,
            l.max_allocation_bytes,
            i.worker_bytes,
            i.max_output_bytes
        ]
        .iter()
        .all(|n| *n != 0 && *n != u64::MAX),
        "explicit finite decode ceilings required"
    );
    ensure!(
        l.max_allocation_bytes <= i.worker_bytes && i.max_output_bytes <= i.worker_bytes,
        "decode/output allocations exceed worker allowance"
    );
    Ok(l)
}
fn check_source(i: &Input) -> Result<metadata_export::FileRevision> {
    let path = i.plan.original.to_path()?;
    let actual = metadata_export::inspect_file_revision(&path, i.limits.max_encoded_bytes.0)?;
    let expected = &i.plan.original_revision;
    ensure!(
        actual.bytes == expected.bytes.0
            && actual.digest == expected.digest
            && actual.modified_ns == expected.modified_ns.0
            && actual.identity == (expected.identity.0.0, expected.identity.1.0),
        "source physical/content revision changed"
    );
    ensure!(
        i.plan
            .identity
            .source
            .fingerprint
            .as_ref()
            .is_some_and(|f| f == &actual.digest),
        "source fingerprint missing or changed"
    );
    Ok(actual)
}
pub fn worker_main() -> Result<()> {
    let mut input = Vec::new();
    std::io::stdin()
        .take((MAX_HEADER + 1) as u64)
        .read_to_end(&mut input)?;
    ensure!(input.len() <= MAX_HEADER, "decode request header allowance");
    let i: Input = serde_json::from_slice(&input)?;
    let l = limits(&i)?;
    let before = check_source(&i)?;
    let rendered = media::decode_full_limited(&i.plan.original.to_path()?, l)?;
    let count = u64::from(rendered.width)
        .checked_mul(rendered.height.into())
        .context("pixel extent overflow")?;
    let extent = count.checked_mul(16).context("float extent overflow")?;
    ensure!(
        extent <= i.max_output_bytes && rendered.pixels.len() as u64 == count,
        "float output extent allowance"
    );
    ensure!(check_source(&i)? == before, "source changed during decode");
    let descriptor = json!({"source_revision":crate::SOURCE_REVISION,"protocol":2,"kind":"float","mime":"application/x-lensworks-rgba-f32le","width":rendered.width,"height":rendered.height,"row_stride":(u64::from(rendered.width)*16).to_string(),"byte_length":extent.to_string(),"channels":4,"sample":"float32_le","color_space":"linear_srgb","alpha":"straight","orientation":"applied","metadata":rendered.metadata,"provenance":rendered.provenance,"source_identity":i.plan.identity,"original":i.plan.original,"original_revision":i.plan.original_revision,"plan_authority":i.plan.authority,"memory_enforcement":"explicit per-surface limits and sampled child RSS watchdog; native scratch is not a hard RSS ceiling"});
    let header = serde_json::to_vec(&descriptor)?;
    ensure!(header.len() <= MAX_HEADER, "float descriptor allowance");
    let mut output = std::io::BufWriter::new(std::io::stdout().lock());
    output.write_all(MAGIC)?;
    output.write_all(&(header.len() as u64).to_le_bytes())?;
    output.write_all(&extent.to_le_bytes())?;
    output.write_all(&header)?;
    for pixel in &rendered.pixels {
        ensure!(
            pixel.iter().all(|v| v.is_finite()) && (0.0..=1.0).contains(&pixel[3]),
            "invalid retained float pixel"
        );
        for sample in pixel {
            output.write_all(&sample.to_le_bytes())?;
        }
    }
    output.flush()?;
    Ok(())
}
struct ChildOwner(Option<Child>);
impl Drop for ChildOwner {
    fn drop(&mut self) {
        if let Some(c) = self.0.as_mut() {
            let _ = c.kill();
            let _ = c.wait();
        }
    }
}
#[cfg(target_os = "macos")]
fn rss(pid: u32) -> Result<u64> {
    // PROC_PIDTASKINFO from the installed SDK. The first two u64 fields are
    // virtual_size/resident_size; remaining counters are irrelevant to admission.
    #[link(name = "proc")]
    unsafe extern "C" {
        fn proc_pidinfo(
            pid: i32,
            flavor: i32,
            arg: u64,
            buffer: *mut std::ffi::c_void,
            size: i32,
        ) -> i32;
    }
    let mut info = [0u64; 12];
    let n = unsafe {
        proc_pidinfo(
            pid as i32,
            4,
            0,
            info.as_mut_ptr().cast(),
            std::mem::size_of_val(&info) as i32,
        )
    };
    ensure!(
        n == std::mem::size_of_val(&info) as i32,
        "child RSS unavailable"
    );
    Ok(info[1])
}
#[cfg(target_os = "linux")]
fn rss(pid: u32) -> Result<u64> {
    let s = std::fs::read_to_string(format!("/proc/{pid}/status"))?;
    let n = s
        .lines()
        .find_map(|l| l.strip_prefix("VmRSS:"))
        .context("child RSS unavailable")?
        .split_whitespace()
        .next()
        .context("child RSS missing")?
        .parse::<u64>()?;
    Ok(n * 1024)
}
#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn rss(_: u32) -> Result<u64> {
    anyhow::bail!("child RSS watchdog unsupported on host")
}
pub(crate) fn run(
    worker: &Path,
    plan: Plan,
    decode: DecodeLimits,
    worker_bytes: u64,
    max_output_bytes: u64,
    cancel: &AtomicBool,
) -> Result<(Vec<u8>, Value)> {
    let i = Input {
        plan,
        limits: decode,
        worker_bytes,
        max_output_bytes,
    };
    limits(&i)?;
    ensure!(
        !cancel.load(Ordering::Acquire),
        "decode canceled before launch"
    );
    let encoded = serde_json::to_vec(&i)?;
    ensure!(
        encoded.len() <= MAX_HEADER,
        "decode request header allowance"
    );
    let mut input = tempfile::tempfile()?;
    input.write_all(&encoded)?;
    input.seek(SeekFrom::Start(0))?;
    let mut output = tempfile::tempfile()?;
    let stderr = tempfile::tempfile()?;
    let child = Command::new(worker)
        .arg("--lensworks-full-decode")
        .stdin(Stdio::from(input))
        .stdout(Stdio::from(output.try_clone()?))
        .stderr(Stdio::from(stderr.try_clone()?))
        .spawn()?;
    let mut owner = ChildOwner(Some(child));
    let start = Instant::now();
    let mut sample = Instant::now();
    let exit = loop {
        let c = owner.0.as_mut().unwrap();
        if let Some(status) = c.try_wait()? {
            break status;
        }
        ensure!(
            !cancel.load(Ordering::Acquire),
            "decode canceled; child terminated and reaped"
        );
        ensure!(
            start.elapsed() < Duration::from_secs(120),
            "decode worker deadline"
        );
        ensure!(
            output.metadata()?.len() <= max_output_bytes + MAX_HEADER as u64 + 24,
            "decode worker frame exceeded extent"
        );
        ensure!(
            stderr.metadata()?.len() <= 65536,
            "decode worker diagnostic allowance"
        );
        if sample.elapsed() >= Duration::from_millis(50) {
            ensure!(
                rss(c.id())? <= worker_bytes,
                "decode child resident memory exceeded watchdog allowance"
            );
            sample = Instant::now();
        }
        std::thread::sleep(Duration::from_millis(10));
    };
    owner.0.take();
    ensure!(
        output.metadata()?.len() <= max_output_bytes + MAX_HEADER as u64 + 24
            && stderr.metadata()?.len() <= 65536,
        "final decode frame/diagnostic allowance"
    );
    ensure!(
        exit.success(),
        "decode worker failed ({exit}); source mismatch, resource admission or retained decoder failure"
    );
    ensure!(
        !cancel.load(Ordering::Acquire),
        "decode canceled after child drain"
    );
    output.seek(SeekFrom::Start(0))?;
    let mut prefix = [0u8; 24];
    output.read_exact(&mut prefix)?;
    ensure!(&prefix[..8] == MAGIC, "invalid float frame version");
    let header = u64::from_le_bytes(prefix[8..16].try_into()?);
    let bytes = u64::from_le_bytes(prefix[16..24].try_into()?);
    ensure!(
        header <= MAX_HEADER as u64
            && bytes <= max_output_bytes
            && output.metadata()?.len() == 24 + header + bytes,
        "float frame bounds"
    );
    let mut descriptor = vec![0; header as usize];
    output.read_exact(&mut descriptor)?;
    let descriptor: Value = serde_json::from_slice(&descriptor)?;
    let width = descriptor["width"].as_u64().context("float width")?;
    let height = descriptor["height"].as_u64().context("float height")?;
    ensure!(
        width > 0
            && height > 0
            && width.checked_mul(height).and_then(|n| n.checked_mul(16)) == Some(bytes)
            && descriptor["sample"] == "float32_le"
            && descriptor["color_space"] == "linear_srgb"
            && descriptor["alpha"] == "straight"
            && descriptor["row_stride"] == (width * 16).to_string()
            && descriptor["byte_length"] == bytes.to_string(),
        "float descriptor extent/color mismatch"
    );
    ensure!(
        descriptor["source_revision"] == crate::SOURCE_REVISION
            && descriptor["protocol"] == 2
            && descriptor["kind"] == "float"
            && descriptor["mime"] == "application/x-lensworks-rgba-f32le"
            && descriptor["channels"] == 4
            && descriptor["orientation"] == "applied",
        "float protocol/provenance header mismatch"
    );
    ensure!(
        descriptor["source_identity"] == serde_json::to_value(&i.plan.identity)?
            && descriptor["original"] == serde_json::to_value(&i.plan.original)?
            && descriptor["original_revision"] == serde_json::to_value(&i.plan.original_revision)?
            && descriptor["plan_authority"] == i.plan.authority,
        "float source authority mismatch"
    );
    let mut pixels = vec![0; bytes as usize];
    let _: media::Metadata =
        serde_json::from_value(descriptor["metadata"].clone()).context("float metadata schema")?;
    let _: media::RenderProvenance = serde_json::from_value(descriptor["provenance"].clone())
        .context("float provenance schema")?;
    output.read_exact(&mut pixels)?;
    for pixel in pixels.chunks_exact(16) {
        let values: [f32; 4] = std::array::from_fn(|c| {
            f32::from_le_bytes(pixel[c * 4..c * 4 + 4].try_into().unwrap())
        });
        ensure!(
            values.iter().all(|v| v.is_finite()) && (0.0..=1.0).contains(&values[3]),
            "invalid float samples/alpha"
        );
    }
    Ok((pixels, descriptor))
}
