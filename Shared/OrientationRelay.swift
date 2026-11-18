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
                guard let name, let o = OrientationRelay.orientation(fromName: name) else { return }
                OrientationRelay.setCurrent(o)
            }, name(for: orientation), nil, .deliverImmediately)
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
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(deadline: .now() + 2, repeating: .seconds(2))
        timer.setEventHandler { OrientationRelay.postCurrent() }
        timer.resume()
        postTimer = timer
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
            name(for: orientation), nil, nil, true)
    }
}
