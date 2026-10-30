import AppKit
import SQEditorUI
import SwiftUI

/// V1 Quiet helpers for SwiftUI windows (Start, Card import). Local to the window package; fold into Theme when its owner allows.
/// TODO: move into Theme.swift as Fonts/Metrics tokens.
enum Quiet {
    static let rowHeight: CGFloat = Theme.Row.list
    static func color(_ c: NSColor) -> Color { Color(nsColor: c) }
    static let label = color(Theme.Colors.label)
    static let label2 = color(Theme.Colors.label2)
    static let label3 = color(Theme.Colors.label3)
    static let accent = color(Theme.Colors.accent)
    static let font = Theme.Typography.bodyFont
    static let fontName = Theme.Typography.bodyStrongFont
    static let fontTitle = Theme.Typography.titleStrongFont
    static let fontMini = Theme.Typography.captionFont
}

/// Section header like the panel headers: 28 high, 11 medium, label2.
struct QuietSectionHeader<Trailing: View>: View {
    var title: String
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack {
            Text(title).font(Quiet.fontName).foregroundStyle(Quiet.label2)
            Spacer()
            trailing()
        }
        .frame(height: Theme.Row.panelHeader)
    }
}
extension QuietSectionHeader where Trailing == EmptyView {
    init(_ title: String) { self.init(title: title) { EmptyView() } }
}

/// Flat full-width row: 24 high, hover = rowHover, no system chrome.
struct QuietRowStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, Theme.Spacing.sm)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.small)
                .fill(Quiet.color(configuration.isPressed ? Theme.State.pressed : hovering ? Theme.State.rowHover : .clear)))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}
