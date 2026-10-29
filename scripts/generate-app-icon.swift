#!/usr/bin/env swift
// SPDX-License-Identifier: Apache-2.0


import AppKit
import Foundation

let fileManager = FileManager.default
let repository = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
let output = repository.appendingPathComponent("Resources/Rationbook.icns")
let iconset = fileManager.temporaryDirectory.appendingPathComponent("Rationbook-\(UUID().uuidString).iconset", isDirectory: true)
try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fileManager.removeItem(at: iconset) }

let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1_024),
]

func point(_ x: CGFloat, _ y: CGFloat, size: CGFloat) -> NSPoint {
    NSPoint(x: x * size, y: y * size)
}

func render(pixels: Int) throws -> Data {
    let size = CGFloat(pixels)
    let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        NSGraphicsContext.current?.imageInterpolation = .high
        let tile = NSBezierPath(roundedRect: rect.insetBy(dx: size * 0.055, dy: size * 0.055), xRadius: size * 0.24, yRadius: size * 0.24)
        NSGradient(colors: [
            NSColor(red: 0.29, green: 0.36, blue: 0.78, alpha: 1),
            NSColor(red: 0.12, green: 0.16, blue: 0.31, alpha: 1),
        ])?.draw(in: tile, angle: -45)

        NSColor.white.withAlphaComponent(0.18).setStroke()
        tile.lineWidth = max(1, size * 0.012)
        tile.stroke()

        NSColor.white.setStroke()
        let stroke = max(2, size * 0.055)
        let book = NSBezierPath(
            roundedRect: NSRect(x: size * 0.215, y: size * 0.21, width: size * 0.57, height: size * 0.58),
            xRadius: size * 0.07,
            yRadius: size * 0.07
        )
        book.lineWidth = stroke
        book.stroke()

        let mark = NSBezierPath()
        mark.move(to: point(0.37, 0.23, size: size))
        mark.line(to: point(0.37, 0.77, size: size))
        mark.move(to: point(0.47, 0.63, size: size))
        mark.line(to: point(0.70, 0.63, size: size))
        mark.move(to: point(0.47, 0.50, size: size))
        mark.line(to: point(0.64, 0.50, size: size))
        mark.move(to: point(0.47, 0.37, size: size))
        mark.line(to: point(0.57, 0.37, size: size))
        mark.lineWidth = max(1.5, size * 0.045)
        mark.lineCapStyle = .round
        mark.stroke()

        let tab = NSBezierPath(
            roundedRect: NSRect(x: size * 0.6175, y: size * 0.69, width: size * 0.085, height: size * 0.13),
            xRadius: size * 0.025,
            yRadius: size * 0.025
        )
        NSColor(red: 0.78, green: 0.96, blue: 0.38, alpha: 1).setFill()
        tab.fill()
        return true
    }
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    return png
}

for variant in variants {
    try render(pixels: variant.pixels).write(to: iconset.appendingPathComponent(variant.name), options: .atomic)
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { exit(iconutil.terminationStatus) }
print(output.path)
