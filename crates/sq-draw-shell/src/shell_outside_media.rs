// Swift: App/Sources/MediaPlacement.swift (the AppKit shell's MediaPlacementController and MediaPlacementPrompt, removed with the AppKit UI)
//! The project's "Outside files" setting at import. Every import path ends in `import_media`: the files land in the bin
//! at their own place first (the clip is usable at once), then the files outside the project folder are asked about,
//! copied into `Files/Imported/` on a worker and the clips are pointed at the verified copies without an undo step.
//! Library items are copied into `Files/Library/` and never asked about; files inside the project folder are never touched.

use crate::shell_dialog::ShellDialog;
use crate::shell_flows::ShellRoot;
use crate::shell_form::{Row, ShellForm};
use crate::shell_host::{ShellEvent, ShellHost};
use sq_core_model::ImportMode;
use sq_core_time::Id;
use sq_editor_session::{ImportedFile, ProjectPanelModel};
use sq_media::media_file_ops::{IngestResult, MediaFileOps, MediaManagement};
use sq_media::media_placement::Disposition;
use sq_runtime::UiRef;
use sq_uikit::localization::SQL10n;
use sq_uikit::sqdialog_model::{SQDialogResponse, SQDialogRole};
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

/// The key of the answer Return takes the next time (Swift `sq.mediaPlacement.lastChoice`).
const LAST_CHOICE_KEY: &str = "sq.mediaPlacement.lastChoice";

/// The three answers of the question.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Choice {
    Copy,
    Move,
    Leave,
}

impl Choice {
    const ALL: [Choice; 3] = [Choice::Copy, Choice::Move, Choice::Leave];

    fn raw(self) -> &'static str {
        match self {
            Choice::Copy => "copy",
            Choice::Move => "move",
            Choice::Leave => "leave",
        }
    }

    fn from_raw(raw: &str) -> Option<Choice> {
        Self::ALL.into_iter().find(|c| c.raw() == raw)
    }

    fn mode(self) -> sq_core_model::OutsideMediaMode {
        match self {
            Choice::Copy => sq_core_model::OutsideMediaMode::Copy,
            Choice::Move => sq_core_model::OutsideMediaMode::Move,
            Choice::Leave => sq_core_model::OutsideMediaMode::Leave,
        }
    }
}

/// One file to bring into the project.
#[derive(Clone, Debug, PartialEq, Eq)]
struct Job {
    id: Id,
    source: PathBuf,
    /// A Library item (`Files/Library/`, deduplicated by content) rather than an import (`Files/Imported/`).
    library: bool,
}

/// What the import left to do: the copies to make once the clips are placed.
#[derive(Debug)]
pub(crate) struct OutsidePlan {
    project_id: Id,
    project_url: PathBuf,
    jobs: Vec<Job>,
    /// Items whose original goes to the Trash after the next save that contains the copy.
    moves: BTreeSet<Id>,
}

impl OutsidePlan {
    fn is_empty(&self) -> bool {
        self.jobs.is_empty()
    }
}

/// An original that is trashed once a save holds the copy.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct PendingMove {
    id: Id,
    original: PathBuf,
    copy: PathBuf,
}

/// Shell state of the outside-files handling.
#[derive(Debug, Default)]
pub struct OutsideMediaState {
    /// The Library folders (the app keeps this current): their files are Library items.
    pub library_roots: Vec<PathBuf>,
    pending_moves: Vec<PendingMove>,
}

struct Outcome {
    job: Job,
    result: Result<IngestResult, String>,
    via_link: bool,
}

/// Copies every job (blocking: run it on a worker).
fn copy_jobs(jobs: Vec<Job>, imported: PathBuf, library: PathBuf) -> Vec<Outcome> {
    jobs.into_iter()
        .map(|job| {
            let via_link = MediaFileOps::is_link_or_alias(&job.source);
            let result = if job.library {
                MediaFileOps::ingest_library_item(&job.source, &library)
            } else {
                MediaFileOps::ingest(&job.source, &imported, ImportMode::Copy, &MediaFileOps::trash)
            };
            Outcome { job, result: result.map_err(|e| e.to_string()), via_link }
        })
        .collect()
}

