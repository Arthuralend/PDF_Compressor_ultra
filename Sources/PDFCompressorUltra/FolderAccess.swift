import AppKit
import Foundation

/// Write access to folders under the App Sandbox (Mac App Store build).
/// The sandboxed app may read the PDFs the user opened, but may write only to
/// folders the user explicitly granted. Grants are kept as security-scoped
/// bookmarks, so the user is asked once per folder. Outside the sandbox
/// (the DMG build) every check simply succeeds.
@MainActor
final class FolderAccess {
    static let shared = FolderAccess()

    let isSandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    private let key = "folderBookmarks"
    private var bookmarks: [String: Data] = [:]
    private var accessing: [String: URL] = [:]

    private init() {
        let stored = UserDefaults.standard.dictionary(forKey: key) as? [String: Data] ?? [:]
        for (_, data) in stored { restore(data) }
        save()
    }

    private func restore(_ data: Data) {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope],
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else { return }
        if url.startAccessingSecurityScopedResource() { accessing[url.path] = url }
        if stale, let fresh = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil,
                                                     relativeTo: nil) {
            bookmarks[url.path] = fresh
        } else {
            bookmarks[url.path] = data
        }
    }

    private func save() {
        UserDefaults.standard.set(bookmarks, forKey: key)
    }

    /// Remembers a folder the user picked in an open panel.
    func remember(_ url: URL) {
        guard isSandboxed else { return }
        if accessing[url.path] == nil, url.startAccessingSecurityScopedResource() { accessing[url.path] = url }
        if let data = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil,
                                            relativeTo: nil) {
            bookmarks[url.path] = data
            save()
        }
    }

    /// Whether a file can really be created in `dir` (the sandbox is checked too).
    func canWrite(_ dir: URL) -> Bool {
        let probe = dir.appendingPathComponent(".pdfcu-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: probe.path, contents: Data()) else { return false }
        try? FileManager.default.removeItem(at: probe)
        return true
    }

    /// Returns a writable folder: `dir` itself, or the folder the user picked when
    /// asked for permission. nil when the user cancelled.
    func writableFolder(for dir: URL) -> URL? {
        if canWrite(dir) { return dir }
        let panel = NSOpenPanel()
        panel.directoryURL = dir
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Разрешить"
        panel.message = "Чтобы сохранить сжатые файлы в папку «\(dir.lastPathComponent)», разрешите доступ к ней "
            + "(нажмите «Разрешить») или выберите другую папку. Разрешение запоминается."
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        remember(url)
        return canWrite(url) ? url : nil
    }
}
