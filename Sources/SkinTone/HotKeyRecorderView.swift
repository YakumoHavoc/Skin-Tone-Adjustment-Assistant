import AppKit
import Carbon.HIToolbox
import SwiftUI

/// 录入快捷键的小方框：把焦点抢过来，直接听 keyDown 事件。
/// 只有带 ⌃ / ⌥ / ⌘ 的组合才会被接受；Esc 取消，⌫ 恢复默认。
struct KeyCaptureField: NSViewRepresentable {

    /// 录到一个可用的组合键
    let onCapture: (HotKey) -> Void
    /// 按下 Esc
    let onCancel: () -> Void
    /// 按下 ⌫
    let onReset: () -> Void

    func makeNSView(context: Context) -> KeyCaptureView {
        let view = KeyCaptureView()
        view.onCapture = onCapture
        view.onCancel = onCancel
        view.onReset = onReset
        return view
    }

    func updateNSView(_ nsView: KeyCaptureView, context: Context) {
        nsView.onCapture = onCapture
        nsView.onCancel = onCancel
        nsView.onReset = onReset
    }
}

/// 透明、只负责接收键盘事件的视图；外观交给外面那层 SwiftUI 边框
final class KeyCaptureView: NSView {

    var onCapture: ((HotKey) -> Void)?
    var onCancel: (() -> Void)?
    var onReset: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // 等视图挂进窗口后再抢焦点，否则 window 还是 nil
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        let code = UInt32(event.keyCode)

        switch Int(code) {
        case kVK_Escape:
            onCancel?()
            return
        case kVK_Delete, kVK_ForwardDelete:
            onReset?()
            return
        default:
            break
        }

        guard let label = HotKey.label(forKeyCode: code) else {
            NSSound.beep()   // 这个键不支持（比如音量键、输入法键）
            return
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option)  { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift)   { modifiers |= UInt32(shiftKey) }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }

        let hotKey = HotKey(keyCode: code, modifiers: modifiers, keyLabel: label)
        guard hotKey.isUsable else {
            NSSound.beep()   // 必须带 ⌃ / ⌥ / ⌘ 之一
            return
        }
        onCapture?(hotKey)
    }
}
