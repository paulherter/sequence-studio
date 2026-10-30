import Foundation
import Testing
@testable import SQCore

/// Vendor log input spaces (ARRI, RED, Blackmagic, Nikon, Fujifilm, ACES): new cases only, no ProjectFile bump.
@Suite struct VendorColorSpaceTests {
    static let vendor: [ColorSpaceID] = [.logC3WideGamut3, .logC4WideGamut4, .log3G10RedWideGamut, .bmdFilmGen5WideGamut,
                                         .nLogBT2020, .fLog2FGamutC, .acesCCTAP1]

    @Test func vendorSpacesAreLogWithOwnNames() {
        for s in Self.vendor { #expect(s.isLog && !s.isHDR && !s.displayName.isEmpty) }
        #expect(Set(Self.vendor.map(\.displayName)).count == Self.vendor.count)
    }

    @Test func vendorSpacesSurviveAClipColorRoundTrip() throws {
        for s in Self.vendor {
            let c = ClipFootageColor(source: s)
            let back = try JSONDecoder().decode(ClipFootageColor.self, from: JSONEncoder().encode(c))
            #expect(back.source == s)
        }
    }

    @Test func eachCameraResolvesToItsCurveAndBack() {
        #expect(InputColorProfile(camera: .arri, log: true).colorSpace == .logC3WideGamut3)
        #expect(InputColorProfile(camera: .arri, log: true, logVariant: .logC4WideGamut4).colorSpace == .logC4WideGamut4)
        #expect(InputColorProfile(camera: .red, log: true).colorSpace == .log3G10RedWideGamut)
        #expect(InputColorProfile(camera: .blackmagic, log: true).colorSpace == .bmdFilmGen5WideGamut)
        #expect(InputColorProfile(camera: .nikon, log: true).colorSpace == .nLogBT2020)
        #expect(InputColorProfile(camera: .fujifilm, log: true).colorSpace == .fLog2FGamutC)
        #expect(InputColorProfile(camera: .aces, log: true).colorSpace == .acesCCTAP1)
        for s in Self.vendor { #expect(InputColorProfile(describing: s).colorSpace == s) }
    }

    @Test func lutNamesHintTheVendorSpace() {
        #expect(LUTSpaceHint.expectedSpace(forFileName: "ARRI_LogC4_to_Rec709.cube") == .logC4WideGamut4)
        #expect(LUTSpaceHint.expectedSpace(forFileName: "LogC3_Rec709.cube") == .logC3WideGamut3)
        #expect(LUTSpaceHint.expectedSpace(forFileName: "FLog2_to_709.cube") == .fLog2FGamutC)
        #expect(LUTSpaceHint.expectedSpace(forFileName: "RED_Log3G10.cube") == .log3G10RedWideGamut)
    }

    @Test func existingProjectsKeepTheirFileVersion() {
        // The new spaces are not v68 content: no version bump (decision 2026-10-17).
        for s in Self.vendor { #expect(!s.needsV68) }
    }
}
