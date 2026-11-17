// Swift: ShellExport.swift `showExport`, ShellExportSheet.swift (the flow around the drawn sheet)
//! File > Export: the 860 x 640 sheet ([`ShellExportSheet`]) over the shared [`ExportDialogModel`], then the preflight
//! questions, the queue and the progress ([`ShellHost::export_after_sheet`]). Quick Export ([`ShellHost::quick_export`])
//! runs the same model without the sheet.
//!
//! The sheet edits the model live; this flow does what only it can: the folder chooser, the stems, the cut-downs, the audio
//! check and the preview frame. The preview renders on a worker ([`PreviewWorker`]) and follows the model and the scrub bar;
//! it sits in its image slot [`EXPORT_PREVIEW_SLOT`], the Slip two-up slot: no Slip drag runs under a modal sheet, while the
//! scopes (slots 2 and 3) stay drawn behind it.
//!
//! shortcut: the sheet polls the worker on a 100 ms timer; upgrade with a wake from the worker.

use crate::shell_dialog::{FormValue, ShellDialog};
use crate::shell_export::{ExportSubmit, ShellExport};
use crate::shell_export_content::{SharedModel, ShellExportSheet};
use crate::shell_export_preview::{At, PreviewJob, PreviewShot, PreviewWorker};
use crate::shell_flows::ShellRoot;
use crate::shell_form::PreviewTransport;
use crate::shell_host::{ShellEvent, ShellHost};
use crate::shell_live::{Live, LiveAsk};
use sq_core_time::{Id, Time};
use sq_draw::RgbaImage;
use sq_editor_session::{ExportDialogModel, ExportPreviewMath};
use sq_export::core::error::CancelToken;
use sq_export::core::error::ExportDecodeError;
use sq_export::core::preset::ExportPreset;
use sq_export::core::queue::{ExportJobState, ExportJobStatus, ExportQueue};
use sq_export::core::settings::VideoCodec;
use sq_runtime::UiRef;
use sq_uikit::editor_command::EditorCommand;
use sq_uikit::localization::SQL10n;
use sq_uikit::sqdialog_model::{SQDialogResponse, SQDialogRole};
use sq_uikit::sqicon::SQIcon;
use std::cell::{Cell, RefCell};
use std::future::{Future, poll_fn};
use std::path::Path;
use std::pin::pin;
use std::rc::Rc;
use std::sync::{Arc, Mutex, PoisonError};
use std::task::Poll;
use std::time::{Duration, Instant};

/// The commands of the sheet's "Other Formats\u{2026}" menu (`ShellHost.otherExportFormats`).
const OTHER_FORMATS: [EditorCommand; 6] = [
    EditorCommand::ExportFrame,
    EditorCommand::ExportMarkersCSV,
    EditorCommand::ExportEDL,
    EditorCommand::ExportFCPXML,
    EditorCommand::ExportFinalCutXML,
    EditorCommand::ExportOpenTimelineIO,
];
/// The renderer image slot of the preview picture. A seventh slot needs a shader change (`DrawQuads.slang` binds six).
pub const EXPORT_PREVIEW_SLOT: usize = 1;

/// How long the open sheet waits for a change before it looks at the preview worker and the playhead again.
const TICK: Duration = Duration::from_millis(100);

/// Cut-down jobs the open sheet started and still follows.
struct CutRun {
    ids: Vec<Id>,
    queue: Arc<ExportQueue>,
}

/// How often a playing preview asks for its next frame (the newest request wins, late frames are skipped).
const PLAY_TICK: Duration = Duration::from_millis(30);

/// Where the preview is (it opens on the playhead, then has its own position) and whether it plays.
struct PreviewState {
    index: usize,
    count: usize,
    duration: Time,
    /// Position wanted before the first frame told the count.
    fraction: f64,
    playing: Option<(Instant, usize)>,
}

impl PreviewState {
    fn new() -> PreviewState {
        PreviewState { index: 0, count: 0, duration: Time::new(1, 30), fraction: 0.0, playing: None }
    }

    /// Opens on the frame the editor shows at `playhead` (clamped into the exported range).
    fn at_playhead(model: &ExportDialogModel, playhead: Time) -> PreviewState {
        let fraction = ExportPreviewMath::playhead_fraction(playhead, model.exported_range());
        PreviewState { fraction, ..PreviewState::new() }
    }

