// SPDX-License-Identifier: GPL-3.0-or-later
//! The ONNX Runtime library the package carries (MIT, docs/THIRD_PARTY.md): a pinned release, downloaded once into a cache
//! folder under the user's home (no install into the system, no brew/pip/npm) and checked against a pinned sha256.

use std::path::{Path, PathBuf};
use std::process::Command;

/// The pinned release.
pub const VERSION: &str = "1.24.4";
/// macOS arm64 archive of that release (Microsoft's GitHub release).
pub const MAC_URL: &str =
    "https://github.com/microsoft/onnxruntime/releases/download/v1.24.4/onnxruntime-osx-arm64-1.24.4.tgz";
/// Its sha256.
pub const MAC_SHA256: &str = "93787795f47e1eee369182e43ed51b9e5da0878ab0346aecf4258979b8bba989";

/// Linux x86_64 archive of that release.
pub const LINUX_URL: &str =
    "https://github.com/microsoft/onnxruntime/releases/download/v1.24.4/onnxruntime-linux-x64-1.24.4.tgz";
/// Its sha256.
pub const LINUX_SHA256: &str = "3a211fbea252c1e66290658f1b735b772056149f28321e71c308942cdb54b747";

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

/// The macOS arm64 `libonnxruntime.dylib` of the pinned release: from the cache, downloaded and verified the first time.
pub fn fetch_macos() -> Result<PathBuf, String> {
    let dir = cache_dir()?;
    let dylib = dir.join(format!("onnxruntime-osx-arm64-{VERSION}/lib/libonnxruntime.{VERSION}.dylib"));
    if dylib.exists() {
        return Ok(dylib);
    }
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let archive = dir.join("onnxruntime-osx-arm64.tgz");
    println!("== onnx: downloading ONNX Runtime {VERSION} (MIT) to {}", dir.display());
    crate::package::run(Command::new("curl").args(["-fsSL", "-o"]).arg(&archive).arg(MAC_URL))?;
    let got = sha256(&archive)?;
    if got != MAC_SHA256 {
        let _ = std::fs::remove_file(&archive);
        return Err(format!("ONNX Runtime archive sha256 {got} is not the pinned {MAC_SHA256}"));
    }
    crate::package::run(Command::new("tar").arg("xzf").arg(&archive).arg("-C").arg(&dir))?;
    if dylib.exists() { Ok(dylib) } else { Err(format!("{} missing after unpacking", dylib.display())) }
}

/// The Linux x86_64 `libonnxruntime.so` of the pinned release: from the cache, downloaded and verified the first time.
pub fn fetch_linux() -> Result<PathBuf, String> {
    let dir = cache_dir()?;
    let lib = dir.join(format!("onnxruntime-linux-x64-{VERSION}/lib/libonnxruntime.so.{VERSION}"));
    if lib.exists() {
        return Ok(lib);
    }
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let archive = dir.join("onnxruntime-linux-x64.tgz");
    println!("== onnx: downloading ONNX Runtime {VERSION} (MIT) to {}", dir.display());
    crate::package::run(Command::new("curl").args(["-fsSL", "-o"]).arg(&archive).arg(LINUX_URL))?;
    let got = sha256(&archive)?;
    if got != LINUX_SHA256 {
        let _ = std::fs::remove_file(&archive);
        return Err(format!("ONNX Runtime archive sha256 {got} is not the pinned {LINUX_SHA256}"));
    }
    crate::package::run(Command::new("tar").arg("xzf").arg(&archive).arg("-C").arg(&dir))?;
    if lib.exists() { Ok(lib) } else { Err(format!("{} missing after unpacking", lib.display())) }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_pin_is_a_sha256_and_names_its_version() {
        assert_eq!(MAC_SHA256.len(), 64);
        assert!(MAC_SHA256.chars().all(|c| c.is_ascii_hexdigit()));
        assert!(MAC_URL.contains(VERSION));
        assert_eq!(LINUX_SHA256.len(), 64);
        assert!(LINUX_URL.contains(VERSION));
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
