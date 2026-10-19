import Foundation

/// 命令行模式：`SkinTone --analyze "#C0504D"`，用于在终端直接查看调色建议
/// （也方便在没有界面的环境下核对引擎结论）
enum CLIRunner {

    static func runIfNeeded() {
        let args = CommandLine.arguments

        // JPG 转 PSD：SkinTone --to-psd <与原来 JPG2PSD 相同的参数>
        // 放在最前面，这样 `--to-psd --help` 显示的是它自己的帮助
        if let psdIndex = args.firstIndex(of: "--to-psd") {
            exit(PSDCLIRunner.run(Array(args[(psdIndex + 1)...])))
        }

        // 隐藏用法（自检）：SkinTone --dump-planar <输出目录> <输入…>
        if let dumpIndex = args.firstIndex(of: "--dump-planar") {
            guard dumpIndex + 1 < args.count else {
                FileHandle.standardError.write(
                    "用法：SkinTone --dump-planar <输出目录> <输入…>\n".data(using: .utf8)!)
                exit(2)
            }
            exit(PSDCLIRunner.dumpPlanar(outputDirectory: args[dumpIndex + 1],
                                         paths: Array(args[(dumpIndex + 2)...])))
        }

        if args.contains("--help") || args.contains("-h") {
            printUsage()
            exit(0)
        }

        // 文件名对应：SkinTone --rename-folders <原图夹> <返图夹> [--apply]
        if let renameIndex = args.firstIndex(where: { $0 == "--rename-folders" || $0 == "-r" }) {
            guard renameIndex + 2 < args.count else {
                FileHandle.standardError.write(
                    "用法：SkinTone --rename-folders <原图文件夹> <返图文件夹> [--apply]\n".data(using: .utf8)!)
                exit(1)
            }
            runRenameFolders(original: args[renameIndex + 1], returned: args[renameIndex + 2],
                             apply: args.contains("--apply"))
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

    /// 文件名对应：比对两个文件夹里图像的画面内容，把返图改回原图的名字。
    /// 默认只打印预览报告；加 `--apply` 才真的改名（只动返图文件夹）。
    private static func runRenameFolders(original: String, returned: String, apply: Bool) {
        let originalFolder = URL(fileURLWithPath: (original as NSString).expandingTildeInPath)
        let returnedFolder = URL(fileURLWithPath: (returned as NSString).expandingTildeInPath)

        for folder in [originalFolder, returnedFolder] {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                FileHandle.standardError.write("「\(folder.path)」不存在或不是文件夹\n".data(using: .utf8)!)
                exit(1)
            }
        }

        let originalScan = FolderRenameEngine.scan(folder: originalFolder)
        let returnedScan = FolderRenameEngine.scan(folder: returnedFolder)
        let matches = FolderRenameEngine.match(originals: originalScan.files, returned: returnedScan.files)
        let plan = FolderRenameEngine.plan(matches: matches, includeUncertain: false,
                                           returnedFolder: returnedFolder)
        let outcome = apply ? FolderRenameEngine.execute(plan) : nil

        print(FolderRenameEngine.report(originalScan: originalScan, returnedScan: returnedScan,
                                        matches: matches, plan: plan, outcome: outcome,
                                        includeUncertain: false))
        exit(0)
    }

    private static func printUsage() {
        print("""
        修图助手 v1.3 — 屏幕取色 / 照片仿色 / 文件名对应（补回拍摄信息）/ JPG 转 PSD

        用法：
          SkinTone                     启动图形界面（全局快捷键 ⌃⌥C 取色）
          SkinTone --analyze #C0504D   命令行分析指定颜色并输出调色建议
          SkinTone --analyze #8FA9C4 肤色
                                       手动指定为肤色（极端环境肤色还原）
          SkinTone --analyze #C0504D 非肤色
                                       手动指定为非肤色（只看颜色本身）
          SkinTone --match 参考图 待调图
                                       照片仿色：比对两张图并输出 Photoshop 仿色建议
          SkinTone --rename-folders 原图夹 返图夹
                                       文件名对应：按画面内容比对两个文件夹并输出改名预览
          SkinTone --rename-folders 原图夹 返图夹 --apply
                                       确认无误后执行改名（只改返图夹里的文件名），
                                       同时把原图的 Exif / IPTC / TIFF 无损补写进返图
          SkinTone --to-psd 输入… [选项]
                                       JPG 转 PSD：批量把 JPG 无损转成 PSD，
                                       --to-psd 后的参数与原 JPG2PSD 一致
          SkinTone --to-psd --help     查看 JPG 转 PSD 的完整参数
          SkinTone --help              显示本帮助

        图形界面左侧有可隐藏的侧边栏，在其中切换「肤色取色 / 照片仿色 / 文件名对应 / JPG 转 PSD」；
        各功能区共用同一个窗口，侧边栏收起后，用窗口左上角的侧边栏按钮可以重新展开。
        """)
    }
}
