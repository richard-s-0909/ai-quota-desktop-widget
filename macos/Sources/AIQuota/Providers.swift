import Foundation
import Security

// MARK: - Claude 登录信息（macOS 上 Claude Code 存在钥匙串里）

enum ClaudeCreds {
    static let service = "Claude Code-credentials"

    enum Source { case keychain, file }

    static var exists: Bool {
        keychainExists() || FileManager.default.fileExists(atPath: Paths.claudeFile.path)
    }

    /// 只查属性不取数据，不会弹出钥匙串授权框
    static func keychainExists() -> Bool {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess
    }

    static func load() throws -> (Data, Source) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data {
            return (d, .keychain)
        }
        if let d = try? Data(contentsOf: Paths.claudeFile) { return (d, .file) }
        throw LoginNeeded("Claude 未登录（没找到 Claude Code 的登录）")
    }

    /// 用原数据“空写”一次，确认之后能把续期结果写回去
    static func canWrite(_ original: Data, _ src: Source) -> Bool {
        switch src {
        case .file:
            return FileManager.default.isWritableFile(atPath: Paths.claudeFile.path)
        case .keychain:
            let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
            return SecItemUpdate(q as CFDictionary, [kSecValueData as String: original] as CFDictionary) == errSecSuccess
        }
    }

    static func save(_ data: Data, _ src: Source) throws {
        switch src {
        case .file:
            let bak = Paths.claudeFile.appendingPathExtension("bak")
            try? FileManager.default.removeItem(at: bak)
            try? FileManager.default.copyItem(at: Paths.claudeFile, to: bak)
            try data.write(to: Paths.claudeFile, options: .atomic)
        case .keychain:
            let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
            let st = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if st != errSecSuccess { throw AppError("无法写回 Claude 登录信息（钥匙串 \(st)）") }
        }
    }
}

// MARK: - Claude：订阅额度（与 claude.ai「设置 → 用量」同一额度池）

enum ClaudeProvider {
    static let labels = [
        "five_hour": "5 小时", "seven_day": "本周 · 全部模型", "seven_day_opus": "本周 · Opus",
        "seven_day_sonnet": "本周 · Sonnet", "seven_day_oauth_apps": "本周 · 应用", "extra_usage": "额外用量",
    ]
    static let order = ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet", "seven_day_oauth_apps", "extra_usage"]

    static func fetch() async -> ProviderResult {
        var r = ProviderResult()
        do {
            let (raw, src) = try ClaudeCreds.load()
            guard var root = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
                  var o = root["claudeAiOauth"] as? [String: Any],
                  var token = o["accessToken"] as? String else {
                throw LoginNeeded("Claude Code 没有用 Claude 订阅账号登录")
            }
            if let rte = num(o["refreshTokenExpiresAt"]) { r.loginExpires = Date(timeIntervalSince1970: rte / 1000) }
            r.plan = (o["subscriptionType"] as? String)?.uppercased()

            // access token 快过期：先确认能写回，再续期（否则会让 Claude Code 自己的登录失效）
            let nowMs = Date().timeIntervalSince1970 * 1000
            if let exp = num(o["expiresAt"]), exp < nowMs + 120_000, let rt = o["refreshToken"] as? String {
                guard ClaudeCreds.canWrite(raw, src) else {
                    throw AppError("Claude 令牌已过期：打开一次 Claude Code 即可续期")
                }
                let t = try await refresh(rt)
                guard let at = t["access_token"] as? String else { throw LoginNeeded("Claude 登录已失效") }
                token = at
                o["accessToken"] = at
                if let nrt = t["refresh_token"] as? String { o["refreshToken"] = nrt }
                if let ei = num(t["expires_in"]) { o["expiresAt"] = Int64(nowMs + ei * 1000) }
                root["claudeAiOauth"] = o
                try ClaudeCreds.save(try JSONSerialization.data(withJSONObject: root), src)
            }

            let (code, data) = try await HTTP.get("https://api.anthropic.com/api/oauth/usage", headers: [
                "Authorization": "Bearer \(token)",
                "anthropic-beta": "oauth-2025-04-20",
                "Accept": "application/json",
                "User-Agent": "claude-code/2.0",
            ])
            if code == 401 { throw LoginNeeded("Claude 登录已失效") }
            guard code == 200 else { throw AppError("获取失败 (HTTP \(code))") }
            let j = HTTP.json(data)
            let keys = order.filter { j[$0] != nil } + j.keys.filter { !order.contains($0) }.sorted()
            for k in keys {
                guard let v = j[k] as? [String: Any], let u = num(v["utilization"]) else { continue }
                r.windows.append(UsageWindow(label: labels[k] ?? k, used: u, resetsAt: parseISODate(v["resets_at"] as? String)))
            }
        } catch {
            r.apply(error)
        }
        return r
    }

    private static func refresh(_ refreshToken: String) async throws -> [String: Any] {
        let body: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
        ]
        var lastCode = 0
        for u in ["https://platform.claude.com/v1/oauth/token", "https://console.anthropic.com/v1/oauth/token"] {
            if let res = try? await HTTP.postJSON(u, body: body, headers: ["User-Agent": "claude-cli"]) {
                if res.0 == 200 { return HTTP.json(res.1) }
                lastCode = res.0
            }
        }
        if [400, 401, 403].contains(lastCode) { throw LoginNeeded("Claude 登录已失效") }
        throw AppError("令牌续期失败（网络问题？），稍后会自动重试")
    }
}

// MARK: - ChatGPT：借用 Codex 的 ChatGPT 登录，显示 Codex 额度

