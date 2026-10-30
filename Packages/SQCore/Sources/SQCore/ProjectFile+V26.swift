import Foundation

extension ProjectFile {
    /// v26 (W4.1 format variants): `Timeline.variants` and `Clip.variantOverrides` (sparse, keyed by variant id). Both
    /// optional on decode; absent = base size only, no overrides, so a v25 file plays unchanged. The step drops overrides
    /// whose variant or effect does not exist (`Project.pruneVariantOverrides`); a project that does not decode is passed
    /// on unchanged (the final decode then reports it). Older builds drop variants and overrides on save.
    static func migrateV25toV26(_ obj: JSONObject) throws -> JSONObject {
        var o = obj
        guard let projectObj = obj["project"], JSONSerialization.isValidJSONObject(projectObj),
              let raw = try? JSONSerialization.data(withJSONObject: projectObj),
              var project = try? decoder().decode(Project.self, from: raw) else { return obj }
        guard project.pruneVariantOverrides() else { return obj }
        guard let data = try? encoder().encode(project),
              let migrated = try? JSONSerialization.jsonObject(with: data) else { return obj }
        o["project"] = migrated
        return o
    }
}
