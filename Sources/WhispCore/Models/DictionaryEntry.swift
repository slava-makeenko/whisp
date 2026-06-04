import Foundation
import SwiftData

/// User dictionary entry. The **only** CloudKit-synced model (`dictionary.store`).
///
/// CloudKit schema rules applied here:
///  • every attribute is optional **or** has a default,
///  • no `@Attribute(.unique)` / unique constraints,
///  • a no-arg `init()` exists so CloudKit can materialize records.
@Model
public final class DictionaryEntry {
    public var id: UUID = UUID()             // defaulted, not unique → CloudKit-safe identity
    public var term: String = ""
    public var replacement: String = ""      // "" → pronunciation hint only
    public var isEnabled: Bool = true
    public var createdAt: Date = Date.now

    public init() {}

    public init(term: String, replacement: String = "", isEnabled: Bool = true) {
        self.term = term
        self.replacement = replacement
        self.isEnabled = isEnabled
    }
}
