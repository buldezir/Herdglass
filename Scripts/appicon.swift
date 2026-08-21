#!/usr/bin/env swift
//
// The app icon, drawn rather than stored: run this to remake
// `Resources/Herdglass.icns` (which *is* in git, so a normal build never runs
// this — only a change to the design does).
//
//   Scripts/appicon.swift                     # rewrite Resources/Herdglass.icns
//   Scripts/appicon.swift --png out.png       # also leave a 1024px PNG
//
// The picture is the app: a lead ghost at a prompt with a small herd behind it,
// the followers in the two colours `StatusStyle` uses for a pane that wants
// looking at — orange for `blocked`, blue for an unseen `done`. libghostty does
// the rendering, so the bezel-and-phosphor family is deliberate; the artwork
// itself is ours, not ghostty's.

import AppKit
import CoreGraphics
import CoreImage
import Foundation
import ImageIO

// MARK: - geometry

/// The art is authored inside `body` — the size a macOS icon's shape normally
/// has on a 1024 canvas — and then blown up to fill the canvas edge to edge.
/// macOS 26 masks a legacy `.icns` to the icon shape and casts the shadow
/// itself, so art that reserves its own margin gets inset twice and ends up
/// half the size it should be. Filling the canvas hands the whole shape to the
/// artwork; drawing our own rounding anyway is what keeps it a proper icon on
/// macOS 14–15, where nothing masks it for us.
let canvas: CGFloat = 1024
let body = CGRect(x: 100, y: 100, width: 824, height: 824)

/// Superellipse — a close enough stand-in for Apple's continuous corners, and
/// unlike a rounded rect it insets concentrically for the bezel and the glass.
func squircle(_ rect: CGRect, n: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = rect.midX + a * pow(abs(ct), 2 / n) * (ct < 0 ? -1 : 1)
        let y = rect.midY + b * pow(abs(st), 2 / n) * (st < 0 ? -1 : 1)
        i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
    }
    path.closeSubpath()
    return path
}

/// A ghost: domed head, straight flanks, a hem of round lobes.
func ghost(_ rect: CGRect, lobes: Int = 3) -> CGPath {
    let r = rect.width / 2
    let domeY = rect.maxY - r
    let lobeR = rect.width / CGFloat(lobes * 2)
    let hemY = rect.minY + lobeR
    let path = CGMutablePath()
    path.move(to: CGPoint(x: rect.minX, y: hemY))
    path.addLine(to: CGPoint(x: rect.minX, y: domeY))
    path.addArc(center: CGPoint(x: rect.midX, y: domeY), radius: r,
                startAngle: .pi, endAngle: 0, clockwise: true)
    path.addLine(to: CGPoint(x: rect.maxX, y: hemY))
    for i in 0..<lobes {
        let cx = rect.maxX - lobeR - CGFloat(i) * lobeR * 2
        path.addArc(center: CGPoint(x: cx, y: hemY), radius: lobeR,
                    startAngle: 0, endAngle: .pi, clockwise: true)
    }
    path.closeSubpath()
    return path
}

// MARK: - drawing helpers

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
let ciContext = CIContext()

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

func newContext(_ size: CGFloat) -> CGContext {
    CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8,
              bytesPerRow: 0, space: sRGB,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

/// Draw into a canvas-sized layer of its own, so it can be blurred whole.
func layer(_ draw: (CGContext) -> Void) -> CGImage {
    let c = newContext(canvas)
    draw(c)
    return c.makeImage()!
}

func blur(_ image: CGImage, _ sigma: CGFloat) -> CGImage {
    let ci = CIImage(cgImage: image)
    let out = ci.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: ci.extent)
    return ciContext.createCGImage(out, from: ci.extent)!
}

