import Foundation

/// 肤色偏色类型
enum SkinBias: String, Hashable {
    case tooRed = "偏红"
    case tooOrange = "偏橙"
    case tooDull = "偏灰偏脏"
    case tooCool = "偏黄偏冷"
    case balanced = "较为均衡"
    /// 只在手动把远离肤色区的颜色指定为肤色时出现（极端环境还原）
    case extreme = "极端偏色"

    var accentHex: String {
        switch self {
        case .tooRed:    return "#D9564F"
        case .tooOrange: return "#E08A32"
        case .tooDull:   return "#8A8A8A"
        case .tooCool:   return "#4E8FB8"
        case .balanced:  return "#4FA96B"
        case .extreme:   return "#8A6BB8"
        }
    }
}

/// 取色点的颜色大分类
enum SkinKind: String, Hashable {
    case skin = "肤色"
    case nonSkin = "非肤色"

    var accentHex: String {
        switch self {
        case .skin:    return "#4FA96B"
        case .nonSkin: return "#8A8A8A"
        }
    }
}

/// 取色点的「肤色 / 非肤色」分类结果
struct SkinClassification: Hashable {
    let kind: SkinKind
    /// 色相家族名（十二色相环），如「橙」「青蓝」；无彩色时为「中性灰」「近白」「深色」
    let family: String
    let reason: String
    /// 是否为手动指定（覆盖自动判定）
    var isManual: Bool = false

    var isSkin: Bool { kind == .skin }
    /// 如「肤色 · 橙」「非肤色 · 青蓝（手动）」
    var label: String { isManual ? "\(kind.rawValue) · \(family)（手动）" : "\(kind.rawValue) · \(family)" }
}

/// 单个滑块操作，例如「青色 +12」
struct SliderMove: Hashable {
    let text: String
    let why: String
}

/// 一个通道上的完整调整动作（对应「可选颜色」里的一个通道）
struct ChannelStep: Hashable {
    let channel: String
    let headline: String
    /// 在 Photoshop 里的操作路径：进哪个对话框 / 面板，选哪个通道，动哪些控件
    let path: String
    let moves: [SliderMove]
    let reason: String
}

/// 诊断用的数值行
struct ColorMetric: Hashable {
    let name: String
    let value: String
    let hint: String
}

/// 去灰建议：互补色以 50% 相混即变灰，所以「减去补色」等于「增加主色」
struct DegreyingAdvice: Hashable {
    /// 主色家族名，如「橙」「青蓝」「红」
    let familyName: String
    /// 家族在色相环上的位置说明，如「橙（红 0° 与黄 60° 之间）」
    let familyDetail: String
    /// 主色（1~2 个），如 ["红", "黄"]
    let primaryPair: [String]
    /// 补色（1~2 个），如 ["青", "蓝"]
    let complementPair: [String]
    /// 灰化程度 0...1，越大说明混入的补色越多
    let grayness: Double
    /// 在 Photoshop 里的操作路径
    let path: String
    /// 具体操作（减去补色）
    let moves: [SliderMove]
    let summary: String
    let examples: [String]

    var graynessText: String { String(format: "%.0f%%", grayness * 100) }
    var isClean: Bool { grayness < 0.20 }
}

/// 一次取色的完整分析结论
struct Analysis: Hashable {
    let source: RGBColor
    let bias: SkinBias
    let diagnosis: String
    let metrics: [ColorMetric]
    let steps: [ChannelStep]
    let theory: [String]
    let target: RGBColor
    let severity: Double
    /// 手动指定的分类（nil = 自动判定）
    var assumedKind: SkinKind? = nil

    var sourceHSB: HSBColor { source.hsb }
    var targetHSB: HSBColor { target.hsb }

    /// 去灰建议只取决于取色点本身，按需计算
    var degreying: DegreyingAdvice { ColorEngine.degreyingAdvice(for: source) }

    /// 取色点本身是肤色还是非肤色（手动指定时以手动为准）
    var classification: SkinClassification { ColorEngine.classifySkin(source, assumed: assumedKind) }

    var currentSummary: String {
        "\(source.hexString)  ·  H \(sourceHSB.hueText) S \(sourceHSB.saturationText) B \(sourceHSB.brightnessText)"
            + "  ·  \(classification.label)  ·  \(bias.rawValue)"
    }
}

/// 调色建议引擎：把取到的颜色按「偏红 / 偏橙 / 偏灰偏脏 / 偏黄偏冷」归类，
/// 并给出「可选颜色」通道级的具体加色、加亮建议。
enum ColorEngine {

    /// 理想肤色参考点：H 27° / S 42% / B 78%
    static let idealSkin = HSBColor(hue: 27, saturation: 0.42, brightness: 0.78)

    /// 健康肤色区间（用于色相环上的标注）
    static let healthyHueRange: ClosedRange<Double> = 15...45
    static let healthySatRange: ClosedRange<Double> = 0.25...0.62

    // MARK: - Photoshop 操作路径（各步骤共用）

    /// 「可选颜色」的入口：对话框与调整图层两种走法
    private static let selectiveEntry = "菜单「图像 › 调整 › 可选颜色」（没有快捷键），或用调整图层：图层面板底部第 4 个图标 › 可选颜色"

    /// 选通道之后的收尾提示
    private static let selectiveTail = "，按下面数值拖底部滑块；「相对 / 绝对」保持默认的「相对」即可（改动更小、过渡更稳）"

