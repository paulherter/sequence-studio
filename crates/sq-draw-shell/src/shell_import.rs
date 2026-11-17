// Swift: ShellImport.swift
//! File > Import… and the Premiere project import, translated from the Mac `AppController+ImportAnything` and
//! `AppController+PremiereImport`: one entry for every file kind, media into the Project panel's model (the probe is the
//! platform's: `MediaImporter` on the Mac, `FFmpegMediaProbe` on Windows), a .prproj through the Premiere importer.

use crate::shell_flows::ShellRoot;
use crate::shell_host::{ShellEvent, ShellFlow, ShellHost};
use crate::shell_interchange::ImportFailure;
use sq_core_file::{FILE_EXTENSION, LEGACY_FILE_EXTENSIONS};
use sq_editor_session::{PlaceOptions, ProjectPanelModel};
use sq_library::library_item_kind::LibraryItemKind;
use sq_premiere_import::prdocument::PRReader;
use sq_premiere_import::prmapper::PRMapper;
use sq_runtime::UiRef;
use sq_uikit::localization::SQL10n;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

/// What a file chosen for import is (`AppController.ImportKind.of`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ShellImportKind {
    /// An EDL, FCPXML, Final Cut XML or OpenTimelineIO file.
    Timeline,
    /// A Premiere project.
    PremiereProject,
    /// Premiere effect presets.
    PremierePresets,
    /// A Motion Graphics Template.
    MotionGraphicsTemplate,
    /// A Lottie animation.
    Lottie,
    /// A subtitle file (.srt, .vtt, .ass, .ssa): becomes captions on the caption track.
    Subtitles,
    /// Anything else: media.
    Media,
}

impl ShellImportKind {
    /// `AppController.ImportKind.of` unchanged.
    pub fn of(url: &Path) -> ShellImportKind {
        match url.extension().map(|e| e.to_string_lossy().to_lowercase()).as_deref() {
            Some("edl" | "fcpxml" | "fcpxmld" | "xml" | "otio") => ShellImportKind::Timeline,
            Some("prproj") => ShellImportKind::PremiereProject,
            Some("prfpset") => ShellImportKind::PremierePresets,
            Some("mogrt") => ShellImportKind::MotionGraphicsTemplate,
            Some("json") => ShellImportKind::Lottie,
            Some("srt" | "vtt" | "ass" | "ssa") => ShellImportKind::Subtitles,
            _ => ShellImportKind::Media,
        }
    }
}

/// `ProjectFile.isProjectURL`: a Sequence Studio project file (current or legacy extension).
fn is_project_url(url: &Path) -> bool {
    url.extension()
        .map(|e| e.to_string_lossy().to_lowercase())
        .is_some_and(|e| e == FILE_EXTENSION || LEGACY_FILE_EXTENSIONS.contains(&e.as_str()))
}

/// Media files below `dir`, depth first in name order, each with the bin path that mirrors its folders (the dropped folder
/// is the first bin). Hidden items, symlinked folders and files that are not media are skipped.
// shortcut: walks the disk on the UI thread; upgrade to the worker pool when a card with 10k files shows up.
fn expand_folder(dir: &Path, bin: &mut Vec<String>, out: &mut Vec<(PathBuf, Vec<String>)>) {
    let Ok(read) = std::fs::read_dir(dir) else { return };
    let mut entries: Vec<_> = read.flatten().collect();
    entries.sort_by_key(|e| e.file_name());
    for entry in entries {
        let path = entry.path();
        let name = entry.file_name().to_string_lossy().into_owned();
        if name.starts_with('.') {
            continue;
        }
        let Ok(kind) = entry.file_type() else { continue };
        if kind.is_dir() {
            bin.push(name);
            expand_folder(&path, bin, out);
            bin.pop();
        } else if (kind.is_file() || path.is_file())
            && matches!(
                LibraryItemKind::classify_if_visible(&path, false),
                Some(
                    LibraryItemKind::Video | LibraryItemKind::Audio | LibraryItemKind::Image | LibraryItemKind::Overlay
                )
            )
        {
            out.push((path, bin.clone()));
        }
    }
}

