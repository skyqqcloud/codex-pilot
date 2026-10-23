import AppKit
import SwiftUI

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
