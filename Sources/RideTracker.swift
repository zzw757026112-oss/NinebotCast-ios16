import AudioToolbox
import Combine
import CoreLocation
import Foundation
import UIKit
import UserNotifications

/// 骑行记录（GPS，不接车）：1.2.9 新增。
///
/// 手动开始/结束。骑行中每 10 米收一个点，累加里程（CLLocation
/// distance(from:)），记时长、最高速度、当前速度；超速（Feature B）
/// 在这里判。历史存在 Documents/rides.json；进行中的骑行另存一份
/// Documents/current-ride.json——只含摘要和最后一个点，不含整条
/// 轨迹，文件只有几百字节，每次定位更新都写也不心疼；App 被杀后
/// 下次打开、最后一个点在 30 分钟内就能续上。
///
/// 后台：project.yml 里 UIBackgroundModes 加了 location；
/// allowsBackgroundLocationUpdates = true + pausesLocationUpdatesAutomatically
/// = false，退后台继续记。定位权限沿用天气的 WhenInUse，不新弹
/// 授权框；WhenInUse 下后台定位时状态栏会显示蓝色定位条，
/// 这是 iOS 的规矩。
struct RidePoint: Codable, Equatable {
    var lat: Double
    var lon: Double
    var time: TimeInterval // 1970 秒
    var speed: Double // m/s，-1 = 未知
}

struct RideRecord: Codable, Identifiable, Equatable {
    var id: UUID
    var startTime: Date
    var endTime: Date
    var distanceM: Double
    var maxSpeedKmh: Double

    var durationSec: Int { max(0, Int(endTime.timeIntervalSince(startTime))) }
    var avgSpeedKmh: Double {
        durationSec > 0 ? distanceM / Double(durationSec) * 3.6 : 0
    }
}

/// 进行中的骑行（可恢复的最小状态）：不含整条轨迹。
private struct RideProgress: Codable {
    var startTime: Date
    var distanceM: Double
    var maxSpeedKmh: Double
    var lastLat: Double
    var lastLon: Double
    var lastTime: TimeInterval
}

/// 超速本地通知（1.3.8，应用内逻辑，不走 Darwin 接力、不碰扩展）：
/// 上升沿发一条系统通知，identifier 固定，只留最新一条，不堆叠。
/// 前台也要弹横幅，所以要挂 delegate（willPresent 返回 [.banner, .sound]，
/// 否则 App 在前台时通知只进通知中心不弹出来——骑行时手机常在前台导航）。
/// delegate 是 weak 引用，用静态属性强持有，别让它被释放。
enum OverspeedNotifier {
    private static let delegate = OverspeedNotificationDelegate()

    /// 启动时调一次：挂 delegate + 请求通知授权（已决定过就是空操作，不重复弹）。
    static func setup() {
        UNUserNotificationCenter.current().delegate = delegate
        requestAuthorization()
    }

    /// 超速提醒 Toggle 打开时调一次（options 只取 alert + sound）。
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// 发超速通知（立即触发，identifier 固定 "nbc.overspeed"）。
    static func post() {
        let content = UNMutableNotificationContent()
        content.title = "超速提醒"
        content.body = "您已超速行驶，请注意安全"
        content.sound = .default
        let request = UNNotificationRequest(identifier: "nbc.overspeed", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

private final class OverspeedNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

final class RideTracker: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = RideTracker()

    @Published private(set) var riding = false
    @Published private(set) var elapsedSec = 0
    @Published private(set) var distanceM = 0.0
    @Published private(set) var currentSpeedKmh = 0.0
    @Published private(set) var maxSpeedKmh = 0.0
    @Published private(set) var overspeed = false
    @Published private(set) var rides: [RideRecord] = []
    @Published private(set) var locationDenied = false

    private let manager = CLLocationManager()
    private var startTime: Date?
    private var lastPoint: CLLocation?
    private var wasOverspeed = false
    private var points: [RidePoint] = []
    private var tickTimer: DispatchSourceTimer?
    private var pendingStart = false

    // 老虎机速度（1.3.13）：没骑行记录时也要给老虎机供速度，否则镜像里
    // 数字不动。开着老虎机就跑定位、发 SpeedRelay；骑行开始后由骑行接管，
    // 骑行结束、老虎机还开着就继续跑（不停定位、不清中继）。
    private var slotTracking = false
    private let feedback = UINotificationFeedbackGenerator()

    private static let ridesURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("rides.json")
    private static let progressURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("current-ride.json")
    private static let resumeWindow: TimeInterval = 1800 // 30 分钟
    private static let maxPoints = 10000
    private static let maxHistory = 50

    /// 限速（km/h）：MainView 的 Stepper 写，默认 60；夹到 35...80 防御。
    private static var speedLimit: Int {
        let value = UserDefaults.standard.object(forKey: "nbc.speedLimit") == nil
            ? 60 : UserDefaults.standard.integer(forKey: "nbc.speedLimit")
        return min(max(value, 35), 80)
    }

    /// 超速提醒开关：MainView 的 Toggle 写，默认开。
    private static var speedAlertOn: Bool {
        UserDefaults.standard.object(forKey: "nbc.speedAlert") == nil
            ? true : UserDefaults.standard.bool(forKey: "nbc.speedAlert")
    }

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 10
        manager.activityType = .automotiveNavigation
        manager.allowsBackgroundLocationUpdates = true
        manager.pausesLocationUpdatesAutomatically = false
        loadRides()
        resumeIfNeeded()
    }

    // MARK: - 开始 / 结束

    func start() {
        guard !riding else { return }
        guard CLLocationManager.locationServicesEnabled() else {
            locationDenied = true
            Diag.log("骑行记录：系统定位总开关关着，无法开始")
            return
        }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            break
        case .denied, .restricted:
            locationDenied = true
            Diag.log("骑行记录：定位未授权，无法开始")
            return
        case .notDetermined:
            // 定位权限沿用天气的 WhenInUse（HUDData 会在启动时申请），
            // 这里不新弹授权框；等授权结果回 didChangeAuthorization 再起。
            pendingStart = true
            Diag.log("骑行记录：定位还没授权，等授权结果")
            return
        @unknown default:
            return
        }
        beginRide()
    }

