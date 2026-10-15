import SwiftUI

@main
struct SkinToneApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    init() {
        // 命令行模式：SkinTone --analyze "#RRGGBB"
        CLIRunner.runIfNeeded()
    }

    var body: some Scene {
        Window("肤色助手 · 取色与调色建议", id: "main") {
            ContentView()
                .environmentObject(model)
        }
        .defaultSize(width: 1120, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("开始取色（\(model.hotKeyDisplay)）") { model.startPick() }
                Divider()
            }
        }
    }
}
