import AppKit
import CoreGraphics

let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
let ctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = ctx
ctx.imageInterpolation = .high
let rect = CGRect(x: 0, y: 0, width: size, height: size)
NSColor(calibratedRed: 0.015, green: 0.025, blue: 0.06, alpha: 1).setFill()
NSBezierPath(roundedRect: rect.insetBy(dx: 8, dy: 8), xRadius: 190, yRadius: 190).fill()

let border = NSBezierPath(roundedRect: rect.insetBy(dx: 22, dy: 22), xRadius: 178, yRadius: 178)
NSColor(calibratedRed: 0.2, green: 0.65, blue: 1, alpha: 0.9).setStroke()
border.lineWidth = 10
border.stroke()

// Subtle chart grid
let grid = NSBezierPath()
for x in stride(from: 160, through: 880, by: 180) {
    grid.move(to: NSPoint(x: x, y: 270)); grid.line(to: NSPoint(x: x, y: 850))
}
for y in stride(from: 330, through: 810, by: 160) {
    grid.move(to: NSPoint(x: 100, y: y)); grid.line(to: NSPoint(x: 920, y: y))
}
NSColor(calibratedRed: 0.15, green: 0.32, blue: 0.55, alpha: 0.35).setStroke()
grid.lineWidth = 3
grid.stroke()

// Candlesticks
let bars: [(CGFloat,CGFloat,CGFloat,CGFloat,Bool)] = [
(150,430,535,620,true),(245,500,600,700,false),(340,560,650,755,true),
(435,520,600,690,false),(530,600,680,785,true),(625,640,720,830,true),
(720,690,770,875,false),(815,730,815,930,true)
]
for (x,lo,op,cl,up) in bars {
    let color = up ? NSColor(calibratedRed:0.0,green:0.95,blue:0.48,alpha:1) : NSColor(calibratedRed:1,green:0.18,blue:0.19,alpha:1)
    color.setStroke(); color.setFill()
    let wick = NSBezierPath(); wick.move(to:NSPoint(x:x,y:lo)); wick.line(to:NSPoint(x:x,y:cl+35)); wick.lineWidth = 9; wick.stroke()
    let body = NSBezierPath(rect:CGRect(x:x-24,y:min(op,cl),width:48,height:max(36,abs(cl-op))))
    body.fill()
}

// Blue and gold moving-average curves
for (color, offset, width): (NSColor, CGFloat, CGFloat) in [(NSColor(calibratedRed:0.05,green:0.55,blue:1,alpha:1),0,10),(NSColor(calibratedRed:1,green:0.62,blue:0.08,alpha:1),-55,8)] {
    let p=NSBezierPath()
    p.move(to:NSPoint(x:90,y:380+offset))
    p.curve(to:NSPoint(x:930,y:690+offset),controlPoint1:NSPoint(x:350,y:180+offset),controlPoint2:NSPoint(x:620,y:780+offset))
    color.setStroke(); p.lineWidth=width; p.stroke()
}

// Chinese title
let title = "期汇" as NSString
let font = NSFont(name:"PingFangSC-Semibold",size:190) ?? NSFont.boldSystemFont(ofSize:190)
let attrs:[NSAttributedString.Key:Any] = [.font:font,.foregroundColor:NSColor(calibratedWhite:0.96,alpha:1)]
let textSize=title.size(withAttributes:attrs)
title.draw(at:NSPoint(x:(CGFloat(size)-textSize.width)/2,y:115),withAttributes:attrs)

NSGraphicsContext.restoreGraphicsState()
let output = URL(fileURLWithPath:"App/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
let png=rep.representation(using:.png,properties:[:])!
try png.write(to:output.appendingPathComponent("AppIcon.png"))
let json = """
{"images":[{"filename":"AppIcon.png","idiom":"universal","platform":"ios","size":"1024x1024"}],"info":{"author":"xcode","version":1}}
"""
try json.write(to:output.appendingPathComponent("Contents.json"),atomically:true,encoding:.utf8)
