import SQRender
import SQUIKit

extension MonitorMenus {
    /// "View Gamma" submenu rows: the display the picture is previewed for, each with its one-line help.
    @MainActor
    public static func viewGammaItems(current: ViewGamma, set: @escaping @MainActor (ViewGamma) -> Void) -> [SQMenuItem] {
        ViewGamma.allCases.map { g in SQMenuItem(title: g.title, isChecked: g == current, help: g.tooltip, action: { set(g) }) }
    }
}

extension MonitorMenus {
    /// "Display View" submenu rows: the display kind the picture is previewed for.
    @MainActor
    public static func displayViewItems(current: DisplayView, set: @escaping @MainActor (DisplayView) -> Void) -> [SQMenuItem] {
        DisplayView.allCases.map { v in SQMenuItem(title: v.title, isChecked: v == current, help: v.tooltip, action: { set(v) }) }
    }
}