    /// 「可选颜色」里先选哪个通道
    private static func selective(_ channel: String) -> String {
        "\(selectiveEntry) → 面板顶部「颜色」下拉选「\(channel)」"
    }

    /// 「可选颜色」底部只有 CMY+K 四个滑块，写清与原色的换算
    private static let cmyNote = "注意「可选颜色」底部只有「青色 / 洋红 / 黄色 / 黑色」四个滑块：加红＝洋红＋黄，加绿＝黄＋青，加蓝＝青＋洋红；减红＝加青，减绿＝加洋红，减蓝＝加黄。"

    /// 整体提亮 / 压暗的两种走法
    private static let lightenPath = "用「曲线」（⌘M）把曲线中段整条往上抬一点"
    private static let darkenPath = "用「亮度/对比度」调整图层把「亮度」往左拖一点"

    static func analyze(_ color: RGBColor, assumed: SkinKind? = nil) -> Analysis {
        let auto = classifySkin(color)
        let kind = assumed ?? auto.kind

        var analysis: Analysis
        if kind != auto.kind {
            analysis = kind == .skin ? restoreAnalysis(color, auto) : nonSkinAnalysis(color, auto)
        } else {
            let hsb = color.hsb
            let bias = classify(hsb, color)
            let severity = intensity(for: bias, hsb: hsb, color: color)
            switch bias {
            case .tooRed:    analysis = redAnalysis(color, hsb, severity)
            case .tooOrange: analysis = orangeAnalysis(color, hsb, severity)
            case .tooDull:   analysis = dullAnalysis(color, hsb, severity)
            case .tooCool:   analysis = coolAnalysis(color, hsb, severity)
            case .balanced:  analysis = balancedAnalysis(color, hsb, severity)
            case .extreme:   analysis = restoreAnalysis(color, auto)
            }
        }
        analysis.assumedKind = assumed
        return analysis
    }

    // MARK: - 判定

    private static func classify(_ hsb: HSBColor, _ c: RGBColor) -> SkinBias {
        // 先判灰：彩度很低，或又暗又闷
        if hsb.saturation < 0.16 || (hsb.saturation < 0.30 && hsb.brightness < 0.45) {
            return .tooDull
        }
        // 色相、饱和、明度都已经落在健康区间内，就不再硬塞一个偏色结论
        if inHealthyBand(hsb) { return .balanced }

        let hue = hsb.hue
        if hue >= 340 || hue < 15 { return .tooRed }
        if hue < 45 { return .tooOrange }
        if hue < 80 { return .tooCool }        // 偏黄
        if hue < 200 { return .tooCool }       // 偏绿 / 偏青
        // 蓝紫方向的冷色也按偏冷处理
        if hue >= 200 { return .tooCool }
        return .balanced
    }

    /// 色相、饱和、明度是否都落在健康肤色区间内（明度取 60%–85%）
    private static func inHealthyBand(_ hsb: HSBColor) -> Bool {
        healthyHueRange.contains(hsb.hue)
            && healthySatRange.contains(hsb.saturation)
            && hsb.brightness >= 0.60 && hsb.brightness <= 0.85
    }

    private static func intensity(for bias: SkinBias, hsb: HSBColor, color: RGBColor) -> Double {
        let s = hsb.saturation, b = hsb.brightness, hue = hsb.hue
        switch bias {
        case .tooRed:
            let hueDef = hue <= 15 ? (15 - hue) : (hue - 340)          // 0...15
            return clamp(hueDef / 15 * 0.55
                         + clamp(s - 0.32) * 0.55
                         + clamp((color.redExcess - 0.10) / 0.30) * 0.5)
        case .tooOrange:
            let dev = abs(hue - 28)                                     // 距橙色中心
            return clamp(clamp(s - 0.28) * 0.7
                         + clamp(dev / 17) * 0.3
                         + clamp((color.warmth - 0.22) / 0.50) * 0.5)
        case .tooDull:
            return clamp((0.30 - s) / 0.30 * 0.7 + clamp((0.60 - b) / 0.60) * 0.5)
        case .tooCool:
            return clamp(clamp((0.24 - color.warmth) / 0.55) * 0.8 + clamp((s - 0.20) / 0.5) * 0.3)
        case .balanced:
            return clamp((0.60 - b) / 0.60 * 0.6)
        case .extreme:
            return clamp(1 - skinScore(hsb, color))
        }
    }

    // MARK: - 肤色 / 非肤色 分类

    /// 综合匹配度阈值：达到即判为肤色
    private static let skinThreshold = 0.55

    /// 十二色相环上的名称（6 基准色 + 6 中间色），用于给出取色点的色相家族
    private static let twelveNames: [(angle: Double, name: String)] = [
        (0, "红"), (30, "橙"), (60, "黄"), (90, "黄绿"), (120, "绿"), (150, "青绿"),
        (180, "青"), (210, "青蓝"), (240, "蓝"), (270, "蓝紫"), (300, "洋红"), (330, "紫红")
    ]

    /// 取色点最接近的色相家族名
    static func hueFamily(_ hue: Double) -> String {
        var best = twelveNames[0].name
        var bestDistance = 360.0
        for item in twelveNames {
            let raw = abs(item.angle - hue)
            let distance = min(raw, 360 - raw)
            if distance < bestDistance {
                bestDistance = distance
                best = item.name
            }
        }
        return best
    }

