//
//  ImageLoader.swift
//  JPG → PSD 批量无损转换
//
//  用 ImageIO 解码 JPG，再把像素整理成 PSD 需要的「通道优先 8bit 平面」。
//
//  无损要点：
//    - 渲染到与原图**同一色彩空间**的 bitmap 上下文里，CoreGraphics 不做任何色彩转换，
//      像素值与解码结果逐字节一致（渲染为 1:1 整数对齐，无重采样）；
//    - EXIF 方向摆正是在平面数据上做纯索引重排（见 PSDWriter.applyOrientation），
//      不像真旋转那样会引入重采样误差。
//

import Foundation
import ImageIO
import CoreGraphics

enum ImageLoaderError: LocalizedError {
    case cannotOpen
    case cannotDecode
    case cannotCreateContext

    var errorDescription: String? {
        switch self {
        case .cannotOpen: return "无法打开文件（可能不是图片或已损坏）"
        case .cannotDecode: return "无法解码图像数据"
        case .cannotCreateContext: return "无法创建绘图上下文"
        }
    }
}

/// 解码并整理好的图像
struct LoadedImage {
    var planar: PlanarImage
    var icc: Data?
    var dpi: (h: Double, v: Double)?
    /// EXIF 方向值 1…8（未标注为 1）
    var orientation: Int
    /// 拍摄信息：EXIF TIFF 块（已做摆正修正），写进 PSD 的 1058 号图像资源
    var exif: Data?
    /// 拍摄信息：IPTC IIM 数据集，写进 PSD 的 1028 号图像资源
    var iptc: Data?
    /// 拍摄信息：XMP 包（XML），写进 PSD 的 1060 号图像资源
    var xmp: Data?
}

