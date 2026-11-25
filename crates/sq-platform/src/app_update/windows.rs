//! The Windows install path of the updater: the downloaded setup program runs quietly over the install it came from.
//! The decisions are pure and tested with a fake host; only the spawn at the end is Windows-only.

use std::ffi::OsString;
use std::path::{Path, PathBuf};

use sq_setup_engine::detect::{InstallSource, detect_installed};
use sq_setup_engine::plan::EXE_NAME;
use sq_setup_engine::{Host, Identity, Version};

#[cfg(windows)]
use super::set_relaunch;
use super::{ApplyError, Relaunch};

/// The install folder when `running` is the app of an install made by our setup program; `None` for a loose exe, a
/// build folder or an install made by another installer.
pub fn install_dir(host: &dyn Host, identity: Identity, running: &Path) -> Option<PathBuf> {
    let installed = detect_installed(host, identity)?;
    // Windows paths compare without case and with either separator.
    let key = |p: &Path| p.to_string_lossy().replace('\\', "/").to_ascii_lowercase();
    let same = |a: &Path, b: &Path| key(a) == key(b);
    (installed.source == InstallSource::Ours && same(&installed.location.join(EXE_NAME), running))
        .then_some(installed.location)
}

/// Whether the setup carries the channel of the running app (a Nightly version has the `nightly` prerelease).
pub fn channel_matches(staged: &Version, running_is_nightly: bool) -> bool {
    staged.pre.as_deref().is_some_and(|pre| pre.split('.').next() == Some("nightly")) == running_is_nightly
}

/// Whether the install put a desktop shortcut that is still there.
pub fn has_desktop_shortcut(host: &dyn Host, identity: Identity) -> bool {
    host.folders().desktop.join(format!("{}.lnk", identity.app_name())).is_file()
}

/// The arguments of the quiet update: the same folder, the shortcut only if it exists, the end of this process awaited,
/// the app started again on request.
pub fn setup_args(dir: &Path, desktop: bool, pid: u32, restart: bool) -> Vec<OsString> {
    let mut out: Vec<OsString> = vec!["--quiet".into(), "--dir".into(), dir.into()];
    if desktop {
        out.push("--desktop".into());
    }
    // `--cleanup`: the downloaded setup file deletes itself once it has done its job.
    out.extend(["--wait-pid".into(), pid.to_string().into(), "--cleanup".into()]);
    if restart {
        out.push("--launch".into());
    }
    out
}

/// Whether an update can be installed here: the running app sits in an install of our setup program.
pub fn supported(host: &dyn Host, identity: Identity) -> bool {
    std::env::current_exe().ok().and_then(|exe| install_dir(host, identity, &exe)).is_some()
}

/// Checks the install and the channel and returns the arguments for `staged`; the caller starts it after the app quits.
pub fn prepare(
    host: &dyn Host,
    identity: Identity,
    running: &Path,
    staged_version: &Version,
    pid: u32,
    restart: bool,
) -> Result<Vec<OsString>, ApplyError> {
    let dir = install_dir(host, identity, running).ok_or(ApplyError::Unsupported)?;
    if !channel_matches(staged_version, identity.is_nightly()) {
        return Err(ApplyError::Failed("this update belongs to another release channel".into()));
    }
    Ok(setup_args(&dir, has_desktop_shortcut(host, identity), pid, restart))
}

/// What starts after the app has quit: the setup program with its arguments. Restart is the installer's `--launch`, so
/// the app is started exactly once, by the installer, and never by this program.
pub fn relaunch(staged: &Path, args: Vec<OsString>) -> Relaunch {
    Relaunch { program: staged.to_path_buf(), args }
}

