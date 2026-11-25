//! The perceive endpoints of the Edit API on the app side: frames of a sequence or of a source file as PNG files in a
//! cache folder, transcript, loudness and silences, and the Premiere project import. The picture comes from the same
//! renderer the export uses (`PerceiveBackend::render`), so a capture shows what the monitor and an export show.

use crate::edit_api_host::{ApiBridge, JobEntry, TaskSlot, TaskState, task_info};
use crate::export_host::ExportSnapshot;
use serde_json::{Value, json};
use sq_core_model::{Clip, MediaRef, Project, Timeline};
use sq_core_time::{Id, Time, TimeRange};
use sq_draw::RgbaImage;
use sq_edit_api::edit_apirouter::EditAPIHost;
use sq_edit_api::perceive::{CAPTION_STYLES, CaptionLookSpec, CaptionSpot, ContactSheet, PerceiveError, PerceiveRequest, Target};
use sq_editor_session::{EditorSession, ImportBackend, PlaceOptions, SessionDeps};
use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::{Duration, Instant};

/// Renders `sequence` of the snapshot at `at`; the `usize` is the wanted width (the height follows the sequence's aspect).
pub type StillRenderer =
    Arc<dyn Fn(&ExportSnapshot, Id, Time, Option<usize>) -> Result<RgbaImage, String> + Send + Sync>;

/// What the app hands the API so it can look at the project.
#[derive(Clone)]
pub struct PerceiveBackend {
    /// The engine that renders one frame of a sequence.
    pub render: StillRenderer,
    /// Probes a file into a media item (the Premiere import links the files it finds).
    pub probe: Arc<dyn ImportBackend>,
}

/// How long a call waits for a long job before it answers with a job id.
/// How long a long call waits for its job before it answers with the job's state. It must end before the connection
/// deadline (`EditAPIServer::TIMEOUT`), else the server closes the connection without a reply and the caller never learns
/// the job id.
pub(crate) const JOB_WAIT: Duration = Duration::from_secs(10);
const _: () = assert!(JOB_WAIT.as_secs() + 2 <= sq_edit_api::edit_apiserver_network::EditAPIServer::TIMEOUT.as_secs());

fn fail(status: u16, message: impl Into<String>) -> PerceiveError {
    PerceiveError::new(status, message)
}

fn wire(t: Time) -> Value {
    json!({ "value": t.value(), "timescale": t.timescale() })
}

fn millis(t: Time) -> i64 {
    (i128::from(t.value()) * 1000 / i128::from(t.timescale().max(1))) as i64
}

