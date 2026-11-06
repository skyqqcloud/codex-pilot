import AppKit
import SwiftUI

/// One event-driven child panel per menu. Delayed work is cancellable; closing
/// releases the hosted charts. This controller never fetches quotas or TPS.
@MainActor
final class QuotaTrendController: NSObject, ObservableObject {
    private let defaults: UserDefaults
    private let anchors = NSMapTable<NSString, QuotaTrendAnchorView>.strongToWeakObjects()
    private var showTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var panel: NSPanel?
    private var model: QuotaTrendModel?
    private var hovered: String?
    private var insidePanel = false
    private var shownName: String?
    private var trackingMenu = false
    private var inspectingInfo = false
    var isOpen: Bool { panel != nil }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
    }

    func register(_ view: QuotaTrendAnchorView) {
        anchors.setObject(view, forKey: view.row.name as NSString)
        if shownName == view.row.name, let model, model.row != view.row {
            let changed = model.row.fetchedAt != view.row.fetchedAt || model.row.quotaHistoryID != view.row.quotaHistoryID
            if model.row.quotaHistoryID != view.row.quotaHistoryID { model.snapshot = QuotaHistorySnapshot() }
            model.row = view.row
            if changed { reload(model) }
        }
        if shownName == view.row.name { panel?.appearance = NSAppearance(named: view.scheme == .dark ? .darkAqua : .aqua) }
    }

    func removed(_ view: QuotaTrendAnchorView) {
        if anchors.object(forKey: view.row.name as NSString) === view {
            anchors.removeObject(forKey: view.row.name as NSString)
            if shownName == view.row.name || hovered == view.row.name { close() }
        }
    }

    func entered(_ view: QuotaTrendAnchorView) {
        hovered = view.row.name
        hideTask?.cancel()
        showTask?.cancel()
        guard shownName != view.row.name else { return }
        showTask = Task { [weak self, weak view] in
            do { try await Task.sleep(nanoseconds: 300_000_000) } catch { return }
            guard let self, let view, self.hovered == view.row.name else { return }
            self.open(view.row.name)
        }
    }

    func exited(_ view: QuotaTrendAnchorView) {
        if hovered == view.row.name { hovered = nil; showTask?.cancel() }
        scheduleClose()
    }

    func panelHover(_ inside: Bool) {
        insidePanel = inside
        if inside { hideTask?.cancel() } else { scheduleClose() }
    }

    func inspectInfo(_ open: Bool) {
        inspectingInfo = open
        if open { hideTask?.cancel() }
        else if panel?.isVisible == true { scheduleClose() }
    }

    private func scheduleClose() {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
            guard let self, self.hovered == nil, !self.insidePanel, !self.trackingMenu, !self.inspectingInfo else { return }
            self.close()
        }
    }

    func open(_ name: String) {
        guard let anchor = anchors.object(forKey: name as NSString), let parent = anchor.window else { return }
        close()
        hovered = name
        let model = QuotaTrendModel(row: anchor.row, historyURL: anchor.historyURL, defaults: defaults)
        self.model = model
        let panel = QuotaFloatingPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = true
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.identifier = NSUserInterfaceItemIdentifier("quota-trend-window")
        panel.title = L10n.string("额度变化")
        panel.appearance = NSAppearance(named: anchor.scheme == .dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: QuotaTrendPanel(model: model, refresh: anchor.refresh,
            close: { [weak self] in self?.close() }, onInspectionChanged: { [weak self] in self?.inspectInfo($0) })
            .onHover { [weak self] in self?.panelHover($0) })
        host.wantsLayer = true
        host.layer?.cornerRadius = 10
        host.layer?.masksToBounds = true
        panel.contentView = host
        self.panel = panel; shownName = name
        position(anchor)
        parent.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: parent, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        })
        // MenuBarExtra orders its persistent window out; it need not close it
        // or dismantle SwiftUI. Release charts on that path as well.
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: parent, queue: .main) { [weak self, weak parent] _ in
            MainActor.assumeIsolated { if parent?.isVisible == false { self?.close() } }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackingMenu = true; self?.hideTask?.cancel() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackingMenu = false; self?.scheduleClose() }
        })
        reload(model)
    }

    private func reload(_ model: QuotaTrendModel) {
        loadTask?.cancel()
        loadTask = Task { [weak self, weak model] in
            guard let model else { return }
            await model.load()
            guard !Task.isCancelled, let self, let name = self.shownName,
                  let anchor = self.anchors.object(forKey: name as NSString) else { return }
            self.position(anchor)
        }
    }

    private func position(_ anchor: QuotaTrendAnchorView) {
        guard let panel, let host = panel.contentView, let parent = anchor.window else { return }
        host.layoutSubtreeIfNeeded()
        let size = NSSize(width: QuotaTrendPanel.width, height: max(160, host.fittingSize.height))
        let rect = parent.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let screen = parent.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
        panel.setFrame(Self.frame(anchor: rect, parent: parent.frame, screen: screen, size: size), display: true)
    }

    static func frame(anchor: NSRect, parent: NSRect, screen: NSRect, size: NSSize) -> NSRect {
        let left = parent.minX - size.width - 8
        let right = parent.maxX + 8
        let x = left >= screen.minX ? left : right + size.width <= screen.maxX ? right : left
        return NSRect(x: min(max(screen.minX + 4, x), screen.maxX - size.width - 4),
                      y: min(max(screen.minY + 4, anchor.maxY - size.height), screen.maxY - size.height - 4),
                      width: size.width, height: size.height)
    }

    func close() {
        showTask?.cancel(); showTask = nil
        hideTask?.cancel(); hideTask = nil
        loadTask?.cancel(); loadTask = nil
        for token in observers { NotificationCenter.default.removeObserver(token) }
        observers.removeAll()
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil); panel.contentView = nil; panel.close()
        }
        panel = nil; model = nil; shownName = nil; hovered = nil; insidePanel = false; trackingMenu = false; inspectingInfo = false
    }
}

private final class QuotaFloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct QuotaTrendAnchor: NSViewRepresentable {
    let controller: QuotaTrendController
    let row: SlotRow
    let scheme: ColorScheme
    var historyURL = QuotaHistoryReader.defaultURL
    let refresh: () -> Void
    func makeNSView(context: Context) -> QuotaTrendAnchorView {
        QuotaTrendAnchorView(controller: controller, row: row, scheme: scheme, historyURL: historyURL, refresh: refresh)
    }
    func updateNSView(_ view: QuotaTrendAnchorView, context: Context) {
        view.row = row; view.scheme = scheme; view.refresh = refresh
        controller.register(view)
    }
    static func dismantleNSView(_ view: QuotaTrendAnchorView, coordinator: ()) { view.controller?.removed(view) }
}

final class QuotaTrendAnchorView: NSView {
    weak var controller: QuotaTrendController?
    var row: SlotRow
    var scheme: ColorScheme
    let historyURL: URL
    var refresh: () -> Void
    private var tracking: NSTrackingArea?
    init(controller: QuotaTrendController, row: SlotRow, scheme: ColorScheme, historyURL: URL, refresh: @escaping () -> Void) {
        self.controller = controller; self.row = row; self.scheme = scheme; self.historyURL = historyURL; self.refresh = refresh
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { controller?.entered(self) }
    override func mouseExited(with event: NSEvent) { controller?.exited(self) }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { controller?.removed(self) } else { controller?.register(self) }
    }
}
