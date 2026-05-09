import AppKit
import CodexNotionBridgeCore
import SwiftUI

struct BridgeMenuView: View {
    @EnvironmentObject private var model: RelayAppModel
    @State private var showsNotionToken = false
    @State private var showsWebhookToken = false
    @State private var tailscaleSettingsExpanded = false
    @State private var notionSettingsExpanded = false
    @State private var completedTailscaleExpanded = false
    @State private var completedNotionExpanded = false
    @State private var configurationExpanded = false
    @State private var showingResetConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                Divider()
                if model.onboardingComplete {
                    dashboard
                    Divider()
                    completedSetup
                } else {
                    setupFlow
                }
                Divider()
                debugSection
                controls
            }
            .padding(16)
        }
        .textFieldStyle(.roundedBorder)
        .onChange(of: model.config.tailscalePath) { _, _ in
            model.scheduleOnboardingTailscaleAutosave()
        }
        .onChange(of: model.config.localPort) { _, _ in
            model.scheduleOnboardingTailscaleAutosave()
        }
        .onChange(of: model.notionTokenInput) { _, _ in
            model.scheduleOnboardingNotionAutosave()
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Codex Notion Bridge")
                    .font(.headline)
                Text(headerDetailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                Text(model.isSetupReady ? "Ready" : "Needs setup")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Circle()
                    .fill(model.isSetupReady ? .green : .yellow)
                    .frame(width: 10, height: 10)
            }
        }
    }

    private var headerDetailText: String {
        if model.onboardingComplete {
            return lastEventText
        }
        if !model.isTailscaleReady {
            return "Tailscale setup required"
        }
        if !model.isNotionReady {
            return "Notion setup required"
        }
        return "Ready"
    }

    private var setupFlow: some View {
        VStack(alignment: .leading, spacing: 12) {
            setupSection(
                title: "Verify Tailscale",
                helpText: tailscaleSetupHelpText,
                status: model.isTailscaleReady ? .complete : .active
            ) {
                tailscaleStepContent
            }

            if model.isTailscaleReady {
                setupSection(
                    title: "Connect Notion",
                    helpText: notionSetupHelpText,
                    status: model.isNotionReady ? .complete : .active
                ) {
                    notionStepContent
                }
            }
        }
    }

    private func setupSection<Content: View>(
        title: String,
        helpText: String,
        status: StepStatus,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                helpIcon(helpText)
                Spacer()
                Label(status.label, systemImage: status.systemImage)
                    .font(.caption2)
                    .foregroundStyle(status.color)
            }
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.18))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var tailscaleStepContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.isTailscaleReady {
                readyLine("Tailscale Funnel ready", systemImage: "network")
                DisclosureGroup("Tailscale Settings", isExpanded: $tailscaleSettingsExpanded) {
                    tailscaleSettingsFields(showManualSave: false)
                        .padding(.top, 8)
                }
            } else {
                tailscaleReadiness
                tailscaleSettingsFields(showManualSave: false)
            }
        }
    }

    private var tailscaleReadiness: some View {
        VStack(alignment: .leading, spacing: 6) {
            compactStatusRow(
                "Tailscale",
                tailscaleBackendText,
                status: model.tailscaleStatus == nil ? .needsValue : .set,
                isLoading: model.tailscaleOperationPhase == .validating
            )
            compactStatusRow(
                "MagicDNS",
                magicDNSText,
                status: model.publicWebhookURL == nil ? .needsValue : .set,
                isLoading: model.tailscaleOperationPhase == .gatheringMagicDNS
            )
            compactStatusRow(
                "Funnel",
                funnelText,
                status: model.tailscaleFunnelStatus?.matchesLocalPort == true ? .set : .needsValue,
                isLoading: model.tailscaleOperationPhase == .startingFunnel
            )
            if let webhookErrorText {
                errorText(webhookErrorText)
            }
        }
    }

    private var notionSetupFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            notionAPITokenField
                .padding(.bottom, 4)
            Divider()
                .padding(.vertical, 2)
            notionWebhookURLRow
            notionVerificationTokenRow
            Link(destination: URL(string: "https://www.notion.so/profile/integrations/internal")!) {
                Label("Open Notion integrations", systemImage: "arrow.up.right.square")
            }
            .font(.caption)
        }
    }

    private var notionAPITokenField: some View {
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
    }

    private var notionWebhookURLRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Webhook URL")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text(model.publicWebhookURL ?? missingWebhookURLText)
                    .font(.caption)
                    .foregroundStyle(model.publicWebhookURL == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Button {
                    model.copyWebhookURL()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .disabled(model.publicWebhookURL == nil)
            }
        }
    }

    private var notionVerificationTokenRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Verification token")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let token = webhookVerificationTokenDisplay {
                HStack(spacing: 6) {
                    Text(token)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Button {
                        model.copyWebhookVerificationToken()
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                }
            } else {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.55)
                        .frame(width: 12, height: 12)
                    Text("Waiting for Notion to send the verification token...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    private func tailscaleSettingsFields(showManualSave: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
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

            configField(
                "Local port",
                status: model.config.localPort == model.savedConfig.localPort ? .set : .changed
            ) {
                TextField("7676", value: $model.config.localPort, format: .number)
            }

            HStack {
                if showManualSave {
                    Button {
                        model.saveTailscaleSettings()
                    } label: {
                        Label("Save & Restart Funnel", systemImage: "arrow.clockwise")
                    }
                    .disabled(normalized(model.config.tailscalePath).isEmpty || model.config.localPort == 0 || model.isTailscaleLoading)
                }

                Button {
                    model.refreshTailscaleStatus()
                } label: {
                    Label("Refresh", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(model.isTailscaleLoading)
            }
        }
    }

    private var notionStepContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.isNotionReady {
                readyLine("Notion connected and webhook verified", systemImage: "lock.fill")
                if model.hasCompletedOnboarding {
                    DisclosureGroup("Notion Settings", isExpanded: $notionSettingsExpanded) {
                        notionSecretFields(showManualSave: true)
                            .padding(.top, 8)
                    }
                }
            } else {
                notionSetupFields
            }
        }
    }

    private func notionSecretFields(showManualSave: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if showManualSave {
                Button {
                    model.saveNotionToken()
                } label: {
                    Label("Save Notion Token", systemImage: "square.and.arrow.down")
                }
                .disabled(!hasNotionAPITokenChanges)
            }
        }
    }

    private func codexConfigFields(showManualSave: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
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

            HStack {
                if showManualSave {
                    Button {
                        model.saveCodexSettings()
                    } label: {
                        Label("Save Codex Settings", systemImage: "square.and.arrow.down")
                    }
                    .disabled(!canSaveCodexSettings)
                }
            }
        }
    }

    private var fileActionButtons: some View {
        HStack(spacing: 8) {
            Button {
                model.openConfigFile()
            } label: {
                Label("Open Config", systemImage: "doc.text")
            }

            Button {
                model.openSecretsFile()
            } label: {
                Label("Open Secrets", systemImage: "lock.doc")
            }
        }
    }

    private var dashboard: some View {
        VStack(alignment: .leading, spacing: 12) {
            stats
            jobList
        }
    }

    private var completedSetup: some View {
        VStack(alignment: .leading, spacing: 8) {
            DisclosureGroup(isExpanded: $completedTailscaleExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    readyLine("Tailscale Funnel ready", systemImage: "network")
                    tailscaleSettingsFields(showManualSave: true)
                }
                .padding(.top, 8)
            } label: {
                sectionHeader("Tailscale", helpText: tailscaleSetupHelpText)
            }
            DisclosureGroup(isExpanded: $completedNotionExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    notionSetupFields
                    notionSecretFields(showManualSave: true)
                }
                .padding(.top, 8)
            } label: {
                sectionHeader("Notion", helpText: notionSetupHelpText)
            }
            DisclosureGroup("Codex", isExpanded: $configurationExpanded) {
                codexConfigFields(showManualSave: true)
                    .padding(.top, 8)
            }
            fileActionButtons
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var debugSection: some View {
        DisclosureGroup("Debug") {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                statusRow("Server", model.snapshot.serverRunning ? "Running" : "Stopped")
                statusRow("Webhook", model.snapshot.hasWebhookVerificationToken ? "Verified" : "Unverified")
                statusRow("Tailscale", tailscaleBackendText)
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
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var jobList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Active Threads")
                .font(.subheadline)
                .fontWeight(.semibold)
            if model.snapshot.activeJobs.isEmpty {
                emptyThreadsState
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

    private var emptyThreadsState: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "text.bubble")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("No active threads")
                    .font(.caption)
                    .fontWeight(.semibold)
                Text("Triggered Notion comments will appear here.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.18))
        .clipShape(RoundedRectangle(cornerRadius: 8))
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

    private func sectionHeader(_ title: String, helpText: String) -> some View {
        HStack(spacing: 5) {
            Text(title)
            helpIcon(helpText)
        }
    }

    private func helpIcon(_ text: String) -> some View {
        Image(systemName: "questionmark.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
            .help(text)
            .accessibilityLabel("Setup instructions")
    }

    private func compactStatusRow(
        _ label: String,
        _ value: String,
        status: FieldStatus,
        isLoading: Bool = false
    ) -> some View {
        HStack(alignment: .center, spacing: 8) {
            ZStack {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.55)
                } else {
                    Circle()
                        .fill(status.color)
                        .frame(width: 9, height: 9)
                }
            }
            .frame(width: 12, height: 12)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func readyLine(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(.green)
    }

    private func errorText(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.red)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }

    private var webhookErrorText: String? {
        if let tailscaleSetupError = model.tailscaleSetupError {
            return tailscaleSetupError
        }
        return model.tailscaleError
    }

    private var webhookVerificationTokenDisplay: String? {
        let saved = normalized(model.savedWebhookTokenInput)
        if !saved.isEmpty {
            return saved
        }
        let current = normalized(model.webhookTokenInput)
        return current.isEmpty ? nil : current
    }

    private var tailscaleBackendText: String {
        if model.tailscaleOperationPhase == .validating {
            return "Validating..."
        }
        return model.tailscaleStatus?.backendState ?? "Unavailable"
    }

    private var magicDNSText: String {
        switch model.tailscaleOperationPhase {
        case .validating:
            return "Waiting"
        case .gatheringMagicDNS:
            return "Gathering..."
        case .idle, .startingFunnel:
            break
        }
        if model.tailscaleStatus?.magicDNSEnabled == false {
            return "Disabled"
        }
        return model.tailscaleStatus?.dnsName ?? "Unavailable"
    }

    private var funnelText: String {
        switch model.tailscaleOperationPhase {
        case .validating, .gatheringMagicDNS:
            return "Waiting"
        case .startingFunnel:
            return "Starting..."
        case .idle:
            break
        }
        if model.isTailscaleLoading && model.tailscaleFunnelStatus == nil {
            return model.tailscaleOperationText
        }
        guard model.tailscaleStatus?.magicDNSEnabled != false else {
            return "Waiting"
        }
        guard let funnelStatus = model.tailscaleFunnelStatus else {
            return "Unavailable"
        }
        if funnelStatus.matchesLocalPort {
            return "Forwarding to \(model.config.localPort)"
        }
        if let proxyTarget = funnelStatus.firstProxyTarget {
            return "Target \(proxyTarget)"
        }
        return "Not configured"
    }

    private var missingWebhookURLText: String {
        model.isTailscaleLoading ? model.tailscaleOperationText : "Tailscale MagicDNS unavailable"
    }

    private var tailscaleSetupHelpText: String {
        """
        1. Sign in to Tailscale and make sure MagicDNS is enabled.
        2. Confirm the Tailscale CLI path and local webhook port.
        3. Let the app configure Funnel for the local webhook port.
        4. Use Refresh after changing Tailscale or Funnel state.
        """
    }

    private var notionSetupHelpText: String {
        """
        1. Create a Notion internal integration.
        2. Give it read and insert comment permissions.
        3. Share the target Notion pages or databases with the integration.
        4. Paste the access token below.
        5. Add the webhook URL below as a Notion webhook subscription.
        6. Copy the verification token back to Notion when it appears.
        """
    }

    private var canSaveCodexSettings: Bool {
        !normalized(model.config.codexPath).isEmpty && model.hasCodexConfigChanges
    }

    private var hasNotionAPITokenChanges: Bool {
        normalized(model.notionTokenInput) != normalized(model.savedNotionTokenInput)
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
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(model.snapshot.serverRunning ? "Stop Server" : "Start Server") {
                    model.snapshot.serverRunning ? model.stopServer() : model.startServer()
                }
                Button(role: .destructive) {
                    showingResetConfirmation = true
                } label: {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .help("Reset configuration and secrets to a fresh install")
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }

            if showingResetConfirmation {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Reset to fresh install?")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") {
                        showingResetConfirmation = false
                    }
                    Button(role: .destructive) {
                        showingResetConfirmation = false
                        model.resetToFreshInstall()
                    } label: {
                        Text("Reset Config & Secrets")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
                .padding(8)
                .background(.red.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var lastEventText: String {
        guard let lastEventAt = model.snapshot.lastEventAt else {
            return "No events received"
        }
        return "Last event \(lastEventAt.formatted(date: .omitted, time: .shortened))"
    }
}

private enum StepStatus {
    case active
    case complete

    var label: String {
        switch self {
        case .active:
            "Current"
        case .complete:
            "Ready"
        }
    }

    var systemImage: String {
        switch self {
        case .active:
            "circle.dotted"
        case .complete:
            "checkmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .active:
            .secondary
        case .complete:
            .green
        }
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
