// Swift: SQFontFieldModel.swift
//! Logic of the font field (Panels board "Font field"): which fonts match what was typed, the sections under the field
//! ("Matches", "Recent", "Included", "Show All Fonts…"), the keyboard highlight and the recents in the settings key
//! `sq.font.recents`. No drawing: the view feeds in the installed families.

use crate::appearance_palette::UiDefaults;
use sq_core_model::trim_spaces;
use sq_core_time::text::standard_compare;

/// One row under the font field.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Row {
    /// A section title.
    Header(String),
    /// A line between sections.
    Separator,
    /// A selectable font: `name` goes to the callbacks (family or PostScript name), `title` is shown in that face.
    Font { name: String, title: String, indented: bool },
    /// The "Show All Fonts…" entry.
    ShowAll,
}

impl Row {
    /// Fonts and the full-list entry can be highlighted; headers and separators cannot.
    pub fn is_selectable(&self) -> bool {
        matches!(self, Row::Font { .. } | Row::ShowAll)
    }

    fn plain(name: &str) -> Row {
        Row::Font { name: name.to_string(), title: name.to_string(), indented: false }
    }
}

/// The state of the font field.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SQFontFieldModel {
    families: Vec<String>,
    recents: Vec<String>,
    /// Fonts that ship with the app, listed under "Included" while nothing is typed (each row is drawn in its own face = preview).
    pub bundled: Vec<String>,
    query: String,
    all_rows: Option<Vec<Row>>,
    highlight: Option<usize>,
}

/// Case and accent folding of the search text.
// shortcut: accents are stripped for the Latin-1 letters and combining marks only, upgrade with a full folding helper in
// sq_core_time::text when other scripts must match across accents.
fn fold(s: &str) -> String {
    s.to_lowercase()
        .chars()
        .filter(|c| !('\u{300}'..='\u{36F}').contains(c))
        .flat_map(|c| -> Vec<char> {
            match c {
                'à'..='å' => vec!['a'],
                'ç' => vec!['c'],
                'è'..='ë' => vec!['e'],
                'ì'..='ï' => vec!['i'],
                'ñ' => vec!['n'],
                'ò'..='ö' | 'ø' => vec!['o'],
                'ù'..='ü' => vec!['u'],
                'ý' | 'ÿ' => vec!['y'],
                'ß' => vec!['s', 's'],
                _ => vec![c],
            }
        })
        .collect()
}

impl SQFontFieldModel {
    /// Settings key of the recents list.
    pub const RECENTS_KEY: &'static str = "sq.font.recents";
    /// Recents kept.
    pub const MAX_RECENTS: usize = 5;
    /// Matches listed.
    pub const MAX_MATCHES: usize = 8;

    /// A model over the installed `families`.
    pub fn new(families: Vec<String>, recents: Vec<String>, bundled: Vec<String>) -> SQFontFieldModel {
        let mut m =
            SQFontFieldModel { families, recents, bundled, query: String::new(), all_rows: None, highlight: None };
        m.rebuild_highlight();
        m
    }

    /// The installed families.
    pub fn families(&self) -> &[String] {
        &self.families
    }

    /// The recent fonts, newest first.
    pub fn recents(&self) -> &[String] {
        &self.recents
    }

    /// The typed text.
    pub fn query(&self) -> &str {
        &self.query
    }

    /// Rows of the full list while "Show All Fonts…" is open; `None` in the match/recent list.
    pub fn all_rows(&self) -> Option<&[Row]> {
        self.all_rows.as_deref()
    }

    /// Index into `rows()` of the highlighted row (follows arrows and the pointer).
    pub fn highlight(&self) -> Option<usize> {
        self.highlight
    }

