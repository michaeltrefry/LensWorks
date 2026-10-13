use lensworks_catalog::*;
use photocatalog::{application as app, storage_volume::NativePath};
use serde_json::{Value, json};
use std::{
    path::Path,
    sync::{
        Mutex,
        atomic::{AtomicBool, AtomicUsize, Ordering},
    },
    time::{Duration, Instant},
};
static TEST_GATE: Mutex<()> = Mutex::new(());
thread_local! { static TEST_ROOTS: std::cell::RefCell<Vec<std::sync::Arc<tempfile::TempDir>>> = const { std::cell::RefCell::new(Vec::new()) }; }
thread_local! { static TEST_SESSIONS: std::cell::RefCell<Vec<String>> = const { std::cell::RefCell::new(Vec::new()) }; }
struct TestScope(std::sync::MutexGuard<'static, ()>);
impl TestScope {
    fn new() -> Self {
        let serial = TEST_GATE.lock().unwrap_or_else(|e| e.into_inner());
        TEST_SESSIONS.with(|v| v.borrow_mut().clear());
        Self(serial)
    }
}
impl Drop for TestScope {
    fn drop(&mut self) {
        let sessions = TEST_SESSIONS.with(|v| std::mem::take(&mut *v.borrow_mut()));
        for s in sessions {
            // This guard also runs after an assertion panic. The API owns the
            // child until checked shutdown succeeds; never abandon that owner.
            let cleaned = std::panic::catch_unwind(|| {
                let until = Instant::now() + Duration::from_secs(30);
                loop {
                    let r = command("session_shutdown", json!({"session":s}));
                    if r["error"]["code"] == "invalid_handle" {
                        return;
                    }
                    if r["ok"] == true {
                        assert_eq!(command("session_release", json!({"session":s}))["ok"], true);
                        return;
                    }
                    assert!(Instant::now() < until, "fixture cleanup timeout: {r}");
                    std::thread::sleep(Duration::from_millis(5));
                }
            });
            if cleaned.is_err() && !std::thread::panicking() {
                panic!("fixture owner cleanup failed");
            }
        }
        TEST_ROOTS.with(|v| v.borrow_mut().clear());
        let _ = &self.0; // Keep the test serialization guard through teardown.
    }
}
fn native(p: &Path) -> Value {
    serde_json::to_value(NativePath::from_path(p)).unwrap()
}
fn read_buffer(id: u64, size: usize) -> Vec<u8> {
    let mut data = vec![0; size];
    let mut n = 0;
    assert_eq!(
        unsafe { lw_catalog_buffer_copy(id, 0, data.as_mut_ptr(), data.len(), &mut n) },
        0
    );
    data.truncate(n);
    data
}
fn call(value: Value) -> Value {
    let bytes = serde_json::to_vec(&value).unwrap();
    let mut output = 0;
    assert_eq!(
        unsafe { lw_catalog_managed_request(bytes.as_ptr(), bytes.len(), &mut output) },
        0
    );
    let result = serde_json::from_slice(&read_buffer(output, 4 * 1024 * 1024)).unwrap();
    assert_eq!(lw_catalog_buffer_release(output), 0);
    result
}
fn command(op: &str, args: Value) -> Value {
    let mut v = args;
    v["version"] = json!(2);
    v["op"] = json!(op);
    let response = call(v);
    if op == "session_create" {
        if let Some(s) = response["result"]["session"].as_str() {
            TEST_SESSIONS.with(|v| v.borrow_mut().push(s.to_owned()));
        }
    }
    response
}
fn submit(s: &str, request: Value) -> String {
    let r = command("submit", json!({"session":s,"request":request}));
    assert_eq!(r["ok"], true, "{r}");
    r["result"]["job"].as_str().unwrap().into()
}
fn take(j: &str) -> Value {
    let until = Instant::now() + Duration::from_secs(30);
    loop {
        let r = command("job_result", json!({"job":j}));
        if r["ok"] == true || r["error"]["code"] != "busy" {
            return r;
        }
        assert!(Instant::now() < until, "job timeout {j}");
        std::thread::sleep(Duration::from_millis(5));
    }
}
fn rpc(s: &str, request: Value) -> Value {
    let j = submit(s, request);
    let r = take(&j);
    assert_eq!(r["ok"], true, "{r}");
    let id = r["result"]["buffer"].as_str().unwrap().parse().unwrap();
    let n = r["result"]["length"].as_str().unwrap().parse().unwrap();
    let result = serde_json::from_slice(&read_buffer(id, n)).unwrap();
    assert_eq!(lw_catalog_buffer_release(id), 0);
    assert_eq!(command("job_release", json!({"job":j}))["ok"], true);
    result
}
fn session(worker: &Path, root: &Path) -> String {
    let r = command(
        "session_create",
        json!({"config":{"worker_executable":native(worker),"cache_root":native(&root.join("cache")),"original_roots":[native(&root.join("originals"))]}}),
    );
    assert_eq!(r["ok"], true, "{r}");
    let s = r["result"]["session"].as_str().unwrap().to_string();
    assert_eq!(
        r["result"]["phase"],
        "ready",
        "{}",
        command("session_status", json!({"session":s}))
    );
    s
}
fn shutdown(s: &str) {
    let until = Instant::now() + Duration::from_secs(30);
    loop {
        let r = command("session_shutdown", json!({"session":s}));
        if r["ok"] == true {
            break;
        }
        assert_eq!(r["error"]["code"], "draining", "{r}");
        assert!(Instant::now() < until, "shutdown timeout");
        std::thread::sleep(Duration::from_millis(5));
    }
    assert_eq!(command("session_release", json!({"session":s}))["ok"], true);
}
fn fixture() -> (std::sync::Arc<tempfile::TempDir>, String, String, Value) {
    fixture_with_sidecar(None)
}
fn fixture_with_sidecar(
    sidecar: Option<&str>,
) -> (std::sync::Arc<tempfile::TempDir>, String, String, Value) {
    let temp = std::sync::Arc::new(tempfile::tempdir().unwrap());
    TEST_ROOTS.with(|v| v.borrow_mut().push(temp.clone()));
    let originals = temp.path().join("originals");
    std::fs::create_dir(&originals).unwrap();
    image::RgbImage::from_pixel(32, 24, image::Rgb([12, 80, 200]))
        .save(originals.join("photo.png"))
        .unwrap();
    if let Some(sidecar) = sidecar {
        std::fs::write(originals.join("photo.xmp"), sidecar).unwrap();
    }
    let s = session(
        Path::new(env!("CARGO_BIN_EXE_lensworks-decode-worker")),
        temp.path(),
    );
    let create = rpc(
        &s,
        json!({"command":"create","args":{"path":native(&temp.path().join("catalog"))}}),
    );
    assert_eq!(create["status"], "ok", "{create}");
    let catalog = create["value"]["data"]["catalog"]
        .as_str()
        .unwrap()
        .to_string();
    let start = rpc(
        &s,
        json!({"command":"import_start","args":{"catalog":catalog,"source":native(&originals)}}),
    );
    assert_eq!(start["status"], "ok", "{start}");
    let until = Instant::now() + Duration::from_secs(30);
    loop {
        let v = rpc(
            &s,
            json!({"command":"import_status","args":{"catalog":catalog}}),
        );
        let phase = &v["value"]["data"]["phase"];
        if phase == "complete" {
            break;
        }
        assert!(phase != "failed", "{v}");
        assert!(Instant::now() < until, "import timeout {v}");
        std::thread::sleep(Duration::from_millis(10));
    }
    let images = rpc(
        &s,
        json!({"command":"images","args":{"catalog":catalog,"folder":null,"recursive":true,"text":null,"cursor":null,"limit":10}}),
    );
    assert_eq!(images["status"], "ok", "{images}");
    let key = images["value"]["data"]["rows"][0]["key"].clone();
    assert!(key.is_object(), "{images}");
    (temp, s, catalog, key)
}
#[test]
fn managed_fixture_assertion_unwind_checks_shutdown_and_reaps_owned_worker() {
    let retained = Mutex::new(None);
    let result = std::panic::catch_unwind(|| {
        let _scope = TestScope::new();
        let (_temp, s, _, _) = fixture();
        let status = command("session_status", json!({"session":s}));
        let pid = status["result"]["pid"].as_i64().unwrap() as libc::pid_t;
        *retained.lock().unwrap() = Some((s, pid));
        panic!("injected fixture assertion failure");
    });
    assert!(result.is_err());
    let (s, pid) = retained.lock().unwrap().take().unwrap();
    assert_eq!(
        command("session_status", json!({"session":s}))["error"]["code"],
        "invalid_handle"
    );
    assert_eq!(
        unsafe { libc::kill(pid, 0) },
        -1,
        "fixture worker must be reaped"
    );
    assert_eq!(
        std::io::Error::last_os_error().raw_os_error(),
        Some(libc::ESRCH)
    );
}
#[cfg(unix)]
#[test]
fn managed_stopped_real_worker_shutdown_is_finite_and_retryable() {
    let _scope = TestScope::new();
    let (_temp, s, _, _) = fixture();
    let status = command("session_status", json!({"session":s}));
    let pid = status["result"]["pid"].as_i64().unwrap() as libc::pid_t;
    assert!(pid > 0);
    struct Resume(libc::pid_t);
    impl Drop for Resume {
        fn drop(&mut self) {
            unsafe {
                libc::kill(self.0, libc::SIGCONT);
            }
        }
    }
    let resume = Resume(pid);
    assert_eq!(unsafe { libc::kill(pid, libc::SIGSTOP) }, 0);
    for _ in 0..3 {
        let start = Instant::now();
        let shutdown = command("session_shutdown", json!({"session":s}));
        assert_eq!(shutdown["error"]["code"], "draining", "{shutdown}");
        assert!(start.elapsed() < Duration::from_millis(250));
        let status = command("session_status", json!({"session":s}));
        assert_eq!(status["result"]["phase"], "draining");
        assert_eq!(
            command("session_release", json!({"session":s}))["error"]["code"],
            "busy"
        );
        std::thread::sleep(Duration::from_millis(10));
    }
    drop(resume);
    shutdown(&s);
    assert_eq!(unsafe { libc::kill(pid, 0) }, -1);
    assert_eq!(
        std::io::Error::last_os_error().raw_os_error(),
        Some(libc::ESRCH)
    );
}

#[test]
fn managed_actual_worker_lifecycle_and_service_errors() {
    let _gate = TestScope::new();
    let (temp, s, c, key) = fixture();
    let original = temp.path().join("originals/photo.png");
    let before = std::fs::read(&original).unwrap();
    let families = [
        (
            "organization",
            json!({"command":"keywords","args":{"kind":"flat","parent":null,"after":"0","limit":10}}),
        ),
        ("metadata", json!({"command":"identity","args":{"key":key}})),
        ("metadata_write", json!({"command":"options"})),
        ("export", json!({"command":"options"})),
        (
            "edit_copy",
            json!({"command":"jobs","args":{"after":"0","limit":"10"}}),
        ),
        ("relink", json!({"command":"mounts"})),
        ("preview_settings", json!({"command":"status"})),
    ];
    for (name, request) in families {
        let result = rpc(
            &s,
            json!({"command":name,"args":{"catalog":c,"request":request}}),
        );
        assert_eq!(result["status"], "ok", "{name}: {result}");
        assert_eq!(result["value"]["kind"], name);
    }
    let lightroom = rpc(
        &s,
        json!({"command":"lightroom","args":{"request":{"kind":"Options"}}}),
    );
    assert_eq!(lightroom["status"], "ok", "{lightroom}");
    let stale = rpc(
        &s,
        json!({"command":"variant","args":{"catalog":"not-a-session","key":key}}),
    );
    assert_eq!(stale["status"], "error");
    assert_eq!(stale["error"]["code"], "stale_session");
    let bad = command(
        "submit",
        json!({"session":s,"request":{"command":"history","args":{"catalog":c,"key":key,"after":9007199254740993u64,"limit":10}}}),
    );
    assert_eq!(bad["error"]["code"], "invalid_request");
    let v1 = json!({"version":1,"op":"open","catalog_path":temp.path().join("catalog")});
    let text = std::ffi::CString::new(v1.to_string()).unwrap();
    let ptr = unsafe { lw_catalog_request(text.as_ptr()) };
    let value: Value =
        serde_json::from_slice(unsafe { std::ffi::CStr::from_ptr(ptr) }.to_bytes()).unwrap();
    unsafe { lw_catalog_string_free(ptr) };
    assert_eq!(value["error"]["code"], "busy");
    assert_eq!(std::fs::read(&original).unwrap(), before);
    shutdown(&s);
    assert_eq!(
        command("session_status", json!({"session":s}))["error"]["code"],
        "invalid_handle"
    );
}

struct Callback {
    entered: AtomicUsize,
    release: AtomicBool,
}
unsafe extern "C" fn callback(context: *mut std::ffi::c_void, _: u64, _: u64) {
    let cb = unsafe { &*(context as *const Callback) };
    cb.entered.fetch_add(1, Ordering::AcqRel);
    while !cb.release.load(Ordering::Acquire) {
        std::thread::sleep(Duration::from_millis(1));
    }
}
#[test]
fn managed_handles_buffers_callbacks_and_cancellation() {
    let _gate = TestScope::new();
    let (temp, s, _, _) = fixture();
    let context = Box::new(Callback {
        entered: AtomicUsize::new(0),
        release: AtomicBool::new(false),
    });
    let mut sub = 0;
    assert_eq!(
        unsafe {
            lw_catalog_subscribe(
                s.parse().unwrap(),
                Some(callback),
                (&*context as *const Callback).cast_mut().cast(),
                &mut sub,
            )
        },
        0
    );
    let j = submit(&s, json!({"command":"status"}));
    let until = Instant::now() + Duration::from_secs(10);
    while context.entered.load(Ordering::Acquire) == 0 {
        assert!(Instant::now() < until);
        std::thread::sleep(Duration::from_millis(2));
    }
    // Completion callback is blocked; out-of-band cancellation and result reading
    // still proceed on independent callers, never on its receiver/main actor.
    let cancel = std::thread::spawn({
        let j = j.clone();
        move || command("job_cancel", json!({"job":j}))
    });
    assert_eq!(cancel.join().unwrap()["ok"], true);
    let result = take(&j);
    assert_eq!(result["ok"], true);
    let b: u64 = result["result"]["buffer"]
        .as_str()
        .unwrap()
        .parse()
        .unwrap();
    let mut n = 0;
    assert_eq!(
        unsafe { lw_catalog_buffer_copy(b, usize::MAX, std::ptr::null_mut(), 0, &mut n) },
        5
    );
    assert_eq!(lw_catalog_buffer_release(0), 4);
    assert_eq!(lw_catalog_unsubscribe_and_drain(sub, 0), 6);
    context.release.store(true, Ordering::Release);
    assert_eq!(lw_catalog_unsubscribe_and_drain(sub, 1000), 0);
    drop(context);
    assert_eq!(lw_catalog_unsubscribe_and_drain(sub, 0), 4);
    shutdown(&s);
    assert!(!read_buffer(b, 4096).is_empty());
    assert_eq!(lw_catalog_buffer_release(b), 0);
    assert_eq!(lw_catalog_buffer_release(b), 4);
    assert_eq!(command("job_release", json!({"job":j}))["ok"], true);
    assert_eq!(
        command("job_status", json!({"job":j}))["error"]["code"],
        "invalid_handle"
    );
    let mut out = 123;
    assert_eq!(
        unsafe { lw_catalog_managed_request(std::ptr::null(), 1, &mut out) },
        1
    );
    assert_eq!(out, 0);
    let mut out = 123;
    assert_eq!(
        unsafe { lw_catalog_managed_request(std::ptr::null(), 4 * 1024 * 1024 + 1, &mut out) },
        2
    );
    assert_eq!(out, 0);
    drop(temp);
}

#[test]
fn managed_retained_worker_failure_and_shutdown() {
    let _gate = TestScope::new();
    let temp = tempfile::tempdir().unwrap();
    let r = command(
        "session_create",
        json!({"config":{"worker_executable":native(&temp.path().join("missing-worker"))}}),
    );
    assert_eq!(r["ok"], true, "{r}");
    assert_eq!(r["result"]["phase"], "retained_startup");
    let s = r["result"]["session"].as_str().unwrap();
    assert_eq!(
        command(
            "submit",
            json!({"session":s,"request":{"command":"status"}})
        )["error"]["code"],
        "retained_startup"
    );
    shutdown(s);
}

#[test]
fn managed_source_plan_float_and_original_preservation() {
    let _gate = TestScope::new();
    let (temp, s, c, _) = fixture();
    let hdr = temp.path().join("originals/hdr.tif");
    let profile = photocatalog::media::linear_profile()
        .unwrap()
        .icc()
        .unwrap();
    {
        let file = std::fs::File::create(&hdr).unwrap();
        let mut encoder = tiff::encoder::TiffEncoder::new(file).unwrap();
        let mut image = encoder
            .new_image::<tiff::encoder::colortype::RGBA32Float>(2, 2)
            .unwrap();
        image
            .encoder()
            .write_tag(tiff::tags::Tag::IccProfile, profile.as_slice())
            .unwrap();
        image
            .write_data(&[
                -0.2f32, 4.0, 0.3, 1.0, 0.1, 0.5, 0.8, 0.5, 2.0, -0.1, 0.3, 0.0, 0.3, 0.4, 0.5, 1.0,
            ])
            .unwrap();
    }
    let before = std::fs::read(&hdr).unwrap();
    let mtime = std::fs::metadata(&hdr).unwrap().modified().unwrap();
    let originals = temp.path().join("originals");
    let start = rpc(
        &s,
        json!({"command":"import_resume","args":{"catalog":c,"source":native(&originals)}}),
    );
    assert_eq!(start["status"], "ok", "{start}");
    let until = Instant::now() + Duration::from_secs(30);
    loop {
        let status = rpc(&s, json!({"command":"import_status","args":{"catalog":c}}));
        if status["value"]["data"]["phase"] == "complete" {
            break;
        }
        assert!(Instant::now() < until, "{status}");
        std::thread::sleep(Duration::from_millis(5));
    }
    let images = rpc(
        &s,
        json!({"command":"images","args":{"catalog":c,"folder":null,"recursive":true,"text":"hdr.tif","cursor":null,"limit":10}}),
    );
    let key = images["value"]["data"]["rows"][0]["key"].clone();
    assert!(key.is_object(), "{images}");
    let mut recipe = photocatalog::edit::Recipe::default();
    let photocatalog::edit::Recipe::V1(ref mut settings) = recipe;
    settings.exposure_ev = 1.0;
    let saved = rpc(
        &s,
        json!({"command":"save_recipe","args":{"catalog":c,"key":key,"expected_revision":"0","recipe":recipe}}),
    );
    assert_eq!(saved["status"], "ok", "{saved}");
    let revision = saved["value"]["data"]["revision"].clone();
    let destination = temp.path().canonicalize().unwrap().join("derivative.tif");
    let export = |request: Value| {
        rpc(
            &s,
            json!({"command":"export","args":{"catalog":c,"request":request}}),
        )
    };
    let begin = export(json!({"command":"begin"}));
    assert_eq!(begin["status"], "ok", "{begin}");
    let id = begin["value"]["data"]["value"]["id"].as_str().unwrap();
    let output = app::exports::Output {
        size: photocatalog::image_export::OutputSize::Original,
        format: photocatalog::image_export::OutputFormat::Tiff {
            depth: photocatalog::image_export::TiffDepth::Float32,
        },
        profile: app::exports::Profile::LinearSrgb,
        alpha: photocatalog::image_export::AlphaPolicy::Preserve,
    };
    let append = export(
        json!({"command":"append","args":{"job":id,"expected_total":"0","target":{"key":key,"expected_revision":revision,"destination":native(&destination),"overwrite":false,"metadata":{"mode":"omit"}},"output":output,"budgets":{"max_original_bytes":"1048576","max_payload_bytes":"1048576","alias_limits":{"directories":"32","candidates":"256"}}}}),
    );
    assert_eq!(append["status"], "ok", "{append}");
    let op = append["value"]["data"]["value"]["id"].as_str().unwrap();
    let until = Instant::now() + Duration::from_secs(10);
    loop {
        let status = export(json!({"command":"status","args":{"operation":op}}));
        let operation = &status["value"]["data"]["value"];
        if operation["phase"] == "complete" {
            break;
        }
        assert!(operation["phase"] != "failed", "{status}");
        assert!(Instant::now() < until, "{status}");
        std::thread::sleep(Duration::from_millis(5));
    }
    let seal = export(json!({"command":"seal","args":{"job":id,"expected_total":"1"}}));
    assert_eq!(seal["status"], "ok", "{seal}");
    let source = command(
        "source_identity",
        json!({"session":s,"catalog":c,"export_job":id,"sequence":"1"}),
    );
    assert_eq!(source["ok"], true, "{source}");
    let sj = source["result"]["job"].as_str().unwrap();
    let sr = take(sj);
    assert_eq!(sr["ok"], true, "{sr}");
    let sb = sr["result"]["buffer"].as_str().unwrap().parse().unwrap();
    let plan: Value = serde_json::from_slice(&read_buffer(sb, 4 * 1024 * 1024)).unwrap();
    assert_eq!(plan["identity"]["revision"], revision);
    assert_eq!(
        plan["identity"]["recipe_digest"],
        recipe.validate().unwrap().digest()
    );
    assert_eq!(
        plan["identity"]["source"]["fingerprint"],
        blake3::hash(&before).to_hex().to_string()
    );
    assert_eq!(lw_catalog_buffer_release(sb), 0);
    command("job_release", json!({"job":sj}));
    let args = json!({"session":s,"catalog":c,"export_job":id,"sequence":"1","limits":{"max_encoded_bytes":"1048576","max_intermediate_pixels":"10000","max_allocation_bytes":"1048576"},"worker_bytes":"536870912","max_output_bytes":"64"});
    let decode = command("decode_full", args.clone());
    assert_eq!(decode["ok"], true, "{decode}");
    let dj = decode["result"]["job"].as_str().unwrap();
    let result = take(dj);
    assert_eq!(result["ok"], true, "{result}");
    let d = &result["result"]["descriptor"];
    assert_eq!(d["width"], 2);
    assert_eq!(d["height"], 2);
    assert_eq!(d["row_stride"], "32");
    assert_eq!(d["color_space"], "linear_srgb");
    assert_eq!(d["alpha"], "straight");
    assert!(d["provenance"].is_object());
    let b = result["result"]["buffer"]
        .as_str()
        .unwrap()
        .parse()
        .unwrap();
    let pixels = read_buffer(b, 64);
    let floats: Vec<f32> = pixels
        .chunks_exact(4)
        .map(|v| f32::from_le_bytes(v.try_into().unwrap()))
        .collect();
    assert!(floats[0] < 0.0 && floats[1] > 1.0, "{floats:?}");
    assert_eq!(floats[7], 0.5);
    assert_eq!(lw_catalog_buffer_release(b), 0);
    command("job_release", json!({"job":dj}));
    assert_eq!(std::fs::read(&hdr).unwrap(), before);
    assert_eq!(std::fs::metadata(&hdr).unwrap().modified().unwrap(), mtime);
    assert_eq!(std::fs::read_dir(&originals).unwrap().count(), 2);
    assert!(!temp.path().join("derivative.tif").exists());
    shutdown(&s);
    // A hostile/stale helper fixture must not bypass the parent's authority,
    // frame, sample, or child-drain validation, even with a valid retained plan.
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let worker = temp.path().join("fault-decode-worker");
        let template = r#"#!/usr/bin/python3
import sys,json,struct,math,time,os
r=sys.stdin.buffer.read();assert r[:8]==b'LWREQ003' and r[16]==0
i=json.loads(r[17:17+struct.unpack('<Q',r[8:16])[0]]);p=i['plan'];fault=FAULT
d={'source_revision':REV,'protocol':2,'kind':'float','mime':'application/x-lensworks-rgba-f32le','width':2,'height':2,'row_stride':'32','byte_length':'64','channels':4,'sample':'float32_le','color_space':'linear_srgb','alpha':'straight','orientation':'applied','source_identity':p['identity'],'original':p['original'],'original_revision':p['original_revision'],'plan_authority':p['authority']}
d.update(json.loads(DETAIL))
v=[0.0,2.0,-0.2,1.0]*4
if fault=='wrong_origin':d['source_identity']['source']['asset_id']='wrong-asset'
if fault=='nan':v[0]=float('nan')
if fault=='dimensions':d['width']=3
if fault=='protocol':d['source_revision']='stale'
if fault=='hold':
 open(MARK,'w').write(str(os.getpid()));time.sleep(30)
h=json.dumps(d).encode();sys.stdout.buffer.write(b'LWFLT002'+struct.pack('<QQ',len(h),64)+h+struct.pack('<16f',*v))
"#;
        let marker = temp.path().join("decode-started");
        let write_fault = |fault: &str| {
            let details = json!({"metadata":d["metadata"],"provenance":d["provenance"]});
            let script = template
                .replace("FAULT", &serde_json::to_string(fault).unwrap())
                .replace("REV", &serde_json::to_string(SOURCE_REVISION).unwrap())
                .replace(
                    "MARK",
                    &serde_json::to_string(marker.to_str().unwrap()).unwrap(),
                )
                .replace(
                    "DETAIL",
                    &serde_json::to_string(&details.to_string()).unwrap(),
                );
            std::fs::write(&worker, script).unwrap();
            std::fs::set_permissions(&worker, std::fs::Permissions::from_mode(0o700)).unwrap();
        };
        write_fault("wrong_origin");
        let new = command(
            "session_create",
            json!({"config":{"worker_executable":native(Path::new(env!("CARGO_BIN_EXE_lensworks-decode-worker"))),"decode_worker_executable":native(&worker),"cache_root":native(&temp.path().join("cache")),"original_roots":[native(&originals)]}}),
        );
        let next = new["result"]["session"].as_str().unwrap();
        let open = rpc(
            next,
            json!({"command":"open_existing","args":{"path":native(&temp.path().join("catalog"))}}),
        );
        let catalog = open["value"]["data"]["catalog"].as_str().unwrap();
        let mut fault_args = args.clone();
        fault_args["session"] = json!(next);
        fault_args["catalog"] = json!(catalog);
        for fault in ["wrong_origin", "nan", "dimensions", "protocol"] {
            write_fault(fault);
            let r = command("decode_full", fault_args.clone());
            let j = r["result"]["job"].as_str().unwrap();
            let result = take(j);
            assert_eq!(result["ok"], false, "{fault}: {result}");
            assert_eq!(result["error"]["code"], "native");
            command("job_release", json!({"job":j}));
        }
        write_fault("hold");
        let r = command("decode_full", fault_args.clone());
        let j = r["result"]["job"].as_str().unwrap();
        let until = Instant::now() + Duration::from_secs(10);
        // The child creates the marker and then writes its pid; wait for the complete pid,
        // not just the file, or an early read sees an empty marker.
        let pid: libc::pid_t = loop {
            if let Ok(pid) = std::fs::read_to_string(&marker).map(|text| text.trim().parse()) {
                if let Ok(pid) = pid { break pid; }
            }
            assert!(Instant::now() < until, "child didn't launch");
            std::thread::sleep(Duration::from_millis(5));
        };
        command("job_cancel", json!({"job":j}));
        let canceled = take(j);
        assert_eq!(canceled["error"]["code"], "canceled", "{canceled}");
        assert_eq!(
            unsafe { libc::kill(pid, 0) },
            -1,
            "canceled decoder still alive"
        );
        command("job_release", json!({"job":j}));
        shutdown(next);
    }
    let s = session(
        Path::new(env!("CARGO_BIN_EXE_lensworks-decode-worker")),
        temp.path(),
    );
    let open = rpc(
        &s,
        json!({"command":"open_existing","args":{"path":native(&temp.path().join("catalog"))}}),
    );
    let catalog = open["value"]["data"]["catalog"].as_str().unwrap();
    let mut args = args;
    args["session"] = json!(s);
    args["catalog"] = json!(catalog);
    // Full-source decoding above ignores the stored recipe. A distinct retained
    // Export.Run now renders that exact prepared recipe and publishes a receipt.
    let render_limits =
        json!({"max_pixels":"10000","max_allocation_bytes":"1048576","max_live_bytes":"16777216"});
    let execution = json!({"worker_bytes":"134217728","working_bytes":"134217728","render":{"decode":{"max_encoded_bytes":"1048576","max_intermediate_pixels":"10000","max_allocation_bytes":"1048576"},"render":render_limits,"encode":{"render":render_limits,"max_metadata_bytes":"1048576","row_buffer_bytes":"1048576"},"max_encoded_extent":"1048576"}});
    let export = |r| family(&s, catalog, "export", r);
    let recovered =
        export(json!({"command":"recover","args":{"directories":"32","limits":execution}}));
    let recover_op = recovered["value"]["id"].as_str().unwrap();
    terminal(&s, catalog, "export", recover_op);
    let run = export(
        json!({"command":"run","args":{"job":id,"limits":execution,"max_items":"1","max_seconds":"30"}}),
    );
    let operation = terminal(&s, catalog, "export", run["value"]["id"].as_str().unwrap());
    assert_eq!(operation["job"]["state"], "complete", "{operation}");
    let published = export(json!({"command":"plan","args":{"job":id,"sequence":"1"}}));
    let published = &published["value"];
    assert_eq!(published["authority"], plan["authority"]);
    assert_eq!(published["identity"], plan["identity"]);
    assert_eq!(published["item"]["state"], "published", "{published}");
    let rendered = photocatalog::media::decode_full_limited(
        &destination,
        photocatalog::media::DecodeLimits {
            max_encoded_bytes: 1048576,
            max_intermediate_pixels: 10000,
            max_allocation_bytes: 1048576,
        },
    )
    .unwrap();
    assert_eq!((rendered.width, rendered.height), (2, 2));
    for (pixel, source) in rendered.pixels.iter().zip(floats.chunks_exact(4)) {
        for c in 0..3 {
            assert!(
                (pixel[c] - source[c] * 2.0).abs() < 0.002,
                "rendered {pixel:?}, original {source:?}"
            );
        }
        assert!((pixel[3] - source[3]).abs() < 0.0001);
    }
    let restored = export(
        json!({"command":"restore","args":{"job":id,"sequence":"1","authority":plan["authority"]}}),
    );
    let receipt = terminal(
        &s,
        catalog,
        "export",
        restored["value"]["id"].as_str().unwrap(),
    );
    assert_eq!(
        receipt["result"]["value"]["receipt"]["state"], "published",
        "{receipt}"
    );
    assert_eq!(std::fs::read(&hdr).unwrap(), before);
    assert_eq!(std::fs::metadata(&hdr).unwrap().modified().unwrap(), mtime);
    // Source mutation invalidates retained authority; decode never returns pixels
    // from a different revision or rewrites the original to repair it.
    std::fs::write(&hdr, b"changed source fixture").unwrap();
    let bad = command("decode_full", args);
    let badjob = bad["result"]["job"].as_str().unwrap();
    let rejected = take(badjob);
    assert_eq!(rejected["ok"], false, "{rejected}");
    command("job_release", json!({"job":badjob}));
    assert_eq!(std::fs::read(&hdr).unwrap(), b"changed source fixture");
    shutdown(&s);
}

