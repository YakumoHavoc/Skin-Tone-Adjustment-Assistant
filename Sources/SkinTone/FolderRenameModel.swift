import AppKit
import Combine
import Foundation

/// 文件名对应模块的状态：左右两个文件夹、扫描与匹配结果、执行与撤销。
/// 重活（解码 + 指纹计算 + 逐张比对）都在后台队列上做，算完只回主线程赋一次值。
final class FolderRenameModel: ObservableObject {

    static let shared = FolderRenameModel()

    /// 左（原图）/ 右（返图）。改名只发生在右侧。
    enum Role: Hashable {
        case original
        case returned

        var shortTitle: String { self == .original ? "原图文件夹" : "返图文件夹" }
        var hint: String {
            self == .original
                ? "模特的原始命名：这一侧的文件名会被用来给返图改名"
                : "模特修完的返图：名字常是乱码，比对成功后会被改成左侧对应原图的名字"
        }
        var panelTitle: String { self == .original ? "选择原图文件夹" : "选择返图文件夹" }
    }

    @Published private(set) var originalFolder: URL?
    @Published private(set) var returnedFolder: URL?
    @Published private(set) var originalScan: FolderScan?
    @Published private(set) var returnedScan: FolderScan?
    @Published private(set) var matches: [RenameMatch] = []
    @Published private(set) var plan = RenamePlan()
    @Published private(set) var outcome: RenameOutcome?
    @Published private(set) var undoSteps: [RenameStep] = []
    @Published private(set) var isScanning = false
    @Published private(set) var isWorking = false
    @Published private(set) var message = ""
    /// 疑似匹配要不要一起改名
    @Published var includeUncertain = false {
        didSet {
            guard oldValue != includeUncertain else { return }
            rebuildPlan()
        }
    }
    /// 正在被拖拽悬停的文件夹卡片（用于高亮），nil = 当前没有拖拽
    @Published var dragTarget: Role?

    /// 每次扫描都换一个令牌，回来时对不上就说明中途换过文件夹，结果作废
    private var scanToken = UUID()

    private init() {}

    func folder(_ role: Role) -> URL? {
        role == .original ? originalFolder : returnedFolder
    }

    func scanResult(_ role: Role) -> FolderScan? {
        role == .original ? originalScan : returnedScan
    }

    var hasBothFolders: Bool { originalFolder != nil && returnedFolder != nil }
    var canUndo: Bool { !undoSteps.isEmpty }
    var isBusy: Bool { isScanning || isWorking }

    var countsText: String {
        let matched = matches.filter { $0.status == .matched }.count
        let uncertain = matches.filter { $0.status == .uncertain }.count
        let unmatched = matches.filter { $0.status == .unmatched }.count
        return "匹配 \(matched) · 疑似 \(uncertain) · 未匹配 \(unmatched)"
    }

    // MARK: - 选择文件夹

    /// 用系统面板选文件夹
    func choose(_ role: Role) {
        let panel = NSOpenPanel()
        panel.title = role.panelTitle
        panel.message = "选一个文件夹（本工具不会改动这个文件夹里的文件）"
        panel.prompt = "选择"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            setFolder(url, role: role)
        }
    }

    /// 设置文件夹：面板选择与 Finder 拖拽都走这里，只接受目录
    func setFolder(_ url: URL, role: Role) {
        // Finder 拖过来的可能是 `.file/id=` 形式的文件引用 URL，先归一化成真实路径
        let fileURL = (url as NSURL).filePathURL ?? url
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            message = "「\(fileURL.lastPathComponent)」不是文件夹，请拖文件夹进来"
            return
        }

        if role == .original { originalFolder = fileURL; originalScan = nil }
        else { returnedFolder = fileURL; returnedScan = nil }
        matches = []
        plan = RenamePlan()
        outcome = nil
        message = "已选择\(role.shortTitle)：\(fileURL.path)"

        if hasBothFolders { scan() }
    }

    func clear(_ role: Role) {
        if role == .original { originalFolder = nil; originalScan = nil }
        else { returnedFolder = nil; returnedScan = nil }
        matches = []
        plan = RenamePlan()
        outcome = nil
        message = ""
    }

    // MARK: - 扫描与匹配

    /// 扫描两个文件夹并比对。解码、指纹、逐张比对都在后台队列，界面不卡。
    func scan() {
        guard let originalFolder, let returnedFolder else {
            message = "请先把左右两个文件夹都选好"
            return
        }
        let token = UUID()
        scanToken = token
        let includeUncertain = self.includeUncertain
        isScanning = true
        message = "正在比对两个文件夹里的图像内容…"

        DispatchQueue.global(qos: .userInitiated).async {
            let originalScan = FolderRenameEngine.scan(folder: originalFolder)
            let returnedScan = FolderRenameEngine.scan(folder: returnedFolder)
            let matches = FolderRenameEngine.match(originals: originalScan.files,
                                                   returned: returnedScan.files)
            let plan = FolderRenameEngine.plan(matches: matches, includeUncertain: includeUncertain,
                                               returnedFolder: returnedFolder)
            DispatchQueue.main.async {
                guard self.scanToken == token else { return }
                self.isScanning = false
                self.originalScan = originalScan
                self.returnedScan = returnedScan
                self.matches = matches
                self.plan = plan
                self.message = matches.isEmpty
                    ? "比对完成：两个文件夹里没有可比对的图像"
                    : "比对完成：\(self.countsText)"
            }
        }
    }

    private func rebuildPlan() {
        guard let returnedFolder else { return }
        plan = FolderRenameEngine.plan(matches: matches, includeUncertain: includeUncertain,
                                       returnedFolder: returnedFolder)
    }

    // MARK: - 执行与撤销

    /// 按当前计划执行改名。执行前请先看过「匹配预览」。
    func execute() {
        guard !plan.isEmpty else {
            message = "没有可改名的文件：请先点「扫描并预览匹配」"
            return
        }
        guard !isWorking else { return }
        let plan = self.plan
        isWorking = true
        outcome = nil
        message = "正在改名并把原图的拍摄信息补写进返图…"

        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = FolderRenameEngine.execute(plan)
            DispatchQueue.main.async {
                self.isWorking = false
                self.outcome = outcome
                self.undoSteps = outcome.renamed
                // 执行后不再自动重扫：文件夹里的文件名已经变了，原来的预览已过期，
                // 直接清掉，需要重新核对时由用户自己点「扫描并预览匹配」。
                self.matches = []
                self.plan = RenamePlan()
                self.message = "已完成：改名 \(outcome.renamed.count) 个 · 跳过 \(outcome.skipped.count) 个"
                    + " · 失败 \(outcome.failed.count) 个。如需再次核对，请点「扫描并预览匹配」"
            }
        }
    }

    /// 撤销上一次执行的重命名
    func undo() {
        guard !undoSteps.isEmpty, !isWorking else { return }
        let steps = undoSteps
        isWorking = true
        outcome = nil
        message = "正在还原文件名…"

        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = FolderRenameEngine.undo(steps)
            DispatchQueue.main.async {
                self.isWorking = false
                self.undoSteps = []
                self.outcome = outcome
                // 撤销后同样不自动重扫，理由与 execute 一致
                self.matches = []
                self.plan = RenamePlan()
                self.message = "已还原文件名（\(outcome.renamed.count) 个）。如需再次核对，请点「扫描并预览匹配」"
            }
        }
    }
}
