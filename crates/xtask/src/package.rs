// SPDX-License-Identifier: GPL-3.0-or-later
//! `cargo xtask package [--sign] [--notarize] [--dmg] [--no-smoke]`: builds `target/package/Sequence Studio.app` on the Mac.
//! On Windows it runs `packaging/windows/build-installer.ps1` (`--sign`; `--inno` for the old Inno Setup installer).
//!
//! Steps: release build, bundle layout (Info.plist, icon, fonts), bundled non-system dylibs (FFmpeg, ONNX runtime) with
//! rewritten install names, inside-out signing, portability check, headless `--ui-shot` smoke test.
//!
//! Signing is ad-hoc unless `--sign` is given. `--sign` reads the identity from `SQ_SIGN_ID` (a "Developer ID
//! Application: ..." name), `--notarize` the notarytool keychain profile from `SQ_NOTARY_PROFILE` (default `sq-notary`; `SQ_NOTARY_KEYCHAIN` names its keychain),
//! the same way scripts/package.sh does. Credentials are never read or stored here. The Developer ID path is documented
//! in packaging/macos/README.md and has not been run.
//!
//! `--channel nightly` (or `SQ_CHANNEL=nightly`) packages Sequence Studio Nightly: own name, bundle id, icon and file names, version
//! `<x.y.z>-nightly.<YYYYMMDD>`, so it installs beside Stable (names in channel.rs).
//!
//! Environment: `SQ_FFMPEG` (FFmpeg folder, see sq-media-ffmpeg/build.rs), `SQ_ONNXRUNTIME` (folder with
//! libonnxruntime*.dylib to bundle instead of the pinned download), `SQ_SUBJECT_MASK_MODELS` (EdgeTAM ONNX parts to bundle),
//! `SQ_BUILD_CACHE` (download cache), `SQ_NICE`.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::process::Command;

use crate::channel::{self, Channel};

const APP_NAME: &str = "Sequence Studio";

#[derive(Default, Debug, PartialEq)]
struct Options {
    sign: bool,
    notarize: bool,
    dmg: bool,
    no_smoke: bool,
}

fn parse(args: &[String]) -> Result<Options, String> {
    let mut o = Options::default();
    for a in args {
        match a.as_str() {
            "--sign" => o.sign = true,
            "--notarize" => o.notarize = true,
            "--dmg" => o.dmg = true,
            "--no-smoke" => o.no_smoke = true,
            other => {
                return Err(format!(
                    "unknown option {other}; usage: cargo xtask package [--sign] [--notarize] [--dmg] [--no-smoke]"
                ));
            }
        }
    }
    if o.notarize && !o.sign {
        return Err("--notarize needs --sign (only a Developer ID signature can be notarized)".into());
    }
    Ok(o)
}

pub(crate) fn run(cmd: &mut Command) -> Result<String, String> {
    let shown = format!("{cmd:?}");
    let out = cmd.output().map_err(|e| format!("cannot start {shown}: {e}"))?;
    if out.status.success() {
        Ok(String::from_utf8_lossy(&out.stdout).into_owned())
    } else {
        Err(format!("{shown} failed: {}", String::from_utf8_lossy(&out.stderr).trim()))
    }
}

/// Linked libraries from `otool -L` output (first line is the file itself and is skipped).
fn linked(otool: &str) -> Vec<String> {
    otool.lines().skip(1).filter_map(|l| l.split_whitespace().next()).map(String::from).collect()
}

/// True for libraries that ship with macOS or are already bundle-relative.
fn is_system(path: &str) -> bool {
    path.starts_with("/System/")
        || path.starts_with("/usr/lib/")
        || path.starts_with("@executable_path")
        || path.starts_with("@loader_path")
}

/// The install name a bundled library gets, relative to `Contents/MacOS`.
fn bundled_name(file_name: &str) -> String {
    format!("@executable_path/../Frameworks/{file_name}")
}

