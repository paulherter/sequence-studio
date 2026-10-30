import Foundation

/// Resolves a `TextStyle` (font name + weight) to a concrete platform font (Core Text on macOS, a `PortableFont` elsewhere).
///
/// An explicit face name (PostScript or full name that differs from the family name, e.g. "Helvetica-Bold")
/// wins: the style's weight is ignored. Only a bare family name ("Helvetica", ".AppleSystemUIFont") lets
/// `weight` pick the face. Unknown names fall back to Core Text's substitute and are treated as family names.
/// Order (family mode): variable-font weight axis / weight trait first, then the nearest available face of the family.
public enum FontResolver {
    /// Core Text weight trait (`kCTFontWeightTrait`, about -1...1) for a `FontWeight`.
    public static func traitValue(for weight: FontWeight) -> Double {
        switch weight {
        case .thin: -0.6
        case .light: -0.4
        case .regular: 0
        case .medium: 0.23
        case .semibold: 0.3
        case .bold: 0.4
        case .heavy: 0.56
        case .black: 0.62
        }
    }

    /// Weight trait of the font the style resolves to.
    public static func resolvedWeightTrait(for style: TextStyle) -> Double {
        weightTrait(of: font(for: style))
    }

    public static func font(for style: TextStyle) -> PlatformFont {
        // Inside a batch scope the scope's own table is used; everywhere else the process-wide memo.
        if scopedCache != nil { return resolveFont(for: style) }
        return memo.font(.init(name: style.fontName, size: style.size, weight: style.weight, italic: style.italic,
                          axes: style.fontAxes)) {
            resolveFont(for: style)
        }
    }

    /// One variation axis of a font.
    public struct Axis: Sendable, Hashable {
        public let tag: String
        public let name: String
        public let minimum: Double
        public let maximum: Double
        public let defaultValue: Double
    }

    static func tag(of id: UInt32) -> String {
        String(decoding: [UInt8(id >> 24 & 255), UInt8(id >> 16 & 255), UInt8(id >> 8 & 255), UInt8(id & 255)], as: UTF8.self)
    }

    static func identifier(of tag: String) -> UInt32? {
        let b = Array(tag.utf8)
        guard b.count == 4 else { return nil }
        return b.reduce(0) { $0 << 8 | UInt32($1) }
    }

    /// Resolved fonts and caption fitting sizes of the whole process (ENGINE-NOTES "Animated captions"): resolving a
    /// family and weight walks the family's descriptors, and playback asked for the same few fonts on every frame.
    /// Dropped whenever the registered fonts change (`fontsChanged`), so a font installed later resolves fresh.
    final class Memo: @unchecked Sendable {
        struct Key: Hashable {
            let name: String; let size: Double; let weight: FontWeight; let italic: Bool
            var axes: [String: Double]?
        }
        struct FitKey: Hashable { let text: String; let style: TextStyle; let boxWidth: Double }
        static let limit = 512
        private let lock = NSLock()
        private var fonts: [Key: PlatformFont] = [:]
        private var fits: [FitKey: Double] = [:]
        private var generation = 0
        private var observing = false

        func font(_ key: Key, _ make: () -> PlatformFont) -> PlatformFont {
            let (hit, gen) = lookup { fonts[key] }
            if let hit { return hit }
            let f = make()
            lock.withLock {
                guard generation == gen else { return }
                if fonts.count >= Self.limit { fonts.removeAll(keepingCapacity: true) }
                fonts[key] = f
            }
            return f
        }

        func fit(_ key: FitKey, _ make: () -> Double) -> Double {
            let (hit, gen) = lookup { fits[key] }
            if let hit { return hit }
            let v = make()
            lock.withLock {
                guard generation == gen else { return }
                if fits.count >= Self.limit { fits.removeAll(keepingCapacity: true) }
                fits[key] = v
            }
            return v
        }

        /// The cached value and the generation it was read in (a value made across a font change is not kept).
        private func lookup<T>(_ read: () -> T?) -> (T?, Int) {
            lock.lock()
            let first = !observing
            observing = true
            let out = (read(), generation)
            lock.unlock()
            if first { installFontChangeObservers() }
            return out
        }

        func clear() {
            lock.withLock { fonts.removeAll(); fits.removeAll(); generation &+= 1 }
        }

        var count: Int { lock.withLock { fonts.count + fits.count } }
    }
    static let memo = Memo()

    /// The registered fonts changed (a font was installed or registered): every remembered font is resolved again.
    public static func fontsChanged() { memo.clear() }

    /// Resolved upright fonts by (name, size, weight), alive only inside `withScopedCache` (a batch such as a prproj map).
    /// Not global: fonts installed later must still resolve fresh in the editor and renderer.
    final class ScopedCache: @unchecked Sendable {
        struct Key: Hashable { let name: String; let size: Double; let weight: FontWeight }
        private let lock = NSLock()
        private var fonts: [Key: PlatformFont] = [:]
        /// The face chosen per (name, weight): a new size derives from it instead of repeating the family search.
        struct FaceKey: Hashable { let name: String; let weight: FontWeight }
        private var faces: [FaceKey: PlatformFont] = [:]
        func font(_ key: Key, _ make: () -> PlatformFont) -> PlatformFont {
            if let f = lock.withLock({ fonts[key] }) { return f }
            let f = make()
            lock.withLock { fonts[key] = f }
            return f
        }
        private var payloads: [TextGenerator.EncodeKey: Data] = [:]
        func payload(_ k: TextGenerator.EncodeKey) -> Data? { lock.withLock { payloads[k] } }
        func setPayload(_ k: TextGenerator.EncodeKey, _ d: Data) { lock.withLock { payloads[k] = d } }
        func face(_ key: FaceKey) -> PlatformFont? { lock.withLock { faces[key] } }
        func setFace(_ key: FaceKey, _ f: PlatformFont) { lock.withLock { faces[key] = f } }
    }
    @TaskLocal static var scopedCache: ScopedCache?

    /// Runs `body` with font resolution memoised: the same style resolves to the same font once. Output is identical to
    /// resolving every time (resolution depends only on name, size and weight).
    public static func withScopedCache<T>(_ body: () throws -> T) rethrows -> T {
        if scopedCache != nil { return try body() }
        return try $scopedCache.withValue(ScopedCache(), operation: body)
    }
}
