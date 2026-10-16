import AppKit
import SwiftUI

struct PanelPickerOption<Value: Hashable> {
    let value: Value
    let title: String
}

/// Native menu tracking and keyboard navigation with the panel's shared geometry.
struct PanelPicker<Value: Hashable>: NSViewRepresentable {
    let label: String
    @Binding var selection: Value
    let options: [PanelPickerOption<Value>]
    var width: CGFloat = 130
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var enabled

    init(_ label: String, selection: Binding<Value>, options: [PanelPickerOption<Value>], width: CGFloat = 130) {
        self.label = label
        self._selection = selection
        self.options = options
        self.width = width
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> PanelPopUpButton {
        let button = PanelPopUpButton(frame: .zero, pullsDown: false)
        button.isBordered = false
        button.focusRingType = .exterior
        (button.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        button.target = context.coordinator
        button.action = #selector(Coordinator.changed(_:))
        return button
    }

    func updateNSView(_ button: PanelPopUpButton, context: Context) {
        context.coordinator.parent = self
        button.controlWidth = width
        button.invalidateIntrinsicContentSize()
        let titles = options.map(\.title)
        if button.itemTitles != titles {
            button.removeAllItems()
            button.addItems(withTitles: titles)
        }
        if let index = options.firstIndex(where: { $0.value == selection }), button.indexOfSelectedItem != index {
            button.selectItem(at: index)
        }
        button.isEnabled = enabled
        button.font = .systemFont(ofSize: 11)
        button.setAccessibilityLabel(label)
        button.toolTip = button.title
        button.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let palette = PanelPalette(scheme: scheme)
        button.fillColor = NSColor(palette.inset)
        button.hoverColor = NSColor(palette.controlHover)
        button.pressColor = NSColor(palette.pressed)
        button.textColor = NSColor(palette.ink)
        button.indicatorColor = NSColor(palette.secondary)
        button.needsDisplay = true
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PanelPopUpButton, context: Context) -> CGSize? {
        CGSize(width: width, height: PanelLayout.controlHeight)
    }

    final class Coordinator: NSObject {
        var parent: PanelPicker
        init(_ parent: PanelPicker) { self.parent = parent }
        @objc func changed(_ sender: NSPopUpButton) {
            let index = sender.indexOfSelectedItem
            guard sender.isEnabled, parent.options.indices.contains(index) else { return }
            parent.selection = parent.options[index].value
        }
    }
}

final class PanelPopUpButton: NSPopUpButton {
    var controlWidth: CGFloat = 130
    override var intrinsicContentSize: NSSize {
        NSSize(width: controlWidth, height: PanelLayout.controlHeight)
    }
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }
    var fillColor: NSColor = .controlBackgroundColor
    var hoverColor: NSColor = .controlBackgroundColor
    var pressColor: NSColor = .controlBackgroundColor
    var textColor: NSColor = .labelColor
    var indicatorColor: NSColor = .secondaryLabelColor
    private var hoverTracking: NSTrackingArea?
    private var hovered = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let tracking = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking)
        hoverTracking = tracking
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let pressed = isEnabled && (cell?.isHighlighted ?? false)
        (pressed ? pressColor : hovered && isEnabled ? hoverColor : fillColor).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 11),
            .foregroundColor: textColor.withAlphaComponent(isEnabled ? 1 : 0.45),
            .paragraphStyle: paragraph
        ]
        let textHeight = (title as NSString).size(withAttributes: attributes).height
        let rect = NSRect(x: 8, y: (bounds.height - textHeight) / 2,
                          width: max(0, bounds.width - 30), height: textHeight)
        (title as NSString).draw(in: rect, withAttributes: attributes)
        indicatorColor.withAlphaComponent(isEnabled ? 1 : 0.45).setStroke()
        let mid = bounds.midY
        let direction: CGFloat = isFlipped ? 1 : -1
        let chevron = NSBezierPath()
        chevron.move(to: NSPoint(x: bounds.width - 17, y: mid - 2 * direction))
        chevron.line(to: NSPoint(x: bounds.width - 13, y: mid + 2 * direction))
        chevron.line(to: NSPoint(x: bounds.width - 9, y: mid - 2 * direction))
        chevron.lineWidth = 1.25
        chevron.lineCapStyle = .round
        chevron.lineJoinStyle = .round
        chevron.stroke()
    }
}