    /// 判断取色点是肤色还是非肤色；assumed 非空时以手动指定为准（用于极端环境纠错）
    static func classifySkin(_ c: RGBColor, assumed: SkinKind? = nil) -> SkinClassification {
        let auto = autoClassification(c)
        guard let assumed, assumed != auto.kind else { return auto }

        if assumed == .skin {
            return SkinClassification(
                kind: .skin,
                family: auto.family,
                reason: "手动指定为「肤色」（自动判定为「\(auto.kind.rawValue) · \(auto.family)」）。"
                    + "该点已远离常规肤色区间，按「极端环境下的肤色还原」给出建议。",
                isManual: true)
        }
        return SkinClassification(
            kind: .nonSkin,
            family: auto.family,
            reason: "手动指定为「非肤色」（自动判定为「肤色 · \(auto.family)」）。"
                + "按非肤色处理：偏红 / 偏橙 / 偏黄偏冷这些肤色结论不适用，只看颜色本身。",
            isManual: true)
    }

    /// 自动判定：先做硬性排除（黑、白、中性灰、冷色相），再按四项加权匹配度决定
    private static func autoClassification(_ c: RGBColor) -> SkinClassification {
        let hsb = c.hsb
        let s = hsb.saturation, b = hsb.brightness, h = hsb.hue
        let family = hueFamily(h)

        if b < 0.12 {
            return SkinClassification(kind: .nonSkin, family: "深色",
                reason: "明度 B \(hsb.brightnessText) 已接近黑色，肤色不会这么暗 → 判定为「非肤色」（深色）。")
        }
        if b > 0.95 && s < 0.12 {
            return SkinClassification(kind: .nonSkin, family: "近白",
                reason: "明度 B \(hsb.brightnessText) 接近全白、饱和 S \(hsb.saturationText) 接近 0，属于高光或白点 → 判定为「非肤色」（近白）。")
        }
        if s < 0.08 {
            return SkinClassification(kind: .nonSkin, family: "中性灰",
                reason: "饱和 S \(hsb.saturationText) 几乎没有彩度，色相已不可靠，属于中性灰 → 判定为「非肤色」（中性灰）。")
        }
        if h > 85 && h < 338 {
            return SkinClassification(kind: .nonSkin, family: family,
                reason: "色相 H \(hsb.hueText) 落在\(family)一侧，肤色只会出现在暖区（约 338°–85°，中心 27°）→ 判定为「非肤色」（\(family)）。")
        }

        let score = skinScore(hsb, c)

        if score >= skinThreshold {
            return SkinClassification(kind: .skin, family: family,
                reason: "色相 H \(hsb.hueText) 落在肤色暖区（中心 27°），饱和 S \(hsb.saturationText)、"
                    + "明度 B \(hsb.brightnessText) 与 R>G>B 的暖调结构都符合，综合匹配度 \(pct(score))"
                    + " → 判定为「肤色」（\(family)）。")
        }

        let cause: String
        if hueAffinity(h) <= 0.3 {
            cause = "色相 H \(hsb.hueText) 离肤色中心 27° 偏远"
        } else if saturationAffinity(s) < 0.5 {
            cause = s > 0.65
                ? "饱和 S \(hsb.saturationText) 高于肤色上限（约 62%），属于高彩度纯色"
                : "饱和 S \(hsb.saturationText) 低于肤色下限（约 25%），彩度不足以构成肤色"
        } else if brightnessAffinity(b) < 0.5 {
            cause = b > 0.85
                ? "明度 B \(hsb.brightnessText) 偏高、接近高光"
                : "明度 B \(hsb.brightnessText) 偏低"
        } else {
            cause = "暖度 R−B = \(pct(c.warmth)) 偏低，缺少肤色应有的暖调"
        }
        return SkinClassification(kind: .nonSkin, family: family,
            reason: "\(cause)，综合匹配度只有 \(pct(score))（阈值 \(pct(skinThreshold))）"
                + " → 判定为「非肤色」（\(family)）。")
    }

    /// 肤色匹配度：色相 0.45 / 饱和 0.25 / 明度 0.15 / 暖度 0.15 四项加权
    private static func skinScore(_ hsb: HSBColor, _ c: RGBColor) -> Double {
        0.45 * hueAffinity(hsb.hue)
            + 0.25 * saturationAffinity(hsb.saturation)
            + 0.15 * brightnessAffinity(hsb.brightness)
            + 0.15 * clamp((c.r - c.b) / 0.35)
    }

    /// 色相接近肤色中心 27° 的程度
    private static func hueAffinity(_ hue: Double) -> Double {
        let raw = abs(hue - 27)
        let d = min(raw, 360 - raw)
        if d <= 20 { return 1 }
        if d <= 40 { return 0.6 }
        if d <= 55 { return 0.3 }
        return 0
    }

    /// 肤色饱和区间：约 25%–62% 最典型
    private static func saturationAffinity(_ s: Double) -> Double {
        if s < 0.08 { return 0 }
        if s < 0.20 { return (s - 0.08) / 0.12 }
        if s <= 0.65 { return 1 }
        if s <= 0.85 { return 1 - (s - 0.65) / 0.20 * 0.75 }
        return 0.1
    }

