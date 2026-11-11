import SwiftUI
import AppKit

// MARK: - 主题（极简风）

enum Theme {
    static let bg = Color(hex: 0x141417, alpha: 0.96)
    static let border = Color.white.opacity(0.08)
    static let divider = Color.white.opacity(0.07)
    static let text = Color(hex: 0xEDEDEF)
    static let sub = Color(hex: 0x8B8B94)
    static let faint = Color(hex: 0x5E5E68)
    static let track = Color.white.opacity(0.11)
    static let off = Color(hex: 0x2A2A30)
    static let amber = Color(hex: 0xE5B454)
    static let red = Color(hex: 0xE5675C)
}

// MARK: - 环境：缩放 / 拖动窗口

private struct ScaleKey: EnvironmentKey { static let defaultValue: CGFloat = 1 }

struct WindowDrag {
    let changed: () -> Void
    let ended: () -> Void
}
private struct DragKey: EnvironmentKey { static let defaultValue: WindowDrag? = nil }

extension EnvironmentValues {
    var uiScale: CGFloat {
        get { self[ScaleKey.self] }
        set { self[ScaleKey.self] = newValue }
    }
    var windowDrag: WindowDrag? {
        get { self[DragKey.self] }
        set { self[DragKey.self] = newValue }
    }
}

extension View {
    /// 只有标题栏 / 胶囊可以拖动窗口（避免和设置里的滑块冲突）
    @ViewBuilder func windowDraggable(_ drag: WindowDrag?) -> some View {
        if let drag = drag {
            self.contentShape(Rectangle()).gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { _ in drag.changed() }
                    .onEnded { _ in drag.ended() }
            )
        } else {
            self
        }
    }
}

// MARK: - 基础组件

struct Dot: View {
    let color: Color
    let size: CGFloat
    var body: some View { Circle().fill(color).frame(width: size, height: size) }
}

struct HoverIconButton: View {
    @Environment(\.uiScale) var s
    let symbol: String
    let help: String
    var size: CGFloat = 11
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * s, weight: .regular))
                .frame(width: 22 * s, height: 22 * s)
                .background(RoundedRectangle(cornerRadius: 6 * s).fill(Color.white.opacity(hover ? 0.08 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(hover ? Theme.text : Theme.sub)
        .onHover { hover = $0 }
        .help(help)
    }
}

struct TextLink: View {
    @Environment(\.uiScale) var s
    let title: String
    var size: CGFloat = 11
    var color: Color = Theme.sub
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: size * s)).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundColor(hover ? Theme.text : color)
        .onHover { hover = $0 }
    }
}

struct MinimalSwitch: View {
    @Environment(\.uiScale) var s
    @Binding var isOn: Bool

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule().fill(isOn ? Theme.text : Theme.off)
            Circle().fill(isOn ? Color(hex: 0x141417) : Theme.sub)
                .frame(width: 10 * s, height: 10 * s)
                .padding(.horizontal, 3 * s)
        }
        .frame(width: 30 * s, height: 16 * s)
        .contentShape(Capsule())
        .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { isOn.toggle() } }
    }
}

struct Segmented: View {
    @Environment(\.uiScale) var s
    let options: [(String, Int)]
    @Binding var selection: Int

    var body: some View {
        HStack(spacing: 2 * s) {
            ForEach(options.indices, id: \.self) { i in
                let opt = options[i]
                let on = opt.1 == selection
                Text(opt.0)
                    .font(.system(size: 11 * s))
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundColor(on ? Color(hex: 0x141417) : Theme.sub)
                    .padding(.horizontal, 8 * s).padding(.vertical, 3 * s)
                    .background(RoundedRectangle(cornerRadius: 6 * s).fill(on ? Theme.text : Color.clear))
                    .contentShape(Rectangle())
                    .onTapGesture { selection = opt.1 }
            }
        }
        .fixedSize()
    }
}

struct ThinBar: View {
    @Environment(\.uiScale) var s
    let fraction: Double
    let color: Color
    @State private var shown = false

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule().fill(color).frame(width: max(0, g.size.width * CGFloat(shown ? fraction : 0)))
            }
        }
        .frame(height: 3 * s)
        .onAppear { withAnimation(.easeOut(duration: 0.6)) { shown = true } }
    }
}

