// Run with 'swift vault/macos/render-icon.swift' on a Mac to regenerate both app icons.
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let vault = URL(fileURLWithPath: #filePath).standardizedFileURL
    .deletingLastPathComponent().deletingLastPathComponent()
let files = FileManager.default
let temp = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try files.createDirectory(at: temp, withIntermediateDirectories: true)
defer { try? files.removeItem(at: temp) }

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [red / 255, green / 255, blue / 255, 1])!
}
let paper = color(247, 246, 241)
let ink = color(38, 37, 31)
let vermilion = color(170, 54, 19)
let wordmarkFont = CTFontCreateWithName("Baskerville" as CFString, 1000, nil)
var letter: UniChar = 0x56
var glyph: CGGlyph = 0
precondition(CTFontGetGlyphsForCharacters(wordmarkFont, &letter, &glyph, 1))
let letterPath = CTFontCreatePathForGlyph(wordmarkFont, glyph, nil)!
let bounds = letterPath.boundingBoxOfPath

func render(to url: URL, pixels: Int, finder: Bool) throws {
    let alpha: CGImageAlphaInfo = finder ? .premultipliedLast : .noneSkipLast
    let gc = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                       bytesPerRow: pixels * 4, space: colorSpace, bitmapInfo: alpha.rawValue)!
    gc.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    let canvas = CGRect(x: 0, y: 0, width: 1024, height: 1024)
    if finder {
        let tile = canvas.insetBy(dx: 84, dy: 84)
        let mask = CGPath(roundedRect: tile, cornerWidth: 184, cornerHeight: 184, transform: nil)
        gc.addPath(mask)
        gc.setFillColor(paper)
        gc.fillPath()
        gc.addPath(mask)
        gc.setLineWidth(1.5)
        gc.setStrokeColor(color(216, 212, 197))
        gc.strokePath()
        gc.translateBy(x: tile.minX, y: tile.minY)
        gc.scaleBy(x: tile.width / 1024, y: tile.height / 1024)
    } else {
        gc.setFillColor(paper)
        gc.fill(canvas)
    }
    // Optical alignment keeps the pointed V and baseline dot balanced in a square.
    gc.saveGState()
    let scale = 574 / bounds.height
    gc.translateBy(x: 498 - bounds.midX * scale, y: 225 - bounds.minY * scale)
    gc.scaleBy(x: scale, y: scale)
    gc.addPath(letterPath)
    gc.setFillColor(ink)
    gc.fillPath()
    gc.restoreGState()
    gc.setFillColor(vermilion)
    gc.fillEllipse(in: CGRect(x: 669, y: 222, width: 84, height: 84))

    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, gc.makeImage()!, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}

try render(to: vault.appendingPathComponent("images/app-icon.png"), pixels: 1024, finder: false)
let iconset = temp.appendingPathComponent("Vault.iconset")
try files.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for multiplier in [1, 2] {
        let suffix = multiplier == 2 ? "@2x" : ""
        let name = "icon_\(points)x\(points)\(suffix).png"
        try render(to: iconset.appendingPathComponent(name), pixels: points * multiplier, finder: true)
    }
}
let convert = Process()
convert.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
convert.arguments = ["-c", "icns", iconset.path, "-o", vault.appendingPathComponent("macos/Vault.icns").path]
try convert.run()
convert.waitUntilExit()
if convert.terminationStatus != 0 { exit(convert.terminationStatus) }
