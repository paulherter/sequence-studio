import Foundation

/// Display name of an animation preset id ("tiktok-pop" -> "TikTok Pop"); display only, the stored ids stay as they are.
/// Portable: the Controls model names presets with it on every platform (`TextBlockView.title` forwards here).
public enum AnimationPresetName {
    public static func title(for id: String) -> String {
        let brands = ["tiktok": "TikTok", "youtube": "YouTube"]
        return id.split(separator: "-").map { brands[$0.lowercased()] ?? ($0.prefix(1).uppercased() + $0.dropFirst()) }.joined(separator: " ")
    }
}

/// A number with a fixed count of decimals in the user's locale (graph readouts, key tool fields).
public enum ControlsNumberText {
    public static func format(_ v: Double, decimals: Int = 0) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = decimals; f.maximumFractionDigits = decimals
        return f.string(from: NSNumber(value: v)) ?? String(v)
    }
}
