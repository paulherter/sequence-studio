import Testing

/// Parent of every suite whose tests call Vision synchronously on the test's own thread (registration, detection,
/// segmentation, tracking). Serialized, nested suites included: Swift Testing runs tests on the cooperative pool (one
/// thread per core), and when every pool thread sits inside a blocking `VNImageRequestHandler.perform` at once, Vision's
/// own queued work is never served and the whole process stalls (2026-10-08: 10 of 10 pool threads inside Vision on a
/// 10-core Mac, 8 of them from `StabilizationTests`). One Vision test at a time keeps the pool free.
/// A new suite that calls Vision directly belongs here: `extension VisionSuites { @Suite struct ... }`.
@Suite(.serialized) enum VisionSuites {}

/// Its `writeMovie` is the shared test movie of the matte and anonymize suites.
typealias MaskTrackerTests = VisionSuites.MaskTrackerTests
