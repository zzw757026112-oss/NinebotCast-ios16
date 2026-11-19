import Combine
import CoreBluetooth
import Foundation

/// ANT BMS（MAYI/JNFN）电池数据：朋友那辆换了锂电池的车。
///
/// 只针对新格式 7E A1 帧的 ANT BMS，不兼容老 AA55AAFF 格式和
/// 其他品牌（JK/Daly/JBD 是不同协议）。只编进主 App（Sources/），
/// 扩展进程绝不能建 CBCentralManager——数据靠 ANTBMSRelay 中继。
///
/// 链路：扫描 FFE0 服务 → 连最强信号的一台 → 发现 FFE0/FFE1 →
/// 订阅 Notify → 写 DBDB00000000，每 2 秒重发轮询。
/// 帧格式（已验证，见文件底 parseFrame）：头 7E A1 11 00 00 A8，
/// 尾 F3 00 AA 55；电芯电压 @34（2N 字节），6 个温度 @34+2N，
/// 总电压 @46+2N ÷100，电流 @48+2N ÷10（放电为正），
/// SOC @52+2N ÷10；功率 = 电压 × 电流。
struct ANTBMSData: Equatable {
    var voltage: Float // 总电压 V
    var current: Float // 电流 A（放电为正）
    var power: Float // 功率 W = 电压 × 电流
    var soc: Float // SOC %
    var temps: [Int] // 6 个温度传感器原始值 °C（对应关系未确认，不猜）
    var cellCount: Int // 电芯数 N
    var cellMin: Int // 最低电芯 mV
    var cellMax: Int // 最高电芯 mV
    var cellAvg: Int // 平均电芯 mV
    var cellDelta: Int // 压差 mV（max - min）
    var minCellIndex: Int // 最低电芯节号（1-based）
    var maxCellIndex: Int // 最高电芯节号（1-based）
    var updatedAt: Date
}