    fn at(&self) -> At {
        if self.count > 0 { At::Index(self.index) } else { At::Fraction(self.fraction) }
    }

    fn transport(&self) -> PreviewTransport {
        let tc_time = Time::new(self.duration.value() * self.index as i64, self.duration.timescale());
        PreviewTransport {
            frames: self.count,
            fraction: if self.count > 0 {
                ExportPreviewMath::fraction(self.index as i64, self.count as i64)
            } else {
                self.fraction
            },
            playing: self.playing.is_some(),
            timecode: ExportDecodeError::timecode(tc_time, self.duration),
        }
    }

    fn fps(&self) -> f64 {
        self.duration.timescale() as f64 / self.duration.value().max(1) as f64
    }

    /// A form answer (`preview_play`, `preview_scrub`, `preview_step`) moves the position; true = ask for that frame.
    fn apply(&mut self, id: &str, v: &FormValue) -> bool {
        match (id, v) {
            ("preview_play", FormValue::Bool(true)) if self.count > 0 => {
                // `ShellExportPreview.togglePlay`: from the last frame it starts again at the first.
                if self.index + 1 >= self.count {
                    self.index = 0;
                }
                self.playing = Some((Instant::now(), self.index));
                true
            }
            ("preview_play", _) => {
                self.playing = None;
                false
            }
            ("preview_scrub", FormValue::Number(f)) if self.count > 0 => {
                self.playing = None;
                self.index = ExportPreviewMath::index(*f, self.count as i64) as usize;
                true
            }
            ("preview_step", FormValue::Index(d)) if self.count > 0 => {
                self.playing = None;
                self.index = (self.index as i64 + d).clamp(0, self.count as i64 - 1) as usize;
                true
            }
            _ => false,
        }
    }

    /// The next frame of a playing preview at the sequence rate; the last frame ends it.
    fn advance(&mut self) -> bool {
        let Some((t0, start)) = self.playing else { return false };
        let next = start + (t0.elapsed().as_secs_f64() * self.fps()) as usize;
        if next + 1 >= self.count {
            (self.index, self.playing) = (self.count.saturating_sub(1), None);
        } else {
            self.index = next;
        }
        true
    }

    /// A rendered frame tells the source's size and rate.
    fn learn(&mut self, shot: &PreviewShot) {
        let first = self.count == 0;
        (self.count, self.duration) = (shot.count, shot.duration);
        if first {
            self.index = ExportPreviewMath::playhead_index(self.fraction, shot.count as i64) as usize;
        }
        self.index = self.index.min(shot.count.saturating_sub(1));
    }
}

