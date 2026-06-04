import Foundation

public enum AppConstants: Sendable {
    /// P5: replace with the real signing bundle identifier.
    public static let bundleIdentifier = "com.example.whisp"

    /// P3: replace with the real iCloud container id. Used only outside `LOCAL_BUILD`.
    public static let cloudKitContainerIdentifier = "iCloud.com.example.whisp"

    /// `~/Library/Application Support/Whisp`, created on demand. Home of the three stores.
    public static func applicationSupportDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = base.appendingPathComponent("Whisp", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
