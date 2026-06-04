import AppKit

let W: CGFloat = 640, H: CGFloat = 400
let scale: CGFloat = 2
let pw = Int(W * scale), ph = Int(H * scale)

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pw, pixelsHigh: ph,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: W, height: H)   // 144 dpi → crisp on Retina, displays at 640×400 pt

let ctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = ctx
let cg = ctx.cgContext
// rep.size (640×400) already maps the 1280×800px backing to a 640×400 point space — no extra scale.

let cs = CGColorSpaceCreateDeviceRGB()

// — background: soft light gradient (Apple-installer look)
let bgGrad = CGGradient(colorsSpace: cs, colors: [
    NSColor(srgbRed: 0.992, green: 0.992, blue: 0.996, alpha: 1).cgColor,
    NSColor(srgbRed: 0.929, green: 0.933, blue: 0.949, alpha: 1).cgColor
] as CFArray, locations: [0, 1])!
cg.drawLinearGradient(bgGrad, start: CGPoint(x: 0, y: H), end: CGPoint(x: 0, y: 0), options: [])

// — arrow (green→orange), centered between the two icon slots, at their vertical center
let ay: CGFloat = 200
let arrow = CGMutablePath()
arrow.addRoundedRect(in: CGRect(x: 252, y: ay - 5, width: 104, height: 10), cornerWidth: 5, cornerHeight: 5)
arrow.move(to: CGPoint(x: 352, y: ay - 17))
arrow.addLine(to: CGPoint(x: 352, y: ay + 17))
arrow.addLine(to: CGPoint(x: 390, y: ay))
arrow.closeSubpath()
cg.saveGState()
cg.addPath(arrow); cg.clip()
let arrowGrad = CGGradient(colorsSpace: cs, colors: [
    NSColor(srgbRed: 0.204, green: 0.780, blue: 0.349, alpha: 1).cgColor,   // #34C759 green
    NSColor(srgbRed: 1.000, green: 0.624, blue: 0.039, alpha: 1).cgColor    // #FF9F0A orange
] as CFArray, locations: [0, 1])!
cg.drawLinearGradient(arrowGrad, start: CGPoint(x: 250, y: ay), end: CGPoint(x: 392, y: ay), options: [])
cg.restoreGState()

// — text
let titleColor = NSColor(srgbRed: 0.114, green: 0.114, blue: 0.122, alpha: 1)
let subColor   = NSColor(srgbRed: 0.522, green: 0.522, blue: 0.545, alpha: 1)
func center(_ s: String, _ attrs: [NSAttributedString.Key: Any], y: CGFloat) {
    let ns = s as NSString
    let sz = ns.size(withAttributes: attrs)
    ns.draw(at: NSPoint(x: (W - sz.width) / 2, y: y), withAttributes: attrs)
}
center("whisp",
       [.font: NSFont.systemFont(ofSize: 30, weight: .semibold), .foregroundColor: titleColor],
       y: 322)
center("Перетащите whisp в папку Applications",
       [.font: NSFont.systemFont(ofSize: 14, weight: .regular), .foregroundColor: subColor],
       y: 50)

NSGraphicsContext.restoreGraphicsState()

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/whisp-bg/background.png"
try! FileManager.default.createDirectory(atPath: (out as NSString).deletingLastPathComponent,
                                         withIntermediateDirectories: true)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out) — \(pw)x\(ph)px @ \(Int(W))x\(Int(H))pt")
