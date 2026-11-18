import CommonCrypto
import CoreBluetooth
import Foundation
import os.log

/// 车辆蓝牙直连（Ninebot Max G2 / F2 / F2 Plus / F2 Pro，Encryption2）。
///
/// 协议来源：codeberg NootNooot/segway-ninebot-ble-cli（nb_crypto.py、
/// nb_protocol.py、boards.py），以及本仓库 research/ninebot-ble-protocol.md。
/// 只做 Enc2（Max G2/F2 系）；G30 的 55 AA + mible 协议、GT3 的板卡地址
/// 都不在这里。胎压不做——踢踏滑板车没有胎压传感器，协议里也没有这个
/// 寄存器，UI 上不要留胎压入口。
///
/// 帧（明文，加密前）：[5A A5 LEN 3E 目标 命令 索引 数据…]
///   LEN = 数据长度（len(data)，按 codeberg build_frame；研究文档 §2.1
///   的示例写的是 LEN=5，那是经典明文协议的算法——以 codeberg 为准，
///   它在真机上验证过；加密帧总长 = LEN + 13）。
///   响应：[5A A5 LEN 来源板 3E 命令 索引 数据…]，读数响应命令是 0x04。
///
/// 加密（Enc2，见 nb_crypto.py）：
///   密钥派生 key = SHA-1(pad16(key1) ‖ pad16(key2))[0:16]。
///   Non-SN（counter=0，仅 PRE_COMM）：密文 = 明文 XOR AES-ECB(key,
///   ecb_input)，同一 keystream 循环用；尾巴 6 字节 =
///   [00 00 校验和LE(2B) 00 00]，校验和 = ~(明文体各字节和) & 0xFFFF。
///   ecb_input 默认用 FW_DATA（97 CF B8 02 …，按任务要求和研究文档）；
///   但 codeberg 客户端对 Gen3（Max G2/F2）用全零，所以 PRE_COMM 失败
///   时自动改用全零再试一次——两种都试，真车上总有一个能通。
///   SN（counter>0）：AES-CCM 式。13 字节 nonce = counter 大端 4B +
///   authParam[0:8] + 00；A_i = 01‖nonce‖00‖i（i=0 加密 tag，i=1…
///   加密数据）；B_0 = 59‖nonce‖00‖payload_len；CBC-MAC =
///   AES(B0) → AES(X^pad16(头3B)) → 每 16B 明文块 AES(X^块)，取前 4B。
///   帧 = 头(3B) + 密文 + 加密 tag(4B) + counter 大端 2B。
///   注意：这里的 CTR 不是标准 AES-CTR（计数块是 CCM 式的 A_i），
///   所以不能直接用 CCCryptorCreateWithMode kCCModeCTR——必须按
///   codeberg 那样用单块 AES-ECB 生成 keystream 再 XOR。
///   CBC-MAC 同理是按块手算的 ECB 链（等价于零 IV 的 AES-CBC 取
///   最后一块前 4B），不是直接调 CBC 模式。
///
/// 握手（三阶段，目标都是 BLE 板 0x21）：
///   PRE_COMM (0x5B, 空数据) → 车回 authParam[16] + 序列号[14]，
///     响应 index：0 = 没存过密码；≠0 = 已存密码。
///     密钥：Gen3 = SHA-1(设备名 pad16 ‖ 零 pad16)，设备名就是
///     广播名（NB-xxxxxxxxxx），必须一字不差。
///   SET_PWD (0x5C, 16 字节密码) → index=1 接受；index=0 在等按
///     电源键，每 2 秒重试，最长 60 秒。
///     密钥：SHA-1(设备名 ‖ authParam)。
///     密码：Java LCG（java.util.Random，48 位）种子 = 当前毫秒 +
///     authParam 各字节按 Java int 语义移位求和，取 16 随机字节后
///     SHA-256 前 16 字节（codeberg generate_password）。
///   AUTH (0x5D, 14 字节 ASCII 序列号) → index=1 已认证。
///     密钥：SHA-1(密码 ‖ authParam)。
///     SN 模式从 PRE_COMM 之后开始（counter=1，第一次 SN 加密用 2）；
///     有已存密码时跳过 SET_PWD 直接 AUTH（此时 AUTH 的 counter=2）。
///     AUTH 失败 → 清掉已存密码、回到 SET_PWD（最多 5 次，每次换新密码）。
///
/// 密码来源（按顺序）：
///   (a) 官方 App 已存的会话密码：读官方 App 的 plist
///       Library/Preferences/com.ninebot.segway.plist（或 cn.ninebot…），
///       键名 {序列号}_decrypt，值是 Base64 的 16 字节。这需要越狱/
///       TrollStore 才能读到沙盒外面；读不到就安静地走 (b)，绝不崩。
///       用这个密码不影响官方 App 的配对（两边用同一个密码）。
///   (b) 自己存的密码（UserDefaults，按序列号存，首次 SET_PWD 生成的）。
///   (c) 都没有 → 首次 SET_PWD 配对（可能要按一下车上电源键）。
///   注意：SET_PWD 会覆盖官方 App 的密码，之后官方 App 要重新配对——
///   界面上要把这点写清楚。
///
/// 读数（小端，Max G2/F2：ctrl=0x20，bms=0x22）：
///   速度 ctrl idx 38 (2B, /10 = km/h)；电量 ctrl idx 34 (2B, %)；
///   电池电压 bms idx 52 (2B, /100 = V)；电池电流 bms idx 51
///   (2B, 有符号 /100 = A)。功率 = 电压 × 电流（没有直接寄存器）。
///   轮询：速度 + 电压/电流 每 500ms；电量每 2s。
///   电压/电流的 ÷100 换算和电流符号待真车确认（静止时电压应在 36–42V）。
///
/// 同步字节的提醒：如果 PRE_COMM 一直没回应，先检查广播名对不对，
/// 再试把下面的 sync2 改成 0xB5——codeberg 把 Gen3 的 sync2 写成
/// 0xB5（WiFi 才用 0xB5 的说法和它冲突），真车上以实测为准。
/// 同步字节只改这一处常量。

