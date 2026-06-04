import Foundation
import SwiftData

/// Productivity metric sample. Local-only store (`metrics.store`); isolated from history
/// so high-frequency metric writes don't contend with history queries.
@Model
public final class SessionMetric {
    public var date: Date = Date.now
    public var wordsDictated: Int = 0
    public var keystrokesSaved: Int = 0
    public var activeSeconds: Int = 0
    public var wpm: Double = 0

    public init() {}

    public init(date: Date = .now, wordsDictated: Int = 0, keystrokesSaved: Int = 0,
                activeSeconds: Int = 0, wpm: Double = 0) {
        self.date = date
        self.wordsDictated = wordsDictated
        self.keystrokesSaved = keystrokesSaved
        self.activeSeconds = activeSeconds
        self.wpm = wpm
    }
}
