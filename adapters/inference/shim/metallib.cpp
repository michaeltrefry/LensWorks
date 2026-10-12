// Upstream MLX's strict metallib override (mlx::core::metal::set_metallib_path). Unlike the
// pmetal search chain, a path set here is the only one MLX tries: if it cannot be loaded,
// device creation fails instead of silently falling back to another metallib.
#include <string>

namespace mlx::core::metal {
void set_metallib_path(const std::string& path);
const std::string& get_metallib_path();
}

extern "C" void lw_mlx_set_metallib_path(const char* path) {
    mlx::core::metal::set_metallib_path(path ? std::string(path) : std::string());
}
