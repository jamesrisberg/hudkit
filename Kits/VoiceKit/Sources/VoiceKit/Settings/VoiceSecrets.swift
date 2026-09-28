import Foundation
import Security

/// Where voice secrets live: the Keychain in an app, memory in tests.
public protocol VoiceSecretStoring: AnyObject {
    func string(forKey key: String) -> String?
    /// An empty value deletes the secret.
    func set(_ value: String, forKey key: String)
}

public enum VoiceSecrets {
    /// The xAI API key used by `GrokVoice`.
    public static let grokAPIKey = "voice.grokAPIKey"
}

/// Generic passwords under one Keychain service (the host's bundle identifier, say).
public final class KeychainVoiceSecretStore: VoiceSecretStoring {
    public let service: String

    public init(service: String) { self.service = service }

    public func string(forKey key: String) -> String? {
        var query = baseQuery(key: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func set(_ value: String, forKey key: String) {
        if value.isEmpty {
            SecItemDelete(baseQuery(key: key) as CFDictionary)
            return
        }
        let data = Data(value.utf8)
        let attributes = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery(key: key) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var query = baseQuery(key: key)
            query[kSecValueData as String] = data
            SecItemAdd(query as CFDictionary, nil)
        }
    }

    private func baseQuery(key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }
}

public final class InMemoryVoiceSecretStore: VoiceSecretStoring {
    public private(set) var values: [String: String]

    public init(_ values: [String: String] = [:]) { self.values = values }

    public func string(forKey key: String) -> String? { values[key] }

    public func set(_ value: String, forKey key: String) {
        values[key] = value.isEmpty ? nil : value
    }
}
