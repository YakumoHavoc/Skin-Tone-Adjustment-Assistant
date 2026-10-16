import SwiftUI
import UniformTypeIdentifiers

/// 照片仿色界面：由 ShellView 在「照片仿色」功能区里渲染，与取色共用同一个窗口。
/// 导入参考图与待仿色图（点选或从 Finder 拖入）→ 先给影调建议，再给色调建议，都落到 Photoshop 的具体操作上。
struct PhotoMatchView: View {

    @ObservedObject private var model = PhotoMatchModel.shared

    private let compareAccent = Color(red: 0.35, green: 0.55, blue: 0.86)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                HStack(alignment: .top, spacing: 14) {
                    PhotoCard(role: .reference)
                    PhotoCard(role: .target)
                }

                if let plan = model.plan {
                    Divider()
                    planSection(plan)
                } else {
                    waitingHint
                }

                if !model.message.isEmpty {
                    Text(model.message)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
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
                Image(systemName: "photo.on.rectangle.angled").foregroundColor(compareAccent)
                Text("照片仿色 · 参考图对比").font(.system(size: 15, weight: .semibold))
                Spacer()
                if model.isReady {
                    Button("交换两图") { model.swap() }.font(.system(size: 12))
                }
            }
            Text("导入参考图与待仿色图（点卡片选择，或把图片从 Finder 直接拖进卡片），比对整图的影调与色调，给出 Photoshop 里的具体仿色操作。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var waitingHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("还差一张图").font(.system(size: 12, weight: .semibold))
            Text("两张图都导入后，这里会自动给出：五区影调对比 → 第一步仿影调（色阶 / 曲线）→ 第二步仿色调（色相/饱和度 / 色彩平衡）。每一条都会给出在 Photoshop 里的菜单路径与要拖的滑块。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.04)))
    }

    // MARK: - 建议区

    private func planSection(_ plan: MatchPlan) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(plan.headline)
                    .font(.system(size: 13, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(plan.orderNote)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("五区影调对比").font(.system(size: 13, weight: .semibold))
                HStack(spacing: 14) {
                    legendDot(color: compareAccent, text: "参考图")
                    legendDot(color: .orange, text: "待调图")
                }
                .font(.system(size: 11))
                ForEach(plan.toneZones.indices, id: \.self) { index in
                    ZoneCompareRow(zone: plan.toneZones[index],
                                   refColor: compareAccent, targetColor: .orange)
                }
            }

            section(title: "第一步 · 仿影调", subtitle: "先把两端的极端值收掉，再微调中间调；用「色阶」「曲线」的调整图层",
                    moves: plan.toneMoves, summary: plan.toneSummary)

            VStack(alignment: .leading, spacing: 8) {
                Text("色相带对比").font(.system(size: 13, weight: .semibold))
                Text("按「色相/饱和度」里可选的六个色相范围统计（各 60°），只统计有彩度的像素。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                ForEach(plan.colorBands.indices, id: \.self) { index in
                    BandCompareRow(band: plan.colorBands[index])
                }
            }

            section(title: "第二步 · 仿色调", subtitle: "对着参考图，哪里颜色不同就调哪里；用「色相/饱和度」「色彩平衡」的调整图层，叠在影调层之上",
                    moves: plan.colorMoves, summary: plan.colorSummary)
        }
    }

    private func section(title: String, subtitle: String, moves: [MatchMove], summary: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
            if moves.isEmpty {
                Text("（这一步无需调整）").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                ForEach(moves.indices, id: \.self) { index in
                    MoveRow(index: index + 1, move: moves[index], accent: compareAccent)
                }
            }
            Text(summary)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.04)))
    }

    private func legendDot(color: Color, text: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text)
        }
    }

    private var theory: [String] {
        [
            "仿色 = 仿影调关系 + 仿色调，顺序必须是「先影调，后色调」。",
            "参考图完全没有最暗部信息、集中在亮部和灰部 → 显得柔和；待调图是全影调、有最暗部 → 需要减少最暗部。",
            "只削两端会发灰，所以中间调要跟着压一点；最亮部过多也要削减，这样画面「柔和但不发灰」。",
            "颜色靠眼睛不好观察：把饱和度拉满放大色差，对着参考图哪里不同调哪里，最后把全图饱和度改回 0。",
            "命中不了的色相不在六个基准色里时，用十二色相环定位（如橙色 = 加红加黄 = 减青减蓝）。",
            "所有调整都走「调整图层」（图层面板底部第 4 个图标）：原图不被破坏、数值随时可回改，图层堆叠顺序就是执行顺序。"
        ]
    }
}

// MARK: - 导入卡片

struct PhotoCard: View {

    @ObservedObject private var model = PhotoMatchModel.shared
    let role: PhotoMatchModel.Role

    private let dropAccent = Color(red: 0.35, green: 0.55, blue: 0.86)

