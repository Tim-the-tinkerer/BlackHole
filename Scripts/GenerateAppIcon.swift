#!/usr/bin/env swift
import AppKit
import Foundation

let sizes: [(name: String, px: CGFloat)] = [
    ("icon_16x16", 16),
    ("icon_16x16@2x", 32),
    ("icon_32x32", 32),
    ("icon_32x32@2x", 64),
    ("icon_128x128", 128),
    ("icon_128x128@2x", 256),
    ("icon_256x256", 256),
    ("icon_256x256@2x", 512),
    ("icon_512x512", 512),
    ("icon_512x512@2x", 1024),
]

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    NSColor(calibratedRed: 0.04, green: 0.04, blue: 0.045, alpha: 1).setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: size, height: size)).fill()

    let center = NSPoint(x: size / 2, y: size / 2)
    let outer = size * 0.34

    if size >= 32 {
        let glowRect = NSRect(
            x: center.x - outer * 1.45,
            y: center.y - outer * 1.45,
            width: outer * 2.9,
            height: outer * 2.9
        )
        let glow = NSGradient(colors: [
            NSColor(calibratedRed: 1, green: 0.55, blue: 0.16, alpha: 0.55),
            NSColor(calibratedRed: 1, green: 0.35, blue: 0.08, alpha: 0),
        ])!
        glow.draw(in: NSBezierPath(ovalIn: glowRect), relativeCenterPosition: .zero)
    }

    let steps = size < 32 ? 10 : 80
    for i in 0..<steps {
        let t = CGFloat(i) / CGFloat(steps)
        let angle = t * 360
        let peak = (1 + cos((angle - 110) * .pi / 180)) / 2
        let color = NSColor(
            calibratedRed: 1,
            green: 0.42 + 0.5 * peak,
            blue: 0.12 + 0.55 * peak,
            alpha: 0.28 + 0.72 * peak
        )
        color.setStroke()
        let path = NSBezierPath()
        path.appendArc(
            withCenter: center,
            radius: outer,
            startAngle: angle,
            endAngle: angle + (360 / CGFloat(steps)) + 1.2,
            clockwise: false
        )
        path.lineWidth = max(1, size * 0.05)
        path.lineCapStyle = .round
        path.stroke()
    }

    let hole = outer * 0.74
    NSColor.black.setFill()
    NSBezierPath(ovalIn: NSRect(x: center.x - hole, y: center.y - hole, width: hole * 2, height: hole * 2)).fill()

    NSColor(calibratedWhite: 1, alpha: size < 32 ? 0.95 : 0.8).setStroke()
    let photon = NSBezierPath(ovalIn: NSRect(x: center.x - hole, y: center.y - hole, width: hole * 2, height: hole * 2))
    photon.lineWidth = max(1, size * 0.012)
    photon.stroke()

    image.unlockFocus()
    return image
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let assets = root.appendingPathComponent("Assets")
let iconset = assets.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for item in sizes {
    let img = drawIcon(size: item.px)
    guard let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:])
    else {
        fputs("Failed to render \(item.name)\n", stderr)
        exit(1)
    }
    try png.write(to: iconset.appendingPathComponent("\(item.name).png"))
    print("Wrote \(item.name).png")
}

let master = drawIcon(size: 1024)
if let tiff = master.tiffRepresentation,
   let rep = NSBitmapImageRep(data: tiff),
   let png = rep.representation(using: .png, properties: [:]) {
    try png.write(to: assets.appendingPathComponent("AppIcon-1024.png"))
}

let icns = assets.appendingPathComponent("AppIcon.icns")
let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try proc.run()
proc.waitUntilExit()
if proc.terminationStatus != 0 {
    fputs("iconutil failed\n", stderr)
    exit(1)
}
print("Created \(icns.path)")
