import CoreFoundation
import Foundation

/// 车速中继：主 App → 录屏扩展，Darwin 通知（1.2.9）。
///
/// 仿 HUDDataRelay（音量中继）的逐名订阅做法：值必须量化成有限名字。
///   速度整数 km/h：com.corpsezhao.ninebotcast.speed.kmh.0..200
///   超速标志：com.corpsezhao.ninebotcast.speed.over.1 / .0
///   com.corpsezhao.ninebotcast.speed.clear
/// 订阅总数 201 + 2 + 1 = 204 个。
///
/// 只有骑行时才发：RideTracker.start() 调 startPosting（每 2 秒重发），
/// stop() 调 clear() + stopPosting()。新鲜度 3 秒：3 秒收不到就当
/// 没在骑行，HUD 的超速行消失。
/// HUD 只在超速时才画红行（平时不画，保持胶囊干净）。
enum SpeedRelay {
    static let prefix = "com.corpsezhao.ninebotcast.speed"
    static let clearName = "\(prefix).clear"

    /// 扩展端数据过期时间（见文件头：App 每 2 秒重发，3 秒足够）。
    static let freshness: TimeInterval = 3.0

    /// App 端重发间隔（跟 HUDSettingsRelay 一致）。
    static let repostInterval: TimeInterval = 2.0

    // MARK: - App 端：发

    private static let lock = NSLock()
    private static var lastSpeed: Int?
    private static var lastOver: Bool?
    private static var timer: DispatchSourceTimer?

    /// RideTracker 每秒调：值变了立刻发一次。
    static func update(speedKmh: Int, overspeed: Bool) {
        let kmh = min(200, max(0, speedKmh))
        lock.lock()
        let changed = lastSpeed != kmh || lastOver != overspeed
        lastSpeed = kmh
        lastOver = overspeed
        lock.unlock()
        if changed {
            post(speedKmh: kmh, overspeed: overspeed)
        }
        // 同时更新本进程的接收缓存：让 current 在 App 进程里也能读到
        //（HUDData.tick 直接读 current，App 内和扩展同一路子）。
        storeLocal(speedKmh: kmh, overspeed: overspeed)
    }

    static func clear() {
        lock.lock()
        lastSpeed = nil
        lastOver = nil
        lock.unlock()
        recvLock.lock()
        _speedKmh = -1
        _overspeed = false
        _updatedAt = nil
        recvLock.unlock()
        postName(clearName)
    }

    private static func storeLocal(speedKmh: Int, overspeed: Bool) {
        recvLock.lock()
        _speedKmh = speedKmh
        _overspeed = overspeed
        _updatedAt = Date()
        recvLock.unlock()
    }

    /// 骑行开始时调：每 2 秒把最新值重发一遍（扩展可能错过单次通知）。
    static func startPosting() {
        stopPosting()
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .background))
        t.schedule(deadline: .now() + repostInterval, repeating: repostInterval)
        t.setEventHandler {
            lock.lock()
            let s = lastSpeed
            let o = lastOver
            lock.unlock()
            if let s, let o {
                post(speedKmh: s, overspeed: o)
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

    private static func post(speedKmh: Int, overspeed: Bool) {
        postName("\(prefix).kmh.\(speedKmh)")
        postName("\(prefix).over.\(overspeed ? 1 : 0)")
    }

    private static func postName(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(rawValue: name as CFString),
            nil, nil, true)
    }

    // MARK: - 扩展端：收

    private static let recvLock = NSLock()
    private static var _speedKmh = -1
    private static var _overspeed = false
    private static var _updatedAt: Date?
    private static var observing = false

    /// 扩展端读到的最新值（nil = 还没收到过，或已过期 3 秒）。
    static var current: (speedKmh: Int, overspeed: Bool, updatedAt: Date?)? {
        recvLock.lock(); defer { recvLock.unlock() }
        guard let t = _updatedAt, Date().timeIntervalSince(t) < freshness, _speedKmh >= 0 else { return nil }
        return (speedKmh: _speedKmh, overspeed: _overspeed, updatedAt: t)
    }

    /// 扩展启动时调一次（SampleHandler.init 里）。
    /// 逐名订阅（OrientationRelay 同款，扩展里 proven）：速度 201 个
    /// 名字 + 超速标志 2 个 + clear 1 个，共 204 个。
    /// observing 守卫防止重复订阅导致双倍回调。
    static func startObserving() {
        lock.lock()
        guard !observing else { lock.unlock(); return }
        observing = true
        lock.unlock()
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        var names: [String] = [clearName]
        for v in 0...200 { names.append("\(prefix).kmh.\(v)") }
        names.append("\(prefix).over.0")
        names.append("\(prefix).over.1")
        for name in names {
            CFNotificationCenterAddObserver(
                center,
                nil,
                { _, _, cfName, _, _ in
                    guard let cfName else { return }
                    SpeedRelay.handle(name: cfName.rawValue as String)
                },
                name as CFString, nil, .deliverImmediately)
        }
    }

    private static func handle(name: String) {
        if name == clearName {
            recvLock.lock()
            _speedKmh = -1
            _overspeed = false
            _updatedAt = nil
            recvLock.unlock()
            return
        }
        guard name.hasPrefix(prefix + ".") else { return }
        let rest = String(name.dropFirst((prefix + ".").count))
        let parts = rest.split(separator: ".")
        guard parts.count == 2 else { return }
        recvLock.lock()
        defer { recvLock.unlock() }
        switch parts[0] {
        case "kmh":
            guard let v = Int(parts[1]), (0...200).contains(v) else { return }
            _speedKmh = v
            _updatedAt = Date()
        case "over":
            guard let v = Int(parts[1]), v == 0 || v == 1 else { return }
            _overspeed = v == 1
            _updatedAt = Date()
        default:
            return
        }
    }
}
