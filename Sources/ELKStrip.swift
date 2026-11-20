import Combine
import CoreBluetooth
import Foundation

/// 七彩日行灯：车上的 LED 灯带，ELK-BLEDOB 控制器（duoCo Strip 同款）。
///
/// 协议已公开（Home Assistant elkbledom，models.json 的 ELK-BLEDOB
/// 条目 + definitions.json 的 EFFECTS 枚举）：服务 FFF0，写 FFF3，
/// 通知 FFF4；命令都是 9 字节 `7E … EF`，Write Without Response，
/// 不加密。**不要发登录握手——那是 MELK/MODELX 才要的，
/// ELK-BLEDOB 不需要**（elkbledom.py 的 _ensure_connected 只给
/// 名字以 melk/modelx 开头的设备做登录）。
/// 只编进主 App（Sources/），扩展进程绝不能建 CBCentralManager。
///
/// 链路：扫描 FFF0 服务 → 收 3 秒选 RSSI 最强的一台 → 发现
/// FFF0/FFF3/FFF4 → 订阅 FFF4 通知 → 发一次查询 → 就绪。
/// 名字是通用型号名：邻居家有个同型号控制器也叫这个名字，
/// 所以必须按信号最强选，卡片上显示设备名 + RSSI，开关一按、
/// 看车灯变不变就知道连的是不是自己车上的灯。
/// 连接是独占的：duoCo 占着灯时我们连不上（didFailToConnect
/// 会写明“可能被 duoCo 占用，请先退出 duoCo”）。
/// 绝对不要把 iOS peripheral UUID 写进代码：那是本机才有的
/// 标识，朋友手机上不一样（只做诊断参考）。
final class ELKStrip: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let shared = ELKStrip()

    /// 开关默认 OFF，MainView 的“七彩日行灯”卡片控制。
    @Published var isEnabled = UserDefaults.standard.bool(forKey: "nbc.elk.enabled") {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "nbc.elk.enabled")
            if isEnabled { start() } else { stop() }
        }
    }
    @Published private(set) var isConnected = false
    @Published private(set) var isScanning = false
    @Published private(set) var deviceName: String?
    @Published private(set) var rssi: Int?
    @Published private(set) var lastError: String?
    // 诊断（照 ANTBMS 的套路）：卡片直接说卡在哪一步。
    @Published private(set) var stage = "未启用"
    @Published private(set) var writeCount = 0
    @Published private(set) var rxBytes = 0
    @Published private(set) var notifyOn = false
    @Published private(set) var lastRxAt: Date?
    // 灯的状态（只记我们最后一次发出去的值；灯的回包不解析，
    // 只数 rxBytes——ELK-BLEDOB 的状态回包格式没在 models.json 里定）。
    @Published private(set) var isOn = false
    @Published private(set) var colorR: UInt8 = 255
    @Published private(set) var colorG: UInt8 = 255
    @Published private(set) var colorB: UInt8 = 255
    @Published private(set) var brightness = 100 // 0–100
    @Published private(set) var lastEffect: String?

    private static let serviceUUID = CBUUID(string: "FFF0")
    private static let writeUUID = CBUUID(string: "FFF3")
    private static let notifyUUID = CBUUID(string: "FFF4")

    /// 命令表（elkbledom models.json 的 ELK-BLEDOB 条目，逐字节照抄；
    /// 别用 ELK-BLEDOM 那份，它的开关命令不一样：第二字节是 04 不是 07）。
    private static let cmdTurnOn  = Data([0x7E, 0x07, 0x04, 0xFF, 0x00, 0x01, 0x02, 0x01, 0xEF])
    private static let cmdTurnOff = Data([0x7E, 0x07, 0x04, 0x00, 0x00, 0x00, 0x02, 0x01, 0xEF])
    private static let cmdQuery   = Data([0x7E, 0x00, 0x01, 0xFA, 0x00, 0x00, 0x00, 0x00, 0xEF])
    private static func cmdColor(r: UInt8, g: UInt8, b: UInt8) -> Data {
        Data([0x7E, 0x07, 0x05, 0x03, r, g, b, 0x0A, 0xEF])
    }
    private static func cmdBrightness(_ v: Int) -> Data {
        Data([0x7E, 0x04, 0x01, UInt8(max(0, min(100, v))), 0x01, 0xFF, 0x02, 0x01, 0xEF])
    }
    private static func cmdWhite(_ v: Int) -> Data {
        Data([0x7E, 0x07, 0x01, UInt8(max(0, min(100, v))), 0x00, 0x00, 0x00, 0x00, 0xEF])
    }
    /// 灯效（definitions.json 的 EFFECTS 枚举，值原样代入 v 位）：
    /// 135 红绿蓝跳变，136 七彩跳变，138 七彩渐变。
    private static func cmdEffect(_ id: UInt8) -> Data {
        Data([0x7E, 0x07, 0x03, id, 0x03, 0xFF, 0xFF, 0x00, 0xEF])
    }
    static let effectJumpRGB = 135 // 红绿蓝跳变
    static let effectJump7 = 136 // 七彩跳变
    static let effectFade7 = 138 // 七彩渐变

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?
    private var candidates: [UUID: (peripheral: CBPeripheral, rssi: Int)] = [:]
    private var scanTimer: Timer?
    private var reconnectTimer: Timer?
    private var notifyFallbackTimer: Timer?
    private var ready = false

    private override init() {
        super.init()
        // 带恢复标识（同 ANTBMS）：系统杀掉 App 后，能在后台把
        // 它拉起来恢复 BLE 会话（willRestoreState）。
        central = CBCentralManager(
            delegate: self, queue: .main,
            options: [CBCentralManagerOptionRestoreIdentifierKey: "com.corpsezhao.ninebotcast.elkstrip"])
        if isEnabled { start() }
    }

    // MARK: - 开关

    private func start() {
        writeCount = 0
        rxBytes = 0
        notifyOn = false
        lastRxAt = nil
        lastError = nil
        ready = false
        stage = central.state == .poweredOn ? "搜索中" : "等蓝牙开启"
        if central.state == .poweredOn {
            startScan()
        }
        // 蓝牙还没开：等 centralManagerDidUpdateState 回调再扫。
    }

    private func stop() {
        scanTimer?.invalidate(); scanTimer = nil
        reconnectTimer?.invalidate(); reconnectTimer = nil
        notifyFallbackTimer?.invalidate(); notifyFallbackTimer = nil
        if let p = peripheral {
            central.cancelPeripheralConnection(p)
        }
        peripheral = nil
        writeChar = nil
        notifyChar = nil
        isConnected = false
        isScanning = false
        deviceName = nil
        rssi = nil
        lastError = nil
        stage = "未启用"
        writeCount = 0
        rxBytes = 0
        notifyOn = false
        lastRxAt = nil
        ready = false
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
        // 选 RSSI 最强的一台（邻居家同型号也在广播，弱信号那台
        // 不是车上的灯）；一台都没发现就继续扫。
        guard let best = candidates.values.max(by: { $0.rssi < $1.rssi }) else {
            startScan()
            return
        }
        peripheral = best.peripheral
        deviceName = best.peripheral.name ?? "ELK-BLEDOB"
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

    /// 系统在后台把被杀的 App 拉起来时恢复 BLE 会话。
    /// 恢复到的外设直接重连/重新发现服务，不用重新扫描。
    /// 注意：这只在 App 启动时就建了 ELKStrip.shared 才生效；
    /// 目前只有 MainView 建它（NinebotCastApp.swift 里还没像
    /// ANTBMS 那样在 init 里 touch，见 MainView 的注释）。
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        guard isEnabled else { return }
        // didUpdateState 可能已经先起了扫描：恢复接管，先停掉它。
        central.stopScan()
        scanTimer?.invalidate(); scanTimer = nil
        isScanning = false
        let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        guard let p = peripherals.first else {
            stage = "恢复后重扫"
            startScan()
            return
        }
        peripheral = p
        p.delegate = self
        deviceName = p.name ?? "ELK-BLEDOB"
        if p.state == .connected {
            isConnected = true
            stage = "恢复连接，发现服务"
            p.discoverServices([Self.serviceUUID])
        } else {
            stage = "恢复后重连"
            central.connect(p, options: nil)
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? ""
        let isBLEDOB = name.lowercased().contains("bledob")
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let hasService = services.contains(Self.serviceUUID)
        guard isBLEDOB || hasService else { return }
        candidates[peripheral.identifier] = (peripheral, RSSI.intValue)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        isConnected = true
        lastError = nil
        ready = false
        stage = "发现服务"
        peripheral.delegate = self
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        // 最常见的原因就是 duoCo 正占着灯：一个灯一次只能连一个 App。
        lastError = "连接失败：\(error?.localizedDescription ?? "?")（可能被 duoCo 占用，请先退出 duoCo 再试）"
        stage = "连接失败，重连中"
        scheduleReconnect()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        isConnected = false
        writeChar = nil
        notifyChar = nil
        notifyOn = false
        ready = false
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
            lastError = "没找到 FFF0 服务"
            central.cancelPeripheralConnection(peripheral)
            scheduleReconnect()
            return
        }
        peripheral.discoverCharacteristics([Self.writeUUID, Self.notifyUUID], for: service)
        stage = "发现特征"
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil,
              let w = service.characteristics?.first(where: { $0.uuid == Self.writeUUID }),
              let n = service.characteristics?.first(where: { $0.uuid == Self.notifyUUID }) else {
            lastError = "没找到 FFF3/FFF4 特征"
            central.cancelPeripheralConnection(peripheral)
            scheduleReconnect()
            return
        }
        writeChar = w
        notifyChar = n
        stage = "订阅中"
        peripheral.setNotifyValue(true, for: n)
        // 正常 1 秒内回调 didUpdateNotificationStateFor；3 秒没回调
        // 也先就绪（有的栈不回调），避免卡死在订阅这一步。
        notifyFallbackTimer?.invalidate()
        notifyFallbackTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            self?.markReadyIfNeeded()
        }
    }

    /// 订阅确认后（或 3 秒超时后）就绪，并发一次查询（看灯回不回包）。
    private func markReadyIfNeeded() {
        guard isEnabled, isConnected, writeChar != nil, !ready else { return }
        ready = true
        stage = "就绪"
        send(Self.cmdQuery)
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
            markReadyIfNeeded()
        } else {
            lastError = "通知未开启"
            stage = "订阅失败"
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let data = characteristic.value, !data.isEmpty else { return }
        rxBytes += data.count
        lastRxAt = Date()
        // 灯的回包不解析：状态回包格式没在 models.json 里定，
        // 只数收到的字节数（能证明灯在回话）。
    }

    // MARK: - 发命令（全是 Write Without Response，9 字节）

    private func send(_ data: Data) {
        guard let p = peripheral, let ch = writeChar, isConnected else { return }
        p.writeValue(data, for: ch, type: .withoutResponse)
        writeCount += 1
    }

    /// 没连上时点命令不发也不崩：卡片上能看到“未连接”。
    private var canSend: Bool { isConnected && writeChar != nil }

    /// 颜色/亮度/白色/灯效都是“开灯”的意思：灯关着时先发开灯
    /// 再发本命令（同 Home Assistant 的做法）。
    private func ensureOn() {
        guard canSend, !isOn else { return }
        send(Self.cmdTurnOn)
        isOn = true
    }

    func turnOn() {
        guard canSend else { return }
        send(Self.cmdTurnOn)
        isOn = true
    }

    func turnOff() {
        guard canSend else { return }
        send(Self.cmdTurnOff)
        isOn = false
    }

    func setColor(r: UInt8, g: UInt8, b: UInt8) {
        guard canSend else { return }
        ensureOn()
        send(Self.cmdColor(r: r, g: g, b: b))
        colorR = r; colorG = g; colorB = b
    }

    func setBrightness(_ value: Int) {
        guard canSend else { return }
        let v = max(0, min(100, value))
        ensureOn()
        send(Self.cmdBrightness(v))
        brightness = v
    }

    /// 白光：亮度用当前亮度值。
    func setWhite() {
        guard canSend else { return }
        ensureOn()
        send(Self.cmdWhite(brightness))
    }

    /// 灯效：id 见 cmdEffect 的注释（definitions.json 的 EFFECTS 枚举）。
    func setEffect(_ id: Int, name: String) {
        guard canSend else { return }
        ensureOn()
        send(Self.cmdEffect(UInt8(id)))
        lastEffect = name
    }
}
