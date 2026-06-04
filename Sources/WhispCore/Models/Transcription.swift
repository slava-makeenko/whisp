import Foundation
import SwiftData

/// History record. Local-only store (`transcriptions.store`); never synced.
@Model
public final class Transcription {
    public var id: UUID = UUID()
    public var text: String = ""
    public var createdAt: Date = Date.now
    public var durationMs: Int = 0
    public var backend: String = ""          // TranscriptionBackendID.rawValue
    public var appBundleID: String?          // capture context (for metrics / Power Mode)
    public var wordCount: Int = 0

    public init() {}

    public init(text: String, createdAt: Date = .now, durationMs: Int = 0,
                backend: String = "", appBundleID: String? = nil) {
        self.text = text
        self.createdAt = createdAt
        self.durationMs = durationMs
        self.backend = backend
        self.appBundleID = appBundleID
        self.wordCount = text.split(whereSeparator: \.isWhitespace).count
    }
}
