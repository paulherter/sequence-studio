import Accelerate
import CoreVideo
import Foundation
import SQCore
import Vision

/// One leg of a subject mask track (forward or backward from one frame) on the tracking model: what
/// `MagicMaskTracker.track` asks per frame instead of the system's segmentation. Used on the frame lane only.
///
/// First frame: the pick's single click is answered by the model (prompted with the person's box under the click,
/// else the box of what the system's segmentation picked, else no box), as long as the answer holds the click and
/// agrees with the matte the user saw; otherwise, and for every other start (a tracked or corrected frame), the model
/// is conditioned on the stored matte as it is. Later frames: tracked from the model's memory; a frame with points
/// made on it (a correction) and a stored matte conditions the model anew from that matte (one conditioning frame at
/// a time: the earlier one is replaced).
final class SubjectTrackLeg {
    enum Answer {
        case found(SubjectMatte)
        case lost
        /// Nothing to follow on the first frame.
        case nothing
    }

    /// Overlap a click's answer needs with the matte the user saw on the click frame.
    static let agreement = 0.4
    /// A person's box answer that lies inside the seen matte (a person of a group the system joins) is taken too.
    static let containment = 0.8

    private let lease: SubjectMaskEngine.Lease
    private let segmenter: any InstanceSegmenting
    private var session: (any SubjectTrackSession)?
    private var rule = SubjectLostRule()
    private var started = false
    /// Set only while a frame is with the model (a Core ML prediction), not during the system's segmentation or the
    /// search for a person's box: a hang there is not the model's.
    let inModel = SubjectModelMark()
    /// The edge step of this leg's mattes.
    let edger = SubjectMatteEdger()
    var refinesEdges: Bool {
        get { edger.refines }
        set { edger.refines = newValue }
    }
    /// See `SubjectMatteEdger.quality`. Set once before the leg's first frame and kept.
    var quality: SubjectMaskQuality {
        get { edger.quality }
        set { edger.quality = newValue }
    }
    /// The model's mattes come back without their edge step: the caller runs `edger` on them (`answerNeedsEdge`),
    /// off the lane, while the model already has the next frame. Set before the first frame and kept.
    var defersEdges = false
    /// The last `step`'s found matte still needs `edger` (only with `defersEdges`; a stored or given matte never does).
    private(set) var answerNeedsEdge = false
    /// `SQ_SUBJECT_MASK_LOG=1`: one line per tracked frame (the model's score, the mask's area, lost or not).
    static let logsFrames = ProcessInfo.processInfo.environment["SQ_SUBJECT_MASK_LOG"] == "1"
    /// The last matte of this leg with the subject on it (what the system's segmentation goes on from after a failure).
    private(set) var lastFound: SubjectMatte?
    /// The last tracked frame's model score, area and lost verdict (the benchmark's details).
    private(set) var lastDiagnostic = ""
    var recordsDiagnostics = false
    /// The box of the last accepted answer (frame fractions): the search band of the next frame grows from it.
    private var lastBox: SubjectTrackBox?
    /// Frames in a row that came back lost: the search band widens with them.
    private var lostRun = 0
    /// Which empty frames enter the model's memory (`SubjectAbsenceMemory`). `SQ_MASK_ABSENT_MEMORY=<n>` overrides the
    /// limit for the benchmark (`all`: every empty frame, as before).
    private var absence = SubjectTrackLeg.defaultAbsence
    static let defaultAbsence: SubjectAbsenceMemory = {
        let env = ProcessInfo.processInfo.environment
        guard env["SQ_MASK_BENCH"] == "1", let value = env["SQ_MASK_ABSENT_MEMORY"] else { return .tracker }   // a benchmark knob only
        if value == "all" { return SubjectAbsenceMemory() }
        return Int(value).map { SubjectAbsenceMemory(limit: $0) } ?? .tracker
    }()
    /// Which masks count as the subject found again after a gap. `SQ_MASK_REACQUIRE=<minScore>,<afterLost>,<settle>`
    /// (or `off`) overrides it for the benchmark.
    private var reacquire = SubjectTrackLeg.defaultReacquire
    static let defaultReacquire: SubjectReacquireRule = {
        let env = ProcessInfo.processInfo.environment
        guard env["SQ_MASK_BENCH"] == "1", let value = env["SQ_MASK_REACQUIRE"] else { return .tracker }   // a benchmark knob only
        if value == "off" { return .off }
        let parts = value.split(separator: ",")
        guard parts.count == 3, let score = Float(parts[0]), let after = Int(parts[1]), let settle = Int(parts[2]) else { return .tracker }
        return SubjectReacquireRule(minScore: score, afterLost: after, settle: settle)
    }()
    /// Second pass on a crop around the first answer (`SQ_SUBJECT_MASK_CROP=1` switches it on) and the search band
    /// (`SQ_SUBJECT_MASK_BAND=0` switches it off): both measured by the mask benchmark.
    // shortcut: the crop pass is off by default, it lowered mean J&F 0.896 -> 0.866 and doubled ms/frame on the 13-clip
    // bench (docs/research/mask-tracking/RESULTS-E2.md); retry when the model gets a tighter box prompt or a crop-trained head.
    static let cropPass = ProcessInfo.processInfo.environment["SQ_SUBJECT_MASK_CROP"] == "1"
    static let searchBand = ProcessInfo.processInfo.environment["SQ_SUBJECT_MASK_BAND"] != "0"

