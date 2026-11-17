import Foundation

struct Matrix {
    var a = 1.0, b = 0.0, c = 0.0, d = 1.0, e = 0.0, f = 0.0

    static let identity = Matrix()

    init() {}
    init(_ v: [Double]) {
        if v.count == 6 { a = v[0]; b = v[1]; c = v[2]; d = v[3]; e = v[4]; f = v[5] }
    }

    /// self × m  (apply self first, then m)
    func concat(_ m: Matrix) -> Matrix {
        var r = Matrix()
        r.a = a * m.a + b * m.c
        r.b = a * m.b + b * m.d
        r.c = c * m.a + d * m.c
        r.d = c * m.b + d * m.d
        r.e = e * m.a + f * m.c + m.e
        r.f = e * m.b + f * m.d + m.f
        return r
    }
}

/// Finds where every image XObject is drawn and how large (in points) it is
/// displayed, so the effective resolution (PPI) can be computed.
final class ImageUsageAnalyzer {
    struct Usage {
        var maxWidthPt: Double = 0   // along the image x axis
        var maxHeightPt: Double = 0  // along the image y axis
    }

    private let doc: PDFDocumentModel
    private(set) var usage: [Int: Usage] = [:]
    private(set) var pagesWithImages = 0
    /// For every page: image object numbers with their placement matrices.
    private(set) var pagePlacements: [[(Int, Matrix)]] = []
    private var formCache: [Int: [(Int, Matrix)]] = [:]
    private var activeForms: Set<Int> = []
    private var visitedImagesOnPage = false

    init(doc: PDFDocumentModel) { self.doc = doc }

    func analyze(pages: [PDFDocumentModel.PageInfo]) {
        for page in pages {
            visitedImagesOnPage = false
            var placements: [(Int, Matrix)] = []
            let content = contentData(page.dict["Contents"])
            scan(content, resources: page.resources, depth: 0, into: &placements)
            // annotation appearances
            for annot in doc.resolve(page.dict["Annots"] ?? .null).arrayValue ?? [] {
                guard let ad = doc.resolveDict(annot), let ap = doc.resolveDict(ad["AP"]) else { continue }
                var streams: [PDFObject] = []
                if let n = ap["N"] {
                    if doc.stream(n) != nil { streams.append(n) }
                    else if let states = doc.resolveDict(n) { streams.append(contentsOf: states.entries.map { $0.1 }) }
                }
                for s in streams { placeForm(s, ctm: .identity, parentResources: page.resources, depth: 1, into: &placements) }
            }
            for (num, m) in placements { record(num, m) }
            pagePlacements.append(placements)
            if !placements.isEmpty { pagesWithImages += 1 }
        }
    }

    private func record(_ num: Int, _ m: Matrix) {
        let w = (m.a * m.a + m.b * m.b).squareRoot()
        let h = (m.c * m.c + m.d * m.d).squareRoot()
        var u = usage[num] ?? Usage()
        u.maxWidthPt = max(u.maxWidthPt, w)
        u.maxHeightPt = max(u.maxHeightPt, h)
        usage[num] = u
    }

    private func contentData(_ obj: PDFObject?) -> [UInt8] {
        guard let obj = obj else { return [] }
        var parts: [PDFObject] = []
        if case .ref = obj, doc.stream(obj) != nil { parts = [obj] }
        else { parts = doc.resolve(obj).arrayValue ?? [] }
        var out: [UInt8] = []
        for p in parts {
            guard let s = doc.stream(p) else { continue }
            if let d = decode(s) { out.append(contentsOf: d); out.append(0x0A) }
        }
        return out
    }

    private func decode(_ s: PDFStream) -> [UInt8]? {
        let (f, p) = Filters.filterChain(s.dict, resolve: doc.resolve)
        guard let dec = try? Filters.decode(s.data, filters: f, parms: p, resolve: doc.resolve, allowPartial: true),
              dec.remainingFilters.isEmpty else { return nil }
        return dec.data
    }

