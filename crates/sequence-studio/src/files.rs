//! Native file dialogs behind the app's chooser traits.
//! Dialogs block the UI thread while open (answers are `Rc`-based asks that cannot leave it) and have no parent window;
//! the system dialog is modal anyway, so only the redraw behind it pauses.

use rfd::{AsyncFileDialog, FileDialog};
use sq_app_shell::{LUTFileTypes, PanelFileChooser, ShellFilePicker};
use sq_os::Platform;
use sq_runtime::{ModalAsk, modal};
use std::future::Future;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

/// The `rfd` choosers of both systems.
pub struct DesktopFiles;

/// File > Open also takes a Premiere project (`MacShellFilePicker.chooseProject`).
const OPEN_EXTENSIONS: [&str; 3] = ["sqproj", "ssproj", "prproj"];
/// What the Open Project dialog picks on a system.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum OpenPicker {
    /// A file. `with_project_json` also lists `project.json`, the file inside a package folder (`package_of` maps it back to
    /// the package): on a system whose file dialog cannot pick the package folder itself.
    File { with_project_json: bool },
    /// A folder: the `.sqproj` package is a folder there and a file dialog only opens it (Linux; Windows saves projects as
    /// files, so a file dialog picks them). A Premiere project is a file: it opens through File > Import.
    Folder,
}

fn open_picker(platform: Platform) -> OpenPicker {
    match platform {
        Platform::Mac => OpenPicker::File { with_project_json: !platform.dialog_picks_packages() },
        Platform::Windows => OpenPicker::File { with_project_json: true },
        Platform::Linux => OpenPicker::Folder,
    }
}

/// Import Shortcuts (`MacShellFilePicker.chooseShortcutFile`).
const SHORTCUT_EXTENSIONS: [&str; 5] = ["sqkeys", "kys", "commandset", "txt", "preset"];
/// Import Subtitles (`SubtitleReader.fileExtensions`).
const SUBTITLE_EXTENSIONS: [&str; 4] = ["srt", "vtt", "ass", "ssa"];

/// An HTTPS GET with the system `curl` (Windows 10+ and macOS ship it; the app has no HTTP library, as the model download).
/// `None` on any failure; the answer is capped at 1 MB (a release feed is a few KB).
fn http_get(url: &str) -> Option<Vec<u8>> {
    let mut cmd = std::process::Command::new("curl");
    cmd.args([
        "-fsSL",
        "--max-time",
        "15",
        "--max-filesize",
        "1000000",
        "-H",
        "Accept: application/vnd.github+json",
        url,
    ])
    .stdin(std::process::Stdio::null())
    .stderr(std::process::Stdio::null());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
    }
    let out = cmd.output().ok()?;
    out.status.success().then_some(out.stdout)
}

/// Runs a dialog future as a task and hands back its answer as an ask. The dialog opens without blocking the event loop
/// (a blocking modal inside a winit callback never showed up on the Mac); the task's waker wakes the loop on the answer.
fn ask_from<T: 'static>(dialog: impl Future<Output = T> + 'static) -> ModalAsk<T> {
    let (ask, answer) = modal();
    sq_runtime::spawn_local(async move {
        answer.answer(dialog.await);
    });
    ask
}

/// The folder a folder chooser opened last in this session (its parent), where the next one starts.
static LAST_FOLDER: Mutex<Option<PathBuf>> = Mutex::new(None);

fn remember_folder_of(picked: &Path) {
    if let (Some(parent), Ok(mut last)) = (picked.parent(), LAST_FOLDER.lock()) {
        *last = Some(parent.to_path_buf());
    }
}

/// The first of `last` and `home` that is a folder: where a folder chooser starts on Linux.
fn start_folder(last: Option<&Path>, home: Option<&Path>) -> Option<PathBuf> {
    [last, home].into_iter().flatten().find(|d| d.is_dir()).map(Path::to_path_buf)
}

/// A folder chooser. On Linux it always gets a start folder: the GTK chooser of the desktop portal starts in its virtual
/// "Recent" view when it is given none, and there "Select" stays greyed whatever path is typed, because a folder can only
/// be picked inside a real folder (Open Project, Locate, Add Folder; measured with xdg-desktop-portal-gtk 1.15.3,
/// 2026-11-16). KDE's chooser has no such view and takes the folder as its start too. The Mac and Windows choosers
/// start where the user was last, so they are left alone.
fn folder_chooser(title: &str) -> AsyncFileDialog {
    let d = AsyncFileDialog::new().set_title(title);
    if Platform::current() != Platform::Linux {
        return d;
    }
    let last = LAST_FOLDER.lock().ok().and_then(|l| l.clone());
    let home = Platform::Linux.home_dir(|k| std::env::var_os(k));
    match start_folder(last.as_deref(), home.as_deref()) {
        Some(dir) => d.set_directory(dir),
        None => d,
    }
}

