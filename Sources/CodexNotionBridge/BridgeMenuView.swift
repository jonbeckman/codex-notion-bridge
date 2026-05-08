import AppKit
import CodexNotionBridgeCore
import SwiftUI

struct BridgeMenuView: View {
    @EnvironmentObject private var model: RelayAppModel
    @State private var showsNotionToken = false
    @State private var showsWebhookToken = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            webhookURLSummary
            stats
            jobList
            Divider()
            settings
            debugSection
            controls
        }
        .padding(16)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading) {
                Text("Codex Notion Bridge")
                    .font(.headline)
                Text(lastEventText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Circle()
                .fill(model.snapshot.serverRunning ? .green : .red)
                .frame(width: 10, height: 10)
        }
    }

    private var webhookURLSummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Webhook URL")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(model.publicWebhookURLSource)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button("Refresh") { model.refreshTailscaleStatus() }
                Button("Copy") { model.copyWebhookURL() }
                    .disabled(model.publicWebhookURL == nil)
            }
            Text(model.publicWebhookURL ?? "Tailscale MagicDNS unavailable")
                .font(.caption)
                .foregroundStyle(model.publicWebhookURL == nil ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            if let webhookErrorText {
                Text(webhookErrorText)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }

    private var webhookErrorText: String? {
        if let tailscaleSetupError = model.tailscaleSetupError {
            return tailscaleSetupError
        }
        return model.tailscaleError
    }

    private var debugSection: some View {
        DisclosureGroup("Debug") {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                statusRow("Server", model.snapshot.serverRunning ? "Running" : "Stopped")
                statusRow("Webhook", model.snapshot.hasWebhookVerificationToken ? "Verified" : "Unverified")
                statusRow("Tailscale", model.tailscaleStatus?.backendState ?? "Unavailable")
                if let dnsName = model.tailscaleStatus?.dnsName {
                    statusRow("MagicDNS", dnsName)
                }
                if let tailscaleStatus = model.tailscaleStatus {
                    statusRow("MagicDNS enabled", tailscaleStatus.magicDNSEnabled ? "Yes" : "No")
                }
                if let funnelStatus = model.tailscaleFunnelStatus {
                    statusRow("Funnel", funnelStatus.matchesLocalPort ? "Forwarding to local port" : "Not forwarding to local port")
                    if let proxyTarget = funnelStatus.firstProxyTarget {
                        statusRow("Funnel target", proxyTarget)
                    }
                    statusRow("Funnel HTTPS", funnelStatus.hasHTTPS443 ? "Yes" : "No")
                }
                if let serverError = model.serverError {
                    statusRow("Server error", serverError)
                }
                if let tailscaleError = model.tailscaleError {
                    statusRow("Tailscale error", tailscaleError)
                }
                if let tailscaleSetupError = model.tailscaleSetupError {
                    statusRow("Funnel setup error", tailscaleSetupError)
                }
            }
            .font(.caption)
            .padding(.top, 8)
        }
    }

    private func statusRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var stats: some View {
        HStack(spacing: 14) {
            StatView(label: "1h", value: model.snapshot.consumed1h)
            StatView(label: "24h", value: model.snapshot.consumed24h)
            StatView(label: "72h", value: model.snapshot.consumed72h)
            StatView(label: "Done", value: model.snapshot.totalCompleted)
            StatView(label: "Failed", value: model.snapshot.totalFailed)
        }
    }

    private var jobList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Active Threads")
                .font(.subheadline)
                .fontWeight(.semibold)
            if model.snapshot.activeJobs.isEmpty {
                Text("No active jobs")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.snapshot.activeJobs) { job in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(job.pageTitle)
                                .font(.caption)
                                .fontWeight(.semibold)
                                .lineLimit(1)
                            Spacer()
                            Text(job.status.rawValue)
                                .font(.caption2)
                                .foregroundStyle(job.status == .failed ? .red : .secondary)
                        }
                        Text(job.commentText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        HStack {
                            Button("Open Notion") { model.openURL(job.pageURL) }
                                .disabled(job.pageURL == nil)
                            Button("Open Output") { model.openPath(job.workspacePath) }
                            if job.status == .running {
                                Button("Stop") { model.stopJob(job) }
                            }
                            if job.status == .failed || job.status == .stopped {
                                Button("Retry") { model.retryJob(job) }
                            }
                        }
                        .font(.caption2)
                    }
                    .padding(8)
                    .background(.quaternary.opacity(0.25))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 10) {
            configSection
            secretsSection
        }
        .textFieldStyle(.roundedBorder)
    }

    private var configSection: some View {
        DisclosureGroup("Config") {
            VStack(alignment: .leading, spacing: 10) {
                configField(
                    "Local port",
                    status: model.config.localPort == model.savedConfig.localPort ? .set : .changed
                ) {
                    TextField("7676", value: $model.config.localPort, format: .number)
                }

                configField(
                    "Codex path",
                    status: fieldStatus(
                        current: model.config.codexPath,
                        saved: model.savedConfig.codexPath,
                        isRequired: true
                    )
                ) {
                    TextField("codex", text: $model.config.codexPath)
                }

                configField(
                    "Codex model",
                    status: fieldStatus(
                        current: model.config.codexModel,
                        saved: model.savedConfig.codexModel,
                        isRequired: false
                    )
                ) {
                    TextField("optional", text: $model.config.codexModel)
                }

                configField(
                    "Codex profile",
                    status: fieldStatus(
                        current: model.config.codexProfile,
                        saved: model.savedConfig.codexProfile,
                        isRequired: false
                    )
                ) {
                    TextField("optional", text: $model.config.codexProfile)
                }

                configField(
                    "Tailscale CLI",
                    status: fieldStatus(
                        current: model.config.tailscalePath,
                        saved: model.savedConfig.tailscalePath,
                        isRequired: true
                    )
                ) {
                    TextField("tailscale", text: $model.config.tailscalePath)
                }

                HStack {
                    Button("Save Config") { model.saveConfig() }
                    Button("Open Config") { model.openConfigFile() }
                }
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var secretsSection: some View {
        DisclosureGroup("Secrets") {
            VStack(alignment: .leading, spacing: 10) {
                secretField(
                    "Notion API token",
                    text: $model.notionTokenInput,
                    isRevealed: $showsNotionToken,
                    status: fieldStatus(
                        current: model.notionTokenInput,
                        saved: model.savedNotionTokenInput,
                        isRequired: true
                    )
                )

                secretField(
                    "Webhook verification token",
                    text: $model.webhookTokenInput,
                    isRevealed: $showsWebhookToken,
                    status: fieldStatus(
                        current: model.webhookTokenInput,
                        saved: model.savedWebhookTokenInput,
                        isRequired: true
                    )
                )

                Button("Save Secrets") {
                    model.saveSecretsToConfigFile()
                }
                .disabled(!hasSecretChanges)
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func configField<Content: View>(
        _ title: String,
        status: FieldStatus,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            fieldLabel(title, status: status)
            content()
                .frame(maxWidth: .infinity)
        }
    }

    private func secretField(
        _ title: String,
        text: Binding<String>,
        isRevealed: Binding<Bool>,
        status: FieldStatus
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            fieldLabel(title, status: status)
            HStack(spacing: 6) {
                if isRevealed.wrappedValue {
                    TextField(title, text: text)
                } else {
                    SecureField(title, text: text)
                }
                Button {
                    isRevealed.wrappedValue.toggle()
                } label: {
                    Image(systemName: isRevealed.wrappedValue ? "eye.slash" : "eye")
                        .frame(width: 18)
                }
                .buttonStyle(.borderless)
                .help(isRevealed.wrappedValue ? "Hide \(title)" : "Show \(title)")
            }
        }
    }

    private func fieldLabel(_ title: String, status: FieldStatus) -> some View {
        HStack {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Circle()
                .fill(status.color)
                .frame(width: 8, height: 8)
                .padding(.trailing, 4)
                .help(status.label)
        }
    }

    private var hasSecretChanges: Bool {
        normalized(model.notionTokenInput) != normalized(model.savedNotionTokenInput)
            || normalized(model.webhookTokenInput) != normalized(model.savedWebhookTokenInput)
    }

    private func fieldStatus(current: String, saved: String, isRequired: Bool) -> FieldStatus {
        let currentValue = normalized(current)
        if currentValue != normalized(saved) {
            return .changed
        }
        if currentValue.isEmpty {
            return isRequired ? .needsValue : .optional
        }
        return .set
    }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var controls: some View {
        HStack {
            Button(model.snapshot.serverRunning ? "Stop Server" : "Start Server") {
                model.snapshot.serverRunning ? model.stopServer() : model.startServer()
            }
            Button("Open Data") { model.openSupportFolder() }
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
    }

    private var lastEventText: String {
        guard let lastEventAt = model.snapshot.lastEventAt else {
            return "No events received"
        }
        return "Last event \(lastEventAt.formatted(date: .omitted, time: .shortened))"
    }
}

private enum FieldStatus {
    case optional
    case needsValue
    case changed
    case set

    var color: Color {
        switch self {
        case .optional:
            .gray
        case .needsValue:
            .red
        case .changed:
            .yellow
        case .set:
            .green
        }
    }

    var label: String {
        switch self {
        case .optional:
            "Optional"
        case .needsValue:
            "Needs to be set"
        case .changed:
            "Changed since last save"
        case .set:
            "Set"
        }
    }
}

struct StatView: View {
    let label: String
    let value: Int

    var body: some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.title3)
                .fontWeight(.semibold)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 48)
    }
}