/// Where a dependency really lives: absolute paths as they are, `@rpath/x` next to the library that asked for it
/// or in the extra search folders.
fn resolve(dep: &str, asker: &Path, extra: &[PathBuf]) -> Option<PathBuf> {
    if let Some(rest) = dep.strip_prefix("@rpath/") {
        let dirs = asker.parent().into_iter().map(Path::to_path_buf).chain(extra.iter().cloned());
        return dirs.map(|d| d.join(rest)).find(|p| p.exists());
    }
    let p = PathBuf::from(dep);
    p.is_absolute().then_some(p).filter(|p| p.exists())
}

/// Copies every non-system dependency (transitively) into `frameworks` and points all references at the copies.
/// Returns the bundled files.
fn bundle_libs(binary: &Path, frameworks: &Path, extra: &[PathBuf]) -> Result<Vec<PathBuf>, String> {
    std::fs::create_dir_all(frameworks).map_err(|e| e.to_string())?;
    // original real path -> bundled path
    let mut done: BTreeMap<PathBuf, PathBuf> = BTreeMap::new();
    let mut queue: Vec<(PathBuf, PathBuf)> = vec![(binary.to_path_buf(), binary.to_path_buf())];
    let mut seen_names = BTreeSet::new();
    while let Some((orig, current)) = queue.pop() {
        let text = run(Command::new("otool").arg("-L").arg(&current))?;
        for dep in linked(&text) {
            if is_system(&dep) {
                continue;
            }
            let Some(real) = resolve(&dep, &orig, extra) else {
                return Err(format!("{}: cannot find {dep}", orig.display()));
            };
            let real = std::fs::canonicalize(&real).map_err(|e| e.to_string())?;
            let file = real.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
            if !done.contains_key(&real) {
                if !seen_names.insert(file.clone()) {
                    return Err(format!("two different libraries named {file}"));
                }
                let target = frameworks.join(&file);
                std::fs::copy(&real, &target).map_err(|e| format!("copy {}: {e}", real.display()))?;
                make_writable(&target)?;
                run(Command::new("install_name_tool").args(["-id", &bundled_name(&file)]).arg(&target))?;
                done.insert(real.clone(), target.clone());
                queue.push((real.clone(), target));
            }
            run(Command::new("install_name_tool").args(["-change", &dep, &bundled_name(&file)]).arg(&current))?;
        }
    }
    Ok(done.into_values().collect())
}

fn make_writable(p: &Path) -> Result<(), String> {
    let mut perms = std::fs::metadata(p).map_err(|e| e.to_string())?.permissions();
    #[allow(clippy::permissions_set_readonly_false)]
    perms.set_readonly(false);
    std::fs::set_permissions(p, perms).map_err(|e| e.to_string())
}

/// Copies our own finished bundle (the DMG stage); a folder that comes from outside goes through `stage::copy_fonts`.
#[cfg(unix)]
fn copy_dir(from: &Path, to: &Path) -> Result<(), String> {
    if cfg!(target_os = "macos") {
        return run(Command::new("ditto").arg(from).arg(to)).map(|_| ());
    }
    std::fs::create_dir_all(to).map_err(|e| e.to_string())?;
    run(Command::new("cp").arg("-R").arg(from.join(".")).arg(to)).map(|_| ())
}

pub(crate) fn workspace_version(root: &Path) -> String {
    let text = std::fs::read_to_string(root.join("Cargo.toml")).unwrap_or_default();
    text.lines()
        .skip_while(|l| !l.trim().starts_with("[workspace.package]"))
        .find_map(|l| l.trim().strip_prefix("version").and_then(|r| r.split('"').nth(1)).map(String::from))
        .unwrap_or_else(|| "0.0.0".into())
}

fn codesign(path: &Path, id: &str, entitlements: &Path, timestamp: bool) -> Result<(), String> {
    let mut c = Command::new("codesign");
    c.args(["--force", "--options", "runtime"]);
    c.arg(if timestamp { "--timestamp" } else { "--timestamp=none" });
    c.arg("--entitlements").arg(entitlements).args(["-s", id]).arg(path);
    run(&mut c).map(|_| ())
}

