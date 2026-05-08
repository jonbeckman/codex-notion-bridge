import AppKit
import NotionCodexBridgeCore
import SwiftUI

@main
struct NotionCodexBridgeApp: App {
    @StateObject private var model = RelayAppModel()

    var body: some Scene {
        MenuBarExtra("Notion Codex Bridge", systemImage: model.menuIcon) {
            BridgeMenuView()
                .environmentObject(model)
                .frame(width: 420)
        }
        .menuBarExtraStyle(.window)
    }
}
