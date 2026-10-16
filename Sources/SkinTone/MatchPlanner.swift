import Foundation

/// 一条 Photoshop 里的具体操作建议
struct MatchMove: Hashable {
    /// 用哪个工具 / 面板，如「色阶 ⌘L · 输出」
    let tool: String
    /// 在 Photoshop 里的操作路径：菜单怎么进、面板里动哪个控件
    let path: String
    /// 具体操作，如「输出黑场 0 → 22」
    let text: String
    /// 为什么这么调
    let why: String
}

/// 五区影调对比
struct ZoneCompare: Hashable {
    let name: String
    let range: String
    let refShare: Double
    let targetShare: Double
    /// 待调图占比 − 参考图占比，正数表示待调图偏多、需要削减
    var delta: Double { targetShare - refShare }
}

/// 单个色相带的色相 / 饱和对比
struct BandCompare: Hashable {
    let name: String
    let refShare: Double
    let targetShare: Double
    let refHue: Double        // -1 表示该带在图中没有像素
    let targetHue: Double
    let refSat: Double
    let targetSat: Double
    /// 要把待调图的色相转到参考图，需要转动的角度（带符号，取最短路径）
    var deltaHue: Double {
        guard refHue >= 0, targetHue >= 0 else { return 0 }
        var d = (refHue - targetHue).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        return d
    }
    var deltaSat: Double { refSat - targetSat }
    var isComparable: Bool { refHue >= 0 && targetHue >= 0 }
}

/// 一份完整的仿色方案：先影调、后色调
struct MatchPlan: Hashable {
    let reference: PhotoStats
    let target: PhotoStats
    let headline: String
    let orderNote: String
    let toneZones: [ZoneCompare]
    let toneMoves: [MatchMove]
    let toneSummary: String
    let colorBands: [BandCompare]
    let colorMoves: [MatchMove]
    let colorSummary: String
    let theory: [String]
}

/// 仿色比对引擎：把参考图与待调图的整图统计对齐，输出 Photoshop 操作建议。
enum MatchPlanner {

    /// 色相差异超过这个角度才值得动色相滑块
    private static let hueThreshold = 8.0
    /// 饱和度差异超过这个比例才值得动饱和度滑块
    private static let satThreshold = 0.06
    /// 黑白端点差异超过这个灰度值才需要动色阶
    private static let pointThreshold = 6

    /// 影调这一步的执行方式：用调整图层
    private static let toneLayerNote = "影调要落在「调整图层」上：图层面板底部第 4 个图标 › 色阶 / 曲线，"
        + "不要直接用「图像 › 调整」里的即时命令——调整图层不破坏原图、数值随时能回改。"
    /// 色调这一步的执行方式：调整图层叠在影调之上
    private static let colorLayerNote = "色调的调整图层要叠在影调图层之上；图层在面板里的堆叠顺序就是执行顺序，从上往下读一遍就是一整套流程。"
        + "色相/饱和度也用调整图层做，比对完才能把临时拉满的饱和度改回 0。"

