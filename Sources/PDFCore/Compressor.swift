import Foundation

/// PDF optimizer:
///  * text and vector graphics are never rasterized — pages stay "electronic";
///  * raster images are downsampled to the target PPI (based on their real size
///    on the page) and re-encoded with JPEGli or JPEG 2000;
///  * all other streams (content, fonts, forms...) are recompressed losslessly
///    with maximum Flate, duplicate streams/fonts are merged, unused objects are
///    dropped and objects are packed into compressed object streams.
public enum PDFCompressor {
    public typealias Progress = (_ fraction: Double, _ message: String) -> Void

    public static func compress(input: URL, output: URL, settings: CompressionSettings,
                                password: String = "", progress: Progress? = nil) throws -> CompressionReport {
        let data: [UInt8]
        do {
            data = [UInt8](try Data(contentsOf: input, options: .mappedIfSafe))
        } catch {
            throw PDFError(.io, "Не удалось прочитать файл: \(error.localizedDescription)")
        }
        let (out, report) = try compress(data: data, settings: settings, password: password, progress: progress)
        do {
            try Data(out).write(to: output, options: .atomic)
        } catch {
            throw PDFError(.io, "Не удалось сохранить файл: \(error.localizedDescription)")
        }
        return report
    }

    public static func compress(data: [UInt8], settings: CompressionSettings, password: String = "",
                                progress: Progress? = nil) throws -> ([UInt8], CompressionReport) {
        progress?(0.02, "Чтение структуры PDF…")
        let doc = try PDFDocumentModel(data: data, password: password)
        let pages = doc.pages()
        guard !pages.isEmpty else { throw PDFError(.damaged, "В документе не найдено страниц") }

        var report = CompressionReport(originalSize: data.count, compressedSize: data.count, pageCount: pages.count,
                                       pagesWithImages: 0, imagesFound: 0, imagesRecompressed: 0,
                                       imagesDownsampled: 0, streamsOptimized: 0, keptOriginal: false, codecNote: nil)

        // 1. Collect every reachable object.
        progress?(0.06, "Сбор объектов…")
        guard let rootRef = doc.trailer["Root"]?.refValue else { throw PDFError(.damaged, "Нет каталога документа") }
        let infoRef = doc.trailer["Info"]?.refValue
        var table: [Int: PDFIndirect] = [:]
        var queue: [Int] = [rootRef.num]
        if let i = infoRef { queue.append(i.num) }
        while let num = queue.popLast() {
            if table[num] != nil { continue }
            guard var ind = doc.indirect(num) else { continue }
            ind = cleaned(ind, removeEditorData: settings.removeEditorData)
            table[num] = ind
            collectRefs(ind) { r in if table[r.num] == nil { queue.append(r.num) } }
        }

        // 2. Where and how large are images drawn?
        progress?(0.1, "Анализ страниц…")
        let analyzer = ImageUsageAnalyzer(doc: doc)
        analyzer.analyze(pages: pages)
        report.pagesWithImages = analyzer.pagesWithImages

        // 3. Build jobs (serial: resolving touches the document cache).
        var maskNums = Set<Int>()
        var matteImages = Set<Int>()
        for (num, ind) in table {
            guard case .stream(let s) = ind, doc.resolve(s.dict["Subtype"] ?? .null).nameValue == "Image" else { continue }
            if let sm = s.dict["SMask"]?.refValue {
                maskNums.insert(sm.num)
                if let smd = table[sm.num]?.dict, smd["Matte"] != nil { matteImages.insert(num) }
            }
            if let m = s.dict["Mask"]?.refValue { maskNums.insert(m.num) }
        }

        var jobs: [Job] = []
        for num in table.keys.sorted() {
            guard case .stream(let s) = table[num]! else { continue }
            let (filters, parms) = Filters.filterChain(s.dict, resolve: doc.resolve)
            let isImage = doc.resolve(s.dict["Subtype"] ?? .null).nameValue == "Image"
            // XMP metadata stays uncompressed (PDF/A requirement, readable by indexers).
            if doc.resolve(s.dict["Type"] ?? .null).nameValue == "Metadata" { continue }
            if isImage {
                report.imagesFound += 1
                jobs.append(.image(makeImageJob(num: num, stream: s, filters: filters, parms: parms, doc: doc,
                                                usage: analyzer.usage[num], settings: settings,
                                                isMask: maskNums.contains(num), hasMatte: matteImages.contains(num))))
            } else {
                jobs.append(.generic(num: num, stream: s, filters: filters, parms: parms))
            }
        }

        // 4. Process streams in parallel.
        var codecNote: String? = nil
        if settings.codec == .jpegli && !ImageCodecs.jpegliAvailable {
            codecNote = "JPEGli не встроен в сборку — использован системный JPEG"
        }
        report.codecNote = codecNote
        let results = UnsafeMutableBufferPointer<JobResult?>.allocate(capacity: jobs.count)
        results.initialize(repeating: nil)
        defer { results.deallocate() }
        let lock = NSLock()
        var done = 0
        let total = max(1, jobs.count)
        DispatchQueue.concurrentPerform(iterations: jobs.count) { i in
            let r = withAutoreleasePool { process(jobs[i], settings: settings) }
            results[i] = r
            lock.lock()
            done += 1
            let d = done
            lock.unlock()
            if d % 4 == 0 || d == total {
                progress?(0.12 + 0.76 * Double(d) / Double(total), "Сжатие изображений и потоков: \(d) из \(total)")
            }
        }
        for i in 0..<jobs.count {
            guard let r = results[i] else { continue }
            table[r.num] = .stream(r.stream)
            if r.isImage {
                report.imagesRecompressed += 1
                if r.downsampled { report.imagesDownsampled += 1 }
            } else {
                report.streamsOptimized += 1
            }
        }

        // 5. Merge duplicates, renumber, write.
        progress?(0.9, "Объединение дубликатов…")
        deduplicate(&table, protected: [rootRef.num, infoRef?.num ?? -1])

        progress?(0.94, "Запись файла…")
        var order: [Int] = []
        var seen = Set<Int>()
        var bfs: [Int] = [rootRef.num]
        if let i = infoRef { bfs.append(i.num) }
        var head = 0
        while head < bfs.count {
            let n = bfs[head]
            head += 1
            guard !seen.contains(n), let ind = table[n] else { continue }
            seen.insert(n)
            order.append(n)
            collectRefs(ind) { r in if !seen.contains(r.num) && table[r.num] != nil { bfs.append(r.num) } }
        }
        var newNum: [Int: Int] = [:]
        for (i, n) in order.enumerated() { newNum[n] = i + 1 }
        let mapRef: (PDFRef) -> PDFRef? = { r in newNum[r.num].map { PDFRef($0, 0) } }
        let objects: [PDFIndirect] = order.map { remapRefs(table[$0]!, mapRef) }

        var fileID: [UInt8] = []
        if let ids = doc.resolve(doc.trailer["ID"] ?? .null).arrayValue, let f = ids.first,
           let s = doc.resolve(f).stringValue, !s.isEmpty {
            fileID = s
        } else {
            fileID = (0..<16).map { _ in UInt8.random(in: 0...255) }
        }
        let out = PDFFileWriter.write(objects: objects, root: PDFRef(newNum[rootRef.num]!, 0),
                                      info: infoRef.flatMap { newNum[$0.num] }.map { PDFRef($0, 0) },
                                      fileID: fileID, version: doc.versionString)

        // 6. Verify the result can be read back with the same number of pages.
        progress?(0.98, "Проверка результата…")
        guard let check = try? PDFDocumentModel(data: out), check.pages().count == pages.count else {
            throw PDFError(.internalError, "Проверка результата не пройдена — файл не изменён")
        }

        if out.count >= data.count && !doc.wasEncrypted {
            report.keptOriginal = true
            report.compressedSize = data.count
            progress?(1, "Готово")
            return (data, report)
        }
        report.compressedSize = out.count
        progress?(1, "Готово")
        return (out, report)
    }

