import SwiftUI
import UniformTypeIdentifiers

/// 本功能区的主色（与照片仿色的蓝区分开）
private let renameAccent = Color(red: 0.16, green: 0.55, blue: 0.48)
/// 匹配判定的绿色
private let matchedGreen = Color(red: 0.16, green: 0.55, blue: 0.30)

/// 文件名对应界面：由 ShellView 在侧边栏第三个功能区里渲染。
/// 左选原图文件夹（名字正确）、右选模特修脸返图的文件夹（名字是乱码的一串英文数字），
/// 按图像内容比对，把返图改成左侧对应原图的名字。先预览再执行，可一键撤销。
struct FolderRenameView: View {

    @ObservedObject private var model = FolderRenameModel.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                HStack(alignment: .top, spacing: 14) {
                    FolderCard(role: .original)
                    FolderCard(role: .returned)
                }

                actionRow

                if model.isScanning {
                    statusCard("正在读取两个文件夹并逐张比对画面内容…")
                } else if !model.matches.isEmpty {
                    previewSection
                } else if model.hasBothFolders {
                    waitingHint
                }

                if let outcome = model.outcome {
                    Divider()
                    outcomeSection(outcome)
                }

                if !model.message.isEmpty {
                    Text(model.message)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()
                Text("原理要点").font(.system(size: 13, weight: .semibold))
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(theory.indices, id: \.self) { index in
                        Text("· \(theory[index])")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.left.arrow.right").foregroundColor(renameAccent)
                Text("文件名对应 · 返图按原图改名").font(.system(size: 15, weight: .semibold))
            }
            Text("左选原图文件夹、右选模特修脸返图的文件夹。两边照片按**画面内容**逐张比对（不看文件名），把返图那串英文数字的名字改回左侧对应原图的名字；同时把原图的 Exif / IPTC / TIFF 拍摄信息一并补回返图（修图软件导出时把这些剔掉了）——**文件名本来就和原图一致的照片不改名，但拍摄信息照样补**。全程只动返图文件夹，**补写信息是无损的、像素与压缩数据不变**，改完可一键撤销。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 操作行

    private var actionRow: some View {
        HStack(spacing: 12) {
            Button {
                model.scan()
            } label: {
                Label("扫描并预览匹配", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(!model.hasBothFolders || model.isBusy)

            Button {
                model.execute()
            } label: {
                Label("执行重命名并补回拍摄信息", systemImage: "checkmark.circle")
            }
            .disabled(model.plan.isEmpty || model.isBusy)

            Button {
                model.undo()
            } label: {
                Label("撤销本次重命名", systemImage: "arrow.uturn.backward")
            }
            .disabled(!model.canUndo || model.isBusy)

            Toggle(isOn: $model.includeUncertain) {
                Text("包含疑似匹配").font(.system(size: 11))
            }
            .toggleStyle(.checkbox)
            .disabled(model.isBusy)

            if model.isBusy { ProgressView().controlSize(.small) }
            Spacer(minLength: 0)
        }
    }

    private func statusCard(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.04)))
    }

    private var waitingHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("两个文件夹都选好后，点「扫描并预览匹配」")
                .font(.system(size: 12, weight: .semibold))
            Text("这里会列出每张返图命中的原图、两者的内容差异与判定结果。确认无误后再点「执行重命名并补回拍摄信息」：名字与目标不同的改名，本来就一致的不改名、只补拍摄信息；两种都会把原图的 Exif / IPTC / TIFF 无损写进返图（像素不动）。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.04)))
    }

    // MARK: - 匹配预览

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("匹配预览").font(.system(size: 13, weight: .semibold))
                Text(model.countsText).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text("将改名 \(model.plan.steps.count) 个")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(renameAccent)
                if !model.plan.metadataOnly.isEmpty {
                    Text("· 只补拍摄信息 \(model.plan.metadataOnly.count) 个")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            Text("「差异」= 128 位内容指纹里不同的位数，越小越像：≤ \(FolderRenameEngine.matchedThreshold) 判为匹配，"
                 + "≤ \(FolderRenameEngine.uncertainThreshold) 判为疑似（默认不改名，可勾选「包含疑似匹配」一起处理）。带底色的一行会被处理："
                 + "名字与目标不同的改名，**本来就一致的不改名、只补拍摄信息**；两种都会把对应原图的 Exif / IPTC / TIFF 补写进返图（无损，像素不动）。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 0) {
                Text("返图文件").frame(width: 210, alignment: .leading)
                Text("").frame(width: 26)
                Text("目标文件名（原图）").frame(width: 210, alignment: .leading)
                Text("差异").frame(width: 74, alignment: .leading)
                Text("判定").frame(width: 60, alignment: .leading)
                Spacer(minLength: 0)
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)

            Divider()

            ForEach(model.matches) { match in
                MatchRow(match: match, includeUncertain: model.includeUncertain)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.04)))
    }

    // MARK: - 执行结果

    private func outcomeSection(_ outcome: RenameOutcome) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("执行结果").font(.system(size: 13, weight: .semibold))
            Text("已改名 \(outcome.renamed.count) 个 · 跳过 \(outcome.skipped.count) 个 · 失败 \(outcome.failed.count) 个")
                .font(.system(size: 12, weight: .medium))
            Text("拍摄信息 Exif / IPTC / TIFF：已补写 \(outcome.metadataCopied.count + outcome.metadataOnlyCopied.count) 个"
                 + "（其中文件名未变、只补信息 \(outcome.metadataOnlyCopied.count) 个）"
                 + " · 原图没有该信息自动跳过 \(outcome.metadataSkipped.count) 个"
                 + " · 失败 \(outcome.metadataFailed.count) 个")
                .font(.system(size: 12, weight: .medium))

            ForEach(outcome.renamed.prefix(80)) { step in
                Text("\(step.oldName)  →  \(step.newName)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if outcome.renamed.count > 80 {
                Text("…另有 \(outcome.renamed.count - 80) 个已改名")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            ForEach(outcome.failed) { item in
                Text("失败：\(item.name) — \(item.reason)")
                    .font(.system(size: 11)).foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(outcome.metadataFailed) { item in
                Text("拍摄信息补写失败：\(item.name) — \(item.reason)")
                    .font(.system(size: 11)).foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(outcome.skipped.prefix(30)) { item in
                Text("跳过：\(item.name) — \(item.reason)")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.04)))
    }

    private var theory: [String] {
        [
            "返图是同一张照片修过脸的版本，文件名却被重命名成乱码，所以只能按「画面内容」找对应关系。",
            "内容指纹用的是感知哈希：把图缩到 9×8 / 8×9 的明暗格，只记「哪边更亮」，得到 128 位编码。",
            "它只保留明暗的相对关系，所以修脸、调色、加锐、重新压缩都不会改变它；而内容不同的照片会差几十位。",
            "每张返图去和所有原图比，取差异最小的那张；差异 ≤ \(FolderRenameEngine.matchedThreshold) 位算匹配。",
            "原图里有两张都很像（与次优的差距 < \(FolderRenameEngine.ambiguityGap)），或构图比例差别大（可能被裁过），都会降级成「疑似」，不自动改名。",
            "同一张原图被两张返图同时命中时，只保留差异最小的那条，另一条降级为「疑似」，避免改错。",
            "改名一律先用临时名错开，再落到目标名，避免两个文件互相占用名字；只有目标名已被本文件夹里别的文件占用时才会跳过并计入报告。",
            "名字本来就和原图一致的照片不需要改名（硬改反而会互相占名），但仍会把对应原图的 Exif / IPTC / TIFF 补上——修图软件剔掉的正是这部分，预览里会单列「只补拍摄信息」的条数。",
            "改名之后，会把对应原图的 Exif / IPTC / TIFF 拍摄信息补写进返图——修图软件导出时通常会把这些剔掉，这里从原图取回来补上。",
            "补写走的是 ImageIO 的无损通道（CGImageDestinationCopyImageSource），只重写元数据段，返图的像素与压缩数据逐字节不变，画质不掉。",
            "原图本身没有这部分信息时自动跳过；返图被裁过或换了尺寸时，原图的像素尺寸与旋转方向标记不会被照抄，避免元数据与实际画面矛盾。",
            "全程只写返图文件夹；执行过的每一条都被记下来，「撤销本次重命名」按逆序还原文件名（已补上的拍摄信息会保留在文件里）。"
        ]
    }
}

