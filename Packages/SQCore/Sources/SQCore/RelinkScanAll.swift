import Foundation

extension RelinkScanner {
    /// Every media file (`isMedia(lowercased extension)`) below each root, for scoring by more than the name. Same walk
    /// rules as `scan(roots:named:)`; stops after `limit` files so a huge drive cannot stall the dialog.
    public static func scanMedia(roots: [(URL, Int)], isMedia: (String) -> Bool, limit: Int = 20_000) -> [RelinkCandidate] {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey, .isDirectoryKey, .contentModificationDateKey]
        var seen = Set<String>()
        var out: [RelinkCandidate] = []
        for (root, depth) in roots {
            let finished = FileWalk.walk(root, keys: keys) { url, v, level in
                if v?.isDirectory == true { return level > depth ? .skip : .descend }
                guard v?.isRegularFile == true, isMedia(url.pathExtension.lowercased()) else { return .descend }
                let path = url.standardizedFileURL.path
                guard seen.insert(path).inserted else { return .descend }
                out.append(RelinkCandidate(path: path, size: Int64(v?.fileSize ?? -1), modified: v?.contentModificationDate))
                return out.count >= limit ? .stop : .descend
            }
            if !finished { return out }
        }
        return out
    }

    /// Where a Reconnect from one found file or folder looks: that folder (deep), its parent two levels down (siblings),
    /// and a folder of the same name on every other mounted volume.
    public static func reconnectRoots(picked: URL, volumes: [URL]) -> [(URL, Int)] {
        var isDir: ObjCBool = false
        let folder = FileManager.default.fileExists(atPath: picked.path, isDirectory: &isDir) && !isDir.boolValue
            ? picked.deletingLastPathComponent() : picked
        var roots: [(URL, Int)] = [(folder, 8)]
        let parent = folder.deletingLastPathComponent()
        if parent.path != "/" && parent.path != folder.path { roots.append((parent, 2)) }
        let comps = folder.standardizedFileURL.pathComponents
        if comps.count >= 3, comps[1] == "Volumes" {
            let rest = comps.dropFirst(3).joined(separator: "/")
            for v in volumes where v.lastPathComponent != comps[2] {
                let twin = rest.isEmpty ? v : v.appendingPathComponent(rest, isDirectory: true)
                if FileManager.default.fileExists(atPath: twin.path) { roots.append((twin, 8)) }
            }
        } else {
            let name = folder.lastPathComponent
            for v in volumes {
                let twin = v.appendingPathComponent(name, isDirectory: true)
                if FileManager.default.fileExists(atPath: twin.path) { roots.append((twin, 8)) }
            }
        }
        return roots
    }
}
