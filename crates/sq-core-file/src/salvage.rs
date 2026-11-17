// Swift: ProjectFile+Salvage.swift
// SPDX-License-Identifier: GPL-3.0-or-later

use crate::files::document_file;
use crate::variant_repair::reads_as;
use crate::{CURRENT_VERSION, ProjectFile, ProjectFileError};
use serde::Deserialize;
use serde_json::{Value, json};
use sq_core_model::{Clip, ClipEffect, MediaRef, Project, Timeline, Track};
use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};

/// What `ProjectFile::read_salvaging` left out of a project file that did not decode as a whole, one line per dropped part.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ProjectSalvageReport {
    /// One line per dropped part.
    pub dropped: Vec<String>,
}

impl ProjectSalvageReport {
    /// Nothing was dropped.
    pub fn is_empty(&self) -> bool {
        self.dropped.is_empty()
    }
}

fn is_uuid(s: &str) -> bool {
    sq_core_time::Id::parse(s).is_some()
}

fn text<'v>(o: &'v Value, key: &str) -> Option<&'v str> {
    o.get(key).and_then(Value::as_str)
}

/// `“name”` when the object has a name, else `fallback`.
fn label(o: &Value, fallback: &str) -> String {
    text(o, "name").map_or_else(|| fallback.to_string(), |n| format!("“{n}”"))
}

/// The array under `key` when every element is an object (Swift `as? [JSONObject]`).
fn objects<'v>(o: &'v Value, key: &str) -> Option<&'v Vec<Value>> {
    o.get(key).and_then(Value::as_array).filter(|a| a.iter().all(Value::is_object))
}

fn placeholder(id: &str, name: &str, path: &str) -> Value {
    json!({"id": id, "name": name, "path": path, "fingerprint": {"size": 0}})
}

