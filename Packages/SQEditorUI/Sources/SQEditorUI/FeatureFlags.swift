/// Features that are built and tested but not shown until Paul decides. One line switches each on.
public enum FeatureFlags {
    /// Clip > Audio Options > Remove Silences… (and the timeline context menu entry). Off: the command is not in any menu and
    /// `AppController.isSupported` says no; the code and its tests stay.
    public static let removeSilences = false
}
