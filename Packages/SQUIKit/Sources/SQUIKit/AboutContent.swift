import Foundation

/// What the About window says besides the version: the one-line description, the credits and the Acknowledgments list
/// (windows plan section 3). Pure data, so tests can check it and the window only lays it out.
public enum AboutContent {
    public static let tagline = "A fast, uncluttered video editor for the Mac. Free software, made in the open."
    public static let license = "GNU General Public License 3.0"
    public static let credits = "Made by Paul Herter and contributors.\n© 2026 Paul Herter. Comes with no warranty."
    public static let licenseNote = "Sequence Studio is free software under the GNU General Public License 3.0. The complete source code is on GitHub."

    public struct Acknowledgment: Equatable, Sendable {
        public let name: String
        public let version: String
        public let license: String
        public let usedFor: String
    }

    /// Fonts, icons and libraries we build on (summary of docs/THIRD_PARTY.md).
    public static let acknowledgments: [Acknowledgment] = [
        .init(name: "Inter", version: "4.x", license: "SIL OFL 1.1", usedFor: "Interface and title font"),
        .init(name: "Google Fonts selection", version: "25 families", license: "SIL OFL 1.1", usedFor: "Title fonts"),
        .init(name: "Lucide", version: "1.55.0", license: "ISC", usedFor: "Icons"),
        .init(name: "RNNoise", version: "0.1.1", license: "BSD-3-Clause", usedFor: "Voice cleanup"),
        .init(name: "ThorVG", version: "1.1.2", license: "MIT", usedFor: "Lottie playback (with RapidJSON, LodePNG, jpgd)"),
        .init(name: "Gyroflow core", version: "gyroflow_core, telemetry-parser, rs-sync, mp4parse", license: "GPL-3.0 compatible", usedFor: "Stabilization and lens profiles"),
        .init(name: "wgpu and Rust crates", version: "about 320 crates", license: "MIT / Apache-2.0 / BSD / Zlib", usedFor: "Used by the stabilizer"),
        .init(name: "EdgeTAM", version: "model by Meta", license: "Apache-2.0", usedFor: "Subject masks"),
    ]

    /// The link buttons in order. Discord only when an invite exists; there is no website entry (no website yet).
    public enum Link: Equatable, Sendable {
        case github, support, discord
        public var title: String {
            switch self {
            case .github: "GitHub"
            case .support: "Support"
            case .discord: "Discord"
            }
        }
    }
    public static func links(discord: URL?) -> [Link] { discord == nil ? [.github, .support] : [.github, .support, .discord] }
}
