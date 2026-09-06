import AppKit
import CoreGraphics

// The EAR Router mark: one route, drawn from where the driver starts to where
// the meal lands. Indigo ground, white path — the same two colours the app
// itself runs on.
let S: CGFloat = 1024
let cs = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(
    data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// Ground: a diagonal indigo gradient through the brand value (#4338CA).
let grad = CGGradient(
    colorsSpace: cs,
    colors: [
        CGColor(red: 0.435, green: 0.376, blue: 0.980, alpha: 1),  // #6F60FA
        CGColor(red: 0.263, green: 0.220, blue: 0.792, alpha: 1),  // #4338CA
        CGColor(red: 0.145, green: 0.106, blue: 0.596, alpha: 1),  // #251B98
    ] as CFArray,
    locations: [0.0, 0.55, 1.0])!
ctx.drawLinearGradient(
    grad, start: CGPoint(x: 0, y: S), end: CGPoint(x: S, y: 0), options: [])

ctx.beginTransparencyLayer(auxiliaryInfo: nil)
ctx.setFillColor(.white)
ctx.setStrokeColor(.white)

// The route: an S from the depot in the bottom left to the door top right.
let start = CGPoint(x: 292, y: 274)
let tip = CGPoint(x: 662, y: 600)
// The route stops *inside* the pin's head rather than at its tip: a round cap
// landing on the tip pokes out sideways past the silhouette, and the two
// shapes have to read as one drawn line.
let route = CGMutablePath()
route.move(to: start)
route.addCurve(
    to: CGPoint(x: 646, y: 706), control1: CGPoint(x: 706, y: 292),
    control2: CGPoint(x: 246, y: 622))
ctx.addPath(route)
ctx.setLineWidth(74)
ctx.setLineCap(.round)
ctx.strokePath()

// Where it starts.
ctx.fillEllipse(in: CGRect(x: start.x - 56, y: start.y - 56, width: 112, height: 112))

// Where it ends: a pin, tip on the end of the route.
let head = CGPoint(x: 662, y: 764)
let r: CGFloat = 106
let pin = CGMutablePath()
// The two points where the tangents from the tip touch the head circle.
let d = hypot(head.x - tip.x, head.y - tip.y)
let a = atan2(head.y - tip.y, head.x - tip.x)
let spread = acos(r / d)
pin.move(to: tip)
// The major arc — the one that runs around the far side of the head, away
// from the tip — so the two tangents and the arc close into a teardrop.
pin.addArc(
    center: head, radius: r,
    startAngle: a + .pi + spread, endAngle: a + .pi - spread, clockwise: false)
pin.closeSubpath()
ctx.addPath(pin)
ctx.fillPath()

// Punch the pin's hole so the ground shows through it.
ctx.setBlendMode(.clear)
ctx.fillEllipse(in: CGRect(x: head.x - 44, y: head.y - 44, width: 88, height: 88))
ctx.setBlendMode(.normal)
ctx.endTransparencyLayer()

let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