/// 简单的自动换行布局
struct FlowLayout: Layout {
    var spacing: CGFloat = 0

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, width: CGFloat = 0
        for v in subviews {
            let sz = v.sizeThatFits(.unspecified)
            if x > 0 && x + sz.width > maxW { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width
            rowH = max(rowH, sz.height)
            width = max(width, x)
        }
        return CGSize(width: proposal.width ?? width, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let sz = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + sz.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width
            rowH = max(rowH, sz.height)
        }
    }
}

struct PanelDivider: View {
    @Environment(\.uiScale) var s
    var body: some View {
        Rectangle().fill(Theme.divider).frame(height: 1).padding(.vertical, 13 * s)
    }
}

// MARK: - 每个 AI 的内容

struct UsageLine: View {
    @Environment(\.uiScale) var s
    @EnvironmentObject var store: Store
    let w: UsageWindow
    let brand: Color

    var body: some View {
        let num = levelColor(w.left)
        let bar = w.left < 30 ? num : brand
        let rs = formatReset(w.resetsAt, now: store.now)
        VStack(alignment: .leading, spacing: 6 * s) {
            HStack(alignment: .lastTextBaseline, spacing: 0) {
                (Text(w.label).font(.system(size: 11.5 * s)).foregroundColor(Theme.sub)
                    + Text(rs.isEmpty ? "" : "   " + rs).font(.system(size: 10 * s)).foregroundColor(Theme.faint))
                    .lineLimit(1)
                Spacer(minLength: 6 * s)
                Text("\(Int(w.left.rounded()))").font(.system(size: 15 * s, weight: .semibold, design: .rounded)).foregroundColor(num)
                    + Text("%").font(.system(size: 10.5 * s, design: .rounded)).foregroundColor(Theme.sub)
            }
            ThinBar(fraction: w.left / 100, color: bar)
        }
        .padding(.top, 10 * s)
    }
}

struct BalanceLine: View {
    @Environment(\.uiScale) var s
    let wallet: Wallet
    let multi: Bool

    var body: some View {
        let txt = money(wallet.currency, wallet.total)
        VStack(alignment: .leading, spacing: 5 * s) {
            HStack(alignment: .lastTextBaseline, spacing: 0) {
                Text(multi ? "余额 · \(wallet.currency)" : "余额").font(.system(size: 11.5 * s)).foregroundColor(Theme.sub)
                Spacer(minLength: 6 * s)
                Text(String(txt.prefix(1))).font(.system(size: 10.5 * s, design: .rounded)).foregroundColor(Theme.sub)
                    + Text(String(txt.dropFirst())).font(.system(size: 15 * s, weight: .semibold, design: .rounded)).foregroundColor(balanceColor(wallet))
            }
            Text(detail).font(.system(size: 10 * s)).foregroundColor(Theme.faint).lineLimit(2)
        }
        .padding(.top, 10 * s)
    }

    private var detail: String {
        var parts = ["充值 " + money(wallet.currency, wallet.normal), "赠送 " + money(wallet.currency, wallet.bonus)]
        if wallet.cost > 0 { parts.append("已用 " + money(wallet.currency, wallet.cost)) }
        if wallet.tokens > 0 { parts.append("约 \(formatTokens(wallet.tokens)) tokens") }
        return parts.joined(separator: " · ")
    }
}

struct AppSection: View {
    @Environment(\.uiScale) var s
    @EnvironmentObject var store: Store
    let app: AIApp
    let controls: Bool

