import Foundation

#if !canImport(Darwin)
/// Status code of `MediaError.decodeFailed` where Darwin is missing (Windows: FFmpeg's negative AVERROR values).
public typealias OSStatus = Int32
#endif

public enum MediaError: Error, Sendable { case unreadable, unsupportedCodec(String), decodeFailed(OSStatus), truncated }
