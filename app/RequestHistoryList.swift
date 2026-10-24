import AppKit
import SwiftUI

/// NSTableView recycles visible rows. The document still represents every
/// retained request, but opening the panel does not lay out hundreds of hosts.
struct RequestHistoryList<Row: View>: NSViewRepresentable {
    let ids: [String]
    let onSelect: (String) -> Void
    var width: CGFloat = PanelLayout.width
    var viewportHeight: CGFloat = PanelLayout.requestHistoryHeight
    var selection: String? = nil
    let row: (Int) -> Row
    @Environment(\.colorScheme) private var scheme

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.horizontalScrollElasticity = .none
        let table = RequestTableView(frame: NSRect(x: 0, y: 0, width: width, height: 0))
        table.style = .plain
        table.autoresizingMask = [.width]
        table.headerView = nil
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.intercellSpacing = .zero
        table.rowHeight = PanelLayout.requestRowHeight
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("request"))
        column.width = width
        column.minWidth = width
        column.maxWidth = width
        table.addTableColumn(column)
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        scroll.documentView = table
        updateNSView(scroll, context: context)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? NSTableView else { return }
        let changed = context.coordinator.parent.ids != ids || table.numberOfRows != ids.count
        context.coordinator.parent = self
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        scroll.appearance = appearance
        table.appearance = appearance
        scroll.scrollerKnobStyle = scheme == .dark ? .light : .dark
        scroll.hasVerticalScroller = CGFloat(ids.count) * PanelLayout.requestRowHeight > viewportHeight
        let origin = scroll.contentView.bounds.origin
        if changed { table.reloadData() }
        if let column = table.tableColumns.first {
            column.minWidth = width; column.maxWidth = width; column.width = width
        }
        table.setFrameSize(NSSize(width: width,
                                  height: CGFloat(ids.count) * PanelLayout.requestRowHeight))
        let visible = table.rows(in: table.visibleRect)
        if visible.location != NSNotFound {
            for index in visible.location..<min(ids.count, NSMaxRange(visible)) {
                if let cell = table.view(atColumn: 0, row: index, makeIfNecessary: false) as? HistoryCell<Row> {
                    cell.setContent(row(index).environment(\.colorScheme, scheme), width: width)
                }
            }
        }
        let bottom = max(0, table.frame.height - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: min(origin.y, bottom)))
        if context.coordinator.lastSelection != selection, let selection, let index = ids.firstIndex(of: selection) {
            table.scrollRowToVisible(index)
        }
        context.coordinator.lastSelection = selection
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: RequestHistoryList
        var lastSelection: String?
        init(parent: RequestHistoryList) { self.parent = parent }
        func numberOfRows(in tableView: NSTableView) -> Int { parent.ids.count }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let table = notification.object as? NSTableView,
                  parent.ids.indices.contains(table.selectedRow) else { return }
            parent.onSelect(parent.ids[table.selectedRow])
        }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            // AppKit can ask for an old visible row during a shrinking reload.
            guard parent.ids.indices.contains(row) else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("request-cell")
            let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? HistoryCell<Row> ?? HistoryCell<Row>()
            cell.identifier = identifier
            cell.setContent(parent.row(row).environment(\.colorScheme, parent.scheme), width: parent.width)
            return cell
        }
    }
}

private final class RequestTableView: NSTableView {
    override func setFrameSize(_ newSize: NSSize) {
        // A fixed-height table has a known document size. AppKit's automatic
        // resizing must not append an empty viewport below the last request.
        super.setFrameSize(NSSize(width: newSize.width, height: CGFloat(numberOfRows) * rowHeight))
    }
}

private final class HistoryCell<Row: View>: NSTableCellView {
    private var host: NSHostingView<AnyView>?
    func setContent<Content: View>(_ content: Content, width: CGFloat) {
        let root = AnyView(content.frame(width: width, height: PanelLayout.requestRowHeight))
        if let host { host.rootView = root }
        else {
            let host = NSHostingView(rootView: root)
            host.sizingOptions = []
            host.translatesAutoresizingMaskIntoConstraints = false
            addSubview(host)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: leadingAnchor),
                host.trailingAnchor.constraint(equalTo: trailingAnchor),
                host.topAnchor.constraint(equalTo: topAnchor),
                host.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            self.host = host
        }
    }
}
