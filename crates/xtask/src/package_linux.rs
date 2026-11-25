// SPDX-License-Identifier: GPL-3.0-or-later
//! `cargo xtask package [--no-smoke]` on Linux: builds `target/package/SequenceStudio-<version>-<yyyyMMdd-HHmm>-x86_64.AppImage`.
//!
//! Layout of the AppDir: `usr/bin` holds the executable and, beside it, `Fonts`, `SubjectMask` and `libonnxruntime.so` (the
//! places the app already looks in, see `fonts_root`, `EdgeTAMOnnxLocation`, csqonnx.c); `usr/lib` holds the FFmpeg shared
//! libraries (rpath `$ORIGIN/../lib`). SPIR-V shaders are compiled into the executable. Everything that comes from the
//! system (libc, Vulkan loader, Wayland/X11, ALSA/Pulse) stays a host library, as for any AppImage.
//!
//! Environment: `SQ_FFMPEG` (folder with `lib`, an LGPL shared build; a GPL or nonfree one is refused), `SQ_ONNXRUNTIME` (folder
//! with `libonnxruntime.so`, else the pinned release is fetched), `SQ_SUBJECT_MASK_MODELS`, `SQ_APPIMAGETOOL` (else
//! `appimagetool` on PATH), `SQ_BUILD_CACHE`, `SQ_DEPS` (the folder `scripts/linux-deps.sh` fills: `ffmpeg-linux` and
//! `appimagetool-x86_64.AppImage` in it stand in for an unset `SQ_FFMPEG` / `SQ_APPIMAGETOOL`). Needs `patchelf`.

use std::path::{Path, PathBuf};
use std::process::Command;

use crate::channel::Channel;
use crate::package::{run, workspace_version};

/// A build tool: the path in `var`, else `name` inside the folder `SQ_DEPS` names (`scripts/linux-deps.sh` fills it), when
/// that exists.
fn dep(var: &str, name: &str) -> Option<PathBuf> {
    dep_from(std::env::var_os(var), std::env::var_os("SQ_DEPS"), name)
}

fn dep_from(var: Option<std::ffi::OsString>, deps: Option<std::ffi::OsString>, name: &str) -> Option<PathBuf> {
    if let Some(v) = var.filter(|v| !v.is_empty()) {
        return Some(PathBuf::from(v));
    }
    Some(PathBuf::from(deps?).join(name)).filter(|p| p.exists())
}

/// The file name of a build: unique per build (version and minute), like the Mac DMG and the Windows installer.
fn image_name(channel: Channel, version: &str, stamp: &str) -> String {
    format!("{}-{version}-{stamp}-x86_64.AppImage", channel.file_prefix())
}

/// Libraries of `lib` the executable needs, found with `ldd`, followed through their own dependencies.
fn needed_from(exe: &Path, lib: &Path) -> Result<Vec<PathBuf>, String> {
    let mut found: Vec<PathBuf> = Vec::new();
    let mut queue = vec![exe.to_path_buf()];
    while let Some(next) = queue.pop() {
        let text = run(Command::new("ldd").env("LD_LIBRARY_PATH", lib).arg(&next))?;
        for line in text.lines() {
            let Some(path) = line.split("=>").nth(1).and_then(|r| r.split_whitespace().next()) else { continue };
            let path = PathBuf::from(path);
            if path.starts_with(lib) && !found.contains(&path) {
                queue.push(path.clone());
                found.push(path);
            }
        }
    }
    Ok(found)
}

/// A release must carry an LGPL FFmpeg: libavcodec embeds its configure line, so refuse `--enable-gpl` / `--enable-nonfree`.
fn check_lgpl(libs: &[PathBuf]) -> Result<(), String> {
    for p in libs.iter().filter(|p| p.file_name().is_some_and(|n| n.to_string_lossy().starts_with("libavcodec"))) {
        let bytes = std::fs::read(p).map_err(|e| e.to_string())?;
        for flag in ["--enable-gpl", "--enable-nonfree"] {
            if bytes.windows(flag.len()).any(|w| w == flag.as_bytes()) {
                return Err(format!("{} was configured with {flag}: bundle an LGPL FFmpeg (SQ_FFMPEG)", p.display()));
            }
        }
    }
    Ok(())
}

/// The newest system symbol versions a bundled ELF file may need: what Ubuntu 22.04 (glibc 2.35, GCC 12 libstdc++) provides.
/// The release is built in an Ubuntu 22.04 container (`scripts/package-linux-compat.sh`); this check fails the package
/// when a binary still asks for more (issue #22: built on glibc 2.43, GLIBC_2.43 not found on Mint 22.3).
const BASELINE: [(&str, &[u32]); 3] = [("GLIBC_", &[2, 35]), ("GLIBCXX_", &[3, 4, 30]), ("CXXABI_", &[1, 3, 13])];

