// Swift: WhisperLanguages.swift
//! The languages of the multilingual Whisper models and how a locale maps to them.

use crate::transcription_service::Locale;

/// The Whisper language codes.
const CODES: &str = "en zh de es ru ko fr ja pt tr pl ca nl ar sv it id hi fi vi he uk el ms cs ro da hu ta no th ur hr bg lt \
    la mi ml cy sk te fa lv bn sr az sl kn et mk br eu is hy ne mn bs kk sq sw gl mr pa si km sn yo so af oc ka be tg sd gu am yi lo uz fo \
    ht ps tk nn mt sa lb my bo tl mg as tt haw ln ha ba jw su";

/// The languages of the multilingual Whisper models and how a BCP-47 locale maps to them.
pub struct WhisperLanguages;

impl WhisperLanguages {
    pub(crate) fn codes() -> impl Iterator<Item = &'static str> {
        CODES.split_whitespace()
    }

    /// The Whisper language code of `locale` ("de-DE" -> "de"), `None` when the model does not know the language.
    pub fn code(locale: &Locale) -> Option<String> {
        let mut id = locale.language_code()?;
        if id == "nb" {
            id = "no".to_string();
        }
        Self::codes().any(|c| c == id).then_some(id)
    }

    /// Identifiers for the language pop-up: the six defaults of the panel keep their regions (so the list holds no
    /// duplicates of the stored choice), everything else is the bare code.
    pub fn supported() -> Vec<String> {
        let regional = |code: &str| -> Vec<String> {
            match code {
                "de" => vec!["de-DE".into()],
                "en" => vec!["en-US".into(), "en-GB".into()],
                "fr" => vec!["fr-FR".into()],
                "es" => vec!["es-ES".into()],
                "it" => vec!["it-IT".into()],
                other => vec![other.to_string()],
            }
        };
        let mut sorted: Vec<&str> = Self::codes().collect();
        sorted.sort_unstable(); // distinct strings: the order of equal elements cannot show
        sorted.into_iter().flat_map(regional).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeSet;

    #[test]
    fn region_and_script_are_dropped_and_unknown_codes_are_refused() {
        assert_eq!(WhisperLanguages::code(&Locale::new("de-DE")).as_deref(), Some("de"));
        assert_eq!(WhisperLanguages::code(&Locale::new("en_GB")).as_deref(), Some("en"));
        assert_eq!(WhisperLanguages::code(&Locale::new("zh-Hans-CN")).as_deref(), Some("zh"));
        assert_eq!(WhisperLanguages::code(&Locale::new("nb-NO")).as_deref(), Some("no"));
        assert_eq!(WhisperLanguages::code(&Locale::new("tlh")), None);
    }

    #[test]
    fn the_supported_list_keeps_the_regions_of_the_ui_defaults() {
        let list = WhisperLanguages::supported();
        for d in ["de-DE", "en-US", "en-GB", "fr-FR", "es-ES", "it-IT"] {
            assert!(list.iter().any(|x| x == d), "{d}");
        }
        assert!(!list.iter().any(|x| x == "de" || x == "en"));
        assert!(list.iter().any(|x| x == "ja"));
        assert_eq!(list.iter().collect::<BTreeSet<_>>().len(), list.len());
    }
}
