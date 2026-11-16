import Foundation

/// Parsed PDF file. Objects are loaded lazily from the xref table (or from a
/// full scan when the xref table is damaged) and cached.
public final class PDFDocumentModel {
    enum XRefEntry {
        case offset(Int, gen: Int)
        case compressed(objStm: Int, index: Int)
        case free
    }

    let buf: [UInt8]
    public private(set) var trailer = PDFDict()
    public private(set) var versionString = "1.4"
    var xref: [Int: XRefEntry] = [:]
    private var cache: [Int: PDFIndirect] = [:]
    private var loading: Set<Int> = []
    private var reconstructed = false
    private var security: StandardSecurity?
    private var encryptRef: PDFRef?
    public private(set) var wasEncrypted = false

    public init(data: [UInt8], password: String = "") throws {
        buf = data
        guard let header = PDFLexer.find(Array("%PDF-".utf8), in: buf, from: 0, to: min(buf.count, 1024)) else {
            throw PDFError(.notAPDF, "Файл не является PDF")
        }
        var v = ""
        var i = header + 5
        while i < buf.count && v.count < 4 && ((buf[i] >= 0x30 && buf[i] <= 0x39) || buf[i] == 0x2E) {
            v.append(Character(UnicodeScalar(buf[i])))
            i += 1
        }
        if !v.isEmpty { versionString = v }

        do {
            try loadXRefChain()
            guard trailer["Root"]?.refValue != nil, resolveDict(trailer["Root"]) != nil else {
                throw PDFError(.damaged, "no root")
            }
        } catch {
            try reconstruct()
        }
        try setupSecurity(password: password)
        if let catalogVersion = resolve(catalog["Version"] ?? .null).nameValue,
           Double(catalogVersion) ?? 0 > Double(versionString) ?? 0 {
            versionString = catalogVersion
        }
    }

