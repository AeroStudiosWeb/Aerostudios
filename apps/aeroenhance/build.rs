// Embed the AeroEnhance application icon in Windows Explorer/shortcuts.
// The eframe window icon is supplied separately in src/main.rs.
fn main() {
    println!("cargo:rerun-if-changed=assets/aeroenhance.ico");

    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("windows") {
        #[cfg(windows)]
        {
            let mut resource = winresource::WindowsResource::new();
            resource
                .set_icon("assets/aeroenhance.ico")
                .set("FileDescription", "AeroEnhance Studio")
                .set("ProductName", "AeroStudios AeroEnhance Studio")
                .set("InternalName", "AeroEnhance-Studio.exe")
                .set("OriginalFilename", "AeroEnhance-Studio.exe");
            resource.compile().expect("Failed to compile AeroEnhance Windows icon resource. Confirm Windows SDK rc.exe is installed.");
        }
    }
}
