import SwiftUI
import UIKit

@main
struct NinebotProPlusApp: App {
    @StateObject private var licenseGate = LicenseGate()

    init() {
        // 第一件事就写启动日志 + 挂异常处理器：
        // 万一这一版还是闪，下次打开 App 能在「诊断」里看到上次停在哪一步。
        Diag.installCrashHandler(version: AppVersion.display)
        // 方向接力：App 测方向、发 Darwin 通知，录屏扩展收了才知道横竖
        //（扩展自己在 iOS 16 下测不到方向，横屏镜像会一直是竖条）。
        // 后台音频保活活着时也会继续发；发通知很轻，不会崩。
        OrientationRelay.startPosting()
        // HUD 设置接力：同上，把用户在 HUD 设置卡片里选的显示项、
        // 位置、字号发给录屏扩展（扩展自己读不到 App 的设置）。
        HUDSettingsRelay.startPosting()
        // 车辆数据接力：同上，把蓝牙读到的车速/电压/电流/功率发给
        // 录屏扩展画车辆胶囊。没连车时不发（扩展端没数据就不画）。
        VehicleDataRelay.startPosting()
        // 音乐 + 音量接力：同上，把主 App 读到的正在播放的歌和手机
        // 音量发给录屏扩展（扩展进程里 MPNowPlayingInfoCenter 读不
        // 到音乐、outputVolume 是陈旧值，镜像时音乐行不显示、音量
        // 卡住不动）。值变了立刻发，另外每 2 秒重发。
        HUDDataRelay.startPosting()
        // 授权码接力：App 把授权码发给录屏扩展（扩展自己读不到
        // App 的钥匙串，靠 Darwin 通知中继；每 2 秒重发一次）。
        LicenseRelay.startPosting()
        // 下面这行必须有：HUDData 是懒加载的，镜像时主 App 进程自己
        // 不画帧、永远不会创建它，tick() 也就不会跑，中继没数据可发。
        // 启动时就建一份，让它的每秒 tick 在后台保活里一直跑。
        // 副作用：定位授权提示会提前到第一次打开 App（原来是第一
        // 次投屏时才弹），天气本来就要定位，不影响使用。
        _ = HUDData.shared
    }
    var body: some Scene {
        WindowGroup {
            Group {
                if licenseGate.isActivated {
                    MainView(licenseGate: licenseGate)
                } else {
                    LicenseView(gate: licenseGate)
                }
            }
            .onAppear { licenseGate.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                licenseGate.refresh()
            }
        }
    }
}
