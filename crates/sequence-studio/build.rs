//! Windows: the main thread gets 1 MB of stack (macOS 8 MB); the shell builds large frames on it, so ask for 8 MB.
//! The exe carries the real app icon (`packaging/windows/SequenceStudio.ico`, from `App/AppIcon.icon`) as its icon
//! resource, so Explorer, the taskbar and the shortcuts show it also for a `cargo run` build.

fn main() {
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("windows")
        && std::env::var("CARGO_CFG_TARGET_ENV").as_deref() == Ok("msvc")
    {
        println!("cargo::rustc-link-arg-bins=/STACK:8388608");
        embed_icon();
        delay_load_ffmpeg();
    }
}

/// Links the FFmpeg DLLs lazily: the Windows loader then does not look for them before `main`, so a missing or blocked
/// DLL cannot end the process with a system dialog before the app can open its own error window. The start loads them
/// itself (`preflight.rs`) and names the one that fails; `SQ_FFMPEG_DLLS` carries the file names to it. The names come
/// from `sq-media-ffmpeg/build.rs` (DEP_CSQFFMPEG_DLLS), which also makes the import libraries the linker can delay-load
/// from; without them (a stub build, no `llvm-lib`) nothing changes.
fn delay_load_ffmpeg() {
    let Ok(dlls) = std::env::var("DEP_CSQFFMPEG_DLLS") else { return };
    for name in dlls.split(',').filter(|n| !n.is_empty()) {
        println!("cargo::rustc-link-arg-bins=/DELAYLOAD:{name}");
    }
    println!("cargo::rustc-link-arg-bins=delayimp.lib");
    println!("cargo::rustc-env=SQ_FFMPEG_DLLS={dlls}");
}

/// Icon and version resource. Not gated on the build host (`cfg(windows)` is the host): a cross build from Linux or
/// the Mac (`cargo xwin`) embeds them through `llvm-rc`, which `winresource` finds on PATH.
fn embed_icon() {
    let ico = "../../packaging/windows/SequenceStudio.ico";
    println!("cargo::rerun-if-changed={ico}");
    let version = std::env::var("CARGO_PKG_VERSION").unwrap_or_else(|_| "0.0.0".into());
    let mut res = winresource::WindowsResource::new();
    res.set_icon(ico);
    res.set("ProductName", "Sequence Studio");
    res.set("FileDescription", "Sequence Studio");
    res.set("InternalName", "SequenceStudio");
    res.set("OriginalFilename", "SequenceStudio.exe");
    res.set("FileVersion", &version);
    res.set("ProductVersion", &version);
    // The publisher of the installer script (Windows/Installer/SequenceStudio.iss: AppPublisher).
    res.set("CompanyName", "Paul Herter");
    res.set("LegalCopyright", "Copyright (C) 2026 Paul Herter. GPL-3.0-or-later.");
    if let Err(e) = res.compile() {
        println!("cargo::warning=exe icon and version not embedded: {e}");
    }
}
