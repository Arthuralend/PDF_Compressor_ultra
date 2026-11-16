import Foundation

@inline(__always) func isPDFWhitespace(_ c: UInt8) -> Bool {
    c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 || c == 0x0C || c == 0x00
}

@inline(__always) func isPDFDelimiter(_ c: UInt8) -> Bool {
    switch c {
    case 0x28, 0x29, 0x3C, 0x3E, 0x5B, 0x5D, 0x7B, 0x7D, 0x2F, 0x25: return true
    default: return false
    }
}

@inline(__always) func isPDFRegular(_ c: UInt8) -> Bool {
    !isPDFWhitespace(c) && !isPDFDelimiter(c)
}

@inline(__always) func hexValue(_ c: UInt8) -> UInt8? {
    switch c {
    case 0x30...0x39: return c - 0x30
    case 0x41...0x46: return c - 0x41 + 10
    case 0x61...0x66: return c - 0x61 + 10
    default: return nil
    }
}

func latin1String(_ bytes: [UInt8]) -> String {
    var s = String()
    s.unicodeScalars.reserveCapacity(bytes.count)
    for b in bytes { s.unicodeScalars.append(Unicode.Scalar(b)) }
    return s
}

func latin1Bytes(_ s: String) -> [UInt8] {
    s.unicodeScalars.map { $0.value < 256 ? UInt8($0.value) : 0x3F }
}

enum PDFToken {
    case int(Int)
    case real(Double)
    case name(String)
    case string([UInt8])
    case arrayOpen, arrayClose, dictOpen, dictClose
    case braceOpen, braceClose
    case keyword(String)
    case eof
}

/// Tokenizer + object parser working directly on a byte buffer.
struct PDFLexer {
    let buf: [UInt8]
    var pos: Int
    let end: Int

    init(_ buf: [UInt8], pos: Int = 0, end: Int? = nil) {
        self.buf = buf
        self.pos = pos
        self.end = min(end ?? buf.count, buf.count)
    }

    mutating func skipWhitespace() {
        while pos < end {
            let c = buf[pos]
            if isPDFWhitespace(c) {
                pos += 1
            } else if c == 0x25 { // % comment
                while pos < end && buf[pos] != 0x0A && buf[pos] != 0x0D { pos += 1 }
            } else {
                break
            }
        }
    }

    mutating func nextToken() -> PDFToken {
        skipWhitespace()
        guard pos < end else { return .eof }
        let c = buf[pos]
        switch c {
        case 0x5B: pos += 1; return .arrayOpen
        case 0x5D: pos += 1; return .arrayClose
        case 0x7B: pos += 1; return .braceOpen
        case 0x7D: pos += 1; return .braceClose
        case 0x3C:
            if pos + 1 < end && buf[pos + 1] == 0x3C { pos += 2; return .dictOpen }
            return .string(readHexString())
        case 0x3E:
            if pos + 1 < end && buf[pos + 1] == 0x3E { pos += 2; return .dictClose }
            pos += 1
            return .keyword(">")
        case 0x28:
            return .string(readLiteralString())
        case 0x29:
            pos += 1
            return .keyword(")")
        case 0x2F:
            return .name(readName())
        default:
            let start = pos
            while pos < end && isPDFRegular(buf[pos]) { pos += 1 }
            if pos == start { pos += 1; return .keyword(String(UnicodeScalar(c))) }
            return numberOrKeyword(start, pos)
        }
    }

    private func numberOrKeyword(_ start: Int, _ stop: Int) -> PDFToken {
        var isNumber = true
        var hasDot = false
        var digits = 0
        for i in start..<stop {
            let ch = buf[i]
            if ch >= 0x30 && ch <= 0x39 { digits += 1 }
            else if ch == 0x2E { hasDot = true }
            else if ch == 0x2B || ch == 0x2D { /* sign */ }
            else { isNumber = false; break }
        }
        if isNumber && digits > 0 {
            // tolerate things like "--5" or "5-": collapse to a sane value
            var negative = false
            var intPart: Int = 0
            var fracPart: Double = 0
            var fracScale: Double = 1
            var seenDot = false
            var seenDigit = false
            var overflow = false
            for i in start..<stop {
                let ch = buf[i]
                if ch == 0x2D { if !seenDigit && !seenDot { negative = true } }
                else if ch == 0x2E { seenDot = true }
                else if ch >= 0x30 && ch <= 0x39 {
                    seenDigit = true
                    let d = Int(ch - 0x30)
                    if seenDot {
                        fracScale /= 10
                        fracPart += Double(d) * fracScale
                    } else {
                        let (m, o1) = intPart.multipliedReportingOverflow(by: 10)
                        let (a, o2) = m.addingReportingOverflow(d)
                        if o1 || o2 { overflow = true } else { intPart = a }
                    }
                }
            }
            if hasDot || overflow {
                var v = Double(intPart) + fracPart
                if overflow { v = Double(String(decoding: buf[start..<stop], as: UTF8.self)) ?? 0 }
                return .real(negative ? -v : v)
            }
            return .int(negative ? -intPart : intPart)
        }
        return .keyword(String(decoding: buf[start..<stop], as: UTF8.self))
    }

    mutating func readName() -> String {
        pos += 1 // '/'
        var bytes: [UInt8] = []
        while pos < end {
            let c = buf[pos]
            if !isPDFRegular(c) { break }
            if c == 0x23, pos + 2 < end, let h = hexValue(buf[pos + 1]), let l = hexValue(buf[pos + 2]) {
                bytes.append(h << 4 | l)
                pos += 3
            } else {
                bytes.append(c)
                pos += 1
            }
        }
        return latin1String(bytes)
    }

