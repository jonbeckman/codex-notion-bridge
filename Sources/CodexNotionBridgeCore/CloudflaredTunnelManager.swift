import Foundation

public final class CloudflaredTunnelManager: @unchecked Sendable {
    private let secretStore: SecretStoring
    private let lock = NSLock()
    private var process: Process?

    public init(secretStore: SecretStoring) {
        self.secretStore = secretStore
    }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return process?.isRunning == true
    }

    public func start(config: AppConfig) throws {
        lock.lock()
        defer { lock.unlock() }

        if process?.isRunning == true {
            return
        }

        let token = try secretStore.get(.cloudflareTunnelToken)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let tunnelName = config.cloudflareTunnelName.trimmingCharacters(in: .whitespacesAndNewlines)

        var arguments = ["tunnel", "--no-autoupdate", "run"]
        if let token, !token.isEmpty {
            arguments.append(contentsOf: ["--token", token])
        } else if !tunnelName.isEmpty {
            arguments.append(tunnelName)
        } else {
            throw RelayError.configuration("Set a Cloudflare tunnel name or tunnel token first.")
        }

        let process = Process()
        let launch = ProcessLaunch.executableAndArguments(command: config.cloudflaredPath, arguments: arguments)
        process.executableURL = launch.0
        process.arguments = launch.1
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        self.process = process
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        process?.terminate()
        process = nil
    }
}
