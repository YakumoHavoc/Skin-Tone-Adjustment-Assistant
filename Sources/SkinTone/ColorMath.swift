import AppKit
import SwiftUI

/// sRGB 颜色（分量范围 0...1）
struct RGBColor: Hashable {
    var r: Double
    var g: Double
    var b: Double

    init(r: Double, g: Double, b: Double) {
        self.r = min(max(r, 0), 1)
        self.g = min(max(g, 0), 1)
        self.b = min(max(b, 0), 1)
    }

    init(r255: Int, g255: Int, b255: Int) {
        self.init(r: Double(r255) / 255, g: Double(g255) / 255, b: Double(b255) / 255)
    }

    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(r255: Int((v >> 16) & 0xFF), g255: Int((v >> 8) & 0xFF), b255: Int(v & 0xFF))
    }

    var r255: Int { Int((r * 255).rounded()) }
    var g255: Int { Int((g * 255).rounded()) }
    var b255: Int { Int((b * 255).rounded()) }

    var hexString: String { String(format: "#%02X%02X%02X", r255, g255, b255) }
    var rgb255String: String { "R \(r255)  G \(g255)  B \(b255)" }

    var hsb: HSBColor {
        let maxV = max(r, g, b)
        let minV = min(r, g, b)
        let d = maxV - minV
        var hue = 0.0
        if d > 0.00001 {
            if maxV == r {
                hue = 60 * ((g - b) / d).truncatingRemainder(dividingBy: 6)
            } else if maxV == g {
                hue = 60 * ((b - r) / d + 2)
            } else {
                hue = 60 * ((r - g) / d + 4)
            }
        }
        if hue < 0 { hue += 360 }
        let sat = maxV <= 0.00001 ? 0 : d / maxV
        return HSBColor(hue: hue, saturation: sat, brightness: maxV)
    }

    /// 红色分量相对绿蓝的超出量，用于衡量“偏红”程度
    var redExcess: Double { r - (g + b) / 2 }
    /// 暖度：红与蓝的差值
    var warmth: Double { r - b }

    func mixed(with other: RGBColor, _ t: Double) -> RGBColor {
        let k = min(max(t, 0), 1)
        return RGBColor(r: r + (other.r - r) * k,
                        g: g + (other.g - g) * k,
                        b: b + (other.b - b) * k)
    }

    var nsColor: NSColor { NSColor(srgbRed: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: 1) }
}

/// HSB / HSV 颜色：色相 0..<360，饱和度 0...1，明度 0...1
struct HSBColor: Hashable {
    var hue: Double
    var saturation: Double
    var brightness: Double

    var rgb: RGBColor {
        let h = ((hue.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360)
        let c = brightness * saturation
        let x = c * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = brightness - c
        var rr = 0.0, gg = 0.0, bb = 0.0
        switch h {
        case ..<60:    rr = c; gg = x; bb = 0
        case ..<120:   rr = x; gg = c; bb = 0
        case ..<180:   rr = 0; gg = c; bb = x
        case ..<240:   rr = 0; gg = x; bb = c
        case ..<300:   rr = x; gg = 0; bb = c
        default:       rr = c; gg = 0; bb = x
        }
        return RGBColor(r: rr + m, g: gg + m, b: bb + m)
    }

    /// 互补色（色相环对面 180°）
    var complement: HSBColor {
        HSBColor(hue: (hue + 180).truncatingRemainder(dividingBy: 360),
                 saturation: saturation,
                 brightness: brightness)
    }

    var hueText: String { String(format: "%.0f°", hue) }
    var saturationText: String { String(format: "%.0f%%", saturation * 100) }
    var brightnessText: String { String(format: "%.0f%%", brightness * 100) }
}
