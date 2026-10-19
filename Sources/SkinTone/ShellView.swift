import SwiftUI

/// 应用的功能区：在同一个窗口的侧边栏里切换，而不是各开一个窗口。
enum AppSection: String, CaseIterable, Hashable, Identifiable {
    case skin
    case photoMatch
    case folderRename
    case toPSD

    var id: String { rawValue }

    var title: String {
        switch self {
        case .skin:         return "肤色取色"
        case .photoMatch:   return "照片仿色"
        case .folderRename: return "文件名对应"
        case .toPSD:        return "JPG 转 PSD"
        }
    }

    var icon: String {
        switch self {
        case .skin:         return "eyedropper.halffull"
        case .photoMatch:   return "photo.on.rectangle.angled"
        case .folderRename: return "arrow.left.arrow.right"
        case .toPSD:        return "doc.text.image"
        }
    }

    var subtitle: String {
        switch self {
        case .skin:         return "屏幕取色 · 通道级调色建议"
        case .photoMatch:   return "参考图对比 · 先影调后色调"
        case .folderRename: return "文件夹比对 · 改名并补回拍摄信息"
        case .toPSD:        return "批量 JPG · 无损转 PSD · 保留拍摄信息"
        }
    }

    /// 侧边栏底部的功能说明
    var detail: String {
        switch self {
        case .skin:
            return "按 ⌃⌥C 唤出取色放大镜，取一个皮肤颜色，直接得到 Photoshop「可选颜色」里每个滑块该动多少。"
        case .photoMatch:
            return "导入参考图与待仿色图（可点选，也可从 Finder 直接拖进卡片），比对整图的影调与色调，给出 Photoshop 里的具体操作。"
        case .folderRename:
            return "左选原图文件夹、右选模特修脸返图的文件夹（可点选，也可从 Finder 拖进来）。按画面内容逐张比对，把返图那串英文数字的名字改回原图的名字，同时把原图的 Exif / IPTC / TIFF 拍摄信息补回返图（文件名本来就一致的照片不改名、照样补信息）；先预览再执行，可一键撤销。"
        case .toPSD:
            return "把一批 JPG 批量转成 PSD 供 Photoshop 修图：像素原样写入（Raw 或无损 RLE，逐字节一致），保留 ICC、DPI 与 Exif / IPTC / XMP 拍摄信息（相机、镜头、拍摄参数、日期、GPS、版权都写进 PSD 的图像资源，原图没有这一段就自动跳过），默认按 EXIF 无损摆正方向。添加图片或文件夹（可点选，也可从 Finder 拖进来），可选输出目录与覆盖策略，后台并行转换、随时可停。"
        }
    }
}

/// 应用外壳：左侧可隐藏侧边栏，右侧是按功能切换的内容区。
/// 各功能区共用同一个窗口，切换时不销毁另一侧已导入的数据。
struct ShellView: View {

    @EnvironmentObject private var model: AppModel

    var body: some View {
        // 注意：这里刻意不用窗口工具栏（`.toolbar`）。只要窗口带了工具栏，系统就会在
        // 工具栏上挂一个「图标和文本 / 仅图标」的右键菜单，对本应用没有意义。
        // 侧边栏的展开按钮因此改放在内容区左上角，收起时才出现。
        VStack(spacing: 0) {
            if !model.isSidebarVisible {
                HStack(spacing: 0) {
                    Button {
                        model.isSidebarVisible = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "sidebar.left")
                                .font(.system(size: 12, weight: .semibold))
                            Text("显示侧边栏").font(.system(size: 11))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("显示侧边栏")
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 8)
                Divider()
            }

            HStack(spacing: 0) {
                if model.isSidebarVisible {
                    SidebarPanel()
                    Divider()
                }
                currentSection
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 1200, minHeight: 680)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var currentSection: some View {
        switch model.section {
        case .skin:         ContentView()
        case .photoMatch:   PhotoMatchView()
        case .folderRename: FolderRenameView()
        case .toPSD:        ToPSDView()
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
                .help("隐藏侧边栏（收起后内容区左上角会出现「显示侧边栏」按钮）")
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