    init?(lease: SubjectMaskEngine.Lease, segmenter: any InstanceSegmenting) {
        guard let model = lease.model else { return nil }
        self.lease = lease; self.segmenter = segmenter
        session = model.makeSession()
    }

    private static func seconds(_ p: MagicPoint) -> Double { Double(p.sourceTime.value) / Double(max(p.sourceTime.timescale, 1)) }

    /// `next` is the frame this leg is asked after the current one: the model may start on it now
    /// (`SubjectTrackSession.lookAhead`). Call it before `step` of the current frame.
    func lookAhead(_ next: CVPixelBuffer) {
        guard lease.model != nil, let session else { return }
        session.lookAhead(next)
    }

    /// `stored`: the matte stored for this frame, nil when it is not tracked. Throws when the model fails or was
    /// taken away (`SubjectTrackError.released`): the caller goes on with the system's segmentation.
    func step(_ pb: CVPixelBuffer, pts: Double, gap: Double, points: [MagicPoint], stored: () -> SubjectMatte?) throws -> Answer {
        answerNeedsEdge = false
        guard lease.model != nil, let session else {
            self.session = nil   // lets go of the model
            throw SubjectTrackError.released
        }
        let here = points.filter { MagicFollower.belongs(point: Self.seconds($0), pts: pts, span: gap) }
        guard started else {
            let answer = try start(session, pb, pts: pts, gap: gap, points: points, here: here, stored: stored())
            if case .found = answer { started = true }
            return answer
        }
        // A frame with points made on it (a correction): the clicks refine what the model tracks here
        // (`SubjectCorrectionRule`), the stored matte (the system's pick) is only the fallback.
        if !here.isEmpty, Self.correctsOnModel {
            if let answer = try corrected(session, pb, here: here, stored: stored) { return answer }
        } else if !here.isEmpty, let kept = stored().flatMap({ Self.solid($0) }) {
            // The stored matte is looked up (decoded) only on a frame with points made on it. One too faint to condition
            // on is no correction the model can take: the frame is tracked.
            try condition(session, pb, kept)
            return .found(kept)
        }
        return try tracked(session, pb, pts: pts)
    }

    /// `SQ_MASK_CORRECT=0`: a correction is answered as before (the stored system pick replaces the tracked mask).
    static let correctsOnModel = ProcessInfo.processInfo.environment["SQ_MASK_CORRECT"] != "0"
    /// `SQ_MASK_CORRECT_MEMORY=recent`: a refined frame joins the recent frames instead of becoming the conditioning frame.
    static let reseedsOnCorrection = ProcessInfo.processInfo.environment["SQ_MASK_CORRECT_MEMORY"] != "recent"

