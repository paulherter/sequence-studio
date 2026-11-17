use std::cell::{Cell, RefCell};
use std::path::{Path, PathBuf};

use sq_core_model::effect_defaults::EffectDefaults;
use sq_core_model::{OutsideMediaMode, TimelineEditMode};
use sq_core_time::{Id, IdSource, SequentialIds};
use sq_export::core::settings::EncoderSpeed;
use sq_os::Platform;
use sq_uikit::appearance_palette::UiDefaults;
use sq_uikit::command_map::{CommandMap, Entry};
use sq_uikit::editor_command::{CommandScope, EditorCommand};
use sq_uikit::key_binding::{Key, KeyBinding, KeyModifiers};

use crate::MonitorQuality;
use crate::es08_media::MediaPolicyDefaults;
use crate::es10_workspace::defaults::TestDefaults;
use crate::es10_workspace::{
    AppSettings, AppSettingsKey, AudioOutputChoices, AudioOutputDevice, AudioPreferences, CardImportSettings,
    DefaultsExt, DefaultsMigration, EffectDefaultsEntry, EffectDefaultsGroup, EffectDefaultsSettings, KeyboardLayout,
    KeyboardLayoutModel, KeyboardStyle, MediaSettings, OnboardingContent, ProxyMove, StorageFolderChoice,
    StorageLocations, StorageLocationsKey, StorageProblem, UpdateCheck, UpdateOutcome, UpdateRelease,
};

fn tmp() -> PathBuf {
    static N: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
    let u = std::env::temp_dir().join(format!(
        "sq-storage-{}-{}",
        std::process::id(),
        N.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
    ));
    std::fs::create_dir_all(&u).unwrap();
    u
}

// MARK: AppSettings

#[test]
fn caption_language_derivation() {
    let s = &AppSettings::SUPPORTED_CAPTION_LANGUAGES;
    let d = |p: &[&str]| AppSettings::derived_caption_language(&p.iter().map(|x| x.to_string()).collect::<Vec<_>>(), s);
    assert_eq!(d(&["en-GB", "de-DE"]), "en-GB"); // exact region wins
    assert_eq!(d(&["de-AT"]), "de-DE");
    assert_eq!(d(&["fr_CA"]), "fr-FR");
    assert_eq!(d(&["ja-JP"]), "en-US");
    assert_eq!(d(&["ja-JP", "es-MX"]), "es-ES");
    assert_eq!(d(&[]), "en-US");
}

#[test]
fn project_language_falls_back_to_the_setting() {
    let mut d = TestDefaults::default();
    let id = SequentialIds::default().next_id();
    assert_eq!(AppSettings::caption_language_for_project(id, &d), AppSettings::load(&d).caption_language);
    AppSettings::set_caption_language_for_project(Some("fr-FR"), id, &mut d);
    assert_eq!(AppSettings::caption_language_for_project(id, &d), "fr-FR");
    AppSettings::set_caption_language_for_project(None, id, &mut d);
    assert_eq!(AppSettings::caption_language_for_project(id, &d), AppSettings::load(&d).caption_language);
    AppSettings::set_caption_language_for_project(Some("not valid!"), id, &mut d);
    assert!(!d.has(&format!("sq.captions.language.{id}")));
}

#[test]
fn proxies_for_export_is_off_by_default_and_round_trips() {
    let mut d = TestDefaults::default();
    assert!(!AppSettings::load(&d).use_proxies_for_export);
    let mut s = AppSettings::load(&d);
    s.use_proxies_for_export = true;
    s.save(&mut d);
    assert!(AppSettings::load(&d).use_proxies_for_export);
    assert!(d.bool_value("sq.proxy.export"));
    assert_eq!(AppSettingsKey::PROXIES_FOR_EXPORT, "sq.proxy.export");
}

#[test]
fn settings_flags_persist() {
    let mut d = TestDefaults::default();
    let mut s = AppSettings::load(&d);
    assert!(s.check_for_updates && !s.onboarding_seen);
    s.check_for_updates = false;
    s.onboarding_seen = true;
    s.save(&mut d);
    let back = AppSettings::load(&d);
    assert!(!back.check_for_updates && back.onboarding_seen);
}

