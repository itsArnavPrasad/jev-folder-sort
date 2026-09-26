import AppKit
import JevFolderSortCore
import SwiftUI

@main
enum Entry {
    static func main() {
        if CommandLine.arguments.contains("--headless") {
            Headless.run(CommandLine.arguments)  // never returns
        }
        JevFolderSortApp.main()
    }
}

struct JevFolderSortApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            PopoverView().environmentObject(model)
                .onAppear { delegate.model = model }
        } label: {
            Image(systemName: model.isSorting ? "tray.and.arrow.down.fill" : "tray.full")
                .onAppear { delegate.showOnboardingIfNeeded(model) }
        }
        .menuBarExtraStyle(.window)

        Window("jev-folder-sort", id: "main") {
            MainWindow().environmentObject(model)
        }
        .defaultSize(width: 900, height: 560)

        Settings {
            SettingsView().environmentObject(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    private var onboarding: NSWindow?

    @MainActor func showOnboardingIfNeeded(_ model: AppModel) {
        self.model = model
        guard model.needsOnboarding, onboarding == nil else { return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Welcome to jev-folder-sort"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: OnboardingView { [weak self] in
            self?.onboarding?.close()
            self?.onboarding = nil
        }.environmentObject(model))
        window.center()
        onboarding = window
        bringToFront()
        window.makeKeyAndOrderFront(nil)
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
