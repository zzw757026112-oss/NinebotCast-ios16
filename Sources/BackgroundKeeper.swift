import AVFoundation
import UIKit

/// 投屏期间的后台保活。
///
/// 用户实测：App 一退后台，投屏就断——因为 iOS 会在几秒内挂起后台进程，
/// 定时器全停，帧和心跳都没了。Info.plist 里早就声明了 UIBackgroundModes=audio，
/// 但声明不生效，必须真的跑一个音频会话。
///
/// 做法：AVAudioSession 设为 .playback，启动一个输出静音的 AVAudioEngine。
/// 引擎在跑，进程就不会被挂起，投屏定时器在后台继续走。
/// 同时投屏期间禁掉自动锁屏（锁屏等于退后台）。
/// 1.2.8：常驻保活——startAlwaysOn 在 App 启动时按开关开启，
/// 平时不禁锁屏，只保进程；投屏时才禁锁屏。
///
/// 1.3.8 加固（镜像投屏不怕切后台——ReplayKit 扩展是独立进程；
/// 断的是跑在主 App 进程里的图片/视频/摄像头/测试图投屏）：原来有三个洞——
/// 1）startEngine 的 guard 只看自家 running flag，引擎真停了也不重启；
/// 2）没有看门狗，引擎无声无息停掉就没人拉起来；
/// 3）切后台瞬间没有后台任务兜底，进程几秒内挂起，看门狗连跑的机会都没有。
/// 修法：flag 以 engine.isRunning 为准；每 2 秒的看门狗；退后台开 25 秒
/// 后台任务桥；中断分 began/ended，ended 失败 1/2/4 秒重试 3 次；
/// 再加音频路由变化监听。
final class BackgroundKeeper {
    static let shared = BackgroundKeeper()

    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    /// 自家 flag：只表示“我们想要引擎在跑”，真凭实据看 engine.isRunning
    private var running = false
    private var observers: [NSObjectProtocol] = []
    /// 投屏中（CastEngine 控制）：同时禁自动锁屏。
    private var casting = false
    /// 常驻保活（App 启动时按开关开启）：只保音频会话，不禁锁屏。
    private var alwaysOn = false

    /// 看门狗：每 2 秒查一次引擎，没在跑就重启。只在该保活时跑。
    private var watchdogTimer: DispatchSourceTimer?
    private let watchdogQueue = DispatchQueue(label: "ninebotcast.keepalive.watchdog")
    /// 退后台时开的后台任务 id：给看门狗争取拉起引擎的时间。
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    /// 后台任务 25 秒到期就主动结束（音频保活接上后不需要它）。
    private var backgroundTaskEndTimer: DispatchSourceTimer?
    /// 中断恢复的重试 work item：停引擎时取消，免得停了还重试。
    private var retryWorkItem: DispatchWorkItem?

    /// 是否已在保活（给界面提示用）
    var isActive: Bool { running }

    /// 投屏开始：禁自动锁屏 + 确保静音引擎在跑。
    func start() {
        casting = true
        UIApplication.shared.isIdleTimerDisabled = true
        ensureEngine()
    }

    /// 投屏结束：恢复自动锁屏；常驻保活没开才停引擎。
    func stop() {
        casting = false
        UIApplication.shared.isIdleTimerDisabled = false
        ensureEngine()
    }

    /// 常驻保活开（1.2.8）：App 启动就跑静音引擎，退后台也不停；
    /// 不禁锁屏，只保进程。开关在运行状态卡片，默认开。
    func startAlwaysOn() {
        alwaysOn = true
        ensureEngine()
    }

    /// 常驻保活关：不在投屏就停引擎。
    func stopAlwaysOn() {
        alwaysOn = false
        ensureEngine()
    }

    private var shouldKeepAlive: Bool { casting || alwaysOn }

    private func ensureEngine() {
        if shouldKeepAlive {
            startEngine()
            startWatchdog()
        } else {
            stopWatchdog()
            stopEngine()
        }
    }