impl ShellHost {
    /// File > Import… (Ctrl+I): the chooser, then `import_mixed`.
    pub async fn import_anything<R: ShellRoot + ?Sized>(h: UiRef<R>) {
        let Some(ask) = h.with(|r| r.shell_parts().files.choose_media()) else { return };
        let urls = ask.await;
        if urls.is_empty() {
            return;
        }
        Self::import_mixed(h, urls).await;
    }

    /// Splits the files by kind (the Mac `importMixed`); also the target of Explorer drops on the window. The media go to
    /// the Project panel first; the other kinds follow one after the other (Swift started each as its own task).
    pub async fn import_mixed<R: ShellRoot + ?Sized>(h: UiRef<R>, urls: Vec<PathBuf>) {
        let mut media: Vec<PathBuf> = Vec::new();
        let mut others: Vec<(ShellImportKind, PathBuf)> = Vec::new();
        let mut placements: Vec<(PathBuf, Vec<String>)> = Vec::new();
        for url in urls {
            if url.is_dir() {
                let name = url.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
                let mut found = Vec::new();
                expand_folder(&url, &mut vec![name], &mut found);
                media.extend(found.iter().map(|(p, _)| p.clone()));
                placements.extend(found);
                continue;
            }
            if is_project_url(&url) {
                media.push(url);
                continue;
            }
            match ShellImportKind::of(&url) {
                ShellImportKind::Media => media.push(url),
                kind => others.push((kind, url)),
            }
        }
        for (kind, url) in others {
            match kind {
                ShellImportKind::PremiereProject => Self::import_premiere_project(h.clone(), url).await,
                ShellImportKind::Timeline => Self::import_timeline(h.clone(), url).await,
                ShellImportKind::PremierePresets => Self::import_premiere_presets(h.clone(), url, true).await,
                ShellImportKind::MotionGraphicsTemplate => {
                    Self::import_motion_graphics_templates(h.clone(), vec![url]).await
                }
                ShellImportKind::Lottie => {
                    let _ = h.with(|r| {
                        let p = r.shell_parts();
                        p.shell.import_lottie(p.session, &url);
                    });
                }
                ShellImportKind::Subtitles => {
                    let _ = h.with(|r| {
                        let p = r.shell_parts();
                        p.shell.import_subtitles(p.session, &url);
                    });
                }
                ShellImportKind::Media => {}
            }
        }
        if !media.is_empty() {
            Self::import_media(h.clone(), media, false).await;
            Self::say_already_in_project(&h);
            if !placements.is_empty() {
                let _ = h.with(|r| {
                    let (panel, session) = r.panel_parts();
                    panel.file_into_bins(session, &placements);
                });
            }
            let _ = h.with(|r| r.shell_parts().shell.emit(ShellEvent::ProjectChanged));
        }
    }

    /// Files the import could not take (unreadable, a codec we cannot decode, no sound) get a dialog that names each file and
    /// why: the report was built but nothing showed it, so a corrupt file just vanished from the batch.
    pub(crate) fn say_import_failures<R: ShellRoot + ?Sized>(h: &UiRef<R>) {
        let _ = h.with(|r| {
            let notice = r.panel_parts().0.last_import_report().and_then(|report| report.failure_notice());
            if let Some((title, detail)) = notice {
                r.shell_parts().shell.present_message(&title, &detail, Some(crate::shell_dialog::Tone::Warning));
            }
        });
    }

    /// An import that skipped files the project already has says so in the status line (nothing else would show it).
    fn say_already_in_project<R: ShellRoot + ?Sized>(h: &UiRef<R>) {
        let _ = h.with(|r| {
            // Same path (`already_in_project`) or another spelling of it that names the same file (`duplicates`, e.g.
            // `C:\\a.mp4` against `c:/a.mp4`): both are "already in the project" for the user.
            let panel = r.panel_parts().0;
            let mut names = panel.already_in_project().to_vec();
            if let Some(report) = panel.last_import_report() {
                names.extend(report.duplicates.iter().filter(|d| !names.contains(d)).cloned().collect::<Vec<_>>());
            }
            let line = match names.as_slice() {
                [] => return,
                [one] => SQL10n::format("Already in the project: %@", &[one]),
                many => SQL10n::format("Already in the project: %@ files", &[&many.len().to_string()]),
            };
            r.shell_parts().shell.emit(ShellEvent::Status(line));
        });
    }

