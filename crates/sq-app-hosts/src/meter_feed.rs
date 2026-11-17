// Swift: SQAppShell/Monitors/MonitorHost.swift (loudnessProvider), EditorPanels (meter `reading` closure)
//! Feeds the dock's audio meter panel from the Program engine: the mixed timeline peaks, the loudness snapshot and the
//! delivery target of the active sequence, polled once per frame.

use sq_draw::monitor::audio_meter::MeterReading as PanelReading;
use sq_draw::monitor::loudness_meter::LoudnessTarget;
use sq_draw_monitor::meter_panel::{MeterPanel, loudness_reading};
use sq_editor_session::{EditorSession, MeterReading};
use sq_playback::audio::LoudnessLevels;

/// Hands one engine reading to `meter` and polls it at `now`. `source` tells engines apart (a new engine restarts its
/// buffer counter). True while the bars still move, so the caller asks for another frame.
pub fn feed(
    meter: &mut MeterPanel,
    source: usize,
    reading: Option<MeterReading>,
    loudness: Option<&LoudnessLevels>,
    target: LoudnessTarget,
    now: f64,
) -> bool {
    meter.reading = reading.map(|r| PanelReading { source, sequence: r.sequence, peaks: r.peaks });
    meter.loudness_reading = loudness.map(loudness_reading);
    meter.loudness_target = Some(target);
    meter.poll(now);
    !meter.meter.is_settled()
}

/// [`feed`] from the session's engine; true while the bars still move.
pub fn feed_from_session(meter: &mut MeterPanel, session: &EditorSession, now: f64) -> bool {
    let engine = session.engine();
    let source = std::ptr::from_ref(engine).cast::<()>() as usize;
    let target = LoudnessTarget::from_delivery(session.active_timeline().and_then(|t| t.delivery_target.as_ref()));
    feed(meter, source, engine.meter_reading(), engine.loudness_levels().as_ref(), target, now)
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_draw_monitor::memory_defaults::MemoryDefaults;

    fn panel() -> MeterPanel {
        MeterPanel::new(Box::new(MemoryDefaults::default()))
    }

    fn reading(sequence: i64, peak: f32) -> Option<MeterReading> {
        Some(MeterReading { sequence, peaks: vec![peak, peak] })
    }

    #[test]
    fn a_new_buffer_moves_the_bars_and_asks_for_frames() {
        let mut m = panel();
        assert!(!feed(&mut m, 1, None, None, LoudnessTarget::default(), 0.0), "nothing playing: settled");
        assert!(feed(&mut m, 1, reading(1, 0.8), None, LoudnessTarget::default(), 0.1));
    }

    #[test]
    fn the_bars_fall_back_when_the_engine_stops_delivering() {
        let mut m = panel();
        feed(&mut m, 1, reading(1, 0.8), None, LoudnessTarget::default(), 0.1);
        let mut t = 0.2;
        // Same buffer counter: no new feed, the stale timeout silences the bars and they settle.
        while feed(&mut m, 1, reading(1, 0.8), None, LoudnessTarget::default(), t) && t < 10.0 {
            t += 0.05;
        }
        assert!(m.meter.is_settled(), "settled at {t}");
    }

    #[test]
    fn the_session_engine_without_audio_leaves_the_meter_at_rest() {
        let mut m = panel();
        let mut ids = sq_core_time::SequentialIds::default();
        let project = EditorSession::make_untitled(&mut ids);
        let mut deps = sq_editor_session::SessionDeps::headless(crate::test_rig::unique_dir("sq-app-hosts-meter-feed"));
        deps.ids = Box::new(ids);
        let rig = crate::test_rig::Rig::new(EditorSession::new(project, deps));
        assert!(!feed_from_session(&mut m, &rig.session, 0.0));
    }
}