/// What woke the open sheet.
enum Tick {
    Live(Live),
    Timer,
}
impl ShellHost {
    /// File > Export… (`showExport`): the sheet, then the submit; a canceled preflight question opens the sheet again.
    #[allow(clippy::await_holding_refcell_ref)] // shortcut: see the note at the `export_after_sheet` call
    pub async fn show_export<R: ShellRoot + ?Sized>(h: UiRef<R>) {
        let Some(Some(model)) = h.with(|r| {
            let p = r.shell_parts();
            p.shell.prepare_export_model(p.session)
        }) else {
            return;
        };
        let model: SharedModel = Rc::new(RefCell::new(model));
        let worker = PreviewWorker::default();
        let playhead = h.with(|r| r.shell_parts().session.playhead()).unwrap_or(Time::ZERO);
        let mut pv = PreviewState::at_playhead(&model.borrow(), playhead);
        let mut last_sequence = model.borrow().selected_id();
        loop {
            let Some(offered) = h.with(|r| {
                let export = &r.shell_parts().shell.export;
                ShellExport::presets(&export.codecs, export.file_outputs)
            }) else {
                return;
            };
            let codecs = Self::offered_codecs(&offered);
            let sheet = ShellExportSheet::new(Rc::clone(&model), offered, codecs, true, true, EXPORT_PREVIEW_SLOT);
            let other = Rc::new(Cell::new(None));
            let d = Self::export_sheet(&model, &sheet, &other);
            let Some(mut live) = Self::present_live(&h, d) else { return };
            if Self::refresh_preview(&h, &model, &worker, &pv, &sheet).is_none() {
                return;
            }
            let mut cuts: Option<CutRun> = None;
            let answered = loop {
                match Self::next_or_tick(&mut live, &h, if pv.playing.is_some() { PLAY_TICK } else { TICK }).await {
                    None => return,
                    Some(Tick::Timer) => {
                        if pv.advance() && Self::refresh_preview(&h, &model, &worker, &pv, &sheet).is_none() {
                            return;
                        }
                        if let Some(done) = worker.take() {
                            if let Some(shot) = &done {
                                pv.learn(shot);
                            }
                            let _ =
                                h.with(|r| Self::show_preview(r.shell_parts().shell, &sheet, done.map(|s| s.image)));
                        }
                        if Self::push_transport(&pv, &sheet).is_none() {
                            return;
                        }
                        if let Some(run) = cuts.as_ref() {
                            let Some(finished) = Self::follow_cut_downs(&h, run) else { return };
                            if finished {
                                cuts = None;
                                sheet.rebuild();
                            }
                        }
                    }
                    Some(Tick::Live(Live::Answered(a))) => break a,
                    Some(Tick::Live(Live::Changed(changes))) => {
                        for (id, value) in &changes {
                            let ok = match id.as_str() {
                                "preview_play" | "preview_scrub" | "preview_step" => {
                                    let moved = pv.apply(id, value);
                                    Self::push_transport(&pv, &sheet);
                                    if moved {
                                        Self::refresh_preview(&h, &model, &worker, &pv, &sheet)
                                    } else {
                                        Some(())
                                    }
                                }
                                "model" => {
                                    // Another sequence starts at its first frame; the same one keeps the position.
                                    let now = model.borrow().selected_id();
                                    if now != last_sequence {
                                        last_sequence = now;
                                        (pv.index, pv.fraction) = (0, 0.0);
                                    }
                                    Self::refresh_preview(&h, &model, &worker, &pv, &sheet)
                                }
                                "folder" => Self::choose_folder(&h, &model, &sheet).await,
                                "stems_run" => Self::run_stems(&h, &model, &sheet).await,
                                "audio_check" => Self::run_audio_check(&h, &model, &sheet).await,
                                "cuts_run" => Self::start_cut_downs(&h, &model).await.map(|run| {
                                    cuts = run.or(cuts.take());
                                    sheet.rebuild();
                                }),
                                _ => Some(()),
                            };
                            if ok.is_none() {
                                return;
                            }
                        }
                    }
                }
            };
            // Closed any way (Export, Cancel, Other Formats): the picks stay for the next opening.
            if h.with(|r| r.shell_parts().shell.remember_export_choices(&model.borrow())).is_none() {
                return;
            }
            if let Some(n) = other.get() {
                let _ = h.with(|r| r.shell_parts().shell.emit(ShellEvent::RunCommand(OTHER_FORMATS[n])));
                return;
            }
            if answered != SQDialogResponse::FIRST {
                // The sheet closed while cut-downs still write: follow them like any export.
                if let Some(run) = cuts
                    && let Some(Some(queue)) = h.with(|r| r.shell_parts().shell.export.queue.clone())
                {
                    Self::follow_exports(&h, &run.ids, &queue).await;
                }
                return;
            }
            let problems = model.borrow().validation_messages();
            if !problems.is_empty() {
                let _ = h.with(|r| r.shell_parts().shell.present_message("Cannot export", &problems.join("\n"), None));
                continue;
            }
            // shortcut: the model stays borrowed across the await; the sheet is closed here and nothing else reads this model
            // until the call returns. Upgrade when `export_after_sheet` takes the model by value.
            let submit = Self::export_after_sheet(h.clone(), &mut model.borrow_mut()).await;
            if submit != ExportSubmit::BackToSheet {
                return;
            }
        }
    }

    /// The next form change, the answer, or a tick of the timer; `None` when the root is gone.
    async fn next_or_tick<R: ShellRoot + ?Sized>(live: &mut LiveAsk, h: &UiRef<R>, tick: Duration) -> Option<Tick> {
        let mut next = pin!(live.next(h));
        let mut nap = pin!(sq_runtime::sleep(tick));
        poll_fn(|cx| {
            if let Poll::Ready(l) = next.as_mut().poll(cx) {
                return Poll::Ready(l.map(Tick::Live));
            }
            match nap.as_mut().poll(cx) {
                Poll::Ready(Ok(())) => Poll::Ready(Some(Tick::Timer)),
                Poll::Ready(Err(_)) => Poll::Ready(None),
                Poll::Pending => Poll::Pending,
            }
        })
        .await
    }

