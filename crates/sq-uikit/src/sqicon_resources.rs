// Swift: SQIcon+Resources.swift
//! Icon resource names. Lucide (ISC, lucide-static 1.65.0, unchanged files `lucide-<name>.svg`) plus the two brand marks and
//! `sq-textOverline` (no Lucide match, see design/redesign-abgenommen/ICON-MAP.md), docs/THIRD_PARTY.md.

use crate::sqicon::SQIcon;
use crate::sqicon_svg_table::ICON_SVGS;

impl SQIcon {
    /// File name (without .svg) in Resources/Icons.
    pub fn resource(self) -> &'static str {
        match self {
            SQIcon::TextBold => "lucide-bold",
            SQIcon::TextItalic => "lucide-italic",
            SQIcon::TextUnderline => "lucide-underline",
            SQIcon::TextStrikethrough => "lucide-strikethrough",
            SQIcon::TextOverline => "sq-textOverline",
            SQIcon::TextCaseUpper => "lucide-case-upper",
            SQIcon::TextTop => "lucide-align-start-horizontal",
            SQIcon::TextMiddle => "lucide-align-center-horizontal",
            SQIcon::TextBottom => "lucide-align-end-horizontal",
            SQIcon::TextLTR => "lucide-pilcrow-right",
            SQIcon::TextRTL => "lucide-pilcrow-left",
            SQIcon::ShadowAngle => "lucide-angle",
            SQIcon::ChevronRight => "lucide-chevron-right",
            SQIcon::ChevronDown => "lucide-chevron-down",
            SQIcon::ChevronUp => "lucide-chevron-up",
            SQIcon::ChevronLeft => "lucide-chevron-left",
            SQIcon::GoToStart => "lucide-skip-back",
            SQIcon::GoToEnd => "lucide-skip-forward",
            SQIcon::ArrowDownToLine => "lucide-arrow-down-to-line",
            SQIcon::ArrowUpToLine => "lucide-arrow-up-to-line",
            SQIcon::ArrowUpFromLine => "lucide-arrow-up-from-line",
            SQIcon::ArrowRightToLine => "lucide-arrow-right-to-line",
            SQIcon::ArrowLeftToLine => "lucide-arrow-left-to-line",
            SQIcon::StepBack => "lucide-step-back",
            SQIcon::StepForward => "lucide-step-forward",
            SQIcon::Play => "lucide-play",
            SQIcon::Pause => "lucide-pause",
            SQIcon::Stop => "lucide-square",
            SQIcon::PlayCircle => "lucide-circle-play",
            SQIcon::PlayRectangle => "lucide-monitor-play",
            SQIcon::Marker => "lucide-map-pin",
            SQIcon::MarkerOff => "lucide-map-pin-off",
            SQIcon::InsertEdit => "lucide-square-arrow-down-right",
            SQIcon::OverwriteEdit => "lucide-square-arrow-down",
            SQIcon::Camera => "lucide-camera",
            SQIcon::Heart => "lucide-heart",
            SQIcon::Discord => "brand-discord",
            SQIcon::Github => "brand-github",
            SQIcon::Mail => "lucide-mail",
            SQIcon::Code => "lucide-code",
            SQIcon::Close => "lucide-x",
            SQIcon::CloseCircle => "lucide-circle-x",
            SQIcon::CloseCircleFilled => "lucide-circle-x",
            SQIcon::Trash => "lucide-trash-2",
            SQIcon::Folder => "lucide-folder",
            SQIcon::FolderFilled => "lucide-folder",
            SQIcon::FolderAdd => "lucide-folder-plus",
            SQIcon::FolderRemove => "lucide-folder-minus",
            SQIcon::Eye => "lucide-eye",
            SQIcon::EyeOff => "lucide-eye-off",
            SQIcon::TrackLock => "lucide-lock",
            SQIcon::TrackUnlock => "lucide-lock-open",
            SQIcon::TrackSyncLock => "lucide-lock-keyhole",
            SQIcon::Link => "lucide-link",
            SQIcon::Unlink => "lucide-unlink",
            SQIcon::Plus => "lucide-plus",
            SQIcon::Minus => "lucide-minus",
            SQIcon::Ellipsis => "lucide-ellipsis",
            SQIcon::Search => "lucide-search",
            SQIcon::ZoomIn => "lucide-zoom-in",
            SQIcon::ZoomOut => "lucide-zoom-out",
            SQIcon::ZoomSparkle => "lucide-scan-search",
            SQIcon::Star => "lucide-star",
            SQIcon::StarFilled => "lucide-star",
            SQIcon::StarOff => "lucide-star-off",
            SQIcon::Grid => "lucide-layout-grid",
            SQIcon::List => "lucide-list",
            SQIcon::Grid3 => "lucide-grid-3x3",
            SQIcon::Reset => "lucide-rotate-ccw",
            SQIcon::RotateCW => "lucide-rotate-cw",
            SQIcon::Refresh => "lucide-refresh-cw",
            SQIcon::Copy => "lucide-copy",
            SQIcon::Paste => "lucide-clipboard",
            SQIcon::PasteInsert => "lucide-clipboard-paste",
            SQIcon::File => "lucide-file",
            SQIcon::Download => "lucide-download",
            SQIcon::Upload => "lucide-upload",
            SQIcon::ToolBlade => "lucide-scissors",
            SQIcon::BladeBadge => "lucide-scissors-line-dashed",
            SQIcon::Paintbrush => "lucide-paintbrush",
            SQIcon::Pencil => "lucide-pencil",
            SQIcon::Pen => "lucide-pen-tool",
            SQIcon::Draw => "lucide-pencil-line",
            SQIcon::ToolMask => "lucide-wand-sparkles",
            SQIcon::Sparkles => "lucide-sparkles",
            SQIcon::Text => "lucide-type",
            SQIcon::TextAlignLeft => "lucide-text-align-start",
            SQIcon::TextAlignCenter => "lucide-text-align-center",
            SQIcon::TextAlignRight => "lucide-text-align-end",
            SQIcon::AlignLeft => "lucide-align-start-vertical",
            SQIcon::AlignCenterH => "lucide-align-center-vertical",
            SQIcon::AlignRight => "lucide-align-end-vertical",
            SQIcon::AlignTop => "lucide-align-start-horizontal",
            SQIcon::AlignCenterV => "lucide-align-center-horizontal",
            SQIcon::AlignBottom => "lucide-align-end-horizontal",
            SQIcon::DistributeH => "lucide-align-horizontal-distribute-center",
            SQIcon::DistributeV => "lucide-align-vertical-distribute-center",
            SQIcon::ShapeRectangle => "lucide-rectangle-horizontal",
            SQIcon::ShapeEllipse => "lucide-circle",
            SQIcon::ShapeLine => "lucide-slash",
            SQIcon::ArrowRight => "lucide-arrow-right",
            SQIcon::ArrowUpRight => "lucide-arrow-up-right",
            SQIcon::ArrowDownRight => "lucide-arrow-down-right",
            SQIcon::MoveHorizontal => "lucide-move-horizontal",
            SQIcon::MoveVertical => "lucide-move-vertical",
            SQIcon::Move => "lucide-move",
            SQIcon::Maximize => "lucide-maximize-2",
            SQIcon::Minimize => "lucide-minimize-2",
            SQIcon::FlipHorizontal => "lucide-flip-horizontal",
            SQIcon::PushRight => "lucide-square-arrow-left",
            SQIcon::SlideOut => "lucide-log-out",
            SQIcon::OpenExternal => "lucide-square-arrow-out-up-right",
            SQIcon::Merge => "lucide-merge",
            SQIcon::Swap => "lucide-arrow-left-right",
            SQIcon::Flask => "lucide-flask-conical",
            SQIcon::Film => "lucide-film",
            SQIcon::Sequence => "lucide-clapperboard",
            SQIcon::Stack => "lucide-layers",
            SQIcon::Generator => "lucide-layers-2",
            SQIcon::Group => "lucide-group",
            SQIcon::Ungroup => "lucide-ungroup",
            SQIcon::Bundle => "lucide-archive",
            SQIcon::Unbundle => "lucide-package-open",
            SQIcon::Duplicate => "lucide-copy-plus",
            SQIcon::Waveform => "lucide-audio-waveform",
            SQIcon::WaveformLines => "lucide-audio-lines",
            SQIcon::Activity => "lucide-activity",
            SQIcon::Microphone => "lucide-mic",
            SQIcon::Voice => "lucide-mic-vocal",
            SQIcon::Volume => "lucide-volume-2",
            SQIcon::VolumeLow => "lucide-volume-1",
            SQIcon::VolumeOff => "lucide-volume-x",
            SQIcon::Image => "lucide-image",
            SQIcon::ImageRemove => "lucide-image-off",
            SQIcon::SlidersVertical => "lucide-sliders-vertical",
            SQIcon::SlidersHorizontal => "lucide-sliders-horizontal",
            SQIcon::ChartBars => "lucide-chart-no-axes-column",
            SQIcon::ChartLine => "lucide-chart-line",
            SQIcon::ZapOff => "lucide-zap-off",
            SQIcon::Zap => "lucide-zap",
            SQIcon::Magnet => "lucide-magnet",
            SQIcon::FoldVertical => "lucide-fold-vertical",
            SQIcon::UnfoldVertical => "lucide-unfold-vertical",
            SQIcon::Loop => "lucide-repeat",
            SQIcon::Landmark => "lucide-landmark",
            SQIcon::Drama => "lucide-drama",
            SQIcon::CircleDotted => "lucide-circle-dot-dashed",
            SQIcon::Wind => "lucide-wind",
            SQIcon::Triangle => "lucide-triangle",
            SQIcon::SunRays => "lucide-sun",
            SQIcon::CircleDashed => "lucide-circle-dashed",
            SQIcon::Contrast => "lucide-contrast",
            SQIcon::Palette => "lucide-palette",
            SQIcon::SunDim => "lucide-sun-dim",
            SQIcon::SunMedium => "lucide-sun-medium",
            SQIcon::Lightbulb => "lucide-lightbulb",
            SQIcon::Droplet => "lucide-droplet",
            SQIcon::Aperture => "lucide-aperture",
            SQIcon::CircleDot => "lucide-circle-dot",
            SQIcon::Tornado => "lucide-tornado",
            SQIcon::Waves => "lucide-waves",
            SQIcon::Checkerboard => "lucide-grid-2x2",
            SQIcon::Grain => "lucide-grip",
            SQIcon::GripHorizontal => "lucide-grip-horizontal",
            SQIcon::Moon => "lucide-moon",
            SQIcon::SquareDashed => "lucide-square-dashed",
            SQIcon::PanelBottom => "lucide-panel-bottom",
            SQIcon::Flower => "lucide-flower-2",
            SQIcon::Columns3 => "lucide-columns-3",
            SQIcon::Columns2 => "lucide-columns-2",
            SQIcon::Hexagon => "lucide-hexagon",
            SQIcon::Crop => "lucide-crop",
            SQIcon::RoundedSquare => "lucide-square-round-corner",
            SQIcon::Scan => "lucide-scan",
            SQIcon::Vibrate => "lucide-vibrate",
            SQIcon::Radio => "lucide-radio",
            SQIcon::Timer => "lucide-timer",
            SQIcon::CalendarClock => "lucide-calendar-clock",
            SQIcon::Menu => "lucide-menu",
            SQIcon::User => "lucide-user",
            SQIcon::Gauge => "lucide-gauge",
            SQIcon::Captions => "lucide-captions",
            SQIcon::Tag => "lucide-tag",
            SQIcon::Bookmark => "lucide-bookmark",
            SQIcon::BookmarkFilled => "lucide-bookmark",
            SQIcon::CheckCircle => "lucide-circle-check",
            SQIcon::CheckCircleFilled => "lucide-circle-check",
            SQIcon::AlertCircle => "lucide-circle-alert",
            SQIcon::Equal => "lucide-equal",
            SQIcon::PlusCircle => "lucide-circle-plus",
            SQIcon::MinusCircle => "lucide-circle-minus",
            SQIcon::AddRectangle => "lucide-square-plus",
            SQIcon::Warning => "lucide-triangle-alert",
            SQIcon::Clock => "lucide-clock",
            SQIcon::UploadCircle => "lucide-circle-arrow-up",
            SQIcon::StopCircle => "lucide-circle-stop",
            SQIcon::Settings => "lucide-settings",
            SQIcon::FindFolder => "lucide-folder-search",
            SQIcon::Power => "lucide-power",
            SQIcon::PowerOn => "lucide-power",
            SQIcon::PowerOff => "lucide-power-off",
            SQIcon::Unknown => "lucide-circle-question-mark",
            SQIcon::DriveOffline => "lucide-unplug",
            SQIcon::Package => "lucide-package",
            SQIcon::Diamond => "lucide-diamond",
            SQIcon::Curve => "lucide-spline",
            SQIcon::ToolHand => "lucide-hand",
            SQIcon::PointerHand => "lucide-pointer",
            SQIcon::ToolSelect => "lucide-mouse-pointer-2",
            SQIcon::MarkClip => "lucide-mouse-pointer-click",
            SQIcon::OpenInSource => "lucide-monitor-up",
            SQIcon::TimelineSelection => "lucide-rows-3",
            SQIcon::Viewfinder => "lucide-maximize",
            SQIcon::Keyboard => "lucide-keyboard",
            SQIcon::Eyedropper => "lucide-pipette",
            SQIcon::Tv => "lucide-tv",
            SQIcon::Cloud => "lucide-cloud",
            SQIcon::Check => "lucide-check",
            SQIcon::Share => "lucide-share",
            SQIcon::Home => "lucide-house",
            SQIcon::Book => "lucide-book-open",
            SQIcon::Snap => "lucide-magnet",
            SQIcon::ToolSlip => "lucide-gallery-horizontal",
            SQIcon::ToolSlide => "lucide-gallery-horizontal-end",
            SQIcon::ToolRipple => "lucide-move-horizontal",
            SQIcon::ToolRoll => "lucide-chevrons-left-right",
            SQIcon::ToolRateStretch => "lucide-fast-forward",
            SQIcon::Keyframe => "lucide-diamond",
            SQIcon::PageEdit => "lucide-file-pen",
            SQIcon::PageColor => "lucide-swatch-book",
            SQIcon::MarkIn => "sq-markIn",
            SQIcon::MarkOut => "sq-markOut",
            SQIcon::MarkInOut => "lucide-brackets",
            SQIcon::Import => "lucide-import",
            SQIcon::LoaderCircle => "lucide-loader-circle",
            SQIcon::Info => "lucide-info",
            SQIcon::Chats => "lucide-messages-square",
            SQIcon::Layout => "lucide-layout-template",
            SQIcon::DeviceMobile => "lucide-smartphone",
            SQIcon::Monitor => "lucide-monitor",
        }
    }
}

