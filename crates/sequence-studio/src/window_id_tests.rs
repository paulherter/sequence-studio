//! Every window the app opens carries the app id (`sq_platform::app_window::with_app_id`): a toplevel without one shows a
//! generic icon and groups apart from the main window on a Linux desktop. Found by reading the sources, so a window added
//! later in any module of the app fails here until it goes through the same call.

use std::path::Path;

fn sources(dir: &Path, found: &mut Vec<(String, Vec<String>)>) {
    let entries = std::fs::read_dir(dir).expect("source folder");
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            sources(&path, found);
        } else if path.extension().is_some_and(|e| e == "rs") {
            let text = std::fs::read_to_string(&path).expect("source file");
            found.push((path.display().to_string(), text.lines().map(str::to_string).collect()));
        }
    }
}

#[test]
fn every_window_the_app_opens_gets_the_app_id() {
    let mut files = Vec::new();
    sources(&Path::new(env!("CARGO_MANIFEST_DIR")).join("src"), &mut files);
    let mut opened = 0;
    for (file, lines) in files.iter().filter(|(f, _)| !f.ends_with("window_id_tests.rs")) {
        for (at, line) in lines.iter().enumerate().filter(|(_, l)| l.contains(".create_window(")) {
            opened += 1;
            let before = &lines[at.saturating_sub(40)..at];
            assert!(
                before.iter().any(|l| l.contains("app_window::with_app_id(")),
                "{file}:{} opens a window without `sq_platform::app_window::with_app_id`: {line}",
                at + 1
            );
        }
    }
    assert!(opened >= 2, "the main window and the floating panels were found ({opened})");
}
