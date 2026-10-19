//
//  PSDWriter.swift
//  JPG → PSD 批量无损转换
//
//  PSD 结构：8BPS(v1) + 颜色模式数据 + 图像资源(DPI/拍摄信息/ICC) + 空图层区 + 图像数据。
//  图像数据只用 Raw(0) / RLE(PackBits,1) 两种**无损**方式，绝不使用 PSD 内部的 JPEG 压缩。
//

import Foundation

/// PSD 内部压缩方式（三者均为无损）。rawValue 与命令行参数一致。
enum PSDCompression: String, CaseIterable {
    case auto
    case raw
    case rle

    var label: String {
        switch self {
        case .auto: return "自动（推荐，自动选更小的无损压缩）"
        case .rle: return "无损 RLE 压缩"
        case .raw: return "不压缩 Raw（最快）"
        }
    }
}

enum PSDWriterError: LocalizedError {
    /// RLE 每行长度用 2 字节表示，超过 65535 无法记录
    case rowTooLong

    var errorDescription: String? {
        switch self {
        case .rowTooLong:
            return "图像过宽，RLE 行长度超出 PSD 上限，请改用「不压缩 Raw」"
        }
    }
}

/// 平面化像素：通道优先（channel-major）、8bit、行优先。
/// `data` 布局为 [通道0 全部像素][通道1 全部像素]…
struct PlanarImage {
    var data: Data
    var width: Int
    var height: Int
    var channels: Int
    /// 1 = 灰度，3 = RGB
    var colorMode: UInt16

    var planeSize: Int { width * height }

    static func empty(width: Int, height: Int, channels: Int, colorMode: UInt16) -> PlanarImage {
        PlanarImage(data: Data(count: channels * width * height),
                    width: width, height: height,
                    channels: channels, colorMode: colorMode)
    }
}

enum PSDWriter {
    static let signature = Array("8BPS".utf8)
    static let version: UInt16 = 1
    static let colorModeGrayscale: UInt16 = 1
    static let colorModeRGB: UInt16 = 3
    static let compressionRaw: UInt16 = 0
    static let compressionRLE: UInt16 = 1
    /// RLE 行长度表的记录上限（2 字节）
    static let maxRowLength = 0xFFFF

    /// 图像资源块 ID
    static let resolutionResourceID: UInt16 = 1005
    static let iptcResourceID: UInt16 = 1028
    static let iccResourceID: UInt16 = 1039
    static let exifResourceID: UInt16 = 1058
    static let xmpResourceID: UInt16 = 1060

    // MARK: - PackBits

    /// 把单行像素按 PackBits(RLE) 编码后**追加**到 `buffer`，按 128 字节分块，
    /// 结果一定能被正确解码。复用同一个缓冲区可以避免每行都新建临时数组。
    ///
    /// 规则：整块 128 字节完全相同 -> 压缩指令（2 字节）；否则 -> 原样输出该块。
    /// 末尾不足 128 字节的块用哨兵值填充，避免与真实数据被误判为同一个 run。
    static func packBits(_ row: UnsafeBufferPointer<UInt8>, into buffer: inout [UInt8]) {
        let n = row.count
        if n == 0 { return }

        let blockCount = (n + 127) / 128
        let last = row[n - 1]
        let sentinel: UInt8 = last != 255 ? last + 1 : last - 1

        for b in 0..<blockCount {
            let base = b * 128
            let length = Swift.min(128, n - base)
            let first = row[base]
            var constant = true
            var i = 1
            while i < 128 {
                // 末块超出真实数据的部分即哨兵值
                let value = base + i < n ? row[base + i] : sentinel
                if value != first { constant = false; break }
                i += 1
            }
            if constant && length >= 3 {
                // 有符号 -(length-1)
                buffer.append(UInt8(truncatingIfNeeded: 256 - (length - 1)))
                buffer.append(first)
            } else {
                buffer.append(UInt8(length - 1))
                buffer.append(contentsOf: UnsafeBufferPointer(rebasing: row[base..<(base + length)]))
            }
        }
    }

    // MARK: - 图像资源块

    /// 构造一个 `8BIM` 图像资源块（名称字段与数据均按偶数对齐）。
    static func resourceBlock(id: UInt16, data: Data, name: Data = Data()) -> Data {
        var block = Data("8BIM".utf8)
        block.appendBE16(id)
        block.append(UInt8(name.count))
        block.append(name)
        if block.count % 2 != 0 { block.append(0) }
        block.appendBE32(UInt32(data.count))
        block.append(data)
        if block.count % 2 != 0 { block.append(0) }
        return block
    }