    // MARK: - Object graph helpers

    @inline(__always) static func withAutoreleasePool<T>(_ body: () -> T) -> T {
        #if canImport(ObjectiveC)
        return autoreleasepool(invoking: body)
        #else
        return body()
        #endif
    }

    private static func cleaned(_ ind: PDFIndirect, removeEditorData: Bool) -> PDFIndirect {
        switch ind {
        case .stream(var s):
            s.dict["Length"] = nil
            if removeEditorData { s.dict["PieceInfo"] = nil }
            return .stream(s)
        case .object(.dict(var d)):
            if removeEditorData {
                d["PieceInfo"] = nil
                if d.name("Type") == "Page" { d["Thumb"] = nil }
            }
            return .object(.dict(d))
        default:
            return ind
        }
    }

    static func collectRefs(_ ind: PDFIndirect, _ f: (PDFRef) -> Void) {
        switch ind {
        case .object(let o): collectRefs(o, f)
        case .stream(let s): collectRefs(.dict(s.dict), f)
        }
    }

    static func collectRefs(_ o: PDFObject, _ f: (PDFRef) -> Void) {
        switch o {
        case .ref(let r): f(r)
        case .array(let a): for x in a { collectRefs(x, f) }
        case .dict(let d): for (_, v) in d.entries { collectRefs(v, f) }
        default: break
        }
    }

