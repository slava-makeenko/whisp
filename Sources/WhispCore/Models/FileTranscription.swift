import Foundation
import SwiftData

/// A completed file transcription (audio or video). The transcript lives here; the original file is
/// copied into `AppConstants.fileTranscriptionsDirectory()` so it can be opened or removed
/// independently. Local-only store (`fileTranscriptions.store`); never synced.
@Model
public final class FileTranscription {
    public var id: UUID = UUID()
    public var createdAt: Date = Date.now
    public var title: String = ""
    public var transcript: String = ""
    /// Original display name (e.g. "meeting.mp4"), kept even after the stored file is removed.
    public var originalName: String = ""
    /// File name relative to `AppConstants.fileTranscriptionsDirectory()`; empty once the user
    /// removes the attached file (the transcript stays).
    public var storedFileName: String = ""
    public var wordCount: Int = 0

    public init() {}

    public init(title: String, transcript: String, originalName: String,
                storedFileName: String, createdAt: Date = .now) {
        self.title = title
        self.transcript = transcript
        self.originalName = originalName
        self.storedFileName = storedFileName
        self.createdAt = createdAt
        self.wordCount = transcript.split(whereSeparator: \.isWhitespace).count
    }
}

extension FileTranscription {
    /// Absolute URL of the attached file, or `nil` if it was removed.
    public var fileURL: URL? {
        guard !storedFileName.isEmpty,
              let dir = try? AppConstants.fileTranscriptionsDirectory() else { return nil }
        return dir.appendingPathComponent(storedFileName)
    }
}
