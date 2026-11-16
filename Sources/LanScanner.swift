import Foundation
import Darwin

/// 局域网里找仪表 IP 的多路探测器。
///
/// 为什么要多路：端口不是通用的。
/// - **5013 RTCP** 是官方投屏 App 真正用的端口（APK 逆向所得），最权威，
///   但仪表只在「投屏接收态」才回包，平时扫是一片安静。
/// - **TCP 80/443/8443/5000/8080** 是车机/仪表上跑网页服务的常见端口，
///   不同车型、不同固件开的都不一样，所以不能只押 8443。
/// - **网关地址**：仪表热点由车机自己发 DHCP，网关通常就是车机自己（多为 .1，少数 .254）。
/// - **UDP 广播**：有的实现会回广播探测包，成本极低，作为补充。
enum LanScanner {
    /// RTCP 探测命中
    struct Hit {
        let ip: String
        let rttMs: Int
        let replyCount: Int
        let replyHex: String
    }

    /// TCP 端口探测命中
    struct TcpHit {
        let ip: String
        var ports: [UInt16]
    }

    /// 单个 IP 的体检结果
    struct ProbeResult {
        var ip: String = ""
        var openPorts: [UInt16] = []
        var rtcpPong: Bool = false
        var pongHex: String = ""
        var rttMs: Int = -1
    }

    static let commonPorts: [UInt16] = [8443, 80, 443, 5000, 8080, 8000, 9000]

    // MARK: - 本机信息

    /// 本机 Wi-Fi IPv4，例如 192.168.1.23
    static func localIPv4() -> String? {
        LocalAddress.primaryIPv4()
    }

