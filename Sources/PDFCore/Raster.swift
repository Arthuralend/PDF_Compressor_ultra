import Foundation
import CCodecs
#if canImport(ImageIO)
import ImageIO
import CoreGraphics
#endif

/// 8-bit interleaved image (1 = gray, 3 = RGB, 4 = CMYK).
struct Raster {
    var width: Int
    var height: Int
    var components: Int
    var pixels: [UInt8]

    /// Area-averaging (box filter) downscale. Never upscales.
    func resized(width nw: Int, height nh: Int) -> Raster {
        let tw = max(1, min(nw, width)), th = max(1, min(nh, height))
        if tw == width && th == height { return self }
        let cx = components
        let hWeights = Raster.weights(src: width, dst: tw)
        let vWeights = Raster.weights(src: height, dst: th)

        // Horizontal pass: width x height -> tw x height
        var tmp = [Float](repeating: 0, count: tw * height * cx)
        pixels.withUnsafeBufferPointer { src in
            tmp.withUnsafeMutableBufferPointer { dst in
                for y in 0..<height {
                    let srow = y * width * cx
                    let drow = y * tw * cx
                    for x in 0..<tw {
                        let (start, ws) = hWeights[x]
                        for c in 0..<cx {
                            var acc: Float = 0
                            for (k, w) in ws.enumerated() {
                                acc += Float(src[srow + (start + k) * cx + c]) * w
                            }
                            dst[drow + x * cx + c] = acc
                        }
                    }
                }
            }
        }
        // Vertical pass
        var out = [UInt8](repeating: 0, count: tw * th * cx)
        tmp.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                let rowLen = tw * cx
                var acc = [Float](repeating: 0, count: rowLen)
                for y in 0..<th {
                    let (start, ws) = vWeights[y]
                    for i in 0..<rowLen { acc[i] = 0 }
                    for (k, w) in ws.enumerated() {
                        let srow = (start + k) * rowLen
                        for i in 0..<rowLen { acc[i] += src[srow + i] * w }
                    }
                    let drow = y * rowLen
                    for i in 0..<rowLen {
                        let v = acc[i] + 0.5
                        dst[drow + i] = v <= 0 ? 0 : (v >= 255 ? 255 : UInt8(v))
                    }
                }
            }
        }
        return Raster(width: tw, height: th, components: cx, pixels: out)
    }

    /// For each destination index: first source index and normalized coverage weights.
    private static func weights(src: Int, dst: Int) -> [(Int, [Float])] {
        let scale = Double(src) / Double(dst)
        var result: [(Int, [Float])] = []
        result.reserveCapacity(dst)
        for i in 0..<dst {
            let x0 = Double(i) * scale
            let x1 = min(Double(src), Double(i + 1) * scale)
            let first = Int(x0.rounded(.down))
            let last = min(src - 1, Int((x1 - 1e-9).rounded(.down)))
            var ws: [Float] = []
            var total = 0.0
            if last >= first {
                for s in first...last {
                    let cover = min(x1, Double(s + 1)) - max(x0, Double(s))
                    ws.append(Float(max(0, cover)))
                    total += max(0, cover)
                }
            }
            if total <= 0 { ws = [1]; total = 1 }
            result.append((first, ws.map { $0 / Float(total) }))
        }
        return result
    }
}

/// Image codecs: jpegli (C library) for JPEG; ImageIO only as a fallback and
/// to read JPEG 2000 images that already exist in a PDF.
enum ImageCodecs {
    static var jpegliAvailable: Bool { ccodecs_jpegli_available() != 0 }

    /// components 1/3/4. For CMYK `adobe` must match the source JPEG.
    static func encodeJpegli(_ r: Raster, quality: Int, adobe: Bool = false) -> [UInt8]? {
        guard [1, 3, 4].contains(r.components) else { return nil }
        var out: UnsafeMutablePointer<UInt8>? = nil
        var len = 0
        let rc = r.pixels.withUnsafeBufferPointer { bp in
            ccodecs_jpegli_encode(bp.baseAddress, Int32(r.width), Int32(r.height), Int32(r.components),
                                  Int32(quality), adobe ? 1 : 0, &out, &len)
        }
        guard rc == 0, let p = out else { return nil }
        defer { ccodecs_free(p) }
        return Array(UnsafeBufferPointer(start: p, count: len))
    }

