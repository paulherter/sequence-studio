import Foundation

/// What `ProjectFile.readSalvaging` left out of a project file that did not decode as a whole, one line per dropped part.
public struct ProjectSalvageReport: Equatable, Sendable {
    public var dropped: [String] = []
    public var isEmpty: Bool { dropped.isEmpty }
    public init(dropped: [String] = []) { self.dropped = dropped }
}

extension ProjectFile {
    /// Opens a project file, and when it does not decode as a whole opens the rest: a clip, effect, sequence or media item
    /// that fails is dropped (a media item is kept as an offline placeholder with its id, name and path) and listed in the
    /// report. Reads only; the file is never written (the caller opens the result as unsaved). A file that is not a project
    /// at all, or from a newer build, throws as `read` does.
    public static func readSalvaging(from url: URL) throws -> (project: Project, report: ProjectSalvageReport) {
        let file = url.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: file.path) else { throw ProjectFileError.missing }
        guard let data = try? Data(contentsOf: file) else { throw ProjectFileError.corrupt }
        return try salvage(data)
    }

    /// Copies the damaged `project.json` of `package` to `<package>.damaged.bak` beside it (a numbered name when one exists:
    /// never overwritten), so a save over the original keeps what the salvage left out. Returns the copy, nil when the package
    /// has no file.
    @discardableResult
    public static func backUpDamaged(package: URL, fileManager fm: FileManager = .default) throws -> URL? {
        let file = package.appendingPathComponent(fileName)
        guard fm.fileExists(atPath: file.path) else { return nil }
        let dir = package.deletingLastPathComponent(), base = package.lastPathComponent
        var n = 1
        var dest = dir.appendingPathComponent("\(base).damaged.bak")
        while fm.fileExists(atPath: dest.path) { n += 1; dest = dir.appendingPathComponent("\(base).damaged\(n).bak") }
        try fm.copyItem(at: file, to: dest)
        return dest
    }

    static func salvage(_ data: Data) throws -> (project: Project, report: ProjectSalvageReport) {
        if let whole = try? decode(data, migrations: nil) { return (whole, ProjectSalvageReport()) }
        guard var obj = (try? JSONSerialization.jsonObject(with: data)) as? JSONObject,
              var version = obj["formatVersion"] as? Int, obj["project"] is JSONObject else { throw ProjectFileError.corrupt }
        if version > currentVersion { throw ProjectFileError.newerVersion(found: version, supported: currentVersion) }
        let steps = migrations
        while version < currentVersion {
            guard let step = steps[version], let next = try? step(obj) else { throw ProjectFileError.corrupt }
            obj = next
            version += 1
        }
        guard var proj = obj["project"] as? JSONObject else { throw ProjectFileError.corrupt }
        var report = ProjectSalvageReport()

        func decodes<T: Decodable>(_ type: T.Type, _ o: JSONObject) -> T? {
            guard JSONSerialization.isValidJSONObject(o), let d = try? JSONSerialization.data(withJSONObject: o) else { return nil }
            return try? decoder().decode(T.self, from: d)
        }
        func label(_ o: JSONObject, _ fallback: String) -> String { (o["name"] as? String).map { "“\($0)”" } ?? fallback }

        // Media: a failing item stays as an offline placeholder when it still has an id.
        if let list = proj["media"] as? [JSONObject] {
            proj["media"] = list.compactMap { m -> JSONObject? in
                if decodes(MediaRef.self, m) != nil { return m }
                let name = (m["name"] as? String) ?? "Media"
                report.dropped.append("Media “\(name)”: its details could not be read, the item is offline")
                guard let id = m["id"] as? String, UUID(uuidString: id) != nil else { return nil }
                return ["id": id, "name": name, "path": (m["path"] as? String) ?? "",
                        "fingerprint": ["size": 0]] as JSONObject
            }
        }

        // Sequences > tracks > clips > effects.
        var timelines: [JSONObject] = []
        var droppedTimelines = Set<String>()
        var keptMedia = Set(((proj["media"] as? [JSONObject]) ?? []).compactMap { $0["id"] as? String })
        var placeholders: [JSONObject] = []
        for var t in (proj["timelines"] as? [JSONObject]) ?? [] {
            let tName = label(t, "a sequence")
            var tracks: [JSONObject] = []
            for var tr in (t["tracks"] as? [JSONObject]) ?? [] {
                let trName = (tr["name"] as? String).flatMap { $0.isEmpty ? nil : "“\($0)”" } ?? "a track"
                var droppedIDs = Set<String>()
                var clips: [JSONObject] = []
                for var c in (tr["clips"] as? [JSONObject]) ?? [] {
                    if decodes(Clip.self, c) == nil, let fx = c["effects"] as? [JSONObject] {
                        var kept: [JSONObject] = []
                        for e in fx {
                            if decodes(ClipEffect.self, e) != nil { kept.append(e); continue }
                            report.dropped.append("Effect \((e["kind"] as? String).map { "“\($0)”" } ?? "") on clip \(label(c, "a clip")) in \(tName): unknown or damaged")
                        }
                        c["effects"] = kept
                    }
                    if decodes(Clip.self, c) != nil { clips.append(c); continue }
                    if let id = c["id"] as? String { droppedIDs.insert(id) }
                    report.dropped.append("Clip \(label(c, "")) on \(trName) in \(tName): unknown or damaged")
                }
                tr["clips"] = clips
                if !droppedIDs.isEmpty, let ts = tr["transitions"] as? [JSONObject] {
                    tr["transitions"] = ts.filter { x in
                        ![x["outgoing"], x["incoming"]].contains { ($0 as? String).map(droppedIDs.contains) == true }
                    }
                }
                if decodes(Track.self, tr) != nil { tracks.append(tr) } else {
                    report.dropped.append("Track \(trName) in \(tName): damaged")
                }
            }
            t["tracks"] = tracks
            if decodes(Timeline.self, t) != nil { timelines.append(t) } else {
                if let id = t["id"] as? String { droppedTimelines.insert(id) }
                report.dropped.append("Sequence \(tName): damaged")
            }
        }
        // Clips that lost what they refer to: nested sequences that were dropped go with them; a clip of media the file no
        // longer lists points at an offline placeholder; an attachment to a dropped clip is cleared (re-derived on edit).
        for ti in timelines.indices {
            let tName = label(timelines[ti], "a sequence")
            var tracks = (timelines[ti]["tracks"] as? [JSONObject]) ?? []
            var gone = Set<String>()
            for tri in tracks.indices {
                var clips = (tracks[tri]["clips"] as? [JSONObject]) ?? []
                clips.removeAll { c in
                    guard let s = c["sequence"] as? String, droppedTimelines.contains(s) else { return false }
                    if let id = c["id"] as? String { gone.insert(id) }
                    report.dropped.append("Clip \(label(c, "")) in \(tName): its sequence could not be read")
                    return true
                }
                tracks[tri]["clips"] = clips
            }
            var present = Set<String>()
            for tr in tracks { for c in (tr["clips"] as? [JSONObject]) ?? [] { if let id = c["id"] as? String { present.insert(id) } } }
            for tri in tracks.indices {
                var clips = (tracks[tri]["clips"] as? [JSONObject]) ?? []
                for ci in clips.indices {
                    if let a = clips[ci]["attachment"] as? JSONObject, let h = a["host"] as? String,
                       gone.contains(h) || !present.contains(h) { clips[ci]["attachment"] = nil }
                    if clips[ci]["sequence"] == nil, clips[ci]["generator"] == nil, let m = clips[ci]["media"] as? String,
                       UUID(uuidString: m) != nil, !keptMedia.contains(m) {
                        keptMedia.insert(m)
                        let n = (clips[ci]["name"] as? String) ?? "Media"
                        placeholders.append(["id": m, "name": n, "path": "", "fingerprint": ["size": 0]] as JSONObject)
                        report.dropped.append("Media for clip “\(n)” is missing from the file; the clip is offline")
                    }
                }
                tracks[tri]["clips"] = clips
            }
            timelines[ti]["tracks"] = tracks
        }
        if !placeholders.isEmpty { proj["media"] = ((proj["media"] as? [JSONObject]) ?? []) + placeholders }
        proj["timelines"] = timelines
        if let a = proj["activeTimeline"] as? String, !timelines.contains(where: { ($0["id"] as? String) == a }) {
            proj["activeTimeline"] = nil
        }
        guard let project = decodes(Project.self, proj) else { throw ProjectFileError.corrupt }
        return (project, report)
    }
}
