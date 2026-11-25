//! The macOS install: copy the new app out of the downloaded disk image next to the running one, verify it, and swap
//! the two after the running app has quit. The pure parts (paths, output parsing, the swap script) build everywhere so
//! they are tested on any machine; the system calls only exist on macOS.
#![cfg_attr(not(target_os = "macos"), allow(dead_code))]

use std::path::{Path, PathBuf};

/// The signing team every release is signed with.
pub const TEAM_ID: &str = "63L6TSM2Y9";

/// The `.app` folder that holds `exe` (`…/X.app/Contents/MacOS/x`).
pub fn bundle_of(exe: &Path) -> Option<PathBuf> {
    exe.ancestors().find(|p| p.extension().is_some_and(|e| e == "app")).map(Path::to_path_buf)
}

/// Whether an app at `bundle` may be replaced in place: not a translocated copy and not run from a mounted image.
pub fn location_allows_install(bundle: &Path) -> bool {
    let text = bundle.to_string_lossy();
    !text.contains("/AppTranslocation/") && !bundle.starts_with("/Volumes")
}

/// The hidden folder entry the verified copy is staged under, on the same volume as `bundle`.
pub fn staged_path(bundle: &Path) -> Option<PathBuf> {
    let stem = bundle.file_stem()?.to_str()?;
    Some(bundle.parent()?.join(format!(".{stem}.update")))
}

/// Where the old app goes when it is replaced: the Trash entry (made unique with `stamp`) and the fallback beside it.
pub fn old_app_targets(bundle: &Path, home: &Path, stamp: u64) -> Option<(PathBuf, PathBuf)> {
    let stem = bundle.file_stem()?.to_str()?;
    let trash = home.join(".Trash").join(format!("{stem} {stamp}.app"));
    let bak = bundle.with_file_name(format!("{stem}.bak"));
    Some((trash, bak))
}

/// The mount point out of `hdiutil attach -plist` output: the `mount-point` value of the entry that has one.
pub fn parse_mount_point(plist: &str) -> Option<String> {
    let at = plist.find("<key>mount-point</key>")?;
    let rest = &plist[at..];
    let open = rest.find("<string>")? + "<string>".len();
    let close = rest[open..].find("</string>")? + open;
    let value = unescape_xml(rest[open..close].trim());
    (!value.is_empty()).then_some(value)
}

fn unescape_xml(s: &str) -> String {
    s.replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", "\"").replace("&apos;", "'").replace("&amp;", "&")
}

/// The `TeamIdentifier` line of `codesign -dv --verbose=2` output (it goes to stderr).
pub fn parse_team_id(output: &str) -> Option<String> {
    output
        .lines()
        .find_map(|l| l.trim().strip_prefix("TeamIdentifier="))
        .map(|v| v.trim().to_string())
        .filter(|v| !v.is_empty())
}

/// Checks a copy's signing team and bundle id against what a release must carry.
pub fn check_identity(codesign_output: &str, copy_id: &str, running_id: &str) -> Result<(), String> {
    match parse_team_id(codesign_output) {
        Some(team) if team == TEAM_ID => {}
        Some(_) => return Err("the new version is signed by another developer".into()),
        None => return Err("the new version is not signed".into()),
    }
    if copy_id != running_id {
        return Err("the new version is a different app than the one running".into());
    }
    Ok(())
}

/// The first `.app` folder inside `dir`.
pub fn find_app(dir: &Path) -> Option<PathBuf> {
    let mut apps: Vec<PathBuf> = std::fs::read_dir(dir)
        .ok()?
        .filter_map(Result::ok)
        .map(|e| e.path())
        .filter(|p| p.is_dir() && p.extension().is_some_and(|e| e == "app"))
        .collect();
    apps.sort();
    apps.into_iter().next()
}

