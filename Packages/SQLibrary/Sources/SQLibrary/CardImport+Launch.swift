import Foundation

/// Cards already plugged in when the app starts. The Mac offers only cards that mount while it runs; the shared shell
/// also offers, once at launch, a drive that is an import source and looks like a camera card by its top folders (a
/// plain USB stick or backup disk that was there at launch stays quiet).
public enum CardAtLaunch {
    /// Top-level folders of camera cards: DCF (DCIM), Sony (PRIVATE, M4ROOT, MP_ROOT, XDROOT), AVCHD, Canon XF / Blackmagic
    /// (CLIP), Panasonic P2 (CONTENTS).
    public static let cameraFolders: Set<String> = ["DCIM", "PRIVATE", "AVCHD", "CLIP", "XDROOT", "M4ROOT", "MP_ROOT", "CONTENTS"]

    /// True when one of `names` (the drive's top-level entries) is a camera folder (case-insensitive: FAT cards).
    public static func looksLikeCameraCard(topLevel names: [String]) -> Bool {
        names.contains { cameraFolders.contains($0.uppercased()) }
    }

    /// The roots to offer at launch, in drive order: import sources whose top level looks like a camera card.
    /// `topLevel` lists a root's entries (only asked of import sources).
    public static func offers(_ present: [DriveFacts], topLevel: (String) -> [String]) -> [String] {
        present.filter { $0.isImportSource && looksLikeCameraCard(topLevel: topLevel($0.root)) }.map(\.root)
    }
}
