import SwiftUI

@main
struct NinebotProPlusApp: App {
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
    }
    var body: some Scene {
        WindowGroup {
            MainView()
        }
    }
}