impl SQIcon {
    /// The icon's SVG text (embedded from `resources/Icons`), `None` when the file is missing.
    pub fn svg_source(self) -> Option<&'static str> {
        let name = self.resource();
        ICON_SVGS.iter().find(|(n, _)| *n == name).map(|(_, s)| *s)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_mapped_name_resolves_to_an_svg() {
        for icon in SQIcon::ALL {
            let svg =
                icon.svg_source().unwrap_or_else(|| panic!("{} has no svg {}", icon.raw_value(), icon.resource()));
            assert!(svg.contains("<svg"), "{}", icon.resource());
        }
    }

    #[test]
    fn only_lucide_the_brand_marks_and_the_overline_are_embedded() {
        for (n, _) in ICON_SVGS {
            assert!(n.starts_with("lucide-") || n.starts_with("brand-") || *n == "sq-textOverline" || *n == "sq-markIn" || *n == "sq-markOut", "{n}");
        }
        assert!(ICON_SVGS.iter().filter(|(n, _)| n.starts_with("lucide-")).count() >= 200);
    }
}

#[cfg(test)]
mod brand_tests {
    use super::*;

    #[test]
    fn github_and_discord_are_the_brand_marks() {
        assert_eq!(SQIcon::Github.resource(), "brand-github");
        assert_eq!(SQIcon::Discord.resource(), "brand-discord");
        for i in [SQIcon::Github, SQIcon::Discord] {
            assert!(i.svg_source().is_some_and(|s| s.contains("viewBox=\"0 0 24 24\"") && s.contains("<path")));
        }
    }

    /// Mark In / Mark Out are the old own drawings, never the Lucide flags (documented exception, ICON-MAP.md).
    #[test]
    fn mark_in_and_out_use_the_documented_exception_files() {
        assert_eq!(SQIcon::MarkIn.resource(), "sq-markIn");
        assert_eq!(SQIcon::MarkOut.resource(), "sq-markOut");
        assert!(!ICON_SVGS.iter().any(|(n, _)| n.contains("flag-triangle")), "the Lucide flags must not come back");
    }
}
