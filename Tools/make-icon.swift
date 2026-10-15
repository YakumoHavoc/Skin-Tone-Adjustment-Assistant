// 生成「肤色助手」应用图标：深色圆角方底 + HSV 色相环 + 取色环标记 + 吸管
//
// 用法：
//   swiftc -O -o /tmp/make-icon Tools/make-icon.swift && /tmp/make-icon
// 产物：
//   Resources/AppIcon.icns          应用图标（build.sh 会拷入 .app）
//   Resources/AppIcon.iconset/      各尺寸 PNG（中间产物）
//   /tmp/icon-preview-1024.png      预览图

import AppKit
import CoreGraphics
import Foundation

let design: CGFloat = 1024          // 设计画布（y 轴向上）
let bodyInset: CGFloat = 100        // macOS 图标圆角方底内缩
let bodyRadius: CGFloat = 184
let wheelCenter = CGPoint(x: 512, y: 528)
let wheelRadius: CGFloat = 305
let markerHue: Double = 22          // 取色点色相（肤色橙红方向）
let markerSat: Double = 0.60

// MARK: - 工具

func hsv2rgb(_ h: Double, _ s: Double, _ v: Double) -> (Double, Double, Double) {
    let hh = (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
    let c = v * s
    let x = c * (1 - abs((hh / 60).truncatingRemainder(dividingBy: 2) - 1))
    let m = v - c
    var r = 0.0, g = 0.0, b = 0.0
    switch hh {
    case ..<60:   r = c; g = x
    case ..<120:  r = x; g = c
    case ..<180:  g = c; b = x
    case ..<240:  g = x; b = c
    case ..<300:  r = x; b = c
    default:      r = c; b = x
    }
    return (r + m, g + m, b + m)
}

func color(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

/// 色相环位图：半径方向 = 饱和度，角度方向 = 色相（0° 在正上方，顺时针）
func makeWheelBitmap(px: Int) -> CGImage? {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    var data = [UInt8](repeating: 0, count: px * px * 4)

    let center = Double(px) / 2
    let radius = Double(px) / 2 - 1
    let edge = max(1.0, radius * 0.01)   // 边缘 1% 做抗锯齿过渡

    for y in 0..<px {
        let dy = center - (Double(y) + 0.5)          // 位图第 0 行 = 设计中的上方
        let dySq = dy * dy
        for x in 0..<px {
            let dx = Double(x) + 0.5 - center
            let r = (dx * dx + dySq).squareRoot()
            var alpha = (radius - r) / edge
            if alpha <= 0 { continue }
            if alpha > 1 { alpha = 1 }

            var hue = atan2(dy, dx) * 180 / Double.pi
            hue = (90 - hue).truncatingRemainder(dividingBy: 360)
            if hue < 0 { hue += 360 }

            let (rr, gg, bb) = hsv2rgb(hue, min(r / radius, 1), 1)
            let i = (y * px + x) * 4
            data[i] = UInt8((rr * alpha * 255).rounded())
            data[i + 1] = UInt8((gg * alpha * 255).rounded())
            data[i + 2] = UInt8((bb * alpha * 255).rounded())
            data[i + 3] = UInt8((alpha * 255).rounded())
        }
    }

    let provider = CGDataProvider(data: Data(data) as CFData)!
    return CGImage(width: px, height: px,
                   bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: px * 4,
                   space: space,
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
}

/// 色相环上的取色点坐标（与界面中的换算保持一致）
func wheelPoint(hue: Double, sat: Double, radius: CGFloat = wheelRadius) -> CGPoint {
    let angle = (90 - hue) * Double.pi / 180
    let r = radius * CGFloat(sat)
    return CGPoint(x: wheelCenter.x + r * CGFloat(cos(angle)),
                   y: wheelCenter.y + r * CGFloat(sin(angle)))
}

/// 吸管：笔尖落在色相环右下边缘，管身指向右下
func eyedropperPath(tip: CGPoint, angleDegrees: Double) -> CGPath {
    let path = CGMutablePath()
    // 以笔尖为原点、沿 +x 方向构造，再整体旋转
    let tipLen: CGFloat = 46, halfW: CGFloat = 22
    let barrelEnd: CGFloat = 134
    let bulbEnd: CGFloat = 192, bulbHalf: CGFloat = 34

    path.move(to: CGPoint(x: 0, y: 0))
    path.addLine(to: CGPoint(x: tipLen, y: halfW))
    path.addLine(to: CGPoint(x: tipLen, y: -halfW))
    path.closeSubpath()
    path.addRoundedRect(in: CGRect(x: tipLen, y: -halfW, width: barrelEnd - tipLen, height: halfW * 2),
                        cornerWidth: halfW, cornerHeight: halfW)
    path.addRoundedRect(in: CGRect(x: barrelEnd, y: -bulbHalf,
                                   width: bulbEnd - barrelEnd, height: bulbHalf * 2),
                        cornerWidth: bulbHalf, cornerHeight: bulbHalf)

    var transform = CGAffineTransform(translationX: tip.x, y: tip.y)
        .rotated(by: CGFloat(angleDegrees * Double.pi / 180))
    return path.copy(using: &transform) ?? path
}

// MARK: - 绘制

func renderIcon(pixelSize: Int, wheel: CGImage) -> CGImage? {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(data: nil, width: pixelSize, height: pixelSize,
                              bitsPerComponent: 8, bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.interpolationQuality = .high

    let k = CGFloat(pixelSize) / design
    ctx.scaleBy(x: k, y: k)

    // 1. 圆角方底 + 投影
    let body = CGPath(roundedRect: CGRect(x: bodyInset, y: bodyInset,
                                          width: design - bodyInset * 2,
                                          height: design - bodyInset * 2),
                      cornerWidth: bodyRadius, cornerHeight: bodyRadius, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -22), blur: 38, color: color(0, 0, 0, 0.38))
    ctx.addPath(body)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: space,
                              colors: [color(66, 59, 55), color(22, 19, 18)] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: bodyInset, y: design - bodyInset),
                           end: CGPoint(x: design - bodyInset, y: bodyInset),
                           options: [])
    ctx.restoreGState()

    // 2. 内描边高光，贴合 macOS 图标质感
    ctx.saveGState()
    ctx.addPath(body)
    ctx.setStrokeColor(color(255, 255, 255, 0.10))
    ctx.setLineWidth(3)
    ctx.strokePath()
    ctx.restoreGState()

    // 3. 色相环
    ctx.draw(wheel, in: CGRect(x: wheelCenter.x - wheelRadius, y: wheelCenter.y - wheelRadius,
                               width: wheelRadius * 2, height: wheelRadius * 2))

    // 4. 取色环标记（深色描边 + 白色圆环）
    let marker = wheelPoint(hue: markerHue, sat: markerSat)
    ctx.saveGState()
    ctx.setStrokeColor(color(0, 0, 0, 0.35))
    ctx.setLineWidth(26)
    ctx.addArc(center: marker, radius: 36, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.strokePath()
    ctx.setStrokeColor(color(255, 255, 255, 0.98))
    ctx.setLineWidth(18)
    ctx.addArc(center: marker, radius: 36, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.strokePath()
    ctx.restoreGState()

    // 5. 吸管
    let tip = CGPoint(x: wheelCenter.x + wheelRadius * 0.707,
                      y: wheelCenter.y - wheelRadius * 0.707)
    let dropper = eyedropperPath(tip: tip, angleDegrees: -45)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: color(0, 0, 0, 0.5))
    ctx.addPath(dropper)
    ctx.setFillColor(color(255, 255, 255, 1))
    ctx.fillPath()
    ctx.restoreGState()

    return ctx.makeImage()
}

// MARK: - 输出

let outputDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconsetDir = outputDir.appendingPathComponent("Resources/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconsetDir)
try! FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

let wheelSource = makeWheelBitmap(px: 1024)!

func write(_ pixelSize: Int, to name: String) -> CGImage {
    let image = renderIcon(pixelSize: pixelSize, wheel: wheelSource)!
    let rep = NSBitmapImageRep(cgImage: image)
    let png = rep.representation(using: .png, properties: [:])!
    try! png.write(to: iconsetDir.appendingPathComponent(name))
    return image
}

// iconset 规范：1x 与 @2x 成对
_ = write(16, to: "icon_16x16.png")
_ = write(32, to: "icon_16x16@2x.png")
_ = write(32, to: "icon_32x32.png")
_ = write(64, to: "icon_32x32@2x.png")
_ = write(128, to: "icon_128x128.png")
_ = write(256, to: "icon_128x128@2x.png")
_ = write(256, to: "icon_256x256.png")
_ = write(512, to: "icon_256x256@2x.png")
_ = write(512, to: "icon_512x512.png")
let preview = write(1024, to: "icon_512x512@2x.png")

let rep = NSBitmapImageRep(cgImage: preview)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/icon-preview-1024.png"))

// 打包成 .icns
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconsetDir.path,
                      "-o", outputDir.appendingPathComponent("Resources/AppIcon.icns").path]
try! iconutil.run()
iconutil.waitUntilExit()

print("iconset: \(iconsetDir.path)")
print("icns:    \(outputDir.appendingPathComponent("Resources/AppIcon.icns").path) (exit \(iconutil.terminationStatus))")
print("preview: /tmp/icon-preview-1024.png")