#[test]
fn every_setting_round_trips() {
    let mut d = TestDefaults::default();
    let mut s = AppSettings::standard();
    s.autosave_interval = 600.0;
    s.offer_recovery = false;
    s.default_quality = MonitorQuality::Half;
    s.preview_quality_auto = false;
    s.frame_cache_gb = 4;
    s.background_work = false;
    s.render_cache = false;
    s.render_cache_cap_gb = 20;
    s.export_encoder_speed = EncoderSpeed::Fast;
    s.audio_output_uid = Some("dev-1".to_string());
    s.cache_folder = Some(PathBuf::from("/Volumes/Fast/C"));
    s.cache_cap_gb = 100;
    s.preroll_seconds = 6;
    s.postroll_seconds = 0;
    s.hover_scrub = false;
    s.drop_indicator = false;
    s.audio_scrubbing = true;
    s.new_sequence_edit_mode = TimelineEditMode::Magnetic;
    s.selection_follows_playhead = true;
    s.refresh_growing_files = false;
    s.default_text_seconds = 8;
    s.caption_language = "fr-FR".to_string();
    s.caption_auto_language = false;
    s.save(&mut d);
    assert_eq!(AppSettings::load(&d), s);
    // Auto leaves no quality behind; a retired key is removed.
    d.set_flag(AppSettingsKey::RETIRED_RIPPLE_DELETE, true);
    s.preview_quality_auto = true;
    s.save(&mut d);
    assert!(d.string(AppSettingsKey::QUALITY).is_none() && !d.has(AppSettingsKey::RETIRED_RIPPLE_DELETE));
}

#[test]
fn stale_or_hand_edited_values_fall_back() {
    let mut d = TestDefaults::default();
    d.set_string(AppSettingsKey::AUTOSAVE, "5");
    d.set_integer(AppSettingsKey::CAP, 0);
    d.set_integer(AppSettingsKey::PREROLL, 99);
    d.set_string(AppSettingsKey::CACHE, "relative");
    d.set_string(AppSettingsKey::CAPTION_LANGUAGE, "x");
    d.set_string(AppSettingsKey::ENCODER_SPEED, "turbo");
    let s = AppSettings::load(&d);
    let std = AppSettings::standard();
    assert_eq!(
        (s.autosave_interval, s.cache_cap_gb, s.preroll_seconds),
        (std.autosave_interval, std.cache_cap_gb, std.preroll_seconds)
    );
    assert!(s.cache_folder.is_none() && s.export_encoder_speed == EncoderSpeed::Quality);
    assert_eq!(s.caption_language, std.caption_language);
}

#[test]
fn quality_auto_follows_the_stored_choice() {
    let mut d = TestDefaults::default();
    assert!(AppSettings::load(&d).preview_quality_auto);
    d.set_string(AppSettingsKey::QUALITY, "full"); // written by every save of older builds
    assert!(AppSettings::load(&d).preview_quality_auto);
    d.set_string(AppSettingsKey::QUALITY, "eighth"); // retired value reads as quarter, fixed
    let s = AppSettings::load(&d);
    assert!(!s.preview_quality_auto && s.default_quality == MonitorQuality::Quarter);
    assert_eq!(s.start_quality(MonitorQuality::Half), MonitorQuality::Quarter);
    assert_eq!(AppSettings::standard().start_quality(MonitorQuality::Half), MonitorQuality::Half);
    let fixed = AppSettings::standard().choosing_fixed_quality(MonitorQuality::Half);
    assert!(!fixed.preview_quality_auto && fixed.default_quality == MonitorQuality::Half);
}

#[test]
fn rolls_and_cache_cap() {
    let s = AppSettings::standard();
    assert_eq!((s.preroll().value(), s.postroll().value()), (3, 2));
    assert_eq!(s.cache_cap_bytes(), 50_000_000_000);
    let mut zero = s;
    zero.cache_cap_gb = 0;
    assert_eq!(zero.cache_cap_bytes(), 1_000_000_000);
}