    /// A correction on a frame inside the leg. The model tracks the frame; when its mask already answers the clicks
    /// it is taken as it is (nil: the caller goes on as on any tracked frame, `pendingTrack` holds the answer).
    /// Otherwise the model is asked again on the same frame with the clicks, and the candidate that refines the
    /// tracked mask is taken and remembered; when none does, the stored matte (the system's pick) is conditioned on
    /// as before, and without one the frame counts as tracked.
    private func corrected(_ session: any SubjectTrackSession, _ pb: CVPixelBuffer, here: [MagicPoint],
                           stored: () -> SubjectMatte?) throws -> Answer? {
        let out = try inModel.during { try session.track(pb) }
        let size = SubjectTrackRules.logitSize
        var logits = out.logits
        if Self.searchBand, let lastBox { logits = SubjectCropPass.constrain(logits, size: size, to: SubjectCropPass.band(around: lastBox, lostFrames: lostRun)) }
        let found = out.score > 0 && SubjectTrackRules.stats(logits: logits, size: size).box != nil
        if found, SubjectCorrectionRule.answers(here, logits: logits, size: size) {
            if recordsDiagnostics { lastDiagnostic = "correction: tracked mask answers the clicks; " }
            pendingTrack = out
            return nil
        }
        let candidates = try inModel.during { try session.corrections(here) }
        let reference = found ? logits : [Float](repeating: -1, count: size * size)
        if let index = SubjectCorrectionRule.refinement(candidates, tracked: reference, points: here, size: size) {
            try inModel.during { try session.adoptCorrection(index, reseed: Self.reseedsOnCorrection) }
            let width = CVPixelBufferGetWidth(pb), height = CVPixelBufferGetHeight(pb)
            let chosen = candidates[index]
            var matte = SubjectMatteUpsample.matte(logits: chosen, size: size, width: width, height: height)
            if !matte.isBlank, let box = SubjectTrackRules.stats(logits: chosen, size: size).box {
                matte = edged(matte, pb)
                let stats = SubjectTrackRules.stats(logits: chosen, size: size)
                rule = SubjectLostRule(area: stats.area, box: box)
                lastFound = matte; lastBox = box; lostRun = 0; absence.found()
                if recordsDiagnostics { lastDiagnostic = "correction: refined (candidate \(index) of \(candidates.count)); " }
                return .found(matte)
            }
        }
        if let kept = stored().flatMap({ Self.solid($0) }) {
            if recordsDiagnostics { lastDiagnostic = "correction: no refinement, stored pick; " }
            try condition(session, pb, kept)
            return .found(kept)
        }
        if recordsDiagnostics { lastDiagnostic = "correction: no refinement, tracked; " }
        pendingTrack = out
        return nil
    }

    /// The model's answer of a frame a correction already tracked (`corrected`), used once by `tracked`.
    private var pendingTrack: SubjectTrackOutput?

    private func tracked(_ session: any SubjectTrackSession, _ pb: CVPixelBuffer, pts: Double) throws -> Answer {
        let width = CVPixelBufferGetWidth(pb), height = CVPixelBufferGetHeight(pb), size = SubjectTrackRules.logitSize
        let out: SubjectTrackOutput
        if let p = pendingTrack { out = p; pendingTrack = nil } else { out = try inModel.during { try session.track(pb) } }
        var logits = out.logits
        if Self.searchBand, let lastBox { logits = SubjectLogitMath.constrain(logits, size: size, to: SubjectCropPass.band(around: lastBox, lostFrames: lostRun)) }
        let stats = SubjectLogitMath.stats(logits: logits, size: size)
        let absent = out.score <= 0 || stats.box == nil
        // The band emptied the mask: the model's unconstrained answer is not what this leg reports, so it stays out of memory.
        let bandEmptied = stats.box == nil && SubjectTrackRules.stats(logits: out.logits, size: size).box != nil
        // After a gap a weak mask is a look-alike, not the subject back (`SubjectReacquireRule`): lost, out of memory.
        var weak = false
        if absent { reacquire.empty() } else if let box = stats.box {
            weak = !reacquire.accepts(score: out.score, area: stats.area, box: box, lostRun: lostRun)
        }
        let lost = weak || rule.isLost(area: absent ? 0 : stats.area, box: absent ? nil : stats.box)
        lastDiagnostic = String(format: "score %.2f area %.4f lost %d", Double(out.score), stats.area, lost ? 1 : 0)
        if Self.logsFrames { NSLog("[SubjectMask] %.3f s: score %.2f, area %.4f, lost %d", pts, Double(out.score), stats.area, lost ? 1 : 0) }
        // A frame the model itself calls empty is remembered (as the reference tracker does), but only the first ones
        // of a gap (`SubjectAbsenceMemory`); one this rule threw out is not: a wrong mask in the memory is followed on
        // the next frames.
        if absent && !bandEmptied {
            if absence.admitsEmpty() { try inModel.during { try session.commit() } }
        } else if !lost {
            absence.found()
            try inModel.during { try session.commit() }
        }
        lostRun = lost ? lostRun + 1 : 0
        if lost { return .lost }
        var matte = SubjectMatteUpsample.matte(logits: logits, size: size, width: width, height: height)
        guard !matte.isBlank else { lostRun += 1; return .lost }
        if Self.cropPass, let box = stats.box { matte = try refined(matte, logits: logits, box: box, session: session, pb) }
        matte = edged(matte, pb)
        lastFound = matte
        lastBox = stats.box
        return .found(matte)
    }

