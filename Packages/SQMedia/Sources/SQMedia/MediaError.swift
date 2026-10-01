import Foundation

public enum MediaError: Error, Sendable { case unreadable, unsupportedCodec(String), decodeFailed(OSStatus), truncated }
