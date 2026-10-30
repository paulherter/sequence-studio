import CoreVideo
import Foundation
import SQCore

// Stabilizer method Gyroflow (DECISIONS 2026-10-06): the camera's own gyro samples instead of picture analysis.
// This file holds where a file's gyro data is (probe) and the engine seam. The engine itself is GyroflowEngine.swift
// (gyroflow_core behind the `sqgyro` C shim, loaded at runtime; docs/GYROFLOW.md).

/// Where a media file's gyro samples come from.
public enum GyroDataSource: String, Sendable, Equatable, CaseIterable {
    /// GoPro GPMF metadata track (`gpmd`).
    case goPro
    /// Sony real-time metadata track (`rtmd`).
    case sony
    /// DJI metadata track (`djmd`).
    case dji
    /// Camera motion metadata track (`camm`: Insta360, some action cameras).
    case camm
    /// Gyroflow's CSV log next to the clip (`<name>.gcsv`).
    case sidecarGCSV

    public var title: String {
        switch self {
        case .goPro: "GoPro"
        case .sony: "Sony"
        case .dji: "DJI"
        case .camm: "Camera motion track"
        case .sidecarGCSV: "Gyro log (.gcsv)"
        }
    }
}

/// Finds gyro data without decoding anything: a sidecar `.gcsv`, else the metadata sample formats in the file's `moov`.
public enum GyroDataProbe {
    /// Sample-entry four-character codes of the metadata tracks that carry gyro samples.
    static let fourCCs: [(code: String, source: GyroDataSource)] = [("gpmd", .goPro), ("rtmd", .sony), ("djmd", .dji), ("camm", .camm)]
    /// A `moov` larger than this is not read (a real one is a few MB even for hour-long clips).
    static let moovLimit = 64 << 20

    public static func probe(_ url: URL) -> GyroDataSource? {
        if sidecar(for: url) != nil { return .sidecarGCSV }
        guard let moov = moovBytes(url) else { return nil }
        return source(inMoov: moov)
    }

    /// `<name>.gcsv` (or `.GCSV`) next to the clip.
    public static func sidecar(for url: URL) -> URL? {
        let base = url.deletingPathExtension()
        for ext in ["gcsv", "GCSV"] {
            let u = base.appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return nil
    }

    /// The first known gyro sample format named in the `moov` payload.
    static func source(inMoov moov: Data) -> GyroDataSource? {
        for (code, source) in fourCCs where moov.range(of: Data(code.utf8)) != nil { return source }
        return nil
    }

    /// The payload of the top-level `moov` box (ISO BMFF / QuickTime), wherever it sits in the file. nil when the file is
    /// not a box file, has no `moov`, or the `moov` is implausibly large.
    static func moovBytes(_ url: URL) -> Data? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard let end = try? fh.seekToEnd() else { return nil }
        var offset: UInt64 = 0
        while offset + 8 <= end {
            guard (try? fh.seek(toOffset: offset)) != nil, let head = try? fh.read(upToCount: 16), head.count >= 8 else { return nil }
            var size = UInt64(be32(head, 0))
            let type = String(decoding: head[head.startIndex + 4 ..< head.startIndex + 8], as: UTF8.self)
            var header: UInt64 = 8
            if size == 1 {
                guard head.count >= 16 else { return nil }
                size = be64(head, 8); header = 16
            } else if size == 0 {
                size = end - offset          // box runs to the end of the file
            }
            guard size >= header, offset + size <= end else { return nil }
            if type == "moov" {
                let length = size - header
                guard length <= UInt64(moovLimit) else { return nil }
                guard (try? fh.seek(toOffset: offset + header)) != nil else { return nil }
                return try? fh.read(upToCount: Int(length))
            }
            offset += size
        }
        return nil
    }

    private static func be32(_ d: Data, _ i: Int) -> UInt32 {
        let s = d.startIndex + i
        return UInt32(d[s]) << 24 | UInt32(d[s + 1]) << 16 | UInt32(d[s + 2]) << 8 | UInt32(d[s + 3])
    }
    private static func be64(_ d: Data, _ i: Int) -> UInt64 { UInt64(be32(d, i)) << 32 | UInt64(be32(d, i + 4)) }
}

/// Whether a gyro engine can run in this build.
public enum GyroEngineAvailability: Sendable, Equatable {
    case available
    case unavailable(String)
}

