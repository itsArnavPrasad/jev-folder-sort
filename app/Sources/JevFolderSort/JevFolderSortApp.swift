import AppKit
import JevFolderSortCore
import SwiftUI

@main
struct JevFolderSortApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            PopoverView().environmentObject(model)
        } label: {
            Image(systemName: model.isSorting ? "tray.and.arrow.down.fill" : "tray.full")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environmentObject(model)
        }

        Window("Activity", id: "activity") {
            ActivityView().environmentObject(model)
        }
        .defaultSize(width: 820, height: 480)
    }
}

/// Menu-bar-only apps start behind other windows; bring ours forward.
@MainActor func bringToFront() {
    NSApp.activate(ignoringOtherApps: true)
}

@MainActor func chooseFolder(prompt: String, message: String) -> URL? {
    bringToFront()
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = false
    panel.prompt = prompt
    panel.message = message
    return panel.runModal() == .OK ? panel.url : nil
}
