import CoreGraphics
import Foundation
import ImageIO

/// 把原图的拍摄信息补到返图上之后的结果
enum MetadataCopyResult {
    /// 已经无损写入
    case copied
    /// 原图本来就没有这部分信息，自动跳过
    case skippedNoSource
    /// 写不进去（格式不支持、文件被锁等）
    case failed(String)
}

/// 把原图的 Exif / IPTC / TIFF 信息复制到返图文件上。
///
/// 修图软件导出返图时会把这几段信息一并剔除，这里从原图取回来补上。
/// 关键点：整段用 `CGImageDestinationCopyImageSource`——它只重写元数据段、**不会重新编码像素**，
/// 返图的压缩数据逐字节保持原样（实测验证过）。若改用 ImageIO 的常规写法
/// （`CGImageDestinationAddImageFromSource`），整张图会被重编一遍，对修图交付物来说不可接受。
enum PhotoMetadataCopier {

    /// 这几个标签必须摘掉，否则会把返图写坏：
    /// - `exif:PixelXDimension` / `exif:PixelYDimension`：返图可能被裁过、换成别的尺寸，
    ///   照抄原图的尺寸会让元数据与实际画面矛盾（实测确实会写错）；
    /// - `tiff:Orientation`：原图若带 90°/270° 旋转标记，而返图导出时像素已经摆正，
    ///   照抄这个标记会让返图在看图软件里被显示成歪的。
    ///
    /// JPG 转 PSD 生成 XMP 时也按同一口径摘（见 ImageLoader.xmp）。
    static let unsafeTagPaths: [CFString] = [
        "exif:PixelXDimension" as CFString,
        "exif:PixelYDimension" as CFString,
        "tiff:Orientation" as CFString,
    ]

    /// 把 `source` 的 Exif / IPTC / TIFF 复制到 `target`。
    /// `target` 会被原地替换，像素数据不变；原图文件不会被碰。
    static func copy(from source: URL, to target: URL) -> MetadataCopyResult {
        let manager = FileManager.default

        guard let sourceImage = CGImageSourceCreateWithURL(source as CFURL, nil),
              let original = CGImageSourceCopyMetadataAtIndex(sourceImage, 0, nil),
              let metadata = CGImageMetadataCreateMutableCopy(original) else {
            return .skippedNoSource
        }

        // ImageIO 会把 Exif / IPTC 一起归到 CGImageMetadata 里，
        // 所以相机直出、没有 XMP 的原图同样取得到要用的信息。
        for path in unsafeTagPaths {
            _ = CGImageMetadataRemoveTagWithPath(metadata, nil, path)
        }
        // 摘完剩下的一个标签都没有，说明原图确实没有这部分信息
        guard hasAnyTag(metadata) else { return .skippedNoSource }

        guard let returnedImage = CGImageSourceCreateWithURL(target as CFURL, nil),
              let type = CGImageSourceGetType(returnedImage) else {
            return .failed("读不到返图文件")
        }

        // 先写到同目录的临时文件，成功后再整体替换，避免中途失败留下半个文件
        let temp = target.deletingLastPathComponent()
            .appendingPathComponent(".skintone-meta-\(UUID().uuidString)")
            .appendingPathExtension(target.pathExtension)
        guard let destination = CGImageDestinationCreateWithURL(temp as CFURL, type, 1, nil) else {
            return .failed("不支持的文件格式（\(type)）")
        }

        let options: [CFString: Any] = [
            kCGImageDestinationMetadata: metadata,
            kCGImageDestinationMergeMetadata: true,
        ]
        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(destination, returnedImage, options as CFDictionary, &error) else {
            try? manager.removeItem(at: temp)
            let reason = error.map { ($0.takeRetainedValue() as Error).localizedDescription } ?? "写入失败"
            return .failed(reason)
        }

        do {
            _ = try manager.replaceItemAt(target, withItemAt: temp)
        } catch {
            try? manager.removeItem(at: temp)
            return .failed(error.localizedDescription)
        }
        return .copied
    }

    /// 元数据里是否还剩至少一个标签
    private static func hasAnyTag(_ metadata: CGImageMetadata) -> Bool {
        var found = false
        CGImageMetadataEnumerateTagsUsingBlock(metadata, nil, nil) { _, _ in
            found = true
            return false   // 找到一个就停
        }
        return found
    }
}
