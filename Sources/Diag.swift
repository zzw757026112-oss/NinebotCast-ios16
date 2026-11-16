import Foundation

/// 极简文件日志。
///
/// 为什么需要它：免费签名装的 App 闪退后，手机上看不到崩溃日志，我也拿不到。
/// 所以把「启动 / 开播 / 编码器创建 / 首帧 / 首包 / 停止」这些阶段节点写进
/// Documents/cast-diag.log，下次打开 App 时直接显示在「诊断」区里。
/// 这样即使这一版还闪，我们也能知道它闪在哪一步。
enum Diag {
    private static let lock = NSLock()
    private static let fileName = "cast-diag.log"
    private static let maxBytes = 256 * 1024

    static var fileURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return dir.appendingPathComponent(fileName)
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func log(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        let line = "[\(stampFormatter.string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        let url = fileURL
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
        trimIfNeeded()
    }

    private static func trimIfNeeded() {
        let url = fileURL
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = (attrs?[.size] as? Int) ?? 0
        guard bytes > maxBytes else { return }
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }
        let keep = content.split(separator: "\n").suffix(160).joined(separator: "\n")
        try? (keep + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// 读取最后若干行，给界面显示
    static func tail(_ lineCount: Int = 16) -> String {
        lock.lock()
        defer { lock.unlock() }
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8),
              !content.isEmpty else {
            return "（暂无日志）"
        }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        return lines.suffix(lineCount).joined(separator: "\n")
    }

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// 启动时调用：打一条启动记录，并挂上未捕获异常处理器（NSException 能落盘）
    static func installCrashHandler(version: String) {
        log("======== APP LAUNCH \(version) ========")
        NSSetUncaughtExceptionHandler { exception in
            Diag.log("CRASH EXCEPTION \(exception.name.rawValue): \(exception.reason ?? "-")")
            let stack = exception.callStackSymbols.prefix(10).joined(separator: " || ")
            Diag.log("CRASH STACK \(stack)")
        }
    }
}