    /// 由本机 IP 推前三段，例如 192.168.1
    static func localPrefix() -> String? {
        guard let ip = localIPv4() else { return nil }
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return nil }
        return "\(parts[0]).\(parts[1]).\(parts[2])"
    }

    /// 仪表热点的网关：车机自己发 DHCP，所以网关基本就是它
    static func gatewayGuess() -> String? {
        guard let prefix = localPrefix() else { return nil }
        return "\(prefix).1"
    }

    // MARK: - RTCP 5013 扫描

    /// 并发扫 1...254，逐个发 RTCP ping，收集回包。
    /// 会跳过本机 IP（否则内核把包回环给自己，误报成"仪表回应"）。
    static func scan(prefix: String,
                     port: UInt16 = 5013,
                     waitSeconds: Double = 2.0,
                     broadcast: Bool = true,
                     found: @escaping (Hit) -> Void,
                     completion: @escaping ([Hit]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var hits: [Hit] = []
            let selfIP = localIPv4() ?? ""

            let fd = socket(AF_INET, SOCK_DGRAM, 0)
            guard fd >= 0 else {
                Diag.log("scan: socket() 失败")
                DispatchQueue.main.async { completion([]) }
                return
            }
            defer { close(fd) }

            setNonBlocking(fd)
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
            let boundPort = bindLocal(fd, preferredPort: port)
            Diag.log("scan: 本地绑定端口 \(boundPort)，本机 \(selfIP.isEmpty ? "nil" : selfIP) 已排除")

            let payload = RTCP.ping(counter: 1)
            var sentAt: [String: Int] = [:]
            for i in 1...254 {
                let ip = "\(prefix).\(i)"
                if ip == selfIP { continue } // 自己 ping 自己只会收到回声
                if sendTo(fd, ip: ip, port: port, payload: payload) {
                    sentAt[ip] = nowMs()
                }
            }
            if broadcast {
                for ip in ["\(prefix).255", "255.255.255.255"] {
                    if sendTo(fd, ip: ip, port: port, payload: payload) {
                        Diag.log("scan: 广播探测 \(ip):\(port)")
                    }
                }
            }
            Diag.log("scan: 已向 \(prefix).1-254:\(port) 发出 \(sentAt.count) 个 ping（排除本机）")

            let deadline = Date().addingTimeInterval(waitSeconds)
            var buffer = [UInt8](repeating: 0, count: 2048)
            while Date() < deadline {
                if let (ip, bytes) = receiveFrom(fd, buffer: &buffer) {
                    if ip == selfIP { continue }
                    if let index = hits.firstIndex(where: { $0.ip == ip }) {
                        let old = hits[index]
                        hits[index] = Hit(ip: ip, rttMs: old.rttMs,
                                          replyCount: old.replyCount + 1,
                                          replyHex: hex(bytes))
                    } else {
                        let rtt = max(0, nowMs() - (sentAt[ip] ?? nowMs()))
                        let hit = Hit(ip: ip, rttMs: rtt, replyCount: 1, replyHex: hex(bytes))
                        hits.append(hit)
                        Diag.log("scan: \(ip) 回应 \(bytes.count) 字节 \(hit.replyHex)")
                        DispatchQueue.main.async { found(hit) }
                    }
                } else {
                    usleep(15_000)
                }
            }

            Diag.log("scan: 完成，\(hits.count) 个主机回应（不含本机）")
            let result = hits
            DispatchQueue.main.async { completion(result) }
        }
    }

    // MARK: - TCP 端口扫描

    /// 扫一批常见端口，报告每台主机开了哪些（而不是只赌 8443）
    static func tcpScan(prefix: String,
                        ports: [UInt16] = commonPorts,
                        waitMsPerPort: Int = 1400,
                        found: @escaping (String) -> Void,
                        completion: @escaping ([TcpHit]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var merged: [String: [UInt16]] = [:]
            Diag.log("tcpScan: 开始 \(prefix).1-254 端口 \(ports.map { String($0) }.joined(separator: ","))")
            for port in ports {
                let ips = tcpScanPort(prefix: prefix, port: port, waitMs: waitMsPerPort)
                for ip in ips {
                    if merged[ip] == nil {
                        DispatchQueue.main.async { found(ip) }
                    }
                    merged[ip, default: []].append(port)
                }
            }
            let hits = merged.map { TcpHit(ip: $0.key, ports: $0.value.sorted()) }
                .sorted { $0.ip < $1.ip }
            Diag.log("tcpScan: 完成，\(hits.count) 个主机有开放端口")
            DispatchQueue.main.async { completion(hits) }
        }
    }

    /// 同步扫单一端口（内部用，分批 60 个连接，避免撞 iOS 的 fd 上限）
    private static func tcpScanPort(prefix: String, port: UInt16, waitMs: Int) -> [String] {
        let selfIP = localIPv4() ?? ""
        var open: [String] = []
        var queue = (1...254).map { "\(prefix).\($0)" }.filter { $0 != selfIP }
        let globalDeadline = Date().addingTimeInterval(Double(waitMs) / 1000.0)

        while !queue.isEmpty && Date() < globalDeadline {
            let chunk = Array(queue.prefix(60))
            queue.removeFirst(chunk.count)
            var pending: [(fd: Int32, ip: String)] = []

            for ip in chunk {
                guard let fd = startConnect(ip: ip, port: port) else { continue }
                pending.append((fd, ip))
            }

            while !pending.isEmpty && Date() < globalDeadline {
                var fds = pending.map { pollfd(fd: $0.fd, events: Int16(POLLOUT), revents: 0) }
                let ready = poll(&fds, nfds_t(fds.count), 150)
                guard ready > 0 else { continue }
                var still: [(fd: Int32, ip: String)] = []
                for (idx, entry) in pending.enumerated() {
                    let re = fds[idx].revents
                    if re & (Int16(POLLOUT) | Int16(POLLERR) | Int16(POLLHUP)) != 0 {
                        var err: Int32 = 0
                        var len = socklen_t(MemoryLayout<Int32>.size)
                        getsockopt(entry.fd, SOL_SOCKET, SO_ERROR, &err, &len)
                        if err == 0 {
                            open.append(entry.ip)
                            Diag.log("tcpScan: \(entry.ip):\(port) 开放")
                        }
                        close(entry.fd)
                    } else {
                        still.append(entry)
                    }
                }
                pending = still
            }
            for entry in pending { close(entry.fd) }
        }
        return open
    }

    /// 启动一个非阻塞 connect；返回 fd（已发起连接）或 nil
    private static func startConnect(ip: String, port: UInt16) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        setNonBlocking(fd)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else {
            close(fd)
            return nil
        }
        let result = withUnsafePointer(to: &addr) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result == 0 { return fd }             // 立即成功
        if errno == EINPROGRESS { return fd }    // 等 poll
        close(fd)
        return nil
    }

    // MARK: - 单个 IP 体检

    /// 对指定 IP 做体检：常见 TCP 端口 + RTCP ping。
    /// 用来回答「这个 IP 到底是不是仪表」，比盲扫更直接。
    static func probe(ip: String, ports: [UInt16] = commonPorts, waitMs: Int = 1200) -> ProbeResult {
        var result = ProbeResult(ip: ip)

        // TCP：每端口单独测，时间可控
        for port in ports {
            if let fd = startConnect(ip: ip, port: port) {
                var fds = [pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)]
                let ready = poll(&fds, 1, Int32(waitMs / max(1, ports.count) + 200))
                if ready > 0 {
                    var err: Int32 = 0
                    var len = socklen_t(MemoryLayout<Int32>.size)
                    getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
                    if err == 0 { result.openPorts.append(port) }
                }
                close(fd)
            }
        }

        // UDP RTCP
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        if fd >= 0 {
            setNonBlocking(fd)
            _ = bindLocal(fd, preferredPort: 5013)
            let payload = RTCP.ping(counter: 1)
            let sentAt = nowMs()
            _ = sendTo(fd, ip: ip, port: 5013, payload: payload)
            let deadline = Date().addingTimeInterval(0.6)
            var buffer = [UInt8](repeating: 0, count: 2048)
            while Date() < deadline {
                if let (_, bytes) = receiveFrom(fd, buffer: &buffer) {
                    if bytes.count == 20, bytes[0] == 0x85, bytes[1] == 0xCC {
                        result.rtcpPong = true
                        result.pongHex = hex(bytes)
                        result.rttMs = nowMs() - sentAt
                        break
                    }
                } else {
                    usleep(15_000)
                }
            }
            close(fd)
        }
        Diag.log("probe \(ip)：TCP \(result.openPorts.map { String($0) }.joined(separator: ",")) pong=\(result.rtcpPong)")
        return result
    }

    // MARK: - POSIX 细节

    private static func nowMs() -> Int {
        Int(Date().timeIntervalSince1970 * 1000)
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }
    }

    /// 先在 5013 上绑（和官方一致），失败了就退到临时端口，保证扫描总能跑
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
}
