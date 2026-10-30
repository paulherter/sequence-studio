import Foundation

/// Select Next / Previous Panel: wraps around the visible panels in layout order.
public enum PanelCycle {
    public static func step(from current: PanelID?, in panels: [PanelID], forward: Bool) -> PanelID? {
        guard !panels.isEmpty else { return nil }
        guard let current, let i = panels.firstIndex(of: current) else { return forward ? panels.first : panels.last }
        let n = panels.count
        return panels[(i + (forward ? 1 : n - 1)) % n]
    }
}
