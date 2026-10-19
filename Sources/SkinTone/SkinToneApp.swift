import SwiftUI

/// 程序入口：先把命令行用法拦下来（`--analyze` / `--to-psd` …），
/// 这样这些命令在 SwiftUI / AppKit 开始初始化之前就结束，终端里也不会带起界面。
/// 没有命令行参数时才启动图形界面。
@main
enum AppEntry {
    static func main() {
        CLIRunner.runIfNeeded()
        SkinToneApp.main()
    }
}

struct SkinToneApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

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
