#if canImport(Metal)
import Foundation
import CoreGraphics
import CoreVideo
import Metal
import os
import simd

/// Which display the monitors preview for (a view only: export never reads it). The compositor's working-linear
/// picture has Rec.709 primaries and 1.0 = reference white (100 nit). `sdr` is the long-standing path; the others change
/// the primaries and the drawable the layer presents:
/// - `sdr`: Rec.709 code values, 8 bit, CoreMedia 709 tag.
/// - `displayP3`: the same picture expressed in P3 primaries (a wide-gamut display shows it, nothing outside Rec.709 is cut).
/// - `hdr1000`: extended-range float output, highlights rolled off (hue-preserving) toward 10x reference white (1000 nit).
/// - `unToneMapped`: extended-range float output with the scene values as they are; the display clips at its headroom.
/// The two HDR views need an EDR display; on an SDR display the system clips them at white.
public enum DisplayView: String, Sendable, CaseIterable, Equatable {
    case sdr, displayP3, hdr1000, unToneMapped

    public var title: String {
        switch self {
        case .sdr: "SDR 100 nit Rec.709"
        case .displayP3: "Display P3"
        case .hdr1000: "HDR 1000 nit"
        case .unToneMapped: "Not Tone-Mapped"
        }
    }

    public var tooltip: String {
        switch self {
        case .sdr: "Standard picture as QuickTime shows it."
        case .displayP3: "Wide-gamut picture for a P3 display."
        case .hdr1000: "HDR preview with highlights rolled off at 1000 nit (needs an HDR display)."
        case .unToneMapped: "Raw scene values, no highlight roll-off; the display clips what it cannot show."
        }
    }

    /// Extended-range float drawable (HDR views).
    public var isExtendedRange: Bool { self == .hdr1000 || self == .unToneMapped }

    /// Peak of `hdr1000` in reference whites (1000 nit / 100 nit).
    public static let hdrPeak: Float = 10

    /// Shader mode index.
    var mode: Float {
        switch self { case .sdr: 0; case .displayP3: 1; case .hdr1000: 2; case .unToneMapped: 3 }
    }

    /// Primaries of the presented values.
    var gamut: Gamut { self == .sdr ? .rec709 : .displayP3 }

    /// CPU reference of the presenter shader (color part, before the transparency checkerboard): working-linear
    /// Rec.709 -> the value written to the drawable. Tests hold the GPU to it.
    public func encode(_ workingLinear: SIMD3<Float>) -> SIMD3<Float> {
        let v = Gamut.rec709.matrix(to: gamut) * workingLinear
        switch self {
        case .sdr, .displayP3:
            return TransferFunctions.bt709OETF(simd_clamp(v, SIMD3<Float>.zero, SIMD3<Float>.one))
        case .unToneMapped:
            return simd_max(v, SIMD3<Float>.zero)
        case .hdr1000:
            let c = simd_max(v, SIMD3<Float>.zero)
            let m = max(c.x, c.y, c.z)
            guard m > 0 else { return c }
            let mapped = ToneMapping().mapMax(m / Self.hdrPeak) * Self.hdrPeak
            return c * (mapped / m)
        }
    }

    // MARK: Drawable

    /// The layer tag: P3 primaries with the Rec.709 transfer for `displayP3`, extended linear P3 for the HDR views.
    var colorSpace: CGColorSpace {
        switch self {
        case .sdr: return Presenter.displayColorSpace
        case .displayP3: return Self.p3Video.space
        case .hdr1000, .unToneMapped: return CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) ?? Presenter.displayColorSpace
        }
    }

    var pixelFormat: MTLPixelFormat { isExtendedRange ? .rgba16Float : Presenter.drawablePixelFormat }

    private struct SpaceBox: @unchecked Sendable { let space: CGColorSpace }
    private static let p3Video: SpaceBox = {
        let attachments = [kCVImageBufferColorPrimariesKey: kCVImageBufferColorPrimaries_P3_D65,
                           kCVImageBufferTransferFunctionKey: kCVImageBufferTransferFunction_ITU_R_709_2,
                           kCVImageBufferYCbCrMatrixKey: kCVImageBufferYCbCrMatrix_ITU_R_709_2] as CFDictionary
        if let cs = CVImageBufferCreateColorSpaceFromAttachments(attachments)?.takeRetainedValue() { return SpaceBox(space: cs) }
        return SpaceBox(space: CGColorSpace(name: CGColorSpace.displayP3)!)
    }()

    private static let store = OSAllocatedUnfairLock(initialState: DisplayView.sdr)

    /// The monitors' shared choice (session-only; every presenter reads it on each frame).
    public static var current: DisplayView {
        get { store.withLock { $0 } }
        set { store.withLock { $0 = newValue } }
    }
}
#endif
