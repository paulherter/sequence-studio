import Foundation
import Testing
@testable import SQCore

/// Hostile numbers (PALMIER #200, #264, #143; FILMCRAFT hostile-input class): NaN, infinities, 1e300, Int64 extremes,
/// negative and zero values reach the edit core through the agent API, files and typed fields. Each must be rejected or
/// clamped; a trap kills the whole run, so these tests only prove "no crash" plus the clamp results.
@Suite struct HostileInputTests {
    static let doubles: [Double] = [.nan, .infinity, -.infinity, 1e300, -1e300, .greatestFiniteMagnitude, 9.3e18, -9.3e18,
                                    1e17, 1e-300, 0, -0.0, -1, 100]
    static let times: [Time] = [
        Time(Int64.max, 1), Time(Int64.min, 1), Time(Int64.min + 1, 1), Time(1, Int64.max), Time(-1, Int64.max),
        Time(Int64.max, Int64.max), Time(Int64.max, Int64.max - 1), Time(Int64.min, Int64.max), Time(0, Int64.max),
        Time(-1, 1), Time(-1_000_000_007, 1), Time(Int64.max / 2, 3), Time(7, 1_000_003),
    ]

    // MARK: Time

    @Test func timeDecodeRejectsNonPositiveTimescale() {
        for json in [#"{"value":1,"timescale":0}"#, #"{"value":1,"timescale":-30}"#, #"{"value":0,"timescale":0}"#,
                     #"{"value":9223372036854775807,"timescale":-9223372036854775808}"#] {
            #expect(throws: (any Error).self) { try JSONDecoder().decode(Time.self, from: Data(json.utf8)) }
        }
    }

    @Test func timeArithmeticNeverTrapsOnExtremes() {
        let fd = Time(1001, 30000)
        for a in Self.times {
            _ = -a; _ = a.halved
            _ = a.snapped(to: fd); _ = a.ceiled(to: fd); _ = a.frameIndex(frameDuration: fd)
            for b in Self.times {
                _ = a + b; _ = a - b; _ = a < b; _ = a == b; _ = max(a, b); _ = min(a, b)
                _ = Time.scaled(a, by: b, over: Time(3, 7))
                if b.value != 0 { _ = Time.scaled(a, by: b, over: b) }   // a zero divisor is the caller's contract
                _ = a.snapped(to: b); _ = a.ceiled(to: b); _ = a.frameIndex(frameDuration: b)
            }
            for n: Int64 in [0, 1, -1, Int64.max, Int64.min, 30, 1 << 40] { _ = a * n; _ = Time.scaled(a, by: n, over: n == 0 ? 1 : n) }
        }
        _ = TimeRange(start: Time(Int64.max, 1), duration: Time(Int64.max, 1)).end
        _ = TimeRange(start: Time(Int64.max, 1), duration: Time(Int64.max, 1)).intersection(
            TimeRange(start: Time(Int64.min, 1), duration: Time(Int64.max, 1)))
    }

    // MARK: Speed

    @Test func clipSpeedFromHostilePercentClamps() {
        for p in Self.doubles {
            let s = ClipSpeed(percent: p)
            #expect(s >= .minimum && s <= .maximum, "\(p) -> \(s)")
            #expect(s.den > 0 && s.num > 0)
        }
        #expect(ClipSpeed(percent: .nan) == .normal && ClipSpeed(percent: -5) == .normal)
        #expect(ClipSpeed(percent: 1e300) == .maximum)
        #expect(ClipSpeed(percent: .infinity) == .maximum)
        #expect(ClipSpeed(percent: 1e-9) == .minimum)      // tiny but positive: the slowest, not 100 %
    }

    @Test func clipSpeedFromHostileRatiosClamps() {
        let ints: [Int64] = [0, 1, -1, Int64.max, Int64.min, Int64.max - 1, 100, 1 << 62]
        for n in ints { for d in ints {
            let s = ClipSpeed(num: n, den: d)
            #expect(s >= .minimum && s <= .maximum)
            for t in Self.times { _ = s.scale(t); _ = s.unscale(t) }
        } }
        for t in Self.times { for o in Self.times {
            let s = ClipSpeed(source: t, over: o)
            #expect(s >= .minimum && s <= .maximum)
        } }
    }

