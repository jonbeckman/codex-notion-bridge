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
    @Published var tailscaleError: String?
    @Published var tailscaleSetupError: String?
    @Published var notionTokenInput = ""
    @Published var webhookTokenInput = ""
    @Published private(set) var savedNotionTokenInput = ""
    @Published private(set) var savedWebhookTokenInput = ""
    @Published private(set) var tailscaleStatus: TailscaleStatus?
    @Published private(set) var tailscaleFunnelStatus: TailscaleFunnelStatus?

    let paths: AppPaths
    private let configStore: AppConfigStore
    private let secretStore: SecretStoring
    private let eventStore: EventStore
    private let processor: WebhookProcessor
    private let tailscaleStatusResolver = TailscaleStatusResolver()
    private var server: LocalHTTPServer?
    private var refreshTask: Task<Void, Never>?

    init() {
        self.paths = AppPaths()
        try? paths.ensure()

        self.configStore = AppConfigStore(url: paths.configURL)
        let loadedConfig = configStore.load()
        self.config = loadedConfig
        self.savedConfig = loadedConfig
        self.secretStore = FileSecretStore(url: paths.secretsURL)
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
        self.snapshot = RelaySnapshot(
            serverRunning: false,
            hasNotionToken: false,
            hasWebhookVerificationToken: false,
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
        if config.autoStartServer {
            startServer()
        }
        startTailscaleFunnel()
        startRefreshLoop()
    }

    deinit {
        refreshTask?.cancel()
        server?.stop()
    }

    var menuIcon: String {
        snapshot.serverRunning && snapshot.hasWebhookVerificationToken ? "checkmark.circle" : "exclamationmark.triangle"
    }

    var publicWebhookURL: String? {
        guard tailscaleStatus?.magicDNSEnabled == true, let dnsName = tailscaleStatus?.dnsName else {
            return nil
        }
        return Self.webhookURL(host: dnsName)
    }

    var publicWebhookURLSource: String {
        if tailscaleFunnelStatus?.matchesLocalPort == true {
            return "Funnel OK"
        }
        if tailscaleSetupError != nil {
            return "Funnel setup failed"
        }
        if tailscaleFunnelStatus?.isConfigured == true {
            return "Funnel target mismatch"
        }
        if tailscaleFunnelStatus?.isConfigured == false {
            return "Funnel not configured"
        }
        if tailscaleStatus?.magicDNSEnabled == true, tailscaleStatus?.dnsName?.isEmpty == false {
            return "Tailscale DNS"
        }
        if tailscaleStatus?.magicDNSEnabled == false {
            return "MagicDNS disabled"
        }
        return "Tailscale DNS unavailable"
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

    func saveConfig() {
        do {
            try configStore.save(config)
            savedConfig = config
            refreshTailscaleStatus()
            refreshNow()
        } catch {
            serverError = error.localizedDescription
        }
    }

    func saveSecretsToConfigFile() {
        do {
            let notionToken = notionTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
            let webhookToken = webhookTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)

            try secretStore.set(notionToken, for: .notionAPIToken)
            try secretStore.set(webhookToken, for: .notionWebhookVerificationToken)

            notionTokenInput = notionToken
            webhookTokenInput = webhookToken
            savedNotionTokenInput = notionToken
            savedWebhookTokenInput = webhookToken
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

    func refreshTailscaleStatus() {
        let config = self.config
        let tailscaleStatusResolver = self.tailscaleStatusResolver
        Task.detached(priority: .utility) { [weak self, config, tailscaleStatusResolver] in
            do {
                let status = try tailscaleStatusResolver.status(config: config)
                let funnelStatus = try tailscaleStatusResolver.funnelStatus(config: config)
                await MainActor.run {
                    self?.tailscaleStatus = status
                    self?.tailscaleFunnelStatus = funnelStatus
                    self?.tailscaleError = nil
                }
            } catch {
                await MainActor.run {
                    self?.tailscaleStatus = nil
                    self?.tailscaleFunnelStatus = nil
                    self?.tailscaleError = error.localizedDescription
                }
            }
        }
    }

    func startTailscaleFunnel() {
        let config = self.config
        let tailscaleStatusResolver = self.tailscaleStatusResolver
        tailscaleSetupError = nil
        Task.detached(priority: .utility) { [weak self, config, tailscaleStatusResolver] in
            do {
                try tailscaleStatusResolver.startFunnel(config: config)
                let status = try tailscaleStatusResolver.status(config: config)
                let funnelStatus = try tailscaleStatusResolver.funnelStatus(config: config)
                await MainActor.run {
                    self?.tailscaleStatus = status
                    self?.tailscaleFunnelStatus = funnelStatus
                    self?.tailscaleError = nil
                    self?.tailscaleSetupError = nil
                }
            } catch {
                await MainActor.run {
                    self?.tailscaleSetupError = error.localizedDescription
                    self?.refreshTailscaleStatus()
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
        let secretStore = self.secretStore
        Task.detached(priority: .userInitiated) { [weak self, secretStore] in
            let notionToken = (try? secretStore.get(.notionAPIToken)) ?? ""
            let webhookToken = (try? secretStore.get(.notionWebhookVerificationToken)) ?? ""

            await MainActor.run {
                self?.notionTokenInput = notionToken
                self?.webhookTokenInput = webhookToken
                self?.savedNotionTokenInput = notionToken
                self?.savedWebhookTokenInput = webhookToken
                self?.refreshNow()
            }
        }
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
        let eventStore = self.eventStore
        let secretStore = self.secretStore
        let serverRunning = server?.isRunning == true
        Task.detached(priority: .utility) { [weak self, eventStore, secretStore, serverRunning] in
            let hasNotionToken = ((try? secretStore.get(.notionAPIToken)) ?? nil)?.isEmpty == false
            let hasWebhookVerificationToken = ((try? secretStore.get(.notionWebhookVerificationToken)) ?? nil)?.isEmpty == false
            let next = await eventStore.snapshot(
                serverRunning: serverRunning,
                hasNotionToken: hasNotionToken,
                hasWebhookVerificationToken: hasWebhookVerificationToken
            )
            await MainActor.run {
                self?.snapshot = next
            }
        }
    }
}