final class ANTBMS: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let shared = ANTBMS()

    /// 开关默认 OFF，MainView 的“电池 BMS (ANT)”卡片控制。
    @Published var isEnabled = false {
        didSet {
            if isEnabled { start() } else { stop() }
        }
    }
    @Published private(set) var snapshot: ANTBMSData?
    @Published private(set) var deviceName: String?
    @Published private(set) var rssi: Int?
    @Published private(set) var isConnected = false
    @Published private(set) var isScanning = false
    @Published private(set) var lastError: String?
    // 诊断（1.2.1：1.2.0 实测只显示“已连接”，没数据也不报错，
    // 不知道卡在哪一步——这些字段让卡片直接说出来）。
    @Published private(set) var stage = "未启用"
    @Published private(set) var pollCount = 0
    @Published private(set) var rxBytes = 0
    @Published private(set) var notifyOn = false
    @Published private(set) var lastFrameInfo: String?
    @Published private(set) var lastRxAt: Date?

    private static let serviceUUID = CBUUID(string: "FFE0")
    private static let cmdUUID = CBUUID(string: "FFE1")
    /// 读数命令：DBDB00000000，Write Without Response。
    private static let pollCommand = Data([0xDB, 0xDB, 0x00, 0x00, 0x00, 0x00])

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var cmdChar: CBCharacteristic?
    private var candidates: [UUID: (peripheral: CBPeripheral, rssi: Int)] = [:]
    private var scanTimer: Timer?
    private var pollTimer: Timer?
    private var reconnectTimer: Timer?
    private var notifyFallbackTimer: Timer?
    private var writeProbeDone = false
    private var rxBuffer = Data()

    private override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: - 开关

    private func start() {
        rxBuffer.removeAll()
        pollCount = 0
        rxBytes = 0
        notifyOn = false
        lastFrameInfo = nil
        lastRxAt = nil
        writeProbeDone = false
        stage = central.state == .poweredOn ? "搜索中" : "等蓝牙开启"
        if central.state == .poweredOn {
            startScan()
        }
        // 蓝牙还没开：等 centralManagerDidUpdateState 回调再扫。
    }

    private func stop() {
        scanTimer?.invalidate(); scanTimer = nil
        pollTimer?.invalidate(); pollTimer = nil
        reconnectTimer?.invalidate(); reconnectTimer = nil
        notifyFallbackTimer?.invalidate(); notifyFallbackTimer = nil
        if let p = peripheral {
            central.cancelPeripheralConnection(p)
        }
        peripheral = nil
        cmdChar = nil
        isConnected = false
        isScanning = false
        deviceName = nil
        rssi = nil
        snapshot = nil
        lastError = nil
        stage = "未启用"
        pollCount = 0
        rxBytes = 0
        notifyOn = false
        lastFrameInfo = nil
        lastRxAt = nil
        writeProbeDone = false
        ANTBMSRelay.clear()
    }

    // MARK: - 扫描（收 3 秒，选 RSSI 最强的）

    private func startScan() {
        guard isEnabled, central.state == .poweredOn else { return }
        candidates.removeAll()
        isScanning = true
        stage = "搜索中"
        central.scanForPeripherals(withServices: [Self.serviceUUID], options: nil)
        scanTimer?.invalidate()
        scanTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            self?.finishScan()
        }
    }

    private func finishScan() {
        central.stopScan()
        isScanning = false
        guard isEnabled else { return }
        // 选 RSSI 最强的一台；一台都没发现就继续扫。
        guard let best = candidates.values.max(by: { $0.rssi < $1.rssi }) else {
            startScan()
            return
        }
        peripheral = best.peripheral
        deviceName = best.peripheral.name ?? "ANT BMS"
        rssi = best.rssi
        stage = "连接中"
        central.connect(best.peripheral, options: nil)
    }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            if isEnabled { startScan() }
        } else if isEnabled {
            lastError = "蓝牙未开启"
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? ""
        let hasPrefix = name.hasPrefix("ANT-BLE") || name.hasPrefix("ANT@BLE")
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let hasService = services.contains(Self.serviceUUID)
        guard hasPrefix || hasService else { return }
        candidates[peripheral.identifier] = (peripheral, RSSI.intValue)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        isConnected = true
        lastError = nil
        writeProbeDone = false
        stage = "发现服务"
        peripheral.delegate = self
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        lastError = "连接失败：\(error?.localizedDescription ?? "?")"
        stage = "连接失败，重连中"
        scheduleReconnect()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        isConnected = false
        cmdChar = nil
        notifyOn = false
        pollTimer?.invalidate(); pollTimer = nil
        notifyFallbackTimer?.invalidate(); notifyFallbackTimer = nil
        stage = "已断开，重连中"
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard isEnabled else { return }
        reconnectTimer?.invalidate()
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
            self?.startScan()
        }
    }

    // MARK: - CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil,
              let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            lastError = "没找到 FFE0 服务"
            central.cancelPeripheralConnection(peripheral)
            scheduleReconnect()
            return
        }
        peripheral.discoverCharacteristics([Self.cmdUUID], for: service)
        stage = "发现特征"
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil,
              let ch = service.characteristics?.first(where: { $0.uuid == Self.cmdUUID }) else {
            lastError = "没找到 FFE1 特征"
            central.cancelPeripheralConnection(peripheral)
            scheduleReconnect()
            return
        }
        cmdChar = ch
        stage = "订阅中"
        peripheral.setNotifyValue(true, for: ch)
        // 正常 1 秒内回调 didUpdateNotificationStateFor；3 秒没回调
        // 也先开始轮询（有的栈不回调），避免卡死在订阅这一步。
        notifyFallbackTimer?.invalidate()
        notifyFallbackTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            self?.startPollingIfNeeded()
        }
    }

    /// 订阅确认后（或 3 秒超时后）开始轮询。
    private func startPollingIfNeeded() {
        guard isEnabled, isConnected, cmdChar != nil, pollTimer == nil else { return }
        stage = "轮询中"
        sendPoll()
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.sendPoll()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        notifyFallbackTimer?.invalidate(); notifyFallbackTimer = nil
        if let error {
            lastError = "订阅通知失败：\(error.localizedDescription)"
            stage = "订阅失败"
            return
        }
        notifyOn = characteristic.isNotifying
        if characteristic.isNotifying {
            startPollingIfNeeded()
        } else {
            lastError = "通知未开启"
            stage = "订阅失败"
        }
    }

    private func sendPoll() {
        guard let p = peripheral, let ch = cmdChar, isConnected else { return }
        pollCount += 1
        p.writeValue(Self.pollCommand, for: ch, type: .withoutResponse)
        // 3 次轮询都没回包：补一次带回应写入，看写入本身通不通。
        if pollCount == 3, rxBytes == 0, !writeProbeDone {
            writeProbeDone = true
            p.writeValue(Self.pollCommand, for: ch, type: .withResponse)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            lastError = "写入失败：\(error.localizedDescription)"
        } else if rxBytes == 0 {
            lastFrameInfo = "写入已确认，仍在等 BMS 回包"
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let data = characteristic.value, !data.isEmpty else { return }
        rxBytes += data.count
        lastRxAt = Date()
        rxBuffer.append(data)
        drainBuffer()
    }

    /// 攒包：找 7E A1 头，按 byte5 的 payload 长度算整帧长，
    /// 验尾 F3 00 AA 55，通过才解析；对不上就逐字节丢，防粘包/半包。
    private func drainBuffer() {
        while true {
            guard let head = rxBuffer.firstIndex(of: 0x7E) else {
                rxBuffer.removeAll()
                return
            }
            if head > 0 { rxBuffer.removeFirst(head) }
            guard rxBuffer.count >= 6 else { return }
            guard rxBuffer[1] == 0xA1 else {
                rxBuffer.removeFirst(1)
                continue
            }
            let total = 6 + Int(rxBuffer[5]) + 4
            guard total <= 512 else {
                // payload 长度离谱（不是真帧头），丢 1 字节继续找。
                rxBuffer.removeFirst(1)
                continue
            }
            guard rxBuffer.count >= total else { return }
            let frame = rxBuffer.prefix(total)
            rxBuffer.removeFirst(total)
            // 1.2.2 的教训：尾部第 1 个字节不是固定的。2026-11-19 实测帧尾
            // 是 F3 00 AA 55，但 2026-11-20 实测 35 帧全是 178B、尾部第 1 字节
            // 变了（简单求和/XOR/CRC8/CRC16 都算不出 0xF3，它不是校验和，
            // 更像是数据/状态字节）。固定尾只认最后 2 字节 AA 55；
            // 真正的防错靠 parseFrame 的电芯范围校验。尾部 4 字节记进诊断。
            let tailHex = frame.suffix(4).map { String(format: "%02X", $0) }.joined(separator: " ")
            guard frame.suffix(2).elementsEqual(Data([0xAA, 0x55])) else {
                lastFrameInfo = "收到 \(total)B，尾部 \(tailHex)，不是 AA 55"
                continue
            }
            if let parsed = Self.parseFrame(Data(frame)) {
                lastFrameInfo = "收到 \(total)B，尾部 \(tailHex)，解析成功"
                snapshot = parsed
                ANTBMSRelay.update(ANTBMSRelay.Values(
                    voltage: parsed.voltage,
                    current: parsed.current,
                    soc: parsed.soc,
                    maxTemp: parsed.temps.max() ?? 0,
                    delta: parsed.cellDelta))
            } else {
                lastFrameInfo = "收到 \(total)B，尾部 \(tailHex)，解析失败"
            }
            // 解析失败就丢弃不更新，继续等下一帧。
        }
    }

    // MARK: - 帧解析（已用朋友的 178 字节实测帧 + ANT BMS V2 App 交叉验证）

    private static func u16(_ d: Data, _ off: Int) -> UInt16 {
        UInt16(d[off]) | (UInt16(d[off + 1]) << 8)
    }

    /// N=电芯数：从 offset 34 起连续读 u16，有效范围 2000–4500mV，
    /// 第一个无效值就停；要求 N>=1 且 34+2N+54 <= 帧长。
    static func parseFrame(_ f: Data) -> ANTBMSData? {
        guard f.count >= 10,
              f[0] == 0x7E, f[1] == 0xA1,
              f.count == 6 + Int(f[5]) + 4,
              // 1.2.2：尾部只认 AA 55（见 drainBuffer 的注释）。
              f.suffix(2).elementsEqual(Data([0xAA, 0x55])) else { return nil }
        var n = 0
        while 34 + 2 * n + 1 < f.count {
            let v = u16(f, 34 + 2 * n)
            guard (2000...4500).contains(v) else { break }
            n += 1
        }
        guard n >= 1, 34 + 2 * n + 54 <= f.count else { return nil }
        let cells = (0..<n).map { Int(u16(f, 34 + 2 * $0)) }
        let temps = (0..<6).map { Int(u16(f, 34 + 2 * n + 2 * $0)) }
        let voltage = Float(u16(f, 46 + 2 * n)) / 100
        let current = Float(Int16(bitPattern: u16(f, 48 + 2 * n))) / 10
        let soc = Float(u16(f, 52 + 2 * n)) / 10
        guard let cMin = cells.min(), let cMax = cells.max() else { return nil }
        return ANTBMSData(
            voltage: voltage,
            current: current,
            power: voltage * current,
            soc: soc,
            temps: temps,
            cellCount: n,
            cellMin: cMin,
            cellMax: cMax,
            cellAvg: cells.reduce(0, +) / n,
            cellDelta: cMax - cMin,
            minCellIndex: (cells.firstIndex(of: cMin) ?? 0) + 1,
            maxCellIndex: (cells.firstIndex(of: cMax) ?? 0) + 1,
            updatedAt: Date())
    }
}