/// Runs after the app quits. The paths arrive as arguments, never inside this text:
/// `$1` pid, `$2` old app, `$3` staged app, `$4` Trash target, `$5` fallback, `$6` "1" to start the new app; `$7…` are
/// extra `open` options (`--env K=V`), empty for a normal restart.
pub const SWAP_SCRIPT: &str = r#"
while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
if mv "$2" "$4" 2>/dev/null; then old="$4"; elif mv "$2" "$5"; then old="$5"; else rm -rf "$3"; exit 1; fi
if ! mv "$3" "$2"; then mv "$old" "$2"; rm -rf "$3"; exit 1; fi
if [ "$6" = 1 ]; then app="$2"; shift 6; open "$@" "$app"; fi
"#;

/// The arguments after `/bin/sh -c SWAP_SCRIPT`; the first one is the script's own name (`$0`).
pub fn swap_args(
    pid: u32,
    old: &Path,
    staged: &Path,
    trash: &Path,
    bak: &Path,
    restart: bool,
) -> Vec<std::ffi::OsString> {
    swap_args_with_env(pid, old, staged, trash, bak, restart, &[])
}

/// [`swap_args`] plus environment variables the restarted app gets (`open --env K=V`; the test hook's windowless
/// relaunch, see `autotest`). Only used with a restart.
pub fn swap_args_with_env(
    pid: u32,
    old: &Path,
    staged: &Path,
    trash: &Path,
    bak: &Path,
    restart: bool,
    env: &[(String, String)],
) -> Vec<std::ffi::OsString> {
    let mut args: Vec<std::ffi::OsString> =
        vec!["-c".into(), SWAP_SCRIPT.into(), "sq-update".into(), pid.to_string().into()];
    args.extend([old, staged, trash, bak].map(|p| p.as_os_str().to_os_string()));
    args.push(if restart { "1" } else { "0" }.into());
    if restart {
        for (k, v) in env {
            args.extend(["--env".into(), format!("{k}={v}").into()]);
        }
    }
    args
}

#[cfg(target_os = "macos")]
pub use system::{apply, supported};

#[cfg(target_os = "macos")]
mod system {
    use super::*;
    use std::os::unix::process::CommandExt;
    use std::process::{Command, Stdio};

    use crate::app_update::ApplyError;

    fn failed(text: impl Into<String>) -> ApplyError {
        ApplyError::Failed(text.into())
    }

    fn running_bundle() -> Option<PathBuf> {
        bundle_of(&std::env::current_exe().ok()?)
    }

    fn writable(dir: &Path) -> bool {
        use std::os::unix::ffi::OsStrExt;
        std::ffi::CString::new(dir.as_os_str().as_bytes())
            // SAFETY: `access` only reads the NUL-terminated path.
            .is_ok_and(|c| unsafe { libc::access(c.as_ptr(), libc::W_OK) } == 0)
    }

    /// Whether the running app can be replaced in place.
    pub fn supported() -> bool {
        running_bundle().is_some_and(|b| location_allows_install(&b) && b.parent().is_some_and(writable))
    }

    fn run(cmd: &mut Command) -> Result<std::process::Output, ApplyError> {
        cmd.output().map_err(|e| failed(format!("could not run {:?}: {e}", cmd.get_program())))
    }

    fn bundle_id(app: &Path) -> Result<String, ApplyError> {
        let plist = app.join("Contents/Info.plist");
        let out = run(Command::new("/usr/libexec/PlistBuddy").arg("-c").arg("Print :CFBundleIdentifier").arg(&plist))?;
        let id = String::from_utf8_lossy(&out.stdout).trim().to_string();
        if out.status.success() && !id.is_empty() {
            Ok(id)
        } else {
            Err(failed("the app's identifier could not be read"))
        }
    }

