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

    static func contentSize(for page: Int) -> NSSize {
        NSSize(width: 332, height: page == 0 ? 368 : page == 3 ? 462 : 350)
    }

    var page = 0 {
        didSet {
            let size = Self.contentSize(for: page)
            setFrameSize(size)
            materialView?.setFrameSize(size)
            updateMask()
            needsDisplay = true
        }
    }
    var arrowX: CGFloat = 166 {
        didSet {
            updateMask()
            needsDisplay = true
        }
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var intrinsicContentSize: NSSize { Self.contentSize(for: page) }

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(origin: frameRect.origin, size: Self.contentSize(for: 0)))
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setFrameSize(Self.contentSize(for: page))
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
        materialView.maskImage = NSImage(size: Self.contentSize(for: page), flipped: true) { _ in
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
            drawContainer(NSRect(x: 16, y: 114, width: 300, height: 78), radius: 12)
            drawContainer(NSRect(x: 16, y: 200, width: 300, height: 78), radius: 12)
            drawContainer(NSRect(x: 16, y: 284, width: 300, height: 28), radius: 14)
        } else {
            drawContainer(NSRect(x: 16, y: 78, width: 300, height: page == 3 ? 334 : 215), radius: 12)
            if page == 1 {
                ("登录 Mac 时启动 Miruun" as NSString).draw(
                    at: NSPoint(x: 51, y: 242), withAttributes: [
                        .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                        .foregroundColor: NSColor.labelColor
                    ])
            }
        }
        let footerY = Self.contentSize(for: page).height - 46
        drawContainer(NSRect(x: 16, y: footerY, width: 144, height: 30), radius: 9)
        drawContainer(NSRect(x: 172, y: footerY, width: 144, height: 30), radius: 9)
        drawFooter(symbol: page == 0 ? "gearshape" : "arrow.left",
                   title: page == 0 ? "设置" : "返回",
                   in: NSRect(x: 16, y: footerY, width: 144, height: 30))
        drawFooter(symbol: "power", title: "退出",
                   in: NSRect(x: 172, y: footerY, width: 144, height: 30))
    }

    static func color(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
                green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }

    // Unequal, weathered basins suggest a paw without tracing a regular paw mark.
    private static let moonBasins: [NSBezierPath] = {
        let outlines: [[(CGFloat, CGFloat)]] = [
            [(5.2, 10.5), (5.0, 9.3), (5.6, 8.2), (6.4, 8.4),
             (7.3, 8.0), (7.9, 9.3), (7.7, 10.2), (6.7, 11.3), (5.8, 11.1)],
            [(8.0, 6.8), (8.5, 5.0), (9.4, 4.7), (10.3, 5.0),
             (10.5, 6.1), (11.1, 6.8), (10.6, 8.0), (9.6, 8.5), (8.6, 8.0)],
            [(12.9, 5.8), (13.6, 4.5), (14.8, 4.6), (15.3, 5.5),
             (14.9, 6.3), (14.8, 7.4), (13.8, 8.0), (12.8, 7.8), (12.5, 6.8)],
            [(16.3, 9.0), (16.6, 8.1), (17.6, 7.6), (18.4, 8.2),
             (18.8, 9.4), (18.1, 10.7), (16.9, 11.1), (16.5, 10.2), (15.8, 9.8)],
            [(7.7, 14.5), (9.4, 13.0), (10.4, 11.8), (11.8, 12.0),
             (12.3, 13.0), (13.1, 13.4), (14.6, 13.0), (15.7, 14.1),
             (15.1, 15.7), (13.5, 16.2), (12.0, 15.8), (10.4, 16.9),
             (8.9, 16.3), (7.5, 16.5), (7.1, 15.5)]
        ]
        return outlines.map { outline in
            let points = outline.map { NSPoint(x: $0.0, y: $0.1) }
            let path = NSBezierPath()
            path.move(to: points[0])
            // Smooth a closed outline while retaining its asymmetry and shallow notches.
            for index in points.indices {
                let previous = points[(index + points.count - 1) % points.count]
                let start = points[index]
                let end = points[(index + 1) % points.count]
                let next = points[(index + 2) % points.count]
                path.curve(to: end,
                    controlPoint1: NSPoint(x: start.x + (end.x - previous.x) / 6,
                                           y: start.y + (end.y - previous.y) / 6),
                    controlPoint2: NSPoint(x: end.x - (next.x - start.x) / 6,
                                           y: end.y - (next.y - start.y) / 6))
            }
            path.close()
            return path
        }
    }()

    static func moonImage(size: NSSize = NSSize(width: 18, height: 18), eclipseProgress: Double? = nil) -> NSImage {
        NSImage(size: size, flipped: true) { _ in
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            let scale = NSAffineTransform()
            scale.scaleX(by: size.width / 24, yBy: size.height / 24)
            scale.concat()

            let progress = min(max(eclipseProgress ?? 0, 0), 1)
            let travel = (1 - cos(progress * .pi)) / 2
            let shadowCenter = NSPoint(x: -27 + 78 * travel, y: 12)
            let glow = 1 - 0.8 * pow(sin(progress * .pi), 4)
            guard let halo = NSGradient(colorsAndLocations:
                (color(0xffbd80).withAlphaComponent(0.30 * glow), 0),
                (color(0xfaa774).withAlphaComponent(0.09 * glow), 0.45),
                (color(0xfaa774).withAlphaComponent(0), 1)),
                let surface = NSGradient(colorsAndLocations:
                (color(0xfff7e7), 0), (color(0xe3dfd4), 0.52), (color(0x929ba5), 1)),
                let basin = NSGradient(colorsAndLocations:
                (color(0x555351).withAlphaComponent(0.21), 0),
                (color(0x69717a).withAlphaComponent(0.16), 0.48),
                (color(0x848984).withAlphaComponent(0.035), 1)),
                let warmEdge = NSGradient(colorsAndLocations:
                (color(0xffb16b).withAlphaComponent(0.60), 0),
                (color(0xffd2a0).withAlphaComponent(0.32), 0.4),
                (color(0xe1e9f4).withAlphaComponent(0.05), 1)),
                let shadow = NSGradient(colorsAndLocations:
                (color(0x272731).withAlphaComponent(0.89), 0),
                (color(0x332c31).withAlphaComponent(0.89), 0.52),
                (color(0x92725e).withAlphaComponent(0.48), 0.82),
                (color(0x92725e).withAlphaComponent(0), 1)) else {
                preconditionFailure("Unable to create the lunar gradients")
            }
            // Keep the glow inside the 18 pt canvas with a transparent outer edge.
            halo.draw(fromCenter: NSPoint(x: 12, y: 12), radius: 9.4,
                      toCenter: NSPoint(x: 12, y: 12), radius: 12, options: [])
            let disk = NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: 20, height: 20))
            NSGraphicsContext.saveGraphicsState()
            disk.addClip()
            surface.draw(fromCenter: NSPoint(x: 8, y: 6), radius: 0,
                         toCenter: NSPoint(x: 12, y: 12), radius: 15,
                         options: [.drawsBeforeStartingLocation, .drawsAfterEndingLocation])
            for (index, path) in moonBasins.enumerated() {
                NSGraphicsContext.saveGraphicsState()
                defer { NSGraphicsContext.restoreGraphicsState() }
                NSGraphicsContext.current?.cgContext.setAlpha([0.85, 1, 0.60, 0.75, 0.95][index])
                NSGraphicsContext.saveGraphicsState()
                let erosion = NSShadow()
                erosion.shadowOffset = .zero
                erosion.shadowBlurRadius = 0.55
                erosion.shadowColor = color(0x5a5c64).withAlphaComponent(0.18)
                erosion.set()
                color(0x5a5c64).withAlphaComponent(0.06).setFill()
                path.fill()
                NSGraphicsContext.restoreGraphicsState()
                // A displaced light lip and shaded floor give each basin a little depth.
                NSGraphicsContext.saveGraphicsState()
                let lip = NSAffineTransform()
                lip.translateX(by: 0.08, yBy: 0.20)
                lip.concat()
                color(0xfff6da).withAlphaComponent(0.16).setFill()
                path.fill()
                NSGraphicsContext.restoreGraphicsState()
                basin.draw(in: path, angle: 78)
            }
            // Fixed small depressions break up the surface, without flickering per frame.
            for index in 0..<32 {
                let angle = Double(index) * 2.3999632297
                let radius = sqrt(Double(index + 1) / 33) * 9.1
                let x = 12 + cos(angle) * radius
                let y = 12 + sin(angle) * radius
                let diameter = 0.22 + Double(index % 4) * 0.12
                color(0x575960).withAlphaComponent(0.11).setFill()
                NSBezierPath(ovalIn: NSRect(x: x, y: y, width: diameter, height: diameter * 0.8)).fill()
                color(0xfff8e1).withAlphaComponent(0.20).setFill()
                NSBezierPath(ovalIn: NSRect(x: x, y: y + diameter * 0.7,
                                           width: diameter, height: diameter * 0.35)).fill()
            }
            let rim = NSBezierPath(ovalIn: NSRect(x: 2.1, y: 2.1, width: 19.8, height: 19.8))
            rim.appendOval(in: NSRect(x: 2.45, y: 2.45, width: 19.1, height: 19.1))
            rim.windingRule = .evenOdd
            warmEdge.draw(in: rim, angle: 32)
            // The penumbra carries a faint amber tint; the moon stays opaque at totality.
            shadow.draw(fromCenter: shadowCenter, radius: 0,
                        toCenter: shadowCenter, radius: 26, options: [])
            NSGraphicsContext.restoreGraphicsState()

            color(0x42434b).withAlphaComponent(0.36).setStroke()
            disk.lineWidth = 0.4
            disk.stroke()
            let edge = NSBezierPath(ovalIn: NSRect(x: 2.3, y: 2.3, width: 19.4, height: 19.4))
            color(0xf8d9b5).withAlphaComponent(0.12 + 0.08 * glow).setStroke()
            edge.lineWidth = 0.25
            edge.stroke()
            return true
        }
    }

    private func surfacePath() -> NSBezierPath {
        let path = NSBezierPath()
        let height = Self.contentSize(for: page).height
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
        path.line(to: NSPoint(x: 331.5, y: height - 19))
        path.curve(to: NSPoint(x: 313, y: height - 0.5),
                   controlPoint1: NSPoint(x: 331.5, y: height - 8.8),
                   controlPoint2: NSPoint(x: 323.2, y: height - 0.5))
        path.line(to: NSPoint(x: 19, y: height - 0.5))
        path.curve(to: NSPoint(x: 0.5, y: height - 19),
                   controlPoint1: NSPoint(x: 8.8, y: height - 0.5),
                   controlPoint2: NSPoint(x: 0.5, y: height - 8.8))
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
