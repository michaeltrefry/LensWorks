#ifndef LENSWORKS_CATALOG_H
#define LENSWORKS_CATALOG_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Blocking version-1 JSON ABI. Invoke on a background executor.
 * request must point to a valid NUL-terminated UTF-8 string (<= 1 MiB).
 * Returned string is owned by Rust; free exactly once with the function below.
 * No handles, callbacks, or borrowed output buffers cross this boundary.
 * A NULL request returns a typed invalid_request JSON response.
 * See ../README.md for the request/response schema and path requirements. */
char *lw_catalog_request(const char *request);
/* NULL is accepted. Other pointers must come from lw_catalog_request. */
void lw_catalog_string_free(char *response);
/* Managed ABI version 2. All calls run off the UI/main thread. Envelopes are
 * length-delimited UTF-8 JSON, never NUL-terminated. See README managed schema.
 * request[0..length] and out_buffer must be valid caller-owned memory. NULL
 * request is accepted only for length=0. <=4MiB input. Rust never borrows input
 * after return. Every nonzero out_buffer is an owned generation-stamped handle.
 * JSON results (including typed errors) are copied with buffer_copy and released
 * exactly once with buffer_release. Handle integers in JSON are decimal strings.
 * Return 0: JSON response available, 1: invalid C arguments, 2: resource limit,
 * 3: panic fenced, 4: invalid/stale/wrong-kind handle, 5: range error, 6: busy.
 * A nonzero status never assigns an output handle. */
int32_t lw_catalog_managed_request(const uint8_t *request, size_t length,
                                  uint64_t *out_buffer);
/* Exact BLAKE3 for retained sealed uploads/proofs. Run off the main thread.
 * Caller supplies readable bytes[0..length] (<=4MiB) and writable out_digest[32].
 * NULL bytes iff length=0. Success 0 writes exactly 32 raw digest bytes; error 1
 * invalid arguments, 5 oversized input, 3 fenced panic leaves output untouched.
 * No input or output pointer is retained and no registry handle is allocated. */
int32_t lw_catalog_blake3(const uint8_t *bytes, size_t length,
                         uint8_t out_digest[32]);
/* Streaming BLAKE3: at most 16 live constant-state hashers, generation-stamped
 * handles. Unlimited finite updates, each <=4MiB, with the same pointer rules.
 * init success assigns owned out_hasher; failure clears it. finalize writes 32
 * bytes exactly once; subsequent update/finalize returns 6 (finalized). Release
 * exactly once even after finalize. Stale/released/wrong-kind handle returns 4,
 * init allowance returns 2; other statuses match one-shot. Calls are serialized
 * per hasher; callers determine update order. No pointers are retained. */
int32_t lw_catalog_blake3_init(uint64_t *out_hasher);
int32_t lw_catalog_blake3_update(uint64_t hasher, const uint8_t *bytes,
                               size_t length);
int32_t lw_catalog_blake3_finalize(uint64_t hasher, uint8_t out_digest[32]);
int32_t lw_catalog_blake3_release(uint64_t hasher);
/* Copy a range. No borrowed Rust pointer escapes. On success writes count;
 * offset<=length, capacity may exceed remaining bytes. NULL dst iff capacity=0.
 * Buffers remain valid until explicit release, independent of session lifetime. */
int32_t lw_catalog_buffer_copy(uint64_t buffer, size_t offset, uint8_t *dst,
                               size_t capacity, size_t *out_count);
int32_t lw_catalog_buffer_release(uint64_t buffer);
/* Optional job-completion notification. Callback receives only opaque IDs and
 * executes on a background receiver thread; obtain data using job_result.
 * context stays caller-owned until unsubscribe_and_drain succeeds. Never
 * unwind through callback. Reentrant drain from its own callback returns busy.
 * timeout_ms<=60000; timeout leaves subscription closed but context retained.
 * Retry drain before freeing context. Session shutdown closes subscriptions. */
typedef void (*lw_catalog_completion)(void *context, uint64_t session,
                                      uint64_t job);
int32_t lw_catalog_subscribe(uint64_t session, lw_catalog_completion callback,
                            void *context, uint64_t *out_subscription);
int32_t lw_catalog_unsubscribe_and_drain(uint64_t subscription,
                                        uint32_t timeout_ms);
#ifdef __cplusplus
}
#endif
#endif