enum ChatGPTProvider {
    static func fetch() async -> ProviderResult {
        var r = ProviderResult()
        do {
            guard let raw = try? Data(contentsOf: Paths.codexAuth) else {
                throw LoginNeeded("没找到 Codex 登录 (~/.codex/auth.json)")
            }
            let tokens = HTTP.json(raw)["tokens"] as? [String: Any] ?? [:]
            guard let at = tokens["access_token"] as? String else { throw AppError("Codex 没有用 ChatGPT 账号登录") }
            var h = ["Authorization": "Bearer \(at)", "Accept": "application/json", "User-Agent": "codex-usage-widget"]
            if let acc = tokens["account_id"] as? String { h["ChatGPT-Account-Id"] = acc }
            let (code, data) = try await HTTP.get("https://chatgpt.com/backend-api/wham/usage", headers: h)
            if code == 401 { throw LoginNeeded("ChatGPT / Codex 登录已过期") }
            guard code == 200 else { throw AppError("获取失败 (HTTP \(code))") }
            let d = HTTP.json(data)
            if let p = d["plan_type"] as? String { r.plan = p.uppercased() + " · Codex" }
            let rl = d["rate_limit"] as? [String: Any] ?? [:]
            for key in ["primary_window", "secondary_window"] {
                guard let w = rl[key] as? [String: Any] else { continue }
                let sec = num(w["limit_window_seconds"]) ?? 0
                let label: String
                if sec == 18000 { label = "5 小时" }
                else if sec == 604800 { label = "本周" }
                else if sec >= 86400 { label = "\(Int((sec / 86400).rounded())) 天" }
                else { label = "\(Int((sec / 3600).rounded())) 小时" }
                let reset = num(w["reset_at"]).map { Date(timeIntervalSince1970: $0) }
                r.windows.append(UsageWindow(label: label, used: num(w["used_percent"]) ?? 0, resetsAt: reset))
            }
        } catch {
            r.apply(error)
        }
        return r
    }
}

// MARK: - DeepSeek：借用 DeepSeek Harness 的账号登录，查询平台账户余额

enum DeepSeekProvider {
    static func fetch() async -> ProviderResult {
        var r = ProviderResult()
        r.plan = "API 余额"
        do {
            guard let y = try? String(contentsOf: Paths.dshCred, encoding: .utf8) else {
                throw LoginNeeded("DeepSeek Harness 未登录")
            }
            guard let token = capture(y, #"deepseek-account-platform/default:[\s\S]*?token:\s*["']?([^"'\s]+)"#) else {
                throw LoginNeeded("DeepSeek Harness 没有登录 DeepSeek 账号")
            }
            var origin = "https://platform.deepseek.com"
            if let iss = capture(y, #"deepseek-account-platform/default:[\s\S]*?issuer:\s*["']?(https://[^"'\s]+)"#),
               iss.range(of: #"^https://([a-z0-9-]+\.)*deepseek\.com/?$"#, options: .regularExpression) != nil {
                origin = iss.hasSuffix("/") ? String(iss.dropLast()) : iss
            }
            // 与 DeepSeek Harness 自己查余额的方式一致：令牌放在 x-dsh-auth-token 头里
            let (code, data) = try await HTTP.get(origin + "/api/v0/users/get_user_summary", headers: [
                "x-dsh-auth-token": token, "Accept": "application/json", "User-Agent": "ai-usage-widget",
            ])
            if code == 401 { throw LoginNeeded("DeepSeek 登录已失效") }
            guard code == 200 else { throw AppError("获取失败 (HTTP \(code))") }
            let j = HTTP.json(data)
            if num(j["code"]) == 40003 { throw LoginNeeded("DeepSeek 登录已失效") }
            let dd = j["data"] as? [String: Any] ?? [:]
            guard num(j["code"]) == 0, num(dd["biz_code"]) == 0, let bd = dd["biz_data"] as? [String: Any] else {
                throw AppError("获取失败 (code \(String(describing: j["code"] ?? "?")))")
            }

            var order: [String] = []
            var map: [String: Wallet] = [:]
            func slot(_ c: String) {
                if map[c] == nil {
                    map[c] = Wallet(currency: c, normal: 0, bonus: 0, tokens: 0, cost: 0)
                    order.append(c)
                }
            }
            for w in bd["normal_wallets"] as? [[String: Any]] ?? [] {
                let c = w["currency"] as? String ?? "CNY"; slot(c)
                map[c]!.normal += num(w["balance"]) ?? 0
                map[c]!.tokens += num(w["token_estimation"]) ?? 0
            }
            for w in bd["bonus_wallets"] as? [[String: Any]] ?? [] {
                let c = w["currency"] as? String ?? "CNY"; slot(c)
                map[c]!.bonus += num(w["balance"]) ?? 0
                map[c]!.tokens += num(w["token_estimation"]) ?? 0
            }
            for w in bd["total_costs"] as? [[String: Any]] ?? [] {
                let c = w["currency"] as? String ?? "CNY"; slot(c)
                map[c]!.cost += num(w["amount"]) ?? 0
            }
            var list = order.compactMap { map[$0] }.filter { abs($0.total) > 1e-6 || $0.cost > 1e-6 }
            list.sort { ($0.currency == "CNY" ? 0 : 1) < ($1.currency == "CNY" ? 0 : 1) }
            if list.isEmpty { list = [Wallet(currency: "CNY", normal: 0, bonus: 0, tokens: 0, cost: 0)] }
            r.wallets = list
        } catch {
            r.apply(error)
        }
        return r
    }
}
