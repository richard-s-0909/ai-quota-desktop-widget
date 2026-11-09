import SwiftUI
import AppKit

// MARK: - 错误类型

/// 普通错误：直接显示 message
struct AppError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// 需要用户重新登录的错误
struct LoginNeeded: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

// MARK: - 小工具

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

/// 把 JSON 里的数字或数字字符串转成 Double
func num(_ v: Any?) -> Double? {
    if let n = v as? NSNumber { return n.doubleValue }
    if let s = v as? String { return Double(s) }
    return nil
}

/// 正则取第 1 个捕获组
func capture(_ s: String, _ pattern: String) -> String? {
    guard let re = try? NSRegularExpression(pattern: pattern),
          let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
          m.numberOfRanges > 1,
          let r = Range(m.range(at: 1), in: s) else { return nil }
    return String(s[r])
}

func parseISODate(_ s: String?) -> Date? {
    guard let s = s, !s.isEmpty else { return nil }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d }
    // 微秒级小数位 ISO8601DateFormatter 解析不了，去掉小数再试
    let trimmed = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: trimmed)
}

func formatReset(_ d: Date?, now: Date) -> String {
    guard let d = d else { return "" }
    let span = d.timeIntervalSince(now)
    if span <= 0 { return "即将重置" }
    let mins = Int(span / 60)
    if span < 3600 { return "\(max(1, mins)) 分钟后重置" }
    if span < 86400 { return "\(mins / 60) 小时 \(mins % 60) 分后重置" }
    let df = DateFormatter()
    df.locale = Locale(identifier: "zh_CN")
    df.dateFormat = "EEE HH:mm"
    return "\(df.string(from: d)) 重置 · \(Int(span / 86400)) 天后"
}

func money(_ currency: String, _ v: Double, digits: Int = 2) -> String {
    let sym: String
    switch currency {
    case "USD": sym = "$"
    case "CNY": sym = "¥"
    default: sym = currency + " "
    }
    return sym + String(format: "%.\(digits)f", v)
}

func formatTokens(_ n: Double) -> String {
    if n >= 1e9 { return String(format: "%.1fB", n / 1e9) }
    if n >= 1e6 { return String(format: "%.1fM", n / 1e6) }
    if n >= 1e3 { return String(format: "%.1fK", n / 1e3) }
    return String(format: "%.0f", n)
}

// MARK: - 网络

enum HTTP {
    static func get(_ url: String, headers: [String: String]) async throws -> (Int, Data) {
        var req = URLRequest(url: URL(string: url)!, timeoutInterval: 20)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, resp) = try await URLSession.shared.data(for: req)
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    static func postJSON(_ url: String, body: [String: Any], headers: [String: String] = [:]) async throws -> (Int, Data) {
        var req = URLRequest(url: URL(string: url)!, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    static func json(_ d: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
    }
}

// MARK: - 本机路径

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let claudeFile = home.appendingPathComponent(".claude/.credentials.json")
    static let codexAuth = home.appendingPathComponent(".codex/auth.json")
    static let dshCred = home.appendingPathComponent(".dsh/.credentials.yaml")

    /// 找 Claude Code 命令行
    static func claudeCLI() -> String? {
        let candidates = [
            home.appendingPathComponent(".local/bin/claude").path,
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            home.appendingPathComponent(".claude/local/claude").path,
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
