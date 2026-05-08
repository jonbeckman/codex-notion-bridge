import AppKit
import Foundation
import CodexNotionBridgeCore
import SwiftUI

@MainActor
final class RelayAppModel: ObservableObject {
    @Published var config: AppConfig
    @Published private(set) var savedConfig: AppConfig
    @Published var snapshot: RelaySnapshot
    @Published var serverError: String?
    @Published var tunnelError: String?
    @Published var notionTokenInput = ""
    @Published var webhookTokenInput = ""
    @Published var tunnelTokenInput = ""
    @Published var cloudflareAPITokenInput = ""
    @Published private(set) var savedNotionTokenInput = ""
    @Published private(set) var savedWebhookTokenInput = ""
    @Published private(set) var savedTunnelTokenInput = ""
    @Published private(set) var savedCloudflareAPITokenInput = ""
    @Published private(set) var tunnelRouteHostname: String?
    @Published var tunnelRouteError: String?

    let paths: AppPaths
    private let configStore: AppConfigStore
    private let secretStore: SecretStoring
    private let eventStore: EventStore
    private let processor: WebhookProcessor
    private let tunnelManager: CloudflaredTunnelManager
    private let tunnelRouteResolver = CloudflareTunnelRouteResolver()
    private var server: LocalHTTPServer?
    private var refreshTask: Task<Void, Never>?

    init() {
        self.paths = AppPaths()
        try? paths.ensure()

        self.configStore = AppConfigStore(url: paths.configURL)
        let loadedConfig = configStore.load()
        self.config = loadedConfig
        self.savedConfig = loadedConfig
        self.secretStore = CachedSecretStore(backing: KeychainStore())
        self.eventStore = EventStore(paths: paths)

        let secretStore = self.secretStore
        let configStore = self.configStore
        let notion = LiveNotionClient(
            tokenProvider: {
                guard let token = try secretStore.get(.notionAPIToken), !token.isEmpty else {
                    throw RelayError.missingSecret(.notionAPIToken)
                }
                return token
            },
            notionVersionProvider: {
                configStore.load().notionVersion
            }
        )
        let codexRunner = LiveCodexRunner()
        self.processor = WebhookProcessor(
            configStore: configStore,
            secretStore: secretStore,
            eventStore: eventStore,
            paths: paths,
            notion: notion,
            codexRunner: codexRunner
        )
        self.tunnelManager = CloudflaredTunnelManager(secretStore: secretStore)
        self.snapshot = RelaySnapshot(
            serverRunning: false,
            tunnelRunning: false,
            hasNotionToken: false,
            hasWebhookVerificationToken: false,
            hasCloudflareTunnelToken: false,
            lastEventAt: nil,
            totalReceived: 0,
            totalIgnored: 0,
            totalFailed: 0,
            totalCompleted: 0,
            consumed1h: 0,
            consumed24h: 0,
            consumed72h: 0,
            activeJobs: []
        )

        loadSecrets()
        refreshTunnelRouteHostname()
        startRefreshLoop()
        if config.autoStartServer {
            startServer()
        }
        if config.autoStartTunnel {
            startTunnel()
        }
    }

    deinit {
        refreshTask?.cancel()
        server?.stop()
        tunnelManager.stop()
    }

    var menuIcon: String {
        snapshot.serverRunning && snapshot.hasWebhookVerificationToken ? "checkmark.circle" : "exclamationmark.triangle"
    }

    var publicWebhookURL: String? {
        let routeHostname = tunnelRouteHostname?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let routeHostname, !routeHostname.isEmpty {
            return Self.webhookURL(host: routeHostname)
        }

        return Self.webhookURL(host: config.publicWebhookHostname)
    }

