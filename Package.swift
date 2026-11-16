// swift-tools-version:5.9
import PackageDescription
import Foundation

// JPEGli is linked in when Scripts/build_jpegli.sh has been run (Vendor/jpegli).
// Without it the app still builds and uses the system JPEG encoder instead.
let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let jpegliDir = packageDir + "/Vendor/jpegli"
let hasJpegli = FileManager.default.fileExists(atPath: jpegliDir + "/lib/libjpegli-static.a")

var codecCSettings: [CSetting] = []
var codecLinker: [LinkerSetting] = [.linkedLibrary("z")]
if hasJpegli {
    codecCSettings += [.define("CCODECS_HAS_JPEGLI"), .unsafeFlags(["-I", jpegliDir + "/include"])]
    codecLinker += [
        .unsafeFlags(["-L", jpegliDir + "/lib"]),
        .linkedLibrary("jpegli-static"),
        .linkedLibrary("hwy"),
    ]
    #if os(macOS)
    codecLinker.append(.linkedLibrary("c++"))
    #else
    codecLinker.append(.linkedLibrary("stdc++"))
    #endif
}

var products: [Product] = [
    .executable(name: "pdfcu", targets: ["pdfcu"]),
]
var targets: [Target] = [
    .target(name: "CCodecs", cSettings: codecCSettings, linkerSettings: codecLinker),
    .target(name: "PDFCore", dependencies: ["CCodecs"]),
    .executableTarget(name: "pdfcu", dependencies: ["PDFCore"]),
]

#if os(macOS)
products.append(.executable(name: "PDFCompressorUltra", targets: ["PDFCompressorUltra"]))
targets.append(.executableTarget(name: "PDFCompressorUltra", dependencies: ["PDFCore"]))
#endif

let package = Package(
    name: "PDFCompressorUltra",
    platforms: [.macOS(.v13)],
    products: products,
    targets: targets
)