/// The named-image search crosses the managed boundary like any retained command: it answers
/// with the image page shape, names only what the filters admit, and reports the keys examined.
#[test]
fn managed_search_among_returns_the_named_images_the_filters_admit() {
    let _scope = TestScope::new();
    let (_temp, s, c, key) = fixture();
    let ghost = json!({"asset_id":"no-such-asset","variant_id":"master"});
    let among = |options: Value, keys: Value, limit: u16| {
        rpc(
            &s,
            json!({"command":"search_among","args":{"catalog":c,"options":options,"keys":keys,"limit":limit}}),
        )
    };
    let all = among(json!({}), json!([ghost, key]), 10);
    assert_eq!(all["status"], "ok", "{all}");
    let page = &all["value"]["data"];
    assert_eq!(all["value"]["kind"], "images", "{all}");
    assert_eq!(page["rows"].as_array().unwrap().len(), 1, "{all}");
    assert_eq!(page["rows"][0]["key"], key, "{all}");
    assert_eq!((&page["scanned"], &page["has_more"], &page["next"]), (&json!(2), &json!(false), &Value::Null), "{all}");
    let applied = organize(&s, &c, &key, json!({"operation":"rating","value":3}));
    assert_eq!(applied["status"], "ok", "{applied}");
    let rated = among(json!({"rating":3}), json!([key]), 10);
    assert_eq!(rated["value"]["data"]["rows"][0]["key"], key, "{rated}");
    let other = among(json!({"rating":5}), json!([key]), 10);
    assert_eq!(other["status"], "ok", "{other}");
    assert!(other["value"]["data"]["rows"].as_array().unwrap().is_empty(), "{other}");
    let refused = among(json!({}), json!([]), 10);
    assert_eq!((&refused["status"], &refused["error"]["code"]), (&json!("error"), &json!("invalid_request")), "{refused}");
    shutdown(&s);
}