    /// Asks the worker for the frame at the preview's position; a format without a preview hides the picture. `None` when
    /// the root is gone.
    fn refresh_preview<R: ShellRoot + ?Sized>(
        h: &UiRef<R>,
        model: &SharedModel,
        worker: &PreviewWorker,
        pv: &PreviewState,
        sheet: &ShellExportSheet,
    ) -> Option<()> {
        let at = pv.at();
        let asked = h.with(|r| {
            let pixels = r.shell_parts().shell.export.frame_pixels.clone();
            let Some(job) = pixels.and_then(|p| PreviewJob::new(&model.borrow(), at, &p)) else { return false };
            worker.request(job);
            true
        })?;
        if !asked {
            sheet.set_picture(16, 9, false);
        }
        Self::push_transport(pv, sheet)
    }

    /// The scrub bar under the picture shows the preview's position.
    fn push_transport(pv: &PreviewState, sheet: &ShellExportSheet) -> Option<()> {
        sheet.set_transport(pv.transport());
        Some(())
    }

    /// Puts a finished preview into its image slot and shows it (a failed render hides the picture).
    fn show_preview(shell: &mut ShellHost, sheet: &ShellExportSheet, picture: Option<RgbaImage>) {
        let ready = picture.is_some();
        let (width, height) = picture.as_ref().map_or((16, 9), |i| (i.width as i64, i.height as i64));
        if let Some(image) = picture {
            shell.export.uploads.push((EXPORT_PREVIEW_SLOT, image));
        }
        sheet.set_picture(width, height, ready);
        // The picture arrives from a worker while no input event follows: ask the app for a frame, or the old picture stays
        // on screen until the next mouse move (Windows: the sheet showed an empty box).
        shell.request_frame();
    }

    /// The folder button: asks for a folder and puts it into the model.
    async fn choose_folder<R: ShellRoot + ?Sized>(
        h: &UiRef<R>,
        model: &SharedModel,
        sheet: &ShellExportSheet,
    ) -> Option<()> {
        let ask = h.with(|r| r.shell_parts().files.choose_folder(&SQL10n::string("Choose")))?;
        if let Some(dir) = ask.await {
            model.borrow_mut().set_output_directory(Some(dir));
            sheet.rebuild();
        }
        Some(())
    }

    /// Waits for a worker's answer; the sheet being closed (Cancel) stops it. `None` when the root is gone.
    async fn wait_for<R: ShellRoot + ?Sized, T>(
        h: &UiRef<R>,
        outcome: &Arc<Mutex<Option<T>>>,
        cancel: &CancelToken,
    ) -> Option<T> {
        loop {
            if let Some(done) = outcome.lock().unwrap_or_else(PoisonError::into_inner).take() {
                return Some(done);
            }
            if h.with(|r| r.shell_parts().shell.dialog().is_none())? {
                cancel.cancel();
            }
            sq_runtime::sleep(TICK).await.ok()?;
        }
    }

    /// Export Stems: one audio file per checked role plus the M&E mix, written on a worker while the sheet stays up.
    async fn run_stems<R: ShellRoot + ?Sized>(
        h: &UiRef<R>,
        model: &SharedModel,
        sheet: &ShellExportSheet,
    ) -> Option<()> {
        let request = {
            let mut m = model.borrow_mut();
            let Some(dir) = m.output_directory().map(Path::to_path_buf) else { return Some(()) };
            let _ = std::fs::create_dir_all(&dir);
            m.begin_export_stems(&dir)
        };
        sheet.rebuild();
        let Some(request) = request else { return Some(()) };
        let cancel = CancelToken::new();
        let outcome = Arc::new(Mutex::new(None));
        let (slot, token) = (Arc::clone(&outcome), cancel.clone());
        std::thread::spawn(move || {
            let result = request.run(&token);
            *slot.lock().unwrap_or_else(PoisonError::into_inner) = Some(result);
        });
        let finished = Self::wait_for(h, &outcome, &cancel).await?;
        let status = {
            let mut m = model.borrow_mut();
            m.finish_export_stems(finished);
            m.stem_status().unwrap_or_default().to_string()
        };
        sheet.rebuild();
        h.with(|r| {
            if !status.is_empty() {
                r.shell_parts().shell.flash(&status);
            }
        })
    }