    /// ICC 色彩描述文件资源块（ID 1039），逐字节嵌入。
    static func iccResource(_ icc: Data?) -> Data? {
        guard let icc, !icc.isEmpty else { return nil }
        return resourceBlock(id: iccResourceID, data: icc)
    }

    /// 分辨率资源块（ID 1005，16 字节：水平 16.16 + 单位 + 宽单位 + 垂直 16.16 + 单位 + 单位）。
    static func resolutionResource(_ dpi: (h: Double, v: Double)?) -> Data? {
        guard let dpi else { return nil }
        let hx = dpi.h
        let vx = dpi.v
        guard hx > 0, hx < 100_000, vx > 0, vx < 100_000, !(hx <= 1 && vx <= 1) else { return nil }

        var payload = Data()
        payload.appendFixed16_16(hx)
        payload.appendBE16(1)  // 水平单位：像素/英寸
        payload.appendBE16(1)  // 宽度单位：英寸
        payload.appendFixed16_16(vx)
        payload.appendBE16(1)
        payload.appendBE16(1)
        return resourceBlock(id: resolutionResourceID, data: payload)
    }

    /// 拍摄信息：IPTC IIM 数据集（ID 1028），逐字节嵌入原图那段。
    static func iptcResource(_ iptc: Data?) -> Data? {
        guard let iptc, !iptc.isEmpty else { return nil }
        return resourceBlock(id: iptcResourceID, data: iptc)
    }

    /// 拍摄信息：EXIF TIFF 块（ID 1058），逐字节嵌入原图那段（相机、镜头、拍摄参数、GPS 等）。
    static func exifResource(_ exif: Data?) -> Data? {
        // TIFF 头最短 8 字节，不足的说明不是一段有效的 EXIF
        guard let exif, exif.count >= 8 else { return nil }
        return resourceBlock(id: exifResourceID, data: exif)
    }

    /// 拍摄信息：XMP 包（ID 1060），逐字节嵌入。
    static func xmpResource(_ xmp: Data?) -> Data? {
        guard let xmp, !xmp.isEmpty else { return nil }
        return resourceBlock(id: xmpResourceID, data: xmp)
    }

    // MARK: - 打包

    /// 把平面化像素打包成完整的 PSD 文件字节。
    /// 返回 (psd 字节, 实际使用的压缩方式描述)。
    /// `exif` / `iptc` / `xmp` 为原图的拍摄信息，写进图像资源段（原图没有哪一段就自动跳过）。
    static func build(_ image: PlanarImage,
                      icc: Data?,
                      dpi: (h: Double, v: Double)?,
                      exif: Data?,
                      iptc: Data?,
                      xmp: Data?,
                      compression: PSDCompression) throws -> (data: Data, method: String) {
        let channels = image.channels
        let width = image.width
        let height = image.height
        let planeSize = image.planeSize
        let rowCount = channels * height

        var rowLengths: [Int] = []
        var rleBody = [UInt8]()
        var maxRowLength = 0

        if compression != .raw {
            // auto 只需要判断「RLE 是否比 Raw 更小」：一旦超出 Raw 体积就没必要继续编码
            let abortWhenLarger = compression == .auto
            image.data.withUnsafeBytes { rawBuffer in
                let pixels = rawBuffer.bindMemory(to: UInt8.self)
                rowLengths.reserveCapacity(rowCount)
                // 最坏情况（全部无法压缩）：每行多 1 字节的指令头
                rleBody.reserveCapacity(image.data.count + rowCount)
                rows: for c in 0..<channels {
                    let planeStart = c * planeSize
                    for y in 0..<height {
                        let start = planeStart + y * width
                        let before = rleBody.count
                        packBits(UnsafeBufferPointer(rebasing: pixels[start..<(start + width)]),
                                 into: &rleBody)
                        let encoded = rleBody.count - before
                        rowLengths.append(encoded)
                        if encoded > maxRowLength { maxRowLength = encoded }
                        if abortWhenLarger, rleBody.count >= image.data.count { break rows }
                    }
                }
            }
        }

        var useRLE = compression == .rle
        if compression == .auto {
            // 行长度超出 2 字节表上限时无法用 RLE；否则取体积更小者
            // （编码提前终止时 rleBody 必然已不小于 Raw，同样落到 Raw）
            useRLE = maxRowLength <= maxRowLengthLimit && rleBody.count < image.data.count
        }
        if compression == .rle, maxRowLength > maxRowLengthLimit {
            throw PSDWriterError.rowTooLong
        }

        var out = Data()
        out.reserveCapacity(image.data.count + channels * height * 2 + 4096)

        // 文件头
        out.append(contentsOf: signature)
        out.appendBE16(version)
        out.append(contentsOf: [UInt8](repeating: 0, count: 6))  // 保留字段
        out.appendBE16(UInt16(channels))
        out.appendBE32(UInt32(height))
        out.appendBE32(UInt32(width))
        out.appendBE16(8)                 // 位深：JPG 为 8bit
        out.appendBE16(image.colorMode)

        // 颜色模式数据（RGB / 灰度均无需调色板）
        out.appendBE32(0)

        // 图像资源段（按 ID 从小到大）：分辨率、拍摄信息、ICC。
        // 原图缺哪一段就不写哪一段，读图的软件按 ID 各取所需。
        var resources = Data()
        if let block = resolutionResource(dpi) { resources.append(block) }
        if let block = iptcResource(iptc) { resources.append(block) }
        if let block = iccResource(icc) { resources.append(block) }
        if let block = exifResource(exif) { resources.append(block) }
        if let block = xmpResource(xmp) { resources.append(block) }
        out.appendBE32(UInt32(resources.count))
        out.append(resources)

        // 图层与蒙版段（长度 0 => Photoshop 视为合并背景层）
        out.appendBE32(0)

        // 图像数据
        if useRLE {
            out.appendBE16(compressionRLE)
            for length in rowLengths { out.appendBE16(UInt16(length)) }
            out.append(contentsOf: rleBody)
            return (out, "RLE(无损)")
        } else {
            out.appendBE16(compressionRaw)
            out.append(image.data)
            return (out, "Raw(无损)")
        }
    }

