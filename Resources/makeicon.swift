import AppKit
import Foundation

let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()

let rect = NSRect(x: 0, y: 0, width: size, height: size)
let radius = size * 0.225
let clip = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
clip.addClip()

// 蓝色渐变背景(上浅下深,和 logo 一致)
let grad = NSGradient(colors: [
    NSColor(srgbRed: 0.30, green: 0.42, blue: 0.66, alpha: 1),
    NSColor(srgbRed: 0.17, green: 0.25, blue: 0.46, alpha: 1),
])!
grad.draw(in: rect, angle: -90)

// 淡色月亮(右上)
NSColor(srgbRed: 0.95, green: 0.95, blue: 0.90, alpha: 1.0).setFill()
let moonR = size * 0.115
NSBezierPath(ovalIn: NSRect(x: size*0.66, y: size*0.63, width: moonR*2, height: moonR*2)).fill()

// 三条白色波浪(中下部)
func wave(centerY: CGFloat, amp: CGFloat, lineWidth: CGFloat, alpha: CGFloat) {
    let p = NSBezierPath()
    p.lineWidth = lineWidth
    p.lineCapStyle = .round
    p.lineJoinStyle = .round
    let startX = size*0.16, endX = size*0.84
    let n = 80
    for i in 0...n {
        let t = CGFloat(i)/CGFloat(n)
        let x = startX + (endX-startX)*t
        let y = centerY + amp*sin(t * .pi * 3.4 + 0.3)
        if i == 0 { p.move(to: NSPoint(x: x, y: y)) } else { p.line(to: NSPoint(x: x, y: y)) }
    }
    NSColor(srgbRed: 1, green: 1, blue: 1, alpha: alpha).setStroke()
    p.stroke()
}
let lw = size*0.055
wave(centerY: size*0.44, amp: size*0.045, lineWidth: lw, alpha: 1.0)
wave(centerY: size*0.34, amp: size*0.045, lineWidth: lw, alpha: 0.85)
wave(centerY: size*0.24, amp: size*0.045, lineWidth: lw, alpha: 0.65)

img.unlockFocus()

guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("png 失败\n".data(using: .utf8)!); exit(1)
}
let out = CommandLine.arguments[1]
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
