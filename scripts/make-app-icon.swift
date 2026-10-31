// Draws the shared app icon (keycap + wireless signal) for the iOS app and the Mac Receiver.
// Usage: swift scripts/make-app-icon.swift   (run from the repo root)
import AppKit
import CoreGraphics

let root = FileManager.default.currentDirectoryPath
let iosSet = "\(root)/iOS/RemoteKeyboardApp/Assets.xcassets/AppIcon.appiconset"
let macSet = "\(root)/macOS/MacReceiver/Assets.xcassets/AppIcon.appiconset"

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

/// Draws the artwork in a 1024x1024 design space (y up) into the current context.
func drawArt(_ c: CGContext) {
    let space = CGColorSpaceCreateDeviceRGB()
    // Background: faint vertical shade, same hue family.
    let grad = CGGradient(colorsSpace: space, colors: [rgb(0x3A3A3C), rgb(0x2C2C2E)] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(grad, start: CGPoint(x: 0, y: 1024), end: CGPoint(x: 0, y: 0), options: [])

    // Keycap: 540 wide (~53%), offset to lower left.
    let cap = CGRect(x: 110, y: 150, width: 540, height: 450)
    let capPath = CGPath(roundedRect: cap, cornerWidth: 96, cornerHeight: 96, transform: nil)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -26), blur: 40, color: rgb(0x000000, 0.28))
    c.setFillColor(rgb(0xFFFFFF))
    c.addPath(capPath)
    c.fillPath()
    c.restoreGState()

    // Signal: three concentric arcs radiating from the keycap's top-right corner.
    let origin = CGPoint(x: cap.maxX, y: cap.maxY)
    c.setStrokeColor(rgb(0xF2F2F7))
    c.setLineWidth(40)
    c.setLineCap(.round)
    for r: CGFloat in [120, 210, 300] {
        c.addArc(center: origin, radius: r, startAngle: 8 * .pi / 180, endAngle: 82 * .pi / 180, clockwise: false)
        c.strokePath()
    }
}

func render(pixels: Int, mac: Bool) -> Data {
    let space = CGColorSpaceCreateDeviceRGB()
    // iOS icons must be opaque (no alpha channel); the macOS one needs transparent corners.
    let info = mac ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
    let c = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                      space: space, bitmapInfo: info)!
    c.setAllowsAntialiasing(true)
    c.setShouldAntialias(true)
    c.interpolationQuality = .high
    let s = CGFloat(pixels) / 1024
    c.scaleBy(x: s, y: s)
    if mac {
        // Apple macOS grid: 824x824 rounded rect centred on the 1024 canvas, corner ~185.
        let body = CGRect(x: 100, y: 100, width: 824, height: 824)
        c.addPath(CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil))
        c.clip()
        c.translateBy(x: 100, y: 100)
        c.scaleBy(x: 824.0 / 1024, y: 824.0 / 1024)
    }
    drawArt(c)
    let rep = NSBitmapImageRep(cgImage: c.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

func write(_ data: Data, _ path: String) { try! data.write(to: URL(fileURLWithPath: path)) }
func mkdir(_ p: String) { try! FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true) }
func json(_ s: String, _ path: String) { try! s.write(toFile: path, atomically: true, encoding: .utf8) }

let info = #"{ "info" : { "author" : "xcode", "version" : 1 } }"# + "\n"

// iOS: one opaque 1024 square (alpha stripped by drawing the full-bleed background).
mkdir(iosSet)
write(render(pixels: 1024, mac: false), "\(iosSet)/AppIcon-1024.png")
json(info, "\(root)/iOS/RemoteKeyboardApp/Assets.xcassets/Contents.json")
json("""
{
  "images" : [
    { "filename" : "AppIcon-1024.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
""" + "\n", "\(iosSet)/Contents.json")

// macOS
mkdir(macSet)
json(info, "\(root)/macOS/MacReceiver/Assets.xcassets/Contents.json")
var entries: [String] = []
for pt in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "AppIcon-\(pt)@\(scale)x.png"
        write(render(pixels: pt * scale, mac: true), "\(macSet)/\(name)")
        entries.append(#"    { "filename" : "\#(name)", "idiom" : "mac", "scale" : "\#(scale)x", "size" : "\#(pt)x\#(pt)" }"#)
    }
}
json("{\n  \"images\" : [\n" + entries.joined(separator: ",\n") + "\n  ],\n  \"info\" : { \"author\" : \"xcode\", \"version\" : 1 }\n}\n", "\(macSet)/Contents.json")

// Previews (kept outside the repo).
let shots = "/private/tmp/claude-501/rk-icon-shots"
mkdir(shots)
for (tag, mac) in [("ios", false), ("mac", true)] {
    for px in [1024, 64, 32] { write(render(pixels: px, mac: mac), "\(shots)/\(tag)-\(px).png") }
}
print("done")
