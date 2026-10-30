import Foundation

/// File sizes as text, always American ("25.9 MB", never "25,9 MB"), whatever the Mac's region is.
/// Decimal units like Finder: KB has no decimals, MB and up one.
public enum SQByteSize {
    public static func string(_ bytes: Int64) -> String {
        let units = ["KB", "MB", "GB", "TB", "PB"]
        if abs(bytes) < 1000 { return bytes == 1 ? "1 byte" : "\(bytes) bytes" }
        var v = Double(bytes) / 1000
        var i = 0
        while abs(v) >= 999.95 || (i == 0 && abs(v) >= 999.5), i < units.count - 1 { v /= 1000; i += 1 }
        let digits = i == 0 ? 0 : 1
        let text = String(format: "%.\(digits)f", v)      // String(format:) always uses a decimal point
        return "\(text) \(units[i])"
    }
}
