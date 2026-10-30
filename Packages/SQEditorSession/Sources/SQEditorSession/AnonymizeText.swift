import Foundation
import SQCore

/// What the user chose in the Anonymize sheet (AppKit `AnonymizeDialog`, shared `ShellHost.askAnonymize`).
public struct AnonymizeChoice: Sendable, Hashable {
    public var target: AnonymizeTarget
    public var cover: AnonymizeCover
    /// Indices into the found people.
    public var people: [Int]

    public init(target: AnonymizeTarget, cover: AnonymizeCover, people: [Int]) {
        self.target = target; self.cover = cover; self.people = people
    }

    private enum Key { static let target = "sq.anonymize.target", cover = "sq.anonymize.cover" }

    /// Last target and cover used (Face, Mosaic the first time).
    public static func remembered(_ d: UserDefaults = .standard) -> (target: AnonymizeTarget, cover: AnonymizeCover) {
        (d.string(forKey: Key.target).flatMap(AnonymizeTarget.init(rawValue:)) ?? .face,
         d.string(forKey: Key.cover).flatMap(AnonymizeCover.init(rawValue:)) ?? .mosaic)
    }

    public func remember(_ d: UserDefaults = .standard) {
        d.set(target.rawValue, forKey: Key.target); d.set(cover.rawValue, forKey: Key.cover)
    }
}

/// The texts of the Anonymize sheets, one copy for the AppKit and the shared dialogs. The text never promises a result:
/// detection is a guess and the user checks it.
public enum AnonymizeText {
    public static let hint = "Detection is a best guess and can miss frames. Frames it was unsure about are listed afterwards. Always check the whole clip before you export."
    /// At most this many uncritical lines are listed after a run.
    public static let maxLines = 12

    /// "Person 2 (center)": numbered left to right, with where they stand on the frame.
    public static func personLabel(_ index: Int, _ p: AnonymizePerson) -> String {
        let x = p.box.center.x
        return "Person \(index + 1) (\(x < 1.0 / 3 ? "left" : x > 2.0 / 3 ? "right" : "center"))"
    }

    public static func info(clipName: String) -> String {
        clipName + "\nEach person gets a mask that follows them through the clip. The cover is an effect limited to those masks; both stay editable in Effect Controls."
    }

    public static func peopleNote(count: Int) -> String {
        count == 1 ? "One person found on this frame:" : "\(count) people found on this frame, numbered left to right:"
    }

    /// The text above the list of frames to check: says plainly when a person may be visible.
    public static func checksText(_ lines: [AnonymizeCheckLine]) -> String {
        let base = "The cover is applied. On the frames below the detection was unsure, so look at them and correct the mask where needed. Other frames can be off too."
        guard lines.contains(where: \.critical) else { return base }
        return "The cover is applied, but a person was not followed through the whole clip. On the first ranges below the cover is only an enlarged estimate of where they were last seen, so they may be visible: check those first and track the mask on from there. " + "On the other frames the detection was unsure. Other frames can be off too."
    }

    public static func moreNote(_ more: Int) -> String { "and \(more) more ranges where the detection was unsure." }
}
