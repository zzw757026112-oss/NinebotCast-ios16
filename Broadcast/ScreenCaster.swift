import CoreMedia
import CoreVideo
import Darwin
import Foundation
import os.log

/// 录屏投屏引擎：发现仪表 → H.264 编码 → RTP 打包 → UDP 5012，RTCP 心跳走 5013。
///
/// 与主 App 的 CastEngine 同一套线上传输（五寸 H.264/RTP 预设），但这里
/// 完全自包含：BSD socket 直发，不依赖主 App 的 UDPChannel / CastEngine，
/// 也不需要 App Groups——扩展自己用 RTCP ping 发现仪表。
///
/// 线程模型：
/// - streamQueue：编码回调、RTP 打包、限流发送、心跳（除编码提交外全在这里）
/// - discoveryQueue：RTCP ping 发现仪表（阻塞式收包，拿到 IP 就停）
/// - SampleHandler 的 processSampleBuffer 在系统队列上调 submitFrame，
///   只做节流 + 背压判断，缩放/编码都在本类里同步完成，不保留源 buffer。
final class ScreenCaster {
    // 与主 App 五寸预设一致
    static let outWidth = 848
    static let outHeight = 480
    static let fps: Int32 = 20
    static let bitrate: UInt32 = 2_000_000
    static let gop = 10
    static let videoPort: UInt16 = 5012
    static let controlPort: UInt16 = 5013

    private let log = Logger(subsystem: "com.corpsezhao.ninebotcast", category: "broadcast")

    private let streamQueue = DispatchQueue(label: "ninebotcast.mirror.stream")
    private let discoveryQueue = DispatchQueue(label: "ninebotcast.mirror.discovery")
    private let streamQueueKey = DispatchSpecificKey<Int>()

    private var stopped = true
    private var paused = false
    private var dashboardIP: String?
    private var videoFd: Int32 = -1
    private var controlFd: Int32 = -1

    private var encoder: ScreenEncoder?
    private var retiredEncoders: [ScreenEncoder] = []
    private var scaler: ScreenScaler?
    private var packer = MirrorPacker(chunkSize: 1400)
    private var pendingPackets: [Data] = []
    private var sendCursor = 0

    private var heartbeatTimer: DispatchSourceTimer?
    private var pacerTimer: DispatchSourceTimer?
    private var discoveryTimer: DispatchSourceTimer?
    private var controlReadSource: DispatchSourceRead?

    private var pingCounter: UInt32 = 0
    private var frameIndex: Int64 = 0
    private var encodedFrameIndex: Int64 = 0
    private var lastSubmitTime = Date.distantPast
    private let inflightLock = NSLock()
    private var inflightFrames = 0
    private var loggedFirstFrame = false
    private var loggedFirstPong = false

    init() {
        streamQueue.setSpecific(key: streamQueueKey, value: 1)
    }

    // MARK: - 生命周期

    /// 录屏开始：启动仪表发现（没找到就每 2 秒重试，直到录屏结束）。
    func start() {
        streamQueue.async { [weak self] in
            guard let self else { return }
            self.stopped = false
            self.paused = false
            self.dashboardIP = nil
            self.log.info("mirror start：开始发现仪表")
            self.kickDiscovery()
            let timer = DispatchSource.makeTimerSource(queue: self.streamQueue)
            timer.schedule(deadline: .now() + 2, repeating: .seconds(2))
            timer.setEventHandler { [weak self] in self?.kickDiscovery() }
            timer.resume()
            self.discoveryTimer = timer
        }
    }

    func setPaused(_ paused: Bool) {
        streamQueue.async { [weak self] in
            self?.paused = paused
            self?.log.info("mirror \(paused ? "paused" : "resumed")")
        }
    }