#[test]
fn managed_all_source_wire_variants_preserve_exact_typed_authority() {
    let _gate = TestScope::new();
    let matrix: Value = serde_json::from_slice(
        &std::fs::read(
            Path::new(env!("CARGO_MANIFEST_DIR")).join("../../docs/CATALOG_SERVICE_COVERAGE.json"),
        )
        .unwrap(),
    )
    .unwrap();
    let cases = matrix["wire_cases"].as_array().unwrap();
    assert!(cases.len() >= 357);
    for case in cases {
        let v = &case["request"];
        let typed: app::Request = serde_json::from_value(v.clone())
            .unwrap_or_else(|e| panic!("{}: {e}: {v}", case["id"]));
        let exact = serde_json::to_value(&typed).unwrap();
        let parsed: app::Request = serde_json::from_value(exact.clone()).unwrap();
        assert_eq!(serde_json::to_value(parsed).unwrap(), exact);
        let response = command("submit", json!({"session":"0","request":v}));
        assert_eq!(
            response["error"]["code"], "invalid_handle",
            "{}: {response}",
            case["id"]
        );
    }
}

#[cfg(unix)]
#[test]
fn managed_open_and_import_reject_redirected_catalog_cache_without_source_effects() {
    use std::os::unix::fs::symlink;
    let _gate = TestScope::new();
    let (temp, s, c, _) = fixture();
    let root = temp.path().join("catalog");
    let originals = temp.path().join("originals");
    let before = std::fs::read(originals.join("photo.png")).unwrap();
    std::fs::remove_dir_all(root.join("previews")).unwrap();
    symlink(&originals, root.join("previews")).unwrap();
    let import = command(
        "submit",
        json!({"session":s,"request":{"command":"import_resume","args":{"catalog":c,"source":native(&originals)}}}),
    );
    assert_eq!(import["error"]["code"], "unsafe_location", "{import}");
    let opened = command(
        "submit",
        json!({"session":s,"request":{"command":"open_existing","args":{"path":native(&root)}}}),
    );
    assert_eq!(opened["error"]["code"], "unsafe_location", "{opened}");
    assert_eq!(std::fs::read_dir(&originals).unwrap().count(), 1);
    assert_eq!(std::fs::read(originals.join("photo.png")).unwrap(), before);
    std::fs::remove_file(root.join("previews")).unwrap();
    std::fs::create_dir(root.join("previews")).unwrap();
    shutdown(&s);
    let hash = blake3::hash(
        &serde_json::to_vec(&NativePath::from_path(
            &std::fs::canonicalize(&root).unwrap(),
        ))
        .unwrap(),
    )
    .to_hex()
    .to_string();
    let cache = temp.path().join("cache").join(hash);
    let saved = temp.path().join("saved-manifest");
    std::fs::rename(cache.join("manifest"), &saved).unwrap();
    symlink(&originals, cache.join("manifest")).unwrap();
    let next = session(
        Path::new(env!("CARGO_BIN_EXE_lensworks-decode-worker")),
        temp.path(),
    );
    let opened = command(
        "submit",
        json!({"session":next,"request":{"command":"open_existing","args":{"path":native(&root)}}}),
    );
    assert_eq!(opened["error"]["code"], "unsafe_location", "{opened}");
    assert_eq!(std::fs::read_dir(&originals).unwrap().count(), 1);
    assert_eq!(std::fs::read(originals.join("photo.png")).unwrap(), before);
    shutdown(&next);
}

