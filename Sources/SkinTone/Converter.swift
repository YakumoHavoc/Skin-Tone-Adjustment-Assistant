//
//  Converter.swift
//  JPG → PSD 批量无损转换
//
//  单文件转换与批量收集，逻辑与命令行/graphical 界面共用。
//

import Foundation

/// 单文件转换结果
enum ConvertOutcome {
    /// 转换成功，附带尺寸/压缩方式/体积描述
    case ok(String)
    /// 因目标已存在等原因跳过
    case skipped(String)
}

/// 一个待转换的文件
struct ConvertJob {
    let source: String
    let destination: String
    /// 源文件名（含扩展名），用于日志
    let name: String
    /// 源文件名（不含扩展名）
    let stem: String
}

/// 批量转换中单个文件的处理结果（供界面/终端展示）
enum FileResult {
    case ok(description: String, bytes: Int)
    case skipped(String)
    case failed(String)
    /// 开始处理前已请求停止
    case cancelled
}

/// 批量转换汇总
struct BatchSummary {
    var succeeded = 0
    var skipped = 0
    var failed = 0
    /// 本次新写出的 PSD 总字节数（跳过的不计）
    var totalBytes = 0
}

enum Converter {
    static let jpegExtensions = [".jpg", ".jpeg", ".jpe", ".jfif", ".jfi"]

    /// 批量转换的并发上限：按 CPU 核数并行，同时不超过 8
    static var maxConcurrentFiles: Int {
        max(1, min(ProcessInfo.processInfo.activeProcessorCount, 8))
    }

    /// 解码/打包过程中每像素约占用 10 字节（32 位交错缓冲 + 平面数据 + 输出缓冲）
    private static let bytesPerPixel = 10

    /// 同时解码/打包的字节上限，约 2GB
    private static let memoryBudget = 2_000_000_000

    /// 读不出像素数时（文件损坏、不是受支持的图片）按「大图」估算的像素数。
    /// 这类文件在解码阶段通常也会立刻失败、几乎不占内存，但绝不能按 0 计：
    /// 按 0 会让任意大的文件都能挤进当前波，内存预算就形同失效。
    private static let unknownPixelCount = 50_000_000

    /// 写盘串行队列（见 convertOne 的说明）
    private static let writeQueue = DispatchQueue(label: "com.tools.jpg2psd.write")

    static func isJPEG(_ path: String) -> Bool {
        let lower = path.lowercased()
        return jpegExtensions.contains { lower.hasSuffix($0) }
    }

    /// 展开 `~` 与相对路径
    static func absolutePath(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
    }

    // MARK: - 单文件转换

    /// 把 `src` 转成 PSD 写到 `dst`。
    /// 写盘用临时文件 + 原子替换，中途中断不会留下半成品。
    static func convertOne(src: String,
                           dst: String,
                           compression: PSDCompression,
                           keepOrientation: Bool,
                           overwrite: Bool) throws -> ConvertOutcome {
        let manager = FileManager.default
        if manager.fileExists(atPath: dst), !overwrite {
            return .skipped("目标已存在（勾选「覆盖已存在的 PSD」可覆盖）")
        }

        let loaded = try ImageLoader.load(path: src, keepOrientation: keepOrientation)
        let (psd, method) = try PSDWriter.build(loaded.planar, icc: loaded.icc,
                                                dpi: loaded.dpi,
                                                exif: loaded.exif, iptc: loaded.iptc,
                                                xmp: loaded.xmp,
                                                compression: compression)

        // 临时文件名带唯一后缀，多个文件并行转换时不会互相覆盖
        let temporary = dst + ".part-" + UUID().uuidString

        // 解码与打包并行，但写盘排队：同时写多个几十 MB 的 PSD 会触发系统的
        // 脏页限流，写出速度反而下降；串行写则能一直跑满磁盘写入带宽。
        try writeQueue.sync {
            try psd.write(to: URL(fileURLWithPath: temporary))
            if manager.fileExists(atPath: dst) {
                _ = try manager.replaceItemAt(URL(fileURLWithPath: dst),
                                              withItemAt: URL(fileURLWithPath: temporary))
            } else {
                try manager.moveItem(atPath: temporary, toPath: dst)
            }
        }

        var description = "\(loaded.planar.width)x\(loaded.planar.height) \(method) "
            + String(format: "%.1fMB", Double(psd.count) / 1_048_576)
        if let icc = loaded.icc, !icc.isEmpty {
            description += " ICC:\(icc.count)B"
        }
        // 写进 PSD 图像资源的拍摄信息（EXIF→1058 / IPTC→1028 / XMP→1060）
        var shooting: [String] = []
        if loaded.exif != nil { shooting.append("EXIF") }
        if loaded.iptc != nil { shooting.append("IPTC") }
        if loaded.xmp != nil { shooting.append("XMP") }
        if !shooting.isEmpty {
            description += " 拍摄信息:" + shooting.joined(separator: "+")
        }
        return .ok(description)
    }

    // MARK: - 批量转换（文件级并行）

