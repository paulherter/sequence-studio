// SPDX-License-Identifier: GPL-3.0-or-later
//! Dates, relative times, numbers and language names in the user's zone and the interface language's order, the part of
//! Swift's `DateFormatter` / `Date.FormatStyle` / `NumberFormatter` / `Locale` the shell uses. Two orders are known: German
//! (`11.11.2026, 14:05`, `1.234,5`) and everything else as en_US (`Nov 11, 2026, 2:05 PM`, `1,234.5`).
// shortcut: only the two shipped interface languages have their own order; a third language falls back to en_US until it
// gets a row in `Order::of`. The zone is the machine's (chrono), the order comes from the interface language.

use crate::localization::SQL10n;
use sq_core_time::Timestamp;
use sq_core_time::local_time::{Civil, local_civil};

const MONTHS_EN: [&str; 12] = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

/// How one language writes dates and numbers.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Order {
    German,
    English,
}

impl Order {
    fn of(language: &str) -> Order {
        if language.starts_with("de") { Order::German } else { Order::English }
    }
}

/// "Nov 11, 2026" / "11.11.2026" for a civil date.
fn date_part(c: &Civil, order: Order) -> String {
    match order {
        Order::German => format!("{:02}.{:02}.{:04}", c.day, c.month, c.year),
        Order::English => format!("{} {}, {}", MONTHS_EN[(c.month.clamp(1, 12) - 1) as usize], c.day, c.year),
    }
}

/// The clock time, with seconds or without.
fn time_part(c: &Civil, order: Order, seconds: bool) -> String {
    match order {
        Order::German => {
            if seconds {
                format!("{:02}:{:02}:{:02}", c.hour, c.minute, c.second)
            } else {
                format!("{:02}:{:02}", c.hour, c.minute)
            }
        }
        Order::English => {
            let h12 = if c.hour % 12 == 0 { 12 } else { c.hour % 12 };
            let ampm = if c.hour < 12 { "AM" } else { "PM" };
            if seconds {
                format!("{h12}:{:02}:{:02} {ampm}", c.minute, c.second)
            } else {
                format!("{h12}:{:02} {ampm}", c.minute)
            }
        }
    }
}

const WEEKDAYS_EN: [&str; 7] = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
const WEEKDAYS_DE: [&str; 7] = ["Mo.", "Di.", "Mi.", "Do.", "Fr.", "Sa.", "So."];
const MONTHS_DE: [&str; 12] =
    ["Jan.", "Feb.", "M\u{e4}rz", "Apr.", "Mai", "Juni", "Juli", "Aug.", "Sept.", "Okt.", "Nov.", "Dez."];

/// Weekday index of a civil date, 0 = Monday.
fn weekday_index(c: &Civil) -> usize {
    let y = if c.month <= 2 { c.year - 1 } else { c.year };
    let era = y.div_euclid(400);
    let yoe = y.rem_euclid(400);
    let doy = (153 * (if c.month > 2 { c.month - 3 } else { c.month + 9 }) + 2) / 5 + c.day - 1;
    let days = era * 146_097 + yoe * 365 + yoe / 4 - yoe / 100 + doy - 719_468;
    (days + 3).rem_euclid(7) as usize
}

/// Group title of a day (template `EEEMMMd`): "Thu, Nov 5" / "Do., 5. Nov.".
pub fn day_title_of(c: &Civil, language: &str) -> String {
    let m = (c.month.clamp(1, 12) - 1) as usize;
    match Order::of(language) {
        Order::German => format!("{}, {}. {}", WEEKDAYS_DE[weekday_index(c)], c.day, MONTHS_DE[m]),
        Order::English => format!("{}, {} {}", WEEKDAYS_EN[weekday_index(c)], MONTHS_EN[m], c.day),
    }
}

/// Medium date of a civil time in a language (`DateFormatter` `.medium`).
pub fn medium_date_of(c: &Civil, language: &str) -> String {
    date_part(c, Order::of(language))
}

/// Medium date and time of a civil time (`.medium` + `.short`), or with seconds (`Date.FormatStyle` `.abbreviated` +
/// `.standard`).
pub fn date_time_of(c: &Civil, language: &str, seconds: bool) -> String {
    let order = Order::of(language);
    format!("{}, {}", date_part(c, order), time_part(c, order, seconds))
}

/// Medium date of `t` in the machine's zone and the interface language.
pub fn medium_date(t: Timestamp) -> String {
    medium_date_of(&local_civil(t), &SQL10n::current_language())
}

/// Medium date and short time of `t` in the machine's zone and the interface language.
pub fn medium_date_short_time(t: Timestamp) -> String {
    date_time_of(&local_civil(t), &SQL10n::current_language(), false)
}

