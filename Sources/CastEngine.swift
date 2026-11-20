import Foundation
import CoreMedia
import UIKit
import AVFoundation

/// 投屏引擎：帧定时器 → 画面源 → VideoToolbox → RTP 打包 → UDP 5012
/// RTCP ping/pong 走 UDP 5013（每 1 秒一次，20 字节，逆向自官方 APK）
///
/// 线程模型（v0.17 起统一）：
/// - frameQueue：按帧率取帧 + 提交编码（背压：在飞帧过多就跳过本次）
/// - 画面源各自的线程：解码 / 渲染成品（图片是预渲染 buffer，零开销）
/// - videoQueue：RTP 打包 + **限流发送**（每毫秒最多 2 个包），避免运动画面
///   一瞬间几十个包砸过去把仪表网卡打丢
/// - callbackQueue：只跑 RTCP 心跳与回包解析
///
/// 为什么限流：静态图片每帧压缩后只有几百字节（1~2 包），怎么发都不卡；
/// 一动起来每帧十几 KB（十来个包），全速连发容易在仪表侧丢包，
/// 表现就是「图片不卡、视频/摄像头一帧一帧地播」。
final class CastEngine: ObservableObject {
    @Published var statusText: String = "待机"
    @Published var sentFrames: Int = 0
    @Published var sentPackets: Int = 0
    @Published var rtcpPongCount: Int = 0
    @Published var lastRTTMs: Int = -1
    @Published var dashboardReport: String = ""
    @Published var localIPText: String = "-"
    @Published var isRunning: Bool = false
    /// 实测每秒出帧数 / 平均帧大小，用来判断是编码跟不上还是链路丢了
    @Published var measuredFps: Int = 0
    @Published var avgFrameKB: Int = 0
    @Published var backlogPackets: Int = 0
    @Published var droppedFrames: Int = 0

    private var preset: DashboardPreset = .fiveInch
    private var activeFps: Int32 = 20
    private var videoChannel: UDPChannel?
    private var controlChannel: UDPChannel?
    private var encoder: H264Encoder?
    private var retiredEncoders: [H264Encoder] = []
    private var kcpChannel: KCPChannel?
    private var kcpTimer: DispatchSourceTimer?
    private var frameTimer: DispatchSourceTimer?
    private var pingTimer: DispatchSourceTimer?
    private var pacerTimer: DispatchSourceTimer?
    private var statTimer: DispatchSourceTimer?
    private var frameIndex: Int64 = 0
    private var encodedFrameIndex: Int64 = 0
    private var pingCounter: UInt32 = 0
    private var pingSentTimes: [UInt32: Int] = [:]
    private var duplicateKeyframes = false
    /// 画面源：测试图 / 相册图片 / 相册视频（循环）/ 摄像头
    private var photoImage: UIImage?
    private var photoRotation = 0
    private var photoBuffer: CVPixelBuffer?
    private var videoSource: VideoFrameSource?
    private var cameraSource: CameraSource?
    private var cameraRotation = 0
    private var cameraPosition: AVCaptureDevice.Position = .back

    private let frameQueue = DispatchQueue(label: "ninebotcast.frames")
    private let callbackQueue = DispatchQueue(label: "ninebotcast.rtcp")
    private let videoQueue = DispatchQueue(label: "ninebotcast.videosend")
    private let queueKey = DispatchSpecificKey<Int>()

    // 以下三项只由 videoQueue 访问
    private var packer: RTPPacker?
    private var pendingPackets: [Data] = []
    private var sendCursor = 0
    private var loggedFirstFrame = false

    // 背压 / 统计
    private let inflightLock = NSLock()
    private var inflightFrames = 0
    private var skippedByBackpressure = 0
    private var backlogDrops = 0
    private var bytesWindow = 0
    private var framesWindow = 0
    private var packetsWindow = 0
    private var lastSampleFrames = 0
    private var statTicks = 0

    init() {
        callbackQueue.setSpecific(key: queueKey, value: 1)
    }

    /// H.264 要求宽高按 16 对齐
    private static func align16(_ v: Int) -> Int {
        max(16, (v / 16) * 16)
    }

    // MARK: - 画面源

    /// 选一张相册图片当画面源；传 nil 回到测试图
    func setPhoto(_ image: UIImage?) {
        usePhoto(image, rotation: photoRotation)
    }

    private func rebuildPhotoBuffer() {
        guard let photoImage else {
            photoBuffer = nil
            return
        }
        photoBuffer = FrameRenderer.drawImage(
            photoImage, rotation: photoRotation,
            width: preset.width, height: preset.height)
    }

