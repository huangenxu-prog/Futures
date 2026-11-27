// Inspect saturated marks across the plot interior, away from indicator legends.
import CoreGraphics
import Foundation
import ImageIO

let url = URL(fileURLWithPath: CommandLine.arguments[1])
let source = CGImageSourceCreateWithURL(url as CFURL,nil)!
let image = CGImageSourceCreateImageAtIndex(source,0,nil)!
let w = image.width, h = image.height
var rgba = [UInt8](repeating:0,count:w*h*4)
let space = CGColorSpace(name:CGColorSpace.sRGB)!
var hits = Array(repeating:[Int](),count:4)
rgba.withUnsafeMutableBytes { bytes in
    let ctx = CGContext(data:bytes.baseAddress,width:w,height:h,bitsPerComponent:8,
                        bytesPerRow:w*4,space:space,
                        bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image,in:CGRect(x:0,y:0,width:w,height:h))
    for y in 0..<h {
        for x in w/4..<(w*4/5) {
            let offset = (y*w+x)*4
            let r = bytes[offset], g = bytes[offset+1], b = bytes[offset+2]
            if r>200 && g<65 && b>200 { hits[0].append(y) } // moving average
            if r>200 && g>200 && b<65 { hits[1].append(y) } // text
            if r<65 && g>200 && b>200 { hits[2].append(y) } // histogram
            if r<65 && g>200 && b<65 { hits[3].append(y) } // conditional sticks
        }
    }
}
for (name,rows) in zip(["average","text","histogram","sticks"],hits) {
    precondition(rows.count >= 12,"missing formula plot: " + name)
    print(name,rows.count,"pixels",rows.first!,rows.last!)
}
let main = hits[0] + hits[1], pane = hits[2] + hits[3]
precondition(main.max()! < pane.min()! || pane.max()! < main.min()!,
             "formula marks overlap the wrong pane")
