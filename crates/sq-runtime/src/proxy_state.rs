//! The one lifecycle of a media's background proxy (one enum, transitions in one place, no flag piles).
//! Generic over the job id `J` and the ready record `R`, so the auto-proxy service (queue ids, cache records) and the
//! runtime's scheduling model share it. [`ProxyState::next`] is the only place a state changes; an event that makes no
//! sense in the current state is ignored (a late answer of a worker never revives a finished media).
//! Swift: AutoProxy.swift (`tracked` flags `taskLive`, `jobs`, `ready`, `capped`, `diskRefused`).

/// Where one media's proxy is.
#[derive(Clone, Debug, PartialEq)]
pub enum ProxyState<J, R> {
    /// No proxy is made (light source, mode off, probe failed): nothing to show.
    NotNeeded,
    /// The decision (probe, warm, disk read) is running on a worker.
    Deciding,
    /// A job is queued (or held while playback/export runs).
    Queued { job: J },
    /// The transcode runs; `progress` is 0...1.
    Generating { job: J, progress: f64 },
    /// A complete proxy of the current file is in the cache (protected from eviction).
    Ready { record: Option<R> },
    /// The transcode failed; the reason is shown.
    Failed { reason: String },
    /// Not generated: the disk reserve would break (retried by `refresh`).
    DiskRefused,
    /// Not generated: proxies in use fill the cache cap (retried by `refresh`).
    Capped,
    /// The source file changed while the proxy was queued, running or ready: the old one is dropped, a new decision
    /// follows.
    Stale,
    /// Stopped on purpose (user, project closed, media removed).
    Cancelled,
}

/// What can happen to a media's proxy.
#[derive(Clone, Debug, PartialEq)]
pub enum ProxyEvent<J, R> {
    /// The decision started on a worker.
    DecisionStarted,
    /// The decision found no proxy is needed.
    Skipped,
    /// The decision found a complete proxy of the current file in the cache.
    FoundReady { record: Option<R> },
    /// The decision enqueued a job.
    JobQueued { job: J },
    /// The queue reports progress of the running job.
    JobProgress { progress: f64 },
    /// The job finished and its proxy is in the cache.
    JobDone { record: Option<R> },
    /// The job failed.
    JobFailed { reason: String },
    /// The disk reserve would break (before or during the transcode: the cache folder is full).
    DiskFull,
    /// The cache cap is full of proxies in use.
    CapReached,
    /// The source file changed (path, size, date, Deinterlace).
    SourceChanged,
    /// The job or the media was stopped (user, media removed, project closed).
    Stopped,
    /// The app started again and found this media's proxy file: `complete` is the cache's verdict (`Some` = intact,
    /// `None` = half-written or unknown, it is discarded and made again).
    Recovered { complete: Option<R> },
}

impl<J: Copy + PartialEq, R: Clone> ProxyState<J, R> {
    /// The single transition function.
    #[must_use]
    pub fn next(self, event: ProxyEvent<J, R>) -> Self {
        use ProxyEvent as E;
        use ProxyState as S;
        match (self, event) {
            // A changed source beats everything: whatever was made belongs to the old file.
            (S::NotNeeded | S::Cancelled, E::SourceChanged) => S::NotNeeded,
            (_, E::SourceChanged) => S::Stale,
            (S::Ready { record }, E::Stopped) => S::Ready { record },
            (S::NotNeeded | S::Failed { .. } | S::DiskRefused | S::Capped | S::Stale, E::Stopped) => S::Cancelled,
            (S::Deciding | S::Queued { .. } | S::Generating { .. }, E::Stopped) => S::Cancelled,
            // Restart: only an intact file counts, a half-written one starts over.
            (
                S::Deciding | S::Queued { .. } | S::Generating { .. } | S::Stale | S::Cancelled,
                E::Recovered { complete },
            ) => match complete {
                Some(record) => S::Ready { record: Some(record) },
                None => S::Stale,
            },
            (
                S::NotNeeded | S::Stale | S::Cancelled | S::Failed { .. } | S::DiskRefused | S::Capped,
                E::DecisionStarted,
            ) => S::Deciding,
            (S::Deciding, E::Skipped) => S::NotNeeded,
            (S::Deciding, E::FoundReady { record }) => S::Ready { record },
            (S::Deciding, E::CapReached) => S::Capped,
            (S::Deciding | S::Generating { .. } | S::Queued { .. }, E::DiskFull) => S::DiskRefused,
            (S::Deciding, E::JobQueued { job }) => S::Queued { job },
            (S::Queued { job } | S::Generating { job, .. }, E::JobProgress { progress }) => {
                S::Generating { job, progress: progress.clamp(0.0, 1.0) }
            }
            (S::Queued { .. } | S::Generating { .. }, E::JobDone { record }) => S::Ready { record },
            (S::Deciding | S::Queued { .. } | S::Generating { .. }, E::JobFailed { reason }) => S::Failed { reason },
            (S::Queued { .. } | S::Generating { .. }, E::CapReached) => S::Capped,
            // Anything else is a late or impossible event: no change.
            (state, _) => state,
        }
    }

    pub fn is_ready(&self) -> bool {
        matches!(self, ProxyState::Ready { .. })
    }
    /// The job of a queued or running transcode.
    pub fn job(&self) -> Option<J> {
        match self {
            ProxyState::Queued { job } | ProxyState::Generating { job, .. } => Some(*job),
            _ => None,
        }
    }
    /// Work is in flight (a decision or a job): the busy signal must still be watched.
    pub fn is_active(&self) -> bool {
        matches!(self, ProxyState::Deciding | ProxyState::Queued { .. } | ProxyState::Generating { .. })
    }
    /// The record in use once ready.
    pub fn record(&self) -> Option<&R> {
        match self {
            ProxyState::Ready { record } => record.as_ref(),
            _ => None,
        }
    }