/// Dylibs first, the app last; `--deep` is only used for verifying.
fn sign_all(app: &Path, libs: &[PathBuf], id: &str, entitlements: &Path) -> Result<(), String> {
    let timestamp = id != "-";
    for l in libs {
        codesign(l, id, entitlements, timestamp)?;
    }
    codesign(app, id, entitlements, timestamp)?;
    run(Command::new("codesign").args(["--verify", "--deep", "--strict"]).arg(app))?;
    Ok(())
}

/// Only system libraries and bundle-relative paths may remain, and no absolute rpaths.
/// A release must carry an LGPL FFmpeg: libavcodec embeds its configure line, so refuse `--enable-gpl` / `--enable-nonfree`.
fn check_lgpl(frameworks: &Path) -> Result<(), String> {
    let Ok(rd) = std::fs::read_dir(frameworks) else { return Ok(()) };
    for e in rd.flatten() {
        let name = e.file_name().to_string_lossy().into_owned();
        if !(name.starts_with("libavcodec") && name.ends_with(".dylib")) {
            continue;
        }
        let bytes = std::fs::read(e.path()).map_err(|e| e.to_string())?;
        for flag in ["--enable-gpl", "--enable-nonfree"] {
            if bytes.windows(flag.len()).any(|w| w == flag.as_bytes()) {
                return Err(format!(
                    "{name} was configured with {flag}: a release needs an LGPL FFmpeg (set SQ_FFMPEG, see packaging/macos/README.md)"
                ));
            }
        }
    }
    Ok(())
}

fn check_portable(files: &[PathBuf]) -> Result<(), String> {
    for f in files {
        let text = run(Command::new("otool").arg("-L").arg(f))?;
        let bad: Vec<String> = linked(&text).into_iter().filter(|d| !is_system(d)).collect();
        // A bundled library's own install name (first entry) is bundle-relative and passes `is_system`.
        if !bad.is_empty() {
            return Err(format!("{} links outside the bundle: {}", f.display(), bad.join(", ")));
        }
        let rp = run(Command::new("otool").arg("-l").arg(f))?;
        let abs: Vec<&str> = rp
            .lines()
            .filter_map(|l| l.trim().strip_prefix("path "))
            .filter_map(|l| l.split(" (offset").next())
            .filter(|p| p.starts_with('/') && !p.starts_with("/usr/lib") && !p.starts_with("/System"))
            .collect();
        if !abs.is_empty() {
            return Err(format!("{} has absolute rpaths: {}", f.display(), abs.join(", ")));
        }
    }
    Ok(())
}

fn smoke(app: &Path, fonts: &Path, out_dir: &Path) -> Result<(), String> {
    let shot = out_dir.join("smoke-ui-shot.png");
    let _ = std::fs::remove_file(&shot);
    let exe = app.join("Contents/MacOS").join(APP_NAME);
    // shortcut: the binary finds the fonts through SQ_FONTS or its build-time path; see packaging/macos/README.md.
    run(Command::new(exe).env("SQ_FONTS", fonts).arg("--ui-shot").arg(&shot).args(["--size", "800x500"]))?;
    let len = std::fs::metadata(&shot).map(|m| m.len()).map_err(|e| format!("no shot written: {e}"))?;
    if len < 1000 {
        return Err(format!("{} is only {len} bytes", shot.display()));
    }
    println!("smoke ok: {} ({len} bytes)", shot.display());
    Ok(())
}

/// `--keychain-profile <profile>`, plus `--keychain <path>` from `SQ_NOTARY_KEYCHAIN`: a profile stored with
/// `store-credentials --keychain <path>` is only found when that keychain is named.
fn notary_auth(profile: &str) -> Vec<String> {
    let mut args = vec!["--keychain-profile".to_string(), profile.to_string()];
    if let Some(keychain) = std::env::var_os("SQ_NOTARY_KEYCHAIN") {
        args.push("--keychain".into());
        args.push(keychain.to_string_lossy().into_owned());
    }
    args
}