/// Abbreviated date and standard time (with seconds) of `t`.
pub fn date_time_standard(t: Timestamp) -> String {
    date_time_of(&local_civil(t), &SQL10n::current_language(), true)
}

/// "12 min. ago" / "vor 12 Min." (`RelativeDateTimeFormatter` `.short`, numeric).
pub fn ago(seconds: i64, language: &str) -> String {
    let s = seconds.max(0);
    let (n, key_en, key_de_one, key_de) = if s < 60 {
        (s, "%@ sec. ago", "", "vor %@ Sek.")
    } else if s < 3600 {
        (s / 60, "%@ min. ago", "", "vor %@ Min.")
    } else if s < 86_400 {
        (s / 3600, "%@ hr. ago", "", "vor %@ Std.")
    } else {
        (s / 86_400, "%@ days ago", "vor %@ Tag", "vor %@ Tagen")
    };
    let n_text = n.to_string();
    if Order::of(language) == Order::German {
        let f = if n == 1 && !key_de_one.is_empty() { key_de_one } else { key_de };
        return f.replace("%@", &n_text);
    }
    let f = if n == 1 && key_en == "%@ days ago" { "%@ day ago" } else { key_en };
    f.replace("%@", &n_text)
}

/// A number with grouping and `decimals` fraction digits in the language's separators.
pub fn number(v: f64, decimals: usize, language: &str) -> String {
    let en = en_number(v, decimals);
    match Order::of(language) {
        Order::English => en,
        Order::German => en
            .chars()
            .map(|c| match c {
                ',' => '.',
                '.' => ',',
                other => other,
            })
            .collect(),
    }
}

/// Grouped number with `.` decimals and `,` groups, rounded half to even like `NumberFormatter`.
fn en_number(v: f64, decimals: usize) -> String {
    if !v.is_finite() {
        return v.to_string();
    }
    let text = format!("{:.*}", decimals, v.abs());
    let (int_part, frac) = match text.split_once('.') {
        Some((i, f)) => (i.to_string(), Some(f.to_string())),
        None => (text.clone(), None),
    };
    let mut out = String::new();
    if v < 0.0 && text.chars().any(|c| c.is_ascii_digit() && c != '0') {
        out.push('-');
    }
    for (i, ch) in int_part.chars().enumerate() {
        if i > 0 && (int_part.len() - i).is_multiple_of(3) {
            out.push(',');
        }
        out.push(ch);
    }
    if let Some(f) = frac {
        out.push('.');
        out.push_str(&f);
    }
    out
}

/// A number in the interface language's separators.
pub fn number_current(v: f64, decimals: usize) -> String {
    number(v, decimals, &SQL10n::current_language())
}

