// Generates img/og-image.png (1200x630) for social sharing, styled like the site hero.
// Run from repo root:  swift scripts/make_og.swift
import AppKit
import CoreText

let W = 1200, H = 630
CTFontManagerRegisterFontsForURL(URL(fileURLWithPath: "scripts/fonts/Outfit.ttf") as CFURL, .process, nil)

func outfit(_ size: CGFloat, weight: Int) -> NSFont {
    let variation: [NSNumber: NSNumber] = [NSNumber(value: 0x77676874): NSNumber(value: weight)]  // 'wght'
    let attrs: [CFString: Any] = [kCTFontFamilyNameAttribute: "Outfit" as CFString,
                                  kCTFontVariationAttribute: variation as CFDictionary]
    return CTFontCreateWithFontDescriptor(CTFontDescriptorCreateWithAttributes(attrs as CFDictionary), size, nil) as NSFont
}
func rgb(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
    NSColor(srgbRed: CGFloat(r)/255, green: CGFloat(g)/255, blue: CGFloat(b)/255, alpha: 1)
}

guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
else { fatalError("no rep") }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// Teal-tinted wash, like the hero.
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [rgb(0xe6,0xf1,0xf0).cgColor, rgb(0xfc,0xfe,0xfd).cgColor] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: H), end: CGPoint(x: 0, y: 0), options: [])

// App icon, left.
if let icon = NSImage(contentsOfFile: "img/appicon_1024.png") {
    let s: CGFloat = 300
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: NSColor(srgbRed: 0.25, green: 0.43, blue: 0.42, alpha: 0.35).cgColor)
    icon.draw(in: CGRect(x: 110, y: (CGFloat(H) - s)/2, width: s, height: s))
    ctx.restoreGState()
}

func line(_ text: String, font: NSFont, color: NSColor, x: CGFloat, y: CGFloat) {
    NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .kern: -0.5]).draw(at: CGPoint(x: x, y: y))
}
let x: CGFloat = 470
line("clipvolume", font: outfit(92, weight: 800), color: rgb(0x26,0x2c,0x2c), x: x - 4, y: 352)
line("Who's making that noise?", font: outfit(40, weight: 600), color: rgb(0x3f,0x6f,0x6d), x: x, y: 280)
line("Per-app volume, mute & pause", font: outfit(27, weight: 400), color: rgb(0x5d,0x66,0x66), x: x, y: 214)
line("for the Mac menu bar  ·  clipvolume.com", font: outfit(27, weight: 400), color: rgb(0x5d,0x66,0x66), x: x, y: 176)

NSGraphicsContext.current!.flushGraphics()
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "img/og-image.png"))
print("wrote img/og-image.png")