    /// Copies the app from the image `dmg` to `staged`; the image is detached again.
    fn copy_out(dmg: &Path, staged: &Path) -> Result<(), ApplyError> {
        let out =
            run(Command::new("hdiutil").args(["attach", "-nobrowse", "-readonly", "-noautoopen", "-plist"]).arg(dmg))?;
        if !out.status.success() {
            return Err(failed("the downloaded disk image could not be opened"));
        }
        let mount = parse_mount_point(&String::from_utf8_lossy(&out.stdout))
            .ok_or_else(|| failed("the downloaded disk image has no volume"))?;
        let copied = match find_app(Path::new(&mount)) {
            None => Err(failed("the disk image holds no app")),
            Some(app) => run(Command::new("ditto").arg(&app).arg(staged)).and_then(|o| {
                if o.status.success() { Ok(()) } else { Err(failed("the new version could not be copied")) }
            }),
        };
        let _ = Command::new("hdiutil").args(["detach", "-quiet"]).arg(&mount).status();
        copied
    }

    fn verify(staged: &Path, running: &Path) -> Result<(), ApplyError> {
        let strict = run(Command::new("codesign").args(["--verify", "--deep", "--strict"]).arg(staged))?;
        if !strict.status.success() {
            return Err(failed("the new version's signature is not valid"));
        }
        let details = run(Command::new("codesign").args(["-dv", "--verbose=2"]).arg(staged))?;
        check_identity(&String::from_utf8_lossy(&details.stderr), &bundle_id(staged)?, &bundle_id(running)?)
            .map_err(failed)
    }

    /// Installs the app held by `dmg`; the old app is swapped out once this process has quit.
    pub fn apply(dmg: &Path, restart: bool) -> Result<(), ApplyError> {
        let bundle = running_bundle().filter(|b| location_allows_install(b)).ok_or(ApplyError::Unsupported)?;
        let staged = staged_path(&bundle).ok_or(ApplyError::Unsupported)?;
        if !bundle.parent().is_some_and(writable) {
            return Err(ApplyError::Unsupported);
        }
        let _ = std::fs::remove_dir_all(&staged);
        let checked = copy_out(dmg, &staged).and_then(|()| verify(&staged, &bundle));
        if let Err(e) = checked {
            let _ = std::fs::remove_dir_all(&staged);
            return Err(e);
        }
        let home = std::env::var_os("HOME").map(PathBuf::from).ok_or_else(|| failed("no home folder"))?;
        let stamp = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_secs());
        let (trash, bak) =
            old_app_targets(&bundle, &home, stamp).ok_or_else(|| failed("the app's name is not usable"))?;
        let spawned = Command::new("/bin/sh")
            .args(swap_args_with_env(
                std::process::id(),
                &bundle,
                &staged,
                &trash,
                &bak,
                restart,
                &crate::app_update::autotest::relaunch_env_now(),
            ))
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .process_group(0)
            .spawn();
        if let Err(e) = spawned {
            let _ = std::fs::remove_dir_all(&staged);
            return Err(failed(format!("the update could not be finished: {e}")));
        }
        let _ = std::fs::remove_file(dmg);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The pid of a process that has already exited, so the script does not wait.
    fn finished_pid() -> u32 {
        let mut child = std::process::Command::new("/bin/sh").args(["-c", "exit 0"]).spawn().expect("sh");
        let pid = child.id();
        child.wait().expect("wait");
        pid
    }

    #[test]
    fn finds_the_bundle_of_the_executable() {
        let exe = Path::new("/Applications/Sequence Studio.app/Contents/MacOS/sequence-studio");
        assert_eq!(bundle_of(exe), Some(PathBuf::from("/Applications/Sequence Studio.app")));
        assert_eq!(bundle_of(Path::new("/usr/local/bin/sequence-studio")), None);
    }

    #[test]
    fn translocated_and_mounted_apps_are_not_replaced() {
        assert!(location_allows_install(Path::new("/Applications/Sequence Studio.app")));
        assert!(location_allows_install(Path::new("/Users/a/Apps/Sequence Studio.app")));
        assert!(!location_allows_install(Path::new(
            "/AppTranslocation-root/x/AppTranslocation/ABC/d/Sequence Studio.app"
        )));
        assert!(!location_allows_install(Path::new("/Volumes/Sequence Studio/Sequence Studio.app")));
    }

