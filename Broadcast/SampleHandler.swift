import CoreMedia
import ReplayKit
import os.log

/// 录屏广播扩展：系统录屏（控制中心 → 屏幕录制 → 选 Ninebot Pro+）启动后，
/// iOS 把整块屏幕的帧送到这里，扩展缩放、编码、发给仪表。
///
/// 只处理视频帧（.video），音频直接丢弃（仪表协议不传音频）。
/// 扩展与主 App 之间没有 App Groups：仪表由扩展自己用 RTCP ping 发现，
/// 所以开始镜像前，仪表必须已进投屏接收态。
final class SampleHandler: RPBroadcastSampleHandler {
    private let log = Logger(subsystem: "com.corpsezhao.ninebotcast", category: "broadcast")
    private let caster = ScreenCaster()

    override init() {
        super.init()
        // 方向接力：App 发 Darwin 通知告诉扩展现在手机是横是竖
        //（扩展自己在 iOS 16 下测不到），越早订阅越好。
        OrientationRelay.startObserving()
        // HUD 设置接力：App 发 Darwin 通知告诉扩展用户选的显示项、
        // 位置、字号（扩展自己读不到 App 的设置），越早订阅越好。
        HUDSettingsRelay.startObserving()
        // 车辆数据接力：App 发 Darwin 通知告诉扩展车速/电压/电流/
        // 功率（扩展自己连不上蓝牙），越早订阅越好。
        VehicleDataRelay.startObserving()
        // 音乐 + 音量接力：App 发 Darwin 通知告诉扩展正在放的歌和
        // 手机音量（扩展自己读不到），越早订阅越好。
        HUDDataRelay.startObserving()
    }

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        log.info("mirror broadcast started")
        caster.start()
    }

    override func broadcastPaused() {
        caster.setPaused(true)
    }

    override func broadcastResumed() {
        caster.setPaused(false)
    }

    override func broadcastFinished() {
        log.info("mirror broadcast finished")
        caster.stop()
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer,
                                      with sampleBufferType: RPSampleBufferType) {
        switch sampleBufferType {
        case .video:
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            caster.submitFrame(pixelBuffer)
        case .audioApp, .audioMic:
            break // 仪表只收画面，音频丢弃
        @unknown default:
            break
        }
    }
}
