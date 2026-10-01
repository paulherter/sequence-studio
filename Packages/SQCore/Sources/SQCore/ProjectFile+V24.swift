import Foundation

extension ProjectFile {
    /// v24 (groups, source patching): `Clip.group` (optional, absent = not grouped) and `Track.isSourcePatched`. A track
    /// without the key is patched exactly when it is targeted, so Source edits keep landing where they did. `Track`
    /// decoding applies the same default; this step writes it into the object so the stored file says so.
    static func migrateV23toV24(_ obj: JSONObject) throws -> JSONObject {
        var o = obj
        guard var p = o["project"] as? JSONObject, let timelines = p["timelines"] as? [Any] else { return obj }
        p["timelines"] = timelines.map { item -> Any in
            guard var t = item as? JSONObject, let tracks = t["tracks"] as? [Any] else { return item }
            t["tracks"] = tracks.map { tr -> Any in
                guard var track = tr as? JSONObject, track["isSourcePatched"] == nil else { return tr }
                track["isSourcePatched"] = track["isTargeted"] as? Bool ?? false
                return track
            }
            return t
        }
        o["project"] = p
        return o
    }
}
