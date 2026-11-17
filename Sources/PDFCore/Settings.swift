import Foundation

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
    /// Remove editor-private data (PieceInfo), embedded page thumbnails.
    public var removeEditorData: Bool
    /// Allow lossy re-encoding of images. When false only lossless optimization is done.
    public var lossyImages: Bool
    /// Master mode: 0-based page indices whose images must stay untouched.
    public var protectedPages: Set<Int> = []
    /// Master mode: object numbers of individual images that must stay untouched
    /// (as reported by `PDFCompressor.inspect`).
    public var protectedImages: Set<Int> = []

    public init(dpi: Int, quality: Int, removeEditorData: Bool = true, lossyImages: Bool = true) {
        self.dpi = dpi
        self.quality = quality
        self.removeEditorData = removeEditorData
        self.lossyImages = lossyImages
    }

    public init(preset: CompressionPreset, manualDPI: Int = 150, manualQuality: Int = 70) {
        let v = preset.values ?? (manualDPI, manualQuality)
        self.init(dpi: v.dpi, quality: v.quality)
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
    /// One line per image: size, effective resolution, what was done and why.
    public var imageLog: [String] = []
    /// Number of images left unchanged, by reason.
    public var skipped: [String: Int] = [:]

    public var savedFraction: Double {
        guard originalSize > 0 else { return 0 }
        return 1 - Double(compressedSize) / Double(originalSize)
    }
}

public enum PDFCompressorInfo {
    /// True when the jpegli encoder was linked in (Scripts/build_jpegli.sh).
    public static var jpegliAvailable: Bool { ImageCodecs.jpegliAvailable }
}

/// One image drawn on a page (master mode).
public struct PageImageInfo: Sendable, Identifiable, Hashable {
    /// Stable within the file: object number of the image.
    public var objectNumber: Int
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// Bounding box in PDF user space (points, origin bottom-left).
    public var x: Double, y: Double, width: Double, height: Double
    /// Effective resolution at this placement.
    public var ppi: Double
    public var id: String { "\(objectNumber)@\(x),\(y)" }

    public init(objectNumber: Int, pixelWidth: Int, pixelHeight: Int,
                x: Double, y: Double, width: Double, height: Double, ppi: Double) {
        self.objectNumber = objectNumber
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.x = x; self.y = y; self.width = width; self.height = height
        self.ppi = ppi
    }
}

public struct PageImagesInfo: Sendable, Identifiable {
    public var index: Int
    public var images: [PageImageInfo]
    public var id: Int { index }

    public init(index: Int, images: [PageImageInfo]) {
        self.index = index
        self.images = images
    }
}
