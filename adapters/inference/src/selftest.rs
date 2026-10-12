//! A weights-free GPU self-test: one steel GEMM and one Q4 `quantized_matmul`, evaluated on
//! the calling thread (the executor thread when reached through the C ABI) and checked against
//! a CPU reference. It proves the Metal kernels in the metallib MLX actually loaded work, and
//! reports that metallib.

use mlx_rs::{Array, ops};
use serde_json::{Value, json};

use crate::metallib;

/// Deterministic values in roughly [-0.75, 0.75].
fn pattern(n: usize, salt: usize) -> Vec<f32> {
    (0..n)
        .map(|i| (((i * 7 + salt * 13) % 17) as f32 - 8.0) / 10.67)
        .collect()
}

/// `a (m×k) · b (k×n)` (or `b` given as `n×k` when `b_transposed`) in f64.
fn reference(a: &[f32], b: &[f32], m: usize, k: usize, n: usize, b_transposed: bool) -> Vec<f64> {
    let mut out = vec![0f64; m * n];
    for i in 0..m {
        for j in 0..n {
            let mut acc = 0f64;
            for t in 0..k {
                let bv = if b_transposed {
                    b[j * k + t]
                } else {
                    b[t * n + j]
                };
                acc += f64::from(a[i * k + t]) * f64::from(bv);
            }
            out[i * n + j] = acc;
        }
    }
    out
}

/// Largest absolute deviation, relative to the reference's largest magnitude (so the bound
/// does not depend on the operands' scale or the GPU's accumulation order).
fn relative_error(got: &[f32], want: &[f64]) -> f64 {
    let scale = want
        .iter()
        .fold(0.0f64, |m, w| m.max(w.abs()))
        .max(f64::MIN_POSITIVE);
    got.iter()
        .zip(want)
        .map(|(g, w)| (f64::from(*g) - w).abs())
        .fold(0.0, f64::max)
        / scale
}

fn check(name: &str, shape: [usize; 3], got: &[f32], want: &[f64], tolerance: f64) -> Value {
    let error = if got.len() == want.len() && got.iter().all(|v| v.is_finite()) {
        relative_error(got, want)
    } else {
        f64::INFINITY
    };
    json!({"op": name, "shape_mkn": shape, "max_rel_error": if error.is_finite() { json!(error) } else { json!(null) },
           "tolerance": tolerance, "ok": error <= tolerance})
}

fn gemm() -> Result<Value, String> {
    // Large enough for MLX's steel (tiled) GEMM kernels rather than the GEMV path.
    let (m, k, n) = (128usize, 256usize, 192usize);
    let (a, b) = (pattern(m * k, 1), pattern(k * n, 2));
    let out = ops::matmul(
        Array::from_slice(&a, &[m as i32, k as i32]),
        Array::from_slice(&b, &[k as i32, n as i32]),
    )
    .map_err(|e| format!("matmul: {e}"))?;
    out.eval().map_err(|e| format!("matmul eval: {e}"))?;
    Ok(check(
        "steel_gemm_f32",
        [m, k, n],
        out.as_slice::<f32>(),
        &reference(&a, &b, m, k, n, false),
        2e-3,
    ))
}

fn quantized() -> Result<Value, String> {
    // M = 64 rows selects the qmm (matrix) kernel rather than qmv.
    let (m, k, n, group, bits) = (64usize, 256usize, 128usize, 64, 4);
    let (x, w) = (pattern(m * k, 3), pattern(n * k, 4));
    let w_array = Array::from_slice(&w, &[n as i32, k as i32]);
    let (wq, scales, biases) =
        ops::quantize(&w_array, group, bits).map_err(|e| format!("quantize: {e}"))?;
    let out = ops::quantized_matmul(
        Array::from_slice(&x, &[m as i32, k as i32]),
        &wq,
        &scales,
        &biases,
        true,
        group,
        bits,
    )
    .map_err(|e| format!("quantized_matmul: {e}"))?;
    out.eval()
        .map_err(|e| format!("quantized_matmul eval: {e}"))?;
    // Reference: the same product over the dequantized weights, so only the qmm kernel is
    // under test (not the quantization error itself).
    let dequantized = ops::dequantize(&wq, &scales, &biases, group, bits)
        .map_err(|e| format!("dequantize: {e}"))?;
    dequantized
        .eval()
        .map_err(|e| format!("dequantize eval: {e}"))?;
    let mut value = check(
        "quantized_matmul_q4",
        [m, k, n],
        out.as_slice::<f32>(),
        &reference(&x, dequantized.as_slice::<f32>(), m, k, n, true),
        2e-3,
    );
    value["group_size"] = json!(group);
    value["bits"] = json!(bits);
    Ok(value)
}

/// Run both kernels and report the result document (`ok` only when both match).
pub fn run() -> Value {
    let resolution = metallib::resolve_once();
    let ops: Vec<Value> = [gemm(), quantized()]
        .into_iter()
        .map(|r| r.unwrap_or_else(|e| json!({"ok": false, "error": e})))
        .collect();
    let ok = ops.iter().all(|o| o["ok"] == true);
    json!({
        "ok": ok,
        "thread": std::thread::current().name().unwrap_or("unnamed"),
        // MLX's own record of its strict metallib once Metal ran; null under its search order.
        "metallib": metallib::mlx_pinned_path().map(|p| p.display().to_string()),
        "metallib_resolution": resolution.describe(),
        "ops": ops,
    })
}
