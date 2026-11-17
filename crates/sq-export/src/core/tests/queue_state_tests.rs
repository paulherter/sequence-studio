// Transition table of the export job and the worker: every valid move, every rejected one (no panic, no change).

use crate::core::*;
use sq_core_time::Id;
use std::path::PathBuf;

fn done() -> ExportJobState {
    ExportJobState::Done(PathBuf::from("a.mp4"))
}

fn all_states() -> Vec<ExportJobState> {
    vec![
        ExportJobState::Waiting,
        ExportJobState::Running,
        ExportJobState::Cancelling,
        done(),
        ExportJobState::Failed("x".into()),
        ExportJobState::Cancelled,
    ]
}

fn all_events() -> Vec<JobEvent> {
    vec![
        JobEvent::Start,
        JobEvent::RequestCancel,
        JobEvent::Finish(PathBuf::from("a.mp4")),
        JobEvent::Fail("why".into()),
        JobEvent::Stopped,
    ]
}

#[test]
fn valid_transitions() {
    use ExportJobState as S;
    use JobEvent as E;
    let cases = [
        (S::Waiting, E::Start, S::Running),
        (S::Waiting, E::RequestCancel, S::Cancelled),
        (S::Running, E::RequestCancel, S::Cancelling),
        (S::Running, E::Finish(PathBuf::from("a.mp4")), done()),
        (S::Running, E::Fail("why".into()), S::Failed("why".into())),
        (S::Running, E::Stopped, S::Cancelled),
        (S::Cancelling, E::RequestCancel, S::Cancelling),
        (S::Cancelling, E::Finish(PathBuf::from("a.mp4")), done()),
        (S::Cancelling, E::Fail("why".into()), S::Failed("why".into())),
        (S::Cancelling, E::Stopped, S::Cancelled),
    ];
    for (from, event, to) in cases {
        assert_eq!(from.transition(event.clone()), Ok(to), "{from:?} + {event:?}");
    }
}

#[test]
fn every_other_transition_is_rejected_with_the_state_unchanged() {
    let valid = 10;
    let mut accepted = 0;
    for s in all_states() {
        for e in all_events() {
            match s.transition(e.clone()) {
                Ok(_) => accepted += 1,
                Err(inv) => assert_eq!((inv.from, inv.event), (s.clone(), e)),
            }
        }
    }
    assert_eq!(accepted, valid);
}

#[test]
fn finished_states_accept_nothing() {
    for s in [done(), ExportJobState::Failed("x".into()), ExportJobState::Cancelled] {
        assert!(!s.is_active() && !s.is_exporting());
        for e in all_events() {
            assert!(s.transition(e).is_err());
        }
    }
}

#[test]
fn waiting_is_not_exporting_and_cancelling_is() {
    assert!(ExportJobState::Waiting.is_active() && !ExportJobState::Waiting.is_exporting());
    assert!(ExportJobState::Cancelling.is_active() && ExportJobState::Cancelling.is_exporting());
}

#[test]
fn worker_lifecycle() {
    let id = Id::from_u128(1);
    let mut w = Worker::default();
    assert!(!w.is_active());
    assert!(w.begin());
    assert!(!w.begin(), "a second run_all is refused");
    assert!(w.start(id, CancelToken::new()));
    assert!(!w.start(Id::from_u128(2), CancelToken::new()), "one job at a time");
    assert!(!w.begin());
    assert_eq!(w.finish(Id::from_u128(2)), None, "only the running job can finish");
    assert_eq!(w.finish(id), Some(None));
    assert!(w.is_active(), "between jobs the worker is still busy");
    w.end();
    assert!(!w.is_active());
    assert!(w.begin());
}

#[test]
fn worker_stop_keeps_the_first_reason_and_ignores_other_jobs() {
    let (a, b) = (Id::from_u128(1), Id::from_u128(2));
    let token = CancelToken::new();
    let mut w = Worker::default();
    assert!(!w.stop(a, StopReason::User), "idle worker: nothing to stop");
    w.begin();
    assert!(!w.stop(a, StopReason::User), "between jobs: nothing to stop");
    w.start(a, token.clone());
    assert!(!w.stop(b, StopReason::User));
    assert!(!token.is_cancelled());
    assert!(w.stop(a, StopReason::LowSpace));
    assert!(w.stop(a, StopReason::User));
    assert!(token.is_cancelled());
    assert_eq!(w.finish(a), Some(Some(StopReason::LowSpace)));
    assert!(!w.stop(a, StopReason::User), "finished");
}
