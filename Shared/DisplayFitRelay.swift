import Foundation
import os.log

/// 「完整显示」开关：主 App 里改，录屏扩展里收。
///
/// 背景（几何原因）：iPhone 14 Pro Max 竖屏 1290x2796，270° 翻转后是
/// 2796x1290（2.17:1），仪表是 848x480（1.77:1）。铺满（aspect-fill，
/// 取大边缩放）按高度撑满仪表，左右各裁掉约 9% 的画面；完整显示
/// （aspect-fit，取小边缩放）整幅画面都可见，上下各留约 44px 黑边。
/// 铺满和不裁剪没法同时做到，开关就是二选一，默认铺满（false）。
///
/// 通道是 Darwin 通知（CFNotificationCenterGetDarwinNotifyCenter），
/// 和方向接力同一个办法：不需要 App Groups、不需要任何 entitlement，
/// 自签名免费证书也能用。Darwin 通知不带 userInfo，开关值编码在
/// 通知名字里，只占 2 个名字（接力总数仍远低于约 2900 的上限）：
///   com.corpsezhao.ninebotcast.display.fit.0（铺满，默认）
///   com.corpsezhao.ninebotcast.display.fit.1（完整显示）
///
/// App 改了开关立刻发一次，另外每 2 秒重发一次当前值——扩展可能
/// 在开关改完之后才启动，靠周期重发在 2 秒内学会。帧路径只读一个
/// 缓存的 Bool（NSLock 保护），不分配、不阻塞。
enum DisplayFitRelay {
    static let prefix = "com.corpsezhao.ninebotcast.display.fit"

    private static let log = Logger(subsystem: "com.corpsezhao.ninebotcast", category: "broadcast")
    private static let lock = NSLock()
    private static var _current = false

    /// 扩展读这个：最近一次收到的开关值；没收到过就是默认 false（铺满）。
    static var current: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _current
    }

    private static func name(for fit: Bool) -> CFString {
        "\(prefix).\(fit ? 1 : 0)" as CFString
    }

    private static func fit(fromName name: CFString) -> Bool? {
        let s = name as String
        guard s.hasPrefix(prefix + ".") else { return nil }
        return s == "\(prefix).1"
    }

    // MARK: - 扩展：收

    private static var observing = false

    /// 扩展启动时调一次（SampleHandler.init）：订阅 2 个开关通知。
    /// 回调可能在任意线程来，只存一个 Bool 值，不做别的。
    /// 注意：回调是 C 函数指针，不能捕获上下文——所以闭包里只调
    /// 全限定名的静态方法（DisplayFitRelay.fit(fromName:)），不直接
    /// 写 bare 的 `prefix`（那样会隐式捕获 self，编不过）。
    static func startObserving() {
        lock.lock()
        guard !observing else { lock.unlock(); return }
        observing = true
        lock.unlock()

        let center = CFNotificationCenterGetDarwinNotifyCenter()
        for fit in [false, true] {
            CFNotificationCenterAddObserver(center, nil, { _, _, name, _, _ in
                guard let name, let f = DisplayFitRelay.fit(fromName: name.rawValue) else { return }
                DisplayFitRelay.setCurrent(f)
            }, name(for: fit), nil, .deliverImmediately)
        }
    }

    private static func setCurrent(_ fit: Bool) {
        lock.lock()
        let changed = fit != _current
        _current = fit
        lock.unlock()
        if changed {
            log.info("完整显示接力：App 说现在是 \(fit ? "完整显示" : "铺满")")
        }
    }

    // MARK: - 主 App：发

    private static var postingStarted = false
    private static var postTimer: DispatchSourceTimer?
    private static var _posted = false

    /// 主 App 启动时调一次（NinebotProPlusApp.init）。
    /// 先读用户存好的开关值发一次，另外每 2 秒重发一次当前值。
    static func startPosting() {
        guard !postingStarted else { return }
        postingStarted = true
        lock.lock()
        _posted = UserDefaults.standard.bool(forKey: "nbc.displayFit")
        lock.unlock()
        post()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(deadline: .now() + 2, repeating: .seconds(2))
        timer.setEventHandler { DisplayFitRelay.post() }
        timer.resume()
        postTimer = timer
    }

    /// 主 App：用户在镜像卡片里拨了完整显示开关。存下并立刻发一次，
    /// 之后每 2 秒随周期重发，扩展晚启动也能在 2 秒内学会，下一帧就生效。
    static func setFit(_ fit: Bool) {
        lock.lock()
        _posted = fit
        lock.unlock()
        post()
        log.info("完整显示开关已发：\(fit ? 1 : 0)")
    }

    private static func post() {
        lock.lock()
        let fit = _posted
        lock.unlock()
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(rawValue: name(for: fit)), nil, nil, true)
    }
}
