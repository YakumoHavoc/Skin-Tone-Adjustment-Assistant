import SwiftUI

/// 色相环色盘：半径方向表示饱和度，角度方向表示色相
/// 取色后会标出取色点、互补色点与目标肤色点，并用虚线扇形标出健康肤色区间
struct ColorWheelView: View {

    let current: HSBColor?
    let target: HSBColor?
    /// 取色点的主色家族名（如「橙」），用于标注「减补色 = 加主色」
    var primaryLabel: String? = nil
    /// 取色点的补色家族名（如「青蓝」）
    var complementLabel: String? = nil

    private let hueLabels: [(Double, String)] = [
        (0, "红"), (60, "黄"), (120, "绿"), (180, "青"), (240, "蓝"), (300, "洋红")
    ]

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let radius = max(side / 2 - 22, 40)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)

            Canvas { ctx, size in
                // 1. 色相分片（每 1° 一片，避免角向渐变在色相上的非线性偏差）
                for degree in 0..<360 {
                    var slice = Path()
                    slice.addArc(center: center,
                                 radius: radius,
                                 startAngle: .degrees(Double(degree) - 90),
                                 endAngle: .degrees(Double(degree + 1) - 90),
                                 clockwise: false)
                    slice.addLine(to: center)
                    slice.closeSubpath()
                    ctx.fill(slice, with: .color(Color(hue: Double(degree) / 360,
                                                       saturation: 1,
                                                       brightness: 1)))
                }

                // 2. 中心白色径向渐变 → 半径越小饱和度越低
                let circle = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                                    width: radius * 2, height: radius * 2))
                ctx.fill(circle, with: .radialGradient(
                    Gradient(colors: [Color.white, Color.white.opacity(0)]),
                    center: center, startRadius: 0, endRadius: radius))

                // 3. 健康肤色区间
                let inner = radius * CGFloat(ColorEngine.healthySatRange.lowerBound)
                let outer = radius * CGFloat(ColorEngine.healthySatRange.upperBound)
                var band = Path()
                band.addArc(center: center, radius: outer,
                            startAngle: .degrees(ColorEngine.healthyHueRange.lowerBound - 90),
                            endAngle: .degrees(ColorEngine.healthyHueRange.upperBound - 90),
                            clockwise: false)
                band.addArc(center: center, radius: inner,
                            startAngle: .degrees(ColorEngine.healthyHueRange.upperBound - 90),
                            endAngle: .degrees(ColorEngine.healthyHueRange.lowerBound - 90),
                            clockwise: true)
                band.closeSubpath()
                ctx.fill(band, with: .color(Color.white.opacity(0.18)))
                ctx.stroke(band, with: .color(Color.white.opacity(0.95)),
                           style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))

                // 4. 取色点 / 互补色点
                if let current {
                    let p = position(of: current, center: center, radius: radius)
                    let comp = position(of: current.complement, center: center, radius: radius)

                    var compLine = Path()
                    compLine.move(to: p)
                    compLine.addLine(to: comp)
                    ctx.stroke(compLine, with: .color(Color.white.opacity(0.55)),
                               style: StrokeStyle(lineWidth: 1, dash: [2, 4]))

                    ctx.fill(Path(ellipseIn: CGRect(x: comp.x - 4, y: comp.y - 4, width: 8, height: 8)),
                             with: .color(Color.white.opacity(0.75)))
                    ctx.stroke(Path(ellipseIn: CGRect(x: comp.x - 4, y: comp.y - 4, width: 8, height: 8)),
                               with: .color(Color.black.opacity(0.45)), lineWidth: 1)

                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - 8, y: p.y - 8, width: 16, height: 16)),
                             with: .color(current.rgb.swiftUIColor))
                    ctx.stroke(Path(ellipseIn: CGRect(x: p.x - 9.5, y: p.y - 9.5, width: 19, height: 19)),
                               with: .color(Color.black.opacity(0.35)), lineWidth: 2.5)
                    ctx.stroke(Path(ellipseIn: CGRect(x: p.x - 8, y: p.y - 8, width: 16, height: 16)),
                               with: .color(Color.white), lineWidth: 2.5)

                    // 主色 / 补色名称：直接体现「减补色 = 加主色」
                    let minX: CGFloat = 44, maxX = max(size.width - 44, minX)
                    if let primaryLabel {
                        drawTag(ctx, text: "主色 \(primaryLabel)",
                                at: CGPoint(x: min(max(p.x, minX), maxX), y: p.y + 21))
                    }
                    if let complementLabel {
                        drawTag(ctx, text: "补色 \(complementLabel)",
                                at: CGPoint(x: min(max(comp.x, minX), maxX), y: comp.y + 21))
                    }
                }

                // 5. 目标肤色点
                if let target {
                    let t = position(of: target, center: center, radius: radius)
                    let rect = CGRect(x: t.x - 7, y: t.y - 7, width: 14, height: 14)
                    ctx.fill(Path(ellipseIn: rect), with: .color(target.rgb.swiftUIColor))
                    ctx.stroke(Path(ellipseIn: rect), with: .color(Color.white),
                               style: StrokeStyle(lineWidth: 2, dash: [2, 2]))
                }

                // 6. 色相标注
                for (degree, label) in hueLabels {
                    let angle = (degree - 90) * Double.pi / 180
                    let pos = CGPoint(x: center.x + (radius - 20) * CGFloat(cos(angle)),
                                      y: center.y + (radius - 20) * CGFloat(sin(angle)))
                    ctx.drawLayer { layer in
                        layer.addFilter(.shadow(color: .black.opacity(0.65), radius: 2))
                        layer.draw(Text(label).font(.system(size: 11, weight: .semibold)).foregroundColor(.white),
                                   at: pos, anchor: .center)
                    }
                }
            }
            .overlay {
                if current == nil {
                    VStack(spacing: 6) {
                        Image(systemName: "eyedropper")
                            .font(.system(size: 22, weight: .light))
                        Text("按 \(AppModel.shared.hotKeyDisplay) 取色")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    /// 色相角对应屏幕角度：0° 在正上方，顺时针递增；半径按饱和度缩放
    private func position(of hsb: HSBColor, center: CGPoint, radius: CGFloat) -> CGPoint {
        let angle = (hsb.hue - 90) * Double.pi / 180
        let r = radius * CGFloat(min(max(hsb.saturation, 0), 1))
        return CGPoint(x: center.x + r * CGFloat(cos(angle)),
                       y: center.y + r * CGFloat(sin(angle)))
    }

    /// 在色盘上绘制小标签（深色底 + 白字，保证在色盘任意位置可读）
    private func drawTag(_ ctx: GraphicsContext, text: String, at point: CGPoint) {
        let cjk = CGFloat(text.filter { $0 != " " }.count)
        let spaces = CGFloat(text.count) - cjk
        let width = cjk * 11.8 + spaces * 4 + 14
        let height: CGFloat = 19
        let box = CGRect(x: point.x - width / 2, y: point.y, width: width, height: height)
        ctx.fill(Path(roundedRect: box, cornerRadius: height / 2), with: .color(.black.opacity(0.55)))
        ctx.draw(Text(text).font(.system(size: 11, weight: .semibold)).foregroundColor(.white),
                 at: CGPoint(x: box.midX, y: box.midY), anchor: .center)
    }
}

extension RGBColor {
    var swiftUIColor: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: 1) }
}
