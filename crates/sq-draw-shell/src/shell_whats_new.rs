//! The What's new page's content (the Help test list adds the experimental features itself): the release text comes from `resources/whats-new.json`, a changelog shipped inside the app,
//! not from code. The file lists the release (version, date), the features to try (each with the command its Try button
//! runs) and the changes grouped as New, Improved and Fixed. A broken file shows an empty page, never a crash.

use sq_draw::experimental::Feature;
use sq_uikit::editor_command::{EditorCommand, EditorTool};
use sq_uikit::panel_id::PanelID;
use sq_uikit::sqicon::SQIcon;

/// The changelog that ships with the app.
const BUNDLED: &str = include_str!("../resources/whats-new.json");

/// One feature to test: its row and where the Try button goes.
#[derive(Clone, Debug, PartialEq)]
pub(crate) struct TestRow {
    pub icon: SQIcon,
    pub name: String,
    pub what: String,
    /// Wears the orange flask.
    pub experimental: bool,
    /// What Try runs; `None` hides nothing, the button just has no target.
    pub command: Option<EditorCommand>,
}

/// One list of changes: New, Improved or Fixed.
#[derive(Clone, Debug, PartialEq)]
pub(crate) struct ChangeGroup {
    pub icon: SQIcon,
    pub title: String,
    pub items: Vec<String>,
}

/// The page's content.
#[derive(Clone, Debug, Default, PartialEq)]
pub(crate) struct WhatsNew {
    pub version: String,
    /// "2026-11-12" as written in the file.
    pub date: String,
    pub tests: Vec<TestRow>,
    pub changes: Vec<ChangeGroup>,
}

impl WhatsNew {
    /// The shipped file, read once at start.
    pub(crate) fn bundled() -> WhatsNew {
        Self::parse(BUNDLED).unwrap_or_default()
    }

    /// Reads a changelog; `None` for text that is not the expected JSON.
    pub(crate) fn parse(json: &str) -> Option<WhatsNew> {
        let v: serde_json::Value = serde_json::from_str(json).ok()?;
        let text = |v: &serde_json::Value, k: &str| v.get(k).and_then(|s| s.as_str()).unwrap_or_default().to_string();
        let list = |v: &serde_json::Value, k: &str| v.get(k).and_then(|a| a.as_array()).cloned().unwrap_or_default();
        let icon = |v: &serde_json::Value| SQIcon::from_raw(&text(v, "icon")).unwrap_or(SQIcon::Sparkles);
        Some(WhatsNew {
            version: text(&v, "version"),
            date: text(&v, "date"),
            tests: list(&v, "tests")
                .iter()
                .map(|t| TestRow {
                    icon: icon(t),
                    name: text(t, "name"),
                    what: text(t, "what"),
                    experimental: t.get("experimental").and_then(|b| b.as_bool()).unwrap_or(false),
                    command: Self::command(&text(t, "try")),
                })
                .collect(),
            changes: Self::sorted(
                list(&v, "changes")
                    .iter()
                    .map(|g| ChangeGroup {
                        icon: icon(g),
                        title: text(g, "title"),
                        items: list(g, "items").iter().filter_map(|s| s.as_str().map(str::to_string)).collect(),
                    })
                    .collect(),
            ),
        })
    }

    /// New first, then Improved, then Fixed, whatever order the file lists them in; other titles keep their place after.
    fn sorted(mut groups: Vec<ChangeGroup>) -> Vec<ChangeGroup> {
        let rank = |g: &ChangeGroup| match g.title.as_str() {
            "New" => 0,
            "Improved" => 1,
            "Fixed" => 2,
            _ => 3,
        };
        groups.sort_by_key(rank);
        groups
    }

    /// The Help test rows: what is new in this release, then every experimental feature, each with its Try target.
    pub(crate) fn help_rows(&self) -> Vec<TestRow> {
        let mut rows: Vec<TestRow> = self.tests.iter().filter(|t| !t.experimental).cloned().collect();
        rows.extend(Feature::ALL.iter().map(|f| Self::feature_row(*f)));
        rows
    }

    fn feature_row(f: Feature) -> TestRow {
        let (icon, what, key) = match f {
            Feature::ProGrading => (SQIcon::Contrast, "Color page › Pro", "panel:steps"),
            Feature::MagicMask => (SQIcon::ToolMask, "Mask tool in the timeline", "tool:mask"),
            Feature::Stabilize => (SQIcon::Minimize, "Effects › Stabilize (not Gyroflow)", "stabilize"),
        };
        TestRow { icon, name: f.name().into(), what: what.into(), experimental: true, command: Self::command(key) }
    }

