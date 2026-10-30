import Foundation
import SQCore
import SQUIKit
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Rows of the edit mode menu and the chip's texts (pure, tested). The chip shows the short label ("Fast"), menus and
/// tooltips use the full name ("Fast Cut"). Shared by the Mac chip and the drawn header bar.
public enum TimelineModeMenu {
    public static func chipLabel(_ mode: TimelineEditMode) -> String { mode == .magnetic ? "Fast" : "Normal" }
    public static func fullName(_ mode: TimelineEditMode) -> String { mode == .magnetic ? "Fast Cut" : "Normal" }
    public static func icon(_ mode: TimelineEditMode) -> SQIcon { mode == .magnetic ? .zap : .stack }
    public static func help(_ mode: TimelineEditMode) -> String {
        mode == .magnetic ? "Gaps close by themselves, attached clips follow"
                          : "Classic tracks, edits stay where you put them"
    }

    /// Normal first, Fast Cut second, a check on `current`; picking a row calls `pick`.
    @MainActor
    public static func items(current: TimelineEditMode, pick: @escaping @MainActor (TimelineEditMode) -> Void) -> [SQMenuItem] {
        [TimelineEditMode.normal, .magnetic].map { mode in
            SQMenuItem(title: fullName(mode), isChecked: mode == current, help: help(mode)) { pick(mode) }
                .withLeading(symbol: icon(mode))
        }
    }

    /// Capsule metrics: icon 14, 8 pt in from the left, 10 pt from the right, 6 pt between icon and label.
    public static let iconSize: CGFloat = 14
    public static let leftPadding: CGFloat = 8
    public static let rightPadding: CGFloat = 10
    public static let iconToLabel: CGFloat = 6
    /// Wide enough for the longer label, so the header does not shift when the mode changes.
    public static func chipWidth(labelWidth: (String) -> CGFloat) -> CGFloat {
        let label = [TimelineEditMode.normal, .magnetic].map { labelWidth(chipLabel($0)) }.max() ?? 0
        return ceil(leftPadding + iconSize + iconToLabel + label + rightPadding)
    }
}

/// One verb of the Fast Cut strip: the command it runs (same path as its key), its title, icon and help.
public struct FastCutVerb: Equatable, Sendable {
    public var command: EditorCommand
    public var title: String
    public var icon: SQIcon
    public var help: String

    /// Left to right; the order follows an edit: add, open a gap, move off and on the main track, group.
    public static let all: [FastCutVerb] = [
        FastCutVerb(command: .appendToMainTrack, title: "Append", icon: .arrowRightToLine, help: "Adds the Source clip to the end of the main track"),
        FastCutVerb(command: .insertSpacer, title: "Spacer", icon: .squareDashed, help: "Inserts an empty spacer at the playhead"),
        FastCutVerb(command: .liftOffMainTrack, title: "Lift off", icon: .arrowUpFromLine, help: "Moves the selected main-track clips above the main track"),
        FastCutVerb(command: .putOnMainTrack, title: "Put on", icon: .arrowDownToLine, help: "Moves the selected attached clips onto the main track"),
        FastCutVerb(command: .createStoryline, title: "Storyline", icon: .stack, help: "Groups the selected attached clips into one storyline"),
    ]
}

/// The timeline header bar's geometry (design v9 `.ph`), shared by the Mac `TimelineHeaderBar` and the drawn bar:
/// tabs (flexible) | edit mode capsule | timecode | Snapping, Linked selection, Add marker, Fit, from the right.
public enum TimelineHeaderLayout {
    /// v9 `.ph`: 30 high, 4 pt padding left and right, 4 pt between the controls.
    public static let height: CGFloat = 30
    /// v9 `.ibtn.sm`: 24 x 24, radius 4.
    public static let buttonWidth: CGFloat = 24
    public static let toggleHeight: CGFloat = 24
    public static let spacing: CGFloat = 4
    public static let leftPadding: CGFloat = 4
    public static let rightPadding: CGFloat = 4
    /// v9 timecode: 8 pt before the first button.
    public static let groupGap: CGFloat = 8
    /// v9 flat popup "Fit": 10 pt, label, 8 pt, 12 pt chevron, 8 pt.
    public static let fitWidth: CGFloat = 56
    /// Playhead timecode ("00:00:15:12", 11 pt) left of the buttons.
    public static let timecodeWidth: CGFloat = 72
    /// The edit mode capsule's height (`Theme.Metrics.capsule`).
    public static let capsuleHeight: CGFloat = 22

    public struct Frames: Equatable, Sendable {
        public var tabs: CGRect
        public var timecode: CGRect
        public var snap: CGRect, link: CGRect, marker: CGRect, fit: CGRect
        /// Normal | Fast Cut capsule, left of the timecode (.zero when not shown).
        public var editMode: CGRect
        public init(tabs: CGRect, timecode: CGRect, snap: CGRect, link: CGRect, marker: CGRect, fit: CGRect, editMode: CGRect) {
            self.tabs = tabs; self.timecode = timecode; self.snap = snap; self.link = link
            self.marker = marker; self.fit = fit; self.editMode = editMode
        }
    }

    /// v9 order: tabs (flexible) | timecode, Snapping, Linked selection, Add marker, Fit. The Normal | Fast Cut switch sits
    /// left of the timecode and is always there (decision 2026-10-10), so the mode shows and one click changes it.
    public static func frames(width: CGFloat, height: CGFloat = height, modeWidth: CGFloat, showsEditMode: Bool = true) -> Frames {
        let b = buttonWidth
        var x = width - rightPadding
        func place(_ w: CGFloat, _ h: CGFloat) -> CGRect {
            x -= w; defer { x -= spacing }
            return CGRect(x: x, y: ((height - h) / 2).rounded(), width: w, height: h)
        }
        let fit = place(fitWidth, toggleHeight), marker = place(b, toggleHeight)
        let link = place(b, toggleHeight), snap = place(b, toggleHeight)
        x += spacing - groupGap
        let timecode = place(timecodeWidth, height)
        x += spacing - groupGap
        let editMode = showsEditMode ? place(modeWidth, capsuleHeight) : .zero
        if showsEditMode { x += spacing - groupGap }
        let tabsRight = max(x, leftPadding)
        return Frames(tabs: CGRect(x: leftPadding, y: 0, width: tabsRight - leftPadding, height: height),
                      timecode: timecode, snap: snap, link: link, marker: marker, fit: fit, editMode: editMode)
    }
}
