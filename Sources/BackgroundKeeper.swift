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
final class BackgroundKeeper {
    static let shared = BackgroundKeeper()

    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var running = false
    private var observers: [NSObjectProtocol] = []
    /// 投屏中（CastEngine 控制）：同时禁自动锁屏。
    private var casting = false
    /// 常驻保活（App 启动时按开关开启）：只保音频会话，不禁锁屏。
    private var alwaysOn = false

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

    private func ensureEngine() {
        if casting || alwaysOn {
            startEngine()
        } else {
            stopEngine()
        }
    }

    private func startEngine() {
        guard !running else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

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
            try engine.start()
            sourceNode = src
            running = true
            installObservers()
            Diag.log("后台保活启动（静音音频\(casting ? " + 禁止锁屏" : "，常驻")）")
        } catch {
            // 保活失败不致命：只是退后台会断流，前台照常
            Diag.log("后台保活启动失败 \(error.localizedDescription)")
        }
    }

    private func stopEngine() {
        removeObservers()
        guard running else { return }
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

    /// 来电等音频中断结束后自动把静音引擎拉起来，否则进程还是会被挂起
    private func installObservers() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        let interruption = center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.resumeIfNeeded(reason: "音频中断结束")
        }
        let reset = center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.resumeIfNeeded(reason: "媒体服务重置")
        }
        observers = [interruption, reset]
    }

    private func removeObservers() {
        let center = NotificationCenter.default
        for observer in observers {
            center.removeObserver(observer)
        }
        observers = []
    }

    private func resumeIfNeeded(reason: String) {
        guard running, !engine.isRunning else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            try engine.start()
            Diag.log("后台保活：\(reason)，静音引擎已恢复")
        } catch {
            Diag.log("后台保活：\(reason)恢复失败 \(error.localizedDescription)")
        }
    }
}
