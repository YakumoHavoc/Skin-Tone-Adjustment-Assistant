import CoreGraphics
import Foundation
import ImageIO

/// 一张图像的内容指纹：不看文件名，只看画面本身长什么样。
///
/// 做法是感知哈希（dHash）：把图缩到极小（9×8 / 8×9 灰度格），再逐格比较相邻格的明暗高低，
/// 得到 128 位「明暗起伏」的编码。只保留「哪边更亮」这种相对关系，
/// 所以修脸、调色、重新压缩都不会改变它；而画面内容不同的两张照片会有几十位不同。
struct PhotoFingerprint: Hashable {

    /// 水平差分（9 列 × 8 行 → 64 位）：每行比较左右相邻格
    let horizontal: UInt64
    /// 垂直差分（8 列 × 9 行 → 64 位）：每列比较上下相邻格
    let vertical: UInt64
    /// 宽高比（按解码后的实际像素），用来核对构图有没有被裁过
    let aspect: Double

    /// 与另一指纹的差异，0…128，越小越像
    func distance(to other: PhotoFingerprint) -> Int {
        PhotoFingerprint.hamming(horizontal, other.horizontal)
            + PhotoFingerprint.hamming(vertical, other.vertical)
    }

    /// 宽高比的相对差异，0 表示完全一致
    func aspectDelta(to other: PhotoFingerprint) -> Double {
        guard aspect > 0, other.aspect > 0 else { return 1 }
        return abs(aspect - other.aspect) / max(aspect, other.aspect)
    }

    /// 两个编码里不同的位数
    static func hamming(_ a: UInt64, _ b: UInt64) -> Int { (a ^ b).nonzeroBitCount }
}

/// 指纹的计算：只做离屏解码与缩放，不碰 AppKit 视图对象，所以能放在后台队列里跑。
enum PhotoFingerprintMaker {

    /// 先按扩展名筛一遍，免得对文件夹里的文档、视频逐个试解码
    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "jpe", "png", "tif", "tiff", "heic", "heif",
        "bmp", "gif", "webp", "avif", "dng", "cr2", "cr3", "nef", "arw", "raf", "orf", "rw2"
    ]

    static func isImageFile(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }

    /// 算出指纹：先用 ImageIO 缩到 128px（顺带按 EXIF 摆正方向），再画进两个小灰度格。
    static func fingerprint(url: URL) -> PhotoFingerprint? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 128,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              image.width > 0, image.height > 0 else { return nil }
        guard let wide = grayscale(image, width: 9, height: 8),
              let tall = grayscale(image, width: 8, height: 9) else { return nil }

        return PhotoFingerprint(
            horizontal: gradient(wide, width: 9, height: 8, vertical: false),
            vertical: gradient(tall, width: 8, height: 9, vertical: true),
            aspect: Double(image.width) / Double(image.height)
        )
    }

    /// 把图缩画进 w×h 的灰度缓冲（先铺白底，免得带透明通道的图被压成纯黑）
    private static func grayscale(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var buffer = [UInt8](repeating: 255, count: width * height)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? buffer : nil
    }

    /// 逐格比较相邻格的明暗：前者更亮记 1，否则记 0。
    /// 横向时向右比（9 宽 × 8 高 = 64 位），纵向时向下比（8 宽 × 9 高 = 64 位）。
    private static func gradient(_ grid: [UInt8], width: Int, height: Int, vertical: Bool) -> UInt64 {
        var hash: UInt64 = 0
        var bit = 0
        for y in 0..<height {
            for x in 0..<width {
                let nextX = vertical ? x : x + 1
                let nextY = vertical ? y + 1 : y
                guard nextX < width, nextY < height else { continue }
                if grid[y * width + x] > grid[nextY * width + nextX] {
                    hash |= UInt64(1) << UInt64(bit)
                }
                bit += 1
            }
        }
        return hash
    }
}
