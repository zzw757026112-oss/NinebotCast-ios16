import CoreFoundation
import Foundation

/// 音乐 + 音量中继：主 App → 录屏扩展，Darwin 通知。
///
/// 背景（1.1.0 实测）：录屏扩展进程里 MPNowPlayingInfoCenter 返回 nil
/// （音乐行永不出现）、AVAudioSession.outputVolume 读到的是陈旧值
/// （用户实测音量卡在 5% 不动）；主 App 进程里这两个读数都是真的，
/// 投图片/视频时音量实时更新就是证明。跟 VehicleDataRelay 同一套
/// 做法：值编进通知名，App 改值立刻发、再每 2 秒重发一次，扩展订
/// 阅并缓存最新值。没有 App Groups，只能这样传。
///
/// 歌名是任意中文字符串，不能像速度/电压那样量化成有限网格，所以
/// 用 URL-safe base64 编进通知名（无损往返中文，比百分号编码短：
/// 中文 3 字节变 4 字符，百分号编码要 9 字符；且不会和名字里的 `.`
/// 冲突）：
///   com.corpsezhao.ninebotcast.huddata.music.<base64url>  （在放）
///   com.corpsezhao.ninebotcast.huddata.music.none         （没放）
/// 音量是 0–100 的整数：
///   com.corpsezhao.ninebotcast.huddata.volume.<0-100>
///   （未知时不发）
///
/// 歌名名字空间是无限的，没法像 VehicleDataRelay 那样逐个订阅：
/// 扩展用名字为 NULL 的观察者收全部 Darwin 通知，回调里按前缀
/// 过滤（只做一次 hasPrefix 就返回，不阻塞；名字不匹配直接丢弃）。
///
/// 新鲜度 3 秒：App 每 1 秒 tick（值变了立刻发）+ 每 2 秒重发，
/// 3 秒收不到就当 App 没在跑，扩展回落到本地读数（跟以前一样）。
enum HUDDataRelay {
    static let prefix = "com.corpsezhao.ninebotcast.huddata"
    static let clearName = "\(prefix).clear"
    static let musicNoneName = "\(prefix).music.none"

    /// 扩展端数据过期时间（见文件头：App 每 2 秒重发，3 秒足够）。
    static let freshness: TimeInterval = 3.0

    /// App 端重发间隔（跟 VehicleDataRelay / HUDSettingsRelay 一致）。
    static let repostInterval: TimeInterval = 2.0

    // MARK: - App 端：发

    private static let lock = NSLock()
    private static var lastValues: (music: String?, volume: Int?)?
    private static var timer: DispatchSourceTimer?

    /// App 的 HUDData.tick() 每秒调：值变了立刻发一次。
    /// music 是截断后（≤24 字）的字符串或 nil；volume 是 0...1，-1 = 未知。
    static func update(music: String?, volume: Float) {
        let m = (music?.isEmpty == false) ? music : nil
        let v: Int? = volume >= 0 ? min(100, max(0, Int((volume * 100).rounded()))) : nil
        lock.lock()
        let changed = lastValues == nil || lastValues!.music != m || lastValues!.volume != v
        lastValues = (m, v)
        lock.unlock()
        if changed {
            post(music: m, volume: v)
        }
        // 同时更新本进程的接收缓存：跟 VehicleDataRelay.update 一样，
        // 让 current 在 App 进程里也能读到（App 内的 drawCopy 虽然
        // 直接读 HUDData.shared，但缓存保持一致不吃亏）。
        // 扩展端不调 update，只靠通知，所以两边都对。
        storeLocal(music: m, volume: v)
    }

    static func clear() {
        lock.lock()
        lastValues = nil
        lock.unlock()
        recvLock.lock()
        _music = nil
        _volume = -1
        _updatedAt = nil
        recvLock.unlock()
        postName(clearName)
    }

    private static func storeLocal(music: String?, volume: Int?) {
        recvLock.lock()
        _music = music
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
                post(music: v.music, volume: v.volume)
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

    /// 音乐和音量一起发：接收端用同一个 _updatedAt 记新鲜度，
    /// 两项必须同批到达，否则过期判断会对不上。
    /// 音量未知（-1）时只发音乐那条。
    private static func post(music: String?, volume: Int?) {
        if let music {
            postName("\(prefix).music.\(encodeMusic(music))")
        } else {
            postName(musicNoneName)
        }
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

    // MARK: - 歌名编解码（URL-safe base64，无 `=` 填充）

    private static func encodeMusic(_ s: String) -> String {
        Data(s.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decodeMusic(_ s: String) -> String? {
        var b64 = s.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let data = Data(base64Encoded: b64),
              let str = String(data: data, encoding: .utf8) else { return nil }
        return str
    }

    // MARK: - 扩展端：收

    private static let recvLock = NSLock()
    private static var _music: String?
    private static var _volume: Float = -1
    private static var _updatedAt: Date?
    private static var observing = false

    /// 扩展端读到的最新值（nil = 还没收到过，或已过期 3 秒）。
    /// music 为 nil = 明确没放音乐（收到 music.none）；volume 为 -1 =
    /// 没收到过音量。调用方（HUDData.tick 的扩展分支）据此决定是
    /// 用中继值还是回落本地读数。
    static var current: (music: String?, volume: Float, updatedAt: Date?)? {
        recvLock.lock(); defer { recvLock.unlock() }
        guard let t = _updatedAt, Date().timeIntervalSince(t) < freshness else { return nil }
        return (music: _music, volume: _volume, updatedAt: t)
    }

    /// 扩展启动时调一次（SampleHandler.init 里）。
    /// 歌名名字空间无限，只能用名字为 NULL 的观察者收全部 Darwin
    /// 通知再按前缀过滤；observing 守卫防止重复订阅导致双倍回调。
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
                HUDDataRelay.handle(name: cfName.rawValue as String)
            },
            nil, nil, .deliverImmediately)
    }

    private static func handle(name: String) {
        if name == clearName {
            recvLock.lock()
            _music = nil
            _volume = -1
            _updatedAt = nil
            recvLock.unlock()
            return
        }
        guard name.hasPrefix(prefix + ".") else { return }
        let rest = String(name.dropFirst(prefix.count + 1))
        // 先判 music.none：它本身也是合法 base64 字符，必须在解码前拦截。
        if rest == "music.none" {
            recvLock.lock()
            _music = nil
            _updatedAt = Date()
            recvLock.unlock()
            return
        }
        if rest.hasPrefix("music.") {
            let payload = String(rest.dropFirst("music.".count))
            guard let music = decodeMusic(payload) else { return }
            recvLock.lock()
            _music = music
            _updatedAt = Date()
            recvLock.unlock()
            return
        }
        if rest.hasPrefix("volume.") {
            let payload = String(rest.dropFirst("volume.".count))
            guard let pct = Int(payload), (0...100).contains(pct) else { return }
            recvLock.lock()
            _volume = Float(pct) / 100
            _updatedAt = Date()
            recvLock.unlock()
            return
        }
    }
}
