import Foundation

/// 文件夹里的一个图像文件：真实文件名 + 画面指纹
struct FolderFile: Hashable {
    let name: String
    let url: URL
    let fingerprint: PhotoFingerprint
}

/// 扫描一个文件夹得到的结果
struct FolderScan {
    let folder: URL
    let files: [FolderFile]
    /// 读不出指纹的文件数（非图像格式、或解码失败），不参与比对
    let skipped: Int
}

/// 一条匹配结果的判定
enum MatchStatus: String {
    case matched   = "匹配"
    case uncertain = "疑似"
    case unmatched = "未匹配"
}

/// 一条「返图 → 原图」的匹配结果
struct RenameMatch: Identifiable {

    /// 用返图文件的真实路径做 id，重新扫描后行不会错位
    var id: String { returned.url.path }

    /// 要被改名的返图文件
    let returned: FolderFile
    /// 命中的原图；未匹配时给的是差异最小的那张，仅供查看
    let original: FolderFile?
    /// 与命中原图的差异（0…128）
    let distance: Int
    /// 次优差异，用来发现「原图里有两张都像」
    let runnerUp: Int?
    let status: MatchStatus
    /// 需要交代的原因（歧义、跳过等）
    let note: String

    /// 改名后的目标文件名 = 原图的文件名
    var targetName: String? { original?.name }

    func with(status: MatchStatus, note: String) -> RenameMatch {
        RenameMatch(returned: returned, original: original, distance: distance,
                    runnerUp: runnerUp, status: status, note: note)
    }
}

/// 一次改名操作
struct RenameStep: Identifiable {
    var id: String { from.path }
    let from: URL
    let to: URL
    /// 拍摄信息（Exif / IPTC / TIFF）从哪里取；改名后从这张原图补到返图上
    let metadataSource: URL?
    var oldName: String { from.lastPathComponent }
    var newName: String { to.lastPathComponent }
}

/// 被跳过 / 失败的条目
struct RenameSkip: Identifiable {
    var id: String { name }
    let name: String
    let reason: String
}

/// 文件名本来就和原图一致、不需要改名的返图：只需把拍摄信息补上
struct MetadataTask: Identifiable {
    var id: String { target.path }
    /// 要补写信息的返图文件
    let target: URL
    /// 拍摄信息从哪张原图取
    let source: URL
}

/// 改名计划：先给用户看过，确认后才执行
struct RenamePlan {
    var steps: [RenameStep] = []
    /// 文件名已经和原图一致、只补写拍摄信息、不改名的那些
    var metadataOnly: [MetadataTask] = []
    var skips: [RenameSkip] = []
    var isEmpty: Bool { steps.isEmpty && metadataOnly.isEmpty }
}

/// 一次执行的结果
struct RenameOutcome {
    var renamed: [RenameStep] = []
    var skipped: [RenameSkip] = []
    var failed: [RenameSkip] = []
    /// 改名后成功补上原图拍摄信息的返图文件名
    var metadataCopied: [String] = []
    /// 文件名本来就一致、没改名、只补上拍摄信息的返图文件名
    var metadataOnlyCopied: [String] = []
    /// 原图本来就没有 Exif / IPTC / TIFF，自动跳过的返图文件名
    var metadataSkipped: [String] = []
    /// 补写拍摄信息失败的返图
    var metadataFailed: [RenameSkip] = []
}

/// 文件名对应：比对两个文件夹里的图像内容，把返图改回原图的名字。
/// 这里全是纯计算 + 文件系统操作、不依赖任何 UI，所以命令行模式也能直接用同一套逻辑。
enum FolderRenameEngine {

    // MARK: - 判定阈值

    /// 差异 ≤ 24（共 128 位）视为匹配
    static let matchedThreshold = 24
    /// 差异 ≤ 44 视为疑似：默认不改名，留给人工确认
    static let uncertainThreshold = 44
    /// 与次优的差距小于 6 → 原图里有两张都像，降级为疑似
    static let ambiguityGap = 6
    /// 宽高比相差超过 6% → 可能被裁过，降级为疑似
    static let aspectTolerance = 0.06

    // MARK: - 扫描

