import SwiftUI
import AppKit

// MARK: - 缩放

private struct ScaleKey: EnvironmentKey { static let defaultValue: CGFloat = 1 }
extension EnvironmentValues {
    var uiScale: CGFloat {
        get { self[ScaleKey.self] }
        set { self[ScaleKey.self] = newValue }
    }
}

let accentColor = Color(hex: 0x8B7CFF)

// MARK: - 基础组件

struct CardBackground: View {
    let radius: CGFloat
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        shape
            .fill(LinearGradient(colors: [Color(hex: 0x232430, alpha: 0.97), Color(hex: 0x14151B, alpha: 0.97)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(shape.stroke(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.04)],
                                                 startPoint: .top, endPoint: .bottom), lineWidth: 1))
            .shadow(color: .black.opacity(0.45), radius: 14, y: 4)
    }
}

struct Badge: View {
    let app: AIApp
    let size: CGFloat
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
        shape
            .fill(app.color)
            .overlay(shape.fill(LinearGradient(colors: [.white.opacity(0.28), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)))
            .frame(width: size, height: size)
            .overlay(
                Text(app.letter)
                    .font(.system(size: size * (app.letter.count > 1 ? 0.4 : 0.5), weight: .bold))
                    .foregroundColor(.white)
            )
    }
}

struct AppMark: View {
    let size: CGFloat
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
            .fill(LinearGradient(colors: [Color(hex: 0x9B8CFF), Color(hex: 0x5AC8FA)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay(Text("AI").font(.system(size: size * 0.43, weight: .bold)).foregroundColor(.white))
    }
}

struct IconButton: View {
    @Environment(\.uiScale) var s
    let symbol: String
    let help: String
    var size: CGFloat = 12
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * s, weight: .medium))
                .frame(width: 24 * s, height: 24 * s)
                .background(RoundedRectangle(cornerRadius: 7 * s).fill(Color.white.opacity(hover ? 0.13 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(.white.opacity(hover ? 1 : 0.72))
        .onHover { hover = $0 }
        .help(help)
    }
}

struct PillButton: View {
    @Environment(\.uiScale) var s
    let title: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11 * s))
                .padding(.horizontal, 10 * s).padding(.vertical, 4 * s)
                .background(RoundedRectangle(cornerRadius: 8 * s).fill(Color.white.opacity(hover ? 0.17 : 0.09)))
                .overlay(RoundedRectangle(cornerRadius: 8 * s).stroke(Color.white.opacity(0.08), lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(.white.opacity(0.92))
        .onHover { hover = $0 }
    }
}

struct CardBox<Content: View>: View {
    @Environment(\.uiScale) var s
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(.horizontal, 12 * s)
            .padding(.top, 10 * s)
            .padding(.bottom, 11 * s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 13 * s, style: .continuous).fill(Color.white.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 13 * s, style: .continuous).stroke(Color.white.opacity(0.07), lineWidth: 1))
    }
}

/// 进度条，出现时从 0 滑到目标值
struct Bar: View {
    @Environment(\.uiScale) var s
    let fraction: Double
    let color: Color
    @State private var shown = false

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.09))
                Capsule()
                    .fill(LinearGradient(colors: [color, color.opacity(0.65)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(0, g.size.width * CGFloat(shown ? fraction : 0)))
            }
        }
        .frame(height: 6 * s)
        .onAppear { withAnimation(.easeOut(duration: 0.6)) { shown = true } }
    }
}

/// 简单的自动换行布局
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, width: CGFloat = 0
        for v in subviews {
            let sz = v.sizeThatFits(.unspecified)
            if x > 0 && x + sz.width > maxW { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
            width = max(width, x - spacing)
        }
        return CGSize(width: proposal.width ?? width, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let sz = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + sz.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
    }
}

// MARK: - 卡片内容

struct WindowRow: View {
    @Environment(\.uiScale) var s
    @EnvironmentObject var store: Store
    let w: UsageWindow
    let brand: Color