    // MARK: Edit verbs on a small timeline

    private func base() -> Timeline {
        let l = UUID()
        func c(_ kind: TrackKind, _ start: Int64, link: UUID? = nil, reversed: Bool = false) -> Clip {
            var x = Clip(name: "c", media: UUID(), kind: kind,
                         source: TimeRange(start: Time(5, 1), duration: Time(10, 1)), start: Time(start, 1), link: link,
                         mediaDuration: Time(40, 1))
            x.reversed = reversed
            return x
        }
        var v = Track(kind: .video), a = Track(kind: .audio)
        for (i, s) in [0, 10, 20].enumerated() {
            try! v.overwrite(c(.video, Int64(s), link: i == 1 ? l : nil, reversed: i == 2))
            try! a.overwrite(c(.audio, Int64(s), link: i == 1 ? l : nil))
        }
        return Timeline(name: "t", frameDuration: Time(1001, 30000), tracks: [v, a])
    }

    private func valid(_ tl: Timeline) -> Bool {
        tl.tracks.allSatisfy { t in t.isConsistent && t.clips.allSatisfy { $0.timeline.duration > .zero } }
    }

    typealias Verb = (inout Timeline, Clip.ID) throws -> Void

    @Test func everyVerbRejectsOrClampsExtremeTimes() {
        let start = base()
        let ids = start.tracks.flatMap(\.clips).map(\.id)
        let tids = start.tracks.map(\.id)
        var applied = 0, refused = 0
        for t in Self.times + [Time(-3, 1), Time(7, 1), .zero] {
            let r = TimeRange(start: t, duration: Time(5, 1))
            var verbs: [(String, Verb)] = []
            func add(_ n: String, _ v: @escaping Verb) { verbs.append((n, v)) }
                add("trim head", { tl, id in _ = try tl.trim(id, edge: .head, by: t) })
                add("trim tail", { tl, id in _ = try tl.trim(id, edge: .tail, by: t) })
                add("ripple trim head", { tl, id in _ = try tl.rippleTrim(id, edge: .head, by: t) })
                add("ripple trim tail", { tl, id in _ = try tl.rippleTrim(id, edge: .tail, by: t) })
                add("roll", { tl, id in _ = try tl.roll(id, by: t) })
                add("slip", { tl, id in _ = try tl.slip(id, by: t) })
                add("slide", { tl, id in _ = try tl.slide(id, by: t) })
                add("move", { tl, id in _ = try tl.move(id, to: t) })
                add("move insert", { tl, id in try tl.moveInsert(id, to: t) })
                add("nudge", { tl, id in _ = try tl.nudge([id], by: t) })
                add("rate stretch tail", { tl, id in _ = try tl.rateStretch(id, edge: .tail, by: t) })
                add("rate stretch head", { tl, id in _ = try tl.rateStretch(id, edge: .head, by: t) })
                add("duration", { tl, id in _ = try tl.apply(SpeedChange(duration: t), to: id) })
                add("duration ripple", { tl, id in _ = try tl.apply(SpeedChange(duration: t, ripple: true), to: id) })
                add("duration hold", { tl, id in _ = try tl.apply(SpeedChange(duration: t, holdingDuration: true), to: id) })
                add("set duration", { tl, id in _ = try tl.setDuration(id, to: t) })
                add("extend tail", { tl, id in _ = try tl.extendEdit(id, edge: .tail, to: t) })
                add("extend head", { tl, id in _ = try tl.extendEdit(id, edge: .head, to: t) })
                add("add edit", { tl, id in _ = try tl.addEdit(at: t, tracks: nil) })
                add("add edit selection", { tl, id in _ = try tl.addEdit(at: t, selection: [id]) })
                add("split edit to", { tl, id in _ = try tl.splitEdit(cut: Time(10, 1), side: .audio, to: t) })
                add("split edit cut", { tl, id in _ = try tl.splitEdit(cut: t, side: .video, to: Time(12, 1)) })
                add("J cut", { tl, id in _ = try tl.splitEditJL(.jCut, at: t) })
                add("trim to playhead", { tl, id in _ = try tl.trimToPlayhead(.tail, at: t, tracks: nil, mode: .ripple) })
                add("trim to playhead roll", { tl, id in _ = try tl.trimToPlayhead(.head, at: t, tracks: nil, mode: .ripple) })
                add("close gap", { tl, id in _ = try tl.closeGap(on: tids[0], at: t) })
                add("lift", { tl, id in try tl.lift(r, tracks: tids) })
                add("extract", { tl, id in _ = try tl.extract(TimeRange(start: t, duration: t < .zero ? .zero - t : t), tracks: tids) })
                add("frame hold", { tl, id in _ = try tl.insertFrameHold(of: id, at: t, duration: t) })
                add("paste") { tl, id in
                    guard let cb = tl.clipboard(copying: [id]) else { return }
                    _ = try tl.paste(cb, at: t, insert: false)
                    _ = try tl.paste(cb, at: t, insert: true)
                }
            for (name, edit) in verbs {
                for id in ids {
                    var tl = start
                    do { try edit(&tl, id); applied += 1 } catch is EditError { refused += 1 } catch {
                        Issue.record("\(name) \(t): non-EditError \(error)")
                    }
                    #expect(valid(tl), "\(name) by \(t) left an invalid timeline")
                }
            }
        }
        #expect(applied + refused > 1000)
    }

