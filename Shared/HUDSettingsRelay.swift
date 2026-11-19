import Foundation
import os.log

/// HUD 自定义设置：主 App 里改，录屏扩展里收。
///
/// 通道是 Darwin 通知（CFNotificationCenterGetDarwinNotifyCenter），
/// 和方向接力同一个办法：不需要 App Groups、不需要任何 entitlement，
/// 自签名免费证书也能用。Darwin 通知不带 userInfo，设置值编码在
/// 通知名字里，扩展订阅全部 15 个名字：
///   com.corpsezhao.ninebotcast.hud.show.date.1 / .0
///   com.corpsezhao.ninebotcast.hud.show.weather.1 / .0
///   com.corpsezhao.ninebotcast.hud.show.signal.1 / .0
///   com.corpsezhao.ninebotcast.hud.show.battery.1 / .0
///   com.corpsezhao.ninebotcast.hud.show.music.1 / .0
///   com.corpsezhao.ninebotcast.hud.show.volume.1 / .0
///   com.corpsezhao.ninebotcast.hud.pos.br / .bl / .tl / .tr
///   com.corpsezhao.ninebotcast.hud.size.s / .m / .l
///
/// App 改了设置立刻发一次，另外每 2 秒重发一次当前设置——扩展可能
/// 在设置改完之后才启动，靠周期重发在 2 秒内学会。改完设置要先打开
/// 一次 App（它在后台靠音频保活继续发），再开镜像；直接从控制中心
/// 开镜像、App 没跑过，扩展就用默认设置（全显示、右下、中字）。
/// 帧路径只读一个缓存的 struct（NSLock 保护），不分配、不阻塞。
struct HUDSettings: Equatable {
    var showDate = true
    var showWeather = true
    var showSignal = true
    var showBattery = true
    var showMusic = true
    var showVolume = true
    var position: Position = .bottomRight
    var fontSize: FontSize = .medium

    enum Position: String, CaseIterable {
        case bottomRight = "br" // 右下（默认，1.0.8 的位置）
        case bottomLeft = "bl"  // 左下
        case topLeft = "tl"     // 左上
        case topRight = "tr"    // 右上：会挡住仪表自己的电量显示

        var label: String {
            switch self {
            case .bottomRight: return "右下"
            case .bottomLeft: return "左下"
            case .topLeft: return "左上"
            case .topRight: return "右上"
            }
        }
    }

    enum FontSize: String, CaseIterable {
        case small = "s"  // 小
        case medium = "m" // 中（默认，1.0.8 的字号）
        case large = "l"  // 大

        var label: String {
            switch self {
            case .small: return "小"
            case .medium: return "中"
            case .large: return "大"
            }
        }

        /// 参考坐标（848x480）下的字号。
        var refPt: CGFloat {
            switch self {
            case .small: return 16
            case .medium: return 20
            case .large: return 24
            }
        }
    }

    static let `default` = HUDSettings()
}

enum HUDSettingsRelay {
    static let prefix = "com.corpsezhao.ninebotcast.hud"

    private static let log = Logger(subsystem: "com.corpsezhao.ninebotcast", category: "broadcast")
    private static let lock = NSLock()
    private static var _current: HUDSettings = .default

    /// 渲染读这个：最近一次收到的设置；没收到过就是默认（全显示、右下、中字）。
    static var current: HUDSettings {
        lock.lock()
        defer { lock.unlock() }
        return _current
    }

    // MARK: - 名字编解码

    private static func showName(item: String, on: Bool) -> CFString {
        "\(prefix).show.\(item).\(on ? 1 : 0)" as CFString
    }

    private static func posName(_ pos: HUDSettings.Position) -> CFString {
        "\(prefix).pos.\(pos.rawValue)" as CFString
    }

    private static func sizeName(_ size: HUDSettings.FontSize) -> CFString {
        "\(prefix).size.\(size.rawValue)" as CFString
    }