    /// The matte with the model's second look at a crop around it laid over the crop, when that agrees with the first.
    private func refined(_ matte: SubjectMatte, logits: [Float], box: SubjectTrackBox, session: any SubjectTrackSession, _ pb: CVPixelBuffer) throws -> SubjectMatte {
        let size = SubjectTrackRules.logitSize
        let aspect = Double(CVPixelBufferGetWidth(pb)) / Double(max(CVPixelBufferGetHeight(pb), 1))
        let coarse = SubjectMatteUpsample.matte(logits: logits, size: size, width: size, height: size)
        guard let crop = SubjectCropPass.crop(around: box, aspect: aspect), let inside = SubjectTrackRules.interiorPoint(of: coarse),
              let second = try inModel.during({ try session.refine(pb, crop: crop, box: box, inside: inside) }) else { return matte }
        let merged = SubjectCropPass.merged(frame: logits, side: size, cropLogits: second, size: size, crop: crop)
        guard SubjectCropPass.accepts(crop: merged, frame: logits) else {
            if recordsDiagnostics { lastDiagnostic += " crop rejected" }
            return matte
        }
        if recordsDiagnostics { lastDiagnostic += " crop used" }
        return SubjectCropPass.compose(base: matte, cropLogits: second, size: size, crop: crop)
    }

    /// The Quality edge step's settings: `SQ_SUBJECT_MASK_STRANDS=1` adds the color step for hair strands.
    static let edgeSettings = ProcessInfo.processInfo.environment["SQ_SUBJECT_MASK_STRANDS"] == "1"
        ? SubjectMatteRefiner.Settings.strands : SubjectMatteRefiner.Settings()

    /// The model's mask with its edge taken from the picture; with `defersEdges` as it is (`answerNeedsEdge`).
    func edged(_ matte: SubjectMatte, _ pb: CVPixelBuffer) -> SubjectMatte {
        guard defersEdges else { return edger.edged(matte, pb) }
        answerNeedsEdge = edger.refines
        return matte
    }

    /// The system's segmentation threw on the first frame: not the model's failure.
    struct SegmenterFailure: Error { let error: any Error }

    /// A matte the model can be conditioned on (some of it is clearly the subject); a blank or faint one is none.
    static func solid(_ matte: SubjectMatte) -> SubjectMatte? { SubjectTrackRules.box(of: matte) == nil ? nil : matte }

    private func condition(_ session: any SubjectTrackSession, _ pb: CVPixelBuffer, _ matte: SubjectMatte) throws {
        try inModel.during { try session.condition(pb, matte: matte) }
        let size = SubjectTrackRules.logitSize
        let stats = SubjectTrackRules.stats(logits: SubjectTrackRules.logits(from: matte, size: size), size: size)
        rule = stats.box.map { SubjectLostRule(area: stats.area, box: $0) } ?? SubjectLostRule()
        lastFound = matte
        lastBox = stats.box; lostRun = 0; absence.found()
    }