    var body: some View {
        let r = store.results[app.id]
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Dot(color: app.color, size: 6 * s).padding(.trailing, 8 * s)
                Text(app.name).font(.system(size: 13 * s, weight: .semibold)).foregroundColor(Theme.text)
                if let plan = r?.plan {
                    Text(plan).font(.system(size: 10 * s)).foregroundColor(Theme.faint).padding(.leading, 8 * s)
                }
                Spacer(minLength: 4 * s)
                if app.appURL != nil {
                    HoverIconButton(symbol: "arrow.up.forward.square", help: "打开 \(app.name)", size: 10) { store.open(app) }
                        .opacity(controls ? 1 : 0)
                        .padding(.vertical, -4 * s).padding(.trailing, -5 * s)
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                if let r = r {
                    if let e = r.error {
                        errorView(r, e)
                    } else if app.id == "deepseek" {
                        ForEach(r.wallets) { BalanceLine(wallet: $0, multi: r.wallets.count > 1) }
                    } else {
                        ForEach(r.windows) { UsageLine(w: $0, brand: app.color) }
                        loginHint(r)
                    }
                } else {
                    Text(store.refreshing ? "正在获取…" : "暂无数据")
                        .font(.system(size: 11 * s)).foregroundColor(Theme.faint).padding(.top, 8 * s)
                }
            }
            .padding(.leading, 14 * s)
        }
    }

    @ViewBuilder private func errorView(_ r: ProviderResult, _ e: String) -> some View {
        Text(e).font(.system(size: 11 * s)).foregroundColor(Theme.red)
            .fixedSize(horizontal: false, vertical: true).padding(.top, 8 * s)
        if store.waiting.contains(app.id) {
            Text("正在等待登录完成…").font(.system(size: 10.5 * s)).foregroundColor(Theme.sub).padding(.top, 5 * s)
        } else if r.needsLogin {
            TextLink(title: app.id == "claude" ? "重新登录 →" : "打开 \(app.name) 重新登录 →", size: 11, color: Theme.text) {
                store.relogin(app.id)
            }
            .padding(.top, 6 * s)
        }
    }

    @ViewBuilder private func loginHint(_ r: ProviderResult) -> some View {
        if store.waiting.contains(app.id) {
            Text("正在等待登录完成…").font(.system(size: 10.5 * s)).foregroundColor(Theme.sub).padding(.top, 8 * s)
        } else if let exp = r.loginExpires, exp.timeIntervalSince(store.now) < store.loginWarnDays * 86400 {
            HStack(spacing: 6 * s) {
                Text("登录 \(exp.formatted(.dateTime.month().day())) 过期").font(.system(size: 10.5 * s)).foregroundColor(Theme.amber)
                TextLink(title: "续期 →", size: 10.5, color: Theme.text) { store.relogin(app.id) }
            }
            .padding(.top, 9 * s)
        }
    }
}

struct OthersRow: View {
    @Environment(\.uiScale) var s
    @EnvironmentObject var store: Store
    let apps: [AIApp]

    var body: some View {
        FlowLayout {
            Text("其他").font(.system(size: 10.5 * s)).foregroundColor(Theme.faint).padding(.trailing, 10 * s)
            ForEach(Array(apps.enumerated()), id: \.element.id) { i, a in
                if i > 0 { Text(" · ").font(.system(size: 11 * s)).foregroundColor(Theme.faint) }
                TextLink(title: a.name) { store.open(a) }.help("打开 \(a.name)")
            }
        }
    }
}

// MARK: - 设置页（在面板内部切换，不再弹出单独窗口）

struct SettingRow<Trailing: View>: View {
    @Environment(\.uiScale) var s
    let title: String
    let trailing: Trailing
    init(_ title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }
    var body: some View {
        HStack(spacing: 8 * s) {
            Text(title).font(.system(size: 12 * s)).foregroundColor(Theme.text).lineLimit(1).fixedSize()
            Spacer(minLength: 4 * s)
            trailing
        }
        .padding(.top, 10 * s)
    }
}