    /// 肤色明度区间：约 30%–85% 最典型
    private static func brightnessAffinity(_ b: Double) -> Double {
        if b < 0.15 { return 0 }
        if b < 0.30 { return (b - 0.15) / 0.15 }
        if b <= 0.85 { return 1 }
        if b <= 0.96 { return 1 - (b - 0.85) / 0.11 * 0.75 }
        return 0.1
    }

    // MARK: - 各分支建议

    private static func redAnalysis(_ c: RGBColor, _ hsb: HSBColor, _ sev: Double) -> Analysis {
        let cyan = amount(5 + 16 * sev)
        let blue = amount(3 + 9 * sev)
        let lighten = lightenAmount(hsb.brightness, target: 0.74)

        let steps = [
            ChannelStep(
                channel: "红色",
                headline: "单独压低「红色」通道",
                path: selective("红色") + selectiveTail + "；加蓝写作「黄色」滑块的负值，提亮写作「黑色」滑块的负值。",
                moves: [
                    SliderMove(text: "青色 +\(cyan)", why: "青是红的互补色，加青直接把红色压下去"),
                    SliderMove(text: "蓝色 +\(blue)", why: "蓝是青的邻近支持色（在「可选颜色」里等于黄色 −\(blue)），补青压得更干净"),
                    SliderMove(text: "明度 +\(lighten)", why: "在「可选颜色」里即黑色 −\(lighten)；压完红不提亮，皮肤会发闷")
                ],
                reason: "不要动整体色相，进入「可选颜色」只选「红色」这一通道，其他颜色不受影响。"
            )
        ]

        return Analysis(
            source: c,
            bias: .tooRed,
            diagnosis: "色相 H \(hsb.hueText) 落在红色区，饱和 S \(hsb.saturationText)，红色分量比绿蓝高出 \(pct(c.redExcess)) → 判定为「偏红」。",
            metrics: metrics(hsb, c, extra: [("红超出量", pct(c.redExcess), "R − (G+B)/2，越大越红")]),
            steps: steps,
            theory: [
                "红 ↔ 青 是互补色：直接用整体色相去混会发脏，所以走「青色 + 蓝色」把红压下去。",
                "蓝色是青的邻近支持色，两者方向一致，比单纯加青更稳、更不容易发灰。",
                "压完红一定要补一点亮，皮肤才会由「红闷」变成「干净透亮」。"
            ],
            target: target(for: c, severity: sev),
            severity: sev
        )
    }

    private static func orangeAnalysis(_ c: RGBColor, _ hsb: HSBColor, _ sev: Double) -> Analysis {
        let redCyan = amount(4 + 12 * sev)
        let redBlue = amount(3 + 8 * sev)
        let yellowCyan = amount(4 + 11 * sev)
        let yellowBlue = amount(3 + 9 * sev)
        let lighten = lightenAmount(hsb.brightness, target: 0.76)

        let steps = [
            ChannelStep(
                channel: "红色",
                headline: "第一步：先调「红色」通道",
                path: selective("红色") + selectiveTail + "；加蓝写作「黄色」滑块的负值。",
                moves: [
                    SliderMove(text: "青色 +\(redCyan)", why: "橙 = 红 + 黄，先把其中的红用青压住"),
                    SliderMove(text: "蓝色 +\(redBlue)", why: "蓝色作青的支持色（可选颜色里为黄色 −\(redBlue)），红这一路收干净")
                ],
                reason: "橙色由红和黄混合而来，只压红往往不够，所以要分两条通道走。"
            ),
            ChannelStep(
                channel: "黄色",
                headline: "第二步：再调「黄色」通道",
                path: selective("黄色") + selectiveTail + "。",
                moves: [
                    SliderMove(text: "蓝色 +\(yellowBlue)", why: "蓝压黄，把橙色里的黄一路收掉（可选颜色里为黄色 −\(yellowBlue)）"),
                    SliderMove(text: "青色 +\(yellowCyan)", why: "青与黄互补，叠加后橙味明显减弱")
                ],
                reason: "红黄两边同时收，橙色才会退回接近肤色的红润感。"
            ),
            ChannelStep(
                channel: "整体明度",
                headline: "第三步：整体提亮",
                path: "\(lightenPath)；或在「可选颜色」里选「中性灰」通道，把「黑色」滑块拖到负值（黑色 −N 即提亮）。",
                moves: [
                    SliderMove(text: "亮度 +\(lighten)", why: "亮度或曲线整体上抬，肤色才透；在可选颜色里就是黑色 −\(lighten)")
                ],
                reason: "只压彩度不提亮，皮肤会显得暗沉，橙味反而更明显。"
            )
        ]

        return Analysis(
            source: c,
            bias: .tooOrange,
            diagnosis: "色相 H \(hsb.hueText) 位于橙（红—黄之间），饱和 S \(hsb.saturationText)，暖度 R−B = \(pct(c.warmth)) → 判定为「偏橙」。",
            metrics: metrics(hsb, c, extra: [("暖度", pct(c.warmth), "R − B，越大越偏橙黄")]),
            steps: steps,
            theory: [
                "橙色在色相环上位于红与黄之间，只处理红，橙色里的黄还会留着。",
                "两条通道都用同样的思路：加青、加蓝，把红黄两路一起往冷方向收。",
                "顺序影响不大，先红后黄更好控制；最后统一提亮。"
            ],
            target: target(for: c, severity: sev),
            severity: sev
        )
    }

