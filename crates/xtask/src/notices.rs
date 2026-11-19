// SPDX-License-Identifier: GPL-3.0-or-later
//! `cargo xtask notices`: writes `packaging/licenses/THIRD-PARTY-NOTICES.txt`, the one file that carries name, version,
//! license, copyright and the full license text of every Rust crate in the `sequence-studio` binary plus the parts that
//! are not crates (FFmpeg, ONNX Runtime, EdgeTAM, icons, fonts, vendored C code). Crate texts are read from the crate
//! sources `cargo metadata` points at (the registry or git checkout), so run it where the dependencies are fetched.
//! Identical license texts are printed once and referenced by number. `LICENSE_FILES` is the list every package ships.

use crate::json::Json;
use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

/// The files of `Licenses/` in every package (macOS, Windows and Linux read this one list; the Windows installer script
/// names the same files in `packaging/windows/build-installer.ps1`).
pub const LICENSE_FILES: &[&str] = &[
    "packaging/licenses/FFMPEG-LICENSE.txt",
    "packaging/licenses/FFMPEG-NOTICE.txt",
    "packaging/licenses/APACHE-2.0.txt",
    "packaging/licenses/THIRD-PARTY-NOTICES.txt",
    "crates/sq-onnx/vendor/ORT-LICENSE-MIT.txt",
    "packaging/licenses/WHISPER-CPP-MIT.txt",
    "docs/THIRD_PARTY.md",
    "docs/THIRD_PARTY-CRATES.md",
];

pub const OUTPUT: &str = "packaging/licenses/THIRD-PARTY-NOTICES.txt";

/// One thing we ship: where it is from and its license texts.
#[derive(Debug, Clone, PartialEq)]
pub struct Entry {
    pub name: String,
    pub version: String,
    pub license: String,
    pub copyright: String,
    pub texts: Vec<String>,
}

/// A crate of the dependency graph as `cargo metadata` describes it.
#[derive(Debug, Clone, PartialEq)]
pub struct CrateInfo {
    pub name: String,
    pub version: String,
    pub license: String,
    pub authors: String,
    pub dir: PathBuf,
}

/// Normal (not dev, not build) dependencies of `sequence-studio` over all targets, workspace members left out.
pub fn crates_from_metadata(meta: &Json) -> Result<Vec<CrateInfo>, String> {
    let packages = meta.get("packages").and_then(Json::as_arr).ok_or("metadata has no packages")?;
    let nodes = meta.at(&["resolve", "nodes"]).and_then(Json::as_arr).ok_or("metadata has no resolve graph")?;
    let find = |id: &str| packages.iter().find(|p| p.get("id").and_then(Json::as_str) == Some(id));
    let root = packages
        .iter()
        .find(|p| p.get("name").and_then(Json::as_str) == Some("sequence-studio"))
        .and_then(|p| p.get("id").and_then(Json::as_str))
        .ok_or("no sequence-studio package")?;
    let mut seen = BTreeSet::new();
    let mut todo = vec![root.to_string()];
    while let Some(id) = todo.pop() {
        if !seen.insert(id.clone()) {
            continue;
        }
        let node = nodes.iter().find(|n| n.get("id").and_then(Json::as_str) == Some(&id));
        for d in node.and_then(|n| n.get("deps")).and_then(Json::as_arr).unwrap_or(&[]) {
            let normal = d
                .get("dep_kinds")
                .and_then(Json::as_arr)
                .is_some_and(|ks| ks.iter().any(|k| matches!(k.get("kind"), Some(Json::Null) | None)));
            if let (true, Some(pkg)) = (normal, d.get("pkg").and_then(Json::as_str)) {
                todo.push(pkg.to_string());
            }
        }
    }
    let mut out = Vec::new();
    for id in &seen {
        let Some(p) = find(id) else { continue };
        if matches!(p.get("source"), None | Some(Json::Null)) {
            continue; // a workspace member: our own code
        }
        let text = |k: &str| p.get(k).and_then(Json::as_str).unwrap_or("").to_string();
        let manifest = text("manifest_path");
        let authors = p
            .get("authors")
            .and_then(Json::as_arr)
            .map(|a| a.iter().filter_map(Json::as_str).collect::<Vec<_>>().join(", "))
            .unwrap_or_default();
        out.push(CrateInfo {
            name: text("name"),
            version: text("version"),
            license: text("license"),
            authors,
            dir: Path::new(&manifest).parent().map(Path::to_path_buf).unwrap_or_default(),
        });
    }
    out.sort_by(|a, b| (&a.name, &a.version).cmp(&(&b.name, &b.version)));
    Ok(out)
}

