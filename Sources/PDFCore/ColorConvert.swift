import CCodecs
import Foundation

// MARK: - Raster color conversion

extension Raster {
    /// Converts gray/RGB/CMYK samples to 8-bit gray (0 = black).
    /// `decode` is the image /Decode array (applied here, so drop it afterwards).
    func toGray(decode: [Double]?) -> Raster {
        let n = width * height
        var out = [UInt8](repeating: 0, count: n)
        let c = components
        var lo = [Double](repeating: 0, count: c), span = [Double](repeating: 1, count: c)
        if let d = decode, d.count >= 2 * c {
            for k in 0..<c { lo[k] = d[2 * k]; span[k] = d[2 * k + 1] - d[2 * k] }
        }
        let identity = lo.allSatisfy { $0 == 0 } && span.allSatisfy { $0 == 1 }
        pixels.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for i in 0..<n {
                    let o = i * c
                    @inline(__always) func v(_ k: Int) -> Double {
                        let x = Double(src[o + k]) / 255
                        return identity ? x : lo[k] + x * span[k]
                    }
                    let g: Double
                    switch c {
                    case 1: g = v(0)
                    case 3: g = 0.299 * v(0) + 0.587 * v(1) + 0.114 * v(2)
                    case 4: g = 1 - min(1, 0.30 * v(0) + 0.59 * v(1) + 0.11 * v(2) + v(3))
                    default: g = v(0)
                    }
                    let b = (g * 255).rounded()
                    dst[i] = b <= 0 ? 0 : (b >= 255 ? 255 : UInt8(b))
                }
            }
        }
        return Raster(width: width, height: height, components: 1, pixels: out)
    }

    private func histogram() -> [Int] {
        var h = [Int](repeating: 0, count: 256)
        let step = max(1, (width * height) / 400_000)
        var i = 0
        while i < pixels.count { h[Int(pixels[i])] += 1; i += step }
        return h
    }

    private static func percentile(_ h: [Int], _ p: Double) -> Int {
        let total = h.reduce(0, +)
        let target = Double(total) * p
        var acc = 0
        for v in 0..<256 {
            acc += h[v]
            if Double(acc) >= target { return v }
        }
        return 255
    }

    /// Heuristic for gray rasters: documents / text scans have almost all pixels
    /// near the paper or ink level; photos have many mid-tones.
    func looksLikeText() -> Bool {
        let h = histogram()
        let p2 = Raster.percentile(h, 0.02), p98 = Raster.percentile(h, 0.98)
        let range = p98 - p2
        if range < 40 { return true } // almost blank
        let lo = Double(p2) + Double(range) * 0.2, hi = Double(p2) + Double(range) * 0.8
        var mid = 0, total = 0
        for v in 0..<256 {
            total += h[v]
            if Double(v) > lo && Double(v) < hi { mid += h[v] }
        }
        return total > 0 && Double(mid) / Double(total) < 0.12
    }

    private static func otsu(_ h: [Int]) -> Int {
        let total = h.reduce(0, +)
        var sum = 0.0
        for i in 0..<256 { sum += Double(i * h[i]) }
        var sumB = 0.0, wB = 0, best = 0.0, threshold = 127
        for t in 0..<256 {
            wB += h[t]
            if wB == 0 { continue }
            let wF = total - wB
            if wF == 0 { break }
            sumB += Double(t * h[t])
            let mB = sumB / Double(wB), mF = (sum - sumB) / Double(wF)
            let between = Double(wB) * Double(wF) * (mB - mF) * (mB - mF)
            if between > best { best = between; threshold = t }
        }
        return threshold
    }

    /// Gray -> 1 byte per pixel, 1 = black. Global Otsu threshold combined with an
    /// adaptive (local mean) one so faint text on uneven paper survives.
    func binarized() -> [UInt8] {
        let h = histogram()
        let t = Raster.otsu(h)
        let p98 = Raster.percentile(h, 0.98)
        let soft = t + (p98 - t) / 2
        let w = width, ht = height
        // integral image
        var integral = [Int64](repeating: 0, count: (w + 1) * (ht + 1))
        pixels.withUnsafeBufferPointer { px in
            for y in 0..<ht {
                var row: Int64 = 0
                for x in 0..<w {
                    row += Int64(px[y * w + x])
                    integral[(y + 1) * (w + 1) + x + 1] = integral[y * (w + 1) + x + 1] + row
                }
            }
        }
        let r = max(4, min(w, ht) / 16)
        var out = [UInt8](repeating: 0, count: w * ht)
        pixels.withUnsafeBufferPointer { px in
            for y in 0..<ht {
                let y0 = max(0, y - r), y1 = min(ht, y + r + 1)
                for x in 0..<w {
                    let v = Int(px[y * w + x])
                    if v <= t { out[y * w + x] = 1; continue }
                    if v >= soft { continue }
                    let x0 = max(0, x - r), x1 = min(w, x + r + 1)
                    let s = integral[y1 * (w + 1) + x1] - integral[y0 * (w + 1) + x1]
                        - integral[y1 * (w + 1) + x0] + integral[y0 * (w + 1) + x0]
                    let count = Int64((x1 - x0) * (y1 - y0))
                    if Int64(v) * count * 100 < s * 85 { out[y * w + x] = 1 }
                }
            }
        }
        return out
    }
}

