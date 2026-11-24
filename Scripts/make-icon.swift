// Draws iMemory's icon and creates Resources/AppIcon.icns.
//
// usage: swift Scripts/make-icon.swift
//
// Everything is drawn with plain shapes and no system symbols, because the SF Symbols
// license doesn't allow them in app icons.
import AppKit

/// The icon at 1024 points, drawn so that any size is a plain scale of it.
func drawIcon(in context: CGContext, size: CGFloat) {
    let scale = size / 1024
    context.scaleBy(x: scale, y: scale)

    // Apple's macOS grid: an 824-point body with continuous corners, inset for the shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185).cgPath

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    context.addPath(shape)
    context.setFillColor(NSColor.black.cgColor)
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(shape)
    context.clip()

    let colors = CGColorSpace(name: CGColorSpace.displayP3)!
    let background = CGGradient(colorsSpace: colors, colors: [
        NSColor(displayP3Red: 0.20, green: 0.42, blue: 0.98, alpha: 1).cgColor,
        NSColor(displayP3Red: 0.09, green: 0.16, blue: 0.55, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(background, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // A soft glow behind the ring, so it reads as lit from within.
    let glow = CGGradient(colorsSpace: colors, colors: [
        NSColor(white: 1, alpha: 0.18).cgColor,
        NSColor(white: 1, alpha: 0).cgColor,
    ] as CFArray, locations: [0, 1])!
    context.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 540), startRadius: 0,
                               endCenter: CGPoint(x: 512, y: 540), endRadius: 420, options: [])

    // The storage ring: used space in segments, free space as a faint track.
    let center = CGPoint(x: 512, y: 512)
    let radius: CGFloat = 255
    let width: CGFloat = 112
    context.setLineWidth(width)
    context.setLineCap(.butt)

    let segments: [(share: CGFloat, color: NSColor)] = [
        (0.36, NSColor(displayP3Red: 1.00, green: 1.00, blue: 1.00, alpha: 1)),
        (0.20, NSColor(displayP3Red: 0.42, green: 0.90, blue: 1.00, alpha: 1)),
        (0.12, NSColor(displayP3Red: 1.00, green: 0.48, blue: 0.62, alpha: 1)),
    ]
    // Free space is a faint arc of its own, so the gaps stay clean instead of showing a track.
    let free = 1 - segments.map(\.share).reduce(0, +)
    let gap: CGFloat = 0.035
    var angle = CGFloat.pi / 2
    for (share, color) in segments + [(free, NSColor(white: 1, alpha: 0.18))] {
        let sweep = share * .pi * 2
        context.setStrokeColor(color.cgColor)
        context.addArc(center: center, radius: radius, startAngle: angle - gap / 2,
                       endAngle: angle - sweep + gap / 2, clockwise: true)
        context.strokePath()
        angle -= sweep
    }

    // A light catch along the top edge of the body.
    let shine = CGGradient(colorsSpace: colors, colors: [
        NSColor(white: 1, alpha: 0.22).cgColor,
        NSColor(white: 1, alpha: 0).cgColor,
    ] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(shine, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 700), options: [])
    context.restoreGState()

    // A fine inner edge, as on system icons.
    context.addPath(NSBezierPath(roundedRect: body.insetBy(dx: 1.5, dy: 1.5), xRadius: 184, yRadius: 184).cgPath)
    context.setStrokeColor(NSColor(white: 1, alpha: 0.25).cgColor)
    context.setLineWidth(3)
    context.strokePath()
}

func png(pixels: Int) -> Data {
    let space = CGColorSpace(name: CGColorSpace.displayP3)!
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.interpolationQuality = .high
    drawIcon(in: context, size: CGFloat(pixels))
    let image = context.makeImage()!
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
}

let project = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for points in [16, 32, 128, 256, 512] {
    try png(pixels: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try png(pixels: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}

let resources = project.appendingPathComponent("Resources")
try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
try png(pixels: 1024).write(to: resources.appendingPathComponent("AppIcon-1024.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print(resources.appendingPathComponent("AppIcon.icns").path)
