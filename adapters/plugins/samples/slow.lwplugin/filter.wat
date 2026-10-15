;; LensWorks sample plugin: Slow invert: counts down from spins on every tile, then inverts it. It succeeds, slowly.
;; Filter interface lensworks_filter_v1 (docs/PLUGINS.md). Pixels are RGBA float32, straight alpha, linear light.
;; Built by scripts/build-sample-plugins.sh; the committed filter.wasm is checked against this source in CI.
(module
  (import "lensworks_filter_v1" "param" (func $param (param i32) (result f64)))
  ;; 17 pages: the 1 MiB tile buffer starts at 65536, above a page left for the module's own use.
  (memory (export "memory") 17)
  (func (export "lw_tile_buffer") (param $bytes i32) (result i32)
    (if (result i32) (i32.gt_u (local.get $bytes) (i32.const 1048576))
      (then (i32.const 0))
      (else (i32.const 65536))))
  (func (export "lw_filter_tile") (param $ptr i32) (param $w i32) (param $h i32) (param $x i32) (param $y i32) (param $fw i32) (param $fh i32) (result i32)
    (local $end i32) (local $spins i64)
    ;; The one parameter: how many times to go round an empty loop before filtering the tile.
    (local.set $spins (i64.trunc_sat_f64_s (call $param (i32.const 0))))
    (block $spun
      (loop $spin
        (br_if $spun (i64.le_s (local.get $spins) (i64.const 0)))
        (local.set $spins (i64.sub (local.get $spins) (i64.const 1)))
        (br $spin)))
    (local.set $end (i32.add (local.get $ptr) (i32.shl (i32.mul (local.get $w) (local.get $h)) (i32.const 4))))
    (block $done
      (loop $next
        (br_if $done (i32.ge_u (local.get $ptr) (local.get $end)))
        (f32.store offset=0 (local.get $ptr) (f32.sub (f32.const 1) (f32.load offset=0 (local.get $ptr))))
        (f32.store offset=4 (local.get $ptr) (f32.sub (f32.const 1) (f32.load offset=4 (local.get $ptr))))
        (f32.store offset=8 (local.get $ptr) (f32.sub (f32.const 1) (f32.load offset=8 (local.get $ptr))))
        (local.set $ptr (i32.add (local.get $ptr) (i32.const 16)))
        (br $next)))
    (i32.const 0)
  )
)
