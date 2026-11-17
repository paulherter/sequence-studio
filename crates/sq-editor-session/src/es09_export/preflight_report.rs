//! What the user should know before an export starts, and the question about files that already exist.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use sq_core_edit::angles_proxy::AnglesClipExt;
use sq_core_masks::picture_mask::PictureMaskTimelineExt;
use sq_core_model::{MediaRef, Project, Timeline};
use sq_core_time::Id;
use sq_export::core::preflight::{ExportPreflight, SpaceVerdict};

use super::model::ExportDialogModel;

/// The notes of one preflight and the dialog title that sums them up.
// Swift: Export/ExportPreflightReport.swift:9
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Report {
    /// One paragraph per finding.
    // Swift: Export/ExportPreflightReport.swift:10
    pub lines: Vec<String>,
    /// Alert title.
    // Swift: Export/ExportPreflightReport.swift:11
    pub title: String,
}

impl Report {
    /// Nothing to tell.
    // Swift: Export/ExportPreflightReport.swift:12
    pub fn is_empty(&self) -> bool {
        self.lines.is_empty()
    }
}

/// Counts Magic mask frames without a matte (the matte store lives in the platform layer).
pub type UntrackedMagicFrames<'a> = &'a dyn Fn(&Timeline, &BTreeMap<Id, Timeline>) -> usize;

/// What the user should know before an export starts (offline, damaged and HDR media, masks without a track or a matte,
/// a failed audio check, little disk space) and the question about files that already exist.
// Swift: Export/ExportPreflightReport.swift:8
pub enum ExportPreflightReport {}

impl ExportPreflightReport {
    /// The notes for `model`'s selected sequence exporting into `dir`. `untracked_magic_frames` counts Magic mask
    /// frames without a matte; `None` counts none.
    // Swift: Export/ExportPreflightReport.swift:17
    pub fn build(
        model: &ExportDialogModel,
        project: &Project,
        dir: &Path,
        untracked_magic_frames: Option<UntrackedMagicFrames<'_>>,
    ) -> Report {
        let Some(tl) = project.timelines.iter().find(|t| t.id == model.selected_id()) else {
            return Report { lines: Vec::new(), title: String::new() };
        };
        let sequences: BTreeMap<Id, Timeline> = project.timelines.iter().map(|t| (t.id, t.clone())).collect();
        let angle_view = |c: &sq_core_model::Clip, t: &Timeline| c.angle_view(t);
        let unlinked = tl.unlinked_picture_mask_count(&sequences, &angle_view);
        let n = untracked_magic_frames.map_or(0, |f| f(tl, &sequences));
        let offline = ExportPreflight::offline_media(tl.id, project);
        let list = |refs: &[&MediaRef]| -> String {
            let shown = refs.iter().take(5).map(|r| format!("• {}", r.name)).collect::<Vec<_>>().join("\n");
            if refs.len() > 5 { format!("{shown}\n• and {} more", refs.len() - 5) } else { shown }
        };
        let plural = |c: usize, one: &'static str, other: &'static str| if c == 1 { one } else { other };
        let mut lines: Vec<String> = Vec::new();
        if !offline.is_empty() {
            lines.push(format!(
                "{} media file{} offline and export as the offline picture:\n{}\nReconnect them first (File > Reconnect Media…).",
                offline.len(),
                plural(offline.len(), " is", "s are"),
                list(&offline)
            ));
        }
        if unlinked > 0 {
            lines.push(format!(
                "{unlinked} Picture mask{} set to No track and cut{} nothing. Pick a track in the mask row.",
                plural(unlinked, " is", "s are"),
                plural(unlinked, "s", "")
            ));
        }
        if n > 0 {
            lines.push(format!(
                "Magic mask not tracked on {n} frame{}: those frames export without the mask. Select the clip, then Track Forward / Backward in its mask row.",
                plural(n, "", "s")
            ));
        }
        // The audio check ran in the dialog and found a failure (clipping, silent mix, level off target): say so again.
        let audio_fails = model.audio_check_failures();
        if !audio_fails.is_empty() {
            let items = audio_fails.iter().map(|f| format!("• {}", f.message)).collect::<Vec<_>>().join("\n");
            lines.push(format!("Audio check failed:\n{items}"));
        }
        // Files that are there but cannot be read: their frames export as the damaged placeholder (or stop the export).
        let damaged = ExportPreflight::unreadable_media(tl.id, project);
        if !damaged.is_empty() {
            let outcome = if model.continue_on_damaged_frames() {
                "their frames export as the damaged-frame placeholder"
            } else {
                "the export stops at the first damaged frame (turn on Continue on damaged frames to export the rest)"
            };
            lines.push(format!(
                "{} media file{} damaged or unreadable; {outcome}:\n{}",
                damaged.len(),
                plural(damaged.len(), " is", "s are"),
                list(&damaged)
            ));
        }
        // HDR sources: the export is Rec. 709 only, so HLG / PQ media is tone-mapped to SDR.
        let hdr = ExportPreflight::hdr_media(tl.id, project);
        if !hdr.is_empty() {
            lines.push(format!(
                "{} media file{} HDR. The export is Rec. 709 (SDR) only, so the picture is converted and will look flatter than on an HDR display:\n{}",
                hdr.len(),
                plural(hdr.len(), " is", "s are"),
                list(&hdr)
            ));
        }
        // The estimate against the free space of the output volume (the queue also watches it while exporting).
        let estimate = model.estimated_bytes();
        let free_bytes = ExportPreflight::free_bytes(dir);
        let verdict = ExportPreflight::space_verdict(free_bytes, estimate);
        if let Some(note) = Self::space_note(verdict, free_bytes, estimate) {
            lines.push(note);
        }
        let flags = [
            !offline.is_empty(),
            unlinked > 0,
            n > 0,
            !audio_fails.is_empty(),
            !damaged.is_empty(),
            verdict != SpaceVerdict::Ok,
            !hdr.is_empty(),
        ];
        let kinds = flags.iter().filter(|f| **f).count();
        let title = if kinds > 1 {
            "Check before exporting"
        } else if !damaged.is_empty() {
            "Media is damaged"
        } else if verdict != SpaceVerdict::Ok {
            "Not much disk space"
        } else if !audio_fails.is_empty() {
            "Audio check failed"
        } else if !offline.is_empty() {
            "Media is offline"
        } else if !hdr.is_empty() {
            "Media is HDR"
        } else if unlinked > 0 {
            "Picture mask without a track"
        } else {
            "Magic mask not tracked"
        };
        Report { lines, title: title.to_string() }
    }