    /// Matches of `query` among `families`: prefix first, then word prefix, then substring; each group A to Z. Empty query: none.
    pub fn matches_in(query: &str, families: &[String], limit: usize) -> Vec<String> {
        let q = trim_spaces(&fold(query), false).to_string();
        if q.is_empty() {
            return Vec::new();
        }
        let mut ranked: Vec<(i32, &String)> = Vec::new();
        for f in families {
            let n = fold(f);
            if n == q {
                ranked.push((-1, f));
            } else if n.starts_with(&q) {
                ranked.push((0, f));
            } else if n.split(|c: char| !c.is_alphanumeric()).any(|w| !w.is_empty() && w.starts_with(&q)) {
                ranked.push((1, f));
            } else if n.contains(&q) {
                ranked.push((2, f));
            }
        }
        ranked.sort_by(|a, b| a.0.cmp(&b.0).then_with(|| standard_compare(a.1, b.1)));
        ranked.into_iter().take(limit).map(|r| r.1.clone()).collect()
    }

    /// The matches of the typed text.
    pub fn matches(&self) -> Vec<String> {
        Self::matches_in(&self.query, &self.families, Self::MAX_MATCHES)
    }

    /// Matches, a separator, recents (minus the matches already listed), a separator, "Show All Fonts…".
    pub fn rows(&self) -> Vec<Row> {
        if let Some(all) = &self.all_rows {
            return all.clone();
        }
        let mut out: Vec<Row> = Vec::new();
        let m = self.matches();
        if !m.is_empty() {
            out.push(Row::Header("Matches".to_string()));
            out.extend(m.iter().map(|n| Row::plain(n)));
        }
        let rec: Vec<&String> = self.recents.iter().filter(|r| !m.contains(r)).collect();
        if !rec.is_empty() {
            if !out.is_empty() {
                out.push(Row::Separator);
            }
            out.push(Row::Header("Recent".to_string()));
            out.extend(rec.iter().map(|n| Row::plain(n)));
        }
        if m.is_empty() {
            let inc: Vec<&String> = self.bundled.iter().filter(|b| !rec.contains(b)).collect();
            if !inc.is_empty() {
                if !out.is_empty() {
                    out.push(Row::Separator);
                }
                out.push(Row::Header("Included".to_string()));
                out.extend(inc.iter().map(|n| Row::plain(n)));
            }
        }
        if !out.is_empty() {
            out.push(Row::Separator);
        }
        out.push(Row::ShowAll);
        out
    }

    /// Sets the typed text and leaves the full list.
    pub fn set_query(&mut self, text: &str) {
        self.query = text.to_string();
        self.all_rows = None;
        self.rebuild_highlight();
    }

    /// Switches to the full list (`rows` supplied by the view from the installed families and their faces).
    pub fn show_all(&mut self, rows: Vec<Row>, current: Option<&str>) {
        self.highlight = rows
            .iter()
            .position(|r| matches!(r, Row::Font { name, .. } if Some(name.as_str()) == current))
            .or_else(|| rows.iter().position(Row::is_selectable));
        self.all_rows = Some(rows);
    }

    /// First match highlighted while typing, else nothing.
    fn rebuild_highlight(&mut self) {
        let r = self.rows();
        self.highlight = if self.matches().is_empty() { None } else { r.iter().position(Row::is_selectable) };
    }

    /// Moves the highlight over the selectable rows, clamped at both ends.
    pub fn move_highlight(&mut self, delta: i64) {
        let r = self.rows();
        let sel: Vec<usize> = (0..r.len()).filter(|&i| r[i].is_selectable()).collect();
        let (Some(&first), Some(&last)) = (sel.first(), sel.last()) else {
            self.highlight = None;
            return;
        };
        let Some(pos) = self.highlight.and_then(|cur| sel.iter().position(|&i| i == cur)) else {
            self.highlight = Some(if delta >= 0 { first } else { last });
            return;
        };
        let moved = (pos as i64).saturating_add(delta).clamp(0, sel.len() as i64 - 1);
        self.highlight = Some(sel[moved as usize]);
    }

    /// Sets the highlight to a selectable row; `None` clears it, anything else is ignored.
    pub fn set_highlight(&mut self, index: Option<usize>) {
        let r = self.rows();
        match index {
            Some(i) if r.get(i).is_some_and(Row::is_selectable) => self.highlight = Some(i),
            None => self.highlight = None,
            Some(_) => {}
        }
    }