    /// The blue dot on the What's new rail item: the release was not opened yet (`seen` = the last version opened).
    pub(crate) fn unseen(&self, seen: Option<&str>) -> bool {
        !self.version.is_empty() && seen != Some(self.version.as_str())
    }

    /// The commands a Try button can run, by the key the changelog uses.
    pub(crate) fn command(key: &str) -> Option<EditorCommand> {
        Some(match key {
            "stabilize" => EditorCommand::Stabilize,
            "tool:draw" => EditorCommand::Tool(EditorTool::Draw),
            "tool:mask" => EditorCommand::Tool(EditorTool::Mask),
            "panel:project" => EditorCommand::FocusPanel(PanelID::Project),
            "panel:steps" => EditorCommand::FocusPanel(PanelID::Steps),
            _ => return None,
        })
    }

    /// "12 Nov 2026" for "2026-11-12"; the text itself when it is not a date.
    pub(crate) fn date_text(&self) -> String {
        const MONTHS: [&str; 12] = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
        let parts: Vec<&str> = self.date.split('-').collect();
        if let [y, m, d] = parts[..]
            && let (Ok(m), Ok(d)) = (m.parse::<usize>(), d.parse::<u32>())
            && (1..=12).contains(&m)
            && (1..=31).contains(&d)
            && y.len() == 4
        {
            return format!("{d} {} {y}", MONTHS[m - 1]);
        }
        self.date.clone()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_shipped_file_parses_into_tests_and_three_groups() {
        let w = WhatsNew::parse(BUNDLED).expect("the shipped changelog is valid");
        assert_eq!(w.version, "0.1.2");
        assert_eq!(w.tests.len(), 2);
        assert_eq!(w.help_rows().len(), 2 + Feature::ALL.len());
        assert_eq!(w.changes.iter().map(|g| g.title.as_str()).collect::<Vec<_>>(), ["New", "Improved", "Fixed"]);
        assert_eq!(w.changes.iter().map(|g| g.items.len()).sum::<usize>(), 11);
        assert!(w.tests.iter().all(|t| t.command.is_some()), "every Try button has a target");
        assert_eq!(w.help_rows().iter().filter(|t| t.experimental).count(), Feature::ALL.len());
        assert!(w.help_rows().iter().all(|t| t.command.is_some()), "every help row has a Try target");
    }

    #[test]
    fn changes_sort_new_improved_fixed_whatever_the_file_order() {
        let json = r#"{"changes":[{"title":"Fixed","items":["a"]},{"title":"Other","items":[]},{"title":"New","items":["b"]},{"title":"Improved","items":["c"]}]}"#;
        let w = WhatsNew::parse(json).unwrap();
        assert_eq!(
            w.changes.iter().map(|g| g.title.as_str()).collect::<Vec<_>>(),
            ["New", "Improved", "Fixed", "Other"]
        );
    }

    #[test]
    fn the_dot_shows_until_the_release_was_opened() {
        let w = WhatsNew { version: "0.1.2".into(), ..WhatsNew::default() };
        assert!(w.unseen(None));
        assert!(w.unseen(Some("0.1.1")), "an update brings the dot back");
        assert!(!w.unseen(Some("0.1.2")));
        assert!(!WhatsNew::default().unseen(None), "no changelog, no dot");
    }

    #[test]
    fn list_items_carry_no_long_dashes() {
        let w = WhatsNew::bundled();
        assert!(w.changes.iter().flat_map(|g| &g.items).all(|i| !i.contains('\u{2014}') && !i.contains('\u{2013}')));
    }

    #[test]
    fn the_date_reads_like_a_subtitle() {
        let w = WhatsNew { date: "2026-11-12".into(), ..WhatsNew::default() };
        assert_eq!(w.date_text(), "12 Nov 2026");
        let odd = WhatsNew { date: "soon".into(), ..WhatsNew::default() };
        assert_eq!(odd.date_text(), "soon");
    }

    #[test]
    fn a_broken_file_shows_an_empty_page() {
        assert_eq!(WhatsNew::parse("not json"), None);
        let w = WhatsNew::parse("{}").expect("an empty object is a page without rows");
        assert!(w.tests.is_empty() && w.changes.is_empty());
    }

    #[test]
    fn try_keys_map_to_commands() {
        assert_eq!(WhatsNew::command("stabilize"), Some(EditorCommand::Stabilize));
        assert_eq!(WhatsNew::command("tool:mask"), Some(EditorCommand::Tool(EditorTool::Mask)));
        assert_eq!(WhatsNew::command("nope"), None);
    }
}