// MARK: StorageLocations (StorageLocationsTests)

#[test]
fn defaults_resolve_to_the_usual_places() {
    let l = StorageLocations::default();
    assert!(l.proxy_directory().ends_with(Path::new("Sequence Studio").join("Proxies")));
    assert_eq!(l.cache_root(), AppSettings::default_cache_folder());
    assert_eq!(l.scratch_root().file_name().and_then(|n| n.to_str()), Some("Scratch"));
    assert_eq!(l.projects_root().file_name().and_then(|n| n.to_str()), Some("Sequence Studio"));
}

#[test]
fn picked_cache_root_decides_proxies_and_waveforms() {
    let l = StorageLocations::new(Some(PathBuf::from("/Volumes/Fast/C")), None, None);
    assert_eq!(l.proxy_directory(), Path::new("/Volumes/Fast/C/Proxies"));
    assert_eq!(l.waveform_directory(), Path::new("/Volumes/Fast/C/Waveforms"));
    assert_eq!(l.scratch_root(), Path::new("/Volumes/Fast/C/Scratch"));
}

#[test]
fn export_fallback_is_the_projects_root() {
    let projects = tmp().join("P");
    let l = StorageLocations::new(None, None, Some(projects.clone()));
    assert_eq!(l.export_fallback_directory(), Some(projects.clone()));
    assert!(projects.exists());
}

#[test]
fn scratch_and_projects_overrides_win() {
    let l = StorageLocations::new(Some("/a".into()), Some("/s".into()), Some("/p".into()));
    assert!(l.scratch_root() == Path::new("/s") && l.projects_root() == Path::new("/p"));
}

#[test]
fn round_trips_through_defaults_and_reads_the_legacy_cache_key() {
    let mut d = TestDefaults::default();
    d.set_string(AppSettingsKey::CACHE, "/old/cache");
    assert_eq!(StorageLocations::load(&d).cache_folder, Some(PathBuf::from("/old/cache")));
    let mut l = StorageLocations::new(Some("/n/c".into()), Some("/n/s".into()), None);
    l.save(&mut d);
    assert_eq!(StorageLocations::load(&d), l);
    l.cache_folder = None;
    l.scratch_folder = None;
    l.save(&mut d);
    assert_eq!(StorageLocations::load(&d), StorageLocations::default());
    assert!(d.string(StorageLocationsKey::CACHE).is_none());
}

#[test]
fn relative_stored_paths_are_ignored() {
    let mut d = TestDefaults::default();
    d.set_string(StorageLocationsKey::SCRATCH, "relative");
    assert!(StorageLocations::load(&d).scratch_folder.is_none());
}

#[test]
fn windows_drive_paths_count_as_absolute() {
    for p in ["/Users/a", "C:/Users/a", "c:\\cache", "\\\\server\\share"] {
        assert!(StorageLocations::is_absolute_path(p), "{p}");
    }
    for p in ["", "rel", "C:", "C:rel", "1:/x"] {
        assert!(!StorageLocations::is_absolute_path(p), "{p}");
    }
}

#[test]
fn validation_accepts_writable_folder_with_space() {
    let dir = tmp();
    assert_eq!(StorageLocations::validate(&dir, 10, &|_| Some(1000)), None);
}

#[test]
fn validation_rejects_each_problem() {
    let dir = tmp();
    let file = dir.join("f.txt");
    std::fs::write(&file, b"x").unwrap();
    let plenty = |_: &Path| Some(1i64 << 40);
    assert_eq!(StorageLocations::validate(Path::new("rel"), 0, &plenty), Some(StorageProblem::NotAbsolute));
    assert_eq!(StorageLocations::validate(&file, 0, &plenty), Some(StorageProblem::NotAFolder));
    assert_eq!(
        StorageLocations::validate(&dir, 500, &|_| Some(100)),
        Some(StorageProblem::NotEnoughSpace { free: 100, needed: 500 })
    );
    assert_eq!(StorageLocations::validate(&dir, 500, &|_| None), None, "an unknown free size passes");
    assert!(StorageProblem::NotEnoughSpace { free: 100, needed: 500 }.message().starts_with("Only 100 bytes free"));
}