fn family(s: &str, c: &str, name: &str, request: Value) -> Value {
    let v = rpc(
        s,
        json!({"command":name,"args":{"catalog":c,"request":request}}),
    );
    assert_eq!(v["status"], "ok", "{name}: {v}");
    v["value"]["data"].clone()
}
fn terminal(s: &str, c: &str, name: &str, operation: &str) -> Value {
    let until = Instant::now() + Duration::from_secs(30);
    loop {
        let v = family(
            s,
            c,
            name,
            json!({"command":"status","args":{"operation":operation}}),
        );
        let op = if name == "metadata_write" {
            &v["value"]["operation"]
        } else {
            &v["value"]
        };
        if op["phase"] == "complete" {
            return op.clone();
        }
        assert!(op["phase"] != "failed" && op["phase"] != "canceled", "{v}");
        assert!(Instant::now() < until, "operation timeout {v}");
        std::thread::sleep(Duration::from_millis(5));
    }
}
fn metadata_action(s: &str, c: &str, attempts: &AtomicUsize, action: Value) -> Value {
    let attempt = format!(
        "00000000-0000-0000-0000-{:012}",
        attempts.fetch_add(1, Ordering::AcqRel)
    );
    let start = family(
        s,
        c,
        "metadata_write",
        json!({"command":"start","args":{"attempt":attempt,"action":action}}),
    );
    terminal(
        s,
        c,
        "metadata_write",
        start["value"]["operation"].as_str().unwrap(),
    )["result"]
        .clone()
}
const PRESERVATION_SIDECAR: &str = r#"<?xpacket begin="" id="W5M0MpCehiHzreSzNTczkc9d"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/">
 <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
  <rdf:Description rdf:about=""
    xmlns:xmp="http://ns.adobe.com/xap/1.0/"
    xmlns:dc="http://purl.org/dc/elements/1.1/"
    xmlns:lr="http://ns.adobe.com/lightroom/1.0/"
    xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
    xmlns:acme="http://example.com/acme/1.0/"
    xmp:Rating="2"
    crs:Exposure2012="+0.50"
    acme:Secret="keep-me">
   <dc:subject><rdf:Bag><rdf:li>Existing</rdf:li></rdf:Bag></dc:subject>
   <lr:hierarchicalSubject><rdf:Bag><rdf:li>Places|Paris</rdf:li></rdf:Bag></lr:hierarchicalSubject>
   <acme:Shot rdf:parseType="Resource">
    <acme:Lens>Fixture 50mm</acme:Lens>
    <acme:Notes><rdf:Seq><rdf:li>first</rdf:li><rdf:li>second</rdf:li></rdf:Seq></acme:Notes>
   </acme:Shot>
  </rdf:Description>
 </rdf:RDF>