    @Test func setSpeedWithHostilePercentsNeverTraps() throws {
        let start = base()
        let id = start.tracks[0].clips[0].id
        for p in Self.doubles {
            var tl = start
            _ = try? tl.setSpeed(id, to: ClipSpeed(percent: p))
            #expect(valid(tl))
        }
    }

    @Test func fadeLengthsFromHostileTimesDoNotTrap() {
        var c = Clip(name: "a", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: Time(10, 1)),
                     start: .zero, mediaDuration: Time(10, 1))
        let fd = Time(1, 30)
        for t in Self.times + [Time(-5, 1), .zero] {
            c.setAudioFadeIn(t, frameDuration: fd)
            c.setAudioFadeOut(t, frameDuration: fd)
            #expect(c.audioFadeIn >= .zero && c.audioFadeOut >= .zero)
            c.setAudioFadeIn(t, frameDuration: .zero)
        }
        for d in Self.doubles { c.audioGainDB = d }
    }

    // MARK: Effect parameters (Int(Double) traps)

    @Test func hostileEffectParametersNeverTrapEvaluation() {
        var evaluated = 0
        for spec in EffectCatalog.everySpec + EffectCatalog.everyAudioSpec {
            for d in Self.doubles {
                var c = Clip(name: "c", media: UUID(), kind: ClipEffect.isAudioKind(spec.kind) ? .audio : .video,
                             source: TimeRange(start: .zero, duration: Time(10, 1)), start: .zero, mediaDuration: Time(10, 1))
                guard let id = c.addEffect(kind: spec.kind) else { continue }
                for p in spec.params {
                    c.setParameter(id, p.key, to: d)
                    guard let e = c.effects.first(where: { $0.id == id }) else { continue }
                    let v = e.scalar(p.key, atLocal: Time(1, 4))
                    #expect(v.isFinite, "\(spec.kind).\(p.key) = \(d) -> \(v)")
                    _ = p.kind.choiceIndex(for: d)
                    _ = e.flag(p.key, atLocal: Time(1, 4)); _ = e.choice(p.key, atLocal: Time(1, 4))
                }
                _ = c.effects(at: Time(1, 4))
                _ = c.audioFXSteps(atLocal: Time(1, 4))
                evaluated += 1
            }
        }
        #expect(evaluated > 200)
    }
}
