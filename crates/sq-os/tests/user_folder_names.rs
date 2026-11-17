//! No crate joins the movies folder's name onto the home folder by hand: `~/Movies` (Mac) and `~/Videos` (Windows, Linux)
//! differ, so only `Platform::movies_dir` / `movies_folder_name` name them. A hand-written `.join("Videos")` once made the
//! Mac's Export sheet offer a folder that does not exist there.

use std::path::{Path, PathBuf};

/// Every non-test source file under `crates/*/src`.
fn sources(dir: &Path, out: &mut Vec<PathBuf>) -> std::io::Result<()> {
    for entry in std::fs::read_dir(dir)? {
        let path = entry?.path();
        let name = path.file_name().and_then(|n| n.to_str()).unwrap_or_default().to_string();
        if path.is_dir() {
            if name != "tests" && name != "target" {
                sources(&path, out)?;
            }
        } else if name.ends_with(".rs")
            && name != "tests.rs"
            && !name.ends_with("_tests.rs")
            && !name.starts_with("tests_")
        {
            out.push(path);
        }
    }
    Ok(())
}

#[test]
fn no_crate_hardcodes_the_movies_folder_name() -> std::io::Result<()> {
    let crates = Path::new(env!("CARGO_MANIFEST_DIR")).join("..");
    let mut files = Vec::new();
    for krate in std::fs::read_dir(&crates)? {
        let src = krate?.path().join("src");
        if src.is_dir() {
            sources(&src, &mut files)?;
        }
    }
    assert!(files.len() > 100, "the scan found only {} files", files.len());
    let needles = ["Movies", "Videos"].map(|name| format!("join(\"{name}\")"));
    let mut hits = Vec::new();
    for file in files {
        let text = std::fs::read_to_string(&file)?;
        for (n, line) in text.lines().enumerate() {
            if needles.iter().any(|needle| line.contains(needle.as_str())) {
                hits.push(format!("{}:{}", file.display(), n + 1));
            }
        }
    }
    assert!(hits.is_empty(), "use Platform::movies_dir instead of a literal folder name: {hits:?}");
    Ok(())
}
