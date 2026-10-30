import Foundation
import SQCore

/// SQ rows for the small timeline context menus (volume key, speed key, transition, track header, ruler).
/// Pure builders (portable, the Windows timeline uses them too): the app passes closures, tests check titles, enabled and checked state, shortcut text and order.
public enum TimelineSideMenus {
    public static func volumeKey(delete: @escaping @MainActor () -> Void) -> [SQMenuItem] {
        [SQMenuItem(title: "Delete Keyframe", action: delete)]
    }

    /// Fade handle menu: the curve shapes with a check on the current one. No fade yet: the rows are disabled.
    public static func fadeCurve(current: FadeCurve?, set: @escaping @MainActor (FadeCurve) -> Void) -> [SQMenuItem] {
        FadeCurve.allCases.map { c in
            SQMenuItem(title: c.title, isEnabled: current != nil, isChecked: current == c) { set(c) }
        }
    }

    /// Right-click on the speed band away from a key: "Add Speed Point" at the click.
    public static func speedPoint(add: @escaping @MainActor () -> Void) -> [SQMenuItem] {
        [SQMenuItem(title: "Add Speed Point", action: add)]
    }

    public static func speedKey(deleteTitle: String, isRamp: Bool, curve: @escaping @MainActor () -> Void,
                                delete: @escaping @MainActor () -> Void) -> [SQMenuItem] {
        var rows: [SQMenuItem] = []
        if isRamp { rows += [SQMenuItem(title: "Speed Transition Curve…", action: curve), .separator] }
        rows.append(SQMenuItem(title: deleteTitle, action: delete))
        return rows
    }

    public static func transition(setDuration: @escaping @MainActor () -> Void, saveAsPreset: @escaping @MainActor () -> Void,
                                  delete: @escaping @MainActor () -> Void) -> [SQMenuItem] {
        [SQMenuItem(title: "Set Transition Duration…", action: setDuration),
         SQMenuItem(title: "Save as Preset…", action: saveAsPreset),
         .separator,
         SQMenuItem(title: "Delete", action: delete)]
    }

    public static func trackHeader(track: Track, addVideo: @escaping @MainActor () -> Void, addAudio: @escaping @MainActor () -> Void,
                                   delete: @escaping @MainActor () -> Void, rename: @escaping @MainActor () -> Void,
                                   moveUp: (@MainActor () -> Void)? = nil, moveDown: (@MainActor () -> Void)? = nil,
                                   mix: @escaping @MainActor () -> Void, toggleDucking: @escaping @MainActor () -> Void,
                                   sequenceVolume: (@MainActor () -> Void)? = nil,
                                   selectAll: (@MainActor () -> Void)? = nil,
                                   toggle: (@MainActor (TrackToggle) -> Void)? = nil) -> [SQMenuItem] {
        // Every switch of the header, also the ones it only shows in their non-default state (audio lock, sync lock).
        var switches = [SQMenuItem]()
        if let toggle {
            switches.append(SQMenuItem(title: "Target Track", isChecked: track.isTargeted) { toggle(.target) })
            if track.kind == .video {
                switches.append(SQMenuItem(title: "Show Track", isChecked: track.isVisible) { toggle(.visible) })
            } else {
                switches.append(SQMenuItem(title: "Mute", isChecked: track.isMuted) { toggle(.mute) })
                switches.append(SQMenuItem(title: "Solo", isChecked: track.isSolo) { toggle(.solo) })
            }
            switches.append(SQMenuItem(title: "Lock Track", isChecked: track.isLocked) { toggle(.lock) })
            switches.append(SQMenuItem(title: "Sync Lock", isChecked: track.syncLock,
                                       help: "Keeps this track in step when a ripple edit moves another track") { toggle(.syncLock) })
            switches.append(.separator)
        }
        var rows = switches
        if let selectAll {
            rows += [SQMenuItem(title: "Select All Clips on Track", isEnabled: !track.clips.isEmpty && !track.isLocked, action: selectAll),
                     .separator]
        }
        rows += [SQMenuItem(title: "Add Video Track", action: addVideo),
                    SQMenuItem(title: "Add Audio Track", action: addAudio),
                    SQMenuItem(title: "Delete Track", isEnabled: !track.isLocked, action: delete),
                    .separator]
        if let moveUp { rows.append(SQMenuItem(title: "Move Track Up", action: moveUp)) }
        if let moveDown { rows.append(SQMenuItem(title: "Move Track Down", action: moveDown)) }
        if moveUp != nil || moveDown != nil { rows.append(.separator) }
        rows.append(SQMenuItem(title: "Rename…", action: rename))
        if track.kind == .audio {
            rows.append(SQMenuItem(title: "Volume and Pan…", action: mix))
            // The level of the whole sequence (after every track), next to the track's own fader.
            if let sequenceVolume { rows.append(SQMenuItem(title: "Sequence Volume…", action: sequenceVolume)) }
            // Per-track opt-out of live ducking. Only Music (ducked) and Dialogue (ducks) tracks take part.
            let title: String
            switch track.audioRole {
            case .music?: title = "Duck Under Dialogue"
            case .dialogue?: title = "Duck the Music"
            default: title = "Live Ducking (Dialogue or Music tracks)"
            }
            let takesPart = track.audioRole == .music || track.audioRole == .dialogue
            rows.append(SQMenuItem(title: title, isEnabled: takesPart, isChecked: takesPart && !track.isExcludedFromLiveDucking,
                                   action: toggleDucking))
        }
        return rows
    }

    /// Marker commands at the pointer, then Mark In / Out and Remove In and Out (keys shown), Delete Marker last.
    public static func ruler(hasMarkerAtPointer: Bool, entries: [RulerRangeEntry], addMarkerShortcut: String,
                             addMarker: @escaping @MainActor () -> Void, editMarker: @escaping @MainActor () -> Void,
                             range: @escaping @MainActor (EditorCommand) -> Void,
                             deleteMarker: @escaping @MainActor () -> Void) -> [SQMenuItem] {
        var rows = [SQMenuItem(title: "Add Marker", shortcut: addMarkerShortcut, action: addMarker)]
        if hasMarkerAtPointer { rows.append(SQMenuItem(title: "Edit Marker…", action: editMarker)) }
        rows.append(.separator)
        for e in entries {
            let cmd = e.command
            rows.append(SQMenuItem(title: e.title, shortcut: SQMenuShortcut.glyphs(key: e.key, keyModifiers: e.keyModifiers),
                                   isEnabled: e.isEnabled, action: { range(cmd) }))
        }
        if hasMarkerAtPointer { rows += [.separator, SQMenuItem(title: "Delete Marker", action: deleteMarker)] }
        return rows
    }
}
