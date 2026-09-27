// Builds the app icons from the square artwork in assets/icons/source.
// Each variant becomes assets/icons/<name>.png, and the default also becomes Farol.icns and the README image.
// Usage: swift scripts/make-icon.swift
import AppKit

let defaultIcon = "beam"
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let assets = root.appendingPathComponent("assets")
let sources = assets.appendingPathComponent("icons/source")

/// Apple's grid: 1024 canvas, 824 artwork, corner radius about 22.5% of the artwork.
func render(_ art: CGImage, size: Int) -> Data {
    let s = CGFloat(size)
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    let rect = CGRect(x: s * 100 / 1024, y: s * 100 / 1024, width: s * 824 / 1024, height: s * 824 / 1024)
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: rect.width * 0.225, cornerHeight: rect.width * 0.225, transform: nil))
    ctx.clip()
    ctx.draw(art, in: rect)
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
}

func artwork(_ name: String) -> CGImage {
    let url = sources.appendingPathComponent("\(name).png")
    guard let image = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        fatalError("cannot read \(url.path)")
    }
    return image
}

let names = try FileManager.default.contentsOfDirectory(atPath: sources.path)
    .filter { $0.hasSuffix(".png") }
    .map { ($0 as NSString).deletingPathExtension }
    .sorted()

for name in names {
    try render(artwork(name), size: 1024).write(to: assets.appendingPathComponent("icons/\(name).png"))
}
try render(artwork(defaultIcon), size: 256).write(to: assets.appendingPathComponent("icon.png"))

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("Farol.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(artwork(defaultIcon), size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(artwork(defaultIcon), size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", assets.appendingPathComponent("Farol.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
print("icons: \(names.joined(separator: ", ")), default \(defaultIcon)")
