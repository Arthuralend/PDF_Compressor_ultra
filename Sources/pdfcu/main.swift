import Foundation
import PDFCore

// Command-line interface: pdfcu input.pdf [options]
func usage() -> Never {
    print("""
    PDF Compressor Ultra — командная строка

    Использование: pdfcu <input.pdf> [-o output.pdf] [опции]

      -p, --preset NAME     strong | optimal-strong | optimal | medium | light (по умолчанию optimal)
          --dpi N           ручной выбор: разрешение изображений (точек на дюйм)
          --quality Q       ручной выбор: качество JPEG 1…100
          --keep-pages LIST  мастер-режим: не сжимать изображения на страницах (напр. 1,3,5-7)
          --list-images     показать изображения на страницах и выйти
      -v, --verbose         подробный отчёт по каждому изображению
          --lossless        только сжатие без потерь (изображения не перекодируются)
          --keep-editor-data  не удалять служебные данные редакторов и миниатюры
          --password PW     пароль для зашифрованного PDF
      -q, --quiet           без вывода прогресса
    """)
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
if args.isEmpty || args.contains("-h") || args.contains("--help") { usage() }

var input: String?
var output: String?
var preset = CompressionPreset.optimal
var dpi: Int?
var quality: Int?
var verbose = false
var keepPages = Set<Int>()
var listImages = false

func parsePages(_ s: String) -> Set<Int> {
    var r = Set<Int>()
    for part in s.split(separator: ",") {
        let b = part.split(separator: "-").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        if b.count == 1 { r.insert(b[0] - 1) }
        else if b.count == 2, b[0] <= b[1] { for p in b[0]...b[1] { r.insert(p - 1) } }
    }
    return r
}
var lossless = false
var keepEditorData = false
var password = ""
var quiet = false

func value(_ i: inout Int) -> String {
    i += 1
    guard i < args.count else { usage() }
    return args[i]
}

func intValue(_ i: inout Int) -> Int {
    guard let v = Int(value(&i)) else { usage() }
    return v
}

var i = 0
while i < args.count {
    let a = args[i]
    switch a {
    case "-o", "--output": output = value(&i)
    case "-p", "--preset":
        switch value(&i) {
        case "strong": preset = .strong
        case "optimal-strong": preset = .optimalStrong
        case "optimal": preset = .optimal
        case "medium": preset = .medium
        case "light": preset = .light
        default: usage()
        }
    case "--dpi": dpi = intValue(&i)
    case "--quality": quality = intValue(&i)
    case "-v", "--verbose": verbose = true
    case "--keep-pages": keepPages = parsePages(value(&i))
    case "--list-images": listImages = true
    case "--lossless": lossless = true
    case "--keep-editor-data": keepEditorData = true
    case "--password": password = value(&i)
    case "-q", "--quiet": quiet = true
    default:
        if a.hasPrefix("-") || input != nil { usage() }
        input = a
    }
    i += 1
}

guard let inPath = input else { usage() }
let inURL = URL(fileURLWithPath: inPath)
let outURL = output.map { URL(fileURLWithPath: $0) }
    ?? inURL.deletingPathExtension().appendingPathExtension("compressed.pdf")

var settings: CompressionSettings
if dpi != nil || quality != nil {
    settings = CompressionSettings(preset: .manual, manualDPI: dpi ?? 150, manualQuality: quality ?? 70)
} else {
    settings = CompressionSettings(preset: preset)
}
settings.lossyImages = !lossless
settings.protectedPages = keepPages

if listImages {
    do {
        for page in try PDFCompressor.inspect(url: inURL, password: password) {
            print("Страница \(page.index + 1): \(page.images.isEmpty ? "только текст/вектор" : "\(page.images.count) изобр.")")
            for img in page.images {
                print("  #\(img.objectNumber) \(img.pixelWidth)×\(img.pixelHeight) px, \(Int(img.ppi.rounded())) ppi, "
                      + "x=\(Int(img.x)) y=\(Int(img.y)) \(Int(img.width))×\(Int(img.height)) pt")
            }
        }
        exit(0)
    } catch {
        FileHandle.standardError.write("Ошибка: \(error.localizedDescription)\n".data(using: .utf8)!)
        exit(1)
    }
}
settings.removeEditorData = !keepEditorData

let start = Date()
do {
    let report = try PDFCompressor.compress(input: inURL, output: outURL, settings: settings, password: password) { f, msg in
        if !quiet {
            FileHandle.standardError.write("\r[\(String(format: "%3d", Int(f * 100)))%] \(msg)".padding(toLength: 70, withPad: " ", startingAt: 0).data(using: .utf8)!)
        }
    }
    if !quiet { FileHandle.standardError.write("\n".data(using: .utf8)!) }
    let fmt = ByteCountFormatter()
    fmt.countStyle = .file
    print("""
    \(inURL.lastPathComponent) → \(outURL.lastPathComponent)
      размер:      \(fmt.string(fromByteCount: Int64(report.originalSize))) → \(fmt.string(fromByteCount: Int64(report.compressedSize))) (−\(String(format: "%.1f", report.savedFraction * 100))%)
      страниц:     \(report.pageCount), с изображениями: \(report.pagesWithImages)
      изображений: \(report.imagesFound), перекодировано: \(report.imagesRecompressed), уменьшено: \(report.imagesDownsampled)
      прочих потоков пересжато без потерь: \(report.streamsOptimized)
      настройки:   \(settings.dpi) dpi, качество JPEGli \(settings.quality)%\(settings.lossyImages ? "" : ", без потерь")
      время:       \(String(format: "%.2f", Date().timeIntervalSince(start))) с
    """)
    if report.keptOriginal { print("  оптимизированный файл не меньше исходного — сохранена копия оригинала") }
    if let note = report.codecNote { print("  примечание: \(note)") }
    if !report.skipped.isEmpty {
        print("  оставлены без изменений:")
        for (reason, n) in report.skipped.sorted(by: { $0.value > $1.value }) { print("    \(n) × \(reason)") }
    }
    if verbose {
        print("  изображения:")
        for line in report.imageLog { print("    " + line) }
    }
} catch let e as PDFError {
    if !quiet { FileHandle.standardError.write("\n".data(using: .utf8)!) }
    FileHandle.standardError.write("Ошибка: \(e.message)\n".data(using: .utf8)!)
    exit(e.kind == .encrypted ? 3 : 1)
} catch {
    FileHandle.standardError.write("Ошибка: \(error.localizedDescription)\n".data(using: .utf8)!)
    exit(1)
}