    mutating func readHexString() -> [UInt8] {
        pos += 1 // '<'
        var out: [UInt8] = []
        var hi: UInt8? = nil
        while pos < end {
            let c = buf[pos]
            pos += 1
            if c == 0x3E { break }
            guard let v = hexValue(c) else { continue }
            if let h = hi { out.append(h << 4 | v); hi = nil } else { hi = v }
        }
        if let h = hi { out.append(h << 4) }
        return out
    }

    mutating func readLiteralString() -> [UInt8] {
        pos += 1 // '('
        var out: [UInt8] = []
        var depth = 1
        while pos < end {
            let c = buf[pos]
            pos += 1
            switch c {
            case 0x28:
                depth += 1
                out.append(c)
            case 0x29:
                depth -= 1
                if depth == 0 { return out }
                out.append(c)
            case 0x0D:
                out.append(0x0A)
                if pos < end && buf[pos] == 0x0A { pos += 1 }
            case 0x5C:
                guard pos < end else { return out }
                let e = buf[pos]
                pos += 1
                switch e {
                case 0x6E: out.append(0x0A)
                case 0x72: out.append(0x0D)
                case 0x74: out.append(0x09)
                case 0x62: out.append(0x08)
                case 0x66: out.append(0x0C)
                case 0x0D:
                    if pos < end && buf[pos] == 0x0A { pos += 1 }
                case 0x0A:
                    break
                case 0x30...0x37:
                    var v = Int(e - 0x30)
                    var n = 1
                    while n < 3 && pos < end && buf[pos] >= 0x30 && buf[pos] <= 0x37 {
                        v = v * 8 + Int(buf[pos] - 0x30)
                        pos += 1
                        n += 1
                    }
                    out.append(UInt8(truncatingIfNeeded: v))
                default:
                    out.append(e)
                }
            default:
                out.append(c)
            }
        }
        return out
    }

    // MARK: Object parsing

    /// Parses one object. Returns nil (and restores the position) when the next
    /// token cannot start an object (closing delimiter, unexpected keyword, EOF).
    mutating func parseObject(depth: Int = 0) -> PDFObject? {
        let save = pos
        let tok = nextToken()
        switch tok {
        case .int(let v):
            // look ahead for "gen R"
            let afterFirst = pos
            if case .int(let g) = nextToken(), g >= 0 {
                let afterSecond = pos
                if case .keyword("R") = nextToken(), v > 0 {
                    return .ref(PDFRef(v, g))
                }
                _ = afterSecond
            }
            pos = afterFirst
            return .int(v)
        case .real(let v): return .real(v)
        case .name(let n): return .name(n)
        case .string(let s): return .string(s)
        case .arrayOpen:
            var items: [PDFObject] = []
            while true {
                if depth > 200 { break }
                if let o = parseObject(depth: depth + 1) {
                    items.append(o)
                    continue
                }
                let t = nextToken()
                switch t {
                case .arrayClose, .eof: return .array(items)
                case .keyword(let k) where k == "endobj" || k == "stream" || k == "endstream":
                    pos = posBefore(keyword: k)
                    return .array(items)
                default: continue // skip garbage
                }
            }
            return .array(items)
        case .dictOpen:
            var d = PDFDict()
            while true {
                if depth > 200 { break }
                let kpos = pos
                let t = nextToken()
                switch t {
                case .dictClose, .eof: return .dict(d)
                case .name(let key):
                    if let v = parseObject(depth: depth + 1) {
                        if case .null = v { d[key] = nil } else { d[key] = v }
                    } else {
                        // missing value: peek what is next
                        let p2 = pos
                        let t2 = nextToken()
                        if case .dictClose = t2 { return .dict(d) }
                        if case .keyword(let k) = t2, k == "endobj" || k == "stream" {
                            pos = p2
                            return .dict(d)
                        }
                    }
                case .keyword(let k) where k == "endobj" || k == "stream" || k == "endstream":
                    pos = kpos
                    return .dict(d)
                default:
                    continue
                }
            }
            return .dict(d)
        case .keyword(let k):
            switch k {
            case "true": return .bool(true)
            case "false": return .bool(false)
            case "null": return .null
            default:
                pos = save
                return nil
            }
        case .braceOpen, .braceClose, .arrayClose, .dictClose, .eof:
            pos = save
            return nil
        }
    }

    private func posBefore(keyword k: String) -> Int { pos - k.utf8.count }

    /// Finds `pattern` starting at `from`, returns the index or nil.
    static func find(_ pattern: [UInt8], in buf: [UInt8], from: Int, to: Int? = nil) -> Int? {
        let limit = min(to ?? buf.count, buf.count) - pattern.count
        guard !pattern.isEmpty, from <= limit else { return nil }
        let first = pattern[0]
        var i = max(0, from)
        while i <= limit {
            if buf[i] == first {
                var ok = true
                for j in 1..<pattern.count where buf[i + j] != pattern[j] { ok = false; break }
                if ok { return i }
            }
            i += 1
        }
        return nil
    }

    static func findLast(_ pattern: [UInt8], in buf: [UInt8], before: Int? = nil, from: Int = 0) -> Int? {
        var i = min(before ?? buf.count, buf.count) - pattern.count
        while i >= from {
            var ok = true
            for j in 0..<pattern.count where buf[i + j] != pattern[j] { ok = false; break }
            if ok { return i }
            i -= 1
        }
        return nil
    }
}
