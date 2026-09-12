// Generates the DMG background (teal wash + faint clip watermark + arrow + headline in Outfit).
// Usage:  swift scripts/make_dmg_bg.swift <outPath.png> <scale>
import AppKit
import CoreText

let args = CommandLine.arguments
let outPath = args.count > 1 ? args[1] : "/tmp/dmgbg.png"
let scale = CGFloat(args.count > 2 ? (Double(args[2]) ?? 2) : 2)

let LW: CGFloat = 660, LH: CGFloat = 400
let W = Int(LW * scale), H = Int(LH * scale)

CTFontManagerRegisterFontsForURL(URL(fileURLWithPath: "scripts/fonts/Outfit.ttf") as CFURL, .process, nil)

func outfit(_ size: CGFloat, weight: Int = 800) -> NSFont {
    let variation: [NSNumber: NSNumber] = [NSNumber(value: 0x77676874): NSNumber(value: weight)]
    let attrs: [CFString: Any] = [kCTFontFamilyNameAttribute: "Outfit" as CFString,
                                  kCTFontVariationAttribute: variation as CFDictionary]
    return CTFontCreateWithFontDescriptor(CTFontDescriptorCreateWithAttributes(attrs as CFDictionary), size, nil) as NSFont
}
func rgb(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
    NSColor(srgbRed: CGFloat(r)/255, green: CGFloat(g)/255, blue: CGFloat(b)/255, alpha: 1)
}

guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
else { fatalError() }

NSGraphicsContext.saveGraphicsState()
let gctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = gctx
let cg = gctx.cgContext
cg.scaleBy(x: scale, y: scale)

// Pale teal diagonal wash.
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [rgb(0xf7,0xfb,0xfa).cgColor, rgb(0xe6,0xf1,0xf0).cgColor, rgb(0xf1,0xf7,0xf6).cgColor] as CFArray,
    locations: [0, 0.55, 1])!
cg.drawLinearGradient(grad, start: CGPoint(x: 0, y: LH), end: CGPoint(x: LW, y: 0),
                      options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

// Faint app-mark watermark, tilted, lower-right.
if let mark = NSImage(contentsOfFile: "img/appicon_1024.png") {
    NSGraphicsContext.saveGraphicsState()
    cg.translateBy(x: 520, y: 150)
    cg.rotate(by: -14 * .pi / 180)
    let s: CGFloat = 280
    mark.draw(in: CGRect(x: -s/2, y: -s/2, width: s, height: s), from: .zero, operation: .sourceOver, fraction: 0.07)
    NSGraphicsContext.restoreGraphicsState()
}

// Arrow between the app and the Applications folder (icon row is y≈200 in a 660×400 window).
let arrow = NSBezierPath()
arrow.lineWidth = 11; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
arrow.move(to: CGPoint(x: 283, y: 200)); arrow.line(to: CGPoint(x: 377, y: 200))
arrow.move(to: CGPoint(x: 377, y: 200)); arrow.line(to: CGPoint(x: 350, y: 173))
arrow.move(to: CGPoint(x: 377, y: 200)); arrow.line(to: CGPoint(x: 350, y: 227))
rgb(0x26, 0x2c, 0x2c).setStroke()
arrow.stroke()

// Headline near the top.
let text = "Who's making that noise?"
var size: CGFloat = 40
let w40 = NSAttributedString(string: text, attributes: [.font: outfit(40)]).size().width
if w40 > 600 { size = 40 * 600 / w40 }
let para = NSMutableParagraphStyle(); para.alignment = .center
let glow = NSShadow(); glow.shadowColor = NSColor.white.withAlphaComponent(0.6); glow.shadowBlurRadius = 5
let astr = NSAttributedString(string: text, attributes: [
    .font: outfit(size), .foregroundColor: rgb(0x26,0x2c,0x2c), .paragraphStyle: para, .shadow: glow])
let ts = astr.size()
astr.draw(at: CGPoint(x: (LW - ts.width)/2, y: LH - 36 - ts.height))

gctx.flushGraphics()
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