/// `Name.sqproj/project.json` stands for the package folder `Name.sqproj`; any other path stays as picked.
fn package_of(picked: &Path) -> PathBuf {
    let in_package = picked.file_name().is_some_and(|n| n == "project.json");
    match picked.parent() {
        Some(dir) if in_package && dir.extension().is_some_and(|e| e == "sqproj") => dir.to_path_buf(),
        _ => picked.to_path_buf(),
    }
}

/// The project a dialog answer stands for: `Name.sqproj/project.json` and any folder inside a package open the package; a
/// folder holding `project.json` opens itself; anything else stays as picked (the open error then names it).
fn opened_project(picked: &Path) -> PathBuf {
    let picked = package_of(picked);
    sq_core_edit::project_open_routing::project_folder(&picked, |dir| dir.join("project.json").is_file())
        .unwrap_or(picked)
}

fn save(name: &str, title: &str, extension: Option<&str>) -> Option<PathBuf> {
    let mut d = FileDialog::new().set_title(title).set_file_name(name);
    if let Some(e) = extension {
        d = d.add_filter(e, &[e]);
    }
    d.save_file()
}

fn save_async(name: &str, title: &str, extension: Option<&str>) -> ModalAsk<Option<PathBuf>> {
    let mut d = AsyncFileDialog::new().set_title(title).set_file_name(name);
    if let Some(e) = extension {
        d = d.add_filter(e, &[e]);
    }
    ask_from(async move { d.save_file().await.map(|h| h.path().to_path_buf()) })
}

impl ShellFilePicker for DesktopFiles {
    fn choose_project(&mut self) -> ModalAsk<Option<PathBuf>> {
        match open_picker(Platform::current()) {
            OpenPicker::Folder => {
                let d = folder_chooser("Open Project");
                ask_from(async move {
                    let project = opened_project(d.pick_folder().await?.path());
                    remember_folder_of(&project);
                    Some(project)
                })
            }
            OpenPicker::File { with_project_json } => {
                let d = AsyncFileDialog::new().set_title("Open Project");
                let d = d.add_filter("Project", &OPEN_EXTENSIONS);
                let d = if with_project_json { d.add_filter("Project file", &["json"]) } else { d };
                ask_from(async move { d.pick_file().await.map(|h| opened_project(h.path())) })
            }
        }
    }
    fn choose_save_location(&mut self, suggested_name: &str, prompt: &str) -> ModalAsk<Option<PathBuf>> {
        save_async(suggested_name, prompt, Some("sqproj"))
    }
    fn choose_media(&mut self) -> ModalAsk<Vec<PathBuf>> {
        // The Mac chooser takes every file ("Import", no type filter); `import_mixed` reports what it cannot route.
        let d = AsyncFileDialog::new().set_title("Import");
        ask_from(async move {
            d.pick_files().await.unwrap_or_default().into_iter().map(|h| h.path().to_path_buf()).collect()
        })
    }
    fn choose_shortcut_file(&mut self) -> ModalAsk<Option<PathBuf>> {
        let d = AsyncFileDialog::new().set_title("Import Shortcuts").add_filter("Shortcuts", &SHORTCUT_EXTENSIONS);
        ask_from(async move { d.pick_file().await.map(|h| h.path().to_path_buf()) })
    }
    fn choose_shortcut_export_location(&mut self, suggested_name: &str) -> ModalAsk<Option<PathBuf>> {
        save_async(suggested_name, "Export Shortcuts", Some("sqkeys"))
    }
    fn choose_style_kit(&mut self, save_kit: bool, suggested_name: &str) -> ModalAsk<Option<PathBuf>> {
        if save_kit {
            return save_async(suggested_name, "Export Style Kit", Some("sqstyle"));
        }
        let d = AsyncFileDialog::new().set_title("Import Style Kit").add_filter("sqstyle", &["sqstyle"]);
        ask_from(async move { d.pick_file().await.map(|h| h.path().to_path_buf()) })
    }
    fn choose_folder(&mut self, prompt: &str) -> ModalAsk<Option<PathBuf>> {
        let d = folder_chooser(prompt);
        ask_from(async move {
            let folder = d.pick_folder().await?.path().to_path_buf();
            remember_folder_of(&folder);
            Some(folder)
        })
    }
    fn choose_file(&mut self, prompt: &str, directory: Option<&Path>) -> ModalAsk<Option<PathBuf>> {
        let mut d = AsyncFileDialog::new().set_title(prompt);
        if let Some(dir) = directory {
            d = d.set_directory(sq_os::paths::for_os(dir));
        }
        ask_from(async move { d.pick_file().await.map(|h| h.path().to_path_buf()) })
    }
    fn fetch(&mut self, url: &str) -> ModalAsk<Option<Vec<u8>>> {
        let (tx, rx) = std::sync::mpsc::channel();
        let url = url.to_string();
        std::thread::spawn(move || {
            let _ = tx.send(http_get(&url));
        });
        ask_from(async move {
            loop {
                match rx.try_recv() {
                    Ok(body) => return body,
                    Err(std::sync::mpsc::TryRecvError::Empty) => {
                        if sq_runtime::sleep(std::time::Duration::from_millis(100)).await.is_err() {
                            return None;
                        }
                    }
                    Err(_) => return None,
                }
            }
        })
    }
    fn choose_export_location(
        &mut self,
        suggested_name: &str,
        file_extension: &str,
        prompt: &str,
    ) -> ModalAsk<Option<PathBuf>> {
        save_async(suggested_name, prompt, Some(file_extension))
    }
}

