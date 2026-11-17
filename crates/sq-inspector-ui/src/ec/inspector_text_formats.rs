// Swift: InspectorTextFormats.swift
//! Display names of animation presets and fixed-decimal number text.

/// Display name of an animation preset id ("tiktok-pop" -> "TikTok Pop"); display only, the stored ids stay as they are.
/// Portable: the Controls model names presets with it on every platform (`TextBlockView.title` forwards here).
pub enum AnimationPresetName {}

impl AnimationPresetName {
    pub fn title(id: &str) -> String {
        id.split('-')
            .filter(|p| !p.is_empty())
            .map(|p| match p.to_lowercase().as_str() {
                "tiktok" => "TikTok".to_string(),
                "youtube" => "YouTube".to_string(),
                _ => {
                    let mut chars = p.chars();
                    match chars.next() {
                        Some(first) => first.to_uppercase().chain(chars).collect(),
                        None => String::new(),
                    }
                }
            })
            .collect::<Vec<_>>()
            .join(" ")
    }
}

/// A number with a fixed count of decimals (graph readouts, key tool fields).
pub enum ControlsNumberText {}

impl ControlsNumberText {
    /// Decimal style with grouping, `decimals` fraction digits, rounded half to even like `NumberFormatter`, in the
    /// interface language's separators ("1,234.5" in English, "1.234,5" in German).
    pub fn format(v: f64, decimals: usize) -> String {
        sq_uikit::local_format::number_current(v, decimals)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn preset_names_capitalize_and_keep_brands() {
        assert_eq!(AnimationPresetName::title("tiktok-pop"), "TikTok Pop");
        assert_eq!(AnimationPresetName::title("youtube-slide-in"), "YouTube Slide In");
        assert_eq!(AnimationPresetName::title("fade"), "Fade");
    }

    #[test]
    fn numbers_get_fixed_decimals_and_grouping() {
        assert_eq!(ControlsNumberText::format(12.5, 2), "12.50");
        assert_eq!(ControlsNumberText::format(1234.5, 0), "1,234");
        assert_eq!(ControlsNumberText::format(-3.0, 1), "-3.0");
        assert_eq!(ControlsNumberText::format(-0.0, 1), "0.0");
    }
}