    var body: some View {
        let c = leftColor(w.left, brand)
        let rs = formatReset(w.resetsAt, now: store.now)
        VStack(alignment: .leading, spacing: 5 * s) {
            HStack(alignment: .lastTextBaseline) {
                Text(w.label).font(.system(size: 11.5 * s)).foregroundColor(.white.opacity(0.72))
                Spacer()
                Text("剩余 ").font(.system(size: 10 * s)).foregroundColor(.white.opacity(0.45))
                    + Text("\(Int(w.left.rounded()))").font(.system(size: 16 * s, weight: .semibold, design: .rounded)).foregroundColor(c)
                    + Text("%").font(.system(size: 11 * s, weight: .semibold, design: .rounded)).foregroundColor(c)
            }
            Bar(fraction: w.left / 100, color: c)
            if !rs.isEmpty {
                HStack(spacing: 4 * s) {
                    Image(systemName: "clock").font(.system(size: 9 * s))
                    Text(rs).font(.system(size: 10 * s))
                }
                .foregroundColor(.white.opacity(0.4))
            }
        }
        .padding(.top, 10 * s)
    }
}

struct BalanceRow: View {
    @Environment(\.uiScale) var s
    let wallet: Wallet
    let multi: Bool

    var body: some View {
        let c = balanceColor(wallet)
        let txt = money(wallet.currency, wallet.total)
        VStack(alignment: .leading, spacing: 6 * s) {
            HStack(alignment: .lastTextBaseline) {
                Text(multi ? "账户余额 · \(wallet.currency)" : "账户余额")
                    .font(.system(size: 11.5 * s)).foregroundColor(.white.opacity(0.72))
                Spacer()
                Text(String(txt.prefix(1))).font(.system(size: 13 * s, weight: .semibold, design: .rounded)).foregroundColor(c)
                    + Text(String(txt.dropFirst())).font(.system(size: 20 * s, weight: .semibold, design: .rounded)).foregroundColor(c)
            }
            if wallet.total > 0 {
                GeometryReader { g in
                    let both = wallet.normal > 0 && wallet.bonus > 0
                    HStack(spacing: both ? 2 : 0) {
                        Capsule().fill(Color(hex: 0x4D6BFE))
                            .frame(width: max(0, (g.size.width - (both ? 2 : 0)) * CGFloat(max(0, wallet.normal) / wallet.total)))
                        Capsule().fill(Color(hex: 0x22D3EE))
                    }
                }
                .frame(height: 6 * s)
            }
            HStack(spacing: 12 * s) {
                legend(Color(hex: 0x4D6BFE), "充值 " + money(wallet.currency, wallet.normal))
                legend(Color(hex: 0x22D3EE), "赠送 " + money(wallet.currency, wallet.bonus))
            }
            let meta = metaText
            if !meta.isEmpty {
                HStack(spacing: 4 * s) {
                    Image(systemName: "creditcard").font(.system(size: 9 * s))
                    Text(meta).font(.system(size: 10 * s))
                }
                .foregroundColor(.white.opacity(0.4))
            }
        }
        .padding(.top, 10 * s)
    }

    private var metaText: String {
        var parts: [String] = []
        if wallet.tokens > 0 { parts.append("约可用 \(formatTokens(wallet.tokens)) tokens") }
        if wallet.cost > 0 { parts.append("累计消费 " + money(wallet.currency, wallet.cost)) }
        return parts.joined(separator: " · ")
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 5 * s) {
            Circle().fill(color).frame(width: 6 * s, height: 6 * s)
            Text(text).font(.system(size: 10.5 * s)).foregroundColor(.white.opacity(0.6))
        }
    }
}

struct ErrorBox: View {
    @Environment(\.uiScale) var s
    @EnvironmentObject var store: Store
    let app: AIApp
    let message: String
    let needsLogin: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7 * s) {
            HStack(alignment: .top, spacing: 6 * s) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(message).fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 11 * s))
            .foregroundColor(Color(hex: 0xFCA5A5))
            if store.waiting.contains(app.id) {
                Text("正在等待登录完成…").font(.system(size: 10.5 * s)).foregroundColor(.white.opacity(0.7))
            } else if needsLogin {
                PillButton(title: app.id == "claude" ? "重新登录" : "打开 \(app.name) 重新登录") { store.relogin(app.id) }
            }
        }
        .padding(10 * s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9 * s).fill(Color(hex: 0xF87171).opacity(0.13)))
        .padding(.top, 10 * s)
    }
}

struct UsageCard: View {
    @Environment(\.uiScale) var s
    @EnvironmentObject var store: Store
    let app: AIApp