fn notarize(app: &Path, out_dir: &Path) -> Result<(), String> {
    let profile = std::env::var("SQ_NOTARY_PROFILE").unwrap_or_else(|_| "sq-notary".into());
    let zip = out_dir.join("notarize-app.zip");
    run(Command::new("ditto").args(["-c", "-k", "--keepParent"]).arg(app).arg(&zip))?;
    let log =
        run(Command::new("xcrun").args(["notarytool", "submit"]).arg(&zip).args(notary_auth(&profile)).arg("--wait"))?;
    if !log.contains("status: Accepted") {
        return Err(format!("notarization was not accepted:\n{log}"));
    }
    run(Command::new("xcrun").args(["stapler", "staple"]).arg(app))?;
    let _ = std::fs::remove_file(zip);
    Ok(())
}

pub fn run_package(args: &[String]) -> Result<(), String> {
    let (channel, args) = Channel::extract(args)?;
    let args = args.as_slice();
    let date = channel::today();
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).ancestors().nth(2).unwrap_or(Path::new(".")).to_path_buf();
    if cfg!(windows) {
        // The Windows installer (zip, and the setup program `sq-installer` with the release folder as its payload):
        // build-installer.ps1. `--inno` builds the old Inno Setup installer instead, until the new one is checked.
        let script = root.join("packaging/windows/build-installer.ps1");
        let mut cmd = Command::new("powershell");
        cmd.args(["-NoProfile", "-ExecutionPolicy", "Bypass", "-File"])
            .arg(script)
            .args(channel.windows_script_args(&workspace_version(&root), &date));
        cmd.args(args.iter().filter(|a| *a == "--sign").map(|_| "-Sign"));
        // The exe must delay-load the FFmpeg DLLs (sq-media-ffmpeg/build.rs): a missing tool fails the build.
        cmd.env("SQ_REQUIRE_DELAYLOAD", "1");
        // The setup program takes the channel at build time (SQ_CHANNEL, below): Nightly gets its own names and records.
        cmd.args(args.iter().filter(|a| *a == "--inno").map(|_| "-Inno"));
        cmd.env("SQ_CHANNEL", channel.id()).env("SQ_BUILD_VERSION", channel.version(&workspace_version(&root), &date));
        // `--release`: file names without the build stamp (SequenceStudio-Setup-<version>.exe).
        cmd.args(args.iter().filter(|a| *a == "--release").map(|_| "-Release"));
        let status = cmd.status().map_err(|e| format!("cannot start powershell: {e}"))?;
        return if status.success() { Ok(()) } else { Err(format!("build-installer.ps1 failed ({status})")) };
    }
    if cfg!(target_os = "linux") {
        return crate::package_linux::run_package(&root, args, channel, &date);
    }
    if !cfg!(target_os = "macos") {
        return Err("package builds the macOS bundle, the Windows installer or the Linux AppImage".into());
    }
    let opts = parse(args)?;
    let pk = root.join("packaging/macos");

    // Credentials are only looked up for the Developer ID path.
    let id = if opts.sign {
        std::env::var("SQ_SIGN_ID")
            .map_err(|_| "--sign needs SQ_SIGN_ID (a \"Developer ID Application: ...\" identity)")?
    } else {
        "-".to_string()
    };

    let mut build = crate::cargo(&["build", "--release", "-p", "sequence-studio"]);
    build.env("SQ_CHANNEL", channel.id()).env("SQ_BUILD_VERSION", channel.version(&workspace_version(&root), &date));
    crate::step("release build", build)?;
    // Same rule as the Linux package: a CARGO_TARGET_DIR outside the tree holds the build, the bundle stays in target/.
    let target = std::env::var_os("CARGO_TARGET_DIR").map(PathBuf::from).unwrap_or_else(|| root.join("target"));
    let release = target.join("release/sequence-studio");
    if !release.exists() {
        return Err(format!("{} missing after the build", release.display()));
    }

    let out = root.join("target/package");
    let app = out.join(format!("{}.app", channel.display_name()));
    let _ = std::fs::remove_dir_all(&app);
    let (macos, resources, frameworks) =
        (app.join("Contents/MacOS"), app.join("Contents/Resources"), app.join("Contents/Frameworks"));
    for d in [&macos, &resources] {
        std::fs::create_dir_all(d).map_err(|e| e.to_string())?;
    }
    let exe = macos.join(APP_NAME);
    std::fs::copy(&release, &exe).map_err(|e| e.to_string())?;

    let plist = std::fs::read_to_string(pk.join("Info.plist.in"))
        .map_err(|e| e.to_string())?
        .replace("@VERSION@", &channel.version(&workspace_version(&root), &date))
        .replace("@BUNDLE_ID@", channel.bundle_id())
        .replace("@NAME@", channel.display_name())
        .replace("@BUILD@", &channel.bundle_build(&workspace_version(&root), &date));
    std::fs::write(app.join("Contents/Info.plist"), plist).map_err(|e| e.to_string())?;
    std::fs::copy(pk.join(channel.mac_icon()), resources.join("AppIcon.icns")).map_err(|e| e.to_string())?;
    std::fs::write(app.join("Contents/PkgInfo"), "APPL????").map_err(|e| e.to_string())?;
    let fonts = resources.join("Fonts");
    crate::stage::copy_fonts(&root.join("Packages/SQText/Sources/SQText/Resources/Fonts"), &fonts)?;
    for f in ["SUPPORTERS.md", "LICENSE", "LICENSE-ADDITIONAL-TERMS.md"] {
        std::fs::copy(root.join(f), resources.join(f)).map_err(|e| format!("{f}: {e}"))?;
    }
    // GPL-3.0 section 7 terms and the LGPL FFmpeg notice travel with the app; the third-party lists are generated
    // (scripts/gen-third-party-crates.py) and checked in.
    let licenses = resources.join("Licenses");
    std::fs::create_dir_all(&licenses).map_err(|e| e.to_string())?;
    for f in crate::notices::LICENSE_FILES {
        let name = Path::new(f).file_name().ok_or("license name")?;
        std::fs::copy(root.join(f), licenses.join(name)).map_err(|e| format!("{f}: {e}"))?;
    }

    // ONNX runtime is loaded at run time (sq-onnx, from Contents/Frameworks), so it is not linked. SQ_ONNXRUNTIME names a
    // folder with libonnxruntime*.dylib; without it the pinned release is fetched into the cache (onnxruntime.rs).
    std::fs::create_dir_all(&frameworks).map_err(|e| e.to_string())?;
    let dylib = match std::env::var_os("SQ_ONNXRUNTIME") {
        Some(dir) => std::fs::read_dir(dir)
            .map_err(|e| e.to_string())?
            .flatten()
            .map(|e| e.path())
            .find(|p| {
                p.file_name().is_some_and(|n| {
                    n.to_string_lossy().starts_with("libonnxruntime") && n.to_string_lossy().ends_with(".dylib")
                })
            })
            .ok_or("SQ_ONNXRUNTIME has no libonnxruntime*.dylib")?,
        None => crate::onnxruntime::fetch_macos()?,
    };
    // Always under the name sq-onnx looks for; fs::copy follows the version symlink.
    std::fs::copy(&dylib, frameworks.join("libonnxruntime.dylib")).map_err(|e| e.to_string())?;
    // The pinned dylib names itself @rpath/libonnxruntime.<version>.dylib: give it the bundle-relative install name.
    run(Command::new("install_name_tool")
        .args(["-id", &bundled_name("libonnxruntime.dylib")])
        .arg(frameworks.join("libonnxruntime.dylib")))?;
    std::fs::copy(root.join("crates/sq-onnx/vendor/ORT-LICENSE-MIT.txt"), resources.join("ORT-LICENSE-MIT.txt"))
        .map_err(|e| format!("ORT-LICENSE-MIT.txt: {e}"))?;

    // The EdgeTAM ONNX parts (not in the repo): SQ_SUBJECT_MASK_MODELS, else the export folder of scripts/win-onnx-setup.sh.
    let models = std::env::var_os("SQ_SUBJECT_MASK_MODELS")
        .map(PathBuf::from)
        .unwrap_or_else(|| root.join("Tools/SubjectMaskSpike/work/models-onnx"));
    let names = ["encoder", "decoder", "decoder_box", "mem_encoder", "mem_attention"];
    if names.iter().all(|n| models.join(format!("edgetam_{n}.onnx")).exists()) {
        let dest = resources.join("SubjectMask");
        std::fs::create_dir_all(&dest).map_err(|e| e.to_string())?;
        for n in names {
            let f = format!("edgetam_{n}.onnx");
            std::fs::copy(models.join(&f), dest.join(&f)).map_err(|e| format!("{f}: {e}"))?;
        }
    } else {
        println!(
            "== models: no EdgeTAM ONNX parts in {} (set SQ_SUBJECT_MASK_MODELS); Magic Mask will report them missing",
            models.display()
        );
    }

    let mut extra = Vec::new();
    if let Some(f) = std::env::var_os("SQ_FFMPEG") {
        extra.push(PathBuf::from(f).join("lib"));
    }
    println!("== bundling libraries");
    let mut libs = bundle_libs(&exe, &frameworks, &extra)?;
    if let Ok(rd) = std::fs::read_dir(&frameworks) {
        for e in rd.flatten() {
            if !libs.contains(&e.path()) {
                libs.push(e.path());
            }
        }
    }
    libs.sort_by_key(|p| std::cmp::Reverse(p.as_os_str().len()));
    println!("   {} libraries in Contents/Frameworks", libs.len());
    // A signed or DMG release must carry an LGPL FFmpeg; a developer build only warns.
    if let Err(why) = check_lgpl(&frameworks) {
        if opts.sign || opts.dmg {
            return Err(why);
        }
        println!("== warning: {why}");
    }

    crate::stage::check(&app, &["common", "macos"])?;

    println!("== signing ({})", if opts.sign { id.as_str() } else { "ad-hoc" });
    let ent = pk.join(if opts.sign { "Release.entitlements" } else { "AdHoc.entitlements" });
    sign_all(&app, &libs, &id, &ent)?;
    let mut all = libs.clone();
    all.push(exe);
    check_portable(&all)?;

    if !opts.no_smoke {
        smoke(&app, &fonts, &out)?;
    }
    if opts.notarize {
        println!("== notarizing");
        notarize(&app, &out)?;
    }
    if opts.dmg {
        make_dmg(&root, &app, &out, opts.sign.then_some(id.as_str()), opts.notarize, channel, &date)?;
    }
    println!("package ok: {}", app.display());
    Ok(())
}