    private static func dullAnalysis(_ c: RGBColor, _ hsb: HSBColor, _ sev: Double) -> Analysis {
        let r = amount(5 + 13 * sev)
        let g = amount(4 + 11 * sev)
        let b = amount(3 + 9 * sev)
        let lighten = lightenAmount(hsb.brightness, target: 0.78, floor: 4)

        let steps = [
            ChannelStep(
                channel: "中性灰",
                headline: "第一步：在「中性灰」通道补齐三原色",
                path: selective("中性灰") + selectiveTail + "。" + cmyNote,
                moves: [
                    SliderMove(text: "红色 +\(r)", why: "补回缺失的红，同时保留血色，红给得最多"),
                    SliderMove(text: "绿色 +\(g)", why: "绿与红是原色对，红绿相加趋白、趋干净"),
                    SliderMove(text: "蓝色 +\(b)", why: "蓝补足三原色，配比控制在最少，避免发紫")
                ],
                reason: "配比参考 红 : 绿 : 蓝 ≈ 1 : 0.85 : 0.67。三个原色同时加，灰色才会由「脏」变「白净」。"
            ),
            ChannelStep(
                channel: "中性灰 + 明度",
                headline: "第二步：把灰色提亮",
                path: "在「可选颜色」里选「中性灰」通道，把「黑色」滑块往负方向拖（黑色 −N 即提亮）；也可\(lightenPath)。",
                moves: [
                    SliderMove(text: "明度 +\(lighten)", why: "在可选颜色里即黑色 −\(lighten)；只加亮不加色会更灰，先加色再加亮才对")
                ],
                reason: "补完彩度再提亮，脏感才真正消失。"
            ),
            ChannelStep(
                channel: "复查（可选）",
                headline: "第三步：仍偏脏时再走一轮",
                path: "同上，把「可选颜色」顶部通道换成「白色」再做一轮；整幅偏脏时也可以先用「色阶」（⌘L）把「输出色阶」的黑场右滑复核。" + cmyNote,
                moves: [
                    SliderMove(text: "红 / 绿 / 蓝 各 +3 ~ +5", why: "红绿原色相加会变白变干净，配比保持近似 1:1:1 微调")
                ],
                reason: "若画面整体脏，可对「白色」通道也做同样处理，先把灰提亮再加原色。"
            )
        ]

        return Analysis(
            source: c,
            bias: .tooDull,
            diagnosis: "饱和 S \(hsb.saturationText)、明度 B \(hsb.brightnessText)，彩度不足导致发灰 → 判定为「偏灰偏脏」。",
            metrics: metrics(hsb, c, extra: []),
            steps: steps,
            theory: [
                "如果怎么加色都还是脏，问题就不在色相，而在「灰」本身彩度不够。",
                "红、绿、蓝三原色按比例同加会趋向白与中性，颜色自然变干净（红绿相加尤其明显）。",
                "配比要偏红一点，肤色才不会发死；加完色再提亮，脏感才消失。"
            ],
            target: target(for: c, severity: sev),
            severity: sev
        )
    }

    private static func coolAnalysis(_ c: RGBColor, _ hsb: HSBColor, _ sev: Double) -> Analysis {
        let magenta = amount(4 + 12 * sev)
        let yellow = amount(3 + 10 * sev)
        let lighten = lightenAmount(hsb.brightness, target: 0.76)

        let steps = [
            ChannelStep(
                channel: "中性灰",
                headline: "第一步：给灰加暖（红 + 黄）",
                path: selective("中性灰") + selectiveTail + "；「洋红」即加红减绿、「黄色」即减蓝。",
                moves: [
                    SliderMove(text: "洋红 +\(magenta)", why: "洋红即加红减绿，把偏绿偏青的冷味拉回来"),
                    SliderMove(text: "黄色 +\(yellow)", why: "加黄即减蓝，抵消皮肤里的冷蓝成分")
                ],
                reason: "偏黄 / 偏绿 / 偏青都属于「冷」，反向操作就是加红加暖。"
            ),
            ChannelStep(
                channel: "青色 / 绿色（按需）",
                headline: "第二步：直接压掉青绿",
                path: "先判断画面是青味重还是绿味重，再回「可选颜色」顶部把通道从「中性灰」换成「青色」或「绿色」，只压其中一个。",
                moves: [
                    SliderMove(text: "青色 −\(amount(4 + 9 * sev))", why: "若画面明显发青，直接在青色通道减青"),
                    SliderMove(text: "绿色 −\(amount(3 + 8 * sev))", why: "若画面明显发绿，在绿色通道减绿")
                ],
                reason: "先看是青味重还是绿味重，只压其中一个即可，不必都动。"
            ),
            ChannelStep(
                channel: "整体明度",
                headline: "第三步：轻微提亮",
                path: "\(lightenPath)；或用「亮度/对比度」调整图层，把「亮度」往右拖一点点（幅度要小，避免高光溢出）。",
                moves: [
                    SliderMove(text: "亮度 +\(lighten)", why: "冷色容易显脏，提亮后更接近健康肤色")
                ],
                reason: "提亮幅度要小，避免高光溢出丢细节。"
            )
        ]

        return Analysis(
            source: c,
            bias: .tooCool,
            diagnosis: "色相 H \(hsb.hueText) 偏向黄 / 绿 / 青一侧，暖度 R−B = \(pct(c.warmth)) → 判定为「偏黄偏冷」。",
            metrics: metrics(hsb, c, extra: [("暖度", pct(c.warmth), "R − B，越小越冷")]),
            steps: steps,
            theory: [
                "偏黄、偏绿、偏青都属于冷方向，处理思路与偏红相反：加红加暖、压青压蓝。",
                "压冷色时优先从「中性灰」通道入手，影响面大且过渡自然。",
                "最后轻微提亮，避免冷色带来的脏感。"
            ],
            target: target(for: c, severity: sev),
            severity: sev
        )
    }