    static func plan(reference ref: PhotoStats, target tgt: PhotoStats) -> MatchPlan {

        // MARK: 第一步 · 影调

        let toneZones = (0..<5).map { index in
            ZoneCompare(name: PhotoStats.zoneNames[index],
                        range: PhotoStats.zoneRanges[index],
                        refShare: ref.zones[index],
                        targetShare: tgt.zones[index])
        }

        // 输出黑场抬起 = 削减最暗部；输出白场压低 = 削减最亮度
        // 只在待调图的两端确实比参考图更极端时才动，否则保持 0 / 255
        let raiseBlack = tgt.blackPoint < ref.blackPoint - pointThreshold
        let lowerWhite = tgt.whitePoint > ref.whitePoint + pointThreshold
        let blackOut = raiseBlack ? clampInt(ref.blackPoint, 0, 96) : 0
        let whiteOut = lowerWhite ? clampInt(ref.whitePoint, 170, 255) : 255

        // 抬黑压白之后，待调图的中间调会落到 compressed 这个位置
        let span = Double(whiteOut - blackOut)
        let compressed = Double(blackOut) + Double(tgt.medianPoint) * span / 255
        let gap = clampInt(ref.medianPoint - Int(compressed.rounded()), -48, 48)

        var toneMoves: [MatchMove] = []

        if raiseBlack {
            toneMoves.append(MatchMove(
                tool: "色阶 ⌘L · 输出",
                path: "菜单「图像 › 调整 › 色阶」（⌘L）→ 面板里找右下角那排「输出色阶」→ 按住它左边那个滑块向右拖（拖动时可看到画面最暗部被抬起来发灰）",
                text: "输出黑场 0 → \(blackOut)",
                why: "待调图最暗部到 \(tgt.blackPoint)/255、占 \(pct(tgt.zones[0]))，"
                    + "参考图根本没有这一档（最暗只到 \(ref.blackPoint)/255、\(pct(ref.zones[0]))）。"
                    + "抬起输出黑场就是把最暗部抽掉，画面立刻变柔和。"))
        } else if tgt.blackPoint > ref.blackPoint + pointThreshold {
            toneMoves.append(MatchMove(
                tool: "色阶 ⌘L · 输入",
                path: "菜单「图像 › 调整 › 色阶」（⌘L）→ 用面板上方那排「输入色阶」→ 按住它左边那个滑块向右拖（按住 Option 拖动可实时看黑场裁切）",
                text: "输入黑场 0 → \(clampInt(ref.blackPoint, 0, 120))",
                why: "参考图最暗部到 \(ref.blackPoint)/255、占 \(pct(ref.zones[0]))，"
                    + "而待调图最暗只到 \(tgt.blackPoint)/255、\(pct(tgt.zones[0]))，缺少最深的那一档，"
                    + "把输入黑场往右拖可以补回最暗部。"))
        }
        if lowerWhite {
            toneMoves.append(MatchMove(
                tool: "色阶 ⌘L · 输出",
                path: "菜单「图像 › 调整 › 色阶」（⌘L）→ 面板右下角「输出色阶」右边那个滑块 → 按住它向左拖（画面最亮部会被压下来）",
                text: "输出白场 255 → \(whiteOut)",
                why: "待调图最亮部到 \(tgt.whitePoint)/255、占 \(pct(tgt.zones[4]))，参考图是 "
                    + "\(ref.whitePoint)/255、\(pct(ref.zones[4]))。压低输出白场削减最亮部，避免死白。"))
        } else if tgt.whitePoint < ref.whitePoint - pointThreshold {
            toneMoves.append(MatchMove(
                tool: "色阶 ⌘L · 输入",
                path: "菜单「图像 › 调整 › 色阶」（⌘L）→ 面板上方「输入色阶」右边那个滑块 → 按住它向左拖（画面最亮部会被提亮）",
                text: "输入白场 255 → \(clampInt(ref.whitePoint, 130, 255))",
                why: "参考图最亮部到 \(ref.whitePoint)/255、占 \(pct(ref.zones[4]))，"
                    + "而待调图最亮只到 \(tgt.whitePoint)/255，把输入白场往左拖可以提亮最亮部。"))
        }
        if abs(gap) >= 3 {
            let word = gap < 0 ? "压暗" : "提亮"
            toneMoves.append(MatchMove(
                tool: "曲线 ⌘M · RGB",
                path: "菜单「图像 › 调整 › 曲线」（⌘M）→ 曲线框里在横坐标「输入 128」的位置单击一次打上锚点 → 按住这个锚点上下拖；要限死 128 这个输入值，可在下方「输入」框里直接键入 128",
                text: "输入 128 → 输出 \(128 + gap)",
                why: "黑场和白场都往中间收之后画面容易发灰，把中间调\(word) \(abs(gap)) 个灰度，"
                    + "对应参考图中位 \(ref.medianPoint) 而压缩后落在 \(Int(compressed.rounded()))。"))
        }
        if tgt.contrastText != ref.contrastText {
            let diff = (ref.stdL - tgt.stdL) * 255
            if abs(diff) >= 6 {
                toneMoves.append(MatchMove(
                    tool: "曲线 ⌘M · RGB",
                    path: "菜单「图像 › 调整 › 曲线」（⌘M）→ 在曲线横坐标约 1/4（输入 64）与 3/4（输入 192）处各单击一次打上锚点 → 把暗部那个锚点往下拉、亮部那个往上推，形成小幅 S 形（不要拉太大，容易断阶）",
                    text: diff > 0 ? "整体对比再提一点（S 形小幅）" : "整体对比再收一点（反向 S 形小幅）",
                    why: "待调图明度标准差 \(tgt.contrastText)，参考图 \(ref.contrastText)；"
                        + (diff > 0 ? "参考图反差更大。" : "参考图反差更小、更柔和。")))
            }
        }

        let toneSummary = toneMoves.isEmpty
            ? "影调两端与中间调都已经和参考图接近，这一步基本不用动。"
            : "先在「色阶」里抬起输出黑场、压低输出白场收掉两端的极端值，"
                + "再用「曲线」把中间调按上面给出的数值微调——这就是「先仿影调」。"
                + (ref.isSoftRange ? "参考图属于软调（缺少最暗部），仿完之后待调图也应如此。" : "")
                + toneLayerNote

        // MARK: 第二步 · 色调

        var colorBands: [BandCompare] = []
        for index in 0..<6 {
            colorBands.append(BandCompare(
                name: PhotoStats.bandNames[index],
                refShare: ref.bandShares[index],
                targetShare: tgt.bandShares[index],
                refHue: ref.bandHues[index],
                targetHue: tgt.bandHues[index],
                refSat: ref.bandSats[index],
                targetSat: tgt.bandSats[index]))
        }

        var colorMoves: [MatchMove] = []

        // 比对手法：先把饱和度拉满放大差异，调完再复位
        colorMoves.append(MatchMove(
            tool: "色相/饱和度 ⌘U",
            path: "菜单「图像 › 调整 › 色相/饱和度」（⌘U）→ 顶部下拉保持「全图」→ 拖最上面那条「饱和度」滑块到 +70 左右；这是比对用的临时状态，不是最终画面",
            text: "先把饱和度滑块临时拉满（+70 左右）放大色差，逐带调完再改回 0",
            why: "「颜色上通过眼睛不好观察」——拉满饱和度后，参考图和待调图的色差会变得很明显，"
                + "对着参考图哪里不同就调哪里；全部调好后把全图饱和度复位到 0。"))

        let hueDelta = circularDelta(from: tgt.mainHue, to: ref.mainHue)
        if tgt.mainHue >= 0 && ref.mainHue >= 0 && abs(hueDelta) >= hueThreshold {
            colorMoves.append(MatchMove(
                tool: "色相/饱和度 ⌘U · 全图",
                path: "菜单「图像 › 调整 › 色相/饱和度」（⌘U）→ 顶部下拉选「全图」→ 拖中间那条「色相」滑块（左右各到头是 ±180°）",
                text: "色相 \(signed(hueDelta))°",
                why: "待调图整体色相 \(hueText(tgt.mainHue))，参考图 \(hueText(ref.mainHue))；"
                    + "把全图色相往参考图方向转 \(abs(Int(hueDelta.rounded())))°。"))
        }

        // 逐色相带（对应「色相/饱和度」里可选的红 / 黄 / 绿 / 青 / 蓝 / 洋红）
        for band in colorBands where band.isComparable {
            var parts: [String] = []
            var reasons: [String] = []
            if abs(band.deltaHue) >= hueThreshold {
                parts.append("色相 \(signed(band.deltaHue))°")
                reasons.append("该带平均色相 \(hueText(band.targetHue))，参考图 \(hueText(band.refHue))")
            }
            if abs(band.deltaSat) >= satThreshold {
                parts.append("饱和度 \(signed(band.deltaSat * 100, unit: "%"))")
                reasons.append("该带平均饱和 \(pct(band.targetSat))，参考图 \(pct(band.refSat))")
            }
            guard !parts.isEmpty else { continue }
            colorMoves.append(MatchMove(
                tool: "色相/饱和度 ⌘U · 选「\(band.name)」",
                path: "菜单「色相/饱和度」（⌘U）→ 顶部下拉把「全图」改成「\(band.name)」（对应色相 \(PhotoStats.bandRanges[PhotoStats.bandNames.firstIndex(of: band.name) ?? 0])）→ 底部随即出现该色的色相条，先把两端四个滑块收拢到画面里对应颜色的位置，再拖上面「色相」「饱和度」两条滑块。找不到合适的范围时，改用十二色相环定位（如橙色 = 加红加黄）",
                text: parts.joined(separator: "，"),
                why: reasons.joined(separator: "；")
                    + "。该带占待调图彩色像素 \(pct(band.targetShare))，参考图 \(pct(band.refShare))。"))
        }

        // 冷暖兜底：色彩平衡
        let warmthGap = ref.warmth - tgt.warmth
        if abs(warmthGap) >= 0.03 {
            let amount = clampInt(Int((warmthGap * 100).rounded()), -40, 40)
            let toward = amount > 0 ? "暖（红 / 黄）" : "冷（青 / 蓝）"
            colorMoves.append(MatchMove(
                tool: "色彩平衡 ⌘B · 中间调",
                path: "菜单「图像 › 调整 › 色彩平衡」（⌘B）→ 面板下方「色调平衡」选「中间调」→ 勾上「保持明度」（否则一动颜色亮度会跟着变）→ 拖上面「青–红」「黄–蓝」两条滑块",
                text: "青–红 \(signed(Double(amount)))，黄–蓝 \(signed(Double(amount)))",
                why: "参考图整体红蓝差 \(String(format: "%.0f", ref.warmth * 255))，待调图 "
                    + "\(String(format: "%.0f", tgt.warmth * 255))，需要往\(toward)方向偏 \(abs(amount))。"))
        }

        let colorSummary: String
        if colorMoves.count <= 1 {
            colorSummary = "两图的色相分布已经很接近，色调这一步做完比对即可收工。"
        } else {
            colorSummary = "先在「色相/饱和度」里把饱和度拉满做比对，"
                + "按下面每一条逐带校正色相与饱和，对着参考图哪里不同调哪里；"
                + "感觉差不多之后把全图饱和度改回 0。"
                + (ref.mainHue >= 0 ? "参考图整体偏\(ColorEngine.hueFamily(ref.mainHue))。" : "")
                + colorLayerNote
        }

        let headline = "参考图 \(ref.toneBrief.replacingOccurrences(of: " · ", with: " / "))，"
            + "待调图 \(tgt.toneBrief.replacingOccurrences(of: " · ", with: " / "))"
            + "—— 先收两端极端值，再校色调。"

        let orderNote = "顺序很重要：先仿影调，再仿色调。影调决定画面柔和还是硬朗，色调只在这个基础上做微调；"
            + "顺序颠倒的话，影调一变色调又得重调。"
            + "在 Photoshop 里就体现为图层堆叠顺序：影调调整图层在下、色调调整图层在上。"

        let theory = [
            "仿色 = 仿影调关系 + 仿色调。影调是「哪里暗、哪里亮、两端有没有极端值」，色调是「颜色往哪偏」。",
            "参考图缺少最暗部信息（集中在亮部与灰部）时会显得柔和；待调图是全影调又有最暗部，所以要先减少最暗部。",
            "只削减两端容易发灰，所以中间调要跟着压一点；再削减过多的最亮部，画面就会「柔和但不发灰」。",
            "颜色光靠眼睛不好比对：把「色相/饱和度」的饱和度拉满，色差被放大，对着参考图哪里不同调哪里，最后把饱和度改回 0。",
            "色相/饱和度里的红 / 黄 / 绿 / 青 / 蓝 / 洋红六个范围，正好对应本文用的六个色相带（每 60°）。",
            "互补色以 50% 不透明度相混会变灰：局部颜色不干净时，减去它的补色等于加回它的主色，画面更干净。",
            "所有调整都走「调整图层」（图层面板底部第 4 个图标）而不是「图像 › 调整」的即时命令：原图不被破坏、数值随时可回改，图层堆叠顺序本身就是执行顺序。"
        ]

        return MatchPlan(
            reference: ref,
            target: tgt,
            headline: headline,
            orderNote: orderNote,
            toneZones: toneZones,
            toneMoves: toneMoves,
            toneSummary: toneSummary,
            colorBands: colorBands,
            colorMoves: colorMoves,
            colorSummary: colorSummary,
            theory: theory)
    }