struct SettingsPage: View {
    @Environment(\.uiScale) var s
    @Environment(\.windowDrag) var drag
    @EnvironmentObject var store: Store
    let mode: WidgetMode
    let close: () -> Void
    @State private var scanText = "重新扫描电脑 →"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4 * s) {
                HoverIconButton(symbol: "chevron.left", help: "返回", size: 10, action: close).padding(.leading, -6 * s)
                Text("设置").font(.system(size: 13 * s, weight: .semibold)).foregroundColor(Theme.text)
                Spacer()
            }
            .frame(height: 18 * s)
            .windowDraggable(drag)

            label("显示")
            ForEach(store.apps) { a in
                HStack(spacing: 0) {
                    Dot(color: a.color, size: 6 * s).padding(.trailing, 9 * s)
                    VStack(alignment: .leading, spacing: 2 * s) {
                        Text(a.name).font(.system(size: 12 * s)).foregroundColor(Theme.text)
                        Text(store.subtitle(for: a)).font(.system(size: 10 * s)).foregroundColor(Theme.faint)
                    }
                    Spacer(minLength: 4 * s)
                    MinimalSwitch(isOn: Binding(get: { store.isVisible(a.id) }, set: { store.setVisible(a.id, $0) }))
                }
                .padding(.top, 9 * s)
            }
            TextLink(title: scanText) {
                store.rescan()
                scanText = "扫描完成 · 找到 \(store.apps.count) 个"
            }
            .padding(.top, 10 * s).padding(.leading, 15 * s)

            PanelDivider()
            label("菜单栏", top: 0)
            SettingRow("显示内容") {
                Segmented(options: [("图标", 0), ("最低", 1), ("每个", 2), ("详细", 3)], selection: $store.menuBarLevel)
            }
            Text(store.menuBarLevel == 0 ? "菜单栏只显示图标" : "预览：" + store.menuBarText(store.menuBarLevel))
                .font(.system(size: 10 * s)).foregroundColor(Theme.faint).lineLimit(1).padding(.top, 5 * s)
            scaleRow("面板大小", value: $store.popoverScale)

            PanelDivider()
            label("悬浮窗", top: 0)
            SettingRow("显示桌面悬浮窗") { MinimalSwitch(isOn: $store.floating) }
            SettingRow("迷你模式") { MinimalSwitch(isOn: $store.compact) }
            SettingRow("始终置顶") { MinimalSwitch(isOn: $store.topmost) }
            scaleRow("大小", value: $store.scale)

            PanelDivider()
            label("通用", top: 0)
            SettingRow("自动刷新") {
                Segmented(options: [("1", 1), ("2", 2), ("5", 5), ("10", 10), ("30", 30)], selection: $store.refreshMinutes)
                Text("分钟").font(.system(size: 10.5 * s)).foregroundColor(Theme.faint)
            }
            SettingRow("开机自动启动") {
                MinimalSwitch(isOn: Binding(get: { store.launchAtLogin }, set: { store.setLaunchAtLogin($0) }))
            }
            if mode == .popover {
                TextLink(title: "退出 AI 用量", size: 11) { NSApp.terminate(nil) }.padding(.top, 14 * s)
            }
        }
    }

    private func label(_ t: String, top: CGFloat = 14) -> some View {
        Text(t).font(.system(size: 10.5 * s)).foregroundColor(Theme.faint).padding(.top, top * s)
    }

    private func scaleRow(_ title: String, value: Binding<Double>) -> some View {
        HStack(spacing: 8 * s) {
            Text(title).font(.system(size: 12 * s)).foregroundColor(Theme.text)
            Slider(value: value, in: 0.7...1.8, step: 0.05)
                .controlSize(.mini)
                .tint(Theme.text)
            Text("\(Int((value.wrappedValue * 100).rounded()))%")
                .font(.system(size: 10.5 * s)).foregroundColor(Theme.sub).monospacedDigit()
                .frame(width: 34 * s, alignment: .trailing)
        }
        .padding(.top, 10 * s)
    }
}

// MARK: - 整体面板

enum WidgetMode { case popover, floating }

struct WidgetView: View {
    @EnvironmentObject var store: Store
    @Environment(\.windowDrag) var drag
    let mode: WidgetMode
    @State private var hovering = false
    @State private var showSettings = ProcessInfo.processInfo.environment["AIQUOTA_PAGE"] == "settings"