    private static func balancedAnalysis(_ c: RGBColor, _ hsb: HSBColor, _ sev: Double) -> Analysis {
        let lighten = lightenAmount(hsb.brightness, target: 0.78, floor: 2)
        let steps = [
            ChannelStep(
                channel: "微调",
                headline: "肤色已在健康区间，只做微调",
                path: selective("红色") + "，只把「青色」滑块拖 +2 ~ +4；提亮用\(lightenPath)。",
                moves: [
                    SliderMove(text: "明度 +\(lighten)", why: "轻微提亮，让肤色更干净"),
                    SliderMove(text: "红色 青色 +2 ~ +4", why: "想更干净时，用青稍微压一点红，量一定要小")
                ],
                reason: "此时不要大幅度调整，任何大动作都会破坏已经正确的肤色。"
            )
        ]
        return Analysis(
            source: c,
            bias: .balanced,
            diagnosis: "色相 H \(hsb.hueText)、饱和 S \(hsb.saturationText)、明度 B \(hsb.brightnessText)"
                + " 都落在健康肤色区间内（H 15°–45°、S 25%–62%、B 60%–85%）→ 判定为「较为均衡」。",
            metrics: metrics(hsb, c, extra: []),
            steps: steps,
            theory: [
                "健康肤色大致落在色相 15°–45°、饱和 25%–62%、明度 60%–85% 的范围内。",
                "已经落在区间里时，调整幅度宁小勿大，保持自然过渡最重要。"
            ],
            target: target(for: c, severity: sev),
            severity: sev
        )
    }

    // MARK: - 手动指定时的处理

    /// 手动把「非肤色」的颜色指定为肤色：极端环境下还原肤色。
    /// 思路：先洗掉环境染上的颜色（减主色 = 加补色），再把明度、彩度拉回肤色区间。
    private static func restoreAnalysis(_ c: RGBColor, _ auto: SkinClassification) -> Analysis {
        let hsb = c.hsb
        let sev = clamp(1 - skinScore(hsb, c))            // 偏离肤色区越远，力度越大
        let cast = degreyingAdvice(for: c)                 // 主色家族就是环境染上的颜色
        let washBase = 8 + 14 * sev

        let washMoves = zip(cast.primaryPair, cast.complementPair).enumerated().map { index, pair -> SliderMove in
            // 双路时主色给得多、次色给得少
            let weight = cast.primaryPair.count == 1 ? 1.0 : (index == 0 ? 0.85 : 0.6)
            let value = amount(washBase * weight)
            return SliderMove(
                text: "\(shade(pair.0)) −\(value)",
                why: "环境光把肤色整体染成了\(shade(pair.0))。在「中性灰」通道减\(shade(pair.0))"
                    + "（等同加\(pair.1)），把这层环境色洗掉，肤色才会回来")
        }

        var steps: [ChannelStep] = [
            ChannelStep(
                channel: "中性灰 / 白色",
                headline: "第一步：洗掉环境染上的颜色",
                path: selective("中性灰") + "（整张画面都被染上同一层色时改选「白色」），再把与主色对应的补色滑块往正方向拖。" + cmyNote,
                moves: washMoves,
                reason: "有色光源、混合光、强滤镜会给整张画面加一层颜色，男女老少全被染成同一个色相："
                    + "先减掉这个颜色，后面的明度与彩度调整才有意义。"
            ),
            restoreBrightnessStep(hsb, sev)
        ]

        if hsb.saturation < 0.25 {
            let r = amount(5 + 13 * sev), g = amount(4 + 11 * sev), b = amount(3 + 9 * sev)
            steps.append(ChannelStep(
                channel: "中性灰",
                headline: "第三步：补回彩度（红 / 绿 / 蓝）",
                path: selective("中性灰") + selectiveTail + "。" + cmyNote,
                moves: [
                    SliderMove(text: "红色 +\(r)", why: "补回血色，红给得最多"),
                    SliderMove(text: "绿色 +\(g)", why: "红绿相加趋白，灰败感才会消失"),
                    SliderMove(text: "蓝色 +\(b)", why: "蓝补足三原色，配比最少，避免发紫")
                ],
                reason: "配比参考 红 : 绿 : 蓝 ≈ 1 : 0.85 : 0.67；环境把彩度压掉后，肤色要靠三原色补回来。"
            ))
        } else if hsb.saturation > 0.62 {
            let complement = shade(cast.complementPair.first ?? "青")
            steps.append(ChannelStep(
                channel: "中性灰",
                headline: "第三步：压掉过浓的彩度",
                path: selective("中性灰") + "，把补色对应的滑块往正方向拖（加补色＝压彩度）：加青 / 洋红 / 黄直接用同名滑块，补色是红用「青色」、绿用「洋红」、蓝用「黄色」。",
                moves: [SliderMove(text: "\(complement) +\(amount(5 + 10 * sev))",
                                   why: "补充一点互补色，颜色会往中性靠，彩度自然降下来")],
                reason: "环境彩光容易把肤色染得过浓，加它的补色让它退回肤色的灰调程度。"
            ))
        }

        return Analysis(
            source: c,
            bias: .extreme,
            diagnosis: "手动指定为「肤色」，但色相 H \(hsb.hueText)（\(auto.family)）、饱和 S \(hsb.saturationText)、"
                + "明度 B \(hsb.brightnessText) 已经偏离健康肤色区间 → 按「极端环境下的肤色还原」处理，"
                + "肤色匹配度 \(pct(skinScore(hsb, c)))。",
            metrics: metrics(hsb, c, extra: [
                ("肤色匹配度", pct(skinScore(hsb, c)), "四项加权综合分，越高越接近肤色"),
                ("主色偏色", cast.familyName, "环境光把肤色染成的主色，洗掉它是还原的第一步"),
                ("色相偏差", "ΔH \(String(format: "%.0f", hueDelta(hsb.hue)))°", "与肤色中心 27° 的角差")
            ]),
            steps: steps,
            theory: [
                "极端环境（有色光源、混合光、强滤镜）会把肤色整体染上一种颜色，这时自动判定往往认不出肤色，需要手动指定。",
                "第一步永远是去环境色：色相环上离它最近的家族色就是被染上的颜色，减掉它（等同加它的补色），肤色才会回来。",
                "第二步处理明度、第三步处理彩度：明度回到 30%–85%、彩度回到 25%–62%，肤色才自然。",
                "画面里如果有已知的中性灰物体或灰卡，先做白平衡再微调肤色，效果最稳。"
            ],
            target: target(for: c, severity: sev),
            severity: sev
        )
    }