    var body: some View {
        let r = store.results[app.id]
        CardBox {
            HStack(spacing: 8 * s) {
                Badge(app: app, size: 22 * s)
                Text(app.name).font(.system(size: 13.5 * s, weight: .semibold)).foregroundColor(.white)
                if let plan = r?.plan {
                    Text(plan)
                        .font(.system(size: 9.5 * s, weight: .semibold))
                        .foregroundColor(app.color)
                        .brightness(0.2)
                        .padding(.horizontal, 6 * s).padding(.vertical, 1.5 * s)
                        .background(RoundedRectangle(cornerRadius: 5 * s).fill(app.color.opacity(0.2)))
                }
                Spacer()
                if app.appURL != nil {
                    IconButton(symbol: "arrow.up.forward.app", help: "打开 \(app.name)", size: 11) { store.open(app) }
                }
            }
            if let r = r {
                if let e = r.error {
                    ErrorBox(app: app, message: e, needsLogin: r.needsLogin)
                } else if app.id == "deepseek" {
                    ForEach(r.wallets) { BalanceRow(wallet: $0, multi: r.wallets.count > 1) }
                } else {
                    ForEach(r.windows) { WindowRow(w: $0, brand: app.color) }
                    if store.waiting.contains(app.id) {
                        Text("正在等待登录完成…").font(.system(size: 10.5 * s)).foregroundColor(.white.opacity(0.7)).padding(.top, 8 * s)
                    } else if let exp = r.loginExpires, exp.timeIntervalSince(store.now) < store.loginWarnDays * 86400 {
                        HStack {
                            Text("登录将于 \(exp.formatted(.dateTime.month().day())) 过期")
                                .font(.system(size: 10.5 * s)).foregroundColor(Color(hex: 0xFBBF24))
                            Spacer()
                            PillButton(title: "续期") { store.relogin(app.id) }
                        }
                        .padding(.top, 9 * s)
                    }
                }
            } else {
                Text(store.refreshing ? "正在获取…" : "暂无数据")
                    .font(.system(size: 11 * s)).foregroundColor(.white.opacity(0.5)).padding(.top, 10 * s)
            }
        }
    }
}

struct OthersCard: View {
    @Environment(\.uiScale) var s
    @EnvironmentObject var store: Store
    let apps: [AIApp]

