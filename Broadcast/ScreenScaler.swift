import Accelerate
import CoreImage
import CoreVideo
import Foundation
import UIKit
import os.log

/// 转正方向：录屏帧本身不会跟着手机转。
/// 手机横过来时，帧还是竖的（1290x2796），横屏内容横着存在里面；
/// 竖屏内容保持竖条 fit，横屏内容先转正再裁满。
/// 方向按实测照片定：用户那次横屏内容在帧里是顺时针歪的，
/// 逆时针转回来是正的。
private enum MirrorRotation {
    case rotateCW        // 内容逆时针歪 → 顺时针转正（手机 landscapeLeft）
    case rotateCCW       // 内容顺时针歪 → 逆时针转正（手机 landscapeRight）
}

/// 把录屏帧缩放到 848x480，复用目标 buffer。
///
/// 横屏源（宽 > 高，如手机横过来）：裁满（fill）——按大边缩放、居中裁掉
/// 多余的两边，铺满整个仪表，没有黑边。代价是左右各裁掉约 9% 的画面。
/// 竖屏源：保持 fit（整屏可见、两边黑边），因为竖屏画面裁满会把上下
/// 裁掉四分之三，没法看；竖屏在横屏仪表上本来就是中间一条竖条。
///
/// 内存纪律（录屏扩展只有约 50MB 预算）：
/// - 目标 buffer 只建 3 个轮换：VT 编码器可能还捏着前一帧，复用同一个
///   会写坏正在编码的画面；3 个配「在飞不超过 2 帧」的背压刚好够用。
/// - 源 buffer（屏幕原尺寸，一帧约 12MB）只在本次调用内读，绝不保留。
/// - BGRA 走 vImage（快、省内存）；其它格式走 CoreImage 兜底。
final class ScreenScaler {
    let outWidth = 848
    let outHeight = 480

    private let log = Logger(subsystem: "com.corpsezhao.ninebotcast", category: "broadcast")
    private var pool: [CVPixelBuffer] = []
    private var nextIndex = 0
    private lazy var ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var loggedFallback = false
    private var lastRotation: MirrorRotation?

    init() {
        // 让 UIDevice.current.orientation 可读：不调用这个，orientation 恒为 unknown。
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
    }

