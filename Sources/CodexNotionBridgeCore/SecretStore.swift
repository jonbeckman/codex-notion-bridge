import Foundation

public protocol SecretStoring: Sendable {
    func get(_ key: SecretKey) throws -> String?
    func set(_ value: String, for key: SecretKey) throws
    func delete(_ key: SecretKey) throws
}

public final class FileSecretStore: SecretStoring, @unchecked Sendable {
    private let url: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private var isLoaded = false
    private var values: [SecretKey: String] = [:]

    public init(url: URL, fileManager: FileManager = .default) {
        self.url = url
        self.fileManager = fileManager
    }

    public func get(_ key: SecretKey) throws -> String? {
        try lock.withLock {
            try loadIfNeededLocked()
            return values[key]
        }
    }

    public func set(_ value: String, for key: SecretKey) throws {
        try lock.withLock {
            try loadIfNeededLocked()
            values[key] = value
            try saveLoadedValues()
        }
    }

    public func delete(_ key: SecretKey) throws {
        try lock.withLock {
            try loadIfNeededLocked()
            values.removeValue(forKey: key)
            try saveLoadedValues()
        }
    }

    private func loadIfNeededLocked() throws {
        guard !isLoaded else { return }
        if fileManager.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            let stored = try JSONDecoder.bridge.decode([String: String].self, from: data)
            values = Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in
                guard let secretKey = SecretKey(rawValue: key) else {
                    return nil
                }
                return (secretKey, value)
            })
        } else {
            values = [:]
        }
        isLoaded = true
    }

    private func saveLoadedValues() throws {
        let pairs: [(String, String)] = values.compactMap { key, value in
            return (key.rawValue, value)
        }
        let stored = Dictionary(uniqueKeysWithValues: pairs)
        let data = try JSONEncoder.bridge.encode(stored)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: url.path) {
            _ = fileManager.createFile(atPath: url.path, contents: Data(), attributes: [.posixPermissions: 0o600])
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try data.write(to: url)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
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
