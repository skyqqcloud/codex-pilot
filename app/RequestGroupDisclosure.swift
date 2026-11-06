import AppKit
import SwiftUI

/// Structural headings carry counts, never a fabricated API speed or selection.
struct RequestHierarchyHeading: View {
    let row: RequestHistoryRow
    let context: RequestCallContext?
    let expanded: Bool
    let toggle: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = PanelPalette(scheme: scheme)
        HStack(spacing: 5) {
            RequestGroupDisclosure(groupID: row.groupID!, expanded: expanded, callCount: row.callCount, toggle: toggle)
                .frame(width: 18, height: 32)
            Button(action: toggle) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: row.kind == .subtaskHeader ? "rectangle.3.group" : "bubble.left")
                            .font(.system(size: 10)).foregroundStyle(palette.secondary)
                        Text(verbatim: row.preview ?? "").lineLimit(1).truncationMode(.tail)
                            .font(.system(size: 11, weight: .medium)).help(row.preview ?? "")
                        Spacer(minLength: 4)
                        Text(L10n.string("\(row.callCount) 次调用")).font(.system(size: 10))
                            .foregroundStyle(palette.secondary).fixedSize()
                    }
                    HStack {
                        Text(row.kind == .subtaskHeader && context?.groupID == nil ?
                            L10n.string("子任务 · 用户消息待关联") : row.subtitle ?? "")
                            .lineLimit(1)
                        Spacer(minLength: 4)
                    }.font(.system(size: 10)).foregroundStyle(palette.tertiary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: PanelLayout.requestRowHeight - 0.5)
            }.buttonStyle(.plain)
        }
        .padding(.leading, CGFloat(row.indent) * 14)
        .help(context?.attributionEvidence.map(L10n.key) ?? context?.associationExplanation ?? "")
        .overlay(alignment: .bottom) { Rectangle().fill(palette.rule.opacity(0.65)).frame(height: 0.5) }
        .accessibilityElement(children: .contain).accessibilityIdentifier(row.id)
    }
}

/// Separate from the request-selection button, so disclosure never changes
/// which API's details are shown unless its selected child is being hidden.
struct RequestGroupDisclosure: NSViewRepresentable {
    let groupID: String
    let expanded: Bool
    let callCount: Int
    let toggle: () -> Void
    @Environment(\.isEnabled) private var enabled

    func makeCoordinator() -> Coordinator { Coordinator(toggle: toggle) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "", target: context.coordinator, action: #selector(Coordinator.click))
        button.bezelStyle = .inline
        button.showsBorderOnlyWhileMouseInside = true
        button.imagePosition = .imageOnly
        button.contentTintColor = .secondaryLabelColor
        updateNSView(button, context: context)
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.toggle = toggle
        button.image = NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold))
        button.isEnabled = enabled
        button.identifier = NSUserInterfaceItemIdentifier("request-group-\(groupID)")
        let action = expanded ? L10n.string("收起") : L10n.string("展开")
        button.toolTip = L10n.string("\(action)关联的 \(callCount) 次 API 调用")
        button.setAccessibilityLabel(L10n.string("\(action)关联调用"))
        button.setAccessibilityValue(L10n.string("\(callCount) 次调用，\(expanded ? L10n.string("已展开") : L10n.string("已折叠"))"))
    }
    final class Coordinator: NSObject {
        var toggle: () -> Void
        init(toggle: @escaping () -> Void) { self.toggle = toggle }
        @objc func click() { toggle() }
    }
}
