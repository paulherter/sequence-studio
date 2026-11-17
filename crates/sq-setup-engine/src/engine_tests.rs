//! Engine tests: real temp folders, a `FakeHost` for the registry and shortcuts.

use crate::detect::{InstallSource, detect_installed};
use crate::engine::{JobEnd, JobSpec, Progress, finish_uninstall_copy, run_job, uninstall_copy_name};
use crate::error::ErrorCode;
use crate::host::{FakeHost, Host};
use crate::job::{Job, Step};
use crate::log::Log;
use crate::payload;
use crate::plan::{INNO_UNINSTALL_KEY, UNINSTALL_KEY};
use crate::version::Version;
use std::path::{Path, PathBuf};

struct Rec {
    seen: Vec<(Step, f64)>,
    cancel_from: Option<f64>,
}

impl Progress for Rec {
    fn update(&mut self, step: Step, fraction: f64, _detail: &str) {
        self.seen.push((step, fraction));
    }
    fn canceled(&self) -> bool {
        matches!((self.cancel_from, self.seen.last()), (Some(c), Some((_, f))) if *f >= c)
    }
}

struct Env {
    dir: PathBuf,
    host: FakeHost,
    setup_exe: PathBuf,
    location: PathBuf,
}

impl Env {
    fn new(name: &str) -> Env {
        let dir = std::env::temp_dir().join(format!("sq-engine-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let stage = dir.join("stage");
        let _ = std::fs::create_dir_all(stage.join("Fonts"));
        let _ = std::fs::write(stage.join("SequenceStudio.exe"), b"exe".repeat(1000));
        let _ = std::fs::write(stage.join("SequenceStudio.ico"), b"ico");
        let _ = std::fs::write(stage.join("LICENSE"), b"license");
        let _ = std::fs::write(stage.join("Fonts").join("a.ttf"), b"font");
        let mut x = 7u32;
        let big: Vec<u8> = (0..1_500_000)
            .map(|_| {
                x = x.wrapping_mul(1664525).wrapping_add(1013904223);
                (x >> 24) as u8
            })
            .collect();
        let _ = std::fs::write(stage.join("big.dll"), big);
        let setup_exe = dir.join("Setup.exe");
        assert!(payload::pack(b"STUB", &stage, &Version::new(0, 3, 0), &setup_exe).is_ok());
        let _ = std::fs::create_dir_all(dir.join("Roaming").join("Start Menu").join("Programs"));
        Env { host: FakeHost::new(&dir), location: dir.join("Apps").join("Sequence Studio"), dir, setup_exe }
    }

    fn spec(&self, job: Job) -> JobSpec {
        JobSpec {
            job,
            location: self.location.clone(),
            desktop_shortcut: true,
            delete_data: false,
            version: Version::new(0, 3, 0),
            payload_exe: self.setup_exe.clone(),
            data_dirs: vec![self.dir.join("data")],
        }
    }

    fn run(&self, spec: &JobSpec, cancel_from: Option<f64>) -> (Result<JobEnd, crate::SetupError>, Rec, Log) {
        let mut rec = Rec { seen: Vec::new(), cancel_from };
        let mut log = Log::new(&self.host.folders.temp, "20261116-090000");
        let result = run_job(spec, &self.host, &mut rec, &mut log);
        (result, rec, log)
    }

    fn install(&self) {
        assert!(matches!(self.run(&self.spec(Job::Install), None).0, Ok(JobEnd::Done)));
    }

    fn menu_link(&self) -> PathBuf {
        self.host.folders.start_menu_programs.join("Sequence Studio.lnk")
    }

    /// Nothing of the job is left next to the location.
    fn no_temp_folders(&self) {
        let parent = self.location.parent().map(Path::to_path_buf).unwrap_or_default();
        assert!(!parent.join("Sequence Studio.new").exists());
        assert!(!parent.join("Sequence Studio.old").exists());
    }
}

fn old_version() -> Job {
    Job::Update { from: Version::new(0, 2, 0) }
}

#[test]
fn an_install_copies_registers_and_reports_a_rising_bar() {
    let env = Env::new("install");
    let (result, rec, log) = env.run(&env.spec(Job::Install), None);
    assert!(matches!(result, Ok(JobEnd::Done)));
    for f in ["SequenceStudio.exe", "SequenceStudio.ico", "LICENSE", "Uninstall Sequence Studio.exe", "big.dll"] {
        assert!(env.location.join(f).exists(), "{f}");
    }
    assert!(env.location.join("Fonts").join("a.ttf").exists());
    assert_eq!(std::fs::read(env.location.join("Uninstall Sequence Studio.exe")).ok(), Some(b"STUB".to_vec()));
    env.no_temp_folders();
    assert!(env.menu_link().exists());
    assert!(env.host.folders.desktop.join("Sequence Studio.lnk").exists());
    let installed = detect_installed(&env.host).expect("our key");
    assert_eq!((installed.source, installed.version), (InstallSource::Ours, Version::new(0, 3, 0)));
    assert_eq!(env.host.get_dword(UNINSTALL_KEY, "NoModify"), Some(1));
    assert_eq!(env.host.with(|s| s.assoc_changes), 1);
    let fractions: Vec<f64> = rec.seen.iter().map(|(_, f)| *f).collect();
    assert!(fractions.windows(2).all(|w| w[0] <= w[1]), "the bar never falls: {fractions:?}");
    assert_eq!(fractions.last(), Some(&1.0));
    assert!(
        rec.seen.iter().any(|(s, f)| *s == Step::Copying && *f > 0.1 && *f < 0.9),
        "bytes move the bar inside 4-90 %"
    );
    assert!(std::fs::read_to_string(log.path()).unwrap_or_default().contains("swapped the new folder"));
}

#[test]
fn an_update_replaces_the_folder_and_removes_the_inno_leftovers() {
    let env = Env::new("update");
    let _ = std::fs::create_dir_all(&env.location);
    for f in ["old-only.txt", "unins000.exe", "unins000.dat", "SequenceStudio.exe"] {
        let _ = std::fs::write(env.location.join(f), b"old");
    }
    let _ = env.host.reg_set_string(INNO_UNINSTALL_KEY, Some("DisplayVersion"), "0.2");
    let _ =
        env.host.reg_set_string(INNO_UNINSTALL_KEY, Some("InstallLocation"), &format!("{}\\", env.location.display()));
    assert_eq!(detect_installed(&env.host).map(|i| i.source), Some(InstallSource::Inno));
    let (result, _, _) = env.run(&env.spec(old_version()), None);
    assert!(matches!(result, Ok(JobEnd::Done)));
    assert!(!env.location.join("old-only.txt").exists());
    assert!(!env.location.join("unins000.exe").exists() && !env.location.join("unins000.dat").exists());
    assert_eq!(std::fs::read(env.location.join("SequenceStudio.exe")).map(|b| b.len()).ok(), Some(3000));
    assert_eq!(env.host.get_string(INNO_UNINSTALL_KEY, Some("DisplayVersion")), None, "the Inno key is gone");
    assert_eq!(detect_installed(&env.host).map(|i| i.source), Some(InstallSource::Ours));
    env.no_temp_folders();
}

#[test]
fn a_failure_after_the_swap_brings_the_old_folder_back() {
    let env = Env::new("rollback-update");
    let _ = std::fs::create_dir_all(&env.location);
    let _ = std::fs::write(env.location.join("old-only.txt"), b"old");
    env.host.with(|s| s.fail_shortcut = true);
    let (result, _, log) = env.run(&env.spec(old_version()), None);
    let err = result.expect_err("the shortcut fails");
    assert_eq!(err.code, ErrorCode::Shortcut);
    assert_eq!(std::fs::read(env.location.join("old-only.txt")).ok(), Some(b"old".to_vec()));
    assert!(!env.location.join("big.dll").exists(), "nothing of the new version stays");
    env.no_temp_folders();
    assert!(std::fs::read_to_string(log.path()).unwrap_or_default().contains("FAILED SQI-107"));
}

#[test]
fn a_failed_first_install_leaves_no_folder_no_shortcut_no_key() {
    let env = Env::new("rollback-install");
    env.host.with(|s| s.fail_reg_name = Some("UninstallString".into()));
    let (result, _, _) = env.run(&env.spec(Job::Install), None);
    assert_eq!(result.expect_err("registry refuses").code, ErrorCode::Registry);
    assert!(!env.location.exists());
    env.no_temp_folders();
    assert!(!env.menu_link().exists() && !env.host.folders.desktop.join("Sequence Studio.lnk").exists());
    assert_eq!(env.host.keys(), Vec::<String>::new(), "every key the plan wrote is deleted again");
}

#[test]
fn a_cancel_before_90_percent_leaves_everything_as_it_was() {
    let env = Env::new("cancel");
    let (result, _, _) = env.run(&env.spec(Job::Install), Some(0.3));
    assert!(matches!(result, Ok(JobEnd::Canceled)));
    assert!(!env.location.exists());
    env.no_temp_folders();
    assert!(env.host.keys().is_empty() && !env.menu_link().exists());

    let _ = std::fs::create_dir_all(&env.location);
    let _ = std::fs::write(env.location.join("keep.txt"), b"k");
    let (result, _, _) = env.run(&env.spec(old_version()), Some(0.3));
    assert!(matches!(result, Ok(JobEnd::Canceled)));
    assert!(env.location.join("keep.txt").exists());
    env.no_temp_folders();
}

#[test]
fn a_cancel_request_after_90_percent_is_ignored() {
    let env = Env::new("late-cancel");
    let (result, _, _) = env.run(&env.spec(Job::Install), Some(0.9));
    assert!(matches!(result, Ok(JobEnd::Done)));
    assert!(env.location.join("SequenceStudio.exe").exists());
}

#[test]
fn too_little_space_is_sqi_104_with_the_numbers_and_nothing_is_written() {
    let env = Env::new("space");
    env.host.with(|s| s.free = Some(1000));
    let (result, _, _) = env.run(&env.spec(Job::Install), None);
    let err = result.expect_err("no space");
    assert_eq!(err.code, ErrorCode::NoSpace);
    let facts = err.space.expect("facts");
    assert_eq!((facts.drive.as_str(), facts.free), ("C:", 1000));
    assert!(facts.need > 1_500_000);
    assert!(!env.location.exists());
    env.no_temp_folders();
}

#[test]
fn a_damaged_setup_file_is_sqi_101_before_anything_is_written() {
    let env = Env::new("damaged");
    let mut bytes = std::fs::read(&env.setup_exe).unwrap_or_default();
    bytes[200] ^= 1;
    let _ = std::fs::write(&env.setup_exe, bytes);
    let (result, _, _) = env.run(&env.spec(Job::Install), None);
    assert_eq!(result.expect_err("hash").code, ErrorCode::PayloadDamaged);
    assert!(!env.location.exists());
}

#[test]
fn a_running_app_is_asked_to_close_and_blocks_after_ten_seconds() {
    let env = Env::new("running");
    env.install();
    let exe = env.location.join("SequenceStudio.exe");
    env.host.with(|s| s.running = vec![exe.clone()]);
    let (result, _, _) = env.run(&env.spec(old_version()), None);
    assert!(matches!(result, Ok(JobEnd::Done)));
    assert_eq!(env.host.with(|s| s.close_requests), 1);

    env.host.with(|s| {
        s.running = vec![exe.clone()];
        s.closes_on_request = false;
    });
    let (result, _, _) = env.run(&env.spec(old_version()), None);
    assert_eq!(result.expect_err("still open").code, ErrorCode::AppStillOpen);
    assert!(exe.exists(), "the installed version is untouched");
    env.no_temp_folders();
}

#[test]
fn an_uninstall_removes_files_shortcuts_and_keys_but_keeps_data_unless_asked() {
    let env = Env::new("uninstall");
    env.install();
    let data = env.dir.join("data");
    let _ = std::fs::create_dir_all(&data);
    let _ = std::fs::write(data.join("cache.bin"), b"c");
    let mut spec = env.spec(Job::Uninstall);
    spec.payload_exe = env.location.join("Uninstall Sequence Studio.exe");
    let (result, rec, _) = env.run(&spec, Some(0.0));
    assert!(matches!(result, Ok(JobEnd::Done)), "an uninstall ignores a cancel request");
    assert!(!env.location.exists());
    assert!(!env.menu_link().exists() && !env.host.folders.desktop.join("Sequence Studio.lnk").exists());
    assert_eq!(env.host.keys(), Vec::<String>::new());
    assert!(data.join("cache.bin").exists(), "data stays");
    assert!(rec.seen.iter().any(|(s, _)| *s == Step::RemovingFiles) && rec.seen.last().map(|(_, f)| *f) == Some(1.0));

    env.install();
    spec.delete_data = true;
    let (result, _, _) = env.run(&spec, None);
    assert!(matches!(result, Ok(JobEnd::Done)));
    assert!(!data.exists(), "data goes when asked");
}

#[test]
fn the_sqproj_link_stays_when_it_points_to_another_program() {
    let env = Env::new("sqproj");
    env.install();
    let _ = env.host.reg_set_string(r"Software\Classes\.sqproj", None, "Other.Editor");
    let mut spec = env.spec(Job::Uninstall);
    spec.payload_exe = env.setup_exe.clone();
    let (result, _, _) = env.run(&spec, None);
    assert!(matches!(result, Ok(JobEnd::Done)));
    assert_eq!(env.host.get_string(r"Software\Classes\.sqproj", None).as_deref(), Some("Other.Editor"));
    assert_eq!(env.host.keys(), vec![r"software\classes\.sqproj".to_string()], "only the foreign value is left");
}

#[test]
fn an_uninstall_with_a_running_app_that_stays_is_sqi_201() {
    let env = Env::new("uninstall-open");
    env.install();
    env.host.with(|s| {
        s.running = vec![env.location.join("SequenceStudio.exe")];
        s.closes_on_request = false;
    });
    let (result, _, _) = env.run(&env.spec(Job::Uninstall), None);
    assert_eq!(result.expect_err("open").code, ErrorCode::UninstallInUse);
    assert!(env.location.exists() && detect_installed(&env.host).is_some());
}

#[test]
fn linux_jobs_are_not_run_here() {
    let env = Env::new("linux");
    let (result, _, _) = env.run(&env.spec(Job::LinuxAdd), None);
    assert!(result.is_err());
}

/// The folders the Windows program names as data (`windows.rs` `env_dirs`): the app's settings under Roaming, its caches
/// and logs under Local, both spellings.
fn app_data_dirs(env: &Env) -> Vec<PathBuf> {
    let f = env.host.folders();
    vec![
        f.app_data.join("Sequence Studio"),
        f.local_app_data.join("Sequence Studio"),
        f.local_app_data.join("SequenceStudio"),
    ]
}

#[test]
fn delete_data_removes_the_settings_and_every_cache_folder_with_what_is_nested_in_them() {
    let env = Env::new("deldata");
    env.install();
    let dirs = app_data_dirs(&env);
    for (i, dir) in dirs.iter().enumerate() {
        let _ = std::fs::create_dir_all(dir.join("Presets").join("deep"));
        let _ = std::fs::write(dir.join("settings.json"), b"{}");
        let _ = std::fs::write(dir.join("Presets").join("deep").join(format!("p{i}.sqpreset")), b"x");
    }
    let mut spec = env.spec(Job::Uninstall);
    spec.payload_exe = env.dir.join("Temp").join(uninstall_copy_name(4321));
    spec.data_dirs = dirs.clone();
    let (kept, _, _) = env.run(&spec, None);
    assert!(matches!(kept, Ok(JobEnd::Done)));
    assert!(dirs.iter().all(|d| d.exists()), "without the option the data stays");
    env.install();
    spec.delete_data = true;
    let (gone, _, log) = env.run(&spec, None);
    assert!(matches!(gone, Ok(JobEnd::Done)));
    for dir in &dirs {
        assert!(!dir.exists(), "{} must be gone", dir.display());
    }
    assert!(!env.location.exists());
    let text = std::fs::read_to_string(log.path()).unwrap_or_default();
    assert!(text.contains("remove folder") && text.contains("Sequence Studio"), "the log names the data folders");
}

#[test]
fn the_sqproj_key_goes_when_ours_was_the_only_value_in_it() {
    let env = Env::new("sqprojkey");
    env.install();
    assert!(env.host.keys().contains(&r"software\classes\.sqproj".to_string()), "the install made the key");
    let (result, _, _) = env.run(&env.spec(Job::Uninstall), None);
    assert!(matches!(result, Ok(JobEnd::Done)));
    assert_eq!(env.host.keys(), Vec::<String>::new(), "no key of ours stays, empty or not");
}

#[test]
fn the_uninstaller_copies_in_temp_are_swept_and_its_own_goes_when_it_has_ended() {
    let env = Env::new("copies");
    let temp = env.host.folders.temp.clone();
    let _ = std::fs::create_dir_all(&temp);
    let (stale, own) = (temp.join(uninstall_copy_name(111)), temp.join(uninstall_copy_name(222)));
    let (other, note) = (temp.join("other.exe"), temp.join("Sequence Studio Uninstall notes.txt"));
    for file in [&stale, &own, &other, &note] {
        let _ = std::fs::write(file, b"x");
    }
    finish_uninstall_copy(&env.host, &own);
    assert!(!stale.exists(), "a copy of an earlier run goes");
    assert!(own.exists() && other.exists() && note.exists(), "the running copy and foreign files stay");
    assert_eq!(env.host.with(|s| s.exit_deletes.clone()), vec![own.clone()], "its own copy is deleted after exit");
    finish_uninstall_copy(&env.host, &other);
    assert_eq!(env.host.with(|s| s.exit_deletes.len()), 1, "a file that is not a copy is never scheduled");
    let elsewhere = env.dir.join(uninstall_copy_name(333));
    finish_uninstall_copy(&env.host, &elsewhere);
    assert_eq!(env.host.with(|s| s.exit_deletes.len()), 1, "nor a copy outside the temp folder");
}
