// Run from the repository root: swift Design/generate-app-icons.swift
// Original vector artwork; no external assets or dependencies.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let canvasSize = 1024

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [red, green, blue, 1])!
}

func makeContext(size: Int, transparent: Bool = false) -> CGContext {
    // App Store icons must be opaque; complication templates need a transparent background.
    CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8,
        bytesPerRow: size * 4, space: colorSpace,
        bitmapInfo: transparent
            ? CGImageAlphaInfo.premultipliedLast.rawValue
            : CGImageAlphaInfo.noneSkipLast.rawValue
    )!
}

func drawIcon(transparent: Bool = false) -> CGImage {
    let context = makeContext(size: canvasSize, transparent: transparent)
    context.translateBy(x: 0, y: CGFloat(canvasSize))
    context.scaleBy(x: 1, y: -1)

    if !transparent {
        let gradient = CGGradient(
            colorsSpace: colorSpace,
            colors: [color(0.08, 0.23, 0.43), color(0.025, 0.07, 0.18)] as CFArray,
            locations: [0, 1]
        )!
        context.drawLinearGradient(
            gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 1024, y: 1024),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
    }

    // Two swept feathers suggest Hermes' wing without losing clarity at Watch sizes.
    context.setFillColor(transparent ? color(1, 1, 1) : color(0.31, 0.88, 0.96))
    let upperFeather = CGMutablePath()
    upperFeather.move(to: CGPoint(x: 534, y: 350))
    upperFeather.addLine(to: CGPoint(x: 790, y: 264))
    upperFeather.addQuadCurve(to: CGPoint(x: 558, y: 416), control: CGPoint(x: 738, y: 382))
    upperFeather.closeSubpath()
    context.addPath(upperFeather)
    context.fillPath()

    let lowerFeather = CGMutablePath()
    lowerFeather.move(to: CGPoint(x: 548, y: 438))
    lowerFeather.addLine(to: CGPoint(x: 730, y: 380))
    lowerFeather.addQuadCurve(to: CGPoint(x: 550, y: 502), control: CGPoint(x: 684, y: 476))
    lowerFeather.closeSubpath()
    context.addPath(lowerFeather)
    context.fillPath()

    context.setFillColor(color(1, 1, 1))
    context.addPath(CGPath(
        roundedRect: CGRect(x: 398, y: 254, width: 156, height: 308),
        cornerWidth: 78, cornerHeight: 78, transform: nil
    ))
    context.fillPath()

    context.setStrokeColor(color(1, 1, 1))
    context.setLineWidth(48)
    context.setLineCap(.round)
    let cradle = CGMutablePath()
    cradle.move(to: CGPoint(x: 340, y: 518))
    cradle.addLine(to: CGPoint(x: 340, y: 534))
    cradle.addCurve(
        to: CGPoint(x: 612, y: 534),
        control1: CGPoint(x: 340, y: 702), control2: CGPoint(x: 612, y: 702)
    )
    cradle.addLine(to: CGPoint(x: 612, y: 518))
    context.addPath(cradle)
    context.strokePath()

    context.move(to: CGPoint(x: 476, y: 660))
    context.addLine(to: CGPoint(x: 476, y: 750))
    context.move(to: CGPoint(x: 404, y: 750))
    context.addLine(to: CGPoint(x: 548, y: 750))
    context.strokePath()
    return context.makeImage()!
}

func writePNG(
    _ image: CGImage, size: Int, to url: URL,
    transparent: Bool = false, contentScale: CGFloat = 1
) throws {
    let context = makeContext(size: size, transparent: transparent)
    context.interpolationQuality = .high
    let canvas = CGRect(x: 0, y: 0, width: size, height: size)
    let padding = CGFloat(size) * (1 - contentScale) / 2
    context.draw(image, in: canvas.insetBy(dx: padding, dy: padding))
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else {
        throw NSError(domain: "AppIconGeneration", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Cannot create \(url.path)"])
    }
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "AppIconGeneration", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "Cannot write \(url.path)"])
    }
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let icon = drawIcon()
let catalogs = [
    "InstantHermes/Assets.xcassets/AppIcon.appiconset",
    "InstantHermesWatchApp/Assets.xcassets/AppIcon.appiconset"
]

// Read the catalog so regeneration always uses exactly the declared filenames and sizes.
for catalog in catalogs {
    let directory = root.appendingPathComponent(catalog)
    let data = try Data(contentsOf: directory.appendingPathComponent("Contents.json"))
    let contents = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    for image in contents["images"] as! [[String: Any]] {
        guard let filename = image["filename"] as? String else { continue }
        let points = Double((image["size"] as! String).components(separatedBy: "x")[0])!
        let scale = Double((image["scale"] as? String ?? "1x").dropLast())!
        try writePNG(icon, size: Int(points * scale), to: directory.appendingPathComponent(filename))
        print("Generated \(catalog)/\(filename)")
    }
}

// Crop away the app icon's padding so the glyph stays legible in small watch-face slots.
let glyph = drawIcon(transparent: true).cropping(to: CGRect(x: 272, y: 224, width: 576, height: 576))!
let complicationDirectory = root.appendingPathComponent(
    "InstantHermesWatchApp/Assets.xcassets/ComplicationIcon.imageset"
)
for scale in 1...2 {
    let filename = scale == 1 ? "ComplicationIcon.png" : "ComplicationIcon@\(scale)x.png"
    try writePNG(glyph, size: 64 * scale,
                 to: complicationDirectory.appendingPathComponent(filename),
                 transparent: true, contentScale: 0.85)
    print("Generated \(filename)")
}