    private func start(_ session: any SubjectTrackSession, _ pb: CVPixelBuffer, pts: Double, gap: Double, points: [MagicPoint],
                       here: [MagicPoint], stored: SubjectMatte?) throws -> Answer {
        lastDiagnostic = ""
        // A frame stored empty with no point made on it: nothing to follow from here (`MagicFollower`'s rule).
        if stored?.isBlank == true, here.isEmpty { return .nothing }
        // A stored matte too faint to condition on and no point made on this frame: the pick's click belongs to
        // another frame and says nothing about where the subject is here, so the model has no start. Not "nothing
        // to follow" (before: the run ended with 0 frames): the caller's system segmentation continues the stored
        // matte, which it can.
        if let stored, Self.solid(stored) == nil, here.isEmpty { throw SubjectTrackError.emptyMatte }
        // What the user saw on this frame: the stored matte, else the system's pick by the points. A matte too faint
        // to condition the model on counts as none.
        var base = stored.flatMap { Self.solid($0) }
        if base == nil {
            let seen: SubjectMatte?
            do {
                seen = try segmenter.segment(pb).flatMap { MagicMaskTracker.pickMatte($0, pts: pts, points: points, span: gap) }
            } catch {
                throw SegmenterFailure(error: error)
            }
            base = seen.flatMap { Self.solid($0) }
        }
        let width = CVPixelBufferGetWidth(pb), height = CVPixelBufferGetHeight(pb), size = SubjectTrackRules.logitSize
        let anchor = points.first?.sourceTime
        // The pick is one click, made on this frame: the model answers it. More points are a corrected pick: its
        // matte is taken as it is.
        if here.count == 1, !here[0].subtract, points.filter({ $0.sourceTime == anchor }) == here {
            let click = here[0].position
            let seen = base.map { SubjectTrackRules.logits(from: $0, size: size) }
            var prompts: [(box: SubjectTrackBox?, person: Bool)] = []
            // The prompt boxes come from the instance under the click, not from the whole seen matte (which can join
            // neighbors), and a person box much larger than that instance is shrunk to it.
            let instance = base.flatMap { SubjectTrackRules.instanceBox(in: $0, at: click) }
            let person = lease.personBox(pb, click)
            let whole = person.map { SubjectTrackRules.promptBox($0, instance: instance) } ?? instance
            // Touching people come out of the system's segmentation as one blob, and a box over the blob picks both.
            // When a person-sized box over the click and another over what is left of the blob give two separate
            // people, the click's own box is the prompt.
            if person != nil, let whole, let seen, let own = try separatedPerson(session, pb, click: click, whole: whole, seen: seen) {
                prompts.append((own, true))
            }
            if let box = whole, person != nil { prompts.append((box, true)) }
            if let instance { prompts.append((instance, false)) }
            prompts.append((nil, false))
            for prompt in prompts {
                let out = try inModel.during { try session.click(pb, point: click, box: prompt.box) }
                if Self.logsFrames || recordsDiagnostics {
                    let st = SubjectTrackRules.stats(logits: out.logits, size: size)
                    lastDiagnostic += String(format: "[prompt %@ box %@ score %.2f area %.4f agrees %d seen %@] ", prompt.person ? "person" : prompt.box == nil ? "point" : "seen-box", prompt.box.map { "\($0)" } ?? "-", Double(out.score), st.area, seen.map { Self.agrees(out.logits, $0, inside: prompt.person) ? 1 : 0 } ?? -1, seen.map { "\(SubjectTrackRules.stats(logits: $0, size: size).area)" } ?? "nothing")
                    NSLog("[SubjectMask] pick at %.3f s (%.3f, %.3f): prompt %@, score %.2f, area %.4f, at the click %.1f, agrees %d, seen %@",
                          pts, click.x, click.y, prompt.box.map { "\($0)" } ?? "point", Double(out.score), st.area,
                          Double(SubjectTrackRules.value(logits: out.logits, size: size, at: click)),
                          seen.map { Self.agrees(out.logits, $0, inside: prompt.person) ? 1 : 0 } ?? -1,
                          seen.map { "\(SubjectTrackRules.stats(logits: $0, size: size))" } ?? "nothing")
                }
                guard out.score > 0, SubjectTrackRules.value(logits: out.logits, size: size, at: click) > 0 else { continue }
                if let seen, !Self.agrees(out.logits, seen, inside: prompt.person) { continue }
                // What the person holds and the answer left out joins it (`SubjectTrackRules.heldPiece`). Only for a
                // person: next to a dog or a car the rest of the segmentation is a bag or a chair, held by nobody.
                let held = prompt.person ? try seen.map { try withHeld(session, pb, click: click, answer: out.logits, seen: $0) } : nil
                let logits = held?.joined ?? out.logits
                let stats = SubjectTrackRules.stats(logits: logits, size: size)
                guard let box = stats.box else { continue }
                var matte = SubjectMatteUpsample.matte(logits: logits, size: size, width: width, height: height)
                guard !matte.isBlank else { continue }
                // The model's memory holds this matte (a click on a held piece replaced the answer's).
                if held?.asked == true { try inModel.during { try session.condition(pb, matte: matte) } }
                matte = edged(matte, pb)
                rule = SubjectLostRule(area: stats.area, box: box)
                lastFound = matte
                lastBox = box; lostRun = 0; absence.found()
                return .found(matte)
            }
        }
        guard let base else { return .nothing }
        try condition(session, pb, base)
        return .found(base)
    }

