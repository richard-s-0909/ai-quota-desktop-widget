import SwiftUI
import AppKit
import ServiceManagement

@MainActor
final class Store: ObservableObject {
    static let shared = Store()
    private let ud = UserDefaults.standard
    private let env = ProcessInfo.processInfo.environment

    @Published var apps: [AIApp] = []
    @Published var results: [String: ProviderResult] = [:]
    @Published var lastUpdated: Date?
    @Published var refreshing = false
    @Published var now = Date()
    @Published var waiting: Set<String> = []          // 正在等待重新登录的 AI

    // 设置（自动保存）
    @Published var hidden: Set<String> { didSet { ud.set(Array(hidden), forKey: "hidden") } }
    @Published var scale: Double { didSet { ud.set(scale, forKey: "scale") } }                 // 悬浮窗大小
    @Published var popoverScale: Double { didSet { ud.set(popoverScale, forKey: "popoverScale") } }  // 菜单栏面板大小
    @Published var menuBarLevel: Int { didSet { ud.set(menuBarLevel, forKey: "menuBarLevel") } }     // 0 图标 / 1 最低 / 2 每个 / 3 详细
    @Published var refreshMinutes: Int { didSet { ud.set(refreshMinutes, forKey: "refreshMinutes"); schedule() } }
    @Published var floating: Bool { didSet { ud.set(floating, forKey: "floating") } }
    @Published var compact: Bool { didSet { ud.set(compact, forKey: "compact") } }
    @Published var topmost: Bool { didSet { ud.set(topmost, forKey: "topmost") } }
    let loginWarnDays: Double

    /// 演示模式：用假数据渲染界面（CI 截图用，不读取任何登录信息）
    let demo: Bool
    let forceHover: Bool

    private var refreshTimer: Timer?
    private var clockTimer: Timer?