// MARK: - 常量

private enum VehicleBLEConstants {
    static let service = CBUUID(string: "6e400001-0000-0000-006e-696e65626f74")
    static let writeChar = CBUUID(string: "6e400002-0000-0000-006e-696e65626f74")
    static let notifyChar = CBUUID(string: "6e400004-0000-0000-006e-696e65626f74")
    static let namePrefix = "NB-"
    static let restoreID = "com.corpsezhao.ninebotcast.vehicleble"

    static let sync1: UInt8 = 0x5A
    static let sync2: UInt8 = 0xA5 // 见文件头：若 PRE_COMM 无回应，试 0xB5
    static let sourceByte: UInt8 = 0x3E // 手机

    static let boardBLE: UInt8 = 0x21 // 握手目标（Max G2/F2）
    static let boardCtrl: UInt8 = 0x20
    static let boardBMS: UInt8 = 0x22

    static let cmdRead: UInt8 = 0x01
    static let cmdReadResp: UInt8 = 0x04
    static let cmdPreComm: UInt8 = 0x5B
    static let cmdSetPwd: UInt8 = 0x5C
    static let cmdAuth: UInt8 = 0x5D

    static let regSpeed: UInt8 = 38     // ctrl，2B，/10 = km/h
    static let regBatteryPct: UInt8 = 34 // ctrl，2B，直接是 %
    static let regBMSVoltage: UInt8 = 52 // bms，2B，/100 = V
    static let regBMSCurrent: UInt8 = 51 // bms，2B，有符号 /100 = A

    // Gen2 的 non-SN ECB 输入（也是 Gen2 的 PRE_COMM key2）。
    // Gen3（Max G2/F2）的 key2 是全零；ecb_input 见文件头说明。
    static let fwData = Data([0x97, 0xCF, 0xB8, 0x02, 0x84, 0x41, 0x43, 0xDE,
                              0x56, 0x00, 0x2B, 0x3B, 0x34, 0x78, 0x0A, 0x5D])
    static let zero16 = Data(repeating: 0, count: 16)
}

// MARK: - 小工具（CommonCrypto 封装）

private func nbSHA1(_ data: Data) -> Data {
    var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
    data.withUnsafeBytes { ptr in
        _ = CC_SHA1(ptr.baseAddress, CC_LONG(data.count), &digest)
    }
    return Data(digest)
}

private func nbSHA256(_ data: Data) -> Data {
    var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    data.withUnsafeBytes { ptr in
        _ = CC_SHA256(ptr.baseAddress, CC_LONG(data.count), &digest)
    }
    return Data(digest)
}

/// 单块 AES-128-ECB 加密（16 字节进，16 字节出）。
private func nbAESECBEncrypt(key: Data, block: Data) -> Data? {
    guard key.count == 16, block.count == 16 else { return nil }
    var out = [UInt8](repeating: 0, count: 16)
    var outLen: Int = 0
    let status = key.withUnsafeBytes { kPtr in
        block.withUnsafeBytes { bPtr in
            CCCrypt(kCCEncrypt, kCCAlgorithmAES128, kCCOptionECBMode,
                    kPtr.baseAddress, key.count, nil,
                    bPtr.baseAddress, block.count,
                    &out, out.count, &outLen)
        }
    }
    guard status == kCCSuccess, outLen == 16 else { return nil }
    return Data(out)
}

/// 字节 XOR；b 短于 a 时循环用（non-SN 的 keystream 就是这么循环的）。
private func nbXOR(_ a: Data, _ b: Data) -> Data {
    guard !b.isEmpty else { return a }
    var out = Data(count: a.count)
    for i in 0..<a.count {
        out[i] = a[i] ^ b[i % b.count]
    }
    return out
}

private func nbPad16(_ data: Data) -> Data {
    if data.count >= 16 { return Data(data.prefix(16)) }
    var out = data
    out.append(Data(repeating: 0, count: 16 - data.count))
    return out
}

/// key = SHA-1(pad16(key1) ‖ pad16(key2))[0:16]（key2 为 nil 时按全零）。
private func nbDeriveKey(key1: Data, key2: Data?) -> Data {
    let sha = nbSHA1(nbPad16(key1) + nbPad16(key2 ?? Data()))
    return Data(sha.prefix(16))
}

private func nbDataFromHex(_ hex: String) -> Data? {
    guard hex.count % 2 == 0 else { return nil }
    var data = Data()
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
        data.append(byte)
        index = next
    }
    return data
}

// MARK: - Enc2 加密上下文（对应 nb_crypto.py 的 NbCrypto）

final class NbCrypto {
    private let lock = NSLock()
    private var key1 = Data()
    private var key2: Data?
    private var auth = Data(repeating: 0, count: 16)
    private var counter: Int = 0 // 0 = non-SN；>0 = SN
    private var ecbInput: Data

    init(ecbInput: Data) {
        self.ecbInput = nbPad16(ecbInput)
    }

    func setKey(key1: Data, key2: Data?) {
        lock.lock(); defer { lock.unlock() }
        self.key1 = key1
        self.key2 = key2
    }

    func setAuthParam(_ auth: Data) {
        lock.lock(); defer { lock.unlock() }
        self.auth = nbPad16(auth)
    }

    func setEcbInput(_ input: Data) {
        lock.lock(); defer { lock.unlock() }
        ecbInput = nbPad16(input)
    }

    /// 进入 SN 模式（counter=1，第一次 SN 加密用 2）。
    func startSN() {
        lock.lock(); defer { lock.unlock() }
        counter = 1
    }

    func resetSN() {
        lock.lock(); defer { lock.unlock() }
        counter = 0
    }

    private func aesKey() -> Data {
        nbDeriveKey(key1: key1, key2: key2)
    }

