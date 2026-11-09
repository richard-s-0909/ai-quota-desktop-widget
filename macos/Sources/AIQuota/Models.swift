import SwiftUI

/// 一个用量窗口，例如“5 小时 / 本周”
struct UsageWindow: Identifiable, Hashable {
    let id = UUID()
    let label: String
    let used: Double          // 已用百分比 0~100
    let resetsAt: Date?
    var left: Double { max(0, min(100, 100 - used)) }
}

/// DeepSeek 某个币种的钱包
struct Wallet: Identifiable, Hashable {
    var id: String { currency }
    let currency: String
    var normal: Double        // 充值余额
    var bonus: Double         // 赠送余额
    var tokens: Double        // 平台给出的可用 token 估算
    var cost: Double          // 累计消费
    var total: Double { normal + bonus }
}

/// 一次查询的结果
struct ProviderResult {
    var windows: [UsageWindow] = []
    var wallets: [Wallet] = []
    var plan: String?
    var error: String?
    var needsLogin = false
    var loginExpires: Date?

    mutating func apply(_ error: Error) {
        if let e = error as? LoginNeeded {
            needsLogin = true
            self.error = e.message
        } else if let e = error as? AppError {
            self.error = e.message
        } else {
            self.error = error.localizedDescription
        }
    }
}

/// 扫描到的一个 AI
struct AIApp: Identifiable, Hashable {
    let id: String
    let name: String
    let color: Color
    let letter: String
    let usage: Bool           // 能否查询用量
    var appURL: URL?
}

struct CatalogEntry {
    let id: String
    let name: String
    let letter: String
    let hex: UInt32
    var usage = false
    let pattern: String       // 匹配 /Applications 里 .app 名称的正则
}

/// 能识别的 AI。usage = true 的可以显示用量，其余只做“已安装 + 一键打开”
let catalog: [CatalogEntry] = [
    CatalogEntry(id: "claude",     name: "Claude",        letter: "C",  hex: 0xD97757, usage: true, pattern: "^Claude$"),
    CatalogEntry(id: "chatgpt",    name: "ChatGPT",       letter: "G",  hex: 0x10A37F, usage: true, pattern: "^(ChatGPT|Codex)$"),
    CatalogEntry(id: "deepseek",   name: "DeepSeek",      letter: "D",  hex: 0x4D6BFE, usage: true, pattern: "DeepSeek"),
    CatalogEntry(id: "copilot",    name: "Copilot",       letter: "Co", hex: 0x3B82F6, pattern: "Copilot"),
    CatalogEntry(id: "gemini",     name: "Gemini",        letter: "Ge", hex: 0x4F8DF7, pattern: "Gemini"),
    CatalogEntry(id: "cursor",     name: "Cursor",        letter: "Cu", hex: 0x9CA3AF, pattern: "^Cursor$"),
    CatalogEntry(id: "windsurf",   name: "Windsurf",      letter: "W",  hex: 0x34D3B4, pattern: "Windsurf"),
    CatalogEntry(id: "trae",       name: "Trae",          letter: "T",  hex: 0xFF4D6D, pattern: "^Trae"),
    CatalogEntry(id: "doubao",     name: "豆包",           letter: "豆", hex: 0x5B8CFF, pattern: "豆包|Doubao"),
    CatalogEntry(id: "kimi",       name: "Kimi",          letter: "K",  hex: 0x64748B, pattern: "Kimi"),
    CatalogEntry(id: "qwen",       name: "通义",           letter: "通", hex: 0x7C5CFF, pattern: "通义|Qwen|Tongyi"),
    CatalogEntry(id: "yuanbao",    name: "腾讯元宝",        letter: "元", hex: 0x22C55E, pattern: "元宝|Yuanbao"),
    CatalogEntry(id: "ernie",      name: "文心一言",        letter: "文", hex: 0x2563EB, pattern: "文心|ERNIE"),
    CatalogEntry(id: "zhipu",      name: "智谱清言",        letter: "智", hex: 0x3B5BFD, pattern: "智谱|ChatGLM"),
    CatalogEntry(id: "perplexity", name: "Perplexity",    letter: "P",  hex: 0x20B8CD, pattern: "Perplexity"),
    CatalogEntry(id: "poe",        name: "Poe",           letter: "Po", hex: 0x8B5CF6, pattern: "^Poe$"),
    CatalogEntry(id: "grok",       name: "Grok",          letter: "Gr", hex: 0x6B7280, pattern: "^Grok"),
    CatalogEntry(id: "ollama",     name: "Ollama",        letter: "O",  hex: 0x6B7280, pattern: "Ollama"),
    CatalogEntry(id: "lmstudio",   name: "LM Studio",     letter: "LM", hex: 0x6366F1, pattern: "LM ?Studio"),
    CatalogEntry(id: "cherry",     name: "Cherry Studio", letter: "Ch", hex: 0xEF4444, pattern: "Cherry ?Studio"),
    CatalogEntry(id: "chatbox",    name: "Chatbox",       letter: "Cb", hex: 0x3B82F6, pattern: "Chatbox"),
    CatalogEntry(id: "lechat",     name: "Le Chat",       letter: "M",  hex: 0xF97316, pattern: "Le Chat|Mistral"),
]

enum AppScanner {
    static func scan() -> [AIApp] {
        let fm = FileManager.default
        let dirs = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/Applications/Utilities"),
            Paths.home.appendingPathComponent("Applications"),
        ]
        var installed: [(name: String, url: URL)] = []
        for d in dirs {
            guard let items = try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: nil) else { continue }
            for u in items where u.pathExtension == "app" {
                installed.append((u.deletingPathExtension().lastPathComponent, u))
            }
        }
        var found: [AIApp] = []
        for c in catalog {
            let hit = installed.first { $0.name.range(of: c.pattern, options: [.regularExpression, .caseInsensitive]) != nil }
            var present = hit != nil
            switch c.id {
            case "claude":   if ClaudeCreds.exists { present = true }
            case "chatgpt":  if fm.fileExists(atPath: Paths.codexAuth.path) { present = true }
            case "deepseek": if fm.fileExists(atPath: Paths.dshCred.path) { present = true }
            default: break
            }
            if present {
                found.append(AIApp(id: c.id, name: c.name, color: Color(hex: c.hex), letter: c.letter,
                                   usage: c.usage, appURL: hit?.url))
            }
        }
        return found
    }
}
