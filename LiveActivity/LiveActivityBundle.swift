import ActivityKit
import SwiftUI
import WidgetKit

/// 动态岛扩展：锁屏 + 灵动岛。1.2.9 新增。
///
/// 只编进 LiveActivityWidget 扩展（部署目标 iOS 16.2），
/// 属性定义在 Shared/RideActivity.swift。
/// 锁屏：大速度 + 距离/时长 + BMS + 超速/投屏状态。
/// 灵动岛：紧凑左 = 速度，紧凑右 = 距离，最小 = 速度，
/// 展开 = 速度/距离/时长/BMS/投屏状态。
@main
struct LiveActivityBundle: WidgetBundle {
    var body: some Widget {
        LiveActivityWidget()
    }
}

struct LiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RideActivityAttributes.self) { context in
            // 锁屏
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(Int(context.state.speedKmh))")
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("km/h")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Spacer()
                    if context.state.overspeed {
                        Text("超速！")
                            .font(.headline)
                            .foregroundColor(.red)
                    } else if context.state.casting {
                        Text("投屏中")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                HStack(spacing: 16) {
                    Label("\(String(format: "%.1f", context.state.distanceKm)) km", systemImage: "map")
                    Label(formatRideDuration(context.state.durationSec), systemImage: "clock")
                    if let v = context.state.bmsVoltage {
                        Label(String(format: "%.1fV", v), systemImage: "bolt.fill")
                    }
                    if let soc = context.state.bmsSoc {
                        Label(String(format: "%.0f%%", soc), systemImage: "battery.25")
                    }
                }
                .font(.subheadline)
                .foregroundColor(.secondary)
            }
            .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading) {
                        Text("\(Int(context.state.speedKmh))")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        Text("km/h").font(.caption2).foregroundColor(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing) {
                        Text(String(format: "%.1f km", context.state.distanceKm))
                            .font(.headline)
                            .monospacedDigit()
                        Text(formatRideDuration(context.state.durationSec))
                            .font(.caption2).foregroundColor(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    if context.state.overspeed {
                        Text("超速！").font(.headline).foregroundColor(.red)
                    } else if context.state.casting {
                        Text("投屏中").font(.subheadline).foregroundColor(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 12) {
                        if let v = context.state.bmsVoltage {
                            Label(String(format: "%.1fV", v), systemImage: "bolt.fill")
                        }
                        if let soc = context.state.bmsSoc {
                            Label(String(format: "%.0f%%", soc), systemImage: "battery.25")
                        }
                        Spacer()
                        Text("Ninebot Pro+").font(.caption2).foregroundColor(.secondary)
                    }
                    .font(.caption)
                }
            } compactLeading: {
                Text("\(Int(context.state.speedKmh))")
                    .font(.headline)
                    .monospacedDigit()
            } compactTrailing: {
                Text(String(format: "%.1fkm", context.state.distanceKm))
                    .font(.caption)
                    .monospacedDigit()
            } minimal: {
                Text("\(Int(context.state.speedKmh))")
                    .font(.headline)
                    .monospacedDigit()
            }
        }
    }
}

/// 秒 → "12:34" / "1:23:45"（锁屏和灵动岛共用）。
private func formatRideDuration(_ sec: Int) -> String {
    let h = sec / 3600, m = (sec % 3600) / 60, s = sec % 60
    if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
    return String(format: "%d:%02d", m, s)
}
