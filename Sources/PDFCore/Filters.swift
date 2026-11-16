import Foundation
import CCodecs

enum Zlib {
    static func deflate(_ data: [UInt8], level: Int = 9) -> [UInt8]? {
        var out: UnsafeMutablePointer<UInt8>? = nil
        var outLen = 0
        let rc = data.withUnsafeBufferPointer { bp -> Int32 in
            ccodecs_deflate(bp.baseAddress, bp.count, Int32(level), &out, &outLen)
        }
        guard rc == 0, let p = out else { return nil }
        defer { ccodecs_free(p) }
        return Array(UnsafeBufferPointer(start: p, count: outLen))
    }

    /// Returns nil on hard failure. Partial data on truncated streams is accepted
    /// only when `allowPartial` is set.
    static func inflate(_ data: [UInt8], allowPartial: Bool) -> [UInt8]? {
        if data.isEmpty { return [] }
        var out: UnsafeMutablePointer<UInt8>? = nil
        var outLen = 0
        let rc = data.withUnsafeBufferPointer { bp -> Int32 in
            ccodecs_inflate(bp.baseAddress, bp.count, &out, &outLen)
        }
        guard rc >= 0, let p = out else { return nil }
        defer { ccodecs_free(p) }
        if rc == 1 && !allowPartial { return nil }
        return Array(UnsafeBufferPointer(start: p, count: outLen))
    }
}

enum FilterError: Error { case unsupported(String), corrupt(String) }

/// Result of decoding a stream as far as possible.
struct DecodedStream {
    var data: [UInt8]
    /// Filters still applied to `data` (image codecs we do not decode here).
    var remainingFilters: [String]
    var remainingParms: [PDFObject]
}

enum Filters {
    static let losslessDecodable: Set<String> = [
        "FlateDecode", "Fl", "LZWDecode", "LZW", "ASCIIHexDecode", "AHx",
        "ASCII85Decode", "A85", "RunLengthDecode", "RL",
    ]

    static func normalize(_ name: String) -> String {
        switch name {
        case "Fl": return "FlateDecode"
        case "LZW": return "LZWDecode"
        case "AHx": return "ASCIIHexDecode"
        case "A85": return "ASCII85Decode"
        case "RL": return "RunLengthDecode"
        case "DCT": return "DCTDecode"
        case "CCF": return "CCITTFaxDecode"
        default: return name
        }
    }

    /// Filter names and parameters of a stream dictionary, resolved through `resolver`.
    static func filterChain(_ dict: PDFDict, resolve: (PDFObject) -> PDFObject) -> ([String], [PDFObject]) {
        var names: [String] = []
        var parms: [PDFObject] = []
        if let f = dict["Filter"].map(resolve) {
            switch f {
            case .name(let n): names = [n]
            case .array(let a): names = a.compactMap { resolve($0).nameValue }
            default: break
            }
        }
        let p = dict["DecodeParms"].map(resolve) ?? dict["DP"].map(resolve)
        switch p {
        case .some(.array(let a)): parms = a.map(resolve)
        case .some(let o): parms = [o]
        case .none: break
        }
        while parms.count < names.count { parms.append(.null) }
        return (names.map(normalize), parms)
    }

    /// Decodes the lossless part of a filter chain. Stops at the first image codec
    /// (DCT, JPX, CCITT, JBIG2...) and returns it as remaining.
    static func decode(_ data: [UInt8], filters: [String], parms: [PDFObject],
                       resolve: (PDFObject) -> PDFObject, allowPartial: Bool = false) throws -> DecodedStream {
        var cur = data
        for (i, f) in filters.enumerated() {
            let p = resolve(parms[i]).dictValue
            switch f {
            case "FlateDecode":
                guard let d = Zlib.inflate(cur, allowPartial: allowPartial) else { throw FilterError.corrupt("Flate") }
                cur = try applyPredictor(d, parms: p)
            case "LZWDecode":
                let early = p?.int("EarlyChange") ?? 1
                cur = try applyPredictor(lzwDecode(cur, earlyChange: early != 0), parms: p)
            case "ASCIIHexDecode":
                cur = asciiHexDecode(cur)
            case "ASCII85Decode":
                cur = try ascii85Decode(cur)
            case "RunLengthDecode":
                cur = runLengthDecode(cur)
            case "Crypt":
                // Identity crypt filter (the only kind we can meet after decryption)
                continue
            default:
                return DecodedStream(data: cur, remainingFilters: Array(filters[i...]),
                                     remainingParms: Array(parms[i...]))
            }
        }
        return DecodedStream(data: cur, remainingFilters: [], remainingParms: [])
    }

