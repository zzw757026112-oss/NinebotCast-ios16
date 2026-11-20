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
        // 音量接力：同上，把主 App 读到的手机音量发给录屏扩展
        //（扩展进程里 outputVolume 是陈旧值，镜像时音量卡住不动）。
        // 值变了立刻发，另外每 2 秒重发。1.1.9：音乐已删。
        HUDDataRelay.startPosting()
        // ANT BMS 接力：同上，每 2 秒把最新电池数据重发给录屏扩展
        //（扩展进程自己连不上 BLE）。1.2.0 新增。
        ANTBMSRelay.startPosting()
        // 常驻后台保活（1.2.8）：启动就开静音音频，退后台进程也不挂起，
        // BMS 轮询和接力继续走；默认开，可在运行状态卡片里关。
        // 只在投屏时才禁自动锁屏，平时不禁。
        if UserDefaults.standard.object(forKey: "nbc.keepAlive") == nil {
            UserDefaults.standard.set(true, forKey: "nbc.keepAlive")
        }
        if UserDefaults.standard.bool(forKey: "nbc.keepAlive") {
            BackgroundKeeper.shared.startAlwaysOn()
        }
        // 蓝牙恢复：如果 BMS 开关开着，建一份 ANTBMS 让系统在后台
        // 把被杀的 App 拉起来时能恢复 BLE 会话（willRestoreState）。
        if UserDefaults.standard.bool(forKey: "nbc.antbms.enabled") {
            _ = ANTBMS.shared
        }
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