</x:xmpmeta>
<?xpacket end="w"?>"#;

fn organize(s: &str, c: &str, key: &Value, operation: Value) -> Value {
    let identity = family(
        s,
        c,
        "organization",
        json!({"command":"identity","args":{"key":key}}),
    )["value"]
        .clone();
    rpc(
        s,
        json!({"command":"organization","args":{"catalog":c,"request":{"command":"apply","args":{"key":key,"expected_revision":identity["metadata_revision"],"operation":operation}}}}),
    )
}
fn metadata_fields(s: &str, c: &str, key: &Value) -> (Value, Vec<Value>) {
    let identity = family(
        s,
        c,
        "metadata",
        json!({"command":"identity","args":{"key":key}}),
    )["value"]
        .clone();
    let fields = family(
        s,
        c,
        "metadata",
        json!({"command":"fields","args":{"identity":identity,"after":null,"limit":50}}),
    );
    (
        identity,
        fields["value"]["rows"].as_array().unwrap().clone(),
    )
}

/// S05 AC2: unknown, Adobe (crs) and structured XMP plus source provenance survive
/// import, organization edits, an unrelated metadata edit and controlled sidecar
/// output. The former combined-state fault (hierarchical keyword, then a rating
/// edit with no explicit base) no longer orphans the keyword choice.
#[test]
fn managed_organization_preserves_unknown_adobe_structured_xmp_through_sidecar_output() {
    let _scope = TestScope::new();
    let (temp, s, c, key) = fixture_with_sidecar(Some(PRESERVATION_SIDECAR));
    let originals = temp.path().join("originals");
    let photo_before = std::fs::read(originals.join("photo.png")).unwrap();
    let sidecar_before = std::fs::read(originals.join("photo.xmp")).unwrap();
    let (_, fields) = metadata_fields(&s, &c, &key);
    let rating = fields.iter().find(|f| f["name"] == "rating").unwrap();
    assert_eq!(rating["conflicted"], false, "{rating}");
    // Source provenance: the associated sidecar is a recorded source.
    let identity = family(
        &s,
        &c,
        "metadata",
        json!({"command":"identity","args":{"key":key}}),
    )["value"]
        .clone();
    let sources = family(
        &s,
        &c,
        "metadata",
        json!({"command":"sources","args":{"identity":identity,"after":null,"limit":20}}),
    );
    assert!(
        sources["value"]["rows"]
            .as_array()
            .unwrap()
            .iter()
            .any(|row| row.to_string().contains("sidecar")),
        "{sources}"
    );

    family(
        &s,
        &c,
        "organization",
        json!({"command":"create_keyword","args":{"kind":"hierarchical","path":["People","Ada"]}}),
    );
    let collection = family(
        &s,
        &c,
        "organization",
        json!({"command":"create_collection","args":{"name":"Portraits"}}),
    )["value"]["id"]
        .as_str()
        .unwrap()
        .to_owned();
    for operation in [
        json!({"operation":"add_keyword","kind":"hierarchical","path":["People","Ada"]}),
        json!({"operation":"rating","value":4}),
        json!({"operation":"label","value":"Blue"}),
        json!({"operation":"flag","value":"pick"}),
        json!({"operation":"add_collection","collection":collection}),
    ] {
        let applied = organize(&s, &c, &key, operation.clone());
        assert_eq!(applied["status"], "ok", "{operation}: {applied}");
    }

    // An unrelated metadata edit with no explicit base (the former fault path).
    let (identity, _) = metadata_fields(&s, &c, &key);
    let edits = serde_json::to_vec(&vec![photocatalog::xmp::Edit::Set {
        namespace: "http://ns.adobe.com/xap/1.0/".into(),
        path: "Rating".into(),
        value: "3".into(),
    }])
    .unwrap();
    let digest = blake3::hash(&edits).to_hex().to_string();
    let limits = serde_json::to_value(app::metadata_write::WriteLimits::default()).unwrap();
    let attempts = AtomicUsize::new(1);
    let action = |a| metadata_action(&s, &c, &attempts, a);
    let input = action(json!({"kind":"input_begin","bytes":edits.len().to_string(),"expected_blake3":digest,"limits":limits}))["value"].clone();
    action(
        json!({"kind":"input_append","token":input["token"],"generation":input["generation"],"offset":"0","bytes":edits}),
    );
    action(
        json!({"kind":"input_finish","token":input["token"],"generation":input["generation"],"bytes":edits.len().to_string(),"blake3":digest}),
    );
    let review = action(json!({"kind":"prepare","identity":identity,"base_model":null,"input":input["token"],"input_blake3":digest}))["value"].clone();
    action(json!({"kind":"commit","review":review["token"],"review_digest":review["digest"]}));

    let (identity, fields) = metadata_fields(&s, &c, &key);
    for field in &fields {
        assert_eq!(field["conflicted"], false, "{field}");
    }
    let keywords = fields
        .iter()
        .find(|f| f["name"] == "hierarchical_keywords")
        .unwrap();
    assert!(keywords.to_string().contains("People|Ada"), "{keywords}");
    assert!(keywords.to_string().contains("Places|Paris"), "{keywords}");
    let model = fields
        .iter()
        .find(|f| f["name"] == "rating")
        .and_then(|f| f["selected_model"].as_str())
        .unwrap()
        .to_owned();
    let sidecar = temp.path().canonicalize().unwrap().join("exported.xmp");
    let plan = action(json!({"kind":"sidecar_plan","identity":identity,"base_model":model,"destination":native(&sidecar),"limits":limits}))["value"].clone();
    let receipt = action(
        json!({"kind":"sidecar_apply","operation":plan["operation"],"authority_blake3":plan["authority_blake3"],"overwrite_ack":false,"limits":limits}),
    );
    assert_eq!(receipt["kind"], "sidecar_receipt", "{receipt}");
    let exported = std::fs::read_to_string(&sidecar).unwrap();
    let meta = photocatalog::xmp::parse(exported.as_bytes()).unwrap();
    let text = |ns: &str, path: &str| meta.property(ns, path).map(|v| v.value);
    const XMP: &str = "http://ns.adobe.com/xap/1.0/";
    const ACME: &str = "http://example.com/acme/1.0/";
    assert_eq!(text(XMP, "Rating").as_deref(), Some("3"), "{exported}");
    assert_eq!(text(XMP, "Label").as_deref(), Some("Blue"), "{exported}");
    assert_eq!(text(ACME, "Secret").as_deref(), Some("keep-me"), "{exported}");
    assert_eq!(
        text("http://ns.adobe.com/camera-raw-settings/1.0/", "Exposure2012").as_deref(),
        Some("+0.50"),
        "{exported}"
    );
    assert_eq!(
        text(ACME, "Shot/acme:Lens").as_deref(),
        Some("Fixture 50mm"),
        "{exported}"
    );
    assert_eq!(meta.array_len(ACME, "Shot/acme:Notes"), 2, "{exported}");
    let lr = "http://ns.adobe.com/lightroom/1.0/";
    let hierarchy: Vec<String> = (1..=meta.array_len(lr, "hierarchicalSubject"))
        .map(|i| meta.array_item(lr, "hierarchicalSubject", i as i32).unwrap().value)
        .collect();
    assert!(hierarchy.contains(&"People|Ada".to_owned()), "{exported}");
    assert!(hierarchy.contains(&"Places|Paris".to_owned()), "{exported}");
    assert_eq!(
        meta.array_item("http://purl.org/dc/elements/1.1/", "subject", 1)
            .map(|v| v.value)
            .as_deref(),
        Some("Existing")
    );
    // Controlled output never touches the original or its source sidecar.
    assert_eq!(std::fs::read(originals.join("photo.png")).unwrap(), photo_before);
    assert_eq!(std::fs::read(originals.join("photo.xmp")).unwrap(), sidecar_before);
    shutdown(&s);
}

