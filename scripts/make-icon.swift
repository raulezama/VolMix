// Draws the VolMix app icon (three rising bars) and writes Support/AppIcon.icns.
// Usage, from the project folder: swift scripts/make-icon.swift
import AppKit

let iconset = URL(fileURLWithPath: "build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Standard macOS icon grid: 1024 canvas with a 100 pt margin around a rounded square.
    let size = CGFloat(pixels)
    let margin = size * 100 / 1024
    let body = NSRect(x: margin, y: margin, width: size - 2 * margin, height: size - 2 * margin)
    let background = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)
    NSGradient(starting: NSColor(srgbRed: 0.33, green: 0.47, blue: 1.0, alpha: 1),
               ending: NSColor(srgbRed: 0.53, green: 0.27, blue: 0.93, alpha: 1))!
        .draw(in: background, angle: -90)

    // Three white bars, short to tall, left to right.
    let barWidth = body.width * 0.16
    let gap = body.width * 0.08
    let left = body.midX - (3 * barWidth + 2 * gap) / 2
    let bottom = body.minY + body.height * 0.22
    NSColor.white.setFill()
    for (i, height) in [0.25, 0.42, 0.58].enumerated() {
        let bar = NSRect(x: left + CGFloat(i) * (barWidth + gap), y: bottom,
                         width: barWidth, height: body.height * height)
        NSBezierPath(roundedRect: bar, xRadius: barWidth * 0.3, yRadius: barWidth * 0.3).fill()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    try render(points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try render(points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Support/AppIcon.icns"]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote Support/AppIcon.icns")
