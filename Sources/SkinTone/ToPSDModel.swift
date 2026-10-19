import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

/// 转换的取消标记：后台线程读、主线程置位
final class CancellationFlag {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
    func cancel() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

/// 「JPG 转 PSD」功能区的状态与调度。
/// 这一层完全对应原 JPG2PSD 的 MainWindowController：列表、输出位置、选项、
/// 后台批量转换与日志的行为都保持一致，只是换成 SwiftUI 单窗口里的一个功能区。
final class ToPSDModel: ObservableObject {

    static let shared = ToPSDModel()

    /// 输出位置：与源文件同目录 / 指定目录
    enum OutputMode {
        case sameDirectory
        case custom
    }

    /// 待转换的 JPG（文件或文件夹路径，与源程序一样存绝对路径）
    @Published var sources: [String] = []
    /// 列表里被选中的路径，供「移除选中」使用
    @Published var selection: Set<String> = []

    @Published private(set) var outputMode: OutputMode = .sameDirectory
    @Published var outputDirectory = ""

    @Published var recursive = true
    /// 「按 EXIF 摆正方向（无损）」默认勾选
    @Published var orientByEXIF = true
    @Published var overwrite = false
    @Published var compression: PSDCompression = .auto

    @Published private(set) var isRunning = false
    @Published private(set) var isCancelling = false
    @Published private(set) var status = "就绪"
    @Published private(set) var progress = 0.0
    @Published private(set) var progressTotal = 1
    @Published private(set) var log: [String] = []
    /// 转换成功后的输出目录，决定「打开输出文件夹」是否可用
    @Published private(set) var lastOutputDirectory: String?
    /// 是否正有文件拖在本区域上方（用于高亮）
    @Published var isDropTargeted = false

    private var cancelFlag: CancellationFlag?

    private init() {
        appendLog("请添加 JPG 图片或文件夹，然后点击「开始转换」。")
        appendLog("提示：可以把文件 / 文件夹直接拖进本区域。")
    }

    var canOpenOutput: Bool { lastOutputDirectory != nil }
    var isEmpty: Bool { sources.isEmpty }

    // MARK: - 日志与状态

    private func appendLog(_ text: String) {
        log.append(text)
    }

    private func setStatus(_ text: String) {
        status = text
    }

    // MARK: - 添加 / 移除输入

    /// 面板选择与 Finder 拖拽都走这里
    func addSources(_ paths: [String]) {
        var added = 0
        var ignored = 0
        var duplicate = 0
        for raw in paths {
            let path = Converter.absolutePath(raw)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
            if sources.contains(path) {
                duplicate += 1
                continue
            }
            if !isDirectory.boolValue && !Converter.isJPEG(path) {
                ignored += 1
                continue
            }
            sources.append(path)
            added += 1
        }
        if added > 0 {
            appendLog("已添加 \(added) 项（列表共 \(sources.count) 项）。")
        }
        if ignored > 0 {
            appendLog("忽略 \(ignored) 个非 JPG 文件。")
        }
        if duplicate > 0 {
            appendLog("\(duplicate) 项已在列表中，已忽略。")
        }
    }

    func addSourceURLs(_ urls: [URL]) {
        // Finder 拖过来的可能是 `.file/id=` 形式的文件引用 URL，先归一化成真实路径
        addSources(urls.map { (($0 as NSURL).filePathURL ?? $0).path })
    }

    func pickFiles() {
        let panel = NSOpenPanel()
        panel.title = "选择要转换的 JPG"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.jpeg]
        guard panel.runModal() == .OK else { return }
        addSources(panel.urls.map { $0.path })
    }

    func pickFolders() {
        let panel = NSOpenPanel()
        panel.title = "选择包含 JPG 的文件夹"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK else { return }
        addSources(panel.urls.map { $0.path })
    }

    func removeSelected() {
        guard !selection.isEmpty else {
            appendLog("没有选中任何项。")
            return
        }
        let count = selection.count
        sources.removeAll { selection.contains($0) }
        selection.removeAll()
        appendLog("已移除 \(count) 项（列表共 \(sources.count) 项）。")
    }

    func clearAll() {
        guard !sources.isEmpty else { return }
        let count = sources.count
        sources.removeAll()
        selection.removeAll()
        appendLog("已清空 \(count) 项。")
    }

    // MARK: - 输出位置

    func setOutputMode(_ mode: OutputMode) {
        outputMode = mode
        // 切到「指定目录」而目录还空着时，直接弹选择面板（与原程序一致）
        if mode == .custom, outputDirectory.isEmpty {
            pickOutputDirectory()
        }
    }

