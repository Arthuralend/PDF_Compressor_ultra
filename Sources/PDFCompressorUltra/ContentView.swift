import AppKit
import PDFCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            SettingsPanel(model: model)
                .frame(width: 310)
            Divider()
            FilesPanel(model: model)
                .frame(minWidth: 460)
        }
        .frame(minWidth: 800, minHeight: 600)
        .sheet(item: Binding(
            get: { model.passwordRequest.map { PasswordRequest(id: $0) } },
            set: { model.passwordRequest = $0?.id }
        )) { req in
            PasswordSheet(model: model, fileID: req.id)
        }
        .sheet(item: Binding(
            get: { model.masterFile.map { PasswordRequest(id: $0) } },
            set: { model.masterFile = $0?.id }
        )) { req in
            if let item = model.files.first(where: { $0.id == req.id }) {
                MasterView(model: model, item: item)
            }
        }
    }
}

private struct PasswordRequest: Identifiable { let id: UUID }

// MARK: - Settings

struct SettingsPanel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 52, height: 52)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("PDF Compressor Ultra")
                            .font(.title3.weight(.bold))
                        Text("Сжатие PDF без потери текста и векторов")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                section("Уровень сжатия") {
                    VStack(spacing: 6) {
                        ForEach(CompressionPreset.allCases) { p in
                            PresetRow(preset: p, selected: model.preset == p) { model.preset = p }
                                .disabled(model.isProcessing)
                        }
                    }
                    if model.preset == .manual {
                        VStack(alignment: .leading, spacing: 10) {
                            LabeledSlider(title: "Разрешение", value: $model.manualDPI, range: 36...600, step: 1,
                                          format: { "\(Int($0)) dpi" })
                            LabeledSlider(title: "Качество", value: $model.manualQuality, range: 10...100, step: 1,
                                          format: { "\(Int($0)) %" })
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
                        .disabled(model.isProcessing)
                    }
                }

                section("Кодек изображений") {
                    Text(codecHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                section("Мастер-режим") {
                    Toggle("Выбирать страницы и изображения, которые не сжимать", isOn: $model.masterMode)
                        .toggleStyle(.switch)
                        .disabled(model.isProcessing)
                    if model.masterMode {
                        Text("У каждого файла появится кнопка «Страницы…»: отметьте страницы или щёлкните по изображениям, которые нужно оставить как есть.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                section("Дополнительно") {
                    Toggle("Удалять служебные данные редакторов и миниатюры страниц", isOn: $model.removeEditorData)
                        .toggleStyle(.checkbox)
                        .disabled(model.isProcessing)
                }

                section("Сохранение") {
                    Picker("", selection: $model.outputMode) {
                        ForEach(AppModel.OutputMode.allCases) { m in Text(m.title).tag(m) }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                    if model.outputMode == .folder {
                        HStack {
                            Text(model.outputFolder?.path ?? "Папка не выбрана")
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Выбрать…") { model.chooseOutputFolder() }
                        }
                    }
                    HStack {
                        Text("Суффикс имени:")
                        TextField("_compressed", text: $model.suffix)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 130)
                    }
                    .font(.callout)
                }
                .disabled(model.isProcessing)

                Text("Страницы, где есть только текст и векторная графика, остаются электронными: сжимаются без потерь. На смешанных страницах уменьшаются и пересжимаются только изображения.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var codecHint: String {
        model.jpegliBuiltIn
            ? "JPEGli — современный кодер JPEG от Google: на 25–35% меньше при том же качестве, открывается в любой программе."
            : "JPEGli не встроен в эту сборку — используется системный JPEG."
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }
}

struct PresetRow: View {
    let preset: CompressionPreset
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(preset.title).font(.callout.weight(selected ? .semibold : .regular))
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let v = preset.values {
                    Text("\(v.dpi)")
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(selected ? Color.accentColor.opacity(0.14) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    private var detail: String {
        if let v = preset.values { return "\(v.dpi) точек на дюйм · качество \(v.quality)%" }
        return "Свои разрешение и качество"
    }
}

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                Text(format(value)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step)
        }
    }
}

// MARK: - Files

struct FilesPanel: View {
    @ObservedObject var model: AppModel
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            if model.files.isEmpty {
                dropZone
            } else {
                List {
                    ForEach(model.files) { item in
                        FileRow(model: model, item: item)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.accentColor, lineWidth: dropTargeted ? 3 : 0)
                )
            }
            Divider()
            bottomBar
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
            loadDropped(providers)
            return true
        }
    }

    private var dropZone: some View {
        Button(action: { model.openPanel() }) {
            VStack(spacing: 14) {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 54, weight: .light))
                    .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary)
                Text("Перетащите PDF-файлы или папки сюда")
                    .font(.title3.weight(.medium))
                Text("или нажмите, чтобы выбрать")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .foregroundStyle(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.5))
                    .padding(24)
            )
        }
        .buttonStyle(.plain)
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button { model.openPanel() } label: { Label("Добавить…", systemImage: "plus") }
                .disabled(model.isProcessing)
            Button("Очистить") { model.clear() }
                .disabled(model.isProcessing || model.files.isEmpty)
            Spacer()
            if model.totalOriginal > 0 {
                let saved = 1 - Double(model.totalCompressed) / Double(max(1, model.totalOriginal))
                Text("\(bytes(model.totalOriginal)) → \(bytes(model.totalCompressed))  (−\(Int((saved * 100).rounded()))%)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if model.isProcessing {
                ProgressView().controlSize(.small)
            }
            Button {
                model.compressAll()
            } label: {
                Text("Сжать").frame(minWidth: 90)
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
            .disabled(model.isProcessing || !hasPending)
        }
        .padding(12)
    }

    private var hasPending: Bool {
        model.files.contains {
            switch $0.status {
            case .pending, .failed: return true
            default: return false
            }
        }
    }

    private func loadDropped(_ providers: [NSItemProvider]) {
        for p in providers {
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url = url {
                    Task { @MainActor in AppModel.shared.add(urls: [url]) }
                }
            }
        }
    }
}

