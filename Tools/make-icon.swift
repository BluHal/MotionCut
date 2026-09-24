import AppKit
import Foundation

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/tmp/motioncut-icon.png")
let side = 1024
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
let field = NSColor(srgbRed: 8/255, green: 11/255, blue: 13/255, alpha: 1)
let surface = NSColor(srgbRed: 17/255, green: 25/255, blue: 27/255, alpha: 1)
let mint = NSColor(srgbRed: 85/255, green: 233/255, blue: 176/255, alpha: 1)
field.setFill()
NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: side, height: side),
             xRadius: 195, yRadius: 195).fill()
surface.setFill()
NSBezierPath(roundedRect: NSRect(x: 48, y: 48, width: side - 96, height: side - 96),
             xRadius: 155, yRadius: 155).fill()
mint.setStroke()
let mark = NSBezierPath()
mark.lineWidth = 43
mark.lineCapStyle = .square
mark.move(to: NSPoint(x: 235, y: 755))
mark.line(to: NSPoint(x: 170, y: 260))
mark.line(to: NSPoint(x: 730, y: 260))
mark.stroke()
for (index, length) in [270, 345, 420].enumerated() {
    let trace = NSBezierPath()
    trace.lineWidth = 37
    trace.lineCapStyle = .square
    let y = 430 + index * 118
    trace.move(to: NSPoint(x: 305, y: y))
    trace.line(to: NSPoint(x: 305 + length, y: y + 95))
    trace.stroke()
}
NSGraphicsContext.restoreGraphicsState()
let png = bitmap.representation(using: .png, properties: [:])!
try png.write(to: output)
print(output.path)
