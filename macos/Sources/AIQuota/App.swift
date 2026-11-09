import SwiftUI
import AppKit
import Combine

@main
struct AIQuotaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject var store = Store.shared

    var body: some Scene {
        // 菜单栏图标：点开显示完整卡片
        MenuBarExtra {
            WidgetView(mode: .popover).environmentObject(store)
        } label: {
            MenuBarLabel().environmentObject(store)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: FloatingPanelController?
    var settings: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in self.setup() }
    }

    @MainActor
    func setup() {
        NSApp.setActivationPolicy(.accessory)   // 不在程序坞显示图标
        let store = Store.shared
        let settings = SettingsWindowController()
        self.settings = settings
        store.openSettings = { settings.show(store: store) }
        panel = FloatingPanelController(store: store)
    }
}

// MARK: - 设置窗口

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?

    func show(store: Store) {
        if window == nil {
            let host = NSHostingController(rootView: SettingsView().environmentObject(store))
            let w = NSWindow(contentViewController: host)
            w.title = "AI 用量 · 设置"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - 桌面悬浮窗

private struct SizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

struct FloatingRoot: View {
    @EnvironmentObject var store: Store
    let controller: FloatingPanelController

    var body: some View {
        Group {
            if store.compact { PillView() } else { WidgetView(mode: .floating) }
        }
        .padding(16)                       // 给阴影留空间
        .fixedSize()
        .background(GeometryReader { g in Color.clear.preference(key: SizeKey.self, value: g.size) })
        .onPreferenceChange(SizeKey.self) { size in controller.resize(to: size) }
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { _ in controller.dragChanged() }
                .onEnded { _ in controller.dragEnded() }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

@MainActor
final class FloatingPanelController {
    let panel: NSPanel
    private let store: Store
    private var bag = Set<AnyCancellable>()
    private var startMouse: NSPoint?
    private var startOrigin: NSPoint?

    init(store: Store) {
        self.store = store
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 480),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let host = NSHostingView(rootView: FloatingRoot(controller: self).environmentObject(store))
        host.sizingOptions = []            // 窗口大小由 resize(to:) 控制
        panel.contentView = host

        // 恢复上次的位置（记录的是左上角），默认放在屏幕右上角
        let ud = UserDefaults.standard
        if ud.object(forKey: "panelX") != nil {
            let x = ud.double(forKey: "panelX"), top = ud.double(forKey: "panelTop")
            panel.setFrameTopLeftPoint(NSPoint(x: x, y: top))
        } else if let vf = NSScreen.main?.visibleFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: vf.maxX - 350, y: vf.maxY - 10))
        }
        ensureOnScreen()

        store.$floating.sink { [weak self] on in self?.setVisible(on) }.store(in: &bag)
        store.$topmost.sink { [weak self] top in self?.panel.level = top ? .floating : .normal }.store(in: &bag)
    }

    func setVisible(_ on: Bool) {
        if on { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
    }

    /// 内容大小变化时调整窗口；在屏幕右半边时保持右边缘不动
    func resize(to size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        var f = panel.frame
        let top = f.maxY
        let screenMid = (panel.screen ?? NSScreen.main)?.visibleFrame.midX ?? 0
        let onRight = f.midX > screenMid
        let oldW = f.width
        f.size = size
        f.origin.y = top - size.height
        if onRight { f.origin.x += oldW - size.width }
        panel.setFrame(f, display: true)
    }

    func dragChanged() {
        let m = NSEvent.mouseLocation
        if startMouse == nil {
            startMouse = m
            startOrigin = panel.frame.origin
            return
        }
        guard let sm = startMouse, let so = startOrigin else { return }
        panel.setFrameOrigin(NSPoint(x: so.x + m.x - sm.x, y: so.y + m.y - sm.y))
    }

    func dragEnded() {
        startMouse = nil
        startOrigin = nil
        let ud = UserDefaults.standard
        ud.set(panel.frame.minX, forKey: "panelX")
        ud.set(panel.frame.maxY, forKey: "panelTop")
    }

    private func ensureOnScreen() {
        let f = panel.frame
        let visible = NSScreen.screens.contains { $0.visibleFrame.insetBy(dx: -100, dy: -100).contains(NSPoint(x: f.midX, y: f.maxY)) }
        if !visible, let vf = NSScreen.main?.visibleFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: vf.maxX - 350, y: vf.maxY - 10))
        }
    }
}
