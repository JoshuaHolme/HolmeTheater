// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Builds App Store marketing images: a raw simulator screenshot inside a drawn device frame, on the app icon's blue
// gradient, under a headline.
//
// Usage: swiftc -O compose.swift -o compose
//        ./compose <iphone|ipad|tv> <screenshot.png> "<headline>" "<subline>" <output.png>
//
// Output sizes are the App Store's: iPhone 6.9" 1320×2868, iPad 13" 2064×2752, Apple TV 3840×2160.

import AppKit

let args = CommandLine.arguments
guard args.count == 6 else {
    FileHandle.standardError.write(Data("usage: compose <iphone|ipad|tv> <screenshot> <headline> <subline> <output>\n".utf8))
    exit(1)
}
let device = args[1], headline = args[3], subline = args[4]
guard let data = try? Data(contentsOf: URL(fileURLWithPath: args[2])),
      let shot = NSBitmapImageRep(data: data)?.cgImage else {
    FileHandle.standardError.write(Data("can't read \(args[2])\n".utf8))
    exit(1)
}

/// Where everything goes for a device, as fractions of the canvas.
struct Layout {
    let size: CGSize
    let textTop: CGFloat        // headline's top, from the canvas top
    let headlineSize: CGFloat
    let sublineSize: CGFloat
    let deviceWidth: CGFloat    // device's width as a fraction of the canvas width
    let deviceTop: CGFloat      // where the device starts, from the canvas top
    let bezel: CGFloat          // bezel thickness in canvas points
    let corner: CGFloat         // screen corner radius as a fraction of the screen width
    let bleeds: Bool            // whether the device runs off the bottom edge
}

let layout: Layout
switch device {
case "iphone":
    layout = Layout(size: CGSize(width: 1320, height: 2868), textTop: 170, headlineSize: 88, sublineSize: 50,
                    deviceWidth: 0.80, deviceTop: 560, bezel: 26, corner: 0.115, bleeds: true)
case "ipad":
    layout = Layout(size: CGSize(width: 2064, height: 2752), textTop: 140, headlineSize: 128, sublineSize: 62,
                    deviceWidth: 0.82, deviceTop: 520, bezel: 36, corner: 0.05, bleeds: true)
case "tv":
    layout = Layout(size: CGSize(width: 3840, height: 2160), textTop: 80, headlineSize: 120, sublineSize: 60,
                    deviceWidth: 0.78, deviceTop: 330, bezel: 0, corner: 0.012, bleeds: true)
default:
    FileHandle.standardError.write(Data("unknown device \(device)\n".utf8))
    exit(1)
}

let W = Int(layout.size.width), H = Int(layout.size.height)
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
// Flip so y grows downward.
ctx.translateBy(x: 0, y: CGFloat(H)); ctx.scaleBy(x: 1, y: -1)

// Background: the app icon's gradient, with a soft glow behind the device.
let top: [CGFloat] = [0.22, 0.47, 0.71], bottom: [CGFloat] = [0.10, 0.31, 0.55]
ctx.drawLinearGradient(CGGradient(colorSpace: space, colorComponents: top + [1] + bottom + [1], locations: [0, 1], count: 2)!,
                       start: .zero, end: CGPoint(x: 0, y: H), options: [])
let glow = CGGradient(colorSpace: space, colorComponents: [1, 1, 1, 0.22, 1, 1, 1, 0], locations: [0, 1], count: 2)!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: CGFloat(W) / 2, y: layout.deviceTop + 300), startRadius: 0,
                       endCenter: CGPoint(x: CGFloat(W) / 2, y: layout.deviceTop + 300), endRadius: CGFloat(W) * 0.7, options: [])

// Text, drawn with AppKit into the flipped context.
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
let centered = NSMutableParagraphStyle(); centered.alignment = .center
func draw(_ text: String, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat, y: CGFloat) -> CGFloat {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: NSColor.white.withAlphaComponent(alpha),
        .paragraphStyle: centered
    ]
    let box = CGRect(x: layout.size.width * 0.06, y: y, width: layout.size.width * 0.88, height: size * 3)
    let used = (text as NSString).boundingRect(with: box.size, options: [.usesLineFragmentOrigin], attributes: attributes)
    (text as NSString).draw(with: box, options: [.usesLineFragmentOrigin], attributes: attributes)
    return used.height
}
let headlineHeight = draw(headline, size: layout.headlineSize, weight: .bold, alpha: 1, y: layout.textTop)
_ = draw(subline, size: layout.sublineSize, weight: .medium, alpha: 0.85, y: layout.textTop + headlineHeight + 24)
NSGraphicsContext.restoreGraphicsState()

// Device: black body with the screenshot inset, scaled to the device width and anchored at its top.
let bodyWidth = layout.size.width * layout.deviceWidth
let screenWidth = bodyWidth - layout.bezel * 2
let scale = screenWidth / CGFloat(shot.width)
let screenHeight = CGFloat(shot.height) * scale
let bodyHeight = screenHeight + layout.bezel * 2
let body = CGRect(x: (layout.size.width - bodyWidth) / 2, y: layout.deviceTop, width: bodyWidth, height: bodyHeight)
let screen = body.insetBy(dx: layout.bezel, dy: layout.bezel)
let bodyRadius = screenWidth * layout.corner + layout.bezel
let screenRadius = screenWidth * layout.corner

// A soft shadow under the body.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 30), blur: 90, color: CGColor(gray: 0, alpha: 0.45))
ctx.setFillColor(CGColor(gray: 0.04, alpha: 1))
ctx.addPath(CGPath(roundedRect: body, cornerWidth: bodyRadius, cornerHeight: bodyRadius, transform: nil))
ctx.fillPath()
ctx.restoreGState()

// A thin rim so the body reads against the dark parts of the screenshot.
ctx.setStrokeColor(CGColor(gray: 0.32, alpha: 1))
ctx.setLineWidth(4)
ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 2, dy: 2), cornerWidth: bodyRadius, cornerHeight: bodyRadius, transform: nil))
ctx.strokePath()

// The screenshot, clipped to the screen's rounded corners. Drawn upright: the context is flipped, so flip back around it.
ctx.saveGState()
ctx.addPath(CGPath(roundedRect: screen, cornerWidth: screenRadius, cornerHeight: screenRadius, transform: nil))
ctx.clip()
ctx.translateBy(x: screen.minX, y: screen.minY + screenHeight)
ctx.scaleBy(x: 1, y: -1)
ctx.draw(shot, in: CGRect(x: 0, y: 0, width: screenWidth, height: screenHeight))
ctx.restoreGState()

try! NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: args[5]))
