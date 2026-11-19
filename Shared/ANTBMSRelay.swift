import CoreFoundation
import Foundation

/// ANT BMS 电池数据中继：主 App → 录屏扩展，Darwin 通知。
///
/// 仿 HUDDataRelay（音量中继）的逐名订阅做法：值必须量化成有限名字。
/// 只传 5 个量（电芯明细不传）：
///   电压 0.01V：0–120.00V → volt.0..12000（1.2.5：原来 0.1V，仪表上
///     停着的车数值看着像冻住的——帧本身就是 0.01V 精度，现在全传过去）
///   电流 0.1A：-50.0–+50.0A → amp.0..1000（值 + 500；帧本身只有 0.1A 精度）
///   SOC 0.1%：0..100 → soc.0..1000（1.2.5：原来 1%，帧本身是 0.1% 精度）
///   最高温度 1°C：-40–+80 → temp.0..120（值 + 40；帧本身就是整数 °C）
///   电芯压差 mV：0–500 → delta.0..500
///   com.corpsezhao.ninebotcast.bms.clear
///
/// 新鲜度 5 秒：BMS 每 1 秒轮询一次（1.2.5：原来 2 秒），App 每 2 秒重发，5 秒足够。
/// 5 秒收不到就当 App 没在跑 / BMS 断开了，扩展回落到无数据
/// （HUD 的 BMS 行消失，跟以前一样，不崩）。
/// 1.2.0 新增：朋友那辆换了锂电池的车的 ANT BMS（MAYI/JNFN）。
enum ANTBMSRelay {
    static let prefix = "com.corpsezhao.ninebotcast.bms"
    static let clearName = "\(prefix).clear"

    /// 扩展端数据过期时间（见文件头：2 秒轮询 + 2 秒重发，5 秒足够）。
    static let freshness: TimeInterval = 5.0

    /// App 端重发间隔（跟 HUDSettingsRelay 一致）。
    static let repostInterval: TimeInterval = 2.0

    /// 一次完整的电池读数（扩展和 App 共用）。
    struct Values: Equatable {
        var voltage: Float // 总电压 V
        var current: Float // 电流 A（放电为正）
        var soc: Float // SOC %
        var maxTemp: Int // 最高温度 °C
        var delta: Int // 电芯压差 mV
    }

    // MARK: - App 端：发

    private static let lock = NSLock()
    private static var lastValues: Values?
    private static var timer: DispatchSourceTimer?

    /// App 的 ANTBMS 解析到新帧时调：值变了立刻发一次。
    static func update(_ values: Values) {
        let v = Values(
            voltage: min(120, max(0, values.voltage)),
            current: min(50, max(-50, values.current)),
            soc: min(100, max(0, values.soc)),
            maxTemp: min(80, max(-40, values.maxTemp)),
            delta: min(500, max(0, values.delta)))
        lock.lock()
        let changed = lastValues != v
        lastValues = v
        lock.unlock()
        if changed {
            post(v)
        }
        // 同时更新本进程的接收缓存：让 current 在 App 进程里也能读到
        //（HUDData.tick 直接读 current，App 内和扩展同一路子）。
        storeLocal(v)
    }

    static func clear() {
        lock.lock()
        lastValues = nil
        lock.unlock()
        recvLock.lock()
        _values = nil
        _updatedAt = nil
        _seenKinds = []
        recvLock.unlock()
        postName(clearName)
    }

    private static func storeLocal(_ values: Values) {
        recvLock.lock()
        _values = values
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
                post(v)
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

    /// 5 个量各发一条名字。接收端用同一个 _updatedAt 记新鲜度。
    private static func post(_ v: Values) {
        postName("\(prefix).volt.\(Int((v.voltage * 100).rounded()))")
        postName("\(prefix).amp.\(Int((v.current * 10).rounded()) + 500)")
        postName("\(prefix).soc.\(Int((v.soc * 10).rounded()))")
        postName("\(prefix).temp.\(v.maxTemp + 40)")
        postName("\(prefix).delta.\(v.delta)")
    }

    private static func postName(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(rawValue: name as CFString),
            nil, nil, true)
    }

    // MARK: - 扩展端：收

    private static let recvLock = NSLock()
    private static var _values: Values?
    private static var _updatedAt: Date?
    private static var _seenKinds: Set<String> = []
    private static var observing = false

    /// 扩展端读到的最新值（nil = 还没收到过，或已过期 5 秒，
    /// 或 5 个量还没到齐——5 条通知是连着发的，到齐前不给半份数据）。
    static var current: Values? {
        recvLock.lock(); defer { recvLock.unlock() }
        guard let t = _updatedAt, Date().timeIntervalSince(t) < freshness,
              _seenKinds.count == 5 else { return nil }
        return _values
    }

    /// 扩展启动时调一次（SampleHandler.init 里）。
    /// 逐名订阅（OrientationRelay 同款，扩展里 proven）：电压 12001 个
    /// 名字 + 电流 1001 个 + SOC 1001 个 + 温度 121 个 + 压差 501 个
    /// + clear 1 个，共 14627 个。observing 守卫防止重复订阅。
    static func startObserving() {
        lock.lock()
        guard !observing else { lock.unlock(); return }
        observing = true
        lock.unlock()
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        var names: [String] = [clearName]
        for v in 0...12000 { names.append("\(prefix).volt.\(v)") }
        for v in 0...1000 { names.append("\(prefix).amp.\(v)") }
        for v in 0...1000 { names.append("\(prefix).soc.\(v)") }
        for v in 0...120 { names.append("\(prefix).temp.\(v)") }
        for v in 0...500 { names.append("\(prefix).delta.\(v)") }
        for name in names {
            CFNotificationCenterAddObserver(
                center,
                nil,
                { _, _, cfName, _, _ in
                    guard let cfName else { return }
                    ANTBMSRelay.handle(name: cfName.rawValue as String)
                },
                name as CFString, nil, .deliverImmediately)
        }
    }

    private static func handle(name: String) {
        guard name.hasPrefix(prefix + ".") else { return }
        if name == clearName {
            recvLock.lock()
            _values = nil
            _updatedAt = nil
            _seenKinds = []
            recvLock.unlock()
            return
        }
        let rest = String(name.dropFirst((prefix + ".").count))
        let parts = rest.split(separator: ".")
        guard parts.count == 2, let raw = Int(parts[1]) else { return }
        recvLock.lock()
        defer { recvLock.unlock() }
        var v = _values ?? Values(voltage: 0, current: 0, soc: 0, maxTemp: 0, delta: 0)
        switch parts[0] {
        case "volt": v.voltage = Float(raw) / 100
        case "amp": v.current = Float(raw - 500) / 10
        case "soc": v.soc = Float(raw) / 10
        case "temp": v.maxTemp = raw - 40
        case "delta": v.delta = raw
        default: return
        }
        _values = v
        _seenKinds.insert(String(parts[0]))
        _updatedAt = Date()
    }
}
