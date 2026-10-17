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
    /// 当前功能区：肤色取色 / 照片仿色
    @Published var section: AppSection = .skin
    /// 左侧侧边栏是否展开
    @Published var isSidebarVisible = true
    /// 是否正在让用户录入新的取色快捷键
    @Published var isRecordingHotKey = false
    /// 当前生效的取色快捷键
    @Published private(set) var hotKey: HotKey = .defaultPick
    /// 当前快捷键是否注册成功
    @Published private(set) var isHotKeyRegistered = false

    let hotKeys = HotKeyManager()
    private let picker = ColorPickerService()

    private init() {}

    var hotKeyDisplay: String { hotKey.displayString }

    // MARK: - 快捷键

    /// 启动时注册：优先用用户上次设定的组合键，被占用则回退到默认
    func registerHotKey() {
        hotKeys.onFire = { [weak self] in self?.startPick() }

        if let saved = HotKey.saved(), hotKeys.register(saved) {
            hotKey = saved
            isHotKeyRegistered = true
            return
        }
        if hotKeys.register(.defaultPick) {
            hotKey = .defaultPick
            isHotKeyRegistered = true
            lastMessage = HotKey.saved() == nil
                ? nil
                : "上次设定的快捷键已被占用，已回退到默认 \(HotKey.defaultPick.displayString)"
            return
        }
        hotKey = hotKeys.current
        isHotKeyRegistered = false
        lastMessage = "全局快捷键注册失败，请改用菜单「开始取色」"
    }

    /// 换成用户刚录下的组合键；注册失败就退回原来那个可用组合，并说明原因
    func updateHotKey(_ newValue: HotKey) {
        guard newValue != hotKey else { return }
        let previous = hotKey
        guard hotKeys.register(newValue) else {
            _ = hotKeys.register(previous)   // 把原来能用的组合装回去
            isHotKeyRegistered = false
            setMessage("\(newValue.displayString) 注册失败：可能已被系统或其他应用占用，快捷键保持 \(previous.displayString)")
            return
        }
        hotKey = newValue
        isHotKeyRegistered = true
        newValue.save()
        setMessage("取色快捷键已改为 \(newValue.displayString)")
    }

    /// 恢复默认 ⌃⌥C
    func resetHotKey() {
        isRecordingHotKey = false
        guard hotKey != .defaultPick else {
            HotKey.clearSaved()
            setMessage("取色快捷键已是默认的 \(HotKey.defaultPick.displayString)")
            return
        }
        updateHotKey(.defaultPick)
        if hotKey == .defaultPick { HotKey.clearSaved() }
    }

    func beginRecordingHotKey() {
        isRecordingHotKey = true
        setMessage("请按下新的组合键：至少含 ⌃ / ⌥ / ⌘ 之一，Esc 取消，⌫ 恢复默认")
    }

    func cancelRecordingHotKey() {
        isRecordingHotKey = false
        setMessage("已取消更改快捷键，仍为 \(hotKeyDisplay)")
    }

    func applyRecordedHotKey(_ newValue: HotKey) {
        isRecordingHotKey = false
        updateHotKey(newValue)
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
