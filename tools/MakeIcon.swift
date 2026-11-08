#!/usr/bin/env swift
// Draws AppIcon.iconset and converts it to AppIcon.icns.
// Icon: three cascading console windows — two dim, the front one live with a
// green tmux status bar and prompt. Usage: swift tools/MakeIcon.swift <output.icns>
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

    // Soft green glow behind the front (active) window.
    let glowCenter = CGPoint(x: size * 0.55, y: size * 0.58)
    let glowColors = [
        CGColor(red: 0.24, green: 0.85, blue: 0.52, alpha: 0.18),
        CGColor(red: 0.24, green: 0.85, blue: 0.52, alpha: 0.0),
    ] as CFArray
    if let glow = CGGradient(colorsSpace: colorSpace, colors: glowColors, locations: [0, 1]) {
        context.drawRadialGradient(glow, startCenter: glowCenter, startRadius: 0,
                                   endCenter: glowCenter, endRadius: size * 0.38,
                                   options: [])
    }

    let green = CGColor(red: 0.30, green: 0.90, blue: 0.55, alpha: 1)
    let greenDeep = CGColor(red: 0.15, green: 0.52, blue: 0.33, alpha: 1)
    let greenBright = CGColor(red: 0.36, green: 0.95, blue: 0.62, alpha: 1)
    let grayStatus = CGColor(red: 0.32, green: 0.35, blue: 0.39, alpha: 1)
    let windowFill = CGColor(red: 0.05, green: 0.06, blue: 0.08, alpha: 1)
    let windowFillDim = CGColor(red: 0.09, green: 0.11, blue: 0.14, alpha: 1)
    let windowStroke = CGColor(red: 0.34, green: 0.39, blue: 0.44, alpha: 0.9)
    let cursorFill = CGColor(red: 0.90, green: 0.95, blue: 0.92, alpha: 1)

    // A mini terminal window: dark body + tmux-style status strip at the bottom.
    // `active` windows get a green status bar (with a bright session segment) and a prompt.
    func window(_ win: CGRect, active: Bool) {
        let r = win.height * 0.09
        // body
        context.setFillColor(active ? windowFill : windowFillDim)
        context.addPath(CGPath(roundedRect: win, cornerWidth: r, cornerHeight: r, transform: nil))
        context.fillPath()
        let lw = win.height * 0.035
        context.setStrokeColor(active
            ? windowStroke
            : CGColor(red: 0.25, green: 0.28, blue: 0.32, alpha: 0.9))
        context.setLineWidth(lw)
        context.addPath(CGPath(roundedRect: win.insetBy(dx: lw / 2, dy: lw / 2),
                               cornerWidth: r, cornerHeight: r, transform: nil))
        context.strokePath()

        // status strip along the bottom
        let barH = win.height * 0.20
        let bar = CGRect(x: win.minX, y: win.minY, width: win.width, height: barH)
        context.saveGState()
        context.addPath(CGPath(roundedRect: win, cornerWidth: r, cornerHeight: r, transform: nil))
        context.clip()
        context.setFillColor(active ? greenDeep : grayStatus)
        context.fill(bar)
        if active {
            context.setFillColor(greenBright)
            context.fill(CGRect(x: bar.minX, y: bar.minY, width: bar.width * 0.38, height: barH))
        }
        context.restoreGState()

        // "> ▮" prompt in the body (active window only)
        guard active else { return }
        let body = CGRect(x: win.minX, y: bar.maxY, width: win.width, height: win.height - barH)
        let h = body.height * 0.46
        let plw = max(body.height * 0.13, 1)
        let left = body.minX + body.width * 0.12
        let midY = body.midY
        context.setStrokeColor(green)
        context.setLineWidth(plw)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.beginPath()
        context.move(to: CGPoint(x: left, y: midY + h / 2))
        context.addLine(to: CGPoint(x: left + h * 0.55, y: midY))
        context.addLine(to: CGPoint(x: left, y: midY - h / 2))
        context.strokePath()
        if body.height >= 48 {
            let cw = h * 0.34, ch = h * 0.42
            let cursor = CGRect(x: left + h * 0.80, y: midY - ch / 2, width: cw, height: ch)
            context.setFillColor(cursorFill)
            context.addPath(CGPath(roundedRect: cursor, cornerWidth: min(cw, ch) * 0.25,
                                   cornerHeight: min(cw, ch) * 0.25, transform: nil))
            context.fillPath()
        }
    }

    // Three cascading console windows; the front one is live.
    let w = size * 0.52, h = size * 0.44
    window(CGRect(x: size * 0.08, y: size * 0.14, width: w, height: h), active: false)
    window(CGRect(x: size * 0.18, y: size * 0.24, width: w, height: h), active: false)
    window(CGRect(x: size * 0.28, y: size * 0.34, width: w, height: h), active: true)

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
