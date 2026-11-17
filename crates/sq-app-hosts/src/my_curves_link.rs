//! The transition panel's ☆ My Curves, served from the preferences: "Save to My Curves" is stored under `sq.myCurves`
//! and the panel's list is refreshed (the same list the keyframe easing choices show).

use sq_core_time::IdSource;
use sq_editor_session::MyCurves;
use sq_inspector_ui::audio_masks::transition_controls_draw::{TransitionControlsDraw, TransitionControlsRequest};
use sq_uikit::appearance_palette::UiDefaults;

/// Loads the stored curves into the panel (call when it opens).
pub fn load_my_curves(panel: &mut TransitionControlsDraw, defaults: &dyn UiDefaults) {
    panel.my_curves = MyCurves::load(defaults).user_curves().to_vec();
}

/// Answers the panel's `SaveToMyCurves` requests and hands every other request back, in order.
pub fn serve_my_curves(
    panel: &mut TransitionControlsDraw,
    defaults: &mut dyn UiDefaults,
    ids: &mut dyn IdSource,
) -> Vec<TransitionControlsRequest> {
    let mut rest = Vec::new();
    let mut saved = false;
    for request in std::mem::take(&mut panel.requests) {
        match request {
            TransitionControlsRequest::SaveToMyCurves(curve) => {
                MyCurves::save(defaults, ids, &curve, "");
                saved = true;
            }
            other => rest.push(other),
        }
    }
    if saved {
        load_my_curves(panel, defaults);
    }
    rest
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_time::{EasingCurve, SequentialIds};
    use sq_draw_shell::MemoryDefaults;
    use sq_inspector_ui::audio_masks::transition_controls_model::TransitionControlsActions;

    #[test]
    fn save_requests_are_stored_and_refresh_the_panel_list() {
        let mut panel = TransitionControlsDraw::new(TransitionControlsActions::default());
        let mut defaults = MemoryDefaults::default();
        let mut ids = SequentialIds::default();
        panel.requests.push(TransitionControlsRequest::SaveToMyCurves(EasingCurve::ease_in()));
        panel.requests.push(TransitionControlsRequest::SavePreset);
        let rest = serve_my_curves(&mut panel, &mut defaults, &mut ids);
        assert_eq!(rest, [TransitionControlsRequest::SavePreset], "other requests stay for the caller");
        assert_eq!(panel.my_curves.len(), 1);
        // A new launch: a fresh panel loads the same list.
        let mut fresh = TransitionControlsDraw::new(TransitionControlsActions::default());
        load_my_curves(&mut fresh, &defaults);
        assert_eq!(fresh.my_curves.len(), 1);
    }
}