impl ProjectFile<'_> {
    /// Opens a project file, and when it does not decode as a whole opens the rest: a clip, effect, sequence or media item
    /// that fails is dropped (a media item is kept as an offline placeholder with its id, name and path) and listed in the
    /// report. Reads only; the file is never written. A file that is not a project at all, or from a newer build, errors as
    /// `read` does.
    pub fn read_salvaging(&self, path: &Path) -> Result<(Project, ProjectSalvageReport), ProjectFileError> {
        let file = document_file(path);
        if !file.exists() {
            return Err(ProjectFileError::Missing);
        }
        let data = fs::read(&file).map_err(|_| ProjectFileError::Corrupt)?;
        self.salvage(&data)
    }

    /// Copies the damaged `project.json` of `package` to `<package>.damaged.bak` beside it (a numbered name when one exists:
    /// never overwritten), so a save over the original keeps what the salvage left out. Returns the copy, `None` when the
    /// package has no file.
    pub fn back_up_damaged(package: &Path) -> Result<Option<PathBuf>, ProjectFileError> {
        let file = document_file(package);
        if !file.exists() {
            return Ok(None);
        }
        let dir = package.parent().unwrap_or(Path::new(""));
        let base = package.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        let mut n = 1;
        let mut dest = dir.join(format!("{base}.damaged.bak"));
        while dest.exists() {
            n += 1;
            dest = dir.join(format!("{base}.damaged{n}.bak"));
        }
        fs::copy(&file, &dest)?;
        Ok(Some(dest))
    }

    pub(crate) fn salvage(&self, data: &[u8]) -> Result<(Project, ProjectSalvageReport), ProjectFileError> {
        if let Ok(whole) = self.decode(data, None) {
            return Ok((whole, ProjectSalvageReport::default()));
        }
        let Ok(Value::Object(mut obj)) = serde_json::from_slice::<Value>(data) else {
            return Err(ProjectFileError::Corrupt);
        };
        let Some(mut version) = obj.get("formatVersion").and_then(Value::as_i64) else {
            return Err(ProjectFileError::Corrupt);
        };
        if !obj.get("project").is_some_and(Value::is_object) {
            return Err(ProjectFileError::Corrupt);
        }
        if version > CURRENT_VERSION {
            return Err(ProjectFileError::NewerVersion { found: version, supported: CURRENT_VERSION });
        }
        let steps = self.migrations();
        while version < CURRENT_VERSION {
            let step = steps.get(&version).ok_or(ProjectFileError::Corrupt)?;
            obj = step(obj).map_err(|_| ProjectFileError::Corrupt)?;
            version += 1;
        }
        let Some(mut proj) = obj.remove("project").filter(Value::is_object) else {
            return Err(ProjectFileError::Corrupt);
        };
        let mut report = ProjectSalvageReport::default();

        // Media: a failing item stays as an offline placeholder when it still has an id.
        if let Some(list) = objects(&proj, "media") {
            let kept: Vec<Value> = list
                .iter()
                .filter_map(|m| {
                    let mut m = m.clone();
                    if reads_as::<MediaRef>(&mut m, &mut report.dropped) {
                        return Some(m);
                    }
                    let name = text(&m, "name").unwrap_or("Media");
                    report.dropped.push(format!("Media “{name}”: its details could not be read, the item is offline"));
                    let id = text(&m, "id").filter(|id| is_uuid(id))?;
                    Some(placeholder(id, name, text(&m, "path").unwrap_or("")))
                })
                .collect();
            proj["media"] = Value::Array(kept);
        }

        // Sequences > tracks > clips > effects.
        let mut timelines: Vec<Value> = Vec::new();
        let mut dropped_timelines = BTreeSet::new();
        let mut kept_media: BTreeSet<String> =
            objects(&proj, "media").into_iter().flatten().filter_map(|m| text(m, "id").map(str::to_string)).collect();
        let mut placeholders: Vec<Value> = Vec::new();
        for mut t in objects(&proj, "timelines").cloned().unwrap_or_default() {
            let t_name = label(&t, "a sequence");
            let mut tracks: Vec<Value> = Vec::new();
            for mut tr in objects(&t, "tracks").cloned().unwrap_or_default() {
                let tr_name =
                    text(&tr, "name").filter(|n| !n.is_empty()).map_or("a track".to_string(), |n| format!("“{n}”"));
                let mut dropped_ids = BTreeSet::new();
                let mut clips: Vec<Value> = Vec::new();
                for mut c in objects(&tr, "clips").cloned().unwrap_or_default() {
                    if !reads_as::<Clip>(&mut c, &mut report.dropped)
                        && let Some(fx) = objects(&c, "effects")
                    {
                        let mut kept = Vec::new();
                        for e in fx {
                            let mut e = e.clone();
                            if reads_as::<ClipEffect>(&mut e, &mut report.dropped) {
                                kept.push(e);
                                continue;
                            }
                            let kind = text(&e, "kind").map_or(String::new(), |k| format!("“{k}”"));
                            report.dropped.push(format!(
                                "Effect {kind} on clip {} in {t_name}: unknown or damaged",
                                label(&c, "a clip")
                            ));
                        }
                        c["effects"] = Value::Array(kept);
                    }
                    if reads_as::<Clip>(&mut c, &mut report.dropped) {
                        clips.push(c);
                        continue;
                    }
                    if let Some(id) = text(&c, "id") {
                        dropped_ids.insert(id.to_string());
                    }
                    report.dropped.push(format!("Clip {} on {tr_name} in {t_name}: unknown or damaged", label(&c, "")));
                }
                tr["clips"] = Value::Array(clips);
                if !dropped_ids.is_empty()
                    && let Some(ts) = objects(&tr, "transitions")
                {
                    let touches_dropped = |x: &Value| {
                        ["outgoing", "incoming"].iter().any(|k| text(x, k).is_some_and(|id| dropped_ids.contains(id)))
                    };
                    let kept: Vec<Value> = ts.iter().filter(|x| !touches_dropped(x)).cloned().collect();
                    tr["transitions"] = Value::Array(kept);
                }
                if reads_as::<Track>(&mut tr, &mut report.dropped) {
                    tracks.push(tr);
                } else {
                    report.dropped.push(format!("Track {tr_name} in {t_name}: damaged"));
                }
            }
            t["tracks"] = Value::Array(tracks);
            if reads_as::<Timeline>(&mut t, &mut report.dropped) {
                timelines.push(t);
            } else {
                if let Some(id) = text(&t, "id") {
                    dropped_timelines.insert(id.to_string());
                }
                report.dropped.push(format!("Sequence {t_name}: damaged"));
            }
        }

        // Clips that lost what they refer to: nested sequences that were dropped go with them; a clip of media the file no
        // longer lists points at an offline placeholder; an attachment to a dropped clip is cleared (re-derived on edit).
        for tl in &mut timelines {
            let t_name = label(tl, "a sequence");
            let mut tracks: Vec<Value> = objects(tl, "tracks").cloned().unwrap_or_default();
            let mut gone = BTreeSet::new();
            for track in &mut tracks {
                let mut clips = objects(track, "clips").cloned().unwrap_or_default();
                clips.retain(|c| {
                    if !text(c, "sequence").is_some_and(|s| dropped_timelines.contains(s)) {
                        return true;
                    }
                    if let Some(id) = text(c, "id") {
                        gone.insert(id.to_string());
                    }
                    report.dropped.push(format!("Clip {} in {t_name}: its sequence could not be read", label(c, "")));
                    false
                });
                track["clips"] = Value::Array(clips);
            }
            let present: BTreeSet<String> = tracks
                .iter()
                .flat_map(|tr| objects(tr, "clips").into_iter().flatten())
                .filter_map(|c| text(c, "id").map(str::to_string))
                .collect();
            for track in &mut tracks {
                let mut clips = objects(track, "clips").cloned().unwrap_or_default();
                for c in &mut clips {
                    let host = c.get("attachment").and_then(|a| text(a, "host"));
                    if host.is_some_and(|h| gone.contains(h) || !present.contains(h))
                        && let Some(o) = c.as_object_mut()
                    {
                        o.remove("attachment");
                    }
                    if c.get("sequence").is_none()
                        && c.get("generator").is_none()
                        && let Some(m) =
                            text(c, "media").filter(|m| is_uuid(m) && !kept_media.contains(*m)).map(str::to_string)
                    {
                        let n = text(c, "name").unwrap_or("Media").to_string();
                        placeholders.push(placeholder(&m, &n, ""));
                        kept_media.insert(m);
                        report
                            .dropped
                            .push(format!("Media for clip “{n}” is missing from the file; the clip is offline"));
                    }
                }
                track["clips"] = Value::Array(clips);
            }
            tl["tracks"] = Value::Array(tracks);
        }
        if !placeholders.is_empty() {
            let mut media = objects(&proj, "media").cloned().unwrap_or_default();
            media.extend(placeholders);
            proj["media"] = Value::Array(media);
        }
        let active_gone =
            text(&proj, "activeTimeline").is_some_and(|a| !timelines.iter().any(|t| text(t, "id") == Some(a)));
        proj["timelines"] = Value::Array(timelines);
        if active_gone && let Some(o) = proj.as_object_mut() {
            o.remove("activeTimeline");
        }
        if !reads_as::<Project>(&mut proj, &mut report.dropped) {
            return Err(ProjectFileError::Corrupt);
        }
        let mut project = Project::deserialize(&proj).map_err(|_| ProjectFileError::Corrupt)?;
        Self::plain_paths(&mut project);
        Self::adopt_file_keys(&mut project, &obj, &proj);
        Ok((project, report))
    }
}
