// Лист кадров из записи экрана симулятора: заставка по кадрам на одной картинке (CI, задача ui).
// swift splash_frames.swift video.mp4 out.png [начало, сек] [шаг, сек] [кадров]
import AVFoundation
import AppKit

let args = CommandLine.arguments
let start = args.count > 3 ? Double(args[3])! : 0.5
let step = args.count > 4 ? Double(args[4])! : 0.3
let count = args.count > 5 ? Int(args[5])! : 24
let columns = 8

let gen = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: args[1])))
gen.appliesPreferredTrackTransform = true
gen.requestedTimeToleranceBefore = .zero
gen.requestedTimeToleranceAfter = .zero
gen.maximumSize = CGSize(width: 300, height: 0)

var frames: [CGImage] = []
for i in 0..<count {
    let t = CMTime(seconds: start + Double(i) * step, preferredTimescale: 600)
    if let img = try? gen.copyCGImage(at: t, actualTime: nil) { frames.append(img) }
}
guard let first = frames.first else { print("нет кадров"); exit(1) }

let w = first.width, h = first.height, gap = 8
let rows = (frames.count + columns - 1) / columns
let sheetW = columns * w + (columns + 1) * gap, sheetH = rows * h + (rows + 1) * gap
let ctx = CGContext(data: nil, width: sheetW, height: sheetH, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
ctx.fill(CGRect(x: 0, y: 0, width: sheetW, height: sheetH))
for (i, img) in frames.enumerated() {
    let col = i % columns, row = i / columns
    let x = gap + col * (w + gap), y = sheetH - (row + 1) * (h + gap)     // кадры слева направо, сверху вниз
    ctx.draw(img, in: CGRect(x: x, y: y, width: w, height: h))
}
let out = URL(fileURLWithPath: args[2]) as CFURL
let dest = CGImageDestinationCreateWithURL(out, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
CGImageDestinationFinalize(dest)
print("кадров: \(frames.count), шаг \(step) с, с \(start) с")