/// The seam the app renders Gyroflow Stabilizers through: open the clip's gyro data with a set of options (in the
/// background), report progress, and warp decoded frames. Playback and export call the same `warp`, so both show the
/// same picture. Every method may be called from any thread.
public protocol GyroStabilizationEngine: Sendable {
    var availability: GyroEngineAvailability { get }
    /// State of the analysis for this file and options.
    func analysisState(path: String, options: GyroflowOptions) -> GyroAnalysisState
    /// Starts the analysis in the background (no-op when it ran or runs).
    func prepare(path: String, options: GyroflowOptions)
    /// Stops a running analysis (Cancel on the Analyze row): `.idle` at once, and playback does not restart it until
    /// `prepare`.
    func cancel(path: String, options: GyroflowOptions)
    /// The stabilized picture of `frame` (a decoded frame of `path`, `timestampUS` = its time in the file), a new buffer
    /// of the same pixel format and size. nil = cannot warp (not ready, unsupported format, failed): show `frame` as is.
    /// `wait` blocks until the analysis is done (export); without it a frame before then is nil (playback).
    func warp(_ frame: CVPixelBuffer, path: String, options: GyroflowOptions, timestampUS: Int64, wait: Bool) -> CVPixelBuffer?
    /// `f` runs (on any thread) whenever an analysis finishes or fails: redraw / refresh the Analyze row.
    func addObserver(_ f: @escaping @Sendable () -> Void)
    /// The analyses running now (file, options, progress 0...1): the Jobs list shows them.
    func runningAnalyses() -> [GyroRunningAnalysis]
}

/// One Gyroflow analysis that is running.
public struct GyroRunningAnalysis: Sendable, Equatable {
    public let path: String
    public let options: GyroflowOptions
    public let progress: Double
    public init(path: String, options: GyroflowOptions, progress: Double) {
        self.path = path; self.options = options; self.progress = progress
    }
}

public extension GyroStabilizationEngine {
    func analysisState(path: String, options: GyroflowOptions) -> GyroAnalysisState { .idle }
    func prepare(path: String, options: GyroflowOptions) {}
    func cancel(path: String, options: GyroflowOptions) {}
    func warp(_ frame: CVPixelBuffer, path: String, options: GyroflowOptions, timestampUS: Int64, wait: Bool) -> CVPixelBuffer? { nil }
    func addObserver(_ f: @escaping @Sendable () -> Void) {}
    func runningAnalyses() -> [GyroRunningAnalysis] { [] }
}

/// What the render paths hold: the engine plus where a media ID's file is. Shared by playback and export.
public struct GyroFrameWarper: Sendable {
    public let engine: any GyroStabilizationEngine
    public let path: @Sendable (UUID) -> String?
    public init(engine: any GyroStabilizationEngine, path: @escaping @Sendable (UUID) -> String?) {
        self.engine = engine; self.path = path
    }

    /// The warped frame of `media` at source time `pts` (the frame's presentation time in the file), or nil (show as is).
    public func warp(_ frame: CVPixelBuffer, media: UUID, options: GyroflowOptions, pts: Time, wait: Bool) -> CVPixelBuffer? {
        guard let p = path(media) else { return nil }
        return engine.warp(frame, path: p, options: options, timestampUS: GyroflowOptions.timestampMicroseconds(pts), wait: wait)
    }
}

public enum GyroStabilization {
    public static let noGyroDataReason = "No gyro data in this file."

    /// Why Gyroflow cannot stabilize a clip of this media (nil = it can). No gyro data is said first: it is the reason
    /// the user can act on (record with gyro on, or put the camera's .gcsv next to the clip).
    public static func block(source: GyroDataSource?, engine: any GyroStabilizationEngine) -> String? {
        guard source != nil else { return noGyroDataReason }
        if case .unavailable(let why) = engine.availability { return why }
        return nil
    }
}

extension GyroStabilization {
    /// Stabilize offers Gyroflow when every clip it would run on can use it (`block` is nil for each of them). One clip
    /// without gyro data keeps the plain command, so a mixed selection never half-switches.
    public static func offersGyroflow(blocks: [String?]) -> Bool {
        !blocks.isEmpty && blocks.allSatisfy { $0 == nil }
    }
}