    func stop() {
        streamQueue.async { [weak self] in
            guard let self else { return }
            self.stopped = true
            self.discoveryTimer?.cancel(); self.discoveryTimer = nil
            self.heartbeatTimer?.cancel(); self.heartbeatTimer = nil
            self.pacerTimer?.cancel(); self.pacerTimer = nil
            self.controlReadSource?.cancel(); self.controlReadSource = nil
            self.packer = MirrorPacker(chunkSize: 1400)
            self.pendingPackets.removeAll()
            self.sendCursor = 0
            self.teardownEncoder()
            if self.videoFd >= 0 { close(self.videoFd); self.videoFd = -1 }
            if self.controlFd >= 0 { close(self.controlFd); self.controlFd = -1 }
            self.dashboardIP = nil
            self.log.info("mirror stop")
        }
    }

    deinit {
        heartbeatTimer?.cancel()
        pacerTimer?.cancel()
        discoveryTimer?.cancel()
        controlReadSource?.cancel()
        if videoFd >= 0 { close(videoFd) }
        if controlFd >= 0 { close(controlFd) }
    }

    private func teardownEncoder() {
        if let encoder {
            encoder.onAnnexBFrame = nil
            encoder.teardown()
            retiredEncoders.append(encoder)
            if retiredEncoders.count > 4 { retiredEncoders.removeFirst() }
        }
        encoder = nil
        inflightLock.lock()
        inflightFrames = 0
        inflightLock.unlock()
    }

    // MARK: - 仪表发现（RTCP ping）

    private func kickDiscovery() {
        guard !stopped, dashboardIP == nil else { return }
        discoveryQueue.async { [weak self] in
            guard let self else { return }
            if let ip = self.probeOnce() {
                self.streamQueue.async { [weak self] in
                    guard let self, !self.stopped, self.dashboardIP == nil else { return }
                    self.log.info("mirror：发现仪表 \(ip)")
                    self.startStreaming(to: ip)
                }
            }
        }
    }

    /// 一轮探测：网关 + 子网广播 + 全网广播发 RTCP ping，等 1.5 秒收 pong。
    /// 仪表只在投屏接收态才回包，没回就是还没进接收态，调用方会重试。
    private func probeOnce() -> String? {
        guard let localIP = Self.localIPv4(),
              let prefix = Self.localPrefix(ip: localIP) else {
            log.error("mirror：没取到本机 Wi-Fi 地址，无法发现仪表")
            return nil
        }
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        Self.setNonBlocking(fd)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = Self.bindLocal(fd, preferredPort: Self.controlPort)

        let payload = MirrorRTCP.ping(counter: 1)
        let targets = ["\(prefix).1", "\(prefix).255", "255.255.255.255"]
        for ip in targets {
            if ip != localIP { _ = Self.sendTo(fd, ip: ip, port: Self.controlPort, payload: payload) }
        }

        let deadline = Date().addingTimeInterval(1.5)
        var buffer = [UInt8](repeating: 0, count: 2048)
        while Date() < deadline {
            if stopped { return nil }
            if let (ip, bytes) = Self.receiveFrom(fd, buffer: &buffer) {
                if ip == localIP { continue }
                if MirrorRTCP.parsePong(Data(bytes)) != nil {
                    return ip
                }
            } else {
                usleep(15_000)
            }
        }
        return nil
    }

    // MARK: - 开始推流

    private func startStreaming(to ip: String) {
        guard !stopped else { return }
        dashboardIP = ip
        discoveryTimer?.cancel(); discoveryTimer = nil

        let localIP = Self.localIPv4()
        videoFd = openSocket(localIP: localIP, preferredPort: Self.videoPort)
        controlFd = openSocket(localIP: localIP, preferredPort: Self.controlPort)
        guard videoFd >= 0, controlFd >= 0 else {
            log.error("mirror：建 socket 失败")
            return
        }

        let scaler = ScreenScaler()
        self.scaler = scaler
        let encoder = ScreenEncoder()
        guard encoder.setup(width: Self.outWidth, height: Self.outHeight,
                            fps: Self.fps, bitrate: Self.bitrate, gop: Self.gop) else {
            log.error("mirror：编码器初始化失败")
            return
        }
        encoder.onAnnexBFrame = { [weak self] data, isKey in
            self?.streamQueue.async { self?.handleEncodedFrame(data, keyframe: isKey) }
        }
        self.encoder = encoder

        startPongReceive()
        startHeartbeat()
        startPacer()
        log.info("mirror：开始推流 → \(ip):5012（848x480 @20fps 2Mbps）")
    }

