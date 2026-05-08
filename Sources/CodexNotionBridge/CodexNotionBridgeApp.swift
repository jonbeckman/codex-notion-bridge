import AppKit
import CodexNotionBridgeCore
import SwiftUI

@main
struct CodexNotionBridgeApp: App {
    @StateObject private var model = RelayAppModel()

    var body: some Scene {
        MenuBarExtra("Codex Notion Bridge", systemImage: model.menuIcon) {
            BridgeMenuView()
                .environmentObject(model)
                .frame(width: 420)
        }
        .menuBarExtraStyle(.window)
    }
}
