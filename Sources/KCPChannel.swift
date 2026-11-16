import Foundation

/// KCP 通道（七寸预设用），包装 Vendor/kcp 的 C 实现。
/// 注意：kcp 的 conv / 模式参数（nodelay 配置、远端 ACK 是否直连 5012）
/// 需要拿到七寸真实抓包后核对，当前按作者仓库说明的常规参数配置。
final class KCPChannel {
    private var kcp: UnsafeMutablePointer<ikcpcb>?
    private let output: (Data) -> Void

    init(conv: UInt32, output: @escaping (Data) -> Void) {
        self.output = output
        guard let created = ikcp_create(conv, Unmanaged.passUnretained(self).toOpaque()) else {
            Diag.log("ikcp_create 失败，KCP 通道降级为不发送")
            return
        }
        kcp = created
        ikcp_setoutput(created) { buffer, length, _, user in
            guard let user, let buffer, length > 0 else { return -1 }
            let channel = Unmanaged<KCPChannel>.fromOpaque(user).takeUnretainedValue()
            channel.output(Data(bytes: UnsafeRawPointer(buffer), count: Int(length)))
            return 0
        }
        ikcp_nodelay(created, 1, 10, 2, 1) // nodelay=1 interval=10 resend=2 nc=1
        ikcp_wndsize(created, 128, 128)
    }

    deinit {
        if let kcp { ikcp_release(kcp) }
    }

    func send(_ data: Data) {
        guard let kcp, !data.isEmpty else { return }
        data.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                ikcp_send(kcp, base.assumingMemoryBound(to: CChar.self), Int32(raw.count))
            }
        }
    }

    /// 收到仪表回包后喂给 KCP（ACK/重传控制）
    func input(_ data: Data) {
        guard let kcp, !data.isEmpty else { return }
        data.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                _ = ikcp_input(kcp, base.assumingMemoryBound(to: CChar.self), raw.count)
            }
        }
    }

    /// 定时驱动（约 10ms 一次）
    func tick() {
        guard let kcp else { return }
        ikcp_update(kcp, Self.currentMillis())
    }

    /// KCP 已组装好的完整包（未用于骨架阶段，预留给后续回包解析）
    func recv() -> Data? {
        guard let kcp else { return nil }
        let size = ikcp_peeksize(kcp)
        guard size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(size))
        let n = ikcp_recv(kcp, &buffer, size)
        guard n > 0 else { return nil }
        return Data(bytes: buffer, count: Int(n))
    }

    static func currentMillis() -> UInt32 {
        UInt32(Date().timeIntervalSince1970 * 1000)
    }
}