impl ShellHost {
    /// The one import: probes `urls` into the bin, then applies the Outside files setting. `generated` marks a file the
    /// app made itself (a voiceover): it is copied without asking whenever it lies outside the project folder.
    pub async fn import_media<R: ShellRoot + ?Sized>(h: UiRef<R>, urls: Vec<PathBuf>, generated: bool) {
        ProjectPanelModel::import_files(h.clone(), urls).await;
        if let Some(plan) = Self::plan_outside(h.clone(), generated).await {
            Self::run_outside(h.clone(), plan).await;
        }
        Self::say_import_failures(&h);
    }

    /// Sorts the files the last import landed and asks about the ones the project asks about. `None`: nothing to copy.
    /// Callers that place the clips run this first and `run_outside` after placing: a long copy must not hold the edit.
    pub(crate) async fn plan_outside<R: ShellRoot + ?Sized>(h: UiRef<R>, generated: bool) -> Option<OutsidePlan> {
        let (mut plan, ask) = h.with(|r| Self::sort_landed(r, generated)).flatten()?;
        if !ask.is_empty() {
            let (choice, always) = Self::ask_outside(&h, ask.len()).await;
            let _ = h.with(|r| {
                let p = r.shell_parts();
                // The project changed while the question was up: it keeps its files where they are.
                if p.session.project().id != plan.project_id {
                    return;
                }
                if choice != Choice::Leave || always {
                    p.shell.defaults.set_string(LAST_CHOICE_KEY, choice.raw());
                }
                if always {
                    Self::change_media_policy(p.session, move |policy| policy.outside = Some(choice.mode()));
                }
            });
            if choice != Choice::Leave
                && h.with(|r| r.shell_parts().session.project().id == plan.project_id) == Some(true)
            {
                for f in &ask {
                    plan.jobs.push(Job { id: f.id, source: f.url.clone(), library: false });
                    if choice == Choice::Move {
                        plan.moves.insert(f.id);
                    }
                }
            }
        }
        (!plan.is_empty()).then_some(plan)
    }

    /// The landed files in three groups: copied without asking, to ask about, and left alone (not returned).
    fn sort_landed<R: ShellRoot + ?Sized>(r: &mut R, generated: bool) -> Option<(OutsidePlan, Vec<ImportedFile>)> {
        let landed: Vec<ImportedFile> =
            r.panel_parts().0.take_imported().into_iter().flat_map(|(files, _)| files).collect();
        if landed.is_empty() {
            return None;
        }
        let p = r.shell_parts();
        let url = p.session.file_url()?.to_path_buf();
        let defaults = p.session.media_policy_defaults();
        let project = p.session.project();
        let copy_library = MediaManagement::copies_library_items(project, Some(&url), &defaults);
        let mut plan =
            OutsidePlan { project_id: project.id, project_url: url.clone(), jobs: Vec::new(), moves: BTreeSet::new() };
        let mut ask = Vec::new();
        let mut stayed = 0;
        for f in landed {
            let path = f.url.to_string_lossy().into_owned();
            let is_library =
                p.shell.outside_media.library_roots.iter().any(|root| MediaManagement::is_inside(&path, root));
            if is_library {
                if copy_library {
                    plan.jobs.push(Job { id: f.id, source: f.url, library: true });
                }
                continue; // a Library item never asks
            }
            match MediaManagement::disposition(&path, project, Some(&url), &defaults) {
                Disposition::Link => {}
                Disposition::Stay => stayed += usize::from(!generated),
                Disposition::Ask if generated => plan.jobs.push(Job { id: f.id, source: f.url, library: false }),
                Disposition::Ask => ask.push(f),
                Disposition::Apply(mode) => {
                    if !generated || mode != ImportMode::Leave {
                        if mode == ImportMode::Move && !generated {
                            plan.moves.insert(f.id);
                        }
                        plan.jobs.push(Job { id: f.id, source: f.url, library: false });
                    }
                }
            }
        }
        if stayed > 0 {
            p.shell.emit(ShellEvent::Status(SQL10n::plural_with(
                stayed as i64,
                "Kept %@ file where it is: this project is not in a folder of its own name, so nothing is copied.",
                "Kept %@ files where they are: this project is not in a folder of its own name, so nothing is copied.",
                &[],
            )));
        }
        Some((plan, ask))
    }

