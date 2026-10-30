import Foundation

/// Structural equality of two JSON-like values. NSDictionary.isEqual is unreliable on Linux for Swift-boxed numbers.
func jsonEqual(_ a: Any, _ b: Any) -> Bool {
    let opts: JSONSerialization.WritingOptions = [.sortedKeys, .fragmentsAllowed]
    guard let x = try? JSONSerialization.data(withJSONObject: a, options: opts),
          let y = try? JSONSerialization.data(withJSONObject: b, options: opts) else { return false }
    return x == y
}
