// Swift: Draw/ColorGradeDraw+Input.swift
//! The Color panel's foot (the Mac `ColorInspectorView` "Input color" header, closed at start): Interpret As, Log Handling,
//! Deliver As, HDR Conform and Project Input; the folded header reads the Interpret As choice. Also the sliders' color
//! ramps (the Mac `ColorParam.Track`).

use super::color_grade_draw::{ColorGradeDraw, Control, DrawMenuCommand, InputRow, Mac, Row, RowStyle, Slider};
use super::color_input_choices::ColorInputChoices;
use super::color_inspector_model::{ColorInspectorModel, ColorTrack};
use sq_core_color::ColorSpaceIdExt;
use sq_core_model::{LogMode, TargetSpace};
use sq_draw::inspector::InspectorColorRamp;
use sq_uikit::controls_grid::CGRect;
use sq_uikit::sqmenu_model::SQMenuItem;

impl ColorGradeDraw {
    pub(crate) fn input_rows(&self, model: &ColorInspectorModel, add: &mut dyn FnMut(Row), _full: CGRect) {
        let hh = Mac::SECTION_GAP + Mac::SECTION;
        let mut head = Row::new(
            Some("Input color"),
            RowStyle::Section,
            hh,
            vec![(Control::InputSection, CGRect::new(0.0, 0.0, self.size.width, hh))],
        );
        head.summary = Some(self.input_title(model, InputRow::Interpret));
        head.open = self.input_open;
        add(head);
        if !self.input_open {
            return;
        }
        let cap = f64::from(sq_draw::theme::metrics::CAPSULE);
        let popup = CGRect::new(
            Mac::TOP_CONTROL_X,
            ((Mac::POPUP_ROW - cap) / 2.0).round(),
            (self.size.width - Mac::INSET - Mac::TOP_CONTROL_X).max(0.0),
            cap,
        );
        let mut row = |label: &str, c: Control, f: CGRect, height: f64| {
            let mut r = Row::plain(Some(label), height, vec![(c, f)]);
            r.label_x = Some(Mac::INSET);
            add(r);
        };
        row("Interpret As", Control::Input(InputRow::Interpret), popup, Mac::POPUP_ROW);
        row("Log Handling", Control::Input(InputRow::LogMode), popup, Mac::POPUP_ROW);
        row("Deliver As", Control::Input(InputRow::Deliver), popup, Mac::POPUP_ROW);
        row(
            "HDR Conform",
            Control::Conform,
            CGRect::new(Mac::TOP_CONTROL_X, 0.0, (self.size.width - Mac::INSET - Mac::TOP_CONTROL_X).max(0.0), 30.0),
            30.0,
        );
        row("Project Input", Control::Input(InputRow::Project), popup, Mac::POPUP_ROW);
    }

    /// The popup's current title.
    pub(crate) fn input_title(&self, m: &ColorInspectorModel, r: InputRow) -> String {
        match r {
            InputRow::Interpret => m.source_override().map_or_else(
                || ColorInputChoices::automatic_title(m.detected_source()),
                |s| s.display_name().to_string(),
            ),
            InputRow::LogMode => ColorInputChoices::log_mode_title(m.log_mode()).to_string(),
            InputRow::Deliver => ColorInputChoices::target_title(m.target_space()).to_string(),
            InputRow::Project => m
                .project_input
                .map_or_else(|| ColorInputChoices::NO_PROJECT_INPUT.to_string(), |s| s.display_name().to_string()),
        }
    }

    /// The popup's items, the current one checked (InputPickerView, FootageRows).
    pub(crate) fn input_menu(&self, m: &ColorInspectorModel, r: InputRow) -> Vec<SQMenuItem> {
        let spaces = |current: Option<sq_core_model::ColorSpaceID>,
                      automatic: String,
                      set: &dyn Fn(Option<sq_core_model::ColorSpaceID>) -> DrawMenuCommand|
         -> Vec<SQMenuItem> {
            let mut first = self.row(&automatic, set(None));
            first.is_checked = current.is_none();
            let mut items = vec![first];
            items.extend(ColorInputChoices::shown(current).into_iter().map(|s| {
                let mut i = self.row(s.display_name(), set(Some(s)));
                i.is_checked = current == Some(s);
                i
            }));
            items
        };
        match r {
            InputRow::Interpret => spaces(
                m.source_override(),
                ColorInputChoices::automatic_title(m.detected_source()),
                &DrawMenuCommand::InputInterpret,
            ),
            InputRow::Project => {
                spaces(m.project_input, ColorInputChoices::NO_PROJECT_INPUT.to_string(), &DrawMenuCommand::InputProject)
            }
            InputRow::LogMode => [LogMode::CameraLUT, LogMode::BuiltIn, LogMode::Off]
                .iter()
                .map(|l| {
                    let mut i = self.row(ColorInputChoices::log_mode_title(*l), DrawMenuCommand::InputLogMode(*l));
                    i.is_checked = m.log_mode() == *l;
                    i
                })
                .collect(),
            InputRow::Deliver => {
                [TargetSpace::Rec709, TargetSpace::Rec2020, TargetSpace::Rec2020PQ, TargetSpace::Rec2020HLG]
                    .iter()
                    .map(|t| {
                        let mut i = self.row(ColorInputChoices::target_title(*t), DrawMenuCommand::InputDeliver(*t));
                        i.is_checked = m.target_space() == *t;
                        i
                    })
                    .collect()
            }
        }
    }

    pub(crate) fn input_help(&self, k: Control) -> Option<&'static str> {
        match k {
            Control::Input(InputRow::LogMode) => Some(
                "How log footage reaches the picture: through the Input LUT, through the built-in transform, or not at all.",
            ),
            Control::Input(InputRow::Deliver) => {
                Some("The space the conversion delivers. The monitors and export render Rec. 709 today.")
            }
            Control::Input(InputRow::Project) => {
                Some("Applies to every untagged clip in the project that is set to Automatic.")
            }
            Control::Conform => {
                Some("Rolls HLG and PQ highlights into the SDR range before the grade. Off clips them.")
            }
            _ => None,
        }
    }

    /// The slider's track: Temperature, Tint and the Saturation / Vibrance rows show their color ramp.
    pub(crate) fn ramp(&self, s: Slider) -> InspectorColorRamp {
        let t = match s {
            Slider::Param(_, p) => p.track(),
            Slider::Range(_, p) => p.track(),
            Slider::Sharpen
            | Slider::ZoneSat(..)
            | Slider::Step(..)
            | Slider::Primary(..)
            | Slider::StepQual(..)
            | Slider::Window(..)
            | Slider::Mix(_) => ColorTrack::Plain,
        };
        match t {
            ColorTrack::Plain => InspectorColorRamp::Plain,
            ColorTrack::Temperature => InspectorColorRamp::Temperature,
            ColorTrack::Tint => InspectorColorRamp::Tint,
            ColorTrack::Saturation => InspectorColorRamp::Saturation,
        }
    }
}
