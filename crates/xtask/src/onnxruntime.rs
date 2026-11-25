// SPDX-License-Identifier: GPL-3.0-or-later
//! The ONNX Runtime library the package carries (MIT, docs/THIRD_PARTY.md): a pinned release, downloaded once into a cache
//! folder under the user's home (no install into the system, no brew/pip/npm) and checked against a pinned sha256.

use std::path::{Path, PathBuf};
use std::process::Command;

/// The pinned release.
pub const VERSION: &str = "1.24.4";
/// The official `Microsoft.ML.OnnxRuntime` NuGet package of that release (Microsoft's GitHub release downloads are gone).
/// It carries the same CPU builds under `runtimes/<rid>/native/`.
pub const NUPKG_URL: &str =
    "https://api.nuget.org/v3-flatcontainer/microsoft.ml.onnxruntime/1.24.4/microsoft.ml.onnxruntime.1.24.4.nupkg";
/// Its sha256.
pub const NUPKG_SHA256: &str = "4b978d5065b85e7004b6c6f60ca494bd978fbe6836cbf0a0b52d82b61ab99638";

/// One native library inside the package: its path in the zip, its file name in the cache and its sha256.
pub struct Lib {
    pub entry: &'static str,
    pub name: &'static str,
    pub sha256: &'static str,
    pub required: bool,
}

/// macOS arm64.
pub const MAC_LIBS: &[Lib] = &[Lib {
    entry: "runtimes/osx-arm64/native/libonnxruntime.dylib",
    name: "libonnxruntime.dylib",
    sha256: "0db33e160224e480c17932799d1dfaea59853b8e722b57bf61932c87e03586f0",
    required: true,
}];

/// Linux x86_64.
pub const LINUX_LIBS: &[Lib] = &[
    Lib {
        entry: "runtimes/linux-x64/native/libonnxruntime.so",
        name: "libonnxruntime.so",
        sha256: "d132535d051344ff5c64c9c200004150559049a81ed330eb4422c1962fb6b7e4",
        required: true,
    },
    Lib {
        entry: "runtimes/linux-x64/native/libonnxruntime_providers_shared.so",
        name: "libonnxruntime_providers_shared.so",
        sha256: "086ec1d5388f64153d9c63470d126693db9a182c8ce236d3a1119068471b8a0d",
        required: false,
    },
];

/// `shasum -a 256` of a file (`sha256sum` where `shasum` is missing).
pub fn sha256(file: &Path) -> Result<String, String> {
    let out = Command::new("shasum")
        .args(["-a", "256"])
        .arg(file)
        .output()
        .or_else(|_| Command::new("sha256sum").arg(file).output())
        .map_err(|e| format!("shasum: {e}"))?;
    let text = String::from_utf8_lossy(&out.stdout).into_owned();
    text.split_whitespace().next().map(str::to_string).ok_or_else(|| format!("shasum failed for {}", file.display()))
}

/// The cache folder of this version: `SQ_BUILD_CACHE`, `~/Library/Caches/SequenceStudio` (macOS) or `~/.cache/SequenceStudio`, then `onnxruntime/<version>`.
fn cache_dir() -> Result<PathBuf, String> {
    let base = match std::env::var_os("SQ_BUILD_CACHE") {
        Some(b) => PathBuf::from(b),
        None => PathBuf::from(std::env::var_os("HOME").ok_or("HOME is not set")?).join(if cfg!(target_os = "macos") {
            "Library/Caches/SequenceStudio"
        } else {
            ".cache/SequenceStudio"
        }),
    };
    Ok(base.join("onnxruntime").join(VERSION))
}

/// True when every library of `libs` is in `dir` with its pinned sha256 (a stub or a half download does not count).
fn cached(dir: &Path, libs: &[Lib]) -> bool {
    libs.iter().all(|l| !l.required || sha256(&dir.join(l.name)).is_ok_and(|h| h == l.sha256))
}

