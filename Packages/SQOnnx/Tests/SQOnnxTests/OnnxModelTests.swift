import Testing
@testable import SQOnnx

@Suite struct OnnxModelTests {
    @Test func tensorKeepsItsShape() {
        let t = OnnxTensor(shape: [2, 3])
        #expect(t.data.count == 6)
    }

    @Test func aMissingRuntimeIsUnavailableNotACrash() {
        #if !os(Windows)
        #expect(throws: OnnxError.self) { try OnnxModel.loadRuntime() }
        #expect(!OnnxModel.isAvailable)
        #expect(throws: OnnxError.self) { _ = try OnnxModel(path: "/nope.onnx", directML: false) }
        #else
        #expect(throws: OnnxError.self) { try OnnxModel.loadRuntime(dll: "C:/does-not-exist/onnxruntime.dll") }
        #endif
    }
}
