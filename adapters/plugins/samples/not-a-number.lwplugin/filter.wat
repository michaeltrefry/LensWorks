;; LensWorks sample plugin: Hostile: returns a pixel that is not a finite number.
;; Filter interface lensworks_filter_v1 (docs/PLUGINS.md). Pixels are RGBA float32, straight alpha, linear light.
;; Built by scripts/build-sample-plugins.sh; the committed filter.wasm is checked against this source in CI.
(module
  ;; 17 pages: the 1 MiB tile buffer starts at 65536, above a page left for the module's own use.
  (memory (export "memory") 17)
  (func (export "lw_tile_buffer") (param $bytes i32) (result i32)
    (if (result i32) (i32.gt_u (local.get $bytes) (i32.const 1048576))
      (then (i32.const 0))
      (else (i32.const 65536))))
  (func (export "lw_filter_tile") (param $ptr i32) (param $w i32) (param $h i32) (param $x i32) (param $y i32) (param $fw i32) (param $fh i32) (result i32)
    (f32.store (local.get $ptr) (f32.div (f32.const 0) (f32.const 0)))
    (i32.const 0)
  )
)