func bytes(_ n: Int) -> String {
    let f = ByteCountFormatter()
    f.countStyle = .file
    return f.string(fromByteCount: Int64(n))
}

struct FileRow: View {
    @ObservedObject var model: AppModel
    let item: AppModel.FileItem

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable()
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.url.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                status
            }
            Spacer()
            trailing
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Показать оригинал в Finder") { model.reveal(item.url) }
            if case .done(_, let out) = item.status {
                Button("Показать результат в Finder") { model.reveal(out) }
            }
            Divider()
            Button("Убрать из списка") { model.remove(item.id) }
        }
    }

    @ViewBuilder private var status: some View {
        switch item.status {
        case .pending:
            Text("\(bytes(item.originalSize)) · ожидает").font(.caption).foregroundStyle(.secondary)
        case .working(let f, let msg):
            VStack(alignment: .leading, spacing: 2) {
                ProgressView(value: f).progressViewStyle(.linear)
                Text(msg).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        case .done(let r, _):
            VStack(alignment: .leading, spacing: 1) {
                Text("\(bytes(r.originalSize)) → \(bytes(r.compressedSize))")
                    .font(.caption.monospacedDigit())
                Text(detail(r))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        case .failed(let msg):
            Text(msg).font(.caption).foregroundStyle(.red).lineLimit(2)
        case .needsPassword:
            Text("Документ защищён паролем").font(.caption).foregroundStyle(.orange)
        }
    }

    private func detail(_ r: CompressionReport) -> String {
        if r.keptOriginal { return "Файл уже оптимален — сохранена копия оригинала" }
        var parts = ["стр.: \(r.pageCount)"]
        if r.imagesFound > 0 {
            parts.append("изображений пересжато: \(r.imagesRecompressed) из \(r.imagesFound)")
        } else {
            parts.append("без изображений — сжатие без потерь")
        }
        if r.imagesDownsampled > 0 { parts.append("уменьшено разрешение: \(r.imagesDownsampled)") }
        if let n = r.codecNote { parts.append(n) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var trailing: some View {
        HStack(spacing: 8) {
            if model.masterMode {
                Button {
                    model.masterFile = item.id
                } label: {
                    Label(item.protectedCount > 0 ? "Страницы (\(item.protectedCount))" : "Страницы…",
                          systemImage: "rectangle.and.hand.point.up.left")
                }
                .disabled(model.isProcessing)
            }
            statusTrailing
        }
    }

    @ViewBuilder private var statusTrailing: some View {
        switch item.status {
        case .done(let r, let out):
            HStack(spacing: 8) {
                Text(r.savedFraction > 0 ? "−\(Int((r.savedFraction * 100).rounded()))%" : "0%")
                    .font(.system(.title3, design: .rounded).weight(.bold))
                    .foregroundStyle(r.savedFraction > 0.01 ? Color.green : Color.secondary)
                if !r.imageLog.isEmpty {
                    ImageReportButton(report: r)
                }
                Button { model.reveal(out) } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.borderless)
                    .help("Показать в Finder")
            }
        case .needsPassword:
            Button("Ввести пароль…") { model.passwordRequest = item.id }
        case .working:
            EmptyView()
        default:
            Button { model.remove(item.id) } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .disabled(model.isProcessing)
        }
    }
}

struct PasswordSheet: View {
    @ObservedObject var model: AppModel
    let fileID: UUID
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Документ защищён паролем", systemImage: "lock.fill").font(.headline)
            Text(model.files.first(where: { $0.id == fileID })?.url.lastPathComponent ?? "")
                .foregroundStyle(.secondary)
            SecureField("Пароль", text: $password)
                .textFieldStyle(.roundedBorder)
                .onSubmit { submit() }
            Text("Сжатый файл будет сохранён без пароля.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Отмена") { model.passwordRequest = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Открыть") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func submit() {
        guard !password.isEmpty else { return }
        model.submitPassword(password, for: fileID)
    }
}

struct ImageReportButton: View {
    let report: CompressionReport
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: { Image(systemName: "info.circle") }
            .buttonStyle(.borderless)
            .help("Отчёт по изображениям")
            .popover(isPresented: $shown, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Изображения: \(report.imagesFound), пересжато \(report.imagesRecompressed), уменьшено \(report.imagesDownsampled)")
                        .font(.headline)
                    if !report.skipped.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Оставлены без изменений:").font(.subheadline.weight(.semibold))
                            ForEach(report.skipped.sorted(by: { $0.value > $1.value }), id: \.key) { k, v in
                                Text("\(v) × \(k)").font(.caption)
                            }
                        }
                    }
                    Divider()
                    ScrollView {
                        Text(report.imageLog.joined(separator: "\n"))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 260)
                    Button("Скопировать отчёт") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(report.imageLog.joined(separator: "\n"), forType: .string)
                    }
                }
                .padding(14)
                .frame(width: 520)
            }
    }
}