    #[test]
    fn staging_sits_next_to_the_app_and_the_old_one_has_two_targets() {
        let app = Path::new("/Applications/Sequence Studio.app");
        assert_eq!(staged_path(app), Some(PathBuf::from("/Applications/.Sequence Studio.update")));
        let (trash, bak) = old_app_targets(app, Path::new("/Users/a"), 42).expect("targets");
        assert_eq!(trash, PathBuf::from("/Users/a/.Trash/Sequence Studio 42.app"));
        assert_eq!(bak, PathBuf::from("/Applications/Sequence Studio.bak"));
    }

    #[test]
    fn reads_the_mount_point_from_attach_output() {
        let plist = "<plist><dict><key>system-entities</key><array>\
            <dict><key>content-hint</key><string>GUID_partition_scheme</string></dict>\
            <dict><key>mount-point</key><string>/Volumes/Sequence &amp; Studio</string></dict></array></dict></plist>";
        assert_eq!(parse_mount_point(plist).as_deref(), Some("/Volumes/Sequence & Studio"));
        assert_eq!(parse_mount_point("<plist/>"), None);
    }

    #[test]
    fn reads_the_team_and_checks_the_identity() {
        let out =
            "Executable=/x\nIdentifier=de.x\nAuthority=Dev\nTeamIdentifier=63L6TSM2Y9\nSealed Resources version=2\n";
        assert_eq!(parse_team_id(out).as_deref(), Some("63L6TSM2Y9"));
        assert_eq!(check_identity(out, "de.stable", "de.stable"), Ok(()));
        assert!(check_identity(out, "de.nightly", "de.stable").is_err());
        assert!(check_identity("TeamIdentifier=OTHER\n", "a", "a").is_err());
        assert!(check_identity("TeamIdentifier=not set\nIdentifier=x\n", "a", "a").is_err());
        assert!(check_identity("Identifier=x\n", "a", "a").is_err());
    }

    #[test]
    fn paths_reach_the_script_only_as_arguments() {
        let evil = Path::new("/Apps/$(rm -rf ~) \"x\".app");
        let args = swap_args(7, evil, Path::new("/Apps/.s"), Path::new("/t"), Path::new("/b"), true);
        assert_eq!(args[1], std::ffi::OsString::from(SWAP_SCRIPT));
        assert!(!SWAP_SCRIPT.contains("rm -rf ~"));
        assert_eq!(args.len(), 9);
        assert_eq!(args[3], std::ffi::OsString::from("7"));
        assert_eq!(args[4], evil.as_os_str());
        assert_eq!(args[8], std::ffi::OsString::from("1"));
    }

    #[test]
    fn the_test_hook_env_reaches_open_as_env_options_and_a_normal_restart_has_none() {
        let (a, s, t, b) = (Path::new("/A.app"), Path::new("/.s"), Path::new("/t"), Path::new("/b"));
        let env = vec![("SQ_UPDATE_AUTOTEST".to_string(), "report".to_string())];
        let with = swap_args_with_env(7, a, s, t, b, true, &env);
        assert_eq!(&with[9..], [std::ffi::OsString::from("--env"), "SQ_UPDATE_AUTOTEST=report".into()]);
        assert_eq!(swap_args_with_env(7, a, s, t, b, true, &[]), swap_args(7, a, s, t, b, true));
        assert_eq!(swap_args_with_env(7, a, s, t, b, false, &env).len(), 9, "no restart: no open options");
    }

