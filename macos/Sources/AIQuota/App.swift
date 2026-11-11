import SwiftUI
import AppKit
import Combine

@main
struct AIQuotaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject var store = Store.shared

    var body: some Scene {
        // 菜单栏：显示剩余数字，点开是完整面板（设置也在面板里）
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in self.setup() }
    }

    @MainActor
    func setup() {
        NSApp.setActivationPolicy(.accessory)   // 不在程序坞显示图标
        panel = FloatingPanelController(store: Store.shared)
    }
}

// MARK: - 桌面悬浮窗

/// 无边框面板默认不能成为 key window，设置页里的开关/滑块需要它
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct SizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

struct FloatingRoot: View {
    @EnvironmentObject var store: Store
    let controller: FloatingPanelController
    private let previewPopover = ProcessInfo.processInfo.environment["AIQUOTA_PREVIEW_POPOVER"] == "1"

    var body: some View {
        Group {
            if store.compact { PillView() }
            else { WidgetView(mode: previewPopover ? .popover : .floating) }
        }
        .environment(\.windowDrag, WindowDrag(changed: { controller.dragChanged() }, ended: { controller.dragEnded() }))
        .padding(16)                       // 给阴影留空间
        .fixedSize()
        .background(GeometryReader { g in Color.clear.preference(key: SizeKey.self, value: g.size) })
        .onPreferenceChange(SizeKey.self) { size in controller.resize(to: size) }
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
        panel = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 480),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let host = NSHostingView(rootView: FloatingRoot(controller: self).environmentObject(store))
        host.sizingOptions = []            // 窗口大小由 resize(to:) 控制
        panel.contentView = host

        // 恢复上次的位置（记录的是左上角），默认放在屏幕右上角
        let ud = UserDefaults.standard
        if ud.object(forKey: "panelX") != nil && !store.demo {
            let x = ud.double(forKey: "panelX"), top = ud.double(forKey: "panelTop")
            panel.setFrameTopLeftPoint(NSPoint(x: x, y: top))
        } else if let vf = NSScreen.main?.visibleFrame {
            panel.setFrameTopLeftPoint(NSPoint(x: vf.maxX - 340, y: vf.maxY - 10))
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
            panel.setFrameTopLeftPoint(NSPoint(x: vf.maxX - 340, y: vf.maxY - 10))
        }
    }
}
