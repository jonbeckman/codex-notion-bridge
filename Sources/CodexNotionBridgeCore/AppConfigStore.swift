import Foundation

public final class AppConfigStore: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()

    public init(url: URL) {
        self.url = url
    }

    public func load() -> AppConfig {
        lock.lock()
        defer { lock.unlock() }

        guard let data = try? Data(contentsOf: url) else {
            return .default
        }

        return (try? JSONDecoder.bridge.decode(AppConfig.self, from: data)) ?? .default
    }

    public func save(_ config: AppConfig) throws {
        lock.lock()
        defer { lock.unlock() }

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder.bridge.encode(config)
        try data.write(to: url, options: [.atomic])
    }
}