fn timecode(t: Time) -> String {
    let ms = millis(t).max(0);
    format!("{:02}:{:02}:{:02}.{:03}", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
}

/// Writes `rgba` as a PNG.
pub fn write_png(path: &Path, width: usize, height: usize, rgba: &[u8]) -> Result<(), String> {
    let file = std::fs::File::create(path).map_err(|e| e.to_string())?;
    let mut encoder = png::Encoder::new(std::io::BufWriter::new(file), width as u32, height as u32);
    encoder.set_color(png::ColorType::Rgba);
    encoder.set_depth(png::BitDepth::Eight);
    let mut writer = encoder.write_header().map_err(|e| e.to_string())?;
    writer.write_image_data(rgba).map_err(|e| e.to_string())
}

/// 3x5 glyphs of the contact sheet's timecodes: digits, ':' and '.'.
const GLYPHS: [(char, [u8; 5]); 12] = [
    ('0', [7, 5, 5, 5, 7]),
    ('1', [2, 6, 2, 2, 7]),
    ('2', [7, 1, 7, 4, 7]),
    ('3', [7, 1, 7, 1, 7]),
    ('4', [5, 5, 7, 1, 1]),
    ('5', [7, 4, 7, 1, 7]),
    ('6', [7, 4, 7, 5, 7]),
    ('7', [7, 1, 1, 1, 1]),
    ('8', [7, 5, 7, 5, 7]),
    ('9', [7, 5, 7, 1, 7]),
    (':', [0, 2, 0, 2, 0]),
    ('.', [0, 0, 0, 0, 2]),
];

/// Draws `text` white on a black strip at (x, y), each dot `scale` pixels.
fn draw_label(img: &mut RgbaImage, x: usize, y: usize, text: &str, scale: usize) {
    let (w, h) = (text.len() * 4 * scale + scale, 6 * scale + scale);
    for yy in y..(y + h).min(img.height) {
        for xx in x..(x + w).min(img.width) {
            let i = (yy * img.width + xx) * 4;
            img.pixels[i..i + 4].copy_from_slice(&[0, 0, 0, 255]);
        }
    }
    for (n, c) in text.chars().enumerate() {
        let Some((_, rows)) = GLYPHS.iter().find(|(g, _)| *g == c) else { continue };
        for (ry, row) in rows.iter().enumerate() {
            for rx in 0..3 {
                if row >> (2 - rx) & 1 == 0 {
                    continue;
                }
                for dy in 0..scale {
                    for dx in 0..scale {
                        let (px, py) = (x + scale + (n * 4 + rx) * scale + dx, y + scale + ry * scale + dy);
                        if px < img.width && py < img.height {
                            let i = (py * img.width + px) * 4;
                            img.pixels[i..i + 4].copy_from_slice(&[255, 255, 255, 255]);
                        }
                    }
                }
            }
        }
    }
}

/// The tiles in a grid of up to four columns, each with its timecode.
fn contact_sheet(tiles: &[(Time, RgbaImage)]) -> Option<RgbaImage> {
    let (tw, th) = tiles.first().map(|(_, i)| (i.width, i.height))?;
    let columns = tiles.len().min(4);
    let rows = tiles.len().div_ceil(columns);
    let mut sheet = RgbaImage { width: tw * columns, height: th * rows, pixels: vec![0; tw * columns * th * rows * 4] };
    for (n, (t, tile)) in tiles.iter().enumerate() {
        let (ox, oy) = (n % columns * tw, n / columns * th);
        for y in 0..th.min(tile.height) {
            let from = y * tile.width * 4;
            let to = ((oy + y) * sheet.width + ox) * 4;
            let len = tw.min(tile.width) * 4;
            sheet.pixels[to..to + len].copy_from_slice(&tile.pixels[from..from + len]);
        }
        draw_label(&mut sheet, ox + 2, oy + 2, &timecode(*t), 2);
    }
    Some(sheet)
}

/// A one-clip sequence of `media`, made like a drop onto an empty timeline.
fn scratch_timeline(project: &Project, media: Id, dir: &Path) -> Result<(Project, Timeline), PerceiveError> {
    let item = project.media(media).ok_or_else(|| fail(404, "unknown media"))?.clone();
    let scratch = Project::new(Id::from_u128(1), "scratch", vec![item], Vec::new());
    let mut session = EditorSession::new(scratch, SessionDeps::headless(dir.join("scratch")));
    if !session.place_media(&[media], &PlaceOptions::default()) {
        return Err(fail(422, "the media cannot be placed (no picture or sound?)"));
    }
    let timeline = session.active_timeline().cloned().ok_or_else(|| fail(422, "the media made no sequence"))?;
    Ok((session.project().clone(), timeline))
}

fn find_clip(project: &Project, id: Id) -> Option<(&Timeline, &Clip)> {
    project.timelines.iter().find_map(|t| t.tracks.iter().find_map(|tr| tr.clip(id)).map(|c| (t, c)))
}

fn snapshot(project: &Project) -> ExportSnapshot {
    ExportSnapshot { timelines: project.timelines.clone(), media: project.media.clone(), use_proxies_for_export: false }
}

impl ApiBridge {
    /// The entry the router calls.
    pub(crate) fn perceive_request(&self, request: &PerceiveRequest, cancel: &AtomicBool) -> Result<Value, PerceiveError> {
        if let PerceiveRequest::ImportPremiere { path, dry_run } = request {
            return self.import_premiere(path, *dry_run);
        }
        if matches!(request, PerceiveRequest::CaptionStyles) {
            return Ok(json!({
                "styles": CAPTION_STYLES,
                "lookKeys": ["wordsPerCaption", "size", "color", "shadow", "box", "positionY", "font", "weight"],
                "animations": ["caption-pop"],
                "layouts": ["wordByWord", "lines"],
                "positions": ["top", "center", "bottom"],
            }));
        }
        if matches!(request, PerceiveRequest::Fonts) {
            // The same list the font picker of the Text and Captions panels shows (bundled + installed families).
            let families = sq_inspector_ui::text::inspector_model::TextBoxDefaults::installed_families();
            return Ok(json!({ "count": families.len(), "families": families }));
        }
        let project = self.project().ok_or_else(|| fail(503, "no project open"))?;
        let active = self.active_sequence();
        let dir = self.cache.clone();
        std::fs::create_dir_all(&dir).map_err(|e| fail(500, format!("cache folder: {e}")))?;
        match request {
            PerceiveRequest::Capture { sequence, at, width, contact_sheet } => {
                let id = sequence.or(active).ok_or_else(|| fail(404, "no sequence"))?;
                if project.timeline(id).is_none() {
                    return Err(fail(404, "unknown sequence"));
                }
                self.capture(&project, id, 0, at, *width, contact_sheet.as_ref(), &dir, cancel)
            }
            PerceiveRequest::MediaFrames { media, at, count, width } => {
                let (scratch, timeline) = scratch_timeline(&project, *media, &dir)?;
                let item = project.media(*media).ok_or_else(|| fail(404, "unknown media"))?;
                let length = item.duration.unwrap_or(timeline.duration());
                let times: Vec<Time> = if at.is_empty() {
                    let n = i64::from(count.unwrap_or(1));
                    (0..n).map(|i| Time::new(millis(length) * (2 * i + 1) / (2 * n), 1000)).collect()
                } else {
                    at.clone()
                };
                self.capture(&scratch, timeline.id, media.as_u128() & u128::from(u32::MAX), &times, *width, None, &dir, cancel)
            }
            PerceiveRequest::Levels { target, from, to } => self.levels(&project, target, *from, *to, &dir, cancel),
            PerceiveRequest::Transcript { target } => self.transcript(&project, target, cancel),
            PerceiveRequest::AddCaptions { target, style, word_by_word, position, look, words, saved_look } => {
                let source = CaptionSource { words: words.as_deref(), saved_look: saved_look.as_deref() };
                self.add_captions(&project, target, style.clone(), *word_by_word, *position, look, source, cancel)
            }
            PerceiveRequest::Scenes { .. } => Err(fail(501, "scene detection is not available through the API yet")),
            PerceiveRequest::ImportPremiere { .. } | PerceiveRequest::CaptionStyles | PerceiveRequest::Fonts => {
                Err(fail(500, "unreachable"))
            },
        }
    }

    #[allow(clippy::too_many_arguments, reason = "one value per wire field")]
    fn capture(
        &self,
        project: &Project,
        sequence: Id,
        tag: u128,
        at: &[Time],
        width: Option<u32>,
        sheet: Option<&ContactSheet>,
        dir: &Path,
        cancel: &AtomicBool,
    ) -> Result<Value, PerceiveError> {
        let backend = self.perceive.clone().ok_or_else(|| fail(501, "this build has no frame renderer"))?;
        let snap = snapshot(project);
        let (at, sheet, dir) = (at.to_vec(), sheet.cloned(), dir.to_path_buf());
        // Many frames take longer than the connection deadline: the work runs as a job and answers with the frames when it
        // finishes within `JOB_WAIT`, else with the job's id (the same way export and captions answer).
        let canceled = Arc::new(AtomicBool::new(false));
        self.run_job("capture", cancel, move |_| {
            capture_frames(&backend, &snap, sequence, tag, &at, width, sheet.as_ref(), &dir, &canceled)
        })
    }

    /// Loudness (LUFS, true peak) and silence ranges of a media item, a clip or a sequence (or a part of it).
    fn levels(
        &self,
        project: &Project,
        target: &Target,
        from: Option<Time>,
        to: Option<Time>,
        dir: &Path,
        cancel: &AtomicBool,
    ) -> Result<Value, PerceiveError> {
        use sq_export::core::error::CancelToken;
        use sq_export::core::loudness::LoudnessNormalizer;
        use sq_export::core::timeline_audio::TimelineAudioSource;
        use sq_export::core::traits::AudioSource;
        let (owner, timeline, mut range): (Project, Timeline, TimeRange) = match target {
            Target::Media(id) => {
                let (p, t) = scratch_timeline(project, *id, dir)?;
                let d = t.duration();
                (p, t, TimeRange::new(Time::ZERO, d))
            }
            Target::Clip(id) => {
                let (t, c) = find_clip(project, *id).ok_or_else(|| fail(404, "unknown clip"))?;
                // The clip alone (with its linked partners), as it sounds: its volume line, Audio Gain and effects count
                // (a clip at -60 dB reads as silence), the other clips under it do not.
                let keep: std::collections::BTreeSet<Id> =
                    t.linked_group(*id).map_or_else(|_| [*id].into(), |g| g.iter().map(|m| m.clip.id).collect());
                let mut alone = t.clone();
                for track in &mut alone.tracks {
                    let others: Vec<Id> = track.clips().iter().map(|x| x.id).filter(|x| !keep.contains(x)).collect();
                    others.into_iter().for_each(|x| track.remove(x));
                }
                (project.clone(), alone, c.timeline())
            }
            Target::Sequence(id) => {
                let t = project.timeline(*id).ok_or_else(|| fail(404, "unknown sequence"))?;
                (project.clone(), t.clone(), TimeRange::new(Time::ZERO, t.duration()))
            }
        };
        let end = range.end();
        let start = from.map_or(range.start, |f| f.max(range.start));
        let stop = to.map_or(end, |t| t.min(end));
        if stop <= start {
            return Err(fail(400, "from/to leave nothing to measure"));
        }
        range = TimeRange::new(start, stop - start);
        let sequences: HashMap<Id, Timeline> = owner.timelines.iter().map(|t| (t.id, t.clone())).collect();
        let paths: HashMap<Id, PathBuf> = owner.media.iter().map(|m| (m.id, PathBuf::from(&m.path))).collect();
        let feed = crate::export_audio::FeederMix::new(&timeline, sequences, paths, crate::export_audio::channel_maps(&owner.media));
        let mut source = TimelineAudioSource::new(feed, 2, range);
        let measured = LoudnessNormalizer::measure(&mut source, &CancelToken::new()).map_err(|e| fail(500, format!("{e:?}")))?;
        // Second pass over the same source: sample peak and the silences (100 ms windows below -50 dBFS, 0.4 s or longer).
        let rate = source.sample_rate().max(1) as f64;
        let (mut peak, mut frame, mut quiet_since): (f32, usize, Option<usize>) = (0.0, 0, None);
        let mut silences: Vec<(f64, f64)> = Vec::new();
        let window = (rate / 10.0) as usize;
        let (mut sum, mut count) = (0.0_f64, 0_usize);
        let note = |quiet: bool, at: usize, silences: &mut Vec<(f64, f64)>, since: &mut Option<usize>| {
            match (quiet, *since) {
                (true, None) => *since = Some(at),
                (false, Some(s)) => {
                    *since = None;
                    if (at - s) as f64 / rate >= 0.4 {
                        silences.push((s as f64 / rate, at as f64 / rate));
                    }
                }
                _ => {}
            }
        };
        while let Some(chunk) = source.next_chunk(4096).map_err(|e| fail(500, format!("{e:?}")))? {
            if cancel.load(Ordering::SeqCst) {
                return Err(fail(503, "cancelled"));
            }
            let channels = chunk.channels.max(1);
            for f in chunk.samples.chunks(channels) {
                let mono = f.iter().map(|s| s.abs()).fold(0.0_f32, f32::max);
                peak = peak.max(mono);
                sum += f64::from(mono) * f64::from(mono);
                count += 1;
                frame += 1;
                if count == window {
                    let rms_db = 10.0 * (sum / count as f64).max(1e-12).log10();
                    note(rms_db < -50.0, frame - count, &mut silences, &mut quiet_since);
                    (sum, count) = (0.0, 0);
                }
            }
        }
        note(false, frame, &mut silences, &mut quiet_since);
        let base = millis(range.start);
        let at = |s: f64| wire(Time::new(base + (s * 1000.0).round() as i64, 1000));
        Ok(json!({
            "integratedLufs": finite(measured.integrated_lufs),
            "truePeakDb": finite(measured.true_peak_db),
            "samplePeakDb": finite(20.0 * f64::from(peak).max(1e-9).log10()),
            "durationSeconds": frame as f64 / rate,
            "silences": silences.iter().map(|(a, b)| json!({ "from": at(*a), "to": at(*b) })).collect::<Vec<_>>(),
        }))
    }

    /// Words with times. Runs as a job: answers when done within a short wait, else with a job id for `GET /v1/jobs/{id}`.
    fn transcript(&self, project: &Project, target: &Target, cancel: &AtomicBool) -> Result<Value, PerceiveError> {
        let (media, clip) = match target {
            Target::Media(id) => (project.media(*id).ok_or_else(|| fail(404, "unknown media"))?.clone(), None),
            Target::Clip(id) => {
                let (t, c) = find_clip(project, *id).ok_or_else(|| fail(404, "unknown clip"))?;
                let m = project.media(c.media).ok_or_else(|| fail(404, "the clip's media is gone"))?.clone();
                (m, Some((c.clone(), t.frame_duration())))
            }
            Target::Sequence(_) => return Err(fail(400, "transcript takes a media item or a clip")),
        };
        self.run_job("transcript", cancel, move |_| transcribe_media(&media, clip))
    }

    /// Runs `work` on its own thread as a job of the API's one job map: answers with its result when it ends within a short
    /// wait, else with the job's state (`id`, `kind`, `state`, ...; plus `job`, the id) to follow with `GET /v1/jobs/{id}`.
    fn run_job(
        &self,
        kind: &'static str,
        cancel: &AtomicBool,
        work: impl FnOnce(ApiBridge) -> Result<Value, String> + Send + 'static,
    ) -> Result<Value, PerceiveError> {
        self.run_job_waiting(kind, cancel, JOB_WAIT, work)
    }

    pub(crate) fn run_job_waiting(
        &self,
        kind: &'static str,
        cancel: &AtomicBool,
        wait: Duration,
        work: impl FnOnce(ApiBridge) -> Result<Value, String> + Send + 'static,
    ) -> Result<Value, PerceiveError> {
        let slot: TaskSlot = Arc::new(Mutex::new(TaskState::Running));
        let id = self.jobs.lock().unwrap_or_else(PoisonError::into_inner).add(kind, JobEntry::Task { kind, slot: Arc::clone(&slot) });
        let (writer, bridge) = (Arc::clone(&slot), self.clone());
        std::thread::spawn(move || {
            let state = work(bridge).map_or_else(TaskState::Failed, TaskState::Done);
            *writer.lock().unwrap_or_else(PoisonError::into_inner) = state;
        });
        let started = Instant::now();
        while started.elapsed() < wait && !cancel.load(Ordering::SeqCst) {
            let state = slot.lock().unwrap_or_else(PoisonError::into_inner).clone();
            match state {
                TaskState::Running => std::thread::sleep(Duration::from_millis(20)),
                TaskState::Done(v) => return Ok(v),
                TaskState::Failed(e) => return Err(fail(job_failure_status(&e), format!("job {id} failed: {e}"))),
            }
        }
        let state = slot.lock().unwrap_or_else(PoisonError::into_inner).clone();
        if let TaskState::Done(v) = &state {
            return Ok(v.clone());
        }
        let mut info = serde_json::to_value(task_info(&id, kind, &state)).unwrap_or(Value::Null);
        if let Some(o) = info.as_object_mut() {
            o.insert("job".to_string(), json!(id));
        }
        Ok(info)
    }

    /// The app's Create Captions on the speech of a clip or a sequence: transcript, segmenting by the preset (word by word =
    /// the short-video preset), then ONE undo step "Agent: Add Captions" on the active sequence's caption track.
    #[allow(clippy::too_many_arguments, reason = "one value per wire field")]
    fn add_captions(
        &self,
        project: &Project,
        target: &Target,
        style: Option<String>,
        word_by_word: bool,
        spot: CaptionSpot,
        look: &CaptionLookSpec,
        source: CaptionSource<'_>,
        cancel: &AtomicBool,
    ) -> Result<Value, PerceiveError> {
        use sq_core_model::{CaptionHorizontal, CaptionPosition, CaptionVertical};
        use sq_transcribe::caption_segmenter::CaptionSegmenter;
        use sq_transcribe::timeline_transcription::TimelineTranscription;
        use sq_transcribe::transcript::Transcript;
        use sq_core_time::IdSource as _;
        use sq_transcribe::transcription_service::{CancelToken, Locale};
        let (timeline, clip) = match target {
            Target::Clip(id) => {
                let (t, c) = find_clip(project, *id).ok_or_else(|| fail(404, "unknown clip"))?;
                (t.clone(), Some(c.clone()))
            }
            Target::Sequence(id) => (project.timeline(*id).ok_or_else(|| fail(404, "unknown sequence"))?.clone(), None),
            Target::Media(_) => return Err(fail(400, "give a clip or a sequence")),
        };
        let media = project.media.clone();
        let looks = self.looks.clone();
        let (preset, made_look) = match source.saved_look {
            Some(name) => (saved_look_preset(looks.as_deref(), name)?, None),
            None => caption_preset_and_look(word_by_word, style, look, (timeline.format.width, timeline.frame_duration())),
        };
        let own_words: Option<Vec<sq_edit_api::perceive::CaptionWordSpec>> = source.words.map(<[_]>::to_vec);
        let vertical = match spot {
            CaptionSpot::Top => CaptionVertical::Top,
            CaptionSpot::Center => CaptionVertical::Middle,
            CaptionSpot::Bottom => CaptionVertical::Bottom,
        };
        let (vertical, offset_y) = match look.position_y {
            Some(y) => (CaptionVertical::Middle, y - 0.5),
            None => (vertical, 0.0),
        };
        let position = CaptionPosition { vertical, horizontal: CaptionHorizontal::Center, offset_x: 0.0, offset_y };
        let undo = "Agent: Add Captions";
        self.run_job("captions", cancel, move |bridge| {
            let service = crate::speech::platform_service();
            let mut ids = sq_core_time::RandomIds;
            let locale = Locale::new("auto");
            let transcript = match (&own_words, &clip) {
                (Some(list), _) => Transcript::new(
                    "und",
                    list.iter()
                        .map(|w| {
                            let range = sq_core_time::TimeRange { start: w.from, duration: w.to - w.from };
                            sq_transcribe::transcript::TranscriptWord::new(ids.next_id(), &w.text, range)
                        })
                        .collect(),
                ),
                (None, Some(c)) => {
                    let item = media.iter().find(|m| m.id == c.media).ok_or("the clip's media is gone")?;
                    let t = service
                        .transcribe(Path::new(&item.path), &locale, &mut |_| {}, &CancelToken::new(), &mut ids)
                        .map_err(|e| format!("{e:?}"))?;
                    Transcript::new(&t.language, TimelineTranscription::map_words(&t.words, c, timeline.frame_duration()))
                }
                (None, None) => {
                    let urls: BTreeMap<Id, PathBuf> = media.iter().map(|m| (m.id, PathBuf::from(&m.path))).collect();
                    TimelineTranscription::transcribe(
                        &timeline,
                        &urls,
                        &BTreeMap::new(),
                        &BTreeMap::new(),
                        service.as_ref(),
                        &locale,
                        &mut |_| {},
                        &CancelToken::new(),
                        &mut ids,
                    )
                    .map_err(|e| format!("{e:?}"))?
                }
            };
            let mut captions = CaptionSegmenter::apply_timing(&CaptionSegmenter::segment(&transcript, &preset), &preset);
            for c in &mut captions {
                c.position = Some(position);
            }
            let words = transcript.words.len();
            let sequence = timeline.id;
            let added = bridge
                .call(None, move |app, _| {
                    if app.session().active_timeline_id() != Some(sequence) {
                        return Err("the sequence is not the one shown in the timeline".to_string());
                    }
                    if let (Some(store), Some((id, look))) = (&looks, &made_look) {
                        save_look(store, *id, look);
                    }
                    let items = crate::text_host::speech_flow::caption_items(app.session(), sequence, &captions);
                    let n = items.len();
                    if n == 0 {
                        return Err("there is no speech to caption".to_string());
                    }
                    if app.session_mut().add_captions_named(items, undo) { Ok(n) } else { Err("the captions were refused".to_string()) }
                })
                .ok_or("cancelled")??;
            Ok(json!({ "added": added, "words": words, "undoName": undo, "sequence": sequence, "style": preset.style_ref, "wordByWord": word_by_word }))
        })
    }

    /// File > Import Premiere Project into the open project: the media the file names are probed, the sequences added in
    /// ONE undo step "Agent: Import Premiere". `dryRun` reports without adding.
    fn import_premiere(&self, path: &str, dry_run: bool) -> Result<Value, PerceiveError> {
        use sq_premiere_import::prdocument::PRReader;
        use sq_premiere_import::primport_report::Status;
        use sq_premiere_import::prmapper::PRMapper;
        let backend = self.perceive.clone().ok_or_else(|| fail(501, "this build cannot probe media"))?;
        let url = PathBuf::from(path);
        if url.extension().map(|e| e.to_string_lossy().to_lowercase()).as_deref() != Some("prproj") {
            return Err(fail(400, "path is not a .prproj file"));
        }
        let data = std::fs::read(&url).map_err(|e| fail(404, format!("cannot read {path}: {e}")))?;
        let doc = PRReader::read(&data).map_err(|e| fail(422, e.to_string()))?;
        let resolved = PRMapper::resolve_media(&doc, &url, Vec::new());
        let mut refs: BTreeMap<String, MediaRef> = BTreeMap::new();
        for stored in PRMapper::media_paths(&doc) {
            let Some(hit) = resolved.get(&stored) else { continue };
            if let Ok(m) = backend.probe.probe(Path::new(&hit.path)) {
                refs.insert(stored, m);
            }
        }
        let stem = url.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
        let busy = self.busy.load(Ordering::SeqCst);
        let answer = self.call(None, move |app, _| {
            if busy {
                return Err(fail(409, "busy"));
            }
            crate::edit_api_host::with_ids(app, |app, ids| {
                let result = PRMapper::map(&doc, &stem, &refs, false, ids);
                let (media_ids, timeline_ids): (Vec<Id>, Vec<Id>) =
                    (result.project.media.iter().map(|m| m.id).collect(), result.project.timelines.iter().map(|t| t.id).collect());
                if !dry_run {
                    let added = result.project.clone();
                    app.session_mut()
                        .try_perform("Agent: Import Premiere", None, |p| {
                            p.media.extend(added.media.iter().cloned());
                            p.timelines.extend(added.timelines.iter().cloned());
                            Ok::<(), sq_core_model::EditError>(())
                        })
                        .map_err(|e| fail(422, format!("{e:?}")))?;
                }
                let entries: Vec<Value> = result
                    .report
                    .entries()
                    .iter()
                    .map(|e| json!({ "feature": e.feature, "status": e.status.label(), "count": e.count, "note": e.note }))
                    .collect();
                let count = |s: Status| result.report.entries().iter().filter(|e| e.status == s).map(|e| e.count).sum::<i64>();
                let sequences: Vec<Value> = result
                    .project
                    .timelines
                    .iter()
                    .map(|t| json!({ "id": t.id, "name": t.name, "durationSeconds": millis(t.duration()) as f64 / 1000.0 }))
                    .collect();
                Ok(json!({
                    "applied": !dry_run,
                    "undoName": "Agent: Import Premiere",
                    "sequences": sequences,
                    "sequenceIds": timeline_ids,
                    "mediaIds": media_ids,
                    "mapped": count(Status::Mapped),
                    "approximated": count(Status::Approximated),
                    "dropped": count(Status::Dropped),
                    "summary": result.report.summary(),
                    "report": entries,
                }))
            })
        });
        answer.unwrap_or_else(|| Err(fail(503, "cancelled")))
    }
}

/// The frames (and contact sheet) of a capture; errors read `render at <timecode>: <reason>`.
#[allow(clippy::too_many_arguments, reason = "one value per wire field")]
fn capture_frames(
    backend: &PerceiveBackend,
    snap: &ExportSnapshot,
    sequence: Id,
    tag: u128,
    at: &[Time],
    width: Option<u32>,
    sheet: Option<&ContactSheet>,
    dir: &Path,
    cancel: &AtomicBool,
) -> Result<Value, String> {
    let stamp = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_millis());
    let render = |t: Time, w: Option<usize>| -> Result<RgbaImage, String> {
        if cancel.load(Ordering::SeqCst) {
            return Err("cancelled".to_string());
        }
        (backend.render)(snap, sequence, t, w).map_err(|e| format!("render at {}: {e}", timecode(t)))
    };
    let mut frames = Vec::new();
    for (n, t) in at.iter().enumerate() {
        let image = render(*t, width.map(|w| w as usize))?;
        let path = dir.join(format!("frame-{stamp}-{tag:x}-{n}.png"));
        write_png(&path, image.width, image.height, &image.pixels)?;
        frames.push(json!({ "at": wire(*t), "timecode": timecode(*t), "path": path, "width": image.width, "height": image.height }));
    }
    let mut reply = json!({ "sequence": sequence, "frames": frames });
    if let Some(s) = sheet {
        let (a, b) = (millis(s.from), millis(s.to));
        let steps = i64::from(s.count.max(2) - 1);
        let mut tiles = Vec::new();
        for i in 0..i64::from(s.count) {
            let ms = if s.count == 1 { a } else { a + (b - a) * i / steps };
            let t = Time::new(ms, 1000);
            tiles.push((t, render(t, Some(320))?));
        }
        let image = contact_sheet(&tiles).ok_or("no tiles")?;
        let path = dir.join(format!("sheet-{stamp}-{tag:x}.png"));
        write_png(&path, image.width, image.height, &image.pixels)?;
        reply["contactSheet"] = json!({
            "path": path, "width": image.width, "height": image.height,
            "tiles": tiles.iter().map(|(t, _)| json!({ "at": wire(*t), "timecode": timecode(*t) })).collect::<Vec<_>>(),
        });
    }
    Ok(reply)
}

