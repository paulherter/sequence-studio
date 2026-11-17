// Swift: SQEditorSession/OnboardingContent.swift, SQDrawShell/ShellDock+Shell.swift (showWelcome, presentWelcomeIfNeeded),
// ShellViewCommands.swift (importProjectAsBin)
//! Help > Welcome Tour (and its first-run showing) and File > Import Project.

use crate::shell_dialog::{KeySeg, KitStep, ShellDialog};
use crate::shell_flows::ShellRoot;
use crate::shell_host::{ShellEvent, ShellFlow, ShellHost};
use sq_editor_session::{AppSettings, ProjectPanelModel};
use sq_os::Platform;
use sq_runtime::UiRef;
use sq_uikit::sqdialog_model::SQDialogRole;
use sq_uikit::sqicon::SQIcon;

/// First-run welcome content: where to start and the few keys worth knowing (key names follow the platform).
pub struct OnboardingContent;

impl OnboardingContent {
    /// The dialog title.
    pub const TITLE: &'static str = "Welcome to Sequence Studio";
    /// The line under the title.
    pub const INTRO: &'static str = "A short start. You can skip this and find everything in the menus.";
    /// The default button.
    pub const START_BUTTON: &'static str = "Get Started";
    /// The leading button.
    pub const SKIP_BUTTON: &'static str = "Skip";

    /// The same steps with icon tiles and key chips (`dialogs.html` `welcome()`).
    pub fn steps(platform: Platform) -> Vec<KitStep> {
        let m = platform.command_name();
        let key = |k: &str| KeySeg::Key(if m == "Cmd" { format!("\u{2318}{k}") } else { format!("Ctrl+{k}") });
        let text = |t: &str| KeySeg::Text(t.to_string());
        let step = |icon, title: &str, detail: Vec<KeySeg>| KitStep { icon, title: title.to_string(), detail };
        vec![
            step(
                SQIcon::Download,
                "Import",
                vec![text("File > Import Media"), key("I"), text(", or drop files into the Project panel.")],
            ),
            step(
                SQIcon::ToolBlade,
                "Edit",
                vec![
                    text("Drag a clip to the timeline."),
                    KeySeg::Key("K".into()),
                    text("stops,"),
                    KeySeg::Key("J".into()),
                    text("and"),
                    KeySeg::Key("L".into()),
                    text("play backward and forward,"),
                    KeySeg::Key("C".into()),
                    text("cuts at the playhead."),
                ],
            ),
            step(
                SQIcon::Reset,
                "Undo",
                vec![key("Z"), text("steps back. Window > History lists every step, click one to jump to it.")],
            ),
            step(
                SQIcon::Keyboard,
                "Shortcuts",
                vec![text("Help shows all keys, and every one can be changed in Keyboard Shortcuts.")],
            ),
            step(SQIcon::Upload, "Export", vec![key("M"), text("opens Export when the sequence is ready.")]),
        ]
    }
}

impl ShellHost {
    /// The welcome dialog (`showWelcome`): Pip, the intro, one card of steps with key chips, Skip and Get Started.
    pub(crate) fn welcome_dialog() -> ShellDialog {
        let mut d = ShellDialog::new(OnboardingContent::TITLE, OnboardingContent::INTRO);
        d.width = 480.0;
        d.kit_steps = OnboardingContent::steps(Platform::current());
        d.add_button(OnboardingContent::START_BUTTON, SQDialogRole::Default, false);
        d.add_button(OnboardingContent::SKIP_BUTTON, SQDialogRole::Cancel, false);
        d
    }

    /// Help > Welcome Tour.
    pub async fn show_welcome<R: ShellRoot + ?Sized>(h: UiRef<R>) {
        let _ = Self::ask(&h, Self::welcome_dialog()).await;
    }

    /// Shows the welcome once per machine, the first time the editor window is up; the flag is written when it opens so it
    /// never comes back after a quit or a crash (`presentWelcomeIfNeeded`). True when it was started.
    pub fn present_welcome_if_needed(&mut self) -> bool {
        let mut s = AppSettings::load(&*self.defaults);
        if s.onboarding_seen || self.dialog().is_some() || self.is_start_shown() {
            return false;
        }
        s.onboarding_seen = true;
        s.save(&mut *self.defaults);
        self.start_flow(ShellFlow::Welcome);
        true
    }

    /// File > Import Project: another .sqproj as a bin (its media and sequences, nothing linked back).
    pub async fn import_project_as_bin<R: ShellRoot + ?Sized>(h: UiRef<R>) {
        let Some(ask) = h.with(|r| r.shell_parts().files.choose_project()) else { return };
        let Some(url) = ask.await else { return };
        ProjectPanelModel::import_projects(h.clone(), vec![url]).await;
        let _ = h.with(|r| r.shell_parts().shell.emit(ShellEvent::ProjectChanged));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tests::Rig;
    use sq_uikit::sqdialog_model::SQDialogResponse;

    #[test]
    fn steps_name_the_platform_modifier() {
        let mac = OnboardingContent::steps(Platform::Mac);
        let win = OnboardingContent::steps(Platform::Windows);
        assert_eq!(mac.len(), 5);
        assert!(mac[0].detail.contains(&KeySeg::Key("\u{2318}I".into())));
        assert!(win[0].detail.contains(&KeySeg::Key("Ctrl+I".into())));
        assert_eq!(mac[4].detail[0], KeySeg::Key("\u{2318}M".into()));
        // The key chip stands without parentheses (kit: "File > Import Media [chip], or drop files").
        assert!(mac[0].detail.iter().all(|s| !matches!(s, KeySeg::Text(t) if t.contains('(') || t.contains(')'))));
    }

    #[test]
    fn welcome_shows_once_and_skip_closes_it() {
        let rig = Rig::new();
        assert!(rig.with(|r| r.shell.present_welcome_if_needed()));
        rig.run_flows();
        assert!(rig.has_dialog());
        rig.answer(SQDialogResponse::SECOND);
        assert!(!rig.has_dialog());
        assert!(!rig.with(|r| r.shell.present_welcome_if_needed()), "the flag is stored");
    }

    /// The click goes through the host's whole input path (not only the dialog), at the size a window really has.
    #[test]
    fn a_click_on_skip_closes_the_welcome_through_the_host() {
        use sq_draw::{InputEvent, InputModifiers};
        let rig = Rig::new();
        assert!(rig.with(|r| r.shell.present_welcome_if_needed()));
        rig.run_flows();
        assert!(rig.has_dialog());
        let frame = rig.cx(|h, cx| {
            h.handle(cx, &InputEvent::MouseMoved { x: 1.0, y: 1.0 }, 1.0); // lays the dialog out
            h.dialog().and_then(|d| d.button_frames().get(&1).copied())
        });
        let Some(skip) = frame else { panic!("the Skip button has a frame") };
        let (x, y) = (skip.mid_x() as f32, skip.mid_y() as f32);
        rig.cx(|h, cx| {
            h.handle(cx, &InputEvent::MouseMoved { x, y }, 1.0);
            h.handle(cx, &InputEvent::MouseDown { x, y, modifiers: InputModifiers::NONE }, 1.0);
            h.handle(cx, &InputEvent::MouseUp { x, y }, 1.0);
        });
        rig.run_flows();
        assert!(!rig.has_dialog(), "Skip closed the welcome");
    }

    #[test]
    fn welcome_tour_menu_row_opens_the_dialog() {
        let rig = Rig::new();
        rig.with(|r| r.shell.start_flow(ShellFlow::Welcome));
        rig.run_flows();
        assert!(rig.has_dialog());
    }
}