/// Whether a file name in a crate's top folder is a license or notice file.
pub fn is_license_file(name: &str) -> bool {
    let n = name.to_ascii_lowercase();
    ["license", "licence", "copying", "unlicense", "notice"].iter().any(|p| n.starts_with(p))
}

/// The license files in a folder (top level only), in name order.
fn read_license_files(dir: &Path) -> Vec<String> {
    let mut names: Vec<_> = std::fs::read_dir(dir)
        .into_iter()
        .flatten()
        .flatten()
        .filter(|e| e.path().is_file() && is_license_file(&e.file_name().to_string_lossy()))
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .collect();
    names.sort();
    names.iter().filter_map(|n| std::fs::read(dir.join(n)).ok()).map(|b| String::from_utf8_lossy(&b).into_owned()).collect()
}

const MIT_TEMPLATE: &str = "MIT License\n\nCopyright (c) @AUTHORS@\n\nPermission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the \"Software\"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:\n\nThe above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.\n\nTHE SOFTWARE IS PROVIDED \"AS IS\", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.\n";
const BSL_TEXT: &str = "Boost Software License - Version 1.0 - August 17th, 2003\n\nPermission is hereby granted, free of charge, to any person or organization obtaining a copy of the software and accompanying documentation covered by this license (the \"Software\") to use, reproduce, display, distribute, execute, and transmit the Software, and to prepare derivative works of the Software, and to permit third-parties to whom the Software is furnished to do so, all subject to the following:\n\nThe copyright notices in the Software and this entire statement, including the above license grant, this restriction and the following disclaimer, must be included in all copies of the Software, in whole or in part, and all derivative works of the Software, unless such copies or derivative works are solely in the form of machine-executable object code generated by a source language processor.\n\nTHE SOFTWARE IS PROVIDED \"AS IS\", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE, TITLE AND NON-INFRINGEMENT. IN NO EVENT SHALL THE COPYRIGHT HOLDERS OR ANYONE DISTRIBUTING THE SOFTWARE BE LIABLE FOR ANY DAMAGES OR OTHER LIABILITY, WHETHER IN CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.\n";
const GPL3_TEXT: &str = include_str!("../../../LICENSE");
/// Git dependencies whose Cargo.toml names no license; the LICENSE of the pinned revision is the GPL-3.0 (docs/THIRD_PARTY.md).
const GPL_GIT_CRATES: &[&str] = &["gyroflow-core", "stabilize_spirv"];
const APACHE_TEXT: &str = include_str!("../../../packaging/licenses/APACHE-2.0.txt");

/// The standard text of an SPDX license that offers MIT or Apache-2.0, for a crate whose source ships no license file
/// (the MIT text names the crate's authors). Apache-2.0 wins when both are offered: its text needs no copyright line.
pub fn fallback_text(license: &str, authors: &str) -> Option<String> {
    let has = |id: &str| license.replace('/', " ").split_whitespace().any(|w| w == id);
    if has("Apache-2.0") {
        Some(APACHE_TEXT.to_string())
    } else if has("MIT") {
        Some(MIT_TEMPLATE.replace("@AUTHORS@", if authors.is_empty() { "the authors" } else { authors }))
    } else if has("BSL-1.0") {
        Some(BSL_TEXT.to_string())
    } else {
        None
    }
}

/// Entries for the crates; the second value lists crates that have no license file (their SPDX id stands alone).
pub fn crate_entries(crates: &[CrateInfo]) -> (Vec<Entry>, Vec<String>) {
    let mut missing = Vec::new();
    let entries = crates
        .iter()
        .map(|c| {
            let mut texts = read_license_files(&c.dir);
            let mut license = c.license.clone();
            if license.is_empty() && GPL_GIT_CRATES.contains(&c.name.as_str()) {
                license = "GPL-3.0".into();
                texts.push(GPL3_TEXT.to_string());
            }
            if texts.is_empty() {
                texts.extend(fallback_text(&license, &c.authors));
                if texts.is_empty() {
                    missing.push(format!("{} {} ({})", c.name, c.version, c.license));
                }
            }
            Entry {
                name: c.name.clone(),
                version: c.version.clone(),
                license,
                copyright: c.authors.clone(),
                texts,
            }
        })
        .collect();
    (entries, missing)
}

fn read(root: &Path, rel: &str) -> Result<String, String> {
    std::fs::read(root.join(rel)).map(|b| String::from_utf8_lossy(&b).into_owned()).map_err(|e| format!("{rel}: {e}"))
}