/// The HTTP status of a failed job: a file that does not open is the request's fault (422), the rest a 500.
fn job_failure_status(message: &str) -> u16 {
    if message.contains("render at ") && message.contains(": open ") { 422 } else { 500 }
}

/// What `addCaptions` captions: the speech (both `None`), its own words, and/or a saved look by name.
#[derive(Clone, Copy)]
struct CaptionSource<'a> {
    words: Option<&'a [sq_edit_api::perceive::CaptionWordSpec]>,
    saved_look: Option<&'a str>,
}

/// The preset of a look saved in the user's Look store (read only), found by name like the Captions panel lists it: its
/// segmentation, and its style registered so the captions render through the one caption renderer.
fn saved_look_preset(store: Option<&sq_editor_session::LookStore>, name: &str) -> Result<sq_transcribe::caption_preset::CaptionPreset, PerceiveError> {
    use sq_editor_session::{CaptionLookStore, LookStoreCaptions};
    let store = store.ok_or_else(|| fail(501, "this build has no Look store"))?;
    let all = LookStoreCaptions(store).user_looks();
    let want = name.trim();
    let hit = all.iter().find(|l| l.name == want).or_else(|| all.iter().find(|l| l.name.eq_ignore_ascii_case(want)));
    let Some(hit) = hit else {
        let names: Vec<&str> = all.iter().map(|l| l.name.as_str()).take(20).collect();
        return Err(fail(404, format!("no saved caption look '{want}'; saved: {}", names.join(", "))));
    };
    let mut preset = hit.segmentation.clone();
    preset.style_ref = sq_text::caption_presets::CaptionLookRegistry::shared().register(hit.look.clone(), &hit.id.to_string()).0;
    preset.emphasis = sq_transcribe::caption_preset::CaptionEmphasis::None;
    Ok(preset)
}

