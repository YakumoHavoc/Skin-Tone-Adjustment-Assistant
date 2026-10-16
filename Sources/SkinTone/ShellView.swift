import SwiftUI

/// 应用的两个功能区：在同一个窗口的侧边栏里切换，而不是各开一个窗口。
enum AppSection: String, CaseIterable, Hashable, Identifiable {
    case skin
    case photoMatch

    var id: String { rawValue }

    var title: String {
        switch self {
        case .skin:       return "肤色取色"
        case .photoMatch: return "照片仿色"
        }
    }

    var icon: String {
        switch self {
        case .skin:       return "eyedropper.halffull"
        case .photoMatch: return "photo.on.rectangle.angled"
        }
    }

    var subtitle: String {
        switch self {
        case .skin:       return "屏幕取色 · 通道级调色建议"
        case .photoMatch: return "参考图对比 · 先影调后色调"
        }
    }

    /// 侧边栏底部的功能说明
    var detail: String {
        switch self {
        case .skin:
            return "按 ⌃⌥C 唤出取色放大镜，取一个皮肤颜色，直接得到 Photoshop「可选颜色」里每个滑块该动多少。"
        case .photoMatch:
            return "导入参考图与待仿色图（可点选，也可从 Finder 直接拖进卡片），比对整图的影调与色调，给出 Photoshop 里的具体操作。"
        }
    }
}

/// 应用外壳：左侧可隐藏侧边栏，右侧是按功能切换的内容区。
/// 两个功能区共用同一个窗口，切换时不销毁另一侧已导入的数据。
struct ShellView: View {

    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            if model.isSidebarVisible {
                SidebarPanel()
                Divider()
            }
            currentSection
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 1200, minHeight: 680)
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    model.isSidebarVisible.toggle()
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .help(model.isSidebarVisible ? "隐藏侧边栏" : "显示侧边栏")
            }
        }
    }

    @ViewBuilder
    private var currentSection: some View {
        switch model.section {
        case .skin:       ContentView()
        case .photoMatch: PhotoMatchView()
        }
    }
}

// MARK: - 侧边栏

struct SidebarPanel: View {

    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("功能")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.isSidebarVisible = false
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                        Text("隐藏").font(.system(size: 11))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("隐藏侧边栏（可用窗口左上角的侧边栏按钮恢复）")
            }
            .padding(.horizontal, 12)
            .padding(.top, 14)
            .padding(.bottom, 10)

            VStack(spacing: 6) {
                ForEach(AppSection.allCases) { section in
                    SidebarItem(section: section, isSelected: model.section == section) {
                        model.section = section
                    }
                }
            }
            .padding(.horizontal, 8)

            Divider().padding(.vertical, 12)

            ScrollView {
                Text(model.section.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                Image(systemName: "command").font(.system(size: 10, weight: .semibold))
                Text("取色快捷键 \(model.hotKeyDisplay)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
            }
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .frame(width: 194)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

/// 侧边栏里的一条功能区入口
struct SidebarItem: View {

    let section: AppSection
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: section.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(section.title).font(.system(size: 12, weight: .semibold))
                    Text(section.subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? Color.accentColor : Color.primary.opacity(0.001))
            )
            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        }
        .buttonStyle(.plain)
        .help(section.subtitle)
    }
}