    /// Imports `urls` (a file already in the project is reused) and places the media as one drop (`options.at` none = the
    /// playhead).
    pub async fn place_files<R: ShellRoot + ?Sized>(h: UiRef<R>, urls: Vec<PathBuf>, options: PlaceOptions) {
        ProjectPanelModel::import_files(h.clone(), urls.clone()).await;
        let plan = Self::plan_outside(h.clone(), false).await;
        Self::say_already_in_project(&h);
        Self::say_import_failures(&h);
        let ids: Vec<_> = h
            .with(|r| {
                let (panel, _) = r.panel_parts();
                urls.iter().filter_map(|u| panel.media_id_for_imported(u)).collect()
            })
            .unwrap_or_default();
        if !ids.is_empty() {
            Self::place_media_asking(h.clone(), ids, options).await;
        }
        if let Some(plan) = plan {
            Self::run_outside(h, plan).await;
        }
    }

    /// File > Import Premiere Project…: the chooser, then `import_premiere_project`.
    pub async fn choose_and_import_premiere_project<R: ShellRoot + ?Sized>(h: UiRef<R>) {
        let Some(ask) = h.with(|r| {
            r.shell_parts().files.choose_file(&SQL10n::string("Choose a Premiere Pro project (.prproj)"), None)
        }) else {
            return;
        };
        let Some(url) = ask.await else { return };
        Self::import_premiere_project(h, url).await;
    }

    /// The Mac `importPremiereProject(at:)`: read, resolve the stored media paths, probe what was found, map, open.
    pub async fn import_premiere_project<R: ShellRoot + ?Sized>(h: UiRef<R>, url: PathBuf) {
        let name = url.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        if url.extension().map(|e| e.to_string_lossy().to_lowercase()).as_deref() != Some("prproj") {
            let _ = h.with(|r| {
                r.shell_parts().shell.present_error(
                    &SQL10n::format("“%@” is not a Premiere project", &[&name]),
                    &ImportFailure("This is not a Premiere Pro project.".to_string()),
                );
            });
            return;
        }
        let Some(running) = h.with(|r| {
            let p = r.shell_parts();
            if p.shell.flow_env.import_running {
                p.shell.flash("An import is already running.");
                return true;
            }
            p.shell.flow_env.import_running = true;
            false
        }) else {
            return;
        };
        if running {
            return;
        }
        Self::run_import_premiere_project(h.clone(), &url, &name).await;
        let _ = h.with(|r| r.shell_parts().shell.flow_env.import_running = false);
    }