    /// The pick's answer joined with the model's answer for the piece of `seen` the person holds, nil when there is
    /// no such piece or the model does not find it. One extra model call per held piece (at most
    /// `SubjectTrackRules.heldLimit`), once per pick. `asked` tells the caller the session's memory moved off the answer.
    private func withHeld(_ session: any SubjectTrackSession, _ pb: CVPixelBuffer, click: Vec2, answer: [Float], seen: [Float]) throws -> (joined: [Float]?, asked: Bool) {
        let size = SubjectTrackRules.logitSize
        var joined: [Float]?, asked = false
        let began = DispatchTime.now().uptimeNanoseconds
        var pieces = SubjectTrackRules.heldPieces(seen: seen, answer: answer, size: size)
        SubjectMaskTiming.count("held_pieces", since: began)
        // Vision's person mask tells a touching neighbor's piece (no held object) and the picked person's own limb the
        // answer surrounds (held, `SubjectTrackRules.heldOwnShare`) apart. Asked once per person pick that leaves
        // anything of `seen` out (the limb is no piece without it).
        if let people = SubjectOtherPeople.grids(pb, at: click, size: size) {
            let all = pieces.count
            pieces = SubjectTrackRules.heldPieces(seen: seen, answer: answer, size: size, others: people.others, own: people.own)
            if recordsDiagnostics { lastDiagnostic += "[held pieces \(pieces.count) of \(all) without the person masks] " }
        }
        for piece in pieces {
            guard let box = SubjectTrackRules.stats(logits: piece, size: size).box,
                  let point = SubjectTrackRules.interiorPoint(of: SubjectMatte(width: size, height: size, values: piece.map { $0 > 0 ? 1 : 0 })) else { continue }
            let prompt = box.grown(box.width * 0.1, box.height * 0.1)
            let object = try inModel.during { try session.click(pb, point: point, box: prompt) }
            asked = true
            guard object.score > 0 else { continue }
            let next = SubjectTrackRules.withHeld(answer: joined ?? answer, object: object.logits, piece: piece, size: size)
            if recordsDiagnostics { lastDiagnostic += "[held piece \(box) joined \(next == nil ? 0 : 1)] " }
            joined = next ?? joined
        }
        return (joined, asked)
    }

    /// The person-sized box over the click when `whole` (the box of the area the click picked) holds more than one
    /// person (`SubjectTrackRules.holdsSeveralPeople`), else nil. Two extra model calls, once per pick.
    private func separatedPerson(_ session: any SubjectTrackSession, _ pb: CVPixelBuffer, click: Vec2, whole: SubjectTrackBox,
                                 seen: [Float]) throws -> SubjectTrackBox? {
        let size = SubjectTrackRules.logitSize
        let own = SubjectTrackRules.clickBox(click: click, person: whole)
        let first = try inModel.during { try session.click(pb, point: click, box: own) }
        guard first.score > 0, SubjectTrackRules.value(logits: first.logits, size: size, at: click) > 0 else { return nil }
        let rest = SubjectTrackRules.leftover(seen: seen, first: first.logits, within: whole, size: size)
        let firstArea = first.logits.filter { $0 > 0 }.count
        guard 2 * rest.filter({ $0 > 0 }).count >= firstArea,
              let point = SubjectTrackRules.interiorPoint(of: SubjectMatte(width: size, height: size, values: rest)) else { return nil }
        let second = try inModel.during { try session.click(pb, point: point, box: SubjectTrackRules.clickBox(click: point, person: whole)) }
        guard second.score > 0 else { return nil }
        let several = SubjectTrackRules.holdsSeveralPeople(first: first.logits, second: second.logits, seen: seen, size: size)
        if recordsDiagnostics { lastDiagnostic += "[several people \(several ? 1 : 0)] " }
        return several ? own : nil
    }

    /// Whether the model's answer `a` is what the user saw (`b`): enough overlap, or (a person's box) inside it.
    static func agrees(_ a: [Float], _ b: [Float], inside: Bool) -> Bool {
        var both = 0, onlyA = 0, onlyB = 0
        for i in 0..<min(a.count, b.count) {
            let x = a[i] > 0, y = b[i] > 0
            if x && y { both += 1 } else if x { onlyA += 1 } else if y { onlyB += 1 }
        }
        guard both > 0 else { return false }
        if Double(both) / Double(both + onlyA + onlyB) >= agreement { return true }
        return inside && Double(both) / Double(both + onlyA) >= containment
    }
}

/// The edge step of a leg's mattes. One thread at a time: the frame lane, or the tracker's finishing queue when the
/// leg defers its edges (the tracker then waits for the queue before the leg goes away).
final class SubjectMatteEdger: @unchecked Sendable {
    var refines = SubjectMatteEdges.enabled
    var quality = SubjectMaskQuality.speed
    private let scratch = SubjectMatteRefiner.Picture()

