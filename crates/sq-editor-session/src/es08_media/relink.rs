// Swift: EditorSession+RelinkOffer.swift, EditorSession+Reconnect.swift
//! Finding offline media again: the offer without asking (old folder, same folder on other volumes, project folder),
//! the near-project relink for a copied project, and the Reconnect checklist scored from one picked file or folder.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Component, Path, PathBuf};
use std::sync::Arc;

use sq_core_edit::near_project_relink::NearProjectRelink;
use sq_core_model::MediaRef;
use sq_core_project::media_path_resolver::{MediaPathResolver, RelinkScanner};
use sq_core_project::near_project_relink_plan::NearProjectRelinkPlanExt;
use sq_core_project::relink::{ProjectRelinkExt, RelinkPlanner};
use sq_core_project::relink_scoring::{RelinkProposal, RelinkScorer, RelinkScorerResult};
use sq_core_time::Id;
use sq_library::library_item_kind::LibraryItemKind;
use sq_runtime::{UiRef, WorkerPool};

use crate::{EditorSession, MediaWorkers, SessionRoot};

/// The path with `.` dropped and `..` resolved lexically, keeping its drive or root (Swift `standardizedFileURL`).
fn clean_path(path: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for c in path.components() {
        match c {
            Component::CurDir => {}
            Component::ParentDir if out.file_name().is_some() => {
                out.pop();
            }
            Component::ParentDir if out.has_root() => {}
            c => out.push(c.as_os_str()),
        }
    }
    out
}

impl EditorSession {
    /// Folders worth searching for offline `missing` media without asking: each file's old folder, the same relative
    /// folder on the other mounted volumes (`/Volumes/OLD/x` -> `/Volumes/NEW/x`), the project folder and the folders
    /// remembered from earlier relinks. Returned with the depth to descend; only folders that exist.
    // Swift: EditorSession+RelinkOffer.swift:8
    pub fn relink_offer_roots(
        missing: &[MediaRef],
        volumes: &[PathBuf],
        project_folder: Option<&Path>,
        extra_folders: &[PathBuf],
    ) -> Vec<(PathBuf, usize)> {
        let mut roots: Vec<(PathBuf, usize)> = Vec::new();
        let mut seen: BTreeSet<String> = BTreeSet::new();
        let mut add = |url: &Path, depth: usize| {
            let dir = clean_path(url);
            if dir.is_dir() && seen.insert(dir.to_string_lossy().into_owned()) {
                roots.push((dir, depth));
            }
        };
        for m in missing {
            let Some(parent) = Path::new(&m.path).parent().filter(|p| p.is_absolute()) else { continue };
            add(parent, 1);
            let comps: Vec<String> =
                parent.to_string_lossy().split('/').filter(|c| !c.is_empty()).map(str::to_string).collect();
            if comps.len() >= 2 && comps[0] == "Volumes" {
                let rest = comps[2..].join("/");
                for v in volumes.iter().filter(|v| v.file_name().is_none_or(|n| n.to_string_lossy() != comps[1])) {
                    if rest.is_empty() { add(v, 1) } else { add(&v.join(&rest), 1) }
                }
            }
        }
        if let Some(f) = project_folder {
            add(f, 5);
        }
        for f in extra_folders {
            add(f, 12);
        }
        roots
    }

    /// Looks for the offline media in the likely places and returns what a relink would do, without changing the
    /// project (the app shows it as an Apply banner). Scans off the UI thread; empty when nothing is offline.
    // Swift: EditorSession+RelinkOffer.swift:41
    pub async fn relink_offer<R: SessionRoot + ?Sized>(
        h: UiRef<R>,
        pool: Arc<WorkerPool>,
        project_folder: Option<PathBuf>,
        extra_folders: Vec<PathBuf>,
        volumes: Option<Vec<PathBuf>>,
    ) -> BTreeMap<Id, String> {
        let Some((missing, project, vols)) = h.with(|r| {
            let vols = volumes.unwrap_or_else(crate::default_volumes);
            let s = r.session();
            (s.project().missing_media(), s.project().id, vols)
        }) else {
            return BTreeMap::new();
        };
        if missing.is_empty() {
            return BTreeMap::new();
        }
        let roots = Self::relink_offer_roots(&missing, &vols, project_folder.as_deref(), &extra_folders);
        if roots.is_empty() {
            return BTreeMap::new();
        }
        let wanted: BTreeSet<String> =
            missing.iter().map(|m| MediaPathResolver::file_name_of(&m.path).to_lowercase()).collect();
        let Ok(found) = pool.run(move |_| RelinkScanner::scan_roots(&roots, &wanted)).await else {
            return BTreeMap::new();
        };
        h.with(|r| {
            let s = r.session();
            if s.project().id != project {
                return BTreeMap::new();
            }
            RelinkPlanner::match_(&s.project().missing_media(), &found).plan
        })
        .unwrap_or_default()
    }

