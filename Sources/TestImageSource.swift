import Foundation
import CoreVideo
import CoreGraphics
import CoreText

/// 测试图帧生成器：色条 + 移动滑块 + 帧计数文字。
///
/// 这个函数跑在后台队列上（20 帧/秒），所以**完全不用 UIKit**：
/// 颜色用 CGColor 直接构造，文字用 CoreText + CTFont，避免在非主线程碰 UIKit 静态状态。
/// 这也是上一版潜在闪退点之一。
enum TestImageSource {
    static func makeFrame(index: Int64, width: Int, height: Int) -> CVPixelBuffer? {
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

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }

        let w = CGFloat(width), h = CGFloat(height)

        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))

        // 彩条
        let colors: [CGColor] = [
            CGColor(red: 1, green: 1, blue: 1, alpha: 1),
            CGColor(red: 1, green: 1, blue: 0, alpha: 1),
            CGColor(red: 0, green: 1, blue: 1, alpha: 1),
            CGColor(red: 0, green: 1, blue: 0, alpha: 1),
            CGColor(red: 1, green: 0, blue: 1, alpha: 1),
            CGColor(red: 1, green: 0, blue: 0, alpha: 1),
            CGColor(red: 0, green: 0, blue: 1, alpha: 1),
            CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        ]
        let barWidth = w / CGFloat(colors.count)
        for (i, color) in colors.enumerated() {
            context.setFillColor(color)
            context.fill(CGRect(x: CGFloat(i) * barWidth, y: h * 0.45,
                                width: barWidth, height: h * 0.2))
        }

        // 移动滑块（证明画面在动）
        let travel = max(1, width - 80)
        let sliderX = CGFloat(Int(index % Int64(travel)))
        context.setFillColor(CGColor(red: 0.2, green: 0.9, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: sliderX, y: h * 0.72, width: 80, height: h * 0.12))

        // 帧计数
        let text = "NINEBOT CAST #\(index)"
        let fontSize = max(18, h * 0.09)
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let textAttrs: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        ]
        if let attributed = CFAttributedStringCreate(
            kCFAllocatorDefault, text as CFString, textAttrs as CFDictionary) {
            let line = CTLineCreateWithAttributedString(attributed)
            context.textPosition = CGPoint(x: 16, y: h * 0.18)
            CTLineDraw(line, context)
        }

        return pixelBuffer
    }
}
