import Foundation
import os.log

/// 显示模式：主 App 里改，录屏扩展里收。
///
/// 背景（几何原因）：iPhone 14 Pro Max 竖屏 1290x2796，270° 翻转后是
/// 2796x1290（2.17:1），仪表是 848x480（1.77:1）。三档：
///   0 铺满（aspect-fill，取大边缩放）：按高度撑满仪表，左右各裁掉约 9% 的画面；
///   1 完整（aspect-fit，取小边缩放）：整幅画面都可见，上下各留约 44px 黑边；
///   2 拉伸（stretch，横竖独立缩放）：整幅画面硬拉到 848x480，无裁剪无黑边，
///     横向压到约 0.815（约 18% 横向压缩），画面略压扁，用户已接受。
/// 铺满、完整、拉伸三者没法同时满足，默认铺满（0）。
///
/// 通道是 Darwin 通知（CFNotificationCenterGetDarwinNotifyCenter），
/// 和方向接力同一个办法：不需要 App Groups、不需要任何 entitlement，
/// 自签名免费证书也能用。Darwin 通知不带 userInfo，模式值编码在
/// 通知名字里，只占 3 个名字（接力总数仍远低于约 2900 的上限）：
///   com.corpsezhao.ninebotcast.display.fit.0（铺满，默认）
///   com.corpsezhao.ninebotcast.display.fit.1（完整显示）
///   com.corpsezhao.ninebotcast.display.fit.2（拉伸）
///
/// App 改了模式立刻发一次，另外每 2 秒重发一次当前值——扩展可能
/// 在模式改完之后才启动，靠周期重发在 2 秒内学会。帧路径只读一个
/// 缓存的 Int（NSLock 保护），不分配、不阻塞。
enum DisplayFitRelay {
    static let prefix = "com.corpsezhao.ninebotcast.display.fit"

    /// 模式：0 铺满，1 完整，2 拉伸。
    static let modeFill = 0
    static let modeFit = 1
    static let modeStretch = 2

    private static let log = Logger(subsystem: "com.corpsezhao.ninebotcast", category: "broadcast")
    private static let lock = NSLock()
    private static var _current = modeFill

    /// 扩展读这个：最近一次收到的模式值；没收到过就是默认 0（铺满）。
    static var current: Int {
        lock.lock()
        defer { lock.unlock() }
        return _current
    }

    private static func name(for mode: Int) -> CFString {
        "\(prefix).\(mode)" as CFString
    }

    private static func mode(fromName name: CFString) -> Int? {
        let s = name as String
        guard s.hasPrefix(prefix + "."),
              let m = Int(s.dropFirst(prefix.count + 1)),
              (modeFill...modeStretch).contains(m) else { return nil }
        return m
    }

    // MARK: - 扩展：收

    private static var observing = false

    /// 扩展启动时调一次（SampleHandler.init）：订阅 3 个模式通知。
    /// 回调可能在任意线程来，只存一个 Int 值，不做别的。
    /// 注意：回调是 C 函数指针，不能捕获上下文——所以闭包里只调
    /// 全限定名的静态方法（DisplayFitRelay.mode(fromName:)），不直接
    /// 写 bare 的 `prefix`（那样会隐式捕获 self，编不过）。
    static func startObserving() {
        lock.lock()
        guard !observing else { lock.unlock(); return }
        observing = true
        lock.unlock()

        let center = CFNotificationCenterGetDarwinNotifyCenter()
        for mode in [modeFill, modeFit, modeStretch] {
            CFNotificationCenterAddObserver(center, nil, { _, _, name, _, _ in
                guard let name, let m = DisplayFitRelay.mode(fromName: name.rawValue) else { return }
                DisplayFitRelay.setCurrent(m)
            }, name(for: mode), nil, .deliverImmediately)
        }
    }

    private static func setCurrent(_ mode: Int) {
        lock.lock()
        let changed = mode != _current
        _current = mode
        lock.unlock()
        if changed {
            log.info("显示模式接力：App 说现在是 \(DisplayFitRelay.modeLabel(mode))")
        }
    }

    private static func modeLabel(_ mode: Int) -> String {
        switch mode {
        case modeFit: return "完整显示"
        case modeStretch: return "拉伸"
        default: return "铺满"
        }
    }

    // MARK: - 主 App：发

    private static var postingStarted = false
    private static var postTimer: DispatchSourceTimer?
    private static var _posted = modeFill

    /// 主 App 启动时调一次（NinebotProPlusApp.init）。
    /// 先读用户存好的模式值发一次，另外每 2 秒重发一次当前值。
    static func startPosting() {
        guard !postingStarted else { return }
        postingStarted = true
        lock.lock()
        _posted = DisplayFitRelay.clampedMode(UserDefaults.standard.integer(forKey: "nbc.displayMode"))
        lock.unlock()
        post()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(deadline: .now() + 2, repeating: .seconds(2))
        timer.setEventHandler { DisplayFitRelay.post() }
        timer.resume()
        postTimer = timer
    }

    /// 主 App：用户在镜像卡片里改了显示模式。存下并立刻发一次，
    /// 之后每 2 秒随周期重发，扩展晚启动也能在 2 秒内学会，下一帧就生效。
    static func setMode(_ mode: Int) {
        lock.lock()
        _posted = DisplayFitRelay.clampedMode(mode)
        lock.unlock()
        post()
        log.info("显示模式已发：\(mode)")
    }

    private static func clampedMode(_ mode: Int) -> Int {
        min(max(mode, modeFill), modeStretch)
    }

    private static func post() {
        lock.lock()
        let mode = _posted
        lock.unlock()
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(rawValue: name(for: mode)), nil, nil, true)
    }
}