    private func teardownSources() {
        videoSource?.stop()
        videoSource = nil
        cameraSource?.stop()
        cameraSource = nil
        photoBuffer = nil
        photoImage = nil
    }

    /// 回到内置测试图
    func useTestImage() {
        teardownSources()
        Diag.log("画面源：测试图")
    }

    /// 相册图片（静态，铺满 + 可旋转）
    func usePhoto(_ image: UIImage?, rotation: Int) {
        teardownSources()
        guard let image else {
            Diag.log("画面源：测试图")
            return
        }
        photoImage = image
        photoRotation = rotation
        rebuildPhotoBuffer()
        Diag.log("画面源：图片 rot=\(rotation) → \(preset.width)x\(preset.height)")
    }

    /// 相册视频（循环播放，铺满 + 可旋转），独立线程按原速解码
    func useVideo(url: URL, rotation: Int) {
        teardownSources()
        let source = VideoFrameSource(url: url, width: preset.width, height: preset.height,
                                      rotation: rotation, fps: Int(activeFps))
        source.start()
        videoSource = source
        Diag.log("画面源：视频 \(url.lastPathComponent) rot=\(rotation)")
    }

    /// 摄像头（铺满 + 可旋转）；渲染走独立线程，发送端零等待
    func useCamera(position: AVCaptureDevice.Position, rotation: Int) {
        teardownSources()
        cameraRotation = rotation
        cameraPosition = position
        startCamera()
    }

    private func startCamera() {
        let source = CameraSource()
        source.start(position: cameraPosition,
                     targetWidth: preset.width,
                     targetHeight: preset.height,
                     rotation: cameraRotation,
                     fps: Int(activeFps)) { [weak self] error in
            if let error {
                Diag.log("摄像头启动失败：\(error)")
                DispatchQueue.main.async {
                    self?.dashboardReport = "摄像头启动失败：\(error)"
                }
            }
        }
        cameraSource = source
    }

    // MARK: - 启动 / 停止

