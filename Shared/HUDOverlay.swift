import AVFoundation
import CallKit
import CoreGraphics
import CoreLocation
import CoreTelephony
import CoreText
import CoreVideo
import Foundation
import MediaPlayer
import Network
import UIKit

/// 仪表 HUD 叠加层：右下角两行小胶囊（1.0.8 重做，照仪表右下角
/// 那条状态栏的样子）。
///
/// 上行：时钟图标 + 日期时间（11月18日 周三 21:07）
/// 下行：天气图标 + 温度、联网方式（WiFi 图标 / 5G / 4G）、
///       音量、电池图标 + 电量百分比。
/// 有音乐在放时再加一行：音符图标 + 歌名 - 歌手。
/// 电量低于 20% 时电池图标和百分比变红。
/// 胶囊：半透明黑底 + 细亮边、圆角，字和图标同一行垂直居中对齐。
/// 来电还是左下角红色小条，不变。
///
/// 共享文件，同时编进主 App（Sources）和录屏扩展（Broadcast）。
/// 画在编码器之前，仪表上看到的就是叠加后的画面；App 自己的
/// H.264/RTP/UDP 传输链路完全不动。
///
/// 线程纪律：
/// - 帧路径（CastEngine.submit / ScreenCaster.submitFrame）只读缓存，
///   永不阻塞：定位、天气网络、来电监听全在后台做，数据进缓存。
/// - 文字层（CGImage）只在显示内容变化时重画，且最多每秒一次；
///   每帧只是把缓存好的层画进 buffer，一次 drawImage。
/// - 全部用 CoreText + CoreGraphics 手画图标（不用 UIKit 绘图），
///   后台队列安全；画法与 TestImageSource 相同（CGContext +
///   CTLineDraw），仪表上已验证是正的。
/// - 通知不在这里：iOS 不让第三方 App 读别的 App 的通知。
/// - 信号格数：iOS 不给 App 看真实信号强度，所以这里显示的是联网
///   方式（WiFi 图标 / 5G / 4G），不是假的信号格。

// MARK: - 数据（单例，缓存值）

enum NetworkKind: Equatable {
    case wifi
    case cellular(String) // 5G / 4G / 3G / 2G / 蜂窝
    case none
    case unknown

    var cacheKey: String {
        switch self {
        case .wifi: return "wifi"
        case .cellular(let t): return "cell:\(t)"
        case .none: return "none"
        case .unknown: return "?"
        }
    }
}

struct HUDSnapshot: Equatable {
    var date: String
    var weatherCode: Int?
    var weatherTemp: Int?
    var batteryLevel: Float // -1 = 未知
    var charging: Bool
    var network: NetworkKind
    var calling: Bool
    var music: String? // 正在放的歌（"歌名 - 歌手"，没放就是 nil）
    var volume: Float // 手机音量 0...1，-1 = 未知
}

final class HUDData: NSObject, CLLocationManagerDelegate, CXCallObserverDelegate {

    /// 必须在主线程初始化（UIDevice 是 UIKit）。帧线程第一次
    /// 访问时如果不在主线程，用 main.sync 切过去建一次。
    static let shared: HUDData = {
        if Thread.isMainThread { return HUDData() }
        var instance: HUDData!
        DispatchQueue.main.sync { instance = HUDData() }
        return instance
    }()

    private let lock = NSLock()
    private var _dateText = ""
    private var _weatherCode: Int?
    private var _weatherTemp: Int?
    private var _batteryLevel: Float = -1
    private var _batteryCharging = false
    private var _network: NetworkKind = .unknown
    private var _calling = false
    private var _music: String?
    private var _volume: Float = -1

    private let dateFormatter: DateFormatter
    private var timer: DispatchSourceTimer?
    private var locationManager: CLLocationManager?
    private var lastWeatherFetch = Date.distantPast
    private var weatherFetching = false
    private var locationRequested = false

