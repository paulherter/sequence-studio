//! Sample dialogs for `--ui-shot --pose dlg-<name>`: the Save Changes, Recovery, Welcome, About, Reconnect and Export
//! Queue cards with the texts of the design kit, so a shot can be compared with the kit render.

use crate::shell_about::AboutPage;
use crate::shell_app_menu::AppMenuOutcome;
use crate::shell_dialog::ShellDialog;
use crate::shell_export_queue_popover::{BackgroundJob, ExportQueuePopover, QueueJob};
use crate::shell_form::{Row, ShellForm};
use crate::shell_host::ShellHost;
use sq_core_model::{Marker, MarkerColor};
use sq_core_time::{Id, Time};
use sq_export::core::queue::ExportJobState;
use sq_uikit::controls_grid::CGPoint;
use sq_uikit::localization::SQL10n;
use sq_uikit::sqdialog_model::SQDialogRole;

// Values the poses show, not UI text (the German-entry scan only reads literals in UI calls).
const SAMPLE_PRESET: &str = "TikTok 1080\u{d7}1920 30 fps vertical for stories and reels";
const SAMPLE_CUT: &str = "Rough cut";
const SAMPLE_MARKER: &str = "Marker 1";
const SAMPLE_REPEAT: &str = "Repeat frames";
const SAMPLE_BLEND: &str = "Blend frames";

impl ShellHost {
    /// A form card with the kit's buttons: (primary, cancel, red button on the left).
    fn sample_form(
        title: &str,
        note: &str,
        rows: Vec<Row>,
        buttons: (&str, Option<&str>, Option<&str>),
    ) -> ShellDialog {
        let mut d = ShellDialog::new(title, note);
        d.form = Some(Box::new(ShellForm::new(rows)));
        d.add_button(buttons.0, SQDialogRole::Default, false);
        if let Some(c) = buttons.1 {
            d.add_button(c, SQDialogRole::Cancel, false);
        }
        if let Some(x) = buttons.2 {
            d.add_button(x, SQDialogRole::Destructive, true);
        }
        d
    }

    /// The Library import alert for a pack whose presets clash with imported ones: Cancel and the three answers.
    pub fn pack_clash_dialog(pack: &str, info: &str) -> ShellDialog {
        let mut d = ShellDialog::new(&SQL10n::format("\u{201c}%@\u{201d} is already in the Library", &[pack]), info);
        d.add_button(&SQL10n::string("Keep Both"), SQDialogRole::Default, false);
        d.add_button(&SQL10n::string("Replace"), SQDialogRole::Normal, false);
        d.add_button(&SQL10n::string("Skip Existing"), SQDialogRole::Normal, false);
        d.add_button(&SQL10n::string("Cancel"), SQDialogRole::Cancel, false);
        d.cancel_first = true;
        d
    }

