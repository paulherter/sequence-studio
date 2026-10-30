import Foundation
import CoreGraphics
import Testing
import SQDrawKit
@testable import SQInspectorUI

@MainActor @Suite struct ColorWheelSmoothTests {
    /// The wheel fades in one ring per point (not 12 bands): neighbouring rings differ by under 3 percent alpha, and the
    /// ring count stays cheap (a few thousand polygons, built once per size).
    @Test func wedgesFadeSmoothly() {
        let w = ColorGradeDraw.wedges(radius: 31)
        #expect(w.count > 1000 && w.count < 4000)
        var alphas = Set<Float>()
        for (_, c) in w { alphas.insert(c.a) }
        let sorted = alphas.sorted()
        #expect(sorted.count >= 40)
        for i in 1..<sorted.count { #expect(sorted[i] - sorted[i - 1] < 0.03) }
    }

    /// The tab pitch is the Mac's ceil(NSString.size) + 16 for each title (the strip drifted by up to 1.5 pt).
    @Test func tabWidthsAreTheMacCeil() {
        #expect(ColorGradeDraw.macTabWidths.count == ColorGradeDraw.proTabTitles.count)
        #expect(ColorGradeDraw.macTabWidths["Primaries"]?.regular == 50)
        #expect(ColorGradeDraw.macTabWidths["Qualifier"]?.regular == 45)
    }
}
