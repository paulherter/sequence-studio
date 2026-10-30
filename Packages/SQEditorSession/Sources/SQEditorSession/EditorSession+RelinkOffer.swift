import Foundation
import SQCore

extension EditorSession {
    /// Folders worth searching for offline `missing` media without asking: each file's old folder, the same relative
    /// folder on the other mounted volumes (`/Volumes/OLD/x` -> `/Volumes/NEW/x`), the project folder and the folders
    /// remembered from earlier relinks. Returned with the depth to descend; only folders that exist.
    public nonisolated static func relinkOfferRoots(missing: [MediaRef], volumes: [URL], projectFolder: URL?,
                                                    extraFolders: [URL]) -> [(URL, Int)] {
        var roots: [(URL, Int)] = []
        var seen = Set<String>()
        func add(_ url: URL, _ depth: Int) {
            let p = url.standardizedFileURL.path
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue, seen.insert(p).inserted else { return }
            roots.append((URL(fileURLWithPath: p, isDirectory: true), depth))
        }
        for m in missing {
            let parent = (m.path as NSString).deletingLastPathComponent
            #if os(Windows)
            guard (parent as NSString).isAbsolutePath else { continue }   // a drive or UNC path
            #else
            guard parent.hasPrefix("/") else { continue }
            #endif
            add(URL(fileURLWithPath: parent, isDirectory: true), 1)
            let comps = parent.split(separator: "/").map(String.init)
            if comps.count >= 2, comps[0] == "Volumes" {
                let rest = comps.dropFirst(2).joined(separator: "/")
                for v in volumes where v.lastPathComponent != comps[1] {
                    add(rest.isEmpty ? v : v.appendingPathComponent(rest, isDirectory: true), 1)
                }
            }
        }
        if let projectFolder { add(projectFolder, 5) }
        for f in extraFolders { add(f, 12) }
        return roots
    }

    /// Looks for the offline media in the likely places and returns what a relink would do, without changing the
    /// project (the app shows it as an Apply banner). Scans off the main thread; empty when nothing is offline.
    public func relinkOffer(projectFolder: URL?, extraFolders: [URL], volumes: [URL]? = nil) async -> [MediaRef.ID: String] {
        let missing = missingMedia
        guard !missing.isEmpty else { return [:] }
        let projectID = project.id
        let vols = volumes ?? ((try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: "/Volumes"), includingPropertiesForKeys: nil)) ?? [])
        let roots = Self.relinkOfferRoots(missing: missing, volumes: vols, projectFolder: projectFolder, extraFolders: extraFolders)
        guard !roots.isEmpty else { return [:] }
        let wanted = Set(missing.map { MediaPathResolver.fileName(of: $0.path).lowercased() })
        let found = await Task.detached(priority: .utility) { RelinkScanner.scan(roots: roots, named: wanted) }.value
        guard project.id == projectID else { return [:] }
        return RelinkPlanner.match(missing: missingMedia, candidates: found).plan
    }

    /// Applies an offer from `relinkOffer` (one undo step), keeping only items that are still offline.
    @discardableResult
    public func applyRelinkOffer(_ plan: [MediaRef.ID: String]) -> Int {
        let still = Set(missingMedia.map(\.id))
        let use = plan.filter { still.contains($0.key) }
        relinkSiblings(use)
        return use.count
    }
}

extension EditorSession {
    /// A project copied to another machine or folder (a Mac project opened on Windows): links the offline media that
    /// sits next to the project file (`NearProjectRelink`: same trailing folders, else name + size below it). The scan
    /// runs off the main actor; applied without an undo step. Returns how many were linked.
    @discardableResult
    public func relinkNearProject() async -> Int {
        let missing = missingMedia
        guard !missing.isEmpty, let folder = fileURL?.deletingLastPathComponent() else { return 0 }
        let projectID = project.id
        let plan = await Task.detached(priority: .userInitiated) { NearProjectRelink.plan(missing: missing, folder: folder) }.value
        guard project.id == projectID else { return 0 }
        let still = Set(missingMedia.map(\.id))
        let use = plan.filter { still.contains($0.key) }
        guard !use.isEmpty else { return 0 }
        stopPlayback()
        relinkMediaQuietly(use)
        SQLog.info("relink near project: \(use.count) of \(missing.count)")
        return use.count
    }
}
