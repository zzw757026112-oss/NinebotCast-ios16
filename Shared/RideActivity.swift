import ActivityKit
import Foundation
import os.log

/// 骑行动态岛（Live Activity，锁屏 + 灵动岛）：1.2.9 新增。
///
/// 属性和内容状态放在 Shared 里：主 App 和 LiveActivityWidget 扩展
/// 都编这份文件。App 端的管理函数（request/update/end）也在这个文件，
/// 但只拿纯数值当参数——不直接碰 RideTracker/ANTBMS/Diag，
/// 这样扩展编译时不缺符号（扩展里没有那些 Sources 文件）。
/// Diag 也不能用（Sources 文件）：日志用 os_log。
///
/// 部署目标：主 App 还是 iOS 16.0。ActivityContent 形式的
/// request/update/end（带 staleDate / dismissalPolicy）要 iOS 16.2，
/// 所以属性和管理都标 @available(iOS 16.2, *)，调用方用
/// if #available(iOS 16.2, *) 包住；iOS 16.1 及以下机器上这些调用
/// 直接跳过，什么都不做。扩展自己的部署目标是 16.2（project.yml）。
@available(iOS 16.2, *)
struct RideActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var speedKmh: Double
        var distanceKm: Double
        var durationSec: Int
        var overspeed: Bool
        var casting: Bool
        var bmsVoltage: Float?
        var bmsSoc: Float?
    }
}

@available(iOS 16.2, *)
enum RideActivity {
    private static let log = Logger(subsystem: "com.corpsezhao.ninebotcast", category: "liveactivity")
    private static var casting = false
    private static var lastRiding = false
    private static var lastState: RideActivityAttributes.ContentState?
    private static var lastUpdate = Date.distantPast

    /// 投屏开始/结束时调（CastEngine.start/stop）：投屏本身也值得
    /// 一个动态岛（速度 0、距离 0，只显示投屏中）。
    static func setCasting(_ value: Bool) {
        casting = value
        apply()
    }

    /// 骑行状态变化时调（RideTracker）：开始/每秒心跳/结束。
    /// 纯数值参数；BMS 由调用方从 ANTBMS.shared.snapshot 里取。
    static func sync(riding: Bool, speedKmh: Double, distanceKm: Double, durationSec: Int,
                     overspeed: Bool, bmsVoltage: Float?, bmsSoc: Float?) {
        lastRiding = riding
        lastState = RideActivityAttributes.ContentState(
            speedKmh: speedKmh, distanceKm: distanceKm, durationSec: durationSec,
            overspeed: overspeed, casting: casting, bmsVoltage: bmsVoltage, bmsSoc: bmsSoc)
        apply()
    }

    /// 骑行结束且投屏也停了 → 结束动态岛；还在跑 → 请求或更新
    ///（更新最多 1 秒一次；请求和结束不节流，立刻办）。
    private static func apply() {
        let live = lastRiding || casting
        let activities = Activity<RideActivityAttributes>.activities
        if live {
            guard let state = lastState else { return }
            if let activity = activities.first {
                guard Date().timeIntervalSince(lastUpdate) >= 1.0 else { return }
                lastUpdate = Date()
                let content = ActivityContent(state: state, staleDate: nil)
                Task { await activity.update(content) }
            } else {
                // 请求是 async：包进 Task；先把 lastUpdate 记下，
                // 避免请求还没回来时又重复请求。
                lastUpdate = Date()
                let content = ActivityContent(state: state, staleDate: nil)
                Task {
                    do {
                        _ = try await Activity.request(attributes: RideActivityAttributes(), content: content)
                    } catch {
                        log.error("动态岛请求失败：\(error.localizedDescription, privacy: .public)")
                    }
                }
            }
        } else {
            guard !activities.isEmpty else { return }
            let state = lastState ?? RideActivityAttributes.ContentState(
                speedKmh: 0, distanceKm: 0, durationSec: 0,
                overspeed: false, casting: false, bmsVoltage: nil, bmsSoc: nil)
            let content = ActivityContent(state: state, staleDate: nil)
            for activity in activities {
                Task { await activity.end(content, dismissalPolicy: .immediate) }
            }
        }
    }
}
