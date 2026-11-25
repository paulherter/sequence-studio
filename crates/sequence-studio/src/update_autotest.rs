//! The updater's UI-free test hook: `SQ_UPDATE_AUTOTEST=update|later` runs Check, Download, Verify and Install at start with
//! no window and no input, through the same state machine (`UpdateFlow`), downloader, verifier and installer the buttons use,
//! then quits. `report` (what the relaunched app gets) logs one `started` line and quits. Each step logs one line
//! `sq-update-autotest: <step> <detail>` to stderr and to `SQ_UPDATE_AUTOTEST_LOG`. Unset = never runs. The pure parts
//! (mode, line format, relaunch env) are in `sq_platform::app_update::autotest`.

use std::path::{Path, PathBuf};

use sq_editor_session::{
    DownloadProgress, PendingUpdate, ReleaseChannel, UpdateCheck, UpdateEffect, UpdateEvent, UpdateFlow, UpdateOutcome,
    UpdateTrust,
};
use sq_platform::app_update::autotest::{AutotestMode, LOG_VAR, log};

/// Runs the hook when the environment asks for it; `None` = not asked, start the app as usual.
pub fn run_from_env() -> Option<Result<(), String>> {
    let mode = AutotestMode::from_env()?;
    let log_file = std::env::var_os(LOG_VAR).filter(|v| !v.is_empty()).map(PathBuf::from);
    let log_file = log_file.as_deref();
    let version = ReleaseChannel::local_version();
    let channel = ReleaseChannel::build().raw();
    if mode == AutotestMode::Report {
        let exe = std::env::current_exe().map(|p| p.display().to_string()).unwrap_or_default();
        log(log_file, "started", &format!("{version} {channel} {exe}"));
        return Some(Ok(()));
    }
    let result = drive(mode, log_file, &version, channel);
    match &result {
        Ok(()) => log(log_file, "quit", ""),
        Err(why) => log(log_file, "failed", why),
    }
    // Linux and Windows start the new version from the recorded relaunch once this process is done.
    if let Err(e) = sq_platform::app_update::start_pending_relaunch() {
        log(log_file, "relaunch-failed", &e.to_string());
    }
    Some(result)
}

fn drive(mode: AutotestMode, log_file: Option<&Path>, local: &str, channel: &str) -> Result<(), String> {
    let say = |step: &str, detail: &str| log(log_file, step, detail);
    say("start", &format!("mode={mode:?} version={local} channel={channel}"));
    let feed = std::env::var("SQ_UPDATE_URL")
        .ok()
        .filter(|v| !v.is_empty())
        .unwrap_or_else(|| ReleaseChannel::build().default_feed_url().to_string());
    say("check", &format!("feed={feed}"));
    let (flow, _) = UpdateFlow::Idle.step(UpdateEvent::Check);
    let outcome = if UpdateCheck::url_allowed(&feed) {
        match crate::files::http_get(&feed) {
            Some(data) => UpdateCheck::outcome(&data, local),
            None => UpdateOutcome::Failed,
        }
    } else {
        UpdateOutcome::NotConfigured
    };
    let (flow, _) = flow.step(UpdateEvent::Checked(outcome.clone()));
    let UpdateFlow::Available(release) = flow else {
        return Err(format!("no update to install: {outcome:?}"));
    };
    say("available", &release.version);

    let can_apply = sq_platform::app_update::supported() && UpdateTrust::key().is_some();
    say("download-start", &format!("can_apply={can_apply}"));
    let (flow, effect) = UpdateFlow::Available(release.clone()).step(UpdateEvent::Download { can_apply });
    let Some(UpdateEffect::StartDownload(install)) = effect else {
        return Err(format!("the update cannot be installed in place here (effect {effect:?}, flow {flow:?})"));
    };
    let cache = crate::paths::app_support_dir().join("caches").join("Updates");
    let staged = UpdateTrust::staged_path(&cache, &release.version, &install).ok_or("the file name is not valid")?;
    if let Some(dir) = staged.parent() {
        std::fs::create_dir_all(dir).map_err(|e| format!("cannot make {}: {e}", dir.display()))?;
    }
    let _ = std::fs::remove_file(&staged);
    let progress = DownloadProgress::new();
    progress.report(0, install.size.unwrap_or(0));
    let downloaded = crate::files::curl_download(&install.url, &staged, &progress);
    let event = match downloaded {
        Ok(()) => UpdateEvent::Downloaded(staged.clone()),
        Err(why) => UpdateEvent::DownloadFailed(why),
    };
    let (flow, effect) = flow.step(event);
    let Some(UpdateEffect::Verify { file, install }) = effect else {
        let _ = std::fs::remove_file(&staged);
        return Err(match flow {
            UpdateFlow::Failed(why) => why.message(),
            other => format!("the download did not lead to a check: {other:?}"),
        });
    };
    let bytes = std::fs::metadata(&file).map_or(0, |m| m.len());
    say("download-done", &format!("{} bytes={bytes}", file.display()));

    let key = UpdateTrust::key().ok_or("no update key is built in")?;
    let signature = crate::files::http_get(&install.sig_url);
    let verdict = match &signature {
        Some(sig) => UpdateTrust::verify_file(&file, &install, Some(sig), &key),
        None => Err(sq_editor_session::UpdateFailure::SignatureMissing),
    };
    let (flow, effect) = flow.step(UpdateEvent::Verified(verdict));
    if let Some(UpdateEffect::Discard(f)) = effect {
        let _ = std::fs::remove_file(f);
    }
    let UpdateFlow::ReadyToInstall { .. } = &flow else {
        return Err(match flow {
            UpdateFlow::Failed(why) => why.message(),
            other => format!("the check did not finish: {other:?}"),
        });
    };
    say("verified", &format!("sha256={} signature=ok", install.sha256));

    // The two buttons: "Restart to Update" (Install, nothing unsaved) or "Later" (installed when the app quits).
    let (event, restart) =
        if mode.restarts() { (UpdateEvent::Install { unsaved: false }, true) } else { (UpdateEvent::Later, false) };
    let (_, effect) = flow.step(event);
    if !matches!(effect, Some(UpdateEffect::Apply { .. } | UpdateEffect::ApplyOnQuit { .. })) {
        return Err(format!("the flow did not reach the install: {effect:?}"));
    }
    say("apply", &format!("restart={restart}"));
    let pending =
        PendingUpdate { file, version: release.version.clone(), install, signature: signature.unwrap_or_default() };
    sq_app_hosts::AppRoot::apply_verified_update(&pending, restart)?;
    say("applied", &format!("version={} restart={restart}", release.version));
    Ok(())
}