func fillGradient(_ c: CGContext, _ path: CGPath, _ colors: [CGColor],
                  _ locations: [CGFloat], from: CGFloat, to: CGFloat) {
    let gradient = CGGradient(colorsSpace: sRGB, colors: colors as CFArray,
                              locations: locations)!
    c.saveGState()
    c.addPath(path)
    c.clip()
    c.drawLinearGradient(gradient, start: CGPoint(x: 0, y: from), end: CGPoint(x: 0, y: to),
                         options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    c.restoreGState()
}

// MARK: - palette

/// Indigo rather than ghostty's blue: same family, own shelf in the Dock.
let screenTop = rgb(28, 24, 70)
let screenBottom = rgb(62, 46, 152)
let phosphor = rgb(152, 132, 255)

let leadWhite = rgb(242, 246, 255)
let blocked = rgb(255, 155, 34)   // StatusStyle.blocked
let done = rgb(96, 190, 255)      // StatusStyle.done
let faceInk = rgb(26, 24, 62)

// MARK: - the case

/// Chrome shell, dark bezel, glass. Returns the glass to draw the screen into.
/// No cast shadow: on macOS 26 the system draws one, and doubling it muddies
/// the edge.
func drawCase(_ c: CGContext) -> CGPath {
    let shell = squircle(body)
    fillGradient(c, shell,
                 [rgb(247, 247, 249), rgb(208, 208, 214), rgb(150, 150, 158)],
                 [0, 0.55, 1], from: body.maxY, to: body.minY)

    fillGradient(c, squircle(body.insetBy(dx: 44, dy: 44)),
                 [rgb(34, 34, 40), rgb(11, 11, 15)],
                 [0, 1], from: body.maxY, to: body.minY)

    let glass = squircle(body.insetBy(dx: 62, dy: 62), n: 4.6)
    fillGradient(c, glass, [screenTop, screenBottom], [0, 1], from: body.maxY, to: body.minY)
    return glass
}

/// Halftone phosphor, brightest where the herd is.
func drawPhosphor(_ c: CGContext, glass: CGPath, focus: CGPoint) {
    c.saveGState()
    c.addPath(glass)
    c.clip()
    let pitch: CGFloat = 15, dot: CGFloat = 5.4, reach: CGFloat = 540
    var y = body.minY
    while y < body.maxY {
        var x = body.minX
        while x < body.maxX {
            let d = hypot(x - focus.x, y - focus.y) / reach
            let alpha = max(0, 1 - d * d) * 0.5
            if alpha > 0.01 {
                c.setFillColor(phosphor.copy(alpha: alpha)!)
                c.fillEllipse(in: CGRect(x: x, y: y, width: dot, height: dot))
            }
            x += pitch
        }
        y += pitch
    }
    c.restoreGState()
}

/// Scanlines and the highlight across the top of the glass.
func drawGlare(_ c: CGContext, glass: CGPath) {
    c.saveGState()
    c.addPath(glass)
    c.clip()

    c.setFillColor(rgb(0, 0, 0, 0.07))
    var y = body.minY
    while y < body.maxY {
        c.fill(CGRect(x: body.minX, y: y, width: body.width, height: 3))
        y += 7
    }

    // Blurred in its own layer: drawn straight, the sweep's own edge shows up as
    // a seam across the top of the screen.
    let gloss = layer { g in
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: canvas))
        path.addLine(to: CGPoint(x: canvas, y: canvas))
        path.addLine(to: CGPoint(x: canvas, y: 648))
        path.addCurve(to: CGPoint(x: 0, y: 706),
                      control1: CGPoint(x: 700, y: 606), control2: CGPoint(x: 380, y: 706))
        path.closeSubpath()
        fillGradient(g, path, [rgb(255, 255, 255, 0.15), rgb(255, 255, 255, 0.02)],
                     [0, 1], from: body.maxY, to: 620)
    }
    c.draw(blur(gloss, 16), in: CGRect(x: 0, y: 0, width: canvas, height: canvas))

    // Seat the glass in the bezel.
    c.addPath(glass)
    c.setStrokeColor(rgb(0, 0, 0, 0.45))
    c.setLineWidth(14)
    c.strokePath()
    c.restoreGState()
}

// MARK: - the herd

/// A ghost with its phosphor bloom under it.
func drawGhost(_ c: CGContext, _ rect: CGRect, color: CGColor,
               glow: CGFloat, alpha: CGFloat, glass: CGPath) {
    let path = ghost(rect)
    let silhouette = layer { g in
        g.addPath(path)
        g.setFillColor(color)
        g.fillPath()
    }
    let full = CGRect(x: 0, y: 0, width: canvas, height: canvas)
    c.saveGState()
    c.addPath(glass)
    c.clip()
    c.setAlpha(0.85 * alpha)
    c.draw(blur(silhouette, glow), in: full)
    c.setAlpha(0.55 * alpha)
    c.draw(blur(silhouette, glow * 2.6), in: full)
    c.setAlpha(alpha)
    c.addPath(path)
    c.setFillColor(color)
    c.fillPath()
    c.restoreGState()
}

