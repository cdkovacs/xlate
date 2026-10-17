import CoreGraphics
import Foundation

public enum PillTiming {
    /// Seconds a caption stays up without a newer one.
    public static let fadeAfter: TimeInterval = 8

    public static func isVisible(lastCaptionAt: TimeInterval?, now: TimeInterval) -> Bool {
        guard let lastCaptionAt else { return false }
        return now - lastCaptionAt < fadeAfter
    }
}

/// What the pill shows: the newest caption plus up to `limit` earlier ones.
public struct CaptionHistory: Equatable, Sendable {
    /// Earlier captions, oldest first.
    public private(set) var earlier: [Caption] = []
    public private(set) var current = Caption(english: "", portuguese: "")
    public var limit: Int {
        didSet {
            limit = max(0, limit)
            trim()
        }
    }

    public init(limit: Int) {
        self.limit = max(0, limit)
    }

    public mutating func push(_ caption: Caption) {
        if !current.english.isEmpty { earlier.append(current) }
        current = caption
        trim()
    }

    public mutating func clear() {
        earlier = []
        current = Caption(english: "", portuguese: "")
    }

    private mutating func trim() {
        if earlier.count > limit { earlier.removeFirst(earlier.count - limit) }
    }
}

/// How big the pill's text is. Medium is the original look; the others
/// scale fonts, spacing, and width together so line breaks stay similar.
public enum CaptionSize: String, CaseIterable, Sendable {
    case small, medium, large, extraLarge

    /// Falls back to medium for a missing or unknown saved value.
    public init(saved: String?) {
        self = saved.flatMap(Self.init(rawValue:)) ?? .medium
    }

    public var title: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        case .extraLarge: "Extra Large"
        }
    }

    public var scale: CGFloat {
        switch self {
        case .small: 0.85
        case .medium: 1
        case .large: 1.2
        case .extraLarge: 1.45
        }
    }
}

/// Where the pill goes. Coordinates are AppKit screen coordinates (origin at
/// the bottom left of the main screen).
public enum PillPlacement {
    public static let topInset: CGFloat = 60

    /// Keeps a saved position if the pill still fits on some screen; otherwise
    /// slides it onto the screen it overlaps most, or onto `preferred`.
    public static func clamp(origin: CGPoint, size: CGSize, visibleFrames: [CGRect], preferred: CGRect) -> CGPoint {
        let rect = CGRect(origin: origin, size: size)
        if visibleFrames.contains(where: { $0.contains(rect) }) { return origin }
        let overlapping = visibleFrames.max { area($0.intersection(rect)) < area($1.intersection(rect)) }
        let screen = overlapping.flatMap { area($0.intersection(rect)) > 0 ? $0 : nil } ?? preferred
        return CGPoint(x: min(max(origin.x, screen.minX), screen.maxX - size.width),
                       y: min(max(origin.y, screen.minY), screen.maxY - size.height))
    }

    public static func defaultOrigin(size: CGSize, in screen: CGRect) -> CGPoint {
        CGPoint(x: (screen.midX - size.width / 2).rounded(), y: screen.maxY - topInset - size.height)
    }

    private static func area(_ rect: CGRect) -> CGFloat {
        rect.isNull ? 0 : rect.width * rect.height
    }
}
