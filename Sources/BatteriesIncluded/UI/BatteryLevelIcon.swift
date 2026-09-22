import AppKit

/// A vector-backed template image so the fill tracks the exact percentage,
/// including values between the standard SF Symbols' battery increments.
enum BatteryLevelIcon {
    static func image(percentage: Int?, isCharging: Bool, showsUnknown: Bool = false) -> NSImage {
        let fraction = CGFloat(min(100, max(0, percentage ?? 0))) / 100
        let image = NSImage(size: NSSize(width: 23, height: 12), flipped: false) { _ in
            NSColor.black.setFill()
            NSColor.black.setStroke()
            let outline = NSBezierPath(roundedRect: NSRect(x: 0.75, y: 0.75, width: 19.5, height: 10.5),
                                       xRadius: 2, yRadius: 2)
            outline.lineWidth = 1.2
            outline.stroke()
            NSBezierPath(roundedRect: NSRect(x: 21, y: 4, width: 2, height: 4),
                         xRadius: 0.8, yRadius: 0.8).fill()
            if fraction > 0 {
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(roundedRect: NSRect(x: 2.5, y: 2.5, width: 16, height: 7),
                             xRadius: 0.6, yRadius: 0.6).addClip()
                NSRect(x: 2.5, y: 2.5, width: 16 * fraction, height: 7).fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            if showsUnknown, percentage == nil {
                let mark = NSAttributedString(string: "?", attributes: [
                    .font: NSFont.systemFont(ofSize: 10, weight: .bold),
                    .foregroundColor: NSColor.black
                ])
                let size = mark.size()
                mark.draw(at: NSPoint(x: (21 - size.width) / 2, y: (12 - size.height) / 2))
            } else if isCharging {
                let bolt = NSBezierPath()
                bolt.move(to: NSPoint(x: 12, y: 10))
                bolt.line(to: NSPoint(x: 7, y: 5.4))
                bolt.line(to: NSPoint(x: 10, y: 5.4))
                bolt.line(to: NSPoint(x: 9, y: 2))
                bolt.line(to: NSPoint(x: 14, y: 6.6))
                bolt.line(to: NSPoint(x: 11, y: 6.6))
                bolt.close()
                // Clear a halo so the bolt is legible against any fill level.
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current?.compositingOperation = .copy
                NSColor.clear.setStroke()
                bolt.lineWidth = 2
                bolt.lineJoinStyle = .round
                bolt.stroke()
                NSGraphicsContext.restoreGraphicsState()
                NSColor.black.setFill()
                bolt.fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
