import AppKit

// Genera el icono de Omnimount: tarjeta SD con flecha de montaje sobre
// squircle degradado, al estilo de los iconos de macOS Big Sur+.

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else { exit(1) }

// Margen estándar de los iconos macOS (~10% por lado).
let margin: CGFloat = size * 0.098
let squircleRect = CGRect(x: margin, y: margin, width: size - 2 * margin, height: size - 2 * margin)
let squircle = NSBezierPath(roundedRect: squircleRect, xRadius: size * 0.185, yRadius: size * 0.185)

// Sombra suave del squircle.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.008), blur: size * 0.02,
              color: NSColor.black.withAlphaComponent(0.35).cgColor)
NSColor(calibratedRed: 0.13, green: 0.15, blue: 0.23, alpha: 1).setFill()
squircle.fill()
ctx.restoreGState()

// Degradado de fondo: azul profundo → violeta.
squircle.addClip()
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.16, green: 0.23, blue: 0.48, alpha: 1),
    NSColor(calibratedRed: 0.35, green: 0.18, blue: 0.55, alpha: 1),
])!
gradient.draw(in: squircleRect, angle: -60)

// Brillo superior sutil.
let glow = NSGradient(colors: [
    NSColor.white.withAlphaComponent(0.18),
    NSColor.white.withAlphaComponent(0.0),
])!
glow.draw(in: CGRect(x: margin, y: squircleRect.midY, width: squircleRect.width, height: squircleRect.height / 2), angle: -90)

// ---- Tarjeta SD ----
// Cuerpo centrado, con la esquina superior derecha achaflanada (forma SD).
let cardW = size * 0.34
let cardH = size * 0.46
let cardX = (size - cardW) / 2
let cardY = (size - cardH) / 2 + size * 0.02
let notch = size * 0.09

let card = NSBezierPath()
card.move(to: NSPoint(x: cardX, y: cardY))
card.line(to: NSPoint(x: cardX + cardW, y: cardY))
card.line(to: NSPoint(x: cardX + cardW, y: cardY + cardH - notch))
card.line(to: NSPoint(x: cardX + cardW - notch, y: cardY + cardH))
card.line(to: NSPoint(x: cardX, y: cardY + cardH))
card.close()

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.012), blur: size * 0.035,
              color: NSColor.black.withAlphaComponent(0.45).cgColor)
NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
card.fill()
ctx.restoreGState()

// Contactos dorados de la tarjeta (5 pines arriba).
let pinCount = 5
let pinAreaW = cardW * 0.72
let pinW = pinAreaW / (CGFloat(pinCount) * 1.6)
let pinH = cardH * 0.14
let pinY = cardY + cardH - pinH - size * 0.035
let pinSpacing = (pinAreaW - CGFloat(pinCount) * pinW) / CGFloat(pinCount - 1)
NSColor(calibratedRed: 0.85, green: 0.68, blue: 0.21, alpha: 1).setFill()
for i in 0..<pinCount {
    let px = cardX + cardW * 0.10 + CGFloat(i) * (pinW + pinSpacing)
    NSBezierPath(roundedRect: NSRect(x: px, y: pinY, width: pinW, height: pinH),
                 xRadius: pinW * 0.25, yRadius: pinW * 0.25).fill()
}

// Flecha de montaje (triángulo + asta), verde, en el cuerpo de la tarjeta.
let arrowColor = NSColor(calibratedRed: 0.22, green: 0.78, blue: 0.45, alpha: 1)
let acx = cardX + cardW / 2
let arrowW = cardW * 0.46
let headH = cardH * 0.20
let shaftH = cardH * 0.22
let shaftW = arrowW * 0.38
let baseY = cardY + cardH * 0.14

arrowColor.setFill()
NSBezierPath(roundedRect: NSRect(x: acx - shaftW / 2, y: baseY, width: shaftW, height: shaftH),
             xRadius: shaftW * 0.2, yRadius: shaftW * 0.2).fill()
let head = NSBezierPath()
head.move(to: NSPoint(x: acx - arrowW / 2, y: baseY + shaftH))
head.line(to: NSPoint(x: acx + arrowW / 2, y: baseY + shaftH))
head.line(to: NSPoint(x: acx, y: baseY + shaftH + headH))
head.close()
head.fill()

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { exit(2) }
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
try! png.write(to: URL(fileURLWithPath: out))
print("escrito \(out)")
