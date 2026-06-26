import Foundation
import SwiftData

/// A recorded online meeting (Conference Mode). The audio lives on disk as an `.m4a`; this row holds
/// its transcript + metadata. Local-only store (`conferences.store`); never synced.
@Model
public final class Conference {
    public var id: UUID = UUID()
    public var createdAt: Date = Date.now
    public var title: String = ""
    public var transcript: String = ""
    /// File name relative to `AppConstants.conferenceRecordingsDirectory()` — never an absolute URL,
    /// so the store survives the container moving.
    public var audioFileName: String = ""
    public var durationMs: Int = 0
    public var sourceAppBundleID: String?
    public var wordCount: Int = 0
    /// AI summary of the transcript (empty until generated). Default keeps lightweight migration.
    public var summary: String = ""

    public init() {}

    public init(title: String, audioFileName: String, createdAt: Date = .now,
                durationMs: Int = 0, sourceAppBundleID: String? = nil, transcript: String = "") {
        self.title = title
        self.audioFileName = audioFileName
        self.createdAt = createdAt
        self.durationMs = durationMs
        self.sourceAppBundleID = sourceAppBundleID
        self.transcript = transcript
        self.wordCount = transcript.split(whereSeparator: \.isWhitespace).count
    }
}

extension Conference {
    /// Absolute URL of the recording, resolved at read time from the relative file name.
    public var audioURL: URL? {
        guard !audioFileName.isEmpty,
              let dir = try? AppConstants.conferenceRecordingsDirectory() else { return nil }
        return dir.appendingPathComponent(audioFileName)
    }
}
