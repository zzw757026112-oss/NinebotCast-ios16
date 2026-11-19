import CoreFoundation
import Foundation
import os.log

private let relayLog = Logger(subsystem: "com.corpsezhao.ninebotcast", category: "license-relay")

/// 授权码中继：主 App → 录屏扩展，Darwin 通知。
///
/// 背景（1.1.3 实测）：授权码存在钥匙串，但 App 与扩展默认用的
/// 访问组不同——组名里带各自的 bundle id（App 是
/// com.corpsezhao.ninebotcast，扩展是
/// com.corpsezhao.ninebotcast.screencast），App 存的码扩展根本
/// 读不到。结果：App 里已激活（进了主界面），扩展却一直报
/// “未激活”，而主界面里又没有输入框，用户卡死。LicenseManager
/// 里的“默认共享同一访问组”注释是错的。
///
/// 跟音乐/音量中继同一套做法：码编进通知名，App 每 2 秒重发，
/// 扩展收到就存进自己的钥匙串（扩展自己的组，读写一致），
/// broadcastStarted 再查自己的钥匙串就有码了。没有 App Groups，
/// 只能这样传。
///
/// 码是 16 位 Crockford 字符（去横杠），通知名：
///   com.corpsezhao.ninebotcast.licensecode.<16位码>
enum LicenseRelay {
    static let prefix = "com.corpsezhao.ninebotcast.licensecode"

    /// App 端重发间隔。1.1.4 用 2 秒 + 后台 QoS 定时器，实测
    /// 扩展 3 秒窗口内收不到（定时器被节流 / App 切后台时停发），
    /// 1.1.5 改成 1 秒 + utility QoS，并且启动时立刻发一次。
    static let repostInterval: TimeInterval = 1.0

    private static let lock = NSLock()
    private static var timer: DispatchSourceTimer?
    private static var observing = false

    // MARK: - App 端：发

    /// 立刻发一次当前码（激活成功后调；startPosting 的 2 秒重发会接上）。
    /// 每次都重读钥匙串，所以换码后发的就是新码。
    static func postNow() {
        guard let code = LicenseManager.loadCode(), !code.isEmpty else { return }
        postName("\(prefix).\(LicenseManager.normalize(code))")
    }

    /// App 启动时调：每 1 秒把当前码重发一遍（扩展可能错过单次通知，
    /// 或扩展是后来才启动的）。1.1.5：第一次立刻发（不等 1 秒），
    /// 定时器用 utility QoS（background QoS 在 App 切后台时会被
    /// 系统节流，1.1.4 的 3 秒窗口就是这么错过的）。
    static func startPosting() {
        stopPosting()
        postNow()
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + repostInterval, repeating: repostInterval)
        t.setEventHandler { postNow() }
        t.resume()
        lock.lock()
        timer = t
        lock.unlock()
    }

    static func stopPosting() {
        lock.lock()
        timer?.cancel()
        timer = nil
        lock.unlock()
    }

    private static func postName(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(rawValue: name as CFString),
            nil, nil, true)
    }

    // MARK: - 扩展端：收

    /// 扩展启动时调一次（SampleHandler.init 里）。
    /// 用名字为 NULL 的观察者收全部 Darwin 通知再按前缀过滤
    ///（跟 HUDDataRelay 一样；observing 守卫防止重复订阅）。
    static func startObserving() {
        lock.lock()
        guard !observing else { lock.unlock(); return }
        observing = true
        lock.unlock()
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(
            center,
            nil,
            { _, _, cfName, _, _ in
                guard let cfName else { return }
                LicenseRelay.handle(name: cfName.rawValue as String)
            },
            nil, nil, .deliverImmediately)
    }

    private static func handle(name: String) {
        guard name.hasPrefix(prefix + ".") else { return }
        let code = String(name.dropFirst(prefix.count + 1))
        // 码是 16 位 Crockford 字符且签名要对得上；不对就丢弃。
        guard code.count == 16, LicenseManager.validate(code: code).isValid else {
            relayLog.info("license relay: 收到无效码，丢弃")
            return
        }
        // 存进扩展自己的钥匙串（扩展自己的访问组，读写一致），
        // broadcastStarted 查 currentStatus() 就能找到。saveCode
        // 已处理重复项（改成 update），换码也能覆盖。
        if LicenseManager.saveCode(code) {
            relayLog.info("license relay: 码已收到并存入扩展钥匙串")
        } else {
            relayLog.info("license relay: 码验证通过但存入钥匙串失败")
        }
    }
}