    /// 明度归位：过亮压暗、过暗提亮、已在区间内则轻微提亮
    private static func restoreBrightnessStep(_ hsb: HSBColor, _ sev: Double) -> ChannelStep {
        if hsb.brightness > 0.88 {
            return ChannelStep(
                channel: "整体明度",
                headline: "第二步：压低过亮的明度",
                path: "在「可选颜色」里选「中性灰」通道，把「黑色」滑块往正方向拖（黑色 +N 即压暗）；也可\(darkenPath)。",
                moves: [SliderMove(text: "明度 −\(amount(4 + 8 * sev))",
                                   why: "环境过曝把肤色冲得太亮，先压回 30%–85% 的肤色明度区间")],
                reason: "明度不在区间内时先归位再细调颜色，否则很容易越调越脏。")
        }
        let lighten = lightenAmount(hsb.brightness, target: 0.74)
        return ChannelStep(
            channel: "整体明度",
            headline: hsb.brightness < 0.40 ? "第二步：把明度拉回肤色区间" : "第二步：轻微提亮",
            path: "在「可选颜色」里选「中性灰」通道，把「黑色」滑块往负方向拖（黑色 −N 即提亮）；也可\(lightenPath)。",
            moves: [SliderMove(text: "明度 +\(lighten)", why: "肤色要透亮；在「可选颜色」里即黑色 −\(lighten)")],
            reason: "明度不在区间内时先归位再细调颜色，否则很容易越调越脏。")
    }

    /// 手动把「肤色」的颜色指定为非肤色：肤色类结论都不适用，只保留颜色本身的处理
    private static func nonSkinAnalysis(_ c: RGBColor, _ auto: SkinClassification) -> Analysis {
        let hsb = c.hsb
        return Analysis(
            source: c,
            bias: classify(hsb, c),
            diagnosis: "手动指定为「非肤色」（自动判定为「肤色 · \(auto.family)」）→ 不按肤色处理，"
                + "偏红 / 偏橙 / 偏黄偏冷这些结论都不适用。",
            metrics: metrics(hsb, c, extra: []),
            steps: [],
            theory: [
                "该点已被手动标记为非肤色，肤色类调整（加青压红、加暖、补原色）都不适用。",
                "只针对颜色本身：用「去灰建议」把混进来的补色减掉，它就会变干净。"
            ],
            target: c,
            severity: 0
        )
    }

    /// 色相与肤色中心 27° 的最短角差
    private static func hueDelta(_ hue: Double) -> Double {
        let raw = abs(hue - idealSkin.hue)
        return min(raw, 360 - raw)
    }

    // MARK: - 工具

    /// 目标肤色：向理想肤色中点收敛，偏离越大收敛越多
    private static func target(for c: RGBColor, severity: Double) -> RGBColor {
        let t = 0.28 + 0.42 * clamp(severity)
        return c.mixed(with: idealSkin.rgb, t)
    }

    private static func metrics(_ hsb: HSBColor, _ c: RGBColor,
                                extra: [(String, String, String)]) -> [ColorMetric] {
        var list: [(String, String, String)] = [
            ("色相 H", hsb.hueText, "在色相环上的角度，红 0° / 黄 60° / 青 180° / 蓝 240°"),
            ("饱和度 S", hsb.saturationText, "越低越灰、越脏"),
            ("明度 B", hsb.brightnessText, "越高越亮，过高会丢细节"),
            ("灰化程度", pct(grayness(hsb)), "混入补色的比例，越大越脏，决定去灰建议的力度")
        ]
        list.append(contentsOf: extra)
        return list.map { ColorMetric(name: $0.0, value: $0.1, hint: $0.2) }
    }

    // MARK: - 去灰建议（减补色 = 加主色）

