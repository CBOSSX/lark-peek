import Foundation

public struct TimelineReadingPosition: Equatable, Sendable {
    public let messageID: String
    public let screenY: CGFloat
    public let isAtBottom: Bool

    public init(messageID: String, screenY: CGFloat, isAtBottom: Bool) {
        self.messageID = messageID
        self.screenY = screenY
        self.isAtBottom = isAtBottom
    }
}

/// In-memory UI state belongs to a cached conversation, never to a reused row view.
@MainActor
public final class PreviewReadingState {
    public var position: TimelineReadingPosition?
    public var expandedCards: [String: Bool] = [:]

    public init() {}
}
