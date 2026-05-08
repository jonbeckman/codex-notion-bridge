import AppKit
import Foundation
import CodexNotionBridgeCore
import SwiftUI

enum TailscaleOperationPhase: Equatable {
    case idle
    case validating
    case gatheringMagicDNS
    case startingFunnel
}

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
    @Published private(set) var isTailscaleLoading = false
    @Published private(set) var tailscaleOperationPhase: TailscaleOperationPhase = .idle

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
        onboardingComplete ? "checkmark.circle" : "exclamationmark.triangle"
    }

    var isTailscaleReady: Bool {
        !hasTailscaleConfigChanges
            && snapshot.serverRunning
            && publicWebhookURL != nil
            && tailscaleFunnelStatus?.matchesLocalPort == true
            && tailscaleError == nil
            && tailscaleSetupError == nil
    }

    var isNotionReady: Bool {
        !hasNotionSecretChanges
            && snapshot.hasNotionToken
            && snapshot.hasWebhookVerificationToken
    }

    var isCodexReady: Bool {
        savedConfig.setup.codexConfigured
            && !hasCodexConfigChanges
            && !Self.normalized(savedConfig.codexPath).isEmpty
    }

    var onboardingComplete: Bool {
        isTailscaleReady && isNotionReady && isCodexReady
    }

    var hasTailscaleConfigChanges: Bool {
        config.localPort != savedConfig.localPort
            || Self.normalized(config.tailscalePath) != Self.normalized(savedConfig.tailscalePath)
    }

    var hasCodexConfigChanges: Bool {
        Self.normalized(config.codexPath) != Self.normalized(savedConfig.codexPath)
            || Self.normalized(config.codexModel) != Self.normalized(savedConfig.codexModel)
            || Self.normalized(config.codexProfile) != Self.normalized(savedConfig.codexProfile)
    }

    var hasNotionSecretChanges: Bool {
        Self.normalized(notionTokenInput) != Self.normalized(savedNotionTokenInput)
            || Self.normalized(webhookTokenInput) != Self.normalized(savedWebhookTokenInput)
    }

    var publicWebhookURL: String? {
        guard tailscaleStatus?.magicDNSEnabled == true, let dnsName = tailscaleStatus?.dnsName else {
            return nil
        }
        return Self.webhookURL(host: dnsName)
    }

    var publicWebhookURLSource: String {
        if isTailscaleLoading && publicWebhookURL == nil {
            return tailscaleOperationText
        }
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

    var tailscaleOperationText: String {
        switch tailscaleOperationPhase {
        case .idle:
            "Unavailable"
        case .validating:
            "Validating..."
        case .gatheringMagicDNS:
            "Gathering..."
        case .startingFunnel:
            "Starting..."
        }
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
        saveCodexSettings()
    }

    func saveTailscaleSettings() {
        let previousConfig = savedConfig
        var nextConfig = sanitizedConfig(config)
        nextConfig.setup.codexConfigured = savedConfig.setup.codexConfigured
        do {
            try persistConfig(nextConfig)
            ensureServerAfterSaving(previousConfig: previousConfig, nextConfig: nextConfig)
            startTailscaleFunnel()
        } catch {
            serverError = error.localizedDescription
        }
    }

    func saveCodexSettings() {
        guard !Self.normalized(config.codexPath).isEmpty else {
            serverError = "Codex path is required."
            return
        }

        var nextConfig = sanitizedConfig(config)
        nextConfig.setup.codexConfigured = true
        do {
            try persistConfig(nextConfig)
            refreshNow()
        } catch {
            serverError = error.localizedDescription
        }
    }

    func saveSecretsToConfigFile() {
        saveNotionToken()
    }

    func saveNotionToken() {
        do {
            let notionToken = notionTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)

            try secretStore.set(notionToken, for: .notionAPIToken)

            notionTokenInput = notionToken
            savedNotionTokenInput = notionToken
            refreshNow()
        } catch {
            serverError = error.localizedDescription
        }
    }

    func saveAllSecretsToConfigFile() {
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

    func copyWebhookVerificationToken() {
        let token = Self.normalized(savedWebhookTokenInput).isEmpty ? webhookTokenInput : savedWebhookTokenInput
        guard !Self.normalized(token).isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.normalized(token), forType: .string)
    }

    func refreshTailscaleStatus() {
        let config = self.config
        let tailscaleStatusResolver = self.tailscaleStatusResolver
        setTailscaleOperationPhase(.validating)
        Task.detached(priority: .utility) { [weak self, config, tailscaleStatusResolver] in
            do {
                try tailscaleStatusResolver.validate(config: config)
                await MainActor.run {
                    self?.setTailscaleOperationPhase(.gatheringMagicDNS)
                }
                let status = try tailscaleStatusResolver.status(config: config)
                await MainActor.run {
                    self?.tailscaleStatus = status
                    self?.tailscaleError = nil
                }

                guard status.magicDNSEnabled, status.dnsName != nil else {
                    await MainActor.run {
                        self?.tailscaleFunnelStatus = nil
                        self?.setTailscaleOperationPhase(.idle)
                    }
                    return
                }

                await MainActor.run {
                    self?.setTailscaleOperationPhase(.startingFunnel)
                }
                let funnelStatus = try tailscaleStatusResolver.funnelStatus(config: config)
                await MainActor.run {
                    self?.tailscaleFunnelStatus = funnelStatus
                    self?.tailscaleError = nil
                    self?.setTailscaleOperationPhase(.idle)
                }
            } catch {
                await MainActor.run {
                    self?.tailscaleStatus = nil
                    self?.tailscaleFunnelStatus = nil
                    self?.tailscaleError = error.localizedDescription
                    self?.setTailscaleOperationPhase(.idle)
                }
            }
        }
    }

    func startTailscaleFunnel() {
        let config = self.config
        let tailscaleStatusResolver = self.tailscaleStatusResolver
        tailscaleSetupError = nil
        setTailscaleOperationPhase(.validating)
        Task.detached(priority: .utility) { [weak self, config, tailscaleStatusResolver] in
            do {
                try tailscaleStatusResolver.validate(config: config)
                await MainActor.run {
                    self?.setTailscaleOperationPhase(.gatheringMagicDNS)
                }
                let status = try tailscaleStatusResolver.status(config: config)
                await MainActor.run {
                    self?.tailscaleStatus = status
                    self?.tailscaleError = nil
                }

                guard status.magicDNSEnabled, status.dnsName != nil else {
                    await MainActor.run {
                        self?.tailscaleFunnelStatus = nil
                        self?.tailscaleSetupError = "MagicDNS is disabled or unavailable. Enable MagicDNS in Tailscale before starting Funnel."
                        self?.setTailscaleOperationPhase(.idle)
                    }
                    return
                }

                await MainActor.run {
                    self?.setTailscaleOperationPhase(.startingFunnel)
                }
                try tailscaleStatusResolver.startFunnel(config: config)
                let funnelStatus = try tailscaleStatusResolver.funnelStatus(config: config)
                await MainActor.run {
                    self?.tailscaleFunnelStatus = funnelStatus
                    self?.tailscaleError = nil
                    self?.tailscaleSetupError = nil
                    self?.setTailscaleOperationPhase(.idle)
                }
            } catch {
                await MainActor.run {
                    self?.tailscaleSetupError = error.localizedDescription
                    self?.setTailscaleOperationPhase(.idle)
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

    private func sanitizedConfig(_ config: AppConfig) -> AppConfig {
        var next = config
        next.codexPath = Self.normalized(next.codexPath)
        next.codexModel = Self.normalized(next.codexModel)
        next.codexProfile = Self.normalized(next.codexProfile)
        next.tailscalePath = Self.normalized(next.tailscalePath)
        return next
    }

    private func persistConfig(_ nextConfig: AppConfig) throws {
        try configStore.save(nextConfig)
        config = nextConfig
        savedConfig = nextConfig
    }

    private func ensureServerAfterSaving(previousConfig: AppConfig, nextConfig: AppConfig) {
        let wasRunning = server?.isRunning == true

        if wasRunning && previousConfig.localPort != nextConfig.localPort {
            server?.stop()
            server = nil
            startServer()
            return
        }

        if !wasRunning && nextConfig.autoStartServer {
            startServer()
            return
        }

        refreshNow()
    }

    private func setTailscaleOperationPhase(_ phase: TailscaleOperationPhase) {
        tailscaleOperationPhase = phase
        isTailscaleLoading = phase != .idle
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
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
            let notionToken = (try? secretStore.get(.notionAPIToken)) ?? ""
            let webhookToken = (try? secretStore.get(.notionWebhookVerificationToken)) ?? ""
            let hasNotionToken = !notionToken.isEmpty
            let hasWebhookVerificationToken = !webhookToken.isEmpty
            let next = await eventStore.snapshot(
                serverRunning: serverRunning,
                hasNotionToken: hasNotionToken,
                hasWebhookVerificationToken: hasWebhookVerificationToken
            )
            await MainActor.run {
                guard let self else { return }

                if Self.normalized(self.notionTokenInput) == Self.normalized(self.savedNotionTokenInput) {
                    self.notionTokenInput = notionToken
                }
                if Self.normalized(self.webhookTokenInput) == Self.normalized(self.savedWebhookTokenInput) {
                    self.webhookTokenInput = webhookToken
                }

                self.savedNotionTokenInput = notionToken
                self.savedWebhookTokenInput = webhookToken
                self.snapshot = next
            }
        }
    }
}
