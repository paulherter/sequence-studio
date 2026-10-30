import Foundation

extension ProjectFile {
    /// v27 (color grade as an effect): the Color effects a clip kept inside `color` (v12...v26) become `ClipEffect`s of
    /// kind `color` in front of its effect list (`Clip.adoptLegacyGrade`, which the clip decoder runs, so this step only
    /// re-encodes); `color` keeps the footage interpretation. LUT references (files, embedded, automatic) are carried
    /// over as they were, so the picture is identical. A project that does not decode is passed on unchanged (the final
    /// decode then converts or reports it). Older builds refuse v27 files.
    static func migrateV26toV27(_ obj: JSONObject) throws -> JSONObject {
        var o = obj
        guard let projectObj = obj["project"], JSONSerialization.isValidJSONObject(projectObj),
              let raw = try? JSONSerialization.data(withJSONObject: projectObj),
              let project = try? decoder().decode(Project.self, from: raw),
              let data = try? encoder().encode(project),
              let migrated = try? JSONSerialization.jsonObject(with: data) else { return obj }
        o["project"] = migrated
        return o
    }
}