    /// 扩展收到通知名，反解出它改的是哪一项。
    private static func apply(name: CFString) {
        let s = name as String
        guard s.hasPrefix(prefix + ".") else { return }
        let rest = String(s.dropFirst(prefix.count + 1))
        lock.lock()
        defer { lock.unlock() }
        if rest.hasPrefix("show.") {
            // show.<item>.<0|1>
            let parts = rest.split(separator: ".")
            guard parts.count == 3, let on = Int(parts[2]) else { return }
            let value = on != 0
            switch parts[1] {
            case "date": _current.showDate = value
            case "weather": _current.showWeather = value
            case "signal": _current.showSignal = value
            case "battery": _current.showBattery = value
            case "music": _current.showMusic = value
            case "volume": _current.showVolume = value
            default: return
            }
        } else if rest.hasPrefix("pos.") {
            let code = String(rest.dropFirst(4))
            if let pos = HUDSettings.Position(rawValue: code) { _current.position = pos }
        } else if rest.hasPrefix("size.") {
            let code = String(rest.dropFirst(5))
            if let size = HUDSettings.FontSize(rawValue: code) { _current.fontSize = size }
        }
    }

    // MARK: - 扩展：收

    private static var observing = false

    /// 扩展启动时调一次（SampleHandler.init）：订阅全部 15 个设置通知。
    static func startObserving() {
        lock.lock()
        guard !observing else { lock.unlock(); return }
        observing = true
        lock.unlock()

        let center = CFNotificationCenterGetDarwinNotifyCenter()
        var names: [CFString] = []
        for item in ["date", "weather", "signal", "battery", "music", "volume"] {
            names.append(showName(item: item, on: true))
            names.append(showName(item: item, on: false))
        }
        for pos in HUDSettings.Position.allCases { names.append(posName(pos)) }
        for size in HUDSettings.FontSize.allCases { names.append(sizeName(size)) }
        for name in names {
            CFNotificationCenterAddObserver(center, nil, { _, _, name, _, _ in
                guard let name else { return }
                HUDSettingsRelay.apply(name: name.rawValue)
            }, name, nil, .deliverImmediately)
        }
    }

    // MARK: - 主 App：发

    private static var postingStarted = false
    private static var postTimer: DispatchSourceTimer?
    private static var _posted: HUDSettings = .default

    /// 主 App 启动时调一次（NinebotProPlusApp.init）。
    /// 改设置立刻发一次；另外每 2 秒重发一次当前设置。
    static func startPosting() {
        guard !postingStarted else { return }
        postingStarted = true
        postAll()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(deadline: .now() + 2, repeating: .seconds(2))
        timer.setEventHandler { HUDSettingsRelay.postAll() }
        timer.resume()
        postTimer = timer
    }

    /// 主 App：用户在 HUD 设置卡片里改了设置。存下并立刻发一次，
    /// 之后每 2 秒随周期重发，扩展晚启动也能在 2 秒内学会。
    static func update(_ settings: HUDSettings) {
        lock.lock()
        _posted = settings
        lock.unlock()
        postAll()
        log.info("HUD 设置已发：日期 \(settings.showDate ? 1 : 0) 天气 \(settings.showWeather ? 1 : 0) 信号 \(settings.showSignal ? 1 : 0) 电量 \(settings.showBattery ? 1 : 0) 音乐 \(settings.showMusic ? 1 : 0) 音量 \(settings.showVolume ? 1 : 0) 位置 \(settings.position.rawValue) 字号 \(settings.fontSize.rawValue)")
    }

    private static func postAll() {
        lock.lock()
        let settings = _posted
        lock.unlock()
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let names: [CFString] = [
            showName(item: "date", on: settings.showDate),
            showName(item: "weather", on: settings.showWeather),
            showName(item: "signal", on: settings.showSignal),
            showName(item: "battery", on: settings.showBattery),
            showName(item: "music", on: settings.showMusic),
            showName(item: "volume", on: settings.showVolume),
            posName(settings.position),
            sizeName(settings.fontSize)
        ]
        for name in names {
            CFNotificationCenterPostNotification(center, CFNotificationName(rawValue: name), nil, nil, true)
        }
    }
}