    /// - Parameter pingOnly: 只发 RTCP ping，不建编码器、不发视频。用于隔离闪退原因。
    /// - Parameter packetSize: RTP 分片大小（官方 1400 / APK 1380）
    /// - Parameter gop: 关键帧间隔（帧数）
    /// - Parameter fpsOverride / bitrateOverride: 界面上的手动覆盖，0 = 跟随预设
    func start(preset: DashboardPreset,
               host: String,
               duplicateKeyframes: Bool,
               packetSize: Int = 1400,
               gop: Int = 10,
               pingOnly: Bool = false,
               fpsOverride: Int = 0,
               bitrateOverride: UInt32 = 0,
               resolutionDivisor: Int = 1) {
        guard preset.isImplemented || pingOnly else {
            statusText = "该预设未实现（JPEG 模式待开发）"
            return
        }
        let target = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else {
            statusText = "仪表 IP 为空"
            return
        }

        // 应用手动覆盖（帧率/码率/分辨率）
        var effective = preset
        let div = max(1, resolutionDivisor)
        let outW = div == 1 ? preset.width : Self.align16(preset.width / div)
        let outH = div == 1 ? preset.height : Self.align16(preset.height / div)
        if fpsOverride > 0 || bitrateOverride > 0 || div > 1 {
            effective = DashboardPreset(
                id: preset.id, title: preset.title,
                width: outW, height: outH,
                fps: fpsOverride > 0 ? Int32(fpsOverride) : preset.fps,
                bitrate: bitrateOverride > 0 ? bitrateOverride : preset.bitrate,
                codec: preset.codec,
                rtpPayloadType: preset.rtpPayloadType,
                kcpConv: preset.kcpConv)
        }
        guard effective.fps > 0 else {
            statusText = "预设帧率非法"
            return
        }

        stop()

        self.preset = effective
        activeFps = effective.fps
        self.duplicateKeyframes = duplicateKeyframes
        frameIndex = 0
        encodedFrameIndex = 0
        pingCounter = 0
        pingSentTimes = [:]
        rebuildPhotoBuffer()   // 预设变了，图片要按新尺寸重画

        let localIP = LocalAddress.primaryIPv4()
        localIPText = localIP ?? "（没取到 Wi-Fi 地址）"
        if let localIP, localIP == target {
            statusText = "填的是本机地址，仪表 IP 不是这个"
            Diag.log("start 中止：host 与本机 IP 相同 \(target)")
            return
        }
        Diag.log("start preset=\(effective.id) \(effective.width)x\(effective.height) @\(effective.fps)fps \(effective.bitrate / 1000)kbps host=\(target) local=\(localIP ?? "nil") pingOnly=\(pingOnly)")

        let video = UDPChannel(host: target, remotePort: 5012, localIP: localIP, localPort: 5012)
        video.start()
        videoChannel = video

        let control = UDPChannel(host: target, remotePort: 5013, localIP: localIP, localPort: 5013)
        control.start()
        controlChannel = control

        // 七寸：视频 RTP 包先过 KCP 再走 UDP
        if effective.codec == .h264kcp && !pingOnly {
            let kcp = KCPChannel(conv: effective.kcpConv) { [weak video] data in
                video?.send(data)
            }
            kcpChannel = kcp
            let timer = DispatchSource.makeTimerSource(queue: videoQueue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(10))
            timer.setEventHandler { kcp.tick() }
            timer.resume()
            kcpTimer = timer
        }

        control.onReceive = { [weak self] data in
            self?.handleControlReceive(data)
        }
        video.onReceive = { [weak self] data in
            self?.handleControlReceive(data)
        }
        let fallbackNote: (String) -> Void = { [weak self] note in
            self?.dashboardReport = note
            Diag.log(note)
        }
        video.onFallback = fallbackNote
        control.onFallback = fallbackNote

        if !pingOnly {
            let encoder = H264Encoder()
            guard encoder.setup(
                width: effective.width, height: effective.height,
                fps: activeFps, bitrate: effective.bitrate, gop: gop) else {
                statusText = "H.264 编码器初始化失败（看诊断日志）"
                return
            }
            encoder.onAnnexBFrame = { [weak self] data, isKey in
                self?.handleEncodedFrame(data, keyframe: isKey)
            }
            self.encoder = encoder

            videoQueue.sync {
                packer = RTPPacker(chunkSize: packetSize)
                pendingPackets.removeAll()
                sendCursor = 0
                loggedFirstFrame = false
            }
            startPacer()
            startStats()
        }

        // RTCP ping：每 1 秒一次（官方节奏），计数器从 1 开始
        let ping = DispatchSource.makeTimerSource(queue: callbackQueue)
        ping.schedule(deadline: .now() + 0.3, repeating: .seconds(1))
        ping.setEventHandler { [weak self] in
            self?.sendPing()
        }
        ping.resume()
        pingTimer = ping

        // 摄像头已经开着时，帧率/尺寸变了要按新参数重来
        if cameraSource != nil {
            cameraSource?.stop()
            cameraSource = nil
            startCamera()
        }

        if !pingOnly {
            let timer = DispatchSource.makeTimerSource(queue: frameQueue)
            timer.schedule(deadline: .now(), repeating: 1.0 / Double(activeFps))
            timer.setEventHandler { [weak self] in self?.produceFrame() }
            timer.resume()
            frameTimer = timer
        }

        sentFrames = 0
        sentPackets = 0
        rtcpPongCount = 0
        lastRTTMs = -1
        measuredFps = 0
        avgFrameKB = 0
        backlogPackets = 0
        droppedFrames = 0
        dashboardReport = ""
        skippedByBackpressure = 0
        backlogDrops = 0
        bytesWindow = 0
        framesWindow = 0
        packetsWindow = 0
        lastSampleFrames = 0
        statTicks = 0
        statusText = pingOnly
            ? "仅 RTCP ping → \(target):5013（不编码、不发画面）"
            : "发送中 → \(target):5012\(localIP.map { "（本机 \($0)）" } ?? "")：\(effective.title)"
        isRunning = true
        BackgroundKeeper.shared.start()   // 退后台不断流（静音音频保活 + 禁止锁屏）
        if #available(iOS 16.2, *) { RideActivity.setCasting(true) } // 动态岛：投屏开始也值得一个动态岛（1.2.9）
        Diag.log("start 完成")
    }

    func stop() {
        frameTimer?.cancel(); frameTimer = nil
        pingTimer?.cancel(); pingTimer = nil
        kcpTimer?.cancel(); kcpTimer = nil
        pacerTimer?.cancel(); pacerTimer = nil
        statTimer?.cancel(); statTimer = nil
        videoQueue.sync {
            packer = nil
            pendingPackets.removeAll()
            sendCursor = 0
        }
        kcpChannel = nil
        isRunning = false

        if let encoder {
            // 先摘回调再失效，最后把实例留在数组里保活（refcon 不能悬垂）
            encoder.onAnnexBFrame = nil
            encoder.teardown()
            retiredEncoders.append(encoder)
            if retiredEncoders.count > 6 {
                retiredEncoders.removeFirst()
            }
        }
        self.encoder = nil
        inflightLock.lock()
        inflightFrames = 0
        inflightLock.unlock()

        videoChannel?.stop(); videoChannel = nil
        controlChannel?.stop(); controlChannel = nil
        BackgroundKeeper.shared.stop()
        if #available(iOS 16.2, *) { RideActivity.setCasting(false) } // 动态岛：投屏停了，骑行没在跑就结束（1.2.9）

        if statusText.hasPrefix("发送中") || statusText.hasPrefix("仅 RTCP") {
            statusText = "已停止"
        }
        if pingCounter > 0 {
            Diag.log("stop：累计 \(sentFrames) 帧 / \(sentPackets) 包，pong \(rtcpPongCount) 次，背压跳过 \(skippedByBackpressure) 次，积压丢弃 \(backlogDrops) 次")
        }
    }

