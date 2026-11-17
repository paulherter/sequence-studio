//! Linux AppImage: the app menu entry and `.sqproj` association. The files and the AppImage move are done by
//! `sq_platform::desktop_integration`; this maps its state to the Settings > General row and the first-run offer, and runs
//! the requests of the Settings row.

use sq_draw_shell::{AppMenuOutcome, AppMenuRequest, AppMenuRow};
use sq_platform::desktop_integration::{self as di, DesktopEnv, DesktopState, SetupFailure};
use sq_setup_engine::{ErrorCode, Job, SetupError};
use std::sync::atomic::{AtomicBool, Ordering};

/// The Settings row for a state: an integrated entry shows its file and offers Remove; the rest offer Add.
pub fn row_for(env: Option<&DesktopEnv>, state: &DesktopState) -> AppMenuRow {
    let Some(env) = env else { return AppMenuRow::Hidden };
    match state {
        DesktopState::Unavailable => AppMenuRow::Hidden,
        DesktopState::Installed | DesktopState::Outdated { .. } | DesktopState::Stale => {
            let file = di::integrated_file(env).unwrap_or_else(|| env.appimage.clone());
            AppMenuRow::Added { file: env.tilde(&file) }
        }
        DesktopState::Offer | DesktopState::Declined => AppMenuRow::NotAdded,
    }
}

/// The row at app start.
pub fn startup_row(env: Option<&DesktopEnv>) -> AppMenuRow {
    // shortcut: SQ_SHOT_APP_MENU=added|not-added fakes the row for `--ui-shot` outside an AppImage; remove with the shots.
    match std::env::var("SQ_SHOT_APP_MENU").ok().as_deref() {
        Some("added") => return AppMenuRow::Added { file: "~/Applications/SequenceStudio.AppImage".into() },
        Some("not-added") => return AppMenuRow::NotAdded,
        _ => {}
    }
    row_for(env, &startup_state(env))
}

static OFFERS_ALLOWED: AtomicBool = AtomicBool::new(true);

/// The headless runs (shots, exports) never ask: a shot must show the app, not the question.
pub fn allow_offers(allowed: bool) {
    OFFERS_ALLOWED.store(allowed, Ordering::Relaxed);
}

/// Whether this run may ask by itself (a window run, not a shot or an export).
pub fn offers_allowed() -> bool {
    OFFERS_ALLOWED.load(Ordering::Relaxed)
}

/// Only a never-answered AppImage start in a window asks by itself.
pub fn offer_due(state: &DesktopState) -> bool {
    offer_due_with(state, OFFERS_ALLOWED.load(Ordering::Relaxed))
}

fn offer_due_with(state: &DesktopState, allowed: bool) -> bool {
    allowed && *state == DesktopState::Offer
}

/// The state at app start. An entry whose file is gone, or that is older than the version key, is pointed at the running
/// AppImage without a question (the user said yes before).
pub fn startup_state(env: Option<&DesktopEnv>) -> DesktopState {
    let state = di::state(env);
    match (&state, env) {
        (DesktopState::Stale, Some(env)) if di::refresh(env).is_ok() => DesktopState::Installed,
        _ => state,
    }
}

/// Runs a request of the Settings row on the user's apps folder.
// shortcut: Add runs on the UI thread, so a copy across file systems blocks the window; upgrade with a background job and
// the progress callback of `di::add` when Add from Settings gets used on slow disks.
pub fn run(env: Option<&DesktopEnv>, request: AppMenuRequest) -> Result<AppMenuOutcome, SetupFailure> {
    let env = env.ok_or_else(|| SetupFailure {
        code: 399,
        step: "starting".into(),
        path: None,
        system: "Sequence Studio is not running from an AppImage.".into(),
    })?;
    match request {
        AppMenuRequest::Add => match di::add(env, &di::default_apps_dir(env), &mut |_, _| true)? {
            di::AddEnd::Done { integrated } => Ok(AppMenuOutcome::Added { file: env.tilde(&integrated) }),
            di::AddEnd::Canceled => Ok(AppMenuOutcome::Added { file: env.tilde(&env.appimage) }),
        },
        AppMenuRequest::Remove { trash_file } => {
            di::remove(env, trash_file)?;
            Ok(AppMenuOutcome::Removed { trashed: trash_file })
        }
    }
}

/// What the result card shows for a finished request: the outcome, or the sentence of the failure's `SQI-3xx` code.
pub fn card_for(request: AppMenuRequest, result: Result<AppMenuOutcome, SetupFailure>) -> AppMenuOutcome {
    let adding = request == AppMenuRequest::Add;
    result.unwrap_or_else(|f| {
        let code = ErrorCode::from_number(f.code).unwrap_or(ErrorCode::LinuxOther);
        let mut error = SetupError::new(code, &f.step, f.system);
        if let Some(path) = &f.path {
            error = error.with_path(path);
        }
        let job = if adding { Job::LinuxAdd } else { Job::LinuxRemove };
        AppMenuOutcome::Failed { adding, sentence: format!("{} ({})", error.sentence(&job), code.text()) }
    })
}

