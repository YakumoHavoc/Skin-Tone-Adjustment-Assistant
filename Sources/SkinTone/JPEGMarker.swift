//
//  JPEGMarker.swift
//  JPG → PSD 批量无损转换
//
//  一趟扫描 JPEG 标记段，取出 PSD 要用到的元数据：
//    1. 内嵌 ICC 色彩描述文件（APP2 `ICC_PROFILE`，多段按序号拼接）
//    2. 分辨率 DPI（JFIF APP0 密度优先，其次 EXIF APP1 的 IFD0 XResolution）
//    3. 拍摄信息：APP1 里的 EXIF TIFF 块、APP13 里的 IPTC IIM 数据集
//       （原样带进 PSD 的 1058 / 1028 号图像资源，见 PSDWriter）
//
//  口径刻意与 Pillow 保持一致：
//    - 文件里没有内嵌 ICC 就返回 nil，不会把 ImageIO 自动补上的默认 sRGB /
//      灰度描述文件当成本图信息写进 PSD；
//    - DPI 的取值与回退规则（JFIF units=1/2；EXIF 有 APP1 但解析不出时回退 72）
//      与 Pillow 的 `JpegImagePlugin` 相同。
//

import Foundation

/// 从 JPEG 文件中读出的元数据
struct JPEGMetadata {
    var icc: Data?
    var dpi: (h: Double, v: Double)?
    /// APP1 里的 EXIF TIFF 块（已去掉 `Exif\0\0` 前缀），原样写进 PSD 的 1058 号资源
    var exif: Data?
    /// APP13 里 8BIM 0x0404 块的 IPTC IIM 数据集，原样写进 PSD 的 1028 号资源
    var iptc: Data?
}

