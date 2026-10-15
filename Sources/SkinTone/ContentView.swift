import AppKit
import SwiftUI

/// 主界面：左「取色与数值」、中「色相环」、右「调整建议」
struct ContentView: View {

    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            ScrollView { PickerPanel().padding(16) }.frame(width: 280)
            Divider()
            WheelPanel().frame(maxWidth: .infinity)
            Divider()
            ScrollView { AdvicePanel().padding(16) }.frame(width: 380)
        }
        .frame(minWidth: 1040, minHeight: 660)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - 左栏：取色与数值

struct PickerPanel: View {

    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("当前取色").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)

            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(model.current?.source.swiftUIColor ?? Color(nsColor: .quaternaryLabelColor))
                    .frame(height: 120)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.black.opacity(0.12), lineWidth: 1)
                    )
                if let current = model.current {
                    VStack(alignment: .leading, spacing: 0) {
                        skinBadge(current.classification)
                        Spacer(minLength: 0)
                        Text(current.source.hexString)
                            .font(.system(size: 15, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white)
                            .padding(6)
                            .background(Color.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                }
            }

            // 手动覆盖自动判定：极端环境（有色光源、混合光、强滤镜）下自动分类会认错
            VStack(alignment: .leading, spacing: 6) {
                Text("判定方式").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Picker("", selection: kindBinding) {
                    Text("自动").tag(SkinKind?.none)
                    Text("肤色").tag(SkinKind?.some(.skin))
                    Text("非肤色").tag(SkinKind?.some(.nonSkin))
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(kindHint)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                model.startPick()
            } label: {
                HStack {
                    Image(systemName: "eyedropper.halffull")
                    Text("开始取色")
                    Spacer()
                    Text(model.hotKeyDisplay).font(.system(size: 11, weight: .semibold, design: .monospaced))
                }
                .padding(.vertical, 7)
                .padding(.horizontal, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isPicking)

            Text(model.isPicking
                 ? "放大镜已启动：移动鼠标定位，单击取色，Esc 取消"
                 : "全局快捷键在任意应用上都能取色，无需屏幕录制权限")
                .font(.system(size: 11))
                .foregroundStyle(model.isPicking ? .primary : .secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                TextField("手动输入 #RRGGBB", text: $model.hexInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .onSubmit { model.applyHexInput() }
                Button("应用") { model.applyHexInput() }
                    .font(.system(size: 12))
            }

            Divider()

            if let current = model.current {
                valueRow("分类", current.classification.label, hint: current.classification.reason)
                valueRow("三原色", current.source.rgb255String)
                ForEach(current.metrics, id: \.name) { metric in
                    valueRow(metric.name, metric.value, hint: metric.hint)
                }
                Divider()
                if current.classification.isSkin {
                    Text("目标肤色").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(current.target.swiftUIColor)
                            .frame(width: 58, height: 40)
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.black.opacity(0.12), lineWidth: 1))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(current.target.hexString)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            Text("H \(current.targetHSB.hueText)  S \(current.targetHSB.saturationText)  B \(current.targetHSB.brightnessText)")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text("非肤色：不给目标肤色。要把它当皮肤还原，把「判定方式」切到「肤色」。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("尚未取色。按 \(model.hotKeyDisplay) 或在画面中取一个脸颊颜色，色盘会标出它的位置并给出调色建议。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !model.history.isEmpty {
                Divider()
                Text("历史记录").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 8), spacing: 6) {
                    ForEach(model.history.indices, id: \.self) { index in
                        let item = model.history[index]
                        Button {
                            model.select(item)
                        } label: {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(item.source.swiftUIColor)
                                .frame(height: 24)
                                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .stroke(model.current?.source == item.source
                                            ? Color.accentColor : Color.black.opacity(0.12),
                                            lineWidth: model.current?.source == item.source ? 2 : 1))
                        }
                        .buttonStyle(.plain)
                        .help(item.currentSummary)
                    }
                }
            }
        }
    }

    /// 「自动 / 肤色 / 非肤色」三态绑定
    private var kindBinding: Binding<SkinKind?> {
        Binding(get: { model.manualKind }, set: { model.setManualKind($0) })
    }

    /// 判定方式的说明文字
    private var kindHint: String {
        guard let current = model.current else {
            return "自动判定取色点是肤色还是非肤色；极端环境下可手动指定。"
        }
        let auto = ColorEngine.classifySkin(current.source)
        switch (model.manualKind, auto.kind) {
        case (.none, _):
            return "自动判定：\(auto.label)。有色光源、混合光、强滤镜下自动会认错，可手动指定。"
        case (.skin, .nonSkin):
            return "自动认为它是\(auto.label)，已按「肤色」处理 → 右侧给出极端环境肤色还原建议。"
        case (.nonSkin, .skin):
            return "自动认为它是\(auto.label)，已按「非肤色」处理 → 只保留去灰建议。"
        default:
            return "手动与自动一致：\(auto.label)。"
        }
    }

    /// 取色点的「肤色 / 非肤色」分类标记
    private func skinBadge(_ classification: SkinClassification) -> some View {
        HStack(spacing: 5) {
            Image(systemName: classification.isSkin ? "person.fill" : "paintpalette.fill")
                .font(.system(size: 10, weight: .semibold))
            Text(classification.label).font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Color(hexString: classification.kind.accentHex) ?? .gray, in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.35), lineWidth: 1))
        .help(classification.reason)
    }

    private func valueRow(_ name: String, _ value: String, hint: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(name).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 62, alignment: .leading)
            Text(value).font(.system(size: 12, weight: .semibold, design: .monospaced))
            Spacer(minLength: 0)
        }
        .help(hint ?? "")
    }
}

