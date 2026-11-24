import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (swift run) instead of an .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Restore folder permissions granted earlier (sandboxed App Store build).
        Task { @MainActor in _ = FolderAccess.shared }
        if NSApp.applicationIconImage == nil || Bundle.main.bundleIdentifier == nil,
           let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let img = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = img
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in AppModel.shared.add(urls: urls) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct PDFCompressorUltraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        WindowGroup("PDF Compressor Ultra") {
            ContentView(model: model)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Открыть PDF…") { model.openPanel() }
                    .keyboardShortcut("o")
            }
            CommandGroup(after: .newItem) {
                Button("Сжать") { model.compressAll() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.isProcessing)
            }
        }
    }
}