    /// 列出一个文件夹里的图像并算出指纹，顺序按文件名的自然序（DSC2 排在 DSC10 前面）
    static func scan(folder: URL) -> FolderScan {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey]
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])) ?? []

        var files: [FolderFile] = []
        var skipped = 0
        for url in entries.sorted(by: {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }) {
            let values = try? url.resourceValues(forKeys: keys)
            guard values?.isRegularFile == true else { continue }   // 子文件夹不参与
            guard PhotoFingerprintMaker.isImageFile(url),
                  let fingerprint = PhotoFingerprintMaker.fingerprint(url: url) else {
                skipped += 1
                continue
            }
            files.append(FolderFile(name: url.lastPathComponent, url: url, fingerprint: fingerprint))
        }
        return FolderScan(folder: folder, files: files, skipped: skipped)
    }

    // MARK: - 匹配

    /// 拿每张返图去和所有原图比对，取差异最小的一张
    static func match(originals: [FolderFile], returned: [FolderFile]) -> [RenameMatch] {
        var results: [RenameMatch] = []

        for file in returned {
            var best: FolderFile?
            var bestDistance = Int.max
            var secondDistance: Int?

            for original in originals {
                let distance = file.fingerprint.distance(to: original.fingerprint)
                if distance < bestDistance {
                    if best != nil { secondDistance = bestDistance }
                    bestDistance = distance
                    best = original
                } else if secondDistance == nil || distance < secondDistance! {
                    secondDistance = distance
                }
            }

            guard let original = best else {
                results.append(RenameMatch(returned: file, original: nil, distance: 128,
                                           runnerUp: nil, status: .unmatched,
                                           note: "原图文件夹里没有可比对的图像"))
                continue
            }

            var status: MatchStatus
            if bestDistance <= matchedThreshold { status = .matched }
            else if bestDistance <= uncertainThreshold { status = .uncertain }
            else { status = .unmatched }

            var notes: [String] = []
            if status == .matched {
                if let secondDistance, secondDistance - bestDistance < ambiguityGap {
                    status = .uncertain
                    notes.append("原图里有两张都很接近（差异 \(secondDistance)），需要人工确认")
                } else if file.fingerprint.aspectDelta(to: original.fingerprint) > aspectTolerance {
                    status = .uncertain
                    notes.append("构图比例与原图不同，可能是裁切过的版本")
                }
            }
            if status == .unmatched {
                notes.append("与最接近的原图也差了 \(bestDistance) 位，判为不同照片")
            }

            results.append(RenameMatch(returned: file, original: original, distance: bestDistance,
                                       runnerUp: secondDistance, status: status,
                                       note: notes.joined(separator: "；")))
        }

        return resolveConflicts(results)
    }

    /// 同一张原图被多个返图命中时，只留差异最小的那条，其余降级为疑似
    private static func resolveConflicts(_ input: [RenameMatch]) -> [RenameMatch] {
        let conflictNote = "同一张原图已被另一个返图文件以更小的差异命中"
        var results = input
        var bestForOriginal: [String: Int] = [:]

        for index in 0..<results.count {
            let candidate = results[index]
            guard let original = candidate.original, candidate.status != .unmatched else { continue }
            let key = original.url.path
            guard let holder = bestForOriginal[key] else {
                bestForOriginal[key] = index
                continue
            }
            // 保住差异更小的那条，另一条降级
            guard candidate.distance < results[holder].distance else {
                results[index] = candidate.with(status: .uncertain, note: appended(candidate.note, conflictNote))
                continue
            }
            let loser = results[holder]
            bestForOriginal[key] = index
            results[holder] = loser.with(status: .uncertain, note: appended(loser.note, conflictNote))
        }
        return results
    }

    private static func appended(_ note: String, _ extra: String) -> String {
        note.isEmpty ? extra : note + "；" + extra
    }

    // MARK: - 计划

    /// 按匹配结果算出改名计划。只会动返图文件夹，绝不会碰原图文件夹。
    static func plan(matches: [RenameMatch], includeUncertain: Bool, returnedFolder: URL) -> RenamePlan {
        var plan = RenamePlan()
        // 返图文件夹里现有的文件名，用来挡掉会撞名的目标
        let existing = Set(((try? FileManager.default.contentsOfDirectory(
            at: returnedFolder, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])) ?? []).map { $0.lastPathComponent })

        // 同一批里若有多个返图都指向同一个目标名（比如一张原图同时被两张返图命中，
        // 勾上「包含疑似匹配」后两条都会入选），只保留差异最小的那条：它才最可信。
        var bestForTarget: [String: Int] = [:]
        for (index, match) in matches.enumerated() where isEligible(match, includeUncertain) {
            guard let target = match.targetName else { continue }
            if let holder = bestForTarget[target], matches[holder].distance <= match.distance { continue }
            bestForTarget[target] = index
        }

        for (index, match) in matches.enumerated() {
            guard let target = match.targetName else { continue }
            guard isEligible(match, includeUncertain) else { continue }

            let from = match.returned.url
            // 本批次里已经有更匹配这张原图的文件，别去抢同一个名字
            if let holder = bestForTarget[target], holder != index {
                let winner = matches[holder]
                plan.skips.append(RenameSkip(
                    name: from.lastPathComponent,
                    reason: "同一批里「\(winner.returned.name)」更匹配原图「\(target)」（差异 \(winner.distance)），本文件跳过以免重名"))
                continue
            }
            if from.lastPathComponent == target {
                // 名字已经对了，不用改名；但拍摄信息该补的还得补——
                // 修图软件剔掉的正是这部分，改了名的补、没改名的同样要补
                if let source = match.original?.url {
                    plan.metadataOnly.append(MetadataTask(target: from, source: source))
                }
                continue
            }
            if existing.contains(target) {
                plan.skips.append(RenameSkip(name: from.lastPathComponent,
                                             reason: "目标文件名「\(target)」在本文件夹里已存在"))
                continue
            }
            plan.steps.append(RenameStep(from: from,
                                         to: returnedFolder.appendingPathComponent(target),
                                         metadataSource: match.original?.url))
        }
        return plan
    }

    /// 这条匹配是否会被写进改名计划
    private static func isEligible(_ match: RenameMatch, _ includeUncertain: Bool) -> Bool {
        match.status == .matched || (includeUncertain && match.status == .uncertain)
    }

    // MARK: - 执行

    /// 执行改名。同一批里先统一改成带前缀的临时名，错开彼此占用的目标名，再落到最终名。
    /// 每改完一个，就把对应原图的 Exif / IPTC / TIFF 补写到这张返图上（无损，不动像素）；
    /// 文件名本来就一致的那些虽然不改名，也同样把拍摄信息补上。
    static func execute(_ plan: RenamePlan) -> RenameOutcome {
        let manager = FileManager.default
        var outcome = RenameOutcome()
        outcome.skipped = plan.skips

        var staged: [(temp: URL, final: URL, original: URL, metadataSource: URL?)] = []
        for step in plan.steps {
            let folder = step.from.deletingLastPathComponent()
            let ext = step.from.pathExtension
            let tempName = ".skintone-\(UUID().uuidString)" + (ext.isEmpty ? "" : ".\(ext)")
            let temp = folder.appendingPathComponent(tempName)
            do {
                try manager.moveItem(at: step.from, to: temp)
                staged.append((temp, step.to, step.from, step.metadataSource))
            } catch {
                outcome.failed.append(RenameSkip(name: step.oldName, reason: error.localizedDescription))
            }
        }

        for item in staged {
            do {
                try manager.moveItem(at: item.temp, to: item.final)
                outcome.renamed.append(RenameStep(from: item.original, to: item.final,
                                                  metadataSource: item.metadataSource))
                copyMetadata(from: item.metadataSource, to: item.final, onlyMetadata: false, into: &outcome)
            } catch {
                outcome.failed.append(RenameSkip(name: item.original.lastPathComponent,
                                                 reason: error.localizedDescription))
                // 落不到目标名就还原成原名，不留半成品
                try? manager.moveItem(at: item.temp, to: item.original)
            }
        }

        // 名字本来就对的那些：不动文件名，只把原图的拍摄信息补上去
        for task in plan.metadataOnly {
            copyMetadata(from: task.source, to: task.target, onlyMetadata: true, into: &outcome)
        }
        return outcome
    }

    /// 把原图的拍摄信息补到返图上。`onlyMetadata` 为 true 表示这条只补信息、没有改过名
    private static func copyMetadata(from source: URL?, to target: URL,
                                     onlyMetadata: Bool, into outcome: inout RenameOutcome) {
        guard let source else { return }
        switch PhotoMetadataCopier.copy(from: source, to: target) {
        case .copied:
            if onlyMetadata {
                outcome.metadataOnlyCopied.append(target.lastPathComponent)
            } else {
                outcome.metadataCopied.append(target.lastPathComponent)
            }
        case .skippedNoSource:
            outcome.metadataSkipped.append(target.lastPathComponent)
        case .failed(let reason):
            outcome.metadataFailed.append(RenameSkip(name: target.lastPathComponent, reason: reason))
        }
    }

    /// 撤销：把改名记录反过来再执行一次。只还原文件名，已经补上的拍摄信息会留在文件里
    static func undo(_ steps: [RenameStep]) -> RenameOutcome {
        execute(RenamePlan(steps: steps.map {
            RenameStep(from: $0.to, to: $0.from, metadataSource: nil)
        }, skips: []))
    }

    // MARK: - 文本报告

    static func report(originalScan: FolderScan, returnedScan: FolderScan,
                       matches: [RenameMatch], plan: RenamePlan,
                       outcome: RenameOutcome?, includeUncertain: Bool) -> String {
        var lines: [String] = []
        lines.append("文件名对应 · 返图按原图改名")
        lines.append("")
        lines.append("原图文件夹  \(originalScan.folder.path)")
        lines.append("            \(describe(originalScan))")
        lines.append("返图文件夹  \(returnedScan.folder.path)")
        lines.append("            \(describe(returnedScan))")
        lines.append("")

        let matched = matches.filter { $0.status == .matched }.count
        let uncertain = matches.filter { $0.status == .uncertain }.count
        let unmatched = matches.filter { $0.status == .unmatched }.count
        lines.append("匹配结果    匹配 \(matched) · 疑似 \(uncertain) · 未匹配 \(unmatched)")
        lines.append("            判定标准：128 位内容指纹的差异 ≤ \(matchedThreshold) 视为匹配，≤ \(uncertainThreshold) 视为疑似"
                     + (includeUncertain ? "（本次疑似也一起改名）" : "（疑似默认不改名）"))
        lines.append("")

        lines.append("将改名（\(plan.steps.count) 个，同时把对应原图的 Exif / IPTC / TIFF 补写进返图）")
        if plan.steps.isEmpty {
            lines.append("  （无）")
        } else {
            for step in plan.steps { lines.append("  \(padded(step.oldName, 34)) →  \(step.newName)") }
        }
        lines.append("")

        if !plan.metadataOnly.isEmpty {
            lines.append("只补写拍摄信息（\(plan.metadataOnly.count) 个，文件名本来就与原图一致，不用改名）")
            for task in plan.metadataOnly {
                lines.append("  \(padded(task.target.lastPathComponent, 34))    信息取自 \(task.source.lastPathComponent)")
            }
            lines.append("")
        }

        let uncertainRows = matches.filter { $0.status == .uncertain }
        if !uncertainRows.isEmpty {
            lines.append("疑似（\(uncertainRows.count) 个，\(includeUncertain ? "已包含在上面的计划里" : "默认不改名，请人工确认")）")
            for match in uncertainRows {
                lines.append("  \(padded(match.returned.name, 34)) →  \(match.targetName ?? "—")   差异 \(match.distance)/128"
                             + (match.note.isEmpty ? "" : "  ·  \(match.note)"))
            }
            lines.append("")
        }

        let unmatchedRows = matches.filter { $0.status == .unmatched }
        if !unmatchedRows.isEmpty {
            lines.append("未匹配（\(unmatchedRows.count) 个，原图文件夹里没有对应的照片）")
            for match in unmatchedRows {
                lines.append("  \(padded(match.returned.name, 34))    最接近 \(match.targetName ?? "—")，差异 \(match.distance)/128")
            }
            lines.append("")
        }

        if !plan.skips.isEmpty {
            lines.append("跳过（\(plan.skips.count) 个）")
            for skip in plan.skips { lines.append("  \(padded(skip.name, 34))    \(skip.reason)") }
            lines.append("")
        }

        if let outcome {
            lines.append("执行结果    已改名 \(outcome.renamed.count) 个 · 跳过 \(outcome.skipped.count) 个 · 失败 \(outcome.failed.count) 个")
            for step in outcome.renamed { lines.append("  \(padded(step.oldName, 34)) →  \(step.newName)") }
            for item in outcome.failed { lines.append("  失败  \(item.name)：\(item.reason)") }
            lines.append("")
            lines.append("拍摄信息    Exif / IPTC / TIFF 已补写 \(outcome.metadataCopied.count + outcome.metadataOnlyCopied.count) 个"
                         + "（其中文件名未变、只补信息 \(outcome.metadataOnlyCopied.count) 个）"
                         + " · 原图没有该信息自动跳过 \(outcome.metadataSkipped.count) 个"
                         + " · 失败 \(outcome.metadataFailed.count) 个")
            if !outcome.metadataSkipped.isEmpty {
                lines.append("  跳过（原图没有可复制的拍摄信息）")
                for name in outcome.metadataSkipped { lines.append("    \(name)") }
            }
            for item in outcome.metadataFailed {
                lines.append("  失败  \(item.name)：\(item.reason)")
            }
            lines.append("")
        }

        lines.append("提示：所有改动都只发生在返图文件夹，原图文件夹不会被碰；"
                     + "补写拍摄信息用的是无损方式，返图的压缩数据与像素逐字节不变。"
                     + "执行后可用界面上的「撤销本次重命名」还原文件名（已补上的拍摄信息会保留在文件里）。")
        return lines.joined(separator: "\n")
    }

    private static func describe(_ scan: FolderScan) -> String {
        var text = "可比对图像 \(scan.files.count) 张"
        if scan.skipped > 0 { text += "，另有 \(scan.skipped) 个非图像文件未参与" }
        return text
    }

    private static func padded(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }
}
