import Foundation

/// Reference to an indirect object (`12 0 R`).
public struct PDFRef: Hashable, Sendable {
    public var num: Int
    public var gen: Int
    public init(_ num: Int, _ gen: Int = 0) {
        self.num = num
        self.gen = gen
    }
}

/// A direct PDF value. Streams are never direct, so they live in `PDFStream`.
public indirect enum PDFObject {
    case null
    case bool(Bool)
    case int(Int)
    case real(Double)
    case string([UInt8])
    case name(String)          // decoded name, bytes stored as ISO-Latin-1 scalars
    case array([PDFObject])
    case dict(PDFDict)
    case ref(PDFRef)

    public var intValue: Int? {
        switch self {
        case .int(let v): return v
        case .real(let v) where v.isFinite && abs(v) < 1e15: return Int(v.rounded())
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .int(let v): return Double(v)
        case .real(let v): return v
        default: return nil
        }
    }

    public var nameValue: String? {
        if case .name(let n) = self { return n }
        return nil
    }

    public var arrayValue: [PDFObject]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var dictValue: PDFDict? {
        if case .dict(let d) = self { return d }
        return nil
    }

    public var refValue: PDFRef? {
        if case .ref(let r) = self { return r }
        return nil
    }

    public var stringValue: [UInt8]? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}

/// Insertion-ordered dictionary with name keys.
public struct PDFDict {
    public private(set) var keys: [String] = []
    private var storage: [String: PDFObject] = [:]

    public init() {}

    public init(_ pairs: [(String, PDFObject)]) {
        for (k, v) in pairs { self[k] = v }
    }

    public subscript(key: String) -> PDFObject? {
        get { storage[key] }
        set {
            if let v = newValue {
                if storage.updateValue(v, forKey: key) == nil { keys.append(key) }
            } else if storage.removeValue(forKey: key) != nil {
                keys.removeAll { $0 == key }
            }
        }
    }

    public var count: Int { keys.count }

    public var entries: [(String, PDFObject)] { keys.map { ($0, storage[$0]!) } }

    public mutating func remove(_ names: String...) {
        for n in names { self[n] = nil }
    }

    public func name(_ key: String) -> String? { self[key]?.nameValue }
    public func int(_ key: String) -> Int? { self[key]?.intValue }
}

/// A stream: dictionary + (still encoded, already decrypted) data.
public struct PDFStream {
    public var dict: PDFDict
    public var data: [UInt8]
    public init(dict: PDFDict, data: [UInt8]) {
        self.dict = dict
        self.data = data
    }
}

/// Value stored at an indirect object slot.
public enum PDFIndirect {
    case object(PDFObject)
    case stream(PDFStream)

    public var object: PDFObject? {
        if case .object(let o) = self { return o }
        return nil
    }

    public var stream: PDFStream? {
        if case .stream(let s) = self { return s }
        return nil
    }

    /// Dictionary of the object, or the stream dictionary.
    public var dict: PDFDict? {
        switch self {
        case .object(let o): return o.dictValue
        case .stream(let s): return s.dict
        }
    }
}

public struct PDFError: Error, LocalizedError, CustomStringConvertible {
    public enum Kind: Sendable {
        case notAPDF
        case damaged
        case encrypted          // needs a password
        case unsupportedEncryption
        case io
        case internalError
    }
    public var kind: Kind
    public var message: String
    public init(_ kind: Kind, _ message: String) {
        self.kind = kind
        self.message = message
    }
    public var errorDescription: String? { message }
    public var description: String { message }
}
