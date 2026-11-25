//! Windows: the setup program carries the app icon, a version resource and a manifest that asks for no elevation
//! (`asInvoker`: no UAC prompt, the install goes to the user's own folders) and for per-monitor DPI awareness. Not gated on
//! the build host: a cross build from Linux or the Mac (`cargo xwin`) embeds them through `llvm-rc`, which `winresource`
//! finds on PATH.

const MANIFEST: &str = r#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0">
  <trustInfo xmlns="urn:schemas-microsoft-com:asm.v3">
    <security>
      <requestedPrivileges>
        <requestedExecutionLevel level="asInvoker" uiAccess="false"/>
      </requestedPrivileges>
    </security>
  </trustInfo>
  <compatibility xmlns="urn:schemas-microsoft-com:compatibility.v1">
    <application>
      <supportedOS Id="{8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a}"/>
    </application>
  </compatibility>
  <application xmlns="urn:schemas-microsoft-com:asm.v3">
    <windowsSettings>
      <dpiAwareness xmlns="http://schemas.microsoft.com/SMI/2016/WindowsSettings">PerMonitorV2</dpiAwareness>
      <longPathAware xmlns="http://schemas.microsoft.com/SMI/2016/WindowsSettings">true</longPathAware>
    </windowsSettings>
  </application>
</assembly>
"#;

fn main() {
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("windows")
        || std::env::var("CARGO_CFG_TARGET_ENV").as_deref() != Ok("msvc")
    {
        return;
    }
    // The Nightly channel (SQ_CHANNEL, set by `cargo xtask package --channel nightly`) carries the blue icon.
    println!("cargo::rerun-if-env-changed=SQ_CHANNEL");
    let nightly = std::env::var("SQ_CHANNEL").as_deref() == Ok("nightly");
    let ico = if nightly {
        "../../packaging/windows/SequenceStudio-Nightly.ico"
    } else {
        "../../packaging/windows/SequenceStudio.ico"
    };
    println!("cargo::rerun-if-changed={ico}");
    let version = std::env::var("CARGO_PKG_VERSION").unwrap_or_else(|_| "0.0.0".into());
    let mut res = winresource::WindowsResource::new();
    res.set_icon(ico);
    res.set_manifest(MANIFEST);
    res.set("ProductName", if nightly { "Sequence Studio Nightly" } else { "Sequence Studio" });
    res.set("FileDescription", "Sequence Studio Setup");
    res.set("InternalName", "SequenceStudioSetup");
    res.set("OriginalFilename", "SequenceStudio-Setup.exe");
    res.set("FileVersion", &version);
    res.set("ProductVersion", &version);
    res.set("CompanyName", "Paul Herter");
    res.set("LegalCopyright", "Copyright (C) 2026 Paul Herter. GPL-3.0-or-later.");
    if let Err(e) = res.compile() {
        println!("cargo::warning=setup icon, version and manifest not embedded: {e}");
    }
}