    func pickOutputDirectory() {
        let panel = NSOpenPanel()
        panel.title = "选择输出文件夹"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        outputDirectory = url.path
        outputMode = .custom
    }

    func openOutputFolder() {
        guard let directory = lastOutputDirectory else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: directory))
    }

    // MARK: - 转换流程

    func startOrCancel() {
        if isRunning {
            cancelFlag?.cancel()
            isCancelling = true
            setStatus("正在停止…")
            appendLog("已请求停止，正在结束当前文件…")
            return
        }
        guard !sources.isEmpty else {
            appendLog("请先添加要转换的 JPG。")
            return
        }

        let recursive = self.recursive
        let keepOrientation = !orientByEXIF
        let overwrite = self.overwrite
        let compression = self.compression
        let customOutput: String? = outputMode == .custom
            ? Converter.absolutePath(outputDirectory)
            : nil

        if outputMode == .custom, outputDirectory.isEmpty {
            appendLog("请先选择输出目录。")
            return
        }

        // 展开文件夹
        let (files, warnings) = Converter.collectInputs(sources, recursive: recursive)
        warnings.forEach { appendLog($0) }
        guard !files.isEmpty else {
            appendLog("没有找到任何 JPG 文件。")
            return
        }

        var outputDirectory: String?
        if let customOutput {
            do {
                try FileManager.default.createDirectory(atPath: customOutput,
                                                        withIntermediateDirectories: true)
                outputDirectory = customOutput
            } catch {
                appendLog("无法创建输出目录：\(error.localizedDescription)")
                return
            }
        }

        appendLog("开始转换 \(files.count) 个文件（压缩方式：\(compression.label)，并发 \(Converter.maxConcurrentFiles)）。")
        isRunning = true
        isCancelling = false
        progressTotal = files.count
        progress = 0
        setStatus("转换中… 0/\(files.count)")

        let flag = CancellationFlag()
        cancelFlag = flag

        let jobs = files.map { source -> ConvertJob in
            let name = (source as NSString).lastPathComponent
            let stem = (name as NSString).deletingPathExtension
            let directory = outputDirectory ?? (source as NSString).deletingLastPathComponent
            return ConvertJob(source: source,
                              destination: (directory as NSString).appendingPathComponent(stem + ".psd"),
                              name: name, stem: stem)
        }
        let total = jobs.count

        // 转换按文件并行（见 Converter.runBatch），结果按顺序回到主线程刷新界面
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // completed 只在主线程里读写
            var completed = 0
            let summary = Converter.runBatch(jobs,
                                             compression: compression,
                                             keepOrientation: keepOrientation,
                                             overwrite: overwrite,
                                             isCancelled: { flag.isCancelled }) { index, result in
                let job = jobs[index]
                DispatchQueue.main.async {
                    let prefix = "[\(index + 1)/\(total)] \(job.name)"
                    switch result {
                    case .ok(let description, _):
                        self?.appendLog("\(prefix)  ->  \(job.stem).psd   \(description)")
                    case .skipped(let reason):
                        self?.appendLog("\(prefix)  跳过：\(reason)")
                    case .failed(let message):
                        self?.appendLog("\(prefix)  失败：\(message)")
                    case .cancelled:
                        return
                    }
                    completed += 1
                    self?.progress = Double(completed)
                    self?.setStatus("转换中… \(completed)/\(total)")
                }
            }

            DispatchQueue.main.async {
                let cancelled = flag.isCancelled
                let megabytes = Double(summary.totalBytes) / 1_048_576
                let text = String(format: "完成：成功 %d，跳过 %d，失败 %d，共 %.1fMB。",
                                  summary.succeeded, summary.skipped, summary.failed, megabytes)
                self?.appendLog(cancelled ? "已停止。" + text : text)
                self?.setStatus(cancelled
                    ? "已停止（成功 \(summary.succeeded)，跳过 \(summary.skipped)，失败 \(summary.failed)）"
                    : "完成：成功 \(summary.succeeded)，跳过 \(summary.skipped)，失败 \(summary.failed)")
                if summary.succeeded > 0,
                   let directory = outputDirectory
                       ?? jobs.last.map({ ($0.source as NSString).deletingLastPathComponent }) {
                    self?.lastOutputDirectory = directory
                }
                self?.isRunning = false
                self?.isCancelling = false
                self?.cancelFlag = nil
            }
        }
    }
}
