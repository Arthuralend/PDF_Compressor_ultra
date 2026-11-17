// Renders page 1 of a PDF with macOS Quartz (the engine of Preview) to a gray PNG.
// Usage: swift Tests/quartz_render.swift in.pdf out.png dpi
import CoreGraphics
import Foundation
import ImageIO

let args = CommandLine.arguments
guard args.count == 4, let doc = CGPDFDocument(URL(fileURLWithPath: args[1]) as CFURL),
      let page = doc.page(at: 1), let dpi = Double(args[3]) else { exit(2) }
let box = page.getBoxRect(.mediaBox)
let scale = dpi / 72
let w = Int((box.width * scale).rounded()), h = Int((box.height * scale).rounded())
guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { exit(3) }
ctx.setFillColor(gray: 1, alpha: 1)
ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
ctx.interpolationQuality = .none
ctx.scaleBy(x: scale, y: scale)
ctx.translateBy(x: -box.minX, y: -box.minY)
ctx.drawPDFPage(page)
guard let img = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL, "public.png" as CFString, 1, nil)
else { exit(4) }
CGImageDestinationAddImage(dest, img, nil)
exit(CGImageDestinationFinalize(dest) ? 0 : 5)
