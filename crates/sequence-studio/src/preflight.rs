//! What must hold before the first window opens, checked one step at a time so a failure has a name instead of a dead
//! process: the settings folder is writable, the video libraries load, the fonts exist, the settings file parses.
//! A step that cannot be worked around is fatal (the error window, then the app ends); a damaged settings file is put
//! aside and the start goes on with the defaults (a notice the user sees once).

use crate::fault_inject::{self, Fault};
use crate::start_failure::{StartCode, StartFailure};
use std::fs;
use std::path::Path;

/// The outcome of [`run`].
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Preflight {
    /// The first step that cannot be worked around.
    pub fatal: Option<StartFailure>,
    /// Problems that were worked around; the user is told once the window is up.
    pub notices: Vec<StartFailure>,
}

/// The video libraries this exe delay-links on Windows (`build.rs` lists them); empty elsewhere, where the system loader
/// already refused to start the process if one was missing.
fn delay_loaded_libraries() -> Vec<&'static str> {
    option_env!("SQ_FFMPEG_DLLS").unwrap_or("").split(',').filter(|n| !n.is_empty()).collect()
}

/// Runs every step in order. `support` is the settings folder, `fonts` the folder with the bundled Inter.
pub fn run(support: &Path, fonts: &Path) -> Preflight {
    let mut out = Preflight::default();
    let steps: [&dyn Fn() -> Result<(), StartFailure>; 3] =
        [&|| check_support(support), &check_ffmpeg, &|| check_fonts(fonts)];
    for step in steps {
        if let Err(failure) = step() {
            out.fatal = Some(failure);
            return out;
        }
    }
    out.notices.extend(check_settings(support));
    out
}

/// The settings folder can be made and written (a probe file that is removed again).
pub fn check_support(support: &Path) -> Result<(), StartFailure> {
    let step = "writing the settings folder";
    if fault_inject::active(Fault::Support) {
        return Err(fault_inject::failure(Fault::Support).with_path(support));
    }
    fs::create_dir_all(support).map_err(|e| StartFailure::from_io(StartCode::SupportFolder, step, support, &e))?;
    let probe = support.join(format!(".write-test-{}", std::process::id()));
    fs::write(&probe, b"sq").map_err(|e| StartFailure::from_io(StartCode::SupportFolder, step, &probe, &e))?;
    let _ = fs::remove_file(&probe);
    Ok(())
}

/// The video libraries are there (Windows: loaded now, because the exe delay-links them) and the loaded ones are the
/// ones this build was made against.
pub fn check_ffmpeg() -> Result<(), StartFailure> {
    let step = "loading the video libraries";
    if fault_inject::active(Fault::Ffmpeg) {
        return Err(fault_inject::failure(Fault::Ffmpeg));
    }
    if let Some((name, why)) = first_missing_library(&delay_loaded_libraries()) {
        return Err(StartFailure::new(StartCode::FfmpegMissing, step, format!("{name}: {why}")));
    }
    sq_media_ffmpeg::shim::version_mismatch().map_or(Ok(()), |why| {
        Err(StartFailure::new(StartCode::FfmpegVersion, "checking the video library versions", why))
    })
}

/// The first of `names` that does not load, with the system's words.
#[cfg(windows)]
fn first_missing_library(names: &[&str]) -> Option<(String, String)> {
    sq_platform_win::first_missing_library(names).map(|(name, error)| (name, crate::start_failure::describe_io(&error)))
}

#[cfg(not(windows))]
fn first_missing_library(_names: &[&str]) -> Option<(String, String)> {
    None
}

/// The bundled Inter exists: without it the window would open with no text at all.
pub fn check_fonts(fonts: &Path) -> Result<(), StartFailure> {
    if fault_inject::active(Fault::Fonts) {
        return Err(fault_inject::failure(Fault::Fonts).with_path(fonts));
    }
    if sq_draw::GlyphAtlas::inter(fonts).is_none() {
        let why = format!("Inter was not found in {}", fonts.display());
        return Err(StartFailure::new(StartCode::FontsMissing, "loading the fonts", why).with_path(fonts));
    }
    Ok(())
}