    /// 加密一帧明文。返回加密帧（明文长度 + 6 字节）。
    func encrypt(_ plaintext: Data) -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard plaintext.count >= 3 else { return nil }
        let key = aesKey()
        let header = Data(plaintext.prefix(3))
        if counter > 0 {
            return encryptSN(key: key, plaintext: plaintext, header: header)
        } else {
            return encryptNonSN(key: key, plaintext: plaintext, header: header)
        }
    }

    /// 解密一帧。返回（明文，rc）：rc=0 成功，1=MAC/校验和不符。
    func decrypt(_ cipherframe: Data) -> (Data, Int) {
        lock.lock(); defer { lock.unlock() }
        guard cipherframe.count >= 9 else { return (Data(), 1) }
        let key = aesKey()
        let header = Data(cipherframe.prefix(3))
        let tail = Data(cipherframe.suffix(6))
        let encBody = Data(cipherframe.dropFirst(3).dropLast(6))
        let recvCounter = (Int(tail[4]) << 8) | Int(tail[5])
        if recvCounter > 0 {
            return decryptSN(key: key, header: header, encBody: encBody, tail: tail, recvCounter: recvCounter)
        } else {
            return decryptNonSN(key: key, header: header, encBody: encBody, tail: tail)
        }
    }

    // MARK: nonce / A_i / B_0

    private func buildNonce(counter: Int, auth: Data) -> Data {
        var nonce = Data()
        var be32 = UInt32(counter).bigEndian
        nonce.append(Data(bytes: &be32, count: 4))
        nonce.append(auth.prefix(8))
        nonce.append(0)
        return nonce // 13 字节
    }

    private func buildABlock(nonce: Data, blockIndex: Int) -> Data {
        var a = Data()
        a.append(0x01)
        a.append(nonce)
        a.append(0)
        a.append(UInt8(blockIndex & 0xFF))
        return a // 16 字节
    }

    private func buildB0(nonce: Data, payloadLen: Int) -> Data {
        var b = Data()
        b.append(0x59)
        b.append(nonce)
        b.append(0)
        b.append(UInt8(payloadLen & 0xFF))
        return b // 16 字节
    }

    // MARK: CBC-MAC / CTR

    private func cbcMAC(key: Data, plaintext: Data, nonce: Data) -> Data? {
        let payloadLen = plaintext.count - 3
        guard var x = nbAESECBEncrypt(key: key, block: buildB0(nonce: nonce, payloadLen: payloadLen)) else {
            return nil
        }
        // 关联数据：帧头 3 字节，补零到 16
        var aad = Data(plaintext.prefix(3))
        aad.append(Data(repeating: 0, count: 13))
        guard let x2 = nbAESECBEncrypt(key: key, block: nbXOR(x, aad)) else { return nil }
        x = x2
        // 明文体每 16 字节一块（最后一块补零）
        let payload = Data(plaintext.dropFirst(3))
        var offset = 0
        while offset < payload.count {
            var block = Data(payload.dropFirst(offset).prefix(16))
            if block.count < 16 {
                block.append(Data(repeating: 0, count: 16 - block.count))
            }
            guard let x3 = nbAESECBEncrypt(key: key, block: nbXOR(x, block)) else { return nil }
            x = x3
            offset += 16
        }
        return Data(x.prefix(4))
    }

    private func ctrXOR(key: Data, data: Data, nonce: Data, startBlock: Int) -> Data? {
        var out = Data()
        var blockIndex = startBlock
        var offset = 0
        while offset < data.count {
            guard let keystream = nbAESECBEncrypt(key: key, block: buildABlock(nonce: nonce, blockIndex: blockIndex)) else {
                return nil
            }
            let chunkLen = min(16, data.count - offset)
            let chunk = Data(data.dropFirst(offset).prefix(chunkLen))
            out.append(nbXOR(chunk, keystream))
            offset += chunkLen
            blockIndex += 1
        }
        return out
    }

    // MARK: SN / non-SN 编解码

    private func encryptSN(key: Data, plaintext: Data, header: Data) -> Data? {
        counter += 1
        let ctr = counter
        let nonce = buildNonce(counter: ctr, auth: auth)
        guard let rawTag = cbcMAC(key: key, plaintext: plaintext, nonce: nonce) else { return nil }
        guard let ciphertext = ctrXOR(key: key, data: Data(plaintext.dropFirst(3)), nonce: nonce, startBlock: 1) else {
            return nil
        }
        guard let a0 = nbAESECBEncrypt(key: key, block: buildABlock(nonce: nonce, blockIndex: 0)) else { return nil }
        let encTag = nbXOR(rawTag, Data(a0.prefix(4)))
        var out = Data()
        out.append(header)
        out.append(ciphertext)
        out.append(encTag)
        var be16 = UInt16(ctr & 0xFFFF).bigEndian
        out.append(Data(bytes: &be16, count: 2))
        return out
    }

    private func encryptNonSN(key: Data, plaintext: Data, header: Data) -> Data? {
        let payload = Data(plaintext.dropFirst(3))
        let sum = payload.reduce(0) { $0 + Int($1) }
        let checksum = (~sum) & 0xFFFF
        guard let keystream = nbAESECBEncrypt(key: key, block: ecbInput) else { return nil }
        let ciphertext = nbXOR(payload, keystream)
        var out = Data()
        out.append(header)
        out.append(ciphertext)
        out.append(contentsOf: [0x00, 0x00,
                                UInt8(checksum & 0xFF), UInt8((checksum >> 8) & 0xFF),
                                0x00, 0x00])
        return out
    }

    private func decryptSN(key: Data, header: Data, encBody: Data, tail: Data, recvCounter: Int) -> (Data, Int) {
        let nonce = buildNonce(counter: recvCounter, auth: auth)
        guard let plainPayload = ctrXOR(key: key, data: encBody, nonce: nonce, startBlock: 1) else {
            return (Data(), 1)
        }
        guard let a0 = nbAESECBEncrypt(key: key, block: buildABlock(nonce: nonce, blockIndex: 0)) else {
            return (Data(), 1)
        }
        let encTag = Data(tail.prefix(4))
        let recvTag = nbXOR(encTag, Data(a0.prefix(4)))
        var plaintext = Data()
        plaintext.append(header)
        plaintext.append(plainPayload)
        guard let expectedTag = cbcMAC(key: key, plaintext: plaintext, nonce: nonce) else {
            return (plaintext, 1)
        }
        if recvTag != expectedTag {
            return (plaintext, 1)
        }
        return (plaintext, 0)
    }

    private func decryptNonSN(key: Data, header: Data, encBody: Data, tail: Data) -> (Data, Int) {
        guard let keystream = nbAESECBEncrypt(key: key, block: ecbInput) else { return (Data(), 1) }
        let payload = nbXOR(encBody, keystream)
        var plaintext = Data()
        plaintext.append(header)
        plaintext.append(payload)
        let sum = payload.reduce(0) { $0 + Int($1) }
        let expected = (~sum) & 0xFFFF
        let recv = Int(tail[2]) | (Int(tail[3]) << 8)
        if expected != recv {
            return (plaintext, 1)
        }
        return (plaintext, 0)
    }
}

