#!/usr/bin/env swift
//
// make-icon.swift
//
// Standalone icon generator for Nickel. Run with `swift scripts/make-icon.swift`.
// Uses AppKit / CoreGraphics offscreen rendering (NSBitmapImageRep) — no SwiftUI,
// no Xcode, no asset catalogs.
//
// Draws the app icon at every required iconset resolution directly from vector
// drawing code (no bitmap upscaling), writes build/icon-preview.png (512x512)
// plus a full build/AppIcon.iconset/, then shells out to `iconutil` to produce
// Resources/AppIcon.icns.

import AppKit
import Foundation

// MARK: - NSBezierPath -> CGPath

extension NSBezierPath {
    var cgPath: CGPath {
        let path = CGMutablePath()
        var points = [CGPoint](repeating: .zero, count: 3)
        for i in 0..<elementCount {
            switch element(at: i, associatedPoints: &points) {
            case .moveTo:
                path.move(to: points[0])
            case .lineTo:
                path.addLine(to: points[0])
            case .curveTo:
                path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .closePath:
                path.closeSubpath()
            default:
                break
            }
        }
        return path
    }
}

// MARK: - Paths

let fileManager = FileManager.default
let scriptURL = URL(fileURLWithPath: #filePath)
let scriptsDir = scriptURL.deletingLastPathComponent()
let repoRoot = scriptsDir.deletingLastPathComponent()

let buildDir = repoRoot.appendingPathComponent("build")
let iconsetDir = buildDir.appendingPathComponent("AppIcon.iconset")
let resourcesDir = repoRoot.appendingPathComponent("Resources")

try? fileManager.createDirectory(at: iconsetDir, withIntermediateDirectories: true)
try? fileManager.createDirectory(at: resourcesDir, withIntermediateDirectories: true)

// MARK: - Drawing

/// Draws the Nickel icon into the current graphics context. `size` is the
/// canvas edge length in pixels; the drawing is defined on a logical 1024
/// canvas and scaled uniformly so every raster size is rendered natively
/// from the same vector description (no upscaling of a fixed bitmap).
func drawIcon(size: CGFloat) {
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }

    let scale = size / 1024.0
    ctx.saveGState()
    ctx.scaleBy(x: scale, y: scale)

    // --- Squircle body -----------------------------------------------------
    let margin: CGFloat = 100
    let bodyRect = CGRect(x: margin, y: margin, width: 1024 - margin * 2, height: 1024 - margin * 2)
    let cornerRadius: CGFloat = 185
    let body = NSBezierPath(roundedRect: bodyRect, xRadius: cornerRadius, yRadius: cornerRadius)
    let bodyCGPath = body.cgPath

    ctx.saveGState()
    ctx.addPath(bodyCGPath)
    ctx.clip()

    let deviceGray = CGColorSpaceCreateDeviceRGB()

    // Vertical brushed-nickel gradient, top (light) -> bottom (dark). Built
    // with an explicit CGGradient (rather than NSGradient's angle parameter)
    // so the direction is unambiguous in this bottom-left-origin context.
    let metalTop = NSColor(calibratedRed: 0x93 / 255.0, green: 0x9A / 255.0, blue: 0xA3 / 255.0, alpha: 1.0)
    let metalBottom = NSColor(calibratedRed: 0x4E / 255.0, green: 0x56 / 255.0, blue: 0x5F / 255.0, alpha: 1.0)
    if let metalGradient = CGGradient(
        colorsSpace: deviceGray,
        colors: [metalTop.cgColor, metalBottom.cgColor] as CFArray,
        locations: [0, 1]
    ) {
        ctx.drawLinearGradient(
            metalGradient,
            start: CGPoint(x: bodyRect.midX, y: bodyRect.maxY),
            end: CGPoint(x: bodyRect.midX, y: bodyRect.minY),
            options: []
        )
    }

    // Soft diagonal sheen across the upper-left half: white -> clear, subtle.
    if let sheenGradient = CGGradient(
        colorsSpace: deviceGray,
        colors: [
            NSColor(calibratedWhite: 1.0, alpha: 0.08).cgColor,
            NSColor(calibratedWhite: 1.0, alpha: 0.0).cgColor,
        ] as CFArray,
        locations: [0, 1]
    ) {
        ctx.drawLinearGradient(
            sheenGradient,
            start: CGPoint(x: bodyRect.minX, y: bodyRect.maxY),
            end: CGPoint(x: bodyRect.midX, y: bodyRect.midY),
            options: []
        )
    }

    ctx.restoreGState()

    // Inner top-edge highlight for a machined-metal feel: a thin bright
    // stroke traced just inside the top of the squircle, fading at the sides.
    ctx.saveGState()
    ctx.addPath(bodyCGPath)
    ctx.clip()
    let edgeHighlight = NSBezierPath(roundedRect: bodyRect.insetBy(dx: 1.5, dy: 1.5), xRadius: cornerRadius - 1.5, yRadius: cornerRadius - 1.5)
    NSColor(calibratedWhite: 1.0, alpha: 0.20).setStroke()
    edgeHighlight.lineWidth = 3
    // Only the top arc reads as a highlight; achieve that by clipping to the
    // upper portion of the body before stroking.
    let topClip = NSBezierPath(rect: CGRect(x: bodyRect.minX, y: bodyRect.midY, width: bodyRect.width, height: bodyRect.height / 2))
    topClip.addClip()
    edgeHighlight.stroke()
    ctx.restoreGState()

    // --- Glyph: two shift-key symbols --------------------------------------
    // Classic shift-key silhouette: a wide upward arrowhead whose base steps
    // inward at "shoulders" into a short rectangular stem, all as one filled
    // polygon.
    func shiftKeyPath(originX: CGFloat, originY: CGFloat, width: CGFloat, height: CGFloat) -> NSBezierPath {
        let headHeight = height * 0.72 // arrowhead portion
        let stemWidth = width * 0.34
        let stemLeft = originX + (width - stemWidth) / 2
        let stemRight = stemLeft + stemWidth
        let shoulderY = originY + headHeight

        let apex = CGPoint(x: originX + width / 2, y: originY + height)
        let rightBaseOuter = CGPoint(x: originX + width, y: shoulderY)
        let rightShoulder = CGPoint(x: stemRight, y: shoulderY)
        let rightStemBottom = CGPoint(x: stemRight, y: originY)
        let leftStemBottom = CGPoint(x: stemLeft, y: originY)
        let leftShoulder = CGPoint(x: stemLeft, y: shoulderY)
        let leftBaseOuter = CGPoint(x: originX, y: shoulderY)

        let path = NSBezierPath()
        path.move(to: apex)
        path.line(to: rightBaseOuter)
        path.line(to: rightShoulder)
        path.line(to: rightStemBottom)
        path.line(to: leftStemBottom)
        path.line(to: leftShoulder)
        path.line(to: leftBaseOuter)
        path.close()
        return path
    }

    let glyphWidth: CGFloat = 280
    let glyphHeight: CGFloat = 400
    let gap: CGFloat = 40
    let groupWidth = glyphWidth * 2 + gap
    let groupOriginX = (1024 - groupWidth) / 2
    let groupOriginY = (1024 - glyphHeight) / 2 + 15 // slight optical lift

    let leftGlyph = shiftKeyPath(originX: groupOriginX, originY: groupOriginY, width: glyphWidth, height: glyphHeight)
    let rightGlyph = shiftKeyPath(originX: groupOriginX + glyphWidth + gap, originY: groupOriginY, width: glyphWidth, height: glyphHeight)

    ctx.saveGState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(calibratedWhite: 0.0, alpha: 0.25)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()

    NSColor.white.setFill()
    leftGlyph.fill()
    rightGlyph.fill()
    ctx.restoreGState()

    ctx.restoreGState()
}

