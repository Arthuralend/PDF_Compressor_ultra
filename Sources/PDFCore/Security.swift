import Foundation
#if canImport(CommonCrypto)
import CommonCrypto
#endif

/// Standard security handler (RC4 40/128, AES-128, AES-256). Used only to
/// decrypt: the compressed output is written without encryption.
final class StandardSecurity {
    enum Method { case none, rc4, aesV2, aesV3 }

    private(set) var fileKey: [UInt8] = []
    let streamMethod: Method
    let stringMethod: Method
    let encryptMetadata: Bool
    let revision: Int

    private static let pad: [UInt8] = [
        0x28, 0xBF, 0x4E, 0x5E, 0x4E, 0x75, 0x8A, 0x41, 0x64, 0x00, 0x4E, 0x56, 0xFF, 0xFA, 0x01, 0x08,
        0x2E, 0x2E, 0x00, 0xB6, 0xD0, 0x68, 0x3E, 0x80, 0x2F, 0x0C, 0xA9, 0xFE, 0x64, 0x53, 0x69, 0x7A,
    ]

    private let o: [UInt8], u: [UInt8], oe: [UInt8], ue: [UInt8]
    private let p: Int32
    private let keyLength: Int
    private let firstID: [UInt8]

    /// Throws `.unsupportedEncryption` or `.encrypted` (wrong/missing password).
    init(encrypt: PDFDict, id: [UInt8], password: String, resolve: (PDFObject) -> PDFObject) throws {
        #if !canImport(CommonCrypto)
        throw PDFError(.unsupportedEncryption, "Шифрование не поддерживается на этой платформе")
        #else
        guard resolve(encrypt["Filter"] ?? .null).nameValue == "Standard" else {
            throw PDFError(.unsupportedEncryption, "Нестандартный обработчик шифрования PDF не поддерживается")
        }
        let v = resolve(encrypt["V"] ?? .int(0)).intValue ?? 0
        revision = resolve(encrypt["R"] ?? .int(2)).intValue ?? 2
        o = resolve(encrypt["O"] ?? .null).stringValue ?? []
        u = resolve(encrypt["U"] ?? .null).stringValue ?? []
        oe = resolve(encrypt["OE"] ?? .null).stringValue ?? []
        ue = resolve(encrypt["UE"] ?? .null).stringValue ?? []
        p = Int32(truncatingIfNeeded: resolve(encrypt["P"] ?? .int(0)).intValue ?? 0)
        encryptMetadata = resolve(encrypt["EncryptMetadata"] ?? .bool(true)).boolValue ?? true
        firstID = id

        var len = resolve(encrypt["Length"] ?? .int(40)).intValue ?? 40
        if len < 40 { len = 40 }
        keyLength = v == 1 ? 5 : min(16, len / 8)

        func method(forFilter name: String?) -> Method {
            guard let name = name else { return .none }
            if name == "Identity" { return .none }
            guard let cf = resolve(encrypt["CF"] ?? .null).dictValue,
                  let f = resolve(cf[name] ?? .null).dictValue else { return .rc4 }
            switch resolve(f["CFM"] ?? .null).nameValue {
            case "AESV2": return .aesV2
            case "AESV3": return .aesV3
            case "None": return .none
            default: return .rc4
            }
        }

        switch v {
        case 1, 2, 3:
            streamMethod = .rc4
            stringMethod = .rc4
        case 4, 5:
            streamMethod = method(forFilter: resolve(encrypt["StmF"] ?? .name("Identity")).nameValue)
            stringMethod = method(forFilter: resolve(encrypt["StrF"] ?? .name("Identity")).nameValue)
        default:
            throw PDFError(.unsupportedEncryption, "Неподдерживаемая версия шифрования PDF (V=\(v))")
        }

        if revision >= 5 {
            guard let key = authenticateV5(password) else {
                throw PDFError(.encrypted, "Документ защищён паролем")
            }
            fileKey = key
        } else {
            let pw = Array(password.utf8) // PDFDocEncoding ~ ASCII for most passwords
            if let key = authenticateUser(pw) {
                fileKey = key
            } else if let key = authenticateOwner(pw) {
                fileKey = key
            } else {
                throw PDFError(.encrypted, "Документ защищён паролем")
            }
        }
        #endif
    }

    // MARK: Object decryption

    func decryptString(_ data: [UInt8], num: Int, gen: Int) -> [UInt8] {
        decrypt(data, num: num, gen: gen, method: stringMethod)
    }