    private var photo: LoadedPhoto? { model.photo(role) }
    private var isDropTarget: Bool { model.dragTarget == role }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(role.title).font(.system(size: 13, weight: .semibold))
                Spacer()
                if photo != nil {
                    Button("清除") { model.clear(role) }.font(.system(size: 11))
                }
            }
            Text(role.roleHint)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let photo {
                Image(nsImage: photo.image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, minHeight: 160, maxHeight: 220)
                    .background(Color.black.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                Text(photo.name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                ToneHistogram(histogram: photo.stats.histogram)
                Text("直方图（明度，按峰值归一化）").font(.system(size: 9)).foregroundStyle(.secondary)

                statRow("影调", photo.stats.rangeBrief)
                statRow("分布", photo.stats.toneBrief)
                statRow("色调", photo.stats.mainHueText)

                HStack(spacing: 8) {
                    Button("更换\(role.title)") { model.choose(role) }
                        .font(.system(size: 12))
                    Text("或把新图片拖进本卡片直接替换")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            } else {
                Button {
                    model.choose(role)
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "plus.viewfinder").font(.system(size: 22))
                        Text(model.prompt(role))
                            .font(.system(size: 11))
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, minHeight: 200)
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
                Label("松手即可导入为\(role.title)", systemImage: "arrow.down.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(dropAccent)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isDropTarget ? dropAccent.opacity(0.12) : Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isDropTarget ? dropAccent : Color.black.opacity(0.06),
                        lineWidth: isDropTarget ? 2 : 1)
        )
        .onDrop(of: [.fileURL], delegate: PhotoDropDelegate(role: role, model: model))
    }

    private func statRow(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(key).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).frame(width: 28, alignment: .leading)
            Text(value).font(.system(size: 11, design: .monospaced)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 从 Finder 拖图片进卡片：校验是不是文件 URL，悬停时高亮，松手后交给模型载入。
/// 目标系统是 macOS 13，`dropDestination(for:)`（14+）用不了，所以走 DropDelegate。
struct PhotoDropDelegate: DropDelegate {

    let role: PhotoMatchModel.Role
    let model: PhotoMatchModel

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
        let providers = info.itemProviders(for: [.fileURL])
        guard !providers.isEmpty else { return false }
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let url = Self.fileURL(from: item) else { return }
                // 载入回调不在主线程，写 @Published 前必须切回主线程
                DispatchQueue.main.async { model.load(url, as: role) }
            }
        }
        return true
    }

    /// 拖拽项可能是 Data / NSURL / String，统一还原成文件 URL
    private static func fileURL(from item: Any?) -> URL? {
        if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
            return url.isFileURL ? url : nil
        }
        if let url = item as? URL { return url.isFileURL ? url : nil }
        if let string = item as? String, let url = URL(string: string) {
            return url.isFileURL ? url : nil
        }
        return nil
    }
}

// MARK: - 小组件

/// 明度直方图
struct ToneHistogram: View {
    let histogram: [Double]

    var body: some View {
        Canvas { context, size in
            guard !histogram.isEmpty else { return }
            let step = size.width / CGFloat(histogram.count)
            for (index, value) in histogram.enumerated() {
                let height = max(1, CGFloat(value) * size.height * 0.94)
                let rect = CGRect(x: CGFloat(index) * step,
                                  y: size.height - height,
                                  width: max(step, 0.8),
                                  height: height)
                context.fill(Path(rect), with: .color(Color.secondary.opacity(0.75)))
            }
        }
        .frame(height: 52)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// 五区占比对比：同一行里画参考图与待调图两条
struct ZoneCompareRow: View {
    let zone: ZoneCompare
    let refColor: Color
    let targetColor: Color

    private var judge: String {
        if zone.delta > 0.02 { return "待调图偏多 → 需削减" }
        if zone.delta < -0.02 { return "待调图偏少 → 需补回" }
        return "接近"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text("\(zone.name)").font(.system(size: 11, weight: .medium)).frame(width: 48, alignment: .leading)
                Text(zone.range).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).frame(width: 62, alignment: .leading)
                Text(judge).font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "参考 %.1f%% → 待调 %.1f%%", zone.refShare * 100, zone.targetShare * 100))
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
            ZoneBar(value: zone.refShare, color: refColor)
            ZoneBar(value: zone.targetShare, color: targetColor)
        }
        .padding(.vertical, 2)
    }
}

/// 单条占比条（固定 0–100% 比例，方便两图直接比长短）
struct ZoneBar: View {
    let value: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.07))
                RoundedRectangle(cornerRadius: 3)
                    .fill(color.opacity(0.85))
                    .frame(width: max(1, geo.size.width * CGFloat(min(value, 1))))
            }
        }
        .frame(height: 7)
    }
}

/// 单个色相带的对比行
struct BandCompareRow: View {
    let band: BandCompare

    var body: some View {
        HStack(spacing: 8) {
            Text(band.name).font(.system(size: 11, weight: .medium)).frame(width: 34, alignment: .leading)
            if band.isComparable {
                Text(String(format: "占比 %.0f%%→%.0f%%", band.refShare * 100, band.targetShare * 100))
                    .font(.system(size: 10, design: .monospaced)).frame(width: 108, alignment: .leading)
                Text(String(format: "色相 %.0f°→%.0f°", band.targetHue, band.refHue))
                    .font(.system(size: 10, design: .monospaced)).frame(width: 96, alignment: .leading)
                Text(String(format: "差值 %+.0f°", band.deltaHue))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(abs(band.deltaHue) >= 8 ? .primary : .secondary)
                    .frame(width: 74, alignment: .leading)
                Text(String(format: "饱和 %.0f%%→%.0f%%", band.targetSat * 100, band.refSat * 100))
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            } else {
                Text(String(format: "占比 %.0f%%→%.0f%%", band.refShare * 100, band.targetShare * 100))
                    .font(.system(size: 10, design: .monospaced))
                Text("一侧无像素，不做比对").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

/// 一条具体操作
struct MoveRow: View {
    let index: Int
    let move: MatchMove
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                Text("\(index)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                    .frame(width: 17, height: 17)
                    .background(Circle().fill(accent))
                Text(move.tool)
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(accent.opacity(0.15)))
                Text(move.text)
                    .font(.system(size: 12, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(accent)
                Text(move.path)
                    .font(.system(size: 10))
                    .foregroundStyle(accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 25)
            Text(move.why)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 25)
        }
        .padding(.vertical, 3)
    }
}
