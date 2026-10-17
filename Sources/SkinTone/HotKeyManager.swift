import Carbon.HIToolbox
import Foundation

/// 一个全局快捷键：按键码 + 修饰键（Carbon 的 controlKey / optionKey / shiftKey / cmdKey 位组合）
struct HotKey: Equatable {

    let keyCode: UInt32
    let modifiers: UInt32
    /// 展示用的按键名（"C"、"F5"、"Space"…）
    let keyLabel: String

    /// 默认：⌃⌥C
    static let defaultPick = HotKey(keyCode: UInt32(kVK_ANSI_C),
                                    modifiers: UInt32(controlKey | optionKey),
                                    keyLabel: "C")

    var displayString: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + keyLabel
    }

    /// 至少要有 ⌃ / ⌥ / ⌘ 之一：只有 ⇧ 或裸按键会跟日常打字冲突，不能拿来当全局快捷键
    var isUsable: Bool {
        modifiers & UInt32(controlKey | optionKey | cmdKey) != 0
    }

    // MARK: - 按键码 → 按键名

    /// 键名表只收常用的主键区按键、空格、方向键与 F1–F12
    static func label(forKeyCode keyCode: UInt32) -> String? {
        return keyLabels[Int(keyCode)]
    }

    private static let keyLabels: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
        kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
        kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
        kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
        kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
        kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[",
        kVK_ANSI_RightBracket: "]", kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'",
        kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/",
        kVK_ANSI_Backslash: "\\", kVK_ANSI_Grave: "`",
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12",
    ]

    // MARK: - 记住用户改过的组合键

    private static let keyCodeStorage = "hotKey.keyCode"
    private static let modifiersStorage = "hotKey.modifiers"
    private static let labelStorage = "hotKey.keyLabel"

    static func saved() -> HotKey? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: keyCodeStorage) != nil,
              defaults.object(forKey: modifiersStorage) != nil,
              let label = defaults.string(forKey: labelStorage) else { return nil }
        let hotKey = HotKey(keyCode: UInt32(defaults.integer(forKey: keyCodeStorage)),
                            modifiers: UInt32(defaults.integer(forKey: modifiersStorage)),
                            keyLabel: label)
        return hotKey.isUsable ? hotKey : nil
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(Int(keyCode), forKey: Self.keyCodeStorage)
        defaults.set(Int(modifiers), forKey: Self.modifiersStorage)
        defaults.set(keyLabel, forKey: Self.labelStorage)
    }

    static func clearSaved() {
        let defaults = UserDefaults.standard
        [keyCodeStorage, modifiersStorage, labelStorage].forEach { defaults.removeObject(forKey: $0) }
    }
}

/// 全局快捷键（Carbon RegisterEventHotKey），无需辅助功能权限，应用不在前台也能触发
final class HotKeyManager {

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    /// 快捷键是否注册成功
    private(set) var isRegistered = false

    /// 当前生效的组合键（注册失败时保持上一个可用的值）
    private(set) var current: HotKey = .defaultPick

    /// 快捷键被按下时回调（已切回主线程）
    var onFire: (() -> Void)?

    private let signature: FourCharCode = 0x534B544E // 'SKTN'

    var displayString: String { current.displayString }

    /// 注册新的组合键；成功才把 current 换成它
    @discardableResult
    func register(_ hotKey: HotKey) -> Bool {
        unregister()

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let installStatus = InstallEventHandler(GetApplicationEventTarget(),
                                                hotKeyCallback,
                                                1,
                                                &eventType,
                                                Unmanaged.passUnretained(self).toOpaque(),
                                                &handlerRef)
        guard installStatus == noErr else { return false }

        let hotKeyID = EventHotKeyID(signature: signature, id: 1)
        let status = RegisterEventHotKey(hotKey.keyCode, hotKey.modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        isRegistered = (status == noErr && hotKeyRef != nil)
        if isRegistered { current = hotKey }
        return isRegistered
    }

    func unregister() {
        isRegistered = false
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let handler = handlerRef {
            RemoveEventHandler(handler)
            handlerRef = nil
        }
    }

    fileprivate func fire() {
        DispatchQueue.main.async { [weak self] in
            self?.onFire?()
        }
    }

    deinit { unregister() }
}

private let hotKeyCallback: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(event,
                                   EventParamName(kEventParamDirectObject),
                                   EventParamType(typeEventHotKeyID),
                                   nil,
                                   MemoryLayout<EventHotKeyID>.size,
                                   nil,
                                   &hotKeyID)
    guard status == noErr, hotKeyID.signature == 0x534B544E else { return OSStatus(eventNotHandledErr) }
    let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
    manager.fire()
    return noErr
}
