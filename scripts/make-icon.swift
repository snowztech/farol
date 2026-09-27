// Builds assets/Farol.icns and assets/icon.png from assets/icon-source.png.
// Usage: swift scripts/make-icon.swift
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let source = root.appendingPathComponent("assets/icon-source.png")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("Farol.iconset")

guard let image = NSImage(contentsOf: source),
      let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fatalError("cannot read \(source.path)")
}

// Find the squircle: the bounding box of everything brighter than the black backdrop.
let rep = NSBitmapImageRep(cgImage: cg)
var minX = rep.pixelsWide, minY = rep.pixelsHigh, maxX = 0, maxY = 0
for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
    for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
        guard let c = rep.colorAt(x: x, y: y), c.brightnessComponent > 0.16 else { continue }
        minX = min(minX, x); maxX = max(maxX, x)
        minY = min(minY, y); maxY = max(maxY, y)
    }
}
// Both the bitmap scan and CGImage cropping use top-left pixel coordinates.
// Take a centered square so the artwork never stretches. The mask redraws the corners.
let side = min(maxX - minX, maxY - minY) + 1
let crop = CGRect(x: (minX + maxX + 1 - side) / 2, y: (minY + maxY + 1 - side) / 2, width: side, height: side)
guard let squircle = cg.cropping(to: crop) else { fatalError("crop failed") }

/// Apple's grid: 1024 canvas, 824 artwork, corner radius about 22.5% of the artwork.
func render(_ size: Int) -> Data {
    let s = CGFloat(size)
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    let art = CGRect(x: s * 100 / 1024, y: s * 100 / 1024, width: s * 824 / 1024, height: s * 824 / 1024)
    // Inset slightly so the source's soft glow at the edge is cut off cleanly.
    let inset = art.width * 0.012
    ctx.addPath(CGPath(roundedRect: art, cornerWidth: art.width * 0.225, cornerHeight: art.width * 0.225, transform: nil))
    ctx.clip()
    ctx.draw(squircle, in: art.insetBy(dx: -inset, dy: -inset))
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

try render(256).write(to: root.appendingPathComponent("assets/icon.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("assets/Farol.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
print("wrote assets/Farol.icns (squircle at \(crop))")
