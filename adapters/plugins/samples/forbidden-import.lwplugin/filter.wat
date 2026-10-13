;; LensWorks sample plugin: Hostile: asks for a WASI file write, which the filter interface does not provide.
;; Filter interface lensworks_filter_v1 (docs/PLUGINS.md). Pixels are RGBA float32, straight alpha, linear light.
;; Built by scripts/build-sample-plugins.sh; the committed filter.wasm is checked against this source in CI.
(module
  (import "wasi_snapshot_preview1" "fd_write" (func $fd_write (param i32 i32 i32 i32) (result i32)))
  ;; 17 pages: the 1 MiB tile buffer starts at 65536, above a page left for the module's own use.
  (memory (export "memory") 17)
  (func (export "lw_tile_buffer") (param $bytes i32) (result i32)
    (if (result i32) (i32.gt_u (local.get $bytes) (i32.const 1048576))
      (then (i32.const 0))
      (else (i32.const 65536))))
  (func (export "lw_filter_tile") (param $ptr i32) (param $w i32) (param $h i32) (param $x i32) (param $y i32) (param $fw i32) (param $fh i32) (result i32)
    (drop (call $fd_write (i32.const 1) (i32.const 0) (i32.const 0) (i32.const 0)))
    (i32.const 0)
  )
)
