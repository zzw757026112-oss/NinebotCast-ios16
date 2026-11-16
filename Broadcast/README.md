# 屏幕镜像（录屏广播扩展）

iOS 官方录屏机制（ReplayKit Broadcast Upload Extension），无需越狱：
用户在控制中心长按「屏幕录制」→ 选 NinebotCast → 开始直播，系统把
整块屏幕的帧送到 `SampleHandler`，扩展缩放、编码、发给仪表。

## 文件

- `SampleHandler.swift` — RPBroadcastSampleHandler 入口，只收视频帧。
- `ScreenCaster.swift` — 引擎：RTCP ping 发现仪表、BSD socket、1 秒心跳、
  1ms 限流发送、20fps 节流、背压丢帧。
- `ScreenEncoder.swift` — VideoToolbox H.264（主 App H264Encoder 的精简版）。
- `ScreenScaler.swift` — vImage fit 缩放到 848x480（黑边填充），3 个目标
  buffer 轮换；非 BGRA 源走 CoreImage 兜底。
- `ScreenRTP.swift` — RTP 打包 + RTCP 心跳，与主 App 的 RTPPacker / RTCP
  逐字节相同（独立拷贝；改协议时两边要同步）。

## 设计要点

- **扩展自发现仪表**：没有 App Groups，主 App 填的 IP 扩展读不到，
  所以扩展用 RTCP ping（网关 + 子网广播 + 全网广播）自己找仪表，
  没找到就每 2 秒重试。仪表必须已进投屏接收态才会回包。
- **只支持五寸 H.264/RTP**：七寸 KCP 暂不支持。
- **内存预算约 50MB**：源帧不保留、目标 buffer 轮换 3 个、在飞帧 ≤ 2。
- **只传画面**：仪表协议没有音频，.audioApp / .audioMic 直接丢弃。
- **局域网权限**：扩展的 socket 属于主 App 的沙盒；先用普通投屏
  （测试图）成功投一次，让系统弹过局域网权限，再用镜像。

## 排查

扩展日志走 os_log（subsystem `com.corpsezhao.ninebotcast`，category
`broadcast`），Mac 上用 Console 看；iPhone 上看不到，只能看仪表
画面。仪表黑屏时按顺序查：仪表接收态 → 强退九号出行（占 5012/5013）
→ 局域网权限 → 重新开始直播。