    /// 有界并发地转换一批文件，结果按输入顺序回调。
    ///
    /// - `onResult` 在锁内被串行调用（保证顺序与日志不交错），实现里不要做耗时操作；
    ///   界面应当只在这里 `DispatchQueue.main.async` 转发。
    /// - 每个文件开始前检查一次 `isCancelled`，已请求停止的文件直接记为 `.cancelled`，
    ///   已在转换中的文件会跑完（保证不留下半成品）。
    static func runBatch(_ jobs: [ConvertJob],
                         compression: PSDCompression,
                         keepOrientation: Bool,
                         overwrite: Bool,
                         isCancelled: @escaping () -> Bool,
                         onResult: @escaping (Int, FileResult) -> Void) -> BatchSummary {
        var summary = BatchSummary()
        guard !jobs.isEmpty else { return summary }

        // 同一个输出文件名只保留先出现的那个，否则并行写同一个文件会互相覆盖
        var claimed = Set<String>()
        var duplicates = Set<Int>()
        for (index, job) in jobs.enumerated() where !claimed.insert(job.destination).inserted {
            duplicates.insert(index)
        }

        let total = jobs.count
        let lock = NSLock()
        var results = [FileResult?](repeating: nil, count: total)
        var nextToReport = 0

        // 结果先按序号存放，再按顺序连续吐出，避免并发完成时日志乱序
        func record(_ index: Int, _ result: FileResult) {
            lock.lock()
            results[index] = result
            while nextToReport < total, let done = results[nextToReport] {
                onResult(nextToReport, done)
                nextToReport += 1
            }
            lock.unlock()
        }

        let queue = OperationQueue()
        queue.name = "com.tools.jpg2psd.batch"
        queue.qualityOfService = .userInitiated

        // 大图解码峰值内存很高，把一批文件按像素数切成若干「波」：
        // 每波的总像素控制在内存预算内，波内再按 CPU 核数并发。
        let cpuLimit = maxConcurrentFiles
        var cursor = 0
        while cursor < total {
            var wave: [Int] = []
            var waveCost = 0
            while cursor < total {
                // 读不到像素数时按大图估算，避免「未知尺寸」的文件无成本地挤进当前波
                let pixels = ImageLoader.pixelCount(path: jobs[cursor].source) ?? unknownPixelCount
                let cost = pixels * bytesPerPixel
                // 单个文件即便超出预算也单独成波处理（`!wave.isEmpty`），避免死循环
                if !wave.isEmpty, waveCost + cost > memoryBudget { break }
                wave.append(cursor)
                waveCost += cost
                cursor += 1
            }
            queue.maxConcurrentOperationCount = max(1, min(cpuLimit, wave.count))

            for index in wave {
                let job = jobs[index]
                queue.addOperation {
                    // 每个文件独立回收，避免 ImageIO/CG 的临时对象在后台线程堆积
                    autoreleasepool {
                        if duplicates.contains(index) {
                            record(index, .skipped("输出文件重名，已跳过（保留先出现的同名文件）"))
                            return
                        }
                        guard !isCancelled() else {
                            record(index, .cancelled)
                            return
                        }
                        do {
                            switch try convertOne(src: job.source, dst: job.destination,
                                                  compression: compression,
                                                  keepOrientation: keepOrientation,
                                                  overwrite: overwrite) {
                            case .ok(let description):
                                let attributes = try? FileManager.default
                                    .attributesOfItem(atPath: job.destination)
                                let bytes = attributes?[.size] as? Int ?? 0
                                record(index, .ok(description: description, bytes: bytes))
                            case .skipped(let reason):
                                record(index, .skipped(reason))
                            }
                        } catch {
                            record(index, .failed(error.localizedDescription))
                        }
                    }
                }
            }
            queue.waitUntilAllOperationsAreFinished()
        }

        for result in results {
            switch result {
            case .ok(_, let bytes):
                summary.succeeded += 1
                summary.totalBytes += bytes
            case .skipped:
                summary.skipped += 1
            case .failed:
                summary.failed += 1
            case .cancelled, nil:
                break
            }
        }
        return summary
    }

    // MARK: - 批量收集

    /// 把「文件 / 文件夹混合的输入列表」展开成待转换的 JPG 文件列表。
    /// 返回去重并排序后的文件，以及需要提示给用户的警告。
    static func collectInputs(_ paths: [String], recursive: Bool) -> (files: [String], warnings: [String]) {
        let manager = FileManager.default
        var found: [String] = []
        var warnings: [String] = []

        for raw in paths {
            let path = absolutePath(raw)
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: path, isDirectory: &isDirectory) else {
                warnings.append("找不到路径：\(raw)")
                continue
            }

            if isDirectory.boolValue {
                if recursive {
                    let options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles]
                    if let enumerator = manager.enumerator(at: URL(fileURLWithPath: path),
                                                           includingPropertiesForKeys: [.isRegularFileKey],
                                                           options: options) {
                        for case let fileURL as URL in enumerator where isJPEG(fileURL.path) {
                            found.append(fileURL.path)
                        }
                    }
                } else {
                    let names = (try? manager.contentsOfDirectory(atPath: path)) ?? []
                    for name in names.sorted() {
                        let full = (path as NSString).appendingPathComponent(name)
                        var childIsDirectory: ObjCBool = false
                        if manager.fileExists(atPath: full, isDirectory: &childIsDirectory),
                           !childIsDirectory.boolValue,
                           isJPEG(full) {
                            found.append(full)
                        }
                    }
                }
            } else if isJPEG(path) {
                found.append(path)
            } else {
                warnings.append("跳过（非 JPG）：\(raw)")
            }
        }

        return (Array(Set(found)).sorted(), warnings)
    }
}