/// The libraries of `libs` from the cache folder `<cache>/<rid>`, downloaded (nupkg, sha256-checked) and unpacked the first time.
/// Every unpacked file is checked against its own pin too. Returns the folder.
fn fetch(rid: &str, libs: &[Lib]) -> Result<PathBuf, String> {
    let dir = cache_dir()?.join(rid);
    if cached(&dir, libs) {
        return Ok(dir);
    }
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let archive = dir.join("onnxruntime.nupkg");
    println!("== onnx: downloading ONNX Runtime {VERSION} (MIT, NuGet package) to {}", dir.display());
    crate::package::run(Command::new("curl").args(["-fsSL", "-o"]).arg(&archive).arg(NUPKG_URL))?;
    let got = sha256(&archive)?;
    if got != NUPKG_SHA256 {
        let _ = std::fs::remove_file(&archive);
        return Err(format!("ONNX Runtime package sha256 {got} is not the pinned {NUPKG_SHA256}"));
    }
    for l in libs {
        let _ = std::fs::remove_file(dir.join(l.name));
        let out =
            Command::new("unzip").arg("-p").arg(&archive).arg(l.entry).output().map_err(|e| format!("unzip: {e}"))?;
        if !out.status.success() || out.stdout.is_empty() {
            if l.required {
                return Err(format!("{} missing in the ONNX Runtime package", l.entry));
            }
            continue;
        }
        std::fs::write(dir.join(l.name), &out.stdout).map_err(|e| e.to_string())?;
        let h = sha256(&dir.join(l.name))?;
        if h != l.sha256 {
            let _ = std::fs::remove_file(dir.join(l.name));
            return Err(format!("{} sha256 {h} is not the pinned {}", l.entry, l.sha256));
        }
    }
    let _ = std::fs::remove_file(&archive);
    Ok(dir)
}

/// The macOS arm64 `libonnxruntime.dylib` of the pinned release (cached, verified).
pub fn fetch_macos() -> Result<PathBuf, String> {
    Ok(fetch("osx-arm64", MAC_LIBS)?.join("libonnxruntime.dylib"))
}

/// The Linux x86_64 `libonnxruntime.so` of the pinned release (cached, verified); `libonnxruntime_providers_shared.so` sits beside it.
pub fn fetch_linux() -> Result<PathBuf, String> {
    Ok(fetch("linux-x64", LINUX_LIBS)?.join("libonnxruntime.so"))
}

/// `cargo xtask fetch-onnxruntime <mac|linux>`: fetch only (what the package steps do first), print the library path.
pub fn run_fetch(args: &[String]) -> Result<(), String> {
    let p = match args.first().map(String::as_str) {
        Some("mac") => fetch_macos()?,
        Some("linux") => fetch_linux()?,
        _ => return Err("usage: cargo xtask fetch-onnxruntime <mac|linux>".into()),
    };
    println!("onnx: {} sha256 {}", p.display(), sha256(&p)?);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_pins_are_sha256_and_name_their_version() {
        assert!(NUPKG_URL.contains(VERSION));
        for h in std::iter::once(NUPKG_SHA256).chain(MAC_LIBS.iter().chain(LINUX_LIBS).map(|l| l.sha256)) {
            assert_eq!(h.len(), 64);
            assert!(h.chars().all(|c| c.is_ascii_hexdigit()));
        }
    }

    #[test]
    fn a_stub_in_the_cache_is_not_a_cache_hit() {
        let d = std::env::temp_dir().join(format!("sq-xtask-ort-{}", std::process::id()));
        std::fs::create_dir_all(&d).expect("mkdir");
        std::fs::write(d.join("libonnxruntime.so"), "stub").expect("write");
        let hit = cached(&d, &LINUX_LIBS[..1]);
        let _ = std::fs::remove_dir_all(&d);
        assert!(!hit);
    }

    #[test]
    fn sha256_of_a_known_file() {
        let f = std::env::temp_dir().join("sq-xtask-sha-test.txt");
        std::fs::write(&f, "abc").expect("write");
        let r = sha256(&f);
        let _ = std::fs::remove_file(&f);
        if let Ok(h) = r {
            assert_eq!(h, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
        }
    }
}