#[test]
fn validation_creates_a_missing_folder_under_a_writable_parent() {
    let sub = tmp().join("new/inner");
    assert_eq!(StorageLocations::validate(&sub, 0, &|_| Some(1i64 << 40)), None);
    assert!(sub.is_dir());
}

#[test]
fn migration_copies_and_never_deletes_or_overwrites() {
    let root = tmp();
    let (old, new) = (root.join("old"), root.join("new"));
    std::fs::create_dir_all(old.join("sub")).unwrap();
    std::fs::create_dir_all(&new).unwrap();
    std::fs::write(old.join("a.mov"), b"a").unwrap();
    std::fs::write(old.join("sub/b.mov"), b"b").unwrap();
    std::fs::write(old.join("clash.mov"), b"keep").unwrap();
    std::fs::write(new.join("clash.mov"), b"mine").unwrap();
    let r = StorageLocations::migrate(&old, &new);
    assert!(r.copied == 2 && r.skipped == 1 && r.failed == 0);
    assert!(new.join("sub/b.mov").exists());
    assert_eq!(std::fs::read(new.join("clash.mov")).unwrap(), b"mine");
    assert!(old.join("a.mov").exists(), "old data stays");
}

#[test]
fn migration_refuses_nested_or_identical_folders() {
    let root = tmp();
    let inner = root.join("inner");
    std::fs::create_dir_all(&inner).unwrap();
    std::fs::write(root.join("a.mov"), b"a").unwrap();
    assert_eq!(StorageLocations::migrate(&root, &root).copied, 0);
    assert_eq!(StorageLocations::migrate(&root, &inner).copied, 0);
    assert_eq!(StorageLocations::migrate(&inner, &root).copied, 0);
}

#[test]
fn app_settings_proxy_directory_follows_the_resolver() {
    let mut s = AppSettings::standard();
    s.cache_folder = Some(PathBuf::from("/x/y"));
    assert_eq!(s.proxy_cache_directory(&TestDefaults::default()), Path::new("/x/y/Proxies"));
}

#[test]
fn settings_locations_read_scratch_and_projects_picks() {
    let mut d = TestDefaults::default();
    StorageLocations::new(None, Some("/s".into()), Some("/p".into())).save(&mut d);
    let mut s = AppSettings::standard();
    s.cache_folder = Some(PathBuf::from("/c"));
    let l = s.locations(&d);
    assert!(
        l.cache_folder == Some(PathBuf::from("/c"))
            && l.scratch_root() == Path::new("/s")
            && l.projects_root() == Path::new("/p")
    );
}

#[test]
fn scratch_directory_is_created_under_the_root() {
    let root = tmp();
    let l = StorageLocations::new(None, Some(root.clone()), None);
    let u = l.scratch_directory("Pasted").unwrap();
    assert!(u.is_dir());
    assert_eq!(u, root.join("Pasted"));
}

// MARK: StorageFolderChoice (StorageFolderChoiceTests)

#[test]
fn an_app_that_moves_proxies_at_once_gets_both_folders_and_a_note_without_relaunch() {
    let mut d = TestDefaults::default();
    let root = tmp();
    let mut s = AppSettings::load(&d);
    s.cache_cap_gb = 0;
    let moved: RefCell<Vec<(PathBuf, PathBuf)>> = RefCell::new(Vec::new());
    let copied = Cell::new(0);
    let old = s.locations(&d).proxy_directory();
    let at_once = |o: &Path, n: &Path| moved.borrow_mut().push((o.to_path_buf(), n.to_path_buf()));
    let background = |_: &Path, _: &Path| copied.set(copied.get() + 1);
    let note = StorageFolderChoice::set_cache_folder(Some(&root), &mut s, &mut d, ProxyMove::AtOnce(&at_once));
    assert!(!note.contains("next launch"), "{note}");
    assert!(note.starts_with("Proxies already made are copied from"));
    let m = moved.borrow();
    assert_eq!(m.len(), 1);
    assert_eq!((&m[0].0, &m[0].1), (&old, &root.join("Proxies")));
    assert_eq!(copied.get(), 0);
    let back = StorageFolderChoice::set_cache_folder(None, &mut s, &mut d, ProxyMove::Background(&background));
    assert!(back.starts_with("Applies at the next launch"));
    assert_eq!(copied.get(), 1);
}

