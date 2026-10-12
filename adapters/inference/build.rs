fn main() {
    println!("cargo:rerun-if-changed=shim/metallib.cpp");
    cc::Build::new()
        .cpp(true)
        .std("c++17")
        .file("shim/metallib.cpp")
        .compile("lw_mlx_shim");
    // The metallib this build of MLX produced; tests copy it to prove the strict pin.
    if let Ok(path) = std::env::var("DEP_MLX_METALLIB") {
        println!("cargo:rustc-env=LW_MLX_BUILD_METALLIB={path}");
    }
}
