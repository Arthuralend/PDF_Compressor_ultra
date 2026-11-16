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
      -c, --codec NAME      jpegli | jpeg2000 (по умолчанию jpegli)
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
var codec = ImageCodec.jpegli
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
    case "-c", "--codec":
        switch value(&i) {
        case "jpegli": codec = .jpegli
        case "jpeg2000", "jp2", "j2k": codec = .jpeg2000
        default: usage()
        }
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
    settings = CompressionSettings(preset: .manual, codec: codec, manualDPI: dpi ?? 150, manualQuality: quality ?? 70)
} else {
    settings = CompressionSettings(preset: preset, codec: codec)
}
settings.lossyImages = !lossless
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
      настройки:   \(settings.dpi) dpi, качество \(settings.quality)%, \(settings.codec.title)\(settings.lossyImages ? "" : ", без потерь")
      время:       \(String(format: "%.2f", Date().timeIntervalSince(start))) с
    """)
    if report.keptOriginal { print("  оптимизированный файл не меньше исходного — сохранена копия оригинала") }
    if let note = report.codecNote { print("  примечание: \(note)") }
} catch let e as PDFError {
    if !quiet { FileHandle.standardError.write("\n".data(using: .utf8)!) }
    FileHandle.standardError.write("Ошибка: \(e.message)\n".data(using: .utf8)!)
    exit(e.kind == .encrypted ? 3 : 1)
} catch {
    FileHandle.standardError.write("Ошибка: \(error.localizedDescription)\n".data(using: .utf8)!)
    exit(1)
}