impl PanelFileChooser for DesktopFiles {
    fn choose_subtitles(&mut self) -> Option<PathBuf> {
        FileDialog::new().set_title("Import Subtitles").add_filter("Subtitles", &SUBTITLE_EXTENSIONS).pick_file()
    }
    fn choose_srt_location(&mut self, suggested_name: &str) -> Option<PathBuf> {
        save(suggested_name, "Export SRT", Some("srt"))
    }
    fn choose_frame_location(&mut self, suggested_name: &str, formats: &[(&str, &str)]) -> Option<PathBuf> {
        let mut d = FileDialog::new().set_title("Export Frame").set_file_name(suggested_name);
        for (label, extension) in formats {
            d = d.add_filter(*label, &[*extension]);
        }
        d.save_file()
    }
    fn choose_csv_location(&mut self, suggested_name: &str) -> Option<PathBuf> {
        save(suggested_name, "Export Markers as CSV", Some("csv"))
    }
    fn choose_luts(&mut self, multiple: bool) -> Vec<PathBuf> {
        let title = if multiple { "Add LUTs to Library" } else { "Choose a LUT" };
        let d = FileDialog::new().set_title(title).add_filter("LUT", &LUTFileTypes::EXTENSIONS);
        if multiple { d.pick_files().unwrap_or_default() } else { d.pick_file().into_iter().collect() }
    }
}