/// Version needs above the baseline in `objdump -T` output: one `"GLIBC_2.43 symbol"` entry per undefined symbol.
fn versions_too_new(objdump: &str) -> Vec<String> {
    let mut bad = Vec::new();
    for line in objdump.lines().filter(|l| l.contains("*UND*")) {
        let mut words = line.split_whitespace().rev();
        let (Some(symbol), Some(ver)) = (words.next(), words.next()) else { continue };
        let ver = ver.trim_matches(|c| c == '(' || c == ')');
        for (prefix, max) in BASELINE {
            let Some(rest) = ver.strip_prefix(prefix) else { continue };
            let nums: Vec<u32> = rest.split('.').map_while(|n| n.parse().ok()).collect();
            if nums.as_slice() > max {
                bad.push(format!("{ver} {symbol}"));
            }
        }
    }
    bad
}

/// Every ELF file under `usr/` of the AppDir (the executable, `usr/lib/*`, `usr/bin/*.so`) against `BASELINE`.
fn check_glibc_baseline(app_dir: &Path) -> Result<(), String> {
    let mut problems = Vec::new();
    let mut dirs = vec![app_dir.join("usr")];
    while let Some(dir) = dirs.pop() {
        for entry in std::fs::read_dir(&dir).map_err(|e| format!("{}: {e}", dir.display()))?.flatten() {
            let path = entry.path();
            let Ok(kind) = entry.file_type() else { continue };
            if kind.is_dir() {
                dirs.push(path);
            } else if kind.is_file() && std::fs::read(&path).is_ok_and(|b| b.starts_with(b"\x7fELF")) {
                let text = run(Command::new("objdump").arg("-T").arg(&path))?;
                for v in versions_too_new(&text) {
                    problems.push(format!("{} needs {v}", path.strip_prefix(app_dir).unwrap_or(&path).display()));
                }
            }
        }
    }
    if problems.is_empty() {
        return Ok(());
    }
    problems.sort();
    problems.dedup();
    let shown = problems.len().min(20);
    Err(format!(
        "{} system version need(s) above the Ubuntu 22.04 baseline (GLIBC 2.35, GLIBCXX 3.4.30, CXXABI 1.3.13); build with scripts/package-linux-compat.sh:\n  {}",
        problems.len(),
        problems[..shown].join("\n  ")
    ))
}

fn copy_to(from: &Path, to: &Path) -> Result<(), String> {
    std::fs::copy(from, to).map(|_| ()).map_err(|e| format!("{}: {e}", from.display()))
}

