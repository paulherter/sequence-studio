import CSQWinApp
import Foundation
import SQDrawKit
import SQGPUD3D12
import SQGPUKernels
import SQRender

/// Swift face of the D3D12 quad shim (CSQWinApp): uploads the glyph atlas when it grew, the picture when it changed,
/// and the quads every frame. Created on the compositor's `D3D12GPUDevice`, it shares that device and its queue: the
/// composited Program picture is sampled where the compositor left it (no readback, no second upload).
final class UIRenderer {
    private let gpu: OpaquePointer
    private var atlasGeneration = -1
    private var pictureGeneration = -1
    let adapter: String
    private(set) var width: Int, height: Int

    /// The picture texture shown now (kept alive while frames in flight may sample it).
    private var pictureTexture: D3D12GPUTexture?

    /// `hwnd` nil renders offscreen. With `device` the renderer runs on that device's ID3D12Device and queue.
    init(hwnd: UnsafeMutableRawPointer?, width: Int, height: Int, device: D3D12GPUDevice? = nil) throws {
        var err = [CChar](repeating: 0, count: 4096)
        // The quad shader: DrawQuads.slang's generated HLSL (the Mac draws the same module's MSL).
        let shader = GeneratedShaders.drawQuads
        let vs = shader.hlsl["quadVertex"] ?? "", ps = shader.hlsl["quadFragment"] ?? ""
        let created = device.map { d in
            sq_ui_create_shared(d.nativeDevice, d.nativeQueue, d.name, hwnd, Int32(width), Int32(height), vs, ps, &err, 4096)
        } ?? sq_ui_create(hwnd, Int32(width), Int32(height), vs, ps, &err, 4096)
        guard let g = created else {
            throw AppError("D3D12: \(String(cString: err))")
        }
        gpu = g
        adapter = String(cString: sq_ui_adapter(g))
        self.width = width; self.height = height
    }

    deinit { sq_ui_destroy(gpu) }

    func resize(_ w: Int, _ h: Int) {
        guard w > 0, h > 0, w != width || h != height else { return }
        if sq_ui_resize(gpu, Int32(w), Int32(h)) == 0 { width = w; height = h }
    }

    func setPicture(_ p: NV12Picture?, generation: Int) {
        setViewGamma(ViewGamma.current.gamma)
        guard generation != pictureGeneration else { return }
        pictureGeneration = generation
        guard let p else { pictureTexture = nil; _ = sq_ui_set_video_nv12(gpu, nil, 0, 0, 0); return }
        if let t = p.texture {
            // The compositor moved it into the shader resource state (WinCompositor.render).
            pictureTexture = t.texture
            _ = sq_ui_set_video_texture(gpu, t.resource)
            return
        }
        pictureTexture = nil
        p.bytes.withUnsafeBufferPointer {
            if p.rgba { _ = sq_ui_set_video_rgba(gpu, $0.baseAddress, Int32(p.width), Int32(p.height)) }
            else { _ = sq_ui_set_video_nv12(gpu, $0.baseAddress, Int32(p.width), Int32(p.height), p.fullRange ? 1 : 0) }
        }
    }

    /// View > View Gamma on the picture: code values to the power gamma / 2.2 (the swap chain shows them as sRGB, so
    /// Web 2.2 leaves the picture unchanged).
    func setViewGamma(_ gamma: Float) {
        guard gamma != viewGamma else { return }
        viewGamma = gamma
        _ = sq_ui_set_view_gamma(gpu, gamma / 2.2)
    }
    private var viewGamma: Float = 2.2

    /// Target pixels per frame pixel: the list is laid out at the app's draw scale, a window on a display with a smaller
    /// scale shows it reduced (the shader supersamples). 1 = unchanged.
    var viewScale: Float = 1 {
        didSet { if viewScale != oldValue { _ = sq_ui_set_view_scale(gpu, viewScale) } }
    }

    /// Uploads image slot `slot` (drawn by `DrawList.image` quads) when `generation` changed since the last upload.
    func setImage(_ slot: Int, _ img: RGBAImage, generation: Int) {
        guard (0..<DrawList.imageSlots).contains(slot), imageGenerations[slot] != generation else { return }
        imageGenerations[slot] = generation
        img.pixels.withUnsafeBufferPointer {
            _ = sq_ui_set_image(gpu, Int32(slot), $0.baseAddress, Int32(img.width), Int32(img.height))
        }
    }
    private var imageGenerations = [Int](repeating: -1, count: DrawList.imageSlots)

    /// Draws `list`; returns the picture as RGBA when `readback` is set.
    @discardableResult
    func render(_ list: DrawList, atlas: GlyphAtlas, clear: DrawColor, readback: Bool = false, vsync: Bool = true) -> RGBAImage? {
        if atlas.generation != atlasGeneration {
            atlasGeneration = atlas.generation
            atlas.pixels.withUnsafeBufferPointer { _ = sq_ui_set_atlas(gpu, $0.baseAddress, Int32(atlas.size)) }
        }
        precondition(MemoryLayout<DrawQuad>.stride == 80)
        list.quads.withUnsafeBytes { raw in
            _ = sq_ui_set_quads(gpu, raw.baseAddress?.assumingMemoryBound(to: Float.self), Int32(list.quads.count))
        }
        if readback {
            var out = [UInt8](repeating: 0, count: width * height * 4)
            let r = out.withUnsafeMutableBufferPointer { sq_ui_render(gpu, clear.r, clear.g, clear.b, $0.baseAddress, vsync ? 1 : 0) }
            return r == 0 ? RGBAImage(width: width, height: height, pixels: out) : nil
        }
        _ = sq_ui_render(gpu, clear.r, clear.g, clear.b, nil, vsync ? 1 : 0)
        return nil
    }
}
