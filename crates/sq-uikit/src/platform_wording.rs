//! Texts written with Mac words ("this Mac", "Command-D", "Option-click", "⌘K") worded for the system they show on. The
//! Mac keeps them as they are; Windows and Linux get "this computer", "Ctrl+D", "Alt-click", "Ctrl+K". One table for
//! English and German, applied by the string lookup (`Catalogs::string`, `Catalogs::localized`) so no caller patches it.

use sq_os::Platform;

/// Mac phrase to the neutral one, longest first (a phrase may contain a shorter one).
const NEUTRAL: &[(&str, &str)] = &[
    ("Shift-Command-D", "Shift+Ctrl+D"),
    ("Command-D", "Ctrl+D"),
    ("Umschalt-Befehl-D", "Umschalt+Strg+D"),
    ("Befehl-D", "Strg+D"),
    ("Option-click", "Alt-click"),
    ("Option-drag", "Alt-drag"),
    ("Wahltaste-Klick", "Alt-Klick"),
    ("mit Option ziehen", "mit Alt ziehen"),
    ("Cmd+", "Ctrl+"),
    ("⌘", "Ctrl+"),
    ("this Mac", "this computer"),
    ("your Mac", "your computer"),
    ("slow Mac", "slow computer"),
    ("on Macs", "on computers"),
    ("the Mac is hot", "the computer is hot"),
    ("the Mac's", "the computer's"),
    ("the Mac has", "the computer has"),
    ("diesem Mac", "diesem Computer"),
    ("dieser Mac", "dieser Computer"),
    ("deinem Mac", "deinem Computer"),
    ("langsamen Mac", "langsamen Computer"),
    ("auf Macs", "auf Computern"),
    ("der Mac heiß", "der Computer heiß"),
    ("des Mac;", "des Computers;"),
];

/// Mac words that are right on every system: a view gamma named after the Mac, the apps it matches.
const ALLOWED: &[&str] = &["Mac 1.96", "Mac 1,96", "QuickTime and Mac apps"];

/// The Mac words left in a text that is shown on Windows or Linux (after `adapt`); empty when it reads right there.
pub fn mac_leftovers(text: &str) -> Vec<String> {
    let mut t = text.to_string();
    for a in ALLOWED {
        t = t.replace(a, "");
    }
    let mut bad: Vec<String> = ["⌘", "Command-", "Cmd", "Option-", "Befehl-", "Wahltaste", "Finder"]
        .iter()
        .filter(|w| t.contains(*w))
        .map(|w| w.to_string())
        .collect();
    bad.extend(t.split(|c: char| !c.is_alphanumeric()).filter(|w| *w == "Mac" || *w == "Macs").map(str::to_string));
    bad
}

/// Wording per platform.
pub enum PlatformWording {}

impl PlatformWording {
    /// A workspace name as `platform` shows it. The built-in "Editing \u{2013} MacBook" reads "Editing \u{2013} Laptop" on
    /// Windows and Linux; the stored name (the workspace's id) never changes, only what the menus and the title row print.
    pub fn workspace_name(name: &str, platform: Platform) -> String {
        if platform == Platform::Mac {
            return name.to_string();
        }
        name.replace("MacBook", "Laptop")
    }

    /// `text` as `platform` shows it; the Mac gets it unchanged.
    pub fn adapt(text: &str, platform: Platform) -> String {
        if platform == Platform::Mac {
            return text.to_string();
        }
        if text.contains("video editor for the Mac") {
            let name = if platform == Platform::Windows { "Windows" } else { "Linux" };
            return text.replace("for the Mac", &format!("for {name}"));
        }
        let (manager, manager_de) = if platform == Platform::Windows {
            ("File Explorer", "Explorer")
        } else {
            ("file manager", "Dateimanager")
        };
        let mut out = text
            .replace("Reveal in Finder", &format!("Show in {manager}"))
            .replace("Show in Finder", &format!("Show in {manager}"))
            .replace("Im Finder zeigen", &format!("Im {manager_de} zeigen"));
        for (mac, other) in NEUTRAL {
            if out.contains(mac) {
                out = out.replace(mac, other);
            }
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_macbook_workspace_reads_laptop_off_the_mac() {
        let name = "Editing \u{2013} MacBook";
        assert_eq!(PlatformWording::workspace_name(name, Platform::Mac), name);
        for p in [Platform::Windows, Platform::Linux] {
            assert_eq!(PlatformWording::workspace_name(name, p), "Editing \u{2013} Laptop");
            assert_eq!(PlatformWording::workspace_name("Editing \u{2013} Portrait", p), "Editing \u{2013} Portrait");
        }
    }
    use crate::localization::Catalogs;
    #[test]
    fn windows_and_linux_texts_have_no_mac_words() {
        let mut texts: Vec<String> = vec![
            crate::about_content::TAGLINE.to_string(),
            "Search shortcuts by name or key, e.g. blade or ⌘K".to_string(),
        ];
        let bundled = Catalogs::bundled("de");
        for (k, v) in bundled.table("de") {
            texts.push(k.clone());
            texts.push(v.clone());
        }
        for platform in [Platform::Windows, Platform::Linux] {
            let catalogs = Catalogs::bundled("de").with_platform(platform);
            let mut failures = Vec::new();
            for t in &texts {
                for shown in [PlatformWording::adapt(t, platform), catalogs.string(t, Some("en"))] {
                    let bad = mac_leftovers(&shown);
                    if !bad.is_empty() {
                        failures.push(format!("{bad:?} in {shown}"));
                    }
                }
            }
            failures.sort();
            failures.dedup();
            assert!(failures.is_empty(), "{platform:?}: {failures:#?}");
        }
    }

    #[test]
    fn the_mac_keeps_its_wording() {
        let t = "Only programs on this Mac; Command-D, Option-click, ⌘K.";
        assert_eq!(PlatformWording::adapt(t, Platform::Mac), t);
    }

    #[test]
    fn windows_and_linux_get_their_words() {
        assert_eq!(
            PlatformWording::adapt("Turn off on a slow Mac; Shift-Command-D, Option-drag, ⌘K", Platform::Windows),
            "Turn off on a slow computer; Shift+Ctrl+D, Alt-drag, Ctrl+K"
        );
        assert_eq!(
            PlatformWording::adapt("A fast, uncluttered video editor for the Mac. Free.", Platform::Linux),
            "A fast, uncluttered video editor for Linux. Free."
        );
        assert_eq!(
            PlatformWording::adapt("Auf einem langsamen Mac, Umschalt-Befehl-D", Platform::Linux),
            "Auf einem langsamen Computer, Umschalt+Strg+D"
        );
    }
}
