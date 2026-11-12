import AppKit
import Foundation

guard CommandLine.arguments.count > 1 else {
    fatalError("Usage: swift make_app_icon.swift <output-directory>")
}

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
}

// These outlines use the same three fanned panels as the menu bar glyph.
func leftPanel() -> NSBezierPath {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: 0.6, y: 4.7))
    path.curve(to: NSPoint(x: 1.0, y: 5.9), controlPoint1: NSPoint(x: 0.4, y: 5.1), controlPoint2: NSPoint(x: 0.5, y: 5.5))
    path.line(to: NSPoint(x: 3.6, y: 10.1))
    path.curve(to: NSPoint(x: 4.8, y: 10.4), controlPoint1: NSPoint(x: 3.9, y: 10.6), controlPoint2: NSPoint(x: 4.4, y: 10.7))
    path.line(to: NSPoint(x: 11.0, y: 5.0))
    path.curve(to: NSPoint(x: 11.2, y: 4.1), controlPoint1: NSPoint(x: 11.3, y: 4.7), controlPoint2: NSPoint(x: 11.4, y: 4.4))
    path.line(to: NSPoint(x: 10.3, y: 1.1))
    path.curve(to: NSPoint(x: 9.5, y: 0.6), controlPoint1: NSPoint(x: 10.1, y: 0.6), controlPoint2: NSPoint(x: 9.9, y: 0.5))
    path.line(to: NSPoint(x: 1.2, y: 3.7))
    path.curve(to: NSPoint(x: 0.6, y: 4.7), controlPoint1: NSPoint(x: 0.7, y: 3.9), controlPoint2: NSPoint(x: 0.5, y: 4.3))
    path.close()
    return path
}

func middlePanel() -> NSBezierPath {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: 6.0, y: 11.5))
    path.curve(to: NSPoint(x: 6.4, y: 12.5), controlPoint1: NSPoint(x: 5.8, y: 11.9), controlPoint2: NSPoint(x: 5.9, y: 12.2))
    path.line(to: NSPoint(x: 10.2, y: 14.6))
    path.curve(to: NSPoint(x: 11.0, y: 14.1), controlPoint1: NSPoint(x: 10.6, y: 14.9), controlPoint2: NSPoint(x: 10.9, y: 14.7))
    path.line(to: NSPoint(x: 13.6, y: 5.6))
    path.curve(to: NSPoint(x: 13.2, y: 4.7), controlPoint1: NSPoint(x: 13.8, y: 5.2), controlPoint2: NSPoint(x: 13.6, y: 4.9))
    path.line(to: NSPoint(x: 12.7, y: 4.5))
    path.curve(to: NSPoint(x: 12.1, y: 4.8), controlPoint1: NSPoint(x: 12.4, y: 4.4), controlPoint2: NSPoint(x: 12.2, y: 4.5))
    path.close()
    return path
}

func rightPanel() -> NSBezierPath {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: 12.2, y: 16.9))
    path.curve(to: NSPoint(x: 13.1, y: 17.5), controlPoint1: NSPoint(x: 12.2, y: 17.3), controlPoint2: NSPoint(x: 12.5, y: 17.5))
    path.line(to: NSPoint(x: 16.4, y: 17.5))
    path.curve(to: NSPoint(x: 17.5, y: 16.4), controlPoint1: NSPoint(x: 17.1, y: 17.5), controlPoint2: NSPoint(x: 17.5, y: 17.1))
    path.line(to: NSPoint(x: 17.5, y: 5.2))
    path.curve(to: NSPoint(x: 16.8, y: 4.6), controlPoint1: NSPoint(x: 17.5, y: 4.7), controlPoint2: NSPoint(x: 17.3, y: 4.5))
    path.line(to: NSPoint(x: 14.1, y: 5.5))
    path.curve(to: NSPoint(x: 13.7, y: 6.0), controlPoint1: NSPoint(x: 13.9, y: 5.6), controlPoint2: NSPoint(x: 13.7, y: 5.8))
    path.close()
    return path
}

func drawPanel(_ path: NSBezierPath, from low: NSColor, to high: NSColor,
               angle: CGFloat, edge: NSColor) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.52)
    shadow.shadowBlurRadius = 25
    shadow.shadowOffset = NSSize(width: 0, height: -8)
    shadow.set()
    NSGradient(starting: low, ending: high)!.draw(in: path, angle: angle)
    NSGraphicsContext.restoreGraphicsState()

    path.lineWidth = 3
    edge.setStroke()
    path.stroke()
}

func drawIcon() {
    let canvas = CGRect(x: 0, y: 0, width: 1024, height: 1024)
    NSGraphicsContext.current!.cgContext.clear(canvas)

    let background = NSBezierPath(roundedRect: canvas.insetBy(dx: 18, dy: 18),
                                  xRadius: 248, yRadius: 248)
    NSGradient(starting: rgb(8, 11, 15), ending: rgb(42, 49, 61))!
        .draw(in: background, angle: 135)
    background.lineWidth = 2
    rgb(124, 138, 158, alpha: 0.18).setStroke()
    background.stroke()

    var transform = AffineTransform(translationByX: 104, byY: 113)
    transform.scale(x: 43.8, y: 38.2)
    let blue = leftPanel()
    let lavender = middlePanel()
    let warmWhite = rightPanel()
    for panel in [blue, lavender, warmWhite] {
        panel.transform(using: transform)
    }

    drawPanel(blue,
              from: rgb(38, 78, 132), to: rgb(151, 194, 245), angle: 125,
              edge: rgb(201, 227, 255, alpha: 0.68))
    drawPanel(lavender,
              from: rgb(93, 87, 132), to: rgb(195, 181, 229), angle: 110,
              edge: rgb(226, 216, 250, alpha: 0.66))
    drawPanel(warmWhite,
              from: rgb(252, 226, 210), to: rgb(187, 197, 215), angle: 90,
              edge: rgb(255, 255, 255, alpha: 0.78))
}

for pixelSize in [16, 32, 64, 128, 256, 512, 1024] {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                        pixelsWide: pixelSize,
                                        pixelsHigh: pixelSize,
                                        bitsPerSample: 8,
                                        samplesPerPixel: 4,
                                        hasAlpha: true,
                                        isPlanar: false,
                                        colorSpaceName: .deviceRGB,
                                        bytesPerRow: 0,
                                        bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        fatalError("Cannot create \(pixelSize)-pixel icon")
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    context.cgContext.scaleBy(x: CGFloat(pixelSize) / 1024,
                              y: CGFloat(pixelSize) / 1024)
    drawIcon()
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Cannot encode \(pixelSize)-pixel icon")
    }
    try data.write(to: outputDirectory.appendingPathComponent("AppIcon-\(pixelSize).png"))
}