// MARK: - Rendering helpers

func renderPNG(size: CGFloat) -> Data? {
    let pixelSize = Int(size.rounded())
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }
    rep.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
        NSGraphicsContext.restoreGraphicsState()
        return nil
    }
    NSGraphicsContext.current = ctx
    ctx.cgContext.clear(CGRect(x: 0, y: 0, width: size, height: size))
    drawIcon(size: size)
    ctx.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    return rep.representation(using: .png, properties: [:])
}

func writePNG(size: CGFloat, to url: URL) {
    guard let data = renderPNG(size: size) else {
        FileHandle.standardError.write("Failed to render \(url.lastPathComponent)\n".data(using: .utf8)!)
        exit(1)
    }
    do {
        try data.write(to: url)
        print("Wrote \(url.path) (\(Int(size))x\(Int(size)))")
    } catch {
        FileHandle.standardError.write("Failed to write \(url.path): \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}

// MARK: - Generate preview

writePNG(size: 512, to: buildDir.appendingPathComponent("icon-preview.png"))

// MARK: - Generate iconset

let iconsetSpecs: [(name: String, size: CGFloat)] = [
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

for spec in iconsetSpecs {
    writePNG(size: spec.size, to: iconsetDir.appendingPathComponent("\(spec.name).png"))
}

// MARK: - Build .icns via iconutil

let icnsURL = resourcesDir.appendingPathComponent("AppIcon.icns")
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetDir.path, "-o", icnsURL.path]

do {
    try process.run()
    process.waitUntilExit()
    if process.terminationStatus == 0 {
        print("Wrote \(icnsURL.path)")
    } else {
        FileHandle.standardError.write("iconutil failed with status \(process.terminationStatus)\n".data(using: .utf8)!)
        exit(Int32(process.terminationStatus))
    }
} catch {
    FileHandle.standardError.write("Failed to run iconutil: \(error)\n".data(using: .utf8)!)
    exit(1)
}
