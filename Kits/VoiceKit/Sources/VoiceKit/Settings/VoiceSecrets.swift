import Foundation
import Security

/// Where voice secrets live: the Keychain in an app, memory in tests.
public protocol VoiceSecretStoring: AnyObject {
    func string(forKey key: String) -> String?
    /// An empty value deletes the secret. Throws when the store refuses the change.
    func set(_ value: String, forKey key: String) throws
}

public enum VoiceSecrets {
    /// The xAI API key used by `GrokVoice`.
    public static let grokAPIKey = "voice.grokAPIKey"
}

/// Generic passwords under one Keychain service (the host's bundle identifier, say), readable
/// after the first unlock and never synced or migrated to another device.
public final class KeychainVoiceSecretStore: VoiceSecretStoring {
    public struct Failure: LocalizedError, Equatable {
        public let status: OSStatus
        public var errorDescription: String? {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
            return "The Keychain refused the change: \(message)"
        }
    }

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

    public func set(_ value: String, forKey key: String) throws {
        if value.isEmpty {
            try Self.check(SecItemDelete(baseQuery(key: key) as CFDictionary), allowing: errSecItemNotFound)
            return
        }
        let data = Data(value.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(baseQuery(key: key) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            try Self.check(SecItemAdd(addAttributes(key: key, data: data) as CFDictionary, nil))
        } else {
            try Self.check(status)
        }
    }

    static func check(_ status: OSStatus, allowing allowed: OSStatus = errSecSuccess) throws {
        guard status == errSecSuccess || status == allowed else { throw Failure(status: status) }
    }

    func addAttributes(key: String, data: Data) -> [String: Any] {
        var query = baseQuery(key: key)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return query
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