    static func remapRefs(_ o: PDFObject, _ map: (PDFRef) -> PDFRef?) -> PDFObject {
        switch o {
        case .ref(let r): return map(r).map { .ref($0) } ?? .null
        case .array(let a): return .array(a.map { remapRefs($0, map) })
        case .dict(let d):
            var nd = PDFDict()
            for (k, v) in d.entries {
                let nv = remapRefs(v, map)
                if !nv.isNull { nd[k] = nv }
            }
            return .dict(nd)
        default: return o
        }
    }

    static func remapRefs(_ ind: PDFIndirect, _ map: (PDFRef) -> PDFRef?) -> PDFIndirect {
        switch ind {
        case .object(let o): return .object(remapRefs(o, map))
        case .stream(var s):
            s.dict = remapRefs(.dict(s.dict), map).dictValue ?? s.dict
            return .stream(s)
        }
    }

    private struct DedupKey: Hashable {
        var head: [UInt8]
        var data: [UInt8]
    }

    private static let dedupTypes: Set<String> = ["Font", "FontDescriptor", "ExtGState", "Encoding", "Pattern", "Shading"]

    /// Merges byte-identical streams and shareable resource objects.
    static func deduplicate(_ table: inout [Int: PDFIndirect], protected: Set<Int>) {
        for _ in 0..<4 {
            var seen: [DedupKey: Int] = [:]
            var remap: [Int: Int] = [:]
            for num in table.keys.sorted() where !protected.contains(num) {
                let ind = table[num]!
                var key: DedupKey
                switch ind {
                case .stream(let s):
                    var ser = PDFSerializer()
                    ser.write(.dict(s.dict), refMap: { $0 })
                    key = DedupKey(head: ser.out, data: s.data)
                case .object(let o):
                    switch o {
                    case .dict(let d):
                        guard let t = d.name("Type"), dedupTypes.contains(t) else { continue }
                    case .array: break
                    default: continue
                    }
                    var ser = PDFSerializer()
                    ser.write(o, refMap: { $0 })
                    key = DedupKey(head: ser.out, data: [])
                }
                if let canon = seen[key] { remap[num] = canon } else { seen[key] = num }
            }
            if remap.isEmpty { return }
            for n in remap.keys { table[n] = nil }
            let map: (PDFRef) -> PDFRef? = { r in PDFRef(remap[r.num] ?? r.num, r.gen) }
            for (n, ind) in table { table[n] = remapRefs(ind, map) }
        }
    }

