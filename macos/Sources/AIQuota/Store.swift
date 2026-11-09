import SwiftUI
import AppKit
import ServiceManagement

@MainActor
final class Store: ObservableObject {
    static let shared = Store()
    private let ud = UserDefaults.standard

    @Published var apps: [AIApp] = []
    @Published var results: [String: ProviderResult] = [:]
    @Published var lastUpdated: Date?
    @Published var refreshing = false
    @Published var now = Date()
    @Published var waiting: Set<String> = []          // 正在等待重新登录的 AI

    // 设置（自动保存）
    @Published var hidden: Set<String> { didSet { ud.set(Array(hidden), forKey: "hidden") } }
    @Published var scale: Double { didSet { ud.set(scale, forKey: "scale") } }
    @Published var refreshMinutes: Int { didSet { ud.set(refreshMinutes, forKey: "refreshMinutes"); schedule() } }
    @Published var floating: Bool { didSet { ud.set(floating, forKey: "floating") } }
    @Published var compact: Bool { didSet { ud.set(compact, forKey: "compact") } }
    @Published var topmost: Bool { didSet { ud.set(topmost, forKey: "topmost") } }
    @Published var menuBarSummary: Bool { didSet { ud.set(menuBarSummary, forKey: "menuBarSummary") } }
    let loginWarnDays: Double

    var openSettings: (() -> Void)?
    private var refreshTimer: Timer?
    private var clockTimer: Timer?

