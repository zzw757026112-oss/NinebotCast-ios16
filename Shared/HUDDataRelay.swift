import CoreFoundation
import Foundation

/// 音乐 + 音量中继：主 App → 录屏扩展，Darwin 通知。
///
/// 背景（1.1.0 实测）：录屏扩展进程里 MPNowPlayingInfoCenter 返回 nil
/// （音乐行永不出现）、AVAudioSession.outputVolume 读到的是陈旧值
/// （用户实测音量卡在 5% 不动）；主 App 进程里这两个读数都是真的，
/// 投图片/视频时音量实时更新就是证明。
///
/// 1.1.1–1.1.6 的教训：这个文件原来用名字为 NULL 的观察者收全部
/// Darwin 通知、回调里按前缀过滤（歌名是任意字符串，名字空间无限，
/// 只能这么收）。但 NULL 名观察者在广播扩展里静默失效——回调根本
/// 不触发，所以 1.1.6 实测音乐行还是不显示、音量还是卡住。
/// 方向接力（OrientationRelay）证明逐名订阅在扩展里是通的：
/// 它订阅 5 个方向 + 4 个手动角度的具体名字，全都收得到。
/// 所以 1.1.7 改成逐名订阅：值必须能量化成有限名字。
///
/// 音量是 0–100 的整数，只有 101 个名字，全部订阅：
///   com.corpsezhao.ninebotcast.huddata.volume.<0-100>
/// 音乐歌名是任意字符串，没法逐名订阅——只传“在放 / 没放”
/// 两个固定名字，扩展收到就显示一个音符 + “正在播放”
/// （歌名传不过去，是 Darwin 通知名字空间的硬限制，不是 bug）：
///   com.corpsezhao.ninebotcast.huddata.music.playing
///   com.corpsezhao.ninebotcast.huddata.music.stopped
///
/// 新鲜度 3 秒：App 每 1 秒 tick（值变了立刻发）+ 每 2 秒重发，
/// 3 秒收不到就当 App 没在跑，扩展回落到本地读数（跟以前一样）。
enum HUDDataRelay {
    static let prefix = "com.corpsezhao.ninebotcast.huddata"
    static let clearName = "\(prefix).clear"
    static let musicPlayingName = "\(prefix).music.playing"
    static let musicStoppedName = "\(prefix).music.stopped"

    /// 扩展端数据过期时间（见文件头：App 每 2 秒重发，3 秒足够）。
    static let freshness: TimeInterval = 3.0

    /// App 端重发间隔（跟 HUDSettingsRelay 一致）。
    static let repostInterval: TimeInterval = 2.0

    // MARK: - App 端：发

    private static let lock = NSLock()
    private static var lastValues: (musicPlaying: Bool, volume: Int?)?
    private static var timer: DispatchSourceTimer?

    /// App 的 HUDData.tick() 每秒调：值变了立刻发一次。
    /// musicPlaying = 有没有在放音乐；volume 是 0...1，-1 = 未知。
    static func update(musicPlaying: Bool, volume: Float) {
        let v: Int? = volume >= 0 ? min(100, max(0, Int((volume * 100).rounded()))) : nil
        lock.lock()
        let changed = lastValues == nil || lastValues!.musicPlaying != musicPlaying || lastValues!.volume != v
        lastValues = (musicPlaying, v)
        lock.unlock()
        if changed {
            post(musicPlaying: musicPlaying, volume: v)
        }
        // 同时更新本进程的接收缓存：让 current 在 App 进程里也能读到
        //（App 内的 drawCopy 虽然直接读 HUDData.shared，但缓存保持一致不吃亏）。
        // 扩展端不调 update，只靠通知，所以两边都对。
        storeLocal(musicPlaying: musicPlaying, volume: v)
    }

    static func clear() {
        lock.lock()
        lastValues = nil
        lock.unlock()
        recvLock.lock()
        _musicPlaying = false
        _volume = -1
        _updatedAt = nil
        recvLock.unlock()
        postName(clearName)
    }

    private static func storeLocal(musicPlaying: Bool, volume: Int?) {
        recvLock.lock()
        _musicPlaying = musicPlaying
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
                post(musicPlaying: v.musicPlaying, volume: v.volume)
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

    /// 音乐状态和音量一起发：接收端用同一个 _updatedAt 记新鲜度，
    /// 两项必须同批到达，否则过期判断会对不上。
    /// 音量未知（-1）时只发音乐那条。
    private static func post(musicPlaying: Bool, volume: Int?) {
        postName(musicPlaying ? musicPlayingName : musicStoppedName)
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
    private static var _musicPlaying = false
    private static var _volume: Float = -1
    private static var _updatedAt: Date?
    private static var observing = false

    /// 扩展端读到的最新值（nil = 还没收到过，或已过期 3 秒）。
    /// musicPlaying = 收到 playing（没收到 stopped 或过期就是 false）；
    /// volume 为 -1 = 没收到过音量。调用方（HUDData.tick 的扩展分支）
    /// 据此决定是用中继值还是回落本地读数。
    static var current: (musicPlaying: Bool, volume: Float, updatedAt: Date?)? {
        recvLock.lock(); defer { recvLock.unlock() }
        guard let t = _updatedAt, Date().timeIntervalSince(t) < freshness else { return nil }
        return (musicPlaying: _musicPlaying, volume: _volume, updatedAt: t)
    }

    /// 扩展启动时调一次（SampleHandler.init 里）。
    /// 逐名订阅（OrientationRelay 同款，扩展里 proven）：音量 101 个
    /// 名字 + 音乐 2 个名字 + clear 1 个，共 104 个。
    /// observing 守卫防止重复订阅导致双倍回调。
    static func startObserving() {
        lock.lock()
        guard !observing else { lock.unlock(); return }
        observing = true
        lock.unlock()
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        var names: [String] = [clearName, musicPlayingName, musicStoppedName]
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
            _musicPlaying = false
            _volume = -1
            _updatedAt = nil
            recvLock.unlock()
            return
        }
        if name == musicPlayingName {
            recvLock.lock()
            _musicPlaying = true
            _updatedAt = Date()
            recvLock.unlock()
            return
        }
        if name == musicStoppedName {
            recvLock.lock()
            _musicPlaying = false
            _updatedAt = Date()
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