#[test]
fn set_folder_validates_then_saves() {
    let mut d = TestDefaults::default();
    let dir = tmp();
    assert_eq!(StorageFolderChoice::set_folder(true, Some(&dir), &mut d), None);
    assert_eq!(StorageLocations::load(&d).scratch_folder, Some(dir));
    assert_eq!(
        StorageFolderChoice::set_folder(false, Some(Path::new("rel")), &mut d),
        Some("Choose a folder on a disk.".to_string())
    );
    assert_eq!(StorageFolderChoice::set_folder(true, None, &mut d), None);
    assert!(StorageLocations::load(&d).scratch_folder.is_none());
}

#[test]
fn short_path_abbreviates_the_home_folder() {
    let home = std::env::var(if cfg!(windows) { "USERPROFILE" } else { "HOME" }).unwrap_or_default();
    if !home.is_empty() {
        let want = format!("~{}Movies", std::path::MAIN_SEPARATOR);
        assert_eq!(StorageFolderChoice::short_path(&Path::new(&home).join("Movies")), want);
    }
    assert_eq!(StorageFolderChoice::short_path(Path::new("/elsewhere/x")), "/elsewhere/x");
}

#[test]
fn short_path_uses_the_separator_it_is_given() {
    let (home, url) = (Path::new("/home/a"), Path::new("/home/a/AppData/Local/Sequence Studio"));
    assert_eq!(StorageFolderChoice::short_path_in(url, home, '\\'), "~\\AppData\\Local\\Sequence Studio");
    assert_eq!(StorageFolderChoice::short_path_in(url, home, '/'), "~/AppData/Local/Sequence Studio");
    assert_eq!(StorageFolderChoice::short_path_in(home, home, '\\'), "~");
}

// MARK: Preference lists

#[test]
fn audio_output_entries() {
    let devices = [AudioOutputDevice::new("a", "Speakers"), AudioOutputDevice::new("b", "USB")];
    let e = AudioOutputChoices::entries(&devices, Some("b"));
    assert_eq!(e.iter().map(|x| x.title.as_str()).collect::<Vec<_>>(), ["System Default", "Speakers", "USB"]);
    assert_eq!(AudioOutputChoices::index(Some("b"), &e), 2);
    assert_eq!(AudioOutputChoices::index(None, &e), 0);
    let gone = AudioOutputChoices::entries(&devices, Some("zz"));
    assert_eq!(gone.last().map(|x| x.title.as_str()), Some(AudioOutputChoices::NOT_CONNECTED));
    assert_eq!(AudioOutputChoices::index(Some("zz"), &gone), 3);
    assert_eq!(AudioOutputChoices::entries(&devices, Some("")).len(), 3);
}

#[test]
fn frame_cache_choices_start_with_auto() {
    use crate::es10_workspace::FrameCacheChoices;
    use sq_playback::engine::memory_budget::{GIB, MemoryBudget};
    let b = MemoryBudget::new(16 * GIB);
    let values = FrameCacheChoices::values(&b);
    let titles = FrameCacheChoices::titles(&b);
    assert_eq!(values[0], 0);
    assert_eq!(values.len(), titles.len());
    assert!(titles[0].starts_with("Auto (") && titles[1].ends_with(" GB"));
    assert_eq!(FrameCacheChoices::index(values[1], &b), 1);
    assert_eq!(FrameCacheChoices::index(9999, &b), 0);
}

#[test]
fn effect_defaults_list_is_grouped_and_sorted() {
    let mut e = EffectDefaults::default();
    assert!(EffectDefaultsGroup::ALL.iter().all(|g| e.entries_in(*g).is_empty()));
    assert!(
        EffectDefaultsGroup::Effects.title() == "Effects"
            && EffectDefaultsGroup::EMPTY_GROUP_TEXT.starts_with("None yet.")
    );
    let entry = EffectDefaultsEntry::Effect("gone".to_string());
    e.remove_entry(&entry); // no default of that kind: nothing happens
    assert!(e.entries_in(EffectDefaultsGroup::Effects).is_empty());
}

