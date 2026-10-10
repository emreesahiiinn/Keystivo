import AppKit

/// Converts between Cocoa screen coordinates (bottom-left origin, y up) and
/// Accessibility/Quartz coordinates (top-left origin of the primary display, y down).
public enum ScreenGeometry {
    public static var primaryHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    public static func toCocoa(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    public static func toAX(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    public static func toCocoa(point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    public static func toAX(point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    /// Usable area of a screen (excluding menu bar and Dock) in AX coordinates.
    public static func visibleFrameAX(of screen: NSScreen) -> CGRect {
        toAX(screen.visibleFrame)
    }

    public static func frameAX(of screen: NSScreen) -> CGRect {
        toAX(screen.frame)
    }

    /// Screen with the largest overlap with an AX-space rect.
    public static func screen(forAXRect rect: CGRect) -> NSScreen? {
        let cocoa = toCocoa(rect)
        var best: (NSScreen, CGFloat)?
        for screen in NSScreen.screens {
            let overlap = screen.frame.intersection(cocoa)
            let area = overlap.isNull ? 0 : overlap.width * overlap.height
            if area > (best?.1 ?? -1) { best = (screen, area) }
        }
        if let best, best.1 > 0 { return best.0 }
        // No overlap (off-screen window): nearest by center distance.
        let center = CGPoint(x: cocoa.midX, y: cocoa.midY)
        return NSScreen.screens.min { lhs, rhs in
            distance(center, lhs.frame) < distance(center, rhs.frame)
        }
    }

    /// Screens ordered left-to-right, then top-to-bottom, for "next display" moves.
    public static var orderedScreens: [NSScreen] {
        NSScreen.screens.sorted { lhs, rhs in
            if abs(lhs.frame.minX - rhs.frame.minX) > 1 { return lhs.frame.minX < rhs.frame.minX }
            return lhs.frame.maxY > rhs.frame.maxY
        }
    }

    private static func distance(_ point: CGPoint, _ rect: CGRect) -> CGFloat {
        hypot(point.x - rect.midX, point.y - rect.midY)
    }
}
