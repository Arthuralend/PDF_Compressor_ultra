import Foundation

public enum ImageCodec: String, CaseIterable, Identifiable, Sendable, Codable {
    case jpegli
    case jpeg2000

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .jpegli: return "JPEGli"
        case .jpeg2000: return "JPEG 2000"
        }
    }
}

public enum CompressionPreset: String, CaseIterable, Identifiable, Sendable, Codable {
    case strong
    case optimalStrong
    case optimal
    case medium
    case light
    case manual

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .strong: return "Сильное сжатие"
        case .optimalStrong: return "Оптимальное сильное"
        case .optimal: return "Оптимальное"
        case .medium: return "Среднее сжатие"
        case .light: return "Лёгкое сжатие"
        case .manual: return "Ручной выбор"
        }
    }

    /// (dpi, jpeg quality %) — nil for manual.
    public var values: (dpi: Int, quality: Int)? {
        switch self {
        case .strong: return (72, 50)
        case .optimalStrong: return (100, 60)
        case .optimal: return (120, 75)
        case .medium: return (144, 75)
        case .light: return (300, 80)
        case .manual: return nil
        }
    }
}

public struct CompressionSettings: Sendable, Codable, Equatable {
    /// Target resolution for raster images (pixels per inch).
    public var dpi: Int
    /// Lossy quality 1...100.
    public var quality: Int
    public var codec: ImageCodec
    /// Remove editor-private data (PieceInfo), embedded page thumbnails.
    public var removeEditorData: Bool
    /// Allow lossy re-encoding of images. When false only lossless optimization is done.
    public var lossyImages: Bool

    public init(dpi: Int, quality: Int, codec: ImageCodec, removeEditorData: Bool = true, lossyImages: Bool = true) {
        self.dpi = dpi
        self.quality = quality
        self.codec = codec
        self.removeEditorData = removeEditorData
        self.lossyImages = lossyImages
    }

    public init(preset: CompressionPreset, codec: ImageCodec, manualDPI: Int = 150, manualQuality: Int = 70) {
        let v = preset.values ?? (manualDPI, manualQuality)
        self.init(dpi: v.dpi, quality: v.quality, codec: codec)
    }
}

public struct CompressionReport: Sendable {
    public var originalSize: Int
    public var compressedSize: Int
    public var pageCount: Int
    public var pagesWithImages: Int
    public var imagesFound: Int
    public var imagesRecompressed: Int
    public var imagesDownsampled: Int
    public var streamsOptimized: Int
    /// The optimized file was not smaller, so the original was copied.
    public var keptOriginal: Bool
    public var codecNote: String?

    public var savedFraction: Double {
        guard originalSize > 0 else { return 0 }
        return 1 - Double(compressedSize) / Double(originalSize)
    }
}

public enum PDFCompressorInfo {
    /// True when the jpegli encoder was linked in (Scripts/build_jpegli.sh).
    public static var jpegliAvailable: Bool { ImageCodecs.jpegliAvailable }
    public static var jpeg2000Available: Bool { ImageCodecs.jpeg2000Available }
}
