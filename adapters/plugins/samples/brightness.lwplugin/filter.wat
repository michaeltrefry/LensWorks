;; LensWorks sample plugin: Brightness: adds amount x repeat to the chosen channels.
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
    (local $add f32) (local $channel i32) (local $clamp i32) (local $v f32) (local $end i32)
    ;; Parameters arrive by index, in the manifest's order: amount, channel (its choice index), clamp (0 or 1), repeat.
    (local.set $add (f32.demote_f64 (f64.mul (call $param (i32.const 0)) (call $param (i32.const 3)))))
    (local.set $channel (i32.trunc_sat_f64_s (call $param (i32.const 1))))
    (local.set $clamp (i32.trunc_sat_f64_s (call $param (i32.const 2))))
    (local.set $end (i32.add (local.get $ptr) (i32.shl (i32.mul (local.get $w) (local.get $h)) (i32.const 4))))
    (block $done
      (loop $next
        (br_if $done (i32.ge_u (local.get $ptr) (local.get $end)))
        (if (i32.or (i32.eqz (local.get $channel)) (i32.eq (local.get $channel) (i32.const 1)))
          (then
            (local.set $v (f32.add (f32.load offset=0 (local.get $ptr)) (local.get $add)))
            (if (local.get $clamp) (then (local.set $v (f32.min (f32.const 1) (f32.max (f32.const 0) (local.get $v))))))
            (f32.store offset=0 (local.get $ptr) (local.get $v))))
        (if (i32.or (i32.eqz (local.get $channel)) (i32.eq (local.get $channel) (i32.const 2)))
          (then
            (local.set $v (f32.add (f32.load offset=4 (local.get $ptr)) (local.get $add)))
            (if (local.get $clamp) (then (local.set $v (f32.min (f32.const 1) (f32.max (f32.const 0) (local.get $v))))))
            (f32.store offset=4 (local.get $ptr) (local.get $v))))
        (if (i32.or (i32.eqz (local.get $channel)) (i32.eq (local.get $channel) (i32.const 3)))
          (then
            (local.set $v (f32.add (f32.load offset=8 (local.get $ptr)) (local.get $add)))
            (if (local.get $clamp) (then (local.set $v (f32.min (f32.const 1) (f32.max (f32.const 0) (local.get $v))))))
            (f32.store offset=8 (local.get $ptr) (local.get $v))))
        (local.set $ptr (i32.add (local.get $ptr) (i32.const 16)))
        (br $next)))
    (i32.const 0)
  )
)
