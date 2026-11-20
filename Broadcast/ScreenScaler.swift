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
    case rotate180       // 内容上下颠倒 → 转 180°（用户手动选）
}

/// 把录屏帧缩放到 848x480，复用目标 buffer。
///
/// 横屏源（宽 > 高，如手机横过来）：三档，按 DisplayFitRelay.current：
///   0 铺满（fill，默认）——按大边缩放、居中裁掉多余的两边，铺满整个仪表，
///     没有黑边。代价是左右各裁掉约 9% 的画面。
///   1 完整（fit）——按小边缩放，整幅画面都可见，上下各留约 44px 黑边。
///   2 拉伸（stretch）——横竖独立缩放，整幅画面硬拉到 848x480，无裁剪无黑边，
///     横向压到约 0.815，画面略压扁。
/// 几何原因：iPhone 竖屏 1290x2796，270° 翻转后是 2796x1290（2.17:1），
/// 仪表是 848x480（1.77:1），铺满、完整、拉伸三者没法同时满足。
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

        // 横屏内容存在竖帧里时先转正（方向见 rotationNeeded），再按模式缩放。
        // 只有竖帧才可能需要转；横帧直接走下面的缩放。
        if let rotation = rotationNeeded(srcWidth: srcWidth, srcHeight: srcHeight) {
            if lastRotation != rotation {
                lastRotation = rotation
                let dirLabel: String
                switch rotation {
                case .rotateCW: dirLabel = "顺时针"
                case .rotateCCW: dirLabel = "逆时针"
                case .rotate180: dirLabel = "180°"
                }
                log.info("横屏内容在竖帧里，转正方向：\(dirLabel)")
            }
            return scaleRotated(src, srcWidth: srcWidth, srcHeight: srcHeight,
                                rotation: rotation, dest: dest)
        }
        lastRotation = nil

        let format = CVPixelBufferGetPixelFormatType(src)
        if format == kCVPixelFormatType_32BGRA {
            // 横屏：按模式走 fill / fit / stretch；竖屏 fit
            if srcWidth > srcHeight {
                switch DisplayFitRelay.current {
                case DisplayFitRelay.modeFit:
                    return scaleBGRA(src, srcWidth: srcWidth, srcHeight: srcHeight, dest: dest)
                case DisplayFitRelay.modeStretch:
                    return scaleStretchBGRA(src, srcWidth: srcWidth, srcHeight: srcHeight, dest: dest)
                default:
                    return scaleFillBGRA(src, srcWidth: srcWidth, srcHeight: srcHeight, dest: dest)
                }
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
    /// 0) 用户手动选的方向（镜像卡片 0°/90°/180°/270°，0 = 自动）；
    ///    手动一旦指定就优先于一切自动检测，点一下下一帧就生效。
    /// 1) App 接力来的方向（Darwin 通知，iOS 16 下唯一可靠的来源）；
    ///    App 说是竖屏就直接不转，App 没发过（.unknown）才往下走。
    /// 2) 旧兜底：扩展自己测（iOS 17+ 上可能有效，16 上恒为竖屏）。
    /// 方向映射不变：landscapeLeft（手机逆时针横过来）内容逆时针歪，
    /// 顺时针转正；landscapeRight 内容顺时针歪，逆时针转正。
    /// 手动方向与图片来源同一约定：90° = 顺时针转 90°，270° = 逆时针转 90°。
    private func rotationNeeded(srcWidth: Int, srcHeight: Int) -> MirrorRotation? {
        guard srcWidth < srcHeight else { return nil }
        switch OrientationRelay.manualDegrees {
        case 90: return .rotateCW
        case 270: return .rotateCCW
        case 180: return .rotate180
        default: break // 0 或未知 → 自动
        }
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

    /// 转正 + 按模式缩放，一步在 CoreImage 里完成，不用开整帧大 buffer
    /// （竖帧全尺寸约 14MB，扩展内存预算只有约 50MB）。
    /// 铺满取大边（裁两边），完整显示取小边（留上下黑边），拉伸横竖独立缩放
    /// （硬拉到 848x480，无裁剪无黑边）。fit 时画面缩进中间，dest 已事先涂黑，
    /// 黑边就是底色；拉伸时画面正好铺满，tx/ty 为 0。
    /// CoreImage 里正角度是逆时针（y 朝上坐标系）。
    private func scaleRotated(_ src: CVPixelBuffer, srcWidth: Int, srcHeight: Int,
                              rotation: MirrorRotation, dest: CVPixelBuffer) -> CVPixelBuffer? {
        let angle: CGFloat
        switch rotation {
        case .rotateCW: angle = -.pi / 2
        case .rotateCCW: angle = .pi / 2
        case .rotate180: angle = .pi
        }
        let cx = CGFloat(srcWidth) / 2
        let cy = CGFloat(srcHeight) / 2
        let rot = CGAffineTransform(translationX: cx, y: cy)
            .rotated(by: angle)
            .translatedBy(x: -cx, y: -cy)
        let image = CIImage(cvPixelBuffer: src).transformed(by: rot)
        let r = image.extent // 转正后是 H x W，中心仍在 (cx, cy)
        // 拉伸：横竖独立缩放；否则铺满取大边、完整显示取小边
        let mode = DisplayFitRelay.current
        let scaleX: Double
        let scaleY: Double
        if mode == DisplayFitRelay.modeStretch {
            scaleX = Double(outWidth) / r.width
            scaleY = Double(outHeight) / r.height
        } else {
            let s = mode == DisplayFitRelay.modeFit
                ? min(Double(outWidth) / r.width, Double(outHeight) / r.height)
                : max(Double(outWidth) / r.width, Double(outHeight) / r.height)
            scaleX = s
            scaleY = s
        }
        let tx = (Double(outWidth) - r.width * scaleX) / 2 - Double(r.origin.x) * scaleX
        let ty = (Double(outHeight) - r.height * scaleY) / 2 - Double(r.origin.y) * scaleY
        let final = image
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
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

    // MARK: - vImage 拉伸（横屏：整幅画面硬拉到 848x480，无裁剪无黑边，横向略压扁）

    private func scaleStretchBGRA(_ src: CVPixelBuffer, srcWidth: Int, srcHeight: Int,
                                  dest: CVPixelBuffer) -> CVPixelBuffer? {
        CVPixelBufferLockBaseAddress(src, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(src, .readOnly) }
        CVPixelBufferLockBaseAddress(dest, [])
        defer { CVPixelBufferUnlockBaseAddress(dest, []) }

        guard let srcBase = CVPixelBufferGetBaseAddress(src),
              let destBase = CVPixelBufferGetBaseAddress(dest) else { return nil }
        let srcRowBytes = CVPixelBufferGetBytesPerRow(src)
        let destRowBytes = CVPixelBufferGetBytesPerRow(dest)

        // 直接缩进 dest（848x480，整块都是画面，不用涂黑、不用临时 buffer）
        var srcBuf = vImage_Buffer(data: srcBase,
                                   height: vImagePixelCount(srcHeight),
                                   width: vImagePixelCount(srcWidth),
                                   rowBytes: srcRowBytes)
        var destBuf = vImage_Buffer(data: destBase,
                                    height: vImagePixelCount(outHeight),
                                    width: vImagePixelCount(outWidth),
                                    rowBytes: destRowBytes)
        let err = vImageScale_ARGB8888(&srcBuf, &destBuf, nil, vImage_Flags(kvImageNoFlags))
        guard err == kvImageNoError else {
            log.error("vImageScale（拉伸）失败 \(err)")
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
        // 横屏：铺满（fill）/ 完整（fit）/ 拉伸（stretch，看模式）、竖屏 fit；
        // 裁满时 dx/dy 为负，render 时按 bounds 裁掉超出部分；
        // 拉伸时横竖独立缩放，dw/dh 正好等于目标尺寸，dx/dy 为 0。
        let mode = DisplayFitRelay.current
        let scaleX: Double
        let scaleY: Double
        if srcWidth > srcHeight, mode == DisplayFitRelay.modeStretch {
            scaleX = Double(outWidth) / Double(srcWidth)
            scaleY = Double(outHeight) / Double(srcHeight)
        } else {
            let scale: Double
            if srcWidth > srcHeight {
                scale = mode == DisplayFitRelay.modeFit
                    ? min(Double(outWidth) / Double(srcWidth),
                          Double(outHeight) / Double(srcHeight))
                    : max(Double(outWidth) / Double(srcWidth),
                          Double(outHeight) / Double(srcHeight))
            } else {
                scale = min(Double(outWidth) / Double(srcWidth),
                            Double(outHeight) / Double(srcHeight))
            }
            scaleX = scale
            scaleY = scale
        }
        let dw = Double(srcWidth) * scaleX
        let dh = Double(srcHeight) * scaleY
        let dx = (Double(outWidth) - dw) / 2
        let dy = (Double(outHeight) - dh) / 2

        CVPixelBufferLockBaseAddress(dest, [])
        defer { CVPixelBufferUnlockBaseAddress(dest, []) }
        guard let destBase = CVPixelBufferGetBaseAddress(dest) else { return nil }
        memset(destBase, 0, CVPixelBufferGetBytesPerRow(dest) * outHeight)

        let image = CIImage(cvPixelBuffer: src)
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            .transformed(by: CGAffineTransform(translationX: dx, y: dy))
        ciContext.render(image, to: dest,
                         bounds: CGRect(x: 0, y: 0, width: outWidth, height: outHeight),
                         colorSpace: CGColorSpaceCreateDeviceRGB())
        return dest
    }
}