/// The whole step on the real system: records the setup program at `staged` as the relaunch. It starts once the app has
/// quit and let go of the instance claim, then replaces the files after this process has ended. Nothing starts here.
#[cfg(windows)]
pub fn apply(staged: &Path, restart: bool) -> Result<(), ApplyError> {
    use sq_setup_engine::{WindowsHost, payload};
    let failed = |why: String| ApplyError::Failed(why);
    let running = std::env::current_exe().map_err(|e| failed(e.to_string()))?;
    let payload = payload::open(staged)
        .map_err(|e| failed(e.to_string()))?
        .ok_or_else(|| failed("the downloaded file is not a setup program".into()))?;
    let args = prepare(&WindowsHost, Identity::build(), &running, &payload.version, std::process::id(), restart)?;
    set_relaunch(relaunch(staged, args));
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_setup_engine::FakeHost;
    use sq_setup_engine::Identity;
    use sq_setup_engine::plan::{INNO_UNINSTALL_KEY, UNINSTALL_KEY};

    fn host_with(key: &str, location: &str) -> FakeHost {
        let host = FakeHost::new(Path::new("fake-root"));
        for (name, value) in [("DisplayVersion", "0.2.0"), ("InstallLocation", location)] {
            let _ = host.reg_set_string(key, Some(name), value);
        }
        host
    }

    #[test]
    fn the_app_of_our_install_is_found_whatever_the_case() {
        let host = host_with(UNINSTALL_KEY, r"C:\Users\a\Apps\Sequence Studio");
        let exe = Path::new(r"c:\users\a\apps\Sequence Studio\SequenceStudio.exe");
        let found = install_dir(&host, Identity::STABLE, exe);
        assert_eq!(found, Some(PathBuf::from(r"C:\Users\a\Apps\Sequence Studio")));
    }

    #[test]
    fn a_loose_exe_or_a_foreign_install_is_not_updated_in_place() {
        let host = host_with(UNINSTALL_KEY, r"C:\Apps\SQ");
        assert_eq!(install_dir(&host, Identity::STABLE, Path::new(r"D:\build\SequenceStudio.exe")), None);
        let inno = host_with(INNO_UNINSTALL_KEY, r"C:\Apps\SQ");
        assert_eq!(install_dir(&inno, Identity::STABLE, Path::new(r"C:\Apps\SQ\SequenceStudio.exe")), None);
        let none = FakeHost::new(Path::new("fake-root"));
        assert_eq!(install_dir(&none, Identity::STABLE, Path::new(r"C:\Apps\SQ\SequenceStudio.exe")), None);
    }

    #[test]
    fn the_channel_of_the_setup_must_be_the_channel_of_the_app() {
        let stable = Version::parse("0.2.1").unwrap_or_else(|| Version::new(0, 2, 1));
        let beta = Version::parse("0.3.0-beta.1").unwrap_or_else(|| Version::new(0, 3, 0));
        let nightly = Version::parse("0.2.1-nightly.20261120").unwrap_or_else(|| Version::new(0, 2, 1));
        assert!(channel_matches(&stable, false) && !channel_matches(&stable, true));
        assert!(channel_matches(&nightly, true) && !channel_matches(&nightly, false));
        assert!(channel_matches(&beta, false) && !channel_matches(&beta, true));
    }

    #[test]
    fn the_arguments_are_a_list_with_the_folder_as_one_item() {
        let dir = Path::new(r"C:\My Apps\Sequence Studio");
        let args = setup_args(dir, true, 77, true);
        let texts: Vec<_> = args.iter().map(|a| a.to_string_lossy().into_owned()).collect();
        assert_eq!(
            texts,
            [
                "--quiet",
                "--dir",
                r"C:\My Apps\Sequence Studio",
                "--desktop",
                "--wait-pid",
                "77",
                "--cleanup",
                "--launch"
            ]
        );
        let plain: Vec<_> =
            setup_args(dir, false, 77, false).iter().map(|a| a.to_string_lossy().into_owned()).collect();
        assert_eq!(plain, ["--quiet", "--dir", r"C:\My Apps\Sequence Studio", "--wait-pid", "77", "--cleanup"]);
    }

    #[test]
    fn prepare_refuses_another_channel_and_an_unknown_install() {
        let host = host_with(UNINSTALL_KEY, r"C:\Apps\SQ");
        let exe = Path::new(r"C:\Apps\SQ\SequenceStudio.exe");
        let nightly = Version::parse("0.2.1-nightly.20261120").unwrap_or_else(|| Version::new(0, 2, 1));
        assert!(matches!(prepare(&host, Identity::STABLE, exe, &nightly, 1, false), Err(ApplyError::Failed(_))));
        let stable = Version::new(0, 2, 1);
        assert!(prepare(&host, Identity::STABLE, exe, &stable, 1, true).is_ok());
        let other = Path::new(r"D:\x\SequenceStudio.exe");
        assert_eq!(prepare(&host, Identity::STABLE, other, &stable, 1, true), Err(ApplyError::Unsupported));
    }

    #[test]
    fn the_app_is_started_once_by_the_setup_and_never_by_the_updater() {
        let staged = Path::new(r"C:\Cache\SequenceStudio-Setup.exe");
        let dir = Path::new(r"C:\Apps\SQ");
        let launches = |restart| {
            let r = relaunch(staged, setup_args(dir, false, 9, restart));
            assert_eq!(r.program, staged);
            r.args.iter().filter(|a| a.to_string_lossy() == "--launch").count()
        };
        assert_eq!(launches(true), 1);
        assert_eq!(launches(false), 0);
    }

    #[test]
    fn a_nightly_app_updates_only_its_own_install_with_a_nightly_setup() {
        let nightly_key = Identity::NIGHTLY.uninstall_key();
        let host = host_with(nightly_key, r"C:\Apps\SQ Nightly");
        let exe = Path::new(r"C:\Apps\SQ Nightly\SequenceStudio.exe");
        let night = Version::parse("0.2.1-nightly.20261120").unwrap_or_else(|| Version::new(0, 2, 1));
        assert!(prepare(&host, Identity::NIGHTLY, exe, &night, 1, true).is_ok());
        assert!(matches!(
            prepare(&host, Identity::NIGHTLY, exe, &Version::new(0, 2, 1), 1, true),
            Err(ApplyError::Failed(_))
        ));
        // The Stable app does not see the Nightly record.
        assert_eq!(
            prepare(&host, Identity::STABLE, exe, &Version::new(0, 2, 1), 1, true),
            Err(ApplyError::Unsupported)
        );
    }
}
