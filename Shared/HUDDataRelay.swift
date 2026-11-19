import CoreFoundation
import Foundation

/// 音量中继：主 App → 录屏扩展，Darwin 通知。
///
/// 背景（1.1.0 实测）：录屏扩展进程里 AVAudioSession.outputVolume
/// 读到的是陈旧值（用户实测音量卡在 5% 不动）；主 App 进程里
/// 这个读数是真的，投图片/视频时音量实时更新就是证明。
///
/// 1.1.1–1.1.6 的教训：这个文件原来用名字为 NULL 的观察者收全部
/// Darwin 通知、回调里按前缀过滤。但 NULL 名观察者在广播扩展里
/// 静默失效——回调根本不触发，所以 1.1.6 实测音量还是卡住。
/// 方向接力（OrientationRelay）证明逐名订阅在扩展里是通的：
/// 它订阅 5 个方向 + 4 个手动角度的具体名字，全都收得到。
/// 所以 1.1.7 改成逐名订阅：值必须能量化成有限名字。
/// 音量是 0–100 的整数，只有 101 个名字，全部订阅：
///   com.corpsezhao.ninebotcast.huddata.volume.<0-100>
///
/// 1.1.9：音乐已删（九号 App 自带音乐显示），只中继音量。
/// 用户决定音量保持现状、不再修镜像实时性。
///
/// 新鲜度 3 秒：App 每 1 秒 tick（值变了立刻发）+ 每 2 秒重发，
/// 3 秒收不到就当 App 没在跑，扩展回落到本地读数（跟以前一样）。
enum HUDDataRelay {
    static let prefix = "com.corpsezhao.ninebotcast.huddata"
    static let clearName = "\(prefix).clear"

    /// 扩展端数据过期时间（见文件头：App 每 2 秒重发，3 秒足够）。
    static let freshness: TimeInterval = 3.0

    /// App 端重发间隔（跟 HUDSettingsRelay 一致）。
    static let repostInterval: TimeInterval = 2.0

    // MARK: - App 端：发

    private static let lock = NSLock()
    private static var lastValues: Int?
    private static var timer: DispatchSourceTimer?

    /// App 的 HUDData.tick() 每秒调：值变了立刻发一次。
    /// volume 是 0...1，-1 = 未知。
    static func update(volume: Float) {
        let v: Int? = volume >= 0 ? min(100, max(0, Int((volume * 100).rounded()))) : nil
        lock.lock()
        let changed = lastValues == nil || lastValues! != v
        lastValues = v
        lock.unlock()
        if changed {
            post(volume: v)
        }
        // 同时更新本进程的接收缓存：让 current 在 App 进程里也能读到
        //（App 内的 drawCopy 虽然直接读 HUDData.shared，但缓存保持一致不吃亏）。
        // 扩展端不调 update，只靠通知，所以两边都对。
        storeLocal(volume: v)
    }

    static func clear() {
        lock.lock()
        lastValues = nil
        lock.unlock()
        recvLock.lock()
        _volume = -1
        _updatedAt = nil
        recvLock.unlock()
        postName(clearName)
    }

    private static func storeLocal(volume: Int?) {
        recvLock.lock()
        _volume = volume.map { Float($0) / 100 } ?? -1
        _updatedAt = Date()
        recvLock.unlock()
    }

    /// App 启动时调：每 2 秒把最新值重发一遍（扩展可能错过单次通知）。
    static func startPosting() {
        stopPosting()
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .background))
        t.schedule(deadline: .now() + repostInterval, repeating: repostInterval)
        t.setEventHandler {
            lock.lock()
            let v = lastValues
            lock.unlock()
            if let v {
                post(volume: v)
            }
        }
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

    /// 音量发一条名字；未知（-1）时什么都不发。
    private static func post(volume: Int?) {
        if let volume {
            postName("\(prefix).volume.\(volume)")
        }
    }

    private static func postName(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(rawValue: name as CFString),
            nil, nil, true)
    }

    // MARK: - 扩展端：收

    private static let recvLock = NSLock()
    private static var _volume: Float = -1
    private static var _updatedAt: Date?
    private static var observing = false

    /// 扩展端读到的最新值（nil = 还没收到过，或已过期 3 秒）。
    /// volume 为 -1 = 没收到过音量。调用方（HUDData.tick 的扩展分支）
    /// 据此决定是用中继值还是回落本地读数。
    static var current: (volume: Float, updatedAt: Date?)? {
        recvLock.lock(); defer { recvLock.unlock() }
        guard let t = _updatedAt, Date().timeIntervalSince(t) < freshness else { return nil }
        return (volume: _volume, updatedAt: t)
    }

    /// 扩展启动时调一次（SampleHandler.init 里）。
    /// 逐名订阅（OrientationRelay 同款，扩展里 proven）：音量 101 个
    /// 名字 + clear 1 个，共 102 个。
    /// observing 守卫防止重复订阅导致双倍回调。
    static func startObserving() {
        lock.lock()
        guard !observing else { lock.unlock(); return }
        observing = true
        lock.unlock()
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        var names: [String] = [clearName]
        for pct in 0...100 {
            names.append("\(prefix).volume.\(pct)")
        }
        for name in names {
            CFNotificationCenterAddObserver(
                center,
                nil,
                { _, _, cfName, _, _ in
                    guard let cfName else { return }
                    HUDDataRelay.handle(name: cfName.rawValue as String)
                },
                name as CFString, nil, .deliverImmediately)
        }
    }

    private static func handle(name: String) {
        if name == clearName {
            recvLock.lock()
            _volume = -1
            _updatedAt = nil
            recvLock.unlock()
            return
        }
        guard name.hasPrefix(prefix + ".volume.") else { return }
        let payload = String(name.dropFirst((prefix + ".volume.").count))
        guard let pct = Int(payload), (0...100).contains(pct) else { return }
        recvLock.lock()
        _volume = Float(pct) / 100
        _updatedAt = Date()
        recvLock.unlock()
    }
}