enum CCITT {
    static func encodeG4(_ bits: [UInt8], width: Int, height: Int) -> [UInt8]? {
        var out: UnsafeMutablePointer<UInt8>? = nil
        var len = 0
        let rc = bits.withUnsafeBufferPointer { bp in
            ccodecs_ccitt_g4_encode(bp.baseAddress, Int32(width), Int32(height), &out, &len)
        }
        guard rc == 0, let p = out else { return nil }
        defer { ccodecs_free(p) }
        return Array(UnsafeBufferPointer(start: p, count: len))
    }
}

// MARK: - Content streams: colors of text and vector graphics to gray

/// Rewrites color operators (rg, k, cs + sc/scn …) in content streams to
/// DeviceGray. Everything else is copied byte for byte. Spot colors, patterns,
/// shadings and inline images are left as they are.
final class ContentGrayConverter {
    private enum Space { case gray, rgb, cmyk, untouched }

    private let doc: PDFDocumentModel
    private var visited = Set<Int>()
    /// Converted (decoded) data per stream object number.
    private(set) var results: [Int: [UInt8]] = [:]

    init(doc: PDFDocumentModel) { self.doc = doc }

    func convertPage(_ page: PDFDocumentModel.PageInfo) {
        let contents = page.dict["Contents"]
        var refs: [PDFObject] = []
        if let c = contents {
            if doc.stream(c) != nil { refs = [c] } else { refs = doc.resolve(c).arrayValue ?? [] }
        }
        var state = (fill: Space.gray, stroke: Space.gray, stack: [(Space, Space)]())
        for r in refs {
            guard case .ref(let ref) = r, !visited.contains(ref.num), let s = doc.stream(r),
                  let data = decoded(s) else { continue }
            visited.insert(ref.num)
            if let new = convert(data, resources: page.resources, state: &state) { results[ref.num] = new }
        }
        convertResources(page.resources, depth: 0)
        for annot in doc.resolve(page.dict["Annots"] ?? .null).arrayValue ?? [] {
            guard let ad = doc.resolveDict(annot), let ap = doc.resolveDict(ad["AP"]) else { continue }
            for (_, v) in ap.entries {
                if doc.stream(v) != nil { convertForm(v, parent: page.resources, depth: 1) }
                else if let states = doc.resolveDict(v) {
                    for (_, sv) in states.entries { convertForm(sv, parent: page.resources, depth: 1) }
                }
            }
        }
    }

    private func convertResources(_ res: PDFDict, depth: Int) {
        guard depth < 12 else { return }
        for key in ["XObject", "Pattern"] {
            guard let d = doc.resolveDict(res[key]) else { continue }
            for (_, v) in d.entries {
                guard let s = doc.stream(v) else { continue }
                let subtype = doc.resolve(s.dict["Subtype"] ?? .null).nameValue
                let isTiling = doc.resolve(s.dict["PatternType"] ?? .null).intValue == 1
                if subtype == "Form" || isTiling { convertForm(v, parent: res, depth: depth + 1) }
            }
        }
    }

    private func convertForm(_ obj: PDFObject, parent: PDFDict, depth: Int) {
        guard case .ref(let r) = obj, !visited.contains(r.num), let s = doc.stream(obj), depth < 12 else { return }
        visited.insert(r.num)
        let res = doc.resolveDict(s.dict["Resources"]) ?? parent
        if let data = decoded(s) {
            var state = (fill: Space.gray, stroke: Space.gray, stack: [(Space, Space)]())
            if let new = convert(data, resources: res, state: &state) { results[r.num] = new }
        }
        convertResources(res, depth: depth)
    }

    private func decoded(_ s: PDFStream) -> [UInt8]? {
        let (f, p) = Filters.filterChain(s.dict, resolve: doc.resolve)
        guard let dec = try? Filters.decode(s.data, filters: f, parms: p, resolve: doc.resolve),
              dec.remainingFilters.isEmpty else { return nil }
        return dec.data
    }