/// Routes the drawn text fields' copy and paste to the system clipboard.
pub fn connect_clipboard(ui: &mut sq_draw::UiCx) {
    ui.clipboard.read_system = Some(Box::new(|| arboard::Clipboard::new().ok()?.get_text().ok()));
    ui.clipboard.write_system = Some(Box::new(|text| {
        // A failed write leaves the field's own copy in place (`TextClipboard::local`).
        if let Ok(mut c) = arboard::Clipboard::new() {
            let _ = c.set_text(text);
        }
    }));
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_runtime::testing::Rt;
    use std::cell::RefCell;
    use std::rc::Rc;

    #[test]
    fn open_project_picks_the_package_folder_on_linux_and_a_file_elsewhere() {
        assert_eq!(open_picker(Platform::Mac), OpenPicker::File { with_project_json: false });
        assert_eq!(open_picker(Platform::Windows), OpenPicker::File { with_project_json: true });
        assert_eq!(open_picker(Platform::Linux), OpenPicker::Folder);
    }

    #[test]
    fn a_picked_package_folder_or_project_json_opens_the_package() {
        let dir = std::env::temp_dir().join(format!("sq-open-{}", std::process::id()));
        let package = dir.join("Oppo.sqproj");
        std::fs::create_dir_all(package.join("media")).expect("package");
        std::fs::write(package.join("project.json"), "{}").expect("json");
        assert_eq!(opened_project(&package), package, "the folder itself");
        assert_eq!(opened_project(&package.join("project.json")), package, "the file inside");
        assert_eq!(opened_project(&package.join("media")), package, "navigated into the package");
        let plain = dir.join("Other");
        std::fs::create_dir_all(&plain).expect("plain");
        assert_eq!(opened_project(&plain), plain, "no project: stays as picked");
        let renamed = dir.join("Renamed");
        std::fs::create_dir_all(&renamed).expect("renamed");
        std::fs::write(renamed.join("project.json"), "{}").expect("json");
        assert_eq!(opened_project(&renamed), renamed, "a folder with project.json opens itself");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_linux_folder_chooser_starts_in_a_real_folder() {
        let dir = std::env::temp_dir().join(format!("sq-start-{}", std::process::id()));
        let (last, home) = (dir.join("last"), dir.join("home"));
        std::fs::create_dir_all(&last).expect("last");
        std::fs::create_dir_all(&home).expect("home");
        let gone = dir.join("gone");
        assert_eq!(start_folder(Some(&last), Some(&home)), Some(last.clone()), "the last folder first");
        assert_eq!(start_folder(Some(&gone), Some(&home)), Some(home.clone()), "a folder that is gone is skipped");
        assert_eq!(start_folder(None, Some(&home)), Some(home.clone()), "home when nothing was picked yet");
        assert_eq!(start_folder(Some(&gone), None), None, "no folder at all leaves the portal's own start");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_next_folder_chooser_starts_beside_the_last_pick() {
        remember_folder_of(Path::new("/projects/Oppo.sqproj"));
        assert_eq!(LAST_FOLDER.lock().ok().and_then(|l| l.clone()), Some(PathBuf::from("/projects")));
        if let Ok(mut last) = LAST_FOLDER.lock() {
            *last = None;
        }
    }

    #[test]
    fn open_project_accepts_current_and_legacy_files() {
        assert_eq!(OPEN_EXTENSIONS, ["sqproj", "ssproj", "prproj"]);
    }

    #[test]
    fn project_json_inside_a_package_opens_the_package() {
        assert_eq!(package_of(Path::new("/a/Oppo.sqproj/project.json")), PathBuf::from("/a/Oppo.sqproj"));
        assert_eq!(package_of(Path::new("/a/other/project.json")), PathBuf::from("/a/other/project.json"));
        assert_eq!(package_of(Path::new("/a/Oppo.sqproj")), PathBuf::from("/a/Oppo.sqproj"));
    }

    #[test]
    fn choosers_match_the_mac_filters() {
        assert!(OPEN_EXTENSIONS.contains(&"prproj"));
        assert_eq!(SHORTCUT_EXTENSIONS, ["sqkeys", "kys", "commandset", "txt", "preset"]);
        assert_eq!(SUBTITLE_EXTENSIONS, ["srt", "vtt", "ass", "ssa"]);
    }

    #[test]
    fn filter_lists_are_bare_lowercase_extensions() {
        // File > Import has no filter (it takes every file, like the Mac chooser), so only these lists remain.
        for e in OPEN_EXTENSIONS.iter().chain(&SHORTCUT_EXTENSIONS).chain(&SUBTITLE_EXTENSIONS) {
            assert!(!e.is_empty() && !e.starts_with('.') && !e.starts_with('*'), "{e} is not a bare extension");
            assert_eq!(*e, e.to_lowercase(), "{e} is not lowercase");
        }
    }

    #[test]
    fn a_canceled_dialog_reaches_the_flow_as_none() {
        let rt = Rt::manual();
        let (gate, close) = modal::<Option<PathBuf>>();
        let ask = ask_from(gate);
        let got = Rc::new(RefCell::new(None));
        let g = Rc::clone(&got);
        sq_runtime::spawn_local(async move {
            *g.borrow_mut() = Some(ask.await);
        });
        rt.run_until_stalled();
        close.answer(None);
        rt.run_until_stalled();
        rt.run_until_stalled();
        assert_eq!(*got.borrow(), Some(None));
    }

    #[test]
    fn a_dialog_answer_reaches_the_waiting_flow() {
        let rt = Rt::manual();
        let (gate, open) = modal::<PathBuf>();
        let ask = ask_from(gate);
        let got = Rc::new(RefCell::new(None));
        let g = Rc::clone(&got);
        sq_runtime::spawn_local(async move {
            *g.borrow_mut() = Some(ask.await);
        });
        rt.run_until_stalled();
        assert!(got.borrow().is_none());
        open.answer(PathBuf::from("/a.sqproj"));
        rt.run_until_stalled();
        rt.run_until_stalled();
        assert_eq!(*got.borrow(), Some(PathBuf::from("/a.sqproj")));
    }
}