    // MARK: - RTCP

    /// 统一走这里访问 callbackQueue：已在队列上就直接执行，不会自锁死
    private func onSendQueue(_ block: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            block()
            return
        }
        callbackQueue.sync(execute: block)
    }

    private func sendPing() {
        pingCounter &+= 1
        pingSentTimes[pingCounter] = Int(Date().timeIntervalSince1970 * 1000)
        if pingSentTimes.count > 16 {
            pingSentTimes.removeValue(forKey: pingSentTimes.keys.first!)
        }
        // 官方心跳（APP 子类型 5，参数 [0,2]）先发；再发计数变体兜底，两包都无害
        controlChannel?.send(RTCP.heartbeat())
        controlChannel?.send(RTCP.ping(counter: pingCounter))
        if pingCounter == 1 {
            Diag.log("首个心跳已发出（官方 [0,2] + 计数变体）")
        }
    }

    // MARK: - 取帧 → 编码（带背压）

    private func produceFrame() {
        autoreleasepool {
            guard encoder != nil else { return }

            inflightLock.lock()
            let inflight = inflightFrames
            inflightLock.unlock()
            // 编码器已经压了 3 帧还没吐出来：这一拍直接跳过，
            // 否则队列越积越长，仪表延迟越滚越大（表现为越投越卡）
            if inflight >= 3 {
                skippedByBackpressure &+= 1
                return
            }

            if let videoSource, let buffer = videoSource.latestFrame() {
                submit(buffer)
                return
            }
            if let cameraSource, let buffer = cameraSource.renderedFrame() {
                submit(buffer)
                return
            }
            if let photoBuffer {
                submit(photoBuffer)
                return
            }
            if let pixelBuffer = TestImageSource.makeFrame(
                index: frameIndex,
                width: preset.width,
                height: preset.height) {
                submit(pixelBuffer)
            }
        }
    }

    private func submit(_ buffer: CVPixelBuffer) {
        guard let encoder else { return }
        inflightLock.lock()
        inflightFrames += 1
        inflightLock.unlock()
        frameIndex &+= 1
        // HUD 叠加（电量/日期/天气/来电）：画进一份拷贝再编码，
        // 相册图片 buffer 是静态复用的，不能原地画。拷贝失败就用原帧。
        let framed = HUDRenderer.drawCopy(of: buffer) ?? buffer
        encoder.encode(framed, presentationTime: CMTime(value: frameIndex, timescale: activeFps))
    }

    // MARK: - 编码输出 → 打包 → 限流发送

    private func handleEncodedFrame(_ annexB: Data, keyframe: Bool) {
        inflightLock.lock()
        if inflightFrames > 0 { inflightFrames -= 1 }
        inflightLock.unlock()
        guard !annexB.isEmpty else { return }

        videoQueue.async { [weak self] in
            guard let self, var currentPacker = self.packer else { return }

            self.encodedFrameIndex &+= 1
            let timestampMs = UInt32((self.encodedFrameIndex * 1000) / Int64(self.activeFps))
            let packets = currentPacker.packetizeFrame(
                annexB, timestampMs: timestampMs, isKeyframe: keyframe)
            self.packer = currentPacker
            guard !packets.isEmpty else { return }

            self.bytesWindow += annexB.count
            self.framesWindow += 1

            self.compactQueueIfNeeded()
            // 积压明显（超过约 0.3 秒的量）：直接丢掉这一帧，不往队尾加，
            // 加进去只会让后面所有帧都跟着多等——延迟就是这么滚起来的
            if self.pendingPackets.count - self.sendCursor > 120 {
                self.backlogDrops &+= 1
                DispatchQueue.main.async {
                    self.droppedFrames += 1
                }
                return
            }

            let copies = (keyframe && self.duplicateKeyframes) ? 2 : 1
            for _ in 0..<copies {
                self.pendingPackets.append(contentsOf: packets)
            }
            let packetCount = packets.count * copies
            DispatchQueue.main.async {
                self.sentFrames += 1
                self.sentPackets += packetCount
            }

            if !self.loggedFirstFrame {
                self.loggedFirstFrame = true
                Diag.log("首帧已发：\(annexB.count) 字节 → \(packets.count) 包 key=\(keyframe)")
            }
        }
    }

    /// 回收已发完的前缀，避免数组无限增长
    private func compactQueueIfNeeded() {
        guard sendCursor > 256 else { return }
        if sendCursor >= pendingPackets.count {
            pendingPackets.removeAll(keepingCapacity: true)
        } else {
            pendingPackets.removeFirst(sendCursor)
        }
        sendCursor = 0
    }

    /// 每毫秒 2 包起步；有积压时自动加速（最多 10 包/毫秒）追平，
    /// 平时保持匀速不发猛，突发时快速消化不让包排队
    private func startPacer() {
        let timer = DispatchSource.makeTimerSource(queue: videoQueue)
        timer.schedule(deadline: .now() + 0.001, repeating: .milliseconds(1),
                       leeway: .microseconds(200))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let backlog = self.pendingPackets.count - self.sendCursor
            let drain = min(10, 2 + backlog / 20)
            var sent = 0
            while sent < drain, self.sendCursor < self.pendingPackets.count {
                let packet = self.pendingPackets[self.sendCursor]
                self.sendCursor += 1
                sent += 1
                self.packetsWindow += 1
                if let kcp = self.kcpChannel {
                    kcp.send(packet)
                } else {
                    self.videoChannel?.send(packet)
                }
            }
            self.compactQueueIfNeeded()
        }
        timer.resume()
        pacerTimer = timer
    }

    /// 每秒统计一次：真实出帧率、平均帧大小、积压量
    private func startStats() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(deadline: .now() + 1, repeating: .seconds(1))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.measuredFps = max(0, self.sentFrames - self.lastSampleFrames)
            self.lastSampleFrames = self.sentFrames
            self.videoQueue.async {
                let frames = self.framesWindow
                let bytes = self.bytesWindow
                let packets = self.packetsWindow
                let backlog = self.pendingPackets.count - self.sendCursor
                let drops = self.backlogDrops
                self.framesWindow = 0
                self.bytesWindow = 0
                self.packetsWindow = 0
                self.inflightLock.lock()
                let inflight = self.inflightFrames
                let skipped = self.skippedByBackpressure
                self.inflightLock.unlock()
                DispatchQueue.main.async {
                    self.avgFrameKB = frames > 0 ? bytes / frames / 1024 : 0
                    self.backlogPackets = backlog
                    self.droppedFrames = drops + self.skippedByBackpressure
                    self.statTicks += 1
                    // 每 5 秒写一行诊断，够看又不刷屏
                    if self.statTicks % 5 == 0 {
                        Diag.log("统计 fps=\(self.measuredFps) 帧均=\(self.avgFrameKB)KB 包=\(packets)/s 积压=\(backlog) 在飞=\(inflight) 背压跳过=\(skipped) 积压丢弃=\(drops)")
                    }
                }
            }
        }
        timer.resume()
        statTimer = timer
    }

    private func handleControlReceive(_ data: Data) {
        if let seq = RTCP.parsePong(data) {
            var sentAt: Int? = nil
            onSendQueue {
                sentAt = pingSentTimes.removeValue(forKey: seq)
            }
            DispatchQueue.main.async {
                self.rtcpPongCount += 1
                if let sentAt {
                    self.lastRTTMs = Int(Date().timeIntervalSince1970 * 1000) - sentAt
                }
                if self.rtcpPongCount == 1 {
                    Diag.log("收到第一个 pong：仪表在线且认 RTCP")
                }
            }
            return
        }
        // 仪表主动报告：1=丢包 2=请求帧率 3=请求码率
        if let report = RTCP.parseApp(data) {
            Diag.log("仪表报告 subtype=\(report.subtype) value=\(report.value ?? 0)")
            DispatchQueue.main.async {
                switch report.subtype {
                case 1:
                    self.dashboardReport = "仪表丢包报告 #\(report.value ?? 0)"
                case 2:
                    self.dashboardReport = "仪表请求帧率 \(report.value ?? 0) FPS"
                case 3:
                    if let rate = report.value {
                        self.dashboardReport = "仪表请求码率 \(rate / 1000) kbps（已应用）"
                        self.encoder?.updateBitrate(rate)
                    }
                default:
                    break
                }
            }
            return
        }
        if data.count != 20 {
            Diag.log("仪表回包 \(data.count) 字节 \(data.prefix(24).map { String(format: "%02x", $0) }.joined())")
        }
    }
}
