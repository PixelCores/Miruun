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

/// Paints the menu surface; the delegate supplies controls and their real state.
final class MenuPanelView: NSView {
    static let contentSize = NSSize(width: 332, height: 379)

    var showsSettings = false { didSet { needsDisplay = true } }
    var selectedIndex = 1 { didSet { needsDisplay = true } }
    var arrowX: CGFloat = 166 { didSet { needsDisplay = true } }
    var active = [false, false, false] { didSet { needsDisplay = true } }
    var waiting = false { didSet { needsDisplay = true } }
    var blocked = false { didSet { needsDisplay = true } }

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

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current?.compositingOperation = .copy
        NSColor.clear.setFill()
        bounds.fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver

        let surface = surfacePath()
        Self.color(0x181818).setFill()
        surface.fill()
        Self.color(0x313131).setStroke()
        surface.lineWidth = 0.5
        surface.stroke()

        Self.orbitImage(size: NSSize(width: 48, height: 24))
            .draw(in: NSRect(x: 142, y: 35, width: 48, height: 24))
        drawNavigation()
        drawContainer(NSRect(x: 12, y: 148, width: 308, height: 167), radius: 10.5)
        if !showsSettings { drawRows() }
        if selectedIndex == 6 {
            // AppKit checkbox cells do not tint their text on this custom surface.
            ("登录 Mac 时启动 Miruun" as NSString).draw(
                at: NSPoint(x: 47, y: 242), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                    .foregroundColor: Self.color(0xE9E9E9)
                ])
        }
        drawContainer(NSRect(x: 12, y: 332, width: 150, height: 28), radius: 7)
        drawContainer(NSRect(x: 170, y: 332, width: 150, height: 28), radius: 7)
        drawFooter(symbol: selectedIndex == 1 ? "gearshape" : "arrow.left",
                   title: selectedIndex == 1 ? "设置" : "返回",
                   in: NSRect(x: 12, y: 332, width: 150, height: 28))
        drawFooter(symbol: "power", title: "退出",
                   in: NSRect(x: 170, y: 332, width: 150, height: 28))
    }

    static func color(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
                green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }

    static func orbitImage(size: NSSize = NSSize(width: 24, height: 14)) -> NSImage {
        let image = NSImage(size: size, flipped: true) { _ in
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            let scale = NSAffineTransform()
            scale.scaleX(by: size.width / 48, yBy: size.height / 24)
            scale.concat()

            let ring = NSBezierPath(ovalIn: NSRect(x: 0, y: 5, width: 48, height: 14))
            ring.appendOval(in: NSRect(x: 3, y: 7, width: 42, height: 10))
            ring.windingRule = .evenOdd
            let tilt = NSAffineTransform()
            tilt.translateX(by: 24, yBy: 12)
            tilt.rotate(byDegrees: -14)
            tilt.translateX(by: -24, yBy: -12)
            ring.transform(using: tilt as AffineTransform)
            NSColor.white.setFill()
            ring.fill()
            NSBezierPath(ovalIn: NSRect(x: 12, y: 0, width: 24, height: 24)).fill()

            // Remove the narrow gap in the foreground ring from this image only.
            let gap = NSBezierPath()
            gap.move(to: NSPoint(x: 7.5, y: 18.5))
            gap.curve(to: NSPoint(x: 40.5, y: 8),
                      controlPoint1: NSPoint(x: 17, y: 24),
                      controlPoint2: NSPoint(x: 37, y: 13))
            gap.lineWidth = 1.3
            gap.lineCapStyle = .round
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSColor.white.setStroke()
            gap.stroke()
            NSGraphicsContext.current?.compositingOperation = .sourceOver

            let foreground = NSBezierPath()
            foreground.move(to: NSPoint(x: 2.5, y: 15.5))
            foreground.curve(to: NSPoint(x: 45, y: 6),
                             controlPoint1: NSPoint(x: 0, y: 29),
                             controlPoint2: NSPoint(x: 35, y: 24))
            foreground.lineWidth = 2.3
            foreground.lineCapStyle = .round
            foreground.stroke()
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
        path.line(to: NSPoint(x: 331.5, y: 360))
        path.curve(to: NSPoint(x: 313, y: 378.5),
                   controlPoint1: NSPoint(x: 331.5, y: 370.2),
                   controlPoint2: NSPoint(x: 323.2, y: 378.5))
        path.line(to: NSPoint(x: 19, y: 378.5))
        path.curve(to: NSPoint(x: 0.5, y: 360),
                   controlPoint1: NSPoint(x: 8.8, y: 378.5),
                   controlPoint2: NSPoint(x: 0.5, y: 370.2))
        path.line(to: NSPoint(x: 0.5, y: 30))
        path.curve(to: NSPoint(x: 19, y: 11.5),
                   controlPoint1: NSPoint(x: 0.5, y: 19.8),
                   controlPoint2: NSPoint(x: 8.8, y: 11.5))
        path.close()
        return path
    }

    private func drawContainer(_ rect: NSRect, radius: CGFloat) {
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.25, dy: 0.25),
                                xRadius: radius, yRadius: radius)
        Self.color(0x292929).setFill()
        path.fill()
        Self.color(0x414141).setStroke()
        path.lineWidth = 0.5
        path.stroke()
    }

    private func drawNavigation() {
        drawContainer(NSRect(x: 12, y: 77, width: 308, height: 38), radius: 12)
        let centers: [CGFloat] = [34, 71.5, 109, 146.5, 184.5, 222, 260, 298]
        let symbols = ["moon.zzz.fill", "slider.horizontal.3", "cpu", "globe",
                       "externaldrive", "bolt.fill", "wrench.and.screwdriver.fill", "switch.2"]
        for index in centers.indices {
            let selected = index == selectedIndex
            if selected {
                Self.color(0x273A54).setFill()
                NSBezierPath(roundedRect: NSRect(x: centers[index] - 17.5, y: 81,
                                                width: 35, height: 30),
                             xRadius: 8, yRadius: 8).fill()
            }
            drawSymbol(symbols[index],
                       in: NSRect(x: centers[index] - 8, y: 88, width: 16, height: 16),
                       color: Self.color(selected ? 0x007AFF : 0x8F8F8F))
        }
    }

    private func drawRows() {
        precondition(active.count == 3)
        let symbols = ["shield.fill", "arrow.up.forward", "power"]
        let topColors: [UInt32] = [0x7C80FF, 0xFF4870, 0xFFFFFF]
        let bottomColors: [UInt32] = [0x5554F1, 0xF50039, 0xE3F3FF]
        for index in active.indices {
            let offset = CGFloat(index) * 52
            let iconRect = NSRect(x: 25, y: 166 + offset, width: 26, height: 26)
            let icon = NSBezierPath(roundedRect: iconRect, xRadius: 6.3, yRadius: 6.3)
            let gradient = NSGradient(starting: Self.color(topColors[index]),
                                      ending: Self.color(bottomColors[index]))!
            gradient.draw(in: icon, angle: 90)
            drawSymbol(symbols[index], in: iconRect.insetBy(dx: 4, dy: 4),
                       color: index == 2 ? Self.color(0x007AFF) : .white)

            let orange = index == 1 && (waiting || blocked)
            let accent = Self.color(orange ? 0xFF9E33 : 0x007AFF)
            let trackRect = NSRect(x: 64, y: 189 + offset, width: 150, height: 5)
            Self.color(0x484848).setFill()
            NSBezierPath(roundedRect: trackRect, xRadius: 2.5, yRadius: 2.5).fill()
            let center: CGFloat = active[index] ? trackRect.maxX - 12 : trackRect.minX + 12
            if active[index] {
                accent.setFill()
                NSBezierPath(roundedRect: NSRect(x: trackRect.minX, y: trackRect.minY,
                                                width: center - trackRect.minX, height: 5),
                             xRadius: 2.5, yRadius: 2.5).fill()
            }
            let knob = NSBezierPath(roundedRect: NSRect(x: center - 12, y: 184 + offset,
                                                       width: 24, height: 15),
                                    xRadius: 7.5, yRadius: 7.5)
            Self.color(orange ? 0x876237 : (active[index] ? 0x435D73 : 0x535353)).setFill()
            knob.fill()
            Self.color(orange ? 0xAA8050 : (active[index] ? 0x64829A : 0x6B6B6B)).setStroke()
            knob.lineWidth = 0.5
            knob.stroke()
        }
    }

    private func drawFooter(symbol: String, title: String, in rect: NSRect) {
        let tint = Self.color(0xA5A5A5)
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
