import Foundation

/// 命令行模式：`SkinTone --analyze "#C0504D"`，用于在终端直接查看调色建议
/// （也方便在没有界面的环境下核对引擎结论）
enum CLIRunner {

    static func runIfNeeded() {
        let args = CommandLine.arguments

        if args.contains("--help") || args.contains("-h") {
            printUsage()
            exit(0)
        }

        // 照片仿色：SkinTone --match <参考图> <待仿色图>
        if let matchIndex = args.firstIndex(where: { $0 == "--match" || $0 == "-m" }) {
            guard matchIndex + 2 < args.count else {
                FileHandle.standardError.write("用法：SkinTone --match <参考图> <待仿色图>\n".data(using: .utf8)!)
                exit(1)
            }
            runMatch(reference: args[matchIndex + 1], target: args[matchIndex + 2])
        }

        guard let index = args.firstIndex(where: { $0 == "--analyze" || $0 == "-a" }),
              index + 1 < args.count else {
            return
        }

        let raw = args[index + 1]
        guard let rgb = RGBColor(hex: raw) else {
            FileHandle.standardError.write("无法解析颜色「\(raw)」，请使用 #RRGGBB 或 RRGGBB 格式\n".data(using: .utf8)!)
            exit(1)
        }

        // 可选第三个参数：手动指定分类（极端环境还原用）
        var assumed: SkinKind?
        if index + 2 < args.count {
            switch args[index + 2].lowercased() {
            case "skin", "肤色":            assumed = .skin
            case "non-skin", "nonskin", "非肤色": assumed = .nonSkin
            case "auto", "自动":            assumed = nil
            default:                        assumed = nil
            }
        }

        let a = ColorEngine.analyze(rgb, assumed: assumed)
        let hsb = a.sourceHSB
        let isSkin = a.classification.isSkin

        print("取色        \(a.source.hexString)")
        print("RGB         \(a.source.rgb255String)")
        print("HSB         H \(hsb.hueText)  S \(hsb.saturationText)  B \(hsb.brightnessText)")
        print("分类        \(a.classification.label)")
        print("            \(a.classification.reason)")
        print("判定        \(isSkin ? a.bias.rawValue : "不适用（非肤色）")  （偏离度 \(String(format: "%.2f", a.severity))）")
        print("")
        print(a.diagnosis)
        if !isSkin {
            print("")
            print("该点是非肤色：下面的肤色步骤只作参考；若想让这个颜色本身更干净，看「去灰建议」。")
        }
        print("")
        for (i, step) in a.steps.enumerated() {
            print("第 \(i + 1) 步 · 通道「\(step.channel)」  \(step.headline)")
            print("    操作：\(step.path)")
            for move in step.moves {
                print("    · \(move.text)    — \(move.why)")
            }
            print("    说明：\(step.reason)")
            print("")
        }
        let d = a.degreying
        print("去灰建议（减补色 = 加主色）")
        print("    主色 \(d.primaryPair.joined(separator: " + "))  ←→  补色 \(d.complementPair.joined(separator: " + "))")
        print("    \(d.familyDetail)    灰化程度 \(d.graynessText)")
        print("    操作：\(d.path)")
        for move in d.moves {
            print("    · \(move.text)    — \(move.why)")
        }
        print("    \(d.summary)")
        for line in d.examples { print("    \(line)") }
        print("")
        print(isSkin ? "目标肤色    \(a.target.hexString)" : "目标肤色    不适用（非肤色）")
        print("")
        print("原理要点")
        for t in a.theory { print("  · \(t)") }
        print("")
        print("参考区间    色相 \(Int(ColorEngine.healthyHueRange.lowerBound))°–\(Int(ColorEngine.healthyHueRange.upperBound))°  "
              + "饱和 \(Int(ColorEngine.healthySatRange.lowerBound * 100))%–\(Int(ColorEngine.healthySatRange.upperBound * 100))%  "
              + "明度 60%–85%")
        exit(0)
    }

    /// 照片仿色：比对两张图的整图统计，输出 Photoshop 操作建议
    private static func runMatch(reference: String, target: String) {
        guard let ref = loadStats(reference) else {
            FileHandle.standardError.write("读不出参考图「\(reference)」，请确认路径与格式\n".data(using: .utf8)!)
            exit(1)
        }
        guard let tgt = loadStats(target) else {
            FileHandle.standardError.write("读不出待仿色图「\(target)」，请确认路径与格式\n".data(using: .utf8)!)
            exit(1)
        }
        print(MatchPlanner.report(MatchPlanner.plan(reference: ref, target: tgt)))
        exit(0)
    }

    private static func loadStats(_ path: String) -> PhotoStats? {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let result = PhotoAnalyzer.load(url: url), result.stats.pixelCount > 0 else { return nil }
        return result.stats
    }

    private static func printUsage() {
        print("""
        肤色助手 v1.1 — 屏幕取色 / 照片仿色建议

        用法：
          SkinTone                     启动图形界面（全局快捷键 ⌃⌥C 取色）
          SkinTone --analyze #C0504D   命令行分析指定颜色并输出调色建议
          SkinTone --analyze #8FA9C4 肤色
                                       手动指定为肤色（极端环境肤色还原）
          SkinTone --analyze #C0504D 非肤色
                                       手动指定为非肤色（只看颜色本身）
          SkinTone --match 参考图 待调图
                                       照片仿色：比对两张图并输出 Photoshop 仿色建议
          SkinTone --help              显示本帮助

        图形界面左侧有可隐藏的侧边栏，在其中切换「肤色取色 / 照片仿色」；
        侧边栏收起后，用窗口左上角的侧边栏按钮可以重新展开。
        """)
    }
}