    func edged(_ matte: SubjectMatte, _ pb: CVPixelBuffer) -> SubjectMatte {
        guard refines else { return matte }
        let began = DispatchTime.now().uptimeNanoseconds
        defer { SubjectMaskTiming.count("edges", since: began) }
        // Either step decides alpha only in the band at the mask's edge: inside it the matte stays solid.
        if quality == .quality,
           let fine = SubjectMatteRefiner.refine(matte, guide: pb, settings: SubjectTrackLeg.edgeSettings, scratch: scratch) {
            return SubjectMatteCore.solid(fine, mask: matte)
        }
        return SubjectMatteCore.solid(SubjectMatteEdges.refine(matte, guide: pb), mask: matte)
    }
}

/// Pulls the soft edge of a tracked matte onto the picture's edges: a guided filter (He et al.) with the gray picture
/// as guide, computed at a quarter of the size and applied only in the band around the matte's edge, so the inside
/// and the outside stay as the model gave them. Not a matting step: hair strands the model left out stay out.
enum SubjectMatteEdges {
    /// `SQ_SUBJECT_MASK_EDGES=0` switches the step off (the matte is then the model's mask scaled up).
    static let enabled = ProcessInfo.processInfo.environment["SQ_SUBJECT_MASK_EDGES"] != "0"
    static let scale = 4
    /// Box radius at the reduced size (x `scale` = px of the matte).
    static let radius = 2
    static let epsilon: Float = 0.001

