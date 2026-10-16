import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 一张已载入的照片（统计结果 + 用于显示的缩略图）
struct LoadedPhoto {
    let name: String
    let url: URL
    let stats: PhotoStats
    let image: NSImage
}

/// 照片仿色的数据模型：与肤色取色模块完全独立
final class PhotoMatchModel: ObservableObject {

    static let shared = PhotoMatchModel()

    enum Role: Hashable {
        case reference
        case target

        var title: String { self == .reference ? "参考图" : "待仿色图" }
        var roleHint: String {
            self == .reference
                ? "想模仿的那张：影调柔和 / 色调偏黄绿的片子"
                : "要动手调的那张：目前是全影调、色调不同的片子"
        }
    }

    @Published private(set) var reference: LoadedPhoto?
    @Published private(set) var target: LoadedPhoto?
    @Published private(set) var message: String = ""
    /// 正在被拖拽悬停的卡片（用于高亮），nil = 当前没有拖拽
    @Published var dragTarget: Role?
    @Published private(set) var loadingReference = false
    @Published private(set) var loadingTarget = false

    var plan: MatchPlan? {
        guard let ref = reference, let tgt = target else { return nil }
        return MatchPlanner.plan(reference: ref.stats, target: tgt.stats)
    }

    var isReady: Bool { reference != nil && target != nil }

    func photo(_ role: Role) -> LoadedPhoto? {
        role == .reference ? reference : target
    }

    func prompt(_ role: Role) -> String {
        "点这里导入\(role.title)，也可把图片从 Finder 直接拖进来\n（PNG / JPEG / TIFF / HEIC）"
    }

    /// 该角色是否正在载入
    func isLoading(_ role: Role) -> Bool {
        role == .reference ? loadingReference : loadingTarget
    }

    /// 载入照片。解码与逐像素统计都在后台队列上做，算完只回主线程赋一次值：
    /// 拖动导入与面板导入走的都是这条路径，大图也不会把界面卡住。
    func load(_ url: URL, as role: Role) {
        // Finder 拖过来的可能是 `.file/id=` 形式的文件引用 URL，先归一化成真实路径
        let fileURL = (url as NSURL).filePathURL ?? url
        guard !isLoading(role) else { return }
        setLoading(true, for: role)
        message = "正在载入\(role.title)：\(fileURL.lastPathComponent)…"

        DispatchQueue.global(qos: .userInitiated).async {
            let result = PhotoAnalyzer.load(url: fileURL)
            DispatchQueue.main.async {
                self.setLoading(false, for: role)
                guard let result else {
                    self.message = "读不出这张照片：\(fileURL.lastPathComponent)。请换一张常见格式的图片。"
                    return
                }
                let image = NSImage(cgImage: result.image,
                                    size: NSSize(width: result.image.width, height: result.image.height))
                let photo = LoadedPhoto(name: fileURL.lastPathComponent, url: fileURL,
                                        stats: result.stats, image: image)
                if role == .reference { self.reference = photo } else { self.target = photo }
                self.message = "已载入\(role.title)：\(photo.name)"
            }
        }
    }

    private func setLoading(_ value: Bool, for role: Role) {
        if role == .reference { loadingReference = value } else { loadingTarget = value }
    }

    func clear(_ role: Role) {
        if role == .reference { reference = nil } else { target = nil }
        message = ""
    }

    func swap() {
        let old = reference
        reference = target
        target = old
    }

    /// 用系统面板选图
    func choose(_ role: Role) {
        let panel = NSOpenPanel()
        panel.title = "选择\(role.title)"
        panel.message = role.roleHint
        panel.prompt = "导入"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK, let url = panel.url {
            load(url, as: role)
        }
    }

    func loadPath(_ path: String, as role: Role) {
        load(URL(fileURLWithPath: (path as NSString).expandingTildeInPath), as: role)
    }
}