    // MARK: Predictors

    static func applyPredictor(_ data: [UInt8], parms: PDFDict?) throws -> [UInt8] {
        guard let parms = parms, let predictor = parms.int("Predictor"), predictor > 1 else { return data }
        let colors = max(1, parms.int("Colors") ?? 1)
        let bpc = max(1, parms.int("BitsPerComponent") ?? 8)
        let columns = max(1, parms.int("Columns") ?? 1)
        let bpp = max(1, (colors * bpc + 7) / 8)
        let rowLen = (colors * bpc * columns + 7) / 8

        if predictor == 2 {
            guard bpc == 8 else { return data } // rare; leave as is
            var out = data
            var r = 0
            while r + rowLen <= out.count {
                for i in r + bpp ..< r + rowLen { out[i] = out[i] &+ out[i - bpp] }
                r += rowLen
            }
            return out
        }
        guard predictor >= 10 else { return data }
        var out = [UInt8]()
        out.reserveCapacity(data.count)
        var prev = [UInt8](repeating: 0, count: rowLen)
        var cur = [UInt8](repeating: 0, count: rowLen)
        var i = 0
        while i < data.count {
            let type = data[i]
            i += 1
            let n = min(rowLen, data.count - i)
            if n <= 0 { break }
            for k in 0..<n { cur[k] = data[i + k] }
            if n < rowLen { for k in n..<rowLen { cur[k] = 0 } }
            i += n
            switch type {
            case 0: break
            case 1:
                for k in bpp..<rowLen { cur[k] = cur[k] &+ cur[k - bpp] }
            case 2:
                for k in 0..<rowLen { cur[k] = cur[k] &+ prev[k] }
            case 3:
                for k in 0..<rowLen {
                    let left = k >= bpp ? Int(cur[k - bpp]) : 0
                    cur[k] = cur[k] &+ UInt8((left + Int(prev[k])) / 2)
                }
            case 4:
                for k in 0..<rowLen {
                    let a = k >= bpp ? Int(cur[k - bpp]) : 0
                    let b = Int(prev[k])
                    let c = k >= bpp ? Int(prev[k - bpp]) : 0
                    cur[k] = cur[k] &+ UInt8(paeth(a, b, c))
                }
            default:
                break
            }
            out.append(contentsOf: cur[0..<n])
            swap(&prev, &cur)
            // keep `cur` content irrelevant: it is overwritten next row
        }
        return out
    }

    @inline(__always) static func paeth(_ a: Int, _ b: Int, _ c: Int) -> Int {
        let p = a + b - c
        let pa = abs(p - a), pb = abs(p - b), pc = abs(p - c)
        if pa <= pb && pa <= pc { return a }
        if pb <= pc { return b }
        return c
    }

    /// PNG-predicts rows (adaptive per row, minimum sum of absolute differences).
    static func pngPredict(_ data: [UInt8], rowLen: Int, bpp: Int) -> [UInt8] {
        let rows = data.count / rowLen
        var out = [UInt8]()
        out.reserveCapacity(rows * (rowLen + 1))
        var cand = [[UInt8]](repeating: [UInt8](repeating: 0, count: rowLen), count: 5)
        let zero = [UInt8](repeating: 0, count: rowLen)
        for r in 0..<rows {
            let base = r * rowLen
            let pbase = (r - 1) * rowLen
            var bestType = 0
            var bestScore = Int.max
            for t in 0..<5 {
                var score = 0
                for k in 0..<rowLen {
                    let x = data[base + k]
                    let a: UInt8 = k >= bpp ? data[base + k - bpp] : 0
                    let b: UInt8 = r > 0 ? data[pbase + k] : zero[k]
                    let c: UInt8 = (r > 0 && k >= bpp) ? data[pbase + k - bpp] : 0
                    let v: UInt8
                    switch t {
                    case 0: v = x
                    case 1: v = x &- a
                    case 2: v = x &- b
                    case 3: v = x &- UInt8((Int(a) + Int(b)) / 2)
                    default: v = x &- UInt8(paeth(Int(a), Int(b), Int(c)))
                    }
                    cand[t][k] = v
                    score += v < 128 ? Int(v) : 256 - Int(v)
                }
                if score < bestScore { bestScore = score; bestType = t }
            }
            out.append(UInt8(bestType))
            out.append(contentsOf: cand[bestType])
        }
        return out
    }