/// What ships but is not a crate: FFmpeg, ONNX Runtime, EdgeTAM, Phosphor icons, vendored C code and every font family.
pub fn extra_entries(root: &Path) -> Result<Vec<Entry>, String> {
    let e = |name: &str, version: &str, license: &str, copyright: &str, files: &[&str]| -> Result<Entry, String> {
        let texts = files.iter().map(|f| read(root, f)).collect::<Result<Vec<_>, _>>()?;
        Ok(Entry { name: name.into(), version: version.into(), license: license.into(), copyright: copyright.into(), texts })
    };
    let mut out = vec![
        e("FFmpeg (shared libraries, replaceable)", "LGPL build", "LGPL-3.0-or-later", "the FFmpeg developers", &[
            "packaging/licenses/FFMPEG-LICENSE.txt",
        ])?,
        e("ONNX Runtime", "1.24.4", "MIT", "Microsoft Corporation", &["crates/sq-onnx/vendor/ORT-LICENSE-MIT.txt"])?,
        e("whisper.cpp (speech to text, loaded at run time)", "b5454", "MIT", "2023-2026 The ggml authors", &[
            "packaging/licenses/WHISPER-CPP-MIT.txt",
        ])?,
        e("EdgeTAM models (subject masks)", "", "Apache-2.0", "Meta Platforms, Inc. and affiliates", &[
            "packaging/licenses/APACHE-2.0.txt",
        ])?,
        e("Phosphor Icons", "2.1", "MIT", "2020 Phosphor Icons", &["packaging/licenses/PHOSPHOR-MIT.txt"])?,
        e("RNNoise (vendored C code)", "0.1.1", "BSD-3-Clause", "Mozilla, Jean-Marc Valin, Xiph.Org Foundation, Mark Borgerding", &[
            "crates/sq-audiofx/vendor/rnnoise/COPYING",
        ])?,
        e("LZFSE (vendored C code)", "", "BSD-3-Clause", "2015-2016 Apple Inc.", &["crates/sq-analysis/vendor/lzfse/LICENSE"])?,
    ];
    let fonts = root.join("Packages/SQText/Sources/SQText/Resources/Fonts");
    let mut ofl = vec![("Inter".to_string(), fonts.join("OFL.txt"))];
    let mut families: Vec<_> = std::fs::read_dir(fonts.join("Families")).map_err(|e| e.to_string())?.flatten().collect();
    families.sort_by_key(|f| f.file_name());
    for f in families {
        ofl.push((f.file_name().to_string_lossy().into_owned(), f.path().join("OFL.txt")));
    }
    for (family, path) in ofl {
        let text = std::fs::read(&path).map_err(|e| format!("{}: {e}", path.display()))?;
        let text = String::from_utf8_lossy(&text).into_owned();
        let copyright = text.lines().next().unwrap_or("").trim().to_string();
        out.push(Entry { name: format!("Font: {family}"), version: String::new(), license: "SIL OFL 1.1".into(), copyright, texts: vec![text] });
    }
    Ok(out)
}

fn normalized(text: &str) -> String {
    text.replace("\r\n", "\n").trim().to_string()
}

/// The notices file: a header, one block per entry and the distinct license texts, numbered.
pub fn render(entries: &[Entry]) -> String {
    let mut distinct: Vec<String> = Vec::new();
    let mut out = String::from(
        "THIRD-PARTY NOTICES\n\nSequence Studio is free software under the GNU General Public License 3.0 (see LICENSE). It includes the\n\
         software below. Each entry names the license; the full text is printed once under \"License texts\" and referenced by number.\n\
         Generated by `cargo xtask notices` from Cargo.lock and the sources of the dependencies. Do not edit by hand.\n\n",
    );
    for e in entries {
        out.push_str(&format!("== {}{}{}\n", e.name, if e.version.is_empty() { "" } else { " " }, e.version));
        out.push_str(&format!("License: {}\n", if e.license.is_empty() { "see the license text" } else { &e.license }));
        if !e.copyright.is_empty() {
            out.push_str(&format!("Copyright / authors: {}\n", e.copyright));
        }
        let mut ids = Vec::new();
        for t in e.texts.iter().map(|t| normalized(t)).filter(|t| !t.is_empty()) {
            let n = distinct.iter().position(|d| *d == t).unwrap_or_else(|| {
                distinct.push(t);
                distinct.len() - 1
            });
            ids.push(format!("[{}]", n + 1));
        }
        out.push_str(&if ids.is_empty() {
            "License text: none shipped with the source; the license named above applies.\n\n".to_string()
        } else {
            format!("License text: {}\n\n", ids.join(" "))
        });
    }
    out.push_str("\n== License texts\n");
    for (i, t) in distinct.iter().enumerate() {
        out.push_str(&format!("\n----- [{}] -----\n{}\n", i + 1, t));
    }
    out
}