    init() {
        ud.register(defaults: [
            "scale": 1.0, "popoverScale": 1.0, "menuBarLevel": 2, "refreshMinutes": 5,
            "floating": true, "compact": false, "topmost": true, "loginWarnDays": 3.0,
        ])
        hidden = Set(ud.stringArray(forKey: "hidden") ?? [])
        scale = ud.double(forKey: "scale")
        popoverScale = ud.double(forKey: "popoverScale")
        menuBarLevel = ud.integer(forKey: "menuBarLevel")
        refreshMinutes = ud.integer(forKey: "refreshMinutes")
        floating = ud.bool(forKey: "floating")
        compact = ud.bool(forKey: "compact")
        topmost = ud.bool(forKey: "topmost")
        loginWarnDays = ud.double(forKey: "loginWarnDays")
        demo = env["AIQUOTA_DEMO"] == "1"
        forceHover = env["AIQUOTA_HOVER"] == "1"

        if demo {
            loadDemo()
            return
        }
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
        if demo { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(max(1, refreshMinutes) * 60), repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func refresh() async {
        if refreshing || demo { return }
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
        if demo { return }
        apps = AppScanner.scan()
        Task { await refresh() }
    }

    func open(_ app: AIApp) {
        if let u = app.appURL { NSWorkspace.shared.open(u) }
    }

    func subtitle(for app: AIApp) -> String {
        if demo { return app.usage ? "可查看剩余用量" : "已安装 · 仅快捷打开" }
        let fm = FileManager.default
        switch app.id {
        case "claude":   return ClaudeCreds.exists ? "可查看剩余用量" : "已安装 · 未登录 Claude Code"
        case "chatgpt":  return fm.fileExists(atPath: Paths.codexAuth.path) ? "可查看剩余用量（Codex 额度）" : "已安装 · 未登录 Codex"
        case "deepseek": return fm.fileExists(atPath: Paths.dshCred.path) ? "可查看账户余额" : "已安装 · 未登录 DeepSeek Harness"
        default:         return "已安装 · 仅快捷打开"
        }
    }

    // MARK: 重新登录（一键 + 自动）

    func relogin(_ id: String) {
        guard !waiting.contains(id), !demo else { return }
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
        guard let r = results[app.id] else { return Theme.faint }
        if r.error != nil { return Theme.amber }
        if app.id == "deepseek", let w = r.wallets.first { return balanceColor(w) }
        if let m = r.windows.map({ $0.left }).min() { return levelColor(m) }
        return Theme.faint
    }

    /// 菜单栏文字，level：0 只显示图标、1 最紧张的一项、2 每个 AI、3 详细
    func menuBarText(_ level: Int) -> String {
        let shown = visibleApps.filter { $0.usage && results[$0.id] != nil }
        switch level {
        case 1:
            var best: (AIApp, Double)?
            for a in shown {
                guard let r = results[a.id], r.error == nil, let m = r.windows.map({ $0.left }).min() else { continue }
                if best == nil || m < best!.1 { best = (a, m) }
            }
            if let b = best { return "\(b.0.letter) \(Int(b.1.rounded()))%" }
            if let a = shown.first { return "\(a.letter) \(shortText(a))" }
            return ""
        case 2:
            return shown.map { "\($0.letter) \(shortText($0))" }.joined(separator: "  ")
        case 3:
            return shown.map { a -> String in
                guard let r = results[a.id], r.error == nil else { return "\(a.letter) !" }
                if a.id == "deepseek", let w = r.wallets.first { return "\(a.letter) " + money(w.currency, w.total, digits: 1) }
                let parts = r.windows.map { String(Int($0.left.rounded())) }
                return parts.isEmpty ? "\(a.letter) …" : "\(a.letter) " + parts.joined(separator: "/") + "%"
            }.joined(separator: "  ")
        default:
            return ""
        }
    }

    var allOk: Bool { results.values.allSatisfy { $0.error == nil } }

    var footerText: String {
        if refreshing { return "正在刷新…" }
        guard let t = lastUpdated else { return "正在加载…" }
        let df = DateFormatter()
        df.dateFormat = "HH:mm"
        return "\(df.string(from: t)) 更新" + (allOk ? "" : " · 部分获取失败")
    }

    func zoom(by delta: Double, popover: Bool) {
        let v = { (x: Double) in min(1.8, max(0.7, ((x + delta) * 20).rounded() / 20)) }
        if popover { popoverScale = v(popoverScale) } else { scale = v(scale) }
    }

    // MARK: 演示数据

    private func loadDemo() {
        let ids = ["claude", "chatgpt", "deepseek", "copilot", "gemini"]
        apps = catalog.filter { ids.contains($0.id) }.map {
            AIApp(id: $0.id, name: $0.name, color: Color(hex: $0.hex), letter: $0.letter, usage: $0.usage,
                  appURL: URL(fileURLWithPath: "/System/Applications/Calculator.app"))
        }
        let n = Date()
        var c = ProviderResult()
        c.plan = "PRO"
        c.windows = [UsageWindow(label: "5 小时", used: 19, resetsAt: n.addingTimeInterval(2 * 3600 + 43 * 60)),
                     UsageWindow(label: "本周 · 全部模型", used: 21, resetsAt: n.addingTimeInterval(3 * 86400))]
        c.loginExpires = n.addingTimeInterval(25 * 86400)
        var g = ProviderResult()
        g.plan = "PLUS · Codex"
        g.windows = [UsageWindow(label: "5 小时", used: 0, resetsAt: n.addingTimeInterval(5 * 3600)),
                     UsageWindow(label: "本周", used: 76, resetsAt: n.addingTimeInterval(2 * 86400))]
        var d = ProviderResult()
        d.plan = "API 余额"
        d.wallets = [Wallet(currency: "CNY", normal: 100, bonus: 5.58, tokens: 0, cost: 0.42)]
        results = ["claude": c, "chatgpt": g, "deepseek": d]
        lastUpdated = n
        if env["AIQUOTA_COMPACT"] == "1" { compact = true } else { compact = false }
        if let lv = env["AIQUOTA_MENULEVEL"], let i = Int(lv) { menuBarLevel = i }
        floating = true
    }
}

func levelColor(_ left: Double) -> Color {
    if left < 10 { return Theme.red }
    if left < 30 { return Theme.amber }
    return Theme.text
}

func balanceColor(_ w: Wallet) -> Color {
    let low: Double = w.currency == "USD" ? 1 : 5
    if w.total <= 0 { return Theme.red }
    if w.total < low { return Theme.amber }
    return Theme.text
}
