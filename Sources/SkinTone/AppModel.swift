import AppKit
import Combine
import Foundation

/// 应用状态：当前取色结果、历史记录、快捷键与取色服务
final class AppModel: ObservableObject {

    static let shared = AppModel()

    @Published private(set) var current: Analysis?
    @Published private(set) var history: [Analysis] = []
    @Published private(set) var isPicking = false
    @Published private(set) var lastMessage: String?
    /// 手动输入的十六进制颜色
    @Published var hexInput = ""
    /// 手动指定的分类（nil = 自动判定），极端环境下可覆盖自动结果
    @Published private(set) var manualKind: SkinKind?

    let hotKeys = HotKeyManager()
    private let picker = ColorPickerService()

    private init() {}

    var hotKeyDisplay: String { hotKeys.displayString }

    var hotKeyRegistered: Bool { hotKeys.isRegistered }

    // MARK: - 快捷键

    func registerHotKey() {
        hotKeys.onFire = { [weak self] in self?.startPick() }
        let ok = hotKeys.register()
        if !ok {
            lastMessage = "全局快捷键注册失败，请改用菜单「开始取色」"
        }
        objectWillChange.send()
    }

    // MARK: - 取色

    func startPick() {
        guard !isPicking else { return }
        isPicking = true
        lastMessage = "拖动屏幕上的放大镜定位，单击取色（Esc 取消）"

        NSApp.activate(ignoringOtherApps: true)

        picker.pick { [weak self] color in
            guard let self else { return }
            self.isPicking = false
            guard let color else {
                self.lastMessage = "已取消取色"
                return
            }
            self.apply(color)
        }
    }

    /// 直接使用十六进制颜色（便于手动输入 / 命令行验证）
    func applyHex(_ hex: String) -> Bool {
        guard let rgb = RGBColor(hex: hex) else { return false }
        apply(rgb)
        return true
    }

    func applyHexInput() {
        if applyHex(hexInput) {
            hexInput = ""
        } else {
            setMessage("颜色格式不正确，请输入 #RRGGBB，例如 #C0504D")
        }
    }

    func apply(_ color: RGBColor) {
        let analysis = ColorEngine.analyze(color, assumed: manualKind)
        current = analysis
        history.insert(analysis, at: 0)
        if history.count > 16 { history.removeLast(history.count - 16) }
        lastMessage = "取色完成：\(color.hexString)"
    }

    func select(_ analysis: Analysis) {
        current = ColorEngine.analyze(analysis.source, assumed: manualKind)
        lastMessage = "已切换到 \(analysis.source.hexString)"
    }

    /// 切换「自动 / 肤色 / 非肤色」，并立即按新分类重算当前取色点
    func setManualKind(_ kind: SkinKind?) {
        guard kind != manualKind else { return }
        manualKind = kind
        guard let source = current?.source else { return }
        current = ColorEngine.analyze(source, assumed: kind)
        switch kind {
        case .none:      lastMessage = "已恢复自动判定"
        case .skin:      lastMessage = "已手动指定为肤色"
        case .nonSkin:   lastMessage = "已手动指定为非肤色"
        }
    }

    func setMessage(_ text: String) {
        lastMessage = text
    }
}