    /// The question (Swift `MediaPlacementPrompt`): Copy, Move or Leave, and whether the project remembers the answer.
    /// Esc or closing leaves the files where they are.
    async fn ask_outside<R: ShellRoot + ?Sized>(h: &UiRef<R>, count: usize) -> (Choice, bool) {
        let last = h
            .with(|r| r.shell_parts().shell.defaults.string(LAST_CHOICE_KEY))
            .flatten()
            .and_then(|s| Choice::from_raw(&s))
            .unwrap_or(Choice::Copy);
        let title = if count == 1 {
            SQL10n::string("This file is outside the project folder")
        } else {
            SQL10n::format("These %@ files are outside the project folder", &[&count.to_string()])
        };
        let mut d = ShellDialog::new(
            &title,
            &SQL10n::string(
                "The clips are already in your project. Copy puts the files into Files/Imported and uses the copies; Move also sends the originals to the Trash after the next save.",
            ),
        );
        d.form = Some(Box::new(ShellForm::new(vec![Row::check(
            "always",
            &SQL10n::string("Always do this in this project"),
            false,
        )])));
        for choice in Choice::ALL {
            let name = match choice {
                Choice::Copy => "Copy into project",
                Choice::Move => "Move into project",
                Choice::Leave => "Leave where it is",
            };
            let role = if choice == last { SQDialogRole::Default } else { SQDialogRole::Normal };
            d.add_button(&SQL10n::string(name), role, false);
        }
        d.escape_response = Some(SQDialogResponse::THIRD);
        let answer = Self::ask(h, d).await;
        let always = h
            .with(|r| r.shell_parts().shell.take_answered_form().and_then(|f| f.bool("always")))
            .flatten()
            .unwrap_or(false);
        let choice = match answer {
            Some(SQDialogResponse::FIRST) => Choice::Copy,
            Some(SQDialogResponse::SECOND) => Choice::Move,
            _ => Choice::Leave,
        };
        (choice, always && answer.is_some())
    }

    /// Copies the files of `plan` on a worker, then points the clips at the verified copies (no undo step). A failed
    /// copy leaves that clip linked to its original and says so.
    pub(crate) async fn run_outside<R: ShellRoot + ?Sized>(h: UiRef<R>, plan: OutsidePlan) {
        let imported = MediaManagement::imported_folder(&plan.project_url);
        let library = MediaManagement::library_folder(&plan.project_url);
        let jobs = plan.jobs.clone();
        let pool = h.with(|r| r.shell_parts().shell.flow_env.services.worker_pool()).flatten();
        let outcomes = match pool {
            Some(pool) => match pool.run(move |_| copy_jobs(jobs, imported, library)).await {
                Ok(o) => o,
                Err(_) => {
                    let _ = h.with(|r| {
                        r.shell_parts().shell.emit(ShellEvent::Status(SQL10n::string(
                            "Could not copy the files into the project: the copy was interrupted. They stay linked to the originals.",
                        )))
                    });
                    return;
                }
            },
            // shortcut: no worker pool (headless tools) copies on the calling thread; upgrade when every host has a pool.
            None => copy_jobs(jobs, imported, library),
        };
        let _ = h.with(|r| Self::finish_outside(r, &plan, outcomes));
    }

