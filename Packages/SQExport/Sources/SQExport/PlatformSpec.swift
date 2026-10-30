import Foundation

/// Delivery numbers of the social platforms as data, each with where it came from and when it was last checked, so a
/// change of a platform's rules is a data edit.
public struct PlatformSpec: Sendable, Codable, Equatable {
    public struct Entry: Sendable, Codable, Equatable, Identifiable {
        public var id: String
        public var name: String
        public var maxWidth: Int
        public var maxHeight: Int
        public var maxFrameRate: Int
        public var maxDurationSeconds: Int
        /// Length the platform usually accepts in practice (the Export sheet warns above it, never blocks); nil = none.
        public var softDurationSeconds: Int? = nil
        public var maxFileMegabytes: Int
        public var videoCodecs: [String]
        public var audioCodec: String
        public var loudnessLUFS: Double?
        public var source: String
        /// ISO date (yyyy-MM-dd) the numbers were last checked against `source`.
        public var verified: String
    }
    public var version: Int
    public var platforms: [Entry]

    public func entry(_ id: String) -> Entry? { platforms.first { $0.id == id } }

    public static func decode(_ json: Data) throws -> PlatformSpec { try JSONDecoder().decode(PlatformSpec.self, from: json) }

    /// The numbers shipped with the app: same JSON a later update can replace.
    /// shortcut: JSON is embedded as a string (no SwiftPM resource, Package.swift untouched); move to a resource when updates ship separately.
    public static let bundled: PlatformSpec = (try? decode(Data(bundledJSON.utf8))) ?? PlatformSpec(version: 0, platforms: [])

    static let bundledJSON = """
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
    """
}
