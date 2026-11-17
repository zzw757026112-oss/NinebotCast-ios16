import SwiftUI

@main
struct NinebotProPlusApp: App {
    init() {
        // 第一件事就写启动日志 + 挂异常处理器：
        // 万一这一版还是闪，下次打开 App 能在「诊断」里看到上次停在哪一步。
        Diag.installCrashHandler(version: AppVersion.display)
    }
    var body: some Scene {
        WindowGroup {
            MainView()
        }
    }
}
