//! Builds the vendored C++ shim over FFmpeg (the LGPL shared build; on the Mac Homebrew's). Where no FFmpeg is found
//! nothing is compiled or linked and the `sq_ffmpeg` cfg stays off: the crate then builds with a stub shim that fails
//! to open anything, so machines without FFmpeg still build the workspace.
//!
//! Lookup: `SQ_FFMPEG` (a folder with `include` and `lib`), on Windows `%USERPROFILE%\ffmpeg\ffmpeg-master-latest-win64-lgpl-shared`,
//! else `pkg-config`.

use std::path::PathBuf;
use std::process::Command;

mod build_def;

struct Found {
    includes: Vec<PathBuf>,
    lib_dirs: Vec<PathBuf>,
}

fn from_folder(root: PathBuf) -> Option<Found> {
    let (inc, lib) = (root.join("include"), root.join("lib"));
    inc.join("libavcodec").is_dir().then_some(Found { includes: vec![inc], lib_dirs: vec![lib] })
}

fn from_pkg_config() -> Option<Found> {
    let out = Command::new("pkg-config")
        .args(["--cflags", "--libs", "libavformat", "libavcodec", "libavutil", "libswscale", "libswresample"])
        .output()
        .ok()
        .filter(|o| o.status.success())?;
    let text = String::from_utf8(out.stdout).ok()?;
    let mut found = Found { includes: Vec::new(), lib_dirs: Vec::new() };
    for word in text.split_whitespace() {
        if let Some(dir) = word.strip_prefix("-I") {
            found.includes.push(dir.into());
        } else if let Some(dir) = word.strip_prefix("-L") {
            found.lib_dirs.push(dir.into());
        }
    }
    Some(found)
}

fn locate() -> Option<Found> {
    println!("cargo:rerun-if-env-changed=SQ_FFMPEG");
    if let Some(root) = std::env::var_os("SQ_FFMPEG") {
        return from_folder(root.into());
    }
    if let Some(home) = std::env::var_os("USERPROFILE") {
        let root = PathBuf::from(home).join("ffmpeg").join("ffmpeg-master-latest-win64-lgpl-shared");
        if let Some(found) = from_folder(root) {
            return Some(found);
        }
    }
    from_pkg_config()
}

/// The five libraries the shim links, leaves first (a library after the ones it needs).
const LIBS: [&str; 5] = ["avutil", "swresample", "swscale", "avcodec", "avformat"];

/// Windows (MSVC target): the FFmpeg build's own import libraries are made by dlltool, and the linker cannot delay-load
/// from those. Rebuilds them in the standard short format from the `.def` files next to them (`llvm-lib`, else the MSVC
/// `lib.exe`), into `out`, so `sequence-studio/build.rs` can delay-load the DLLs and the app can open its own error window
/// when one is missing. Returns the DLL file names. When a step is not possible it returns `None` with a warning (the link
/// then uses the original libraries and the loader looks for the DLLs before `main`, as before), or stops the build with an
/// error when `SQ_REQUIRE_DELAYLOAD=1` (the package builds set it: such an exe must not ship).
fn short_import_libs(lib_dirs: &[PathBuf], out: &std::path::Path) -> Option<Vec<String>> {
    println!("cargo:rerun-if-env-changed=SQ_REQUIRE_DELAYLOAD");
    match make_short_import_libs(lib_dirs, out) {
        Ok(dlls) => Some(dlls),
        Err(why) if build_def::delay_load_required(std::env::var("SQ_REQUIRE_DELAYLOAD").ok().as_deref()) => {
            eprintln!(
                "error: sq-media-ffmpeg: {why}; SQ_REQUIRE_DELAYLOAD=1 forbids an exe that loads the FFmpeg DLLs eagerly"
            );
            std::process::exit(1);
        }
        Err(why) => {
            println!("cargo:warning=sq-media-ffmpeg: {why}; DLLs are not delay-loaded");
            None
        }
    }
}

