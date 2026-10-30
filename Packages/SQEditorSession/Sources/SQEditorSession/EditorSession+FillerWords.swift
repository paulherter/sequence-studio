import Foundation
import SQCore

extension EditorSession {
    /// Filler words ("um", "uh", "äh", "ähm"...) among the timed caption words of the active sequence, as ripple cuts. Reads the
    /// transcript data the captions carry; nothing is changed.
    public func fillerScan(language: String) -> FillerWords.Scan {
        activeTimeline.map { FillerWords.scan($0, language: language) } ?? FillerWords.Scan()
    }

    /// Remove Filler Words, step one: marks every filler as a proposed cut (red range markers, replacing earlier filler proposals;
    /// one undo step). The cuts are removed with Accept Proposed Cuts, which rides the Remove Silences ripple path (one undo
    /// step, all or nothing) and can be rejected one by one. Returns the scan (its count is the preview number).
    @discardableResult
    public func proposeFillerWordCuts(language: String) -> FillerWords.Scan {
        let scan = fillerScan(language: language)
        guard !scan.cuts.isEmpty else { return scan }
        proposeCuts(scan.cuts, kind: .filler)
        return scan
    }
}
