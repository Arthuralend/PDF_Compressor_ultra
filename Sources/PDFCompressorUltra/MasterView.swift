import AppKit
import PDFCore
import PDFKit
import SwiftUI

/// Master mode: choose pages / individual images that must not be compressed.
struct MasterView: View {
    @ObservedObject var model: AppModel
    let item: AppModel.FileItem

    @State private var pdf: PDFDocument?
    @State private var pages: [PageImagesInfo] = []
    @State private var loading = true
    @State private var error: String?
    @State private var selected = 0
    @State private var protectedPages: Set<Int> = []
    @State private var protectedImages: Set<Int> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if loading {
                ProgressView("Анализ страниц…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = error {
                Text(error).foregroundStyle(.red).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let pdf = pdf {
                HStack(spacing: 0) {
                    pageList(pdf)
                        .frame(width: 190)
                    Divider()
                    pageDetail(pdf)
                }
            }
            Divider()
            footer
        }
        .frame(minWidth: 900, idealWidth: 1000, minHeight: 640, idealHeight: 760)
        .task { await load() }
    }

    // MARK: Header / footer

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Мастер-режим").font(.headline)
                Text(item.url.lastPathComponent).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("Щёлкните по изображению на странице, чтобы не сжимать его")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Все страницы с изображениями") {
                protectedPages = Set(pages.filter { !$0.images.isEmpty }.map(\.index))
            }
            Button("Снять всё") {
                protectedPages = []
                protectedImages = []
            }
            Spacer()
            Text(summary).font(.callout).foregroundStyle(.secondary)
            Button("Отмена") { model.masterFile = nil }
                .keyboardShortcut(.cancelAction)
            Button("Готово") {
                model.setProtection(item.id, pages: protectedPages, images: protectedImages)
                model.masterFile = nil
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    private var summary: String {
        var parts: [String] = []
        if !protectedPages.isEmpty { parts.append("страниц: \(protectedPages.count)") }
        if !protectedImages.isEmpty { parts.append("изображений: \(protectedImages.count)") }
        return parts.isEmpty ? "Сжимается всё" : "Не сжимать — " + parts.joined(separator: ", ")
    }

    // MARK: Page list

    private func pageList(_ pdf: PDFDocument) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(0..<pdf.pageCount, id: \.self) { i in
                        PageThumb(page: pdf.page(at: i), index: i,
                                  imageCount: i < pages.count ? pages[i].images.count : 0,
                                  isSelected: i == selected,
                                  isProtected: protectedPages.contains(i)
                                      || (i < pages.count && pages[i].images.contains { protectedImages.contains($0.objectNumber) }))
                            .id(i)
                            .onTapGesture { selected = i }
                    }
                }
                .padding(10)
            }
            .onChange(of: selected) { v in withAnimation { proxy.scrollTo(v) } }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    // MARK: Page detail

    @ViewBuilder
    private func pageDetail(_ pdf: PDFDocument) -> some View {
        let info = selected < pages.count ? pages[selected] : PageImagesInfo(index: selected, images: [])
        VStack(spacing: 10) {
            HStack {
                Button { if selected > 0 { selected -= 1 } } label: { Image(systemName: "chevron.left") }
                    .disabled(selected == 0)
                Text("Страница \(selected + 1) из \(pdf.pageCount)").font(.callout.monospacedDigit())
                Button { if selected + 1 < pdf.pageCount { selected += 1 } } label: { Image(systemName: "chevron.right") }
                    .disabled(selected + 1 >= pdf.pageCount)
                Spacer()
                if info.images.isEmpty {
                    Text("Только текст и вектор — сжимается без потерь")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Toggle("Не сжимать изображения на этой странице", isOn: Binding(
                        get: { protectedPages.contains(selected) },
                        set: { on in
                            if on { protectedPages.insert(selected) } else { protectedPages.remove(selected) }
                        }))
                    .toggleStyle(.checkbox)
                }
            }
            if let page = pdf.page(at: selected) {
                PageCanvas(page: page, images: info.images,
                           pageProtected: protectedPages.contains(selected),
                           protectedImages: protectedImages) { num in
                    if protectedImages.contains(num) { protectedImages.remove(num) } else { protectedImages.insert(num) }
                }
            }
            if !info.images.isEmpty {
                HStack(spacing: 16) {
                    legend(color: .orange, text: "будет сжато")
                    legend(color: .green, text: "не сжимать")
                    Spacer()
                }
                .font(.caption)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func legend(color: Color, text: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).stroke(color, lineWidth: 2).frame(width: 14, height: 10)
            Text(text).foregroundStyle(.secondary)
        }
    }

    // MARK: Loading

    private func load() async {
        protectedPages = item.protectedPages
        protectedImages = item.protectedImages
        let url = item.url
        let password = item.password
        let result: Result<[PageImagesInfo], Error> = await Task.detached(priority: .userInitiated) {
            () -> Result<[PageImagesInfo], Error> in
            do { return .success(try PDFCompressor.inspect(url: url, password: password)) } catch { return .failure(error) }
        }.value
        switch result {
        case .success(let p):
            pages = p
            let doc = PDFDocument(url: url)
            if let d = doc, d.isLocked { _ = d.unlock(withPassword: password) }
            pdf = doc
            if doc == nil { error = "Не удалось открыть PDF для просмотра" }
            if let first = p.firstIndex(where: { !$0.images.isEmpty }) { selected = first }
        case .failure(let e):
            error = e.localizedDescription
        }
        loading = false
    }
}

