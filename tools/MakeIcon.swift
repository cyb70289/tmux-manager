#!/usr/bin/env swift
// Draws AppIcon.iconset and converts it to AppIcon.icns.
// Usage: swift tools/MakeIcon.swift <output.icns>
import AppKit
import CoreGraphics

let output = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Resources/AppIcon.icns"

func drawIcon(size: CGFloat) -> Data {
    let pixels = Int(size)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(data: nil, width: pixels, height: pixels,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("cannot create context")
    }
    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high

    // Background: rounded square with a subtle vertical gradient.
    let inset = size * 0.055
    let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = rect.width * 0.235
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    context.addPath(path)
    context.clip()
    let colors = [
        CGColor(red: 0.13, green: 0.15, blue: 0.18, alpha: 1),
        CGColor(red: 0.07, green: 0.08, blue: 0.10, alpha: 1),
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1]) {
        context.drawLinearGradient(gradient,
                                   start: CGPoint(x: 0, y: size),
                                   end: CGPoint(x: 0, y: 0),
                                   options: [])
    }

    // Soft green glow behind the prompt.
    let glowCenter = CGPoint(x: size * 0.46, y: size * 0.52)
    let glowColors = [
        CGColor(red: 0.24, green: 0.85, blue: 0.52, alpha: 0.28),
        CGColor(red: 0.24, green: 0.85, blue: 0.52, alpha: 0.0),
    ] as CFArray
    if let glow = CGGradient(colorsSpace: colorSpace, colors: glowColors, locations: [0, 1]) {
        context.drawRadialGradient(glow, startCenter: glowCenter, startRadius: 0,
                                   endCenter: glowCenter, endRadius: size * 0.42,
                                   options: [])
    }

    // Prompt chevron ">"
    let green = CGColor(red: 0.30, green: 0.90, blue: 0.55, alpha: 1)
    context.setStrokeColor(green)
    context.setLineWidth(size * 0.085)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.beginPath()
    context.move(to: CGPoint(x: size * 0.31, y: size * 0.63))
    context.addLine(to: CGPoint(x: size * 0.47, y: size * 0.48))
    context.addLine(to: CGPoint(x: size * 0.31, y: size * 0.33))
    context.strokePath()

    // Cursor block
    let cursor = CGRect(x: size * 0.55, y: size * 0.30, width: size * 0.17, height: size * 0.075)
    context.setFillColor(CGColor(red: 0.90, green: 0.95, blue: 0.92, alpha: 1))
    context.addPath(CGPath(roundedRect: cursor, cornerWidth: size * 0.02,
                           cornerHeight: size * 0.02, transform: nil))
    context.fillPath()

    guard let image = context.makeImage() else { fatalError("no image") }
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: size, height: size)
    guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("no png") }
    return data
}

let fileManager = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("AppIcon.iconset")
try? fileManager.removeItem(at: iconset)
try! fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)

let variants: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
for (points, scale) in variants {
    let pixelSize = points * scale
    let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
    let data = drawIcon(size: CGFloat(pixelSize))
    try! data.write(to: iconset.appendingPathComponent(name))
}
print("wrote \(iconset.path)")

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output]
try! task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}
print("wrote \(output)")