    /// Applies an offer from [`EditorSession::relink_offer`] (one undo step), keeping only items that are still offline.
    // Swift: EditorSession+RelinkOffer.swift:56
    pub fn apply_relink_offer(&mut self, plan: &BTreeMap<Id, String>) -> usize {
        let still: BTreeSet<Id> = self.project().missing_media().iter().map(|m| m.id).collect();
        let usable: BTreeMap<Id, String> =
            plan.iter().filter(|(k, _)| still.contains(k)).map(|(k, v)| (*k, v.clone())).collect();
        if !usable.is_empty() {
            self.stop_playback();
            self.relink_media(&usable, "Relink Media");
        }
        usable.len()
    }

    /// A project copied to another machine or folder (a Mac project opened on Windows): links the offline media that
    /// sits next to the project file (same trailing folders, else name + size below it). The scan runs off the UI
    /// thread; applied without an undo step. Returns how many were linked.
    // Swift: EditorSession+RelinkOffer.swift:69
    pub async fn relink_near_project<R: SessionRoot + ?Sized>(h: UiRef<R>, pool: Arc<WorkerPool>) -> usize {
        let Some((missing, folder, project)) = h.with(|r| {
            let s = r.session();
            (
                s.project().missing_media(),
                s.file_url.as_deref().and_then(Path::parent).map(Path::to_path_buf),
                s.project().id,
            )
        }) else {
            return 0;
        };
        let Some(folder) = folder.filter(|_| !missing.is_empty()) else { return 0 };
        let probe_set = missing.clone();
        let Ok(plan) = pool.run(move |_| NearProjectRelink::plan(&probe_set, &folder, 8)).await else { return 0 };
        h.with(|r| {
            let s = r.session();
            if s.project().id != project {
                return 0;
            }
            let still: BTreeSet<Id> = s.project().missing_media().iter().map(|m| m.id).collect();
            let usable: BTreeMap<Id, String> = plan.into_iter().filter(|(k, _)| still.contains(k)).collect();
            if usable.is_empty() {
                return 0;
            }
            s.stop_playback();
            s.relink_media_quietly(&usable);
            usable.len()
        })
        .unwrap_or(0)
    }

    /// Reconnect from one find: looks around the picked file or folder (that folder, its parent and siblings, the same
    /// folder on other volumes) and scores every media file there against all offline media. Changes nothing; the dialog
    /// shows the result as a checklist. Lengths are probed only for files that could matter. Off the UI thread.
    // Swift: EditorSession+Reconnect.swift:9
    pub async fn propose_reconnect<R: SessionRoot + MediaWorkers + ?Sized>(
        h: UiRef<R>,
        picked: PathBuf,
        volumes: Option<Vec<PathBuf>>,
    ) -> RelinkScorerResult {
        let Some((missing, project, vols, probe, pool)) = h.with(|r| {
            let vols = volumes.unwrap_or_else(|| r.volumes());
            let pool = r.workers();
            let s = r.session();
            (s.project().missing_media(), s.project().id, vols, std::sync::Arc::clone(&s.media_info_probe), pool)
        }) else {
            return RelinkScorerResult::default();
        };
        if missing.is_empty() {
            return RelinkScorerResult::default();
        }
        let wanted = missing.clone();
        let Ok(found) = pool
            .run(move |ctl| {
                let roots = RelinkScanner::reconnect_roots(&picked, &vols);
                let is_media = |ext: &str| {
                    matches!(
                        LibraryItemKind::classify(Path::new(&format!("/x.{ext}")), false),
                        LibraryItemKind::Video | LibraryItemKind::Image | LibraryItemKind::Audio
                    )
                };
                let mut files = RelinkScanner::scan_media(&roots, &is_media, 20_000);
                let mut probed = 0;
                for f in &mut files {
                    if probed >= 300 || ctl.is_cancelled() {
                        break;
                    }
                    if RelinkScorer::worth_probing(f, &wanted) {
                        probed += 1;
                        f.duration = probe(Path::new(&f.path)).map(|i| i.duration);
                    }
                }
                files
            })
            .await
        else {
            return RelinkScorerResult::default();
        };
        h.with(|r| {
            let s = r.session();
            if s.project().id != project {
                return RelinkScorerResult::default();
            }
            RelinkScorer::propose(&s.project().missing_media(), &found)
        })
        .unwrap_or_default()
    }

    /// Applies the ticked rows of a reconnect checklist (one undo step), keeping only items that are still offline.
    // Swift: EditorSession+Reconnect.swift:37
    pub fn apply_reconnect(&mut self, proposals: &[RelinkProposal]) -> usize {
        let still: BTreeSet<Id> = self.project().missing_media().iter().map(|m| m.id).collect();
        let mut plan: BTreeMap<Id, String> = BTreeMap::new();
        for p in proposals.iter().filter(|p| still.contains(&p.media_id)) {
            plan.entry(p.media_id).or_insert_with(|| p.path.clone());
        }
        if plan.is_empty() {
            return 0;
        }
        self.stop_playback();
        self.relink_media(&plan, "Reconnect Media");
        plan.len()
    }
}
