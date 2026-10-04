#ifndef LENSWORKS_CATALOG_H
#define LENSWORKS_CATALOG_H
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
#ifdef __cplusplus
}
#endif
#endif
