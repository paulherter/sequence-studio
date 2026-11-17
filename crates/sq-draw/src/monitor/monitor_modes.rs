// Swift: MonitorModes.swift
//! The monitor's modes, zoom presets and footer actions.

/// Program or Source monitor.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum MonitorMode {
    /// The Program monitor.
    Program,
    /// The Source monitor.
    Source,
}

/// Picture zoom.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum MonitorZoom {
    /// Fit the panel.
    Fit,
    /// A popup preset.
    Percent(i64),
    /// Reached by pinch or scroll zoom (not a popup preset).
    Custom(i64),
}

impl MonitorZoom {
    /// The popup presets, in menu order.
    pub fn presets() -> Vec<MonitorZoom> {
        let mut v = vec![MonitorZoom::Fit];
        v.extend([10, 25, 50, 75, 100, 150, 200, 400, 800].map(MonitorZoom::Percent));
        v
    }

    /// Menu title.
    pub fn title(self) -> String {
        match self {
            MonitorZoom::Fit => "Fit".to_string(),
            MonitorZoom::Percent(p) | MonitorZoom::Custom(p) => format!("{p} %"),
        }
    }
}

/// What a footer button or menu row does.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum MonitorAction {
    /// Mark In.
    MarkIn,
    /// Mark Out.
    MarkOut,
    /// Go to In.
    GoToIn,
    /// Go to Out.
    GoToOut,
    /// Step back one frame.
    StepBack,
    /// Step forward one frame.
    StepForward,
    /// Play or pause.
    PlayPause,
    /// Add a marker.
    AddMarker,
    /// Insert edit.
    Insert,
    /// Overwrite edit.
    Overwrite,
    /// Lift.
    Lift,
    /// Extract.
    Extract,
    /// Export the frame.
    ExportFrame,
    /// Loop playback.
    Loop,
    /// Play In to Out.
    PlayInToOut,
    /// Toggle safe margins.
    ToggleSafeMargins,
    /// Scrub bar right-click: take the In mark away.
    ClearIn,
    /// Take the Out mark away.
    ClearOut,
    /// Take both marks away.
    ClearInOut,
    /// Source monitor menu only (no key of their own yet): Replace the selected clip with the Source clip at the playhead frame.
    Replace,
    /// Fit to Fill (the marked source range retimed into the sequence In..Out).
    FitToFill,
}

impl MonitorAction {
    /// Every action, in declaration order.
    pub const ALL: [MonitorAction; 21] = [
        MonitorAction::MarkIn,
        MonitorAction::MarkOut,
        MonitorAction::GoToIn,
        MonitorAction::GoToOut,
        MonitorAction::StepBack,
        MonitorAction::StepForward,
        MonitorAction::PlayPause,
        MonitorAction::AddMarker,
        MonitorAction::Insert,
        MonitorAction::Overwrite,
        MonitorAction::Lift,
        MonitorAction::Extract,
        MonitorAction::ExportFrame,
        MonitorAction::Loop,
        MonitorAction::PlayInToOut,
        MonitorAction::ToggleSafeMargins,
        MonitorAction::ClearIn,
        MonitorAction::ClearOut,
        MonitorAction::ClearInOut,
        MonitorAction::Replace,
        MonitorAction::FitToFill,
    ];

    /// Footer transport, left to right: Mark In at the far left, Mark Out at the far right, Play exactly in the middle
    /// (two buttons on each side of it, so the row centers Play itself).
    pub fn button_bar(_mode: MonitorMode) -> Vec<MonitorAction> {
        vec![
            MonitorAction::MarkIn,
            MonitorAction::StepBack,
            MonitorAction::PlayPause,
            MonitorAction::StepForward,
            MonitorAction::MarkOut,
        ]
    }

    /// Everything else lives in the header wrench menu (with Loop, Play In to Out and Safe Margins). Mark In / Out stay on I / O and the Mark menu. Insert / Overwrite belong to the Source monitor, Lift / Extract to the Program monitor.
    /// Extra Source rows below the overflow rows of the "..." menu (not buttons, no EditorCommand yet).
    pub fn source_menu_extras(mode: MonitorMode) -> Vec<MonitorAction> {
        if mode == MonitorMode::Source { vec![MonitorAction::Replace, MonitorAction::FitToFill] } else { vec![] }
    }

    /// Menu title of an action that has no footer button.
    pub fn menu_title(self) -> Option<&'static str> {
        match self {
            MonitorAction::Replace => Some("Replace Clip from Source"),
            MonitorAction::FitToFill => Some("Fit to Fill"),
            _ => None,
        }
    }

    /// The rows of the "..." menu.
    pub fn overflow_menu(mode: MonitorMode) -> Vec<MonitorAction> {
        let edit = if mode == MonitorMode::Source {
            [MonitorAction::Insert, MonitorAction::Overwrite]
        } else {
            [MonitorAction::Lift, MonitorAction::Extract]
        };
        let mut v = vec![MonitorAction::AddMarker, MonitorAction::GoToIn, MonitorAction::GoToOut];
        v.extend(edit);
        v.push(MonitorAction::ExportFrame);
        v
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_transport_has_play_in_the_middle() {
        let bar = MonitorAction::button_bar(MonitorMode::Program);
        assert_eq!(bar.len(), 5);
        assert_eq!(bar[2], MonitorAction::PlayPause);
    }

    #[test]
    fn overflow_menu_follows_the_mode_and_zoom_titles() {
        assert!(MonitorAction::overflow_menu(MonitorMode::Source).contains(&MonitorAction::Insert));
        assert!(MonitorAction::overflow_menu(MonitorMode::Program).contains(&MonitorAction::Lift));
        assert_eq!(MonitorZoom::presets().len(), 10);
        assert_eq!(MonitorZoom::Custom(133).title(), "133 %");
        assert_eq!(MonitorZoom::Fit.title(), "Fit");
    }
}