    private func startPongReceive() {
        guard controlFd >= 0 else { return }
        let source = DispatchSource.makeReadSource(fileDescriptor: controlFd, queue: streamQueue)
        source.setEventHandler { [weak self] in
            guard let self, self.controlFd >= 0 else { return }
            var buffer = [UInt8](repeating: 0, count: 2048)
            while let (_, bytes) = Self.receiveFrom(self.controlFd, buffer: &buffer) {
                if MirrorRTCP.parsePong(Data(bytes)) != nil, !self.loggedFirstPong {
                    self.loggedFirstPong = true
                    self.log.info("mirror：收到第一个 pong，仪表在线")
                }
            }
        }
        source.setCancelHandler { }
        source.resume()
        controlReadSource = source
    }

    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: streamQueue)
        timer.schedule(deadline: .now() + 0.3, repeating: .seconds(1))
        timer.setEventHandler { [weak self] in
            guard let self, !self.stopped, let ip = self.dashboardIP, self.controlFd >= 0 else { return }
            self.pingCounter &+= 1
            Self.sendTo(self.controlFd, ip: ip, port: Self.controlPort, payload: MirrorRTCP.heartbeat())
            Self.sendTo(self.controlFd, ip: ip, port: Self.controlPort, payload: MirrorRTCP.ping(counter: self.pingCounter))
        }
        timer.resume()
        heartbeatTimer = timer
    }

    /// 每毫秒 2 包起步；有积压时自动加速（最多 10 包/毫秒）追平。
    private func startPacer() {
        let timer = DispatchSource.makeTimerSource(queue: streamQueue)
        timer.schedule(deadline: .now() + 0.001, repeating: .milliseconds(1),
                       leeway: .microseconds(200))
        timer.setEventHandler { [weak self] in
            guard let self, !self.stopped, self.videoFd >= 0, let ip = self.dashboardIP else { return }
            let backlog = self.pendingPackets.count - self.sendCursor
            let drain = min(10, 2 + backlog / 20)
            var sent = 0
            while sent < drain, self.sendCursor < self.pendingPackets.count {
                let packet = self.pendingPackets[self.sendCursor]
                self.sendCursor += 1
                sent += 1
                Self.sendTo(self.videoFd, ip: ip, port: Self.videoPort, payload: packet)
            }
            self.compactQueueIfNeeded()
        }
        timer.resume()
        pacerTimer = timer
    }

    // MARK: - 帧管线（系统录屏队列调入）

    /// 录屏每帧都到这里：节流到 20fps，背压丢帧，缩放后送编码器。
    /// 源 buffer 只在本次调用内读，不保留。
    func submitFrame(_ pixelBuffer: CVPixelBuffer) {
        if stopped || paused || dashboardIP == nil || encoder == nil { return }
        let now = Date()
        guard now.timeIntervalSince(lastSubmitTime) >= 0.05 else { return }
        inflightLock.lock()
        let inflight = inflightFrames
        inflightLock.unlock()
        guard inflight < 2 else { return } // 编码器已压 2 帧：跳过这一拍
        guard let scaler, let scaled = scaler.scale(pixelBuffer) else { return }

        lastSubmitTime = now
        inflightLock.lock()
        inflightFrames += 1
        inflightLock.unlock()
        frameIndex &+= 1
        encoder?.encode(scaled, presentationTime: CMTime(value: frameIndex, timescale: Self.fps))
    }

    private func handleEncodedFrame(_ annexB: Data, keyframe: Bool) {
        inflightLock.lock()
        if inflightFrames > 0 { inflightFrames -= 1 }
        inflightLock.unlock()
        guard !annexB.isEmpty, !stopped else { return }

        encodedFrameIndex &+= 1
        let timestampMs = UInt32((encodedFrameIndex * 1000) / Int64(Self.fps))
        let packets = packer.packetizeFrame(annexB, timestampMs: timestampMs, isKeyframe: keyframe)
        guard !packets.isEmpty else { return }

        compactQueueIfNeeded()
        // 积压超过约 0.3 秒的量：直接丢掉这一帧，不让延迟滚起来
        if pendingPackets.count - sendCursor > 120 { return }
        pendingPackets.append(contentsOf: packets)

        if !loggedFirstFrame {
            loggedFirstFrame = true
            log.info("mirror：首帧已发 \(annexB.count) 字节 → \(packets.count) 包 key=\(keyframe)")
        }
    }

    private func compactQueueIfNeeded() {
        guard sendCursor > 256 else { return }
        if sendCursor >= pendingPackets.count {
            pendingPackets.removeAll(keepingCapacity: true)
        } else {
            pendingPackets.removeFirst(sendCursor)
        }
        sendCursor = 0
    }

    // MARK: - POSIX socket 细节

    private func openSocket(localIP: String?, preferredPort: UInt16) -> Int32 {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return -1 }
        Self.setNonBlocking(fd)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = Self.bindLocal(fd, preferredPort: preferredPort)
        return fd
    }

    private static func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }
    }

    /// 先绑官方端口，失败就退到临时端口（主 App 占着端口时也能发）。
    private static func bindLocal(_ fd: Int32, preferredPort: UInt16) -> UInt16 {
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        for candidate in [preferredPort, UInt16(0)] {
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = candidate.bigEndian
            addr.sin_addr.s_addr = INADDR_ANY
            let ok = withUnsafePointer(to: &addr) { pointer -> Bool in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
                }
            }
            if ok {
                var actual = sockaddr_in()
                var length = socklen_t(MemoryLayout<sockaddr_in>.size)
                let got = withUnsafeMutablePointer(to: &actual) { pointer -> Bool in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        getsockname(fd, sa, &length) == 0
                    }
                }
                return got ? UInt16(bigEndian: actual.sin_port) : candidate
            }
        }
        return 0
    }

    @discardableResult
    private static func sendTo(_ fd: Int32, ip: String, port: UInt16, payload: Data) -> Bool {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { return false }
        let bytes = [UInt8](payload)
        let sent = withUnsafePointer(to: &addr) { pointer -> Int in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                sendto(fd, bytes, bytes.count, 0, sa,
                       socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return sent > 0
    }

    private static func receiveFrom(_ fd: Int32, buffer: inout [UInt8]) -> (String, [UInt8])? {
        var addr = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let received = withUnsafeMutablePointer(to: &addr) { pointer -> Int in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                recvfrom(fd, &buffer, buffer.count, 0, sa, &length)
            }
        }
        guard received > 0 else { return nil }

        var raw = addr.sin_addr
        var host = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &raw, &host, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
        return (String(cString: host), Array(buffer[0..<received]))
    }

    // MARK: - 本机地址

    private static func localIPv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(first) }

        var preferred: String?
        var fallback: String?
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let ifa = current.pointee
            cursor = ifa.ifa_next
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ifa.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                              &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            if name == "en0" && preferred == nil {
                preferred = ip
            } else if fallback == nil && name.hasPrefix("en") {
                fallback = ip
            }
        }
        return preferred ?? fallback
    }

    private static func localPrefix(ip: String) -> String? {
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return nil }
        return "\(parts[0]).\(parts[1]).\(parts[2])"
    }
}
