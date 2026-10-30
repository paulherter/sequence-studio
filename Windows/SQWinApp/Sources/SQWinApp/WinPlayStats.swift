import Foundation
import Synchronization

/// Per-stage playback timings for the play test (`--play-test`): decode, download (GPU copy or software conversion),
/// reduce, upload, composite and present, each as total milliseconds and a count since the last `reset`. Decode work
/// runs on detached tasks, so the numbers are summed under a lock.
final class WinPlayStats: Sendable {
    static let shared = WinPlayStats()

    enum Stage: String, CaseIterable, Sendable { case decode, download, reduce, upload, texture, grade, proxyOpen, videoLayers, key, title, layers, record, compose, position, plan, runloop, tick, ui, present }
    private struct State {
        var ms: [Stage: Double] = [:]
        var count: [Stage: Int] = [:]
        var max: [Stage: Double] = [:]
        var layers = 0, layerFrames = 0, layersMax = 0, culled = 0
        var waits = 0
        var decoders: [String: Int] = [:]
    }
    private let state = Mutex(State())

    func reset() { state.withLock { let d = $0.decoders; $0 = State(); $0.decoders = d } }

    func add(_ s: Stage, _ ms: Double, count: Int = 1) {
        state.withLock { st in
            st.ms[s, default: 0] += ms
            st.count[s, default: 0] += count
            st.max[s] = Swift.max(st.max[s] ?? 0, count > 0 ? ms / Double(count) : ms)
        }
    }

    /// Times `body` as one `stage` sample.
    func time<T>(_ s: Stage, _ body: () throws -> T) rethrows -> T {
        let t0 = DispatchTime.now().uptimeNanoseconds
        defer { add(s, Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6) }
        return try body()
    }

    /// One composited frame with `layers` media pictures drawn and `culled` left out (covered).
    func frame(layers: Int, culled: Int) {
        state.withLock { st in
            st.layers += layers; st.layerFrames += 1; st.layersMax = Swift.max(st.layersMax, layers); st.culled += culled
        }
    }

    /// A window frame while playing whose sequence frame was not ready (a decode still running).
    func waited() { state.withLock { $0.waits += 1 } }

    func decoderOpened(_ name: String) { state.withLock { $0.decoders[name, default: 0] += 1 } }

    /// "stage: mean ms (max ms, n)" lines for the play test.
    func report() -> [String] {
        state.withLock { st in
            var out = Stage.allCases.compactMap { s -> String? in
                guard let n = st.count[s], n > 0 else { return nil }
                return String(format: "%@ %.2f ms mean, %.2f max, %d", s.rawValue, st.ms[s]! / Double(n), st.max[s] ?? 0, n)
            }
            let mean = st.layerFrames > 0 ? Double(st.layers) / Double(st.layerFrames) : 0
            out.append(String(format: "media layers %.1f per frame (max %d), %d covered left out, %d window frames waited",
                              mean, st.layersMax, st.culled, st.waits))
            if !st.decoders.isEmpty {
                out.append("decoders " + st.decoders.sorted { $0.key < $1.key }.map { "\($0.value)x \($0.key)" }.joined(separator: ", "))
            }
            return out
        }
    }
}
