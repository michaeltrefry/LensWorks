;; LensWorks sample plugin: Position gradient: red and green become the pixel's place in the layer, so tiling must agree with one whole frame.
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
    (local $col i32) (local $row i32)
    (block $rows
      (loop $nextrow
        (br_if $rows (i32.ge_u (local.get $row) (local.get $h)))
        (local.set $col (i32.const 0))
        (block $cols
          (loop $nextcol
            (br_if $cols (i32.ge_u (local.get $col) (local.get $w)))
            (f32.store (local.get $ptr) (f32.div (f32.convert_i32_u (i32.add (local.get $x) (local.get $col))) (f32.convert_i32_u (local.get $fw))))
            (f32.store offset=4 (local.get $ptr) (f32.div (f32.convert_i32_u (i32.add (local.get $y) (local.get $row))) (f32.convert_i32_u (local.get $fh))))
            (local.set $ptr (i32.add (local.get $ptr) (i32.const 16)))
            (local.set $col (i32.add (local.get $col) (i32.const 1)))
            (br $nextcol)))
        (local.set $row (i32.add (local.get $row) (i32.const 1)))
        (br $nextrow)))
    (i32.const 0)
  )
)
