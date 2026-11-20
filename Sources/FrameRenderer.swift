import UIKit
import CoreVideo
import CoreGraphics
import CoreImage

/// 画面源共用的渲染工具：建 buffer、旋转、铺满（aspect-fill）或完整显示（aspect-fit）。
/// 图片、视频帧、摄像头帧都走这里。
/// 几何原因：iPhone 竖屏 1290x2796，270° 翻转后是 2796x1290（2.17:1），
/// 仪表是 848x480（1.77:1）。铺满（fill，取大边）按高度撑满、左右各裁
/// 约 9%；完整显示（fit，取小边）整幅可见、上下各留约 44px 黑边。
/// 两者没法同时做到，由 nbc.displayFit 开关二选一，默认铺满。
enum FrameRenderer {
    /// 建一块 BGRA 的目标尺寸 buffer
    static func makeBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        guard width > 16, height > 16 else { return nil }
        var buffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buffer) == kCVReturnSuccess,
            let pixelBuffer = buffer else { return nil }
        return pixelBuffer
    }

    /// CIImage 等比缩放到目标尺寸并居中。fill（默认）：铺满，超出部分被裁掉；
    /// fit：完整显示，整幅可见，余下部分黑边——调用方复用 dest buffer
    /// （CameraSource/VideoFrameSource 的 3 块轮换），不垫黑底的话黑边会
    /// 残留上一帧的画面，所以 fit 时直接在 CI 里垫一块黑底。
    static func aspectFillTransform(_ image: CIImage, destWidth: Int, destHeight: Int, fit: Bool = false) -> CIImage {
        let ext = image.extent
        guard ext.width > 0, ext.height > 0 else { return image }
        let scale = fit
            ? min(CGFloat(destWidth) / ext.width, CGFloat(destHeight) / ext.height)
            : max(CGFloat(destWidth) / ext.width, CGFloat(destHeight) / ext.height)
        var ci = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let e2 = ci.extent
        ci = ci.transformed(by: CGAffineTransform(
            translationX: CGFloat(destWidth) / 2 - e2.midX,
            y: CGFloat(destHeight) / 2 - e2.midY))
        if fit {
            let bg = CIImage(color: CIColor(red: 0, green: 0, blue: 0))
                .cropped(to: CGRect(x: 0, y: 0, width: destWidth, height: destHeight))
            ci = ci.composited(over: bg)
        }
        return ci
    }

    /// 图片路径：先旋转（0/90/180/270），再铺满或完整显示画进目标 buffer。
    /// 目标 buffer 事先已涂黑，fit 时画面缩进中间，黑边就是底色。
    static func drawImage(_ image: UIImage, rotation: Int, width: Int, height: Int, fit: Bool = false) -> CVPixelBuffer? {
        guard let cg0 = image.cgImage else { return nil }
        let cg: CGImage
        if rotation == 90 || rotation == 180 || rotation == 270 {
            guard let rotated = rotateCG(cg0, degrees: rotation) else { return nil }
            cg = rotated
        } else {
            cg = cg0
        }
        guard let buffer = makeBuffer(width: width, height: height) else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }

        let w = CGFloat(width), h = CGFloat(height)
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))

        let iw = CGFloat(cg.width), ih = CGFloat(cg.height)
        guard iw > 0, ih > 0 else { return buffer }
        // 完整：取小边，画面缩进中间、黑边；铺满：取大边，多余裁掉
        let scale = fit ? min(w / iw, h / ih) : max(w / iw, h / ih)
        let dw = iw * scale, dh = ih * scale
        context.interpolationQuality = .high
        context.draw(cg, in: CGRect(x: (w - dw) / 2, y: (h - dh) / 2, width: dw, height: dh))
        return buffer
    }

    /// 用 CGContext 旋转一张图（90/180/270，顺时针）
    static func rotateCG(_ cg: CGImage, degrees: Int) -> CGImage? {
        let isSide = (degrees == 90 || degrees == 270)
        let w = cg.width, h = cg.height
        let outW = isSide ? h : w
        let outH = isSide ? w : h
        guard outW > 0, outH > 0 else { return nil }
        guard let context = CGContext(
            data: nil, width: outW, height: outH,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        context.translateBy(x: CGFloat(outW) / 2, y: CGFloat(outH) / 2)
        context.rotate(by: CGFloat(Double(degrees) * Double.pi / 180.0))
        context.draw(cg, in: CGRect(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2,
                                    width: CGFloat(w), height: CGFloat(h)))
        return context.makeImage()
    }
}
