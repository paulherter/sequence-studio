import Foundation
import Synchronization
import Testing
@testable import SQMedia

// Import speed (PLAYBACK-PERF "Import speed"): media of a project are probed several at a time, results in input order.

@Test func probeAllKeepsOrderFailuresAndBoundsConcurrency() async {
    let urls = (0..<20).map { URL(fileURLWithPath: "/m/\($0).mov") }
    let state = Mutex<(now: Int, peak: Int)>((0, 0))
    let out = await MediaImporter.probeAll(urls, concurrency: 4) { url -> Int in
        state.withLock { $0.now += 1; $0.peak = max($0.peak, $0.now) }
        defer { state.withLock { $0.now -= 1 } }
        let n = Int(url.deletingPathExtension().lastPathComponent)!
        try await Task.sleep(for: .milliseconds(5 + (n * 7) % 13))
        if n % 5 == 3 { throw MediaError.unreadable }
        return n
    }
    #expect(out.count == 20)
    for (i, r) in out.enumerated() {
        switch r {
        case .success(let n): #expect(n == i && i % 5 != 3)
        case .failure: #expect(i % 5 == 3)
        }
    }
    let peak = state.withLock { $0.peak }
    #expect(peak <= 4 && peak > 1, "peak \(peak)")
}

@Test func probeAllOfNothingIsEmpty() async {
    let out = await MediaImporter.probeAll([], concurrency: 4) { _ in 1 }
    #expect(out.isEmpty)
}