    // MARK: - Jobs

    enum ColorModel {
        case device(comps: Int, object: PDFObject)
        case indexed(base: Int, baseObject: PDFObject, hival: Int, lookup: [UInt8])

        var outputComponents: Int {
            switch self {
            case .device(let c, _): return c
            case .indexed(let b, _, _, _): return b
            }
        }
        var outputObject: PDFObject {
            switch self {
            case .device(_, let o): return o
            case .indexed(_, let o, _, _): return o
            }
        }
    }

    struct ImageJob {
        var num: Int
        var stream: PDFStream
        var filters: [String]
        var parms: [PDFObject]
        var width: Int
        var height: Int
        var bpc: Int
        var color: ColorModel?
        var imageMask: Bool
        var defaultDecode: Bool
        var lossyAllowed: Bool
        var resampleAllowed: Bool
        var targetWidth: Int
        var targetHeight: Int
        var smaskInData: Bool
    }

    enum Job {
        case image(ImageJob)
        case generic(num: Int, stream: PDFStream, filters: [String], parms: [PDFObject])
    }

    struct JobResult {
        var num: Int
        var stream: PDFStream
        var isImage: Bool
        var downsampled: Bool
    }

    private static func deviceComps(_ name: String) -> Int? {
        switch name {
        case "DeviceGray", "G", "CalGray": return 1
        case "DeviceRGB", "RGB", "CalRGB": return 3
        case "DeviceCMYK", "CMYK": return 4
        default: return nil
        }
    }

    private static func colorModel(_ original: PDFObject, doc: PDFDocumentModel, allowIndexed: Bool = true) -> ColorModel? {
        let cs = doc.resolve(original)
        switch cs {
        case .name(let n):
            guard let c = deviceComps(n) else { return nil }
            return .device(comps: c, object: original)
        case .array(let a):
            guard let first = a.first.map(doc.resolve)?.nameValue else { return nil }
            switch first {
            case "ICCBased":
                guard a.count >= 2, let s = doc.stream(a[1]), let n = doc.resolve(s.dict["N"] ?? .null).intValue,
                      [1, 3, 4].contains(n) else { return nil }
                return .device(comps: n, object: original)
            case "CalRGB": return .device(comps: 3, object: original)
            case "CalGray": return .device(comps: 1, object: original)
            case "DeviceGray", "DeviceRGB", "DeviceCMYK":
                return .device(comps: deviceComps(first)!, object: original)
            case "Indexed", "I":
                guard allowIndexed, a.count >= 4, let base = colorModel(a[1], doc: doc, allowIndexed: false),
                      case .device(let bc, let bobj) = base,
                      let hival = doc.resolve(a[2]).intValue, hival >= 0 else { return nil }
                var lookup: [UInt8] = []
                if let s = doc.resolve(a[3]).stringValue {
                    lookup = s
                } else if let st = doc.stream(a[3]) {
                    let (f, p) = Filters.filterChain(st.dict, resolve: doc.resolve)
                    guard let dec = try? Filters.decode(st.data, filters: f, parms: p, resolve: doc.resolve),
                          dec.remainingFilters.isEmpty else { return nil }
                    lookup = dec.data
                } else {
                    return nil
                }
                return .indexed(base: bc, baseObject: bobj, hival: min(hival, 255), lookup: lookup)
            default:
                return nil
            }
        default:
            return nil
        }
    }

