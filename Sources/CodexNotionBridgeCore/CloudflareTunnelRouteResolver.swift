import Foundation

public final class CloudflareTunnelRouteResolver: @unchecked Sendable {
    private let urlSession: URLSession

    public init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    public func firstHostname(config: AppConfig, apiToken: String) async throws -> String? {
        let tunnelName = config.cloudflareTunnelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let accountID = config.cloudflareAccountID.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !tunnelName.isEmpty else {
            return nil
        }
        guard !accountID.isEmpty else {
            throw RelayError.configuration("Set a Cloudflare account ID to read tunnel routes.")
        }
        guard !token.isEmpty else {
            throw RelayError.missingSecret(.cloudflareAPIToken)
        }

        let tunnelsData = try runCloudflared(
            command: config.cloudflaredPath,
            arguments: ["tunnel", "list", "-o", "json", "--name", tunnelName]
        )
        guard let tunnelID = try Self.tunnelID(from: tunnelsData, named: tunnelName) else {
            throw RelayError.configuration("Could not find Cloudflare tunnel named \(tunnelName).")
        }

        return try await firstHostname(accountID: accountID, tunnelID: tunnelID, apiToken: token)
    }

    private func firstHostname(accountID: String, tunnelID: String, apiToken: String) async throws -> String? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.cloudflare.com"
        components.path = "/client/v4/accounts/\(accountID)/zerotrust/routes/hostname"
        components.queryItems = [
            URLQueryItem(name: "tunnel_id", value: tunnelID),
            URLQueryItem(name: "is_deleted", value: "false"),
            URLQueryItem(name: "per_page", value: "1000")
        ]

        guard let url = components.url else {
            throw RelayError.configuration("Could not build Cloudflare hostname routes URL.")
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RelayError.configuration("Cloudflare hostname routes response was not HTTP.")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw RelayError.configuration("Cloudflare hostname routes request failed with HTTP \(httpResponse.statusCode): \(body)")
        }

        return try Self.firstHostnameRoute(from: data)
    }

    private func runCloudflared(command: String, arguments: [String]) throws -> Data {
        let process = Process()
        let launch = ProcessLaunch.executableAndArguments(command: command, arguments: arguments)
        let stdout = Pipe()
        let stderr = Pipe()

        process.executableURL = launch.0
        process.arguments = launch.1
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let errorMessage = String(data: errorOutput, encoding: .utf8) ?? "Unknown cloudflared error."
            throw RelayError.configuration("cloudflared tunnel list failed: \(errorMessage.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        return output
    }

    static func tunnelID(from data: Data, named tunnelName: String) throws -> String? {
        let root = try JSONDecoder.bridge.decode(JSONValue.self, from: data)
        let tunnels = root.arrayValue ?? []
        let exactMatch = tunnels.first { tunnel in
            tunnel["name"]?.stringValue == tunnelName
        }

        return (exactMatch ?? tunnels.first)?["id"]?.stringValue
    }

    static func firstHostnameRoute(from data: Data) throws -> String? {
        let root = try JSONDecoder.bridge.decode(JSONValue.self, from: data)
        let routes = root["result"]?.arrayValue ?? []

        return routes.first { route in
            route["deleted_at"] == .null || route["deleted_at"] == nil
        }?["hostname"]?.stringValue
    }
}