    static func refine(_ matte: SubjectMatte, guide pb: CVPixelBuffer) -> SubjectMatte {
        let w = matte.width, h = matte.height
        guard CVPixelBufferGetWidth(pb) == w, CVPixelBufferGetHeight(pb) == h,
              CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA, w >= 16 * scale, h >= 16 * scale else { return matte }
        var gray = [Float](repeating: 0, count: w * h)
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return matte }
        let row = CVPixelBufferGetBytesPerRow(pb)
        var bytes = [UInt8](repeating: 0, count: w * h)
        // Green as luma: close enough for edges, one channel to read.
        for y in 0..<h {
            let line = base.advanced(by: y * row).assumingMemoryBound(to: UInt8.self)
            bytes.withUnsafeMutableBufferPointer { out in
                var i = y * w
                for x in 0..<w { out[i] = line[x * 4 + 1]; i += 1 }
            }
        }
        vDSP.convertElements(of: bytes, to: &gray)
        vDSP.multiply(1 / 255, gray, result: &gray)
        return refine(matte, gray: gray)
    }

    /// `gray`: the picture at the matte's size, 0...1.
    static func refine(_ matte: SubjectMatte, gray: [Float]) -> SubjectMatte {
        let w = matte.width, h = matte.height
        guard gray.count == w * h, w >= 16 * scale, h >= 16 * scale else { return matte }
        let lw = w / scale, lh = h / scale, n = lw * lh
        let guide = resized(gray, w, h, lw, lh), mask = resized(matte.values, w, h, lw, lh)
        let meanGuide = box(guide, lw, lh), meanMask = box(mask, lw, lh)
        let meanBoth = box(vDSP.multiply(guide, mask), lw, lh), meanSquare = box(vDSP.multiply(guide, guide), lw, lh)
        var a = [Float](repeating: 0, count: n), b = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let variance = meanSquare[i] - meanGuide[i] * meanGuide[i]
            a[i] = (meanBoth[i] - meanGuide[i] * meanMask[i]) / (max(variance, 0) + epsilon)
            b[i] = meanMask[i] - a[i] * meanGuide[i]
        }
        let fullA = resized(box(a, lw, lh), lw, lh, w, h), fullB = resized(box(b, lw, lh), lw, lh, w, h)
        let near = resized(meanMask, lw, lh, w, h)
        var out = matte.values
        out.withUnsafeMutableBufferPointer { o in
            for i in 0..<(w * h) {
                // 1 on the edge, 0 where the matte is plainly in or out within the filter's reach.
                let band = min(max(4 * near[i] * (1 - near[i]), 0), 1)
                guard band > 0.01 else { continue }
                let filtered = min(max(fullA[i] * gray[i] + fullB[i], 0), 1)
                o[i] += band * (filtered - o[i])
            }
        }
        return SubjectMatte(width: w, height: h, values: out)
    }

    private static func resized(_ values: [Float], _ w: Int, _ h: Int, _ toW: Int, _ toH: Int) -> [Float] {
        var out = [Float](repeating: 0, count: toW * toH)
        var input = values
        input.withUnsafeMutableBytes { s in
            out.withUnsafeMutableBytes { d in
                var src = vImage_Buffer(data: s.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
                var dst = vImage_Buffer(data: d.baseAddress, height: vImagePixelCount(toH), width: vImagePixelCount(toW), rowBytes: toW * 4)
                _ = vImageScale_PlanarF(&src, &dst, nil, vImage_Flags(kvImageNoFlags))
            }
        }
        return out
    }

    private static func box(_ values: [Float], _ w: Int, _ h: Int) -> [Float] {
        let side = 2 * radius + 1
        let kernel = [Float](repeating: 1 / Float(side * side), count: side * side)
        var out = [Float](repeating: 0, count: w * h)
        var input = values
        input.withUnsafeMutableBytes { s in
            out.withUnsafeMutableBytes { d in
                var src = vImage_Buffer(data: s.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
                var dst = vImage_Buffer(data: d.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w * 4)
                _ = vImageConvolve_PlanarF(&src, &dst, nil, 0, 0, kernel, UInt32(side), UInt32(side), 0, vImage_Flags(kvImageEdgeExtend))
            }
        }
        return out
    }
}

/// The person under a point and the people other than them, from Vision's person instance mask, on logit grids (> 0
/// in them): what tells a touching neighbor's arm and the picked person's own limb from an object the picked person
/// holds (`SubjectTrackRules.heldPieces`). A point just off Vision's person mask (a click at the outline, between the
/// legs) picks the nearest person. nil when Vision finds nobody or fails; `others` nil when it finds nobody else.
enum SubjectOtherPeople {
    static func grids(_ frame: CVPixelBuffer, at p: Vec2, size: Int) -> (own: [Float], others: [Float]?)? {
        let began = DispatchTime.now().uptimeNanoseconds
        defer { SubjectMaskTiming.count("held_people", since: began) }
        let request = VNGeneratePersonInstanceMaskRequest()
        guard (try? VNImageRequestHandler(cvPixelBuffer: frame, orientation: .up).perform([request])) != nil,
              let observation = request.results?.first else { return nil }
        let labels = observation.instanceMask
        guard CVPixelBufferGetPixelFormatType(labels) == kCVPixelFormatType_OneComponent8 else { return nil }
        CVPixelBufferLockBaseAddress(labels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(labels, .readOnly) }
        guard let raw = CVPixelBufferGetBaseAddress(labels) else { return nil }
        let w = CVPixelBufferGetWidth(labels), h = CVPixelBufferGetHeight(labels), row = CVPixelBufferGetBytesPerRow(labels)
        guard w > 0, h > 0 else { return nil }
        let base = raw.assumingMemoryBound(to: UInt8.self)
        let px = min(max(Int(p.x * Double(w)), 0), w - 1), py = min(max(Int(p.y * Double(h)), 0), h - 1)
        let picked = nearestLabel(base, row: row, width: w, height: h, x: px, y: py)
        guard picked != 0 else { return nil }
        let people = Set(observation.allInstances.map { UInt8(truncatingIfNeeded: $0) }).subtracting([0, picked])
        var own = [Float](repeating: -SubjectTrackRules.matteLogit, count: size * size), others = own
        for y in 0..<size {
            let sy = min((y * h + h / 2) / size, h - 1)
            for x in 0..<size {
                let label = base[sy * row + min((x * w + w / 2) / size, w - 1)]
                if label == picked { own[y * size + x] = SubjectTrackRules.matteLogit }
                else if people.contains(label) { others[y * size + x] = SubjectTrackRules.matteLogit }
            }
        }
        return (own, people.isEmpty ? nil : others)
    }

    /// The label at (x, y), or the nearest nonzero label to it (0 when the mask holds nobody).
    static func nearestLabel(_ base: UnsafePointer<UInt8>, row: Int, width w: Int, height h: Int, x: Int, y: Int) -> UInt8 {
        if base[y * row + x] != 0 { return base[y * row + x] }
        var best: UInt8 = 0, bestDistance = Int.max
        for sy in 0..<h {
            for sx in 0..<w where base[sy * row + sx] != 0 {
                let d = (sx - x) * (sx - x) + (sy - y) * (sy - y)
                if d < bestDistance { bestDistance = d; best = base[sy * row + sx] }
            }
        }
        return best
    }
}
