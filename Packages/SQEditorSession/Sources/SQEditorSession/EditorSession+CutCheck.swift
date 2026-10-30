import Foundation
import SQCore
import SQText

/// What Check Cuts found, for the stats sheet.
public struct CutCheckReport: Sendable {
    public var findings: [CutFinding]
    public var stats: EditStats
    public var platform: CutCheckPlatform
    public func count(_ k: CutFindingKind) -> Int { findings.filter { $0.kind == k }.count }

    /// The two note lines of the Check Cuts sheet (board `Dialogs`): shots and average, then the findings that exist.
    public var boardSummary: String {
        let s = stats
        let first = String(format: "%d shots \u{00B7} average shot %.1f s", s.shotCount, s.averageShotSeconds)
        func n(_ k: CutFindingKind, _ one: String, _ many: String) -> String? {
            let c = count(k); return c == 0 ? nil : "\(c) \(c == 1 ? one : many)"
        }
        let parts = [n(.jumpCut, "jump cut", "jump cuts"), n(.gap, "gap", "gaps"),
                     n(.captionOutsideSafeZone, "caption outside the safe zone", "captions outside the safe zone"),
                     n(.audioPop, "audio pop", "audio pops")].compactMap { $0 }
        return first + "\n" + (parts.isEmpty ? "No findings" : parts.joined(separator: " \u{00B7} "))
    }

    /// Plain-text summary (the sheet draws the histogram itself).
    public var summary: String {
        var lines = CutFindingKind.allCases.map { "\($0.title): \(count($0))" }
        let s = stats
        lines.append("")
        lines.append(String(format: "%d shots, %d cuts, %.1f cuts per minute", s.shotCount, s.cuts, s.cutsPerMinute))
        lines.append(String(format: "Shot length: average %.1f s, shortest %.1f s, longest %.1f s",
                            s.averageShotSeconds, s.shortestShotSeconds, s.longestShotSeconds))
        return lines.joined(separator: "\n")
    }
}

extension EditorSession {
    /// A caption's drawn box as a fraction of the frame (origin top-left).
    public static func captionBox(_ item: CaptionItem, canvas stored: SequenceFormat) -> NormRect {
        let f = stored.layoutFormat      // display canvas: the rect is in display px
        let r = CaptionMonitorHit.textRect(of: item, canvas: f)
        let w = Double(f.width), h = Double(f.height)
        return NormRect(x: (Double(r.minX) + w / 2) / w, y: (Double(r.minY) + h / 2) / h, width: Double(r.width) / w, height: Double(r.height) / h)
    }

    /// Runs the analysis against `platform`'s safe zone (mapped into the frame, so landscape sequences are checked too) and
    /// replaces the markers of the last run (one undo step; re-runs from the sheet's platform picker coalesce into it).
    /// Nil without an active sequence.
    @discardableResult
    public func runCutCheck(platform: CutCheckPlatform = .tiktok) -> CutCheckReport? {
        guard let t = activeTimeline else { return nil }
        let f = t.format
        let aspect = f.height > 0 ? Double(f.displayWidth) / Double(f.height) : 9.0 / 16
        let findings = CutCheck.analyze(t, platform: platform, frameAspect: aspect, captionBounds: { Self.captionBox($0, canvas: f) })
        _ = attempt("Check Cuts", coalescing: "cutcheck") { $0.applyCutCheck(findings) }
        return CutCheckReport(findings: findings, stats: CutCheck.stats(t), platform: platform)
    }
}