// MARK: - Java LCG（java.util.Random，48 位）+ 密码生成

/// 对应 nb_crypto.py 的 JavaRandom：seed=(seed^0x5DEECE66D)&((1<<48)-1)，
/// 每步 seed=(seed*0x5DEECE66D+0xB)&((1<<48)-1)，取高位。
/// Swift 的 * / + 会在溢出时 trap，所以这里全用 UInt64 + &* / &+。
struct JavaRandom {
    private var seed: UInt64
    private static let mask: UInt64 = (1 << 48) - 1
    private static let mult: UInt64 = 0x5DEECE66D
    private static let add: UInt64 = 0xB

    init(seed: Int64) {
        self.seed = (UInt64(bitPattern: seed) ^ Self.mult) & Self.mask
    }

    private mutating func next(bits: Int) -> UInt32 {
        seed = (seed &* Self.mult &+ Self.add) & Self.mask
        return UInt32(seed >> (48 - bits))
    }

    mutating func nextInt() -> UInt32 {
        next(bits: 32)
    }

    /// 对应 Java 的 nextBytes：每 4 字节取一个 nextInt()，小端拆开。
    mutating func nextBytes(count: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: count)
        var i = 0
        while i < count {
            let rnd = nextInt()
            for j in 0..<min(4, count - i) {
                out[i] = UInt8((rnd >> (8 * j)) & 0xFF)
                i += 1
            }
        }
        return out
    }
}

/// 密码生成（codeberg generate_password，源自官方 App）：
/// seed = 当前毫秒 + auth 各字节按 Java int 语义移位求和
/// （字节先当有符号 byte，移位量 (i%8)*8，Java int 移位只取低 5 位）；
/// 随机 16 字节后 SHA-256 前 16 字节即密码。
func nbGeneratePassword(auth: Data, timeMs: Int64? = nil) -> Data {
    let ms = timeMs ?? Int64(Date().timeIntervalSince1970 * 1000)
    var j: Int64 = 0
    for (i, b) in auth.prefix(16).enumerated() {
        let sb = Int32(Int8(bitPattern: b)) // Java 有符号 byte
        let shift = (i % 8) * 8
        let val = sb &<< (shift & 31) // Java int 移位（&<< 不 trap）
        j = j &+ Int64(val) // Java long 累加（回绕）
    }
    let seed = ms &+ j
    var rng = JavaRandom(seed: seed)
    let randomBytes = rng.nextBytes(count: 16)
    let sha = nbSHA256(Data(randomBytes))
    return Data(sha.prefix(16))
}

// MARK: - 帧构造 / 解析（对应 nb_protocol.py）

struct NbFrame {
    var length: Int // LEN 字段 = 数据长度
    var boardID: Int // 响应里是来源板卡
    var cmd: Int
    var index: Int
    var data: Data
}

/// 明文帧：[5A A5 LEN 3E 目标 命令 索引 数据…]，LEN = len(data)。
func nbBuildFrame(target: UInt8, cmd: UInt8, index: UInt8, data: Data) -> Data {
    var frame = Data()
    frame.append(contentsOf: [VehicleBLEConstants.sync1, VehicleBLEConstants.sync2,
                              UInt8(data.count & 0xFF), VehicleBLEConstants.sourceByte,
                              target, cmd, index])
    frame.append(data)
    return frame
}

/// 解析解密后的帧。接收端两个 sync2（0xA5/0xB5）都接受，发送只用 0xA5。
func nbParseFrame(_ decrypted: Data) -> NbFrame? {
    guard decrypted.count >= 7 else { return nil }
    guard decrypted[0] == VehicleBLEConstants.sync1,
          (decrypted[1] == 0xA5 || decrypted[1] == 0xB5) else { return nil }
    guard decrypted[4] == VehicleBLEConstants.sourceByte else { return nil }
    let length = Int(decrypted[2])
    let boardID = Int(decrypted[3])
    let cmd = Int(decrypted[5])
    let index = Int(decrypted[6])
    let dataEnd = min(7 + length, decrypted.count)
    let data = Data(decrypted[7..<dataEnd])
    return NbFrame(length: length, boardID: boardID, cmd: cmd, index: index, data: data)
}

// MARK: - BLE 客户端（app target 专用）

enum VehicleBLEError: Error, LocalizedError {
    case bluetoothOff
    case notConnected
    case timeout
    case cryptoFailed
    case invalidResponse
    case echoRejected // 车把帧原样打回来了（密钥/设备名不对）
    case authFailed
    case setPwdFailed(String)

    /// 注意：必须叫 errorDescription（LocalizedError）——直接写
    /// localizedDescription 的话，被当作 Error 用时拿不到自定义文案。
    var errorDescription: String? {
        switch self {
        case .bluetoothOff: return "蓝牙未开启"
        case .notConnected: return "还没连上滑板车"
        case .timeout: return "车没回应（超时）"
        case .cryptoFailed: return "加密失败"
        case .invalidResponse: return "车回的数据不对"
        case .echoRejected: return "车拒绝了握手（广播名可能不对）"
        case .authFailed: return "认证失败"
        case .setPwdFailed(let msg): return msg
        }
    }
}

