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
        // 授权码接力：App 发 Darwin 通知把授权码告诉扩展（钥匙串
        // App 与扩展默认访问组不同，App 存的码扩展读不到；扩展收
        // 到就存进自己的钥匙串），越早订阅越好。
        LicenseRelay.startObserving()
    }

    /// 扩展结束标志：broadcastStarted 里等授权码时如果用户中途
    /// 停了直播，3 秒后的复查就不该再启动推流。
    private var broadcastEnded = false

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        broadcastEnded = false
        // 镜像也要授权。先查扩展自己的钥匙串（LicenseRelay 收到
        // App 发来的码就会存进来，之前成功镜像过就直接有码）。
        if LicenseManager.currentStatus().isValid {
            log.info("mirror broadcast started")
            caster.start()
            return
        }
        // 没码：可能是 App 刚激活、码还没通过中继发过来。App 每
        // 2 秒重发一次，等 3 秒再查一次；收到了就启动，3 秒后还
        // 没有才拒绝（这时 App 很大概率没在跑，或根本没激活）。
        log.info("mirror 未激活，等 3 秒再查（等 App 中继授权码）")
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self, !self.broadcastEnded else { return }
            if LicenseManager.currentStatus().isValid {
                self.log.info("mirror broadcast started (after license relay)")
                self.caster.start()
            } else {
                self.log.info("mirror 未激活，拒绝推流")
                let error = NSError(domain: "com.corpsezhao.ninebotcast.license", code: 1,
                                    userInfo: [NSLocalizedDescriptionKey: "Ninebot Pro+ 未激活，请先在 App 内输入授权码"])
                self.finishBroadcastWithError(error)
            }
        }
    }

    override func broadcastPaused() {
        caster.setPaused(true)
    }

    override func broadcastResumed() {
        caster.setPaused(false)
    }

    override func broadcastFinished() {
        broadcastEnded = true
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
