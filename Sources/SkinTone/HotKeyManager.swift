import Carbon.HIToolbox
import Foundation

/// 全局快捷键（Carbon RegisterEventHotKey），无需辅助功能权限，应用不在前台也能触发
final class HotKeyManager {

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    /// 快捷键是否注册成功
    private(set) var isRegistered = false

    /// 快捷键被按下时回调（已切回主线程）
    var onFire: (() -> Void)?

    private let signature: FourCharCode = 0x534B544E // 'SKTN'
    private var keyCode: UInt32 = UInt32(kVK_ANSI_C)
    private var modifiers: UInt32 = UInt32(controlKey | optionKey)

    var displayString: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        s += "C"
        return s
    }

    @discardableResult
    func register(keyCode: UInt32 = UInt32(kVK_ANSI_C),
                  modifiers: UInt32 = UInt32(controlKey | optionKey)) -> Bool {
        unregister()
        self.keyCode = keyCode
        self.modifiers = modifiers

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
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        isRegistered = (status == noErr && hotKeyRef != nil)
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
