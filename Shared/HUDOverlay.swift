import CallKit
import CoreGraphics
import CoreLocation
import CoreText
import CoreVideo
import Foundation
import UIKit

/// 仪表 HUD 叠加层：电量 / 日期时间 / 天气 / 来电提示。
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
/// - 文字用 CoreText（不用 UIKit 文本绘制），后台队列安全；
///   画法与 TestImageSource 相同（CGContext + CTLineDraw），
///   仪表上已验证是正的。
/// - 通知不在这里：iOS 不让第三方 App 读别的 App 的通知。

// MARK: - 数据（单例，缓存值）

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
    private var _batteryText = "电量 --"
    private var _dateText = ""
    private var _weatherText: String?
    private var _calling = false

    private let dateFormatter: DateFormatter
    private var timer: DispatchSourceTimer?
    private var locationManager: CLLocationManager?
    private var lastWeatherFetch = Date.distantPast
    private var weatherFetching = false
    private var locationRequested = false

    private let callObserver = CXCallObserver()
    private let callQueue = DispatchQueue(label: "ninebotcast.hud.calls")
    private var activeCalls = Set<UUID>()

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

        // 每秒刷新电量/日期（主线程，轻量）；天气按 20 分钟周期检查。
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        t.schedule(deadline: .now(), repeating: .seconds(1))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
        tick()
    }

    /// 帧路径只读这个：三行文字 + 是否来电。
    func snapshot() -> (lines: [String], calling: Bool) {
        lock.lock()
        defer { lock.unlock() }
        var lines = [_batteryText, _dateText]
        if let w = _weatherText { lines.append(w) }
        return (lines, _calling)
    }

    // MARK: - 每秒刷新（主线程）

    private func tick() {
        let level = UIDevice.current.batteryLevel
        let state = UIDevice.current.batteryState
        let battery: String
        if level < 0 {
            battery = "电量 --"
        } else if state == .charging || state == .full {
            battery = "电量 \(Int(level * 100))% 充电中"
        } else {
            battery = "电量 \(Int(level * 100))%"
        }
        let date = dateFormatter.string(from: Date())
        lock.lock()
        _batteryText = battery
        _dateText = date
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
        default: // denied / restricted：没有定位，天气行直接不显示。
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
            let text = "\(Self.condition(for: code.intValue)) \(Int(temp.doubleValue))°"
            self.lock.lock()
            self._weatherText = text
            self.lock.unlock()
        }.resume()
    }

    /// Open-Meteo weather_code → 中文
    static func condition(for code: Int) -> String {
        switch code {
        case 0: return "晴"
        case 1, 2: return "多云"
        case 3: return "阴"
        case 45, 48: return "雾"
        case 51, 53, 55: return "毛毛雨"
        case 61, 63, 65: return "雨"
        case 71, 73, 75: return "雪"
        case 80, 81, 82: return "阵雨"
        case 95: return "雷雨"
        default: return "多云"
        }
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
    // 848x480 参考坐标：仪表自己的画面占 (640,44)-(842,254)，
    // HUD 文字放右列、遮挡区下方；来电红条放左下角。
    // 1.0.5：字改小（30→22）、行距收紧（42→32），整块文字罩一块
    // 半透明磨砂板（黑底 40% + 白边 35%，圆角 10）。
    private static let refWidth: CGFloat = 848
    private static let refHeight: CGFloat = 480
    private static let rightXRef: CGFloat = 836
    private static let firstTopRef: CGFloat = 272
    private static let lineStepRef: CGFloat = 32
    private static let fontSizeRef: CGFloat = 22
    private static let panelAlpha: CGFloat = 0.40
    private static let panelBorderAlpha: CGFloat = 0.35
    private static let panelCornerRef: CGFloat = 10
    private static let panelPadXRef: CGFloat = 12
    private static let panelPadRightRef: CGFloat = 8
    private static let panelPadYRef: CGFloat = 10

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
        let (lines, calling) = HUDData.shared.snapshot()
        let key = "\(width)x\(height)|\(lines.joined(separator: "\n"))|\(calling ? 1 : 0)"
        lock.lock()
        defer { lock.unlock() }
        if key == cachedKey, let layer = cachedLayer { return layer }
        // 内容变了但离上次重画不到 1 秒：先用旧层，不阻塞帧路径。
        if let layer = cachedLayer, Date().timeIntervalSince(lastRender) < 1.0 {
            return layer
        }
        guard let layer = renderLayer(width: width, height: height,
                                      lines: lines, calling: calling) else {
            return cachedLayer
        }
        cachedKey = key
        cachedLayer = layer
        lastRender = Date()
        return layer
    }

    /// 把三行文字 + 来电红条画进一张全尺寸透明层。
    /// CGContext 在这里是 y 朝上的坐标系（与 TestImageSource 相同），
    /// 所以「离顶 xx」要换算成 baseline = 高 - 顶距 - 上伸。
    private static func renderLayer(width: Int, height: Int,
                                    lines: [String], calling: Bool) -> CGImage? {
        guard !lines.isEmpty || calling else { return nil }
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }

        let sx = CGFloat(width) / refWidth
        let sy = CGFloat(height) / refHeight
        let h = CGFloat(height)

        let fontSize = max(16, fontSizeRef * sy)
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)

        // 先量每行宽度（不画），才能给整块文字配一块磨砂底板。
        let rightX = rightXRef * sx
        var ctLines: [(line: CTLine, width: CGFloat, ascent: CGFloat, descent: CGFloat)] = []
        var maxWidth: CGFloat = 0
        for line in lines {
            let attrs: [CFString: Any] = [
                kCTFontAttributeName: font,
                kCTForegroundColorAttributeName: white
            ]
            guard let attrStr = CFAttributedStringCreate(
                kCFAllocatorDefault, line as CFString, attrs as CFDictionary) else { continue }
            let ctLine = CTLineCreateWithAttributedString(attrStr)
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let w = CGFloat(CTLineGetTypographicBounds(ctLine, &ascent, &descent, &leading))
            ctLines.append((ctLine, w, ascent, descent))
            maxWidth = max(maxWidth, w)
        }

        // 磨砂面板：半透明黑底 + 细亮边，罩住整个右列文字（一块板，
        // 不是每行一块）。平面半透明板，不是真高斯模糊——真模糊要逐帧
        // 采样底图，扩展 50MB 预算扛不住；半透明板盖在视频上看过去
        // 就是磨砂玻璃。板顶在遮挡区（底边 254）下方，不挡仪表画面。
        if !ctLines.isEmpty {
            let padX = panelPadXRef * sx
            let padRight = panelPadRightRef * sx
            let padY = panelPadYRef * sy
            let stackTop = firstTopRef * sy
            let stackBottom = stackTop
                + CGFloat(ctLines.count - 1) * lineStepRef * sy + fontSize
            let panel = CGRect(
                x: rightX - maxWidth - padX,
                y: h - stackBottom - padY,
                width: maxWidth + padX + padRight,
                height: (stackBottom - stackTop) + padY * 2)
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: panelAlpha))
            context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: panelBorderAlpha))
            context.setLineWidth(max(1, 1 * sx))
            context.addPath(CGPath(roundedRect: panel,
                                   cornerWidth: panelCornerRef * sx,
                                   cornerHeight: panelCornerRef * sy,
                                   transform: nil))
            context.drawPath(using: .fillStroke)
        }

        // 右列三行，右对齐，遮挡区下方开始往下排。
        let shadow = CGColor(red: 0, green: 0, blue: 0, alpha: 0.85)
        context.setShadow(offset: CGSize(width: 0, height: -2), blur: 3, color: shadow)
        var top = firstTopRef * sy
        for (ctLine, lineWidth, ascent, _) in ctLines {
            context.textPosition = CGPoint(x: rightX - lineWidth, y: h - top - ascent)
            CTLineDraw(ctLine, context)
            top += lineStepRef * sy
        }

        // 来电：左下角红色圆角条，半透明红底 + 细亮边，字随正文一起改小。
        if calling {
            let text = "来电"
            let attrs: [CFString: Any] = [
                kCTFontAttributeName: font,
                kCTForegroundColorAttributeName: white
            ]
            if let attrStr = CFAttributedStringCreate(
                kCFAllocatorDefault, text as CFString, attrs as CFDictionary) {
                let ctLine = CTLineCreateWithAttributedString(attrStr)
                var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
                let textWidth = CGFloat(CTLineGetTypographicBounds(ctLine, &ascent, &descent, &leading))
                let padX = 12 * sx
                let pillW = textWidth + 24 * sx
                let pillH = 34 * sy
                let pillRect = CGRect(x: 16 * sx, y: 16 * sy, width: pillW, height: pillH)
                context.setFillColor(CGColor(red: 0.9, green: 0.1, blue: 0.1, alpha: 0.55))
                context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: panelBorderAlpha))
                context.setLineWidth(max(1, 1 * sx))
                context.addPath(CGPath(roundedRect: pillRect,
                                       cornerWidth: 8 * sx, cornerHeight: 8 * sy,
                                       transform: nil))
                context.drawPath(using: .fillStroke)
                let baseline = pillRect.minY + (pillH - ascent - descent) / 2 + descent
                context.textPosition = CGPoint(x: pillRect.minX + padX, y: baseline)
                CTLineDraw(ctLine, context)
            }
        }

        return context.makeImage()
    }
}
