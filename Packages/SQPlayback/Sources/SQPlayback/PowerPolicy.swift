import Foundation
import SQCore
import SQMedia

/// `ProcessInfo.ThermalState` as a value the policy can be tested with.
public enum ThermalLevel: Int, Sendable, Comparable, CaseIterable {
    case nominal, fair, serious, critical

    #if canImport(Darwin)
    public init(_ s: ProcessInfo.ThermalState) {
        switch s {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .serious
        }
    }
    #endif

    /// `SQ_THERMAL=nominal|fair|serious|critical` forces a level (try the throttled behavior on a cool Mac); nil = none.
    public init?(environment: [String: String]) {
        guard let v = environment["SQ_THERMAL"]?.lowercased(), let l = Self.allCases.first(where: { "\($0)" == v }) else { return nil }
        self = l
    }

    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// Q-PERF2 rec 3: what the monitors and background work give up under thermal pressure or Low Power Mode. Pure.
///
/// - fair, or Low Power Mode: background jobs (AutoProxy generation) start nothing new.
/// - serious / critical: also the viewer decodes at most at half size and the playback prefetch looks half as far ahead.
///
/// Applies to the playback engines only: export never reads it (its quality is fixed; only its pace drops with the clocks).
public struct PowerPolicy: Sendable, Equatable {
    public var pausesBackgroundJobs: Bool
    /// Largest viewer decode size (.full = no cap).
    public var decodeScaleCap: DecodeScale
    public var halvesPrefetch: Bool

    public static let normal = PowerPolicy(pausesBackgroundJobs: false, decodeScaleCap: .full, halvesPrefetch: false)

    public init(pausesBackgroundJobs: Bool, decodeScaleCap: DecodeScale, halvesPrefetch: Bool) {
        self.pausesBackgroundJobs = pausesBackgroundJobs; self.decodeScaleCap = decodeScaleCap; self.halvesPrefetch = halvesPrefetch
    }

    public init(thermal: ThermalLevel, lowPower: Bool) {
        let hot = thermal >= .serious
        self.init(pausesBackgroundJobs: hot || thermal == .fair || lowPower, decodeScaleCap: hot ? .half : .full, halvesPrefetch: hot)
    }

    /// The decode size the viewer uses for the user's choice: never larger than the cap, never larger than the choice.
    public func viewerScale(_ user: DecodeScale) -> DecodeScale {
        Self.rank(user) >= Self.rank(decodeScaleCap) ? user : decodeScaleCap
    }

    /// The prefetch planner to use (lookahead halved when hot; behind and paused radius unchanged).
    func planner(_ base: PrefetchPlanner) -> PrefetchPlanner {
        guard halvesPrefetch else { return base }
        var p = base
        p.lookahead = Time(base.lookahead.value, base.lookahead.timescale * 2)
        return p
    }

    private static func rank(_ s: DecodeScale) -> Int { s == .full ? 0 : s == .half ? 1 : 2 }
}

/// Watches the thermal state and Low Power Mode and reports the resulting policy (main actor, on change only).
@MainActor public final class PowerMonitor {
    public private(set) var policy: PowerPolicy
    public private(set) var thermal: ThermalLevel
    public var onChange: ((PowerPolicy) -> Void)?
    private let forced: ThermalLevel?
    private var tokens: [any NSObjectProtocol] = []

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        forced = ThermalLevel(environment: environment)
        #if canImport(Darwin)
        let info = ProcessInfo.processInfo
        thermal = forced ?? ThermalLevel(info.thermalState)
        policy = PowerPolicy(thermal: thermal, lowPower: forced == nil && info.isLowPowerModeEnabled)
        guard forced == nil else { return }
        let nc = NotificationCenter.default
        for name in [ProcessInfo.thermalStateDidChangeNotification, Notification.Name.NSProcessInfoPowerStateDidChange] {
            tokens.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            })
        }
        #else
        // shortcut: no thermal or battery saver signal off the Mac yet (nominal, never low power); read the Windows
        // power throttling state when the Windows shell runs playback.
        thermal = forced ?? .nominal
        policy = PowerPolicy(thermal: thermal, lowPower: false)
        #endif
    }

    isolated deinit { for t in tokens { NotificationCenter.default.removeObserver(t) } }

    #if canImport(Darwin)
    private func update() {
        let info = ProcessInfo.processInfo
        thermal = ThermalLevel(info.thermalState)
        let p = PowerPolicy(thermal: thermal, lowPower: info.isLowPowerModeEnabled)
        guard p != policy else { return }
        policy = p
        onChange?(p)
    }
    #endif
}
