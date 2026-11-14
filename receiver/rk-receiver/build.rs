//! Hands the target triple to the crate so `--diag` can say what the binary was built for.

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    let target = std::env::var("TARGET").unwrap_or_else(|_| "unknown".into());
    println!("cargo:rustc-env=RK_TARGET={target}");
}
