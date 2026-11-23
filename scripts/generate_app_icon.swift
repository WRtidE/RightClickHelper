import AppKit

// Generate app and README icons from the same system symbol used by the Finder menu.
let project = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = project.appendingPathComponent("build/AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let sizes = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]
let blue = NSColor(calibratedRed: 0.04, green: 0.49, blue: 0.98, alpha: 1)
let symbol = NSImage(systemSymbolName: "cursorarrow.click.2", accessibilityDescription: nil)!
    .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 600, weight: .regular))!

func renderIcon(pixels: Int, includeTile: Bool) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let scale = CGFloat(pixels) / 1024
    let transform = NSAffineTransform()
    transform.scale(by: scale)
    transform.concat()

    if includeTile {
        let tile = NSBezierPath(roundedRect: NSRect(x: 62, y: 62, width: 900, height: 900),
                                xRadius: 202, yRadius: 202)
        NSGradient(starting: .white, ending: NSColor(calibratedRed: 0.91, green: 0.96, blue: 1, alpha: 1))!
            .draw(in: tile, angle: -90)
    }
    let symbolSize = symbol.size
    // Both exports preserve the symbol's intrinsic aspect ratio.
    let width: CGFloat = includeTile ? 600 : 720
    let height = width * symbolSize.height / symbolSize.width
    let tinted = NSImage(size: symbolSize, flipped: false) { rect in
        symbol.draw(in: rect)
        blue.setFill()
        rect.fill(using: .sourceIn)
        return true
    }
    tinted.draw(in: NSRect(x: (1024 - width) / 2, y: (1024 - height) / 2,
                           width: width, height: height))
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

for (name, pixels) in sizes {
    try renderIcon(pixels: pixels, includeTile: true)
        .write(to: iconset.appendingPathComponent(name + ".png"))
}

let documentationAssets = project.appendingPathComponent("docs/assets")
try FileManager.default.createDirectory(at: documentationAssets, withIntermediateDirectories: true)
try renderIcon(pixels: 512, includeTile: false)
    .write(to: documentationAssets.appendingPathComponent("rightclickhelper-icon.png"))

let resources = project.appendingPathComponent("App/Resources")
try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { fatalError("iconutil failed") }