/// The preset of `addCaptions`: word by word = the short-video preset (one word per caption), else the standard one.
/// A look (the named style "paul" or any look key) becomes a Caption Look in the registry the Captions panel's saved
/// looks use, so the captions render through the one caption renderer.
#[cfg(test)]
fn caption_preset(word_by_word: bool, style: Option<String>, look: &CaptionLookSpec) -> sq_transcribe::caption_preset::CaptionPreset {
    caption_preset_and_look(word_by_word, style, look, (1080, Time::new(1, 30))).0
}

/// The preset of `addCaptions` and the made look (its id and values) when the request carried look keys: the caller saves it to the
/// Look store so the captions' style ref still resolves after the project is saved and reopened.
fn caption_preset_and_look(
    word_by_word: bool,
    style: Option<String>,
    look: &CaptionLookSpec,
    (frame_width, frame_duration): (i64, Time),
) -> (sq_transcribe::caption_preset::CaptionPreset, Option<(Id, sq_text::caption_presets::CaptionLook)>) {
    use sq_transcribe::caption_preset::{CaptionEmphasis, CaptionPreset};
    let mut preset = match look.words_per_caption {
        Some(n) if n > 1 => {
            let mut p = CaptionPreset::short_video();
            p.max_words_per_caption = Some(i64::from(n));
            p.max_chars_per_line = 40;
            p.pause_break = sq_core_time::Time::new(1, 2);
            p
        }
        _ if word_by_word => CaptionPreset::short_video(),
        _ => CaptionPreset::standard(),
    };
    let is_paul = style.as_deref() == Some("paul");
    let mut look = look.clone();
    if is_paul && look.size.is_none() {
        // The editor's captions are Inter Bold ~70 px on a 1080 px wide frame; other frames scale with their width.
        look.size = Some((PAUL_SIZE_AT_1080 * frame_width as f64 / 1080.0).round().max(1.0));
    }
    let look = &look;
    if let Some(s) = style {
        preset.style_ref = if s == "paul" { "default".to_string() } else { s };
    }
    let mut made = None;
    if !look.is_empty() {
        let (id, made_look) = make_look(&preset.style_ref, look, is_paul.then_some(frame_duration));
        preset.style_ref = sq_text::caption_presets::CaptionLookRegistry::shared().register(made_look.clone(), &id.to_string()).0;
        made = Some((id, made_look));
        preset.emphasis = CaptionEmphasis::None;
    }
    (preset, made)
}