    var publicWebhookURLSource: String {
        if tunnelRouteHostname?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return "Cloudflare route[0]"
        }
        if publicWebhookURL != nil {
            return "Config public host"
        }
        return "Missing public host"
    }

    func startServer() {
        serverError = nil
        do {
            let server = LocalHTTPServer { [processor] request in
                await processor.handle(request)
            }
            try server.start(port: config.localPort)
            self.server = server
            refreshNow()
        } catch {
            serverError = error.localizedDescription
        }
    }

    func stopServer() {
        server?.stop()
        server = nil
        refreshNow()
    }

    func startTunnel() {
        tunnelError = nil
        do {
            try tunnelManager.start(config: config)
            refreshTunnelRouteHostname()
            refreshNow()
        } catch {
            tunnelError = error.localizedDescription
        }
    }

    func stopTunnel() {
        tunnelManager.stop()
        refreshNow()
    }

    func saveConfig() {
        do {
            try configStore.save(config)
            savedConfig = config
            refreshTunnelRouteHostname()
            refreshNow()
        } catch {
            serverError = error.localizedDescription
        }
    }

    func saveSecretsToKeychain() {
        do {
            let notionToken = notionTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
            let webhookToken = webhookTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
            let tunnelToken = tunnelTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
            let cloudflareAPIToken = cloudflareAPITokenInput.trimmingCharacters(in: .whitespacesAndNewlines)

            try secretStore.set(notionToken, for: .notionAPIToken)
            try secretStore.set(webhookToken, for: .notionWebhookVerificationToken)
            try secretStore.set(tunnelToken, for: .cloudflareTunnelToken)
            try secretStore.set(cloudflareAPIToken, for: .cloudflareAPIToken)

            notionTokenInput = notionToken
            webhookTokenInput = webhookToken
            tunnelTokenInput = tunnelToken
            cloudflareAPITokenInput = cloudflareAPIToken
            savedNotionTokenInput = notionToken
            savedWebhookTokenInput = webhookToken
            savedTunnelTokenInput = tunnelToken
            savedCloudflareAPITokenInput = cloudflareAPIToken
            refreshTunnelRouteHostname()
            refreshNow()
        } catch {
            serverError = error.localizedDescription
        }
    }

    func openSupportFolder() {
        NSWorkspace.shared.open(paths.root)
    }

    func openConfigFile() {
        do {
            if !FileManager.default.fileExists(atPath: paths.configURL.path) {
                try configStore.save(config)
            }
            NSWorkspace.shared.open(paths.configURL)
        } catch {
            serverError = error.localizedDescription
        }
    }

    func copyWebhookURL() {
        guard let publicWebhookURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(publicWebhookURL, forType: .string)
    }

    func refreshTunnelRouteHostname() {
        let config = self.config
        let apiToken = cloudflareAPITokenInput
        let tunnelName = config.cloudflareTunnelName.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !tunnelName.isEmpty else {
            tunnelRouteHostname = nil
            tunnelRouteError = nil
            return
        }

        Task {
            do {
                let hostname = try await tunnelRouteResolver.firstHostname(config: config, apiToken: apiToken)
                await MainActor.run {
                    self.tunnelRouteHostname = hostname
                    self.tunnelRouteError = nil
                }
            } catch {
                await MainActor.run {
                    self.tunnelRouteHostname = nil
                    self.tunnelRouteError = error.localizedDescription
                }
            }
        }
    }

    func openURL(_ string: String?) {
        guard let string, let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }

    func openPath(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func retryJob(_ job: RelayJob) {
        Task {
            do {
                try await processor.retryJob(jobID: job.id)
                refreshNow()
            } catch {
                await MainActor.run {
                    self.serverError = error.localizedDescription
                }
            }
        }
    }

    func stopJob(_ job: RelayJob) {
        Task {
            do {
                try await processor.stopJob(jobID: job.id)
                refreshNow()
            } catch {
                await MainActor.run {
                    self.serverError = error.localizedDescription
                }
            }
        }
    }

    private func loadSecrets() {
        let notionToken = (try? secretStore.get(.notionAPIToken)) ?? ""
        let webhookToken = (try? secretStore.get(.notionWebhookVerificationToken)) ?? ""
        let tunnelToken = (try? secretStore.get(.cloudflareTunnelToken)) ?? ""
        let cloudflareAPIToken = (try? secretStore.get(.cloudflareAPIToken)) ?? ""

        notionTokenInput = notionToken
        webhookTokenInput = webhookToken
        tunnelTokenInput = tunnelToken
        cloudflareAPITokenInput = cloudflareAPIToken
        savedNotionTokenInput = notionToken
        savedWebhookTokenInput = webhookToken
        savedTunnelTokenInput = tunnelToken
        savedCloudflareAPITokenInput = cloudflareAPIToken
    }

    private static func webhookURL(host: String) -> String? {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else {
            return nil
        }

        let hostWithScheme = if trimmedHost.hasPrefix("http://") || trimmedHost.hasPrefix("https://") {
            trimmedHost
        } else {
            "https://\(trimmedHost)"
        }

        let baseURL = hostWithScheme.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let webhookPath = "/notion/webhook"
        if baseURL.hasSuffix(webhookPath) {
            return baseURL
        }
        return "\(baseURL)\(webhookPath)"
    }

    private func startRefreshLoop() {
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refreshNow()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func refreshNow() {
        Task {
            let next = await eventStore.snapshot(
                serverRunning: server?.isRunning == true,
                tunnelRunning: tunnelManager.isRunning,
                hasNotionToken: ((try? secretStore.get(.notionAPIToken)) ?? nil)?.isEmpty == false,
                hasWebhookVerificationToken: ((try? secretStore.get(.notionWebhookVerificationToken)) ?? nil)?.isEmpty == false,
                hasCloudflareTunnelToken: ((try? secretStore.get(.cloudflareTunnelToken)) ?? nil)?.isEmpty == false
            )
            await MainActor.run {
                self.snapshot = next
            }
        }
    }
}
