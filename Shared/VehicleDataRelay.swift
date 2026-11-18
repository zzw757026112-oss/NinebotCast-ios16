import CoreFoundation
import Foundation

/// 车辆数据中继：App（蓝牙读数）→ 广播扩展（HUD 显示），Darwin 通知。
///
/// 跟 OrientationRelay / HUDSettingsRelay 同一套做法：值编进通知名，
/// App 改值时立刻发、再每 2 秒重发一次；扩展订阅全部名字并缓存最新值。
/// 没有 App Groups，所以只能这样传。
///
/// 连续量不能一个值一个通知名（那要订阅无穷多个），所以量化成有限网格：
///   速度：整数 km/h，0–99（`<0` 或 ≥100 时截到边界）
///   电压：整数 V，0–99
///   电流：整数 A 的绝对值，0–99（回充时为负——只传大小，符号丢掉）
///   功率：每 10W 一档，0–990W（取绝对值再截，符号同样丢掉）
/// 精度损失和符号丢失对仪表 HUD 够用；App 内的车辆卡片直接读 BLE
/// 客户端，不走这条中继，所以卡片上是带符号的完整精度。
enum VehicleDataRelay {
    static let prefix = "com.corpsezhao.ninebotcast.vehicle"
    static let clearName = "\(prefix).clear"

    /// 扩展端数据过期时间：超过这个没收到新值，就当车断了、不画。
    static let freshness: TimeInterval = 5.0

    /// App 端重发间隔（跟 OrientationRelay / HUDSettingsRelay 一致）。
    static let repostInterval: TimeInterval = 2.0

    // MARK: - App 端：发

    private static let lock = NSLock()
    private static var lastValues: (speed: Int, volt: Int, current: Int, power: Int)?
    private static var timer: DispatchSourceTimer?

    static func update(speedKmh: Double, voltageV: Double, currentA: Double, powerW: Double) {
        let q = (
            speed: clampInt(speedKmh),
            volt: clampInt(voltageV),
            current: clampInt(abs(currentA)),
            power: clampInt(abs(powerW) / 10.0)
        )
        lock.lock()
        let changed = lastValues == nil || lastValues! != q
        lastValues = q
        lock.unlock()
        if changed {
            post(q)
        }
        // 同时更新本进程的接收缓存：App 内的 drawCopy（相册/视频/摄像
        // 头）也走 HUDRenderer，需要直接读到车辆数据，不经过通知回路。
        // 扩展端不调 update，只靠通知，所以两边都对。
        storeLocal(q)
    }

    static func clear() {
        lock.lock()
        lastValues = nil
        lock.unlock()
        recvLock.lock()
        _speedKmh = nil
        _voltageV = nil
        _currentA = nil
        _powerW = nil
        _updatedAt = nil
        recvLock.unlock()
        postName(clearName)
    }

    private static func storeLocal(_ q: (speed: Int, volt: Int, current: Int, power: Int)) {
        recvLock.lock()
        _speedKmh = q.speed
        _voltageV = q.volt
        _currentA = q.current
        _powerW = q.power * 10
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
            let q = lastValues
            lock.unlock()
            if let q {
                post(q)
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

    private static func clampInt(_ v: Double) -> Int {
        min(99, max(0, Int(v.rounded())))
    }

    private static func post(_ q: (speed: Int, volt: Int, current: Int, power: Int)) {
        postName("\(prefix).speed.\(q.speed)")
        postName("\(prefix).volt.\(q.volt)")
        postName("\(prefix).current.\(q.current)")
        postName("\(prefix).power.\(q.power)")
    }

    private static func postName(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(rawValue: name as CFString),
            nil, nil, true)
    }

    // MARK: - 扩展端：收

    private static let recvLock = NSLock()
    private static var _speedKmh: Int?
    private static var _voltageV: Int?
    private static var _currentA: Int?
    private static var _powerW: Int?
    private static var _updatedAt: Date?

    /// 扩展端读到的最新值（nil = 还没收到过，或已过期）。
    static var current: (speedKmh: Int, voltageV: Int, currentA: Int, powerW: Int)? {
        recvLock.lock(); defer { recvLock.unlock() }
        guard let t = _updatedAt, Date().timeIntervalSince(t) < freshness,
              let s = _speedKmh, let v = _voltageV,
              let c = _currentA, let p = _powerW else { return nil }
        return (s, v, c, p)
    }

    /// 扩展启动时调（SampleHandler.init 里）。
    static func startObserving() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        var names: [String] = [clearName]
        for i in 0...99 {
            names.append("\(prefix).speed.\(i)")
            names.append("\(prefix).volt.\(i)")
            names.append("\(prefix).current.\(i)")
            names.append("\(prefix).power.\(i)")
        }
        for name in names {
            let cfName = CFNotificationName(rawValue: name as CFString)
            CFNotificationCenterAddObserver(
                center,
                nil,
                { _, _, cfName, _, _ in
                    guard let cfName else { return }
                    VehicleDataRelay.handle(name: cfName.rawValue as String)
                },
                cfName, nil, .deliverImmediately)
        }
    }

    private static func handle(name: String) {
        if name == clearName {
            recvLock.lock()
            _speedKmh = nil
            _voltageV = nil
            _currentA = nil
            _powerW = nil
            _updatedAt = nil
            recvLock.unlock()
            return
        }
        // 通知名是 com.corpsezhao.ninebotcast.vehicle.<项>.<值>：
        // 先去掉前缀，剩下的 "<项>.<值>" 只有两段。
        guard name.hasPrefix(prefix + ".") else { return }
        let rest = String(name.dropFirst(prefix.count + 1))
        let parts = rest.split(separator: ".")
        guard parts.count == 2,
              let value = Int(parts[1]) else { return }
        recvLock.lock()
        switch parts[0] {
        case "speed": _speedKmh = value
        case "volt": _voltageV = value
        case "current": _currentA = value
        case "power": _powerW = value * 10
        default: break
        }
        _updatedAt = Date()
        recvLock.unlock()
    }
}