    /// The highlighted row.
    pub fn highlighted_row(&self) -> Option<Row> {
        self.highlight.and_then(|h| self.rows().into_iter().nth(h))
    }

    /// Font name to apply for Return: the highlighted font, else the typed text when it names an installed family exactly.
    pub fn return_target(&self) -> Option<String> {
        if let Some(Row::Font { name, .. }) = self.highlighted_row() {
            return Some(name);
        }
        let q = trim_spaces(&fold(&self.query), false).to_string();
        self.families.iter().find(|f| fold(f) == q && !q.is_empty()).cloned()
    }

    // Recents

    /// `list` with `name` moved to the front, capped at `max`.
    pub fn adding_recent(name: &str, list: &[String], max: usize) -> Vec<String> {
        let n = trim_spaces(name, false);
        if n.is_empty() {
            return list.to_vec();
        }
        let mut out = vec![n.to_string()];
        out.extend(list.iter().filter(|x| x.as_str() != n).cloned());
        out.truncate(max);
        out
    }

    /// The stored recents (at most `MAX_RECENTS`).
    pub fn load_recents(defaults: &dyn UiDefaults) -> Vec<String> {
        let mut list = defaults.string_array(Self::RECENTS_KEY).unwrap_or_default();
        list.truncate(Self::MAX_RECENTS);
        list
    }

    /// Stores `name` as the newest recent.
    pub fn remember(name: &str, defaults: &mut dyn UiDefaults) {
        let list = Self::adding_recent(name, &Self::load_recents(defaults), Self::MAX_RECENTS);
        defaults.set_string_array(Self::RECENTS_KEY, &list);
    }
}

/// Guards a deferred step of the font search against a newer keystroke: take a token before scheduling, and apply the
/// result only while the token is still current. Any later `begin()` (the next keystroke) retires older tokens.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct SQSearchGuard {
    generation: i64,
}

impl SQSearchGuard {
    /// A guard with no token handed out.
    pub fn new() -> SQSearchGuard {
        SQSearchGuard::default()
    }

    /// Hands out a new token and retires the older ones.
    pub fn begin(&mut self) -> i64 {
        self.generation += 1;
        self.generation
    }

