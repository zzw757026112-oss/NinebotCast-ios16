import UIKit
import CoreVideo
import CoreGraphics
import CoreImage

/// 画面源共用的渲染工具：建 buffer、旋转、铺满（aspect-fill）。
/// 图片、视频帧、摄像头帧都走这里，保证「铺满全屏、不露黑边」。
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

    /// CIImage 等比放大到铺满目标尺寸并居中（超出部分被裁掉）
    static func aspectFillTransform(_ image: CIImage, destWidth: Int, destHeight: Int) -> CIImage {
        let ext = image.extent
        guard ext.width > 0, ext.height > 0 else { return image }
        let scale = max(CGFloat(destWidth) / ext.width, CGFloat(destHeight) / ext.height)
        var ci = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let e2 = ci.extent
        ci = ci.transformed(by: CGAffineTransform(
            translationX: CGFloat(destWidth) / 2 - e2.midX,
            y: CGFloat(destHeight) / 2 - e2.midY))
        return ci
    }

    /// 图片路径：先旋转（0/90/180/270），再铺满画进目标 buffer
    static func drawImage(_ image: UIImage, rotation: Int, width: Int, height: Int) -> CVPixelBuffer? {
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
        let scale = max(w / iw, h / ih) // 铺满：取大边，多余裁掉
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