    init() {
        ud.register(defaults: [
            "scale": 1.0, "refreshMinutes": 5, "floating": true, "compact": false,
            "topmost": true, "menuBarSummary": true, "loginWarnDays": 3.0,
        ])
        hidden = Set(ud.stringArray(forKey: "hidden") ?? [])
        scale = ud.double(forKey: "scale")
        refreshMinutes = ud.integer(forKey: "refreshMinutes")
        floating = ud.bool(forKey: "floating")
        compact = ud.bool(forKey: "compact")
        topmost = ud.bool(forKey: "topmost")
        menuBarSummary = ud.bool(forKey: "menuBarSummary")
        loginWarnDays = ud.double(forKey: "loginWarnDays")

        apps = AppScanner.scan()
        schedule()
        clockTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Date() }
        }
        Task { await self.refresh() }
    }

    // MARK: 刷新

    func schedule() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(max(1, refreshMinutes) * 60), repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func refresh() async {
        if refreshing { return }
        refreshing = true
        let ids = Set(visibleApps.filter { $0.usage }.map { $0.id })
        var out: [String: ProviderResult] = [:]
        await withTaskGroup(of: (String, ProviderResult).self) { group in
            if ids.contains("claude")   { group.addTask { ("claude", await ClaudeProvider.fetch()) } }
            if ids.contains("chatgpt")  { group.addTask { ("chatgpt", await ChatGPTProvider.fetch()) } }
            if ids.contains("deepseek") { group.addTask { ("deepseek", await DeepSeekProvider.fetch()) } }
            for await (k, v) in group { out[k] = v }
        }
        results = out
        lastUpdated = Date()
        now = Date()
        refreshing = false
        for k in Array(waiting) where out[k] != nil && out[k]?.error == nil { waiting.remove(k) }
        checkAutoRelogin()
    }

    // MARK: 显示哪些 AI

    var visibleApps: [AIApp] { apps.filter { isVisible($0.id) } }
    func isVisible(_ id: String) -> Bool { !hidden.contains(id) }

    func setVisible(_ id: String, _ on: Bool) {
        if on { hidden.remove(id) } else { hidden.insert(id) }
        if on { Task { await refresh() } }
    }

    func rescan() {
        apps = AppScanner.scan()
        Task { await refresh() }
    }

    func open(_ app: AIApp) {
        if let u = app.appURL { NSWorkspace.shared.open(u) }
    }

    func subtitle(for app: AIApp) -> String {
        let fm = FileManager.default
        switch app.id {
        case "claude":   return ClaudeCreds.exists ? "可查看剩余用量" : "已安装 · 未登录 Claude Code"
        case "chatgpt":  return fm.fileExists(atPath: Paths.codexAuth.path) ? "可查看剩余用量（Codex 额度）" : "已安装 · 未登录 Codex"
        case "deepseek": return fm.fileExists(atPath: Paths.dshCred.path) ? "可查看账户余额（DeepSeek Harness 登录）" : "已安装 · 未登录 DeepSeek Harness"
        default:         return "已安装 · 仅快捷打开"
        }
    }

    // MARK: 重新登录（一键 + 自动）

    func relogin(_ id: String) {
        guard !waiting.contains(id) else { return }
        if id == "claude" {
            guard let cli = Paths.claudeCLI() else {
                NSWorkspace.shared.open(URL(string: "https://docs.claude.com/en/docs/claude-code/setup")!)
                return
            }
            // 打开浏览器授权；浏览器已登录 claude.ai 时会自动完成
            let p = Process()
            p.executableURL = URL(fileURLWithPath: cli)
            p.arguments = ["auth", "login"]
            p.standardInput = FileHandle.nullDevice
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return }
        } else {
            guard let u = apps.first(where: { $0.id == id })?.appURL else { return }
            NSWorkspace.shared.open(u)
        }
        waiting.insert(id)
        let deadline = Date().addingTimeInterval(600)
        Task { @MainActor in
            while self.waiting.contains(id) && Date() < deadline {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await self.refresh()
            }
            self.waiting.remove(id)
        }
    }

    /// 登录失效或快到期时自动打开登录；同一种每天最多一次
    private func checkAutoRelogin() {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let today = df.string(from: Date())
        for (id, r) in results where isVisible(id) {
            var need = r.needsLogin
            if id == "claude", let exp = r.loginExpires, exp.timeIntervalSinceNow < loginWarnDays * 86400 { need = true }
            guard need else { continue }
            let key = "autoLogin_\(id)"
            if ud.string(forKey: key) == today { continue }
            ud.set(today, forKey: key)
            relogin(id)
        }
    }

    // MARK: 开机启动

    var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("AIQuota: launch at login failed: \(error)")
        }
        objectWillChange.send()
    }

    // MARK: 摘要（菜单栏 / 迷你模式）

    func shortText(_ app: AIApp) -> String {
        guard let r = results[app.id] else { return "…" }
        if r.error != nil { return "!" }
        if app.id == "deepseek", let w = r.wallets.first { return money(w.currency, w.total, digits: 0) }
        if let m = r.windows.map({ $0.left }).min() { return "\(Int(m.rounded()))%" }
        return "…"
    }

    func shortColor(_ app: AIApp) -> Color {
        guard let r = results[app.id] else { return .white.opacity(0.5) }
        if r.error != nil { return Color(hex: 0xFBBF24) }
        if app.id == "deepseek", let w = r.wallets.first { return balanceColor(w) }
        if let m = r.windows.map({ $0.left }).min() { return leftColor(m, app.color) }
        return .white.opacity(0.5)
    }

    var summaryText: String {
        visibleApps.filter { $0.usage && results[$0.id] != nil }
            .map { "\($0.letter) \(shortText($0))" }
            .joined(separator: "  ")
    }

    var allOk: Bool { results.values.allSatisfy { $0.error == nil } }

    var footerText: String {
        if refreshing { return "正在刷新…" }
        guard let t = lastUpdated else { return "正在加载…" }
        let df = DateFormatter()
        df.dateFormat = "HH:mm"
        return "更新于 \(df.string(from: t)) · 每 \(refreshMinutes) 分钟刷新"
    }

    func zoom(by delta: Double) {
        scale = min(1.8, max(0.7, ((scale + delta) * 20).rounded() / 20))
    }
}

func leftColor(_ left: Double, _ brand: Color) -> Color {
    if left < 10 { return Color(hex: 0xF87171) }
    if left < 30 { return Color(hex: 0xFBBF24) }
    return brand
}

func balanceColor(_ w: Wallet) -> Color {
    let low: Double = w.currency == "USD" ? 1 : 5
    if w.total <= 0 { return Color(hex: 0xF87171) }
    if w.total < low { return Color(hex: 0xFBBF24) }
    return Color(hex: 0x8FA3FF)
}