enum ImageLoader {
    /// 只解析图像头取得像素总数（不解码像素），用于批量转换时的内存配额估算。
    static func pixelCount(path: String) -> Int? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return width * height
    }

    /// 解码单个文件。`keepOrientation = true` 时不做 EXIF 摆正。
    static func load(path: String, keepOrientation: Bool) throws -> LoadedImage {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else {
            throw ImageLoaderError.cannotOpen
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ImageLoaderError.cannotDecode
        }

        // 灰度 JPG -> 灰度 PSD（单通道）；其余（含 CMYK）-> RGB
        let wantsGray = (properties?[kCGImagePropertyColorModel] as? String) == "Gray"
            || image.colorSpace?.model == .monochrome
        let channels = wantsGray ? 1 : 3
        let colorMode = wantsGray ? PSDWriter.colorModeGrayscale : PSDWriter.colorModeRGB

        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { throw ImageLoaderError.cannotDecode }

        // 与原图一致的色彩空间，保证渲染是恒等变换（不做色彩管理）
        let space: CGColorSpace
        if let sourceSpace = image.colorSpace,
           sourceSpace.model == (wantsGray ? .monochrome : .rgb) {
            space = sourceSpace
        } else {
            space = wantsGray ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB()
        }

        // 交错缓冲区：灰度 1 字节/像素；RGB 用 32bit 的 RGBX（末字节被忽略），随后拆成平面
        let bytesPerRow = wantsGray ? width : width * 4
        let bitmapInfo = wantsGray ? CGImageAlphaInfo.none.rawValue
                                   : CGImageAlphaInfo.noneSkipLast.rawValue
        var interleaved = [UInt8](repeating: 0, count: bytesPerRow * height)
        let drawn = interleaved.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress,
                                          width: width, height: height,
                                          bitsPerComponent: 8,
                                          bytesPerRow: bytesPerRow,
                                          space: space,
                                          bitmapInfo: bitmapInfo) else { return false }
            context.setShouldAntialias(false)
            context.interpolationQuality = .none
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw ImageLoaderError.cannotCreateContext }

        var planar = PlanarImage.empty(width: width, height: height,
                                       channels: channels, colorMode: colorMode)
        planar.data.withUnsafeMutableBytes { dstRaw in
            guard let dst = dstRaw.bindMemory(to: UInt8.self).baseAddress else { return }
            interleaved.withUnsafeBufferPointer { src in
                guard let source = src.baseAddress else { return }
                if wantsGray {
                    dst.update(from: source, count: width * height)
                } else {
                    let planeSize = width * height
                    for y in 0..<height {
                        let rowStart = y * bytesPerRow
                        var out = y * width
                        for x in 0..<width {
                            let p = rowStart + x * 4
                            dst[out] = source[p]
                            dst[planeSize + out] = source[p + 1]
                            dst[2 * planeSize + out] = source[p + 2]
                            out += 1
                        }
                    }
                }
            }
        }

        // EXIF 方向
        var orientation = 1
        if let raw = properties?[kCGImagePropertyOrientation] as? Int, raw >= 1, raw <= 8 {
            orientation = raw
        }
        let rotated = !keepOrientation && orientation > 1
        if rotated {
            planar = PSDWriter.applyOrientation(planar, orientation)
        }

        // ICC 与 DPI 直接按 JPEG 标记段解析，口径与 Pillow 一致
        let metadata = JPEGMarker.metadata(at: path)

        // 拍摄信息（EXIF / IPTC）原样带过去；像素做过摆正时，
        // 只用原地改值的方式把 EXIF 的方向标记与像素尺寸顺过来，其余标签一个不动。
        // 生成不出 XMP 说明原图确实没有拍摄信息（ImageIO 对空白 JPG 只会补像素尺寸），
        // 这时 EXIF 也不写，免得 PSD 里莫名其妙多出一段只有尺寸的空 EXIF。
        let xmp = xmp(from: source, droppingUnsafeTags: rotated)
        let exif = xmp == nil ? nil : metadata.exif.map {
            rotated ? JPEGMarker.normalizeExif($0, swapDimensions: orientation >= 5) : $0
        }

        return LoadedImage(planar: planar, icc: metadata.icc, dpi: metadata.dpi,
                           orientation: orientation,
                           exif: exif, iptc: metadata.iptc, xmp: xmp)
    }

    /// ImageIO 对任何 JPG 都会补上这几个标签（像素尺寸与方向），它们不含拍摄信息。
    /// 实测：完全没有元数据的 JPG 取出来的就只有这两项像素尺寸，
    /// 所以要判断「原图到底有没有拍摄信息」，得排除掉它们。
    private static let nonShootingTagPaths: Set<String> = [
        "exif:PixelXDimension",
        "exif:PixelYDimension",
        "tiff:Orientation",
        "tiff:ImageWidth",
        "tiff:ImageLength",
    ]

    /// 用 ImageIO 的元数据生成 XMP 包：Exif / IPTC / TIFF 会一并转成 XMP 属性，
    /// 所以相机直出、没有 XMP 的 JPG 同样能拿到一份完整的拍摄信息。
    /// 原图没有拍摄信息（只剩像素尺寸）时返回 nil。
    ///
    /// 像素被摆正过时摘掉三个「照抄就会自相矛盾」的标签（尺寸与方向，口径同
    /// PhotoMetadataCopier）：PSD 里的像素已经转正，再带上原图的方向或尺寸会让
    /// 看图软件按旧标记再转一次。没摆正时不摘——此时 PSD 像素与原图逐字节相同，
    /// 这些标记同样成立。
    private static func xmp(from source: CGImageSource, droppingUnsafeTags: Bool) -> Data? {
        guard let original = CGImageSourceCopyMetadataAtIndex(source, 0, nil),
              let metadata = CGImageMetadataCreateMutableCopy(original) else { return nil }
        if droppingUnsafeTags {
            for path in PhotoMetadataCopier.unsafeTagPaths {
                _ = CGImageMetadataRemoveTagWithPath(metadata, nil, path)
            }
        }
        guard hasShootingInfo(metadata) else { return nil }
        guard let packet = CGImageMetadataCreateXMPData(metadata, nil) else { return nil }
        return packet as Data
    }

    /// 元数据里是否存在「拍摄信息」标签（不算像素尺寸这类自动补上的）
    private static func hasShootingInfo(_ metadata: CGImageMetadata) -> Bool {
        var found = false
        CGImageMetadataEnumerateTagsUsingBlock(metadata, nil, nil) { path, _ in
            if !nonShootingTagPaths.contains(path as String) { found = true }
            return !found   // 找到一个就停
        }
        return found
    }
}
