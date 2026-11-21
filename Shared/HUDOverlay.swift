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
/// 有 ANT BMS 数据时右上角车辆表盘下面再加一块单独面板：三排、每排两个
///（电压/电流、功率/电量、最高温/压差），宽度跟那个表盘对齐（1.3.11，同朋友版 105）。
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
    var volume: Float // 手机音量 0...1，-1 = 未知
    var bms: BMSHUDData? // ANT BMS 读数（没数据就是 nil）
    var speed: SpeedHUDData? // 超速行（只在骑行超速时才有值）
}

/// HUD 上超速行的数据（1.2.9，RideTracker → SpeedRelay 中继来）。
struct SpeedHUDData: Equatable {
    var kmh: Int
    var overspeed: Bool
}

/// HUD 上 BMS 行的数据（电压/电流/功率/SOC/最高温/压差）。
struct BMSHUDData: Equatable {
    var voltage: Float
    var current: Float
    var power: Float
    var soc: Float
    var maxTemp: Int
    var delta: Int
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
    private var _volume: Float = -1
    private var _bms: BMSHUDData?
    private var _speed: SpeedHUDData?

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
                           volume: _volume,
                           bms: _bms,
                           speed: _speed)
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
        // 手机音量（0...1）。
        var volume = AVAudioSession.sharedInstance().outputVolume
        // 手机电量（0...1）：扩展进程直接读 UIDevice.batteryLevel 是陈旧值，
        // 跟音量一个毛病（1.3.3 实测仪表显示 100%，手机实际 95%），
        // 所以 1.3.4 也走 HUDDataRelay 中继。
        var batteryLevel = level
        var batteryCharging = (state == .charging || state == .full)
        if isExtension {
            // 扩展进程读不到真实音量（outputVolume 是陈旧值，
            // 1.1.0 实测音量卡在 5% 不动）：优先用主 App 中继来的新鲜值；
            // 中继过期或没值时回落到本地读数（和现在一样，不崩）。
            // App 没跑过时中继就没有，扩展就跟以前一样。
            // 1.1.7：中继改逐名订阅（NULL 名观察者在扩展里静默失效，
            // 是 1.1.1–1.1.6 音量镜像不实时的根因之一）。
            // 1.1.9：音乐已删，只中继音量。
            if let relayed = HUDDataRelay.current {
                if relayed.volume >= 0 { volume = relayed.volume }
            }
            // 电量中继（1.3.4）：新鲜就用中继值，过期或没值回落本地读数。
            if let relayedBattery = HUDDataRelay.currentBattery,
               relayedBattery.level >= 0 {
                batteryLevel = relayedBattery.level
                batteryCharging = relayedBattery.charging
            }
        } else {
            // App 进程：本地读数是真的，读完发给扩展画镜像 HUD。
            HUDDataRelay.update(volume: volume)
            HUDDataRelay.update(batteryLevel: level, charging: batteryCharging)
        }
        // ANT BMS（1.2.0）：和音量同一路子——App 进程读中继的本地缓存
        //（ANTBMS 解析到帧就调 ANTBMSRelay.update），扩展进程读通知；
        // 5 秒过期就当没数据，BMS 行消失。
        var bms: BMSHUDData?
        if let r = ANTBMSRelay.current {
            bms = BMSHUDData(voltage: r.voltage, current: r.current,
                             power: r.voltage * r.current, soc: r.soc,
                             maxTemp: r.maxTemp, delta: r.delta)
        }
        // 超速（1.2.9）：RideTracker 只在骑行超速时发 SpeedRelay；
        // 中继 3 秒过期就当没超速，红行消失。
        var speed: SpeedHUDData?
        if let r = SpeedRelay.current, r.overspeed {
            speed = SpeedHUDData(kmh: r.speedKmh, overspeed: true)
        }
        lock.lock()
        _batteryLevel = batteryLevel
        _batteryCharging = batteryCharging
        _dateText = date
        _volume = volume
        _bms = bms
        _speed = speed
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

    // MARK: - 老虎机状态机（1.3.12）
    //
    // 骑行开始（SpeedRelay 车速 > 2）：摇杆朝前方下面扳（0→80°，透视缩短），
    // 三格数字 1–9 上下滚动，越快转得越快。
    // 车停下（车速 < 1）：摇杆弹回 0°，三格依次停下（0 / 0.4 / 0.8 秒），
    // 每格滑到最近的 8 停住，最后 888。
    // 数字带是 1–9 循环，格距 40 参考点；偏移 ≡ 280（= 7×40）时正中是 8。
    private static let slotPitch: CGFloat = 40
    private static var slotOffsets: [CGFloat] = [0, 0, 0]      // 每格滚动偏移（参考点）
    private static let slotRateMul: [CGFloat] = [1.0, 1.5, 0.7] // 三格转速倍率（1.3.15：各格不同速，骑行时显示不同数字）
    private static var slotLever: CGFloat = 0                   // 摇杆角度 0–80
    private static var slotSpinning = false
    private static var slotStopAt: [Date?] = [nil, nil, nil]    // 每格停下的时刻
    private static var slotSettle: [CGFloat?] = [nil, nil, nil] // 每格对准 8 的目标偏移
    private static var slotLastTick = Date.distantPast

    /// 每帧调一次，推进老虎机状态。返回：老虎机是否在动
    /// （在动时 layer() 用 150ms 档重画；静止时走正常 1 秒节流）。
    private static func slotTick(now: Date, speedKmh: Int, enabled: Bool) -> Bool {
        guard enabled else {
            // 没开老虎机：状态归零，下次开从 888 / 摇杆 0 开始。
            if slotLever != 0 || slotOffsets != [0, 0, 0] || slotSpinning {
                slotOffsets = [0, 0, 0]
                slotLever = 0
                slotSpinning = false
                slotStopAt = [nil, nil, nil]
                slotSettle = [nil, nil, nil]
                slotLastTick = .distantPast
            }
            return false
        }
        let dt = slotLastTick == .distantPast ? 0 : now.timeIntervalSince(slotLastTick)
        slotLastTick = now
        let dtC = CGFloat(min(max(dt, 0), 0.5))
        let spinning = speedKmh > 2
        // 摇杆：转时目标 80°，停时目标 0°；每秒 240° 逼近。
        let leverTarget: CGFloat = spinning ? 80 : 0
        let leverStep = CGFloat(240) * dtC
        if slotLever < leverTarget { slotLever = min(leverTarget, slotLever + leverStep) }
        else if slotLever > leverTarget { slotLever = max(leverTarget, slotLever - leverStep) }
        if spinning {
            if !slotSpinning {
                slotSpinning = true
                slotStopAt = [nil, nil, nil]
                slotSettle = [nil, nil, nil]
            }
            // 滚动速度随车速：每秒 2 + 车速/10 格；三格转速不同（1.0 / 1.5 / 0.7），
            // 骑行时三格显示不同数字（真老虎机三格是独立转的），停下仍各滑到 888。
            // 偏移对 360 取余防越滚越大。
            let baseRate = slotPitch * (2 + CGFloat(speedKmh) / 10)
            for i in 0..<3 {
                slotOffsets[i] += baseRate * slotRateMul[i] * dtC
                slotOffsets[i] = slotOffsets[i].truncatingRemainder(dividingBy: 9 * slotPitch)
            }
        } else {
            if slotSpinning {
                // 刚停下：排停表，三格依次停（0 / 0.4 / 0.8 秒）。
                slotSpinning = false
                for i in 0..<3 { slotStopAt[i] = now.addingTimeInterval(Double(i) * 0.4) }
            }
            for i in 0..<3 {
                guard let t = slotStopAt[i], now >= t else { continue }
                if slotSettle[i] == nil {
                    // 下一个 8：偏移 ≡ 280（mod 360）。
                    let period = 9 * slotPitch
                    let rem = slotOffsets[i].truncatingRemainder(dividingBy: period)
                    var target = slotOffsets[i] - rem + 7 * slotPitch
                    if target < slotOffsets[i] { target += period }
                    slotSettle[i] = target
                }
                if let target = slotSettle[i] {
                    // 滑向 8：每帧走剩下距离的 1/4，快到时贴上去。
                    slotOffsets[i] += (target - slotOffsets[i]) * min(1, dtC / 0.25)
                    if abs(target - slotOffsets[i]) < 0.5 {
                        slotOffsets[i] = target.truncatingRemainder(dividingBy: 9 * slotPitch)
                        slotSettle[i] = nil
                        slotStopAt[i] = nil
                    }
                }
            }
        }
        // 在动 = 转着，或摇杆没归位，或还有格子没停稳。
        if spinning || slotLever != 0 { return true }
        for i in 0..<3 {
            if slotStopAt[i] != nil || slotSettle[i] != nil { return true }
        }
        return false
    }

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
        // 老虎机（1.3.12）：每帧推进一次状态（转/停/摇杆），
        // 动的时候缓存键里加一个 150ms 档位，逼重画跟上动画。
        let slotMoving = slotTick(now: Date(), speedKmh: SpeedRelay.current?.speedKmh ?? 0, enabled: settings.showSlot)
        let slotBucket = slotMoving ? Int(Date().timeIntervalSinceReferenceDate / 0.15) : -1
        let settingsKey = "\(settings.showDate ? 1 : 0)\(settings.showWeather ? 1 : 0)\(settings.showSignal ? 1 : 0)\(settings.showBattery ? 1 : 0)\(settings.showVolume ? 1 : 0)\(settings.showBMS ? 1 : 0)\(settings.showSlot ? 1 : 0)|\(settings.position.rawValue)|\(settings.fontSize.rawValue)"
        let bmsKey = snap.bms.map { "\($0.voltage)|\($0.current)|\($0.power)|\($0.soc)|\($0.maxTemp)|\($0.delta)" } ?? "-"
        let speedKey = snap.speed.map { "\($0.kmh)" } ?? "-"
        let key = "\(width)x\(height)|\(snap.date)|\(snap.weatherCode ?? -1)|\(snap.weatherTemp ?? -999)|\(snap.batteryLevel)|\(snap.charging ? 1 : 0)|\(snap.network.cacheKey)|\(snap.calling ? 1 : 0)|\(snap.volume)|\(bmsKey)|\(speedKey)|\(settingsKey)|slot\(slotBucket)"
        lock.lock()
        defer { lock.unlock() }
        if key == cachedKey, let layer = cachedLayer { return layer }
        // 内容变了但离上次重画不到节流间隔：先用旧层，不阻塞帧路径。
        // 平时 1 秒；老虎机在动时 0.15 秒（数字滚动才跟得上）。
        let minInterval = slotMoving ? 0.15 : 1.0
        if let layer = cachedLayer, Date().timeIntervalSince(lastRender) < minInterval {
            return layer
        }
        guard let layer = renderLayer(width: width, height: height, snap: snap, settings: settings) else {
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
        case speaker // 喇叭（音量）
        case bolt // 闪电（ANT BMS）
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

    /// 把胶囊（最多三行：日期 / 天气信号音量电量 / 超速）+ 右上角 BMS 面板 + 来电红条画进一张全尺寸透明层。
    /// CGContext 在这里是 y 朝上的坐标系（与 TestImageSource 相同），
    /// 所以「离顶 xx」要换算成 baseline = 高 - 顶距 - 上伸。
    /// 设置全关、又没来电时返回一张全透明层（不是 nil），
    /// 这样旧胶囊才会从画面上消失；layer() 的缓存也随之更新。
    private static func renderLayer(width: Int, height: Int, snap: HUDSnapshot, settings: HUDSettings) -> CGImage? {
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
        // ANT BMS 单独一块面板（1.3.11，同朋友版 105）：放在右上角车辆自带表盘下面，
        // 宽度跟那个表盘对齐；三排、每排两个——电压/电流、功率/电量、最高温/压差。
        // 不再放进底下那个胶囊。
        var bmsItems: [String] = []
        // 老虎机和 BMS 面板互斥：老虎机开时 BMS 面板不画（设置页里也会互斥关，
        // 这里是扩展侧兜底，两个绝不同时出现）。
        if settings.showBMS, !settings.showSlot, let bms = snap.bms {
            bmsItems = [String(format: "电压 %.2fV", bms.voltage),
                        String(format: "电流 %.1fA", bms.current),
                        String(format: "功率 %.0fW", bms.power),
                        String(format: "电量 %.1f%%", bms.soc),
                        String(format: "最高温 %d°", bms.maxTemp),
                        String(format: "压差 %dmV", bms.delta)]
        }
        // 第五行：超速红行（1.2.9，只在骑行超速时画）。
        var row5: [Segment] = []
        if let speed = snap.speed, speed.overspeed {
            row5 = [.text("超速 \(speed.kmh) km/h", red)]
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

        // 只画非空的行；行数决定胶囊高度（一行就矮一点）。BMS 不再进胶囊。
        let measuredRows = [measure(row1), measure(row2), measure(row5)].filter { !$0.items.isEmpty }
        // 全关了、又没 BMS、又没来电：返回全透明层（旧胶囊随之消失）。
        if measuredRows.isEmpty && bmsItems.isEmpty && !snap.calling {
            return context.makeImage()
        }

        let contentWidth = measuredRows.map { $0.width }.max() ?? 0
        // 1.3.11：有 BMS 面板时，胶囊宽度跟它对齐（281，左沿 375），上下两块一样宽。
        let bmsPanelW = CGFloat(281) * sx
        let bmsPanelX = CGFloat(375) * sx
        var pillW = contentWidth + padX * 2
        if !bmsItems.isEmpty {
            pillW = max(pillW, bmsPanelW)
        }
        let rowCount = measuredRows.count
        let pillH = padY * 2 + rowHeight * CGFloat(rowCount) + rowGap * CGFloat(max(0, rowCount - 1))

        // 胶囊锚点按设置来（y 朝上坐标系）。有 BMS 面板且在右侧时，左沿跟 BMS 面板对齐。
        let pillX: CGFloat
        let pillY: CGFloat
        switch settings.position {
        case .bottomRight:
            pillX = (!bmsItems.isEmpty && pillW <= bmsPanelW + 0.5) ? bmsPanelX : (refWidth - marginRightRef) * sx - pillW
            pillY = marginBottomRef * sy
        case .bottomLeft:
            pillX = marginLeftRef * sx
            pillY = marginBottomRef * sy
        case .topLeft:
            pillX = marginLeftRef * sx
            pillY = h - marginTopRef * sy - pillH
        case .topRight:
            pillX = (!bmsItems.isEmpty && pillW <= bmsPanelW + 0.5) ? bmsPanelX : (refWidth - marginRightRef) * sx - pillW
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

        // ---- ANT BMS 单独面板（1.3.11，同朋友版 105）：右上角车辆自带表盘下面，宽度跟它对齐 ----
        // 1.3.14：紧贴表盘底沿（顶边 222，离底沿 8px），不再在表盘和胶囊之间垂直居中——
        // 居中会把它推到屏幕中部、压住地图/画面（用户 2026-11-21 照片反馈）。
        // 位置是按仪表照片量的（848×480 参考系）：表盘左沿 375、宽 281、底沿 214。
        if !bmsItems.isEmpty {
            let bmsLeft = bmsPanelX
            let bmsW = bmsPanelW
            let bmsH = padY * 2 + rowHeight * 3 + rowGap * 2
            let bmsTopFromTop: CGFloat = CGFloat(222) * sy
            let bmsY = h - bmsTopFromTop - bmsH
            let bmsPanel = CGRect(x: bmsLeft, y: bmsY, width: bmsW, height: bmsH)
            context.setShadow(offset: .zero, blur: 0, color: nil)
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: panelAlpha))
            context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: panelBorderAlpha))
            context.setLineWidth(max(1, 1 * sx))
            context.addPath(CGPath(roundedRect: bmsPanel,
                                   cornerWidth: panelCornerRef * sx,
                                   cornerHeight: panelCornerRef * sy,
                                   transform: nil))
            context.drawPath(using: .fillStroke)
            // 两列等宽；每排左列在左半，右列在右半。
            let shadow2 = CGColor(red: 0, green: 0, blue: 0, alpha: 0.85)
            context.setShadow(offset: CGSize(width: 0, height: -2), blur: 3, color: shadow2)
            let colW = (bmsW - padX * 2) / 2
            for r in 0..<3 {
                let rowTop = bmsTopFromTop + padY + CGFloat(r) * (rowHeight + rowGap)
                let baseline = h - rowTop - ascent
                for c in 0..<2 {
                    let idx = r * 2 + c
                    guard idx < bmsItems.count else { continue }
                    let line = ctLine(bmsItems[idx], font: font, color: white)
                    let x = bmsLeft + padX + CGFloat(c) * colW
                    context.textPosition = CGPoint(x: x, y: baseline)
                    CTLineDraw(line, context)
                }
            }
        }

        // ---- 老虎机（1.3.12）：跟 BMS 面板同一位置，互斥（BMS 不画时才画） ----
        // 机身图是用户参考图抠出来的（格子黑色、摇杆已去掉），数字是运行时画的
        // 文字（1–9 上下滚动，停下变 888），摇杆是运行时画的（向前下方扳动是
        // 透视缩短，不是往右下甩）。局部坐标是参考点、y 朝下，跟预览同一套数。
        if settings.showSlot, let tmpl = SlotMachineImage.image() {
            let slotW: CGFloat = 245  // 1.3.17：面板收窄（281→245），黑底不再比表盘/胶囊宽出一截；机身图 223 宽，两边各留 11px
            let slotH: CGFloat = 108
            // 位置（1.3.17）：顶边 265（222→265，往下 43px）。表盘底沿约 234（照片实测，旧 214 是朋友车的数）、胶囊顶约 403，
            // 两边间隙各约 30px（之前顶边 222 直接压住表盘底沿，照片上老虎机顶边比表盘底沿高约 12px）。
            let slotTopFromTop: CGFloat = CGFloat(265) * sy
            let slotX = (refWidth - marginRightRef - slotW) * sx  // 1.3.17：右对齐，X=591（848-12-245）
            // 局部（参考点、y 朝下）→ CG（y 朝上）的换算。
            func cgRect(_ r: CGRect) -> CGRect {
                CGRect(x: slotX + r.minX * sx,
                       y: h - slotTopFromTop - (r.minY + r.height) * sy,
                       width: r.width * sx, height: r.height * sy)
            }
            func cgPoint(_ p: CGPoint) -> CGPoint {
                CGPoint(x: slotX + p.x * sx, y: h - slotTopFromTop - p.y * sy)
            }
            context.setShadow(offset: .zero, blur: 0, color: nil)
            // 底板（1.3.13，方案 A）：黑透磨砂底板，衬白机身——导航地图是白的，
            // 白机身直接画在上面看不清；跟 BMS 面板同一套黑半透明 + 细亮边，
            // 只是更黑一点（0.55），白机身才跳得出来。
            let slotPanel = cgRect(CGRect(x: 0, y: 0, width: slotW, height: slotH))
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.55))
            context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: panelBorderAlpha))
            context.setLineWidth(max(1, 1 * sx))
            context.addPath(CGPath(roundedRect: slotPanel,
                                   cornerWidth: panelCornerRef * sx,
                                   cornerHeight: panelCornerRef * sy,
                                   transform: nil))
            context.drawPath(using: .fillStroke)
            // 机身图：高 104，横向拉长 1.4（用户定的，左右不那么空），面板内居中。
            let imgH: CGFloat = 104
            let imgW: CGFloat = 724 * (imgH / 473) * 1.4
            let imgX = (slotW - imgW) / 2
            context.draw(tmpl, in: cgRect(CGRect(x: imgX, y: 2, width: imgW, height: imgH)))
            // 三格数字：格子窗口（面板局部、y 朝下、参考点），跟预览同一套数。
            // 1.3.17：面板收窄 36px，机身图跟着左移 18px（imgX 29→11），格子同步左移 18px，
            // 仍对准模板里的黑格子（图内坐标不变）。
            let reels: [CGRect] = [
                CGRect(x: 47.67, y: 38.33, width: 42.33, height: 61.67),
                CGRect(x: 98.67, y: 38.33, width: 42.33, height: 61.67),
                CGRect(x: 147.67, y: 38.33, width: 42.67, height: 61.67),
            ]
            let digitFont = CTFontCreateWithName("Helvetica-Bold" as CFString, 32 * sy, nil)
            let digitAscent = CTFontGetAscent(digitFont)
            let digitDescent = CTFontGetDescent(digitFont)
            for (i, reel) in reels.enumerated() {
                context.saveGState()
                context.addPath(CGPath(roundedRect: cgRect(reel),
                                       cornerWidth: reel.width * sx / 2,
                                       cornerHeight: reel.height * sy / 2,
                                       transform: nil))
                context.clip()
                // 数字带 1–9 循环；偏移 slotOffsets[i]（参考点），画够覆盖格子。
                let off = slotOffsets[i]
                let pitch = slotPitch
                let jMin = Int(floor((off - reel.height / 2 - pitch) / pitch))
                let jMax = Int(ceil((off + reel.height / 2 + pitch) / pitch))
                for j in jMin...jMax {
                    let digit = ((j % 9) + 9) % 9 + 1
                    let cy = CGFloat(j) * pitch - off + reel.midY
                    let line = ctLine("\(digit)", font: digitFont, color: white)
                    let w = lineWidth(line)
                    let center = cgPoint(CGPoint(x: reel.midX, y: cy))
                    let baseline = center.y - (digitAscent - digitDescent) / 2
                    context.textPosition = CGPoint(x: center.x - w / 2, y: baseline)
                    CTLineDraw(line, context)
                }
                context.restoreGState()
            }
            // 摇杆：从支点（218, 56.1）出发；扳动是向前下方（透视缩短），
            // 球直直往下掉、杆变短、球微微变大，不是往右下甩。
            // 1.3.17：支点 x 跟机身图同步左移 18px（236→218）。
            let pivot = CGPoint(x: 218, y: 56.1)
            let rodLen: CGFloat = 47
            let th = slotLever * CGFloat.pi / 180
            let proj = rodLen * cos(th)
            let ballCenter = CGPoint(x: pivot.x + 10 * sin(th), y: pivot.y - proj)
            let ballR = 11 * (1 + 0.18 * sin(th))
            let pivotCG = cgPoint(pivot)
            let ballCG = cgPoint(ballCenter)
            context.setStrokeColor(CGColor(red: 0.78, green: 0.78, blue: 0.78, alpha: 1))
            context.setLineWidth(max(1, 4 * sx))
            context.setLineCap(.round)
            context.beginPath()
            context.move(to: pivotCG)
            context.addLine(to: ballCG)
            context.strokePath()
            context.setFillColor(white)
            context.setStrokeColor(CGColor(red: 0.7, green: 0.7, blue: 0.7, alpha: 1))
            context.setLineWidth(max(1, 2 * sx))
            context.addEllipse(in: CGRect(x: ballCG.x - ballR * sx,
                                          y: ballCG.y - ballR * sy,
                                          width: ballR * 2 * sx,
                                          height: ballR * 2 * sy))
            context.drawPath(using: .fillStroke)
        }

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
        case .bolt:
            drawBolt(in: rect, context: context)
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