// (code, English, German): every language of the speech engine (Whisper's list) and the interface languages, so no
// language shows as a bare code.
const LANGUAGES: [(&str, &str, &str); 100] = [
    ("en", "English", "Englisch"),
    ("zh", "Chinese", "Chinesisch"),
    ("de", "German", "Deutsch"),
    ("es", "Spanish", "Spanisch"),
    ("ru", "Russian", "Russisch"),
    ("ko", "Korean", "Koreanisch"),
    ("fr", "French", "Französisch"),
    ("ja", "Japanese", "Japanisch"),
    ("pt", "Portuguese", "Portugiesisch"),
    ("tr", "Turkish", "Türkisch"),
    ("pl", "Polish", "Polnisch"),
    ("ca", "Catalan", "Katalanisch"),
    ("nl", "Dutch", "Niederländisch"),
    ("ar", "Arabic", "Arabisch"),
    ("sv", "Swedish", "Schwedisch"),
    ("it", "Italian", "Italienisch"),
    ("id", "Indonesian", "Indonesisch"),
    ("hi", "Hindi", "Hindi"),
    ("fi", "Finnish", "Finnisch"),
    ("vi", "Vietnamese", "Vietnamesisch"),
    ("he", "Hebrew", "Hebräisch"),
    ("uk", "Ukrainian", "Ukrainisch"),
    ("el", "Greek", "Griechisch"),
    ("ms", "Malay", "Malaiisch"),
    ("cs", "Czech", "Tschechisch"),
    ("ro", "Romanian", "Rumänisch"),
    ("da", "Danish", "Dänisch"),
    ("hu", "Hungarian", "Ungarisch"),
    ("ta", "Tamil", "Tamil"),
    ("no", "Norwegian", "Norwegisch"),
    ("nb", "Norwegian Bokmål", "Norwegisch (Bokmål)"),
    ("nn", "Norwegian Nynorsk", "Norwegisch (Nynorsk)"),
    ("th", "Thai", "Thailändisch"),
    ("ur", "Urdu", "Urdu"),
    ("hr", "Croatian", "Kroatisch"),
    ("bg", "Bulgarian", "Bulgarisch"),
    ("lt", "Lithuanian", "Litauisch"),
    ("la", "Latin", "Latein"),
    ("mi", "Maori", "Maori"),
    ("ml", "Malayalam", "Malayalam"),
    ("cy", "Welsh", "Walisisch"),
    ("sk", "Slovak", "Slowakisch"),
    ("te", "Telugu", "Telugu"),
    ("fa", "Persian", "Persisch"),
    ("lv", "Latvian", "Lettisch"),
    ("bn", "Bengali", "Bengalisch"),
    ("sr", "Serbian", "Serbisch"),
    ("az", "Azerbaijani", "Aserbaidschanisch"),
    ("sl", "Slovenian", "Slowenisch"),
    ("kn", "Kannada", "Kannada"),
    ("et", "Estonian", "Estnisch"),
    ("mk", "Macedonian", "Mazedonisch"),
    ("br", "Breton", "Bretonisch"),
    ("eu", "Basque", "Baskisch"),
    ("is", "Icelandic", "Isländisch"),
    ("hy", "Armenian", "Armenisch"),
    ("ne", "Nepali", "Nepalesisch"),
    ("mn", "Mongolian", "Mongolisch"),
    ("bs", "Bosnian", "Bosnisch"),
    ("kk", "Kazakh", "Kasachisch"),
    ("sq", "Albanian", "Albanisch"),
    ("sw", "Swahili", "Suaheli"),
    ("gl", "Galician", "Galicisch"),
    ("mr", "Marathi", "Marathi"),
    ("pa", "Punjabi", "Pandschabi"),
    ("si", "Sinhala", "Singhalesisch"),
    ("km", "Khmer", "Khmer"),
    ("sn", "Shona", "Shona"),
    ("yo", "Yoruba", "Yoruba"),
    ("so", "Somali", "Somali"),
    ("af", "Afrikaans", "Afrikaans"),
    ("oc", "Occitan", "Okzitanisch"),
    ("ka", "Georgian", "Georgisch"),
    ("be", "Belarusian", "Belarussisch"),
    ("tg", "Tajik", "Tadschikisch"),
    ("sd", "Sindhi", "Sindhi"),
    ("gu", "Gujarati", "Gujarati"),
    ("am", "Amharic", "Amharisch"),
    ("yi", "Yiddish", "Jiddisch"),
    ("lo", "Lao", "Laotisch"),
    ("uz", "Uzbek", "Usbekisch"),
    ("fo", "Faroese", "Färöisch"),
    ("ht", "Haitian Creole", "Haitianisch"),
    ("ps", "Pashto", "Paschtu"),
    ("tk", "Turkmen", "Turkmenisch"),
    ("mt", "Maltese", "Maltesisch"),
    ("sa", "Sanskrit", "Sanskrit"),
    ("lb", "Luxembourgish", "Luxemburgisch"),
    ("my", "Burmese", "Birmanisch"),
    ("bo", "Tibetan", "Tibetisch"),
    ("tl", "Tagalog", "Tagalog"),
    ("mg", "Malagasy", "Madagassisch"),
    ("as", "Assamese", "Assamesisch"),
    ("tt", "Tatar", "Tatarisch"),
    ("haw", "Hawaiian", "Hawaiianisch"),
    ("ln", "Lingala", "Lingala"),
    ("ha", "Hausa", "Haussa"),
    ("ba", "Bashkir", "Baschkirisch"),
    ("jw", "Javanese", "Javanisch"),
    ("su", "Sundanese", "Sundanesisch"),
];

// (code, the language's own name) of the interface languages, for the language picker.
const NATIVE_NAMES: [(&str, &str); 14] = [
    ("de", "Deutsch"),
    ("en", "English"),
    ("fr", "français"),
    ("es", "español"),
    ("it", "italiano"),
    ("pt", "português"),
    ("nl", "Nederlands"),
    ("pl", "polski"),
    ("ru", "русский"),
    ("tr", "Türkçe"),
    ("ja", "日本語"),
    ("ko", "한국어"),
    ("zh", "中文"),
    ("sv", "svenska"),
];