    private func makeDestBuffer() -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, outWidth, outHeight,
            kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let buffer else {
            log.error("建目标 buffer 失败 status=\(status)")
            return nil
        }
        return buffer
    }

    /// 返回缩放好的 848x480 BGRA buffer（来自轮换池，调用方不要长期持有）。
    func scale(_ src: CVPixelBuffer) -> CVPixelBuffer? {
        let srcWidth = CVPixelBufferGetWidth(src)
        let srcHeight = CVPixelBufferGetHeight(src)
        guard srcWidth > 0, srcHeight > 0 else { return nil }

        if pool.isEmpty {
            for _ in 0..<3 {
                guard let buffer = makeDestBuffer() else { return nil }
                pool.append(buffer)
            }
        }
        let dest = pool[nextIndex]
        nextIndex = (nextIndex + 1) % pool.count

        // 横屏内容存在竖帧里时先转正（方向见 rotationNeeded），再裁满。
        // 只有竖帧才可能需要转；横帧直接走下面的缩放。
        if let rotation = rotationNeeded(srcWidth: srcWidth, srcHeight: srcHeight) {
            if lastRotation != rotation {
                lastRotation = rotation
                log.info("横屏内容在竖帧里，转正方向：\(rotation == .rotateCW ? "顺时针" : "逆时针")")
            }
            return scaleRotated(src, srcWidth: srcWidth, srcHeight: srcHeight,
                                rotation: rotation, dest: dest)
        }
        lastRotation = nil

        let format = CVPixelBufferGetPixelFormatType(src)
        if format == kCVPixelFormatType_32BGRA {
            // 横屏裁满、竖屏 fit
            if srcWidth > srcHeight {
                return scaleFillBGRA(src, srcWidth: srcWidth, srcHeight: srcHeight, dest: dest)
            }
            return scaleBGRA(src, srcWidth: srcWidth, srcHeight: srcHeight, dest: dest)
        }
        if !loggedFallback {
            loggedFallback = true
            log.info("源格式不是 BGRA (\(format))，改走 CoreImage 兜底")
        }
        return scaleViaCoreImage(src, srcWidth: srcWidth, srcHeight: srcHeight, dest: dest)
    }

    // MARK: - 转正（横屏内容存在竖帧里）

    /// 帧是竖的但内容是横的，才需要转。方向来源按优先级：
    /// 1) App 接力来的方向（Darwin 通知，iOS 16 下唯一可靠的来源）；
    ///    App 说是竖屏就直接不转，App 没发过（.unknown）才往下走。
    /// 2) 旧兜底：扩展自己测（iOS 17+ 上可能有效，16 上恒为竖屏）。
    /// 方向映射不变：landscapeLeft（手机逆时针横过来）内容逆时针歪，
    /// 顺时针转正；landscapeRight 内容顺时针歪，逆时针转正。
    private func rotationNeeded(srcWidth: Int, srcHeight: Int) -> MirrorRotation? {
        guard srcWidth < srcHeight else { return nil }
        switch OrientationRelay.current {
        case .landscapeLeft: return .rotateCW
        case .landscapeRight: return .rotateCCW
        case .portrait, .portraitUpsideDown: return nil
        case .unknown: break
        }
        switch UIDevice.current.orientation {
        case .landscapeLeft: return .rotateCW
        case .landscapeRight: return .rotateCCW
        default: break
        }
        if UIScreen.main.bounds.width > UIScreen.main.bounds.height {
            return .rotateCCW
        }
        return nil
    }

    /// 转正 + 裁满，一步在 CoreImage 里完成，不用开整帧大 buffer
    /// （竖帧全尺寸约 14MB，扩展内存预算只有约 50MB）。
    /// CoreImage 里正角度是逆时针（y 朝上坐标系）。
    private func scaleRotated(_ src: CVPixelBuffer, srcWidth: Int, srcHeight: Int,
                              rotation: MirrorRotation, dest: CVPixelBuffer) -> CVPixelBuffer? {
        let angle: CGFloat = rotation == .rotateCW ? -.pi / 2 : .pi / 2
        let cx = CGFloat(srcWidth) / 2
        let cy = CGFloat(srcHeight) / 2
        let rot = CGAffineTransform(translationX: cx, y: cy)
            .rotated(by: angle)
            .translatedBy(x: -cx, y: -cy)
        let image = CIImage(cvPixelBuffer: src).transformed(by: rot)
        let r = image.extent // 转正后是 H x W，中心仍在 (cx, cy)
        let scale = max(Double(outWidth) / r.width, Double(outHeight) / r.height)
        let tx = (Double(outWidth) - r.width * scale) / 2 - Double(r.origin.x) * scale
        let ty = (Double(outHeight) - r.height * scale) / 2 - Double(r.origin.y) * scale
        let final = image
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: tx, y: ty))

        CVPixelBufferLockBaseAddress(dest, [])
        defer { CVPixelBufferUnlockBaseAddress(dest, []) }
        guard let destBase = CVPixelBufferGetBaseAddress(dest) else { return nil }
        memset(destBase, 0, CVPixelBufferGetBytesPerRow(dest) * outHeight)
        ciContext.render(final, to: dest,
                         bounds: CGRect(x: 0, y: 0, width: outWidth, height: outHeight),
                         colorSpace: CGColorSpaceCreateDeviceRGB())
        return dest
    }

    // MARK: - vImage（BGRA 主路径）

    private func scaleBGRA(_ src: CVPixelBuffer, srcWidth: Int, srcHeight: Int,
                           dest: CVPixelBuffer) -> CVPixelBuffer? {
        CVPixelBufferLockBaseAddress(src, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(src, .readOnly) }
        CVPixelBufferLockBaseAddress(dest, [])
        defer { CVPixelBufferUnlockBaseAddress(dest, []) }

        guard let srcBase = CVPixelBufferGetBaseAddress(src),
              let destBase = CVPixelBufferGetBaseAddress(dest) else { return nil }
        let srcRowBytes = CVPixelBufferGetBytesPerRow(src)
        let destRowBytes = CVPixelBufferGetBytesPerRow(dest)

        // fit：整屏可见，居中，余下部分黑边
        let scale = min(Double(outWidth) / Double(srcWidth),
                        Double(outHeight) / Double(srcHeight))
        let dw = max(2, Int(Double(srcWidth) * scale) & ~1)
        let dh = max(2, Int(Double(srcHeight) * scale) & ~1)
        let dx = (outWidth - dw) / 2
        let dy = (outHeight - dh) / 2

        // 整块先涂黑（RGB 均为 0；VT 编码 H.264 时忽略 alpha），再把画面缩进中间
        memset(destBase, 0, destRowBytes * outHeight)

        var srcBuf = vImage_Buffer(data: srcBase,
                                   height: vImagePixelCount(srcHeight),
                                   width: vImagePixelCount(srcWidth),
                                   rowBytes: srcRowBytes)
        let destPtr = destBase.advanced(by: dy * destRowBytes + dx * 4)
        var destBuf = vImage_Buffer(data: destPtr,
                                    height: vImagePixelCount(dh),
                                    width: vImagePixelCount(dw),
                                    rowBytes: destRowBytes)
        let err = vImageScale_ARGB8888(&srcBuf, &destBuf, nil, vImage_Flags(kvImageNoFlags))
        guard err == kvImageNoError else {
            log.error("vImageScale 失败 \(err)")
            return nil
        }
        return dest
    }

    // MARK: - vImage 裁满（横屏：铺满 848x480，两边裁掉多余部分）

    private func scaleFillBGRA(_ src: CVPixelBuffer, srcWidth: Int, srcHeight: Int,
                               dest: CVPixelBuffer) -> CVPixelBuffer? {
        CVPixelBufferLockBaseAddress(src, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(src, .readOnly) }
        CVPixelBufferLockBaseAddress(dest, [])
        defer { CVPixelBufferUnlockBaseAddress(dest, []) }

        guard let srcBase = CVPixelBufferGetBaseAddress(src),
              let destBase = CVPixelBufferGetBaseAddress(dest) else { return nil }
        let srcRowBytes = CVPixelBufferGetBytesPerRow(src)
        let destRowBytes = CVPixelBufferGetBytesPerRow(dest)

        // 按大边缩放：缩放后一边等于目标尺寸，另一边超出目标尺寸
        let scale = max(Double(outWidth) / Double(srcWidth),
                        Double(outHeight) / Double(srcHeight))
        let sw = max(outWidth, max(2, Int(Double(srcWidth) * scale) & ~1))
        let sh = max(outHeight, max(2, Int(Double(srcHeight) * scale) & ~1))

        // 先缩放到临时 buffer（横屏手机源约 1040x480，约 2MB），再居中拷出 848x480
        guard let tmp = malloc(sw * sh * 4) else {
            log.error("裁满临时 buffer 分配失败 \(sw)x\(sh)")
            return nil
        }
        defer { free(tmp) }

        var srcBuf = vImage_Buffer(data: srcBase,
                                   height: vImagePixelCount(srcHeight),
                                   width: vImagePixelCount(srcWidth),
                                   rowBytes: srcRowBytes)
        var tmpBuf = vImage_Buffer(data: tmp,
                                   height: vImagePixelCount(sh),
                                   width: vImagePixelCount(sw),
                                   rowBytes: sw * 4)
        var err = vImageScale_ARGB8888(&srcBuf, &tmpBuf, nil, vImage_Flags(kvImageNoFlags))
        guard err == kvImageNoError else {
            log.error("vImageScale（裁满）失败 \(err)")
            return nil
        }

        let sx = ((sw - outWidth) / 2) & ~1
        let sy = ((sh - outHeight) / 2) & ~1
        let tmpRowBytes = sw * 4
        for y in 0..<outHeight {
            let srcRow = tmp.advanced(by: (sy + y) * tmpRowBytes + sx * 4)
            let dstRow = destBase.advanced(by: y * destRowBytes)
            memcpy(dstRow, srcRow, outWidth * 4)
        }
        return dest
    }

    // MARK: - CoreImage 兜底（非 BGRA 源）

    private func scaleViaCoreImage(_ src: CVPixelBuffer, srcWidth: Int, srcHeight: Int,
                                   dest: CVPixelBuffer) -> CVPixelBuffer? {
        // 横屏裁满、竖屏 fit；裁满时 dx/dy 为负，render 时按 bounds 裁掉超出部分
        let scale = srcWidth > srcHeight
            ? max(Double(outWidth) / Double(srcWidth),
                  Double(outHeight) / Double(srcHeight))
            : min(Double(outWidth) / Double(srcWidth),
                  Double(outHeight) / Double(srcHeight))
        let dw = Double(srcWidth) * scale
        let dh = Double(srcHeight) * scale
        let dx = (Double(outWidth) - dw) / 2
        let dy = (Double(outHeight) - dh) / 2

        CVPixelBufferLockBaseAddress(dest, [])
        defer { CVPixelBufferUnlockBaseAddress(dest, []) }
        guard let destBase = CVPixelBufferGetBaseAddress(dest) else { return nil }
        memset(destBase, 0, CVPixelBufferGetBytesPerRow(dest) * outHeight)

        let image = CIImage(cvPixelBuffer: src)
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: dx, y: dy))
        ciContext.render(image, to: dest,
                         bounds: CGRect(x: 0, y: 0, width: outWidth, height: outHeight),
                         colorSpace: CGColorSpaceCreateDeviceRGB())
        return dest
    }
}