    /// The audio check (`audioCheckTapped`): mixes the sequence on a worker, the rows show the findings when it ends.
    async fn run_audio_check<R: ShellRoot + ?Sized>(
        h: &UiRef<R>,
        model: &SharedModel,
        sheet: &ShellExportSheet,
    ) -> Option<()> {
        let request = model.borrow_mut().begin_audio_check();
        sheet.rebuild();
        let Some(request) = request else { return Some(()) };
        let cancel = CancelToken::new();
        let outcome = Arc::new(Mutex::new(None));
        let (slot, token) = (Arc::clone(&outcome), cancel.clone());
        std::thread::spawn(move || {
            let result = request.run(&token);
            *slot.lock().unwrap_or_else(PoisonError::into_inner) = Some(result);
        });
        let finished = Self::wait_for(h, &outcome, &cancel).await?;
        model.borrow_mut().finish_audio_check(finished);
        sheet.rebuild();
        Some(())
    }

    /// Export Cut-downs: one queue job per checked range. The sheet stays usable while they write; its tick follows them
    /// ([`ShellHost::follow_cut_downs`]). `Some(None)` = nothing to run.
    async fn start_cut_downs<R: ShellRoot + ?Sized>(h: &UiRef<R>, model: &SharedModel) -> Option<Option<CutRun>> {
        let Some(dir) = model.borrow().output_directory().map(Path::to_path_buf) else { return Some(None) };
        let _ = std::fs::create_dir_all(&dir);
        let queue = h.with(|r| r.shell_parts().shell.export.queue.clone())??;
        let ids = model.borrow_mut().submit_cut_downs(&queue, &dir);
        if ids.is_empty() {
            return Some(None);
        }
        h.with(|r| r.shell_parts().shell.emit(ShellEvent::RunExportQueue))?;
        Some(Some(CutRun { ids, queue }))
    }

    /// One look at the running cut-downs: the progress in the status bar; at the end the result line.
    /// `Some(true)` = finished, `None` = the root is gone.
    fn follow_cut_downs<R: ShellRoot + ?Sized>(h: &UiRef<R>, run: &CutRun) -> Option<bool> {
        let all: Vec<ExportJobStatus> =
            run.queue.all_statuses().into_iter().filter(|s| run.ids.contains(&s.id)).collect();
        let current = all
            .iter()
            .find(|s| s.state.is_exporting())
            .or_else(|| all.iter().find(|s| s.state == ExportJobState::Waiting));
        h.with(|r| {
            let shell = &mut *r.shell_parts().shell;
            shell.export.progress =
                ShellExport::overall_progress(&all.iter().map(|s| (s.state.clone(), s.progress)).collect::<Vec<_>>());
            if current.is_some() {
                return false;
            }
            let failed: Vec<String> = all
                .iter()
                .filter_map(|s| match &s.state {
                    ExportJobState::Failed(why) => Some(format!("\u{201c}{}\u{201d}: {why}", s.name)),
                    _ => None,
                })
                .collect();
            let done = all.iter().filter(|s| matches!(s.state, ExportJobState::Done(_))).count();
            let line = match failed.first() {
                Some(why) => SQL10n::format("Export failed: %@", &[why]),
                None => SQL10n::format("Exported %@ cut-downs", &[&done.to_string()]),
            };
            shell.export.progress = None;
            shell.flash(&line);
            true
        })
    }

    /// The video codecs of the offered presets: the codec popup of the sheet lists them.
    fn offered_codecs(offered: &[ExportPreset]) -> Vec<VideoCodec> {
        let video = |s: &sq_export::core::settings::ExportSettings| s.audio_only.is_none() && s.frame_output.is_none();
        offered.iter().map(ExportPreset::settings).filter(video).map(|s| s.video.codec).collect()
    }

