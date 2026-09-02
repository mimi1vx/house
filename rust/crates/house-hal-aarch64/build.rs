fn main() {
    let is_riscv = std::env::var("CARGO_FEATURE_RISCV64").is_ok();
    if is_riscv {
        println!("cargo:rustc-cfg=house_arch=\"riscv64\"");
    } else {
        println!("cargo:rustc-cfg=house_arch=\"aarch64\"");
    }
}
