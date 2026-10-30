import Foundation

/// Iteration counts of the long fuzz/soak tests. Default runs use the reduced count (a few seconds per test);
/// `SQ_TEST_SOAK=1` runs the full count (the maintainer's nightly/pre-release pass). Only counts change, never assertions.
/// `SQ_FUZZ_STEPS` / `SQ_FUZZ_SEED_COUNT` still override both.
enum Soak {
    static let full = ProcessInfo.processInfo.environment["SQ_TEST_SOAK"] == "1"
    static func count(quick: Int, full fullCount: Int) -> Int { full ? fullCount : quick }
}