    /// The Export sheet card: headerless 1000 x 740 around the drawn body, the summary at the left of the footer band and the
    /// Export, Cancel and Other Formats buttons (`ShellExport.swift`).
    pub(crate) fn export_sheet(
        model: &SharedModel,
        sheet: &ShellExportSheet,
        other: &Rc<Cell<Option<usize>>>,
    ) -> ShellDialog {
        let mut d = ShellDialog::new("Export", "");
        d.headerless = true;
        d.width = EXPORT_SHEET_WIDTH;
        d.card_height = Some(EXPORT_SHEET_HEIGHT);
        d.content = Some(Box::new(sheet.clone()));
        let note = Rc::clone(model);
        d.footer_note = Some(Box::new(move || note.try_borrow().map(|m| m.output_summary_text()).unwrap_or_default()));
        d.add_button("Export", SQDialogRole::Default, false);
        // Kit footer: the primary carries the upload icon, as the title row's Export does.
        d.button_icons.insert(0, SQIcon::Upload);
        d.add_button("Cancel", SQDialogRole::Cancel, false);
        // Kit footer: Other Formats at the left, Cancel and Export at the right.
        d.add_button("Other Formats\u{2026}", SQDialogRole::Normal, true);
        let titles = OTHER_FORMATS.iter().map(|c| SQL10n::string(&c.title())).collect();
        d.button_menus.insert(2, (titles, Rc::clone(other)));
        let (enabled, closing, sheet) = (Rc::clone(model), Rc::clone(model), sheet.clone());
        d.button_enabled = Some(Box::new(move |i| i != 0 || enabled.try_borrow().is_ok_and(|m| m.can_export())));
        d.can_close = Some(Box::new(move |r| {
            if r != SQDialogResponse::FIRST {
                return true;
            }
            sheet.commit_editing();
            closing.try_borrow().is_ok_and(|m| m.can_export())
        }));
        d
    }
}

/// The card of the Export sheet (`ShellDialog.M.widthL`, `heightL`).
const EXPORT_SHEET_WIDTH: f64 = 1000.0;
const EXPORT_SHEET_HEIGHT: f64 = 740.0;

#[cfg(test)]
#[path = "shell_export_sheet_flow_tests.rs"]
mod flow_tests;

#[cfg(test)]
mod tests {
    use super::*;
    use crate::shell_export::FramePixels;
    use sq_core_time::{Id, Time, TimeRange};
    use sq_editor_session::{ExportDialogModel, SequenceItem};
    use std::sync::Arc;

    fn model(in_out: bool) -> ExportDialogModel {
        let mut item = SequenceItem::new(Id::from_u128(1), "Main", Time::seconds(60));
        if in_out {
            item.in_out = Some(TimeRange::new(Time::seconds(10), Time::seconds(20)));
        }
        ExportDialogModel::new(
            vec![item],
            None,
            ExportDialogModel::system_free_space(),
            Arc::new(|_, _| Err(sq_export::core::error::ExportError::Other("test".into()))),
            Box::new(sq_core_time::SequentialIds::default()),
        )
    }

    struct Pixels;
    impl sq_frame::sqframe::SQFrameStorage for Pixels {}

    struct Frames;
    impl sq_export::core::traits::FrameSource for Frames {
        fn frame_count(&self) -> usize {
            1500
        }
        fn frame_duration(&self) -> Time {
            Time::new(1, 25)
        }
        fn frame(
            &mut self,
            index: usize,
        ) -> Result<sq_export::core::traits::ExportFrame, sq_export::core::error::ExportError> {
            Ok(sq_frame::sqframe::SQFrame::new(
                4,
                2,
                sq_frame::sqframe::SQFramePixelFormat::Rgba8,
                sq_frame::sqframe::SQFrameColorSpace::Rec709,
                Time::new(index as i64, 25),
                Arc::new(Pixels),
            ))
        }
    }

    #[test]
    fn the_export_sheet_primary_carries_the_upload_icon() {
        let model: SharedModel = Rc::new(RefCell::new(model(false)));
        let sheet = ShellExportSheet::new(Rc::clone(&model), Vec::new(), Vec::new(), true, true, EXPORT_PREVIEW_SLOT);
        let d = ShellHost::export_sheet(&model, &sheet, &Rc::new(Cell::new(None)));
        let primary = d.model.primary_index().expect("a primary");
        assert_eq!(d.model.buttons[primary].title, "Export");
        assert_eq!(d.button_icons.get(&primary), Some(&SQIcon::Upload));
        assert_eq!(d.button_icons.len(), 1, "only the primary has an icon");
    }