// MARK: - 中栏：色相环

struct WheelPanel: View {

    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text("色相环").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                if let current = model.current {
                    HStack(spacing: 8) {
                        Text(current.classification.label)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Color(hexString: current.classification.kind.accentHex) ?? .gray, in: Capsule())
                            .help(current.classification.reason)
                        // 偏红 / 偏橙 / 偏黄偏冷 是肤色专用结论，非肤色时不再显示
                        if current.classification.isSkin {
                            Text(current.bias.rawValue)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(Color(hexString: current.bias.accentHex) ?? .gray, in: Capsule())
                        }
                    }
                }
            }

            ColorWheelView(current: model.current?.sourceHSB,
                            target: model.current.flatMap { $0.classification.isSkin ? $0.targetHSB : nil },
                            primaryLabel: model.current?.degreying.familyName,
                            complementLabel: model.current?.degreying.complementPair.joined(separator: "+"))
                .padding(.horizontal, 8)

            HStack(spacing: 16) {
                legendItem(filled: true, dashed: false, text: "取色点")
                legendItem(filled: false, dashed: false, text: "互补点（要去掉）")
                legendItem(filled: false, dashed: true, text: "目标肤色")
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white.opacity(0.25))
                        .frame(width: 14, height: 10)
                        .overlay(RoundedRectangle(cornerRadius: 2)
                            .stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: 1, dash: [2, 2])))
                    Text("健康肤色区间").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
            }

            Text("角度 = 色相（红 0° / 黄 60° / 绿 120° / 青 180° / 蓝 240° / 洋红 300°），半径 = 饱和度，越靠外颜色越浓。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
    }

    private func legendItem(filled: Bool, dashed: Bool, text: String) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(filled ? Color.white : Color.clear)
                .frame(width: 11, height: 11)
                .overlay(
                    Circle().stroke(Color.white, style: StrokeStyle(lineWidth: 1.6, dash: dashed ? [2, 2] : []))
                )
            Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

// MARK: - 右栏：调整建议