    #[test]
    fn restart_passes_the_env_options_to_open_before_the_app() {
        use std::os::unix::fs::PermissionsExt;
        let root = std::env::temp_dir().join(format!("sq-mac-openenv-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let (old, new, bak) = (root.join("A.app"), root.join(".A.update"), root.join("A.bak"));
        let (tools, log) = (root.join("tools"), root.join("opened"));
        for dir in [&old, &new, &tools] {
            std::fs::create_dir_all(dir).expect("dir");
        }
        let fake = tools.join("open");
        std::fs::write(&fake, format!("#!/bin/sh\necho \"$*\" >> '{}'\n", log.display())).expect("fake");
        std::fs::set_permissions(&fake, std::fs::Permissions::from_mode(0o755)).expect("mode");
        let env = vec![("K".to_string(), "v w".to_string())];
        let status = std::process::Command::new("/bin/sh")
            .args(swap_args_with_env(finished_pid(), &old, &new, &root.join("no/dir/A.app"), &bak, true, &env))
            .env("PATH", format!("{}:/usr/bin:/bin", tools.display()))
            .status()
            .expect("sh");
        assert!(status.success());
        assert_eq!(std::fs::read_to_string(&log).expect("log"), format!("--env K=v w {}\n", old.display()));
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn the_swap_script_replaces_the_app_and_keeps_the_old_one() {
        let root = std::env::temp_dir().join(format!("sq-mac-swap-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let (old, new, trash, bak) =
            (root.join("A b.app"), root.join(".A b.update"), root.join("trash/A b 1.app"), root.join("A b.bak"));
        for (dir, text) in [(&old, "old"), (&new, "new")] {
            std::fs::create_dir_all(dir).expect("dir");
            std::fs::write(dir.join("v"), text).expect("v");
        }
        std::fs::create_dir_all(root.join("trash")).expect("trash");
        let status = std::process::Command::new("/bin/sh")
            .args(swap_args(finished_pid(), &old, &new, &trash, &bak, false))
            .status()
            .expect("sh");
        assert!(status.success());
        assert_eq!(std::fs::read_to_string(old.join("v")).expect("v"), "new");
        assert_eq!(std::fs::read_to_string(trash.join("v")).expect("v"), "old");
        assert!(!new.exists());
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn the_old_app_falls_back_to_the_bak_folder_when_the_trash_is_missing() {
        let root = std::env::temp_dir().join(format!("sq-mac-bak-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let (old, new, bak) = (root.join("A.app"), root.join(".A.update"), root.join("A.bak"));
        for (dir, text) in [(&old, "old"), (&new, "new")] {
            std::fs::create_dir_all(dir).expect("dir");
            std::fs::write(dir.join("v"), text).expect("v");
        }
        let status = std::process::Command::new("/bin/sh")
            .args(swap_args(finished_pid(), &old, &new, &root.join("no/such/dir/A.app"), &bak, false))
            .status()
            .expect("sh");
        assert!(status.success());
        assert_eq!(std::fs::read_to_string(old.join("v")).expect("v"), "new");
        assert_eq!(std::fs::read_to_string(bak.join("v")).expect("v"), "old");
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn restart_starts_the_new_app_once_from_the_script() {
        use std::os::unix::fs::PermissionsExt;
        let root = std::env::temp_dir().join(format!("sq-mac-open-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let (old, new, bak) = (root.join("A.app"), root.join(".A.update"), root.join("A.bak"));
        let (tools, log) = (root.join("tools"), root.join("opened"));
        for dir in [&old, &new, &tools] {
            std::fs::create_dir_all(dir).expect("dir");
        }
        let fake = tools.join("open");
        std::fs::write(&fake, format!("#!/bin/sh\necho \"$1\" >> '{}'\n", log.display())).expect("fake");
        std::fs::set_permissions(&fake, std::fs::Permissions::from_mode(0o755)).expect("mode");
        let path = format!("{}:/usr/bin:/bin", tools.display());
        let status = std::process::Command::new("/bin/sh")
            .args(swap_args(finished_pid(), &old, &new, &root.join("no/dir/A.app"), &bak, true))
            .env("PATH", path)
            .status()
            .expect("sh");
        assert!(status.success());
        assert_eq!(std::fs::read_to_string(&log).expect("log"), format!("{}\n", old.display()));
        let _ = std::fs::remove_dir_all(root);
    }
}
