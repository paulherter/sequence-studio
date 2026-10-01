import Foundation

extension ProjectFile {
    /// v19 (source-project-flow): `MediaRef.posterTime` (Project panel poster frame, Cmd+P) and `MediaRef.sourceMarkers`
    /// (markers set with M in the Source monitor). Both optional on decode; absent = automatic poster, no markers:
    /// identity migration. Older builds drop these fields on save.
    static func migrateV18toV19(_ obj: JSONObject) throws -> JSONObject { obj }
}
