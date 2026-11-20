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
        // 音量接力：App 发 Darwin 通知告诉扩展手机音量
        //（扩展自己读不到），越早订阅越好。1.1.9：音乐已删。
        HUDDataRelay.startObserving()
        // ANT BMS 接力：订阅电池数据的 5 组名字，越早订阅越好。1.2.0 新增。
        ANTBMSRelay.startObserving()
    }

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        // 1.1.6：扩展不再验授权码。授权只在主 App 里验一次
        //（没激活连主界面都进不去）；扩展是独立进程，钥匙串
        // 跟 App 不通，靠 Darwin 中继传码一直传不过去（1.1.4、
        // 1.1.5 连跪两次），索性不验了——开播就直接推流。
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
