// Upstream MLX's strict metallib override (mlx::core::metal::set_metallib_path). Unlike the
// pmetal search chain, a path set here is the only one MLX tries: if it cannot be loaded,
// device creation fails instead of silently falling back to another metallib.
#include <cstring>
#include <string>

namespace mlx::core::metal {
void set_metallib_path(const std::string& path);
const std::string& get_metallib_path();
}

extern "C" void lw_mlx_set_metallib_path(const char* path) {
    mlx::core::metal::set_metallib_path(path ? std::string(path) : std::string());
}

// Copies MLX's strict metallib path (empty when none is pinned) into `out`; returns its length.
extern "C" size_t lw_mlx_get_metallib_path(char* out, size_t capacity) {
    const std::string& path = mlx::core::metal::get_metallib_path();
    if (out && capacity > 0) {
        size_t n = path.size() < capacity - 1 ? path.size() : capacity - 1;
        std::memcpy(out, path.data(), n);
        out[n] = '\0';
    }
    return path.size();
}