    private static func makeImageJob(num: Int, stream s: PDFStream, filters: [String], parms: [PDFObject],
                                     doc: PDFDocumentModel, usage: ImageUsageAnalyzer.Usage?,
                                     settings: CompressionSettings, isMask: Bool, hasMatte: Bool) -> ImageJob {
        let d = s.dict
        let width = doc.resolve(d["Width"] ?? .null).intValue ?? 0
        let height = doc.resolve(d["Height"] ?? .null).intValue ?? 0
        let imageMask = doc.resolve(d["ImageMask"] ?? .null).boolValue ?? false
        let bpc = doc.resolve(d["BitsPerComponent"] ?? .null).intValue ?? (imageMask ? 1 : 8)
        let color = d["ColorSpace"].flatMap { colorModel($0, doc: doc) }

        var defaultDecode = true
        if let dec = doc.resolve(d["Decode"] ?? .null).arrayValue {
            let vals = dec.compactMap { doc.resolve($0).doubleValue }
            let isIndexed: Bool = { if case .indexed? = color { return true }; return false }()
            for (i, v) in vals.enumerated() {
                let expected: Double = i % 2 == 0 ? 0 : (isIndexed ? Double((1 << bpc) - 1) : 1)
                if abs(v - expected) > 1e-6 { defaultDecode = false }
            }
        }
        // Color-key masking (/Mask [ranges]) breaks with lossy codecs.
        let colorKeyMask = doc.resolve(d["Mask"] ?? .null).arrayValue != nil
        let smaskInData = (doc.resolve(d["SMaskInData"] ?? .null).intValue ?? 0) != 0

        var tw = width, th = height
        if let u = usage, width > 0, height > 0, settings.dpi > 0 {
            let target = Double(settings.dpi)
            if u.maxWidthPt > 0.5 {
                let ppi = Double(width) / (u.maxWidthPt / 72)
                if ppi > target * 1.1 { tw = max(1, Int((Double(width) * target / ppi).rounded(.up))) }
            }
            if u.maxHeightPt > 0.5 {
                let ppi = Double(height) / (u.maxHeightPt / 72)
                if ppi > target * 1.1 { th = max(1, Int((Double(height) * target / ppi).rounded(.up))) }
            }
        }
        let lossy = settings.lossyImages && !isMask && !imageMask && !colorKeyMask && defaultDecode && !smaskInData
        let resample = !isMask && !imageMask && !hasMatte && !colorKeyMask && defaultDecode
        return ImageJob(num: num, stream: s, filters: filters, parms: parms, width: width, height: height, bpc: bpc,
                        color: color, imageMask: imageMask, defaultDecode: defaultDecode, lossyAllowed: lossy,
                        resampleAllowed: resample, targetWidth: tw, targetHeight: th, smaskInData: smaskInData)
    }

    static func process(_ job: Job, settings: CompressionSettings) -> JobResult? {
        switch job {
        case .generic(let num, let s, let f, let p):
            guard let ns = optimizeLossless(s, filters: f, parms: p, imageInfo: nil) else { return nil }
            return JobResult(num: num, stream: ns, isImage: false, downsampled: false)
        case .image(let j):
            if let r = recompressImage(j, settings: settings) { return r }
            // Fall back to lossless recompression of the image data.
            var info: (Int, Int, Int)? = nil
            if let c = j.color, !j.imageMask {
                let comps: Int = { if case .indexed = c { return 1 }; return c.outputComponents }()
                info = (comps, j.bpc, j.width)
            }
            guard let ns = optimizeLossless(j.stream, filters: j.filters, parms: j.parms, imageInfo: info) else { return nil }
            return JobResult(num: j.num, stream: ns, isImage: false, downsampled: false)
        }
    }

    // MARK: - Lossless stream optimization