    func decryptStream(_ data: [UInt8], num: Int, gen: Int) -> [UInt8] {
        decrypt(data, num: num, gen: gen, method: streamMethod)
    }

    private func decrypt(_ data: [UInt8], num: Int, gen: Int, method: Method) -> [UInt8] {
        switch method {
        case .none: return data
        case .rc4: return Self.rc4(objectKey(num: num, gen: gen, aes: false), data)
        case .aesV2: return Self.aesCBCDecrypt(objectKey(num: num, gen: gen, aes: true), data) ?? data
        case .aesV3: return Self.aesCBCDecrypt(fileKey, data) ?? data
        }
    }

    private func objectKey(num: Int, gen: Int, aes: Bool) -> [UInt8] {
        var m = fileKey
        m += [UInt8(num & 0xFF), UInt8((num >> 8) & 0xFF), UInt8((num >> 16) & 0xFF)]
        m += [UInt8(gen & 0xFF), UInt8((gen >> 8) & 0xFF)]
        if aes { m += [0x73, 0x41, 0x6C, 0x54] }
        let h = Self.md5(m)
        return Array(h[0..<min(fileKey.count + 5, 16)])
    }

    // MARK: R2-R4

    private func padded(_ pw: [UInt8]) -> [UInt8] {
        Array((pw + Self.pad).prefix(32))
    }

    private func computeKey(_ pw: [UInt8]) -> [UInt8] {
        var m = padded(pw) + o
        m += [UInt8(truncatingIfNeeded: p), UInt8(truncatingIfNeeded: p >> 8),
              UInt8(truncatingIfNeeded: p >> 16), UInt8(truncatingIfNeeded: p >> 24)]
        m += firstID
        if revision >= 4 && !encryptMetadata { m += [0xFF, 0xFF, 0xFF, 0xFF] }
        var h = Self.md5(m)
        if revision >= 3 {
            for _ in 0..<50 { h = Self.md5(Array(h[0..<keyLength])) }
        }
        return Array(h[0..<keyLength])
    }

    private func authenticateUser(_ pw: [UInt8]) -> [UInt8]? {
        let key = computeKey(pw)
        if revision == 2 {
            return Self.rc4(key, Self.pad) == Array(u.prefix(32)) ? key : nil
        }
        var x = Self.rc4(key, Self.md5(Self.pad + firstID))
        for i in 1...19 { x = Self.rc4(key.map { $0 ^ UInt8(i) }, x) }
        return Array(x.prefix(16)) == Array(u.prefix(16)) ? key : nil
    }

    private func authenticateOwner(_ pw: [UInt8]) -> [UInt8]? {
        var h = Self.md5(padded(pw))
        if revision >= 3 { for _ in 0..<50 { h = Self.md5(h) } }
        let rk = Array(h[0..<keyLength])
        var userPw: [UInt8]
        if revision == 2 {
            userPw = Self.rc4(rk, o)
        } else {
            userPw = o
            for i in stride(from: 19, through: 0, by: -1) { userPw = Self.rc4(rk.map { $0 ^ UInt8(i) }, userPw) }
        }
        return authenticateUser(userPw)
    }

    // MARK: R5/R6 (AES-256)

    private func authenticateV5(_ password: String) -> [UInt8]? {
        let pw = Array(Array(password.utf8).prefix(127))
        guard u.count >= 48, o.count >= 48 else { return nil }
        let u48 = Array(u[0..<48])
        // owner
        if hashV5(pw, salt: Array(o[32..<40]), udata: u48) == Array(o[0..<32]), oe.count >= 32 {
            let k = hashV5(pw, salt: Array(o[40..<48]), udata: u48)
            if let key = Self.aesCBCNoPad(k, iv: [UInt8](repeating: 0, count: 16), Array(oe[0..<32]), encrypt: false) {
                return key
            }
        }
        if hashV5(pw, salt: Array(u[32..<40]), udata: []) == Array(u[0..<32]), ue.count >= 32 {
            let k = hashV5(pw, salt: Array(u[40..<48]), udata: [])
            return Self.aesCBCNoPad(k, iv: [UInt8](repeating: 0, count: 16), Array(ue[0..<32]), encrypt: false)
        }
        return nil
    }