struct AdvicePanel: View {

    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("调整建议").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)

            if let current = model.current {
                let accent = Color(hexString: current.bias.accentHex) ?? .gray

                card(title: "诊断", accent: accent) {
                    VStack(alignment: .leading, spacing: 6) {
                        badge(current.classification.label,
                              tint: Color(hexString: current.classification.kind.accentHex) ?? .gray)
                        Text(current.classification.reason)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(current.diagnosis)
                            .font(.system(size: 12))
                            .fixedSize(horizontal: false, vertical: true)
                        if !current.classification.isSkin {
                            Text(current.steps.isEmpty
                                 ? "该点按非肤色处理：肤色类调整不适用，只按颜色本身处理——见「去灰建议」。"
                                 : "该点判定为非肤色，下面的肤色步骤只作参考；若想让这个颜色本身更干净，看「去灰建议」。")
                                .font(.system(size: 11))
                                .foregroundStyle(Color(hexString: "#B4643C") ?? .orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                degreyingCard(current)

                ForEach(current.steps.indices, id: \.self) { index in
                    let step = current.steps[index]
                    card(title: "第 \(index + 1) 步 · 通道「\(step.channel)」", accent: accent) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(step.headline).font(.system(size: 12, weight: .semibold))
                            ForEach(step.moves.indices, id: \.self) { moveIndex in
                                let move = step.moves[moveIndex]
                                HStack(alignment: .top, spacing: 8) {
                                    Text(move.text)
                                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 8).padding(.vertical, 3)
                                        .background(accent, in: RoundedRectangle(cornerRadius: 5))
                                        .fixedSize()
                                    Text(move.why)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .help(move.why)
                            }
                            Text(step.reason)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                card(title: "原理要点", accent: .gray) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(current.theory.indices, id: \.self) { index in
                            HStack(alignment: .top, spacing: 6) {
                                Text("·")
                                Text(current.theory[index]).fixedSize(horizontal: false, vertical: true)
                            }
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                card(title: "使用方式", accent: .gray) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(["1. 按 \(model.hotKeyDisplay) 唤出取色放大镜，在皮肤中性区域（如颧骨）单击取色。",
                                 "2. 取色点会自动标记为「肤色」或「非肤色」；色盘会标出它在色相环上的位置，并显示它的互补色与目标肤色。",
                                 "3. 右侧按「偏红 / 偏橙 / 偏灰偏脏 / 偏黄偏冷」给出通道级调整量，可直接照着在「可选颜色」里调。"],
                                id: \.self) { line in
                            Text(line).font(.system(size: 11)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            if let message = model.lastMessage {
                Text(message).font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
    }

    /// 去灰卡片：互补色相混成灰，减掉补色主色即回干净
    private func degreyingCard(_ analysis: Analysis) -> some View {
        let advice = analysis.degreying
        let tint = Color(hexString: "#6E6259") ?? .gray
        return card(title: "去灰建议 · 减补色 = 加主色", accent: tint) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    badge("主色 \(advice.primaryPair.joined(separator: " + "))",
                          tint: Color(hexString: "#3E7FA8") ?? .blue)
                    badge("减 \(advice.complementPair.joined(separator: " + "))", tint: tint)
                    Spacer()
                }
                HStack(spacing: 8) {
                    Text(advice.familyDetail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Text("灰化 \(advice.graynessText)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(advice.isClean ? .secondary : .primary)
                }
                ForEach(advice.moves.indices, id: \.self) { index in
                    let move = advice.moves[index]
                    HStack(alignment: .top, spacing: 8) {
                        Text(move.text)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(tint, in: RoundedRectangle(cornerRadius: 5))
                            .fixedSize()
                        Text(move.why)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .help(move.why)
                }
                Text(advice.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(advice.examples.indices, id: \.self) { index in
                    Text(advice.examples[index])
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let note = directionNote(analysis) {
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(Color(hexString: "#B4643C") ?? .orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// 去灰（保留当前色相）与肤色建议（改变色偏）方向相反时点明
    private func directionNote(_ analysis: Analysis) -> String? {
        let advice = analysis.degreying
        if analysis.bias == .extreme {
            return "方向提示：去灰建议是「保留 \(advice.familyName) 这个颜色、只去掉灰」，"
                + "肤色还原是「把环境染上的 \(advice.familyName) 洗掉」，两者方向正好相反。"
                + "要还原肤色就按下面「第 1 步 · 洗掉环境染上的颜色」走，只想让这个颜色本身更纯就按去灰。"
        }
        // 只有真的给出肤色步骤时才谈方向冲突
        guard analysis.classification.isSkin,
              advice.grayness >= 0.10,
              analysis.bias == .tooRed || analysis.bias == .tooOrange else { return nil }
        let mood = analysis.bias == .tooRed ? "红味" : "橙味"
        return "方向提示：肤色步骤要求削掉\(mood)（加青加蓝），去灰要求减青减蓝，两者方向相反。"
            + "因为目的不同——去灰是「保留当前色相、只去灰」，肤色建议是「改变色偏」。"
            + "想让皮肤干净就按肤色步骤，想让这个颜色本身更纯就按去灰。"
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(tint.opacity(0.9), in: Capsule())
    }

    private func card<Content: View>(title: String, accent: Color, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2).fill(accent).frame(width: 3, height: 12)
                Text(title).font(.system(size: 12, weight: .semibold))
            }
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.black.opacity(0.06), lineWidth: 1))
    }
}

extension Color {
    init?(hexString: String) {
        guard let rgb = RGBColor(hex: hexString) else { return nil }
        self = rgb.swiftUIColor
    }
}