    private func startEngine() {
        // 1.3.8 修 flag 脱节：以 engine.isRunning 为准，不再只信自家 flag。
        // 引擎已在跑就只把 flag 同步回来；没在跑就（重新）拉起来。
        // 反复调是安全的：节点还在就复用，AVAudioEngine 支持停了再起。
        if engine.isRunning {
            running = true
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            // 节点还在（只是引擎停了）就直接复用，不用重复 attach；
            // 只有节点被 stopEngine 摘掉后才新建一个挂上去。
            if sourceNode == nil {
                let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)
                guard let format else {
                    Diag.log("后台保活：音频格式创建失败，退后台会断流")
                    return
                }
                let src = AVAudioSourceNode(format: format) { _, _, _, audioBufferList -> OSStatus in
                    // 输出全零 = 静音；目的只是让音频会话保持活跃
                    let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
                    for buffer in buffers {
                        if let data = buffer.mData {
                            memset(data, 0, Int(buffer.mDataByteSize))
                        }
                    }
                    return noErr
                }
                engine.attach(src)
                engine.connect(src, to: engine.mainMixerNode, format: format)
                sourceNode = src
            }
            try engine.start()
            running = true
            installObservers()
            Diag.log("后台保活启动（静音音频\(casting ? " + 禁止锁屏" : "，常驻")）")
        } catch {
            // 保活失败不致命：只是退后台会断流，前台照常；
            // 看门狗每 2 秒会再试一次。
            Diag.log("后台保活启动失败 \(error.localizedDescription)")
        }
    }

    private func stopEngine() {
        removeObservers()
        retryWorkItem?.cancel()
        retryWorkItem = nil
        endBackgroundTask()
        guard running || engine.isRunning else { return }
        running = false
        engine.stop()
        if let sourceNode {
            engine.detach(sourceNode)
        }
        sourceNode = nil
        try? AVAudioSession.sharedInstance().setActive(
            false, options: .notifyOthersOnDeactivation)
        Diag.log("后台保活停止")
    }

    // MARK: - 看门狗

    /// 引擎该跑时开看门狗；引擎停掉且 casting 与 alwaysOn 都为 false 时停。
    private func startWatchdog() {
        guard watchdogTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: watchdogQueue)
        timer.schedule(deadline: .now() + 2, repeating: .seconds(2))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard self.shouldKeepAlive else { return }
            guard !self.engine.isRunning else { return }
            Diag.log("后台保活看门狗：静音引擎停了，正在重启")
            DispatchQueue.main.async { [weak self] in
                self?.startEngine()
            }
        }
        timer.resume()
        watchdogTimer = timer
    }

    private func stopWatchdog() {
        watchdogTimer?.cancel()
        watchdogTimer = nil
    }

    // MARK: - 后台任务桥

    /// 退后台时开一个后台任务：切后台瞬间给进程一段保证运行时间，
    /// 让看门狗有机会把死掉的引擎拉起来；引擎跑起来后音频模式
    /// 会继续保活，后台任务就可以结束。
    private func beginBackgroundTaskIfNeeded(reason: String) {
        guard backgroundTask == .invalid else { return }
        let taskId = UIApplication.shared.beginBackgroundTask(withName: "ninebotcast.keepalive") { [weak self] in
            // 系统要收回时间了：必须在这里 end 掉，否则会被杀。
            // 过期回调跑在主线程，直接 end。
            Diag.log("后台保活：后台任务过期，结束")
            self?.endBackgroundTask()
        }
        guard taskId != .invalid else {
            Diag.log("后台保活：申请后台任务失败（invalid）")
            return
        }
        backgroundTask = taskId
        Diag.log("后台保活：\(reason)，已开后台任务兜底（25 秒）")
        // 25 秒后主动结束：引擎跑起来后音频模式会继续保活，不用一直占着
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(deadline: .now() + 25)
        timer.setEventHandler { [weak self] in
            self?.endBackgroundTask()
        }
        timer.resume()
        backgroundTaskEndTimer = timer
    }

    private func endBackgroundTask() {
        backgroundTaskEndTimer?.cancel()
        backgroundTaskEndTimer = nil
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
        Diag.log("后台保活：后台任务已结束")
    }

    private func handleDidEnterBackground() {
        guard shouldKeepAlive else { return }
        let engineState = engine.isRunning ? "运行中" : "已停"
        beginBackgroundTaskIfNeeded(reason: "退后台")
        if !engine.isRunning {
            startEngine()
        }
        Diag.log("后台保活：已退后台，静音引擎\(engineState)，已开后台任务兜底")
    }

    // MARK: - 通知

    /// 来电等音频中断结束后自动把静音引擎拉起来，否则进程还是会被挂起
    private func installObservers() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        let interruption = center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            self?.handleInterruption(notification)
        }
        let reset = center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.resumeIfNeeded(reason: "媒体服务重置")
        }
        let routeChange = center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            guard self.shouldKeepAlive else { return }
            guard !self.engine.isRunning else { return }
            Diag.log("后台保活：音频路由变化，静音引擎停了，正在重启")
            self.startEngine()
        }
        let didEnterBackground = center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.handleDidEnterBackground()
        }
        let willEnterForeground = center.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.endBackgroundTask()
        }
        observers = [interruption, reset, routeChange, didEnterBackground, willEnterForeground]
    }

    private func removeObservers() {
        let center = NotificationCenter.default
        for observer in observers {
            center.removeObserver(observer)
        }
        observers = []
    }

    /// 音频中断：began 时什么都不做（这时重启必失败），ended 时恢复，
    /// 失败则 1/2/4 秒重试，最多 3 次。
    private func handleInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let raw = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else {
            // 读不到类型：按旧逻辑，引擎没在跑就恢复一次
            resumeIfNeeded(reason: "音频中断")
            return
        }
        switch type {
        case .began:
            Diag.log("后台保活：音频中断开始，等待结束")
        case .ended:
            resumeWithRetry(reason: "音频中断结束", attempt: 1)
        @unknown default:
            resumeIfNeeded(reason: "音频中断")
        }
    }

    private func resumeIfNeeded(reason: String) {
        guard shouldKeepAlive else { return }
        guard !engine.isRunning else {
            running = true
            return
        }
        resumeWithRetry(reason: reason, attempt: 1)
    }

    /// 中断/重置后恢复引擎：失败按 1、2、4 秒重试，最多 3 次。
    private func resumeWithRetry(reason: String, attempt: Int) {
        guard shouldKeepAlive else { return }
        guard !engine.isRunning else {
            running = true
            return
        }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            try engine.start()
            running = true
            Diag.log("后台保活：\(reason)，静音引擎已恢复")
        } catch {
            if attempt < 4 {
                let delay = 1 << (attempt - 1) // 1、2、4 秒
                Diag.log("后台保活：\(reason)恢复失败（第 \(attempt) 次），\(delay) 秒后重试")
                let item = DispatchWorkItem { [weak self] in
                    self?.resumeWithRetry(reason: reason, attempt: attempt + 1)
                }
                retryWorkItem = item
                DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(delay), execute: item)
            } else {
                Diag.log("后台保活：\(reason)恢复失败，已重试 3 次：\(error.localizedDescription)")
            }
        }
    }
}