    /// imageInfo: (colors, bitsPerComponent, columns) enabling PNG prediction.
    static func optimizeLossless(_ s: PDFStream, filters: [String], parms: [PDFObject],
                                 imageInfo: (Int, Int, Int)?) -> PDFStream? {
        guard let dec = try? Filters.decode(s.data, filters: filters, parms: parms, resolve: { $0 }) else { return nil }
        // Nothing to gain if no lossless filter was involved and the data is already
        // in a terminal image codec.
        let remaining = dec.remainingFilters
        let remainingParms = dec.remainingParms
        var best: (data: [UInt8], filters: [String], parms: [PDFObject])? = nil
        func consider(_ data: [UInt8], _ f: [String], _ p: [PDFObject]) {
            if best == nil || data.count < best!.data.count { best = (data, f, p) }
        }
        if !remaining.isEmpty {
            consider(dec.data, remaining, remainingParms)
        }
        if let z = Zlib.deflate(dec.data) {
            consider(z, ["FlateDecode"] + remaining, [.null] + remainingParms)
        }
        if remaining.isEmpty, let info = imageInfo, info.1 >= 1, info.2 > 0 {
            let (colors, bpc, columns) = info
            let rowLen = (colors * bpc * columns + 7) / 8
            if rowLen > 0, dec.data.count >= rowLen, dec.data.count % rowLen == 0 {
                let predicted = Filters.pngPredict(dec.data, rowLen: rowLen, bpp: max(1, (colors * bpc + 7) / 8))
                if let z = Zlib.deflate(predicted) {
                    let p = PDFDict([("Predictor", .int(15)), ("Colors", .int(colors)),
                                     ("BitsPerComponent", .int(bpc)), ("Columns", .int(columns))])
                    consider(z, ["FlateDecode"], [.dict(p)])
                }
            }
        }
        if dec.data.count < (best?.data.count ?? Int.max) && remaining.isEmpty {
            consider(dec.data, [], [])
        }
        guard let b = best, b.data.count + 8 < s.data.count else { return nil }
        var d = s.dict
        d.remove("Filter", "DecodeParms", "DP", "Length")
        if !b.filters.isEmpty {
            d["Filter"] = b.filters.count == 1 ? .name(b.filters[0]) : .array(b.filters.map { .name($0) })
            if b.parms.contains(where: { !$0.isNull }) {
                d["DecodeParms"] = b.parms.count == 1 ? b.parms[0] : .array(b.parms)
            }
        }
        return PDFStream(dict: d, data: b.data)
    }

    // MARK: - Image recompression

    static func recompressImage(_ j: ImageJob, settings: CompressionSettings) -> JobResult? {
        guard j.width > 0, j.height > 0, !j.imageMask else { return nil }
        let needsResample = j.resampleAllowed && (j.targetWidth < j.width || j.targetHeight < j.height)
        guard j.lossyAllowed || needsResample else { return nil }
        guard let dec = try? Filters.decode(j.stream.data, filters: j.filters, parms: j.parms, resolve: { $0 }) else { return nil }

        var raster: Raster
        var colorObject: PDFObject
        var paletteSize = Int.max
        let rest = dec.remainingFilters
        if rest.isEmpty {
            guard let c = j.color else { return nil }
            if j.bpc == 1, case .device = c { return nil } // bilevel scans: keep lossless
            guard let r = unpack(dec.data, width: j.width, height: j.height, bpc: j.bpc, color: c) else { return nil }
            raster = r
            colorObject = c.outputObject
            if case .indexed(_, _, let hival, _) = c { paletteSize = hival + 1 }
        } else if rest == ["DCTDecode"] || rest == ["JPXDecode"] {
            guard j.defaultDecode else { return nil }
            if let c = j.color, c.outputComponents == 4 { return nil }
            if case .indexed? = j.color { return nil }
            guard let r = ImageCodecs.decode(dec.data) else { return nil }
            raster = r
            if let c = j.color, c.outputComponents == r.components {
                colorObject = c.outputObject
            } else if j.color == nil || rest == ["DCTDecode"] {
                colorObject = .name(r.components == 1 ? "DeviceGray" : "DeviceRGB")
            } else {
                return nil
            }
        } else {
            return nil
        }

        var downsampled = false
        if needsResample {
            raster = raster.resized(width: j.targetWidth, height: j.targetHeight)
            downsampled = raster.width < j.width || raster.height < j.height
        }

        let lossyOK = j.lossyAllowed && (raster.components == 1 || raster.components == 3)
            && paletteSize > 64 && raster.width * raster.height >= 256
        var encoded: [UInt8]? = nil
        var filter = "FlateDecode"
        var parms: PDFObject = .null
        if lossyOK {
            switch settings.codec {
            case .jpeg2000:
                if let e = ImageCodecs.encodeJPEG2000(raster, quality: settings.quality) {
                    encoded = e
                    filter = "JPXDecode"
                }
            case .jpegli:
                break
            }
            if encoded == nil {
                if let e = ImageCodecs.encodeJpegli(raster, quality: settings.quality)
                    ?? ImageCodecs.encodeSystemJPEG(raster, quality: settings.quality) {
                    encoded = e
                    filter = "DCTDecode"
                }
            }
        }
        if encoded == nil {
            // Lossless (CMYK, small palettes, masks…) — only worth it when downsampled.
            guard downsampled else { return nil }
            let rowLen = raster.width * raster.components
            let predicted = Filters.pngPredict(raster.pixels, rowLen: rowLen, bpp: raster.components)
            guard let z = Zlib.deflate(predicted) else { return nil }
            encoded = z
            filter = "FlateDecode"
            parms = .dict(PDFDict([("Predictor", .int(15)), ("Colors", .int(raster.components)),
                                   ("BitsPerComponent", .int(8)), ("Columns", .int(raster.width))]))
        }
        guard let data = encoded else { return nil }
        // Keep the original unless we gain at least 5 %.
        guard Double(data.count) < Double(j.stream.data.count) * 0.95 else { return nil }

        var d = j.stream.dict
        d.remove("Filter", "DecodeParms", "DP", "Length", "DL", "Decode", "SMaskInData")
        d["Width"] = .int(raster.width)
        d["Height"] = .int(raster.height)
        d["BitsPerComponent"] = .int(8)
        d["ColorSpace"] = colorObject
        d["Filter"] = .name(filter)
        if !parms.isNull { d["DecodeParms"] = parms }
        return JobResult(num: j.num, stream: PDFStream(dict: d, data: data), isImage: true, downsampled: downsampled)
    }

