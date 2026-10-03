import AppKit

final class MenuPanel: NSPanel {
    var onDismiss: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        if let onDismiss { onDismiss() }
        else { orderOut(sender) }
    }
}

/// The system supplies the glass material; the delegate supplies native controls.
final class MenuPanelView: NSView {
    private weak var materialView: NSVisualEffectView?

    static let contentSize = NSSize(width: 332, height: 350)

    var page = 0 { didSet { needsDisplay = true } }
    var arrowX: CGFloat = 166 {
        didSet {
            updateMask()
            needsDisplay = true
        }
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var intrinsicContentSize: NSSize { Self.contentSize }

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(origin: frameRect.origin, size: Self.contentSize))
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setFrameSize(Self.contentSize)
    }

    func installMaterial(_ view: NSVisualEffectView) {
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        view.wantsLayer = true
        materialView = view
        updateMask()
        needsDisplay = true
    }

    private func updateMask() {
        guard let materialView else { return }
        // Snapshot the path so the retained image does not retain this view.
        let path = surfacePath()
        materialView.maskImage = NSImage(size: Self.contentSize, flipped: true) { _ in
            NSColor.white.setFill()
            path.fill()
            return true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }

        let surface = surfacePath()
        surface.addClip()
        NSColor.white.withAlphaComponent(0.18).setStroke()
        surface.lineWidth = 0.5
        surface.stroke()
        Self.moonImage(size: NSSize(width: 28, height: 28))
            .draw(in: NSRect(x: 19, y: 25, width: 28, height: 28))

        if page == 0 {
            drawContainer(NSRect(x: 16, y: 75, width: 300, height: 28), radius: 14)
            drawContainer(NSRect(x: 16, y: 114, width: 300, height: 120), radius: 12)
            let divider = NSBezierPath()
            divider.move(to: NSPoint(x: 30, y: 174))
            divider.line(to: NSPoint(x: 302, y: 174))
            NSColor.white.withAlphaComponent(0.12).setStroke()
            divider.lineWidth = 0.5
            divider.stroke()
            // The real launch button supplies its blue tint and disabled state.
            drawContainer(NSRect(x: 16, y: 248, width: 300, height: 38),
                          radius: 10, fillAlpha: 0.035)
        } else {
            drawContainer(NSRect(x: 16, y: 86, width: 300, height: 200), radius: 12)
            if page == 1 {
                ("登录 Mac 时启动 Miruun" as NSString).draw(
                    at: NSPoint(x: 51, y: 203), withAttributes: [
                        .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                        .foregroundColor: NSColor.labelColor
                    ])
            }
        }
        drawContainer(NSRect(x: 16, y: 304, width: 144, height: 30), radius: 9)
        drawContainer(NSRect(x: 172, y: 304, width: 144, height: 30), radius: 9)
        drawFooter(symbol: page == 0 ? "gearshape" : "arrow.left",
                   title: page == 0 ? "设置" : "返回",
                   in: NSRect(x: 16, y: 304, width: 144, height: 30))
        drawFooter(symbol: "power", title: "退出",
                   in: NSRect(x: 172, y: 304, width: 144, height: 30))
    }

    static func color(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
                green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }

    static func moonImage(size: NSSize = NSSize(width: 18, height: 18)) -> NSImage {
        let image = NSImage(size: size, flipped: true) { _ in
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            let scale = NSAffineTransform()
            scale.scaleX(by: size.width / 24, yBy: size.height / 24)
            scale.concat()

            NSColor.white.setFill()
            NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: 22, height: 22)).fill()
            // Alpha shading keeps the lunar craters visible in both template tints.
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSColor.white.withAlphaComponent(0.28).setFill()
            for crater in [
                NSRect(x: 6, y: 5, width: 4, height: 4),
                NSRect(x: 13, y: 6, width: 3, height: 3),
                NSRect(x: 8, y: 12, width: 5, height: 4),
                NSRect(x: 15, y: 14, width: 3, height: 4),
                NSRect(x: 4.5, y: 11, width: 2, height: 2)
            ] {
                NSBezierPath(ovalIn: crater).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private func surfacePath() -> NSBezierPath {
        let path = NSBezierPath()
        let tip = min(max(arrowX, 34), 298)
        path.move(to: NSPoint(x: 19, y: 11.5))
        path.line(to: NSPoint(x: tip - 15, y: 11.5))
        path.curve(to: NSPoint(x: tip - 10, y: 8),
                   controlPoint1: NSPoint(x: tip - 13, y: 11.5),
                   controlPoint2: NSPoint(x: tip - 11, y: 9))
        path.line(to: NSPoint(x: tip - 3, y: 1.8))
        path.curve(to: NSPoint(x: tip + 3, y: 1.8),
                   controlPoint1: NSPoint(x: tip - 1, y: 0),
                   controlPoint2: NSPoint(x: tip + 1, y: 0))
        path.line(to: NSPoint(x: tip + 10, y: 8))
        path.curve(to: NSPoint(x: tip + 15, y: 11.5),
                   controlPoint1: NSPoint(x: tip + 11, y: 9),
                   controlPoint2: NSPoint(x: tip + 13, y: 11.5))
        path.line(to: NSPoint(x: 313, y: 11.5))
        path.curve(to: NSPoint(x: 331.5, y: 30),
                   controlPoint1: NSPoint(x: 323.2, y: 11.5),
                   controlPoint2: NSPoint(x: 331.5, y: 19.8))
        path.line(to: NSPoint(x: 331.5, y: 331))
        path.curve(to: NSPoint(x: 313, y: 349.5),
                   controlPoint1: NSPoint(x: 331.5, y: 341.2),
                   controlPoint2: NSPoint(x: 323.2, y: 349.5))
        path.line(to: NSPoint(x: 19, y: 349.5))
        path.curve(to: NSPoint(x: 0.5, y: 331),
                   controlPoint1: NSPoint(x: 8.8, y: 349.5),
                   controlPoint2: NSPoint(x: 0.5, y: 341.2))
        path.line(to: NSPoint(x: 0.5, y: 30))
        path.curve(to: NSPoint(x: 19, y: 11.5),
                   controlPoint1: NSPoint(x: 0.5, y: 19.8),
                   controlPoint2: NSPoint(x: 8.8, y: 11.5))
        path.close()
        return path
    }

    private func drawContainer(_ rect: NSRect, radius: CGFloat, fillAlpha: CGFloat = 0.06) {
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.25, dy: 0.25),
                                xRadius: radius, yRadius: radius)
        NSColor.white.withAlphaComponent(fillAlpha).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.14).setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }

    private func drawFooter(symbol: String, title: String, in rect: NSRect) {
        let tint = NSColor.labelColor.withAlphaComponent(0.84)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: tint
        ]
        let text = title as NSString
        let textSize = text.size(withAttributes: attributes)
        let start = rect.midX - (13 + 7 + textSize.width) / 2
        drawSymbol(symbol, in: NSRect(x: start, y: rect.midY - 6.5, width: 13, height: 13),
                   color: tint)
        text.draw(at: NSPoint(x: start + 20, y: rect.midY - textSize.height / 2),
                  withAttributes: attributes)
    }

    private func drawSymbol(_ name: String, in rect: NSRect, color: NSColor) {
        let configuration = NSImage.SymbolConfiguration(pointSize: rect.height, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else {
            preconditionFailure("Unavailable menu symbol: \(name)")
        }
        symbol.draw(in: rect)
    }
}