enum JPEGMarker {
    static func metadata(at path: String) -> JPEGMetadata {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path),
                                   options: .mappedIfSafe) else {
            return JPEGMetadata()
        }
        return data.withUnsafeBytes { metadata(in: $0) }
    }

    static func metadata(in bytes: UnsafeRawBufferPointer) -> JPEGMetadata {
        var result = JPEGMetadata()
        let count = bytes.count
        guard count > 4 else { return result }
        let b = bytes.bindMemory(to: UInt8.self)

        var iccChunks: [Int: Data] = [:]
        var iccExpected = 0
        var jfifDPI: (Double, Double)?
        var exifPresent = false
        var exifDPI: (Double, Double)?

        var i = 2  // 跳过 SOI(FFD8)
        while i + 4 <= count {
            guard b[i] == 0xFF else { break }
            let marker = b[i + 1]
            if marker == 0xD8 || marker == 0x01 || (0xD0...0xD7).contains(marker) {
                i += 2
                continue
            }
            if marker == 0xDA { break }  // SOS 之后是压缩数据，标记段到此为止
            let length = Int(b[i + 2]) << 8 | Int(b[i + 3])
            guard length >= 2 else { break }
            let payload = i + 4
            let end = i + 2 + length
            guard end <= count else { break }
            let body = UnsafeBufferPointer(rebasing: b[payload..<end])

            switch marker {
            case 0xE0 where jfifDPI == nil:
                // JFIF：units 1 = 像素/英寸，2 = 像素/厘米（1 dpcm = 2.54 dpi）
                if body.count >= 12, hasPrefix(body, Array("JFIF".utf8)) {
                    let units = Int(body[7])
                    let x = Int(body[8]) << 8 | Int(body[9])
                    let y = Int(body[10]) << 8 | Int(body[11])
                    if units == 1 {
                        jfifDPI = (Double(x), Double(y))
                    } else if units == 2 {
                        jfifDPI = (Double(x) * 2.54, Double(y) * 2.54)
                    }
                }

            case 0xE1 where !exifPresent:
                if body.count > 6, hasPrefix(body, Array("Exif\0\0".utf8)) {
                    exifPresent = true
                    exifDPI = exifResolution(fromTIFF: body, at: 6)
                    // 整段 TIFF 块原样留下（含相机、镜头、拍摄参数、GPS 等）
                    result.exif = Data(bytes: body.baseAddress!.advanced(by: 6),
                                       count: body.count - 6)
                }

            case 0xED where result.iptc == nil:
                result.iptc = iptcDataset(body)

            case 0xE2:
                // ICC_PROFILE 分段：签名(11) + 0x00 + 序号 + 总数 + 数据
                if body.count >= 14, hasPrefix(body, Array("ICC_PROFILE".utf8)), body[11] == 0 {
                    let sequence = Int(body[12])
                    let total = Int(body[13])
                    if sequence >= 1, total >= 1, sequence <= total, body.count > 14 {
                        iccExpected = total
                        iccChunks[sequence] = Data(bytes: body.baseAddress!.advanced(by: 14),
                                                   count: body.count - 14)
                    }
                }

            default:
                break
            }
            i = end
        }

        if iccExpected > 0, iccChunks.count == iccExpected {
            var icc = Data()
            var complete = true
            for index in 1...iccExpected {
                guard let chunk = iccChunks[index] else { complete = false; break }
                icc.append(chunk)
            }
            if complete { result.icc = icc }
        }

        if let jfif = jfifDPI {
            result.dpi = (h: jfif.0, v: jfif.1)
        } else if exifPresent {
            // 与 Pillow 一致：有 EXIF 但解析不出分辨率时回退 72
            let resolved = exifDPI ?? (72, 72)
            result.dpi = (h: resolved.0, v: resolved.1)
        }

        return result
    }

    // MARK: - EXIF IFD0

    /// 从 APP1 载荷里的 TIFF 头读 IFD0 的 XResolution(0x011A) 与 ResolutionUnit(0x0128)。
    /// 两者缺一即返回 nil（调用方按 Pillow 的规则回退 72 DPI）。
    private static func exifResolution(fromTIFF payload: UnsafeBufferPointer<UInt8>, at tiff: Int) -> (Double, Double)? {
        guard payload.count >= tiff + 8 else { return nil }
        let marker = payload[tiff]
        let little: Bool
        switch marker {
        case 0x49: little = true    // "II"
        case 0x4D: little = false   // "MM"
        default: return nil
        }
        func u16(_ o: Int) -> Int {
            o + 2 <= payload.count ? (little ? Int(payload[o]) | Int(payload[o + 1]) << 8
                                              : Int(payload[o]) << 8 | Int(payload[o + 1])) : -1
        }
        func u32(_ o: Int) -> Int {
            guard o + 4 <= payload.count else { return -1 }
            return little
                ? Int(payload[o]) | Int(payload[o + 1]) << 8 | Int(payload[o + 2]) << 16 | Int(payload[o + 3]) << 24
                : Int(payload[o]) << 24 | Int(payload[o + 1]) << 16 | Int(payload[o + 2]) << 8 | Int(payload[o + 3])
        }
        guard u16(tiff + 2) == 42 else { return nil }
        let ifdOffset = u32(tiff + 4)
        guard ifdOffset > 0 else { return nil }
        let base = tiff + ifdOffset
        let entryCount = u16(base)
        guard entryCount > 0 else { return nil }

        var xResolution: Double?
        var resolutionUnit: Int?
        for index in 0..<entryCount {
            let entry = base + 2 + index * 12
            guard entry + 12 <= payload.count else { break }
            let tag = u16(entry)
            let type = u16(entry + 2)
            let count = u32(entry + 4)
            guard tag == 0x011A || tag == 0x0128 else { continue }
            if tag == 0x0128 {
                if type == 3, count == 1 { resolutionUnit = u16(entry + 8) }
            } else if count == 1 {
                if type == 5 {
                    // RATIONAL：值是 8 字节，前 4 字节为偏移
                    let offset = tiff + u32(entry + 8)
                    let numerator = u32(offset)
                    let denominator = u32(offset + 4)
                    if numerator >= 0, denominator > 0 { xResolution = Double(numerator) / Double(denominator) }
                } else if type == 4 {
                    let value = u32(entry + 8)
                    if value >= 0 { xResolution = Double(value) }
                }
            }
        }
        guard let x = xResolution, let unit = resolutionUnit else { return nil }
        let dpi = unit == 3 ? x * 2.54 : x   // 3 = 像素/厘米
        guard dpi.isFinite, dpi > 0 else { return nil }
        return (dpi, dpi)
    }

    // MARK: - APP13 / IPTC

    /// 从 APP13 载荷里取出 IPTC IIM 数据集。
    /// 结构：`"Photoshop 3.0\0"` 之后是一串 8BIM 图像资源块（id 0x0404 即 IPTC）。
    private static func iptcDataset(_ body: UnsafeBufferPointer<UInt8>) -> Data? {
        let signature: [UInt8] = Array("Photoshop 3.0\0".utf8)
        guard body.count > signature.count, hasPrefix(body, signature) else { return nil }

        var i = signature.count
        while i + 12 <= body.count {
            guard b(body, i) == 0x38, b(body, i + 1) == 0x42,
                  b(body, i + 2) == 0x49, b(body, i + 3) == 0x4D else { break }  // "8BIM"
            let id = Int(body[i + 4]) << 8 | Int(body[i + 5])

            // Pascal 名：长度字节 + 名字，整体补齐到偶数
            let nameLength = Int(body[i + 6])
            var p = i + 7 + nameLength
            if (1 + nameLength) % 2 != 0 { p += 1 }
            guard p + 4 <= body.count else { break }

            let size = Int(body[p]) << 24 | Int(body[p + 1]) << 16
                | Int(body[p + 2]) << 8 | Int(body[p + 3])
            p += 4
            guard size >= 0, p + size <= body.count else { break }

            if id == 0x0404, size > 0 {
                return Data(bytes: body.baseAddress!.advanced(by: p), count: size)
            }
            // 数据同样按偶数对齐，跳过后继续找下一块
            p += size
            if size % 2 != 0 { p += 1 }
            i = p
        }
        return nil
    }

    private static func b(_ body: UnsafeBufferPointer<UInt8>, _ index: Int) -> UInt8 {
        index >= 0 && index < body.count ? body[index] : 0
    }

    // MARK: - EXIF 摆正后的修正

    /// 像素已按 EXIF 摆正时，把 EXIF 块里的方向标记顺过来（全部是原地改值，块长度不变）：
    ///   - `Orientation`(0x0112) 归一为 1，否则 Photoshop 会按旧标记再转一次；
    ///   - 发生 90°/270° 的轴交换时（orientation ≥ 5）互换 Exif SubIFD 里的
    ///     `PixelXDimension`(0xA002) / `PixelYDimension`(0xA003)，让记录的尺寸与 PSD 实际尺寸一致。
    static func normalizeExif(_ exif: Data, swapDimensions: Bool) -> Data {
        var bytes = [UInt8](exif)
        guard bytes.count >= 8 else { return exif }

        let little: Bool
        switch bytes[0] {
        case 0x49: little = true    // "II"
        case 0x4D: little = false   // "MM"
        default: return exif
        }

        func u16(_ o: Int) -> Int {
            guard o >= 0, o + 2 <= bytes.count else { return -1 }
            return little ? Int(bytes[o]) | Int(bytes[o + 1]) << 8
                          : Int(bytes[o]) << 8 | Int(bytes[o + 1])
        }
        func u32(_ o: Int) -> Int {
            guard o >= 0, o + 4 <= bytes.count else { return -1 }
            return little
                ? Int(bytes[o]) | Int(bytes[o + 1]) << 8 | Int(bytes[o + 2]) << 16 | Int(bytes[o + 3]) << 24
                : Int(bytes[o]) << 24 | Int(bytes[o + 1]) << 16 | Int(bytes[o + 2]) << 8 | Int(bytes[o + 3])
        }
        func put16(_ o: Int, _ value: Int) {
            guard o >= 0, o + 2 <= bytes.count else { return }
            if little {
                bytes[o] = UInt8(value & 0xFF)
                bytes[o + 1] = UInt8((value >> 8) & 0xFF)
            } else {
                bytes[o] = UInt8((value >> 8) & 0xFF)
                bytes[o + 1] = UInt8(value & 0xFF)
            }
        }
        func put32(_ o: Int, _ value: Int) {
            guard o >= 0, o + 4 <= bytes.count else { return }
            if little {
                bytes[o] = UInt8(value & 0xFF)
                bytes[o + 1] = UInt8((value >> 8) & 0xFF)
                bytes[o + 2] = UInt8((value >> 16) & 0xFF)
                bytes[o + 3] = UInt8((value >> 24) & 0xFF)
            } else {
                bytes[o] = UInt8((value >> 24) & 0xFF)
                bytes[o + 1] = UInt8((value >> 16) & 0xFF)
                bytes[o + 2] = UInt8((value >> 8) & 0xFF)
                bytes[o + 3] = UInt8(value & 0xFF)
            }
        }

        guard u16(2) == 42 else { return exif }
        let ifd = u32(4)
        let entryCount = u16(ifd)
        guard entryCount > 0 else { return exif }

        var subIFD = -1
        for index in 0..<entryCount {
            let entry = ifd + 2 + index * 12
            guard entry + 12 <= bytes.count else { break }
            let tag = u16(entry)
            let type = u16(entry + 2)
            let count = u32(entry + 4)
            if tag == 0x0112, type == 3, count == 1 {
                put16(entry + 8, 1)
            } else if tag == 0x8769, type == 4, count == 1 {
                subIFD = u32(entry + 8)
            }
        }

        if swapDimensions {
            let subCount = u16(subIFD)
            var xDimension = -1
            var yDimension = -1
            for index in 0..<max(0, subCount) {
                let entry = subIFD + 2 + index * 12
                guard entry + 12 <= bytes.count else { break }
                guard u16(entry + 2) == 4, u32(entry + 4) == 1 else { continue }
                if u16(entry) == 0xA002 { xDimension = entry + 8 }
                else if u16(entry) == 0xA003 { yDimension = entry + 8 }
            }
            if xDimension >= 0, yDimension >= 0 {
                let x = u32(xDimension)
                let y = u32(yDimension)
                if x > 0, y > 0 { put32(xDimension, y); put32(yDimension, x) }
            }
        }
        return Data(bytes)
    }

    private static func hasPrefix(_ body: UnsafeBufferPointer<UInt8>, _ needle: [UInt8]) -> Bool {
        guard body.count >= needle.count else { return false }
        for (offset, byte) in needle.enumerated() where body[offset] != byte { return false }
        return true
    }
}