fn make_short_import_libs(lib_dirs: &[PathBuf], out: &std::path::Path) -> Result<Vec<String>, String> {
    let mut dlls = Vec::new();
    for lib in LIBS {
        let prefix = format!("{lib}-");
        let def = lib_dirs
            .iter()
            .find_map(|dir| {
                std::fs::read_dir(dir).ok()?.flatten().map(|e| e.path()).find(|p| {
                    let name = p.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
                    name.starts_with(&prefix) && name.ends_with(".def")
                })
            })
            .ok_or_else(|| format!("no {lib}-<n>.def beside the import libraries"))?;
        let dll =
            def.file_stem().map(|n| n.to_string_lossy().into_owned() + ".dll").ok_or("a .def file without a name")?;
        let text = std::fs::read_to_string(&def).map_err(|e| format!("{}: {e}", def.display()))?;
        let local = out.join(format!("{lib}.def"));
        std::fs::write(&local, build_def::def_with_library(&text, &dll))
            .map_err(|e| format!("{}: {e}", local.display()))?;
        let lib_out = out.join(format!("{lib}.lib"));
        let args =
            [format!("/def:{}", local.display()), format!("/out:{}", lib_out.display()), "/machine:x64".to_string()];
        let ran = ["llvm-lib", "lib"]
            .iter()
            .any(|tool| Command::new(tool).args(&args).output().is_ok_and(|o| o.status.success()) && lib_out.exists())
            || cc::windows_registry::find_tool("x86_64-pc-windows-msvc", "lib.exe").is_some_and(|tool| {
                tool.to_command().args(&args).output().is_ok_and(|o| o.status.success()) && lib_out.exists()
            });
        if !ran {
            return Err(format!("llvm-lib / lib.exe could not make {lib}.lib"));
        }
        dlls.push(dll);
    }
    Ok(dlls)
}

fn main() {
    println!("cargo:rerun-if-changed=vendor");
    println!("cargo:rerun-if-env-changed=SQ_ALLOW_STUB_SHIM");
    let Some(found) = locate() else {
        let target_os = std::env::var("CARGO_CFG_TARGET_OS").ok();
        if build_def::stub_shim_refused(target_os.as_deref(), std::env::var("SQ_ALLOW_STUB_SHIM").ok().as_deref()) {
            eprintln!(
                "error: sq-media-ffmpeg: no FFmpeg found for a Windows build (SQ_FFMPEG must name the folder with include and lib); \
                 the stub shim would fail every decode with -38. SQ_ALLOW_STUB_SHIM=1 builds it anyway (compile checks only)."
            );
            std::process::exit(1);
        }
        println!("cargo:warning=sq-media-ffmpeg: FFmpeg not found (set SQ_FFMPEG); building the stub shim");
        return;
    };
    let mut build = cc::Build::new();
    build.cpp(true).std("c++17").include("vendor").warnings(false);
    // A braced init that narrows (int to bool) is a warning on gcc but an error on Apple clang and clang-cl, so
    // every compiler rejects it here and Linux cannot pass what the other two refuse. MSVC proper skips both flags.
    build.flag_if_supported("-Werror=narrowing").flag_if_supported("-Werror=c++11-narrowing");
    for dir in &found.includes {
        build.include(dir);
    }
    for entry in std::fs::read_dir("vendor").into_iter().flatten().flatten() {
        let path = entry.path();
        if path.extension().is_some_and(|e| e == "cpp") {
            build.file(path);
        }
    }
    build.compile("csqffmpeg");
    // The short-format libraries go first in the search order, so they win over the FFmpeg build's own.
    let msvc = std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("windows")
        && std::env::var("CARGO_CFG_TARGET_ENV").as_deref() == Ok("msvc");
    if let (true, Some(out)) = (msvc, std::env::var_os("OUT_DIR").map(PathBuf::from))
        && let Some(dlls) = short_import_libs(&found.lib_dirs, &out)
    {
        println!("cargo:rustc-link-search=native={}", out.display());
        // Read by `sequence-studio/build.rs` as DEP_CSQFFMPEG_DLLS (this package's `links` key).
        println!("cargo:dlls={}", dlls.join(","));
    }
    for dir in &found.lib_dirs {
        println!("cargo:rustc-link-search=native={}", dir.display());
    }
    for lib in ["avformat", "avcodec", "avutil", "swscale", "swresample"] {
        println!("cargo:rustc-link-lib={lib}");
    }
    println!("cargo:rustc-cfg=sq_ffmpeg");
}