    func stop() {
        guard riding else { return }
        riding = false
        // 老虎机还开着：定位和速度中继继续跑（给老虎机供速度），只停骑行计时；
        // 超速旗也清掉，不然 HUD 红行会在骑行结束后还挂一会儿。
        if slotTracking {
            overspeed = false
        } else {
            manager.stopUpdatingLocation()
            SpeedRelay.clear()
            SpeedRelay.stopPosting()
        }
        tickTimer?.cancel(); tickTimer = nil
        if let start = startTime {
            let record = RideRecord(id: UUID(), startTime: start, endTime: Date(),
                                    distanceM: distanceM, maxSpeedKmh: maxSpeedKmh)
            rides.insert(record, at: 0)
            if rides.count > Self.maxHistory { rides.removeLast(rides.count - Self.maxHistory) }
            saveRides()
        }
        try? FileManager.default.removeItem(at: Self.progressURL)
        // 最后同步一次速度状态到 HUD 中继。
        postLiveState()
        startTime = nil
        Diag.log("骑行记录：结束，\(String(format: "%.2f", distanceM / 1000)) km")
    }

    /// 老虎机速度开关（1.3.13）：MainView 跟着“老虎机”设置调。
    /// 开：有定位权限就跑定位、每 2 秒重发速度；没授权就等授权回调。
    /// 关：没在骑行就停定位、清速度中继。
    func setSlotTracking(_ on: Bool) {
        guard on != slotTracking else { return }
        slotTracking = on
        if on {
            switch manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways:
                manager.startUpdatingLocation()
                SpeedRelay.startPosting()
            case .notDetermined:
                break // 等 didChangeAuthorization
            default:
                break
            }
        } else if !riding {
            manager.stopUpdatingLocation()
            SpeedRelay.stopPosting()
            SpeedRelay.clear()
        }
    }

    func deleteRide(id: UUID) {
        rides.removeAll { $0.id == id }
        saveRides()
    }

    private func beginRide() {
        startTime = Date()
        distanceM = 0
        lastPoint = nil
        points.removeAll()
        wasOverspeed = false
        overspeed = false
        currentSpeedKmh = 0
        maxSpeedKmh = 0
        elapsedSec = 0
        riding = true
        locationDenied = false
        startLocationUpdates()
        startTick()
        SpeedRelay.startPosting()
        postLiveState()
        Diag.log("骑行记录：开始")
    }

    private func startLocationUpdates() {
        manager.startUpdatingLocation()
    }

    // MARK: - 定位回调

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            locationDenied = false
            if pendingStart, !riding {
                pendingStart = false
                beginRide()
            } else if riding {
                startLocationUpdates()
            } else if slotTracking {
                manager.startUpdatingLocation()
                SpeedRelay.startPosting()
            }
        case .denied, .restricted:
            locationDenied = true
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Diag.log("骑行记录：定位失败 \(error.localizedDescription)")
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for loc in locations {
            // 丢掉缓存的老点（启动时系统可能先给一个旧位置）。
            guard abs(loc.timestamp.timeIntervalSinceNow) < 10 else { continue }
            guard loc.horizontalAccuracy >= 0, loc.horizontalAccuracy <= 65 else { continue }
            if riding {
                process(loc)
            } else if slotTracking {
                // 没骑行、老虎机开着：只给老虎机供速度，不记点、不算里程、不判超速。
                let kmh = loc.speed >= 0 ? loc.speed * 3.6 : 0
                currentSpeedKmh = kmh
                SpeedRelay.update(speedKmh: Int(kmh.rounded()), overspeed: false)
            }
        }
    }

    private func process(_ loc: CLLocation) {
        var speedKmh = currentSpeedKmh
        if let last = lastPoint {
            let dt = loc.timestamp.timeIntervalSince(last.timestamp)
            let d = loc.distance(from: last)
            // 传送门过滤：两点间隐含速度超过 200 km/h 当 GPS 跳变，整点丢掉。
            if dt > 0, d / dt > 55.6 { return }
            if d > 0 { distanceM += d }
            if loc.speed >= 0 {
                speedKmh = loc.speed * 3.6
            } else if dt > 0, d > 0 {
                speedKmh = d / dt * 3.6
            }
        } else if loc.speed >= 0 {
            speedKmh = loc.speed * 3.6
        }
        points.append(RidePoint(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude,
                                time: loc.timestamp.timeIntervalSince1970, speed: loc.speed))
        if points.count > Self.maxPoints { points.removeFirst(points.count - Self.maxPoints) }
        lastPoint = loc
        currentSpeedKmh = speedKmh
        if speedKmh > maxSpeedKmh { maxSpeedKmh = speedKmh }
        checkOverspeed(speedKmh: speedKmh)
        saveProgress()
        postLiveState()
    }

    // MARK: - 超速（Feature B）

    private func checkOverspeed(speedKmh: Double) {
        let limit = Self.speedLimit
        let alertOn = Self.speedAlertOn
        let over = speedKmh > Double(limit)
        if over, !wasOverspeed, alertOn {
            overspeed = true
            feedback.notificationOccurred(.warning)
            AudioServicesPlaySystemSound(1005)
            OverspeedNotifier.post()
            Diag.log("超速提醒：\(Int(speedKmh)) km/h，限速 \(limit)")
        } else if !over, wasOverspeed {
            overspeed = false
        }
        wasOverspeed = over
        // 提醒关了就不置超速旗：HUD 红行和卡片红字都跟着开关走。
        if !alertOn { overspeed = false }
    }

    // MARK: - 每秒心跳（时长 + 停下归零 + 中继）

    private func startTick() {
        tickTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 1, repeating: .seconds(1))
        t.setEventHandler { [weak self] in
            guard let self, self.riding else { return }
            if let start = self.startTime {
                self.elapsedSec = max(0, Int(Date().timeIntervalSince(start)))
            }
            // 停下超过 5 秒没新点：速度归零，超速状态也清掉
            //（distanceFilter 10 米时停下就没回调，速度会一直冻在旧值）。
            if let last = self.lastPoint, Date().timeIntervalSince(last.timestamp) > 5 {
                self.currentSpeedKmh = 0
                self.checkOverspeed(speedKmh: 0)
            }
            self.postLiveState()
        }
        t.resume()
        tickTimer = t
    }

    /// 速度中继：RideTracker 是唯一的数据源。
    private func postLiveState() {
        SpeedRelay.update(speedKmh: Int(currentSpeedKmh.rounded()), overspeed: overspeed)
    }

    // MARK: - 持久化

    private func loadRides() {
        guard let data = try? Data(contentsOf: Self.ridesURL),
              let decoded = try? JSONDecoder().decode([RideRecord].self, from: data) else { return }
        rides = decoded
    }

    private func saveRides() {
        guard let data = try? JSONEncoder().encode(rides) else { return }
        try? data.write(to: Self.ridesURL, options: .atomic)
    }

    private func saveProgress() {
        guard riding, let start = startTime, let last = lastPoint else { return }
        let p = RideProgress(startTime: start, distanceM: distanceM, maxSpeedKmh: maxSpeedKmh,
                             lastLat: last.coordinate.latitude, lastLon: last.coordinate.longitude,
                             lastTime: last.timestamp.timeIntervalSince1970)
        guard let data = try? JSONEncoder().encode(p) else { return }
        try? data.write(to: Self.progressURL, options: .atomic)
    }

    /// App 被杀后下次打开：最后一个点在 30 分钟内就续上这趟骑行。
    private func resumeIfNeeded() {
        guard let data = try? Data(contentsOf: Self.progressURL),
              let p = try? JSONDecoder().decode(RideProgress.self, from: data) else { return }
        let lastDate = Date(timeIntervalSince1970: p.lastTime)
        guard Date().timeIntervalSince(lastDate) < Self.resumeWindow else {
            try? FileManager.default.removeItem(at: Self.progressURL)
            return
        }
        guard manager.authorizationStatus == .authorizedWhenInUse
                || manager.authorizationStatus == .authorizedAlways else { return }
        startTime = p.startTime
        distanceM = p.distanceM
        maxSpeedKmh = p.maxSpeedKmh
        elapsedSec = max(0, Int(Date().timeIntervalSince(p.startTime)))
        lastPoint = CLLocation(coordinate: CLLocationCoordinate2D(latitude: p.lastLat, longitude: p.lastLon),
                               altitude: 0, horizontalAccuracy: 10, verticalAccuracy: 10,
                               timestamp: lastDate)
        riding = true
        startLocationUpdates()
        startTick()
        SpeedRelay.startPosting()
        postLiveState()
        Diag.log("骑行记录：恢复进行中的骑行，已骑 \(String(format: "%.2f", distanceM / 1000)) km")
    }
}