    private let callObserver = CXCallObserver()
    private let callQueue = DispatchQueue(label: "ninebotcast.hud.calls")
    private var activeCalls = Set<UUID>()

    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "ninebotcast.hud.network")
    private var telephonyInfo: CTTelephonyNetworkInfo?

    private var isExtension: Bool {
        Bundle.main.bundlePath.hasSuffix(".appex")
    }

    private override init() {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "zh_CN")
        fmt.dateFormat = "M月d日 E HH:mm"
        dateFormatter = fmt
        super.init()

        UIDevice.current.isBatteryMonitoringEnabled = true
        callObserver.setDelegate(self, queue: callQueue)

        // 联网方式监听（WiFi / 蜂窝 + 制式）。
        pathMonitor.pathUpdateHandler = { [weak self] path in
            self?.updateNetwork(path: path)
        }
        pathMonitor.start(queue: pathQueue)

        // 每秒刷新电量/日期（主线程，轻量）；天气按 20 分钟周期检查。
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        t.schedule(deadline: .now(), repeating: .seconds(1))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
        tick()
    }

    /// 帧路径只读这个：快照 + 是否来电。
    func snapshot() -> HUDSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return HUDSnapshot(date: _dateText,
                           weatherCode: _weatherCode,
                           weatherTemp: _weatherTemp,
                           batteryLevel: _batteryLevel,
                           charging: _batteryCharging,
                           network: _network,
                           calling: _calling,
                           music: _music,
                           volume: _volume)
    }

    // MARK: - 联网方式

    private func updateNetwork(path: NWPath) {
        let kind: NetworkKind
        if path.status != .satisfied {
            kind = .none
        } else if path.usesInterfaceType(.wifi) {
            kind = .wifi
        } else if path.usesInterfaceType(.cellular) {
            kind = .cellular(radioTechLabel())
        } else {
            kind = .unknown
        }
        lock.lock()
        _network = kind
        lock.unlock()
    }

    /// 蜂窝制式 → 5G / 4G / 3G / 2G（拿不到就写“蜂窝”）。
    private func radioTechLabel() -> String {
        if telephonyInfo == nil { telephonyInfo = CTTelephonyNetworkInfo() }
        guard let techs = telephonyInfo?.serviceCurrentRadioAccessTechnology,
              let tech = techs.values.first else { return "蜂窝" }
        switch tech {
        case CTRadioAccessTechnologyNR, CTRadioAccessTechnologyNRNSA:
            return "5G"
        case CTRadioAccessTechnologyLTE:
            return "4G"
        case CTRadioAccessTechnologyWCDMA, CTRadioAccessTechnologyHSDPA,
             CTRadioAccessTechnologyHSUPA, CTRadioAccessTechnologyeHRPD,
             CTRadioAccessTechnologyCDMAEVDORev0, CTRadioAccessTechnologyCDMAEVDORevA,
             CTRadioAccessTechnologyCDMAEVDORevB, CTRadioAccessTechnologyCDMA1x:
            return "3G"
        case CTRadioAccessTechnologyGPRS, CTRadioAccessTechnologyEdge:
            return "2G"
        default:
            return "蜂窝"
        }
    }

    // MARK: - 每秒刷新（主线程）

    private func tick() {
        let level = UIDevice.current.batteryLevel
        let state = UIDevice.current.batteryState
        let date = dateFormatter.string(from: Date())
        // 正在放的歌：系统“正在播放”信息（任何 App 在放都能读到，
        // 包括 QQ 音乐、网易云、Spotify；没放就是 nil）。
        let info = MPNowPlayingInfoCenter.default().nowPlayingInfo
        let title = info?[MPMediaItemPropertyTitle] as? String
        let artist = info?[MPMediaItemPropertyArtist] as? String
        var music: String?
        if let title, !title.isEmpty {
            music = (artist?.isEmpty == false) ? "\(title) - \(artist!)" : title
            // 太长会把胶囊撑出仪表，截到 24 字。
            if let m = music, m.count > 24 { music = String(m.prefix(24)) + "…" }
        }
        // 手机音量（0...1）。
        let volume = AVAudioSession.sharedInstance().outputVolume
        lock.lock()
        _batteryLevel = level
        _batteryCharging = (state == .charging || state == .full)
        _dateText = date
        _music = music
        _volume = volume
        lock.unlock()
        refreshWeatherIfNeeded()
    }

    // MARK: - 天气（定位一次 + Open-Meteo，20 分钟缓存）

    private func refreshWeatherIfNeeded() {
        lock.lock()
        let due = Date().timeIntervalSince(lastWeatherFetch) >= 1200 && !weatherFetching
        if due {
            weatherFetching = true
            lastWeatherFetch = Date()
        }
        lock.unlock()
        guard due else { return }
        ensureLocation()
    }

    private func ensureLocation() {
        if locationManager == nil {
            let mgr = CLLocationManager()
            mgr.delegate = self
            mgr.desiredAccuracy = kCLLocationAccuracyKilometer
            locationManager = mgr
        }
        guard let mgr = locationManager else {
            setWeatherFetching(false)
            return
        }
        switch mgr.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            locationRequested = true
            mgr.requestLocation()
        case .notDetermined:
            if isExtension {
                // 扩展里弹不出授权框：直接试一次定位，系统拒绝就静默
                // 失败，天气这一行跳过（不崩、不卡、不弹框）。
                locationRequested = true
                mgr.requestLocation()
            } else if !locationRequested {
                locationRequested = true
                mgr.requestWhenInUseAuthorization()
                // 授权结果回 didChangeAuthorization，再 requestLocation。
            } else {
                setWeatherFetching(false)
            }
        default: // denied / restricted：没有定位，天气组直接不显示。
            setWeatherFetching(false)
        }
    }

    private func setWeatherFetching(_ value: Bool) {
        lock.lock()
        weatherFetching = value
        lock.unlock()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        default:
            setWeatherFetching(false)
        }
    }

    func locationManager(_ manager: CLLocationManager,
                         didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else {
            setWeatherFetching(false)
            return
        }
        fetchWeather(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude)
    }

    func locationManager(_ manager: CLLocationManager,
                         didFailWithError error: Error) {
        // 定位失败：这次不显示天气，20 分钟后下一个周期再试。
        setWeatherFetching(false)
    }

    private func fetchWeather(lat: Double, lon: Double) {
        let urlString = String(
            format: "https://api.open-meteo.com/v1/forecast?latitude=%.4f&longitude=%.4f&current=temperature_2m,weather_code&timezone=auto",
            lat, lon)
        guard let url = URL(string: urlString) else {
            setWeatherFetching(false)
            return
        }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self else { return }
            defer { self.setWeatherFetching(false) }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cur = json["current"] as? [String: Any],
                  let temp = cur["temperature_2m"] as? NSNumber,
                  let code = cur["weather_code"] as? NSNumber else { return }
            self.lock.lock()
            self._weatherCode = code.intValue
            self._weatherTemp = Int(temp.doubleValue)
            self.lock.unlock()
        }.resume()
    }

    // MARK: - 来电（CallKit，只记有没有未结束的通话，不读号码）

    func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        if call.hasEnded {
            activeCalls.remove(call.uuid)
        } else {
            activeCalls.insert(call.uuid)
        }
        lock.lock()
        _calling = !activeCalls.isEmpty
        lock.unlock()
    }
}

