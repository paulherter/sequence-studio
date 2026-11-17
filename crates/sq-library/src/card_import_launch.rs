// Swift: CardImport+Launch.swift
//! Cards already plugged in when the app starts. The Mac offers only cards that mount while it runs; the shared shell
//! also offers, once at launch, a drive that is an import source and looks like a camera card by its top folders (a
//! plain USB stick or backup disk that was there at launch stays quiet).

use crate::card_import::DriveFacts;

/// Top-level folders of camera cards: DCF (DCIM), Sony (PRIVATE, M4ROOT, MP_ROOT, XDROOT), AVCHD, Canon XF / Blackmagic
/// (CLIP), Panasonic P2 (CONTENTS).
pub const CAMERA_FOLDERS: [&str; 8] = ["DCIM", "PRIVATE", "AVCHD", "CLIP", "XDROOT", "M4ROOT", "MP_ROOT", "CONTENTS"];

/// True when one of `names` (the drive's top-level entries) is a camera folder (case-insensitive: FAT cards).
pub fn looks_like_camera_card(top_level: &[String]) -> bool {
    top_level.iter().any(|n| CAMERA_FOLDERS.contains(&n.to_uppercase().as_str()))
}

/// The roots to offer at launch, in drive order: import sources whose top level looks like a camera card.
/// `top_level` lists a root's entries (only asked of import sources).
pub fn offers(present: &[DriveFacts], top_level: impl Fn(&str) -> Vec<String>) -> Vec<String> {
    present
        .iter()
        .filter(|d| d.is_import_source() && looks_like_camera_card(&top_level(&d.root)))
        .map(|d| d.root.clone())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::card_import::{DriveBus, DriveKind};
    use std::collections::HashMap;

    #[test]
    fn only_camera_cards_that_are_import_sources_are_offered_at_launch() {
        let d = |root: &str, kind, bus, system| DriveFacts { root: root.into(), kind, bus, is_system: system };
        let drives = [
            d("C:\\", DriveKind::Fixed, DriveBus::Other, true),
            d("D:\\", DriveKind::Fixed, DriveBus::Other, false),
            d("E:\\", DriveKind::Removable, DriveBus::Other, false),
            d("F:\\", DriveKind::Fixed, DriveBus::Usb, false),
            d("G:\\", DriveKind::Fixed, DriveBus::Usb, false),
        ];
        let strings = |l: &[&str]| l.iter().map(|s| (*s).to_string()).collect::<Vec<_>>();
        let tops: HashMap<&str, Vec<String>> = HashMap::from([
            ("C:\\", strings(&["DCIM"])),
            ("D:\\", strings(&["DCIM"])),
            ("E:\\", strings(&["dcim", "MISC"])),
            ("F:\\", strings(&["Backups"])),
            ("G:\\", strings(&["PRIVATE"])),
        ]);
        assert_eq!(offers(&drives, |r| tops.get(r).cloned().unwrap_or_default()), ["E:\\", "G:\\"]);
        assert!(!looks_like_camera_card(&[]));
    }
}