// MARK: Media, audio, card import, migration

#[test]
fn media_defaults_round_trip() {
    let mut d = TestDefaults::default();
    assert_eq!(MediaSettings::load(&d), MediaPolicyDefaults::default());
    let v = MediaPolicyDefaults { outside: OutsideMediaMode::Move, copy_library_items: false, watch_folder: false };
    MediaSettings::store(v, &mut d);
    assert_eq!(MediaSettings::load(&d), v);
    assert_eq!(d.string("sq.media.outside").as_deref(), Some("move"));
}

#[test]
fn card_import_and_de_click_default_on() {
    let mut d = TestDefaults::default();
    assert!(CardImportSettings::is_enabled(&d) && AudioPreferences::de_click(&d));
    CardImportSettings::set_enabled(false, &mut d);
    AudioPreferences::set_de_click(false, &mut d);
    assert!(!CardImportSettings::is_enabled(&d) && !AudioPreferences::de_click(&d));
}

#[test]
fn legacy_keys_are_moved_and_an_existing_new_value_wins() {
    let mut d = TestDefaults::default();
    d.set_string("ss.font", "Inter");
    d.set_integer("ss.n", 3);
    d.set_string("ss.both", "old");
    d.set_string("sq.both", "new");
    d.set_string("other", "x");
    let keys: Vec<String> = ["ss.font", "ss.n", "ss.both", "sq.both", "other"].iter().map(|s| s.to_string()).collect();
    assert_eq!(DefaultsMigration::migrate_legacy_keys(&mut d, &keys), 3);
    assert_eq!(d.string("sq.font").as_deref(), Some("Inter"));
    assert_eq!(d.integer("sq.n"), Some(3));
    assert_eq!(d.string("sq.both").as_deref(), Some("new"));
    assert!(!d.has("ss.font") && !d.has("ss.both") && d.has("other"));
    assert_eq!(DefaultsMigration::migrate_legacy_keys(&mut d, &[]), 0);
}

// MARK: Update check (UpdateCheckTests)

fn release_json(v: &str, url: &str) -> Vec<u8> {
    format!("{{\"version\":\"{v}\",\"url\":\"{url}\"}}").into_bytes()
}

#[test]
fn version_order() {
    assert!(UpdateCheck::is_newer("1.2.0", "1.1.9"));
    assert!(UpdateCheck::is_newer("v1.10", "1.9.3"));
    assert!(!UpdateCheck::is_newer("1.2", "1.2.0"));
    assert!(!UpdateCheck::is_newer("1.1", "1.2"));
    assert!(!UpdateCheck::is_newer("beta", "1.0"));
    assert!(UpdateCheck::is_newer("2.0.0-rc1", "1.9"));
}

#[test]
fn outcomes() {
    let rel = |v: &str, n: Option<&str>| UpdateRelease {
        version: v.to_string(),
        url: "https://example.org/dl".to_string(),
        notes: n.map(String::from),
    };
    assert_eq!(
        UpdateCheck::outcome(&release_json("1.0.1", "https://example.org/dl"), "1.0.0"),
        UpdateOutcome::Available(rel("1.0.1", None))
    );
    assert_eq!(
        UpdateCheck::outcome(&release_json("1.0.0", "https://example.org/dl"), "1.0.0"),
        UpdateOutcome::UpToDate
    );
    assert_eq!(UpdateCheck::outcome(b"nope", "1.0.0"), UpdateOutcome::Failed);
    assert_eq!(UpdateCheck::outcome(&release_json("2.0", "http://insecure"), "1.0"), UpdateOutcome::Failed);
}