/// Saves a look made by the API in the app's Look store (what the Captions panel's "save look" does), or updates it when the
/// same look was saved before (the id follows the look's values, so asking twice makes one entry).
fn save_look(store: &sq_editor_session::LookStore, id: Id, look: &sq_text::caption_presets::CaptionLook) {
    use sq_editor_session::{CaptionLookStore, LookStoreCaptions};
    let mut captions = LookStoreCaptions(store);
    if captions.user_looks().iter().any(|l| l.id == id) {
        captions.update(id, look, None);
    } else {
        // Named by its values so it is found in the panel's list; the segmentation is the standard one (the captions carry theirs).
        let name = format!("API look {:.0} pt", look.style.size);
        captions.add(id, &name, look, &sq_transcribe::caption_preset::CaptionPreset::standard());
    }
}

/// Font size of the named style "paul" on a 1080 px wide frame (measured on the editor's own Premiere captions).
const PAUL_SIZE_AT_1080: f64 = 70.0;

/// The pop of the named style "paul" through the caption animation model: scale 90 % at the start, 105 % at frame 3,
/// 100 % at frame 4, linear (as decoded from the editor's .prproj captions).
fn paul_pop(frame: Time) -> sq_core_model::anchored_animation::KeyframeTemplate {
    use sq_core_model::anchored_animation::{AnimationAnchor, AnimationTrack, KeyframeTemplate, SegmentShape};
    let at = |n: i64| Time::new(frame.value() * n, frame.timescale());
    KeyframeTemplate {
        tracks: vec![AnimationTrack::from_shapes(
            "scale",
            &[(Time::ZERO, 0.9, SegmentShape::Linear), (at(3), 1.05, SegmentShape::Linear), (at(4), 1.0, SegmentShape::Linear)],
        )],
        duration: at(4),
        anchor: AnimationAnchor::Start,
        ..KeyframeTemplate::none()
    }
}