    /// What the project panel's proxy column, the status line and Preferences show; `None` = nothing to show.
    pub fn label(&self) -> Option<String> {
        Some(match self {
            ProxyState::NotNeeded | ProxyState::Cancelled => return None,
            ProxyState::Deciding => "Checking".to_string(),
            ProxyState::Queued { .. } => "Proxy waiting".to_string(),
            ProxyState::Generating { progress, .. } => format!("Proxy {}%", (progress * 100.0).round() as i64),
            ProxyState::Ready { .. } => "Proxy ready".to_string(),
            ProxyState::Failed { reason } => format!("Proxy failed: {reason}"),
            ProxyState::DiskRefused => "Proxy skipped: disk full".to_string(),
            ProxyState::Capped => "Proxy skipped: cache full".to_string(),
            ProxyState::Stale => "Proxy outdated".to_string(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    type S = ProxyState<u32, &'static str>;
    type E = ProxyEvent<u32, &'static str>;

    fn run(start: S, events: Vec<E>) -> S {
        events.into_iter().fold(start, S::next)
    }

    #[test]
    fn happy_path() {
        let s = run(
            S::NotNeeded,
            vec![
                E::DecisionStarted,
                E::JobQueued { job: 7 },
                E::JobProgress { progress: 0.5 },
                E::JobDone { record: Some("r") },
            ],
        );
        assert_eq!(s, S::Ready { record: Some("r") });
        assert!(s.is_ready() && !s.is_active() && s.job().is_none());
    }

    #[test]
    fn progress_is_clamped_and_labeled() {
        let s = run(S::Queued { job: 1 }, vec![E::JobProgress { progress: 2.0 }]);
        assert_eq!(s, S::Generating { job: 1, progress: 1.0 });
        assert_eq!(s.label().as_deref(), Some("Proxy 100%"));
    }

    #[test]
    fn cache_folder_full_before_and_during() {
        assert_eq!(run(S::Deciding, vec![E::DiskFull]), S::DiskRefused);
        assert_eq!(run(S::Generating { job: 1, progress: 0.3 }, vec![E::DiskFull]), S::DiskRefused);
        assert_eq!(S::DiskRefused.label().as_deref(), Some("Proxy skipped: disk full"));
        // retried by refresh
        assert_eq!(run(S::DiskRefused, vec![E::DecisionStarted]), S::Deciding);
    }

    #[test]
    fn cap_reached_also_stops_waiting_jobs() {
        assert_eq!(run(S::Deciding, vec![E::CapReached]), S::Capped);
        assert_eq!(run(S::Queued { job: 2 }, vec![E::CapReached]), S::Capped);
        assert_eq!(run(S::Ready { record: None }, vec![E::CapReached]), S::Ready { record: None });
    }

    #[test]
    fn source_changed_while_generating_is_stale_and_late_results_are_ignored() {
        let s = run(S::Generating { job: 3, progress: 0.4 }, vec![E::SourceChanged]);
        assert_eq!(s, S::Stale);
        // the old job's late finish must not make the media ready
        assert_eq!(s.clone().next(E::JobDone { record: Some("old") }), S::Stale);
        assert_eq!(s.next(E::DecisionStarted), S::Deciding);
        assert_eq!(S::Ready { record: Some("r") }.next(E::SourceChanged), S::Stale);
        assert_eq!(S::NotNeeded.next(E::SourceChanged), S::NotNeeded);
    }

    #[test]
    fn project_closed_while_generating_cancels_but_keeps_ready() {
        assert_eq!(S::Generating { job: 3, progress: 0.4 }.next(E::Stopped), S::Cancelled);
        assert_eq!(S::Deciding.next(E::Stopped), S::Cancelled);
        assert_eq!(S::Ready { record: Some("r") }.next(E::Stopped), S::Ready { record: Some("r") });
        // a late finish after cancel changes nothing
        assert_eq!(S::Cancelled.next(E::JobDone { record: Some("r") }), S::Cancelled);
        assert_eq!(S::Cancelled.label(), None);
    }

    #[test]
    fn restart_with_half_written_file_starts_over() {
        assert_eq!(S::Generating { job: 1, progress: 0.9 }.next(E::Recovered { complete: None }), S::Stale);
        assert_eq!(S::Stale.next(E::Recovered { complete: Some("r") }), S::Ready { record: Some("r") });
        // a ready proxy is not touched by a recovery report
        assert_eq!(
            S::Ready { record: Some("a") }.next(E::Recovered { complete: None }),
            S::Ready { record: Some("a") }
        );
    }

    #[test]
    fn failure_shows_reason_and_stays_until_new_decision() {
        let s = S::Queued { job: 1 }.next(E::JobFailed { reason: "no space".into() });
        assert_eq!(s.label().as_deref(), Some("Proxy failed: no space"));
        assert!(!s.is_active());
        assert_eq!(s.next(E::JobDone { record: None }), S::Failed { reason: "no space".into() });
    }

    #[test]
    fn skipped_and_found_ready_only_from_deciding() {
        assert_eq!(S::Deciding.next(E::Skipped), S::NotNeeded);
        assert_eq!(S::Deciding.next(E::FoundReady { record: Some("r") }), S::Ready { record: Some("r") });
        assert_eq!(S::Queued { job: 1 }.next(E::Skipped), S::Queued { job: 1 });
    }
}