    fn finish_outside<R: ShellRoot + ?Sized>(r: &mut R, plan: &OutsidePlan, outcomes: Vec<Outcome>) {
        let p = r.shell_parts();
        let made: Vec<IngestResult> = outcomes.iter().filter_map(|o| o.result.as_ref().ok().cloned()).collect();
        // Another project meanwhile: the copies this batch created have no clip; remove them.
        if p.session.project().id != plan.project_id {
            MediaFileOps::discard_unlinked(&made);
            return;
        }
        let present: BTreeSet<Id> = p.session.project().media.iter().map(|m| m.id).collect();
        let mut paths: BTreeMap<Id, String> = BTreeMap::new();
        for o in &outcomes {
            // A clip removed meanwhile (undo of the import) keeps no copy of ours.
            if let Ok(done) = &o.result
                && present.contains(&o.job.id)
                && done.url != o.job.source
            {
                paths.insert(o.job.id, done.url.to_string_lossy().into_owned());
                if plan.moves.contains(&o.job.id) && !o.via_link {
                    p.shell.outside_media.pending_moves.push(PendingMove {
                        id: o.job.id,
                        original: o.job.source.clone(),
                        copy: done.url.clone(),
                    });
                }
            }
        }
        let gone: Vec<IngestResult> = outcomes
            .iter()
            .filter(|o| !present.contains(&o.job.id))
            .filter_map(|o| o.result.as_ref().ok().cloned())
            .collect();
        MediaFileOps::discard_unlinked(&gone);
        p.session.relink_media_quietly(&paths);
        let failed: Vec<&Outcome> = outcomes.iter().filter(|o| o.result.is_err()).collect();
        let line = match failed.first() {
            Some(first) => {
                let name = first.job.source.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
                let why = first.result.as_ref().err().cloned().unwrap_or_default();
                if failed.len() == 1 {
                    SQL10n::format(
                        "Could not copy “%@” into the project: %@ It stays linked to the original.",
                        &[&name, &why],
                    )
                } else {
                    SQL10n::format(
                        "Could not copy %@ files into the project (%@ and others). They stay linked to the originals.",
                        &[&failed.len().to_string(), &name],
                    )
                }
            }
            None if paths.is_empty() => return,
            None => SQL10n::plural_with(
                paths.len() as i64,
                "Copied %@ file into the project.",
                "Copied %@ files into the project.",
                &[],
            ),
        };
        p.shell.emit(ShellEvent::Status(line));
    }

    /// After a successful save: the originals of moved items whose saved path is the copy go to the Trash. An item that
    /// was removed or undone before the save keeps both files.
    pub(crate) async fn trash_moved_originals<R: ShellRoot + ?Sized>(h: UiRef<R>) {
        let Some(Some((moves, pool))) = h.with(|r| {
            let p = r.shell_parts();
            if p.shell.outside_media.pending_moves.is_empty() {
                return None;
            }
            let saved: BTreeMap<Id, String> =
                p.session.project().media.iter().map(|m| (m.id, m.path.clone())).collect();
            let (ready, rest): (Vec<_>, Vec<_>) = std::mem::take(&mut p.shell.outside_media.pending_moves)
                .into_iter()
                .partition(|m| saved.get(&m.id).is_some_and(|path| Path::new(path) == m.copy));
            // Still waiting: the item exists but not with the copy's path yet.
            p.shell.outside_media.pending_moves = rest.into_iter().filter(|m| saved.contains_key(&m.id)).collect();
            Some((ready, p.shell.flow_env.services.worker_pool()))
        }) else {
            return;
        };
        if moves.is_empty() {
            return;
        }
        let trash = move || -> usize {
            moves.iter().filter(|m| !MediaFileOps::remove_original(&m.original, &m.copy, &MediaFileOps::trash)).count()
        };
        let kept = match pool {
            Some(pool) => pool.run(move |_| trash()).await.unwrap_or(0),
            None => trash(),
        };
        if kept > 0 {
            let _ = h.with(|r| {
                r.shell_parts().shell.emit(ShellEvent::Status(SQL10n::string(
                    "Copied into the project, but some originals could not be moved to the Trash and were kept.",
                )))
            });
        }
    }
}

#[cfg(test)]
#[path = "shell_outside_media_tests.rs"]
mod tests;
