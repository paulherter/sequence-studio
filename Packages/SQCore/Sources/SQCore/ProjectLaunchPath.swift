import Foundation

extension ProjectFile {
    /// Cleans one command-line argument into a project path: trims spaces and a pair of quotes (Explorer's "Open with"
    /// may pass them through), drops trailing slashes or backslashes. Nil when it is not a `.sqproj` / legacy `.ssproj`
    /// (case-insensitive).
    public static func launchProjectPath(_ argument: String) -> String? {
        var s = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.count >= 2, let f = s.first, f == s.last, f == "\"" || f == "'" {
            s = String(s.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        s = s.replacingOccurrences(of: "\"", with: "")
        while let last = s.last, last == "/" || last == "\\" { s.removeLast() }
        guard !s.isEmpty else { return nil }
        let name = s.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? s
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
        let ext = name[name.index(after: dot)...].lowercased()
        guard ext == fileExtension || legacyFileExtensions.contains(ext) else { return nil }
        return s
    }

    /// The first project path among the process arguments (the program name excluded by the caller).
    public static func launchProjectPath(in arguments: [String]) -> String? {
        arguments.lazy.compactMap { launchProjectPath($0) }.first
    }
}