// MARK: - 文件夹卡片

struct FolderCard: View {

    @ObservedObject private var model = FolderRenameModel.shared
    let role: FolderRenameModel.Role

    private var folder: URL? { model.folder(role) }
    private var scan: FolderScan? { model.scanResult(role) }
    private var isDropTarget: Bool { model.dragTarget == role }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(role.shortTitle).font(.system(size: 13, weight: .semibold))
                Spacer()
                if folder != nil {
                    Button("清除") { model.clear(role) }.font(.system(size: 11))
                }
            }
            Text(role.hint)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let folder {
                VStack(alignment: .leading, spacing: 4) {
                    Image(systemName: "folder.fill").font(.system(size: 20)).foregroundColor(renameAccent)
                    Text(folder.lastPathComponent)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1).truncationMode(.middle)
                    Text(folder.path)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2).truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12).padding(.horizontal, 10)
                .background(Color.black.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                if let scan {
                    statRow("可比对图像", "\(scan.files.count) 张")
                    if scan.skipped > 0 { statRow("未参与", "\(scan.skipped) 个非图像文件") }
                } else if model.isScanning {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("正在读取…").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 8) {
                    Button("更换文件夹") { model.choose(role) }.font(.system(size: 12))
                    Text("或把文件夹从 Finder 拖到本卡片")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            } else {
                Button {
                    model.choose(role)
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "folder.badge.plus").font(.system(size: 22))
                        Text("点这里选择\(role.shortTitle)\n也可把文件夹从 Finder 直接拖进来")
                            .font(.system(size: 11))
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, minHeight: 150)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(style: StrokeStyle(lineWidth: 1, dash: [5]))
                        .foregroundColor(Color.secondary.opacity(0.5))
                )
            }

            if isDropTarget {
                Label("松手即可选择为\(role.shortTitle)", systemImage: "arrow.down.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(renameAccent)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isDropTarget ? renameAccent.opacity(0.12) : Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isDropTarget ? renameAccent : Color.black.opacity(0.06),
                        lineWidth: isDropTarget ? 2 : 1)
        )
        .onDrop(of: [.fileURL], delegate: FolderDropDelegate(role: role, model: model))
    }

    private func statRow(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(key).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
            Text(value).font(.system(size: 11, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 从 Finder 拖文件夹进卡片：悬停时高亮，松手后交给模型校验并设置。
/// 目标系统是 macOS 13，`dropDestination(for:)`（14+）用不了，所以走 DropDelegate。
struct FolderDropDelegate: DropDelegate {

    let role: FolderRenameModel.Role
    let model: FolderRenameModel

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.fileURL])
    }

    func dropEntered(info: DropInfo) {
        model.dragTarget = role
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        if model.dragTarget == role { model.dragTarget = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        model.dragTarget = nil
        // 一次只取第一个：多份拖拽会串行叠 N 次扫描
        guard let provider = info.itemProviders(for: [.fileURL]).first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            guard let url = Self.fileURL(from: item) else { return }
            // 回调不在主线程，写 @Published 前必须切回主线程
            DispatchQueue.main.async { model.setFolder(url, role: role) }
        }
        return true
    }

    /// 拖拽项可能是 Data / NSURL / String，统一还原成文件 URL
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

// MARK: - 匹配行

/// 一行匹配结果：返图 → 目标名、差异、判定；会被改名的一行带底色
struct MatchRow: View {

    let match: RenameMatch
    let includeUncertain: Bool

    private var planned: Bool {
        match.status == .matched || (includeUncertain && match.status == .uncertain)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 0) {
                Text(match.returned.name)
                    .frame(width: 210, alignment: .leading)
                    .lineLimit(1).truncationMode(.middle)
                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26)
                Text(match.targetName ?? "—")
                    .frame(width: 210, alignment: .leading)
                    .lineLimit(1).truncationMode(.middle)
                Text("\(match.distance)/128")
                    .frame(width: 74, alignment: .leading)
                    .foregroundStyle(match.status == .matched ? .primary : .secondary)
                StatusBadge(status: match.status)
                    .frame(width: 60, alignment: .leading)
                Spacer(minLength: 0)
            }
            .font(.system(size: 11, design: .monospaced))

            if !match.note.isEmpty {
                Text(match.note)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(planned ? renameAccent.opacity(0.10) : Color.clear)
        )
    }
}

/// 匹配 / 疑似 / 未匹配 的小标签
struct StatusBadge: View {

    let status: MatchStatus

    private var color: Color {
        switch status {
        case .matched:   return matchedGreen
        case .uncertain: return .orange
        case .unmatched: return .secondary
        }
    }

    var body: some View {
        Text(status.rawValue)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundColor(color)
    }
}