const GITHUB: &[u8] = br#"{"tag_name":"v1.4.0","html_url":"https://github.com/paulherter/sequence-studio/releases/tag/v1.4.0","body":" Fixes ",
 "assets":[{"name":"SequenceStudio-1.4.0.dmg","browser_download_url":"https://example.org/a.dmg"},
           {"name":"SequenceStudio-Setup-1.4.0.EXE","browser_download_url":"https://example.org/Setup.exe"},
           {"name":"SequenceStudio-1.4.0-x86_64.AppImage","browser_download_url":"https://example.org/a.AppImage"}]}"#;

#[test]
fn github_release_uses_installer_asset_of_this_system() {
    let exe = UpdateCheck::github_release(GITHUB, ".exe");
    assert_eq!(
        exe,
        Some(UpdateRelease {
            version: "v1.4.0".into(),
            url: "https://example.org/Setup.exe".into(),
            notes: Some("Fixes".into())
        })
    );
    assert_eq!(
        UpdateCheck::github_release(GITHUB, ".dmg").map(|r| r.url).as_deref(),
        Some("https://example.org/a.dmg")
    );
    assert_eq!(
        UpdateCheck::github_release(GITHUB, ".zip").map(|r| r.url).as_deref(),
        Some("https://github.com/paulherter/sequence-studio/releases/tag/v1.4.0")
    );
    let linux = br#"{"tag_name":"v2.0.0","html_url":"https://example.org/r","assets":[{"name":"SequenceStudio-2.0.0.dmg","browser_download_url":"https://example.org/a.dmg"},{"name":"SequenceStudio-2.0.0-x86_64.AppImage","browser_download_url":"https://example.org/a.AppImage"}]}"#;
    let suffix = Platform::Linux.update_asset().suffix();
    assert_eq!(
        UpdateCheck::github_release(linux, suffix).map(|r| r.url).as_deref(),
        Some("https://example.org/a.AppImage")
    );
    let mac = Platform::Mac.update_asset().suffix();
    assert_eq!(UpdateCheck::github_release(linux, mac).map(|r| r.url).as_deref(), Some("https://example.org/a.dmg"));
    assert_ne!(UpdateCheck::outcome(GITHUB, "1.3.9"), UpdateOutcome::Failed);
    assert_eq!(UpdateCheck::outcome(GITHUB, "1.4.0"), UpdateOutcome::UpToDate);
    assert_eq!(UpdateCheck::github_release(br#"{"message":"Not Found"}"#, UpdateCheck::installer_suffix()), None);
}

#[test]
fn each_system_downloads_its_own_installer_asset() {
    assert_eq!(
        UpdateCheck::github_release(GITHUB, ".appimage").map(|r| r.url).as_deref(),
        Some("https://example.org/a.AppImage")
    );
    let expected = if cfg!(windows) {
        "https://example.org/Setup.exe"
    } else if cfg!(target_os = "linux") {
        "https://example.org/a.AppImage"
    } else {
        "https://example.org/a.dmg"
    };
    // The whole path the Download button takes: feed document, outcome, `UpdateRelease.url`.
    assert_eq!(
        UpdateCheck::outcome(GITHUB, "1.3.9"),
        UpdateOutcome::Available(UpdateRelease {
            version: "v1.4.0".into(),
            url: expected.into(),
            notes: Some("Fixes".into())
        })
    );
}

#[test]
fn default_address_is_github_releases() {
    assert_eq!(
        UpdateCheck::DEFAULT_FEED_URL,
        "https://api.github.com/repos/paulherter/sequence-studio/releases/latest"
    );
    let d = TestDefaults::default();
    assert!(UpdateCheck::feed_url(&d) == UpdateCheck::DEFAULT_FEED_URL || std::env::var("SQ_UPDATE_URL").is_ok());
}

/// Runs a future that never waits on anything.
fn block_on<F: std::future::Future>(f: F) -> F::Output {
    let waker = std::task::Waker::noop();
    let mut cx = std::task::Context::from_waker(waker);
    let mut f = std::pin::pin!(f);
    loop {
        if let std::task::Poll::Ready(v) = f.as_mut().poll(&mut cx) {
            return v;
        }
    }
}

#[test]
fn empty_address_is_inert_and_never_fetches() {
    let fetched = Cell::new(false);
    let o = block_on(UpdateCheck::check("1.0", "", |_| {
        fetched.set(true);
        async { Some(Vec::new()) }
    }));
    assert_eq!(o, UpdateOutcome::NotConfigured);
    assert!(!fetched.get());
}

#[test]
fn fetches_configured_address() {
    let o = block_on(UpdateCheck::check("1.0", "https://example.org/u.json", |_| async {
        Some(release_json("1.1", "https://example.org/dl"))
    }));
    assert!(matches!(o, UpdateOutcome::Available(r) if r.version == "1.1"));
    let failed = block_on(UpdateCheck::check("1.0", "https://example.org/u.json", |_| async { None }));
    assert_eq!(failed, UpdateOutcome::Failed);
}

// MARK: Onboarding and keyboard picture

#[test]
fn onboarding_keys_follow_the_platform() {
    let mac = OnboardingContent::tips_for(Platform::Mac);
    let win = OnboardingContent::tips_for(Platform::Windows);
    assert_eq!(mac.len(), 5);
    assert!(mac[0].detail.contains("Cmd+I") && win[0].detail.contains("Ctrl+I"));
    assert!(mac[4].detail.starts_with("Cmd+M") && win[4].detail.starts_with("Ctrl+M"));
    assert_eq!(OnboardingContent::TITLE, "Welcome to Sequence Studio");
}

#[test]
fn keyboard_rows_are_centered_and_sized() {
    for style in KeyboardStyle::ALL {
        let caps = KeyboardLayout::caps(style);
        assert!(caps.iter().all(|c| c.x >= 0.0
            && c.x + c.w <= KeyboardLayout::WIDTH + 1e-9
            && c.y + c.h <= KeyboardLayout::HEIGHT + 1e-9));
        let letters =
            caps.iter().filter(|c| c.label.len() == 1 && c.label.chars().all(|ch| ch.is_ascii_alphabetic())).count();
        assert_eq!(letters, 26);
        assert!(caps.iter().any(|c| c.key == Some(Key::Space)));
    }
    let de = KeyboardLayout::caps(KeyboardStyle::German);
    assert!(de.iter().any(|c| c.label == "Z" && c.key == Some(Key::Char('z'))));
    assert!(de.iter().any(|c| c.is_ghost));
    assert!(!KeyboardLayout::caps(KeyboardStyle::Us).iter().any(|c| c.is_ghost));
    assert_eq!(KeyboardLayout::HEIGHT, 5.0 * 42.0 + 4.0 * 6.0);
}

#[test]
fn keyboard_style_follows_locale_and_saved_choice() {
    assert_eq!(KeyboardStyle::for_locale("de_AT.UTF-8"), KeyboardStyle::German);
    assert_eq!(KeyboardStyle::for_locale("en_US.UTF-8"), KeyboardStyle::Us);
    assert_eq!(KeyboardStyle::for_locale(""), KeyboardStyle::Us);
    assert_eq!(KeyboardStyle::German.title(), "Layout: German");
    let mut d = TestDefaults::default();
    d.set_string(KeyboardStyle::DEFAULTS_KEY, "german");
    assert_eq!(KeyboardStyle::saved(&d), KeyboardStyle::German);
}

#[test]
fn layout_model_lists_bindings_global_first() {
    let b = KeyBinding::new(Key::Char('c'), KeyModifiers::default());
    let entries = vec![
        Entry { scope: CommandScope::Timeline, binding: b, command: EditorCommand::Undo },
        Entry { scope: CommandScope::Global, binding: b, command: EditorCommand::Redo },
    ];
    let m = KeyboardLayoutModel::new(CommandMap::new(entries), KeyModifiers::default());
    let found = m.entries(Key::Char('c'));
    assert_eq!(found.iter().map(|e| e.scope).collect::<Vec<_>>(), [CommandScope::Global, CommandScope::Timeline]);
    assert!(m.group(Key::Char('c')).is_some() && m.group(Key::Char('x')).is_none());
    assert!(m.summary(Key::Char('x'), Platform::Mac).ends_with(": free"));
    assert!(m.summary(Key::Char('c'), Platform::Mac).contains('('));
    let _ = Id::parse("");
}
