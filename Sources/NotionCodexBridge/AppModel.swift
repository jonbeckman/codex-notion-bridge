import AppKit
import Foundation
import NotionCodexBridgeCore
import SwiftUI

@MainActor
final class RelayAppModel: ObservableObject {
    @Published var config: AppConfig
    @Published var snapshot: RelaySnapshot
    @Published var serverError: String?
    @Published var tunnelError: String?
    @Published var notionTokenInput = ""
    @Published var webhookTokenInput = ""
    @Published var tunnelTokenInput = ""

    let paths: AppPaths
    private let configStore: AppConfigStore
    private let secretStore: SecretStoring
    private let eventStore: EventStore
    private let processor: WebhookProcessor
    private let tunnelManager: CloudflaredTunnelManager
    private var server: LocalHTTPServer?
    private var refreshTask: Task<Void, Never>?

    init() {
        self.paths = AppPaths()
        try? paths.ensure()

        self.configStore = AppConfigStore(url: paths.configURL)
        self.config = configStore.load()
        self.secretStore = KeychainStore()
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
            refreshNow()
        } catch {
            serverError = error.localizedDescription
        }
    }

    func saveNotionToken() {
        saveSecret(.notionAPIToken, notionTokenInput)
        notionTokenInput = ""
    }

    func saveWebhookToken() {
        saveSecret(.notionWebhookVerificationToken, webhookTokenInput)
        webhookTokenInput = ""
    }

    func saveTunnelToken() {
        saveSecret(.cloudflareTunnelToken, tunnelTokenInput)
        tunnelTokenInput = ""
    }

    func openSupportFolder() {
        NSWorkspace.shared.open(paths.root)
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

    private func saveSecret(_ key: SecretKey, _ value: String) {
        do {
            try secretStore.set(value.trimmingCharacters(in: .whitespacesAndNewlines), for: key)
            refreshNow()
        } catch {
            serverError = error.localizedDescription
        }
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
