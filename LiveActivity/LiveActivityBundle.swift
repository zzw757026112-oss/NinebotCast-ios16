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
                    leadingView(speedKmh: context.state.speedKmh)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    trailingView(distanceKm: context.state.distanceKm, durationSec: context.state.durationSec)
                }
                DynamicIslandExpandedRegion(.center) {
                    centerStatusView(overspeed: context.state.overspeed, casting: context.state.casting)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    bottomView(voltage: context.state.bmsVoltage, soc: context.state.bmsSoc)
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

/// 灵动岛展开区中间的状态行（超速/投屏中）。
/// 单独抽成 @ViewBuilder：条件分支放在普通 ViewBuilder 里，
/// 别直接写在 DynamicIsland 的展开区闭包里——1.3.0 构建时
/// DynamicIslandExpandedContentBuilder 在那处报
/// "does not implement any 'buildBlock' ... with sufficient availability"，
/// 展开区闭包里只留一个调用，类型就确定了。
@ViewBuilder
private func centerStatusView(overspeed: Bool, casting: Bool) -> some View {
    if overspeed {
        Text("超速！").font(.headline).foregroundColor(.red)
    } else if casting {
        Text("投屏中").font(.subheadline).foregroundColor(.secondary)
    }
}

/// 展开区左：速度。1.3.2 构建时 DynamicIsland 又报
/// "generic parameter 'Expanded' could not be inferred"（跟 1.3.0
/// 首次构建同一处），1.3.0 的修复只抽了中间区，剩下的三区
/// 仍是内联写法；这次四区全部抽成 @ViewBuilder 函数，
/// DynamicIsland 闭包里只留四个区域调用，不再做类型推断。
@ViewBuilder
private func leadingView(speedKmh: Double) -> some View {
    VStack(alignment: .leading) {
        Text("\(Int(speedKmh))")
            .font(.system(size: 28, weight: .bold, design: .rounded))
            .monospacedDigit()
        Text("km/h").font(.caption2).foregroundColor(.secondary)
    }
}

/// 展开区右：距离/时长。
@ViewBuilder
private func trailingView(distanceKm: Double, durationSec: Int) -> some View {
    VStack(alignment: .trailing) {
        Text(String(format: "%.1f km", distanceKm))
            .font(.headline)
            .monospacedDigit()
        Text(formatRideDuration(durationSec))
            .font(.caption2).foregroundColor(.secondary)
    }
}

/// 展开区下：BMS 电压/电量 + 名称（条件分支放这里，别放闭包里）。
/// 注意：bmsVoltage/bmsSoc 在 RideActivity 里是 Float?，别写成 Double?。
@ViewBuilder
private func bottomView(voltage: Float?, soc: Float?) -> some View {
    HStack(spacing: 12) {
        if let v = voltage {
            Label(String(format: "%.1fV", v), systemImage: "bolt.fill")
        }
        if let s = soc {
            Label(String(format: "%.0f%%", s), systemImage: "battery.25")
        }
        Spacer()
        Text("Ninebot Pro+").font(.caption2).foregroundColor(.secondary)
    }
    .font(.caption)
}

/// 秒 → "12:34" / "1:23:45"（锁屏和灵动岛共用）。
private func formatRideDuration(_ sec: Int) -> String {
    let h = sec / 3600, m = (sec % 3600) / 60, s = sec % 60
    if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
    return String(format: "%d:%02d", m, s)
}
