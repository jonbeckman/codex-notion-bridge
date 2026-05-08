import Foundation
import Security

public protocol SecretStoring: Sendable {
    func get(_ key: SecretKey) throws -> String?
    func set(_ value: String, for key: SecretKey) throws
    func delete(_ key: SecretKey) throws
}

public final class KeychainStore: SecretStoring, @unchecked Sendable {
    private let service: String

    public init(service: String = "NotionCodexBridge") {
        self.service = service
    }

    public func get(_ key: SecretKey) throws -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw RelayError.configuration("Keychain read failed with status \(status).")
        }
        guard let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    public func set(_ value: String, for key: SecretKey) throws {
        let data = Data(value.utf8)
        var query = baseQuery(key)
        query[kSecValueData as String] = data

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(
                baseQuery(key) as CFDictionary,
                [kSecValueData as String: data] as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                throw RelayError.configuration("Keychain update failed with status \(updateStatus).")
            }
            return
        }
        guard status == errSecSuccess else {
            throw RelayError.configuration("Keychain write failed with status \(status).")
        }
    }

    public func delete(_ key: SecretKey) throws {
        let status = SecItemDelete(baseQuery(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw RelayError.configuration("Keychain delete failed with status \(status).")
        }
    }

    private func baseQuery(_ key: SecretKey) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue
        ]
    }
}

public final class InMemorySecretStore: SecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SecretKey: String] = [:]

    public init(values: [SecretKey: String] = [:]) {
        self.values = values
    }

    public func get(_ key: SecretKey) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    public func set(_ value: String, for key: SecretKey) throws {
        lock.lock()
        defer { lock.unlock() }
        values[key] = value
    }

    public func delete(_ key: SecretKey) throws {
        lock.lock()
        defer { lock.unlock() }
        values.removeValue(forKey: key)
    }
}