    // MARK: - 输出

    /// 命令行文本报告
    static func report(_ plan: MatchPlan) -> String {
        var lines: [String] = []
        lines.append("参考图      \(plan.reference.name)")
        lines.append("            \(plan.reference.rangeBrief)")
        lines.append("            \(plan.reference.toneBrief)  ·  整体色相 \(plan.reference.mainHueText)")
        lines.append("待调图      \(plan.target.name)")
        lines.append("            \(plan.target.rangeBrief)")
        lines.append("            \(plan.target.toneBrief)  ·  整体色相 \(plan.target.mainHueText)")
        lines.append("")
        lines.append(plan.headline)
        lines.append(plan.orderNote)
        lines.append("")
        lines.append("五区影调对比（参考图 → 待调图）")
        for zone in plan.toneZones {
            let bar = zone.delta > 0.02 ? "待调图偏多" : (zone.delta < -0.02 ? "待调图偏少" : "接近")
            lines.append("    \(zone.name)（\(zone.range)）  \(pct(zone.refShare)) → \(pct(zone.targetShare))   \(bar)")
        }
        lines.append("")
        lines.append("第一步 · 仿影调")
        if plan.toneMoves.isEmpty {
            lines.append("    （影调已接近，无需调整）")
        } else {
            for (i, move) in plan.toneMoves.enumerated() {
                lines.append("    \(i + 1). [\(move.tool)] \(move.text)")
                lines.append("        操作：\(move.path)")
                lines.append("        理由：\(move.why)")
            }
        }
        lines.append("    \(plan.toneSummary)")
        lines.append("")
        lines.append("第二步 · 仿色调")
        lines.append("    色相带对比")
        for band in plan.colorBands {
            guard band.isComparable else {
                lines.append("        \(band.name)  参考图 \(pct(band.refShare)) / 待调图 \(pct(band.targetShare))（一侧无像素，不比对）")
                continue
            }
            lines.append("        \(band.name)  占比 \(pct(band.refShare)) → \(pct(band.targetShare))"
                + "   色相 \(hueText(band.targetHue)) → \(hueText(band.refHue))（差 \(signed(band.deltaHue))°）"
                + "   饱和 \(pct(band.targetSat)) → \(pct(band.refSat))")
        }
        for (i, move) in plan.colorMoves.enumerated() {
            lines.append("    \(i + 1). [\(move.tool)] \(move.text)")
            lines.append("        操作：\(move.path)")
            lines.append("        理由：\(move.why)")
        }
        lines.append("    \(plan.colorSummary)")
        lines.append("")
        lines.append("原理要点")
        for item in plan.theory { lines.append("  · \(item)") }
        return lines.joined(separator: "\n")
    }

    // MARK: - 小工具

    private static func pct(_ value: Double) -> String { String(format: "%.0f%%", value * 100) }

    private static func hueText(_ hue: Double) -> String {
        hue < 0 ? "无彩色" : String(format: "%.0f°（%@）", hue, ColorEngine.hueFamily(hue))
    }

    private static func signed(_ value: Double, unit: String = "") -> String {
        let rounded = Int(value.rounded())
        return "\(rounded >= 0 ? "+" : "")\(rounded)\(unit)"
    }

    private static func clampInt(_ value: Int, _ lower: Int, _ upper: Int) -> Int {
        min(max(value, lower), upper)
    }

    /// 从 from 转到 to 的最短角度差（带符号）
    private static func circularDelta(from: Double, to: Double) -> Double {
        guard from >= 0, to >= 0 else { return 0 }
        var d = (to - from).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        return d
    }
}