pub fn run(args: &[String]) -> Result<(), String> {
    let root = std::env::current_dir().map_err(|e| e.to_string())?;
    let out = Command::new("cargo")
        .args(["metadata", "--format-version", "1", "--locked"])
        .current_dir(&root)
        .output()
        .map_err(|e| e.to_string())?;
    if !out.status.success() {
        return Err(String::from_utf8_lossy(&out.stderr).into_owned());
    }
    let meta = Json::parse(&String::from_utf8_lossy(&out.stdout))?;
    let (mut entries, missing) = crate_entries(&crates_from_metadata(&meta)?);
    entries.extend(extra_entries(&root)?);
    let text = render(&entries);
    let target = root.join(OUTPUT);
    if args.iter().any(|a| a == "--check") {
        let current = std::fs::read_to_string(&target).unwrap_or_default();
        return if current == text { Ok(()) } else { Err(format!("{OUTPUT} is stale: run `cargo xtask notices`")) };
    }
    std::fs::write(&target, &text).map_err(|e| e.to_string())?;
    println!("{} entries, {} bytes written to {OUTPUT}", entries.len(), text.len());
    for m in missing {
        println!("no license file: {m}");
    }
    Ok(())
}

use std::process::Command;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn license_file_names() {
        for n in ["LICENSE", "LICENSE-MIT", "license-apache", "COPYING", "UNLICENSE", "NOTICE.md", "LICENCE.txt"] {
            assert!(is_license_file(n), "{n}");
        }
        for n in ["Cargo.toml", "README.md", "src", "main.rs"] {
            assert!(!is_license_file(n), "{n}");
        }
    }

    fn entry(name: &str, texts: &[&str]) -> Entry {
        Entry { name: name.into(), version: "1.0".into(), license: "MIT".into(), copyright: "A".into(), texts: texts.iter().map(|t| t.to_string()).collect() }
    }

    #[test]
    fn identical_texts_print_once() {
        let out = render(&[entry("a", &["MIT text\r\n"]), entry("b", &["  MIT text"]), entry("c", &["Other"]), entry("d", &[])]);
        assert_eq!(out.matches("MIT text").count(), 1);
        assert!(out.contains("== a 1.0\nLicense: MIT\nCopyright / authors: A\nLicense text: [1]\n"));
        assert!(out.contains("== b 1.0\nLicense: MIT\nCopyright / authors: A\nLicense text: [1]\n"));
        assert!(out.contains("License text: [2]"));
        assert!(out.contains("== d 1.0") && out.contains("none shipped with the source"));
    }

    #[test]
    fn fallback_picks_apache_then_mit() {
        assert!(fallback_text("MIT OR Apache-2.0", "X").unwrap().contains("Apache License"));
        assert!(fallback_text("MIT/Apache-2.0", "X").unwrap().contains("Apache License"));
        let mit = fallback_text("MIT", "Jane <j@x>").unwrap();
        assert!(mit.contains("Copyright (c) Jane <j@x>") && mit.contains("Permission is hereby granted"));
        assert!(fallback_text("BSL-1.0", "X").unwrap().contains("Boost Software License"));
        assert_eq!(fallback_text("Zlib", "X"), None);
        assert_eq!(fallback_text("", "X"), None);
    }

    #[test]
    fn graph_keeps_normal_deps_only_and_skips_workspace() {
        let meta = Json::parse(
            r#"{"packages":[
              {"id":"r","name":"sequence-studio","version":"1","source":null,"license":"GPL-3.0","authors":[],"manifest_path":"/w/r/Cargo.toml"},
              {"id":"n","name":"norm","version":"2.0.0","source":"registry","license":"MIT","authors":["X","Y"],"manifest_path":"/reg/norm/Cargo.toml"},
              {"id":"b","name":"buildonly","version":"1","source":"registry","license":"MIT","authors":[],"manifest_path":"/reg/b/Cargo.toml"},
              {"id":"w","name":"member","version":"1","source":null,"license":"GPL-3.0","authors":[],"manifest_path":"/w/m/Cargo.toml"}],
             "resolve":{"nodes":[
              {"id":"r","deps":[{"pkg":"n","dep_kinds":[{"kind":null,"target":null}]},{"pkg":"b","dep_kinds":[{"kind":"build","target":null}]},{"pkg":"w","dep_kinds":[{"kind":null}]}]},
              {"id":"n","deps":[]},{"id":"b","deps":[]},{"id":"w","deps":[]}]}}"#,
        )
        .unwrap();
        let c = crates_from_metadata(&meta).unwrap();
        assert_eq!(c.len(), 1);
        assert_eq!((c[0].name.as_str(), c[0].authors.as_str(), c[0].dir.as_path()), ("norm", "X, Y", Path::new("/reg/norm")));
    }
}