    /// Whether `token` is the newest.
    pub fn is_current(&self, token: i64) -> bool {
        token == self.generation
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn s(v: &[&str]) -> Vec<String> {
        v.iter().map(|x| x.to_string()).collect()
    }

    fn fams() -> Vec<String> {
        s(&[
            "Interstate Condensed",
            "Inter Tight",
            "Inter",
            "Bebas Neue",
            "Playfair Display",
            "Helvetica",
            "Inter Display",
            "Avenir Next",
        ])
    }

    fn font(n: &str) -> Row {
        Row::plain(n)
    }

    fn header(t: &str) -> Row {
        Row::Header(t.to_string())
    }

    #[test]
    fn matching_ranks_prefix_word_then_substring() {
        let mut f = fams();
        f.push("Winter Sans".to_string());
        let m = SQFontFieldModel::matches_in("inter", &f, 8);
        assert_eq!(m, s(&["Inter", "Inter Display", "Inter Tight", "Interstate Condensed", "Winter Sans"]));
        assert_eq!(SQFontFieldModel::matches_in("NEXT", &fams(), 8), s(&["Avenir Next"])); // word prefix, case-insensitive
        assert!(SQFontFieldModel::matches_in("  ", &fams(), 8).is_empty());
        assert!(SQFontFieldModel::matches_in("zzz", &fams(), 8).is_empty());
        assert_eq!(SQFontFieldModel::matches_in("e", &fams(), 2).len(), 2);
    }

    #[test]
    fn rows_list_matches_recent_and_show_all() {
        let mut m = SQFontFieldModel::new(fams(), s(&["Bebas Neue", "Inter"]), vec![]);
        // Empty query: only recents and the full-list entry.
        assert_eq!(m.rows(), vec![header("Recent"), font("Bebas Neue"), font("Inter"), Row::Separator, Row::ShowAll]);
        assert_eq!(m.highlight(), None);
        m.set_query("inter");
        let r = m.rows();
        assert_eq!(r.first(), Some(&header("Matches")));
        assert!(r.contains(&header("Recent")));
        // "Inter" is already a match: not repeated under Recent.
        assert_eq!(r.iter().filter(|x| **x == font("Inter")).count(), 1);
        assert_eq!(r.last(), Some(&Row::ShowAll));
        assert_eq!(m.highlighted_row(), Some(font("Inter")));
    }

    #[test]
    fn included_fonts_listed_when_nothing_typed() {
        let mut m = SQFontFieldModel::new(fams(), s(&["Anton"]), s(&["Inter", "Anton", "Bangers"]));
        assert_eq!(
            m.rows(),
            vec![
                header("Recent"),
                font("Anton"),
                Row::Separator,
                header("Included"),
                font("Inter"),
                font("Bangers"),
                Row::Separator,
                Row::ShowAll
            ]
        );
        m.move_highlight(1);
        m.move_highlight(1);
        assert_eq!(m.highlighted_row(), Some(font("Inter"))); // arrows preview the bundled fonts
        m.set_query("inter");
        assert!(!m.rows().contains(&header("Included"))); // typing narrows to matches
    }

    #[test]
    fn arrows_clamp_and_skip_headers() {
        let mut m = SQFontFieldModel::new(fams(), s(&["Bebas Neue"]), vec![]);
        m.set_query("bebas"); // Matches: Bebas Neue; Recent is the same font, so only showAll follows
        assert_eq!(m.highlighted_row(), Some(font("Bebas Neue")));
        m.move_highlight(-1);
        assert_eq!(m.highlighted_row(), Some(font("Bebas Neue")));
        m.move_highlight(1);
        assert_eq!(m.highlighted_row(), Some(Row::ShowAll));
        m.move_highlight(1);
        assert_eq!(m.highlighted_row(), Some(Row::ShowAll));
        m.move_highlight(-1);
        assert_eq!(m.highlighted_row(), Some(font("Bebas Neue")));
    }

    #[test]
    fn return_target() {
        let mut m = SQFontFieldModel::new(fams(), vec![], vec![]);
        m.set_query("play");
        assert_eq!(m.return_target().as_deref(), Some("Playfair Display"));
        m.set_query("helvetica");
        m.set_highlight(None);
        assert_eq!(m.return_target().as_deref(), Some("Helvetica")); // exact family name even without highlight
        m.set_query("nothing");
        assert_eq!(m.return_target(), None);
    }

    #[test]
    fn show_all_list_starts_at_current_font() {
        let mut m = SQFontFieldModel::new(fams(), vec![], vec![]);
        let rows = vec![
            font("A"),
            Row::Font { name: "A-Bold".to_string(), title: "Bold".to_string(), indented: true },
            font("B"),
        ];
        m.show_all(rows.clone(), Some("A-Bold"));
        assert_eq!(m.rows(), rows);
        assert_eq!(m.highlight(), Some(1));
        m.set_query("x"); // typing leaves the full list
        assert_eq!(m.all_rows(), None);
    }

    #[test]
    fn recents_dedupe_cap_and_persist() {
        let mut l: Vec<String> = vec![];
        for n in ["A", "B", "C", "D", "E", "F", "B"] {
            l = SQFontFieldModel::adding_recent(n, &l, SQFontFieldModel::MAX_RECENTS);
        }
        assert_eq!(l, s(&["B", "F", "E", "D", "C"]));
        let mut d = crate::appearance_palette::MemoryDefaults::default();
        SQFontFieldModel::remember("Inter", &mut d);
        SQFontFieldModel::remember("Bebas Neue", &mut d);
        assert_eq!(SQFontFieldModel::load_recents(&d), s(&["Bebas Neue", "Inter"]));
        assert_eq!(UiDefaults::string_array(&d, "sq.font.recents"), Some(s(&["Bebas Neue", "Inter"])));
    }

    #[test]
    fn search_guard_retires_older_tokens() {
        let mut g = SQSearchGuard::new();
        let a = g.begin();
        assert!(g.is_current(a));
        let b = g.begin();
        assert!(!g.is_current(a) && g.is_current(b));
    }
}