    /// Any JPEG encoder available: jpegli, else the system encoder (gray/RGB only).
    static func encodeJPEG(_ r: Raster, quality: Int, adobe: Bool = false) -> [UInt8]? {
        if jpegliAvailable { return encodeJpegli(r, quality: quality, adobe: adobe) }
        return r.components == 4 ? nil : encodeSystemJPEG(r, quality: quality)
    }

    /// Decodes a JPEG to samples exactly as stored (CMYK is not inverted).
    /// colorTransform: PDF /ColorTransform from DecodeParms, nil = automatic.
    static func decodeJPEG(_ bytes: [UInt8], colorTransform: Int?) -> (Raster, adobe: Bool)? {
        if jpegliAvailable {
            var out: UnsafeMutablePointer<UInt8>? = nil
            var w: Int32 = 0, h: Int32 = 0, c: Int32 = 0, adobe: Int32 = 0
            let rc = bytes.withUnsafeBufferPointer { bp in
                ccodecs_jpegli_decode(bp.baseAddress, bp.count, Int32(colorTransform ?? -1), &out, &w, &h, &c, &adobe)
            }
            guard rc == 0, let p = out else { return nil }
            defer { ccodecs_free(p) }
            let n = Int(w) * Int(h) * Int(c)
            return (Raster(width: Int(w), height: Int(h), components: Int(c),
                           pixels: Array(UnsafeBufferPointer(start: p, count: n))), adobe != 0)
        }
        return decodeSystem(bytes).map { ($0, false) }
    }

    static func decodeJPX(_ bytes: [UInt8]) -> Raster? { decodeSystem(bytes) }

    #if canImport(ImageIO)
    static func cgImage(_ r: Raster) -> CGImage? {
        let space: CGColorSpace
        switch r.components {
        case 1: space = CGColorSpaceCreateDeviceGray()
        case 3: space = CGColorSpaceCreateDeviceRGB()
        default: return nil
        }
        guard let provider = CGDataProvider(data: Data(r.pixels) as CFData) else { return nil }
        return CGImage(width: r.width, height: r.height, bitsPerComponent: 8, bitsPerPixel: 8 * r.components,
                       bytesPerRow: r.width * r.components, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    static func encodeSystemJPEG(_ r: Raster, quality: Int) -> [UInt8]? {
        guard let img = cgImage(r) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, "public.jpeg" as CFString, 1, nil) else { return nil }
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: Double(quality) / 100.0]
        CGImageDestinationAddImage(dest, img, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return [UInt8](data as Data)
    }

    /// Decodes via ImageIO into a gray or RGB raster (no color conversion when the
    /// source is already gray/RGB). CMYK sources return nil.
    static func decodeSystem(_ bytes: [UInt8]) -> Raster? {
        guard let src = CGImageSourceCreateWithData(Data(bytes) as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let model = img.colorSpace?.model ?? .rgb
        let comps: Int
        let space: CGColorSpace
        switch model {
        case .monochrome:
            comps = 1
            space = img.colorSpace ?? CGColorSpaceCreateDeviceGray()
        case .rgb:
            comps = 3
            space = img.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        default:
            return nil
        }
        let w = img.width, h = img.height
        guard w > 0, h > 0 else { return nil }
        if comps == 1 {
            var px = [UInt8](repeating: 0, count: w * h)
            let ok = px.withUnsafeMutableBytes { mb -> Bool in
                guard let ctx = CGContext(data: mb.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: w, space: space,
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
                ctx.interpolationQuality = .none
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            return ok ? Raster(width: w, height: h, components: 1, pixels: px) : nil
        }
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let ok = rgba.withUnsafeMutableBytes { mb -> Bool in
            guard let ctx = CGContext(data: mb.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        var px = [UInt8](repeating: 0, count: w * h * 3)
        for i in 0..<(w * h) {
            px[i * 3] = rgba[i * 4]
            px[i * 3 + 1] = rgba[i * 4 + 1]
            px[i * 3 + 2] = rgba[i * 4 + 2]
        }
        return Raster(width: w, height: h, components: 3, pixels: px)
    }
    #else
    static func encodeSystemJPEG(_ r: Raster, quality: Int) -> [UInt8]? { nil }
    static func decodeSystem(_ bytes: [UInt8]) -> Raster? { nil }
    #endif
}