    #[test]
    fn the_preview_shows_the_frame_at_the_scrub_position() {
        let mut m = model(false);
        m.set_preview_source(Some(Arc::new(|_, _| Ok(Box::new(Frames)))));
        // The hook reads the frame's time back as the first pixel: it proves which frame was rendered.
        let pixels: FramePixels = Arc::new(|f| {
            let mut image = RgbaImage { width: f.width, height: f.height, pixels: vec![0; f.width * f.height * 4] };
            image.pixels[0] = f.presentation_time.frame_index(Time::new(1, 25)) as u8;
            Some(image)
        });
        let at = |a| PreviewJob::new(&m, a, &pixels).and_then(|j| j.render_once()).expect("a picture");
        assert_eq!(at(At::Index(50)).image.pixels[0], 50);
        assert_eq!(at(At::Fraction(0.0)).image.pixels[0], 0);
        let late = at(At::Index(600_000));
        assert_eq!(late.image.pixels[0], (1499 % 256) as u8, "past the end shows the last frame");
        assert_eq!((late.index, late.count), (1499, 1500));
        m.set_preview_source(None);
        assert!(PreviewJob::new(&m, At::Index(0), &pixels).is_none());
    }

    /// A finished preview render asks for a frame: nothing else redraws the sheet while the pointer rests.
    #[test]
    fn a_finished_preview_asks_the_app_for_a_frame() {
        let model: SharedModel = Rc::new(RefCell::new(model(false)));
        let sheet = ShellExportSheet::new(Rc::clone(&model), Vec::new(), Vec::new(), true, true, EXPORT_PREVIEW_SLOT);
        let mut shell = crate::test_support::shell();
        assert!(!shell.take_frame_request());
        let image = RgbaImage { width: 2, height: 1, pixels: vec![0; 8] };
        ShellHost::show_preview(&mut shell, &sheet, Some(image));
        assert!(shell.take_frame_request(), "a picture asks for a frame");
        ShellHost::show_preview(&mut shell, &sheet, None);
        assert!(shell.take_frame_request(), "a failed render asks for a frame too");
    }

    #[test]
    fn the_preview_opens_on_the_playhead_frame() {
        let m = model(true); // In/Out 10 s .. 30 s of a 60 s sequence
        let mut pv = PreviewState::at_playhead(&m, Time::seconds(20));
        assert!(matches!(pv.at(), At::Fraction(f) if (f - 0.5).abs() < 1e-9), "half way into the range");
        let shot = PreviewShot {
            image: RgbaImage { width: 1, height: 1, pixels: vec![0; 4] },
            index: 0,
            count: 501,
            duration: Time::new(1, 25),
        };
        pv.learn(&shot);
        assert_eq!(pv.index, 250, "the frame at the playhead, not the first one");
        let whole = model(false);
        let pv = PreviewState::at_playhead(&whole, Time::seconds(30));
        assert!(matches!(pv.at(), At::Fraction(f) if (f - 0.5).abs() < 1e-9));
    }

    #[test]
    fn the_preview_position_follows_scrub_step_and_play() {
        let mut pv = PreviewState::new();
        assert!(!pv.apply("preview_scrub", &FormValue::Number(0.5)), "nothing moves before the first frame");
        let shot = PreviewShot {
            image: RgbaImage { width: 1, height: 1, pixels: vec![0; 4] },
            index: 0,
            count: 101,
            duration: Time::new(1, 25),
        };
        pv.learn(&shot);
        assert!(pv.apply("preview_scrub", &FormValue::Number(0.5)));
        assert_eq!(pv.index, 50);
        assert!(pv.apply("preview_step", &FormValue::Index(-1)));
        assert_eq!(pv.index, 49);
        assert!(pv.apply("preview_step", &FormValue::Index(-100)));
        assert_eq!(pv.index, 0, "the first frame is the stop on the left");
        assert_eq!(pv.transport().timecode, "00:00:00:00");
        assert!(pv.apply("preview_scrub", &FormValue::Number(1.0)));
        assert_eq!((pv.index, pv.transport().timecode.as_str()), (100, "00:00:04:00"));
        assert!(pv.apply("preview_play", &FormValue::Bool(true)));
        assert_eq!(pv.index, 0, "play from the last frame starts again");
        assert!(pv.transport().playing);
        assert!(!pv.apply("preview_play", &FormValue::Bool(false)));
        assert!(!pv.transport().playing);
        pv.playing = Some((Instant::now() - Duration::from_secs(10), 0));
        assert!(pv.advance());
        assert_eq!((pv.index, pv.playing.is_none()), (100, true), "the last frame ends the play");
    }
}