    var body: some View {
        let s = CGFloat(mode == .popover ? store.popoverScale : store.scale)
        let controls = mode == .popover || hovering || store.forceHover
        VStack(alignment: .leading, spacing: 0) {
            if showSettings {
                SettingsPage(mode: mode) { showSettings = false }
            } else {
                header(s, controls)
                content(s, controls)
                footer(s, controls)
            }
        }
        .padding(.horizontal, 18 * s)
        .padding(.top, 13 * s)
        .padding(.bottom, 12 * s)
        .frame(width: 280 * s, alignment: .leading)
        .background(background(s))
        .onHover { hovering = $0 }
        .environment(\.uiScale, s)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private func background(_ s: CGFloat) -> some View {
        if mode == .floating {
            RoundedRectangle(cornerRadius: 14 * s, style: .continuous)
                .fill(Theme.bg)
                .overlay(RoundedRectangle(cornerRadius: 14 * s, style: .continuous).stroke(Theme.border, lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 12, y: 2)
        } else {
            Color(hex: 0x141417)
        }
    }

    private func header(_ s: CGFloat, _ controls: Bool) -> some View {
        HStack(spacing: 0) {
            Text("AI 用量").font(.system(size: 11.5 * s)).foregroundColor(Theme.sub)
            Spacer(minLength: 8 * s)
            HStack(spacing: 2 * s) {
                if mode == .floating {
                    HoverIconButton(symbol: "arrow.down.right.and.arrow.up.left", help: "迷你模式", size: 10) { store.compact = true }
                }
                HoverIconButton(symbol: "gearshape", help: "设置") { showSettings = true }
                HoverIconButton(symbol: "arrow.clockwise", help: "立即刷新") { Task { await store.refresh() } }
                if mode == .floating {
                    HoverIconButton(symbol: "minus", help: "隐藏悬浮窗（菜单栏仍可查看）") { store.floating = false }
                }
            }
            .opacity(controls ? 1 : 0)
            .padding(.trailing, -6 * s)
        }
        .frame(height: 18 * s)
        .windowDraggable(drag)
    }

    @ViewBuilder private func content(_ s: CGFloat, _ controls: Bool) -> some View {
        let vis = store.visibleApps
        let usage = vis.filter { $0.usage }
        let others = vis.filter { !$0.usage }
        if vis.isEmpty {
            Text("没有要显示的 AI。点 ⚙ 选择要显示哪些。")
                .font(.system(size: 11 * s)).foregroundColor(Theme.sub).padding(.top, 12 * s)
        }
        ForEach(Array(usage.enumerated()), id: \.element.id) { i, app in
            if i == 0 { Color.clear.frame(height: 12 * s) } else { PanelDivider() }
            AppSection(app: app, controls: controls)
        }
        if !others.isEmpty {
            if usage.isEmpty { Color.clear.frame(height: 12 * s) } else { PanelDivider() }
            OthersRow(apps: others)
        }
    }

    private func footer(_ s: CGFloat, _ controls: Bool) -> some View {
        let value = mode == .popover ? store.popoverScale : store.scale
        return HStack(spacing: 0) {
            Text(store.footerText).font(.system(size: 10 * s)).foregroundColor(Theme.faint)
            Spacer(minLength: 6 * s)
            HStack(spacing: 0) {
                HoverIconButton(symbol: "minus", help: "缩小", size: 9) { store.zoom(by: -0.1, popover: mode == .popover) }
                Text("\(Int((value * 100).rounded()))%")
                    .font(.system(size: 10 * s)).foregroundColor(Theme.faint)
                    .frame(minWidth: 32 * s)
                    .onTapGesture { if mode == .popover { store.popoverScale = 1 } else { store.scale = 1 } }
                    .help("点击恢复 100%")
                HoverIconButton(symbol: "plus", help: "放大", size: 9) { store.zoom(by: 0.1, popover: mode == .popover) }
            }
            .opacity(controls ? 1 : 0)
            .padding(.trailing, -6 * s)
        }
        .padding(.top, 14 * s)
    }
}

/// 迷你模式：小胶囊
struct PillView: View {
    @EnvironmentObject var store: Store
    @Environment(\.windowDrag) var drag

    var body: some View {
        let s = CGFloat(store.scale)
        HStack(spacing: 13 * s) {
            ForEach(store.visibleApps.filter { $0.usage }) { a in
                HStack(spacing: 6 * s) {
                    Dot(color: a.color, size: 6 * s)
                    Text(store.shortText(a))
                        .font(.system(size: 12.5 * s, weight: .semibold, design: .rounded))
                        .foregroundColor(store.shortColor(a))
                }
            }
            HoverIconButton(symbol: "arrow.up.left.and.arrow.down.right", help: "展开", size: 9) { store.compact = false }
        }
        .padding(.leading, 14 * s).padding(.trailing, 5 * s).padding(.vertical, 5 * s)
        .background(
            Capsule().fill(Theme.bg)
                .overlay(Capsule().stroke(Theme.border, lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 12, y: 2)
        )
        .environment(\.uiScale, s)
        .environment(\.colorScheme, .dark)
        .windowDraggable(drag)
        .onTapGesture(count: 2) { store.compact = false }
        .help(store.menuBarText(2).isEmpty ? "双击展开" : store.menuBarText(2) + "\n双击展开")
    }
}

struct MenuBarLabel: View {
    @EnvironmentObject var store: Store
    var body: some View {
        let text = store.menuBarText(store.menuBarLevel)
        if store.menuBarLevel == 0 || text.isEmpty {
            Image(systemName: "gauge.medium")
        } else {
            Text(text)
        }
    }
}