/// 车辆蓝牙客户端：扫描 NB-* 设备 → Enc2 握手 → 每 500ms 读速度/电压/
/// 电流，每 2s 读电量。读到的值一方面给 App 内的车辆卡片（完整精度），
/// 另一方面通过 VehicleDataRelay（Darwin 通知）发给广播扩展画 HUD。
///
/// 线程：所有 CoreBluetooth 回调都在 bleQueue 上；握手/轮询是 async
/// Task（不阻塞 bleQueue，否则通知回调进不来会死锁）。@Published 只在
/// 主线程更新；读数值先存到带锁的私有变量，轮询循环里统一发布。
final class VehicleBLE: NSObject, ObservableObject {
    // MARK: - 发布给 UI 的状态
    @Published var status: String = "未连接"
    @Published var isConnected = false
    @Published var isAuthenticated = false
    @Published var deviceName: String?
    @Published var serial: String?
    @Published var speedKmh: Double?
    @Published var voltageV: Double?
    @Published var currentA: Double?
    @Published var powerW: Double?
    @Published var batteryPct: Int?

    // MARK: - BLE
    private let bleQueue = DispatchQueue(label: "com.corpsezhao.ninebotcast.vehicleble")
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?
    private var isConnecting = false

    // MARK: - 协议状态
    private let crypto = NbCrypto(ecbInput: VehicleBLEConstants.fwData)
    private var rxBuffer = Data()
    private let frameLock = NSLock()
    private var pendingCont: CheckedContinuation<NbFrame, Error>?
    private var pendingTimeout: DispatchWorkItem?
    private var pendingExpectCmd: Int?
    private var pendingExpectIndex: Int?
    private var btName = ""
    private var authParam = Data()
    private var serialData = Data()
    private var handshakeTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?

    // MARK: - 最新读数（带锁；轮询循环和断开流程都会碰）
    private let valuesLock = NSLock()
    private var _speedKmh: Double?
    private var _voltageV: Double?
    private var _currentA: Double?
    private var _powerW: Double?
    private var _batteryPct: Int?

