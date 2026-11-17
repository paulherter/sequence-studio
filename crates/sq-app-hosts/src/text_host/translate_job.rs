//! Caption translation as a background job (Swift `EditorSession.translateCaptions`, there Apple's Translation framework; here the
//! offline OPUS-MT models of `sq-translate`, the same on Mac and Windows). The worker thread downloads missing models, translates
//! and reports; the host polls, shows progress in the status bar and writes the result as one undo step.

use sq_core_model::CaptionTrack;
use sq_translate::{Cancel, CurlFetcher, Progress, TranslateError, TranslateStore, Translator};
use std::sync::mpsc::{Receiver, Sender, channel};

/// What the worker tells the UI thread.
enum Message {
    Status(String),
    Done(Result<Vec<String>, TranslateError>),
}

/// A running translation of one caption track.
pub(super) struct TranslateJob {
    rx: Receiver<Message>,
    cancel: Cancel,
    track: CaptionTrack,
    target: String,
}

/// The work of a job: gets a progress sink and the cancel flag.
pub(super) type Work = Box<dyn FnOnce(&mut dyn FnMut(Progress), &Cancel) -> Result<Vec<String>, TranslateError> + Send>;

/// The status-bar line of a progress report.
pub(super) fn status_line(p: &Progress) -> String {
    match p {
        Progress::Downloading(what, f) => format!("Downloading translation {what}: {:.0} %", f * 100.0),
        Progress::Translating(done, total) => format!("Translating captions: {done} of {total}"),
    }
}

/// The real work: `translator` over the texts from `from` to `to`, downloading with curl.
pub(super) fn real_work(texts: Vec<String>, from: String, to: String) -> Work {
    Box::new(move |progress, cancel| {
        let store = TranslateStore::new(TranslateStore::default_folder(|k| std::env::var(k).ok()));
        Translator::new(store).translate(&texts, &from, &to, &CurlFetcher, progress, cancel)
    })
}

impl TranslateJob {
    /// Starts `work` on a worker thread for `track` (the result becomes the track "<name> (<target>)").
    pub(super) fn start(track: CaptionTrack, target: String, work: Work) -> TranslateJob {
        let (tx, rx) = channel();
        let cancel = Cancel::default();
        let token = cancel.clone();
        std::thread::spawn(move || {
            let tx: Sender<Message> = tx;
            let mut last = String::new();
            let result = work(
                &mut |p| {
                    let line = status_line(&p);
                    if line != last {
                        tx.send(Message::Status(line.clone())).ok();
                        last = line;
                    }
                },
                &token,
            );
            tx.send(Message::Done(result)).ok();
        });
        TranslateJob { rx, cancel, track, target }
    }

    /// Asks the worker to stop; the end arrives through `poll` as `Canceled`.
    pub(super) fn cancel(&self) {
        self.cancel.cancel();
    }

    /// The status lines since the last call and, once the job ended, its result with the track and target.
    #[allow(clippy::type_complexity, reason = "one private tuple read by the host")]
    pub(super) fn poll(
        &mut self,
    ) -> (Vec<String>, Option<(Result<Vec<String>, TranslateError>, CaptionTrack, String)>) {
        let mut lines = Vec::new();
        while let Ok(m) = self.rx.try_recv() {
            match m {
                Message::Status(s) => lines.push(s),
                Message::Done(r) => return (lines, Some((r, self.track.clone(), self.target.clone()))),
            }
        }
        (lines, None)
    }
}
