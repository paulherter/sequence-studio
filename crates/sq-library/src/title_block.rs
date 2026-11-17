// Swift: TitleBlock.swift
//! A saved title block: generator clips of a selection with their transitions and relative offsets and lanes.

use crate::favorites::LibraryStoreError;
use crate::preset_store::{PresetFileError, PresetItem, PresetKind};
use sq_core_edit::timeline_clipboard::TimelineClipboard;
use sq_core_model::TrackKind;
use sq_core_time::{EncodeContext, Id, Timestamp};

/// Why a title block payload cannot be read.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PayloadError {
    /// Written by a newer build.
    NewerVersion {
        /// The payload's version.
        found: i64,
        /// The newest version this build reads.
        supported: i64,
    },
    /// Not a title block.
    Damaged,
}

impl From<PayloadError> for PresetFileError {
    fn from(e: PayloadError) -> Self {
        match e {
            PayloadError::NewerVersion { found, supported } => {
                LibraryStoreError::NewerFormat { found, supported }.into()
            }
            PayloadError::Damaged => PresetFileError::DamagedPayload,
        }
    }
}

/// A saved title block: the generator clips of a selection (text, shapes, adjustment layers) with their element
/// transitions and relative offsets and lanes, stored as the payload of a `TitleBlock` preset. Own payload version;
/// nothing of it goes into the project file (placing it copies the clips into the sequence).
#[derive(Clone, Debug, PartialEq)]
pub struct TitleBlock {
    /// The copied clips.
    pub block: TimelineClipboard,
}

impl TitleBlock {
    /// Version of the JSON payload (`PresetItem.payload_version` for `TitleBlock` presets).
    pub const PAYLOAD_VERSION: i64 = 1;

    /// `None` when the block is empty or holds anything with media.
    pub fn new(block: TimelineClipboard) -> Option<TitleBlock> {
        let only_titles = block
            .entries
            .iter()
            .all(|e| e.clip.generator.is_some() && e.clip.sequence.is_none() && e.clip.kind == TrackKind::Video);
        (!block.is_empty() && only_titles).then_some(TitleBlock { block })
    }

    /// Reads a payload of `version`.
    pub fn from_payload(payload: &[u8], version: i64) -> Result<TitleBlock, PayloadError> {
        if version > Self::PAYLOAD_VERSION {
            return Err(PayloadError::NewerVersion { found: version, supported: Self::PAYLOAD_VERSION });
        }
        serde_json::from_slice::<TimelineClipboard>(payload).ok().and_then(TitleBlock::new).ok_or(PayloadError::Damaged)
    }

    /// The JSON bytes, keys sorted.
    pub fn payload(&self) -> Result<Vec<u8>, serde_json::Error> {
        let _plain = EncodeContext::plain();
        // A `Value` keeps its object keys sorted (the workspace does not enable `preserve_order`).
        serde_json::to_vec(&sq_core_time::json_sorted::to_value(&self.block)?)
    }

    /// The preset to store.
    pub fn preset_item(&self, name: &str, id: Id, created_at: Timestamp) -> Result<PresetItem, serde_json::Error> {
        Ok(PresetItem::new(id, PresetKind::TitleBlock, name, created_at, self.payload()?, Self::PAYLOAD_VERSION))
    }

    /// Reads a `TitleBlock` preset.
    pub fn from_preset(preset: &PresetItem) -> Result<TitleBlock, PayloadError> {
        if preset.kind != PresetKind::TitleBlock {
            return Err(PayloadError::Damaged);
        }
        Self::from_payload(&preset.payload, preset.payload_version)
    }

    /// Number of clips (for a subtitle in the Library).
    pub fn clip_count(&self) -> usize {
        self.block.entries.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::folder_scanner::test_dir::TempDir;
    use crate::preset_store::{PresetFile, PresetStore};
    use sq_core_edit::timeline_clipboard::ClipboardEntry;
    use sq_core_model::{Clip, GeneratorRef};
    use sq_core_time::{SequentialIds, Time, TimeRange};

    const NOW: Timestamp = Timestamp::from_reference_seconds(800_000_000.0);

    fn text(n: u128, offset: Time, lane: usize) -> ClipboardEntry {
        let id = Id::from_u128(n);
        let mut clip =
            Clip::new(id, "Line", id, TrackKind::Video, TimeRange::new(Time::ZERO, Time::new(3, 1)), Time::new(4, 1));
        clip.generator =
            Some(GeneratorRef { kind: "text".into(), payload: br#"{"t":1}"#.to_vec(), payload_version: 1 });
        ClipboardEntry { clip, offset, lane }
    }

    fn block() -> TitleBlock {
        let clipboard = TimelineClipboard {
            entries: vec![text(1, Time::ZERO, 1), text(2, Time::new(1, 2), 2)],
            transitions: vec![],
            picture_track_lanes: None,
        };
        TitleBlock::new(clipboard).unwrap_or_else(|| panic!("title block"))
    }

    #[test]
    fn save_store_reopen_round_trip() {
        let dir = TempDir::new();
        let block = block();
        let mut store = PresetStore::open(dir.path(), false, NOW).unwrap_or_else(|e| panic!("{e}"));
        let item = block.preset_item("My Title", Id::fixed(1), NOW).unwrap_or_else(|e| panic!("{e}"));
        assert!(store.add(item).is_ok());
        let reopened = PresetStore::open(dir.path(), false, NOW).unwrap_or_else(|e| panic!("{e}"));
        let item = reopened.presets(Some(PresetKind::TitleBlock), "").remove(0);
        assert_eq!(item.payload_version, TitleBlock::PAYLOAD_VERSION);
        let loaded = TitleBlock::from_preset(&item);
        assert_eq!(loaded.as_ref().ok(), Some(&block));
        assert_eq!(loaded.map(|b| b.clip_count()), Ok(2));
    }

    #[test]
    fn refuses_media_clips_and_empty_blocks() {
        let empty = TimelineClipboard { entries: vec![], transitions: vec![], picture_track_lanes: None };
        assert!(TitleBlock::new(empty).is_none());
        let id = Id::from_u128(9);
        let media = Clip::new(id, "m", id, TrackKind::Video, TimeRange::new(Time::ZERO, Time::new(1, 1)), Time::ZERO);
        let one = TimelineClipboard {
            entries: vec![ClipboardEntry { clip: media, offset: Time::ZERO, lane: 0 }],
            transitions: vec![],
            picture_track_lanes: None,
        };
        assert!(TitleBlock::new(one).is_none());
    }

    #[test]
    fn newer_payload_version_and_damaged_payload_are_rejected() {
        let good = block().payload().unwrap_or_default();
        assert_eq!(TitleBlock::from_payload(&good, 2), Err(PayloadError::NewerVersion { found: 2, supported: 1 }));
        assert_eq!(TitleBlock::from_payload(b"{}", 1), Err(PayloadError::Damaged));
    }

    #[test]
    fn export_import_keeps_the_payload_readable() {
        let item = block().preset_item("T", Id::fixed(2), NOW).unwrap_or_else(|e| panic!("{e}"));
        let file = PresetFile::encode(&item).unwrap_or_default();
        let imported =
            PresetFile::decode(&file, &mut SequentialIds::default(), NOW).unwrap_or_else(|e| panic!("{e:?}"));
        assert_eq!(imported.kind, PresetKind::TitleBlock);
        assert_eq!(TitleBlock::from_preset(&imported).map(|b| b.clip_count()), Ok(2));
    }
}