    private let log = Logger(subsystem: "com.corpsezhao.ninebotcast", category: "vehicleble")

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: bleQueue, options: [
            CBCentralManagerOptionRestoreIdentifierKey: VehicleBLEConstants.restoreID,
            CBCentralManagerOptionShowPowerAlertKey: true
        ])
    }

    // MARK: - 连接 / 断开（UI 调）

    func connect() {
        bleQueue.async { [weak self] in
            guard let self else { return }
            guard peripheral == nil, !isConnecting else { return }
            guard central.state == .poweredOn else {
                switch central.state {
                case .poweredOff: setStatus("蓝牙未开启")
                case .unauthorized: setStatus("蓝牙权限未开（去设置里允许）")
                case .unsupported: setStatus("此设备不支持蓝牙")
                default: setStatus("蓝牙未就绪，稍后再试")
                }
                return
            }
            // 优先接管系统里已连着的九号设备（比如官方 App 退出后留下的连接）
            let connected = central.retrieveConnectedPeripherals(withServices: [VehicleBLEConstants.service])
            if let p = connected.first {
                self.peripheral = p
                self.btName = p.name ?? ""
                p.delegate = self
                setStatus("已连上 \(self.btName)，正在握手…")
                central.connect(p, options: nil)
                return
            }
            isConnecting = true
            setStatus("正在扫描滑板车…")
            central.scanForPeripherals(withServices: [VehicleBLEConstants.service], options: nil)
            // 15 秒还没找到就停扫（别一直耗电）
            bleQueue.asyncAfter(deadline: .now() + 15) { [weak self] in
                guard let self, isConnecting, peripheral == nil else { return }
                central.stopScan()
                isConnecting = false
                setStatus("没找到滑板车（请确认车已开机、在附近）")
            }
        }
    }

    func disconnect() {
        bleQueue.async { [weak self] in
            guard let self else { return }
            pollTask?.cancel()
            pollTask = nil
            handshakeTask?.cancel()
            handshakeTask = nil
            if let p = peripheral {
                central.cancelPeripheralConnection(p)
            }
            central.stopScan()
            isConnecting = false
            peripheral = nil
            writeChar = nil
            notifyChar = nil
            rxBuffer = Data()
            crypto.resetSN()
            clearValues()
            VehicleDataRelay.clear()
            publishConnected(false, authenticated: false)
            setStatus("已断开")
        }
    }

    // MARK: - 内部小工具

    private func setStatus(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            self?.status = text
        }
        log.info("vehicle: \(text)")
    }

    private func publishConnected(_ connected: Bool, authenticated: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isConnected = connected
            self.isAuthenticated = authenticated
            if !connected {
                self.speedKmh = nil
                self.voltageV = nil
                self.currentA = nil
                self.powerW = nil
                self.batteryPct = nil
            }
        }
    }

    private func clearValues() {
        valuesLock.lock(); defer { valuesLock.unlock() }
        _speedKmh = nil
        _voltageV = nil
        _currentA = nil
        _powerW = nil
        _batteryPct = nil
    }

    /// 一轮读数结束统一发布：更新 @Published + 发给扩展的 Darwin 通知。
    private func setLatest(speed: Double?, voltage: Double?, current: Double?, battery: Int?) {
        valuesLock.lock()
        if let speed { _speedKmh = speed }
        if let voltage { _voltageV = voltage }
        if let current { _currentA = current }
        if let battery { _batteryPct = battery }
        if let v = _voltageV, let c = _currentA {
            _powerW = v * c
        }
        let snap = (_speedKmh, _voltageV, _currentA, _powerW, _batteryPct)
        valuesLock.unlock()
        if let s = snap.0, let v = snap.1, let c = snap.2, let p = snap.3 {
            VehicleDataRelay.update(speedKmh: s, voltageV: v, currentA: c, powerW: p)
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.speedKmh = snap.0
            self.voltageV = snap.1
            self.currentA = snap.2
            self.powerW = snap.3
            self.batteryPct = snap.4
        }
    }

    // MARK: - 收发帧

    /// 分片写（MTU 23 → 每段 20 字节；段间 10ms，避免被静默截断）。
    private func sendFragmented(_ data: Data) async throws {
        guard let peripheral, let writeChar else { throw VehicleBLEError.notConnected }
        let chunkSize = max(20, peripheral.maximumWriteValueLength(for: .withoutResponse))
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            peripheral.writeValue(Data(data[offset..<end]), for: writeChar, type: .withoutResponse)
            offset = end
            if offset < data.count {
                try await Task.sleep(nanoseconds: 10_000_000) // 10ms
            }
        }
    }

    /// 发一帧明文，等一帧响应（按命令、必要时按索引匹配）。
    /// 注意：先发后等——车最快也要几毫秒才回，中间没有帧会丢；
    /// 不合期望的帧（或解密失败的帧）直接丢掉，等超时。
    private func sendAndWait(_ plaintext: Data, expectCmd: Int?, expectIndex: Int?, timeout: TimeInterval) async throws -> NbFrame {
        guard let encrypted = crypto.encrypt(plaintext) else {
            throw VehicleBLEError.cryptoFailed
        }
        try await sendFragmented(encrypted)
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<NbFrame, Error>) in
            frameLock.lock()
            pendingCont = cont
            pendingExpectCmd = expectCmd
            pendingExpectIndex = expectIndex
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.frameLock.lock()
                if let c = self.pendingCont {
                    self.pendingCont = nil
                    self.pendingExpectCmd = nil
                    self.pendingExpectIndex = nil
                    self.pendingTimeout = nil
                    self.frameLock.unlock()
                    c.resume(throwing: VehicleBLEError.timeout)
                } else {
                    self.frameLock.unlock()
                }
            }
            pendingTimeout = work
            frameLock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: work)
        }
    }

    /// 通知里的数据攒起来，按 5A + sync2 找帧头，LEN + 13 攒满一帧再交。
    private func extractFrames() {
        while rxBuffer.count >= 3 {
            var start: Int? = nil
            for i in 0..<(rxBuffer.count - 1) {
                if rxBuffer[i] == VehicleBLEConstants.sync1
                    && (rxBuffer[i + 1] == 0xA5 || rxBuffer[i + 1] == 0xB5) {
                    start = i
                    break
                }
            }
            guard let s = start else {
                // 没有同步头：只保留末尾一个 0x5A（可能是下个帧头的开头）
                if rxBuffer.last == VehicleBLEConstants.sync1 {
                    rxBuffer = Data([VehicleBLEConstants.sync1])
                } else {
                    rxBuffer = Data()
                }
                return
            }
            if s > 0 {
                rxBuffer.removeFirst(s)
            }
            guard rxBuffer.count >= 3 else { return }
            let total = Int(rxBuffer[2]) + 13
            guard rxBuffer.count >= total else { return } // 还没攒满，等下一段
            let frame = Data(rxBuffer.prefix(total))
            rxBuffer.removeFirst(total)
            deliverFrame(frame)
        }
    }

    private func deliverFrame(_ encryptedFrame: Data) {
        let (plain, rc) = crypto.decrypt(encryptedFrame)
        guard rc == 0 else {
            log.info("vehicle: 丢弃解密失败的帧 (rc=\(rc))")
            return
        }
        guard let frame = nbParseFrame(plain) else {
            log.info("vehicle: 丢弃无法解析的帧")
            return
        }
        frameLock.lock()
        guard let cont = pendingCont else {
            frameLock.unlock()
            return // 没人在等（比如轮询间隙的重复帧），直接丢
        }
        if let expectCmd = pendingExpectCmd, frame.cmd != expectCmd {
            frameLock.unlock()
            return
        }
        if let expectIndex = pendingExpectIndex, frame.index != expectIndex {
            frameLock.unlock()
            return
        }
        pendingCont = nil
        pendingTimeout?.cancel()
        pendingTimeout = nil
        pendingExpectCmd = nil
        pendingExpectIndex = nil
        frameLock.unlock()
        cont.resume(returning: frame)
    }

    // MARK: - 握手

    private func startHandshake() {
        handshakeTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.handshake()
                self.publishConnected(true, authenticated: true)
                self.setStatus("已认证，正在读数…")
                self.startPolling()
            } catch {
                if Task.isCancelled { return }
                self.setStatus("握手失败：\(error.localizedDescription)")
                self.log.error("vehicle: 握手失败 \(error.localizedDescription)")
            }
        }
    }

    private func handshake() async throws {
        let (auth, sn) = try await preComm()
        authParam = auth
        serialData = preCommSerialData // AUTH 要用 PRE_COMM 的原始字节
        DispatchQueue.main.async { [weak self] in self?.serial = sn }

        var password = readOfficialAppPassword(serial: sn) ?? storedPassword(serial: sn)
        var setPwdAttempts = 0
        while setPwdAttempts < 5 {
            if let pwd = password {
                do {
                    if try await doAuth(password: pwd, snData: serialData) {
                        savePassword(pwd, serial: sn)
                        return // 已认证
                    }
                } catch {
                    throw error // 超时/通信问题：直接失败，别拿错密码去 SET_PWD
                }
                // AUTH 明确拒绝（index≠1）：密码不对，清掉，走 SET_PWD
                clearStoredPassword(serial: sn)
                password = nil
            }
            setPwdAttempts += 1
            let newPwd = nbGeneratePassword(auth: auth)
            do {
                try await doSetPwd(password: newPwd)
            } catch {
                throw VehicleBLEError.setPwdFailed("配对失败：请按一下车上的电源键，再点连接重试")
            }
            password = newPwd
        }
        throw VehicleBLEError.authFailed
    }

    // preComm 的序列号原始字节（AUTH 要用原始字节，不能用重编码的字符串）
    private var preCommSerialData = Data()

    /// PRE_COMM：拿 authParam[16] + 序列号[14]，顺带进入 SN 模式。
    /// 先用 FW_DATA 作 ecb_input，失败再用全零试一次（codeberg Gen3 用零）。
    private func preComm() async throws -> (auth: Data, sn: String) {
        let inputs: [Data] = [VehicleBLEConstants.fwData, VehicleBLEConstants.zero16]
        var lastError: Error = VehicleBLEError.timeout
        for input in inputs {
            crypto.setEcbInput(input)
            crypto.resetSN()
            crypto.setKey(key1: Data(btName.utf8), key2: nil)
            let frame = nbBuildFrame(target: VehicleBLEConstants.boardBLE,
                                     cmd: VehicleBLEConstants.cmdPreComm,
                                     index: 0, data: Data())
            do {
                let resp = try await sendAndWait(frame,
                                                 expectCmd: Int(VehicleBLEConstants.cmdPreComm),
                                                 expectIndex: nil, timeout: 5)
                if resp.data.isEmpty {
                    // 车把帧原样打回来了：密钥（设备名）或加密参数不对
                    throw VehicleBLEError.echoRejected
                }
                guard resp.data.count >= 30 else {
                    throw VehicleBLEError.invalidResponse
                }
                let auth = Data(resp.data.prefix(16))
                let snData = Data(resp.data[16..<30])
                let sn = String(bytes: snData, encoding: .ascii) ?? ""
                crypto.setAuthParam(auth)
                crypto.startSN()
                preCommSerialData = snData
                log.info("vehicle: PRE_COMM 成功（ecb=\(input == VehicleBLEConstants.fwData ? "FW_DATA" : "zeros")），序列号 \(sn)，已存密码=\(resp.index != 0)")
                return (auth, sn)
            } catch {
                lastError = error
                log.info("vehicle: PRE_COMM 失败（ecb=\(input == VehicleBLEConstants.fwData ? "FW_DATA" : "zeros")）：\(error.localizedDescription)")
            }
        }
        throw lastError
    }

    /// SET_PWD：把新密码写进车。index=0 是在等按电源键，每 2 秒重试，
    /// 最长 60 秒。注意这会覆盖官方 App 的密码（之后官方 App 要重配对）。
    /// （codeberg 客户端是发一次等 60 秒收第二条响应；这里按任务要求
    /// 每 2 秒重发——重发是幂等的，车在按钮按下后对重发回 index=1；
    /// 如果重发反而坏了事，改成“发一次，等 60 秒收第二条响应”。）
    private func doSetPwd(password: Data) async throws {
        crypto.setKey(key1: Data(btName.utf8), key2: authParam)
        let frame = nbBuildFrame(target: VehicleBLEConstants.boardBLE,
                                 cmd: VehicleBLEConstants.cmdSetPwd,
                                 index: 0, data: password)
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            if Task.isCancelled { throw CancellationError() }
            do {
                let resp = try await sendAndWait(frame,
                                                 expectCmd: Int(VehicleBLEConstants.cmdSetPwd),
                                                 expectIndex: nil, timeout: 2)
                if resp.index == 1 {
                    log.info("vehicle: SET_PWD 已接受")
                    return
                }
                setStatus("请按一下车上的电源键…")
            } catch VehicleBLEError.timeout {
                // 2 秒没回音：车可能在等按键，继续重试
                setStatus("请按一下车上的电源键…")
            }
        }
        throw VehicleBLEError.setPwdFailed("配对超时")
    }

    /// AUTH：14 字节 ASCII 序列号。index=1 即已认证。
    /// 注意：有已存密码时直接 AUTH，这是第一帧 SN 帧（counter=2）。
    private func doAuth(password: Data, snData: Data) async throws -> Bool {
        crypto.setKey(key1: password, key2: authParam)
        let frame = nbBuildFrame(target: VehicleBLEConstants.boardBLE,
                                 cmd: VehicleBLEConstants.cmdAuth,
                                 index: 0, data: snData)
        let resp = try await sendAndWait(frame,
                                         expectCmd: Int(VehicleBLEConstants.cmdAuth),
                                         expectIndex: nil, timeout: 5)
        log.info("vehicle: AUTH 响应 index=\(resp.index)")
        return resp.index == 1
    }

    // MARK: - 轮询读数

    private func startPolling() {
        pollTask = Task { [weak self] in
            guard let self else { return }
            var cycle = 0
            while !Task.isCancelled {
                cycle += 1
                let speed = try? await self.readU16(target: VehicleBLEConstants.boardCtrl,
                                                    index: VehicleBLEConstants.regSpeed)
                if Task.isCancelled { break }
                let volt = try? await self.readU16(target: VehicleBLEConstants.boardBMS,
                                                   index: VehicleBLEConstants.regBMSVoltage)
                if Task.isCancelled { break }
                let cur = try? await self.readS16(target: VehicleBLEConstants.boardBMS,
                                                  index: VehicleBLEConstants.regBMSCurrent)
                var battery: Int? = nil
                if cycle % 4 == 0 {
                    if let pct = try? await self.readU16(target: VehicleBLEConstants.boardCtrl,
                                                         index: VehicleBLEConstants.regBatteryPct) {
                        battery = Int(pct)
                    }
                }
                self.setLatest(speed: speed.map { Double($0) / 10.0 },
                               voltage: volt.map { Double($0) / 100.0 },
                               current: cur.map { Double($0) / 100.0 },
                               battery: battery)
                try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
            }
        }
    }

    private func readU16(target: UInt8, index: UInt8) async throws -> UInt16 {
        let frame = nbBuildFrame(target: target, cmd: VehicleBLEConstants.cmdRead,
                                 index: index, data: Data([0x02]))
        let resp = try await sendAndWait(frame,
                                         expectCmd: Int(VehicleBLEConstants.cmdReadResp),
                                         expectIndex: Int(index), timeout: 2)
        guard resp.data.count >= 2 else { throw VehicleBLEError.invalidResponse }
        return UInt16(resp.data[0]) | (UInt16(resp.data[1]) << 8)
    }

    private func readS16(target: UInt8, index: UInt8) async throws -> Int16 {
        let u = try await readU16(target: target, index: index)
        return Int16(bitPattern: u)
    }

    // MARK: - 密码来源

    /// 官方 App 已存的会话密码：{序列号}_decrypt，Base64 16 字节。
    /// 只有越狱/TrollStore 能读到沙盒外面；读不到就返回 nil（走 SET_PWD）。
    private func readOfficialAppPassword(serial: String) -> Data? {
        let fm = FileManager.default
        let candidates = ["com.ninebot.segway.plist", "cn.ninebot.segway.plist"]
        // 1）上次找到的路径（缓存）
        if let cached = UserDefaults.standard.string(forKey: "nbc.vehicle.officialPlistPath"),
           fm.fileExists(atPath: cached),
           let pwd = passwordFromPlist(path: cached, serial: serial) {
            log.info("vehicle: 官方 App 密码已读出（缓存路径）")
            return pwd
        }
        // 2）枚举应用容器找官方 App 的 plist
        let containers = "/var/mobile/Containers/Data/Application"
        guard let apps = try? fm.contentsOfDirectory(atPath: containers) else {
            log.info("vehicle: 读不到应用容器目录（未越狱或无权限），跳过官方 App 密码")
            return nil
        }
        for app in apps {
            for name in candidates {
                let path = "\(containers)/\(app)/Library/Preferences/\(name)"
                if fm.fileExists(atPath: path) {
                    UserDefaults.standard.set(path, forKey: "nbc.vehicle.officialPlistPath")
                    if let pwd = passwordFromPlist(path: path, serial: serial) {
                        log.info("vehicle: 官方 App 密码已读出（\(name)）")
                        return pwd
                    }
                    log.info("vehicle: 找到官方 App plist，但里面没有这个序列号的密码")
                    return nil
                }
            }
        }
        log.info("vehicle: 没找到官方 App 的 plist")
        return nil
    }

    private func passwordFromPlist(path: String, serial: String) -> Data? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: &format) as? [String: Any] else {
            return nil
        }
        guard let value = plist["\(serial)_decrypt"] else { return nil }
        if let str = value as? String {
            guard let decoded = Data(base64Encoded: str), decoded.count == 16 else { return nil }
            return decoded
        }
        if let bin = value as? Data, bin.count == 16 {
            return bin
        }
        return nil
    }

    /// 自己首次配对生成的密码（UserDefaults，按序列号存 16 进制串）。
    private func storedPassword(serial: String) -> Data? {
        guard let hex = UserDefaults.standard.string(forKey: "nbc.vehicle.pwd.\(serial)") else {
            return nil
        }
        return nbDataFromHex(hex)
    }

    private func savePassword(_ pwd: Data, serial: String) {
        let hex = pwd.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(hex, forKey: "nbc.vehicle.pwd.\(serial)")
    }

    private func clearStoredPassword(serial: String) {
        UserDefaults.standard.removeObject(forKey: "nbc.vehicle.pwd.\(serial)")
    }
}

