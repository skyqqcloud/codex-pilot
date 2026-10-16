import SwiftUI

struct PanelButtonStyle: ButtonStyle {
    enum Kind { case subtle, neutral, primary, segment(Bool) }
    var kind: Kind = .subtle
    var cornerRadius: CGFloat = 7
    var highlighted = false
    var backgroundPadding: CGFloat = 0

    func makeBody(configuration: Configuration) -> some View {
        PanelButtonFeedback(configuration: configuration, style: self)
    }
}

private struct PanelButtonFeedback: View {
    let configuration: ButtonStyleConfiguration
    let style: PanelButtonStyle
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false

    private var palette: PanelPalette { PanelPalette(scheme: scheme) }
    private var pressed: Bool { enabled && configuration.isPressed }
    private var hovering: Bool { enabled && hovered }

    private var background: Color {
        switch style.kind {
        case .subtle:
            return pressed ? palette.pressed : hovering || style.highlighted ? palette.inset : .clear
        case .neutral:
            return pressed ? palette.pressed : hovering ? palette.controlHover : palette.inset
        case .primary:
            return pressed ? palette.primaryPressed : hovering ? palette.primaryHover : palette.action
        case .segment(let selected):
            if selected { return Color.accentColor.opacity(pressed ? 0.72 : hovering ? 0.86 : 1) }
            return pressed ? palette.pressed : hovering ? palette.controlHover : .clear
        }
    }

    var body: some View {
        configuration.label
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: style.cornerRadius)
                    .fill(background)
                    .padding(-style.backgroundPadding)
            }
            .opacity(enabled ? 1 : 0.45)
            .onHover { hovered = $0 }
    }
}

private struct PanelControlHover: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(hovered && enabled ? PanelPalette(scheme: scheme).controlOutline : .clear,
                            lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .onHover { hovered = $0 }
    }
}

extension View {
    func panelControlHover(cornerRadius: CGFloat = 5) -> some View {
        modifier(PanelControlHover(cornerRadius: cornerRadius))
    }
}
