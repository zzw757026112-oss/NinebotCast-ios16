import Foundation
import UIKit
import os.log

/// App → 录屏扩展的方向接力。
///
/// 背景：iOS 16 下 ReplayKit 永远给竖帧（1290x2796），横屏内容顺时针歪在
/// 里面；扩展里 UIDevice/UIScreen 测不到方向（恒为竖屏），1.0.2 的检测
/// 在扩展里永远返回 false，横屏镜像就一直是中间一条竖条。
/// 主 App 能正常测到方向，所以由 App 发、扩展收。
///
/// 通道是 Darwin 通知（CFNotificationCenterGetDarwinNotifyCenter）：
/// 不需要 App Groups、不需要任何 entitlement、自签名免费证书也能用。
/// Darwin 通知不带 userInfo，方向编码在通知名字里：
///   com.corpsezhao.ninebotcast.orientation.portrait
///   com.corpsezhao.ninebotcast.orientation.portraitUpsideDown
///   com.corpsezhao.ninebotcast.orientation.landscapeLeft
///   com.corpsezhao.ninebotcast.orientation.landscapeRight
///   com.corpsezhao.ninebotcast.orientation.unknown
///
/// 帧路径只读一个缓存的 enum 值（NSLock 保护），不分配、不阻塞；
/// 方向变化时才记一条 os_log。App 被杀、通知没到，扩展就走老兜底
/// （fit 竖条），绝不崩、绝不卡帧。
enum OrientationRelay {
    static let prefix = "com.corpsezhao.ninebotcast.orientation"
    /// 手动方向通知名：com.corpsezhao.ninebotcast.rotation.manual.<0|90|180|270>，
    /// 0 = 自动（清除手动指定）。用户在镜像卡片里点的方向，靠它发给扩展。

    enum Orientation: String {
        case portrait
        case portraitUpsideDown
        case landscapeLeft
        case landscapeRight
        case unknown
    }

    private static let log = Logger(subsystem: "com.corpsezhao.ninebotcast", category: "broadcast")
    private static let lock = NSLock()
    private static var _current: Orientation = .unknown

    /// 扩展读这个：最近一次收到的方向；没收到过就是 .unknown。
    static var current: Orientation {
        lock.lock()
        defer { lock.unlock() }
        return _current
    }

    private static let manualPrefix = "com.corpsezhao.ninebotcast.rotation.manual"
    private static var _manualDegrees: Int = 0 // 0 = 自动，90/180/270 = 用户手动指定

    /// 扩展读这个：用户手动选的镜像方向；0 表示自动（走下面的方向接力）。
    static var manualDegrees: Int {
        lock.lock()
        defer { lock.unlock() }
        return _manualDegrees
    }

    static func manualName(for degrees: Int) -> CFString {
        "\(manualPrefix).\(degrees)" as CFString
    }

    static func manualDegrees(fromName name: CFString) -> Int? {
        let s = name as String
        guard s.hasPrefix(manualPrefix + ".") else { return nil }
        return Int(s.dropFirst(manualPrefix.count + 1))
    }

    static func name(for orientation: Orientation) -> CFString {
        "\(prefix).\(orientation.rawValue)" as CFString
    }

    static func orientation(fromName name: CFString) -> Orientation? {
        let s = name as String
        guard s.hasPrefix(prefix + ".") else { return nil }
        return Orientation(rawValue: String(s.dropFirst(prefix.count + 1)))
    }

    // MARK: - 扩展：收

    private static var observing = false

    /// 扩展启动时调一次（SampleHandler.init）：订阅 5 个方向通知。
    /// 回调可能在任意线程来，只存一个 enum 值，不做别的。
    static func startObserving() {
        lock.lock()
        guard !observing else { lock.unlock(); return }
        observing = true
        lock.unlock()

        let center = CFNotificationCenterGetDarwinNotifyCenter()
        for orientation in [Orientation.portrait, .portraitUpsideDown,
                            .landscapeLeft, .landscapeRight, .unknown] {
            CFNotificationCenterAddObserver(center, nil, { _, _, name, _, _ in
                guard let name, let o = OrientationRelay.orientation(fromName: name.rawValue) else { return }
                OrientationRelay.setCurrent(o)
            }, name(for: orientation), nil, .deliverImmediately)
        }
        // 手动方向：再订阅 4 个角度，用户一点就生效。
        for degrees in [0, 90, 180, 270] {
            CFNotificationCenterAddObserver(center, nil, { _, _, name, _, _ in
                guard let name, let d = OrientationRelay.manualDegrees(fromName: name.rawValue) else { return }
                OrientationRelay.setManualCurrent(d)
            }, manualName(for: degrees), nil, .deliverImmediately)
        }
    }

    private static func setManualCurrent(_ degrees: Int) {
        lock.lock()
        let changed = degrees != _manualDegrees
        _manualDegrees = degrees
        lock.unlock()
        if changed {
            log.info("手动方向接力：App 说镜像转 \(degrees)°（0=自动）")
        }
    }

    private static func setCurrent(_ orientation: Orientation) {
        lock.lock()
        let changed = orientation != _current
        _current = orientation
        lock.unlock()
        if changed {
            log.info("方向接力：App 说现在是 \(orientation.rawValue)")
        }
    }

    // MARK: - 主 App：发

    private static var postingStarted = false
    private static var postObserver: NSObjectProtocol?
    private static var postTimer: DispatchSourceTimer?

    /// 主 App 启动时调一次（NinebotProPlusApp.init）。
    /// 方向变化立刻发一次；另外每 2 秒重发一次当前方向——扩展可能
    /// 在方向变化之后才启动，靠周期重发在 2 秒内学会当前方向。
    /// 平放（faceUp/faceDown）不发：保持上一个有效方向。
    /// 发通知本身很轻（一条 mach 消息），失败也不会抛异常、不崩。
    static func startPosting() {
        guard !postingStarted else { return }
        postingStarted = true
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        postObserver = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification,
            object: nil, queue: nil) { _ in
            OrientationRelay.postCurrent()
        }
        postCurrent()
        postManualRotation()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(deadline: .now() + 2, repeating: .seconds(2))
        timer.setEventHandler {
            OrientationRelay.postCurrent()
            OrientationRelay.postManualRotation()
        }
        timer.resume()
        postTimer = timer
    }

    /// 主 App：用户在镜像卡片里手动选了方向（0=自动）。立即发一次，
    /// 之后每 2 秒随方向一起重发，扩展晚启动也能在 2 秒内学会。
    static func setManualRotation(_ degrees: Int) {
        lock.lock()
        _manualDegrees = degrees
        lock.unlock()
        postManualRotation()
        log.info("手动方向：\(degrees)°（0=自动）")
    }

    private static func postManualRotation() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(rawValue: manualName(for: manualDegrees)), nil, nil, true)
    }

    private static func postCurrent() {
        let orientation: Orientation
        switch UIDevice.current.orientation {
        case .portrait: orientation = .portrait
        case .portraitUpsideDown: orientation = .portraitUpsideDown
        case .landscapeLeft: orientation = .landscapeLeft
        case .landscapeRight: orientation = .landscapeRight
        default: return // unknown / faceUp / faceDown：不发，保持上一个方向
        }
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(rawValue: name(for: orientation)), nil, nil, true)
    }
}