    /// Unpacks raw PDF image samples into an 8-bit raster (palettes expanded).
    static func unpack(_ data: [UInt8], width w: Int, height h: Int, bpc: Int, color: ColorModel) -> Raster? {
        guard [1, 2, 4, 8, 16].contains(bpc) else { return nil }
        let inComps: Int
        switch color {
        case .device(let c, _): inComps = c
        case .indexed: inComps = 1
        }
        let outComps = color.outputComponents
        let rowBytes = (w * inComps * bpc + 7) / 8
        guard w > 0, h > 0, rowBytes > 0, data.count >= rowBytes * h * 9 / 10 else { return nil }
        var px = [UInt8](repeating: 0, count: w * h * outComps)
        let maxV = (1 << min(bpc, 8)) - 1
        let samplesPerRow = w * inComps
        data.withUnsafeBufferPointer { src in
            px.withUnsafeMutableBufferPointer { dst in
                for y in 0..<h {
                    let rowStart = y * rowBytes
                    if rowStart + rowBytes > src.count { break }
                    for sIdx in 0..<samplesPerRow {
                        var v: Int
                        switch bpc {
                        case 8: v = Int(src[rowStart + sIdx])
                        case 16: v = Int(src[rowStart + sIdx * 2])
                        default:
                            let bit = sIdx * bpc
                            let byte = src[rowStart + bit / 8]
                            let shift = 8 - bpc - (bit % 8)
                            v = (Int(byte) >> shift) & maxV
                        }
                        switch color {
                        case .device:
                            if bpc < 8 { v = v * 255 / maxV }
                            dst[y * samplesPerRow + sIdx] = UInt8(v)
                        case .indexed(let base, _, let hival, let lookup):
                            let idx = min(v, hival) * base
                            let o = (y * w + sIdx) * base
                            for k in 0..<base {
                                dst[o + k] = idx + k < lookup.count ? lookup[idx + k] : 0
                            }
                        }
                    }
                }
            }
        }
        return Raster(width: w, height: h, components: outComps, pixels: px)
    }
}
