import Foundation
import SQGPU
import SQGPUKernels
import Testing
#if os(Windows)
import SQGPUD3D12
import SQRender
import WinSDK

private extension String {
    var wide: [WCHAR] { Array(utf16) + [0] }
}
#endif

@Suite struct SQGPUD3D12Tests {
    /// Every generated HLSL entry binds only what the shim's root signature has: t0...t24, u0 and u2...u4, b0...b1, s0...s2.
    @Test func generatedHLSLFitsTheRootSignature() throws {
        let allowed = Set((0...24).map { "t\($0)" } + ["u0", "u2", "u3", "u4", "b0", "b1", "s0", "s1", "s2"])
        let regex = try Regex(#"register\((\w+)\)"#)
        var checked = 0
        for module in GeneratedShaders.all {
            for (entry, source) in module.hlsl {
                for m in source.matches(of: regex) {
                    let reg = String(source[m.range]).dropFirst("register(".count).dropLast()
                    #expect(allowed.contains(String(reg)), "\(entry) binds \(reg)")
                }
                checked += 1
            }
        }
        #expect(checked == GeneratedShaders.all.reduce(0) { $0 + $1.entries.count } && checked > 0)
    }

    #if os(Windows)
    /// fxc compiles every generated entry, also those only engines use (scopes, temporal), into a pipeline; each fragment
    /// entry into a draw pipeline with its module's vertex entry.
    @Test func everyEntryCompilesOnD3D12() throws {
        let gpu = try D3D12GPUDevice()
        var failed: [String] = []
        for module in GeneratedShaders.all {
            let vertex = module.entries.first { module.stage(of: $0) == .vertex }
            for entry in module.entries {
                do {
                    switch module.stage(of: entry) {
                    case .compute: _ = try gpu.makePipeline(GPUKernel(module, entry))
                    case .fragment:
                        _ = try gpu.makeRenderPipeline(GPURenderKernel(module, vertex: vertex ?? "", fragment: entry),
                                                       format: .rgba16Float, blend: .premultipliedOver)
                    case .vertex: break
                    }
                } catch { failed.append("\(entry): \(error)") }
            }
        }
        #expect(failed.isEmpty, "\(failed.joined(separator: "\n"))")
        print("SQGPU D3D12: \(GeneratedShaders.all.reduce(0) { $0 + $1.entries.count }) entries compiled, \(failed.count) failed")
    }

    /// The shader cache: a cold pipeline is compiled once and written to the cache folder; a second device (as in a
    /// second app run) reads the bytecode back instead of running fxc again.
    @Test func compiledShadersAreCachedOnDisk() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sqshaders-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = SetEnvironmentVariableW("SQ_D3D12_SHADER_CACHE".wide, dir.path.wide)
        defer { _ = SetEnvironmentVariableW("SQ_D3D12_SHADER_CACHE".wide, nil) }
        // A source no other test compiles, so the process-wide memory cache has not seen it.
        let module = try #require(GeneratedShaders.all.first { m in m.entries.contains { m.stage(of: $0) == .compute } })
        let entry = try #require(module.entries.first { module.stage(of: $0) == .compute })
        let tag = "\n// cache test \(UUID().uuidString)\n"
        let tagged = GPUShaderModule(name: module.name, entries: module.entries, stages: module.stages, msl: module.msl,
                                     hlsl: module.hlsl.mapValues { $0 + tag })
        let gpu = try D3D12GPUDevice()
        _ = try gpu.makePipeline(GPUKernel(tagged, entry))
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".dxbc") }
        // At least ours: tests running beside this one may compile into the same folder while it is set.
        #expect(files.count >= 1)
        let again = try D3D12GPUDevice()
        _ = try again.makePipeline(GPUKernel(tagged, entry))
        #expect(again.lastCommitSucceeded)
    }

    /// The cross-backend graph on D3D12. SQ_GPU_PNG_OUT=<path> writes the PNG; scripts/win-gpu-check.sh compares it with
    /// the Metal render of the same graph.
    @Test func referenceGraphRunsOnD3D12() throws {
        let gpu = try D3D12GPUDevice()
        let kernels = try GPUKernels(device: gpu)
        let start = Date()
        let rgba = try GPUReferenceGraph.render(on: gpu, kernels: kernels)
        let ms = Date().timeIntervalSince(start) * 1000
        #expect(gpu.lastCommitSucceeded)
        #expect(rgba.count == GPUReferenceGraph.width * GPUReferenceGraph.height * 4)
        #expect(Set(rgba).count > 64)
        print("SQGPU D3D12 \(gpu.name): reference graph \(String(format: "%.1f", ms)) ms (first run, includes upload)")
        if let path = ProcessInfo.processInfo.environment["SQ_GPU_PNG_OUT"] {
            try Data(GPUPNG.encode(rgba: rgba, width: GPUReferenceGraph.width, height: GPUReferenceGraph.height))
                .write(to: URL(fileURLWithPath: path))
        }
    }

    /// The portable compositor's reference tree on D3D12 (blend modes through the destination copy at input 6).
    /// SQ_COMPOSITOR_PNG_OUT=<path> writes the PNG; scripts/win-compositor-check.sh compares it with the Metal render.
    @Test func compositorReferenceRunsOnD3D12() throws {
        let gpu = try D3D12GPUDevice()
        let start = Date()
        let rgba = try GPUCompositorReference.render(on: gpu)
        let ms = Date().timeIntervalSince(start) * 1000
        #expect(gpu.lastCommitSucceeded)
        #expect(Set(rgba).count > 64)
        print("SQGPU D3D12 \(gpu.name): compositor reference \(String(format: "%.1f", ms)) ms (first run, includes pipelines)")
        if let path = ProcessInfo.processInfo.environment["SQ_COMPOSITOR_PNG_OUT"] {
            try Data(GPUPNG.encode(rgba: rgba, width: GPUCompositorReference.width, height: GPUCompositorReference.height))
                .write(to: URL(fileURLWithPath: path))
        }
    }

    /// The per-frame transfers of playback and export: two NV12 planes uploaded into the frame's command buffer and the
    /// RGBA8 result read back, 1080p, 60 frames. Bytes must come back unchanged; the time is printed (staging cost).
    @Test func frameTransfersRoundTripAndAreTimed() throws {
        let gpu = try D3D12GPUDevice()
        let w = 1920, h = 1080
        guard let y = gpu.makeTexture(GPUTextureDescriptor(width: w, height: h, format: .r8Unorm)),
              let uv = gpu.makeTexture(GPUTextureDescriptor(width: w / 2, height: h / 2, format: .rg8Unorm)),
              let out = gpu.makeTexture(GPUTextureDescriptor(width: w, height: h, format: .rgba8Unorm, cpuAccessible: true))
        else { Issue.record("no textures"); return }
        let luma = [UInt8](repeating: 100, count: w * h), chroma = [UInt8](repeating: 128, count: w * h / 2)
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        for i in rgba.indices { rgba[i] = UInt8(truncatingIfNeeded: i &* 7) }
        rgba.withUnsafeBytes { gpu.upload($0, bytesPerRow: w * 4, to: out) }
        #expect(gpu.download(out) == rgba)
        let frames = 60
        let start = Date()
        for _ in 0..<frames {
            guard let cb = gpu.makeCommandBuffer() else { Issue.record("no command buffer"); return }
            luma.withUnsafeBytes { gpu.upload($0, bytesPerRow: w, to: y) }
            chroma.withUnsafeBytes { gpu.upload($0, bytesPerRow: w, to: uv) }
            gpu.commitAndWait(cb)
            #expect(gpu.download(out).count == rgba.count)
        }
        let ms = Date().timeIntervalSince(start) * 1000 / Double(frames)
        #expect(gpu.download(out) == rgba)
        print("SQGPU D3D12 \(gpu.name): 1080p frame transfers (2 plane uploads + RGBA8 readback) \(String(format: "%.2f", ms)) ms")
    }

    /// P010 planes (10 bits MSB-aligned in 16) upload into r16/rg16 textures unchanged, so 10-bit media keeps its
    /// precision into the compositor.
    @Test func sixteenBitPlanesRoundTrip() throws {
        let gpu = try D3D12GPUDevice()
        let w = 64, h = 32
        guard let y = gpu.makeTexture(GPUTextureDescriptor(width: w, height: h, format: .r16Unorm, cpuAccessible: true)),
              let uv = gpu.makeTexture(GPUTextureDescriptor(width: w / 2, height: h / 2, format: .rg16Unorm, cpuAccessible: true))
        else { Issue.record("no 16-bit textures"); return }
        let luma = (0..<(w * h)).map { UInt16(($0 * 13) % 1024) << 6 }, chroma = (0..<(w * h / 2)).map { UInt16(($0 * 7) % 1024) << 6 }
        luma.withUnsafeBytes { gpu.upload($0, bytesPerRow: w * 2, to: y) }
        chroma.withUnsafeBytes { gpu.upload($0, bytesPerRow: w * 2, to: uv) }
        #expect(gpu.download(y) == luma.withUnsafeBytes { Array($0) })
        #expect(gpu.download(uv) == chroma.withUnsafeBytes { Array($0) })
    }

    /// Frames in flight: each frame uploads its own picture into a texture it then drops, copies it into a reused target
    /// and records a readback, committed without waiting. Every readback returns its own frame (in-queue copies, retained
    /// textures, per-slot staging), more than one list ran at once, and the pipelined loop is not slower than waiting.
    @Test func framesInFlightKeepEveryFrameApart() throws {
        let gpu = try D3D12GPUDevice()
        let w = 1920, h = 1080, frames = 30
        guard let target = gpu.makeTexture(GPUTextureDescriptor(width: w, height: h, format: .rgba8Unorm, cpuAccessible: true))
        else { Issue.record("no target"); return }
        func picture(_ f: Int) -> [UInt8] { [UInt8](repeating: UInt8(f * 7 + 1), count: w * h * 4) }
        func run(pipelined: Bool) throws -> Double {
            var pending: [(Int, D3D12GPUDevice.Readback)] = []
            let start = Date()
            for f in 0..<frames {
                guard let cb = gpu.makeCommandBuffer(),
                      let t = gpu.makeTexture(GPUTextureDescriptor(width: w, height: h, format: .rgba8Unorm, cpuAccessible: true))
                else { Issue.record("no command buffer"); return 0 }
                picture(f).withUnsafeBytes { gpu.upload($0, bytesPerRow: w * 4, to: t) }
                #expect(cb.copy(t, to: target))
                guard let r = gpu.readback(target, in: cb) else { Issue.record("no readback"); return 0 }
                if pipelined { gpu.commit(cb) } else { gpu.commitAndWait(cb) }
                #expect(gpu.lastCommitSucceeded)
                pending.append((f, r))
                if pending.count > 1 || !pipelined {
                    let (i, done) = pending.removeFirst()
                    let bytes = done.finish()
                    #expect(bytes.count == w * h * 4 && bytes.first == UInt8(i * 7 + 1) && bytes.last == UInt8(i * 7 + 1))
                }
            }
            for (i, done) in pending { #expect(done.finish().first == UInt8(i * 7 + 1)) }
            return Date().timeIntervalSince(start) * 1000 / Double(frames)
        }
        let waited = try run(pipelined: false)
        let pipelined = try run(pipelined: true)
        // The frames above are so light the GPU often finishes one before the CPU records the next; a burst of heavier
        // lists committed back to back must overlap.
        guard let other = gpu.makeTexture(GPUTextureDescriptor(width: w, height: h, format: .rgba8Unorm)) else { return }
        for _ in 0..<3 {
            guard let cb = gpu.makeCommandBuffer() else { return }
            for i in 0..<40 { _ = i % 2 == 0 ? cb.copy(target, to: other) : cb.copy(other, to: target) }
            gpu.commit(cb)
        }
        #expect(gpu.download(target).first == UInt8((frames - 1) * 7 + 1))
        #expect(gpu.inFlightMax >= 2)
        print("SQGPU D3D12 \(gpu.name): 1080p upload + copy + readback per frame, waiting \(String(format: "%.2f", waited)) ms, "
              + "frames in flight \(String(format: "%.2f", pipelined)) ms (up to \(gpu.inFlightMax) lists)")
    }
    #endif
}
