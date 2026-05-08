import Darwin
import Foundation

public struct TailscaleStatus: Equatable, Sendable {
    public var backendState: String?
    public var dnsName: String?
    public var magicDNSEnabled: Bool
}

public struct TailscaleFunnelStatus: Equatable, Sendable {
    public var webHosts: [String]
    public var proxyTargets: [String]
    public var hasHTTPS443: Bool
    public var matchesLocalPort: Bool

    public var isConfigured: Bool {
        !webHosts.isEmpty && !proxyTargets.isEmpty
    }

    public var firstProxyTarget: String? {
        proxyTargets.first
    }
}

public final class TailscaleStatusResolver: @unchecked Sendable {
    private static let defaultTimeout: TimeInterval = 10
    private static let tailscaleAppExecutable = "/Applications/Tailscale.app/Contents/MacOS/tailscale"

    public init() {}

    public func status(config: AppConfig) throws -> TailscaleStatus {
        let data = try runTailscale(command: config.tailscalePath, arguments: ["status", "--json"])
        return try Self.status(from: data)
    }

    public func funnelStatus(config: AppConfig) throws -> TailscaleFunnelStatus {
        let data = try runTailscale(command: config.tailscalePath, arguments: ["funnel", "status", "--json"])
        return try Self.funnelStatus(from: data, localPort: config.localPort)
    }

    public func startFunnel(config: AppConfig) throws {
        _ = try runTailscale(
            command: config.tailscalePath,
            arguments: ["funnel", "--bg", "--yes", "\(config.localPort)"]
        )
    }

    public static func status(from data: Data) throws -> TailscaleStatus {
        let root = try JSONDecoder.bridge.decode(JSONValue.self, from: data)
        let rawDNSName = root["Self"]?["DNSName"]?.stringValue ?? ""
        let dnsName = rawDNSName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))

        let magicDNSEnabled: Bool
        if case .bool(let value) = root["CurrentTailnet"]?["MagicDNSEnabled"] {
            magicDNSEnabled = value
        } else {
            magicDNSEnabled = false
        }

        return TailscaleStatus(
            backendState: root["BackendState"]?.stringValue,
            dnsName: dnsName.isEmpty ? nil : dnsName,
            magicDNSEnabled: magicDNSEnabled
        )
    }

    public static func funnelStatus(from data: Data, localPort: UInt16) throws -> TailscaleFunnelStatus {
        let root = try JSONDecoder.bridge.decode(JSONValue.self, from: data)
        let tcp443 = root["TCP"]?["443"]
        let hasHTTPS443: Bool
        if case .bool(let value) = tcp443?["HTTPS"] {
            hasHTTPS443 = value
        } else {
            hasHTTPS443 = false
        }

        let web = root["Web"]?.objectValue ?? [:]
        let webHosts = web.keys.sorted()
        let proxyTargets = web.flatMap { _, hostConfig -> [String] in
            let handlers = hostConfig["Handlers"]?.objectValue ?? [:]
            return handlers.values.compactMap { handler in
                handler["Proxy"]?.stringValue
            }
        }.sorted()

        return TailscaleFunnelStatus(
            webHosts: webHosts,
            proxyTargets: proxyTargets,
            hasHTTPS443: hasHTTPS443,
            matchesLocalPort: proxyTargets.contains { proxyTarget($0, matchesLocalPort: localPort) }
        )
    }

    private static func proxyTarget(_ target: String, matchesLocalPort localPort: UInt16) -> Bool {
        guard let components = URLComponents(string: target),
              let host = components.host,
              components.port == Int(localPort) else {
            return false
        }

        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    private func runTailscale(command: String, arguments: [String]) throws -> Data {
        let process = Process()
        let launch = tailscaleExecutableAndArguments(command: command, arguments: arguments)
        let stdout = Pipe()
        let stderr = Pipe()
        let completed = DispatchSemaphore(value: 0)

        process.executableURL = launch.0
        process.arguments = launch.1
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        process.terminationHandler = { _ in
            completed.signal()
        }

        try process.run()
        if completed.wait(timeout: .now() + Self.defaultTimeout) == .timedOut {
            process.terminate()
            if completed.wait(timeout: .now() + .seconds(1)) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = completed.wait(timeout: .now() + .seconds(1))
            }
            let output = stdout.fileHandleForReading.readDataToEndOfFile()
            let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
            throw RelayError.configuration(
                "tailscale command timed out after \(Int(Self.defaultTimeout))s: \(Self.processMessage(output: output, errorOutput: errorOutput))"
            )
        }

        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            throw RelayError.configuration("tailscale command failed: \(Self.processMessage(output: output, errorOutput: errorOutput))")
        }

        return output
    }

    private func tailscaleExecutableAndArguments(command: String, arguments: [String]) -> (URL, [String]) {
        if (command == "tailscale" || command == "/usr/local/bin/tailscale"),
           FileManager.default.isExecutableFile(atPath: Self.tailscaleAppExecutable) {
            return (URL(fileURLWithPath: Self.tailscaleAppExecutable), arguments)
        }

        return ProcessLaunch.executableAndArguments(command: command, arguments: arguments)
    }

    private static func processMessage(output: Data, errorOutput: Data) -> String {
        let parts = [errorOutput, output]
            .compactMap { String(data: $0, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? "Unknown tailscale error." : parts.joined(separator: "\n")
    }
}
