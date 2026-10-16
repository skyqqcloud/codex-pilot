import AppKit
import SwiftUI

/// A single native viewport. Measure the hosted document synchronously rather
/// than passing document-height preferences through nested hosting boundaries.
struct BoundedPanelScrollView<Content: View>: View {
    let maximumHeight: CGFloat
    let minimumHeight: CGFloat
    private let content: Content
    @Environment(\.colorScheme) private var scheme

    init(maximumHeight: CGFloat, minimumHeight: CGFloat = 0, @ViewBuilder content: () -> Content) {
        self.maximumHeight = maximumHeight
        self.minimumHeight = min(minimumHeight, maximumHeight)
        self.content = content()
    }

    var body: some View {
        PanelScrollHost(
            content: content.environment(\.colorScheme, scheme)
                .frame(width: PanelLayout.width, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true),
            maximumHeight: maximumHeight, minimumHeight: minimumHeight, scheme: scheme
        ).frame(width: PanelLayout.width)
    }
}

private final class PanelScrollContainer: NSView {
    let scroll = NSScrollView()
    var documentHeight: CGFloat = 1
    var maximumHeight: CGFloat = 350
    var minimumHeight: CGFloat = 0
    var viewportHeight: CGFloat { max(minimumHeight, min(documentHeight, maximumHeight)) }
    override var intrinsicContentSize: NSSize {
        NSSize(width: PanelLayout.width, height: viewportHeight)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        scroll.frame = bounds
        scroll.autoresizingMask = [.width, .height]
        addSubview(scroll)
    }
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        updateScrollerVisibility()
    }
    func updateScrollerVisibility() {
        let overflow = documentHeight > scroll.contentView.bounds.height + 0.5
        if scroll.hasVerticalScroller != overflow { scroll.hasVerticalScroller = overflow }
    }

    func measureDocument() {
        guard let document = scroll.documentView else { return }
        let measured = document.fittingSize.height
        guard measured.isFinite else { return }
        let height = max(1, ceil(measured * 2) / 2)
        let origin = scroll.contentView.bounds.origin
        if documentHeight != height {
            documentHeight = height
            invalidateIntrinsicContentSize()
        }
        if document.frame.size != NSSize(width: PanelLayout.width, height: height) {
            document.setFrameSize(NSSize(width: PanelLayout.width, height: height))
            scroll.contentView.scroll(to: NSPoint(x: 0, y: min(origin.y, max(0, height - scroll.contentView.bounds.height))))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        updateScrollerVisibility()
    }
}

private struct PanelScrollHost<Content: View>: NSViewRepresentable {
    let content: Content
    let maximumHeight: CGFloat
    let minimumHeight: CGFloat
    let scheme: ColorScheme

    func makeNSView(context: Context) -> PanelScrollContainer {
        let container = PanelScrollContainer(frame: .zero)
        container.maximumHeight = maximumHeight
        container.minimumHeight = minimumHeight
        let scroll = container.scroll
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.horizontalScrollElasticity = .none
        let document = NSHostingView(rootView: content)
        document.isFlipped = true
        document.sizingOptions = [.intrinsicContentSize]
        document.frame = NSRect(x: 0, y: 0, width: PanelLayout.width, height: 1)
        scroll.documentView = document
        updateAppearance(scroll, document: document)
        container.measureDocument()
        container.setFrameSize(NSSize(width: PanelLayout.width, height: container.viewportHeight))
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        return container
    }

    func updateNSView(_ container: PanelScrollContainer, context: Context) {
        let scroll = container.scroll
        guard let document = scroll.documentView as? NSHostingView<Content> else { return }
        container.maximumHeight = maximumHeight
        container.minimumHeight = minimumHeight
        if scroll.scrollerStyle != .overlay { scroll.scrollerStyle = .overlay }
        document.rootView = content
        container.measureDocument()
        updateAppearance(scroll, document: document)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PanelScrollContainer, context: Context) -> CGSize? {
        nsView.measureDocument()
        return CGSize(width: PanelLayout.width, height: nsView.viewportHeight)
    }

    private func updateAppearance(_ scroll: NSScrollView, document: NSView) {
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        scroll.appearance = appearance
        document.appearance = appearance
        scroll.scrollerKnobStyle = scheme == .dark ? .light : .dark
    }
}