    async fn run_import_premiere_project<R: ShellRoot + ?Sized>(h: UiRef<R>, url: &Path, name: &str) {
        if !Self::confirm_discard_changes(h.clone()).await {
            return;
        }
        let _ = h.with(|r| {
            r.shell_parts().shell.emit(ShellEvent::Status(SQL10n::format("Importing %@…", &[name])));
        });
        let read = |url: PathBuf| -> Result<_, ImportFailure> {
            let data = std::fs::read(&url).map_err(|e| ImportFailure(e.to_string()))?;
            let doc = PRReader::read(&data).map_err(|e| ImportFailure(e.to_string()))?;
            let resolved = PRMapper::resolve_media(&doc, &url, Vec::new());
            Ok((doc, resolved))
        };
        let pool = h.with(|r| r.shell_parts().shell.flow_env.services.worker_pool()).flatten();
        let result = match pool {
            Some(pool) => {
                let u = url.to_path_buf();
                match pool.run(move |_| read(u)).await {
                    Ok(r) => r,
                    Err(_) => return,
                }
            }
            // shortcut: the file is read on the UI thread when the app provides no worker pool.
            None => read(url.to_path_buf()),
        };
        let (doc, resolved) = match result {
            Ok(r) => r,
            Err(e) => {
                let _ = h.with(|r| {
                    r.shell_parts().shell.present_error(&SQL10n::format("Could not import “%@”", &[name]), &e);
                });
                return;
            }
        };
        let mut refs: BTreeMap<String, sq_core_model::MediaRef> = BTreeMap::new();
        for stored in PRMapper::media_paths(&doc) {
            let Some(hit) = resolved.get(&stored) else { continue };
            let Some(ask) = h.with(|r| r.shell_parts().shell.flow_env.services.probe(Path::new(&hit.path))).flatten()
            else {
                break;
            };
            if let Some(m) = ask.await {
                refs.insert(stored, m);
            }
        }
        let stem = url.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
        let _ = h.with(|r| {
            let p = r.shell_parts();
            let result = PRMapper::map(&doc, &stem, &refs, false, &mut *p.shell.ids);
            p.session.new_project(result.project);
            p.shell.emit(ShellEvent::ProjectChanged);
            let (approx, dropped) = Self::approximated_and_dropped(&result.report);
            p.shell.emit(ShellEvent::Status(SQL10n::format(
                "Imported %@: %@ approximated, %@ dropped items.",
                &[name, &approx.to_string(), &dropped.to_string()],
            )));
            p.shell.remember_import(result.report.clone(), p.session.project(), name);
            // The Mac shows the checklist when something needs a look, then offers Reconnect Media for what is missing.
            if p.shell.import_card_due(p.session) {
                p.shell.start_flow(ShellFlow::ImportCard);
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tests::Rig;

    /// One 5 s video item on a "Main" sequence whose media file does not exist (offline until relinked).
    fn tiny_prproj() -> String {
        let s = 254_016_000_000i64;
        format!(
            "<?xml version=\"1.0\" encoding=\"UTF-8\" ?>\n<PremiereData Version=\"3\">\n\
<Media ObjectUID=\"M1\" Version=\"30\"><ActualMediaFilePath>/nowhere/a.mov</ActualMediaFilePath><FilePath>/nowhere/a.mov</FilePath><Title>a.mov</Title></Media>\n\
<VideoComponentChain ObjectID=\"2\"><ComponentChain><Components></Components></ComponentChain></VideoComponentChain>\n\
<VideoMediaSource ObjectID=\"3\"><MediaSource><Media ObjectURef=\"M1\"/></MediaSource></VideoMediaSource>\n\
<VideoClip ObjectID=\"4\"><Clip><Source ObjectRef=\"3\"/><InPoint>0</InPoint><OutPoint>{o}</OutPoint></Clip></VideoClip>\n\
<SubClip ObjectID=\"5\"><Clip ObjectRef=\"4\"/><Name>a</Name></SubClip>\n\
<VideoClipTrackItem ObjectID=\"6\"><ClipTrackItem><ComponentOwner><Components ObjectRef=\"2\"/></ComponentOwner><TrackItem><Node/><Start>0</Start><End>{o}</End></TrackItem><SubClip ObjectRef=\"5\"/></ClipTrackItem></VideoClipTrackItem>\n\
<VideoClipTrack ObjectUID=\"T1\"><ClipTrack><Track><ID>1</ID></Track><ClipItems><TrackItems><TrackItem Index=\"0\" ObjectRef=\"6\"/></TrackItems></ClipItems><TransitionItems><TrackItems></TrackItems></TransitionItems></ClipTrack></VideoClipTrack>\n\
<VideoTrackGroup ObjectID=\"7\"><TrackGroup><Tracks><Track Index=\"0\" ObjectURef=\"T1\"/></Tracks><FrameRate>8467200000</FrameRate></TrackGroup><FrameRect>0,0,1920,1080</FrameRect></VideoTrackGroup>\n\
<AudioTrackGroup ObjectID=\"8\"><TrackGroup><Tracks></Tracks><FrameRate>5292000</FrameRate></TrackGroup></AudioTrackGroup>\n\
<Sequence ObjectUID=\"S1\"><Name>Main</Name><TrackGroups><TrackGroup Index=\"0\"><First>a</First><Second ObjectRef=\"7\"/></TrackGroup><TrackGroup Index=\"1\"><First>b</First><Second ObjectRef=\"8\"/></TrackGroup></TrackGroups></Sequence>\n\
</PremiereData>\n",
            o = 5 * s
        )
    }

    #[test]
    fn the_menu_command_imports_a_chosen_prproj_and_shows_the_card() {
        let dir = std::env::temp_dir().join(format!("sq-prproj-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("dir");
        let file = dir.join("Cut.prproj");
        std::fs::write(&file, tiny_prproj()).expect("write");
        let rig = Rig::new();
        rig.with(|r| r.files.file = Some(file.clone()));
        assert!(rig.execute(sq_uikit::editor_command::EditorCommand::ImportPremiereProject));
        rig.run_flows();
        rig.run_flows(); // the card the import started
        let names: Vec<String> = rig.with(|r| r.session.project().timelines.iter().map(|t| t.name.clone()).collect());
        assert_eq!(names, ["Main"], "the sequence of the Premiere project is the open project");
        assert!(rig.with(|r| r.shell.flow_env.import_checklist.is_some()), "the checklist is kept");
        assert!(rig.with(|r| r.session.can_relink()), "the offline media can be reconnected");
        assert!(rig.has_dialog(), "the import card is up");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_subtitle_file_in_import_becomes_captions() {
        assert_eq!(ShellImportKind::of(Path::new("/x/Talk.SRT")), ShellImportKind::Subtitles);
        let dir = std::env::temp_dir().join(format!("sq-subs-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("dir");
        let file = dir.join("talk.srt");
        std::fs::write(&file, "1\n00:00:01,000 --> 00:00:02,000\nHello\n\n2\n00:00:03,000 --> 00:00:04,000\nWorld\n")
            .expect("write");
        let rig = Rig::new();
        rig.rt.ex.spawn_local(ShellHost::import_mixed(rig.handle(), vec![file]));
        rig.rt.run_until_stalled();
        let captions: usize = rig.with(|r| {
            r.session.active_timeline().map_or(0, |t| t.caption_tracks.iter().map(|c| c.items().len()).sum())
        });
        assert_eq!(captions, 2);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn importing_a_file_the_project_already_has_says_so() {
        let rig = Rig::new();
        let url = PathBuf::from("/x/a.mov");
        let run = |rig: &Rig| {
            rig.rt.ex.spawn_local(ShellHost::import_mixed(rig.handle(), vec![url.clone()]));
            rig.rt.run_until_stalled();
            rig.with(|r| r.shell.take_events())
                .into_iter()
                .filter_map(|e| if let ShellEvent::Status(s) = e { Some(s) } else { None })
                .collect::<Vec<_>>()
        };
        rig.with(|r| {
            let mut project = r.session.project().clone();
            let media = sq_core_model::MediaRef::new(
                sq_core_time::Id::from_u128(5),
                "a.mov",
                "/x/a.mov",
                sq_core_model::MediaFingerprint::new(1),
            );
            project.media = vec![media].into();
            r.panel =
                sq_editor_session::ProjectPanelModel::new(project, sq_editor_session::ProjectPanelDeps::headless());
        });
        assert_eq!(run(&rig), ["Already in the project: a.mov"]);
        rig.with(|r| {
            r.panel = sq_editor_session::ProjectPanelModel::new(
                r.session.project().clone(),
                sq_editor_session::ProjectPanelDeps::headless(),
            )
        });
        assert!(run(&rig).is_empty(), "a new file is not reported as known");
    }

    /// Another spelling of a path the project has (the Windows drop gives `C:\\A.MP4` for a stored `c:/a.mp4`) is
    /// caught by the file identity, not the path compare: the user still hears "Already in the project".
    #[test]
    fn another_spelling_of_a_known_file_says_so_too() {
        struct SameFile;
        impl sq_editor_session::ImportBackend for SameFile {
            fn probe(&self, _: &Path) -> Result<sq_core_model::MediaRef, sq_editor_session::ImportError> {
                Err(sq_editor_session::ImportError::Failed("no".into()))
            }
            fn file_identity(&self, p: &Path) -> Option<String> {
                Some(p.to_string_lossy().replace('\\', "/").to_lowercase())
            }
        }
        let rig = Rig::new();
        // The file identity is read on the pool (as the probes are), which the rig steps.
        let pool = std::sync::Arc::clone(&rig.rt.pool);
        rig.with(|r| {
            let mut project = r.session.project().clone();
            let media = sq_core_model::MediaRef::new(
                sq_core_time::Id::from_u128(5),
                "a.mov",
                "/x/a.mov",
                sq_core_model::MediaFingerprint::new(1),
            );
            project.media = vec![media].into();
            let deps = sq_editor_session::ProjectPanelDeps {
                backend: std::sync::Arc::new(SameFile),
                pool: std::sync::Arc::clone(&pool),
                ..sq_editor_session::ProjectPanelDeps::headless()
            };
            r.panel = sq_editor_session::ProjectPanelModel::new(project, deps);
        });
        rig.rt.ex.spawn_local(ShellHost::import_mixed(rig.handle(), vec![PathBuf::from("/X/A.MOV")]));
        rig.rt.run_until_stalled();
        let lines: Vec<String> = rig
            .with(|r| r.shell.take_events())
            .into_iter()
            .filter_map(|e| if let ShellEvent::Status(s) = e { Some(s) } else { None })
            .collect();
        assert_eq!(lines, ["Already in the project: A.MOV"]);
    }

    /// A corrupt file among good ones used to vanish without a word: the report knew, nothing showed it.
    #[test]
    fn a_file_that_cannot_be_read_is_named_with_its_reason() {
        struct Unreadable;
        impl sq_editor_session::ImportBackend for Unreadable {
            fn probe(&self, _: &Path) -> Result<sq_core_model::MediaRef, sq_editor_session::ImportError> {
                Err(sq_editor_session::ImportError::Failed("no".into()))
            }
        }
        let rig = Rig::new();
        let pool = std::sync::Arc::clone(&rig.rt.pool);
        rig.with(|r| {
            let deps = sq_editor_session::ProjectPanelDeps {
                backend: std::sync::Arc::new(Unreadable),
                pool,
                ..sq_editor_session::ProjectPanelDeps::headless()
            };
            r.panel = sq_editor_session::ProjectPanelModel::new(r.session.project().clone(), deps);
        });
        rig.rt.ex.spawn_local(ShellHost::import_mixed(rig.handle(), vec![PathBuf::from("/x/corrupt.mp4")]));
        rig.rt.run_until_stalled();
        let dialog = rig.with(|r| r.shell.dialog().map(|d| (d.message_text.clone(), d.informative_text.clone())));
        let (title, detail) = dialog.expect("the import tells what it skipped");
        assert_eq!(title, "Could not import \u{201C}corrupt.mp4\u{201D}");
        assert!(detail.contains("corrupt.mp4: "), "{detail}");
    }

    #[test]
    fn kinds_follow_the_extension() {
        let kind = |p: &str| ShellImportKind::of(Path::new(p));
        assert_eq!(kind("/a/cut.EDL"), ShellImportKind::Timeline);
        assert_eq!(kind("/a/cut.fcpxmld"), ShellImportKind::Timeline);
        assert_eq!(kind("/a/p.prproj"), ShellImportKind::PremiereProject);
        assert_eq!(kind("/a/p.prfpset"), ShellImportKind::PremierePresets);
        assert_eq!(kind("/a/t.mogrt"), ShellImportKind::MotionGraphicsTemplate);
        assert_eq!(kind("/a/l.json"), ShellImportKind::Lottie);
        assert_eq!(kind("/a/clip.mov"), ShellImportKind::Media);
        assert_eq!(kind("/a/noext"), ShellImportKind::Media);
    }

    #[test]
    fn folders_expand_to_media_with_mirrored_bins() {
        let root = std::env::temp_dir().join(format!("sq-expand-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let dir = root.join("Shoot");
        std::fs::create_dir_all(dir.join("day1/.cache")).unwrap_or_default();
        std::fs::create_dir_all(dir.join(".hidden")).unwrap_or_default();
        for f in [
            "b.mp4",
            "a.wav",
            "notes.txt",
            ".dot.mp4",
            "day1/c.mov",
            "day1/d.png",
            "day1/.cache/e.mp4",
            ".hidden/f.mp4",
        ] {
            std::fs::write(dir.join(f), b"x").unwrap_or_default();
        }
        let mut found = Vec::new();
        expand_folder(&dir, &mut vec!["Shoot".to_string()], &mut found);
        let _ = std::fs::remove_dir_all(&root);
        let shown: Vec<(String, String)> = found
            .iter()
            .map(|(p, bin)| {
                (p.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default(), bin.join("/"))
            })
            .collect();
        let expect = [("a.wav", "Shoot"), ("b.mp4", "Shoot"), ("c.mov", "Shoot/day1"), ("d.png", "Shoot/day1")];
        assert_eq!(shown, expect.map(|(a, b)| (a.to_string(), b.to_string())));
    }

    #[test]
    fn project_files_are_media_for_the_panel() {
        assert!(is_project_url(Path::new("/a/p.sqproj")));
        assert!(is_project_url(Path::new("/a/p.SSPROJ")));
        assert!(!is_project_url(Path::new("/a/p.json")));
    }
}
