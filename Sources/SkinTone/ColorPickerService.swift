import AppKit

/// 屏幕取色服务：使用系统自带的取色放大镜（NSColorSampler）
/// 好处：无需「屏幕录制」权限，放大镜可放大到像素级，且支持任意应用之上取色
final class ColorPickerService {

    /// NSColorSampler 会在会话结束前被系统保留，这里持有一份引用更稳妥
    private var sampler: NSColorSampler?

    /// 开始取色；取消或失败时回调 nil
    func pick(completion: @escaping (RGBColor?) -> Void) {
        let sampler = NSColorSampler()
        self.sampler = sampler
        sampler.show { [weak self] color in
            self?.sampler = nil
            guard let color, let srgb = color.usingColorSpace(.sRGB) else {
                completion(nil)
                return
            }
            completion(RGBColor(r: Double(srgb.redComponent),
                                g: Double(srgb.greenComponent),
                                b: Double(srgb.blueComponent)))
        }
    }
}
