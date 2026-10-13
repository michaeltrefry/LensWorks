// The C interface of the sandboxed filter-plugin runtime (adapters/plugins). docs/PLUGINS.md is the contract.
#ifndef LENSWORKS_PLUGINS_H
#define LENSWORKS_PLUGINS_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Every bound a plugin runs under (adapters/plugins/src/lib.rs `LIMITS`).
typedef struct LWPluginLimits {
    uint64_t module_bytes;
    uint64_t memory_bytes;
    uint64_t table_elements;
    uint64_t stack_bytes;
    uint64_t recursion_depth;
    uint64_t tile_pixels;
    uint64_t fuel_buffer_call;
    uint64_t fuel_filter_base;
    uint64_t fuel_per_pixel;
    uint64_t parameters;
    uint32_t interface_version;
} LWPluginLimits;

void lw_plugin_limits(LWPluginLimits *out);

/// Validates a module without running it. 0 when it conforms; otherwise `message` (NUL-terminated UTF-8) says why.
int32_t lw_plugin_validate(const uint8_t *wasm, size_t length, char *message, size_t capacity);

/// Validates and instantiates a module with its parameter values. NULL on failure, with the reason in `message`.
void *lw_plugin_open(const uint8_t *wasm, size_t length, const double *parameters, size_t count, char *message, size_t capacity);

/// Filters one tile of width × height RGBA float32 pixels (straight alpha, linear) in place. 0 on success; otherwise
/// the pixels are unchanged, `message` says why, and the instance refuses every later call.
int32_t lw_plugin_filter_tile(void *instance, float *pixels, size_t count, uint32_t width, uint32_t height, uint32_t x, uint32_t y,
                              uint32_t frame_width, uint32_t frame_height, char *message, size_t capacity);

void lw_plugin_close(void *instance);

#ifdef __cplusplus
}
#endif

#endif
