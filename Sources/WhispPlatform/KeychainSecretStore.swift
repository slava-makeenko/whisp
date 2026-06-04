import Foundation
import Security

public enum SecretKey: String, Sendable {
    case llmProviderAPIKey = "llm_provider_api_key"   // OpenAI
    case groqAPIKey = "groq_api_key"
    case openRouterAPIKey = "openrouter_api_key"
    case anthropicAPIKey = "anthropic_api_key"
    case licenseKey = "license_key"
}

public enum KeychainError: Error, Sendable {
    case osStatus(OSStatus)
}

/// Keychain-backed store for the only two secrets in the app: the LLM provider key and
/// the license key. These never appear in settings backups or logs.
public struct KeychainSecretStore: Sendable {
    private let service: String

    public init(service: String = "com.example.whisp.secrets") { // P5: real bundle id
        self.service = service
    }

    public func set(_ value: String?, for key: SecretKey) throws {
        guard let value, let data = value.data(using: .utf8) else {
            try remove(key)
            return
        }
        let query = baseQuery(key)
        let status = SecItemUpdate(query as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var insert = query
            insert[kSecValueData as String] = data
            let add = SecItemAdd(insert as CFDictionary, nil)
            guard add == errSecSuccess else { throw KeychainError.osStatus(add) }
        default:
            throw KeychainError.osStatus(status)
        }
    }

    public func get(_ key: SecretKey) throws -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.osStatus(status)
        }
    }

    public func remove(_ key: SecretKey) throws {
        let status = SecItemDelete(baseQuery(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.osStatus(status)
        }
    }

    private func baseQuery(_ key: SecretKey) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key.rawValue]
    }
}
