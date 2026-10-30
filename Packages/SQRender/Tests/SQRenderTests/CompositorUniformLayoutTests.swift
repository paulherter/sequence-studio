import Testing
@testable import SQRender

/// The layer draw's uniform blocks keep the byte layout of their Slang twins on every system (the Windows build uses the
/// portable simd stand-ins in PortableSIMD.swift).
@Suite struct CompositorUniformLayoutTests {
    @Test func uniformBlocksMatchTheSlangSizes() {
        #expect(MemoryLayout<Compositor.Uniforms>.stride == 368, "CompositeU")
        #expect(MemoryLayout<Compositor.TransitionSideUniforms>.stride == 40, "TransitionSideU")
        #expect(MemoryLayout<Compositor.TransitionUniforms>.stride == 120, "TransitionU")
        #expect(MemoryLayout<Compositor.Uniforms>.offset(of: \.blend) == 148)
        #expect(MemoryLayout<Compositor.Uniforms>.offset(of: \.alphaMode) == 312)
    }
}
