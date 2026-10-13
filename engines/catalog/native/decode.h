#pragma once
#include <cstdint>
#include <cstddef>
extern "C" {
struct PcDecodeLimits {
    uint64_t max_encoded_bytes, max_intermediate_pixels, max_allocation_bytes;
};
struct PcWhitePoint { double x, y; }; // {0,0} preserves the as-shot path.
struct PcImage {
    float *pixels;
    unsigned char *icc;
    size_t icc_size;
    uint32_t width, height, bits, orientation, primaries, transfer, flags;
    uint64_t calibration_applied_pixels, calibration_bypassed_pixels;
    // Linear-sRGB value of a neutral subject at the exposure where its first sensor channel
    // saturates: above it a neutral highlight is clipped. Valid only when neutral_clip_valid != 0.
    float neutral_clip[3];
    uint32_t neutral_clip_valid;
    char make[128], model[128], profile[128], error[256];
};
// Callback receives one full, unoriented float row. Zero continues; nonzero
// cancels/fails the decode before any next row. No vendor object crosses the ABI.
// Cancellation context is independently immutable/Sync; SDK workers never
// touch the mutable row consumer or its color-transform state.
struct PcDecodeControl { int (*canceled)(void *); void *context; };
typedef int (*PcRowSink)(void *context, const PcImage *image, uint32_t row, const float *rgba);
int pc_raw_rows(const unsigned char *, size_t, const PcDecodeLimits *, const PcWhitePoint *, PcImage *, PcRowSink, void *, const PcDecodeControl *);
int pc_dng_rows(const unsigned char *, size_t, const PcDecodeLimits *, const PcWhitePoint *, PcImage *, PcRowSink, void *, const PcDecodeControl *);
int pc_avif_rows(const unsigned char *, size_t, const PcDecodeLimits *, PcImage *, PcRowSink, void *, const PcDecodeControl *);
void pc_free(PcImage *out);
}
int fail(PcImage *out, const char *message);
bool allocate(PcImage *out, const PcDecodeLimits *limits);

inline bool pc_canceled(const PcDecodeControl *control) {
    return control && control->canceled && control->canceled(control->context)!=0;
}
