//! Every way a project reaches the window runs the Open flow's after-open work: a project folder that was moved and
//! renamed shows its clips online whether it came as the launch argument, a double click or a drop on the start window.

use crate::first_picture_tests::{first_frames, project_around, start_app};
use sq_app_shell::Headless;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

fn scratch(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("sq-open-path-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("scratch folder");
    dir
}

/// A saved project whose one clip lives in its own `Files/` folder, then the project folder moved to another place under
/// another name: the project file's media path now points at nothing, but the clip sits at the same place inside the folder.
fn moved_and_renamed_project(dir: &Path) -> PathBuf {
    let original = dir.join("Film");
    let clip = original.join("Files").join("c1.mp4");
    std::fs::create_dir_all(clip.parent().expect("parent")).expect("Files folder");
    // One byte: the project records the clip's size as 1 (`project_around`), and the relink matches by size.
    std::fs::write(&clip, b"x").expect("clip");
    let saved = project_around(&original, &clip).expect("the project is saved");
    let moved = dir.join("elsewhere").join("Renamed Film");
    std::fs::create_dir_all(moved.parent().expect("parent")).expect("target folder");
    std::fs::rename(&original, &moved).expect("move and rename the project folder");
    moved.join(saved.file_name().expect("file name"))
}

fn missing(app: &Headless) -> Option<usize> {
    app.with(|a| a.session().missing_media().len())
}

fn wait_until(app: &Headless, what: &str, done: impl Fn(&Headless) -> bool) {
    // A generous deadline: the whole suite shares the machine, and the relink scan runs on the shared worker pool.
    let deadline = Instant::now() + Duration::from_secs(20);
    while Instant::now() < deadline {
        app.turn();
        if done(app) {
            return;
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    panic!("{what}");
}

#[test]
fn a_moved_and_renamed_project_from_the_command_line_finds_its_clip() {
    let dir = scratch("launch");
    let file = moved_and_renamed_project(&dir);
    // The guard: opened by the session alone the clip is offline, so the test cannot pass without the relink.
    let (plain, _) = crate::session_for(Some(&file), &dir.join("plain-support"), crate::playback::WakeSlot::default());
    assert_eq!(plain.missing_media().len(), 1, "the clip is offline before the relink");
    let (app, _picture, _wakes) = start_app(Some(&file), &dir.join("support"));
    wait_until(&app, "the clip stayed offline after a launch-argument open", |a| missing(a) == Some(0));
    let recents = std::fs::read_to_string(dir.join("support").join("recents.json")).unwrap_or_default();
    assert!(recents.contains("Renamed Film"), "the project joined Recent: {recents}");
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_project_dropped_on_the_start_window_opens_and_finds_its_clip() {
    let dir = scratch("drop");
    let file = moved_and_renamed_project(&dir);
    let (app, _picture, _wakes) = start_app(None, &dir.join("support"));
    first_frames(&app);
    assert_eq!(app.with(|a| a.session().file_url().is_none()), Some(true), "the start window shows an empty project");
    app.with(|a| a.drop_files(vec![file.clone()]));
    wait_until(&app, "the dropped project did not open", |a| {
        a.with(|a| a.session().file_url().map(Path::to_path_buf)).flatten().as_deref() == Some(file.as_path())
    });
    wait_until(&app, "the clip stayed offline after a drop", |a| missing(a) == Some(0));
    let _ = std::fs::remove_dir_all(&dir);
}
