import Foundation
import Testing
@testable import SQAnalysis
import SQCore

@Suite struct EdgeTAMOnnxTests {
    @Test func theModelSquareIsPlanarRGBInZeroToOne() {
        // Left half red, right half blue, 40 x 20.
        var rgba = [UInt8](repeating: 255, count: 40 * 20 * 4)
        for y in 0..<20 { for x in 0..<40 {
            let i = (y * 40 + x) * 4
            rgba[i] = x < 20 ? 255 : 0; rgba[i + 1] = 0; rgba[i + 2] = x < 20 ? 0 : 255
        } }
        let t = EdgeTAMOnnxModel.input(SubjectFrame(width: 40, height: 20, rgba: rgba))
        let side = SubjectTrackRules.modelSize, plane = side * side
        #expect(t.shape == [1, 3, side, side])
        let leftMiddle = (side / 2) * side + 10, rightMiddle = (side / 2) * side + side - 10
        #expect(abs(t.data[leftMiddle] - 1) < 0.01)               // R of the left half
        #expect(abs(t.data[plane + leftMiddle]) < 0.01)           // G
        #expect(abs(t.data[2 * plane + rightMiddle] - 1) < 0.01)  // B of the right half
        #expect(abs(t.data[rightMiddle]) < 0.01)
    }

    @Test func aCropTakesOnlyThatPartOfTheFrame() {
        var rgba = [UInt8](repeating: 255, count: 40 * 20 * 4)
        for y in 0..<20 { for x in 0..<40 {
            let i = (y * 40 + x) * 4
            rgba[i] = x < 20 ? 255 : 0; rgba[i + 1] = 0; rgba[i + 2] = x < 20 ? 0 : 255
        } }
        let frame = SubjectFrame(width: 40, height: 20, rgba: rgba)
        let t = EdgeTAMOnnxModel.input(frame, crop: SubjectTrackBox(x0: 0.5, y0: 0, x1: 1, y1: 1))
        let plane = SubjectTrackRules.modelSize * SubjectTrackRules.modelSize
        #expect(t.data[plane * 2 + 5000] > 0.99 && t.data[5000] < 0.01)   // all blue
    }

    @Test func modelsAreFoundByTheEnvironmentFolderOnlyWhenComplete() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sq-edgetam-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let env = ["SQ_SUBJECT_MASK_MODELS": dir.path]
        #expect(EdgeTAMOnnxLocation.find(environment: env) == nil)
        for name in EdgeTAMOnnxLocation.names { try Data().write(to: EdgeTAMOnnxLocation.file(name, in: dir)) }
        #expect(EdgeTAMOnnxLocation.find(environment: env)?.path == dir.path)
    }
}

/// Runs the real models when `SQ_SUBJECT_MASK_MODELS` points at them (the PC: ONNX Runtime + DirectML); otherwise a no-op.
@Suite struct EdgeTAMOnnxRealTests {
    @Test func aDiscFollowsTheClickAndMoves() throws {
        guard let dir = EdgeTAMOnnxLocation.find() else { return }
        let model = try EdgeTAMOnnxModel(directory: dir, directML: ProcessInfo.processInfo.environment["SQ_ONNX_CPU"] == nil)
        func frame(cx: Int) -> SubjectFrame {
            let w = 640, h = 360
            var rgba = [UInt8](repeating: 255, count: w * h * 4)
            for y in 0..<h { for x in 0..<w {
                let i = (y * w + x) * 4
                let inside = (x - cx) * (x - cx) + (y - 180) * (y - 180) < 80 * 80
                rgba[i] = inside ? 220 : 40; rgba[i + 1] = inside ? 60 : 90; rgba[i + 2] = inside ? 40 : 120
            } }
            return SubjectFrame(width: 640, height: 360, rgba: rgba)
        }
        let session = model.makeSession()
        var t0 = ContinuousClock.now
        func lap() -> Double { let d = ContinuousClock.now - t0; t0 = ContinuousClock.now; return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
        let a = try session.click(frame(cx: 200), point: Vec2(200.0 / 640, 0.5), box: nil)
        print("onnx smoke: click \(lap()) ms")
        let n = SubjectTrackRules.logitSize
        let area = a.logits.filter { $0 > 0 }.count
        print("onnx smoke: click area \(area) of \(n * n), disc should be \(Int(Double.pi * 6400 / (640 * 360) * Double(n * n)))")
        #expect(area > 500)
        for k in 1...6 {
            let r = try session.track(frame(cx: 200 + k * 20))
            try session.commit()
            print("onnx smoke: track \(k) \(lap()) ms area \(r.logits.filter { $0 > 0 }.count) score \(r.score)")
        }
        for (name, v) in model.takeTimings().sorted(by: { $0.key < $1.key }) {
            print("onnx smoke: \(name) \(v.count)x avg \(v.seconds / Double(v.count) * 1000) ms")
        }
    }
}
