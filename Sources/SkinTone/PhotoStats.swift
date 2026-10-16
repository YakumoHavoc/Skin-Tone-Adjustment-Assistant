import AppKit
import ImageIO

/// 一张照片的影调与色调统计，供仿色比对使用。
/// 与肤色模块完全独立：这里只做整图统计，不做单点取色。
struct PhotoStats: Hashable {

    /// 影调五区（0–255 划分，与 Photoshop 直方图的说法一致）
    static let zoneNames = ["最暗部", "暗部", "中间调", "亮部", "最亮部"]
    static let zoneRanges = ["0–63", "64–127", "128–191", "192–223", "224–255"]

    /// 十二色相环上的六个色相带（每 60° 一带）
    static let bandNames = ["红", "黄", "绿", "青", "蓝", "洋红"]
    static let bandRanges = ["330°–30°", "30°–90°", "90°–150°", "150°–210°", "210°–270°", "270°–330°"]

    let name: String
    let pixelCount: Int

    // MARK: 影调
    let meanL: Double          // 平均明度 0...1
    let medianL: Double        // 中位明度
    let p1L: Double            // 1% 分位，代表最暗部边界
    let p99L: Double           // 99% 分位，代表最亮部边界
    let stdL: Double           // 明度标准差，越大对比越强
    let zones: [Double]        // 五区占比，合计 1
    let histogram: [Double]    // 256 桶直方图，按最大值归一化

    // MARK: 色调
    let meanR: Double
    let meanG: Double
    let meanB: Double
    let colorShare: Double     // 彩度 ≥ 15% 的像素占比
    let meanSat: Double        // 有彩度像素的平均饱和度
    let mainHue: Double        // 有彩度像素的加权平均色相（无彩度时为 -1）
    let bandShares: [Double]   // 六个色相带在有彩度像素中的占比
    let bandHues: [Double]     // 各色相带平均色相（无像素为 -1）
    let bandSats: [Double]     // 各色相带平均饱和度

    var blackPoint: Int { Int((p1L * 255).rounded()) }
    var whitePoint: Int { Int((p99L * 255).rounded()) }
    var medianPoint: Int { Int((medianL * 255).rounded()) }
    var contrastText: String { String(format: "%.0f", stdL * 255) }
    var warmth: Double { meanR - meanB }

    /// 有最暗部信息（1% 分位落在 20/255 以内）＝ 全影调
    var isFullRange: Bool { p1L <= 0.08 }
    /// 最暗部边界偏高 ＝ 画面偏软
    var isSoftRange: Bool { p1L >= 0.14 }

    var mainHueText: String {
        mainHue < 0 ? "几乎无彩色" : String(format: "H %.0f° · %@", mainHue, ColorEngine.hueFamily(mainHue))
    }

    var dominantBandIndex: Int {
        var best = 0
        for (index, share) in bandShares.enumerated() where share > bandShares[best] { best = index }
        return best
    }

    /// 影调一句话概览，如「最暗部 0.4% · 中间调 46% · 最亮部 6%」
    var toneBrief: String {
        String(format: "最暗部 %.0f%% · 中间调 %.0f%% · 最亮部 %.0f%%",
               zones[0] * 100, zones[2] * 100, zones[4] * 100)
    }

    /// 影调另一句：黑白端点与对比
    var rangeBrief: String {
        "\(blackPoint)–\(whitePoint)  对比度 \(contrastText)  平均明度 \(Int((meanL * 255).rounded()))"
    }
}

/// 照片载入与统计
enum PhotoAnalyzer {