/// The `>_` the lead ghost wears as a face.
func drawPrompt(_ c: CGContext, in rect: CGRect) {
    let weight = rect.height * 0.21
    let chevron = rect.width * 0.34
    c.saveGState()
    c.setStrokeColor(faceInk)
    c.setLineWidth(weight)
    c.setLineCap(.round)
    c.setLineJoin(.round)
    c.move(to: CGPoint(x: rect.minX, y: rect.maxY))
    c.addLine(to: CGPoint(x: rect.minX + chevron, y: rect.midY))
    c.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
    c.strokePath()
    c.move(to: CGPoint(x: rect.minX + chevron + weight * 1.6, y: rect.minY))
    c.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
    c.strokePath()
    c.restoreGState()
}

func drawEyes(_ c: CGContext, _ rect: CGRect, at height: CGFloat, glass: CGPath) {
    let r = rect.width * 0.115
    let y = rect.maxY - rect.height * height
    c.saveGState()
    c.addPath(glass)
    c.clip()
    c.setFillColor(faceInk.copy(alpha: 0.72)!)
    for x in [rect.minX + rect.width * 0.30, rect.minX + rect.width * 0.70] {
        c.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
    }
    c.restoreGState()
}

func drawIcon() -> CGImage {
    // The followers' heads stay well below the lead's dome — level with it they
    // fuse into one silhouette with ears once the icon is 32px wide.
    let lead = CGRect(x: 360, y: 312, width: 304, height: 372)
    let followers = [
        (CGRect(x: 612, y: 354, width: 166, height: 204), blocked, 0.95 as CGFloat),
        (CGRect(x: 248, y: 366, width: 152, height: 186), done, 0.9 as CGFloat),
    ]

    return layer { c in
        // Blow the art up from `body` to the full canvas about the centre. Every
        // length below is authored in `body`'s space and scales with it.
        let fill = canvas / body.width
        c.translateBy(x: canvas / 2, y: canvas / 2)
        c.scaleBy(x: fill, y: fill)
        c.translateBy(x: -canvas / 2, y: -canvas / 2)

        let glass = drawCase(c)
        drawPhosphor(c, glass: glass, focus: CGPoint(x: 512, y: 580))

        for (rect, color, alpha) in followers {
            drawGhost(c, rect, color: color, glow: 13, alpha: alpha, glass: glass)
            drawEyes(c, rect, at: 0.42, glass: glass)
        }

        // A dark gap so the lead reads as standing in front of the herd.
        c.saveGState()
        c.addPath(glass)
        c.clip()
        c.addPath(ghost(lead))
        c.setStrokeColor(rgb(10, 8, 30, 0.55))
        c.setLineWidth(26)
        c.strokePath()
        c.restoreGState()

        drawGhost(c, lead, color: leadWhite, glow: 30, alpha: 1, glass: glass)
        let width = lead.width * 0.60
        drawPrompt(c, in: CGRect(x: lead.midX - width / 2, y: lead.maxY - lead.height * 0.44,
                                 width: width, height: width * 0.38))

        drawGlare(c, glass: glass)
    }
}

// MARK: - output

func write(_ image: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        FileHandle.standardError.write("appicon: cannot write \(path)\n".data(using: .utf8)!)
        exit(1)
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        FileHandle.standardError.write("appicon: failed writing \(path)\n".data(using: .utf8)!)
        exit(1)
    }
}

func scaled(_ image: CGImage, to size: Int) -> CGImage {
    let c = newContext(CGFloat(size))
    c.interpolationQuality = .high
    c.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    return c.makeImage()!
}

func run(_ launchPath: String, _ arguments: [String]) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: launchPath)
    task.arguments = arguments
    try! task.run()
    task.waitUntilExit()
    if task.terminationStatus != 0 { exit(task.terminationStatus) }
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.contains("-h") || arguments.contains("--help") {
    print("usage: Scripts/appicon.swift [--png <path>] [--icns <path>]")
    exit(0)
}

func option(_ name: String) -> String? {
    guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
    return arguments[i + 1]
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let icnsPath = option("--icns") ?? root.appendingPathComponent("Resources/Herdglass.icns").path

let icon = drawIcon()
if let png = option("--png") {
    write(icon, to: png)
    print("wrote \(png)")
}

// iconutil wants an .iconset of the sizes macOS actually asks for.
let iconset = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("Herdglass-\(ProcessInfo.processInfo.processIdentifier).iconset")
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

for base in [16, 32, 128, 256, 512] {
    write(scaled(icon, to: base), to: iconset.appendingPathComponent("icon_\(base)x\(base).png").path)
    write(scaled(icon, to: base * 2), to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png").path)
}

run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", icnsPath])
print("wrote \(icnsPath)")
