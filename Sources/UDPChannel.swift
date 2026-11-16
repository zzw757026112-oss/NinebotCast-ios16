import Foundation
import Network

/// 基于 Network.framework 的 UDP 通道（视频 5012 / RTCP 5013）。
///
/// 官方实现会把本地端口也绑到 5012/5013。但实测发现：只要九号出行还在后台
/// （哪怕已"暂停视频"），它就占着这两个端口，我们的绑定会直接
/// `Address already in use` 失败——之前连接进入 failed 后 send 全部静默丢弃，
/// 表现为"帧数在涨但仪表毫无反应"。
///
/// 所以这里做成两段式：先尝试绑官方端口，失败就自动降级为临时端口重连，
/// 并通过 onFallback 把这件事上报到界面（此时应强退九号出行再试）。
final class UDPChannel {
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "ninebotcast.udp")

    private let host: NWEndpoint.Host
    private let remotePort: NWEndpoint.Port
    private let localIP: String?
    private let localPort: UInt16?
    /// 当前这次连接是否还要求绑定官方本地端口
    private var wantLocalBind: Bool

    /// 收到仪表回包（RTCP pong / 其他控制回应）时回调
    var onReceive: ((Data) -> Void)?

    /// 本机端口被占、降级为临时端口时回调（已在主线程）
    var onFallback: ((String) -> Void)?

    init(host: String, remotePort: UInt16, localIP: String? = nil, localPort: UInt16? = nil) {
        self.host = NWEndpoint.Host(host)
        self.remotePort = NWEndpoint.Port(rawValue: remotePort) ?? 5012
        self.localIP = localIP
        self.localPort = localPort
        self.wantLocalBind = (localIP != nil && localPort != nil)
    }

    func start() {
        startConnection()
    }

    private func startConnection() {
        let params = NWParameters.udp
        if wantLocalBind, let localIP, let localPort,
           let lp = NWEndpoint.Port(rawValue: localPort) {
            params.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(localIP), port: lp)
        }
        let conn = NWConnection(host: host, port: remotePort, using: params)
        let target = "\(host):\(remotePort.rawValue)"

        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                let localDesc = conn.currentPath?.localEndpoint.map { String(describing: $0) } ?? "?"
                Diag.log("UDP 就绪 本地=\(localDesc) → \(target)")
                self?.receiveLoop(on: conn)
            case .failed(let error):
                Diag.log("UDP 失败 \(target) \(error)")
                self?.handleFailure(error)
            default:
                break
            }
        }
        connection = conn
        conn.start(queue: queue)
    }

    private func handleFailure(_ error: NWError) {
        guard wantLocalBind else { return }
        // POSIX 48 = EADDRINUSE。九号出行在后台占着官方端口是常态，
        // 降级为临时端口先让包发出去，同时提醒用户强退九号出行。
        wantLocalBind = false
        Diag.log("UDP 本机端口被占（多半是九号出行还开着），降级为临时端口重连")
        connection?.cancel()
        connection = nil
        DispatchQueue.main.async { [weak self] in
            let port = self?.localPort.map(String.init) ?? "?"
            self?.onFallback?("本机端口 \(port) 被占（九号出行没退干净），已改用临时端口发送；建议强退九号出行后重试")
        }
        startConnection()
    }

    private func receiveLoop(on conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.onReceive?(data)
            }
            if error == nil {
                self.receiveLoop(on: conn)
            }
        }
    }

    func send(_ data: Data) {
        connection?.send(content: data, completion: .contentProcessed { _ in })
    }

    func stop() {
        connection?.cancel()
        connection = nil
    }
}