    public convenience init(url: URL, password: String = "") throws {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw PDFError(.io, "Не удалось прочитать файл: \(error.localizedDescription)")
        }
        try self.init(data: [UInt8](data), password: password)
    }

    public var catalog: PDFDict { resolveDict(trailer["Root"]) ?? PDFDict() }
    public var maxObjectNumber: Int { max(xref.keys.max() ?? 0, cache.keys.max() ?? 0) }
    public var allObjectNumbers: [Int] {
        Array(Set(xref.compactMap { k, v -> Int? in if case .free = v { return nil }; return k })
            .union(cache.keys)).sorted()
    }

    // MARK: Resolution

    public func resolve(_ obj: PDFObject) -> PDFObject {
        var cur = obj
        var hops = 0
        while case .ref(let r) = cur, hops < 32 {
            guard let ind = indirect(r.num) else { return .null }
            switch ind {
            case .object(let o): cur = o
            case .stream: return cur // streams stay referenced
            }
            hops += 1
        }
        return cur
    }

    public func resolveDict(_ obj: PDFObject?) -> PDFDict? {
        guard let obj = obj else { return nil }
        if case .ref(let r) = obj, let ind = indirect(r.num) { return ind.dict }
        return resolve(obj).dictValue
    }

    public func stream(_ obj: PDFObject?) -> PDFStream? {
        guard case .ref(let r)? = obj else { return nil }
        return indirect(r.num)?.stream
    }

    public func indirect(_ num: Int) -> PDFIndirect? {
        if let c = cache[num] { return c }
        guard !loading.contains(num) else { return nil }
        loading.insert(num)
        defer { loading.remove(num) }
        var result = load(num)
        if result == nil && !reconstructed && xref[num] != nil {
            if (try? reconstruct()) != nil { result = load(num) }
        }
        if let r = result { cache[num] = r }
        return result
    }

    private func load(_ num: Int) -> PDFIndirect? {
        guard let entry = xref[num] else { return nil }
        switch entry {
        case .free: return nil
        case .offset(let off, _):
            guard let parsed = parseIndirect(at: off), parsed.0 == num else { return nil }
            return decryptIndirect(parsed.2, num: parsed.0, gen: parsed.1)
        case .compressed(let stm, let index):
            loadObjectStream(stm, wantIndex: index)
            return cache[num]
        }
    }

    // MARK: Parsing indirect objects

    /// Parses `n g obj ... endobj` at the given offset.
    func parseIndirect(at offset: Int) -> (Int, Int, PDFIndirect)? {
        guard offset >= 0 && offset < buf.count else { return nil }
        var lx = PDFLexer(buf, pos: offset)
        guard case .int(let num) = lx.nextToken(),
              case .int(let gen) = lx.nextToken(),
              case .keyword("obj") = lx.nextToken() else { return nil }
        let obj = lx.parseObject() ?? .null
        let save = lx.pos
        if case .keyword("stream") = lx.nextToken(), case .dict(let d) = obj {
            var start = lx.pos
            if start < buf.count && buf[start] == 0x0D { start += 1 }
            if start < buf.count && buf[start] == 0x0A { start += 1 }
            var length: Int? = nil
            if let l = d["Length"] {
                if case .ref(let r) = l {
                    if r.num != num, let ind = indirect(r.num), case .object(let o) = ind { length = o.intValue }
                } else {
                    length = l.intValue
                }
            }
            var end: Int? = nil
            if let len = length, len >= 0, start + len <= buf.count, endstreamFollows(start + len) {
                end = start + len
            }
            if end == nil {
                // Length missing or wrong: find "endstream"
                guard let es = PDFLexer.find(Array("endstream".utf8), in: buf, from: start) else { return nil }
                var e = es
                if e > start && buf[e - 1] == 0x0A { e -= 1 }
                if e > start && buf[e - 1] == 0x0D { e -= 1 }
                end = e
            }
            let data = Array(buf[start..<end!])
            return (num, gen, .stream(PDFStream(dict: d, data: data)))
        }
        lx.pos = save
        return (num, gen, .object(obj))
    }

    private func endstreamFollows(_ p: Int) -> Bool {
        var i = p
        while i < buf.count && i < p + 4 && isPDFWhitespace(buf[i]) { i += 1 }
        let kw = Array("endstream".utf8)
        guard i + kw.count <= buf.count else { return false }
        for k in 0..<kw.count where buf[i + k] != kw[k] { return false }
        return true
    }

    private func loadObjectStream(_ stmNum: Int, wantIndex: Int) {
        guard let ind = indirect(stmNum), case .stream(let s) = ind else { return }
        let (filters, parms) = Filters.filterChain(s.dict, resolve: resolve)
        guard let dec = try? Filters.decode(s.data, filters: filters, parms: parms, resolve: resolve, allowPartial: true),
              dec.remainingFilters.isEmpty else { return }
        let data = dec.data
        let n = s.dict.int("N") ?? 0
        let first = s.dict.int("First") ?? 0
        var lx = PDFLexer(data, pos: 0, end: min(first, data.count))
        var pairs: [(Int, Int)] = []
        for _ in 0..<max(0, n) {
            guard case .int(let on) = lx.nextToken(), case .int(let off) = lx.nextToken() else { break }
            pairs.append((on, off))
        }
        for (on, off) in pairs {
            // Only accept objects that the xref says live here (newer revisions win).
            if case .compressed(let owner, _)? = xref[on], owner == stmNum, cache[on] == nil {
                var olx = PDFLexer(data, pos: first + off)
                cache[on] = .object(olx.parseObject() ?? .null)
            }
        }
    }

    // MARK: Encryption

    private func setupSecurity(password: String) throws {
        guard let encObj = trailer["Encrypt"] else { return }
        encryptRef = encObj.refValue
        guard let enc = resolveDict(encObj) else { return }
        wasEncrypted = true
        var id: [UInt8] = []
        if let ids = resolve(trailer["ID"] ?? .null).arrayValue, let first = ids.first {
            id = resolve(first).stringValue ?? []
        }
        security = try StandardSecurity(encrypt: enc, id: id, password: password, resolve: resolve)
        // Objects parsed before the security handler existed must be decrypted again.
        let keep = cache.filter { k, _ in k == encryptRef?.num }
        cache = keep
    }

    private func decryptIndirect(_ v: PDFIndirect, num: Int, gen: Int) -> PDFIndirect {
        guard let sec = security, num != encryptRef?.num else { return v }
        switch v {
        case .object(let o):
            return .object(decryptStrings(o, sec, num, gen))
        case .stream(var s):
            let type = s.dict.name("Type")
            if type == "XRef" { return v }
            s.dict = decryptStrings(.dict(s.dict), sec, num, gen).dictValue ?? s.dict
            if type == "Metadata" && !sec.encryptMetadata { return .stream(s) }
            let (filters, _) = Filters.filterChain(s.dict, resolve: { $0 })
            if filters.first == "Crypt" { return .stream(s) } // explicit identity crypt filter
            s.data = sec.decryptStream(s.data, num: num, gen: gen)
            return .stream(s)
        }
    }

    private func decryptStrings(_ o: PDFObject, _ sec: StandardSecurity, _ num: Int, _ gen: Int) -> PDFObject {
        switch o {
        case .string(let s): return .string(sec.decryptString(s, num: num, gen: gen))
        case .array(let a): return .array(a.map { decryptStrings($0, sec, num, gen) })
        case .dict(let d):
            var nd = PDFDict()
            for (k, v) in d.entries { nd[k] = decryptStrings(v, sec, num, gen) }
            return .dict(nd)
        default: return o
        }
    }

    // MARK: XRef

    private func loadXRefChain() throws {
        guard let sx = PDFLexer.findLast(Array("startxref".utf8), in: buf, from: max(0, buf.count - 4096)) else {
            throw PDFError(.damaged, "startxref not found")
        }
        var lx = PDFLexer(buf, pos: sx + 9)
        guard case .int(var offset) = lx.nextToken() else { throw PDFError(.damaged, "bad startxref") }
        var visited = Set<Int>()
        var first = true
        while offset > 0 && !visited.contains(offset) {
            visited.insert(offset)
            let section = try loadXRefSection(at: offset)
            if first {
                trailer = section
                first = false
            }
            // hybrid files
            if let stm = section.int("XRefStm"), !visited.contains(stm) {
                visited.insert(stm)
                _ = try? loadXRefSection(at: stm)
            }
            guard let prev = section.int("Prev") else { break }
            offset = prev
        }
        if trailer["Root"] == nil { throw PDFError(.damaged, "no Root") }
    }

    /// Loads one xref section; entries already known (from newer sections) win.
    private func loadXRefSection(at offset: Int) throws -> PDFDict {
        guard offset < buf.count else { throw PDFError(.damaged, "bad xref offset") }
        var lx = PDFLexer(buf, pos: offset)
        let save = lx.pos
        if case .keyword("xref") = lx.nextToken() {
            while true {
                let p = lx.pos
                guard case .int(let start) = lx.nextToken(), case .int(let count) = lx.nextToken() else {
                    lx.pos = p
                    break
                }
                for k in 0..<max(0, count) {
                    guard case .int(let off) = lx.nextToken(), case .int(let gen) = lx.nextToken(),
                          case .keyword(let t) = lx.nextToken() else { throw PDFError(.damaged, "bad xref row") }
                    let num = start + k
                    if xref[num] == nil {
                        xref[num] = t == "n" ? .offset(off, gen: gen) : .free
                    }
                }
            }
            guard case .keyword("trailer") = lx.nextToken(), case .dict(let d)? = lx.parseObject() else {
                throw PDFError(.damaged, "no trailer")
            }
            return d
        }
        lx.pos = save
        guard let parsed = parseIndirect(at: offset), case .stream(let s) = parsed.2,
              s.dict.name("Type") == "XRef" else {
            throw PDFError(.damaged, "bad xref stream")
        }
        let (filters, parms) = Filters.filterChain(s.dict, resolve: { $0 })
        let dec = try Filters.decode(s.data, filters: filters, parms: parms, resolve: { $0 }, allowPartial: true)
        guard dec.remainingFilters.isEmpty else { throw PDFError(.damaged, "xref filter") }
        let data = dec.data
        guard let w = s.dict["W"]?.arrayValue?.compactMap({ $0.intValue }), w.count >= 3 else {
            throw PDFError(.damaged, "xref W")
        }
        let size = s.dict.int("Size") ?? 0
        var index: [Int] = s.dict["Index"]?.arrayValue?.compactMap { $0.intValue } ?? [0, size]
        if index.count % 2 != 0 { index = [0, size] }
        let rowLen = w[0] + w[1] + w[2]
        guard rowLen > 0 else { throw PDFError(.damaged, "xref W") }
        var pos = 0
        func field(_ width: Int, _ def: Int) -> Int {
            if width == 0 { return def }
            var v = 0
            for _ in 0..<width {
                v = (v << 8) | Int(data[pos])
                pos += 1
            }
            return v
        }
        var i = 0
        while i + 1 < index.count {
            let start = index[i], count = index[i + 1]
            for k in 0..<max(0, count) {
                guard pos + rowLen <= data.count else { break }
                let t = field(w[0], 1)
                let f2 = field(w[1], 0)
                let f3 = field(w[2], 0)
                let num = start + k
                if xref[num] == nil {
                    switch t {
                    case 0: xref[num] = .free
                    case 1: xref[num] = .offset(f2, gen: f3)
                    case 2: xref[num] = .compressed(objStm: f2, index: f3)
                    default: break
                    }
                }
            }
            i += 2
        }
        return s.dict
    }

    /// Rebuilds the xref by scanning the file for `n g obj` headers.
    private func reconstruct() throws {
        reconstructed = true
        var table: [Int: XRefEntry] = [:]
        var objStreams: [Int] = []
        var trailers: [PDFDict] = []
        let objKw = Array("obj".utf8)
        var i = 0
        let n = buf.count
        while i < n {
            // object header: digits ws digits ws "obj"
            if buf[i] >= 0x30 && buf[i] <= 0x39 && (i == 0 || !isPDFRegular(buf[i - 1])) {
                var j = i
                var num = 0
                while j < n && buf[j] >= 0x30 && buf[j] <= 0x39 && num < 100_000_000 { num = num * 10 + Int(buf[j] - 0x30); j += 1 }
                var k = j
                while k < n && isPDFWhitespace(buf[k]) { k += 1 }
                if k > j {
                    var gen = 0
                    let gs = k
                    while k < n && buf[k] >= 0x30 && buf[k] <= 0x39 && gen < 70000 { gen = gen * 10 + Int(buf[k] - 0x30); k += 1 }
                    if k > gs {
                        var m = k
                        while m < n && isPDFWhitespace(buf[m]) { m += 1 }
                        if m > k && m + 3 <= n && buf[m] == objKw[0] && buf[m + 1] == objKw[1] && buf[m + 2] == objKw[2]
                            && (m + 3 == n || !isPDFRegular(buf[m + 3])) {
                            table[num] = .offset(i, gen: gen)
                            i = m + 3
                            continue
                        }
                    }
                }
                i = j
                continue
            }
            if buf[i] == 0x74, i + 7 <= n, buf[i + 1] == 0x72, buf[i + 2] == 0x61, buf[i + 3] == 0x69,
               buf[i + 4] == 0x6C, buf[i + 5] == 0x65, buf[i + 6] == 0x72 {
                var lx = PDFLexer(buf, pos: i + 7)
                if case .dict(let d)? = lx.parseObject() { trailers.append(d) }
                i += 7
                continue
            }
            i += 1
        }
        guard !table.isEmpty else { throw PDFError(.damaged, "Файл PDF повреждён: объекты не найдены") }
        xref = table
        cache.removeAll()
        // Find object streams and register their contents (non-overriding).
        for (num, entry) in table {
            guard case .offset(let off, _) = entry, let parsed = parseIndirect(at: off),
                  case .stream(let s) = parsed.2 else { continue }
            if s.dict.name("Type") == "ObjStm" { objStreams.append(num) }
            if s.dict.name("Type") == "XRef" { trailers.append(s.dict) }
        }
        for stm in objStreams.sorted() {
            guard case .offset(let off, _)? = xref[stm], let parsed = parseIndirect(at: off),
                  case .stream(let s) = parsed.2 else { continue }
            let (filters, parms) = Filters.filterChain(s.dict, resolve: { $0 })
            guard let dec = try? Filters.decode(s.data, filters: filters, parms: parms, resolve: { $0 }, allowPartial: true) else { continue }
            let first = s.dict.int("First") ?? 0
            var lx = PDFLexer(dec.data, pos: 0, end: min(first, dec.data.count))
            var idx = 0
            while case .int(let on) = lx.nextToken(), case .int(_) = lx.nextToken() {
                if xref[on] == nil { xref[on] = .compressed(objStm: stm, index: idx) }
                idx += 1
            }
        }
        // Trailer: prefer the last one that has a valid Root.
        var newTrailer = PDFDict()
        for t in trailers.reversed() where t["Root"] != nil {
            newTrailer = t
            break
        }
        trailer = newTrailer
        if resolveDict(trailer["Root"]) == nil {
            // find a catalog object
            for num in xref.keys.sorted() {
                if let d = indirect(num)?.dict, d.name("Type") == "Catalog" {
                    trailer["Root"] = .ref(PDFRef(num, 0))
                    break
                }
            }
        }
        guard resolveDict(trailer["Root"]) != nil else {
            throw PDFError(.damaged, "Файл PDF повреждён: каталог документа не найден")
        }
    }

    // MARK: Pages

    /// Page dictionaries (by reference) in document order, with inherited attributes.
    public struct PageInfo {
        public var ref: PDFRef
        public var dict: PDFDict
        public var resources: PDFDict
        public var mediaBox: [Double]
    }

    public func pages() -> [PageInfo] {
        var result: [PageInfo] = []
        var seen = Set<Int>()
        func walk(_ obj: PDFObject, inheritedRes: PDFObject?, inheritedBox: PDFObject?, depth: Int) {
            guard depth < 64, case .ref(let r) = obj, !seen.contains(r.num) else { return }
            seen.insert(r.num)
            guard let d = resolveDict(obj) else { return }
            let res = d["Resources"] ?? inheritedRes
            let box = d["MediaBox"] ?? inheritedBox
            let type = d.name("Type")
            if type == "Pages" || (type == nil && d["Kids"] != nil) {
                for kid in resolve(d["Kids"] ?? .null).arrayValue ?? [] {
                    walk(kid, inheritedRes: res, inheritedBox: box, depth: depth + 1)
                }
            } else {
                let resources = resolveDict(res) ?? PDFDict()
                let mb = (resolve(box ?? .null).arrayValue ?? []).compactMap { resolve($0).doubleValue }
                result.append(PageInfo(ref: r, dict: d, resources: resources,
                                       mediaBox: mb.count == 4 ? mb : [0, 0, 612, 792]))
            }
        }
        walk(catalog["Pages"] ?? .null, inheritedRes: nil, inheritedBox: nil, depth: 0)
        return result
    }
}
