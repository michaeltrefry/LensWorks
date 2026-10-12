#ifndef LENSWORKS_INFERENCE_H
#define LENSWORKS_INFERENCE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* LensWorks-owned ABI over the pinned SceneWorks inference macOS runtime.
 * The library is loaded at runtime (dlopen) from liblensworks_inference.dylib.
 * See adapters/inference/README.md for the full contract. */

#define LW_INFERENCE_ABI_VERSION 1u

#define LW_INFERENCE_ALPHA_NONE 0u
#define LW_INFERENCE_ALPHA_STRAIGHT 1u
#define LW_INFERENCE_ALPHA_PREMULTIPLIED 2u
#define LW_INFERENCE_COLOR_SPACE_SRGB 1u

enum {
    LW_INFERENCE_EVENT_STARTED = 1,
    LW_INFERENCE_EVENT_PROGRESS = 2,
    LW_INFERENCE_EVENT_IMAGE = 3,
    LW_INFERENCE_EVENT_MASK = 4,
    LW_INFERENCE_EVENT_COMPLETED = 5,
    LW_INFERENCE_EVENT_FAILED = 6,
    LW_INFERENCE_EVENT_CANCELLED = 7,
};

/* A caller-owned 8-bit sRGB input. Read (and copied) only during lw_inference_job_start.
 * channels: 1 (gray/mask, alpha NONE), 3 (RGB, alpha NONE) or 4 (RGBA, STRAIGHT or
 * PREMULTIPLIED). row_bytes >= width * channels; the last row needs no padding. */
typedef struct lw_inference_image {
    const uint8_t *pixels;
    size_t byte_length;
    uint32_t width;
    uint32_t height;
    uint32_t row_bytes;
    uint32_t channels;
    uint32_t alpha;
    uint32_t color_space;
} lw_inference_image;

/* An event borrowed for the duration of the callback only: copy what you keep.
 * json is always a NUL-terminated UTF-8 object. pixels is non-NULL only for IMAGE (1, 3 or 4
 * channels, tightly packed, straight alpha) and MASK (1 channel, 0 or 255) events. */
typedef struct lw_inference_event {
    uint32_t kind;
    const char *json;
    const uint8_t *pixels;
    size_t byte_length;
    uint32_t width;
    uint32_t height;
    uint32_t row_bytes;
    uint32_t channels;
    uint32_t alpha;
    uint32_t color_space;
} lw_inference_event;

/* Invoked on the inference executor thread, never concurrently for one job. Keep it short. */
typedef void (*lw_inference_callback)(void *context, const lw_inference_event *event);

typedef struct LwInferenceJob lw_inference_job;

uint32_t lw_inference_abi_version(void);

/* Owned JSON {"version":1,"ok":true,"result":{...}}; release with lw_inference_string_free. */
char *lw_inference_capabilities(void);

/* Weights-free GPU self-test, run on the executor thread after the jobs queued ahead of it:
 * a steel GEMM and a Q4 quantized_matmul checked against a CPU reference. Owned JSON
 * {"version":1,"ok":bool,"result":{"metallib":<path MLX loaded, or null under its own search
 * order>,"metallib_resolution":...,"ops":[...]}}; release with lw_inference_string_free. */
char *lw_inference_self_test(void);

/* NULL is allowed. Never free these strings with any other allocator. */
void lw_inference_string_free(char *value);

/* Copies and validates the inputs synchronously and queues the job (callers on a UI thread
 * should call this from a background thread: input copies scale with the image size). An input
 * edge above 16384 pixels fails with kind "input_too_large". On failure returns NULL and, when error_out is
 * non-NULL, stores an owned JSON {"kind","message"}. On success the job owns no caller memory
 * except context, which must remain valid until lw_inference_job_release returns. Every job
 * not released first receives exactly one terminal event (COMPLETED, FAILED or CANCELLED). */
lw_inference_job *lw_inference_job_start(const char *request_json,
                                         const lw_inference_image *inputs,
                                         size_t input_count,
                                         lw_inference_callback callback,
                                         void *context,
                                         char **error_out);

/* Cooperative cancel; idempotent, any thread. */
void lw_inference_job_cancel(const lw_inference_job *job);

/* Cancels if running and frees the handle exactly once. When it returns no callback for the
 * job is running or will run. Safe to call from inside the job's own callback. */
void lw_inference_job_release(lw_inference_job *job);

/* Blocks until queued jobs ahead finish, then drops resident models. Returns the count. */
size_t lw_inference_release_models(void);

#ifdef __cplusplus
}
#endif

#endif
