import SwiftUI
import UniformTypeIdentifiers

/// 本功能区的主色（与取色、仿色、改名三块区分开）
private let psdAccent = Color(red: 0.20, green: 0.42, blue: 0.78)

/// JPG 转 PSD 界面：由 ShellView 在侧边栏第四个功能区里渲染。
/// 把一批 JPG 批量转成 PSD——解码后的像素原样写入（Raw / 无损 RLE），
/// 保留 ICC、DPI 与拍摄信息（EXIF / IPTC / XMP），可按 EXIF 无损摆正方向；
/// 先添加文件或文件夹，再点开始转换。
struct ToPSDView: View {

    @ObservedObject private var model = ToPSDModel.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                inputsSection
                outputSection
                optionsSection
                actionSection
                logSection
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 与原程序一致：拖到本区域任意位置都能加入待转列表
        .onDrop(of: [.fileURL], delegate: ToPSDDropDelegate(model: model))
    }

    // MARK: - 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "doc.text.image").foregroundColor(psdAccent)
                Text("JPG 转 PSD · 批量无损转换").font(.system(size: 15, weight: .semibold))
            }
            Text("把一批 JPG 批量转成 PSD，供 Photoshop 直接打开修图：解码后的像素**原样**写入（Raw 或无损 RLE，逐字节一致），不用 PSD 内部的 JPEG 压缩，不会二次损失画质；同时保留原图的 **ICC 色彩描述文件**、**DPI** 与**拍摄信息**（EXIF 相机/镜头/拍摄参数/GPS、IPTC、XMP 一并写进 PSD 的图像资源，在 Photoshop 的「文件 › 文件简介」里可查），默认按 EXIF 无损摆正方向（旋转 90°/180° 属像素搬移）。添加图片或文件夹（也能从 Finder 直接拖进来），转换在后台按 CPU 核数并行，随时可停。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 分组框

    private func box<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold))
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.04)))
    }

    // MARK: - 1. 待转换的 JPG

    private var inputsSection: some View {
        box("1. 待转换的 JPG") {
            HStack(alignment: .top, spacing: 10) {
                List(selection: $model.selection) {
                    ForEach(model.sources, id: \.self) { path in
                        Text(path)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(path)
                    }
                }
                .frame(height: 168)
                .overlay {
                    if model.isEmpty {
                        Text("把 JPG 图片或文件夹拖到这里")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .allowsHitTesting(false)
                    }
                }
                .overlay {
                    if model.isDropTargeted {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(psdAccent, lineWidth: 2)
                            .allowsHitTesting(false)
                    }
                }

                VStack(spacing: 6) {
                    Button("添加图片…") { model.pickFiles() }
                    Button("添加文件夹…") { model.pickFolders() }
                    Button("移除选中") { model.removeSelected() }
                        .disabled(model.selection.isEmpty)
                    Button("全部清空") { model.clearAll() }
                        .disabled(model.isEmpty)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 12))
                .frame(width: 122)
            }
        }
    }

    // MARK: - 2. 输出位置

    private var outputSection: some View {
        box("2. 输出位置") {
            VStack(alignment: .leading, spacing: 8) {
                PSDModeRadio(title: "与源文件同目录",
                             isOn: model.outputMode == .sameDirectory) {
                    model.setOutputMode(.sameDirectory)
                }
                HStack(spacing: 8) {
                    PSDModeRadio(title: "指定目录：", isOn: model.outputMode == .custom) {
                        model.setOutputMode(.custom)
                    }
                    TextField("选择一个输出文件夹", text: $model.outputDirectory)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .disabled(model.outputMode != .custom)
                    Button("选择…") { model.pickOutputDirectory() }
                        .font(.system(size: 12))
                        .disabled(model.outputMode != .custom)
                }
            }
        }
    }

    // MARK: - 3. 选项

    private var optionsSection: some View {
        box("3. 选项") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 16) {
                    Toggle("递归子文件夹", isOn: $model.recursive).toggleStyle(.checkbox)
                    Toggle("按 EXIF 摆正方向（无损）", isOn: $model.orientByEXIF).toggleStyle(.checkbox)
                    Toggle("覆盖已存在的 PSD", isOn: $model.overwrite).toggleStyle(.checkbox)
                }
                .font(.system(size: 12))

                HStack(spacing: 8) {
                    Text("PSD 压缩方式：").font(.system(size: 12))
                    Picker("", selection: $model.compression) {
                        ForEach(PSDCompression.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 320)
                }
            }
        }
    }

    // MARK: - 操作与进度

    private var actionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Button(model.isRunning ? "停止" : "开始转换") { model.startOrCancel() }
                    .font(.system(size: 12))
                    .frame(width: 118)
                    .disabled(model.isCancelling)

                ProgressView(value: model.progress, total: Double(max(1, model.progressTotal)))
                    .frame(maxWidth: .infinity)

                Button("打开输出文件夹") { model.openOutputFolder() }
                    .font(.system(size: 12))
                    .frame(width: 118)
                    .disabled(!model.canOpenOutput)
            }
            Text(model.status)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    // MARK: - 日志

    private var logSection: some View {
        box("日志") {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(model.log.indices, id: \.self) { index in
                            Text(model.log[index])
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .id(index)
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 6)
                }
                .frame(height: 150)
                .background(Color(nsColor: .textBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .onChange(of: model.log.count) { _ in
                    guard let last = model.log.indices.last else { return }
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
        }
    }
}

/// 单选按钮（SwiftUI 没有原生单选控件，这里用图标 + 按钮拼一个）
struct PSDModeRadio: View {

    let title: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: isOn ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 12))
                Text(title).font(.system(size: 12))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isOn ? AnyShapeStyle(psdAccent) : AnyShapeStyle(.primary))
    }
}

/// 把拖进来的文件 / 文件夹交给待转列表（与原程序 DropView 一致：整块区域都可接收）
struct ToPSDDropDelegate: DropDelegate {

    let model: ToPSDModel

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL])
    }

    func dropEntered(info: DropInfo) {
        model.isDropTargeted = true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        model.isDropTargeted = false
    }

    func performDrop(info: DropInfo) -> Bool {
        model.isDropTargeted = false
        let providers = info.itemProviders(for: [.fileURL])
        guard !providers.isEmpty else { return false }

        // 逐个异步取 URL，按拖入顺序归位，最后一次性加入列表
        // （一次加入才能和原程序一样汇总成「已添加 N 项」一条日志）
        let group = DispatchGroup()
        let lock = NSLock()
        var slots = [URL?](repeating: nil, count: providers.count)
        for (index, provider) in providers.enumerated() {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                guard let url = Self.fileURL(from: item) else { return }
                lock.lock()
                slots[index] = url
                lock.unlock()
            }
        }
        group.notify(queue: .main) {
            model.addSourceURLs(slots.compactMap { $0 })
        }
        return true
    }

    private static func fileURL(from item: Any?) -> URL? {
        let raw: URL?
        if let data = item as? Data {
            raw = URL(dataRepresentation: data, relativeTo: nil)
        } else if let url = item as? URL {
            raw = url
        } else if let string = item as? String {
            raw = URL(string: string)
        } else {
            raw = nil
        }
        guard let url = raw, url.isFileURL else { return nil }
        // Finder 拖来的是 `.file/id=` 文件引用 URL 时，先归一化成真实路径
        return (url as NSURL).filePathURL ?? url
    }
}