// MARK: - 渲染

enum HUDRenderer {
    // 848x480 参考坐标。胶囊锚在右下角：右边距 12、上边距…下边距 12。
    // 1.0.8：三行文字右列 → 右下角两行胶囊（照仪表右下角状态栏）。
    // 1.0.9：胶囊可自定义——显示哪些项、放哪个角、字号（HUDSettingsRelay）。
    private static let refWidth: CGFloat = 848
    private static let refHeight: CGFloat = 480
    private static let iconTextGapRef: CGFloat = 4
    private static let groupGapRef: CGFloat = 14
    private static let rowGapRef: CGFloat = 8
    private static let padXRef: CGFloat = 12
    private static let padYRef: CGFloat = 10
    private static let marginRightRef: CGFloat = 12
    private static let marginBottomRef: CGFloat = 12
    private static let marginLeftRef: CGFloat = 12
    private static let marginTopRef: CGFloat = 12
    private static let panelAlpha: CGFloat = 0.45
    private static let panelBorderAlpha: CGFloat = 0.35
    private static let panelCornerRef: CGFloat = 12

    private static let lock = NSLock()
    private static var cachedKey = ""
    private static var cachedLayer: CGImage?
    private static var lastRender = Date.distantPast

    /// 画进已有 buffer（原地）。调用方保证该 buffer 每帧都会被
    /// 完整重画（录屏扩展的 scaler 池就是这样），才不会叠字。
    static func draw(on pixelBuffer: CVPixelBuffer) {
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA,
              w > 16, h > 16,
              let layer = layer(forWidth: w, height: h) else { return }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: w, height: h,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
        context.interpolationQuality = .none
        context.draw(layer, in: CGRect(x: 0, y: 0, width: w, height: h))
    }

    /// 拷一份再画 HUD，返回带 HUD 的新 buffer；失败返回 nil，
    /// 调用方用原 buffer 继续（HUD 跳过一帧，不影响投屏）。
    /// 主 App 用这个：相册图片 buffer 是静态复用的，不能原地画。
    static func drawCopy(of src: CVPixelBuffer) -> CVPixelBuffer? {
        let w = CVPixelBufferGetWidth(src)
        let h = CVPixelBufferGetHeight(src)
        guard CVPixelBufferGetPixelFormatType(src) == kCVPixelFormatType_32BGRA,
              w > 16, h > 16,
              let layer = layer(forWidth: w, height: h) else { return nil }
        var copy: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault, w, h,
            kCVPixelFormatType_32BGRA, attrs as CFDictionary, &copy) == kCVReturnSuccess,
            let dst = copy else { return nil }
        CVPixelBufferLockBaseAddress(src, .readOnly)
        CVPixelBufferLockBaseAddress(dst, [])
        defer {
            CVPixelBufferUnlockBaseAddress(src, .readOnly)
            CVPixelBufferUnlockBaseAddress(dst, [])
        }
        guard let s = CVPixelBufferGetBaseAddress(src),
              let d = CVPixelBufferGetBaseAddress(dst) else { return nil }
        let sRow = CVPixelBufferGetBytesPerRow(src)
        let dRow = CVPixelBufferGetBytesPerRow(dst)
        if sRow == dRow {
            memcpy(d, s, sRow * h)
        } else {
            let rowBytes = min(sRow, dRow)
            for y in 0..<h {
                memcpy(d.advanced(by: y * dRow), s.advanced(by: y * sRow), rowBytes)
            }
        }
        guard let context = CGContext(
            data: d,
            width: w, height: h,
            bitsPerComponent: 8,
            bytesPerRow: dRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        context.interpolationQuality = .none
        context.draw(layer, in: CGRect(x: 0, y: 0, width: w, height: h))
        return dst
    }

    // MARK: - 文字层缓存

    private static func layer(forWidth width: Int, height: Int) -> CGImage? {
        let snap = HUDData.shared.snapshot()
        let settings = HUDSettingsRelay.current
        let settingsKey = "\(settings.showDate ? 1 : 0)\(settings.showWeather ? 1 : 0)\(settings.showSignal ? 1 : 0)\(settings.showBattery ? 1 : 0)\(settings.showMusic ? 1 : 0)\(settings.showVolume ? 1 : 0)\(settings.showVehicle ? 1 : 0)|\(settings.position.rawValue)|\(settings.fontSize.rawValue)"
        // 车辆数据：新鲜才有（过期/没连车时为 nil，缓存键随之变，旧胶囊消失）。
        let vehicle = settings.showVehicle ? VehicleDataRelay.current : nil
        let vehicleKey = vehicle.map { "\($0.speedKmh)/\($0.voltageV)/\($0.currentA)/\($0.powerW)" } ?? "-"
        let key = "\(width)x\(height)|\(snap.date)|\(snap.weatherCode ?? -1)|\(snap.weatherTemp ?? -999)|\(snap.batteryLevel)|\(snap.charging ? 1 : 0)|\(snap.network.cacheKey)|\(snap.calling ? 1 : 0)|\(snap.music ?? "")|\(snap.volume)|\(settingsKey)|\(vehicleKey)"
        lock.lock()
        defer { lock.unlock() }
        if key == cachedKey, let layer = cachedLayer { return layer }
        // 内容变了但离上次重画不到 1 秒：先用旧层，不阻塞帧路径。
        if let layer = cachedLayer, Date().timeIntervalSince(lastRender) < 1.0 {
            return layer
        }
        guard let layer = renderLayer(width: width, height: height, snap: snap, settings: settings, vehicle: vehicle) else {
            return cachedLayer
        }
        cachedKey = key
        cachedLayer = layer
        lastRender = Date()
        return layer
    }

