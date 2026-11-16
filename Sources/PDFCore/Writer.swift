import Foundation

/// Serializes PDF objects.
struct PDFSerializer {
    var out: [UInt8] = []

    init(capacity: Int = 0) { out.reserveCapacity(capacity) }

    @inline(__always) private mutating func token(_ bytes: [UInt8]) {
        if let last = out.last, let first = bytes.first, isPDFRegular(last), isPDFRegular(first) {
            out.append(0x20)
        }
        out.append(contentsOf: bytes)
    }

    @inline(__always) mutating func raw(_ s: String) { out.append(contentsOf: Array(s.utf8)) }

    static func formatReal(_ v: Double) -> String {
        guard v.isFinite else { return "0" }
        if v == v.rounded() && abs(v) < 1e15 { return String(Int(v)) }
        var s = String(format: "%.6f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        if s == "-0" || s.isEmpty { s = "0" }
        if s.hasPrefix("0.") { s.removeFirst() }
        else if s.hasPrefix("-0.") { s = "-" + s.dropFirst(2) }
        return s
    }

    static func nameBytes(_ name: String) -> [UInt8] {
        var b: [UInt8] = [0x2F]
        let hex = Array("0123456789ABCDEF".utf8)
        for c in latin1Bytes(name) {
            if c < 0x21 || c > 0x7E || c == 0x23 || isPDFDelimiter(c) {
                b.append(0x23); b.append(hex[Int(c >> 4)]); b.append(hex[Int(c & 0xF)])
            } else {
                b.append(c)
            }
        }
        return b
    }

    static func stringBytes(_ s: [UInt8]) -> [UInt8] {
        var b: [UInt8] = [0x28]
        b.reserveCapacity(s.count + 2)
        for c in s {
            switch c {
            case 0x28, 0x29, 0x5C: b.append(0x5C); b.append(c)
            case 0x0D: b.append(0x5C); b.append(0x72)
            default: b.append(c)
            }
        }
        b.append(0x29)
        return b
    }

    mutating func write(_ o: PDFObject, refMap: (PDFRef) -> PDFRef?) {
        switch o {
        case .null: token(Array("null".utf8))
        case .bool(let v): token(Array((v ? "true" : "false").utf8))
        case .int(let v): token(Array(String(v).utf8))
        case .real(let v): token(Array(Self.formatReal(v).utf8))
        case .name(let n): out.append(contentsOf: Self.nameBytes(n))
        case .string(let s): out.append(contentsOf: Self.stringBytes(s))
        case .array(let a):
            out.append(0x5B)
            for item in a { write(item, refMap: refMap) }
            out.append(0x5D)
        case .dict(let d):
            out.append(0x3C); out.append(0x3C)
            for (k, v) in d.entries {
                out.append(contentsOf: Self.nameBytes(k))
                write(v, refMap: refMap)
            }
            out.append(0x3E); out.append(0x3E)
        case .ref(let r):
            if let m = refMap(r) {
                token(Array("\(m.num) \(m.gen) R".utf8))
            } else {
                token(Array("null".utf8))
            }
        }
    }
}

/// Writes a complete PDF with compressed object streams and an xref stream.
enum PDFFileWriter {
    /// `objects` must be numbered 1...N without gaps. References are written as-is.
    static func write(objects: [PDFIndirect], root: PDFRef, info: PDFRef?, fileID: [UInt8],
                      version: String) -> [UInt8] {
        let identity: (PDFRef) -> PDFRef? = { r in
            (r.num >= 1 && r.num <= objects.count) ? PDFRef(r.num, 0) : nil
        }
        var ver = version
        if (Double(ver) ?? 1.4) < 1.5 { ver = "1.5" }

        var w = PDFSerializer(capacity: 1 << 20)
        w.raw("%PDF-\(ver)\n")
        w.out.append(contentsOf: [0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A])

        let n = objects.count
        // xref entries: type, field2, field3
        var entries = [(Int, Int, Int)](repeating: (0, 0, 0), count: n + 1)
        entries[0] = (0, 0, 65535)

        // 1. Streams, written directly
        var pending: [Int] = []
        for (i, obj) in objects.enumerated() {
            let num = i + 1
            switch obj {
            case .stream(let s):
                entries[num] = (1, w.out.count, 0)
                w.raw("\(num) 0 obj\n")
                var d = s.dict
                d["Length"] = .int(s.data.count)
                w.write(.dict(d), refMap: identity)
                w.raw("\nstream\n")
                w.out.append(contentsOf: s.data)
                w.raw("\nendstream\nendobj\n")
            case .object:
                pending.append(num)
            }
        }

        // 2. Other objects packed into object streams
        var nextNum = n + 1
        var objStmEntries: [(Int, Int, Int)] = []
        let chunk = 120
        var idx = 0
        while idx < pending.count {
            let group = Array(pending[idx..<min(idx + chunk, pending.count)])
            idx += chunk
            let stmNum = nextNum
            nextNum += 1
            var body = PDFSerializer(capacity: 4096)
            var header = ""
            for (k, num) in group.enumerated() {
                if case .object(let o) = objects[num - 1] {
                    header += "\(num) \(body.out.count) "
                    body.write(o, refMap: identity)
                    body.out.append(0x0A)
                }
                entries[num] = (2, stmNum, k)
            }
            let headerBytes = Array(header.utf8)
            let plain = headerBytes + body.out
            var d = PDFDict()
            d["Type"] = .name("ObjStm")
            d["N"] = .int(group.count)
            d["First"] = .int(headerBytes.count)
            var data = plain
            if let z = Zlib.deflate(plain), z.count < plain.count {
                d["Filter"] = .name("FlateDecode")
                data = z
            }
            d["Length"] = .int(data.count)
            objStmEntries.append((1, w.out.count, 0))
            w.raw("\(stmNum) 0 obj\n")
            w.write(.dict(d), refMap: { $0 })
            w.raw("\nstream\n")
            w.out.append(contentsOf: data)
            w.raw("\nendstream\nendobj\n")
        }
        entries.append(contentsOf: objStmEntries)

        // 3. XRef stream
        let xrefNum = nextNum
        let xrefOffset = w.out.count
        entries.append((1, xrefOffset, 0))
        let size = entries.count
        var maxF2 = 0
        for e in entries { maxF2 = max(maxF2, e.1) }
        var w2 = 1
        while (1 << (8 * w2)) <= maxF2 { w2 += 1 }
        var table: [UInt8] = []
        table.reserveCapacity(size * (3 + w2))
        for e in entries {
            table.append(UInt8(e.0))
            for b in stride(from: w2 - 1, through: 0, by: -1) { table.append(UInt8((e.1 >> (8 * b)) & 0xFF)) }
            table.append(UInt8((e.2 >> 8) & 0xFF)); table.append(UInt8(e.2 & 0xFF))
        }
        var xd = PDFDict()
        xd["Type"] = .name("XRef")
        xd["Size"] = .int(size)
        xd["W"] = .array([.int(1), .int(w2), .int(2)])
        xd["Root"] = .ref(root)
        if let info = info { xd["Info"] = .ref(info) }
        xd["ID"] = .array([.string(fileID), .string(fileID)])
        var xdata = table
        let predicted = Filters.pngPredict(table, rowLen: 3 + w2, bpp: 1)
        if let z = Zlib.deflate(predicted) {
            xd["Filter"] = .name("FlateDecode")
            xd["DecodeParms"] = .dict(PDFDict([("Predictor", .int(12)), ("Columns", .int(3 + w2))]))
            xdata = z
        }
        xd["Length"] = .int(xdata.count)
        w.raw("\(xrefNum) 0 obj\n")
        w.write(.dict(xd), refMap: { $0 })
        w.raw("\nstream\n")
        w.out.append(contentsOf: xdata)
        w.raw("\nendstream\nendobj\nstartxref\n\(xrefOffset)\n%%EOF\n")
        return w.out
    }
}