#[cfg(unix)]
fn make_dmg(
    root: &Path,
    app: &Path,
    out: &Path,
    sign_id: Option<&str>,
    notarize: bool,
    channel: Channel,
    date: &str,
) -> Result<(), String> {
    // Every DMG gets its own name (version + local date and time), so a stale copy in Downloads is never mistaken for it.
    let stamp = run(Command::new("date").arg("+%Y%m%d-%H%M"))?.trim().to_string();
    let dmg =
        out.join(format!("{} {} {stamp}.dmg", channel.display_name(), channel.version(&workspace_version(root), date)));
    let stage = out.join("dmg");
    let _ = std::fs::remove_dir_all(&stage);
    std::fs::create_dir_all(&stage).map_err(|e| e.to_string())?;
    copy_dir(app, &stage.join(format!("{}.app", channel.display_name())))?;
    std::os::unix::fs::symlink("/Applications", stage.join("Applications")).map_err(|e| e.to_string())?;
    run(Command::new(root.join("scripts/make-dmg.sh")).arg(&stage).arg(&dmg).arg(channel.display_name()))?;
    let _ = std::fs::remove_dir_all(stage);
    // The DMG is a file of its own: Gatekeeper checks its signature and staple, not only the app inside.
    let profile = std::env::var("SQ_NOTARY_PROFILE").unwrap_or_else(|_| "sq-notary".into());
    for step in dmg_finish_steps(&dmg, sign_id, notarize.then_some(profile.as_str())) {
        let (program, args) = step.split_first().ok_or("empty step")?;
        let log = run(Command::new(program).args(args))?;
        if args.contains(&"submit".to_string()) && !log.contains("status: Accepted") {
            return Err(format!("notarization of the DMG was not accepted:\n{log}"));
        }
    }
    println!("dmg: {}", dmg.display());
    Ok(())
}