    // MARK: Other decoders

    static func asciiHexDecode(_ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(data.count / 2)
        var hi: UInt8? = nil
        for c in data {
            if c == 0x3E { break }
            guard let v = hexValue(c) else { continue }
            if let h = hi { out.append(h << 4 | v); hi = nil } else { hi = v }
        }
        if let h = hi { out.append(h << 4) }
        return out
    }

    static func ascii85Decode(_ data: [UInt8]) throws -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(data.count * 4 / 5)
        var group: [UInt32] = []
        var i = 0
        if data.count >= 2 && data[0] == 0x3C && data[1] == 0x7E { i = 2 }
        while i < data.count {
            let c = data[i]
            i += 1
            if isPDFWhitespace(c) { continue }
            if c == 0x7E { break } // ~>
            if c == 0x7A && group.isEmpty { out.append(contentsOf: [0, 0, 0, 0]); continue }
            guard c >= 0x21 && c <= 0x75 else { throw FilterError.corrupt("A85") }
            group.append(UInt32(c - 0x21))
            if group.count == 5 {
                var v: UInt32 = 0
                for g in group { v = v &* 85 &+ g }
                out.append(UInt8(v >> 24)); out.append(UInt8((v >> 16) & 0xFF))
                out.append(UInt8((v >> 8) & 0xFF)); out.append(UInt8(v & 0xFF))
                group.removeAll(keepingCapacity: true)
            }
        }
        if group.count > 1 {
            let n = group.count
            while group.count < 5 { group.append(84) }
            var v: UInt32 = 0
            for g in group { v = v &* 85 &+ g }
            let bytes = [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
            out.append(contentsOf: bytes[0..<(n - 1)])
        }
        return out
    }

    static func runLengthDecode(_ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var i = 0
        while i < data.count {
            let len = Int(data[i])
            i += 1
            if len == 128 { break }
            if len < 128 {
                let n = min(len + 1, data.count - i)
                out.append(contentsOf: data[i..<(i + n)])
                i += n
            } else if i < data.count {
                out.append(contentsOf: repeatElement(data[i], count: 257 - len))
                i += 1
            }
        }
        return out
    }

    static func lzwDecode(_ data: [UInt8], earlyChange: Bool) throws -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(data.count * 3)
        var dict: [[UInt8]] = (0..<256).map { [UInt8($0)] }
        dict.append([]); dict.append([]) // 256 clear, 257 EOD
        var codeLen = 9
        var bitBuf: UInt32 = 0
        var bitCount = 0
        var prev: [UInt8]? = nil
        var i = 0
        let early = earlyChange ? 1 : 0
        while true {
            while bitCount < codeLen && i < data.count {
                bitBuf = (bitBuf << 8) | UInt32(data[i])
                bitCount += 8
                i += 1
            }
            if bitCount < codeLen { break }
            let code = Int((bitBuf >> UInt32(bitCount - codeLen)) & ((1 << UInt32(codeLen)) - 1))
            bitCount -= codeLen
            if code == 256 {
                dict.removeSubrange(258...)
                codeLen = 9
                prev = nil
                continue
            }
            if code == 257 { break }
            var entry: [UInt8]
            if code < dict.count {
                entry = dict[code]
                if let p = prev { dict.append(p + [entry[0]]) }
            } else if let p = prev, code == dict.count {
                entry = p + [p[0]]
                dict.append(entry)
            } else {
                break // corrupt
            }
            out.append(contentsOf: entry)
            prev = entry
            let size = dict.count + early
            if size >= 4096 { codeLen = 12 }
            else if size >= 2048 { codeLen = 12 }
            else if size >= 1024 { codeLen = 11 }
            else if size >= 512 { codeLen = 10 }
        }
        return out
    }
}
