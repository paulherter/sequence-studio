import Foundation
import SQCore

/// Dynamic Zoom (Ken Burns): the selected clips (else the one under the playhead) get a Dynamic Zoom stage, a slow eased
/// zoom between two windows of the picture, as Scale and Position keys in Effect Controls. Zoom In goes from the whole
/// picture to a centered window, Zoom Out the other way. The stage sits on top of Motion (Motion is never touched); a
/// second run replaces the stage. One undo step.
extension EditorSession {
    /// The window a one-click Dynamic Zoom ends on (1.25 = 125 %).
    public static let dynamicZoomAmount = 1.25

    /// Same targets as Auto Reframe: media video clips with a known picture size on unlocked tracks.
    @discardableResult
    public func applyDynamicZoom(zoomIn: Bool, zoom: Double = EditorSession.dynamicZoomAmount,
                                 ease: ZoomEase = .easeInOut) -> Bool {
        let targets = reframeTargets
        guard !targets.isEmpty else { return false }
        let near = ZoomRect.full, far = ZoomRect.centred(zoom: zoom)
        let (a, b) = zoomIn ? (near, far) : (far, near)
        let sizes = Dictionary(uniqueKeysWithValues: targets.compactMap { c in
            project.pictureSize(of: c).map { (c.id, Vec2(Double($0.width), Double($0.height))) }
        })
        return attempt("Dynamic Zoom") { t in
            var changed = 0
            for tr in t.tracks where !tr.isLocked {
                for c in tr.clips {
                    guard let size = sizes[c.id] else { continue }
                    var n = c
                    guard DynamicZoom.apply(to: &n, from: a, to: b, picture: size, ease: ease) else { continue }
                    if n != c { try t.replaceClip(n); changed += 1 }
                }
            }
            if changed == 0 { throw EditError.emptyClip }
        }
    }

    // MARK: Editing the two windows (Program monitor)

    /// What the Dynamic Zoom editor shows for `clip`: its stage's windows, else the one-click default (whole picture to
    /// 125 %) as a starting point. nil for clips Dynamic Zoom does not work on.
    public func dynamicZoomWindows(for clip: Clip) -> (start: ZoomRect, end: ZoomRect, ease: ZoomEase)? {
        guard let size = project.pictureSize(of: clip), !clip.isGenerator, clip.sequence == nil, !clip.isStill, clip.holdFrame == nil
        else { return nil }
        let pic = Vec2(Double(size.width), Double(size.height))
        return DynamicZoom.windows(of: clip, picture: pic) ?? (.full, .centred(zoom: Self.dynamicZoomAmount), .easeInOut)
    }

    /// Writes `start` / `end` into the clip's Dynamic Zoom stage as a live edit: `continuesGesture` joins the running drag
    /// into one undo step. The monitor shows the new zoom at once.
    @discardableResult
    public func setDynamicZoomWindows(clip id: Clip.ID, start: ZoomRect, end: ZoomRect, ease: ZoomEase,
                                      continuesGesture: Bool) -> Bool {
        guard let t = activeTimeline, let c = t.tracks.lazy.flatMap(\.clips).first(where: { $0.id == id }),
              let size = project.pictureSize(of: c) else { return false }
        let shown = displayedClip(c)
        var n = shown
        guard DynamicZoom.apply(to: &n, from: start, to: end, picture: Vec2(Double(size.width), Double(size.height)), ease: ease),
              n != shown else { return false }
        replaceDisplayedClip(n, name: "Dynamic Zoom", continuesGesture: continuesGesture)
        return true
    }
}