pub fn run_package(root: &Path, args: &[String], channel: Channel, date: &str) -> Result<(), String> {
    let no_smoke = args.iter().any(|a| a == "--no-smoke");
    if let Some(bad) = args.iter().find(|a| *a != "--no-smoke") {
        return Err(format!("unknown option {bad}; usage: cargo xtask package [--no-smoke]"));
    }
    let ffmpeg = dep("SQ_FFMPEG", "ffmpeg-linux")
        .ok_or("SQ_FFMPEG must name an LGPL FFmpeg shared build (scripts/linux-deps.sh fetches one into $SQ_DEPS)")?;
    let version = channel.version(&workspace_version(root), date);
    let pk = root.join("packaging/linux");

    let mut build = crate::cargo(&["build", "--release", "-p", "sequence-studio"]);
    build.env("SQ_CHANNEL", channel.id()).env("SQ_BUILD_VERSION", &version);
    crate::step("release build", build)?;
    let target = std::env::var_os("CARGO_TARGET_DIR").map(PathBuf::from).unwrap_or_else(|| root.join("target"));
    let release = target.join("release/sequence-studio");
    if !release.exists() {
        return Err(format!("{} missing after the build", release.display()));
    }

    let out = target.join("package");
    let app_dir = out.join("SequenceStudio.AppDir");
    let _ = std::fs::remove_dir_all(&app_dir);
    let (bin, lib) = (app_dir.join("usr/bin"), app_dir.join("usr/lib"));
    for d in [&bin, &lib, &app_dir.join("usr/share/applications"), &app_dir.join("usr/share/mime/packages")] {
        std::fs::create_dir_all(d).map_err(|e| e.to_string())?;
    }
    let exe = bin.join("sequence-studio");
    copy_to(&release, &exe)?;

    // FFmpeg: only what the executable needs, under the soname it asks for.
    let libs = needed_from(&release, &ffmpeg.join("lib"))?;
    check_lgpl(&libs)?;
    let mut bundled = vec![exe.clone()];
    for l in &libs {
        let dest = lib.join(l.file_name().ok_or("library name")?);
        copy_to(l, &dest)?;
        bundled.push(dest);
    }
    for f in &bundled {
        run(Command::new("patchelf")
            .args(["--set-rpath", if f == &exe { "$ORIGIN/../lib" } else { "$ORIGIN" }])
            .arg(f))?;
    }
    println!("   {} FFmpeg libraries in usr/lib", libs.len());

    // ONNX Runtime is loaded at run time from beside the executable.
    let ort = match std::env::var_os("SQ_ONNXRUNTIME") {
        Some(dir) => PathBuf::from(dir).join("libonnxruntime.so"),
        None => crate::onnxruntime::fetch_linux()?,
    };
    copy_to(&ort, &bin.join("libonnxruntime.so"))?;
    if let Some(shared) = ort.parent().map(|d| d.join("libonnxruntime_providers_shared.so")).filter(|p| p.exists()) {
        copy_to(&shared, &bin.join("libonnxruntime_providers_shared.so"))?;
    }

    let fonts = bin.join("Fonts");
    crate::stage::copy_fonts(&root.join("Packages/SQText/Sources/SQText/Resources/Fonts"), &fonts)?;

    // The EdgeTAM ONNX parts (not in the repo).
    let models = std::env::var_os("SQ_SUBJECT_MASK_MODELS")
        .map(PathBuf::from)
        .unwrap_or_else(|| root.join("Tools/SubjectMaskSpike/work/models-onnx"));
    let names = ["encoder", "decoder", "decoder_box", "mem_encoder", "mem_attention"];
    if names.iter().all(|n| models.join(format!("edgetam_{n}.onnx")).exists()) {
        let dest = bin.join("SubjectMask");
        std::fs::create_dir_all(&dest).map_err(|e| e.to_string())?;
        for n in names {
            copy_to(&models.join(format!("edgetam_{n}.onnx")), &dest.join(format!("edgetam_{n}.onnx")))?;
        }
    } else {
        println!(
            "== models: no EdgeTAM ONNX parts in {} (set SQ_SUBJECT_MASK_MODELS); Magic Mask will report them missing",
            models.display()
        );
    }

    // Licenses, notes, desktop integration.
    let licenses = bin.join("Licenses");
    std::fs::create_dir_all(&licenses).map_err(|e| e.to_string())?;
    // The shared list every package ships (macOS and Windows use it too), plus what only the Linux package carries.
    let linux_only = ["packaging/linux/NOTES.txt", "LICENSE", "LICENSE-ADDITIONAL-TERMS.md", "SUPPORTERS.md"];
    for f in crate::notices::LICENSE_FILES.iter().chain(linux_only.iter()) {
        copy_to(&root.join(f), &licenses.join(Path::new(f).file_name().ok_or("license name")?))?;
    }
    // The desktop entry and icon carry the channel id; the Nightly entry gets its own name and window class.
    let id = channel.linux_id();
    let mut desktop = std::fs::read_to_string(pk.join("sequence-studio.desktop")).map_err(|e| e.to_string())?;
    if channel != Channel::Stable {
        desktop = desktop
            .replace("Name=Sequence Studio", &format!("Name={}", channel.display_name()))
            .replace("Icon=sequence-studio", &format!("Icon={id}"))
            .replace("StartupWMClass=sequence-studio", &format!("StartupWMClass={id}"));
    }
    std::fs::write(app_dir.join(format!("{id}.desktop")), &desktop).map_err(|e| e.to_string())?;
    std::fs::write(app_dir.join(format!("usr/share/applications/{id}.desktop")), &desktop)
        .map_err(|e| e.to_string())?;
    copy_to(
        &pk.join("de.paulherter.sequencestudio.xml"),
        &app_dir.join("usr/share/mime/packages/de.paulherter.sequencestudio.xml"),
    )?;
    let icon = pk.join(channel.linux_icon());
    copy_to(&icon, &app_dir.join(format!("{id}.png")))?;
    copy_to(&icon, &app_dir.join(".DirIcon"))?;
    let icons = app_dir.join("usr/share/icons/hicolor/256x256/apps");
    std::fs::create_dir_all(&icons).map_err(|e| e.to_string())?;
    copy_to(&icon, &icons.join(format!("{id}.png")))?;
    copy_to(&pk.join("AppRun"), &app_dir.join("AppRun"))?;

    if !no_smoke {
        let shot = out.join("smoke-ui-shot.png");
        let _ = std::fs::remove_file(&shot);
        run(Command::new(&exe).env_remove("LD_LIBRARY_PATH").arg("--ui-shot").arg(&shot).args(["--size", "800x500"]))?;
        let len = std::fs::metadata(&shot).map(|m| m.len()).map_err(|e| format!("no shot written: {e}"))?;
        if len < 1000 {
            return Err(format!("{} is only {len} bytes", shot.display()));
        }
        println!("smoke ok: {} ({len} bytes)", shot.display());
    }

    check_glibc_baseline(&app_dir)?;
    crate::stage::check(&app_dir, &["common", "linux"])?;

    let stamp = run(Command::new("date").arg("+%Y%m%d-%H%M"))?.trim().to_string();
    let image = out.join(image_name(channel, &version, &stamp));
    let tool = dep("SQ_APPIMAGETOOL", "appimagetool-x86_64.AppImage").unwrap_or_else(|| PathBuf::from("appimagetool"));
    // The tool is itself an AppImage: run it without FUSE.
    run(Command::new(tool).env("APPIMAGE_EXTRACT_AND_RUN", "1").env("ARCH", "x86_64").arg(&app_dir).arg(&image))?;
    println!("package ok: {}", image.display());
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_tool_comes_from_its_variable_else_from_the_deps_folder() {
        let dir = std::env::temp_dir().join(format!("sq-xtask-deps-{}", std::process::id()));
        std::fs::create_dir_all(dir.join("ffmpeg-linux")).expect("dir");
        let os = |s: &str| Some(std::ffi::OsString::from(s));
        assert_eq!(
            dep_from(os("/x/ff"), os(dir.to_str().expect("utf8")), "ffmpeg-linux"),
            Some(PathBuf::from("/x/ff"))
        );
        assert_eq!(dep_from(None, os(dir.to_str().expect("utf8")), "ffmpeg-linux"), Some(dir.join("ffmpeg-linux")));
        assert_eq!(dep_from(os(""), os(dir.to_str().expect("utf8")), "ffmpeg-linux"), Some(dir.join("ffmpeg-linux")));
        assert_eq!(dep_from(None, os(dir.to_str().expect("utf8")), "missing"), None);
        assert_eq!(dep_from(None, None, "ffmpeg-linux"), None);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn versions_above_the_ubuntu_2204_baseline_are_listed() {
        let dump = "\
0000000000000000      DF *UND*\t0000000000000000 (GLIBC_2.2.5) memcpy
0000000000000000      DF *UND*\t0000000000000000 (GLIBC_2.35)  pthread_cond_clockwait
0000000000000000      DF *UND*\t0000000000000000 (GLIBC_2.43)  fmod
0000000000000000      DF *UND*\t0000000000000000 GLIBC_2.38    strlcpy
0000000000000000      DO *UND*\t0000000000000000 (GLIBCXX_3.4.30) _ZTVN10__cxxabiv117__class_type_infoE
0000000000000000      DF *UND*\t0000000000000000 (GLIBCXX_3.4.32) _ZNSt6thread6_StateD2Ev
0000000000000000      DO *UND*\t0000000000000000 (CXXABI_1.3.15) __cxa_foo
0000000000000000 g    DF .text\t0000000000000010 (GLIBC_2.99) defined_here_is_fine";
        assert_eq!(
            versions_too_new(dump),
            [
                "GLIBC_2.43 fmod",
                "GLIBC_2.38 strlcpy",
                "GLIBCXX_3.4.32 _ZNSt6thread6_StateD2Ev",
                "CXXABI_1.3.15 __cxa_foo"
            ]
        );
        assert!(versions_too_new("0 DF *UND*\t0 (GLIBC_2.3.4) a\n0 DF *UND*\t0 (GLIBC_2.9) b").is_empty());
    }

    #[test]
    fn the_image_name_carries_version_and_build_minute() {
        assert_eq!(
            image_name(Channel::Stable, "0.1.2", "20261112-2202"),
            "SequenceStudio-0.1.2-20261112-2202-x86_64.AppImage"
        );
        assert_eq!(
            image_name(Channel::Nightly, "0.1.2-nightly.20261112", "20261112-2202"),
            "SequenceStudioNightly-0.1.2-nightly.20261112-20261112-2202-x86_64.AppImage"
        );
    }

    #[test]
    fn a_gpl_libavcodec_is_refused_and_an_lgpl_one_passes() {
        let dir = std::env::temp_dir().join(format!("sq-xtask-lin-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("dir");
        let lib = dir.join("libavcodec.so.63");
        std::fs::write(&lib, "configuration: --enable-version3 --disable-debug").expect("write");
        assert!(check_lgpl(std::slice::from_ref(&lib)).is_ok());
        std::fs::write(&lib, "configuration: --enable-gpl --enable-version3").expect("write");
        assert!(check_lgpl(std::slice::from_ref(&lib)).is_err());
        let _ = std::fs::remove_dir_all(dir);
    }
}