    private static let maxRowLengthLimit = maxRowLength

    // MARK: - EXIF 方向摆正（纯字节重排，无损）

    /// 按 EXIF 方向值 1…8 把像素重排到正确方向。1 表示无需处理。
    static func applyOrientation(_ image: PlanarImage, _ orientation: Int) -> PlanarImage {
        guard orientation > 1, orientation <= 8 else { return image }
        let w = image.width
        let h = image.height
        let swapAxes = orientation >= 5
        let outW = swapAxes ? h : w
        let outH = swapAxes ? w : h

        var out = PlanarImage.empty(width: outW, height: outH,
                                   channels: image.channels, colorMode: image.colorMode)
        let inSize = w * h
        let outSize = outW * outH
        image.data.withUnsafeBytes { srcRaw in
            out.data.withUnsafeMutableBytes { dstRaw in
                guard let src = srcRaw.bindMemory(to: UInt8.self).baseAddress,
                      let dst = dstRaw.bindMemory(to: UInt8.self).baseAddress else { return }
                for c in 0..<image.channels {
                    permute(src: src.advanced(by: c * inSize),
                            dst: dst.advanced(by: c * outSize),
                            w: w, h: h, orientation: orientation)
                }
            }
        }
        return out
    }

    /// 单通道重排。目标像素 O(x,y)，源像素 S(sx,sy)，均以行优先索引。
    private static func permute(src: UnsafePointer<UInt8>, dst: UnsafeMutablePointer<UInt8>,
                                w: Int, h: Int, orientation: Int) {
        switch orientation {
        case 2:  // 水平镜像
            for y in 0..<h {
                let row = y * w
                for x in 0..<w { dst[row + x] = src[row + (w - 1 - x)] }
            }
        case 3:  // 旋转 180°
            let n = w * h
            for i in 0..<n { dst[i] = src[n - 1 - i] }
        case 4:  // 垂直镜像
            for y in 0..<h {
                let s = (h - 1 - y) * w
                let d = y * w
                for x in 0..<w { dst[d + x] = src[s + x] }
            }
        case 5:  // 主对角线转置 -> outW = h
            for x in 0..<h { for y in 0..<w { dst[y * h + x] = src[x * w + y] } }
        case 6:  // 顺时针 90° -> outW = h
            for x in 0..<h { for y in 0..<w { dst[y * h + x] = src[(h - 1 - x) * w + y] } }
        case 7:  // 副对角线转置 -> outW = h
            for x in 0..<h { for y in 0..<w { dst[y * h + x] = src[(h - 1 - x) * w + (w - 1 - y)] } }
        case 8:  // 逆时针 90° -> outW = h
            for x in 0..<h { for y in 0..<w { dst[y * h + x] = src[x * w + (w - 1 - y)] } }
        default:
            break
        }
    }
}

// MARK: - 大端写入辅助

extension Data {
    mutating func appendBE16(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    mutating func appendBE32(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value >> 24))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    /// PSD 分辨率用的 16.16 定点数
    mutating func appendFixed16_16(_ value: Double) {
        let scaled = (value * 65536).rounded()
        let clamped = Swift.min(Swift.max(scaled, 0), Double(UInt32.max))
        appendBE32(UInt32(clamped))
    }
}