/// The command line: applies a request and reports the new state (`--desktop-entry add|remove`).
pub fn apply(env: Option<&DesktopEnv>, request: AppMenuRequest) -> Result<DesktopState, String> {
    run(env, request).map_err(|f| f.to_string())?;
    Ok(di::state(env))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn rig(name: &str) -> (PathBuf, DesktopEnv) {
        let root = std::env::temp_dir().join(format!("sq-hosts-desktop-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let share = root.join("mnt/usr/share");
        for (p, bytes) in [
            ("applications/sequence-studio.desktop", "[Desktop Entry]\nExec=sequence-studio %F\n"),
            ("mime/packages/de.paulherter.sequencestudio.xml", "<mime-info/>"),
            ("icons/hicolor/256x256/apps/sequence-studio.png", "png"),
        ] {
            std::fs::create_dir_all(share.join(p).parent().expect("dir")).expect("mkdir");
            std::fs::write(share.join(p), bytes).expect("write");
        }
        std::fs::create_dir_all(root.join("home/Downloads")).expect("mkdir");
        std::fs::write(root.join("home/Downloads/A-1.AppImage"), "bytes").expect("appimage");
        let env = DesktopEnv {
            appimage: root.join("home/Downloads/A-1.AppImage"),
            appdir: root.join("mnt"),
            data_home: root.join("home/.local/share"),
            home: root.join("home"),
            version: "0.2.0".into(),
        };
        (root, env)
    }

    #[test]
    fn the_settings_row_and_the_first_run_offer_follow_the_state() {
        let (root, env) = rig("rows");
        let row = |s: DesktopState| row_for(Some(&env), &s);
        assert_eq!(row_for(None, &DesktopState::Offer), AppMenuRow::Hidden);
        assert_eq!(row(DesktopState::Unavailable), AppMenuRow::Hidden);
        assert_eq!(row(DesktopState::Offer), AppMenuRow::NotAdded);
        assert_eq!(row(DesktopState::Declined), AppMenuRow::NotAdded);
        let added = AppMenuRow::Added { file: "~/Downloads/A-1.AppImage".into() };
        for s in [DesktopState::Installed, DesktopState::Stale, DesktopState::Outdated { installed: "0.1.0".into() }] {
            assert_eq!(row(s), added);
        }
        assert!(offer_due_with(&DesktopState::Offer, true));
        assert!(!offer_due_with(&DesktopState::Offer, false), "headless runs never ask");
        for s in [DesktopState::Unavailable, DesktopState::Declined, DesktopState::Installed] {
            assert!(!offer_due_with(&s, true), "{s:?} does not ask by itself");
        }
        assert!(
            !offer_due_with(&DesktopState::Outdated { installed: "0.1.0".into() }, true),
            "an update is its own question"
        );
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn requests_move_between_the_states_and_a_stale_entry_is_refreshed_at_start() {
        let (root, mut env) = rig("answers");
        let done = |r| card_for(AppMenuRequest::Add, r);
        assert_eq!(
            done(run(Some(&env), AppMenuRequest::Add)),
            AppMenuOutcome::Added { file: "~/Applications/SequenceStudio.AppImage".into() }
        );
        assert_eq!(di::state(Some(&env)), DesktopState::Installed);
        assert_eq!(
            row_for(Some(&env), &DesktopState::Installed),
            AppMenuRow::Added { file: "~/Applications/SequenceStudio.AppImage".into() }
        );
        // The integrated file goes away: stale, then refreshed at start, pointing at the running file.
        std::fs::remove_file(root.join("home/Applications/SequenceStudio.AppImage")).expect("remove");
        std::fs::write(root.join("home/Downloads/B.AppImage"), "x").expect("b");
        env.appimage = root.join("home/Downloads/B.AppImage");
        assert_eq!(startup_state(Some(&env)), DesktopState::Installed);
        assert_eq!(
            card_for(
                AppMenuRequest::Remove { trash_file: false },
                run(Some(&env), AppMenuRequest::Remove { trash_file: false })
            ),
            AppMenuOutcome::Removed { trashed: false }
        );
        assert_eq!(di::state(Some(&env)), DesktopState::Offer);
        assert_eq!(apply(Some(&env), AppMenuRequest::Add), Ok(DesktopState::Installed));
        assert!(apply(None, AppMenuRequest::Add).is_err());
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn a_failure_shows_the_sentence_of_its_code_and_the_state() {
        let failure =
            SetupFailure { code: 301, step: "writing the menu entry".into(), path: None, system: "denied".into() };
        match card_for(AppMenuRequest::Add, Err(failure.clone())) {
            AppMenuOutcome::Failed { adding: true, sentence } => {
                assert_eq!(
                    sentence,
                    "Your user folder didn't allow adding the menu entry. Nothing was added. (SQI-301)"
                );
            }
            other => panic!("{other:?}"),
        }
        match card_for(AppMenuRequest::Remove { trash_file: true }, Err(failure)) {
            AppMenuOutcome::Failed { adding: false, sentence } => {
                assert!(sentence.ends_with("Nothing was removed. (SQI-301)"), "{sentence}")
            }
            other => panic!("{other:?}"),
        }
    }
}
