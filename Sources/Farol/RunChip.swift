import AppKit

/// The corner of a pane: ▶ to run one of the project's commands, or while one it started runs, ■ to stop it and the ports it listens on.
final class RunChip: NSView {
    enum Look: Equatable {
        case play
        case running(ports: [Int])
    }

    var look = Look.play {
        didSet { if look != oldValue { rebuild() } }
    }
    /// ▶ or ■ was clicked.
    var onPress: (() -> Void)?

    private lazy var button = QuietButton(symbol: "play.fill", help: "Run") { [weak self] in self?.onPress?() }
    private var portButtons: [NSButton] = []
    private var colors = (background: NSColor.black, foreground: NSColor.white)

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        addSubview(button)
        rebuild()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func apply(background: NSColor, foreground: NSColor) {
        colors = (background, foreground)
        button.apply(background: background, foreground: foreground)
        rebuild()
    }

    /// The button alone, or with each port after it.
    var fittingWidth: CGFloat { 22 + portButtons.reduce(0) { $0 + $1.intrinsicContentSize.width + 4 } + (portButtons.isEmpty ? 0 : 4) }

    private func rebuild() {
        portButtons.forEach { $0.removeFromSuperview() }
        portButtons = []
        switch look {
        case .play:
            button.show(symbol: "play.fill", help: "Run")
            // Only under the mouse, so it is just the glyph, like the other quiet buttons.
            layer?.backgroundColor = nil
            layer?.borderWidth = 0
        case .running(let ports):
            button.show(symbol: "stop.fill", help: "Stop")
            // While something runs it stays on screen, so it reads as a chip, like a pane's name.
            layer?.backgroundColor = colors.background.mixed(with: colors.foreground, 0.06).cgColor
            layer?.borderColor = colors.background.mixed(with: colors.foreground, 0.14).cgColor
            layer?.borderWidth = 1
            for port in ports {
                let link = NSButton(title: ":\(port)", target: self, action: #selector(openPort(_:)))
                link.tag = port
                link.isBordered = false
                link.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
                link.contentTintColor = colors.background.mixed(with: colors.foreground, 0.6)
                link.toolTip = "Open localhost:\(port)"
                addSubview(link)
                portButtons.append(link)
            }
        }
        needsLayout = true
        superview?.needsLayout = true
    }

    override func layout() {
        super.layout()
        button.frame = NSRect(x: 0, y: 0, width: 22, height: bounds.height)
        var x: CGFloat = 22
        for link in portButtons {
            let width = link.intrinsicContentSize.width
            link.frame = NSRect(x: x, y: (bounds.height - link.intrinsicContentSize.height) / 2, width: width, height: link.intrinsicContentSize.height)
            x += width + 4
        }
    }

    override func resetCursorRects() {
        portButtons.forEach { addCursorRect($0.frame, cursor: .pointingHand) }
    }

    @objc private func openPort(_ sender: NSButton) {
        NSWorkspace.shared.open(URL(string: "http://localhost:\(sender.tag)")!)
    }
}