/// Thumbnail in the page list.
private struct PageThumb: View {
    let page: PDFPage?
    let index: Int
    let imageCount: Int
    let isSelected: Bool
    let isProtected: Bool
    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let img = image {
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        Rectangle().fill(Color.white).aspectRatio(0.7, contentMode: .fit)
                    }
                }
                .frame(width: 150)
                .shadow(radius: 1)
                if isProtected {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .padding(4)
                        .background(Circle().fill(Color.green))
                        .foregroundStyle(.white)
                        .padding(4)
                }
            }
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 6).stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 3))
            Text(imageCount > 0 ? "\(index + 1) · изобр.: \(imageCount)" : "\(index + 1)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .task(id: index) {
            image = page?.thumbnail(of: CGSize(width: 300, height: 420), for: .mediaBox)
        }
    }
}

/// Large page render with clickable image frames.
private struct PageCanvas: View {
    let page: PDFPage
    let images: [PageImageInfo]
    let pageProtected: Bool
    let protectedImages: Set<Int>
    let toggle: (Int) -> Void

    var body: some View {
        let bounds = page.bounds(for: .mediaBox)
        let rotated = page.rotation % 180 != 0
        let size = rotated ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
        let transform = page.transform(for: .mediaBox)
        GeometryReader { geo in
            let scale = min(geo.size.width / max(size.width, 1), geo.size.height / max(size.height, 1))
            let w = size.width * scale, h = size.height * scale
            ZStack(alignment: .topLeading) {
                Image(nsImage: page.thumbnail(of: CGSize(width: w * 2, height: h * 2), for: .mediaBox))
                    .resizable()
                    .frame(width: w, height: h)
                    .shadow(radius: 2)
                ForEach(images) { img in
                    let r = CGRect(x: img.x, y: img.y, width: img.width, height: img.height).applying(transform)
                    let on = pageProtected || protectedImages.contains(img.objectNumber)
                    let color: Color = on ? .green : .orange
                    Rectangle()
                        .fill(color.opacity(on ? 0.22 : 0.08))
                        .overlay(Rectangle().stroke(color, lineWidth: 2))
                        .overlay(alignment: .topLeading) {
                            Text("\(img.pixelWidth)×\(img.pixelHeight) · \(Int(img.ppi.rounded())) ppi\(on ? " · не сжимать" : "")")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 4).padding(.vertical, 2)
                                .background(color)
                                .foregroundStyle(.white)
                        }
                        .frame(width: max(8, r.width * scale), height: max(8, r.height * scale))
                        .offset(x: r.minX * scale, y: (size.height - r.maxY) * scale)
                        .onTapGesture { if !pageProtected { toggle(img.objectNumber) } }
                        .help(pageProtected ? "Вся страница отмечена «не сжимать»" : "Щёлкните, чтобы переключить")
                }
            }
            .frame(width: w, height: h)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
