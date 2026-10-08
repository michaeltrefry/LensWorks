#!/usr/bin/env python3
"""Execute exact owned public-service semantic fixtures, separately from ABI tests."""
import json
import os
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[3]
ENGINE = ROOT / "engines/catalog"
subprocess.run([sys.executable, str(ROOT / "scripts/catalog_source.py")], check=True)
ENV = dict(os.environ, MACOSX_DEPLOYMENT_TARGET="26.2", CARGO_BUILD_JOBS="4",
           PHOTOCATALOG_DNG_SDK=str(ROOT / ".build/deps/dng_sdk_1_7_1_2724/dng_sdk_1_7_1"),
           PHOTOCATALOG_TEST_EXECUTABLE=str(ROOT / ".build/rust-catalog/release/photocatalog"))
CARGO = ["cargo", "test", "--release", "--locked", "--manifest-path", str(ENGINE / "Cargo.toml"),
         "--target-dir", str(ROOT / ".build/rust-catalog")]
CASES = [
    "application::organization::tests::hierarchy_collection_cas_membership_and_synonyms_preserve_evidence",
    "application::organization::tests::variant_batch_is_durable_single_unit_cancelable_and_never_becomes_master",
    "application::relink::tests::atomic_relink_status_write_hold_cancel_commit_wins_and_close_undo",
    "application::copy::tests::all_groups_are_frozen_and_preserve_other_target_settings",
    "application::copy::tests::run_foreground_holds_cas_cancel_and_explicit_resume",
    "application::backup::tests::backup_inspect_restore_keep_receipts_and_hold",
    "application::desktop::migration::tests::actual::lm_facade_actual_managed_run_status_preserve_raw_rows_and_reap_all_roles",
    "application::desktop::migration::tests::actual::lm_facade_actual_remaining_five_routes_preserve_repairs_and_status",
    "application::desktop::workbench_capability_tests::managed_dispatcher_preserves_sealed_artifact_and_approval_capabilities",
    "filesystem_worker::metadata_files::tests::filesystem_owner_plans_applies_and_restores_without_losing_original",
    "application::metadata::tests::selected_copy_resolution_cas_and_opaque_provenance_preserve_originals",
    "application::metadata::tests::exact_utf16_packet_chunks_ownership_checksum_and_cancel",
]
additional = "--additional-only" in sys.argv[1:]
with (ROOT / ".build/rust-catalog-retained-tests.log").open("a" if additional else "w") as log:
    def run(cmd):
        log.write("COMMAND " + repr(cmd) + "\n"); log.flush()
        proc = subprocess.Popen(cmd, cwd=ROOT, env=ENV, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        lines = []
        for line in proc.stdout:
            log.write(line); lines.append(line)
        log.flush()
        assert proc.wait() == 0, "retained fixture failed; inspect log"
        return "".join(lines)
    artifacts = run(CARGO + ["--lib", "--no-run", "--message-format=json"])
    executable = None
    for line in artifacts.splitlines():
        try: obj = json.loads(line)
        except json.JSONDecodeError: continue
        if obj.get("reason") == "compiler-artifact" and obj.get("profile", {}).get("test") and obj.get("executable"):
            executable = obj["executable"]
    assert executable, "missing exact retained library test executable"
    for case in CASES[-2:] if additional else CASES:
        result = run([executable, "--exact", case, "--include-ignored", "--test-threads=1", "--nocapture"])
        assert re.search(r"test result: ok\. 1 passed; 0 failed; 0 ignored;", result), case
        print("PASS", case, flush=True)
    result = run([executable, "application::preview_settings::tests::", "--include-ignored", "--test-threads=1", "--nocapture"])
    summary = re.search(r"test result: ok\. (\d+) passed; 0 failed; 0 ignored;", result)
    assert summary and int(summary[1]) > 0, "preview settings profile missing acceptance summary"
    print("PASS preview_settings", summary[1], "tests", flush=True)
    if additional:
        sys.exit(0)
    # The entire retained application bridge profile covers real browsing/search,
    # import, preview, independent variants/recipes, organization, relink,
    # edit/export recovery authority, and backup/restore ownership.
    result = run(CARGO + ["--test", "application_bridge", "--", "--test-threads=1"])
    summary = re.search(r"test result: ok\. (\d+) passed; 0 failed; 0 ignored;", result)
    assert summary, "application bridge profile missing acceptance summary"
    print("PASS application_bridge", summary[1], "tests", flush=True)