/// The look of `base` changed by `look`, with an id that follows its values.
fn make_look(base: &str, look: &CaptionLookSpec, pop_frame: Option<Time>) -> (Id, sq_text::caption_presets::CaptionLook) {
    use sq_edit_api::perceive::Part;
    use sq_text::caption_presets::{CaptionLook, CaptionPresetLibrary};
    use sq_text::text_style::{BoxPadding, FontWeight, RGBAColor, TextBackground, TextShadow};
    let mut style = CaptionPresetLibrary::base().style(Some(base));
    if let Some(s) = look.size {
        style.size = s;
    }
    if let Some([r, g, b, a]) = look.color {
        style.color = RGBAColor::new(r, g, b, a);
    }
    if let Some(f) = &look.font {
        style.font_name.clone_from(f);
    }
    if let Some(w) = look.weight.and_then(FontWeight::from_raw) {
        style.weight = w;
    }
    match look.shadow {
        Some(Part::Off) => style.shadow = None,
        Some(Part::On(sh)) => style.shadow = Some(TextShadow::new(RGBAColor::new(0.0, 0.0, 0.0, sh.opacity), 0.0, sh.offset, sh.blur)),
        None => {}
    }
    match look.box_ {
        Some(Part::Off) => style.background = None,
        Some(Part::On(b)) => {
            // Padding of the kit pill: 0.40 em across, 0.16 em up and down.
            let padding = BoxPadding::new(style.size * 0.40, style.size * 0.16);
            style.background = Some(TextBackground::new(RGBAColor::new(b.color[0], b.color[1], b.color[2], b.color[3]), padding, b.radius));
        }
        None => {}
    }
    let animation = match pop_frame {
        Some(frame) => paul_pop(frame),
        None => CaptionLook::default_look().animation,
    };
    let json = serde_json::to_string(&(&style, &animation)).unwrap_or_default();
    let mut h = std::collections::hash_map::DefaultHasher::new();
    std::hash::Hash::hash(&json, &mut h);
    // A fixed tag in the high half keeps these ids apart from the random ones of panel looks.
    let id = Id::from_u128((0x4150_494c_4f4f_4b00_u128 << 64) | u128::from(std::hash::Hasher::finish(&h)));
    (id, CaptionLook::new(style, animation))
}