fn organization_state(s: &str, c: &str, key: &Value) -> Value {
    family(
        s,
        c,
        "organization",
        json!({"command":"states","args":{"keys":[key],"keywords":[],"collection":null}}),
    )["value"][0]
        .clone()
}
/// Export the photo's current catalog metadata through controlled sidecar output.
fn exported_sidecar(
    temp: &tempfile::TempDir,
    s: &str,
    c: &str,
    key: &Value,
    name: &str,
) -> String {
    let (identity, fields) = metadata_fields(s, c, key);
    let model = fields
        .iter()
        .filter_map(|f| f["selected_model"].as_str())
        .max_by_key(|v| v.parse::<i64>().unwrap())
        .unwrap()
        .to_owned();
    let limits = serde_json::to_value(app::metadata_write::WriteLimits::default()).unwrap();
    let attempts = AtomicUsize::new(1);
    let action = |a| metadata_action(s, c, &attempts, a);
    let sidecar = temp.path().canonicalize().unwrap().join(name);
    let plan = action(json!({"kind":"sidecar_plan","identity":identity,"base_model":model,"destination":native(&sidecar),"limits":limits}))["value"].clone();
    let receipt = action(
        json!({"kind":"sidecar_apply","operation":plan["operation"],"authority_blake3":plan["authority_blake3"],"overwrite_ack":false,"limits":limits}),
    );
    assert_eq!(receipt["kind"], "sidecar_receipt", "{receipt}");
    std::fs::read_to_string(&sidecar).unwrap()
}

/// S05 AC1/AC2: undoing a rating/label/flag change restores the exact prior state.
/// An absent rating or label stays absent (no explicit `xmp:Rating="0"` or empty
/// label in sidecar output) and a Lightroom reject (`xmp:Rating="-1"`) stays a
/// reject rather than being clamped to 0 and silently unflagged.
#[test]
fn managed_organization_undo_restores_absent_and_reject_values_through_sidecar_output() {
    let _scope = TestScope::new();
    const XMP: &str = "http://ns.adobe.com/xap/1.0/";
    let (temp, s, c, key) = fixture();
    let before = organization_state(&s, &c, &key);
    assert!(before["rating"].is_null() && before["label"].is_null(), "{before}");
    for operation in [
        json!({"operation":"rating","value":3}),
        json!({"operation":"label","value":"Blue"}),
        json!({"operation":"flag","value":"pick"}),
        json!({"operation":"restore_rating","value":null}),
        json!({"operation":"restore_label","value":null}),
        json!({"operation":"restore_flag","value":null}),
    ] {
        let applied = organize(&s, &c, &key, operation.clone());
        assert_eq!(applied["status"], "ok", "{operation}: {applied}");
    }
    let after = organization_state(&s, &c, &key);
    assert!(after["rating"].is_null() && after["label"].is_null(), "{after}");
    assert!(after["flag"].is_null() && after["effective_flag"] == "unflagged", "{after}");
    let exported = exported_sidecar(&temp, &s, &c, &key, "unrated.xmp");
    let meta = photocatalog::xmp::parse(exported.as_bytes()).unwrap();
    assert!(meta.property(XMP, "Rating").is_none(), "absent rating exported: {exported}");
    assert!(meta.property(XMP, "Label").is_none(), "absent label exported: {exported}");
    shutdown(&s);

    let reject = PRESERVATION_SIDECAR.replace("xmp:Rating=\"2\"", "xmp:Rating=\"-1\"");
    let (temp, s, c, key) = fixture_with_sidecar(Some(&reject));
    let before = organization_state(&s, &c, &key);
    assert_eq!((&before["rating"], &before["effective_flag"]), (&json!("-1"), &json!("reject")));
    for operation in [
        json!({"operation":"rating","value":3}),
        json!({"operation":"restore_rating","value":"-1"}),
    ] {
        let applied = organize(&s, &c, &key, operation.clone());
        assert_eq!(applied["status"], "ok", "{operation}: {applied}");
    }
    let after = organization_state(&s, &c, &key);
    assert_eq!((&after["rating"], &after["flag"], &after["effective_flag"]), (&json!("-1"), &Value::Null, &json!("reject")), "{after}");
    let exported = exported_sidecar(&temp, &s, &c, &key, "reject.xmp");
    let meta = photocatalog::xmp::parse(exported.as_bytes()).unwrap();
    assert_eq!(meta.property(XMP, "Rating").map(|v| v.value).as_deref(), Some("-1"));
    assert_eq!(
        meta.property("http://example.com/acme/1.0/", "Secret").map(|v| v.value).as_deref(),
        Some("keep-me")
    );
    shutdown(&s);
}

/// S05 AC2: a genuine source disagreement is surfaced as a conflict; organization
/// edits and sidecar output refuse to overwrite it, and source bytes stay intact.
#[test]
fn managed_source_conflict_is_surfaced_and_never_silently_overwritten() {
    let _scope = TestScope::new();
    let (temp, s, c, key) = fixture_with_sidecar(Some(PRESERVATION_SIDECAR));
    let originals = temp.path().join("originals");
    let photo_before = std::fs::read(originals.join("photo.png")).unwrap();
    // A second, independent source for the same photo disagrees about Rating.
    let embedded = PRESERVATION_SIDECAR.replace("xmp:Rating=\"2\"", "xmp:Rating=\"5\"");
    std::fs::write(originals.join("photo.png.xmp"), &embedded).unwrap();
    let resume = rpc(
        &s,
        json!({"command":"import_resume","args":{"catalog":c,"source":native(&originals)}}),
    );
    assert_eq!(resume["status"], "ok", "{resume}");
    let until = Instant::now() + Duration::from_secs(30);
    loop {
        let v = rpc(&s, json!({"command":"import_status","args":{"catalog":c}}));
        if v["value"]["data"]["phase"] == "complete" {
            break;
        }
        assert!(Instant::now() < until, "{v}");
        std::thread::sleep(Duration::from_millis(10));
    }
    let (identity, fields) = metadata_fields(&s, &c, &key);
    let rating = fields.iter().find(|f| f["name"] == "rating").unwrap();
    assert_eq!(rating["conflicted"], true, "{fields:?}");
    let refused = organize(&s, &c, &key, json!({"operation":"rating","value":1}));
    assert_ne!(refused["status"], "ok", "{refused}");
    assert!(refused.to_string().contains("conflict"), "{refused}");
    // Both disagreeing values remain visible as explicit candidates.
    let candidates = family(
        &s,
        &c,
        "metadata",
        json!({"command":"candidates","args":{"identity":identity,"field":"rating","after":null,"limit":10}}),
    );
    let rows = candidates["value"]["rows"].as_array().unwrap();
    assert!(rows.len() >= 2, "{candidates}");
    let model = rows[0]["model"].as_str().unwrap().to_owned();
    let limits = serde_json::to_value(app::metadata_write::WriteLimits::default()).unwrap();
    let sidecar = temp.path().canonicalize().unwrap().join("conflicted.xmp");
    let start = family(
        &s,
        &c,
        "metadata_write",
        json!({"command":"start","args":{"attempt":"00000000-0000-0000-0000-000000000099","action":{"kind":"sidecar_plan","identity":identity,"base_model":model,"destination":native(&sidecar),"limits":limits}}}),
    );
    let until = Instant::now() + Duration::from_secs(30);
    loop {
        let status = family(
            &s,
            &c,
            "metadata_write",
            json!({"command":"status","args":{"operation":start["value"]["operation"]}}),
        );
        let operation = &status["value"]["operation"];
        if operation["phase"] == "failed" {
            assert_eq!(operation["error"], "resolve metadata conflicts before export");
            break;
        }
        assert!(operation["phase"] != "complete", "{status}");
        assert!(Instant::now() < until, "{status}");
        std::thread::sleep(Duration::from_millis(5));
    }
    assert!(!sidecar.exists());
    assert_eq!(std::fs::read(originals.join("photo.png")).unwrap(), photo_before);
    assert_eq!(std::fs::read_to_string(originals.join("photo.png.xmp")).unwrap(), embedded);
    shutdown(&s);
}