    private func hashV5(_ pw: [UInt8], salt: [UInt8], udata: [UInt8]) -> [UInt8] {
        var k = Self.sha(pw + salt + udata, bits: 256)
        if revision < 6 { return k }
        var round = 0
        while true {
            let block = pw + k + udata
            var k1: [UInt8] = []
            k1.reserveCapacity(block.count * 64)
            for _ in 0..<64 { k1 += block }
            guard let e = Self.aesCBCNoPad(Array(k[0..<16]), iv: Array(k[16..<32]), k1, encrypt: true, keyBits: 128) else { return k }
            var mod = 0
            for i in 0..<16 { mod += Int(e[i]) }
            switch mod % 3 {
            case 0: k = Self.sha(e, bits: 256)
            case 1: k = Self.sha(e, bits: 384)
            default: k = Self.sha(e, bits: 512)
            }
            round += 1
            if round >= 64 && Int(e[e.count - 1]) <= round - 32 { break }
        }
        return Array(k[0..<32])
    }

    // MARK: Primitives

    static func rc4(_ key: [UInt8], _ data: [UInt8]) -> [UInt8] {
        var s = [UInt8](0...255)
        var j = 0
        for i in 0..<256 {
            j = (j + Int(s[i]) + Int(key[i % key.count])) & 0xFF
            s.swapAt(i, j)
        }
        var out = [UInt8](repeating: 0, count: data.count)
        var i = 0
        j = 0
        for k in 0..<data.count {
            i = (i + 1) & 0xFF
            j = (j + Int(s[i])) & 0xFF
            s.swapAt(i, j)
            out[k] = data[k] ^ s[(Int(s[i]) + Int(s[j])) & 0xFF]
        }
        return out
    }

    static func md5(_ data: [UInt8]) -> [UInt8] {
        #if canImport(CommonCrypto)
        var out = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        data.withUnsafeBufferPointer { _ = CC_MD5($0.baseAddress, CC_LONG($0.count), &out) }
        return out
        #else
        return []
        #endif
    }

    static func sha(_ data: [UInt8], bits: Int) -> [UInt8] {
        #if canImport(CommonCrypto)
        switch bits {
        case 384:
            var out = [UInt8](repeating: 0, count: Int(CC_SHA384_DIGEST_LENGTH))
            data.withUnsafeBufferPointer { _ = CC_SHA384($0.baseAddress, CC_LONG($0.count), &out) }
            return out
        case 512:
            var out = [UInt8](repeating: 0, count: Int(CC_SHA512_DIGEST_LENGTH))
            data.withUnsafeBufferPointer { _ = CC_SHA512($0.baseAddress, CC_LONG($0.count), &out) }
            return out
        default:
            var out = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
            data.withUnsafeBufferPointer { _ = CC_SHA256($0.baseAddress, CC_LONG($0.count), &out) }
            return out
        }
        #else
        return []
        #endif
    }

    /// AES-CBC with the IV in the first 16 bytes and PKCS#7 padding.
    static func aesCBCDecrypt(_ key: [UInt8], _ data: [UInt8]) -> [UInt8]? {
        #if canImport(CommonCrypto)
        guard data.count >= 16 else { return [] }
        let iv = Array(data[0..<16])
        let body = Array(data[16...])
        if body.isEmpty { return [] }
        let usable = body.count - body.count % 16
        let cap = usable + 16
        var out = [UInt8](repeating: 0, count: cap)
        var moved = 0
        let status = CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                             CCOptions(kCCOptionPKCS7Padding), key, key.count, iv,
                             body, usable, &out, cap, &moved)
        if status == CCCryptorStatus(kCCSuccess) { return Array(out[0..<moved]) }
        // Bad padding: decrypt without padding removal
        if let raw = aesCBCNoPad(key, iv: iv, Array(body[0..<usable]), encrypt: false, keyBits: key.count * 8) {
            return raw
        }
        return nil
        #else
        return nil
        #endif
    }

    static func aesCBCNoPad(_ key: [UInt8], iv: [UInt8], _ data: [UInt8], encrypt: Bool, keyBits: Int = 256) -> [UInt8]? {
        #if canImport(CommonCrypto)
        guard data.count % 16 == 0 else { return nil }
        let cap = data.count + 16
        var out = [UInt8](repeating: 0, count: cap)
        var moved = 0
        let status = CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                             CCOptions(0), key, key.count, iv, data, data.count, &out, cap, &moved)
        guard status == CCCryptorStatus(kCCSuccess) else { return nil }
        return Array(out[0..<moved])
        #else
        return nil
        #endif
    }
}