    // MARK: - 段（图标或文字）

    private enum Segment {
        case icon(IconKind)
        case battery(level: Float, charging: Bool, low: Bool)
        case text(String, CGColor)
    }

    private enum IconKind {
        case clock
        case weather(Int) // Open-Meteo weather_code
        case wifi
        case music // 音符
        case speaker // 喇叭（音量）
        case bolt // 闪电（车辆电压/功率行）
    }

    private static func ctLine(_ text: String, font: CTFont, color: CGColor) -> CTLine {
        let attrs: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: color
        ]
        let attrStr = CFAttributedStringCreate(kCFAllocatorDefault, text as CFString, attrs as CFDictionary)!
        return CTLineCreateWithAttributedString(attrStr)
    }

    private static func lineWidth(_ line: CTLine) -> CGFloat {
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        return CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
    }

    /// 把两行胶囊 + 来电红条 + 车辆胶囊画进一张全尺寸透明层。
    /// CGContext 在这里是 y 朝上的坐标系（与 TestImageSource 相同），
    /// 所以「离顶 xx」要换算成 baseline = 高 - 顶距 - 上伸。
    /// 设置全关、又没来电、又没车数据时返回一张全透明层（不是 nil），
    /// 这样旧胶囊才会从画面上消失；layer() 的缓存也随之更新。
    /// vehicle 是中继里的最新车辆数据（nil = 没连车或已过期）。
    private static func renderLayer(width: Int, height: Int, snap: HUDSnapshot, settings: HUDSettings, vehicle: (speedKmh: Int, voltageV: Int, currentA: Int, powerW: Int)?) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }

        let sx = CGFloat(width) / refWidth
        let sy = CGFloat(height) / refHeight
        let h = CGFloat(height)

        // 字号跟设置走（小 16 / 中 20 / 大 24），图标跟着字一样大。
        let fontSize = max(12, settings.fontSize.refPt * sy)
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        let iconSize = fontSize
        let iconTextGap = iconTextGapRef * sx
        let groupGap = groupGapRef * sx
        let rowGap = rowGapRef * sy
        let padX = padXRef * sx
        let padY = padYRef * sy

        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let rowHeight = ascent + descent

        // ---- 按设置组行（关掉的项不进胶囊） ----
        // 电量低于 20%：电池图标和百分比变红。
        let isLowBattery = snap.batteryLevel >= 0 && snap.batteryLevel < 0.2
        let red = CGColor(red: 1, green: 0.25, blue: 0.25, alpha: 1)
        // 上行：时钟图标 + 日期时间
        var row1: [Segment] = []
        if settings.showDate, !snap.date.isEmpty {
            row1 = [.icon(.clock), .text(snap.date, white)]
        }
        // 下行：天气图标 + 温度、联网方式、音量、电池图标 + 百分比
        var row2: [Segment] = []
        if settings.showWeather,
           let code = snap.weatherCode, let temp = snap.weatherTemp {
            row2.append(.icon(.weather(code)))
            row2.append(.text("\(temp)°", white))
        }
        if settings.showSignal {
            switch snap.network {
            case .wifi:
                row2.append(.icon(.wifi))
            case .cellular(let tech):
                row2.append(.text(tech, white))
            case .none, .unknown:
                break
            }
        }
        if settings.showVolume, snap.volume >= 0 {
            row2.append(.icon(.speaker))
            row2.append(.text("\(Int(snap.volume * 100))%", white))
        }
        if settings.showBattery {
            row2.append(.battery(level: snap.batteryLevel, charging: snap.charging, low: isLowBattery))
            row2.append(.text(snap.batteryLevel < 0 ? "--%" : "\(Int(snap.batteryLevel * 100))%",
                              isLowBattery ? red : white))
        }
        // 第三行：正在放的歌（没放就不画，胶囊还是两行）。
        var row3: [Segment] = []
        if settings.showMusic, let music = snap.music, !music.isEmpty {
            row3 = [.icon(.music), .text(music, white)]
        }

        // ---- 量每段宽度 ----
        // 段间间距：图标后面跟文字是“一组”（小间距），其余都是组间距。
        func isIcon(_ seg: Segment) -> Bool {
            switch seg { case .icon, .battery: return true; case .text: return false }
        }

        func measure(_ segments: [Segment]) -> (width: CGFloat, items: [(seg: Segment, w: CGFloat, line: CTLine?)]) {
            var items: [(Segment, CGFloat, CTLine?)] = []
            var total: CGFloat = 0
            for (i, seg) in segments.enumerated() {
                if i > 0 {
                    let prev = segments[i - 1]
                    total += (isIcon(prev) && !isIcon(seg)) ? iconTextGap : groupGap
                }
                var w: CGFloat
                var line: CTLine?
                switch seg {
                case .icon, .battery:
                    w = iconSize
                case .text(let t, let color):
                    line = ctLine(t, font: font, color: color)
                    w = lineWidth(line!)
                }
                total += w
                items.append((seg, w, line))
            }
            return (total, items)
        }

        // 只画非空的行；行数决定胶囊高度（一行就矮一点）。
        let measuredRows = [measure(row1), measure(row2), measure(row3)].filter { !$0.items.isEmpty }
        // 全关了、又没来电、又没车数据：返回全透明层（旧胶囊随之消失）。
        if measuredRows.isEmpty && !snap.calling && vehicle == nil {
            return context.makeImage()
        }

        let contentWidth = measuredRows.map { $0.width }.max() ?? 0
        let pillW = contentWidth + padX * 2
        let rowCount = measuredRows.count
        let pillH = padY * 2 + rowHeight * CGFloat(rowCount) + rowGap * CGFloat(max(0, rowCount - 1))

        // 胶囊锚点按设置来（y 朝上坐标系）。
        let pillX: CGFloat
        let pillY: CGFloat
        switch settings.position {
        case .bottomRight:
            pillX = (refWidth - marginRightRef) * sx - pillW
            pillY = marginBottomRef * sy
        case .bottomLeft:
            pillX = marginLeftRef * sx
            pillY = marginBottomRef * sy
        case .topLeft:
            pillX = marginLeftRef * sx
            pillY = h - marginTopRef * sy - pillH
        case .topRight:
            pillX = (refWidth - marginRightRef) * sx - pillW
            pillY = h - marginTopRef * sy - pillH
        }

        // ---- 画胶囊底板（有行才画；全关了只剩来电条时不画空胶囊） ----
        if !measuredRows.isEmpty {
        let panel = CGRect(x: pillX, y: pillY, width: pillW, height: pillH)
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: panelAlpha))
        context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: panelBorderAlpha))
        context.setLineWidth(max(1, 1 * sx))
        context.addPath(CGPath(roundedRect: panel,
                               cornerWidth: panelCornerRef * sx,
                               cornerHeight: panelCornerRef * sy,
                               transform: nil))
        context.drawPath(using: .fillStroke)

        // ---- 画各行（左对齐，图标与文字垂直居中对齐） ----
        // 行顶（离顶距离）：胶囊顶 + padY 是第一行顶。
        let pillTopFromTop = h - (pillY + pillH)
        let shadow = CGColor(red: 0, green: 0, blue: 0, alpha: 0.85)
        context.setShadow(offset: CGSize(width: 0, height: -2), blur: 3, color: shadow)

        func drawRow(_ measured: (width: CGFloat, items: [(seg: Segment, w: CGFloat, line: CTLine?)]),
                     rowTopFromTop: CGFloat) {
            // 行内文字基线（y 朝上坐标）
            let baseline = h - rowTopFromTop - ascent
            // 图标垂直中心对齐文字中心：文字中心 = 基线 + (上伸 - 下伸)/2
            let textCenterY = baseline + (ascent - descent) / 2
            var x = pillX + padX
            for (i, item) in measured.items.enumerated() {
                let (seg, w, line) = item
                switch seg {
                case .icon(let kind):
                    let rect = CGRect(x: x, y: textCenterY - iconSize / 2,
                                      width: iconSize, height: iconSize)
                    drawIcon(kind, in: rect, context: context)
                case .battery(let level, let charging, let low):
                    let rect = CGRect(x: x, y: textCenterY - iconSize / 2,
                                      width: iconSize, height: iconSize)
                    drawBattery(level: level, charging: charging, low: low, in: rect, context: context)
                case .text:
                    if let line {
                        context.textPosition = CGPoint(x: x, y: baseline)
                        CTLineDraw(line, context)
                    }
                }
                x += w
                // 下一段的间距：图标后跟文字是小间距，其余组间距
                if i + 1 < measured.items.count {
                    let next = measured.items[i + 1].seg
                    x += (isIcon(seg) && !isIcon(next)) ? iconTextGap : groupGap
                }
            }
        }

        // 按顺序画非空的行
        for (i, row) in measuredRows.enumerated() {
            let rowTop = pillTopFromTop + padY + CGFloat(i) * (rowHeight + rowGap)
            drawRow(row, rowTopFromTop: rowTop)
        }
        } // if !measuredRows.isEmpty

        // 来电：左下角红色圆角条，半透明红底 + 细亮边（不动）。
        if snap.calling {
            let text = "来电"
            let line = ctLine(text, font: font, color: white)
            let textWidth = lineWidth(line)
            let padX2 = 12 * sx
            let pillW2 = textWidth + 24 * sx
            let pillH2 = 34 * sy
            let pillRect = CGRect(x: 16 * sx, y: 16 * sy, width: pillW2, height: pillH2)
            context.setFillColor(CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 0.55))
            context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: panelBorderAlpha))
            context.setLineWidth(max(1, 1 * sx))
            context.addPath(CGPath(roundedRect: pillRect,
                                   cornerWidth: 8 * sx, cornerHeight: 8 * sy,
                                   transform: nil))
            context.drawPath(using: .fillStroke)
            let callBaseline = pillRect.minY + (pillH2 - ascent - descent) / 2 + descent
            context.textPosition = CGPoint(x: pillRect.minX + padX2, y: callBaseline)
            CTLineDraw(line, context)
        }

        // 车辆胶囊（独立胶囊，不塞进手机状态胶囊）：
        // 第一行大速度 + km/h（同基线），第二行闪电图标 + 电压 + 功率。
        // 没车数据时不画（不留空胶囊）。默认左上；手机胶囊在左上时
        // 改放右下（右上是仪表自己的显示区，左下是来电条，都不能放）。
        // 功率是中继传来的大小（10W 一档），回充的负号传不过来——
        // App 内的车辆卡片显示带符号的完整值。
        if let vehicle {
            let bigFontSize = fontSize * 1.8
            let bigFont = CTFontCreateWithName("Helvetica-Bold" as CFString, bigFontSize, nil)
            let bigAscent = CTFontGetAscent(bigFont)
            let bigDescent = CTFontGetDescent(bigFont)
            let bigRowHeight = bigAscent + bigDescent
            let speedLine = ctLine("\(vehicle.speedKmh)", font: bigFont, color: white)
            let unitLine = ctLine("km/h", font: font, color: white)
            let voltLine = ctLine("\(vehicle.voltageV)V", font: font, color: white)
            let powerLine = ctLine("\(vehicle.powerW)W", font: font, color: white)
            let row1W = lineWidth(speedLine) + iconTextGap + lineWidth(unitLine)
            let row2W = iconSize + iconTextGap + lineWidth(voltLine) + groupGap + lineWidth(powerLine)
            let vPillW = max(row1W, row2W) + padX * 2
            let vPillH = padY * 2 + bigRowHeight + rowGap + rowHeight
            let vPillX: CGFloat
            let vPillY: CGFloat
            if settings.position == .topLeft {
                vPillX = (refWidth - marginRightRef) * sx - vPillW
                vPillY = marginBottomRef * sy
            } else {
                vPillX = marginLeftRef * sx
                vPillY = h - marginTopRef * sy - vPillH
            }
            // 底板（跟手机胶囊同款：黑 45% + 白 35% 边，圆角 12）
            let vPanel = CGRect(x: vPillX, y: vPillY, width: vPillW, height: vPillH)
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: panelAlpha))
            context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: panelBorderAlpha))
            context.setLineWidth(max(1, 1 * sx))
            context.addPath(CGPath(roundedRect: vPanel,
                                   cornerWidth: panelCornerRef * sx,
                                   cornerHeight: panelCornerRef * sy,
                                   transform: nil))
            context.drawPath(using: .fillStroke)
            let vShadow = CGColor(red: 0, green: 0, blue: 0, alpha: 0.85)
            context.setShadow(offset: CGSize(width: 0, height: -2), blur: 3, color: vShadow)
            // 第一行：大速度 + km/h（同基线，左对齐）
            let vTopFromTop = h - (vPillY + vPillH)
            let row1Baseline = h - (vTopFromTop + padY) - bigAscent
            var vx = vPillX + padX
            context.textPosition = CGPoint(x: vx, y: row1Baseline)
            CTLineDraw(speedLine, context)
            vx += lineWidth(speedLine) + iconTextGap
            context.textPosition = CGPoint(x: vx, y: row1Baseline)
            CTLineDraw(unitLine, context)
            // 第二行：闪电图标 + 电压 + 功率
            let row2Top = vTopFromTop + padY + bigRowHeight + rowGap
            let row2Baseline = h - row2Top - ascent
            let textCenterY2 = row2Baseline + (ascent - descent) / 2
            var vx2 = vPillX + padX
            let boltRect = CGRect(x: vx2, y: textCenterY2 - iconSize / 2,
                                  width: iconSize, height: iconSize)
            drawIcon(.bolt, in: boltRect, context: context)
            vx2 += iconSize + iconTextGap
            context.textPosition = CGPoint(x: vx2, y: row2Baseline)
            CTLineDraw(voltLine, context)
            vx2 += lineWidth(voltLine) + groupGap
            context.textPosition = CGPoint(x: vx2, y: row2Baseline)
            CTLineDraw(powerLine, context)
        }

        return context.makeImage()
    }

    // MARK: - 图标（CoreGraphics 手画，白色，后台线程安全）

    private static func drawIcon(_ kind: IconKind, in rect: CGRect, context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.setLineWidth(max(1, rect.width * 0.07))
        context.setLineCap(.round)
        switch kind {
        case .clock:
            // 圆圈 + 两根指针
            let c = CGPoint(x: rect.midX, y: rect.midY)
            let r = rect.width * 0.38
            context.addArc(center: c, radius: r, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
            context.strokePath()
            context.beginPath()
            context.move(to: c)
            context.addLine(to: CGPoint(x: c.x, y: c.y + r * 0.72))
            context.move(to: c)
            context.addLine(to: CGPoint(x: c.x + r * 0.55, y: c.y - r * 0.35))
            context.strokePath()
        case .wifi:
            // 三道弧 + 一个点（圆心在图标底部）
            let c = CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.12)
            for f in [0.30, 0.52, 0.74] {
                context.addArc(center: c, radius: rect.width * f,
                               startAngle: .pi * 0.25, endAngle: .pi * 0.75, clockwise: false)
                context.strokePath()
            }
            context.addArc(center: c, radius: rect.width * 0.06,
                           startAngle: 0, endAngle: 2 * .pi, clockwise: false)
            context.fillPath()
        case .weather(let code):
            drawWeather(code: code, in: rect, context: context)
        case .music:
            // 音符：下面一个实心椭圆 + 竖线 + 顶上小旗
            let headW = rect.width * 0.34
            let headH = rect.height * 0.26
            let head = CGRect(x: rect.minX + rect.width * 0.18,
                              y: rect.minY + rect.height * 0.08,
                              width: headW, height: headH)
            context.addEllipse(in: head)
            context.fillPath()
            let stemX = head.maxX - headW * 0.15
            context.beginPath()
            context.move(to: CGPoint(x: stemX, y: head.midY))
            context.addLine(to: CGPoint(x: stemX, y: rect.maxY - rect.height * 0.08))
            context.strokePath()
            context.beginPath()
            context.move(to: CGPoint(x: stemX, y: rect.maxY - rect.height * 0.08))
            context.addQuadCurve(to: CGPoint(x: stemX + rect.width * 0.34, y: rect.maxY - rect.height * 0.32),
                                 control: CGPoint(x: stemX + rect.width * 0.3, y: rect.maxY - rect.height * 0.06))
            context.addLine(to: CGPoint(x: stemX + rect.width * 0.34, y: rect.maxY - rect.height * 0.52))
            context.addQuadCurve(to: CGPoint(x: stemX, y: rect.maxY - rect.height * 0.3),
                                 control: CGPoint(x: stemX + rect.width * 0.3, y: rect.maxY - rect.height * 0.28))
            context.closePath()
            context.fillPath()
        case .speaker:
            // 喇叭：左边小方块 + 右边锥形 + 两道声波弧
            let bx = rect.minX + rect.width * 0.08
            let bw = rect.width * 0.2
            let bh = rect.height * 0.36
            context.fill(CGRect(x: bx, y: rect.midY - bh / 2, width: bw, height: bh))
            context.beginPath()
            context.move(to: CGPoint(x: bx + bw, y: rect.midY - bh / 2))
            context.addLine(to: CGPoint(x: bx + bw + rect.width * 0.34, y: rect.minY + rect.height * 0.1))
            context.addLine(to: CGPoint(x: bx + bw + rect.width * 0.34, y: rect.maxY - rect.height * 0.1))
            context.addLine(to: CGPoint(x: bx + bw, y: rect.midY + bh / 2))
            context.closePath()
            context.fillPath()
            let c = CGPoint(x: bx + bw + rect.width * 0.34, y: rect.midY)
            context.addArc(center: c, radius: rect.width * 0.12,
                           startAngle: -.pi / 3, endAngle: .pi / 3, clockwise: false)
            context.strokePath()
            context.addArc(center: c, radius: rect.width * 0.24,
                           startAngle: -.pi / 3, endAngle: .pi / 3, clockwise: false)
            context.strokePath()
        case .bolt:
            drawBolt(in: rect, context: context)
        }
    }

    /// Open-Meteo weather_code → 手绘天气图标。
    private static func drawWeather(code: Int, in rect: CGRect, context: CGContext) {
        switch code {
        case 0:
            drawSun(in: rect, context: context)
        case 1, 2:
            drawPartlyCloudy(in: rect, context: context)
        case 3:
            drawCloud(in: rect, context: context)
        case 45, 48:
            drawCloud(in: rect, context: context)
            drawFogLines(in: rect, context: context)
        case 51, 53, 55, 61, 63, 65, 80, 81, 82:
            drawCloud(in: rect, context: context)
            drawRainDrops(in: rect, context: context)
        case 71, 73, 75:
            drawCloud(in: rect, context: context)
            drawSnowDots(in: rect, context: context)
        case 95:
            drawCloud(in: rect, context: context)
            drawBolt(in: rect, context: context)
        default:
            drawCloud(in: rect, context: context)
        }
    }

    private static func drawSun(in rect: CGRect, context: CGContext) {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = rect.width * 0.20
        context.addArc(center: c, radius: r, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
        context.fillPath()
        // 8 根光线
        for i in 0..<8 {
            let a = CGFloat(i) * .pi / 4
            let p1 = CGPoint(x: c.x + cos(a) * r * 1.45, y: c.y + sin(a) * r * 1.45)
            let p2 = CGPoint(x: c.x + cos(a) * r * 2.05, y: c.y + sin(a) * r * 2.05)
            context.beginPath()
            context.move(to: p1)
            context.addLine(to: p2)
            context.strokePath()
        }
    }

    private static func drawCloud(in rect: CGRect, context: CGContext) {
        // 三个圆 + 一个底座，同色重叠成一朵云
        let s = rect.width
        let base = CGRect(x: rect.minX + s * 0.12, y: rect.minY + s * 0.18,
                          width: s * 0.76, height: s * 0.34)
        context.fill(base)
        for (fx, fy, fr) in [(0.30, 0.48, 0.20), (0.55, 0.60, 0.24), (0.78, 0.48, 0.18)] {
            let c = CGPoint(x: rect.minX + s * fx, y: rect.minY + s * fy)
            context.addArc(center: c, radius: s * fr, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
            context.fillPath()
        }
    }

    private static func drawPartlyCloudy(in rect: CGRect, context: CGContext) {
        // 左上小太阳 + 右下云
        let s = rect.width
        let sunRect = CGRect(x: rect.minX, y: rect.minY + s * 0.45, width: s * 0.55, height: s * 0.55)
        drawSun(in: sunRect, context: context)
        let cloudRect = CGRect(x: rect.minX + s * 0.30, y: rect.minY, width: s * 0.70, height: s * 0.70)
        drawCloud(in: cloudRect, context: context)
    }

    private static func drawRainDrops(in rect: CGRect, context: CGContext) {
        let s = rect.width
        for fx in [0.30, 0.52, 0.74] {
            let x = rect.minX + s * fx
            context.beginPath()
            context.move(to: CGPoint(x: x + s * 0.04, y: rect.minY + s * 0.16))
            context.addLine(to: CGPoint(x: x - s * 0.04, y: rect.minY + s * 0.02))
            context.strokePath()
        }
    }

    private static func drawSnowDots(in rect: CGRect, context: CGContext) {
        let s = rect.width
        for (fx, fy) in [(0.32, 0.10), (0.52, 0.04), (0.72, 0.10)] {
            let c = CGPoint(x: rect.minX + s * fx, y: rect.minY + s * fy)
            context.addArc(center: c, radius: s * 0.045, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
            context.fillPath()
        }
    }

    private static func drawFogLines(in rect: CGRect, context: CGContext) {
        let s = rect.width
        for fy in [0.12, 0.03] {
            context.beginPath()
            context.move(to: CGPoint(x: rect.minX + s * 0.22, y: rect.minY + s * fy))
            context.addLine(to: CGPoint(x: rect.minX + s * 0.80, y: rect.minY + s * fy))
            context.strokePath()
        }
    }

    private static func drawBolt(in rect: CGRect, context: CGContext) {
        // 云下的小闪电
        let s = rect.width
        let pts = [
            CGPoint(x: rect.minX + s * 0.56, y: rect.minY + s * 0.20),
            CGPoint(x: rect.minX + s * 0.42, y: rect.minY + s * 0.02),
            CGPoint(x: rect.minX + s * 0.52, y: rect.minY + s * 0.02),
            CGPoint(x: rect.minX + s * 0.44, y: rect.minY - s * 0.12),
            CGPoint(x: rect.minX + s * 0.62, y: rect.minY + s * 0.04),
            CGPoint(x: rect.minX + s * 0.52, y: rect.minY + s * 0.04)
        ]
        context.beginPath()
        context.move(to: pts[0])
        for p in pts.dropFirst() { context.addLine(to: p) }
        context.closePath()
        context.fillPath()
    }

    /// 电池图标：圆角外框 + 按电量填充 + 右边小凸起；充电中填充变绿
    /// 并在里面画一道深色闪电。
    private static func drawBattery(level: Float, charging: Bool, low: Bool, in rect: CGRect, context: CGContext) {
        // 低电量：轮廓和填充都变红。
        let tint = low ? CGColor(red: 1, green: 0.25, blue: 0.25, alpha: 1)
                       : CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.setStrokeColor(tint)
        context.setFillColor(tint)
        let s = rect.width
        let bodyW = s * 0.78
        let bodyH = s * 0.52
        let bodyX = rect.minX + s * 0.02
        let bodyY = rect.midY - bodyH / 2
        let body = CGRect(x: bodyX, y: bodyY, width: bodyW, height: bodyH)
        let lw = max(1, s * 0.06)
        context.setLineWidth(lw)
        context.addPath(CGPath(roundedRect: body, cornerWidth: s * 0.08, cornerHeight: s * 0.08, transform: nil))
        context.strokePath()
        // 右边凸起
        let nub = CGRect(x: bodyX + bodyW, y: rect.midY - bodyH * 0.22,
                         width: s * 0.07, height: bodyH * 0.44)
        context.fill(nub)
        // 填充
        let clamped = max(0, min(1, level < 0 ? 0 : level))
        if clamped > 0 {
            let inset: CGFloat = lw + s * 0.03
            let fillW = (bodyW - inset * 2) * CGFloat(clamped)
            let fillRect = CGRect(x: bodyX + inset, y: bodyY + inset,
                                  width: fillW, height: bodyH - inset * 2)
            if charging {
                context.setFillColor(CGColor(red: 0.25, green: 0.85, blue: 0.35, alpha: 1))
            } else if low {
                context.setFillColor(CGColor(red: 1, green: 0.25, blue: 0.25, alpha: 1))
            } else {
                context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            }
            context.fill(fillRect)
            if charging {
                // 深色闪电盖在绿填充上
                context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.75))
                let cx = bodyX + bodyW * 0.5
                let cy = rect.midY
                let bw = bodyW * 0.16
                let bh = bodyH * 0.38
                let pts = [
                    CGPoint(x: cx + bw * 0.4, y: cy + bh),
                    CGPoint(x: cx - bw * 0.6, y: cy - bh * 0.1),
                    CGPoint(x: cx - bw * 0.05, y: cy - bh * 0.1),
                    CGPoint(x: cx - bw * 0.4, y: cy - bh),
                    CGPoint(x: cx + bw * 0.6, y: cy + bh * 0.1),
                    CGPoint(x: cx + bw * 0.05, y: cy + bh * 0.1)
                ]
                context.beginPath()
                context.move(to: pts[0])
                for p in pts.dropFirst() { context.addLine(to: p) }
                context.closePath()
                context.fillPath()
            }
        }
    }
}
