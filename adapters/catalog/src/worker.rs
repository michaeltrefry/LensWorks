// Compile the exact owned executable dispatch, including every descendant
// worker mode. The complete dispatch is copied into LensWorks; upstream remains unchanged.
mod retained {
    include!("../../../engines/catalog/src/main.rs");
    pub fn run() -> anyhow::Result<()> {
        main()
    }
}
fn main() -> anyhow::Result<()> {
    if std::env::args_os()
        .nth(1)
        .is_some_and(|v| v == "--lensworks-full-decode")
    {
        return lensworks_catalog::full_decode::worker_main();
    }
    retained::run()
}
