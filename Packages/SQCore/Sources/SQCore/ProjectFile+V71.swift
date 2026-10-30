import Foundation

// v71: Angles clip (Angles.swift): `Clip.angle` (which angle a piece plays) and `Timeline.angles` (the sequence is the
// inside of an Angles clip). A v70 build would open such a clip as a plain nested sequence, show every angle stacked
// (the top one always wins), mix every angle's sound and drop both keys on the next save; at v71 it refuses the file with
// `ProjectFileError.newerVersion` instead. Projects without an Angles clip store neither key and keep the lowest version
// that holds their content. Files before v71 have no key: every nested clip plays its whole sequence as before.

extension Project {
    /// Any clip plays one angle or any sequence is an Angles sequence: the file must be v71.
    public var containsV71Content: Bool {
        timelines.contains { $0.angles != nil } || allClips().contains { $0.angle != nil }
    }
}
