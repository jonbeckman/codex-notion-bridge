import AppKit
import CodexNotionBridgeCore
import SwiftUI

struct BridgeMenuView: View {
    @EnvironmentObject private var model: RelayAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            statusGrid
            stats
            jobList
            Divider()
            settings
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

    private var statusGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
            statusRow("Server", model.snapshot.serverRunning ? "Running" : "Stopped")
            statusRow("Tunnel", model.snapshot.tunnelRunning ? "Running" : "Stopped")
            statusRow("Notion token", model.snapshot.hasNotionToken ? "Set" : "Missing")
            statusRow("Webhook", model.snapshot.hasWebhookVerificationToken ? "Verified" : "Unverified")
            if let serverError = model.serverError {
                statusRow("Server error", serverError)
            }
            if let tunnelError = model.tunnelError {
                statusRow("Tunnel error", tunnelError)
            }
        }
        .font(.caption)
    }

    private func statusRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .lineLimit(2)
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
        DisclosureGroup("Settings") {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Local port") {
                    TextField("8787", value: $model.config.localPort, format: .number)
                        .frame(width: 90)
                }
                LabeledContent("Codex path") {
                    TextField("codex", text: $model.config.codexPath)
                        .frame(width: 240)
                }
                LabeledContent("Codex model") {
                    TextField("optional", text: $model.config.codexModel)
                        .frame(width: 240)
                }
                LabeledContent("Codex profile") {
                    TextField("optional", text: $model.config.codexProfile)
                        .frame(width: 240)
                }
                LabeledContent("cloudflared") {
                    TextField("cloudflared", text: $model.config.cloudflaredPath)
                        .frame(width: 240)
                }
                LabeledContent("Tunnel name") {
                    TextField("name", text: $model.config.cloudflareTunnelName)
                        .frame(width: 240)
                }
                LabeledContent("Public host") {
                    TextField("https://...", text: $model.config.publicWebhookHostname)
                        .frame(width: 240)
                }
                Button("Save Config") { model.saveConfig() }
                Button("Open Config") { model.openConfigFile() }

                SecureField("Notion API token", text: $model.notionTokenInput)
                Button("Save Notion Token") { model.saveNotionToken() }
                    .disabled(model.notionTokenInput.isEmpty)

                SecureField("Webhook verification token", text: $model.webhookTokenInput)
                Button("Save Webhook Token") { model.saveWebhookToken() }
                    .disabled(model.webhookTokenInput.isEmpty)

                SecureField("Cloudflare tunnel token", text: $model.tunnelTokenInput)
                Button("Save Tunnel Token") { model.saveTunnelToken() }
                    .disabled(model.tunnelTokenInput.isEmpty)
            }
            .textFieldStyle(.roundedBorder)
            .padding(.top, 8)
        }
    }

    private var controls: some View {
        HStack {
            Button(model.snapshot.serverRunning ? "Stop Server" : "Start Server") {
                model.snapshot.serverRunning ? model.stopServer() : model.startServer()
            }
            Button(model.snapshot.tunnelRunning ? "Stop Tunnel" : "Start Tunnel") {
                model.snapshot.tunnelRunning ? model.stopTunnel() : model.startTunnel()
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