    /// Shows the sample dialog `name`; false for an unknown name.
    pub fn present_sample_dialog(&mut self, name: &str) -> bool {
        let d = match name {
            "save" => Self::save_changes_dialog("T2", true),
            "save-new" => Self::save_changes_dialog("T2", false),
            "recovery" => Self::recovery_dialog("T2", "Nov 10, 2026, 9:41:07 PM"),
            "welcome" => Self::welcome_dialog(),
            "app-menu-remove" => Self::app_menu_remove_dialog(),
            "app-menu-removed" => Self::app_menu_done_dialog(&AppMenuOutcome::Removed { trashed: false }),
            "about" => self.about_dialog(AboutPage::About),
            "ack" => self.about_dialog(AboutPage::Acknowledgments),
            "relink" => {
                let mut rows = Vec::new();
                let items = [
                    ("C2170.MP4", true, "Strong \u{b7} name, size, length \u{b7} /Volumes/Footage/Day 2/C2170.MP4"),
                    ("C2172.MP4", true, "Strong \u{b7} name, size \u{b7} /Volumes/Footage/Day 2/C2172.MP4"),
                    (
                        "IMG20261104_0412.MOV",
                        false,
                        "Weak \u{b7} similar name \u{b7} /Volumes/SD/DCIM/IMG20261104_0412.MOV",
                    ),
                ];
                for (i, (title, on, _)) in items.iter().enumerate() {
                    rows.push(Row::check(&format!("p{i}"), title, *on));
                }
                let mut form = ShellForm::new(rows);
                for (i, (_, _, detail)) in items.iter().enumerate() {
                    form.helps.insert(format!("p{i}"), (*detail).to_string());
                }
                Self::reconnect_dialog(
                    form,
                    "Found 3 of 4 missing files",
                    "1 still missing after this. Untick any match you do not trust; weak matches start unticked.",
                )
            }
            "library-import" => Self::pack_clash_dialog(
                "Summer Pack",
                "2 presets have the same name as one you already imported from this pack.",
            ),
            "form-anonymize" => {
                let mut d = Self::sample_form(
                    "Anonymize",
                    "Each person gets a mask that follows them through the clip. The cover is an effect limited to those masks; both stay editable in Effect Controls.",
                    vec![
                        Row::segmented("t", "Cover", &["Face", "Whole Person", "Skin"], 0, 0.0),
                        Row::segmented("c", "With", &["Mosaic", "Blur"], 0, 0.0),
                        Row::Text("2 people found on this frame, numbered left to right:".into()),
                        Row::check("p0", "Person 1 (left)", true),
                        Row::check("p1", "Person 2 (right)", true),
                        Row::Text("Detection is a best guess and can miss frames. Frames it was unsure about are listed afterwards. Always check the whole clip before you export.".into()),
                    ],
                    ("Anonymize", Some("Cancel"), None),
                );
                d.header_subtitle = Some("C2171.MP4".into());
                d
            }
            "form-new-sequence" => Self::sample_form(
                "New Sequence",
                "",
                vec![
                    Row::field("n", "Name", "Sequence 03"),
                    Row::popup("p", "Preset", &[SAMPLE_PRESET, "YouTube 1080p 30", "Cinema 4K 24"], 0),
                    Row::popup("s", "Pixel Shape", &["Square", "D1/DV NTSC 0.9091"], 0),
                    Row::popup("f", "Frame Rate", &["30 fps", "29.97 fps drop-frame"], 0),
                    Row::popup("a", "Sample Rate", &["48 kHz", "44.1 kHz"], 0),
                ],
                ("Create", Some("Cancel"), None),
            ),
            "form-remove-silences" => {
                let mut d = Self::sample_form(
                "Remove Silences",
                "Silences are cut and the gaps closed on every sync-locked track, so picture, music and B-roll stay in sync.",
                vec![
                    Row::field("l", "Level", "-35"),
                    Row::field("m", "Min. Length", "350"),
                    Row::field("k", "Keep Each Side", "70"),
                    Row::Text("No silences found.".into()),
                    Row::Text("Red ranges on the timeline will be cut. \u{201c}Mark for Review\u{201d} leaves them as proposed cuts to accept or reject.".into()),
                ],
                ("Remove", Some("Cancel"), None),
            );
                d.add_button("Mark for Review", SQDialogRole::Normal, true);
                d.ghost_buttons.insert(2);
                d
            }
            "form-captions" => Self::sample_form(
                "Create Captions",
                "Captions are made from the transcript of the whole sequence.",
                vec![
                    Row::popup("s", "Style", &["Subtitle, bottom center, white on a dark box", "Karaoke highlight"], 0),
                    Row::field("w", "Max. Words per Line", "7"),
                    Row::check("r", "Replace existing captions", false),
                ],
                ("Create", Some("Cancel"), None),
            ),
            "form-find" => Self::sample_form(
                "Find",
                "Select the clips and sequences that match.",
                vec![
                    Row::field("q", "Find", "interview"),
                    Row::popup(
                        "w",
                        "Where",
                        &["Clip name", "Marker comment", "Transcript text of the whole project"],
                        0,
                    ),
                    Row::check("c", "Match case", false),
                ],
                ("Find", Some("Cancel"), None),
            ),
            "form-timecode" => Self::sample_form(
                "Go to Timecode",
                "hh:mm:ss:ff, a shorter form like 1:00, or frames.",
                vec![Row::field("tc", "Timecode", "00:00:04:21")],
                ("Go", Some("Cancel"), None),
            ),
            "form-tone" => Self::sample_form(
                "Tone Settings",
                "Sine tone, 1 kHz at \u{2212}12 dB by default",
                vec![Row::field("f", "Frequency", "1000"), Row::field("l", "Level", "-12")],
                ("OK", Some("Cancel"), None),
            ),
            "form-preset" => Self::sample_form(
                "Save as Preset",
                "The preset keeps every setting and keyframe of the effects you pick.",
                vec![
                    Row::field("n", "Name", "Warm look with lifted shadows and a very long descriptive name"),
                    Row::popup("k", "Folder", &["My Presets", "Look Development/Client Work/Summer Campaign"], 0),
                    Row::check("e", "Include keyframes", true),
                ],
                ("Save", Some("Cancel"), None),
            ),
            "form-matte" => Self::sample_form(
                "New Color Matte",
                "",
                vec![Row::field("n", "Name", "Color Matte"), Row::field("c", "Color", "#1F6FEB")],
                ("Create", Some("Cancel"), None),
            ),
            "form-fcpxml" => Self::sample_form(
                "Export FCPXML",
                "The timeline goes out as an FCPXML file other editors can read. Effects that have no match there are skipped and listed afterwards.",
                vec![
                    Row::radio("scope", &["Open sequence", "All sequences"], 0),
                    Row::check("m", "Include markers", true),
                ],
                ("Export", Some("Cancel"), None),
            ),
            "form-voiceover" => Self::sample_form(
                "Voiceover from Text",
                "The voice is made on this Mac; nothing leaves it.",
                vec![
                    Row::popup("v", "Voice", &["Samantha (English, United States, enhanced quality)", "Daniel"], 0),
                    Row::field("t", "Text", "Welcome to the summer collection."),
                ],
                ("Create", Some("Cancel"), None),
            ),
            "form-checkpoint" => Self::sample_form(
                "Save Checkpoint",
                "A checkpoint is kept until you remove it; automatic backups never replace it.",
                vec![Row::field("n", "Checkpoint", SAMPLE_CUT)],
                ("Save", Some("Cancel"), None),
            ),
            "form-speed" => Self::sample_form(
                "Speed",
                "",
                vec![
                    Row::field("s", "Speed", "100.0"),
                    Row::field("d", "Duration", "00:00:04:21"),
                    Row::popup("f", "Frames", &[SAMPLE_REPEAT, SAMPLE_BLEND], 0),
                    Row::check("r", "Reverse", false),
                    Row::check("k", "Keep Pitch", true),
                    Row::check("m", "Move Later Clips", false),
                ],
                ("OK", Some("Cancel"), None),
            ),
            "form-marker" => {
                let m = Marker {
                    id: Id::from_u128(7),
                    time: Time::ZERO,
                    name: SAMPLE_MARKER.into(),
                    color: MarkerColor::Blue,
                    comment: String::new(),
                    duration: Time::ZERO,
                };
                let mut d = ShellDialog::new("Marker", "");
                d.form = Some(Box::new(Self::marker_form(&m, false, Time::new(1, 30))));
                d.add_button("OK", SQDialogRole::Default, false);
                d.add_button("Cancel", SQDialogRole::Cancel, false);
                d.add_button("Delete Marker", SQDialogRole::Destructive, true);
                d.ghost_buttons.insert(2);
                d
            }
            "queue" => {
                let job = |n: u128, name: &str, state, progress| QueueJob {
                    id: Id::from_u128(n),
                    name: name.into(),
                    state,
                    progress,
                };
                let mut pop =
                    ExportQueuePopover::new(CGPoint::new(self.size().width - 60.0, self.size().height - 40.0));
                pop.update(
                    &[
                        job(1, "Cut A.mp4", ExportJobState::Running, 0.42),
                        job(2, "Cut B.mp4", ExportJobState::Waiting, 0.0),
                        job(3, "Cut C.mp4", ExportJobState::Waiting, 0.0),
                    ],
                    Some(vec![
                        BackgroundJob { id: "proxy".into(), title: "Creating proxies".into(), progress: Some(0.38) },
                        BackgroundJob { id: "stt".into(), title: "Transcribing C2171.MP4".into(), progress: None },
                    ]),
                );
                pop.pinned = true;
                pop.layout(sq_uikit::controls_grid::CGRect::new(0.0, 0.0, self.size().width, self.size().height));
                self.export.popover = Some(pop);
                return true;
            }
            _ => return false,
        };
        drop(self.present(d));
        true
    }
}
