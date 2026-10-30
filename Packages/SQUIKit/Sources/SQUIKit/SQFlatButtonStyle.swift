import AppKit
import SwiftUI

/// Flat push button for SwiftUI (same box as SQButton: 20 high, radius 5, fill / hover / pressed, 11 pt).
public struct SQFlatButtonStyle: ButtonStyle {
    public var accent = false
    public init(accent: Bool = false) { self.accent = accent }
    public func makeBody(configuration: Configuration) -> some View {
        Hover { hovering in
            configuration.label
                .font(Theme.Typography.bodyFont)
                .foregroundStyle(Color(nsColor: Theme.Colors.label))
                .padding(.horizontal, 10)
                .frame(height: Theme.Row.control)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.control)
                    .fill(Color(nsColor: accent ? Theme.State.primaryPressed
                        : (configuration.isPressed ? Theme.State.pressed : hovering ? Theme.State.controlHover : Theme.State.controlRest))))
        }
    }
}

/// Borderless text-only button (the "link" look without the system tint).
public struct SQTextButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Typography.bodyFont)
            .foregroundStyle(Color(nsColor: configuration.isPressed ? Theme.Colors.label : Theme.Colors.label2))
    }
}

private struct Hover<Content: View>: View {
    @State private var hovering = false
    let content: (Bool) -> Content
    init(@ViewBuilder _ content: @escaping (Bool) -> Content) { self.content = content }
    var body: some View { content(hovering).onHover { hovering = $0 } }
}