fn finite(v: f64) -> Value {
    if v.is_finite() { json!((v * 100.0).round() / 100.0) } else { Value::Null }
}

/// Transcribes one media file; a clip maps the words into its sequence's time.
fn transcribe_media(media: &MediaRef, clip: Option<(Clip, Time)>) -> Result<Value, String> {
    use sq_transcribe::timeline_transcription::TimelineTranscription;
    use sq_transcribe::transcription_service::{CancelToken, Locale};
    let service = crate::speech::platform_service();
    let transcript = service
        .transcribe(Path::new(&media.path), &Locale::new("auto"), &mut |_| {}, &CancelToken::new(), &mut sq_core_time::RandomIds)
        .map_err(|e| format!("{e:?}"))?;
    let words = match &clip {
        Some((c, frame)) => TimelineTranscription::map_words(&transcript.words, c, *frame),
        None => transcript.words.clone(),
    };
    let text = words.iter().map(|w| w.text.as_str()).collect::<Vec<_>>().join(" ");
    let list: Vec<Value> = words
        .iter()
        .map(|w| json!({ "text": w.text, "from": wire(w.range.start), "to": wire(w.range.end()), "confidence": w.confidence }))
        .collect();
    Ok(json!({ "language": transcript.language, "inSequenceTime": clip.is_some(), "text": text, "words": list }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_transcribe::caption_segmenter::CaptionSegmenter;
    use sq_transcribe::transcript::{Transcript, TranscriptWord};

    #[test]
    fn a_saved_look_is_found_by_name_read_only_and_its_style_resolves() {
        use sq_editor_session::{CaptionLookStore, LookStore, LookStoreCaptions};
        let store = LookStore::new(None, None, None, None);
        let mut look = sq_text::caption_presets::CaptionLook::default_look();
        look.style.size = 64.0;
        let seg = sq_transcribe::caption_preset::CaptionPreset::short_video();
        assert!(LookStoreCaptions(&store).add(Id::from_u128(77), "Caption Look 1", &look, &seg));
        let preset = saved_look_preset(Some(&store), "caption look 1").expect("found by name, any case");
        assert_eq!(preset.max_words_per_caption, seg.max_words_per_caption);
        assert_eq!(sq_text::caption_presets::CaptionLookRegistry::shared().library(None, false).style(Some(&preset.style_ref)).size, 64.0);
        let miss = saved_look_preset(Some(&store), "nope").expect_err("unknown name");
        assert!(miss.status == 404 && miss.message.contains("Caption Look 1"));
        assert_eq!(saved_look_preset(None, "x").err().map(|e| e.status), Some(501));
        assert_eq!(LookStoreCaptions(&store).user_looks().len(), 1);
    }

    fn paul_look() -> CaptionLookSpec {
        CaptionLookSpec::paul()
    }

    #[test]
    fn style_paul_is_white_with_a_soft_shadow_and_no_box_in_the_caption_library() {
        use sq_text::caption_presets::CaptionLookRegistry;
        let look = paul_look();
        let preset = caption_preset(false, Some("paul".into()), &look);
        assert!(preset.style_ref.starts_with("look-"), "{}", preset.style_ref);
        assert_eq!(preset.max_words_per_caption, Some(2));
        let style = CaptionLookRegistry::shared().library(None, false).style(Some(&preset.style_ref));
        assert_eq!((style.color.red, style.color.green, style.color.blue), (1.0, 1.0, 1.0));
        assert!(style.background.is_none());
        let shadow = style.shadow.expect("soft shadow");
        assert_eq!((shadow.blur, shadow.opacity()), (8.0, 0.6));
        assert_eq!(style.font_name, "Inter-Bold");
    }

    #[test]
    fn a_look_made_by_add_captions_is_in_the_look_store_file_and_resolves_after_a_restart() {
        let dir = std::env::temp_dir().join(format!("sq-api-look-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("temp folder");
        let url = dir.join("looks.json");
        let store = sq_editor_session::LookStore::new(Some(url.clone()), None, None, None);
        let (preset, made) = caption_preset_and_look(false, Some("paul".into()), &paul_look(), (1080, Time::new(1, 30)));
        let (id, look) = made.expect("a look");
        save_look(&store, id, &look);
        save_look(&store, id, &look);
        // A second process: a fresh store on the same file.
        let reopened = sq_editor_session::LookStore::new(Some(url), None, None, None);
        assert_eq!(reopened.library().user().len(), 1, "asking twice made two entries");
        assert_eq!(preset.style_ref, sq_text::caption_presets::CaptionLook::style_id(&id.to_string()));
        let style = reopened.library().user()[0].caption_look().style;
        assert_eq!(style.font_name, "Inter-Bold");
        assert!(style.shadow.is_some() && style.background.is_none());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_box_key_makes_the_pill_and_word_cap_one_is_word_by_word() {
        use sq_edit_api::perceive::{BoxSpec, Part};
        use sq_text::caption_presets::CaptionLookRegistry;
        let look = CaptionLookSpec { box_: Some(Part::On(BoxSpec { color: [1.0, 0.0, 0.0, 1.0], radius: 9.0 })), words_per_caption: Some(1), ..Default::default() };
        let preset = caption_preset(true, None, &look);
        assert_eq!(preset.max_words_per_caption, Some(1));
        let bg = CaptionLookRegistry::shared().library(None, false).style(Some(&preset.style_ref)).background.expect("pill");
        assert_eq!((bg.color.red, bg.corner_radius), (1.0, 9.0));
    }

    /// The editor's own captions: ~70 px on a 1080 px wide frame, and the pop 90 % -> 105 % (frame 3) -> 100 % (frame 4), linear.
    #[test]
    fn style_paul_is_70_px_at_1080_wide_and_pops_90_105_100_by_frame() {
        let fd = Time::new(1, 30);
        let (_, made) = caption_preset_and_look(false, Some("paul".into()), &paul_look(), (1080, fd));
        let look = made.expect("a look");
        let size = look.1.style.size;
        assert!((60.0..=80.0).contains(&size), "size {size}");
        let scale = look.1.animation.tracks.iter().find(|t| t.property == "scale").expect("scale track");
        let at = |n: i64| scale.value_at(Time::new(n, 30)).expect("value");
        assert_eq!((at(0), at(3), at(4)), (0.9, 1.05, 1.0));
        assert!((at(1) - 0.95).abs() < 1e-9 && (at(5) - 1.0).abs() < 1e-9, "linear between the keys");
        // A wider frame scales the size; an explicit size wins.
        let wide = caption_preset_and_look(false, Some("paul".into()), &paul_look(), (2160, fd)).1.expect("look").1.style.size;
        assert_eq!(wide, 140.0);
        let own = CaptionLookSpec { size: Some(50.0), ..paul_look() };
        assert_eq!(caption_preset_and_look(false, Some("paul".into()), &own, (1080, fd)).1.expect("look").1.style.size, 50.0);
    }

    #[test]
    fn a_job_failure_that_names_an_unopenable_file_is_a_422() {
        assert_eq!(job_failure_status("render at 00:00:01.000: open /a.mp4: no decoder"), 422);
        assert_eq!(job_failure_status("render at 00:00:01.000: decode error"), 500);
    }

    #[test]
    fn fonts_lists_families() {
        let families = sq_inspector_ui::text::inspector_model::TextBoxDefaults::installed_families();
        assert!(!families.is_empty());
    }

    #[test]
    fn word_by_word_gives_one_caption_per_word_and_off_gives_phrases() {
        // 10 s of continuous speech: 25 words of 0.4 s without pauses.
        let words: Vec<TranscriptWord> = (0..25)
            .map(|i| TranscriptWord::new(Id::from_u128(i + 1), &format!("word{i}"), TimeRange::new(Time::new(i as i64 * 4, 10), Time::new(4, 10))))
            .collect();
        let t = Transcript::new("en", words);
        let one = caption_preset(true, Some("pill".into()), &CaptionLookSpec::default());
        assert_eq!(one.style_ref, "pill");
        let caps = CaptionSegmenter::apply_timing(&CaptionSegmenter::segment(&t, &one), &one);
        assert_eq!(caps.len(), 25);
        assert!(CaptionSegmenter::segment(&t, &caption_preset(false, None, &CaptionLookSpec::default())).len() < 25);
    }
}
