import AppKit
import Foundation
import PDFCore
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    enum Status: Equatable {
        case pending
        case working(Double, String)
        case done(CompressionReport, URL)
        case failed(String)
        case needsPassword

        static func == (l: Status, r: Status) -> Bool {
            switch (l, r) {
            case (.pending, .pending), (.needsPassword, .needsPassword): return true
            case let (.working(a, b), .working(c, d)): return a == c && b == d
            case let (.done(_, a), .done(_, b)): return a == b
            case let (.failed(a), .failed(b)): return a == b
            default: return false
            }
        }
    }

    struct FileItem: Identifiable {
        let id = UUID()
        let url: URL
        let originalSize: Int
        var status: Status = .pending
        var password: String = ""
        /// Master mode selections (0-based page indices / image object numbers).
        var protectedPages: Set<Int> = []
        var protectedImages: Set<Int> = []
        var protectedCount: Int { protectedPages.count + protectedImages.count }
    }

    enum OutputMode: String, CaseIterable, Identifiable {
        case nextToOriginal, folder
        var id: String { rawValue }
        var title: String {
            switch self {
            case .nextToOriginal: return "Рядом с оригиналом"
            case .folder: return "В выбранную папку"
            }
        }
    }

    @Published var files: [FileItem] = []
    @Published var isProcessing = false
    @Published var passwordRequest: FileItem.ID? = nil
    @Published var masterFile: FileItem.ID? = nil
    @Published var masterMode: Bool { didSet { save() } }

    @Published var preset: CompressionPreset { didSet { save() } }
    @Published var manualDPI: Double { didSet { save() } }
    @Published var manualQuality: Double { didSet { save() } }
    @Published var removeEditorData: Bool { didSet { save() } }
    @Published var outputMode: OutputMode { didSet { save() } }
    @Published var outputFolder: URL? { didSet { save() } }
    @Published var suffix: String { didSet { save() } }

    private let defaults = UserDefaults.standard

    private init() {
        preset = CompressionPreset(rawValue: defaults.string(forKey: "preset") ?? "") ?? .optimal
        manualDPI = defaults.object(forKey: "manualDPI") as? Double ?? 150
        manualQuality = defaults.object(forKey: "manualQuality") as? Double ?? 70
        removeEditorData = defaults.object(forKey: "removeEditorData") as? Bool ?? true
        outputMode = OutputMode(rawValue: defaults.string(forKey: "outputMode") ?? "") ?? .nextToOriginal
        outputFolder = defaults.url(forKey: "outputFolder")
        suffix = defaults.string(forKey: "suffix") ?? "_compressed"
        masterMode = defaults.object(forKey: "masterMode") as? Bool ?? false
    }

    private func save() {
        defaults.set(preset.rawValue, forKey: "preset")
        defaults.set(manualDPI, forKey: "manualDPI")
        defaults.set(manualQuality, forKey: "manualQuality")
        defaults.set(removeEditorData, forKey: "removeEditorData")
        defaults.set(outputMode.rawValue, forKey: "outputMode")
        defaults.set(outputFolder, forKey: "outputFolder")
        defaults.set(suffix, forKey: "suffix")
        defaults.set(masterMode, forKey: "masterMode")
    }

    var settings: CompressionSettings {
        var s = CompressionSettings(preset: preset,
                                    manualDPI: Int(manualDPI.rounded()), manualQuality: Int(manualQuality.rounded()))
        s.removeEditorData = removeEditorData
        return s
    }

    var jpegliBuiltIn: Bool { PDFCompressorInfo.jpegliAvailable }

    // MARK: Files

    func add(urls: [URL]) {
        var found: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil,
                                                       options: [.skipsHiddenFiles])
                while let f = e?.nextObject() as? URL {
                    if f.pathExtension.lowercased() == "pdf" { found.append(f) }
                }
            } else if url.pathExtension.lowercased() == "pdf" {
                found.append(url)
            }
        }
        for url in found where !files.contains(where: { $0.url == url }) {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            files.append(FileItem(url: url, originalSize: size))
        }
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.pdf, .folder]
        panel.message = "Выберите PDF-файлы или папки"
        if panel.runModal() == .OK { add(urls: panel.urls) }
    }

    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Выбрать"
        if panel.runModal() == .OK, let url = panel.url {
            outputFolder = url
            outputMode = .folder
        }
    }

    func remove(_ id: FileItem.ID) {
        guard !isProcessing else { return }
        files.removeAll { $0.id == id }
    }

    func clear() {
        guard !isProcessing else { return }
        files.removeAll()
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    var totalOriginal: Int {
        files.reduce(0) { acc, f in if case .done = f.status { return acc + f.originalSize }; return acc }
    }

    var totalCompressed: Int {
        files.reduce(0) { acc, f in if case .done(let r, _) = f.status { return acc + r.compressedSize }; return acc }
    }

    // MARK: Compression

    private func outputURL(for input: URL) -> URL {
        let dir = (outputMode == .folder ? outputFolder : nil) ?? input.deletingLastPathComponent()
        let base = input.deletingPathExtension().lastPathComponent + suffix
        var candidate = dir.appendingPathComponent(base).appendingPathExtension("pdf")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base) \(n)").appendingPathExtension("pdf")
            n += 1
        }
        return candidate
    }

    func compressAll() {
        guard !isProcessing else { return }
        let ids = files.filter {
            switch $0.status {
            case .pending, .failed: return true
            default: return false
            }
        }.map(\.id)
        guard !ids.isEmpty else { return }
        run(ids)
    }

    func recompressAll() {
        guard !isProcessing else { return }
        for i in files.indices { files[i].status = .pending }
        compressAll()
    }

    func submitPassword(_ password: String, for id: FileItem.ID) {
        guard let idx = files.firstIndex(where: { $0.id == id }) else { return }
        files[idx].password = password
        files[idx].status = .pending
        passwordRequest = nil
        if !isProcessing { run([id]) }
    }

    private func run(_ ids: [FileItem.ID]) {
        isProcessing = true
        let settings = self.settings
        Task {
            for id in ids {
                guard let idx = files.firstIndex(where: { $0.id == id }) else { continue }
                let item = files[idx]
                let out = outputURL(for: item.url)
                var settings = settings
                if masterMode {
                    settings.protectedPages = item.protectedPages
                    settings.protectedImages = item.protectedImages
                }
                files[idx].status = .working(0, "Подготовка…")
                let result: Result<CompressionReport, Error> = await Task.detached(priority: .userInitiated) { () -> Result<CompressionReport, Error> in
                    do {
                        let r = try PDFCompressor.compress(input: item.url, output: out, settings: settings,
                                                           password: item.password) { f, msg in
                            Task { @MainActor in
                                AppModel.shared.updateProgress(id, f, msg)
                            }
                        }
                        return .success(r)
                    } catch {
                        return .failure(error)
                    }
                }.value
                guard let j = files.firstIndex(where: { $0.id == id }) else { continue }
                switch result {
                case .success(let r):
                    files[j].status = .done(r, out)
                case .failure(let e as PDFError) where e.kind == .encrypted:
                    files[j].status = .needsPassword
                    if passwordRequest == nil { passwordRequest = id }
                case .failure(let e):
                    files[j].status = .failed(e.localizedDescription)
                }
            }
            isProcessing = false
        }
    }

    func setProtection(_ id: FileItem.ID, pages: Set<Int>, images: Set<Int>) {
        guard let i = files.firstIndex(where: { $0.id == id }) else { return }
        files[i].protectedPages = pages
        files[i].protectedImages = images
        if case .done = files[i].status { files[i].status = .pending }
    }

    fileprivate func updateProgress(_ id: FileItem.ID, _ f: Double, _ msg: String) {
        guard let i = files.firstIndex(where: { $0.id == id }) else { return }
        if case .working = files[i].status { files[i].status = .working(f, msg) }
    }
}
