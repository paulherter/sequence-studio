import SwiftUI

/// SwiftUI host for a mascot place (the start window is SwiftUI). Renders nothing when the place is switched off.
public struct SQMascotPlaceView: View {
    public let place: SQMascotPlace
    public let side: CGFloat?
    public init(_ place: SQMascotPlace, side: CGFloat? = nil) { self.place = place; self.side = side }

    public var body: some View {
        if place.isEnabled {
            Host(place: place, side: side)
                .frame(width: side ?? place.side, height: Self.height(place, side: side))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    @MainActor private static func height(_ p: SQMascotPlace, side: CGFloat?) -> CGFloat {
        p.makeView(side: side)?.intrinsicContentSize.height ?? side ?? p.side
    }

    private struct Host: NSViewRepresentable {
        let place: SQMascotPlace
        let side: CGFloat?
        func makeNSView(context: Context) -> NSView { place.makeView(side: side) ?? NSView() }
        func updateNSView(_ nsView: NSView, context: Context) {}
    }
}
