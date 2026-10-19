import AppKit

struct MenuBarQuota {
    let windows: [(title: String, remaining: Int)]

    init(account: SlotRow?) {
        guard let account else { windows = []; return }
        windows = [(account.fiveWindowTitle, account.five), (account.weekWindowTitle, account.week)]
            .compactMap { title, remaining in
                guard let remaining, (0...100).contains(remaining) else { return nil }
                return (title, remaining)
            }
    }

    var text: String { windows.map(\.remaining).min().map { "\($0)%" } ?? "—" }
    var help: String {
        guard !windows.isEmpty else { return "剩余额度：暂无数据" }
        let detail = windows.map { "\($0.title)剩余 \($0.remaining)%" }.joined(separator: "，")
        return windows.count > 1 ? detail + "（第二行显示较低值）" : detail
    }
}

@MainActor
enum MenuBarMetrics {
    private static var cachedText: [String] = []
    private static var cachedImage: NSImage?

    // A template image preserves two rows in MenuBarExtra's native label.
    // Reuse unchanged text so unrelated store updates do not redraw it.
    static func image(speed: String, quota: String) -> NSImage {
        let text = [speed, quota]
        if text == cachedText, let cachedImage { return cachedImage }
        let fonts = [NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium),
                     NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)]
        let lines = zip(text, fonts).map { value, font in
            NSAttributedString(string: value, attributes: [.font: font, .foregroundColor: NSColor.black])
        }
        let reservedWidth = NSAttributedString(string: "000.0 t/s", attributes: [.font: fonts[0]]).size().width
        let width = ceil(max(reservedWidth, lines.map { $0.size().width }.max() ?? 0)) + 4
        let size = NSSize(width: width, height: 22)
        let image = NSImage(size: size, flipped: false) { _ in
            for (index, line) in lines.enumerated() {
                let x = ((width - line.size().width) * 2).rounded() / 4
                // NSString drawing adds baseline padding. Offset it so both
                // rows' visible glyphs fit inside the 22pt native status item.
                line.draw(at: NSPoint(x: x, y: index == 0 ? 10 : -2))
            }
            return true
        }
        image.isTemplate = true
        cachedText = text
        cachedImage = image
        return image
    }
}
