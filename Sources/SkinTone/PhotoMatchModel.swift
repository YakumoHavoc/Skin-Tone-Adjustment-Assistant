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

    func load(_ url: URL, as role: Role) {
        guard let result = PhotoAnalyzer.load(url: url) else {
            message = "读不出这张照片：\(url.lastPathComponent)。请换一张常见格式的图片。"
            return
        }
        let photo = LoadedPhoto(name: url.lastPathComponent, url: url,
                                stats: result.stats, image: result.image)
        if role == .reference { reference = photo } else { target = photo }
        message = "已载入\(role.title)：\(photo.name)"
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
