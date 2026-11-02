#!/usr/bin/env swift
import CoreGraphics
import Foundation
import ImageIO

// Rasterize the existing PatternMark from LibraryComponents.swift for AppIcon.
// Keep its 3×3 dot layout, equal dot/gap sizes, accent, and muted-dot opacity.
let size = 1024
let background: [CGFloat] = [0.965, 0.961, 0.945]
let accent: [CGFloat] = [0.22, 0.38, 0.32]
let diameter: CGFloat = 128
let gap: CGFloat = 128
let inset = (CGFloat(size) - (diameter * 3 + gap * 2)) / 2

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                        bytesPerRow: size * 4, space: colorSpace,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
context.setFillColor(CGColor(colorSpace: colorSpace, components: background + [1])!)
context.fill(CGRect(x: 0, y: 0, width: size, height: size))
// Match SwiftUI's top-to-bottom grid rows in Core Graphics' coordinate system.
context.translateBy(x: 0, y: CGFloat(size))
context.scaleBy(x: 1, y: -1)

for row in 0..<3 {
    for column in 0..<3 {
        let opacity: CGFloat = row == column || column == 2 ? 1 : 0.23
        let color = zip(accent, background).map { $0 * opacity + $1 * (1 - opacity) }
        context.setFillColor(CGColor(colorSpace: colorSpace, components: color + [1])!)
        context.fillEllipse(in: CGRect(x: inset + CGFloat(column) * (diameter + gap),
                                       y: inset + CGFloat(row) * (diameter + gap),
                                       width: diameter, height: diameter))
    }
}

// Leave the canvas square and opaque; iOS applies the app-icon corner mask.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let output = root.appending(path: "patternlock/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
let destination = CGImageDestinationCreateWithURL(output as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(destination, context.makeImage()!, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("Could not write app icon") }
print(output.path)
