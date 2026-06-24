import Foundation
import SwiftData
import Security

/// Builds the three-store SwiftData container: history + metrics are local-only,
/// the dictionary store optionally syncs via CloudKit in production.
public enum PersistenceController {

    /// - Parameters:
    ///   - localBuild: when true, the dictionary store is local-only (no CloudKit).
    ///   - directory: store location; defaults to `~/Library/Application Support/Whisp`.
    ///
    // VERIFY-DATA-1: confirm `ModelConfiguration(_:schema:url:cloudKitDatabase:)` labels and the
    // `CloudKitDatabase` case names on the macOS 26.5 SDK, plus that one ModelContainer accepts a
    // mixed CloudKit + local-only configuration set. The host SDK build is the source of truth.
    public static func makeContainer(
        localBuild: Bool = BuildConfig.isLocalBuild,
        directory: URL? = nil
    ) throws -> ModelContainer {
        let dir = try directory ?? AppConstants.applicationSupportDirectory()

        let historyConfig = ModelConfiguration(
            "history",
            schema: Schema([Transcription.self]),
            url: dir.appendingPathComponent("transcriptions.store"),
            cloudKitDatabase: .none)

        let metricsConfig = ModelConfiguration(
            "metrics",
            schema: Schema([SessionMetric.self]),
            url: dir.appendingPathComponent("metrics.store"),
            cloudKitDatabase: .none)

        let conferenceConfig = ModelConfiguration(
            "conferences",
            schema: Schema([Conference.self]),
            url: dir.appendingPathComponent("conferences.store"),
            cloudKitDatabase: .none)

        // CloudKit only when explicitly enabled AND the iCloud entitlement is actually present —
        // CloudKit setup crashes (not throws) on its own queue otherwise, so this can't be try/catch.
        let useCloudKit = !localBuild && Self.hasICloudEntitlement()
        let dictionaryConfig = ModelConfiguration(
            "dictionary",
            schema: Schema([DictionaryEntry.self]),
            url: dir.appendingPathComponent("dictionary.store"),
            cloudKitDatabase: useCloudKit ? .private(AppConstants.cloudKitContainerIdentifier) : .none)

        return try ModelContainer(
            for: Transcription.self, SessionMetric.self, DictionaryEntry.self, Conference.self,
            configurations: historyConfig, metricsConfig, dictionaryConfig, conferenceConfig)
    }

    /// True only when the process carries a `com.apple.developer.icloud-services` entitlement
    /// that includes CloudKit. Guards against CloudKit's async setup crash on builds without
    /// P3 (container id) + the iCloud entitlement.
    private static func hasICloudEntitlement() -> Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-services" as CFString, nil),
              let services = value as? [String]
        else { return false }
        return services.contains { $0.hasPrefix("CloudKit") }
    }
}
