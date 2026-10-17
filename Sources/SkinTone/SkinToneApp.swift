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
        Window("修图助手", id: "main") {
            ShellView()
                .environmentObject(model)
        }
        .defaultSize(width: 1200, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("开始取色（\(model.hotKeyDisplay)）") { model.startPick() }
                Divider()
            }
        }
    }
}
