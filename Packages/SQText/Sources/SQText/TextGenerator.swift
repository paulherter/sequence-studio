import Foundation
import Synchronization
import SQCore

public enum TextGeneratorError: Error, Equatable, CustomStringConvertible {
    case wrongKind(String)
    /// Payload written by a newer app version.
    case unsupportedPayloadVersion(found: Int, supported: Int)
    case invalidPayload(String)

    public var description: String {
        switch self {
        case let .wrongKind(k): "Not a text generator: \(k)"
        case let .unsupportedPayloadVersion(f, s): "Text payload version \(f) is newer than the supported version \(s)."
        case let .invalidPayload(why): "Invalid text payload: \(why)"
        }
    }
}

/// Bridge between a generator clip (`GeneratorRef` kind "text") and the text renderer.
public enum TextGenerator {
    public static let payloadVersion = 1

    struct Payload: Codable, Sendable {
        var template: TextTemplate
        var animations: AnimationSet?
    }

    struct EncodeKey: Hashable, Sendable { let template: TextTemplate; let animations: AnimationSet? }

    /// Encoded payloads by template and animations (ENGINE-NOTES "Animated captions"): the caption plan of every
    /// playback frame builds its refs again, and encoding is a pure function of the two. Cleared when full.
    static let encodeMemo = Mutex<[EncodeKey: Data]>([:])
    static let encodeMemoLimit = 1024

    public static func makeRef(template: TextTemplate, animations: AnimationSet?) throws -> GeneratorRef {
        // Inside a batch scope (prproj map) identical templates encode once; bytes are the same as encoding each time.
        let scope = FontResolver.scopedCache
        let key = EncodeKey(template: template, animations: animations)
        if let scope, let data = scope.payload(key) {
            return GeneratorRef(kind: GeneratorRef.text, payload: data, payloadVersion: payloadVersion)
        }
        if scope == nil, let data = encodeMemo.withLock({ $0[key] }) {
            return GeneratorRef(kind: GeneratorRef.text, payload: data, payloadVersion: payloadVersion)
        }
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        let data = try e.encode(Payload(template: template, animations: animations))
        if let scope { scope.setPayload(key, data) } else {
            encodeMemo.withLock { m in
                if m.count >= encodeMemoLimit { m.removeAll(keepingCapacity: true) }
                m[key] = data
            }
        }
        return GeneratorRef(kind: GeneratorRef.text, payload: data, payloadVersion: payloadVersion)
    }

    public static func decode(_ ref: GeneratorRef) throws -> (TextTemplate, AnimationSet?) {
        guard ref.kind == GeneratorRef.text else { throw TextGeneratorError.wrongKind(ref.kind) }
        guard ref.payloadVersion <= payloadVersion else {
            throw TextGeneratorError.unsupportedPayloadVersion(found: ref.payloadVersion, supported: payloadVersion)
        }
        guard ref.payloadVersion >= 1 else { throw TextGeneratorError.invalidPayload("version \(ref.payloadVersion)") }
        if let hit = decodeMemo.withLock({ m -> Payload? in
            guard let p = m.map[ref] else { return nil }
            m.hits &+= 1
            return p
        }) { return (hit.template, hit.animations) }
        do {
            let p = try JSONDecoder().decode(Payload.self, from: ref.payload)
            decodeMemo.withLock { m in
                if m.map.count >= decodeMemoLimit { m.map.removeAll(keepingCapacity: true) }
                m.map[ref] = p
            }
            return (p.template, p.animations)
        } catch { throw TextGeneratorError.invalidPayload(String(describing: error)) }
    }

    /// Decoded payloads by ref (PLAYBACK-PERF "Text payload decode memo"): playback decoded every text layer twice per
    /// frame (stand-in check + raster) on the render thread. Decoding is a pure function of the ref, so the value is the
    /// same; failures are not kept. Cleared when full (a project's text payloads are a few hundred).
    static let decodeMemo = Mutex<(map: [GeneratorRef: Payload], hits: Int)>(([:], 0))
    static let decodeMemoLimit = 1024
    /// Memo hits since launch (tests).
    static var decodeMemoHits: Int { decodeMemo.withLock { $0.hits } }
}