    var body: some View {
        CardBox {
            HStack(spacing: 8 * s) {
                Text("其他 AI").font(.system(size: 12.5 * s, weight: .semibold)).foregroundColor(.white.opacity(0.9))
                Text("无公开用量数据 · 点击打开").font(.system(size: 10 * s)).foregroundColor(.white.opacity(0.35))
            }
            FlowLayout(spacing: 6 * s) {
                ForEach(apps) { a in
                    Button { store.open(a) } label: {
                        HStack(spacing: 6 * s) {
                            Badge(app: a, size: 16 * s)
                            Text(a.name).font(.system(size: 11 * s))
                        }
                        .padding(.vertical, 4 * s).padding(.leading, 5 * s).padding(.trailing, 9 * s)
                        .background(RoundedRectangle(cornerRadius: 8 * s).fill(Color.white.opacity(0.08)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.white.opacity(0.9))
                    .help("打开 \(a.name)")
                }
            }
            .padding(.top, 8 * s)
        }
    }
}

// MARK: - 整体

enum WidgetMode { case popover, floating }

struct WidgetView: View {
    @EnvironmentObject var store: Store
    let mode: WidgetMode

    var body: some View {
        let s = CGFloat(store.scale)
        let vis = store.visibleApps
        let others = vis.filter { !$0.usage }
        VStack(alignment: .leading, spacing: 10 * s) {
            HStack(spacing: 8 * s) {
                AppMark(size: 22 * s)
                Text("AI 用量").font(.system(size: 14.5 * s, weight: .semibold))
                Spacer()
                if mode == .floating {
                    IconButton(symbol: "minus", help: "迷你模式") { store.compact = true }
                }
                IconButton(symbol: "gearshape", help: "设置") { store.openSettings?() }
                IconButton(symbol: "arrow.clockwise", help: "立即刷新") { Task { await store.refresh() } }
                if mode == .floating {
                    IconButton(symbol: "xmark", help: "隐藏悬浮窗（菜单栏图标仍在）") { store.floating = false }
                } else {
                    IconButton(symbol: "power", help: "退出") { NSApp.terminate(nil) }
                }
            }
            if vis.isEmpty {
                CardBox {
                    Text("没有要显示的 AI。点 ⚙ 设置选择要显示哪些。")
                        .font(.system(size: 11 * s)).foregroundColor(.white.opacity(0.6))
                }
            }
            ForEach(vis.filter { $0.usage }) { UsageCard(app: $0) }
            if !others.isEmpty { OthersCard(apps: others) }
            HStack(spacing: 6 * s) {
                Circle().fill(store.allOk ? Color(hex: 0x4ADE80) : Color(hex: 0xFBBF24)).frame(width: 6 * s, height: 6 * s)
                Text(store.footerText).font(.system(size: 10.5 * s)).foregroundColor(.white.opacity(0.45))
                Spacer()
                IconButton(symbol: "minus.magnifyingglass", help: "缩小", size: 11) { store.zoom(by: -0.1) }
                Text("\(Int((store.scale * 100).rounded()))%")
                    .font(.system(size: 10.5 * s)).foregroundColor(.white.opacity(0.6))
                    .frame(minWidth: 30 * s)
                    .onTapGesture { store.scale = 1 }
                    .help("点击恢复 100%")
                IconButton(symbol: "plus.magnifyingglass", help: "放大", size: 11) { store.zoom(by: 0.1) }
            }
            .padding(.leading, 2 * s)
        }
        .foregroundColor(.white)
        .padding(14 * s)
        .frame(width: 300 * s)
        .background(mode == .floating ? AnyView(CardBackground(radius: 18 * s)) : AnyView(Color(hex: 0x17181F)))
        .environment(\.uiScale, s)
        .environment(\.colorScheme, .dark)
    }
}

/// 迷你模式：小胶囊
struct PillView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let s = CGFloat(store.scale)
        HStack(spacing: 10 * s) {
            ForEach(store.visibleApps.filter { $0.usage }) { a in
                HStack(spacing: 5 * s) {
                    Badge(app: a, size: 17 * s)
                    Text(store.shortText(a))
                        .font(.system(size: 13 * s, weight: .semibold, design: .rounded))
                        .foregroundColor(store.shortColor(a))
                }
            }
            IconButton(symbol: "arrow.up.left.and.arrow.down.right", help: "展开", size: 10) { store.compact = false }
        }
        .padding(.leading, 11 * s).padding(.trailing, 5 * s).padding(.vertical, 5 * s)
        .background(CardBackground(radius: 17 * s))
        .environment(\.uiScale, s)
        .help(store.summaryText.isEmpty ? "双击展开" : store.summaryText + "\n双击展开")
        .onTapGesture(count: 2) { store.compact = false }
    }
}

struct MenuBarLabel: View {
    @EnvironmentObject var store: Store
    var body: some View {
        if store.menuBarSummary && !store.summaryText.isEmpty {
            Text(store.summaryText)
        } else {
            Image(systemName: "gauge.medium")
        }
    }
}

// MARK: - 设置

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @State private var scanText = "重新扫描电脑"

    var body: some View {
        Form {
            Section("显示哪些 AI") {
                ForEach(store.apps) { a in
                    Toggle(isOn: Binding(get: { store.isVisible(a.id) }, set: { store.setVisible(a.id, $0) })) {
                        HStack(spacing: 10) {
                            Badge(app: a, size: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(a.name)
                                Text(store.subtitle(for: a)).font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                }
                Button(scanText) {
                    store.rescan()
                    scanText = "扫描完成 · 找到 \(store.apps.count) 个"
                }
            }
            Section("外观") {
                Toggle("桌面悬浮窗", isOn: $store.floating)
                Toggle("迷你模式", isOn: $store.compact)
                Toggle("悬浮窗始终置顶", isOn: $store.topmost)
                Toggle("菜单栏显示剩余数字", isOn: $store.menuBarSummary)
                HStack {
                    Text("大小")
                    Slider(value: $store.scale, in: 0.7...1.8, step: 0.05)
                    Text("\(Int((store.scale * 100).rounded()))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                }
            }
            Section("自动刷新") {
                Picker("间隔", selection: $store.refreshMinutes) {
                    ForEach([1, 2, 5, 10, 15, 30], id: \.self) { Text("\($0) 分钟").tag($0) }
                }
            }
            Section("其他") {
                Toggle("开机自动启动", isOn: Binding(get: { store.launchAtLogin }, set: { store.setLaunchAtLogin($0) }))
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
    }
}