/// A settings file that does not parse is moved to `prefs.json.damaged-<unix seconds>` so the next save cannot overwrite
/// the evidence; the start then reads no file and uses the defaults. A missing file is a first start, not a problem.
pub fn check_settings(support: &Path) -> Option<StartFailure> {
    let file = support.join("prefs.json");
    if fault_inject::active(Fault::Settings) {
        return Some(fault_inject::failure(Fault::Settings).with_path(&file));
    }
    let bytes = fs::read(&file).ok()?;
    let why = match serde_json::from_slice::<serde_json::Value>(&bytes) {
        Ok(serde_json::Value::Object(_)) => return None,
        Ok(_) => "the file is not a settings object".to_string(),
        Err(e) => format!("the file does not parse: {e}"),
    };
    let secs = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_secs());
    let aside = support.join(format!("prefs.json.damaged-{secs}"));
    let moved = match fs::rename(&file, &aside) {
        Ok(()) => format!("moved to {}", aside.display()),
        Err(e) => format!("could not be moved aside ({})", crate::start_failure::describe_io(&e)),
    };
    Some(
        StartFailure::new(StartCode::SettingsDamaged, "reading the settings", format!("{why}; {moved}"))
            .with_path(&file),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp(name: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("sq-preflight-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        dir
    }

    #[test]
    fn a_writable_support_folder_passes_and_leaves_no_probe() {
        let dir = temp("ok");
        assert_eq!(check_support(&dir), Ok(()));
        assert_eq!(fs::read_dir(&dir).map(Iterator::count).unwrap_or(1), 0);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_support_path_under_a_file_cannot_be_made_and_says_401() {
        let dir = temp("file");
        let _ = fs::create_dir_all(&dir);
        let blocker = dir.join("blocker");
        let _ = fs::write(&blocker, b"x");
        let failure = check_support(&blocker.join("Sequence Studio")).err();
        assert_eq!(failure.as_ref().map(|f| f.code), Some(StartCode::SupportFolder));
        assert!(failure.is_some_and(|f| f.system.starts_with("os error")));
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn missing_fonts_say_303_and_name_the_folder() {
        let dir = temp("fonts");
        let failure = check_fonts(&dir).err();
        assert_eq!(failure.as_ref().map(|f| f.code), Some(StartCode::FontsMissing));
        assert_eq!(failure.and_then(|f| f.path), Some(dir));
    }

    #[test]
    fn a_damaged_settings_file_is_put_aside_and_noticed_once() {
        let dir = temp("settings");
        let _ = fs::create_dir_all(&dir);
        let _ = fs::write(dir.join("prefs.json"), b"{ \"strings\": ");
        let notice = check_settings(&dir);
        assert_eq!(notice.as_ref().map(|f| f.code), Some(StartCode::SettingsDamaged));
        assert!(!dir.join("prefs.json").exists(), "the damaged file is out of the way");
        let kept = fs::read_dir(&dir).map(|d| {
            d.flatten().filter(|e| e.file_name().to_string_lossy().starts_with("prefs.json.damaged-")).count()
        });
        assert_eq!(kept.ok(), Some(1));
        assert!(notice.is_some_and(|f| f.system.contains("does not parse")));
        assert_eq!(check_settings(&dir), None, "the next start finds no file and no problem");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn good_and_missing_settings_are_no_problem() {
        let dir = temp("good");
        let _ = fs::create_dir_all(&dir);
        assert_eq!(check_settings(&dir), None);
        let _ = fs::write(dir.join("prefs.json"), b"{\"strings\":{}}");
        assert_eq!(check_settings(&dir), None);
        let _ = fs::write(dir.join("prefs.json"), b"[1,2]");
        assert_eq!(check_settings(&dir).map(|f| f.code), Some(StartCode::SettingsDamaged));
        let _ = fs::remove_dir_all(&dir);
    }
}
