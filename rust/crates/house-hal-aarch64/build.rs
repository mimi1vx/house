fn main() {
    println!("cargo:rustc-check-cfg=cfg(has_house_ram_limit)");
    println!("cargo:rerun-if-env-changed=HOUSE_RAM_LIMIT_BYTES");
    let is_riscv = std::env::var("CARGO_FEATURE_RISCV64").is_ok();
    if is_riscv {
        println!("cargo:rustc-cfg=house_arch=\"riscv64\"");
    } else {
        println!("cargo:rustc-cfg=house_arch=\"aarch64\"");
    }
    if let Ok(v) = std::env::var("HOUSE_RAM_LIMIT_BYTES") {
        println!("cargo:rustc-env=HOUSE_RAM_LIMIT_BYTES={}", v);
        println!("cargo:rustc-cfg=has_house_ram_limit");
    }
}