// MARK: - CBCentralManagerDelegate / CBPeripheralDelegate

extension VehicleBLE: CBCentralManagerDelegate, CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOff:
            setStatus("蓝牙未开启")
        case .unauthorized:
            setStatus("蓝牙权限未开（去设置里允许）")
        case .unsupported:
            setStatus("此设备不支持蓝牙")
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        log.info("vehicle: BLE 状态恢复")
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
           let p = peripherals.first {
            self.peripheral = p
            self.btName = p.name ?? ""
            p.delegate = self
            if p.state == .connected {
                setStatus("正在恢复蓝牙连接…")
                p.discoverServices([VehicleBLEConstants.service])
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? ""
        guard name.hasPrefix(VehicleBLEConstants.namePrefix) else { return }
        // 第一个 NB-* 就连（附近一般只有一辆车）
        central.stopScan()
        isConnecting = false
        self.peripheral = peripheral
        self.btName = name
        peripheral.delegate = self
        setStatus("找到 \(name)，正在连接…")
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        setStatus("已连接，正在发现服务…")
        publishConnected(true, authenticated: false)
        peripheral.discoverServices([VehicleBLEConstants.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        isConnecting = false
        self.peripheral = nil
        setStatus("连接失败（先彻底退出九号出行再试）")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        pollTask?.cancel()
        pollTask = nil
        handshakeTask?.cancel()
        handshakeTask = nil
        self.peripheral = nil
        writeChar = nil
        notifyChar = nil
        rxBuffer = Data()
        crypto.resetSN()
        clearValues()
        VehicleDataRelay.clear()
        publishConnected(false, authenticated: false)
        if let error {
            setStatus("已断开（\(error.localizedDescription)）")
        } else {
            setStatus("已断开")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let services = peripheral.services,
              let svc = services.first(where: { $0.uuid == VehicleBLEConstants.service }) else {
            setStatus("没找到九号蓝牙服务")
            return
        }
        peripheral.discoverCharacteristics([VehicleBLEConstants.writeChar,
                                            VehicleBLEConstants.notifyChar], for: svc)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil, let chars = service.characteristics else {
            setStatus("没找到蓝牙特征")
            return
        }
        writeChar = chars.first(where: { $0.uuid == VehicleBLEConstants.writeChar })
        notifyChar = chars.first(where: { $0.uuid == VehicleBLEConstants.notifyChar })
        guard let writeChar, let notifyChar else {
            setStatus("没找到读写特征")
            return
        }
        // 重连时先关通知 → 等 300ms → 再开（iOS 残留的 CCCD 会让订阅失效）；
        // 开通知后先清空接收缓冲，丢掉陈旧帧。
        peripheral.setNotifyValue(false, for: notifyChar)
        bleQueue.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.peripheral === peripheral else { return }
            peripheral.setNotifyValue(true, for: notifyChar)
        }
        _ = writeChar
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == VehicleBLEConstants.notifyChar else { return }
        if characteristic.isNotifying {
            rxBuffer = Data()
            setStatus("正在握手…")
            startHandshake()
        } else if let error {
            setStatus("订阅通知失败：\(error.localizedDescription)")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == VehicleBLEConstants.notifyChar,
              error == nil,
              let data = characteristic.value, !data.isEmpty else { return }
        rxBuffer.append(data)
        extractFrames()
    }
}