    /// 载入照片（缩到 maxPixel 以便快速统计），返回统计结果与用于显示的图
    static func load(url: URL, maxPixel: Int = 640) -> (stats: PhotoStats, image: NSImage)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        guard let pixels = rgbPixels(cgImage) else { return nil }
        let stats = analyze(name: url.lastPathComponent, pixels: pixels,
                            width: cgImage.width, height: cgImage.height)
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        return (stats, image)
    }

    /// 六个色相带的分带索引（红 / 黄 / 绿 / 青 / 蓝 / 洋红 各占 60°）
    static func bandIndex(_ hue: Double) -> Int {
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        return Int((h + 30).truncatingRemainder(dividingBy: 360) / 60)
    }

    /// 把 CGImage 画进 RGBX 缓冲（先铺白底，避免带透明通道的图被压暗）
    private static func rgbPixels(_ image: CGImage) -> [UInt8]? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        var buffer = [UInt8](repeating: 255, count: w * h * 4)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return drawn ? buffer : nil
    }

    /// 单次遍历算出全部统计量
    static func analyze(name: String, pixels: [UInt8], width: Int, height: Int) -> PhotoStats {
        let count = width * height
        var hist = [Int](repeating: 0, count: 256)
        var sumR = 0.0, sumG = 0.0, sumB = 0.0
        var bandCount = [Int](repeating: 0, count: 6)
        var bandSatSum = [Double](repeating: 0, count: 6)
        var bandSin = [Double](repeating: 0, count: 6)
        var bandCos = [Double](repeating: 0, count: 6)
        var colorCount = 0
        var satSum = 0.0
        var globalSin = 0.0, globalCos = 0.0, globalWeight = 0.0

        for i in stride(from: 0, to: count * 4, by: 4) {
            let r = Double(pixels[i]) / 255
            let g = Double(pixels[i + 1]) / 255
            let b = Double(pixels[i + 2]) / 255
            sumR += r; sumG += g; sumB += b

            let l = 0.2126 * r + 0.7152 * g + 0.0722 * b
            hist[min(255, max(0, Int((l * 255).rounded())))] += 1

            let hsb = RGBColor(r: r, g: g, b: b).hsb
            guard hsb.saturation >= 0.15 else { continue }
            colorCount += 1
            satSum += hsb.saturation
            let weight = hsb.saturation
            let rad = hsb.hue * .pi / 180
            let band = bandIndex(hsb.hue)
            bandCount[band] += 1
            bandSatSum[band] += hsb.saturation
            bandSin[band] += sin(rad) * weight
            bandCos[band] += cos(rad) * weight
            globalSin += sin(rad) * weight
            globalCos += cos(rad) * weight
            globalWeight += weight
        }

        func percentile(_ p: Double) -> Double {
            let target = max(1, Int(Double(count) * p))
            var acc = 0
            for value in 0..<256 {
                acc += hist[value]
                if acc >= target { return Double(value) / 255 }
            }
            return 1
        }

        var meanL = 0.0
        for value in 0..<256 { meanL += Double(value) / 255 * Double(hist[value]) / Double(count) }
        var variance = 0.0
        for value in 0..<256 {
            let diff = Double(value) / 255 - meanL
            variance += diff * diff * Double(hist[value]) / Double(count)
        }

        var zones = [Double](repeating: 0, count: 5)
        for value in 0..<256 {
            let share = Double(hist[value]) / Double(count)
            switch value {
            case ...63:     zones[0] += share
            case 64...127:  zones[1] += share
            case 128...191: zones[2] += share
            case 192...223: zones[3] += share
            default:        zones[4] += share
            }
        }

        let peak = Double(hist.max() ?? 1)
        let histogram = hist.map { peak > 0 ? Double($0) / peak : 0 }

        func circularMean(_ sinSum: Double, _ cosSum: Double) -> Double {
            guard abs(sinSum) > 0.000001 || abs(cosSum) > 0.000001 else { return -1 }
            let deg = atan2(sinSum, cosSum) * 180 / .pi
            return (deg + 360).truncatingRemainder(dividingBy: 360)
        }

        var bandShares = [Double](repeating: 0, count: 6)
        var bandHues = [Double](repeating: -1, count: 6)
        var bandSats = [Double](repeating: 0, count: 6)
        for band in 0..<6 where bandCount[band] > 0 {
            bandShares[band] = Double(bandCount[band]) / Double(max(1, colorCount))
            bandHues[band] = circularMean(bandSin[band], bandCos[band])
            bandSats[band] = bandSatSum[band] / Double(bandCount[band])
        }

        return PhotoStats(
            name: name,
            pixelCount: count,
            meanL: meanL,
            medianL: percentile(0.5),
            p1L: percentile(0.01),
            p99L: percentile(0.99),
            stdL: variance.squareRoot(),
            zones: zones,
            histogram: histogram,
            meanR: sumR / Double(count),
            meanG: sumG / Double(count),
            meanB: sumB / Double(count),
            colorShare: Double(colorCount) / Double(count),
            meanSat: colorCount > 0 ? satSum / Double(colorCount) : 0,
            mainHue: circularMean(globalSin, globalCos),
            bandShares: bandShares,
            bandHues: bandHues,
            bandSats: bandSats
        )
    }
}