    /// 六个基准色及其互补色；相邻两者之间就是十二色相环的中间色
    private static let basics: [(angle: Double, name: String, complement: String)] = [
        (0, "红", "青"),
        (60, "黄", "蓝"),
        (120, "绿", "洋红"),
        (180, "青", "红"),
        (240, "蓝", "黄"),
        (300, "洋红", "绿")
    ]

    private static let intermediateNames: [String: String] = [
        "红黄": "橙", "黄绿": "黄绿", "绿青": "青绿",
        "青蓝": "青蓝", "蓝洋红": "蓝紫", "洋红红": "紫红"
    ]

    /// 灰化程度：饱和度不足、以及偏暗，都意味着混进了更多补色（灰）
    static func grayness(_ hsb: HSBColor) -> Double {
        let neutral = 1 - hsb.saturation
        let darkness = max(0, 0.35 - hsb.brightness) * 0.6
        return clamp(neutral + darkness)
    }

    static func degreyingAdvice(for color: RGBColor) -> DegreyingAdvice {
        let hsb = color.hsb
        let h = hsb.hue

        // 定位色相落在哪两个基准色之间
        var lowerIndex = 0
        for (index, basic) in basics.enumerated() where basic.angle <= h { lowerIndex = index }
        let lower = basics[lowerIndex]
        let upper = basics[(lowerIndex + 1) % basics.count]
        let span = ((upper.angle - lower.angle) + 360).truncatingRemainder(dividingBy: 360)
        let upperWeight = span > 0 ? ((h - lower.angle) + 360).truncatingRemainder(dividingBy: 360) / span : 0
        let lowerWeight = 1 - upperWeight

        // 权重达到 1/4（距基准色 15°）才单独成路，正好对应十二色相环的 30° 分区
        var picks: [(basic: (angle: Double, name: String, complement: String), weight: Double)] = []
        if lowerWeight >= 0.25 { picks.append((lower, lowerWeight)) }
        if upperWeight >= 0.25 { picks.append((upper, upperWeight)) }

        let g = grayness(hsb)
        let base = 4 + 15 * g
        let primaries = picks.map { $0.basic.name }
        let complements = picks.map { $0.basic.complement }

        let familyName: String
        let familyDetail: String
        if primaries.count == 1 {
            familyName = primaries[0]
            familyDetail = "\(primaries[0])（色相 \(Int(picks[0].basic.angle))°）"
        } else {
            familyName = intermediateNames[primaries.joined()] ?? "\(primaries[0])—\(primaries[1])"
            familyDetail = "\(familyName)（\(primaries[0]) \(Int(picks[0].basic.angle))° 与 "
                + "\(primaries[1]) \(Int(picks[1].basic.angle))° 之间）"
        }

        let moves: [SliderMove] = picks.map { pick in
            let amount = Int(max(3, (primaries.count == 1 ? base : base * pick.weight)).rounded())
            let complement = shade(pick.basic.complement)
            let primary = shade(pick.basic.name)
            return SliderMove(
                text: "\(complement) −\(amount)",
                why: "\(complement)是\(primary)的补色。把混进来的\(complement)降掉"
                    + "（图层上就降低补色层的不透明度），\(primary)自然干净了；也可理解为"
                    + " \(primary) +\(amount)"
            )
        }

        let level: String
        if g < 0.20 {
            level = "当前颜色已经比较干净，去灰只需很小的力度。"
        } else if g < 0.50 {
            level = "当前颜色带一定灰感，按上面的力度去掉补色即可。"
        } else {
            level = "当前颜色灰化明显、补色混入较多，需要较大力度去补色。"
        }

        return DegreyingAdvice(
            familyName: familyName,
            familyDetail: familyDetail,
            primaryPair: primaries,
            complementPair: complements,
            grayness: g,
            path: selective("中性灰") + "（整幅画面偏色时改选「白色」），再把下面各条里的补色换算成底部滑块："
                + "青 / 洋红 / 黄 直接用同名滑块拖负值，红 ⇒「青色」拖正值、绿 ⇒「洋红」拖正值、蓝 ⇒「黄色」拖正值。",
            moves: moves,
            summary: "互补色以 50% 相混就会变成灰，所以颜色发灰就是补色混进来的证据："
                + "减补色与加主色是同一件事，把补色降掉，主色就回到干净状态。\(level)",
            examples: [
                "举例：减去黄色，蓝天会更蓝；减去绿色，花会变品红；减去品红，草地会更绿。",
                "中间色怎么调：橙色不在六色里，所以加红加黄（等于减青减蓝）；要调青蓝，则加青加蓝（等于减红减黄）。"
            ]
        )
    }

    /// 颜色名 + 「色」，洋红保持原样
    private static func shade(_ name: String) -> String { name == "洋红" ? name : name + "色" }

    private static func lightenAmount(_ brightness: Double, target: Double, floor: Double = 2) -> Int {
        guard brightness < target else { return Int(floor) }
        return Int(min(max((target - brightness) * 55 + floor, floor), 14).rounded())
    }

    private static func amount(_ v: Double) -> Int { Int(max(1, v.rounded())) }

    private static func pct(_ v: Double) -> String { String(format: "%.0f%%", v * 100) }

    private static func clamp(_ v: Double, _ lo: Double = 0, _ hi: Double = 1) -> Double {
        min(max(v, lo), hi)
    }
}
