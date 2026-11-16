import Foundation

/// 仪表投屏预设（依据 ninebot_pro README 与抓包结论）
enum CodecKind: String {
    case h264rtp   // 五寸：H.264 连续编码，标准 RTP 直发
    case h264kcp   // 七寸：H.264，RTP 外再包一层 KCP（带重传确认）
    case jpeg      // 4.3寸：逐帧 JPEG 切片（骨架阶段未实现）
}

struct DashboardPreset: Identifiable, Equatable {
    let id: String
    let title: String
    let width: Int
    let height: Int
    let fps: Int32
    let bitrate: UInt32
    let codec: CodecKind
    let rtpPayloadType: UInt8
    let kcpConv: UInt32

    /// 五寸（KZ110 验证过）：848x480 H.264/RTP 20FPS 2000kbps
    static let fiveInch = DashboardPreset(
        id: "5inch", title: "五寸 848x480 20FPS 2Mbps",
        width: 848, height: 480, fps: 20, bitrate: 2_000_000,
        codec: .h264rtp, rtpPayloadType: 32, kcpConv: 0)

    /// 五寸 M5P：848x480，但按官方 HUD 参数（25fps / 500kbps / gop 10）
    /// 依据 NinebotEnhance README：M5P（车型 14103）仪表 848×480 Wi-Fi Direct H.264 实测通过
    static let fiveInchHud = DashboardPreset(
        id: "5inch-hud", title: "五寸 848x480 25FPS 800k（官方 HUD）",
        width: 848, height: 480, fps: 25, bitrate: 800_000,
        codec: .h264rtp, rtpPayloadType: 32, kcpConv: 0)

    /// 七寸（待实测）：1024x600 H.264/KCP 25FPS 2000kbps
    static let sevenInch = DashboardPreset(
        id: "7inch", title: "七寸 1024x600 25FPS KCP",
        width: 1024, height: 600, fps: 25, bitrate: 2_000_000,
        codec: .h264kcp, rtpPayloadType: 32, kcpConv: 1)

    /// 4.3寸（测试）：480x272 JPEG/RTP 10FPS —— 骨架阶段未实现
    static let smallInch = DashboardPreset(
        id: "4.3inch", title: "4.3寸 480x272 JPEG（未实现）",
        width: 480, height: 272, fps: 10, bitrate: 0,
        codec: .jpeg, rtpPayloadType: 32, kcpConv: 0)

    static let all = [fiveInch, fiveInchHud, sevenInch, smallInch]

    var isImplemented: Bool { codec != .jpeg }
}