    /// The paragraph about the output disk (design: "Not much disk space"); `None` when there is room or the free space is
    /// unknown.
    pub fn space_note(verdict: SpaceVerdict, free_bytes: Option<i64>, estimate: i64) -> Option<String> {
        let free = free_bytes?;
        let gb = |b: i64| format!("{:.1} GB", b as f64 / 1_000_000_000.0);
        match verdict {
            SpaceVerdict::Ok => None,
            SpaceVerdict::Insufficient => Some(format!(
                "The output disk has {} free and the export needs about {}. It will probably stop before it is done. Pick another folder or free some space.",
                gb(free),
                gb(estimate)
            )),
            _ => Some(format!(
                "The output disk has {} free and the export needs about {}: little room is left over.",
                gb(free),
                gb(estimate)
            )),
        }
    }

    /// The question when files of the new export are already in the folder: its title and message (Keep Both / Replace);
    /// `None` when none exists.
    // Swift: Export/ExportPreflightReport.swift:81
    pub fn existing_files_question(existing: &[PathBuf]) -> Option<(String, String)> {
        if existing.is_empty() {
            return None;
        }
        let name =
            |p: &PathBuf| format!("“{}”", p.file_name().map_or_else(String::new, |n| n.to_string_lossy().into_owned()));
        let names = existing.iter().take(3).map(name).collect::<Vec<_>>().join(", ");
        let more = if existing.len() > 3 { format!(" and {} more", existing.len() - 3) } else { String::new() };
        let what = if existing.len() == 1 {
            format!("{names} already exists")
        } else {
            format!("{names}{more} already exist")
        };
        Some((
            format!("{what} in this folder"),
            "Keep Both saves the new export with a number added to its name. Replace overwrites the existing file."
                .to_string(),
        ))
    }
}
