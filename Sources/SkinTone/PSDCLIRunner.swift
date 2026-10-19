//
//  PSDCLIRunner.swift
//  JPG → PSD 批量无损转换
//
//  并入「修图助手」后命令行为 `修图助手 --to-psd <与原来相同的参数>`，参数与行为不变。
//  另外保留 `--dump-planar`（自检用）：把解码后的平面像素原样导出成 .raw，
//  便于逐字节核对 PSD 里写入的像素与解码结果是否一致。
//

import Foundation

enum PSDCLIRunner {
    static func usage() -> String {
        """
        批量把 JPG 无损转存为 PSD（供 Photoshop 修图）。

        PSD 里的像素与原图逐字节一致（Raw 或无损 RLE），并保留 ICC 色彩描述文件、
        DPI 与拍摄信息：EXIF / IPTC / XMP 分别写进 PSD 的 1058 / 1028 / 1060 号图像资源，
        相机、镜头、拍摄参数、日期、GPS、版权等都不会丢。

        用法：修图助手 --to-psd <输入…> [选项]

        参数（与原 JPG2PSD 命令行一致）：
          inputs                  JPG 文件、文件夹，或两者混合，可多个
          -o, --output <目录>      输出目录（默认与源文件同目录）
          -r, --recursive         递归扫描子文件夹
          --compression <方式>     auto（默认，自动在 Raw / RLE 中选体积更小者，均无损）、raw、rle
          --keep-orientation      不按 EXIF 方向摆正（默认会按 EXIF 摆正，旋转为无损）
          --overwrite             覆盖已存在的 PSD（默认跳过）
          -q, --quiet             只输出汇总，不逐个打印
          -h, --help              显示本帮助

        示例：
          修图助手 --to-psd 照片文件夹 -o PSD输出 -r
          修图助手 --to-psd a.jpg b.jpg
          修图助手 --to-psd . -r --compression rle --overwrite
        """
    }

    private static func warn(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    // MARK: - 命令行批量转换

    static func run(_ args: [String]) -> Int32 {
        var inputs: [String] = []
        var output: String?
        var recursive = false
        var compression: PSDCompression = .auto
        var keepOrientation = false
        var overwrite = false
        var quiet = false

        var index = 0
        while index < args.count {
            let argument = args[index]
            switch argument {
            case "-o", "--output":
                index += 1
                guard index < args.count else { warn("--output 缺少参数"); return 2 }
                output = args[index]
            case "-r", "--recursive":
                recursive = true
            case "--keep-orientation":
                keepOrientation = true
            case "--overwrite":
                overwrite = true
            case "-q", "--quiet":
                quiet = true
            case "--compression":
                index += 1
                guard index < args.count, let value = PSDCompression(rawValue: args[index]) else {
                    warn("--compression 只支持 auto / raw / rle")
                    return 2
                }
                compression = value
            case "-h", "--help":
                print(usage())
                return 0
            default:
                if argument.hasPrefix("-") {
                    warn("未知参数：\(argument)")
                    warn(usage())
                    return 2
                }
                inputs.append(argument)
            }
            index += 1
        }

        guard !inputs.isEmpty else {
            warn(usage())
            return 2
        }

        let (files, warnings) = Converter.collectInputs(inputs, recursive: recursive)
        warnings.forEach(warn)
        guard !files.isEmpty else {
            warn("没有找到任何 JPG 文件。")
            return 1
        }

        var outputDirectory: String?
        if let output {
            let directory = Converter.absolutePath(output)
            do {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                outputDirectory = directory
            } catch {
                warn("无法创建输出目录：\(error.localizedDescription)")
                return 1
            }
        }

        let jobs = files.map { source -> ConvertJob in
            let name = (source as NSString).lastPathComponent
            let stem = (name as NSString).deletingPathExtension
            let directory = outputDirectory ?? (source as NSString).deletingLastPathComponent
            return ConvertJob(source: source,
                              destination: (directory as NSString).appendingPathComponent(stem + ".psd"),
                              name: name, stem: stem)
        }

        let total = jobs.count
        let summary = Converter.runBatch(jobs,
                                         compression: compression,
                                         keepOrientation: keepOrientation,
                                         overwrite: overwrite,
                                         isCancelled: { false }) { index, result in
            let job = jobs[index]
            let prefix = "[\(index + 1)/\(total)] \(job.name)"
            switch result {
            case .ok(let description, _):
                if !quiet { print("\(prefix)  ->  \(job.stem).psd   \(description)") }
            case .skipped(let reason):
                if !quiet { print("\(prefix)  跳过：\(reason)") }
            case .failed(let message):
                warn("\(prefix)  失败：\(message)")
            case .cancelled:
                break
            }
        }

        print(String(format: "\n完成：成功 %d，跳过 %d，失败 %d，共 %.1fMB。",
                     summary.succeeded, summary.skipped, summary.failed,
                     Double(summary.totalBytes) / 1_048_576))
        return summary.failed == 0 ? 0 : 1
    }

    // MARK: - 自检：导出解码后的平面像素

    static func dumpPlanar(outputDirectory: String, paths: [String]) -> Int32 {
        let manager = FileManager.default
        do {
            try manager.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)
        } catch {
            warn("无法创建输出目录：\(error.localizedDescription)")
            return 1
        }

        var count = 0
        for path in paths {
            let name = (path as NSString).lastPathComponent
            let stem = (name as NSString).deletingPathExtension
            do {
                let oriented = try ImageLoader.load(path: path, keepOrientation: false)
                let unrotated = try ImageLoader.load(path: path, keepOrientation: true)
                try oriented.planar.data.write(to: URL(fileURLWithPath: "\(outputDirectory)/\(stem).raw"))
                try unrotated.planar.data.write(to: URL(fileURLWithPath: "\(outputDirectory)/\(stem).norot.raw"))

                var meta = "oriented: \(oriented.planar.width)x\(oriented.planar.height) "
                meta += "channels=\(oriented.planar.channels) colorMode=\(oriented.planar.colorMode)\n"
                meta += "norot: \(unrotated.planar.width)x\(unrotated.planar.height) "
                meta += "channels=\(unrotated.planar.channels)\n"
                meta += "orient=\(oriented.orientation)\n"
                meta += "icc=\(oriented.icc?.count ?? 0)\n"
                if let dpi = oriented.dpi {
                    meta += "dpi=\(dpi.h)x\(dpi.v)\n"
                } else {
                    meta += "dpi=none\n"
                }
                try meta.write(toFile: "\(outputDirectory)/\(stem).meta", atomically: true, encoding: .utf8)
                count += 1
            } catch {
                warn("\(name) 失败：\(error.localizedDescription)")
            }
        }
        print("已导出 \(count) 个文件的平面像素 -> \(outputDirectory)")
        return 0
    }
}