    /// Places a form XObject drawn with `ctm`, appending absolute placements.
    private func placeForm(_ ref: PDFObject, ctm: Matrix, parentResources: PDFDict, depth: Int,
                           into placements: inout [(Int, Matrix)]) {
        guard case .ref(let r) = ref, let s = doc.stream(ref), depth < 16, !activeForms.contains(r.num) else { return }
        let formMatrix = Matrix((doc.resolve(s.dict["Matrix"] ?? .null).arrayValue ?? []).compactMap { doc.resolve($0).doubleValue })
        let base = formMatrix.concat(ctm)
        let ownRes = doc.resolveDict(s.dict["Resources"])
        let relative: [(Int, Matrix)]
        if let cached = formCache[r.num], ownRes != nil {
            relative = cached
        } else {
            activeForms.insert(r.num)
            var local: [(Int, Matrix)] = []
            scan(decode(s) ?? [], resources: ownRes ?? parentResources, depth: depth, into: &local)
            activeForms.remove(r.num)
            if ownRes != nil { formCache[r.num] = local }
            relative = local
        }
        for (num, m) in relative { placements.append((num, m.concat(base))) }
    }

    /// Scans a content stream; placements are relative to the stream's space.
    private func scan(_ data: [UInt8], resources: PDFDict, depth: Int, into placements: inout [(Int, Matrix)]) {
        guard !data.isEmpty else { return }
        let xobjects = doc.resolveDict(resources["XObject"])
        let patterns = doc.resolveDict(resources["Pattern"])
        // Tiling patterns (macOS Quartz / "Save as PDF" paint images this way):
        // the selected pattern is drawn when an area is filled or stroked.
        var fillPattern: String? = nil
        var strokePattern: String? = nil
        var placedPatterns = Set<String>()
        func paint(_ name: String?) {
            guard let n = name, !placedPatterns.contains(n), let p = patterns?[n], doc.stream(p) != nil else { return }
            placedPatterns.insert(n)
            // Pattern space is the default space of this content stream, not the CTM.
            placeForm(p, ctm: .identity, parentResources: resources, depth: depth + 1, into: &placements)
        }
        var lx = PDFLexer(data)
        var ctm = Matrix.identity
        var stack: [Matrix] = []
        var nums: [Double] = []
        var lastName: String? = nil
        while true {
            let t = lx.nextToken()
            switch t {
            case .eof:
                return
            case .int(let v): nums.append(Double(v))
            case .real(let v): nums.append(v)
            case .name(let n): lastName = n
            case .keyword(let op):
                switch op {
                case "q":
                    if stack.count < 512 { stack.append(ctm) }
                case "Q":
                    if let m = stack.popLast() { ctm = m }
                case "cm":
                    if nums.count >= 6 {
                        ctm = Matrix(Array(nums.suffix(6))).concat(ctm)
                    }
                case "Do":
                    if let n = lastName, let xo = xobjects?[n], case .ref(let r) = xo,
                       let s = doc.stream(xo) {
                        let subtype = doc.resolve(s.dict["Subtype"] ?? .null).nameValue
                        if subtype == "Image" {
                            placements.append((r.num, ctm))
                        } else if subtype == "Form" {
                            placeForm(xo, ctm: ctm, parentResources: resources, depth: depth + 1, into: &placements)
                        }
                    }
                case "scn":
                    if let n = lastName, patterns?[n] != nil { fillPattern = n }
                case "SCN":
                    if let n = lastName, patterns?[n] != nil { strokePattern = n }
                case "cs", "sc", "g", "rg", "k":
                    if op != "cs" || lastName != "Pattern" { fillPattern = nil }
                case "CS", "SC", "G", "RG", "K":
                    if op != "CS" || lastName != "Pattern" { strokePattern = nil }
                case "f", "F", "f*", "B", "B*", "b", "b*":
                    paint(fillPattern)
                    if op.hasPrefix("B") || op.hasPrefix("b") { paint(strokePattern) }
                case "S", "s":
                    paint(strokePattern)
                case "Tj", "TJ", "'", "\"":
                    paint(fillPattern)
                case "BI":
                    skipInlineImage(&lx)
                default:
                    break
                }
                nums.removeAll(keepingCapacity: true)
                lastName = nil
            default:
                if nums.count > 64 { nums.removeFirst(nums.count - 6) }
            }
        }
    }

    private func skipInlineImage(_ lx: inout PDFLexer) {
        // skip dictionary entries until ID
        while true {
            let t = lx.nextToken()
            if case .eof = t { return }
            if case .keyword("ID") = t { break }
        }
        var i = lx.pos + 1
        let buf = lx.buf
        while i + 2 <= lx.end {
            if buf[i] == 0x45 && i + 1 < lx.end && buf[i + 1] == 0x49 && isPDFWhitespace(buf[i - 1])
                && (i + 2 == lx.end || isPDFWhitespace(buf[i + 2]) || isPDFDelimiter(buf[i + 2])) {
                lx.pos = i + 2
                return
            }
            i += 1
        }
        lx.pos = lx.end
    }
}
