import CryptoKit
import Foundation
import Security

/// 离线授权码：无服务器，HMAC-SHA256 签名 + Crockford base32。
/// 码格式 16 字符，分 4 组：XXXX-XXXX-XXXX-XXXX
///   - 前 4 字符（20 bit）：有效期 = 2026-01-01 起的天数；0 = 永久
///   - 后 12 字符（60 bit）：HMAC-SHA256(secret, "NB1|<天数>") 的前 60 bit
/// 生成器在 tools/gen_license.py（不进仓库），与这里逐位一致。
/// 注意：密钥嵌在 App 里；仓库是公开的，懂行的人能从源码/二进制里找到
/// 它并自己生成码——这是一把防普通用户的锁，不是防不住的加密。
enum LicenseManager {
    // MARK: - 常量
    private static let secretHex = "f246011891202707b6afe43c6f4672d8a663706b2530f785c05fbbd67a3cdd58"
    private static let alphabet: [Character] = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    private static let alphabetIndex: [Character: Int] = {
        var d: [Character: Int] = [:]
        for (i, ch) in alphabet.enumerated() { d[ch] = i }
        return d
    }()
    private static let keychainService = "com.corpsezhao.ninebotcast.license"
    private static let keychainAccount = "activation-code"

    enum Status {
        case valid(expiry: Date?)
        case invalid
        case expired(expiry: Date)
        var isValid: Bool {
            if case .valid = self { return true }
            return false
        }
    }

    // MARK: - 编解码
    static func normalize(_ code: String) -> String {
        let s = code.uppercased().filter { $0 != "-" && !$0.isWhitespace }
        return String(s.map { ch in
            switch ch {
            case "O": return "0"
            case "I", "L": return "1"
            default: return ch
            }
        })
    }

    private static func base32Encode(value: UInt64, chars: Int) -> String {
        var out = ""
        out.reserveCapacity(chars)
        for i in 0..<chars {
            let shift = 5 * (chars - 1 - i)
            out.append(alphabet[Int((value >> shift) & 31)])
        }
        return out
    }

    private static func base32Decode(_ s: String) -> UInt64? {
        var value: UInt64 = 0
        for ch in s {
            guard let idx = alphabetIndex[ch] else { return nil }
            value = value &* 32 &+ UInt64(idx)
        }
        return value
    }

    private static func secretData() -> Data {
        var data = Data()
        data.reserveCapacity(secretHex.count / 2)
        var index = secretHex.startIndex
        while index < secretHex.endIndex {
            let next = secretHex.index(index, offsetBy: 2)
            let byte = UInt8(secretHex[index..<next], radix: 16) ?? 0
            data.append(byte)
            index = next
        }
        return data
    }

    private static func signature60(expiryDays: Int) -> UInt64 {
        let key = SymmetricKey(data: secretData())
        let mac = HMAC<SHA256>.authenticationCode(for: Data("NB1|\(expiryDays)".utf8), using: key)
        var value: UInt64 = 0
        for byte in mac.prefix(8) {
            value = (value << 8) | UInt64(byte)
        }
        return value >> 4
    }

    // MARK: - 日期
    private static var calendar: Calendar { Calendar.current }
    private static var baseDate: Date {
        calendar.date(from: DateComponents(year: 2026, month: 1, day: 1))!
    }
    static func expiryDate(days: Int) -> Date {
        calendar.date(byAdding: .day, value: days, to: baseDate)!
    }
    static func displayDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月d日"
        return f.string(from: date)
    }

    // MARK: - 验证
    static func validate(code: String) -> Status {
        let s = normalize(code)
        guard s.count == 16 else { return .invalid }
        guard s.allSatisfy({ alphabetIndex[$0] != nil }) else { return .invalid }
        guard let expiryDays = base32Decode(String(s.prefix(4))),
              let sig = base32Decode(String(s.dropFirst(4))) else { return .invalid }
        guard sig == signature60(expiryDays: Int(expiryDays)) else { return .invalid }
        if expiryDays == 0 { return .valid(expiry: nil) }
        let expiry = expiryDate(days: Int(expiryDays))
        let today = calendar.startOfDay(for: Date())
        if today > expiry { return .expired(expiry: expiry) }
        return .valid(expiry: expiry)
    }

    // MARK: - 钥匙串（App 与录屏扩展默认共享同一访问组）
    static func saveCode(_ code: String) -> Bool {
        let data = Data(normalize(code).utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updateQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keychainService,
                kSecAttrAccount as String: keychainAccount
            ]
            return SecItemUpdate(updateQuery as CFDictionary,
                                 [kSecValueData as String: data] as CFDictionary) == errSecSuccess
        }
        return status == errSecSuccess
    }

    static func loadCode() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let code = String(data: data, encoding: .utf8) else { return nil }
        return code
    }

    static func clearCode() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - 对外接口
    @discardableResult
    static func activate(code: String) -> Status {
        let status = validate(code: code)
        if status.isValid {
            _ = saveCode(code)
        }
        return status
    }

    static func currentStatus() -> Status {
        guard let code = loadCode() else { return .invalid }
        return validate(code: code)
    }
}
