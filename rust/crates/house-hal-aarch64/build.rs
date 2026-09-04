fn main() {
    println!("cargo:rustc-check-cfg=cfg(house_arch, values(\"riscv64\", \"aarch64\"))");
    let is_riscv = std::env::var("CARGO_FEATURE_RISCV64").is_ok();
    if is_riscv {
        println!("cargo:rustc-cfg=house_arch=\"riscv64\"");
    } else {
        println!("cargo:rustc-cfg=house_arch=\"aarch64\"");
    }
}