#[test]
fn managed_organization_metadata_write_copy_preview_backup_restore_lifecycles() {
    let _gate = TestScope::new();
    let (temp, s, c, key) = fixture();
    let original = temp.path().join("originals/photo.png");
    let bytes = std::fs::read(&original).unwrap();
    let mtime = std::fs::metadata(&original).unwrap().modified().unwrap();
    let identity = family(
        &s,
        &c,
        "metadata",
        json!({"command":"identity","args":{"key":key}}),
    )["value"]
        .clone();
    let edits = serde_json::to_vec(&vec![photocatalog::xmp::Edit::Set {
        namespace: "http://ns.adobe.com/xap/1.0/".into(),
        path: "Rating".into(),
        value: "3".into(),
    }])
    .unwrap();
    let digest = blake3::hash(&edits).to_hex().to_string();
    let limits = serde_json::to_value(app::metadata_write::WriteLimits::default()).unwrap();
    let attempt = AtomicUsize::new(1);
    let action = |action: Value| {
        let attempt = format!(
            "00000000-0000-0000-0000-{:012}",
            attempt.fetch_add(1, Ordering::AcqRel)
        );
        let start = family(
            &s,
            &c,
            "metadata_write",
            json!({"command":"start","args":{"attempt":attempt,"action":action}}),
        );
        let op = start["value"]["operation"].as_str().unwrap();
        terminal(&s, &c, "metadata_write", op)["result"].clone()
    };
    let input=action(json!({"kind":"input_begin","bytes":edits.len().to_string(),"expected_blake3":digest,"limits":limits}))["value"].clone();
    let token = input["token"].as_str().unwrap();
    let generation = input["generation"].clone();
    action(
        json!({"kind":"input_append","token":token,"generation":generation,"offset":"0","bytes":edits}),
    );
    action(
        json!({"kind":"input_finish","token":token,"generation":generation,"bytes":edits.len().to_string(),"blake3":digest}),
    );
    let review=action(json!({"kind":"prepare","identity":identity,"base_model":null,"input":token,"input_blake3":digest}))["value"].clone();
    assert_eq!(review["changed_fields"], "1");
    let change =
        action(json!({"kind":"commit","review":review["token"],"review_digest":review["digest"]}));
    assert_eq!(change["kind"], "changed");
    let identity = family(
        &s,
        &c,
        "metadata",
        json!({"command":"identity","args":{"key":key}}),
    )["value"]
        .clone();
    let fields = family(
        &s,
        &c,
        "metadata",
        json!({"command":"fields","args":{"identity":identity,"after":null,"limit":10}}),
    );
    assert!(
        !fields["value"]["rows"].as_array().unwrap().is_empty(),
        "{fields}"
    );
    // Resolve each conflict through explicit retained candidate authority before
    // reconciling a frozen full XMP base with the effective metadata fields.
    let mut export_identity = identity.clone();
    for field in fields["value"]["rows"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|f| f["conflicted"] == true)
    {
        let mut after = Value::Null;
        let selected = loop {
            let candidates = family(
                &s,
                &c,
                "metadata",
                json!({"command":"candidates","args":{"identity":export_identity,"field":field["name"],"after":after,"limit":10}}),
            );
            if let Some(model) = candidates["value"]["rows"][0]["model"].as_str() {
                break model.to_owned();
            }
            after = candidates["value"]["next"].clone();
            assert!(
                !after.is_null(),
                "missing candidate for {field}: {candidates}"
            );
        };
        action(
            json!({"kind":"resolve","identity":export_identity,"field":field["name"],"model":selected}),
        );
        export_identity = family(
            &s,
            &c,
            "metadata",
            json!({"command":"identity","args":{"key":key}}),
        )["value"]
            .clone();
    }
    let model = fields["value"]["rows"]
        .as_array()
        .unwrap()
        .iter()
        .find_map(|field| field["selected_model"].as_str())
        .expect("committed XMP model");
    let sidecar = temp.path().canonicalize().unwrap().join("edited.xmp");
    let plan = action(json!({"kind":"sidecar_plan","identity":export_identity,"base_model":model,"destination":native(&sidecar),"limits":limits}))["value"].clone();
    let receipt = action(
        json!({"kind":"sidecar_apply","operation":plan["operation"],"authority_blake3":plan["authority_blake3"],"overwrite_ack":false,"limits":limits}),
    );
    assert_eq!(receipt["kind"], "sidecar_receipt", "{receipt}");
    let sidecar_bytes = std::fs::read(&sidecar).unwrap();
    assert!(
        std::str::from_utf8(&sidecar_bytes)
            .unwrap()
            .contains("Rating")
    );
    let keyword = family(
        &s,
        &c,
        "organization",
        json!({"command":"create_keyword","args":{"kind":"hierarchical","path":["People","Ada"]}}),
    );
    assert!(keyword["value"]["id"].is_string());
    let before_identity = family(
        &s,
        &c,
        "organization",
        json!({"command":"identity","args":{"key":key}}),
    )["value"]
        .clone();
    let applied = family(
        &s,
        &c,
        "organization",
        json!({"command":"apply","args":{"key":key,"expected_revision":before_identity["metadata_revision"],"operation":{"operation":"add_keyword","kind":"hierarchical","path":["People","Ada"]}}}),
    );
    assert!(applied["value"]["revision"].is_string());
    let collection = family(
        &s,
        &c,
        "organization",
        json!({"command":"create_collection","args":{"name":"Portraits"}}),
    );
    let collection = collection["value"]["id"].as_str().unwrap();
    let identity = family(
        &s,
        &c,
        "organization",
        json!({"command":"identity","args":{"key":key}}),
    )["value"]
        .clone();
    family(
        &s,
        &c,
        "organization",
        json!({"command":"set_member","args":{"identity":identity,"collection":collection,"position":"0"}}),
    );
    let members = family(
        &s,
        &c,
        "organization",
        json!({"command":"members","args":{"collection":collection,"after":null,"limit":10}}),
    );
    assert_eq!(members["value"]["rows"].as_array().unwrap().len(), 1);
    let variant = rpc(
        &s,
        json!({"command":"create_variant","args":{"catalog":c,"key":key,"expected_revision":"0","label":"Copy target"}}),
    );
    assert_eq!(variant["status"], "ok", "{variant}");
    let target = variant["value"]["data"]["key"].clone();
    let mut recipe = photocatalog::edit::Recipe::default();
    let photocatalog::edit::Recipe::V1(ref mut settings) = recipe;
    settings.exposure_ev = 1.0;
    let save = rpc(
        &s,
        json!({"command":"save_recipe","args":{"catalog":c,"key":key,"expected_revision":"0","recipe":recipe}}),
    );
    assert_eq!(save["status"], "ok", "{save}");
    let revision = save["value"]["data"]["revision"].clone();
    let copy = family(
        &s,
        &c,
        "edit_copy",
        json!({"command":"begin","args":{"source":key,"expected_revision":revision,"groups":["exposure"]}}),
    );
    let copyid = copy["value"]["id"].as_str().unwrap();
    family(
        &s,
        &c,
        "edit_copy",
        json!({"command":"append","args":{"job":copyid,"expected_total":"0","targets":[{"key":target,"expected_revision":"0"}]}}),
    );
    family(
        &s,
        &c,
        "edit_copy",
        json!({"command":"seal","args":{"job":copyid,"expected_total":"1"}}),
    );
    let run = family(
        &s,
        &c,
        "edit_copy",
        json!({"command":"run","args":{"job":copyid}}),
    );
    terminal(&s, &c, "edit_copy", run["value"]["id"].as_str().unwrap());
    let copied = rpc(
        &s,
        json!({"command":"variant","args":{"catalog":c,"key":target}}),
    );
    assert_eq!(
        copied["value"]["data"]["recipe"]["settings"]["exposure_ev"],
        1.0
    );
    let preview = rpc(
        &s,
        json!({"command":"preview","args":{"catalog":c,"key":key,"tier":"thumbnail","interactive":false,"viewport":"fixture","generation":"1","foreground":true,"diagnostics":false}}),
    );
    assert_eq!(preview["status"], "ok", "{preview}");
    let ticket = preview["value"]["data"]["ticket"].as_str().unwrap();
    let until = Instant::now() + Duration::from_secs(30);
    loop {
        let status = rpc(
            &s,
            json!({"command":"preview_status","args":{"catalog":c,"ticket":ticket}}),
        );
        if status["value"]["data"]["state"] == "ready" {
            break;
        }
        assert!(Instant::now() < until, "{status}");
        std::thread::sleep(Duration::from_millis(10));
    }
    let preview = command(
        "preview_bytes",
        json!({"session":s,"catalog":c,"ticket":ticket,"foreground":true}),
    );
    let pj = preview["result"]["job"].as_str().unwrap();
    let result = take(pj);
    assert_eq!(result["ok"], true, "{result}");
    let b = result["result"]["buffer"]
        .as_str()
        .unwrap()
        .parse()
        .unwrap();
    let n = result["result"]["length"]
        .as_str()
        .unwrap()
        .parse()
        .unwrap();
    assert!(image::load_from_memory(&read_buffer(b, n)).is_ok());
    lw_catalog_buffer_release(b);
    command("job_release", json!({"job":pj}));
    let bundle = temp.path().join("backup");
    let create = rpc(
        &s,
        json!({"command":"backup_create","args":{"catalog":c,"bundle":native(&bundle)}}),
    );
    assert_eq!(create["status"], "ok", "{create}");
    let backup_wait = || {
        let until = Instant::now() + Duration::from_secs(30);
        loop {
            let v = rpc(&s, json!({"command":"backup_status"}));
            let state = &v["value"]["data"]["state"];
            if state == "complete" {
                return v;
            }
            assert!(state != "failed", "{v}");
            assert!(Instant::now() < until, "{v}");
            std::thread::sleep(Duration::from_millis(5));
        }
    };
    backup_wait();
    let inspect = rpc(
        &s,
        json!({"command":"backup_inspect","args":{"bundle":native(&bundle)}}),
    );
    assert_eq!(inspect["status"], "ok", "{inspect}");
    backup_wait();
    let destination = temp.path().join("restored");
    let restore = rpc(
        &s,
        json!({"command":"backup_restore","args":{"bundle":native(&bundle),"destination":native(&destination)}}),
    );
    assert_eq!(restore["status"], "ok", "{restore}");
    backup_wait();
    assert_eq!(std::fs::read(&original).unwrap(), bytes);
    assert_eq!(
        std::fs::metadata(&original).unwrap().modified().unwrap(),
        mtime
    );
    shutdown(&s);
    let next = session(
        Path::new(env!("CARGO_BIN_EXE_lensworks-decode-worker")),
        temp.path(),
    );
    let opened = rpc(
        &next,
        json!({"command":"open_existing","args":{"path":native(&destination)}}),
    );
    assert_eq!(opened["status"], "ok", "{opened}");
    let newcatalog = opened["value"]["data"]["catalog"].as_str().unwrap();
    let image = rpc(
        &next,
        json!({"command":"image","args":{"catalog":newcatalog,"key":key}}),
    );
    assert_eq!(image["status"], "ok", "{image}");
    assert_eq!(image["value"]["data"]["key"], key);
    shutdown(&next);
}

