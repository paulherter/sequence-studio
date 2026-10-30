import Foundation

/// The one source of the app version. The marketing version comes from the bundle (project.yml `MARKETING_VERSION`
/// through Info.plist), the stage from `stage`; every place that shows a version reads this (status bar, splash,
/// start window, About, feedback mail, launch log). A hard-coded version string elsewhere fails `AppVersionTests`.
public enum AppVersion {
    /// Release stage shown after the number.
    public static let stage = "Alpha"

    /// Used when the process has no bundle version (tests, command-line tools).
    static let fallbackNumber = "0.1"

    /// Marketing version, "0.1".
    public static var number: String { number(from: Bundle.main.infoDictionary) }
    /// Build number set by packaging, "1".
    public static var build: String { (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "?" }
    /// "0.1 Alpha".
    public static var display: String { display(number: number) }
    /// "Sequence Studio 0.1 Alpha".
    public static var fullName: String { "Sequence Studio " + display }
    /// "Version 0.1 Alpha (1)", the About line.
    public static var aboutLine: String { "Version \(display) (\(build))" }

    static func number(from info: [String: Any]?) -> String {
        let v = (info?["CFBundleShortVersionString"] as? String) ?? ""
        return v.isEmpty ? fallbackNumber : v
    }
    static func display(number: String) -> String { number + " " + stage }
}
