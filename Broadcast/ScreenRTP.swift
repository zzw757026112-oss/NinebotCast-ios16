import Foundation

/// 与主 App 的 RTPPacker / RTCP 逐字节相同的打包器与心跳（独立拷贝，
/// 录屏扩展不能引用主 App 的文件，所以这里自成一份；改协议时两边要同步）。
///
/// 视频 RTP 包结构（共 20 字节头）：
/// - [0]      0x90（V=2, X=1 扩展头）
/// - [1]      (marker?0x80:0) | 32（payload type 固定 32）
/// - [2..3]   序列号 BE16（全局逐包递增）
/// - [4..7]   时间戳 BE32（单位：毫秒，帧间隔节奏）
/// - [8..14]  0
/// - [15]     1
/// - [16]     0
/// - [17]     标志：0x10=帧首包 0x08=帧尾包 0x01=关键帧
/// - [18..19] BE16(1024 | (时间戳低10位))（帧级标识）
/// - 负载：Annex-B 原始字节流按 1400 字节切块（不按 NALU 对齐）
struct MirrorPacker {
    var chunkSize: Int = 1400
    private(set) var sequence: UInt16 = 0

    init(chunkSize: Int = 1400) {
        self.chunkSize = chunkSize
    }

    mutating func packetizeFrame(_ frame: Data, timestampMs: UInt32, isKeyframe: Bool) -> [Data] {
        let bytes = [UInt8](frame)
        guard !bytes.isEmpty else { return [] }
        var packets: [Data] = []
        var offset = 0
        while offset < bytes.count {
            let chunkLen = min(chunkSize, bytes.count - offset)
            let isFirst = offset == 0
            let isLast = offset + chunkLen >= bytes.count
            sequence &+= 1

            var packet = Data(repeating: 0, count: 20 + chunkLen)
            packet[0] = 0x90
            packet[1] = (isLast ? 0x80 : 0x00) | 32
            packet[2] = UInt8(sequence >> 8)
            packet[3] = UInt8(sequence & 0xFF)
            packet[4] = UInt8((timestampMs >> 24) & 0xFF)
            packet[5] = UInt8((timestampMs >> 16) & 0xFF)
            packet[6] = UInt8((timestampMs >> 8) & 0xFF)
            packet[7] = UInt8(timestampMs & 0xFF)
            // [8..14] 保持 0，[15] = 1，[16] = 0
            packet[15] = 1
            packet[17] = (isFirst ? 0x10 : 0x00) | (isKeyframe ? 0x01 : 0x00) | (isLast ? 0x08 : 0x00)
            let frameTag = UInt16(1024 + Int(timestampMs & 1023))
            packet[18] = UInt8(frameTag >> 8)
            packet[19] = UInt8(frameTag & 0xFF)
            packet.replaceSubrange(20..<20 + chunkLen, with: bytes[offset..<offset + chunkLen])
            packets.append(packet)
            offset += chunkSize
        }
        return packets
    }
}

/// 5013 上的 RTCP 风格控制包（与主 App 的 RTCP 相同）
enum MirrorRTCP {
    /// 官方 iOS 心跳：RTCP APP，子类型 5，length=4（20 字节），app data = int32 0, int32 2
    static func heartbeat() -> Data {
        var d = Data(repeating: 0, count: 20)
        d[0] = 0x85          // V=2 | subtype=5
        d[1] = 0xCC          // PT=204 (APP)
        d[3] = 4             // length = 4 words → 20 字节
        d[19] = 2            // app data: [0, 2]（int32 大端连续）
        return d
    }

    /// 20 字节 ping：85 CC 00 04 + 8 个 0 + 序号(LE32) + 02 00 00 00
    static func ping(counter: UInt32) -> Data {
        var d = Data(repeating: 0, count: 20)
        d[0] = 0x85
        d[1] = 0xCC
        d[3] = 4
        d[12] = UInt8(counter & 0xFF)
        d[13] = UInt8((counter >> 8) & 0xFF)
        d[14] = UInt8((counter >> 16) & 0xFF)
        d[15] = UInt8((counter >> 24) & 0xFF)
        d[16] = 2
        return d
    }

    /// 校验 pong（只认 85 CC 00 04 + 长度 20）并取出序号。
    static func parsePong(_ data: Data) -> UInt32? {
        let b = [UInt8](data)
        guard b.count == 20, b[0] == 0x85, b[1] == 0xCC, b[2] == 0, b[3] == 4 else {
            return nil
        }
        return UInt32(b[12]) | (UInt32(b[13]) << 8) | (UInt32(b[14]) << 16) | (UInt32(b[15]) << 24)
    }
}
