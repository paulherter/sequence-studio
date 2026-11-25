// Swift: AboutContent.swift
//! What the About window says besides the version: the one-line description, the credits and the Acknowledgments list
//! (windows plan section 3). Pure data, so tests can check it and the window only lays it out.

pub const TAGLINE: &str =
    "A fast, uncluttered video editor for macOS, Windows and Linux. Free software, made in the open.";
pub const LICENSE: &str = "GNU General Public License 3.0";
pub const CREDITS: &str = "Made by Paul Herter and contributors.\n© 2026 Paul Herter. Comes with no warranty.";
pub const LICENSE_NOTE: &str =
    "Sequence Studio is free software under the GNU General Public License 3.0. The complete source code is on GitHub.";

/// One third-party entry of the Acknowledgments list.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Acknowledgment {
    pub name: &'static str,
    pub version: &'static str,
    pub license: &'static str,
    pub used_for: &'static str,
}

const fn ack(
    name: &'static str,
    version: &'static str,
    license: &'static str,
    used_for: &'static str,
) -> Acknowledgment {
    Acknowledgment { name, version, license, used_for }
}

/// Fonts, icons and libraries we build on (summary of docs/THIRD_PARTY.md).
pub const ACKNOWLEDGMENTS: [Acknowledgment; 11] = [
    ack("FFmpeg", "shared libraries", "LGPL-3.0-or-later", "Reading and writing video and audio"),
    ack("ONNX Runtime", "1.24", "MIT", "Runs the subject mask, speech and translation models"),
    ack("Inter", "4.x", "SIL OFL 1.1", "Interface and title font"),
    ack("Google Fonts selection", "25 families", "SIL OFL 1.1", "Title fonts"),
    ack("Lucide", "1.65.0", "ISC", "Icons"),
    ack("RNNoise", "0.1.1", "BSD-3-Clause", "Voice cleanup"),
    ack(
        "Gyroflow core",
        "gyroflow_core, telemetry-parser, rs-sync, mp4parse",
        "GPL-3.0 compatible",
        "Stabilization and lens profiles",
    ),
    ack(
        "tiny-skia and Rust crates",
        "see the notices file",
        "MIT / Apache-2.0 / BSD / Zlib",
        "Lottie rendering and the rest of the app",
    ),
    ack("EdgeTAM", "model by Meta", "Apache-2.0", "Subject masks"),
    ack("Whisper", "models by OpenAI, ONNX export by Xenova", "MIT", "Speech recognition"),
    ack("OPUS-MT", "Helsinki-NLP, ONNX export by Xenova", "CC-BY-4.0", "Caption translation"),
];

/// The link buttons.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Link {
    Github,
    Support,
    Discord,
}

impl Link {
    /// Button title.
    pub fn title(self) -> &'static str {
        match self {
            Link::Github => "GitHub",
            Link::Support => "Support",
            Link::Discord => "Discord",
        }
    }
}

/// The link buttons in order. Discord only when an invite exists; there is no website entry (no website yet).
pub fn links(discord: Option<&str>) -> Vec<Link> {
    if discord.is_none() { vec![Link::Github, Link::Support] } else { vec![Link::Github, Link::Support, Link::Discord] }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn discord_link_only_with_an_invite() {
        assert_eq!(links(None), vec![Link::Github, Link::Support]);
        assert_eq!(links(Some("https://discord.gg/x")).last().map(|l| l.title()), Some("Discord"));
        assert_eq!(ACKNOWLEDGMENTS.len(), 11);
    }
}
