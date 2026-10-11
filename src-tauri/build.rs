fn main() {
    println!("cargo:rerun-if-changed=../scripts/render-tray-icon.swift");
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
        let path = std::path::PathBuf::from(std::env::var_os("OUT_DIR").unwrap()).join("tray-moon.png");
        let status = std::process::Command::new("swift")
            .arg("../scripts/render-tray-icon.swift")
            .arg(&path)
            .status()
            .expect("Swift is required to render the macOS system tray symbol");
        assert!(status.success(), "could not render the macOS moon.fill symbol");
    }
    tauri_build::build()
}
