import Foundation
import SSCore

/// Serial, off-main queue for everything that touches the project package on disk (save, read, autosave), so
/// the UI never waits for I/O and two writes never overlap (docs/PALMIER.md: off-main save queue).
public actor ProjectSaveQueue {
    public typealias Writer = @Sendable (Project, URL) throws -> Void
    public typealias Reader = @Sendable (URL) throws -> Project

    private let writer: Writer
    private let reader: Reader

    public init(writer: @escaping Writer = { try ProjectFile.write($0, to: $1) },
                reader: @escaping Reader = { try ProjectFile.read(from: $0) }) {
        self.writer = writer; self.reader = reader
    }

    public func write(_ project: Project, to url: URL) throws { try writer(project, url) }
    public func read(_ url: URL) throws -> Project { try reader(url) }

    public func recover(_ candidate: RecoveryCandidate, scanner: RecoveryScanner) throws -> Project {
        try scanner.recover(candidate)
    }

    @discardableResult
    public func autosave(_ project: Project, store: AutosaveStore, date: Date) throws -> AutosaveVersion {
        try store.write(project, date: date)
    }
}