#[cfg(unix)]
/// The commands that follow `make-dmg.sh`: sign the DMG with the Developer ID (`sign_id`), then notarize it and staple the
/// ticket to it (`notary_profile`). Nothing for an ad-hoc build.
fn dmg_finish_steps(dmg: &Path, sign_id: Option<&str>, notary_profile: Option<&str>) -> Vec<Vec<String>> {
    let file = dmg.to_string_lossy().into_owned();
    let mut steps = Vec::new();
    if let Some(id) = sign_id {
        steps.push(["codesign", "--force", "--sign", id, "--timestamp", &file].map(String::from).to_vec());
        if let Some(profile) = notary_profile {
            let mut submit = ["xcrun", "notarytool", "submit", &file].map(String::from).to_vec();
            submit.extend(notary_auth(profile));
            submit.push("--wait".into());
            steps.push(submit);
            steps.push(["xcrun", "stapler", "staple", &file].map(String::from).to_vec());
        }
    }
    steps
}

#[cfg(not(unix))]
fn make_dmg(
    _root: &Path,
    _app: &Path,
    _out: &Path,
    _sign_id: Option<&str>,
    _notarize: bool,
    _channel: Channel,
    _date: &str,
) -> Result<(), String> {
    Err("--dmg needs macOS".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn options() {
        assert_eq!(parse(&["--dmg".into()]).map(|o| o.dmg), Ok(true));
        assert!(parse(&["--notarize".into()]).is_err());
        assert!(parse(&["--x".into()]).is_err());
    }

    #[cfg(unix)]
    #[test]
    fn the_dmg_is_signed_then_notarized_and_stapled() {
        let dmg = Path::new("/o/Sequence Studio 0.1.2 20261113-0537.dmg");
        let file = dmg.to_string_lossy().into_owned();
        assert!(dmg_finish_steps(dmg, None, None).is_empty(), "an ad-hoc build leaves the DMG alone");
        let signed = dmg_finish_steps(dmg, Some("Developer ID Application: X (T)"), None);
        assert_eq!(signed.len(), 1);
        assert_eq!(signed[0][..5], ["codesign", "--force", "--sign", "Developer ID Application: X (T)", "--timestamp"]);
        assert_eq!(signed[0][5], file);
        let notarized = dmg_finish_steps(dmg, Some("id"), Some("sq-notary"));
        assert_eq!(notarized.len(), 3);
        assert_eq!(notarized[0][0], "codesign", "the signature comes before the submission");
        assert_eq!(notarized[1][..3], ["xcrun", "notarytool", "submit"]);
        assert!(notarized[1].contains(&file) && notarized[1].contains(&"--wait".to_string()));
        assert_eq!(notarized[2], ["xcrun", "stapler", "staple", file.as_str()]);
    }

    #[test]
    fn otool_output() {
        let t = "/x/bin:\n\t/opt/homebrew/lib/libavcodec.62.dylib (compatibility version 62.0.0)\n\t/usr/lib/libSystem.B.dylib (x)\n";
        assert_eq!(linked(t), ["/opt/homebrew/lib/libavcodec.62.dylib", "/usr/lib/libSystem.B.dylib"]);
        assert!(is_system("/usr/lib/libSystem.B.dylib"));
        assert!(!is_system("/opt/homebrew/lib/libavcodec.62.dylib"));
        assert_eq!(bundled_name("liba.dylib"), "@executable_path/../Frameworks/liba.dylib");
    }

    #[test]
    fn a_gpl_ffmpeg_is_refused_and_an_lgpl_one_passes() {
        let dir = std::env::temp_dir().join(format!("sq-lgpl-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap_or_default();
        let lib = dir.join("libavcodec.62.dylib");
        std::fs::write(&lib, b"junk --enable-version3 --disable-debug junk").unwrap_or_default();
        assert_eq!(check_lgpl(&dir), Ok(()));
        std::fs::write(&lib, b"junk --enable-gpl --enable-libx264 junk").unwrap_or_default();
        assert!(check_lgpl(&dir).is_err_and(|e| e.contains("--enable-gpl")));
        std::fs::remove_dir_all(&dir).unwrap_or_default();
    }
}