// (code, English, German)
const REGIONS: [(&str, &str, &str); 24] = [
    ("DE", "Germany", "Deutschland"),
    ("AT", "Austria", "Österreich"),
    ("CH", "Switzerland", "Schweiz"),
    ("US", "United States", "Vereinigte Staaten"),
    ("GB", "United Kingdom", "Vereinigtes Königreich"),
    ("FR", "France", "Frankreich"),
    ("ES", "Spain", "Spanien"),
    ("IT", "Italy", "Italien"),
    ("PT", "Portugal", "Portugal"),
    ("BR", "Brazil", "Brasilien"),
    ("NL", "Netherlands", "Niederlande"),
    ("JP", "Japan", "Japan"),
    ("CN", "China", "China"),
    ("MX", "Mexico", "Mexiko"),
    ("AU", "Australia", "Australien"),
    ("CA", "Canada", "Kanada"),
    ("IN", "India", "Indien"),
    ("SE", "Sweden", "Schweden"),
    ("DK", "Denmark", "Dänemark"),
    ("NO", "Norway", "Norwegen"),
    ("FI", "Finland", "Finnland"),
    ("PL", "Poland", "Polen"),
    ("RU", "Russia", "Russland"),
    ("UA", "Ukraine", "Ukraine"),
];

/// `Locale.localizedString(forIdentifier:)`: "German (Germany)" in English, "Deutsch (Deutschland)" in German; an unknown
/// code stays as written. `in_language` `None` is the interface language.
pub fn language_name(code: &str, in_language: Option<&str>) -> String {
    let current = SQL10n::current_language();
    let target = in_language.unwrap_or(&current);
    let german = Order::of(target) == Order::German;
    let mut parts = code.split(['-', '_']);
    let lang = parts.next().unwrap_or("");
    let Some(row) = LANGUAGES.iter().find(|r| r.0 == lang) else { return code.to_string() };
    let name = if german { row.2 } else { row.1 };
    match parts.next().and_then(|r| REGIONS.iter().find(|x| x.0 == r)) {
        Some(region) => format!("{name} ({})", if german { region.2 } else { region.1 }),
        None => name.to_string(),
    }
}

/// A language in its own name ("Deutsch", "English"), for the interface-language picker.
pub fn native_language_name(code: &str) -> String {
    let lang = code.split(['-', '_']).next().unwrap_or("");
    NATIVE_NAMES.iter().find(|r| r.0 == lang).map_or_else(|| code.to_string(), |r| capitalized_first(r.1))
}

fn capitalized_first(s: &str) -> String {
    let mut c = s.chars();
    c.next().map_or_else(String::new, |f| f.to_uppercase().chain(c).collect())
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_time::local_time::civil_at_offset;

    fn civil() -> Civil {
        // 2027-01-15 08:00:00 UTC at +2 h
        civil_at_offset(Timestamp::from_unix_seconds(1_800_000_000.0 + 5.0 * 3600.0 + 9.0), 2 * 3600)
    }

    #[test]
    fn dates_follow_zone_and_language_order() {
        let c = civil();
        assert_eq!(date_time_of(&c, "en", false), "Jan 15, 2027, 3:00 PM");
        assert_eq!(date_time_of(&c, "de", false), "15.01.2027, 15:00");
        assert_eq!(date_time_of(&c, "de", true), "15.01.2027, 15:00:09");
        assert_eq!(medium_date_of(&c, "en"), "Jan 15, 2027");
        assert_eq!(medium_date_of(&c, "de"), "15.01.2027");
    }

    #[test]
    fn day_titles_name_the_weekday() {
        let c = civil(); // Friday 2027-01-15
        assert_eq!(day_title_of(&c, "en"), "Fri, Jan 15");
        assert_eq!(day_title_of(&c, "de"), "Fr., 15. Jan.");
    }

    #[test]
    fn ago_is_localized() {
        assert_eq!(ago(720, "en"), "12 min. ago");
        assert_eq!(ago(720, "de"), "vor 12 Min.");
        assert_eq!(ago(30, "de"), "vor 30 Sek.");
        assert_eq!(ago(86_400, "en"), "1 day ago");
        assert_eq!(ago(3 * 86_400, "de"), "vor 3 Tagen");
        assert_eq!(ago(-5, "en"), "0 sec. ago");
    }

    #[test]
    fn numbers_use_the_languages_separators() {
        assert_eq!(number(1234.5, 1, "en"), "1,234.5");
        assert_eq!(number(1234.5, 1, "de"), "1.234,5");
        assert_eq!(number(-0.0, 2, "de"), "0,00");
        assert_eq!(number(-1_234_567.0, 0, "de"), "-1.234.567");
    }

    #[test]
    fn language_names_come_from_the_table() {
        assert_eq!(language_name("de-DE", Some("en")), "German (Germany)");
        assert_eq!(language_name("en-GB", Some("de")), "Englisch (Vereinigtes Königreich)");
        assert_eq!(language_name("fr", Some("en")), "French");
        assert_eq!(language_name("xx-YY", Some("en")), "xx-YY");
        assert_eq!(native_language_name("de"), "Deutsch");
        assert_eq!(native_language_name("en"), "English");
        assert_eq!(native_language_name("fr"), "Français");
    }
}