    private func space(named n: String, resources: PDFDict) -> (Space, Bool) {
        switch n {
        case "DeviceGray", "G": return (.gray, false)
        case "DeviceRGB", "RGB": return (.rgb, true)
        case "DeviceCMYK", "CMYK": return (.cmyk, true)
        default: break
        }
        guard let csd = doc.resolveDict(resources["ColorSpace"]), let cs = csd[n] else { return (.untouched, false) }
        let arr = doc.resolve(cs).arrayValue ?? []
        let family = arr.first.map(doc.resolve)?.nameValue ?? doc.resolve(cs).nameValue ?? ""
        switch family {
        case "CalRGB", "DeviceRGB": return (.rgb, true)
        case "CalGray", "DeviceGray": return (.gray, true)
        case "DeviceCMYK": return (.cmyk, true)
        case "ICCBased":
            guard arr.count >= 2, let s = doc.stream(arr[1]) else { return (.untouched, false) }
            switch doc.resolve(s.dict["N"] ?? .null).intValue {
            case 1: return (.gray, true)
            case 3: return (.rgb, true)
            case 4: return (.cmyk, true)
            default: return (.untouched, false)
            }
        default:
            return (.untouched, false)
        }
    }

    private func gray(_ nums: [Double], _ sp: Space) -> Double? {
        switch sp {
        case .gray where nums.count == 1: return nums[0]
        case .rgb where nums.count == 3: return 0.299 * nums[0] + 0.587 * nums[1] + 0.114 * nums[2]
        case .cmyk where nums.count == 4:
            return 1 - min(1, 0.30 * nums[0] + 0.59 * nums[1] + 0.11 * nums[2] + nums[3])
        default: return nil
        }
    }

    private func fmt(_ v: Double) -> String { PDFSerializer.formatReal((min(1, max(0, v)) * 10000).rounded() / 10000) }

    private func convert(_ data: [UInt8], resources: PDFDict,
                         state: inout (fill: Space, stroke: Space, stack: [(Space, Space)])) -> [UInt8]? {
        var lx = PDFLexer(data)
        var out: [UInt8] = []
        out.reserveCapacity(data.count)
        var copyFrom = 0
        var operandStart: Int? = nil
        var nums: [Double] = []
        var names: [String] = []
        var changed = false

        func replace(_ text: String) {
            guard let s = operandStart else { return }
            out.append(contentsOf: data[copyFrom..<s])
            out.append(contentsOf: Array(text.utf8))
            copyFrom = lx.pos
            changed = true
        }

        while true {
            lx.skipWhitespace()
            let start = lx.pos
            let tok = lx.nextToken()
            switch tok {
            case .eof:
                if !changed { return nil }
                out.append(contentsOf: data[copyFrom...])
                return out
            case .int(let v):
                if operandStart == nil { operandStart = start }
                nums.append(Double(v))
            case .real(let v):
                if operandStart == nil { operandStart = start }
                nums.append(v)
            case .name(let n):
                if operandStart == nil { operandStart = start }
                names.append(n)
            case .keyword(let op):
                switch op {
                case "q":
                    state.stack.append((state.fill, state.stroke))
                case "Q":
                    if let s = state.stack.popLast() { state.fill = s.0; state.stroke = s.1 }
                case "g": state.fill = .gray
                case "G": state.stroke = .gray
                case "rg", "RG", "k", "K":
                    let sp: Space = (op == "rg" || op == "RG") ? .rgb : .cmyk
                    if names.isEmpty, let g = gray(Array(nums.suffix(sp == .rgb ? 3 : 4)), sp) {
                        replace("\(fmt(g)) \(op == "rg" || op == "k" ? "g" : "G")")
                    }
                    if op == "rg" || op == "k" { state.fill = .gray } else { state.stroke = .gray }
                case "cs", "CS":
                    if let n = names.last {
                        let (sp, rewrite) = space(named: n, resources: resources)
                        if rewrite { replace("/DeviceGray \(op)") }
                        if op == "cs" { state.fill = sp } else { state.stroke = sp }
                    }
                case "sc", "scn", "SC", "SCN":
                    let sp = (op == "sc" || op == "scn") ? state.fill : state.stroke
                    if names.isEmpty, sp == .rgb || sp == .cmyk, let g = gray(nums, sp) {
                        replace("\(fmt(g)) \(op)")
                    }
                case "BI":
                    // copy inline image verbatim
                    while true {
                        let t = lx.nextToken()
                        if case .eof = t { break }
                        if case .keyword("ID") = t { break }
                    }
                    var i = lx.pos + 1
                    while i + 2 <= lx.end {
                        if data[i] == 0x45 && data[i + 1] == 0x49 && isPDFWhitespace(data[i - 1])
                            && (i + 2 == lx.end || isPDFWhitespace(data[i + 2]) || isPDFDelimiter(data[i + 2])) {
                            break
                        }
                        i += 1
                    }
                    lx.pos = min(lx.end, i + 2)
                default:
                    break
                }
                operandStart = nil
                nums.removeAll(keepingCapacity: true)
                names.removeAll(keepingCapacity: true)
            default:
                if operandStart == nil { operandStart = start }
            }
        }
    }
}
