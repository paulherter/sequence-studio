// Swift: PlatformSpec.swift

use serde::{Deserialize, Serialize};
use std::sync::OnceLock;

/// Delivery numbers of the social platforms as data, each with where it came from and when it was last checked, so a
/// change of a platform's rules is a data edit.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct PlatformSpec {
    /// Version of the data.
    pub version: i64,
    /// One entry per platform.
    pub platforms: Vec<PlatformSpecEntry>,
}

/// One platform's limits.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PlatformSpecEntry {
    /// Platform id (`tiktok`, `reels`, `shorts`).
    pub id: String,
    /// Shown name.
    pub name: String,
    /// Widest picture.
    pub max_width: i64,
    /// Tallest picture.
    pub max_height: i64,
    /// Highest frame rate.
    pub max_frame_rate: i64,
    /// Longest accepted duration.
    pub max_duration_seconds: i64,
    /// Length the platform usually accepts in practice (the Export sheet warns above it, never blocks); `None` = none.
    #[serde(default)]
    pub soft_duration_seconds: Option<i64>,
    /// Largest accepted file.
    pub max_file_megabytes: i64,
    /// Accepted video codecs.
    pub video_codecs: Vec<String>,
    /// Audio codec.
    pub audio_codec: String,
    /// Loudness the platform normalizes to.
    #[serde(rename = "loudnessLUFS", default)]
    pub loudness_lufs: Option<f64>,
    /// Where the numbers come from.
    pub source: String,
    /// ISO date (yyyy-MM-dd) the numbers were last checked against `source`.
    pub verified: String,
}

impl PlatformSpec {
    /// The entry with this id.
    pub fn entry(&self, id: &str) -> Option<&PlatformSpecEntry> {
        self.platforms.iter().find(|e| e.id == id)
    }

    /// Reads a spec from JSON.
    pub fn decode(json: &[u8]) -> Result<PlatformSpec, serde_json::Error> {
        serde_json::from_slice(json)
    }

    /// The numbers shipped with the app: same JSON a later update can replace.
    // shortcut: JSON is embedded as a string; move to a resource file when updates ship separately.
    pub fn bundled() -> &'static PlatformSpec {
        static BUNDLED: OnceLock<PlatformSpec> = OnceLock::new();
        BUNDLED.get_or_init(|| {
            PlatformSpec::decode(BUNDLED_JSON.as_bytes()).unwrap_or(PlatformSpec { version: 0, platforms: Vec::new() })
        })
    }
}

const BUNDLED_JSON: &str = r#"
{"version":1,"platforms":[
 {"id":"tiktok","name":"TikTok","maxWidth":1080,"maxHeight":1920,"maxFrameRate":60,"maxDurationSeconds":600,"softDurationSeconds":null,"maxFileMegabytes":500,
  "videoCodecs":["h264","hevc"],"audioCodec":"aac","loudnessLUFS":null,
  "source":"https://ads.tiktok.com/help/article/video-ad-specifications","verified":"2026-10-14"},
 {"id":"reels","name":"Instagram Reels","maxWidth":1080,"maxHeight":1920,"maxFrameRate":60,"maxDurationSeconds":900,"softDurationSeconds":90,"maxFileMegabytes":4000,
  "videoCodecs":["h264","hevc"],"audioCodec":"aac","loudnessLUFS":null,
  "source":"https://help.instagram.com/1038071743007909","verified":"2026-10-14"},
 {"id":"shorts","name":"YouTube Shorts","maxWidth":1080,"maxHeight":1920,"maxFrameRate":60,"maxDurationSeconds":180,"softDurationSeconds":180,"maxFileMegabytes":2000,
  "videoCodecs":["h264","hevc"],"audioCodec":"aac","loudnessLUFS":-14,
  "source":"https://support.google.com/youtube/answer/1722171","verified":"2026-10-14"}
]}
"#;
