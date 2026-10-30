import Testing
import Foundation
import SQCore
@testable import SQPremiereImport

/// Runs only with `SQ_PRPROJ_SAMPLE=/path/to/project.prproj` (real projects never live in the repo).
/// `SQ_PRPROJ_REPORT=/path/out.txt` writes the import report there.
@Suite struct RealProjectTests {
    static let sample = ProcessInfo.processInfo.environment["SQ_PRPROJ_SAMPLE"]

    @Test(.enabled(if: sample != nil)) func importsRealProject() throws {
        let url = URL(fileURLWithPath: Self.sample!)
        let doc = try PRReader.read(url: url)
        #expect(!doc.sequences.isEmpty)
        let r = PRMapper.map(doc, name: url.deletingPathExtension().lastPathComponent)
        // Every timeline must survive a model round trip (sorted, non-overlapping clips).
        let data = try JSONEncoder().encode(r.project)
        _ = try JSONDecoder().decode(Project.self, from: data)
        var lines = ["sequences \(doc.sequences.count)"]
        for t in r.project.timelines {
            let counts = t.tracks.map { "\($0.name):\($0.clips.count)" }.joined(separator: " ")
            lines.append("\(t.id == r.project.activeTimeline ? "*" : " ") \(t.name) \(t.format.width)x\(t.format.height) \(counts)")
        }
        // Drop Shadow audit: raw items carrying the effect vs. imported clips carrying it, per sequence.
        for seq in doc.sequences {
            let items = seq.videoTracks.flatMap(\.items)
            let raw = items.filter { !$0.components("AE.ADBE Drop Shadow").isEmpty }
            guard !raw.isEmpty else { continue }
            for it in raw {
                var kind = "?"
                switch it.source { case .media: kind = "media"; case .sequence: kind = "nest"; case .graphic: kind = "graphic"; case .colorMatte: kind = "matte"; case .unknown: kind = "unknown" }
                lines.append("rawshadow \(seq.name) \(it.name) src=\(kind) texts=\(it.components("AE.ADBE Text").count) comps=\(it.components.map(\.matchName).joined(separator: ","))")
            }
            let idx = doc.sequences.firstIndex { $0.id == seq.id }!
            let tl = r.project.timelines.indices.contains(idx) && r.project.timelines[idx].name == seq.name ? r.project.timelines[idx] : nil
            let got = tl?.tracks.flatMap(\.clips).filter { $0.effects.contains { $0.kind == ClipEffect.dropShadowKind } }.count ?? -1
            lines.append("shadow \(seq.name): raw \(raw.count) imported \(got) " + raw.prefix(3).map { it in
                it.components("AE.ADBE Drop Shadow").map { c in c.params.map { "\($0.id ?? -1)=\($0.staticValue ?? "-")" }.joined(separator: ",") }.joined()
            }.joined(separator: " | "))
        }
        for t in r.project.timelines {
            for c in t.tracks.flatMap(\.clips) where c.effects.contains(where: { $0.kind == ClipEffect.dropShadowKind }) {
                let ev = c.effects(at: c.start + Time(1, 30))
                let segs = ev.segments.map { "[shadow=\($0.shadow.map { "op\($0.opacity) d\($0.dx),\($0.dy) sig\($0.sigma) col\($0.color)" } ?? "-") blur=\($0.blurAfter) filt=\($0.filter != nil)]" }
                lines.append("evalshadow \(t.name) \(c.name) kinds=\(c.effects.map(\.kind)) gen=\(c.generator != nil) \(segs.joined())")
            }
        }
        var textShadows = [String: Int]()
        for seq in doc.sequences { for it in seq.videoTracks.flatMap(\.items) {
            for t in it.components("AE.ADBE Text") {
                guard let blob = t.param(1)?.blob, let text = PRTextBlob.decode(base64: blob), let sh = text.shadow else { continue }
                textShadows["op\(sh.opacity) ang\(sh.angle) dist\(sh.distance) size\(sh.size) blur\(sh.blur) font\(text.size ?? 0) rgb\(sh.red),\(sh.green),\(sh.blue)", default: 0] += 1
            }
        } }
        for (k, v) in textShadows.sorted(by: { $0.value > $1.value }).prefix(8) { lines.append("textshadow \(v)x \(k)") }
        // Text stacks: graphic clips on different tracks that overlap in time (an upper text's shadow lands on lower texts).
        for t in r.project.timelines {
            let gens = t.tracks.enumerated().flatMap { (ti, tr) in tr.clips.filter { $0.generator != nil }.map { (ti, $0) } }
            var pairs = 0
            for (i, a) in gens.enumerated() { for b in gens[(i + 1)...] where a.0 != b.0 {
                let ae = a.1.start + a.1.duration, be = b.1.start + b.1.duration
                guard a.1.start < be, b.1.start < ae else { continue }
                pairs += 1
                if pairs <= 6 { lines.append("stack \(t.name) V\(a.0 + 1) '\(a.1.name.prefix(16))' over/under V\(b.0 + 1) '\(b.1.name.prefix(16))' at \(Double(a.1.start.value) / Double(a.1.start.timescale))") }
            } }
            if pairs > 0 { lines.append("stack \(t.name): \(pairs) overlapping text pairs") }
        }
        // Per sequence: markers, speed changes, transitions, nests (what Premiere shows in the timeline).
        for seq in doc.sequences {
            let items = (seq.videoTracks + seq.audioTracks).flatMap(\.items)
            let speeds = items.filter { $0.speed != 1 }.map { String(format: "%.2f", $0.speed) }
            let nests = items.filter { if case .sequence = $0.source { true } else { false } }.count
            let trans = seq.videoTracks.flatMap(\.transitions).map { "V " + $0.matchName } + seq.audioTracks.flatMap(\.transitions).map { "A " + $0.matchName }
            lines.append("seq \(seq.name): markers \(seq.markers.count), speed \(speeds), nests \(nests), transitions \(Dictionary(trans.map { ($0, 1) }, uniquingKeysWith: +))")
        }
        // Distinct text looks: font, size, fill, shadow, background, second-line style.
        var looks = [String: Int]()
        for seq in doc.sequences { for it in seq.videoTracks.flatMap(\.items) {
            for t in it.components("AE.ADBE Text") {
                guard let blob = t.param(1)?.blob, let x = PRTextBlob.decode(base64: blob) else { continue }
                func rgb(_ c: PRText.RGB?) -> String { c.map { "\(Int($0.red * 255)),\(Int($0.green * 255)),\(Int($0.blue * 255))" } ?? "-" }
                let line2 = x.secondLine.map { " line2=\($0.fontName ?? "-")/\(Int($0.size ?? 0))" } ?? (x.mixedStyles ? " MIXED" : "")
                let key = "\(x.fontName ?? "-") \(Int(x.size ?? 0))px fill=\(rgb(x.fill)) stroke=\(x.stroke.map { "\(rgb($0.color))/\($0.width)" } ?? "-") "
                    + "shadow=\(x.shadow.map { "op\(Int($0.opacity * 100)) d\(Int($0.distance)) a\(Int($0.angle)) s\(Int($0.size)) b\(Int($0.blur))" } ?? "-") "
                    + "bg=\(x.background.map { "\(rgb($0.color)) op\(Int($0.opacity * 100)) s\(Int($0.size))" } ?? "-") box=\(x.boxSize == nil ? "point" : "area")\(line2)"
                looks[key, default: 0] += 1
            }
        } }
        for (k, v) in looks.sorted(by: { $0.value > $1.value }) { lines.append("text \(v)x \(k)") }
        lines.append(r.report.summary)
        if let out = ProcessInfo.processInfo.environment["SQ_PRPROJ_REPORT"] {
            try lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
        }
    }
}
