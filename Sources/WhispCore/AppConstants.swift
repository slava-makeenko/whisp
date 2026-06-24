import Foundation

public enum AppConstants: Sendable {
    /// The app's signing bundle identifier (matches `PRODUCT_BUNDLE_IDENTIFIER` in project.yml).
    public static let bundleIdentifier = "com.slavamakeenko.whisp"

    /// P3: real iCloud container provisioning still pending. Used only outside `LOCAL_BUILD`.
    public static let cloudKitContainerIdentifier = "iCloud.com.slavamakeenko.whisp"

    /// `~/Library/Application Support/Whisp`, created on demand. Home of the three stores.
    public static func applicationSupportDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("Whisp", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `~/Library/Application Support/Whisp/ConferenceRecordings`, created on demand. Holds the
    /// `.m4a` files recorded by Conference Mode.
    public static func conferenceRecordingsDirectory() throws -> URL {
        let dir = try applicationSupportDirectory().appendingPathComponent("ConferenceRecordings", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