/// Polls one relink storage operation to its terminal status without asserting success.
fn relink_operation(s: &str, c: &str, request: Value) -> Value {
    let started = family(s, c, "relink", request);
    assert_eq!(started["kind"], "operation", "{started}");
    let id = started["value"]["id"].as_str().unwrap().to_owned();
    let until = Instant::now() + Duration::from_secs(30);
    loop {
        let v = family(
            s,
            c,
            "relink",
            json!({"command":"status","args":{"operation":id}}),
        );
        let op = &v["value"];
        let terminal = ["complete", "canceled", "failed"].contains(&op["phase"].as_str().unwrap());
        if terminal && op["write_hold"] == false {
            return op.clone();
        }
        assert!(Instant::now() < until, "relink timeout {v}");
        std::thread::sleep(Duration::from_millis(5));
    }
}

/// S06 through the managed ABI the native app uses: with the source tree renamed away
/// (unmount-like), organization still writes and the original reports missing;
/// content-verified prefix reviews expose mismatch and ambiguity, a review with any
/// unresolved row is refused as a whole, the recursive relink applies in one step and
/// one Undo reverses it. Identities and metadata survive; no source file moves.
#[test]
fn managed_offline_tree_organizes_and_relinks_by_content_atomically_without_moving_files() {
    let _scope = TestScope::new();
    let temp = std::sync::Arc::new(tempfile::tempdir().unwrap());
    TEST_ROOTS.with(|v| v.borrow_mut().push(temp.clone()));
    let root = temp.path().canonicalize().unwrap();
    let originals = root.join("originals");
    std::fs::create_dir_all(originals.join("nested/deeper")).unwrap();
    let files = ["a.png", "nested/b.png", "nested/deeper/c.png"];
    for (index, name) in files.iter().enumerate() {
        image::RgbImage::from_pixel(24, 16, image::Rgb([30 + index as u8 * 40, 60, 90]))
            .save(originals.join(name))
            .unwrap();
    }
    let bytes = |at: &Path| -> Vec<Vec<u8>> {
        files
            .iter()
            .map(|f| std::fs::read(at.join(f)).unwrap())
            .collect()
    };
    let online = bytes(&originals);
    let s = session(
        Path::new(env!("CARGO_BIN_EXE_lensworks-decode-worker")),
        &root,
    );
    let create = rpc(
        &s,
        json!({"command":"create","args":{"path":native(&root.join("catalog"))}}),
    );
    assert_eq!(create["status"], "ok", "{create}");
    let c = create["value"]["data"]["catalog"]
        .as_str()
        .unwrap()
        .to_string();
    let start = rpc(
        &s,
        json!({"command":"import_start","args":{"catalog":c,"source":native(&originals)}}),
    );
    assert_eq!(start["status"], "ok", "{start}");
    let until = Instant::now() + Duration::from_secs(30);
    loop {
        let v = rpc(&s, json!({"command":"import_status","args":{"catalog":c}}));
        let phase = &v["value"]["data"]["phase"];
        if phase == "complete" {
            break;
        }
        assert!(phase != "failed", "{v}");
        assert!(Instant::now() < until, "import timeout {v}");
        std::thread::sleep(Duration::from_millis(10));
    }
    let images = || -> Vec<Value> {
        let v = rpc(
            &s,
            json!({"command":"images","args":{"catalog":c,"folder":null,"recursive":true,"text":null,"cursor":null,"limit":10}}),
        );
        assert_eq!(v["status"], "ok", "{v}");
        v["value"]["data"]["rows"].as_array().unwrap().clone()
    };
    let mut keys: Vec<Value> = images().iter().map(|row| row["key"].clone()).collect();
    keys.sort_by(|a, b| a["asset_id"].as_str().cmp(&b["asset_id"].as_str()));
    assert_eq!(keys.len(), 3);
    let state = |key: &Value| -> String {
        let op = relink_operation(&s, &c, json!({"command":"original","args":{"key":key}}));
        assert_eq!(op["phase"], "complete", "{op}");
        op["result"]["value"]["status"]["state"]
            .as_str()
            .unwrap()
            .to_owned()
    };
    let available =
        |key: &Value| ["online_unverified", "available_unverified"].contains(&state(key).as_str());
    let review = |destinations: Vec<&Path>| -> (Value, Vec<Value>) {
        let begun = family(
            &s,
            &c,
            "relink",
            json!({"command":"begin","args":{"scope":{"scope":"prefix","value":{"from":{"Native":native(&originals)},"destinations":destinations.into_iter().map(native).collect::<Vec<_>>()}}}}),
        );
        assert_eq!(begun["kind"], "plan", "{begun}");
        let plan = &begun["value"];
        let op = relink_operation(
            &s,
            &c,
            json!({"command":"prepare","args":{"plan":plan["id"],"revision":plan["revision"],"batch_rows":"64"}}),
        );
        assert_eq!(op["phase"], "complete", "{op}");
        let plan = op["plan"].clone();
        let items = family(
            &s,
            &c,
            "relink",
            json!({"command":"items","args":{"plan":plan["id"],"revision":plan["revision"],"after":"0","limit":"10"}}),
        );
        (plan, items["value"]["rows"].as_array().unwrap().clone())
    };
    let apply = |plan: &Value| {
        relink_operation(
            &s,
            &c,
            json!({"command":"apply","args":{"plan":plan["id"],"revision":plan["revision"]}}),
        )
    };
    for key in &keys {
        assert!(available(key));
    }

    // Disconnect: the whole tree leaves its recorded location.
    let moved = root.join("moved");
    std::fs::rename(&originals, &moved).unwrap();
    for key in &keys {
        assert_eq!(state(key), "missing");
    }
    // Organization keeps writing offline.
    let rated = organize(&s, &c, &keys[0], json!({"operation":"rating","value":4}));
    assert_eq!(rated["status"], "ok", "{rated}");
    let keyword = organize(
        &s,
        &c,
        &keys[0],
        json!({"operation":"add_keyword","kind":"hierarchical","path":["Trips","Offline"]}),
    );
    assert_eq!(keyword["status"], "ok", "{keyword}");
    let organized = organization_state(&s, &c, &keys[0]);
    assert_eq!(organized["rating"], "4", "{organized}");

    // Same names, different bytes: every row is a mismatch and Apply is refused.
    let wrong = root.join("wrong");
    for (name, data) in files.iter().zip(&online) {
        std::fs::create_dir_all(wrong.join(name).parent().unwrap()).unwrap();
        std::fs::write(wrong.join(name), [data.as_slice(), b"x"].concat()).unwrap();
    }
    let (plan, items) = review(vec![&wrong]);
    assert!(
        items.len() == 3 && items.iter().all(|i| i["status"] == "mismatch"),
        "{items:?}"
    );
    assert_eq!(apply(&plan)["phase"], "failed");

    // Identical bytes at two destinations: ambiguous until chosen explicitly.
    let duplicate = root.join("duplicate");
    let mixed = root.join("mixed");
    for name in files {
        for target in [&duplicate, &mixed] {
            std::fs::create_dir_all(target.join(name).parent().unwrap()).unwrap();
            std::fs::copy(moved.join(name), target.join(name)).unwrap();
        }
    }
    let (_, items) = review(vec![&moved, &duplicate]);
    assert!(
        items.iter().all(|i| i["status"] == "ambiguous"),
        "{items:?}"
    );

    // One wrong file among correct ones: the whole review is refused; nothing changes.
    std::fs::write(mixed.join(files[2]), b"not the original").unwrap();
    let (plan, items) = review(vec![&mixed]);
    assert_eq!(
        (&plan["matched"], &plan["unresolved"]),
        (&json!("2"), &json!("1")),
        "{plan}"
    );
    assert_eq!(
        items.iter().filter(|i| i["status"] == "mismatch").count(),
        1
    );
    assert_eq!(apply(&plan)["phase"], "failed");
    for key in &keys {
        assert_eq!(state(key), "missing");
    }

    // The recursive folder relink: all match and apply once.
    let (plan, items) = review(vec![&moved]);
    assert!(items.iter().all(|i| i["status"] == "matched"), "{items:?}");
    let applied = apply(&plan);
    assert_eq!(applied["phase"], "complete", "{applied}");
    let applied = applied["plan"].clone();
    assert_eq!(applied["state"], "applied");
    for key in &keys {
        assert!(available(key));
    }
    let mut after: Vec<Value> = images().iter().map(|row| row["key"].clone()).collect();
    after.sort_by(|a, b| a["asset_id"].as_str().cmp(&b["asset_id"].as_str()));
    assert_eq!(after, keys);
    let kept = organization_state(&s, &c, &keys[0]);
    assert_eq!(kept["rating"], "4", "{kept}");
    assert_eq!(kept["keywords"], organized["keywords"], "{kept}");

    // One Undo step restores every previous association.
    let undone = relink_operation(
        &s,
        &c,
        json!({"command":"undo","args":{"plan":applied["id"],"revision":applied["revision"]}}),
    );
    assert_eq!(undone["phase"], "complete", "{undone}");
    for key in &keys {
        assert_eq!(state(key), "missing");
    }
    assert_eq!(organization_state(&s, &c, &keys[0])["rating"], "4");

    // No source moved or changed; nothing appeared at the old location.
    assert!(!originals.exists());
    assert_eq!(bytes(&moved), online);
    assert_eq!(bytes(&duplicate), online);
    shutdown(&s);
}
